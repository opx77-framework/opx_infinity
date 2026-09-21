--- Client half: the markers, the strip row, the key, and the list you buy from.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT, and the list doubly so. The nearest dealer, the
-- radius, the stock and the price all decide only what this player is OFFERED;
-- the server re-derives the distance, the bucket, whether that dealer sells that
-- model and whether the money is there before anything is charged or created.
--
-- The dealers come from the server and never from `config/dealership.lua`
-- directly: captured dealers live in the database, and the server filters the
-- list to this player's own routing bucket. The prices come from the server for
-- the same reason -- it owns the currency table, and a client that formatted its
-- own would be a second answer to a question with one.
--
-- THE LIST IS THE `menu` MODULE'S, one flat screen at a time, with this file
-- holding its own stack -- the pattern the emote picker established. The whole
-- tree in one spec goes past the host's 1024-value bound, and a catalogue is
-- whatever an operator made it: two screens of forty rows each is a shop, and a
-- shop that silently stopped opening because the stock list grew is not.
--
-- The destination choice is read from the GARAGES contract, not resent by this
-- module: which garages exist, and where they are, is that module's answer, and
-- asking for a copy would be asking for a copy to keep in step.
--
-- The heading a capture records is read HERE and not on the server: a chat
-- command has no facing, and `Open77.character.yaw` is the only place a facing
-- exists. It is the one field this half contributes, and it only turns a
-- vehicle that is handed over where it was bought.

local M = OPX.Modules.Get('dealership')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'dealership'
local GROUP = 'dealer'

-- The id the menu is opened under, and the same id comes back on every payload.
-- Stable, because a payload names it.
local SPEC_ID = 'dealership'

-- The dealer list as the server last sent it, and the markers drawn for it.
local spots = {}
local markers = {}

-- What each kind of dealer sells, as the server sent it: `{ garage = {},
-- avpad = {} }` of `{ key, label, class, price, text }`.
local stock = { garage = {}, avpad = {} }

-- The dealer the player is standing on, whether its row is up, and the locale
-- key that row is naming. THE LABEL IS STATE, not a function of the boolean:
-- there are two kinds with two different strings, so a sync that compared only
-- "is a row up" would leave "Browse vehicles" standing over an AV pad the player
-- walked onto straight from a car dealer, without `nearest` ever passing nil.
local nearest, shown, shownLabel = nil, false, nil

-- Whether the key mapping answered.
local keyRegistered = false

-- The open menu's handle, and the screen stack this file owns, or nil/empty.
local handle, stack = nil, {}

-- Whether each failure was already logged. A marker that cannot be drawn and a
-- row that cannot be posted are different problems and a player reading the log
-- wants to know which one they have.
local reportedMarkers, reportedStrip, reportedMenu = false, false, false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- ── config and the player ───────────────────────────────────────────────────

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.dealership.use', NAME = 'dealership.key.use', DEFAULT = 'E' }
end

-- Reads the menu geometry declaration, with the shipped panel as the fallback so a
-- config that lost its MENU block still opens a large centred list rather than a
-- strip down the corner. The menu module clamps every value it is handed.
local function menuSettings()
	local declared = type(M.Settings.MENU) == 'table' and M.Settings.MENU or nil
	return declared or { ANCHOR = 'center', WIDTH = 708, HEIGHT = 708, MAX_HEIGHT_VH = 88, VISIBLE_ROWS = 15 }
end

-- The player's own ground position, or nil before there is a world to read.
local function playerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- The player's own facing in degrees, or nil. Read only when a capture is asked
-- for, because that is the only time it is used.
local function playerYaw()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.yaw) ~= 'function' then return nil end
	local read, yaw = pcall(character.yaw)
	if not read or type(yaw) ~= 'number' or yaw ~= yaw then return nil end
	return yaw
end

-- Whether another surface holds the keyboard: the chat box, a form, the pause
-- menu. Kept module-local rather than folded into `OPX.Lib.Input.IsCaptured`,
-- which answers captured when the read itself raises where this answers free.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

-- ── the markers ─────────────────────────────────────────────────────────────

-- Creates one marker, or answers why it could not be. Never raises.
local function createMarker(spot)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = Access.Marker(spot.kind)
	local read, id, reason = pcall(api.create, {
		-- The spot's declared height plus the look's own lift: a ring left at
		-- floor height is co-planar with the floor and draws nothing at all.
		position = { x = spot.x, y = spot.y, z = spot.z + look.lift },
		shape = look.shape,
		style = look.style,
		radius = look.radius,
		maxDistance = Access.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

-- Removes one marker without raising.
local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

-- Brings the drawn set in line with what is in range: a dealer within
-- MAX_DISTANCE has a marker, one beyond it does not.
--
-- THE POSITION IS THREADED THROUGH, NOT READ AGAIN. `scan()` -- the only caller
-- -- has just read it for `Access.Nearest`, and reading it a second time here
-- made this module cost TWO host position reads per pass at SCAN_MS. Across
-- `clothing`, `dealership` and `garages` that was twelve host reads a second for
-- six distinct answers. `modules/teleports/client/main.lua` already threads it
-- (`reconcile(at)`); these three were never updated with it.
-- @param x number|nil the player's position, or nil where it could not be read
-- @param y number|nil
local function reconcile(x, y)
	local limit = Access.MaxDistance()
	local reach = limit * limit

	for key, spot in pairs(spots) do
		local flat = nil
		if x ~= nil then flat = Access.FlatDistanceSquared(spot, x, y) end
		local wanted = flat ~= nil and flat <= reach
		if wanted and markers[key] == nil then
			local id, failure = createMarker(spot)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[dealership] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end

	-- A dealer the server no longer names loses its marker here rather than
	-- being left behind: it may have been removed while it was in range.
	for key, id in pairs(markers) do
		if spots[key] == nil then
			removeMarker(id)
			markers[key] = nil
		end
	end
end

-- Drops every marker this module drew.
local function clearMarkers()
	for key, id in pairs(markers) do
		removeMarker(id)
		markers[key] = nil
	end
end

-- ── the strip ───────────────────────────────────────────────────────────────

-- Names the key the row is bound to, or nil when it is off or was refused -- a
-- row with no key to name says nothing.
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

-- What the key is about to open, as a locale key: a car dealer and an AV pad are
-- the same gesture but two different lists, so the row has to name the one it is
-- standing over.
local function promptLabel()
	if nearest == nil then return nil end
	return 'dealership.prompt.' .. nearest.kind
end

-- Brings the strip in line with where the player is standing AND with which kind
-- of dealer that is: comparing only "is a row up" would keep a car dealer's
-- label over an adjacent AV pad, because both want a row.
local function syncPrompt()
	local want = nearest ~= nil and keyLabel() ~= nil and not captured() and handle == nil
	local label = want and promptLabel() or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the list, and this is
		-- said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[dealership] no prompts contract; the strip row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	shown, shownLabel = want, label
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line. A dealer that sells
			-- AVs says so, because what is behind the key is a different list.
			label = locale(label),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[dealership] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Refusals and purchases share the one id, so the last thing said
-- replaces the one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.dealership.answer',
		kind = kind,
		title = locale('dealership.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[dealership] ' .. tostring(message)) end
end

-- ── the list ────────────────────────────────────────────────────────────────

-- The row handler the menu calls back on. Declared here and assigned below,
-- because the menu contract wants the callback at open time and `draw` is the
-- one that hands it over.
local onRow

-- The menu contract, or nil.
local function menuApi()
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' or type(api.Close) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.info('[dealership] no menu contract: the list cannot be drawn, and ' ..
				'/opx.dealership.buy still sells a vehicle')
		end
		return nil
	end
	return api
end

-- The rows of one screen, and what it is titled. Nil when the screen cannot be
-- built at all, which is how a dealer with nothing to sell says so.
local function screenFor(current)
	if current.screen == 'root' then
		local dealer = nearest
		local rows = type(dealer) == 'table' and stock[dealer.kind] or nil
		if type(rows) ~= 'table' or #rows == 0 then return nil end

		local items = {}
		local lastClass = nil
		for index = 1, #rows do
			local row = rows[index]
			-- A separator per class, on the line where the class changes: the
			-- list is sorted by class, so one pass is enough.
			if row.class ~= lastClass and row.class ~= '' then
				lastClass = row.class
				items[#items + 1] = { separator = true, label = row.class }
			end
			items[#items + 1] = {
				id = row.key,
				label = row.label,
				value = row.text,
				-- A row that leads to the destination choice, not a row that
				-- buys: the arrow column has to say so.
				submenu = true,
				data = { entry = row.key },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'close', label = locale('dealership.close'), close = true }
		return locale('dealership.menu.title', { dealer = tostring(dealer.label) }), items
	end

	if current.screen == 'deliver' then
		local arg = type(current.arg) == 'table' and current.arg or {}
		local row = nil
		local rows = type(nearest) == 'table' and stock[nearest.kind] or nil
		for index = 1, type(rows) == 'table' and #rows or 0 do
			if rows[index].key == arg.entry then row = rows[index] end
		end
		if row == nil then return nil end

		local items = {}
		local places = type(arg.places) == 'table' and arg.places or {}
		for index = 1, #places do
			local place = places[index]
			items[#items + 1] = {
				id = place.key,
				label = place.label,
				value = locale('dealership.deliverHere'),
				data = { entry = row.key, dest = place.key },
			}
		end
		if #items == 0 then
			-- Nothing of this category the player may file it under. The row is
			-- still a real choice -- it buys and lets the server's own default
			-- garage take it -- and it says which one that is.
			items[1] = {
				id = 'default',
				label = locale('dealership.dest.none'),
				value = locale('dealership.deliverHere'),
				data = { entry = row.key, dest = '' },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'back', label = locale('dealership.back'), back = true }
		return locale('dealership.menu.deliver', { model = row.label }), items, {
			status = locale('dealership.menu.pay', { price = row.text }),
		}
	end

	return nil
end

-- Takes the menu down for a reason of this file's own.
local function takeDown()
	local closing = handle
	handle, stack = nil, {}
	local api = OPX.Api.Get('menu')
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, 'dealership')
	end
	syncPrompt()
	return closing ~= nil
end

-- Draws the screen on top of the stack, or updates the one already up.
-- `inPlace` is the navigation redraw: the destination screen is added under the
-- model the player picked, and reopening would throw them back to the top of the
-- list if the menu were reopened rather than updated.
local function draw(inPlace)
	local current = stack[#stack]
	if current == nil then return false end

	local title, items, extra = screenFor(current)
	if title == nil then
		-- The screen cannot be built: the dealer's stock went away under an open
		-- list. Said plainly rather than left as a menu of nothing.
		takeDown()
		say('error', locale('dealership.nothingForSale'))
		return false
	end
	extra = extra or {}

	local api = menuApi()
	if api == nil then
		takeDown()
		return false
	end

	if inPlace then
		if handle == nil then return false end
		local patched = api.Update(handle, { title = title, items = items, status = extra.status })
		if patched ~= nil and patched.ok then return true end
		-- The handle went stale under us: fall through and ask for the menu.
		handle = nil
	end

	-- THE SIZE IS OURS, NOT THE MENU MODULE'S. Everything else hangs off an edge; a
	-- dealership is a shop counter, so it opens centred and large, and the module
	-- takes what it is given rather than the other way round.
	local where = menuSettings()
	local opened = api.Open({
		owner = OWNER,
		id = SPEC_ID,
		title = title,
		on = onRow,
		cursor = current.cursor,
		anchor = where.ANCHOR,
		width = where.WIDTH,
		-- The height and the width are asked for together: a square panel, whatever
		-- the level holds. Without it a three-row screen draws a bar.
		height = where.HEIGHT,
		maxHeight = where.MAX_HEIGHT_VH,
		rows = where.VISIBLE_ROWS,
		items = items,
		status = extra.status,
	})
	if opened == nil or opened.ok ~= true then
		local failure = type(opened) == 'table' and tostring(opened.error or 'refused') or 'refused'
		if not reportedMenu then
			reportedMenu = true
			Open77.log.warn(('[dealership] the list did not open: %s'):format(failure))
		end
		takeDown()
		return false
	end
	handle = opened.value.handle
	return true
end

-- Navigates to a screen under the current one.
local function push(screen, arg)
	stack[#stack + 1] = { screen = screen, arg = arg }
	if draw() then return true end
	stack[#stack] = nil
	return false
end

-- Steps back one screen, closing the list at the top of the stack.
local function pop()
	if #stack <= 1 then return takeDown() end
	stack[#stack] = nil
	return draw()
end

-- The garages a bought vehicle of this kind may be filed under, by key.
-- Read from the garages contract every time a destination screen is opened: it
-- is that module's answer, and a copy would be a copy to keep in step.
local function placesFor(kind)
	local api = OPX.Api.Get('garages')
	if api == nil or type(api.Spots) ~= 'function' then return {} end
	local read, answer = pcall(api.Spots)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return {} end
	local listed = type(answer.value) == 'table' and answer.value.spots or nil
	if type(listed) ~= 'table' then return {} end

	local places = {}
	for key, spot in pairs(listed) do
		if type(spot) == 'table' and spot.kind == kind then
			places[#places + 1] = { key = key, label = tostring(spot.label or key) }
		end
	end
	table.sort(places, function(left, right) return left.key < right.key end)
	return places
end

-- Sends the purchase this file has already decided to offer.
local function buy(entryKey, destKey)
	local dealer = nearest
	if dealer == nil then
		local verdict = { ok = false, error = 'dealership.noSuchSpot', source = 'client' }
		publish(verdict)
		say('error', locale(verdict.error))
		return verdict
	end
	if type(entryKey) ~= 'string' or entryKey == '' then
		local verdict = { ok = false, error = 'error.badRequest', source = 'client' }
		publish(verdict)
		return verdict
	end

	-- Taken down BEFORE the request, so the key opens rather than closes and a
	-- refusal toast is not raised underneath an open menu.
	takeDown()
	local sent, reason = TriggerServerEvent(M.Event.BUY, dealer.key, entryKey, destKey)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		say('error', locale('dealership.refused'))
		return verdict
	end

	local verdict = { ok = true, queued = true, dealer = dealer.key, entry = entryKey,
		garage = type(destKey) == 'string' and destKey ~= '' and destKey or nil,
		source = 'key' }
	publish(verdict)
	return verdict
end

-- Navigates, buys or finishes for a row the menu raised. The shape is checked
-- because the menu also raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end

	if payload.action == 'close' then
		-- A close for a screen this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		-- Back on a one-level screen would close it; step up instead.
		if payload.reason == 'back' and #stack > 1 then return pop() end
		stack = {}
		return syncPrompt()
	end
	if payload.action ~= 'select' or captured() then return end

	local data = payload.data
	local current = stack[#stack]
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId

	if current.screen == 'root' then
		if type(data.entry) ~= 'string' then return end
		local places = placesFor(type(nearest) == 'table' and nearest.kind or '')
		return push('deliver', { entry = data.entry, places = places })
	end

	if current.screen == 'deliver' then
		-- The destination row is the confirmation: it names the place the
		-- vehicle is filed under, and the price has been on the status line for
		-- as long as the screen has been up.
		return buy(data.entry, type(data.dest) == 'string' and data.dest or nil)
	end
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- Opens the list for the dealer the player is standing on, or closes it.
-- @author XEROX710
-- @param origin string|nil the key or a caller's name
-- @return table
function Runtime.Open(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end

	-- The same key closes what it opened. Asked of this file's own handle rather
	-- than of the menu's state, because the menu is shared: another module's menu
	-- is not this one's to close.
	if handle ~= nil then
		takeDown()
		result.ok, result.closed = true, true
		publish(result)
		return result
	end

	if nearest == nil then
		result.ok, result.error = false, 'dealership.noSuchSpot'
		publish(result)
		return result
	end
	if type(stock[nearest.kind]) ~= 'table' or #stock[nearest.kind] == 0 then
		result.ok, result.error = false, 'dealership.nothingForSale'
		publish(result)
		say('error', locale(result.error))
		return result
	end

	stack = { { screen = 'root' } }
	if not draw() then
		result.ok, result.error = false, 'dealership.noList'
		publish(result)
		return result
	end
	syncPrompt()
	result.ok, result.dealer = true, nearest.key
	publish(result)
	return result
end

--- Closes the list this file opened.
-- @author XEROX710
-- @return table
function Runtime.Close()
	if not takeDown() then return { ok = false, error = 'not_open' } end
	return { ok = true }
end

--- Whether this file's own list is up.
-- @author XEROX710
-- @return boolean
function Runtime.IsOpen()
	return handle ~= nil
end

--- The dealer the player is standing on, or nil.
-- @author XEROX710
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every dealer this client was told about, by key.
-- @author XEROX710
-- @return table
function Runtime.Spots()
	return spots
end

--- What this client knows, for a diagnostic or a test.
-- @author XEROX710
-- @return table
function Runtime.Report()
	local count = OPX.Table.Count(spots)
	local drawn = OPX.Table.Count(markers)
	local current = stack[#stack]
	return {
		spots = count,
		markers = drawn,
		nearest = nearest and nearest.key or nil,
		shown = shown,
		-- Which kind the row is naming, so a diagnostic can tell a row that never
		-- went up from one that went up naming the other kind.
		label = shownLabel,
		key = keyLabel(),
		open = handle ~= nil,
		screen = current and current.screen or nil,
		listed = nearest ~= nil and type(stock[nearest.kind]) == 'table'
			and #stock[nearest.kind] or 0,
	}
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- One pass: where the player is, which dealer they are on, and what is drawn.
local function scan()
	local x, y = playerXY()
	if x == nil then
		nearest = nil
		syncPrompt()
		return
	end
	nearest = Access.Nearest(spots, x, y)
	syncPrompt()
	reconcile(x, y)
end

-- ── the capture round-trip ──────────────────────────────────────────────────

-- A command on the server cannot know a facing, so it asks this client for one:
-- the answer carries the position's heading and nothing else this half decides.
local function answerCapture(kind, key, label)
	local yaw = playerYaw()
	local accepted, reason = TriggerServerEvent(M.Event.CAPTURED, kind, key, label, yaw)
	if not accepted then
		Open77.log.warn(('[dealership] capture of %s was not sent: %s'):format(tostring(key),
			tostring(reason)))
		return
	end
	-- Said out loud because the other end of this round trip is invisible from
	-- here: the server's own line says the request went out, and this one says it
	-- came back with a facing.
	Open77.log.info(('[dealership] answered the capture of %s as %s yaw=%s'):format(
		tostring(key), tostring(kind), tostring(yaw)))
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author XEROX710
function Runtime.Init()
	spots, markers = {}, {}
	stock = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
	nearest, shown, shownLabel, keyRegistered = nil, false, nil, false
	handle, stack = nil, {}
	reportedMarkers, reportedStrip, reportedMenu = false, false, false
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the four server events.
-- @author XEROX710
function Runtime.Start()
	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Open, 'key')
				if not ran then
					Open77.log.error(('[dealership] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Reading only the second logged a working mapping as
		-- refused.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[dealership] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT),
					tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	-- The strip redraws a rebound key itself; this only re-reads whether the row
	-- should be up at all.
	AddEventHandler(M.KEYBINDS_CHANGED, function()
		if shown and keyLabel() == nil then shown = false end
		syncPrompt()
	end)

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.spots or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local spot, why = Access.FromWire(listed[index])
			if spot == nil then
				Open77.log.warn('[dealership] a dealer was refused: ' .. tostring(why))
			else
				accepted[spot.key] = spot
			end
		end
		spots = accepted

		-- A dealer the player is standing on that has gone takes an open list
		-- down with it: the list is that dealer's, and it is not there any more.
		if nearest ~= nil and spots[nearest.key] == nil and handle ~= nil then
			takeDown()
		end
		-- A full pass, not just the markers: a list that arrives while the
		-- player is standing on a dealer must put its row up now rather than
		-- wait for the next scan.
		scan()
	end)

	RegisterNetEvent(M.Event.STOCK, function(payload)
		local kinds = type(payload) == 'table' and payload.kinds or nil
		if type(kinds) ~= 'table' then return end
		local accepted = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
		for kind in pairs(accepted) do
			local listed = kinds[kind]
			for index = 1, type(listed) == 'table' and #listed or 0 do
				local row, why = Access.FromWireRow(listed[index])
				if row == nil then
					Open77.log.warn('[dealership] a stock row was refused: ' .. tostring(why))
				else
					accepted[kind][#accepted[kind] + 1] = row
				end
			end
		end
		stock = accepted

		-- An open list is redrawn against the new stock: a row that is sold out
		-- or repriced must not stay on screen as it was.
		if handle ~= nil then draw(true) end
	end)

	RegisterNetEvent(M.Event.ANSWER, function(ok, failure, entry, value)
		local verdict = {
			ok = ok == true,
			error = ok ~= true and tostring(failure or 'dealership.refused') or nil,
			entry = type(entry) == 'string' and entry or nil,
			source = 'server',
		}
		if ok == true and type(value) == 'table' then
			verdict.plate = value.plate
			verdict.model = value.model
			verdict.dealer = value.dealer
			verdict.garage = value.garage
			verdict.price = value.price
		end
		publish(verdict)
		if not verdict.ok then
			say('error', locale(verdict.error))
		end
	end)

	RegisterNetEvent(M.Event.CAPTURE, function(kind, key, label)
		answerCapture(kind, key, label)
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[dealership] the dealer list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('dealership:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[dealership] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('dealership:scan', Access.SCAN_MS, scan)
	-- One pass now, so a dealer already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, closes the list, takes the markers down and hands the
--- strip back.
-- @author XEROX710
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	takeDown()
	clearMarkers()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
