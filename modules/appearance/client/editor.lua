--- The two modal transactions: building a new face, and editing one.
-- @author dop42
--
-- The engine's own customization mirror is the only face editor there is: an
-- option is `{ part, name, value, choices }` where `name` is an opaque 64-bit
-- catalogue hash with no human label anywhere on the platform. So this file does
-- not draw a face editor, it opens one, and everything after the player confirms
-- -- the capture, the body check, the save -- belongs here again.

local M = OPX.Modules.Get('appearance')

local Snapshot = M.Snapshot
local State = M.Face
local Runtime = M.Runtime

M.Editor = {}
local Editor = M.Editor

-- Milliseconds an asked-for creation editor may stay unseen before a log line.
local CREATOR_UNSEEN_MS = 30000

-- Milliseconds between two passes, matching the watch that drives this file.
local WATCH_MS = 200

-- When the last captured face went out, in milliseconds.
local lastSaveAtMs = 0

-- A creation editor is being waited for or opened, when it was last asked for,
-- and whether it was then seen on screen.
local creatorOpening = false
local creatorAskedAtMs = 0
local creatorShown = false

-- Every code the server answers a face save with. A code outside this set is a
-- protocol drift worth one log line, and is handled like any other refusal.
local REFUSALS = {
	['appearance.invalid'] = true,
	['appearance.stale'] = true,
	['appearance.tooLarge'] = true,
	['error.badRequest'] = true,
	['error.notLoggedIn'] = true,
	['error.tooFast'] = true,
	['error.unavailable'] = true,
}

--- Releases the native transaction a moment later.
-- Not on this stack: the engine is still settling the face it has just accepted,
-- and releasing inside the confirmation loses it.
local function releaseSoon()
	CreateThread(function()
		Wait(250)
		Runtime.FinishMutation()
	end)
end

--- Puts the stored face back after an edit that did not land.
local function rollback(reason)
	Runtime.FinishMutation()
	if type(State.canonical) ~= 'table' then return end
	CreateThread(function()
		local ok, failure = Runtime.ApplySnapshot(State.canonical, 8, nil)
		if not ok then
			Runtime.Notify('error', 'appearance.rollbackFailed',
				{ reason = tostring(reason), failure = tostring(failure) })
		end
	end)
end

--- Sends a captured face to the server once its cooldown has passed.
-- The cooldown is WAITED OUT rather than tripped: a save refused for being early
-- is a save the player has to make again, and they cannot see that it failed.
-- @param kind string `edit` or `create`
local function send(payload, kind, onNotSent)
	State.commit = { kind = kind, deadlineMs = 0 }
	local citizen = State.citizenId
	local cooldown = M.ConfigMs(M.Settings.SAVE_COOLDOWN_MS) or 2000
	local commitMs = M.ConfigMs(M.Settings.COMMIT_MS) or 20000
	CreateThread(function()
		local idle = cooldown - (Runtime.NowMs() - lastSaveAtMs)
		if idle > 0 then Wait(idle) end
		if State.commit == nil then return end
		lastSaveAtMs = Runtime.NowMs()
		State.commit.deadlineMs = Runtime.NowMs() + commitMs
		local sent, reason = TriggerServerEvent(M.Event.SAVE_FACE,
			{ snapshot = payload, citizenId = citizen })
		if sent then return end
		State.commit = nil
		onNotSent(tostring(reason or 'not_sent'))
	end)
end

--- Ends a creation that stored nothing and settles on the default face.
-- Nobody is ever left unable to enter: the character exists either way, only its
-- face does not. It is not reopened for this character again this session, or it
-- would come straight back up on top of somebody standing in the city.
local function enterPristine(reason)
	State.creating = false
	State.creatorUp = false
	State.commit = nil
	State.creationRefused = true
	Runtime.Publish({ ok = false, event = 'created', error = tostring(reason),
		citizenId = State.citizenId })
	Runtime.Notify('error', 'appearance.creationNotSaved', { reason = tostring(reason) })
	Runtime.BeginPristine('creation_ended')
end

--- Opens the creation editor on the character's own body, reloading it first.
local function openCreator()
	State.creating = true
	if creatorOpening or State.creatorUp then return end
	creatorOpening = true
	local citizen = State.citizenId
	CreateThread(function()
		while not Runtime.Faceable() or Runtime.IsDown() do
			-- The captured citizen id is what ends this wait: a character change
			-- must not open a creator for the one that left.
			if not State.creating or State.citizenId ~= citizen then
				creatorOpening = false
				return
			end
			Wait(WATCH_MS)
		end
		creatorOpening = false
		if not State.creating or State.creatorUp or State.citizenId ~= citizen then return end

		local family = M.IsFamily(State.family) and State.family or nil
		if family ~= nil and Runtime.BodyFamily() ~= family then
			if State.familyAttempts >= (tonumber(M.Settings.FAMILY_RETRIES) or 2) then
				return enterPristine('body_family_mismatch')
			end
			local outcome, reason = Runtime.SwitchBody(family, true)
			if outcome == 'switching' then
				State.familyAttempts = State.familyAttempts + 1
				return Runtime.Notify('info', 'appearance.creatorSwitching')
			end
			if outcome == nil then
				Runtime.Notify('error', 'appearance.bodyChangeFailed', { reason = tostring(reason) })
				return enterPristine('body_family_mismatch')
			end
		end

		local opened, reason = Open77.appearance.open({ mode = 'ripperdoc', gender = family })
		if opened then
			State.creatorUp = true
			creatorAskedAtMs, creatorShown = Runtime.NowMs(), false
			Open77.log.info(('[appearance] creation editor asked for on the %s body')
				:format(tostring(family)))
			return
		end
		Runtime.Notify('error', 'appearance.creatorUnavailable', { reason = tostring(reason) })
		enterPristine('character_creator_unavailable')
	end)
end

--- Answers `needsCreation` by opening the creation editor for the live character.
-- @author dop42
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Creator()
	if Runtime.IsDown() then return false, 'player_down' end
	if State.citizenId == nil then return false, 'no_character' end
	if State.creating then return false, 'appearance_busy' end
	if State.editing or Runtime.ModalOnScreen() then return false, 'appearance_busy' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.creationRefused then return false, 'creation_refused' end
	if type(State.canonical) == 'table' then return false, 'already_has_a_face' end
	State.creationAskedAtMs = 0
	openCreator()
	return true
end

--- Completes a creation whose face the server stored.
-- @author dop42
function M.Editor.FinishCreation()
	State.creating = false
	State.creatorUp = false
	State.Wore()
	Runtime.Publish({ ok = true, event = 'created', citizenId = State.citizenId })
	Runtime.Notify('success', 'appearance.created')
	Runtime.Announce()
end

--- Checks the body, captures the creation and sends it to the server.
local function confirmCreation()
	State.creatorUp = false

	-- The body they built on has to be the body their character is: the family is
	-- the character's, and nothing here may change it.
	local family = Runtime.BodyFamily()
	if M.IsFamily(State.family) and family ~= nil and family ~= State.family then
		Runtime.FinishMutation()
		State.familyAttempts = State.familyAttempts + 1
		if State.familyAttempts > (tonumber(M.Settings.FAMILY_RETRIES) or 2) then
			return enterPristine('body_family_mismatch')
		end
		Runtime.Notify('warning', 'appearance.wrongBody',
			{ family = Runtime.FamilyText(State.family) })
		return openCreator()
	end

	local payload, why = Snapshot.Capture()
	if payload == nil then
		Runtime.FinishMutation()
		return enterPristine(tostring(why or 'character_capture_failed'))
	end

	send(payload, 'create', function(reason)
		Runtime.FinishMutation()
		enterPristine(reason)
	end)
end

--- Asks the server to store a face, by default a capture.
-- @author dop42
-- @param snapshot table|nil
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Save(snapshot)
	if State.citizenId == nil then return false, 'no_character' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.editing or State.creating then return false, 'appearance_busy' end

	local payload, reason
	if snapshot == nil then
		payload, reason = Snapshot.Capture()
	else
		payload, reason = Snapshot.ForNetwork(snapshot)
	end
	if payload == nil then return false, tostring(reason or 'capture_failed') end
	if not M.BuildAccepted(payload.gameBuild) then
		return false, 'stored_build_mismatch'
	end

	-- A save that changes nothing is completed here: the server writes nothing and
	-- publishes nothing for a face identical to the stored one, so waiting for an
	-- answer would time out on a correct save.
	if Snapshot.Same(payload, State.canonical) then
		-- Deferred, so the caller learns the save was accepted before anything can
		-- act on the decision it raises.
		CreateThread(function()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId,
				unchanged = true })
		end)
		return true
	end

	send(payload, 'edit', function(failure)
		Runtime.Publish({ ok = false, event = 'saved', error = failure,
			citizenId = State.citizenId })
		Runtime.Notify('error', 'appearance.saveFailed', { reason = failure })
	end)
	return true
end

--- Asks for the native face editor on the live character.
-- @author dop42
-- @param mode string `ripperdoc` or `hairdresser`
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Open(mode)
	mode = tostring(mode or 'ripperdoc'):lower()
	if mode ~= 'ripperdoc' and mode ~= 'hairdresser' then return false, 'invalid_mode' end
	if Runtime.IsDown() then return false, 'player_down' end
	if State.creating then return false, 'character_creation_in_progress' end
	if State.editing or Runtime.ModalOnScreen() then return false, 'appearance_busy' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.citizenId == nil then return false, 'no_character' end

	if type(State.canonical) ~= 'table' or not M.BuildAccepted(State.canonical.gameBuild) then
		Runtime.Notify('warning', 'appearance.editorDefaultFace')
	end

	-- No gender is ever passed here: `openEditor` must not be able to change a
	-- character's body family, which belongs to the character row.
	State.editing = true
	CreateThread(function()
		if Runtime.IsDown() then
			State.editing = false
			return
		end
		local opened, reason = Open77.appearance.open({ mode = mode })
		if opened then return end
		State.editing = false
		Runtime.Notify('error', 'appearance.editorUnavailable', { reason = tostring(reason) })
	end)
	return true
end

--- Whether a creation is waiting for an editor nothing is opening.
local function creationStalled()
	return State.creating and not State.creatorUp and not creatorOpening and State.commit == nil
end

--- Picks up what a body-family reload answered on its other side.
local function resumeFamilyTransition()
	local result = Open77.appearance.takeBodyFamilyTransition()
	if type(result) ~= 'string' or result == '' then return false end
	local action, family = result:match('^([^:]+):(.+)$')
	if action == 'error' then
		Runtime.Notify('error', 'appearance.bodyChangeFailed', { reason = tostring(family) })
		State.bodyReloading = false
		Runtime.LiftCover('body_family_transition_error')
		Runtime.MarkWorldEligibility('body_family_transition_error')
		if creationStalled() then return enterPristine('body_family_mismatch') end
		State.settled = false
		Runtime.ResolveCharacter('body_family_transition_error')
		return true
	end
	if action ~= 'edit' then
		Open77.log.debug('[appearance] body family transition: ' .. result)
		return true
	end
	if not M.IsFamily(family) then
		Runtime.Notify('error', 'appearance.bodyChangeInvalid')
		return true
	end
	Open77.log.info(('[appearance] body family transition answered %s'):format(result))
	if creationStalled() then openCreator() end
	return true
end

--- One pass over creations, family transitions and save deadlines.
-- @author dop42
--
-- Driven by the scheduler rather than a thread of its own: exceeding the
-- per-resume instruction budget unwinds out of a coroutine body, and a
-- `while true` loop that hits it is never resumed again, silently -- which here
-- would mean a body reload nobody ends and a gate nobody opens.
function M.Editor.Watch()
	Runtime.WarnUnanswered()
	resumeFamilyTransition()

	if creationStalled() and Runtime.Faceable() then openCreator() end

	if State.creatorUp and creatorAskedAtMs ~= 0 and not creatorShown then
		local waited = Runtime.NowMs() - creatorAskedAtMs
		if Runtime.ModalOnScreen() then
			creatorShown = true
		elseif waited >= CREATOR_UNSEEN_MS then
			creatorShown = true
			Open77.log.warn(('[appearance] the creation editor asked for %d ms ago is not on ' ..
				'screen: reset=%s life=%s'):format(waited, tostring(Runtime.PlayerResetPhase()),
					tostring(Runtime.LifePhase())))
		end
	end

	local pending = State.commit
	if pending ~= nil and pending.deadlineMs > 0 and Runtime.NowMs() >= pending.deadlineMs then
		State.commit = nil
		if pending.kind == 'create' then
			Runtime.FinishMutation()
			enterPristine('save_timeout')
		else
			rollback('save_timeout')
			Runtime.Notify('error', 'appearance.saveTimedOut')
		end
	end
end

--- Registers the modal and save handlers.
-- @author dop42
function M.Editor.Wire()
	AddEventHandler(M.HostEvent.CONFIRMED, function()
		if State.creatorUp then return confirmCreation() end
		if not State.editing then
			-- Not a player confirming anything: the mirror acknowledging the
			-- restore this world entry queued, which is what the announcement
			-- has been waiting on.
			if State.bootstrapToken == State.restoreToken and State.bootstrapQueued then
				State.appearanceConfirmed = true
				Runtime.Announce()
			else
				Runtime.FinishMutation()
			end
			return
		end
		State.editing = false

		local payload, why = Snapshot.Capture()
		if payload == nil then
			why = tostring(why or 'capture_failed')
			rollback(why)
			return Runtime.Notify('error', 'appearance.captureFailed', { reason = why })
		end

		if Snapshot.Same(payload, State.canonical) then
			State.Wore()
			releaseSoon()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId,
				unchanged = true })
			return Runtime.Notify('success', 'appearance.saved')
		end

		send(payload, 'edit', function(reason)
			rollback(reason)
			Runtime.Notify('error', 'appearance.saveFailed', { reason = reason })
		end)
	end)

	AddEventHandler(M.HostEvent.CANCELLED, function()
		local creation = State.creatorUp
		State.editing = false
		State.creatorUp = false
		Runtime.FinishMutation()
		if creation then enterPristine('character_creation_cancelled') end
	end)

	RegisterNetEvent(M.Event.FACE_SAVED, function(snapshot)
		if type(snapshot) ~= 'table' then return end
		local pending = State.commit
		State.commit = nil
		State.canonical = snapshot

		if pending ~= nil and pending.kind == 'create' then return Editor.FinishCreation() end
		if pending ~= nil then
			State.Wore()
			releaseSoon()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId })
			Runtime.Notify('success', 'appearance.saved')
			return
		end

		-- Nothing pending: this face was stored somewhere else, so it is put on.
		Runtime.BeginRestore(snapshot, 'server')
	end)

end

--- Ends the pending face save the server refused.
-- @author dop42
--
-- Only a refusal naming a FACE save is this one's: an `error.tooFast` raised by a
-- clothing save, or by anything else, is left alone rather than taken for the
-- answer to a capture still in flight. The server already toasted this code
-- through the runtime's refusal channel, which guarantees it is in the catalogue,
-- so nothing is said here twice.
-- @param code string
-- @param operation string
function M.Editor.OnRefused(code, operation)
	local pending = State.commit
	if pending == nil or operation ~= M.Operation.SAVE_FACE then return end
	code = tostring(code)
	if not REFUSALS[code] then
		Open77.log.warn(('[appearance] a face save was refused with an unlisted code: %s')
			:format(code))
	end
	State.commit = nil
	if pending.kind == 'create' then return enterPristine(code) end
	Runtime.Publish({ ok = false, event = 'saved', error = code, citizenId = State.citizenId })
	rollback(code)
end
