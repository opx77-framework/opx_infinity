--- The flow: the world to draw in, the roster, the selection, the creation and the stage.
-- @author dop42
--
-- Everything that decides is here; `client/model.lua` shapes what is drawn and
-- `client/stage.lua` executes the camera. The page is reached over the
-- interactive surface and answers with INTENTS: it reports which card was
-- chosen, and this file reads the card it named out of its own model, calls the
-- character contract and waits for the event.

local M = OPX.Modules.Get('entry')
local Model = M.Model
local Stage = M.Stage
local Result = OPX.Result

local LOCAL = OPX.Channel.LOCAL
local NET = OPX.Channel.NET

-- The interactive layer: z 740, focused, created on first use.
local SURFACE = 'interactive'

-- This screen's name on the focus stack.
local FOCUS = 'entry'

-- Lua to the page.
local OUT_OPEN = 'entry:open'
local OUT_ROSTER = 'entry:roster'
local OUT_FORM = 'entry:form'
local OUT_STATUS = 'entry:status'
local OUT_CLOSE = 'entry:close'

-- The page to Lua.
local IN_READY = 'entry:ready'
local IN_FOCUS = 'entry:focus'
local IN_CHOOSE = 'entry:choose'
local IN_DISMISS = 'entry:dismiss'
local IN_STEP = 'entry:step'
local IN_SUBMIT = 'entry:submit'

-- The character module's public local bus. A bare name would be a typo waiting
-- to happen, so it is built the same way the module that raises it builds it.
local EVENT_ROSTER = OPX.Event(LOCAL, 'character', 'roster')
local EVENT_LOADED = OPX.Event(LOCAL, 'character', 'loaded')
local EVENT_UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded')

-- The appearance module's public decision bus, which is where `needsCreation` is
-- announced. Public: a bare AddEventHandler is the documented way to hear it.
local EVENT_APPEARANCE = OPX.Event(LOCAL, 'appearance', 'decision')

-- Where every server refusal arrives, with the operation it answers.
-- AddEventHandler and not RegisterNetEvent: `core/client/notify.lua` has already
-- registered this name for the wire, the dispatcher matches on the name alone,
-- and a second RegisterNetEvent would be a second registration of a name that is
-- already allowed. This handler is additive -- the runtime's own toast still goes
-- up; this one is what puts the reason on the screen the player is looking at.
local EVENT_REFUSED = OPX.Event(NET, 'runtime', 'notify')

-- Period of this module's one scheduler pass.
local TICK_MS = 250

-- How long after a dismissal the screen goes back up. The screen is what stands
-- between the player and the world: without this, Escape leaves a player with no
-- character and no way to choose one.
local REOPEN_MS = 250

-- How long the stage outlives the last thing that wanted it. The screen closing
-- and coming back after a dismissal is a gap of a few hundred milliseconds, and
-- the camera must not snap back to the player for it.
local STAGE_LINGER_MS = 1500

-- Shortest roster retry. The server DROPS a second request inside its own 2000 ms
-- cooldown without answering it, so a retry under this floor asks for nothing;
-- the margin covers the network between the two clocks.
local ROSTER_RETRY_FLOOR_MS = 2500
local ROSTER_RETRY_DEFAULT_MS = 3000

-- The contracts this screen is built on, resolved once the Api phase has ended.
local Character
local Appearance

-- idle | roster | selecting | create | creating
local phase = 'idle'

-- The generation the page echoes on every message. A payload carrying an older
-- one is a message from a screen that has been replaced, and is dropped.
local handle = 0

-- Whether the last frame reached the page. A surface refuses every send until
-- its page has reported ready, and the first open usually happens before that.
local frameSent = false

-- Whether the page handlers have been wired, which also creates the surface.
local wired = false

-- The card id the cursor is on.
local cursor

-- The five answers of a creation in progress, and where in the form it is.
local draft = {}
local step = 'identity'
local formError, formField

-- The line under the screen: text and a tone the page colours it by.
local status

-- The selection with the server, and the registration with the server.
local pending
local registering

local inWorld = false
local worldEntered = false
local worldUp = false
local editing = false
local running = false

local rosterAskedMs = 0
local rosterRetrying = false
local rosterRetryMs = ROSTER_RETRY_DEFAULT_MS
local rosterRetryProblem

local selectDeadline
local createDeadline

local lingerUntilMs = 0
local reopenAtMs = 0

-- Forward declarations: the page handlers and the flow reach each other.
local openScreen, closeScreen, sendForm, syncStage, rosterWanted

--- Announces where the screen is, once per change, on the public local bus.
local function announce()
	TriggerEvent(M.Event.ON_STATE, { open = phase ~= 'idle', phase = phase })
end

--- Sends one payload to the page and remembers whether it landed.
local function push(channel, payload)
	payload.handle = handle
	local sent = OPX.UI.Send(SURFACE, channel, payload)
	if not sent then frameSent = false end
	return sent
end

--- Writes the status line, and puts it on the page when one is up.
local function setStatus(text, tone)
	status = text ~= nil and { text = text, tone = tone or 'info' } or nil
	if phase == 'idle' then return end
	push(OUT_STATUS, { text = status ~= nil and status.text or '', tone = tone or 'info' })
end

-- ── the stage ────────────────────────────────────────────────────────────────

--- Whether the world, no loaded character and no face editor allow the stage.
local function stageAllowed()
	return running and worldUp and not inWorld and not editing
end

--- Whether somebody is choosing a character right now.
local function choosing(atMs)
	return phase ~= 'idle' or pending ~= nil or registering ~= nil or atMs < reopenAtMs
end

--- Tells the stage what it should be now, the linger included.
syncStage = function()
	local atMs = OPX.Now()
	if not stageAllowed() then
		lingerUntilMs = 0
		Stage.Set(false)
		return
	end
	if choosing(atMs) then
		lingerUntilMs = atMs + STAGE_LINGER_MS
	elseif atMs >= lingerUntilMs then
		Stage.Set(false)
		return
	end
	-- The fallback hold lets go the moment a selection is with the server, and not
	-- when the character loads: the server is about to place the character, and a
	-- teleport would pull it back. The camera and the controls stay, since the
	-- server announces the load before it places anybody.
	Stage.Set(true, pending == nil)
end

--- Takes the stage down now, whatever was lingering.
local function dropStage(reason)
	lingerUntilMs, reopenAtMs = 0, 0
	Stage.Set(false)
	Open77.log.debug('[entry] the stage went down: ' .. reason)
end

-- ── the world to draw in ─────────────────────────────────────────────────────

--- The host's character bootstrap phase, or `unreadable`.
local function bootstrapPhase()
	if type(Open77.session) ~= 'table' then return 'unreadable' end
	local ok, bootstrap = pcall(Open77.session.characterBootstrap)
	return ok and type(bootstrap) == 'table' and tostring(bootstrap.phase) or 'unreadable'
end

--- Whether the local puppet is attached and alive.
local function puppetAlive()
	if type(Open77.character) ~= 'table' then return false end
	local ok, character = pcall(Open77.character.state)
	return ok and type(character) == 'table' and character.attached == true and
		character.alive == true
end

--- Settles whether the gameplay world is up after a world entry.
-- The bootstrap phase alone is not enough: just after it resolves, the pre-game
-- menu's puppet still answers attached and alive, so the world would read as up
-- under the loading cover.
local function worldCheck()
	if worldUp then return true end
	if not worldEntered or bootstrapPhase() ~= 'ready' or not puppetAlive() then return false end
	worldUp = true
	return true
end

--- Whether nothing stands between the held roster and the player.
rosterWanted = function()
	return running and worldUp and Model.hasRoster and phase == 'idle' and
		not inWorld and not editing and pending == nil and registering == nil
end

--- Puts up the roster that was waiting for the gameplay world.
local function openInWorld(reason)
	if not rosterWanted() then return end
	Open77.log.debug('[entry] the gameplay world is up (' .. reason .. '): the roster goes up')
	openScreen('roster')
end

-- ── the screen ───────────────────────────────────────────────────────────────

--- The cards, stripped of what the page has no business holding.
-- The citizen id stays on this side: the page reports a CARD ID, and the card it
-- names is what is read. A page that sent an identity could name one it was
-- never given.
local function drawableCards()
	local source = Model.Cards()
	local out = {}
	for index = 1, #source do
		local card = source[index]
		out[index] = {
			id = card.id,
			kind = card.kind,
			name = card.name,
			monogram = card.monogram,
			identifier = card.identifier,
			lifepath = card.lifepath,
			body = card.body,
			role = card.role,
			affiliation = card.affiliation,
			lastSeen = card.lastSeen,
			note = card.note,
			disabled = card.disabled,
		}
	end
	return out
end

--- Sends the roster frame.
local function sendRoster()
	frameSent = push(OUT_ROSTER, {
		cards = drawableCards(),
		cursor = cursor,
		used = #Model.roster.list,
		slots = Model.roster.slots,
		slotsLabel = locale('entry.slots',
			{ used = #Model.roster.list, slots = Model.roster.slots }),
		busy = phase == 'selecting',
		status = status ~= nil and status.text or '',
		tone = status ~= nil and status.tone or 'info',
	})
end

--- Sends the creation frame for the step the form is on.
sendForm = function()
	local frame = Model.Frame(step, draft)
	frame.busy = phase == 'creating'
	frame.error = formError or ''
	frame.errorField = formField or ''
	frame.status = status ~= nil and status.text or ''
	frame.tone = status ~= nil and status.tone or 'info'
	frame.warning = locale('entry.create.warning')
	frameSent = push(OUT_FORM, frame)
end

--- Which of the two modes the screen is showing.
local function currentMode()
	return (phase == 'create' or phase == 'creating') and 'create' or 'roster'
end

--- Sends whichever frame the screen is showing.
local function sendFrame()
	if currentMode() == 'create' then sendForm() else sendRoster() end
end

--- The keycap hints, resolved here because the page holds no English.
local function keyHints(mode)
	if mode == 'create' then
		return {
			{ key = '↑ ↓', label = locale('entry.key.move') },
			{ key = '↵', label = locale('entry.key.confirm') },
			{ key = 'ESC', label = locale('entry.key.back') },
		}
	end
	return {
		{ key = '↑ ↓ ← →', label = locale('entry.key.move') },
		{ key = '↵', label = locale('entry.key.choose') },
	}
end

--- Wires the page's channels. Doing so creates the interactive surface, so it is
--- deferred to the first open: a player who reconnects straight into a character
--- never pays for the second CEF page.
local function wirePage()
	if wired then return end
	wired = true

	OPX.UI.On(SURFACE, IN_READY, function(payload)
		if payload.handle ~= nil and payload.handle ~= handle then return end
		if phase == 'idle' then return end
		-- The page has just come up. Everything it was sent before it could
		-- report ready was dropped rather than queued, so it is sent again.
		openScreen(currentMode(), true)
	end)

	OPX.UI.On(SURFACE, IN_FOCUS, function(payload)
		if payload.handle ~= handle or phase ~= 'roster' then return end
		local card = Model.Card(payload.id)
		if card == nil then return end
		cursor = card.id
	end)

	OPX.UI.On(SURFACE, IN_CHOOSE, function(payload)
		if payload.handle ~= handle then return end
		M.Choose(payload.id)
	end)

	OPX.UI.On(SURFACE, IN_DISMISS, function(payload)
		if payload.handle ~= handle or phase ~= 'roster' then return end
		closeScreen('dismissed')
		reopenAtMs = OPX.Now() + REOPEN_MS
		syncStage()
	end)

	OPX.UI.On(SURFACE, IN_STEP, function(payload)
		M.Step(payload)
	end)

	OPX.UI.On(SURFACE, IN_SUBMIT, function(payload)
		if payload.handle ~= handle then return end
		M.Submit(payload)
	end)
end

--- Puts the screen up, or switches it between its two modes.
-- @param mode string `roster` or `create`
-- @param again boolean|nil Redrawing what is already up, keeping its handle.
openScreen = function(mode, again)
	wirePage()
	local was = phase
	-- The phase is the caller's to set: a selection or a registration in flight
	-- keeps its own, and only a screen that was down is given one here.
	if phase == 'idle' then phase = mode == 'create' and 'create' or 'roster' end

	-- A fresh open takes a new generation; a mode switch and a redraw keep the one
	-- the page is already echoing, so a message in flight is not thrown away.
	if not again and was == 'idle' then
		handle = handle + 1
		OPX.UI.AcquireFocus(FOCUS, { keyboard = true, cursor = true })
	end

	push(OUT_OPEN, {
		mode = mode,
		eyebrow = locale(mode == 'create' and 'entry.eyebrow.create' or 'entry.eyebrow.roster'),
		title = locale(mode == 'create' and 'entry.create.title' or 'entry.title'),
		keys = keyHints(mode),
	})
	sendFrame()
	if was ~= phase then announce() end
	syncStage()
end

--- Takes the screen down and gives the focus back.
closeScreen = function(reason)
	if phase == 'idle' then return end
	phase = 'idle'
	push(OUT_CLOSE, {})
	OPX.UI.ReleaseFocus(FOCUS)
	announce()
	Open77.log.debug('[entry] the screen closed: ' .. reason)
end

-- ── choosing ─────────────────────────────────────────────────────────────────

--- Ends a selection that will not load, and says why under the cards.
local function unlockSelection(text)
	pending = nil
	if phase == 'selecting' then phase = 'roster' end
	syncStage()
	setStatus(text, 'error')
	if rosterWanted() then openScreen('roster') else sendFrame() end
end

--- Asks the character contract to enter the world as one character.
-- The answer is an EVENT and not a return: the contract answers whether the
-- request left this client, and the world arrives on `loaded` or a refusal.
local function select(citizenId)
	pending = { atMs = OPX.Now() }
	phase = 'selecting'
	syncStage()
	setStatus(locale('entry.notice.entering'), 'info')
	sendRoster()

	local sent, code = Character.SelectCharacter(citizenId)
	if sent then return end
	unlockSelection(Model.Refusal(code))
end

--- The body family the world was loaded on, or nil.
-- A world entry loads the most recently played character's body, so this is what
-- the player is looking at; offering the other one reloads the world.
local function loadedFamily()
	if Appearance == nil or type(Appearance.State) ~= 'function' then return nil end
	local ok, answer = pcall(Appearance.State)
	if not ok or type(answer) ~= 'table' or not answer.ok then return nil end
	local body = type(answer.value) == 'table' and answer.value.body or nil
	if body == 'female' or body == 'male' then return body end
	return nil
end

--- Starts a creation on the screen the roster was on.
local function beginCreation()
	if not Model.HasOrigins() then
		-- The lifepaths arrive with the roster, so asking for one asks for them.
		setStatus(locale('entry.notice.noLifepath'), 'error')
		Character.RequestCharacters()
		rosterAskedMs = OPX.Now()
		sendRoster()
		return
	end
	draft = { gender = loadedFamily() }
	step = 'identity'
	formError, formField = nil, nil
	setStatus(nil)
	phase = 'create'
	openScreen('create')
end

--- Acts on the card the player chose, read from this module's own cards.
-- @author dop42
-- @param id any
function M.Choose(id)
	if phase ~= 'roster' then return end
	local card = Model.Card(id)
	if card == nil or card.disabled then return end
	cursor = card.id
	if card.kind == 'character' and type(card.citizenId) == 'string' then
		select(card.citizenId)
	elseif card.kind == 'empty' or card.kind == 'create' then
		beginCreation()
	end
end

-- ── creating ─────────────────────────────────────────────────────────────────

--- Ends the creation and hands the player back to the roster.
-- @author dop42
-- @param reason string
function M.CancelCreation(reason)
	if phase ~= 'create' and phase ~= 'creating' then return end
	registering = nil
	draft = {}
	formError, formField = nil, nil
	phase = 'roster'
	cursor = cursor or Model.FirstFocus()
	setStatus(nil)
	openScreen('roster')
	Open77.log.debug('[entry] creation ended: ' .. reason)
end

--- Sends the registration, having checked every step's rules again.
local function submit()
	local registration, field, message = Model.Registration(draft)
	if registration == nil then
		-- A player who walked back and edited a field must not submit a value no
		-- step happened to look at on the way forward, so the form goes back to
		-- the step that owns whatever refused.
		formField, formError = field, message
		step = Model.StepOf(field) or step
		sendForm()
		return
	end

	registering = { atMs = OPX.Now() }
	phase = 'creating'
	formError, formField = nil, nil
	syncStage()
	setStatus(locale('entry.notice.registering'), 'info')
	sendForm()

	local sent, code = Character.CreateCharacter(registration)
	if sent then return end
	-- The contract refused before anything left this client. Its codes are the
	-- server's own, so they render the same way.
	registering = nil
	phase = 'create'
	setStatus(nil)
	formError = Model.Refusal(code, { max = Model.roster.slots })
	syncStage()
	sendForm()
end

--- Moves the form one step, in either direction.
-- @author dop42
-- @param payload table
function M.Step(payload)
	if type(payload) ~= 'table' or payload.handle ~= handle then return end
	if phase ~= 'create' then return end

	draft = Model.Draft(payload.values)
	local at = Model.StepAt(step) or 1
	local steps = Model.Steps()

	if tonumber(payload.direction) == -1 then
		if at <= 1 then
			M.CancelCreation('back from the first step')
			return
		end
		step = steps[at - 1]
		formError, formField = nil, nil
		sendForm()
		return
	end

	local field, message = Model.Check(step, draft)
	if field ~= nil then
		formField, formError = field, message
		sendForm()
		return
	end
	if at >= #steps then
		submit()
		return
	end
	step = steps[at + 1]
	formError, formField = nil, nil
	sendForm()
end

--- Submits the form from its last step.
-- @author dop42
-- @param payload table
function M.Submit(payload)
	if type(payload) ~= 'table' or phase ~= 'create' then return end
	draft = Model.Draft(payload.values)
	submit()
end

-- ── what the server says ─────────────────────────────────────────────────────

--- Adopts a roster, and ends a registration it answers.
local function onRoster(roster)
	local known = Model.hasRoster and Model.KnownIds() or nil
	if not Model.Adopt(roster) then return end
	-- A roster received with a character loaded is ONLY adopted. Reopening then
	-- would put the screen, the camera and the control lock on a player who is
	-- playing. The server no longer sends one; this is defence in depth.
	if inWorld then return end

	local created = known ~= nil and Model.FirstNew(known) or nil

	if registering ~= nil then
		-- A roster that gained a character IS the answer to the registration.
		registering = nil
		draft = {}
		formError, formField = nil, nil
	elseif phase == 'create' then
		-- The player is still filling the form. The roster is adopted and the form
		-- is left exactly where it is.
		return
	end

	pending = nil
	editing = false
	if created ~= nil then
		cursor = created
		local card = Model.Card(created)
		setStatus(locale('entry.notice.created',
			{ name = card ~= nil and card.name or '' }), 'ok')
	else
		cursor = Model.FirstFocus()
		setStatus(nil)
	end

	if not worldUp then
		-- Held, not drawn. The world entry puts it up.
		if phase ~= 'idle' then closeScreen('roster before the world') end
		return
	end
	if phase ~= 'idle' then phase = 'roster' end
	openScreen('roster')
end

--- Takes the screen and the stage down for a character that loaded.
local function onLoaded()
	pending = nil
	registering = nil
	inWorld = true
	closeScreen('character loaded')
	dropStage('character loaded')
end

--- Forgets the character and the roster, then asks for a fresh one.
local function unloadCharacter(reason)
	inWorld = false
	editing = false
	-- A selection that is still with the server unloaded the PREVIOUS character;
	-- the screen is already waiting on it and must not be reset under it.
	if pending ~= nil then return end
	registering = nil
	closeScreen(reason)
	Model.Forget()
	rosterAskedMs = OPX.Now()
	Character.RequestCharacters()
	syncStage()
end

--- Shows a server refusal meant for this screen, and nothing else.
-- BRANCHED ON THE OPERATION, never on the code: `error.tooFast` is raised by
-- every request the server rate limits, and without the operation this screen
-- would take a vehicle's refusal for its own.
local function onRefused(payload)
	if type(payload) ~= 'table' then return end
	local code = payload.code
	local operation = payload.operation

	if operation == M.Operation.SELECT then
		if pending == nil then return end
		unlockSelection(Model.Refusal(code))
	elseif operation == M.Operation.CREATE then
		if registering == nil then return end
		registering = nil
		phase = 'create'
		setStatus(nil)
		-- `character.limit` reads the account's slot count back to the player.
		formError = Model.Refusal(code, { max = Model.roster.slots })
		formField = nil
		syncStage()
		sendForm()
	elseif operation == M.Operation.ROSTER or operation == M.Operation.ENTRY then
		setStatus(Model.Refusal(code), 'error')
		if phase == 'idle' then
			Open77.log.warn(('[entry] %s was refused: %s'):format(operation, tostring(code)))
		end
	end
end

--- Answers `needsCreation` by opening the face editor through the contract.
local function onAppearance(payload)
	if type(payload) ~= 'table' or payload.event ~= 'needsCreation' then return end
	-- The face editor has a camera of its own. `loaded` has normally already taken
	-- the stage down; this is for a character this module did not see load, and
	-- `editing` keeps it down until the appearance work has settled.
	editing = true
	dropStage('face editor')
	if phase ~= 'idle' then closeScreen('face editor') end

	if Appearance == nil or type(Appearance.OpenCreator) ~= 'function' then
		Open77.log.warn('[entry] no appearance contract answers `needsCreation`: ' ..
			'the character enters on the default face')
		return
	end
	local ok, answer = pcall(Appearance.OpenCreator)
	if ok and type(answer) == 'table' and answer.ok then return end
	Open77.log.error('[entry] the face editor was refused: ' ..
		tostring(type(answer) == 'table' and answer.error or answer))
end

-- ── the one pass ─────────────────────────────────────────────────────────────

--- Lets go of `editing` once the appearance module says its work has settled.
local function watchEditor()
	if not editing then return end
	if Appearance == nil or type(Appearance.IsSettled) ~= 'function' then return end
	local ok, answer = pcall(Appearance.IsSettled)
	if not ok or type(answer) ~= 'table' or not answer.ok then return end
	if type(answer.value) == 'table' and answer.value.settled == true then editing = false end
end

--- Reads the roster the contract already holds, when it carries slots.
local function adoptHeld()
	local held = Character.GetCharacters()
	-- A mirror with no slots is what the contract answers before any roster has
	-- reached this client: adopting it would end the retries on nothing.
	if type(held) ~= 'table' or (tonumber(held.slots) or 0) <= 0 then return false end
	if not Model.Adopt(held) then return false end
	cursor = Model.FirstFocus()
	if rosterWanted() then openScreen('roster') end
	return true
end

--- Asks for the roster again, reading the mirror back first.
local function retryRoster()
	if adoptHeld() then
		Open77.log.info('[entry] the roster was read back from the character contract')
		return
	end
	rosterAskedMs = OPX.Now()
	Character.RequestCharacters()
end

--- Whether a roster retry is due, past the server's own cooldown.
local function rosterDue(atMs)
	if Model.hasRoster or inWorld then
		rosterRetrying = false
		return false
	end
	return atMs - rosterAskedMs >= rosterRetryMs
end

--- Expires a selection or a registration the server never answered.
-- Without them a lost answer leaves a player in front of a greyed screen with no
-- way out, and no way to reach this screen again for the rest of the session.
local function expireDeadlines(atMs)
	if pending ~= nil and selectDeadline ~= nil and atMs - pending.atMs >= selectDeadline then
		unlockSelection(locale('entry.notice.timedOut'))
	end
	if registering ~= nil and createDeadline ~= nil and
		atMs - registering.atMs >= createDeadline then
		registering = nil
		phase = 'create'
		setStatus(nil)
		formError = locale('entry.notice.timedOut')
		syncStage()
		sendForm()
	end
end

--- One pass: the world watch, the deadlines, the retries, the stage and the page.
local function tick()
	local atMs = OPX.Now()

	if worldEntered and not worldUp and worldCheck() then openInWorld('puppet attached') end
	watchEditor()
	expireDeadlines(atMs)

	if reopenAtMs ~= 0 and atMs >= reopenAtMs then
		reopenAtMs = 0
		if rosterWanted() then openScreen('roster') end
	end

	if rosterDue(atMs) then
		if not rosterRetrying then
			rosterRetrying = true
			Open77.log.warn(('[entry] no roster yet: asking again every %d ms'):format(rosterRetryMs))
		end
		retryRoster()
	end

	-- A send made before the page reported ready is DROPPED, not queued, so the
	-- frame is pushed again until one lands.
	if phase ~= 'idle' and not frameSent then openScreen(currentMode(), true) end

	syncStage()
	Stage.Tick()
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- Puts the screen up, asking for a roster when none is held.
-- @author dop42
-- @param reason string|nil
-- @return Result
local function open(reason)
	if inWorld then return Result.Err('in_world') end
	if phase == 'selecting' or phase == 'creating' then return Result.Err('busy') end
	if not Model.hasRoster then
		Character.RequestCharacters()
		rosterAskedMs = OPX.Now()
		return Result.Err('no_roster')
	end
	if not worldUp then return Result.Err('world_not_ready') end
	openScreen(currentMode())
	Open77.log.debug('[entry] the screen was asked for: ' .. tostring(reason or 'caller'))
	return Result.Ok({ open = true })
end

--- Takes the screen down, and the stage with it.
-- Whoever closes the screen has taken the player somewhere else.
-- @author dop42
-- @param reason string|nil
-- @return Result
local function close(reason)
	if phase == 'selecting' or phase == 'creating' then return Result.Err('busy') end
	closeScreen(tostring(reason or 'caller'))
	dropStage(tostring(reason or 'caller'))
	return Result.Ok(true)
end

--- Whether the screen is on the player's monitor.
-- @author dop42
-- @return Result
local function isOpen()
	return Result.Ok({ open = phase ~= 'idle' })
end

--- Where the screen is, what it holds and what the stage is doing.
-- @author dop42
-- @return Result
local function state()
	local card = cursor ~= nil and Model.Card(cursor) or nil
	return Result.Ok({
		open = phase ~= 'idle',
		phase = phase,
		world = worldUp,
		inWorld = inWorld,
		characters = #Model.roster.list,
		slots = Model.roster.slots,
		cursor = cursor,
		citizenId = card ~= nil and card.citizenId or nil,
		step = (phase == 'create' or phase == 'creating') and step or nil,
		staged = Stage.Up(),
		frozen = Stage.Frozen(),
		cameraLocked = Stage.CameraLocked(),
	})
end

-- ── the lifecycle ────────────────────────────────────────────────────────────

--- Builds the held state and resolves the settings that are read once.
-- @author dop42
function M.Init()
	Stage.Configure()

	phase, handle, cursor = 'idle', 0, nil
	draft, step = {}, 'identity'
	formError, formField, status = nil, nil, nil
	pending, registering = nil, nil
	inWorld, worldEntered, worldUp, editing = false, false, false, false
	rosterAskedMs, rosterRetrying = 0, false
	lingerUntilMs, reopenAtMs = 0, 0

	selectDeadline = M.Deadline(M.Settings.SELECT_TIMEOUT_MS)
	createDeadline = M.Deadline(M.Settings.CREATE_TIMEOUT_MS)

	local wanted = tonumber(M.Settings.ROSTER_RETRY_MS)
	if not OPX.Math.IsFinite(wanted) or wanted <= 0 then
		rosterRetryMs = ROSTER_RETRY_DEFAULT_MS
		rosterRetryProblem = ('ROSTER_RETRY_MS is not a positive number: %d ms is used')
			:format(ROSTER_RETRY_DEFAULT_MS)
	elseif wanted < ROSTER_RETRY_FLOOR_MS then
		rosterRetryMs = ROSTER_RETRY_FLOOR_MS
		rosterRetryProblem = ("ROSTER_RETRY_MS is inside the server's cooldown: raised to %d ms")
			:format(ROSTER_RETRY_FLOOR_MS)
	else
		rosterRetryMs = math.floor(wanted)
		rosterRetryProblem = nil
	end
end

--- Publishes the screen: open it, close it, and read where it is.
-- @author dop42
function M.Api()
	OPX.Api.Provide('entry', 1, {
		Open = open,
		Close = close,
		IsOpen = isOpen,
		State = state,
	})
end

--- Names a key one catalogue carries and the other does not.
local function compareCatalogs()
	local en, fr = M.Catalogs.en, M.Catalogs.fr
	for key in pairs(en) do
		if fr[key] == nil then Open77.log.warn('[entry] fr is missing ' .. key) end
	end
	for key in pairs(fr) do
		if en[key] == nil then Open77.log.warn('[entry] en is missing ' .. key) end
	end
end

--- Resolves the contracts, wires the events, and reads what is already known.
-- @author dop42
function M.Start()
	running = true
	Character = OPX.Api.Require('character')
	-- OPTIONAL. Without it a character with no face enters on the default one,
	-- which is what the platform does when nothing answers `needsCreation`.
	Appearance = OPX.Api.Get('appearance')
	if Appearance == nil then
		Open77.log.info('[entry] no appearance contract: a new character enters on the ' ..
			'default face and the form offers both bodies')
	end

	if rosterRetryProblem ~= nil then Open77.log.error('[entry] ' .. rosterRetryProblem) end
	for _, line in ipairs(Stage.Problems()) do Open77.log.error('[entry] ' .. line) end
	compareCatalogs()

	AddEventHandler(EVENT_ROSTER, onRoster)
	AddEventHandler(EVENT_LOADED, onLoaded)
	AddEventHandler(EVENT_UNLOADED, function() unloadCharacter('character unloaded') end)
	AddEventHandler(EVENT_APPEARANCE, onAppearance)
	AddEventHandler(EVENT_REFUSED, onRefused)

	AddEventHandler(OPX.Host.WORLD_READY, function()
		local bootstrap = bootstrapPhase()
		if bootstrap == 'unreadable' then return end
		if bootstrap ~= 'ready' then
			-- The pre-game menu world raises this too, and a screen drawn there
			-- sits under the loading cover with the player's controls locked behind
			-- it. The next gameplay entry puts it back.
			worldEntered, worldUp = false, false
			if phase ~= 'idle' then closeScreen('pre-game world') end
			syncStage()
			return
		end
		worldEntered = true
		if worldCheck() then openInWorld('worldReady') end
	end)

	AddEventHandler(M.HostEvent.RESET_COMPLETE, function()
		if bootstrapPhase() ~= 'ready' then return end
		worldEntered, worldUp = true, true
		openInWorld('playerReset')
	end)

	-- A reload inside a living world is followed by no world entry at all: a
	-- bootstrap already in the ready phase stands in for one.
	worldEntered = bootstrapPhase() == 'ready'
	worldCheck()

	if Character.IsLoggedIn() then
		inWorld = true
	elseif not adoptHeld() then
		setStatus(locale('entry.notice.waiting'), 'info')
		rosterAskedMs = OPX.Now()
		Character.RequestCharacters()
	end

	-- One registration, not a thread. The per-resume instruction budget unwinds
	-- out of a coroutine body, and a `while true` loop that hits it is never
	-- resumed again, silently.
	OPX.Scheduler.Every('entry:tick', TICK_MS, tick)
end

--- Gives the focus, the camera, the controls and the hold back.
-- @author dop42
function M.Stop()
	running = false
	closeScreen('module stopped')
	dropStage('module stopped')
end
