--- The screen: its page, its requests, the server's pushes and a confirmed use.
-- @author dop42
--
-- The server decides every change; the page predicts one and draws it, and the
-- next push corrects it. Nothing here is authoritative about anything.
--
-- The page lives on the INTERACTIVE surface (z 740), which takes the keyboard and
-- the cursor for exactly as long as the screen is up. `OPX.UI` owns the surface
-- and the focus stack; this file owns one module on it.
--
-- WHAT THIS RUNTIME DELETED. The screen used to create and own a CEF surface of
-- its own, one of twelve, each carrying its own copy of the same stylesheet
-- because a WebUI page cannot load a file from another origin. It is one module
-- on a shared surface now, and the focus it takes is a stack entry rather than a
-- `setFocus` nobody else can see.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog

M.Screen = {}
local Screen = M.Screen

-- The one surface this module draws on, and the owner name it takes focus under.
local SURFACE = 'interactive'
local FOCUS_OWNER = 'inventory'

-- Milliseconds before a request with no answer settles as a timeout. Above the
-- server's own bounded waits, so a slow answer arrives rather than being dropped.
local REQUEST_TIMEOUT_MS = 15000

-- Catalogue entries carried by one page write. An entry is about twenty value
-- nodes with its name, and the host silently drops a page write past 1,024.
local CATALOG_PART = 40

-- Whether the surface has been built and its channels wired, whether the page has
-- reported itself mounted, and the one write that is waiting for it to.
local surfaceWired = false
local pageReady = false
local pendingOpen = nil

-- The handle the current opening is keyed on. A payload carrying any other handle
-- belongs to a screen that has already been replaced, and is dropped.
local handle = nil
local handleSequence = 0

local open = false
local opening = false
local openAgain = false

-- The bag the server last pushed, and the weapon the bag put in hand.
local own = nil
local held = nil

-- Requests awaiting an answer, and the last id handed out.
local waiting = {}
local nextRequest = 0

-- Catalogue names still to be written to the page, and the generation the writer
-- belongs to: a newer send stops an older writer at its next part.
local catalogQueue = nil
local catalogAt = 1
local catalogWrites = 0

local release = nil

-- Forward-declared: the open path calls it and it is defined further down, beside
-- the page channels it wires. A local declared after its caller would leave that
-- caller reading a global that is never set.
local ensureSurface

--- Writes one message to the page.
local function send(name, payload)
	if not pageReady then return false end
	return OPX.UI.Send(SURFACE, 'inventory:' .. name, payload)
end

--- Whether a payload belongs to the screen that is open now.
local function mine(payload)
	return handle ~= nil and payload.handle == handle
end

--- The words and the tabs the page draws, in the configured language.
local function labels()
	local keys = {
		'bag', 'ground', 'trunk', 'glovebox', 'stash', 'drop', 'weight', 'ammo', 'serial',
		'condition', 'use', 'split', 'dropZone', 'giveTo', 'sortWeight', 'sortName', 'close',
		'nobody', 'unknown', 'kg', 'g', 'm', 'slots', 'groundHint',
		-- The two the page needs for its own status line. Every refusal the SERVER
		-- makes is toasted from there, so the page only ever has to say that a
		-- round trip failed or never came back.
		'failed', 'timeout',
	}
	local out = {}
	for index = 1, #keys do out[keys[index]] = locale('inventory.ui.' .. keys[index]) end

	local tabs = {}
	for index, tab in ipairs(Options.TABS) do
		tabs[index] = {
			key = tab.key,
			label = locale('inventory.tab.' .. tab.key),
			categories = tab.categories,
			rest = tab.rest,
		}
	end
	out.tabs = tabs
	return out
end

--- The words, the tabs, the hotbar keys and the open key.
-- The keys are read at send time rather than at registration: a player who
-- rebinds one gets the new cap without anything being registered again.
local function configPayload()
	local hotbar = {}
	for index = 1, Options.HOTBAR_SLOTS do
		hotbar[index] = M.Keys.Effective('opx.inventory.hotbar' .. index)
			or (Options.KEYS_HOTBAR[index] or '')
	end
	return {
		labels = labels(),
		hotbar = hotbar,
		openKey = M.Keys.Effective('opx.inventory.open') or '',
		drops = Options.DROPS,
		defaultWeight = Catalog.DefaultWeight(),
	}
end

--- Sends the page the configuration on its own, for a rebind.
-- @author dop42
function Screen.SendConfig()
	send('config', configPayload())
end

--- Queues the whole catalogue to be written to the page in parts.
-- The scheduler drains it one part per pass: an entry costs about sixty VM
-- instructions to shape, a client handler that passes 10,000 is stopped by the
-- host, and a page write past 1,024 value nodes is dropped without a word.
local function queueCatalog()
	catalogWrites = catalogWrites + 1
	catalogQueue = Catalog.Names()
	catalogAt = 1
end

--- Writes the next catalogue part, if one is waiting.
local function drainCatalog()
	if catalogQueue == nil then return end
	local names = catalogQueue
	local mark = catalogWrites
	local first = catalogAt
	local last = math.min(#names, first + CATALOG_PART - 1)

	local entries = {}
	for index = first, last do entries[names[index]] = Catalog.ViewOf(names[index]) end
	send('catalog', { entries = entries, first = first == 1, done = last >= #names })

	-- A newer send replaced the queue while this part was being shaped; that
	-- writer owns it now.
	if mark ~= catalogWrites then return end
	catalogAt = last + 1
	if catalogAt > #names then catalogQueue = nil end
end

-- ── requests ─────────────────────────────────────────────────────────────────

--- Sends one request to the server, answered to the page, to a callback, or both.
-- @author dop42
-- @param action string
-- @param payload table|nil
-- @param callback fun(ok: boolean, code: string, data: table)|nil
-- @param ref any the page reference the answer is written back under
function Screen.Request(action, payload, callback, ref)
	nextRequest = nextRequest % 2147483646 + 1
	waiting[nextRequest] = { ref = ref, callback = callback, atMs = OPX.Now() }
	TriggerServerEvent(M.Event.REQUEST, nextRequest, action, payload or {})
end

--- Delivers one answer to the page and to the callback.
local function settle(entry, ok, code, data)
	if entry.ref ~= nil then
		-- The page waits on `opx:reply` under the ref it generated; `OPX.UI.Answer`
		-- is the channel `ui/src/bridge/rpc.ts` listens on.
		OPX.UI.Answer(SURFACE, entry.ref, { ok = ok, error = code, data = data })
	end
	if entry.callback then
		local ran, failure = pcall(entry.callback, ok, code, data)
		if not ran then Open77.log.error('[inventory] request callback: ' .. tostring(failure)) end
	end
end

--- Whether something says the local player is down.
-- The `downed` contract answers a Result carrying `{ down, waiting }`, not a
-- boolean: reading the Result itself as one makes every player permanently down,
-- because a table is truthy.
local function isDown()
	local downed = M.Contracts.downed
	if downed == nil then return false end
	local answer = downed.IsDown()
	return answer ~= nil and answer.ok == true and answer.value.down == true
end

--- Whether the screen may be up at all: not down, and not dead.
local function usable()
	if isDown() then return false end
	local character = Open77.character
	if type(character) == 'table' and type(character.isAlive) == 'function' then
		local read, alive = pcall(character.isAlive)
		if read and alive == false then return false end
	end
	return true
end

--- Whether the screen is up.
-- @author dop42
-- @return boolean
function Screen.IsOpen()
	return open
end

--- The bag the server last pushed, or nil.
-- @author dop42
-- @return table|nil
function Screen.Own()
	return own
end

--- The weapon the bag put in hand, or nil.
-- @author dop42
-- @return table|nil
function Screen.Held()
	return held
end

--- How many units of an item the bag the server last pushed holds.
-- Read off the LAST PUSH, which is the server's own copy, and never off a
-- prediction the page has drawn.
local function countOf(name)
	local bag = own
	if type(bag) ~= 'table' or type(bag.items) ~= 'table' then return 0 end
	local total = 0
	for index = 1, #bag.items do
		local entry = bag.items[index]
		if entry.name == name then total = total + (tonumber(entry.count) or 0) end
	end
	return total
end

--- Whether something says the local player is down.
-- @author dop42
-- @return boolean
function Screen.IsDown()
	return isDown()
end

-- ── opening and closing ──────────────────────────────────────────────────────

--- Takes the keyboard and the cursor, then draws the granted open answer.
local function show(data)
	if type(data.primary) ~= 'table' then return end
	own = data.primary
	if Screen.IsDown() then
		if not open then Screen.Request('close') end
		return
	end

	local wasOpen = open
	if not wasOpen then
		handleSequence = handleSequence + 1
		handle = ('inv%d'):format(handleSequence)
		-- The page holds the keyboard as well as the cursor: the modifier gestures
		-- and Escape are read there, and a held ALT must not open something else
		-- over the top.
		release = OPX.UI.AcquireFocus(FOCUS_OWNER, { keyboard = true, cursor = true })
			and function() OPX.UI.ReleaseFocus(FOCUS_OWNER) end
			or nil
	end
	open = true

	local payload = {
		handle = handle,
		config = configPayload(),
		primary = data.primary,
		secondary = type(data.secondary) == 'table' and data.secondary or false,
	}
	-- A send made before the page has reported ready is DROPPED, not queued, so
	-- the very first open -- the one that built the surface -- is held until the
	-- page says it has mounted.
	if not send('open', payload) then pendingOpen = payload end

	if not wasOpen then TriggerEvent(M.Event.ON_OPENED) end
end

--- Closes the screen and hands the focus back.
-- @author dop42
function Screen.Close()
	if not open then return end
	open = false
	send('close', { handle = handle })
	handle = nil
	pendingOpen = nil
	if release then release() end
	release = nil
	Screen.Request('close')
	TriggerEvent(M.Event.ON_CLOSED)
end

--- Opens the screen, optionally after a request that opens a container first.
-- `first` is sent before the open; `onlyWith` says the screen must stay closed
-- when that request is refused, which is what a world prompt wants and what the
-- open key does not.
-- @author dop42
-- @param first string|nil a request action sent before the open
-- @param payload table|nil
-- @param onlyWith boolean|nil
function Screen.Open(first, payload, onlyWith)
	if opening then return end
	if not usable() then return end
	-- The surface is built here, on the first open, and not at start: a player who
	-- never opens anything never pays for a second CEF page.
	if not ensureSurface() then return end
	opening = true

	local function settled()
		opening = false
		if not openAgain then return end
		openAgain = false
		Screen.FromServer()
	end

	local function openBag()
		Screen.Request('open', nil, function(ok, code, data)
			opening = false
			if ok then
				show(data)
			elseif code ~= 'not_ready' and code ~= 'not_loaded' then
				-- Those two are the ordinary "not in the world yet" and are silent.
				Open77.log.info('[inventory] open refused: ' .. tostring(code))
			end
			settled()
		end)
	end

	if not first then return openBag() end
	Screen.Request(first, payload, function(ok)
		if not ok and onlyWith then return settled() end
		openBag()
	end)
end

--- Opens what the server has just opened beside the bag.
-- Held back while an opening is already in flight and replayed as soon as that
-- one settles, accepted or refused: without that the screen could end up closed,
-- or open without the container the server had just put beside it -- whose push
-- is ignored while the screen is closed.
-- @author dop42
function Screen.FromServer()
	if Screen.IsDown() then return Screen.Request('close') end
	if opening then
		openAgain = true
		return
	end
	if open then
		Screen.Request('open', nil, function(ok, _, data) if ok then show(data) end end)
		return
	end
	Screen.Open()
end

-- ── what the server pushes ───────────────────────────────────────────────────

--- Units per item name in a bag payload.
local function countsOf(bag)
	local counts = {}
	local items = type(bag.items) == 'table' and bag.items or {}
	for index = 1, #items do
		local entry = items[index]
		counts[entry.name] = (counts[entry.name] or 0) + (tonumber(entry.count) or 0)
	end
	return counts
end

--- What the bag gained and lost between two pushes.
local function changesOf(previous, current)
	if not previous or previous.id ~= current.id then return {} end
	local before, after = countsOf(previous), countsOf(current)
	local changes = {}
	for name, count in pairs(after) do
		local delta = count - (before[name] or 0)
		if delta ~= 0 then changes[#changes + 1] = { name = name, delta = delta } end
	end
	for name, count in pairs(before) do
		if not after[name] then changes[#changes + 1] = { name = name, delta = -count } end
	end
	return changes
end

--- Says what the bag gained and lost, with the screen closed.
-- One replaceable toast and not a strip of its own: the interactive surface is
-- not built until the player opens something, and a running total of pickups is
-- exactly what the overlay's toast lane is for. The id is fixed, so a run of
-- pickups rewrites one toast instead of stacking a pile of them.
local function announce(changes)
	local lines = {}
	for index = 1, #changes do
		local change = changes[index]
		lines[#lines + 1] = ('%s%d %s')
			:format(change.delta > 0 and '+' or '', change.delta, Catalog.Label(change.name))
	end
	if #lines == 0 then return end
	OPX.Toast.Show({
		id = 'inventory.change',
		kind = 'info',
		message = table.concat(lines, '   '),
	})
end

--- Sends another resource's client half a message, from a thread of its own.
-- Each call gets its own thread so one slow answer cannot hold up the rest; a
-- resource that is simply not running costs nothing and is not reported.
local function tell(resource, name, ...)
	local args = table.pack(...)
	CreateThread(function()
		local sent = OPX.Lib.Rpc.Call(resource, name, table.unpack(args, 1, args.n))
		if not sent.ok and sent.error ~= 'not_running' and sent.error ~= 'no_exports' then
			Open77.log.info(('[inventory] %s.%s answered %s'):format(resource, name, sent.error))
		end
	end)
end

--- Registers the handlers the server pushes to.
local function registerEvents()
	RegisterNetEvent(M.Event.ANSWER, function(requestId, ok, code, data)
		local entry = waiting[requestId]
		if not entry then return end
		waiting[requestId] = nil
		settle(entry, ok == true, type(code) == 'string' and code or '',
			type(data) == 'table' and data or {})
	end)

	RegisterNetEvent(M.Event.OWN, function(payload)
		if type(payload) ~= 'table' then return end
		local changes = changesOf(own, payload)
		own = payload
		if open then
			send('update', { handle = handle, container = payload })
		elseif #changes > 0 and not Screen.IsDown() then
			announce(changes)
		end
		-- The mirror is updated BEFORE the event, so a handler reading `Own` sees
		-- the change and not the value it replaced.
		TriggerEvent(M.Event.ON_CHANGED, { inventory = payload, changes = changes })
	end)

	RegisterNetEvent(M.Event.CONTAINER, function(payload)
		if not open or type(payload) ~= 'table' then return end
		send('update', { handle = handle, container = payload })
	end)

	RegisterNetEvent(M.Event.SECONDARY, function(payload)
		if not open then return end
		send('secondary', { handle = handle,
			container = type(payload) == 'table' and payload or false })
	end)

	RegisterNetEvent(M.Event.NEARBY, function(list)
		if not open then return end
		send('nearby', { handle = handle, players = type(list) == 'table' and list or {} })
	end)

	RegisterNetEvent(M.Event.OPEN, function()
		Screen.FromServer()
	end)

	RegisterNetEvent(M.Event.RESET, function()
		Screen.Close()
		own = nil
		held = nil
		OPX.Toast.Dismiss('inventory.change')
	end)

	RegisterNetEvent(M.Event.ARMED, function(payload)
		held = type(payload) == 'table' and payload or nil
		TriggerEvent(M.Event.ON_ARMED, held)
	end)

	RegisterNetEvent(M.Event.USED, function(payload)
		if type(payload) ~= 'table' then return end
		if payload.close ~= false then Screen.Close() end

		-- The needs contract is optional: with none the item is still consumed and
		-- the animation still plays, and only what it would have moved is lost.
		local needs = M.Contracts.needs
		if needs and type(payload.status) == 'table' and next(payload.status) ~= nil then
			local moved = needs.AddNeeds(payload.status)
			if moved ~= nil and moved.ok ~= true then
				-- A need this item names that the operator has not declared is the
				-- ordinary case; it costs the move, not the use.
				Open77.log.debug('[inventory] the needs of a use were refused: '
					.. tostring(moved.error))
			end
		end

		local animation = payload.animation
		if type(animation) == 'table' and type(animation.name) == 'string' then
			-- THROUGH OUR OWN CONTRACT, AND IT USED TO BE A CALL INTO NOTHING. This
			-- read `tell('opx77_animations', 'play', ...)` -- the external resource
			-- `modules/animations` was written to replace, which this server does
			-- not load and which the manifest does not name. A cross-resource call
			-- to a resource that is not running costs nothing and says nothing, so
			-- eating an item played no animation at all and nobody could tell the
			-- difference between "the config is wrong" and "the call went nowhere".
			--
			-- The comment that was here said there was no contract to read. There
			-- is: `animations` publishes one, it takes the same four options under
			-- the same names, and it is in this runtime.
			-- THE BAR OWNS THE GESTURE, and that is why this asks `progress` rather
			-- than `animations`. A timed action is three things -- a picture of how
			-- long is left, a hold on the player, and a gesture -- and they have to
			-- begin and end together or the player is left standing in an animation
			-- with no bar, or held by a lock with nothing on screen to explain it.
			-- `progress` starts both and `finish` takes both down on every exit.
			--
			-- A DURATION IS WHAT MAKES IT A BAR. An item whose `USE.ANIMATION` names
			-- no `DURATION_MS` is a gesture and not a timed action, so it goes
			-- straight to `animations` as before -- there is nothing to count.
			local progress = OPX.Api.Get('progress')
			local animations = OPX.Api.Get('animations')

			if progress ~= nil and animation.durationMs ~= nil then
				local shown = progress.Start(FOCUS_OWNER, {
					label = payload.label or payload.name or '',
					durationMs = animation.durationMs,
					animation = { name = animation.name, variant = animation.variant },
					-- Eating is the case this was written for, and the owner's words
					-- were that the player must not be able to stop it.
					cancelable = false,
				})
				if type(shown) == 'table' and shown.ok ~= true then
					Open77.log.debug(('[inventory] the bar for %s was refused: %s')
						:format(animation.name, tostring(shown.error)))
				end
			elseif animations == nil then
				-- Optional, like every other contract this module reaches for: the
				-- item is still used and its needs still move, and only the gesture
				-- is lost. Said once rather than silently, because a missing
				-- animation is exactly what the old call failed to report.
				Open77.log.debug('[inventory] no animations contract: ' .. animation.name
					.. ' is not played')
			else
				local played = animations.Play(animation.name, {
					variant = animation.variant,
					loop = false,
					durationMs = animation.durationMs,
					cancelable = false,
				}, FOCUS_OWNER)
				if type(played) == 'table' and played.ok ~= true then
					Open77.log.debug(('[inventory] %s was refused: %s')
						:format(animation.name, tostring(played.error)))
				end
			end
		end

		TriggerEvent(M.Event.ON_USED, payload)
	end)

	-- A character leaving takes the screen and the mirror with it.
	AddEventHandler(M.Event.ON_CHARACTER_UNLOADED, function()
		Screen.Close()
		own = nil
		held = nil
	end)

	AddEventHandler(M.Event.ON_CHARACTER_LOADED, function()
		TriggerServerEvent(M.Event.HELLO)
	end)
end

--- Builds the interactive surface if it does not exist, and wires this module's
--- page channels once. Answers whether there is a surface at all.
--
-- CALLED FROM `Start`, and idempotently from the open path after it. It used to be
-- called ONLY from the open path, to keep a player who never opens anything from
-- paying for a second CEF page. That reasoning died with the page merge: there is
-- one surface now and `core/client/boot.lua` creates it BEFORE any module's
-- `Start`, so nothing is saved by wiring late -- and wiring late broke the screen
-- outright.
--
-- `inventory:ready` is emitted ONCE, from the page's `setup()`, and a channel
-- event raised before its handler exists is dropped, not queued. Wiring on first
-- open therefore always missed it: `pageReady` stayed false, `send` refused every
-- write for the life of the session, and the first open parked its payload in
-- `pendingOpen` waiting for a handshake that had already been and gone. The player
-- lost the keyboard and the cursor to a screen that was never drawn.
--
-- This is the same idiom `modules/hud/client/main.lua` uses: the ready channel is
-- wired in `Start`, which is the only phase that is guaranteed to run before the
-- page mounts.
-- @return boolean
function ensureSurface()
	if surfaceWired then return true end
	if OPX.UI.Interactive() == nil then return false end
	surfaceWired = true

	-- The page says when it has mounted. Core's `ui.lua` owns `opx:ready` and uses
	-- it to hand the page the locale catalogue; replacing that handler would leave
	-- every label rendering as its own key, so this module has a channel of its own.
	OPX.UI.On(SURFACE, 'inventory:ready', function()
		pageReady = true
		Screen.SendConfig()
		queueCatalog()
		-- A screen opened before the page had mounted: its one write was held back
		-- rather than dropped, because a send made before ready is not queued.
		if pendingOpen ~= nil then
			send('open', pendingOpen)
			pendingOpen = nil
		end
	end)

	OPX.UI.On(SURFACE, 'inventory:request', function(payload)
		if type(payload.action) ~= 'string' then return end
		if payload.handle ~= nil and not mine(payload) then return end
		local body = type(payload.payload) == 'table' and payload.payload or {}
		if payload.action == 'drop' then
			-- The heading lets the server put the pile in front of the player rather
			-- than under them. It is the only thing the client is asked for here,
			-- and all it can do is turn the pile around a position the server owns.
			local character = Open77.character
			local read, yaw = pcall(function() return character.yaw() end)
			body.yaw = read and tonumber(yaw) or nil
		end
		Screen.Request(payload.action, body, nil, payload.ref)
	end)

	-- A channel of its own, and not the one Lua sends `close` on. One name used in
	-- both directions reads as a loop even where it is not one, and the page
	-- asking to be closed is not the same message as Lua saying it has been.
	OPX.UI.On(SURFACE, 'inventory:dismiss', function(payload)
		if payload.handle ~= nil and not mine(payload) then return end
		Screen.Close()
	end)

	return true
end

--- One pass: expires unanswered requests, drains the catalogue, closes a screen
--- the player may no longer have up.
local function pass()
	local now = OPX.Now()
	for requestId, entry in pairs(waiting) do
		if now - entry.atMs > REQUEST_TIMEOUT_MS then
			waiting[requestId] = nil
			settle(entry, false, 'timeout', {})
		end
	end
	drainCatalog()
	if open and not usable() then Screen.Close() end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Nothing to build before the contract: the mirror is empty by definition.
-- @author dop42
function M.Init()
	M.Contracts = {}
end

--- Publishes the client half of the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('inventory', 1, {
		Open = function() Screen.Open() end,
		Close = Screen.Close,
		IsOpen = Screen.IsOpen,

		GetInventory = Screen.Own,
		GetHeldWeapon = Screen.Held,

		GetItemCount = countOf,

		HasItem = function(name, count)
			return countOf(name) >= (Common.Integer(count, 1, Options.MAX_STACK) or 1)
		end,

		GetItem = Catalog.ViewOf,

		OpenStash = function(name)
			-- Asking only. The server checks that the player is standing at it.
			Screen.Open('openStash', { name = name }, true)
		end,
	})
end

--- Wires the page and the wire, and registers the one pass. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.downed = OPX.Api.Get('downed')
	M.Contracts.needs = OPX.Api.Get('needs')
	M.Contracts.target = OPX.Api.Get('target')

	registerEvents()

	-- FIRST, and before anything that sends. The page emits `inventory:ready` once,
	-- from its own `setup()`, and a channel event with no handler is dropped rather
	-- than queued -- so the handler has to exist before the page mounts. `Start` is
	-- the last phase that is still inside the synchronous boot pass, and
	-- `core/client/boot.lua` created the surface before that pass began, so there is
	-- no page here to pay for: it is already up.
	if not ensureSurface() then
		Open77.log.error('[inventory] there is no surface: the screen can never be drawn')
	end

	-- THE KEYS BEFORE THE WORLD ROWS, and the order is load-bearing rather than
	-- tidy. `Wire` registers rows with the target module, and a raise anywhere in
	-- there aborts this function -- so with the two the other way round, one bad
	-- registration cost the player the open key AND the whole hotbar, which is
	-- every way into the bag at once. It is what the budget overrun did: the
	-- screen was unreachable by any route and nothing on screen said why.
	-- Nothing in `Register` needs a world row, so it goes first and survives.
	M.Keys.Register()
	M.World.Wire()

	OPX.Scheduler.Every('inventory.screen', 500, pass)

	TriggerServerEvent(M.Event.HELLO)
end

--- Gives the focus back unconditionally.
-- A cursor left captured through a stop leaves the player unable to move, which
-- is worse than any state this module could be leaving behind.
-- @author dop42
function M.Stop()
	open = false
	pageReady = false
	handle = nil
	OPX.UI.ReleaseFocus(FOCUS_OWNER)
end
