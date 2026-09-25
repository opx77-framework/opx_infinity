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

-- The name the pause plugin re-raises Escape under. A host name, so it is not
-- built from `OPX.Event`, and the same constant `modules/menu` reads.
local PAUSE_KEY = 'open77:pauseKey'

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

-- Forward-declared: `onState` below pushes the projection's payload as well as
-- the card's, and it is defined with the rest of the hologram two hundred lines
-- further down. Without this the call would resolve to a global and be nil.
local drawHolo

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
		-- At once, not on the next sweep: the first half-second of a call is
		-- exactly when somebody says "allô".
		routeVoice()
	elseif hadCall ~= nil and nowCall == nil then
		play(sounds.HANG_UP)
	end

	-- THE PROJECTION KNOWS ABOUT THE CALL TOO. It is not only the screen the
	-- player opens: a call arriving pops the sphere with the caller in it and
	-- nothing else, which is the owner's "tu vas juste pop l'animation pas le
	-- menu". So the holo payload goes out on every state change as well as on
	-- every open.
	drawHolo()

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
-- ── the route this machine's own voice takes ─────────────────────────────────
--
-- THE OWNER: "petit bug quand il repond a l'appel on s'entend pas". The server
-- half of that is a voice channel per call and membership on it -- see
-- `modules/calls/server/main.lua` -- and membership is what makes the other
-- person AUDIBLE. It is not what makes you audible to them.
--
-- A client captures one stream and ROUTES it: `setTransmitting`'s intent picks
-- between proximity, the channels you are a member of, or both. The default is
-- proximity, which across Night City reaches nobody, so two people on a call
-- could each hear a channel neither of them was speaking into.
--
-- THE MIC IS NEVER FORCED OPEN, and the shape below is the whole of that
-- promise: `enabled` is read back out of `Open77.voice.status()` and handed
-- straight back. This says "whatever you are doing with the microphone, keep
-- doing it, and send it to the call as well" -- it cannot start a transmission
-- and it cannot stop one. `all` rather than `channels` because a holocall in a
-- shared world should still be half-audible to whoever is standing next to you.
--
-- Re-asserted on the sweep as well as on the state change, because `open-voice`
-- owns the push-to-talk key and drives the same native; if it re-states the
-- intent, this takes it back within half a second rather than for good.
local function routeVoice()
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.setTransmitting) ~= 'function' then return end
	if type(api.status) ~= 'function' then return end

	local read, status = pcall(api.status)
	if not read or type(status) ~= 'table' then return end

	-- Two names for the same fact across builds, and neither is guessed at: the
	-- card for `status` promises "PTT/VAD state" without fixing the field, so
	-- both are read and anything else leaves the route alone.
	local talking = status.transmitting
	if type(talking) ~= 'boolean' then talking = status.pushToTalk end
	if type(talking) ~= 'boolean' then return end

	pcall(api.setTransmitting, talking, 'all')
end

local function rearm()
	-- BEFORE THE INVITE GUARD, because a call is live long after the invite is
	-- gone and this is the only clock the module runs.
	if state.call ~= nil then routeVoice() end
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

	-- ── THE HOLOGRAM'S OWN VERBS ─────────────────────────────────────────────
	-- Every one of them names a player id the SERVER then judges again. A page
	-- is the least trustworthy caller in the resource -- it is a browser -- so
	-- the id is bounded through the model here and the rule is applied there.
	if action == 'close' then return M.CloseHolo() end
	if action == 'toggle' then return M.ToggleHolo() end
	if action == 'call' then
		return M.Invite(type(payload) == 'table' and payload.id or nil, nil)
	end
	if action == 'share' then
		-- THE OWNER: "le share contact devrais etre un input qui propose un yes
		-- or no". It always was on the receiving side -- a contact hand-over is
		-- an invite like any other and needs the other party's consent -- and
		-- what was missing is that the ASKING side had no screen of its own.
		-- The page puts the question; this is the yes.
		return M.Invite(type(payload) == 'table' and payload.id or nil, 'contact')
	end
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
-- ── the one thing the eye is still right for ─────────────────────────────────
--
-- THE OWNER: "pour demander le contact a quelqun c'est toujours avec alt ? ce
-- serais top", and then: "du coup plus de arround me vu que tu utilise le target
-- pour partager le contact ou avoir le contact".
--
-- ALT CAME BACK FOR EXACTLY ONE ROW, and the reason is the reason it was wrong
-- for the others. The eye needs a body under the crosshair. Answering a call
-- does not have one -- the person is somewhere else, which is the whole point of
-- a holocall -- and the eight rows that used to live here made a player point at
-- their own body to pick up. Handing somebody your contact is the opposite: it
-- IS a thing you do to a person standing in front of you, face to face, within
-- arm's reach, and pointing at them is the natural way to say which one.
--
-- SO THE "AROUND ME" TAB WENT. The hologram grew one when ALT was removed --
-- otherwise a contact list you can only add to with the thing just deleted stays
-- empty forever -- and this row makes it redundant. One way to do a thing.
--
-- THE SERVER STILL DECIDES. The row names a player id and nothing else; the
-- range, the bucket, the consent and the swap are all judged there, by the same
-- function that judges every other invite.
local OWNER = 'calls'

-- Metres the row reaches. Deliberately short and deliberately not the twelve a
-- call row used to have: the server refuses a hand-over beyond `CONTACT_RANGE`,
-- and a row offered where it would be refused is a row that teaches a player the
-- feature is broken.
local ROW_DISTANCE = 6.0

-- The id the eye's context names for the body under the crosshair, as a number.
local function targetOf(context)
	local target = type(context) == 'table' and context.target or nil
	if type(target) ~= 'table' then return nil end
	return Model.PlayerId(target.playerId)
end

--- The one row this module draws on another player.
-- @author dop42
-- @return table[]
function M.PlayerRows()
	return {
		{
			id = 'callShare',
			label = locale('calls.row.share'),
			icon = 'person',
			group = locale('calls.group'),
			order = 60,
			distance = ROW_DISTANCE,
			canInteract = function(context) return targetOf(context) ~= nil end,
			onSelect = function(context)
				local target = targetOf(context)
				if target == nil then return false end
				return M.Invite(target, 'contact')
			end,
		},
	}
end

-- Puts the row on the eye. ON A THREAD with a `Wait(0)`, because `RegisterMany`
-- is ALL OR NOTHING -- one malformed row refuses the whole batch, and the
-- refusal is written to a log on the player's own machine, which is the trap
-- `modules/animations/client/walk.lua` fell into and documented.
local function registerRows(contract)
	Wait(0)
	local answer = contract.RegisterPlayers(OWNER, M.PlayerRows())
	if answer == nil or answer.ok ~= true then
		OPX.Note('calls', ('the contact row was refused: %s')
			:format(tostring(answer and answer.error)))
		return false
	end
	return true
end


-- ── the hologram: one screen, and every verb on it ───────────────────────────
--
-- THE OWNER: "fait en sorte que cela passe pas par alt ce serais en gros fait
-- une touche qui ouvre un menu style halogram tous se passe desus call resus
-- contact etc plus de alt", then "le halo prend vrais le devant de l'ecran" and
-- "en plein centre".
--
-- WHAT WAS HERE BEFORE: eight rows on the target eye and a contacts list drawn
-- with the generic menu module. Both are gone. The eye is where you interact
-- with a thing you are LOOKING AT, and a holocall is the thing you reach for
-- when the person is not there -- answering one meant pointing at your own body
-- first, which is the tell that the mechanism was the one at hand rather than
-- the one the feature wanted.
--
-- TWO SURFACES, AND THE SPLIT IS THE WHOLE DESIGN. The incoming card and the
-- live chip stay on `overlay`: `pointer-events: none` for their whole height,
-- never focused, so a call arriving can never take the mouse or stand between
-- the player and what they are aiming at. The hologram is the opposite on
-- purpose -- centred, in front, focused, pressable -- because it is the thing
-- the player deliberately opened. A passive notice that could steal input and a
-- deliberate screen that could not would both be the wrong way round.
--
-- THE LIST IS ASKED FOR WHEN THE SCREEN OPENS AND NEVER CACHED. A contact list a
-- minute old is a list of rows that refuse: who is connected, who is already on
-- a call and who is close enough to hand a contact to are all facts with a
-- shelf life measured in seconds, and the server works every one of them out
-- with the SAME function that judges the invite itself.

-- The letter a configured key block names, or nil. The page prints it beside
-- the word that says what it does, so a rebind reaches the player.
local function keyLetter(block)
	local key = type(block) == 'table' and block.DEFAULT or nil
	if type(key) ~= 'string' or key == '' then return nil end
	return key
end

-- Whether the hologram is up, and the last roster the server sent for it.
local holoOpen = false
local roster = { rows = {}, recent = {}, onCall = false }

-- Pushes the hologram's own payload. Separate from `draw` because they are two
-- surfaces with two lifetimes: the card comes and goes with the call, this
-- comes and goes with the player's attention.
function drawHolo()
	publish({
		kind = 'holo',
		open = holoOpen,
		rows = roster.rows,
		recent = roster.recent,
		call = state.call,
		invite = state.invite,
		outgoing = state.outgoing,
		-- THE LETTERS THE SPHERE PRINTS. Read off the config rather than written
		-- into the page: a server that rebinds them must not have its players
		-- told the wrong key.
		-- WHERE IT SITS, settled once through the shared vocabulary. The page
		-- takes a name rather than a stylesheet: one word, nine values, refused
		-- and named in the journal when it is none of them.
		anchor = OPX.Anchors.Resolve(M.Settings.ANCHOR, 'bottom-center', 'calls.ANCHOR'),
		answerKey = keyLetter(M.Settings.ANSWER_KEY),
		declineKey = keyLetter(M.Settings.DECLINE_KEY),
	})
end

-- Takes a roster from the server and redraws, if the screen is still up. A
-- roster arriving after the player closed the screen is dropped rather than
-- stored: the next open asks again.
local function onRoster(payload)
	if type(payload) ~= 'table' then return end
	roster = {
		rows = type(payload.rows) == 'table' and payload.rows or {},
		recent = type(payload.recent) == 'table' and payload.recent or {},
		onCall = payload.onCall == true,
	}
	if holoOpen then drawHolo() end
end

--- Opens the hologram and asks for a fresh roster.
-- @author dop42
-- @return boolean
function M.OpenHolo()
	if holoOpen then return true end
	holoOpen = true
	-- Drawn before the roster arrives, with whatever the last one held. The
	-- screen must appear on the key press rather than on a round trip: a
	-- hologram that opens a beat after the key is a hologram that feels broken.
	drawHolo()
	TriggerServerEvent(M.Event.ASK_ROSTER)
	return true
end

--- Takes the hologram down.
-- @author dop42
-- @return boolean
function M.CloseHolo()
	if not holoOpen then return false end
	holoOpen = false
	drawHolo()
	return true
end

--- The key's verb, and the page's close button.
-- @author dop42
-- @return boolean
function M.ToggleHolo()
	if holoOpen then return M.CloseHolo() end
	return M.OpenHolo()
end

--- Whether the hologram is up. For a test, and for whatever asks next.
-- @author dop42
-- @return boolean
function M.HoloOpen()
	return holoOpen
end


--- Builds the state.
-- @author dop42
function M.Init()
	state = { call = nil, invite = nil, outgoing = nil }
	dismissed = nil
	cardUpMs = nil
	lastRingMs = -math.huge
	mutedEvents = {}
	holoOpen = false
	roster = { rows = {}, recent = {}, onCall = false }
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
		onRoster(payload)
	end)

	-- The ring is a scheduler job rather than a thread of its own: it has one
	-- comparison to make and a module that wants a tick has to justify it.
	jobs[#jobs + 1] = OPX.Scheduler.Every('calls:ring', 500, rearm)
	-- ── THE KEYS ─────────────────────────────────────────────────────────────
	-- One opens the projection; two answer a call without opening anything. All
	-- three are declared the same way and refused the same way, so the shape is
	-- written once.
	--
	-- `DEFAULT = false` switches one off for a server that binds it elsewhere,
	-- and there is then no way in by that route -- a configuration rather than a
	-- fault, so it is said once and not warned about.
	local function bind(block, fallbackId, fallbackName, press)
		local declared = type(block) == 'table' and block or {}
		local key = declared.DEFAULT
		if type(key) ~= 'string' or key == '' then
			Open77.log.info(('[calls] no key is configured for %s'):format(fallbackId))
			return
		end
		if type(RegisterKeyMapping) ~= 'function' then
			OPX.Note('calls', 'this host has no RegisterKeyMapping: the calls have no keys')
			return
		end
		-- TWO ANSWER SHAPES ARE DOCUMENTED for this host call -- the effective
		-- key, or `true` and the key -- and reading only one of them logged a
		-- working mapping as a failure everywhere else in this resource before
		-- it was written down. Both are accepted; anything else is reported.
		local called, ok, answer = pcall(RegisterKeyMapping,
			tostring(declared.ID or fallbackId),
			locale(declared.NAME or fallbackName), key, press)
		if not called then
			OPX.Note('calls', ('%s was not mapped: %s'):format(fallbackId, tostring(ok)))
		elseif ok == false or (ok == nil and answer == nil) then
			OPX.Note('calls', ('%s could not take %q: %s')
				:format(fallbackId, key, tostring(answer)))
		end
	end

	bind(M.Settings.KEY, 'opx.calls.holo', 'calls.key.holo',
		function() M.ToggleHolo() end)

	-- ANSWERING AND REFUSING DO NOTHING WHEN THERE IS NOTHING TO ANSWER, and
	-- that is what makes sharing a key with the hotbar peek and the emote stop
	-- survivable: outside a ringing call these handlers return immediately and
	-- the other feature is the only one that acted. `M.Accept` and `M.Decline`
	-- already answer false with no invite, so the guard is theirs and not a
	-- second copy of the same question.
	bind(M.Settings.ANSWER_KEY, 'opx.calls.answer', 'calls.key.answer',
		function() M.Accept() end)
	bind(M.Settings.DECLINE_KEY, 'opx.calls.decline', 'calls.key.decline',
		function() M.Decline() end)

	-- ESCAPE CLOSES IT, and it is not a key this module may bind. The pause
	-- plugin swallows Escape before any surface sees it and re-raises it under
	-- its own name --  answers the same broadcast the same way --
	-- so binding  here would be asking for a key the platform has already
	-- taken. Closing only when the projection is OPEN matters: the sphere pops
	-- unbidden while a call rings, and Escape must not answer a call.
	AddEventHandler(PAUSE_KEY, function()
		if holoOpen then M.CloseHolo() end
	end)

	-- THE ONE ROW ON THE EYE. `target` is optional to this module, so its absence
	-- is a runtime with no way to hand somebody a contact face to face rather
	-- than a fault: the calls themselves are all behind the key above.
	local eye = OPX.Api.Get('target')
	if eye == nil or type(eye.RegisterPlayers) ~= 'function' then
		Open77.log.info('[calls] this client has no target eye: contacts cannot be handed over')
	else
		CreateThread(function()
			local ok, failure = pcall(registerRows, eye)
			if not ok then OPX.Note('calls', 'the contact row: ' .. tostring(failure)) end
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
	-- THE HOLOGRAM GOES WITH THE MODULE. A screen left standing over a stopped
	-- owner is a set of buttons whose handler belongs to a VM that is no longer
	-- answering -- and this one holds focus, so it would also be a screen the
	-- player cannot close.
	holoOpen = false
	drawHolo()
	publish({ kind = 'state' })
end
