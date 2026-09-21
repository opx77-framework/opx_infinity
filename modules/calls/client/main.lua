--- The client half: the state the server pushed, the rows on the eye, the ring.
-- @author dop42
--
-- This file owns a state machine and DRAWS NOTHING. It says everything it has
-- to say on the local `calls:view` event and takes everything back through
-- `M.FromView`; `client/view.lua` is the only file that knows those two ends
-- are a CEF page. That is the seam `modules/downed` uses and it is here for the
-- same reason -- the state half stays testable without a browser.
--
-- NOTHING IN THIS FILE IS A FACT. The server pushes one payload describing this
-- player's whole call world and everything below is a projection of it. A row
-- on the eye does not end a call, it asks the server to; `dismissed` is the one
-- piece of genuinely local state in the module, and it is local precisely
-- because it is about this screen rather than about the call.
--
-- ── the rows, and the budget ─────────────────────────────────────────────────
--
-- Seven rows across two kinds. `RegisterMany` is ALL OR NOTHING -- one
-- malformed row refuses the whole batch and the refusal is written to a log on
-- the player's own machine -- which is the trap `modules/animations/client/walk.lua`
-- fell into and documented, so the registration is one `Register*` call per
-- kind with a `Wait(0)` between, on a thread of its own, and the answer of each
-- is checked and relayed with `OPX.Note` rather than `Open77.log`.
--
-- THE ROWS ARE REGISTERED ONCE AND NEVER RE-REGISTERED. `canInteract` is what
-- makes a row appear and disappear: answer is called in-process on every pick,
-- costs a table lookup, and reads the same state the screen does. The first
-- sketch re-registered the set on every state push -- a `Clear` plus two
-- `Register*` calls per incoming call -- which is the admin module's whole
-- instruction-budget story being re-enacted on a hot path.
--
-- ── the sound ────────────────────────────────────────────────────────────────
--
-- `Open77.sfx.play2d(event)` plays one of Cyberpunk's own `ui_phone_01` Wwise
-- events, by name, with nothing shipped and nothing copied -- see the SOUND
-- block in `config/calls.lua`. It is gated on `world.effects`, which this
-- manifest already declares for the vfx the staff noclip pops, and its refusal
-- is SILENT in the same way: the native answers `nil, permission_denied` or
-- `nil, invalid_sfx_event` and logs nothing. So every call goes through `ring`
-- below, which notes the FIRST refusal of each event name to the server and
-- then stops asking about it.

local M = OPX.Modules.Get('calls')

local Model = M.Model

-- What this module calls itself on the eye, and the folder its rows sit in.
local OWNER = 'calls'

-- Metres a call row reaches. The eye's own default is 3.0; a holocall is
-- placed by looking at somebody across a room, so this is longer and still
-- well inside the registry's 50 m ceiling.
local ROW_DISTANCE = 12.0

-- The last state the server pushed. Never written from this side.
local state = { call = nil, invite = nil, outgoing = nil }

-- Whether the player waved the incoming card away. LOCAL, and the only local
-- state in this module: it is a fact about this screen and not about the call,
-- so the server neither knows nor should. Cleared whenever the invite it was
-- about goes away, so the next call rings on a clean screen.
local dismissed = nil

-- When the ring was last re-armed, and how often it may be.
local lastRingMs = -math.huge
local ringEveryMs = 3500

-- When the card went up, and how long it may stay. THE OWNER'S REQUIREMENT AS A
-- CLOCK: the card says its piece and takes itself off the screen, and the eye's
-- re-pop row brings it back. The call goes on ringing throughout -- this is the
-- card leaving, not the call being refused.
--
-- THE CLOCK IS THE CLIENT'S AND THE SERVER IS NEVER TOLD. Where a card is on
-- somebody's screen is a fact about that screen, so a dismissal that crossed
-- the wire would be this module asking the authority to remember something the
-- authority has no business knowing -- and would then have to be un-remembered
-- on every reconnect, every reload and every character change.
local cardUpMs = nil
local cardDwellMs = 8000

-- Sound event names, settled in `Start` from the config.
local sounds = {}

-- Event names whose refusal has already been reported. One note per name per
-- session: a missing sound is worth saying once and is worth nothing at all
-- forty times.
local mutedEvents = {}

-- The scheduler handles this module holds, so `Stop` can give them back.
local jobs = {}

-- The view seam, and the one channel every payload travels on.
local EVENT_VIEW = M.Event.VIEW

local function locale(key, params)
	return OPX.Locale.Text(key, params)
end

--- Plays one of the game's own frontend events, at most once per name per
--- refusal.
---
--- A REFUSAL IS A MISSING SOUND AND NEVER A FAILED CALL. The platform refuses
--- an event outside its curated table rather than forwarding it, and every name
--- in the config is carried by the devkit's catalogue as read-from-the-bank but
--- not yet played on this build. So a name that does not take costs the player
--- a ringtone and costs the call nothing.
-- @param event string|nil
local function play(event)
	if type(event) ~= 'string' or event == '' or mutedEvents[event] then return end
	local sfx = Open77.sfx
	if type(sfx) ~= 'table' or type(sfx.play2d) ~= 'function' then return end
	local ok, reason = pcall(sfx.play2d, event)
	-- `pcall` answers (true, nil, reason) when the native refused, so the raise
	-- and the refusal are two different shapes and both are caught here.
	if ok and reason ~= nil then return end
	mutedEvents[event] = true
	-- `OPX.Note` AND NOT `Open77.log.warn`: a client log line is written on the
	-- PLAYER's machine, and a ringtone that never played would otherwise be a
	-- complaint with no evidence anywhere the operator can reach.
	OPX.Note('calls', ('the sound %q did not play: %s'):format(event, tostring(reason)))
end

-- Publishes one payload to whatever is drawing this module.
local function publish(payload)
	TriggerEvent(EVENT_VIEW, payload)
end

-- Whether the incoming card should be on screen: there is an invite, and the
-- player has not waved this one away.
local function carded()
	return state.invite ~= nil and dismissed ~= state.invite.id
end

-- Pushes the whole of what the screen draws. ONE payload rather than a diff:
-- the object is three optional tables and the page redraws from it whole, so a
-- diff would be more code than the thing it describes.
local function draw()
	publish({
		kind = 'state',
		call = state.call,
		invite = carded() and state.invite or nil,
		-- The card being dismissed is drawn too, because that is exactly when
		-- the re-pop row has to be offered and the live chip has to say there
		-- is something waiting.
		invitePending = state.invite ~= nil,
		outgoing = state.outgoing,
		dismissed = state.invite ~= nil and dismissed == state.invite.id,
	})
end

-- Takes a fresh state from the server and works out what changed, which is the
-- only thing the sounds and the dismissal are keyed off.
local function onState(payload)
	if type(payload) ~= 'table' then return end

	local hadInvite = state.invite ~= nil and state.invite.id or nil
	local hadCall = state.call ~= nil and state.call.id or nil
	local hadOutgoing = state.outgoing ~= nil and state.outgoing.id or nil

	state = {
		call = type(payload.call) == 'table' and payload.call or nil,
		invite = type(payload.invite) == 'table' and payload.invite or nil,
		outgoing = type(payload.outgoing) == 'table' and payload.outgoing or nil,
	}

	local nowInvite = state.invite ~= nil and state.invite.id or nil
	local nowCall = state.call ~= nil and state.call.id or nil

	-- A NEW INVITE CLEARS THE DISMISSAL. Without this, waving one call away
	-- would silence the next one too: `dismissed` holds an id, so the first
	-- card the player never sees is the one that happens to reuse it. Holding
	-- the id rather than a boolean is what makes this a one-line rule.
	if nowInvite ~= hadInvite then
		dismissed = nil
		lastRingMs = -math.huge
		cardUpMs = nowInvite ~= nil and OPX.Now() or nil
	end

	-- The ring starts on a card arriving and stops on it going, whichever way
	-- it went -- answered, refused, expired or the caller hanging up. The stop
	-- event exists because `ui_phone_incoming_call` is a one-shot with no
	-- handle: there is nothing to stop, so the bank carries a separate event
	-- that plays the line closing.
	if nowInvite ~= nil and nowInvite ~= hadInvite then
		play(sounds.INCOMING)
		lastRingMs = OPX.Now()
	elseif hadInvite ~= nil and nowInvite == nil then
		play(sounds.INCOMING_STOP)
	end

	if hadOutgoing == nil and state.outgoing ~= nil then
		play(sounds.OUTGOING)
	elseif hadOutgoing ~= nil and state.outgoing == nil and nowCall == nil then
		play(sounds.OUTGOING_STOP)
	end

	if nowCall ~= nil and nowCall ~= hadCall then
		play(sounds.ACCEPTED)
	elseif hadCall ~= nil and nowCall == nil then
		play(sounds.HANG_UP)
	end

	draw()
end

-- Re-arms the ring while a card is up, and takes the card down once it has had
-- its say.
--
-- THE RING OUTLIVES THE CARD, deliberately. `ui_phone_incoming_call` is a
-- one-shot, so "it rings until you answer" is a clock rather than a loop -- and
-- it keeps ticking after the card has gone, because the card leaving is about
-- the SCREEN and the call is still ringing. A player who looked away still
-- hears it, and ALT still answers it.
local function rearm()
	if state.invite == nil then return end
	local atMs = OPX.Now()

	if atMs - lastRingMs >= ringEveryMs then
		lastRingMs = atMs
		play(sounds.INCOMING)
	end

	if cardUpMs ~= nil and dismissed ~= state.invite.id
		and atMs - cardUpMs >= cardDwellMs then
		dismissed = state.invite.id
		draw()
	end
end

-- ── what the page asks for ───────────────────────────────────────────────────

--- The other end of the seam. Every action the page may take, and an unknown
--- one is ignored here so `view.lua` need not filter a second time.
-- @author dop42
-- @param action string
-- @param payload table|nil
function M.FromView(action, payload)
	if action == 'ready' then
		-- The page mounted, or this module started. Ask the server for the
		-- state again -- which is also, exactly, the re-pop button.
		TriggerServerEvent(M.Event.READY)
		draw()
		return
	end
	if action == 'dismiss' then
		-- WAVED AWAY, NOT DECLINED, and the difference is the owner's whole
		-- point about not ruining the player's vision: the card goes, the call
		-- keeps ringing, and the eye still offers the answer. Declining is a
		-- separate row that tells the server.
		if state.invite ~= nil then dismissed = state.invite.id end
		draw()
		return
	end
	if action == 'repop' then
		dismissed = nil
		-- THE DWELL CLOCK RESTARTS, which is what makes the re-pop row worth
		-- pressing twice. Without this the card would come back and be taken
		-- down again on the next sweep, because `cardUpMs` would still be the
		-- moment the call first arrived -- a button that appears to do nothing,
		-- which is the worst kind.
		cardUpMs = OPX.Now()
		TriggerServerEvent(M.Event.READY)
		draw()
		return
	end
	if action == 'accept' then return M.Accept() end
	if action == 'decline' then return M.Decline() end
	if action == 'hangUp' then return M.HangUp() end
	if action == 'diag' then
		OPX.Note('calls', ('view: %s'):format(tostring(type(payload) == 'table'
			and payload.detail or payload)))
		return
	end
end

-- ── the verbs, as the rows and the page call them ────────────────────────────

--- Answers the call waiting for this player. Answers false when there is none,
--- which is what a row's `canInteract` already prevents and what a page cannot
--- be trusted to.
-- @author dop42
-- @return boolean whether anything was asked for
function M.Accept()
	if state.invite == nil then return false end
	TriggerServerEvent(M.Event.ACCEPT, state.invite.id)
	return true
end

--- Refuses the call waiting for this player.
-- @author dop42
-- @return boolean
function M.Decline()
	if state.invite == nil then return false end
	play(sounds.DECLINED)
	TriggerServerEvent(M.Event.DECLINE, state.invite.id)
	return true
end

--- Leaves the call this player is on.
-- @author dop42
-- @return boolean
function M.HangUp()
	if state.call == nil then return false end
	TriggerServerEvent(M.Event.HANG_UP)
	return true
end

--- Asks to call, to add, or to share a contact with one player.
---
--- ONE VERB FOR ALL THREE, because the server derives which of them this is
--- from whether the caller is already on a call -- see `registry.Invite`. The
--- client names `contact` or nothing, and naming anything else is a request the
--- server refuses as `badRequest` rather than a shape this file has to know.
-- @author dop42
-- @param playerId integer
-- @param kind string|nil 'contact', or nil for a call
-- @return boolean
function M.Invite(playerId, kind)
	local target = Model.PlayerId(playerId)
	if target == nil then return false end
	TriggerServerEvent(M.Event.INVITE, target, kind == 'contact' and 'contact' or nil)
	return true
end

--- Whether this player is on a call, and what it looks like. For the HUD, for
--- another module, and for a test.
-- @author dop42
-- @return table|nil
function M.State()
	return {
		call = state.call,
		invite = state.invite,
		outgoing = state.outgoing,
		carded = carded(),
	}
end

-- ── the menu: the other way to reach somebody who is not in front of you ─────
--
-- THE OWNER ASKED FOR THE THIRD PARTICIPANT "par le menu ou par le ALT", and
-- the two paths are not alternatives so much as complements. ALT needs a body
-- under the crosshair, which is exactly the person a holocall was invented to
-- avoid having to walk to; the menu is how you reach the rest.
--
-- IT LISTS THE CALLER'S CONTACTS AND NOBODY ELSE, which is what makes the
-- sharing worth having: the people you can ring from a menu are the people who
-- agreed to be reachable that way. The server builds the list, works out each
-- row's reachability with the SAME function that judges an invite, and sends
-- neither a position nor a row for a contact who is not connected.
--
-- THE MENU IS OPTIONAL AND THE LIST IS NOT CACHED. Without the menu module the
-- calls still work on the eye, and the list is asked for when the screen opens
-- rather than held: a contact list a minute old is a list of rows that refuse.

-- The open menu's handle, or nil.
local menuHandle = nil

-- Turns one roster row into a menu row, greyed with its reason when it has one.
local function rosterRow(row)
	local reason = row.refusal
	return {
		id = 'contact_' .. tostring(row.id),
		label = tostring(row.name or '?'),
		icon = 'person',
		-- THE REASON IS SHOWN, not merely obeyed. A row that is simply dark
		-- tells a player their contact is unreachable and nothing else, and the
		-- two commonest reasons -- already on a call, line busy -- are both
		-- things that stop being true in a minute.
		description = reason ~= nil and locale('calls.error.' .. reason) or nil,
		value = reason ~= nil and locale('calls.menu.unavailable') or nil,
		disabled = reason ~= nil,
		data = { kind = 'invite', id = row.id },
	}
end

-- Draws or redraws the contacts screen from a roster the server sent.
local function drawMenu(payload)
	local menu = OPX.Api.Get('menu')
	if menu == nil then return end

	local items = {}
	local rows = type(payload.rows) == 'table' and payload.rows or {}
	if #rows == 0 then
		-- A SEPARATOR AND NOT A DISABLED ROW. An empty list still has to say
		-- something, and a row that looks pressable and is not is worse than a
		-- line of text that never looked like one.
		items[#items + 1] = { separator = true, label = locale('calls.menu.empty') }
	else
		items[#items + 1] = { separator = true,
			label = payload.onCall == true and locale('calls.menu.add')
				or locale('calls.menu.call') }
		for index = 1, #rows do
			local row = rows[index]
			if type(row) == 'table' and Model.PlayerId(row.id) ~= nil then
				items[#items + 1] = rosterRow(row)
			end
		end
	end

	if state.call ~= nil then
		items[#items + 1] = { separator = true, label = locale('calls.live.title') }
		items[#items + 1] = {
			id = 'hangUp',
			label = locale('calls.row.hangUp'),
			icon = 'ban',
			danger = true,
			data = { kind = 'hangUp' },
		}
	end

	local spec = {
		owner = OWNER,
		id = 'calls',
		title = locale('calls.menu.title'),
		items = items,
		on = function(payload2)
			if type(payload2) ~= 'table' or payload2.action ~= 'select' then return end
			local data = type(payload2.data) == 'table' and payload2.data or nil
			if data == nil then return end
			if data.kind == 'hangUp' then return M.HangUp() end
			if data.kind == 'invite' then return M.Invite(data.id, nil) end
		end,
	}

	if menuHandle ~= nil then
		-- `Update` and not a fresh `Open`: it re-walks the navigation stack by
		-- row id, so a refresh does not throw the cursor back to the top of a
		-- list somebody is halfway down.
		local updated = menu.Update(menuHandle, spec)
		if updated.ok then return end
		menuHandle = nil
	end

	local opened = menu.Open(spec)
	if not opened.ok then
		OPX.Note('calls', 'the contacts screen was refused: ' .. tostring(opened.error))
		return
	end
	menuHandle = opened.value.handle
end

--- Opens the contacts screen, which is the menu path to placing a call and to
--- adding a third.
-- @author dop42
-- @return boolean whether anything was asked for
function M.OpenMenu()
	if OPX.Api.Get('menu') == nil then return false end
	TriggerServerEvent(M.Event.ASK_ROSTER)
	return true
end

-- ── the rows on the eye ──────────────────────────────────────────────────────

-- The id the eye's context names for the body under the crosshair, as a number.
-- `modules/admin/client/target.lua` reads the same field and turns it into a
-- command argument; here it is passed straight back to the server, so it is
-- bounded through the model rather than formatted.
local function targetOf(context)
	local target = type(context) == 'table' and context.target or nil
	if type(target) ~= 'table' then return nil end
	return Model.PlayerId(target.playerId)
end

--- The rows drawn on somebody ELSE's body: call them, add them, give them your
--- contact.
---
--- `canInteract` is what makes each appear at the right moment, and each of
--- them is the cheap half of a rule the server owns. "Not while they are
--- already on your call" is checked here so the row is simply absent; it is
--- checked AGAIN on the server, because a row that is absent is not a rule.
-- @author dop42
-- @return table[]
function M.PlayerRows()
	local group = locale('calls.group')
	local function onCall()
		return state.call ~= nil
	end
	local function alreadyOn(context)
		local id = targetOf(context)
		if id == nil or state.call == nil then return false end
		for _, row in ipairs(state.call.participants or {}) do
			if row.id == id then return true end
		end
		return false
	end

	return {
		{
			id = 'callPlace',
			label = locale('calls.row.call'),
			icon = 'talk',
			group = group,
			-- Below the staff band, which starts at 100, and above nothing in
			-- particular: these are rows everybody has.
			order = 20,
			distance = ROW_DISTANCE,
			canInteract = function(context)
				return targetOf(context) ~= nil and not onCall()
			end,
			onSelect = function(context)
				return M.Invite(targetOf(context), nil)
			end,
		},
		{
			id = 'callAdd',
			label = locale('calls.row.add'),
			icon = 'plus',
			group = group,
			order = 21,
			distance = ROW_DISTANCE,
			canInteract = function(context)
				return targetOf(context) ~= nil and onCall() and not alreadyOn(context)
			end,
			onSelect = function(context)
				return M.Invite(targetOf(context), nil)
			end,
		},
		{
			id = 'callShare',
			label = locale('calls.row.share'),
			icon = 'tag',
			group = group,
			order = 22,
			-- SHORTER THAN THE OTHER TWO, and it matches the server's
			-- CONTACT_RANGE rather than merely being small: a row offered at
			-- twelve metres for an action refused past six is a row that
			-- refuses most of the times it is pressed.
			distance = 6.0,
			canInteract = function(context)
				return targetOf(context) ~= nil
			end,
			onSelect = function(context)
				return M.Invite(targetOf(context), 'contact')
			end,
		},
	}
end

--- The rows drawn on the player's OWN body: answer, refuse, hang up, and bring
--- the card back.
---
--- THIS IS WHERE THE OWNER'S "ACCEPT AND DECLINE ON ALT" LIVES. There is no
--- keybinding for either and there is deliberately none: ALT on yourself
--- already lists what you can do to yourself, it costs no key, and it cannot
--- collide with anything else on the keyboard. `modules/animations/client/walk.lua`
--- makes the same argument for the walking paces.
-- @author dop42
-- @return table[]
function M.SelfRows()
	local group = locale('calls.group')
	return {
		{
			id = 'callAccept',
			label = locale('calls.row.accept'),
			icon = 'talk',
			group = group,
			order = 10,
			canInteract = function() return state.invite ~= nil end,
			onSelect = function() return M.Accept() end,
		},
		{
			id = 'callDecline',
			label = locale('calls.row.decline'),
			icon = 'ban',
			group = group,
			order = 11,
			danger = true,
			canInteract = function() return state.invite ~= nil end,
			onSelect = function() return M.Decline() end,
		},
		{
			id = 'callHangUp',
			label = locale('calls.row.hangUp'),
			icon = 'ban',
			group = group,
			order = 12,
			danger = true,
			canInteract = function() return state.call ~= nil end,
			onSelect = function() return M.HangUp() end,
		},
		{
			id = 'callMenu',
			label = locale('calls.row.menu'),
			icon = 'list',
			group = group,
			order = 14,
			-- THE MENU PATH, offered whether or not a call is up: with none it
			-- places one, with one it adds a third. Both are the same verb and
			-- the server derives which -- see `registry.Consider`.
			canInteract = function() return OPX.Api.Get('menu') ~= nil end,
			onSelect = function() return M.OpenMenu() end,
		},
		{
			id = 'callRepop',
			label = locale('calls.row.repop'),
			icon = 'eye',
			group = group,
			order = 15,
			-- THE RE-POP BUTTON THE OWNER ASKED FOR, and it is offered only
			-- when there is something to re-pop: a card that was waved away, or
			-- a live call whose chip somebody lost. Offered unconditionally it
			-- would be a row that does nothing, most of the time, on everybody's
			-- own body.
			canInteract = function()
				return (state.invite ~= nil and dismissed == state.invite.id) or state.call ~= nil
			end,
			onSelect = function()
				M.FromView('repop')
				return true
			end,
		},
	}
end

-- Puts both sets on the eye, one resume per kind.
--
-- ONE `Wait(0)` BETWEEN THE TWO KINDS, and `modules/admin/client/target.lua`'s
-- `register` carries the full story of what it is for: the host bounds a task
-- by a per-frame instruction budget and stops it dead when it is passed, with
-- no error, no log and no refusal -- so a registration that builds and submits
-- every row in one resume loses whichever kinds were after the cut. That module
-- lost its `sky` rows for days. Seven rows is a long way inside the budget and
-- the yield costs one frame on a path that runs once, which is the wrong
-- trade-off to get clever about.
local function register(contract)
	local sets = {
		{ call = 'RegisterSelf', rows = M.SelfRows() },
		{ call = 'RegisterPlayers', rows = M.PlayerRows() },
	}
	for index = 1, #sets do
		Wait(0)
		local set = sets[index]
		local answer = contract[set.call](OWNER, set.rows)
		if answer == nil or answer.ok ~= true then
			-- `OPX.Note` and not `Open77.log.warn`: `RegisterMany` is
			-- all-or-nothing, so this line is the difference between "the
			-- feature is missing" and "row `callShare` has a bad icon", and on
			-- a client the warning would be written to a file on the player's
			-- own machine.
			OPX.Note('calls', ('the %s rows were refused: %s')
				:format(set.call, tostring(answer and answer.error)))
			return false
		end
	end
	return true
end

--- Builds the state.
-- @author dop42
function M.Init()
	state = { call = nil, invite = nil, outgoing = nil }
	dismissed = nil
	cardUpMs = nil
	lastRingMs = -math.huge
	mutedEvents = {}
	menuHandle = nil
	jobs = {}

	local settings = M.Settings
	sounds = type(settings.SOUND) == 'table' and settings.SOUND or {}
	ringEveryMs = math.floor(OPX.Math.Clamp(
		OPX.Math.Finite(settings.RING_EVERY_MS) or 3500, 1000, 60000))
	-- Bounded to something a player can read and something short of the whole
	-- invite lifetime: a dwell longer than INVITE_TTL_S would mean the card
	-- never left on its own and the configuration said it did.
	cardDwellMs = math.floor(OPX.Math.Clamp(
		OPX.Math.Finite(settings.CARD_DWELL_S) or 8, 2, 60) * 1000)
end

--- Wires the state push, the rows and the ring.
-- @author dop42
function M.Start()
	-- The seam, FIRST: `client/view.lua` registers the handler for the local
	-- view event, and the very first payload this module publishes is the one
	-- `FromView('ready')` draws straight back at the end of this function.
	if type(M.View) == 'table' and type(M.View.Start) == 'function' then M.View.Start() end

	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' then return end
		drawMenu(payload)
	end)

	-- The ring is a scheduler job rather than a thread of its own: it has one
	-- comparison to make and a module that wants a tick has to justify it.
	jobs[#jobs + 1] = OPX.Scheduler.Every('calls:ring', 500, rearm)

	-- `target` is optional to this module, so its absence is a runtime without
	-- an eye rather than a fault: the calls still work over the contract and
	-- the page, and nobody can reach them by looking at somebody.
	local contract = OPX.Api.Get('target')
	if contract == nil or type(contract.RegisterSelf) ~= 'function' then
		Open77.log.info('[calls] this client has no target eye: no call rows are offered')
	else
		-- ON A THREAD, and the `Wait(0)` in `register` is the only reason it
		-- needs one. Whether a `Start` may yield is the lifecycle's business
		-- rather than this module's -- `runPhase` already yields between
		-- modules under a `pcall` for exactly that doubt -- so the yield is put
		-- somewhere it is certainly allowed.
		CreateThread(function()
			local ok, failure = pcall(register, contract)
			if not ok then OPX.Note('calls', 'call rows: ' .. tostring(failure)) end
		end)
	end

	-- Ask for the state once we are up. A player who reloads into a live call
	-- has to get their chip back, and the server has no way of knowing this VM
	-- restarted.
	TriggerServerEvent(M.Event.READY)
end

--- Stops the ring and takes the rows back down.
-- @author dop42
function M.Stop()
	for index = 1, #jobs do
		if type(OPX.Scheduler.Cancel) == 'function' then OPX.Scheduler.Cancel(jobs[index]) end
	end
	jobs = {}
	local contract = OPX.Api.Get('target')
	if contract ~= nil and type(contract.Clear) == 'function' then
		pcall(contract.Clear, OWNER)
	end
	-- The contacts screen goes with the module. A menu left standing over a
	-- stopped owner is a list of rows whose `on` callback belongs to a VM that
	-- is no longer answering.
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'calls')
	end
	menuHandle = nil
	publish({ kind = 'state' })
end
