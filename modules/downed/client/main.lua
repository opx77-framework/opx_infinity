--- Client half: what the server said, the input a downed player loses, the stock
--- HUD, and the seam a view attaches to.
-- @author dop42

local M = OPX.Modules.Get('downed')

local Result = OPX.Result

-- Server to client: the state, and why a request was refused.
local EVENT_STATE = OPX.Event(OPX.Channel.NET, 'downed', 'state')
local EVENT_REFUSED = OPX.Event(OPX.Channel.NET, 'downed', 'refused')

-- Client to server.
local EVENT_READY = OPX.Event(OPX.Channel.NET, 'downed', 'ready')
local EVENT_WAIT = OPX.Event(OPX.Channel.NET, 'downed', 'wait')
local EVENT_GIVE_UP = OPX.Event(OPX.Channel.NET, 'downed', 'giveup')

-- The client local bus. `changed` is what every surface hides on; `view` is the
-- seam below; `key` carries a key heard while the keyboard is held. They must
-- stay on the LOCAL channel: the host dispatcher matches on the name alone, so a
-- local raise on a NET name would re-enter the handlers above.
local EVENT_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')
local EVENT_VIEW = OPX.Event(OPX.Channel.LOCAL, 'downed', 'view')
local EVENT_KEY = OPX.Event(OPX.Channel.LOCAL, 'downed', 'key')

-- How often, while down, the view is told to take the keyboard and mouse back.
local HOLD_MS = 500

-- A GIVE UP press is a RUN of reports and not one message, and this is how long
-- a gap in that run may be before the press is taken to have ended. The page
-- repeats itself several times a second while the button is down, so a second of
-- silence is a button let go, a view unmounted, or a surface the host stopped
-- resuming -- none of which is a player still pressing. Without it a press
-- abandoned at 1.4s would complete itself the next time the button was touched,
-- however many minutes later.
local HOLD_LAPSE_MS = 1000

-- What the server last said.
local state = { down = false, waiting = false, giveUpInMs = 0, downForMs = 0 }

-- When the live GIVE UP press began and when it was last reported, by this
-- client's clock. Both nil while nothing is pressed.
local holdingSinceMs = nil
local holdingSeenMs = nil

-- Every string a view draws, read from the active catalogue when it reports
-- ready.
local TEXT_KEYS = {
	'medic.screen.eyebrow', 'medic.screen.title', 'medic.screen.subtitle', 'medic.screen.vitals',
	'medic.screen.bpm', 'medic.screen.down', 'medic.screen.signal', 'medic.screen.signalOff',
	'medic.screen.signalOn', 'medic.wait.label', 'medic.wait.hint', 'medic.wait.active',
	'medic.wait.activeHint', 'medic.giveUp.label', 'medic.giveUp.hint', 'medic.giveUp.locked',
	'medic.giveUp.holding',
}

-- Modules holding the screen aside, by name.
local suspenders = {}

-- Whether the stock HUD components are hidden by this module.
local hudHidden = false

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state machine and nothing else: no surface is created
-- here. Everything it has to say to whatever draws the screen leaves on
-- EVENT_VIEW, and everything the view has to say comes back through the one
-- function `M.FromView`. A view module attaches by listening to the first and
-- calling the second.

-- Tells the view something. `kind` is 'config', 'show', 'hide', 'notice' or
-- 'focus'.
local function publish(kind, payload)
	payload = payload or {}
	payload.kind = kind
	TriggerEvent(EVENT_VIEW, payload)
end

-- Whether any suspender holds the screen aside.
local function suspended()
	return next(suspenders) ~= nil
end

-- Asks the view to take keyboard and cursor, so that every key mapping, the chat
-- box and every interaction prompt go inert. Repeated while down, because
-- something else may have taken them in the meantime.
local function hold()
	if suspended() then return end
	publish('focus', { hold = true })
end

-- Hands keyboard and cursor back unconditionally, so the player can always move.
local function release()
	publish('focus', { hold = false })
end

-- Hides or shows the VANILLA_HUD components, once per change.
local function hideVanillaHud(hidden)
	if hudHidden == hidden then return end
	local hud = Open77.hud
	if type(hud) ~= 'table' or type(hud.setVisible) ~= 'function' then return end
	hudHidden = hidden
	local components = M.Settings.VANILLA_HUD
	for _, component in ipairs(type(components) == 'table' and components or {}) do
		if type(component) == 'string' then pcall(hud.setVisible, component, not hidden) end
	end
	-- A CLAIM BELONGS TO THE RESOURCE, NOT TO THIS MODULE. `modules/hud` hides the
	-- vanilla HUD in the same resource's name, so the release above released its
	-- claims too and every revive brought the whole vanilla HUD back. It is asked
	-- to put its own back.
	if not hidden then
		local owner = OPX.Api.Get('hud')
		if owner ~= nil and type(owner.ApplyVanilla) == 'function' then pcall(owner.ApplyVanilla) end
	end
end

-- How long the GIVE UP press must last. Floored, because a misconfigured zero
-- would turn the hold into a click, which is the one thing GIVE_UP_HOLD_MS
-- exists to prevent. The view is told this number so that its fill takes exactly
-- as long as the press it depicts, and the press itself is timed against the
-- same one below -- one setting, read in one place.
local function holdMs()
	return math.floor(math.max(300, tonumber(M.Settings.GIVE_UP_HOLD_MS) or 1500))
end

-- Forgets a press in flight. Called wherever the screen stops being a thing the
-- player is holding a button on: a press left half-finished across a revive
-- would otherwise be a press already 1.5 seconds old at the next death.
local function forgetPress()
	holdingSinceMs, holdingSeenMs = nil, nil
end

-- Shows the screen with the held state, or hides it.
local function draw()
	if not state.down then
		publish('hide')
		return
	end
	publish('show', {
		suspended = suspended(),
		waiting = state.waiting,
		giveUpInMs = state.giveUpInMs,
		downForMs = state.downForMs,
		holdMs = holdMs(),
	})
end

-- Asks the server for this player's state again.
local function announce()
	TriggerServerEvent(EVENT_READY)
end

-- Adopts a server state, retaking the input after chat boxes and forms hand
-- theirs back.
local function apply(payload)
	local wasDown = state.down
	local wasWaiting = state.waiting
	state.down = payload.down == true
	state.waiting = state.down and payload.waiting == true
	state.giveUpInMs = math.max(0, math.floor(tonumber(payload.giveUpInMs) or 0))
	state.downForMs = math.max(0, math.floor(tonumber(payload.downForMs) or 0))
	if not state.down then forgetPress() end

	if state.down then
		hold()
		hideVanillaHud(true)
		if not wasDown then
			-- The first moments after a death are when something else is most
			-- likely to take the input; two further attempts cover them.
			CreateThread(function()
				Wait(150)
				if state.down then hold() end
				Wait(350)
				if state.down then hold() end
			end)
		end
	elseif wasDown then
		release()
		hideVanillaHud(false)
	end

	draw()
	if state.down ~= wasDown then OPX.Toast.SetDown(state.down) end
	if state.down ~= wasDown or state.waiting ~= wasWaiting then
		TriggerEvent(EVENT_CHANGED, { down = state.down, waiting = state.waiting })
	end
end

-- Shows a refusal. An unknown code reads as the generic sentence, never as a raw
-- key.
local function onRefused(code)
	if type(code) ~= 'string' or not code:match('^[%w_]+$') then code = 'failed' end
	local key = 'medic.refused.' .. code
	local line = locale(key)
	if line == key then line = locale('medic.refused.failed') end
	publish('notice', { text = line })
end

-- Times a GIVE UP press and sends the one that lasted long enough.
--
-- THE HOLD IS TIMED HERE, AND UNTIL THIS IT WAS TIMED NOWHERE. `GIVE_UP_HOLD_MS`
-- was published to a view and the server never looks at it: `onGiveUp` checks
-- the two-minute delay, that the body is still dead, and that the readiness gate
-- is open, and nothing else. So one call on this action respawned the player the
-- instant the delay was up, and a stray click on a screen that has been in front
-- of a bored player for two minutes is exactly what the setting exists to refuse.
--
-- THE PAGE REPORTS AN INTENT, NEVER A FACT: `holding = true` when the button
-- goes down and again while it is still down, `holding = false` when it is let
-- go. The elapsed time is read off THIS clock from the first report of a run, so
-- a page with a fast clock, a throttled timer or a rewritten payload cannot
-- shorten the hold -- the most it can do is fail to say the button is still down,
-- which ends the press. Everything after this is the server's: it re-checks the
-- delay, the body and the gate, and refuses on its own authority.
local function press(holding)
	if holding ~= true or not state.down or suspended() then return forgetPress() end

	local atMs = OPX.Now()
	if holdingSinceMs == nil or atMs - (holdingSeenMs or atMs) > HOLD_LAPSE_MS then
		holdingSinceMs = atMs
	end
	holdingSeenMs = atMs

	if atMs - holdingSinceMs < holdMs() then return end
	forgetPress()
	TriggerServerEvent(EVENT_GIVE_UP)
end

-- Raises a host-vocabulary key the view caught while holding the keyboard: no
-- key mapping fires while it does, so this is the only way another module hears
-- one.
local function forwardKey(key)
	if not state.down or suspended() or type(key) ~= 'string' then return end
	if not (key:match('^F%d%d?$') or key:match('^[A-Z0-9]$')) then return end
	TriggerEvent(EVENT_KEY, key)
end

--- What a view module calls. `action` is 'ready', 'wait', 'giveUp', 'key' or
--- 'diag'.
-- @author dop42
--
-- The other half of the seam. `ready` says the view can be drawn on and answers
-- with its text and the current state; `wait` and `giveUp` are the two choices,
-- checked in full on the server; `key` reports a key heard while the keyboard is
-- held; `diag` carries a view-side failure to the client log, which it could not
-- otherwise reach.
--
-- `giveUp` carries `holding`, which is the state of the BUTTON and not a
-- decision: see `press`. A call with no payload is therefore a click, and a
-- click respawns nobody.
-- @param action string
-- @param payload table|nil
function M.FromView(action, payload)
	if action == 'ready' then
		local text = {}
		for _, key in ipairs(TEXT_KEYS) do text[key] = locale(key) end
		publish('config', { text = text })
		draw()
		announce()
	elseif action == 'wait' then
		if state.down and not state.waiting then TriggerServerEvent(EVENT_WAIT) end
	elseif action == 'giveUp' then
		press(type(payload) == 'table' and payload.holding == true)
	elseif action == 'key' then
		forwardKey(type(payload) == 'table' and payload.key or nil)
	elseif action == 'diag' then
		Open77.log.info('downed view: ' .. tostring(type(payload) == 'table' and payload.text or ''))
	end
end

--- Sets the screen aside while a caller's own surface is up, or lets it back.
-- @author dop42
--
-- It fades out and the input goes back, so that a downed staff member can still
-- use the staff menu. SUSPENDERS names who may: the caller gives its own name,
-- so this is a configuration switch and no longer a boundary.
-- @param owner string
-- @param on boolean
-- @return Result
local function suspend(owner, on)
	local allowed = M.Settings.SUSPENDERS
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	if type(allowed) ~= 'table' or allowed[owner] ~= true then return Result.Err('caller_denied') end

	local was = suspended()
	suspenders[owner] = on == true or nil
	local now = suspended()
	if was == now then return Result.Ok(true) end
	if now then
		-- The screen is going aside under somebody else's surface, so whatever
		-- was being held on it is not being held any more.
		forgetPress()
		release()
	elseif state.down then
		hold()
	end
	draw()
	return Result.Ok(true)
end

--- Whether the local player is down, and whether they asked for help.
-- @author dop42
-- @return Result
local function isDown()
	return Result.Ok({ down = state.down, waiting = state.waiting })
end

-- Lets go on behalf of a suspender that stopped and cannot.
local function sweepSuspenders()
	for owner in pairs(suspenders) do
		if not OPX.Modules.IsRunning(owner) and GetResourceState(owner) ~= 'running' then
			suspend(owner, false)
		end
	end
end

--- Builds the held state.
-- @author dop42
function M.Init()
	state = { down = false, waiting = false, giveUpInMs = 0, downForMs = 0 }
	suspenders = {}
	hudHidden = false
	forgetPress()
end

--- Publishes the local player's state and the suspend switch.
-- @author dop42
function M.Api()
	OPX.Api.Provide('downed', 1, {
		IsDown = isDown,
		Suspend = suspend,
	})
end

--- Wires the events and starts the hold loop.
-- @author dop42
function M.Start()
	-- FIRST, so that the seam has somewhere to go before anything below can
	-- publish on it. `client/view.lua` is the only file that knows the other end
	-- is a CEF page; without it this module still holds its state and simply
	-- never draws, which is exactly what it did before that file existed.
	M.View.Start()

	RegisterNetEvent(EVENT_STATE, function(payload)
		if type(payload) ~= 'table' then return end
		apply(payload)
	end)
	RegisterNetEvent(EVENT_REFUSED, onRefused)

	-- A world change can stand a body up unannounced, so the state is asked for
	-- again.
	AddEventHandler(OPX.Host.WORLD_READY, announce)

	OPX.Scheduler.Every('downed:hold', HOLD_MS, function()
		sweepSuspenders()
		if state.down then hold() end
	end)

	announce()
end

--- Hands the input back and clears a raised down state.
-- @author dop42
function M.Stop()
	release()
	forgetPress()
	M.View.Shutdown()
	hideVanillaHud(false)
	if state.down then
		OPX.Toast.SetDown(false)
		TriggerEvent(EVENT_CHANGED, { down = false, waiting = false })
	end
	state.down, state.waiting = false, false
end
