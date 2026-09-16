--- The join bootstrap, the body the world loads with, the restore, and the one
--- announcement that lets anybody into the world.
-- @author dop42
--
-- `open77:session:gameplayReady` is the only thing that clears the platform's
-- `__platform` hold, and `M.Runtime.Announce` is the only thing that sends it.
-- Everything else in this file exists to decide when that is honest: a loaded
-- character, on its own body, with its face settled, on a puppet that is really
-- attached and alive in the gameplay world.
--
-- THE WORLD COMES FIRST. The platform's loading cover stays up until the
-- one-shot character bootstrap is spent, and nothing drawn by a resource shows
-- through it -- so the bootstrap is spent at join, before any character is
-- chosen, and the roster, the identity form and the face editor all happen in the
-- gameplay world afterwards.

local M = OPX.Modules.Get('appearance')

local Snapshot = M.Snapshot
local State = M.Face

M.Runtime = {}
local Runtime = M.Runtime

local HostEvent = M.HostEvent

-- The character module's own local bus.
local EVENT_CHARACTER_LOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded')
local EVENT_CHARACTER_UNLOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded')
local EVENT_CHARACTER_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'character', 'changed')
local EVENT_CHARACTER_ROSTER = OPX.Event(OPX.Channel.LOCAL, 'character', 'roster')

-- The downed module's own local bus. Optional: with it stopped nobody is down.
local EVENT_DOWNED_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Milliseconds between two looks at a world a face may go on, and between two
-- reads of the roster the character module already holds.
local WATCH_MS = 200
local ROSTER_POLL_MS = 250

-- Shipped values, for a configuration that lost one.
local ROSTER_WAIT_MS = 3000
local DEFAULT_FAMILY = 'female'
local RELOAD_SETTLE_MS = 10000

-- Life phases a native modal may go up in.
local LIFE_OPEN = { alive = true, recovering = true }

-- Apply refusals that mean 'not yet', retried after a short wait.
local RETRYABLE = {
	options_unavailable = true,
	player_unavailable = true,
	customization_state_unavailable = true,
}

-- The body family this client last loaded the world with, whether the host's
-- reset projection has left `complete` since a switch, and until when a finished
-- reload holds modals back (0 when none).
local loadedFamily = nil
local reloadResetSeen = false
local reloadSettleUntilMs = 0

-- This client spent the one-shot character bootstrap, and the join-time roster
-- wait that picks its body is running.
local bootstrapResolved = false
local bootstrapPicking = false

-- The roster the character module last broadcast, nil until one arrives.
local rosterSeen = nil

-- Whether the downed module says the player is down, and how many of its events
-- have been heard, so a stale catch-up answer is dropped.
local down = false
local downHeard = 0

-- Set once at Start when the native appearance API is not on this client.
local unavailable = false

-- The last finite clock reading in milliseconds, held across a failed read.
local lastMs = 0

--- Monotonic milliseconds, holding the last finite reading.
-- Not `OPX.Now` directly: that one is unguarded, and a raised clock read inside a
-- restore thread would end the restore -- and with it this world entry's
-- announcement -- for the rest of the session.
local function nowMs()
	local read, value = pcall(OPX.Now)
	if read and OPX.Math.IsFinite(value) and value >= 0 then lastMs = math.floor(value) end
	return lastMs
end
M.Runtime.NowMs = nowMs

--- Raises one of this module's decisions on its public client bus.
-- @author dop42
-- @param payload table carries `event`, `ok` and usually `citizenId`
function M.Runtime.Publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

--- Tells the player something, in their own language.
-- @author dop42
-- @param kind string info, success, warning or error
-- @param key string a catalogue key
-- @param params table|nil
function M.Runtime.Notify(kind, key, params)
	Open77.log.info(('[appearance] notify %s: %s'):format(kind, key))
	OPX.Toast.Locale(key, params, kind)
end

--- The player-facing name of a body family.
-- @author dop42
-- @param family any
-- @return string
function M.Runtime.FamilyText(family)
	if family == 'female' then return locale('appearance.familyFemale') end
	if family == 'male' then return locale('appearance.familyMale') end
	return tostring(family)
end

--- Whether the local puppet is attached, alive and above zero health.
-- @author dop42
-- @return boolean
function M.Runtime.InGameplay()
	local ok, character = pcall(Open77.character.state)
	return ok and type(character) == 'table' and character.attached == true and
		character.alive == true and (tonumber(character.health) or 0) > 0
end
local inGameplay = Runtime.InGameplay

--- The host's character bootstrap projection, nil when it cannot be read.
local function readBootstrap()
	local ok, bootstrap = pcall(Open77.session.characterBootstrap)
	return ok and type(bootstrap) == 'table' and bootstrap or nil
end

--- The host's character bootstrap phase, or `unreadable`.
local function bootstrapPhase()
	local bootstrap = readBootstrap()
	return bootstrap and tostring(bootstrap.phase) or 'unreadable'
end

--- The host's pristine player reset phase, nil where none is projected.
-- @author dop42
-- @return string|nil
function M.Runtime.PlayerResetPhase()
	local bootstrap = readBootstrap()
	if bootstrap == nil or bootstrap.playerReset == nil then return nil end
	return tostring(bootstrap.playerReset)
end
local playerResetPhase = Runtime.PlayerResetPhase

-- The life state was found unreadable and said so once.
local lifeUnreadable = false

--- The local life phase, false without one, nil when it cannot be read.
-- A phase that cannot be read at all answers nil and faces go on without waiting
-- for it: refusing for ever would be worse than a face applied a moment early.
-- @author dop42
-- @return string|false|nil
function M.Runtime.LifePhase()
	if lifeUnreadable then return nil end
	local players = Open77.players
	local called, life, reason = false, nil, 'Open77.players.getLifeState is not on this client'
	if type(players) == 'table' and type(players.getLifeState) == 'function' then
		called, life, reason = pcall(players.getLifeState)
	end
	if called and type(life) == 'table' then return tostring(life.phase) end
	if called and not tostring(reason or ''):find('permission', 1, true) then return false end
	lifeUnreadable = true
	Open77.log.warn(('[appearance] the life state cannot be read (%s): faces go on without ' ..
		'waiting for it'):format(tostring(called and reason or life or reason)))
	return nil
end
local lifePhase = Runtime.LifePhase

--- BODY_RELOAD_SETTLE_MS, or the shipped value for an unusable one.
local function reloadSettleMs()
	return M.ConfigMs(M.Settings.BODY_RELOAD_SETTLE_MS) or RELOAD_SETTLE_MS
end

--- Whether a face or a native modal may go on the puppet now.
-- @author dop42
--
-- `InGameplay` alone is not enough: `attached` is true for the pre-game menu's
-- puppet too, and a face applied before the pristine reset arms a native watchdog
-- that ends in a user-facing error on a perfectly correct face.
-- @return boolean
function M.Runtime.Faceable()
	if not State.worldEligible or State.bodyReloading or not inGameplay() then return false end
	local reset = playerResetPhase()
	if reset ~= nil and reset ~= 'complete' then return false end
	local life = lifePhase()
	if life == false or (life ~= nil and not LIFE_OPEN[life]) then return false end
	if reloadSettleUntilMs ~= 0 then
		-- After a reload the platform replays the character's placement onto the
		-- new puppet: a respawn with a grace window, which has to end first.
		if life ~= nil and life ~= 'alive' and nowMs() < reloadSettleUntilMs then
			return false
		end
		reloadSettleUntilMs = 0
	end
	return true
end
local faceable = Runtime.Faceable

--- Judges from the bootstrap phase whether this is the gameplay world.
-- Called only from world-entry events: polling would read `ready` too early.
-- @author dop42
-- @param reason string
function M.Runtime.MarkWorldEligibility(reason)
	local phase = bootstrapPhase()
	State.worldEligible = phase == 'ready'
	Open77.log.debug(('[appearance] world entry (%s): bootstrap phase=%s -> %s'):format(reason,
		phase, State.worldEligible and 'gameplay world' or 'menu, not announcing'))
end
local markWorldEligibility = Runtime.MarkWorldEligibility

--- Whether a native appearance modal is on screen. A raise counts as 'up'.
-- @author dop42
-- @return boolean
function M.Runtime.ModalOnScreen()
	local read, open = pcall(Open77.appearance.isOpen)
	return not read or open == true
end

--- Releases the native appearance mutation transaction.
-- @author dop42
function M.Runtime.FinishMutation()
	local ok, reason = Open77.appearance.finishCommit()
	if not ok then Open77.log.debug('[appearance] finishCommit: ' .. tostring(reason)) end
end

--- The body family, from the engine, from this client, or from the bootstrap.
-- @author dop42
-- @return string|nil
function M.Runtime.BodyFamily()
	local read, body = pcall(Open77.appearance.captureBody)
	if read and type(body) == 'table' and M.IsFamily(body.family) then
		return body.family
	end
	if loadedFamily ~= nil then return loadedFamily end
	local bootstrap = readBootstrap()
	if bootstrap and bootstrap.phase == 'ready' and M.IsFamily(bootstrap.family) then
		return bootstrap.family
	end
	return nil
end

--- Whether the downed module says the local player is down.
-- @author dop42
-- @return boolean
function M.Runtime.IsDown()
	return down
end

--- Asks the engine to reload the player on a body family.
-- @author dop42
-- @param family string
-- @param edit boolean an editor reopens after the reload
-- @return string|nil `switching` or `active`
-- @return string|nil the failure
function M.Runtime.SwitchBody(family, edit)
	local called, switched, reason = pcall(Open77.appearance.switchBodyFamily, family, edit)
	if not called then return nil, tostring(switched) end
	if switched then
		loadedFamily = family
		State.bodyReloading = true
		reloadResetSeen = false
		reloadSettleUntilMs = 0
		State.Undress()
		-- The body goes away first, so observers drop their proxy rather than
		-- keeping the old one until the new body is published.
		if M.Presence then M.Presence.Withdraw() end
		Open77.log.info(('[appearance] the %s body is reloading (%s)'):format(family,
			edit and 'an editor reopens after it' or 'for the character'))
		return 'switching'
	end
	-- Already on it counts as done.
	if tostring(reason) == 'body_family_already_active' then
		loadedFamily = family
		return 'active'
	end
	return nil, tostring(reason or 'body_family_switch_failed')
end

--- Asks the shell to take down the cover a body reload put up.
-- A known platform issue: nothing else takes that cover down after a covered
-- transition, and a player left behind it sees nothing at all.
-- @author dop42
-- @param origin string
function M.Runtime.LiftCover(origin)
	Open77.log.info(('[appearance] lifting the loading cover of the body reload (%s)')
		:format(origin))
	TriggerEvent(HostEvent.SHELL_HIDE)
end

--- Ends a body reload once its new puppet has been reset.
-- @author dop42
--
-- A reload attaches the world TWICE -- a covered return to the pre-game menu,
-- then the target save -- and both raise world-ready with a puppet that answers
-- attached and alive. Neither says the reload is over: only the new puppet's
-- pristine reset does.
-- @param origin string
function M.Runtime.FinishReload(origin)
	if not State.bodyReloading then return end
	State.bodyReloading = false
	reloadResetSeen = false
	reloadSettleUntilMs = nowMs() + reloadSettleMs()
	Open77.log.info(('[appearance] the body reload reached its new puppet (%s)'):format(origin))
	Runtime.LiftCover(origin)
	State.EnterWorld()
	State.playerResetDone = true
	markWorldEligibility(origin)
	Runtime.ResolveCharacter('body_reload')
end

--- Follows a body reload through the host's reset projection.
-- @author dop42
function M.Runtime.WatchReload()
	if not State.bodyReloading then return end
	local reset = playerResetPhase()
	if reset == nil then return end
	if reset ~= 'complete' then
		reloadResetSeen = true
	elseif reloadResetSeen then
		Runtime.FinishReload('reset_projection')
	end
end

--- Reloads onto the character's body family, within FAMILY_RETRIES.
local function reloadOntoFamily()
	if not M.IsFamily(State.family) then return false end
	if State.familyAttempts >= (tonumber(M.Settings.FAMILY_RETRIES) or 2) then
		if Runtime.BodyFamily() ~= nil then
			Runtime.Notify('error', 'appearance.bodyLoadFailed', { reason = 'body_family_retries' })
		end
		return false
	end
	local outcome, reason = Runtime.SwitchBody(State.family, false)
	if outcome == 'switching' then
		State.familyAttempts = State.familyAttempts + 1
		Runtime.Notify('info', 'appearance.bodySwitching')
		return true
	end
	if outcome == nil then
		Runtime.Notify('error', 'appearance.bodyLoadFailed', { reason = tostring(reason) })
	end
	return false
end
M.Runtime.ReloadOntoFamily = reloadOntoFamily

--- Puts the puppet on the character's body family before a face goes on.
-- Answers false when a reload started, so the caller stops: the restore runs
-- again on the other side of it.
local function ensureFamily()
	if not M.IsFamily(State.family) or Runtime.BodyFamily() == State.family then
		return true
	end
	return not reloadOntoFamily()
end

--- Sends `open77:session:gameplayReady`, once per settled gameplay world entry.
-- @author dop42
--
-- THIS IS THE ONE THING THAT LETS ANYBODY PLAY. Every joining player carries a
-- `__platform` hold on the readiness gate that no Lua can take or release and
-- that has no deadline; this announcement is the only thing that clears it.
-- Nothing below it may be relaxed:
--   * `worldEligible` -- the gameplay world, never the pre-game menu
--   * `AppearanceSettled` -- a loaded character whose face is decided, which is
--     also false while a creation editor is open, so a player deliberating for an
--     hour holds their own gate for an hour and nobody else's
--   * `InGameplay` -- a puppet really attached and alive
-- @return boolean whether it went out on this call
function M.Runtime.Announce()
	if State.gameplayAnnounced or not State.worldEligible then return false end
	if not State.AppearanceSettled() or not inGameplay() then return false end

	local sent, reason = TriggerServerEvent(OPX.Host.GAMEPLAY_READY)
	if not sent then
		Open77.log.warn('[appearance] gameplay-ready not sent: ' .. tostring(reason))
		return false
	end

	State.gameplayAnnounced = true
	Runtime.FinishMutation()
	Runtime.Publish({ ok = true, event = 'gameplayReady', citizenId = State.citizenId })
	Open77.log.info('[appearance] gameplay-ready announced; the platform hold can clear')
	return true
end

--- Applies a snapshot from a coroutine, retrying the refusals that mean not yet.
-- @author dop42
-- @param snapshot table
-- @param attempts integer
-- @param token integer|nil the restore generation, nil when none is owned
-- @return boolean
-- @return string|nil the failure
function M.Runtime.ApplySnapshot(snapshot, attempts, token)
	if type(snapshot) ~= 'table' then return false, 'invalid_snapshot' end
	for attempt = 1, attempts do
		if token ~= nil and not State.Current(token) then return false, 'superseded' end
		local ok, reason = Open77.appearance.apply(snapshot)
		if ok then return true end
		if not RETRYABLE[tostring(reason)] or attempt >= attempts then return false, reason end
		Wait(400)
	end
	return false, 'restore_timeout'
end
local applySnapshot = Runtime.ApplySnapshot

--- Waits for a faceable puppet, answering false once the generation is stale.
-- There is no deadline on purpose: a player building a face for an hour is a
-- correct state, and the token is what ends this wait.
local function awaitWorld(token, label)
	local waitedFrom, said = nowMs(), false
	while not faceable() do
		if not State.Current(token) then return false end
		if not said and nowMs() - waitedFrom > 60000 then
			said = true
			Open77.log.warn(('[appearance] %s token=%d is still waiting: eligible=%s reloading=%s ' ..
				'gameplay=%s reset=%s life=%s'):format(label, token, tostring(State.worldEligible),
					tostring(State.bodyReloading), tostring(inGameplay()), tostring(playerResetPhase()),
					tostring(lifePhase())))
		end
		Wait(WATCH_MS)
	end
	return State.Current(token)
end

--- Restores the stored face on the right body, once the puppet can take one.
-- @author dop42
-- @param snapshot table
-- @param origin string
function M.Runtime.BeginRestore(snapshot, origin)
	State.canonical = snapshot
	local token = State.NextRestore()

	if State.Wearing() then
		State.restoreSettledToken = token
		Open77.log.debug(('[appearance] restore skipped for %s: already worn')
			:format(tostring(State.citizenId)))
		return
	end

	Open77.log.debug(('[appearance] restore token=%d origin=%s'):format(token, origin))

	CreateThread(function()
		if not awaitWorld(token, 'restore') then return end
		if not ensureFamily() then return end

		local ok, reason = applySnapshot(State.canonical, 20, token)
		if not State.Current(token) then return end

		State.restoreSettledToken = token
		if ok then
			State.Wore()
			State.bootstrapQueued = true
			Runtime.Publish({ ok = true, event = 'restored', citizenId = State.citizenId })
			Runtime.Announce()
			return
		end

		Runtime.FinishMutation()
		if tostring(reason) == 'body_gender_switch_requires_reload' and reloadOntoFamily() then
			return
		end

		-- A failed restore is still a settled one: the player is let in on the
		-- pristine face rather than held behind the gate.
		Runtime.Publish({ ok = false, event = 'restored', error = tostring(reason),
			citizenId = State.citizenId })
		Runtime.Notify('error', 'appearance.restoreFailed', { reason = tostring(reason) })
		Runtime.Announce()
	end)
end

--- Settles a world entry on the default face of the character's own body.
-- @author dop42
-- @param origin string
function M.Runtime.BeginPristine(origin)
	local token = State.NextRestore()
	Open77.log.debug(('[appearance] pristine token=%d origin=%s'):format(token, origin))
	CreateThread(function()
		if not awaitWorld(token, 'pristine') then return end
		if not ensureFamily() then return end
		State.restoreSettledToken = token
		Runtime.Announce()
	end)
end

--- Spends the one-shot character bootstrap on a body family.
-- @author dop42
-- @param family any
-- @return boolean
function M.Runtime.ResolveBootstrap(family)
	if bootstrapResolved then return true end
	if bootstrapPhase() == 'ready' then
		bootstrapResolved = true
		return true
	end
	if not M.IsFamily(family) then
		Open77.session.failCharacterBootstrap('invalid_body_family')
		return false
	end
	local resolved, reason = Open77.session.resolveCharacterBootstrap(family)
	if not resolved then
		Open77.session.failCharacterBootstrap(tostring(reason or 'character_bootstrap_failed'))
		Runtime.Notify('error', 'appearance.bootstrapFailed', { reason = tostring(reason) })
		return false
	end
	bootstrapResolved = true
	loadedFamily = family
	Open77.log.info(('[appearance] character bootstrap resolved as %s'):format(family))
	return true
end

--- The roster the character module already holds, nil while it holds none.
-- Read from what it broadcast, or from its contract -- never REQUESTED: roster
-- requests are cooled at 2000 ms and the excess is dropped, so asking would cost
-- the announce its own answer.
local function heldRoster()
	if rosterSeen ~= nil then return rosterSeen end
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetCharacters) ~= 'function' then return nil end
	local roster = api.GetCharacters()
	if type(roster) ~= 'table' or type(roster.list) ~= 'table' then return nil end
	-- Zero characters WITH slots is a real empty roster; zero of both is the
	-- mirror answering before anything arrived.
	if #roster.list == 0 and (tonumber(roster.slots) or 0) <= 0 then return nil end
	return roster.list
end

--- The body family of the most recently played character.
-- Only two timestamps of the same comparable type are compared: the roster
-- already arrives newest first, and this keeps that order rather than inventing
-- one across types.
local function lastPlayedFamily(characters)
	local family, latest
	for index = 1, #characters do
		local summary = characters[index]
		local at = type(summary) == 'table' and summary.lastLoggedOut or nil
		if at ~= nil and M.IsFamily(summary.gender) then
			local comparable = type(at) == type(latest) and
				(type(at) == 'string' or type(at) == 'number')
			if latest == nil or (comparable and at > latest) then
				family, latest = summary.gender, at
			end
		end
	end
	return family
end

--- BOOTSTRAP.DEFAULT_FAMILY, or female with one log line.
local function defaultFamily()
	local bootstrap = type(M.Settings.BOOTSTRAP) == 'table' and M.Settings.BOOTSTRAP or {}
	if M.IsFamily(bootstrap.DEFAULT_FAMILY) then return bootstrap.DEFAULT_FAMILY end
	Open77.log.warn(('[appearance] BOOTSTRAP.DEFAULT_FAMILY %s is not "female" or "male"; ' ..
		'loading %q'):format(tostring(bootstrap.DEFAULT_FAMILY), DEFAULT_FAMILY))
	return DEFAULT_FAMILY
end

--- BOOTSTRAP.ROSTER_WAIT_MS, or the shipped value with one log line.
local function rosterWaitMs()
	local bootstrap = type(M.Settings.BOOTSTRAP) == 'table' and M.Settings.BOOTSTRAP or {}
	local wait = M.ConfigMs(bootstrap.ROSTER_WAIT_MS)
	if wait == nil then
		Open77.log.warn(('[appearance] BOOTSTRAP.ROSTER_WAIT_MS %s is not a number of ms; ' ..
			'waiting %d'):format(tostring(bootstrap.ROSTER_WAIT_MS), ROSTER_WAIT_MS))
		return ROSTER_WAIT_MS
	end
	return wait
end

--- Spends the join bootstrap on the last played body, or on the default.
-- @author dop42
-- @param origin string
function M.Runtime.BeginBootstrap(origin)
	if bootstrapResolved or bootstrapPicking then return end
	if bootstrapPhase() ~= 'waiting' then return end
	bootstrapPicking = true

	CreateThread(function()
		local deadline = nowMs() + rosterWaitMs()
		local roster
		while roster == nil and nowMs() < deadline do
			if bootstrapResolved or bootstrapPhase() ~= 'waiting' then break end
			roster = heldRoster()
			if roster == nil then Wait(ROSTER_POLL_MS) end
		end
		bootstrapPicking = false
		if bootstrapResolved or bootstrapPhase() ~= 'waiting' then return end

		local family = roster ~= nil and lastPlayedFamily(roster) or nil
		local why = family ~= nil and 'the last character played' or
			(roster ~= nil and 'no character played yet' or 'no roster in time')
		family = family or defaultFamily()
		Open77.log.info(('[appearance] bootstrap (%s): loading the %s body, %s')
			:format(origin, family, why))
		Runtime.ResolveBootstrap(family)
	end)
end

--- Restores, asks for a creation, or settles on the default face.
-- @author dop42
-- @param origin string
function M.Runtime.ResolveCharacter(origin)
	if State.citizenId == nil then return end
	local stored = State.canonical

	-- A loaded character has the better claim on the body than the join guess did.
	if M.IsFamily(State.family) then Runtime.ResolveBootstrap(State.family) end
	State.settled = true

	if type(stored) == 'table' and not M.BuildAccepted(stored.gameBuild) then
		Runtime.Publish({ ok = false, event = 'settled', error = 'stored_build_mismatch',
			citizenId = State.citizenId })
		if not State.buildWarned then
			State.buildWarned = true
			Runtime.Notify('warning', 'appearance.buildMismatch')
		end
		Runtime.BeginPristine(origin)
		return
	end

	if type(stored) == 'table' then
		State.restoreAttempts = 0
		Runtime.BeginRestore(stored, origin)
		return
	end

	if State.creating then return end
	if State.creationAskedAtMs ~= 0 then return end

	-- This module never opens the creator itself: it says a character needs one
	-- and waits. Whoever draws the creation flow answers by calling `OpenCreator`.
	if not State.creationRefused and not State.creationWarned then
		State.creationAskedAtMs = nowMs()
		Runtime.Publish({ ok = true, event = 'needsCreation', citizenId = State.citizenId,
			family = State.family })
		return
	end

	Runtime.BeginPristine(origin)
end

--- Lets the player in on the default face when nobody answered needsCreation.
-- @author dop42
function M.Runtime.WarnUnanswered()
	if State.creationAskedAtMs == 0 or State.creating or State.creationWarned then return end
	local wait = M.ConfigMs(M.Settings.CREATION_WAIT_MS) or 15000
	if nowMs() - State.creationAskedAtMs < wait then return end
	State.creationWarned = true
	State.creationAskedAtMs = 0
	Open77.log.warn(('[appearance] %s has no stored face and nothing answered `needsCreation`')
		:format(tostring(State.citizenId)))
	Open77.log.warn('  the player enters on the default face; something has to call the ' ..
		'`OpenCreator` contract function to open the editor.')
	Runtime.BeginPristine('creation_unanswered')
end

-- ── the live character ───────────────────────────────────────────────────────

--- Adopts a new live character, its body family, face and clothing.
local function adoptCharacter(playerData, origin)
	if type(playerData) ~= 'table' then return end
	local citizen = playerData.citizenId
	if type(citizen) ~= 'string' or citizen == '' then return end
	if citizen == State.citizenId then return end

	local switching = State.citizenId ~= nil
	State.citizenId = citizen
	State.family = type(playerData.charInfo) == 'table' and playerData.charInfo.gender or nil
	State.canonical = type(playerData.appearance) == 'table' and playerData.appearance or nil
	State.settled = false
	State.creationRefused = false
	State.creationAskedAtMs = 0
	State.creationWarned = false
	State.familyAttempts = 0
	State.buildWarned = false
	State.Undress()
	-- A new generation, marked settled: a restore still running for the character
	-- that just left would otherwise wait for a world and then apply its face.
	State.restoreSettledToken = State.NextRestore()
	M.Clothing.Adopt(playerData)
	if switching then
		Open77.log.info(('[appearance] live character is now %s'):format(citizen))
		Runtime.Publish({ ok = true, event = 'characterChanged', citizenId = citizen })
	end
	Runtime.ResolveCharacter(origin)
end
M.Runtime.AdoptCharacter = adoptCharacter

--- Forgets the character, its transaction, clothing, views and published body.
local function unloadCharacter()
	State.Unload()
	Runtime.FinishMutation()
	M.Clothing.Unload()
	M.Panel.Close('no_character')
	M.Wardrobe.Close('no_character')
	M.Presence.Withdraw()
end
M.Runtime.UnloadCharacter = unloadCharacter

--- Records whether the player is down, taking the views down when they are.
local function setDown(value)
	down = value == true
	if down then
		M.Panel.Close('player_down')
		M.Wardrobe.Close('player_down')
	end
end

--- Asks the downed module once whether the player is already down.
-- Its answer is dropped when an event has arrived in the meantime: that event is
-- newer than the question.
local function adoptDownedState()
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return end
	local heard = downHeard
	local asked = api.IsDown()
	if type(asked) ~= 'table' or not asked.ok or downHeard ~= heard then return end
	setDown(type(asked.value) == 'table' and asked.value.down == true)
end

--- Registers everything this half listens to.
local function registerEvents()
	AddEventHandler(EVENT_CHARACTER_LOADED, function(playerData)
		adoptCharacter(playerData, 'characterLoaded')
	end)
	AddEventHandler(EVENT_CHARACTER_CHANGED, function(playerData)
		adoptCharacter(playerData, 'characterChanged')
	end)
	AddEventHandler(EVENT_CHARACTER_UNLOADED, unloadCharacter)

	AddEventHandler(EVENT_CHARACTER_ROSTER, function(roster)
		if type(roster) == 'table' and type(roster.list) == 'table' then rosterSeen = roster.list end
	end)

	AddEventHandler(EVENT_DOWNED_CHANGED, function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
	end)

	-- The world coming up: judge it, spend the bootstrap, then decide the face.
	AddEventHandler(OPX.Host.WORLD_READY, function()
		State.EnterWorld()
		markWorldEligibility('worldReady')
		Runtime.BeginBootstrap('worldReady')
		Runtime.ResolveCharacter('worldReady')
	end)

	-- One door for both refusals, dispatched by the operation each one names.
	-- Registering the same net event name twice is a coin toss on which handler
	-- survives, and the answer to a face save must never be eaten by the clothing
	-- half or the other way round.
	RegisterNetEvent(M.Event.REFUSED, function(code, operation)
		M.Editor.OnRefused(code, operation)
		M.Clothing.OnRefused(code, operation)
	end)

	AddEventHandler(HostEvent.RESET_COMPLETE, function()
		Runtime.FinishReload('playerReset')
		State.playerResetDone = true
		Runtime.Announce()
	end)

	-- The mirror aborted a restore before confirming it.
	AddEventHandler(HostEvent.RESTORE_FAILED, function()
		Runtime.FinishMutation()

		if State.bootstrapToken == State.restoreToken and State.bootstrapQueued and
			not State.appearanceConfirmed then
			State.Undress()
			State.bootstrapQueued = false
			local retries = tonumber(M.Settings.RESTORE_RETRIES) or 3
			if type(State.canonical) == 'table' and State.restoreAttempts < retries then
				State.restoreAttempts = State.restoreAttempts + 1
				Open77.log.warn(('[appearance] bootstrap restore aborted before confirmation; ' ..
					'retry %d/%d'):format(State.restoreAttempts, retries))
				Runtime.BeginRestore(State.canonical, 'mirror_abort')
				return
			end
			Runtime.Notify('error', 'appearance.mirrorUnconfirmed')
			-- Announced anyway: an unconfirmed face must not shut the gate.
			Runtime.Announce()
			return
		end

		if State.Wearing() then return end
		State.bootstrapQueued = false
		State.appearanceConfirmed = false
		Runtime.Notify('error', 'appearance.catalogueMismatch')
	end)
end

-- ── the contract ─────────────────────────────────────────────────────────────
-- Every one of these answers a `Result`, and none of them raises. A write answers
-- that it was ASKED FOR: the engine schedules an apply through its own mirror and
-- the server validates a save, so the outcome arrives on the decision bus rather
-- than in the return value.
--
-- A caller passes its own name where one is needed. Nothing is a boundary here --
-- this runtime has no invoking resource to read -- so ownership is bookkeeping:
-- it decides who may take a view back down, not who may open one.

local Result = OPX.Result

M.Contract = {}

--- Refuses everything while the native appearance API is absent.
local function guard()
	if unavailable then return Result.Err('appearance_unavailable') end
	return nil
end

--- The live character's stored face, as the server holds it.
-- @author dop42
-- @return Result
function M.Contract.GetSkin()
	local gone = guard()
	if gone then return gone end
	if State.citizenId == nil then return Result.Err('no_character') end
	return Result.Ok({
		citizenId = State.citizenId,
		family = State.family,
		snapshot = State.canonical,
	})
end

--- What the puppet wears right now, ready to hand back.
-- @author dop42
-- @return Result
function M.Contract.CaptureSkin()
	local gone = guard()
	if gone then return gone end
	local payload, failure = Snapshot.Capture()
	if payload == nil then return Result.Err(tostring(failure)) end
	return Result.Ok({ snapshot = payload, citizenId = State.citizenId })
end

--- The live character's body family.
-- @author dop42
-- @return Result
function M.Contract.GetFamily()
	local gone = guard()
	if gone then return gone end
	if State.citizenId == nil then return Result.Err('no_character') end
	return Result.Ok({ family = State.family, citizenId = State.citizenId })
end

--- Puts a face on the puppet. Stores nothing.
-- @author dop42
-- @param snapshot table
-- @return Result
function M.Contract.SetSkin(snapshot)
	local gone = guard()
	if gone then return gone end
	if State.citizenId == nil then return Result.Err('no_character') end
	if State.editing or State.creating then return Result.Err('appearance_busy') end
	local canonical, reason = Snapshot.ForNetwork(snapshot)
	if canonical == nil then return Result.Err(tostring(reason)) end
	-- A face from another catalogue build is refused, never applied: it would put
	-- a different face on the puppet rather than failing.
	if not M.BuildAccepted(canonical.gameBuild) then
		return Result.Err('stored_build_mismatch')
	end
	CreateThread(function()
		local ok, failure = applySnapshot(canonical, 8, nil)
		Runtime.Publish({ ok = ok, event = 'applied', citizenId = State.citizenId,
			error = (not ok) and tostring(failure) or nil })
	end)
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Asks the server to store a face, by default a capture.
-- @author dop42
-- @param snapshot table|nil
-- @return Result
function M.Contract.SaveSkin(snapshot)
	local gone = guard()
	if gone then return gone end
	local ok, reason = M.Editor.Save(snapshot)
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Asks for the native face editor on the live character.
-- @author dop42
-- @param mode string|nil `ripperdoc` or `hairdresser`
-- @return Result
function M.Contract.OpenEditor(mode)
	local gone = guard()
	if gone then return gone end
	local ok, reason = M.Editor.Open(mode or 'ripperdoc')
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Answers `needsCreation` by opening the creation editor on the character's body.
-- @author dop42
-- @return Result
function M.Contract.OpenCreator()
	local gone = guard()
	if gone then return gone end
	local ok, reason = M.Editor.Creator()
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Whether a native modal is on screen, and what else this module has up.
-- @author dop42
-- @return Result
function M.Contract.IsOpen()
	local gone = guard()
	if gone then return gone end
	return Result.Ok({
		open = Runtime.ModalOnScreen(),
		editing = State.editing,
		creating = State.creating,
		panel = M.Panel.IsOpen(),
		wardrobe = M.Wardrobe.IsOpen(),
	})
end

--- Whether this world entry's appearance work has finished, and what it waits on.
-- @author dop42
--
-- This is the gate question in contract form: while `settled` is false this client
-- has not announced gameplay-ready and the player is not in the world.
-- @return Result
function M.Contract.IsSettled()
	local gone = guard()
	if gone then return gone end
	local waiting = nil
	if State.creating then
		waiting = 'creator'
	elseif State.creationAskedAtMs ~= 0 and State.canonical == nil then
		waiting = 'creation'
	elseif not State.settled then
		waiting = 'server'
	elseif State.bodyReloading then
		waiting = 'body'
	elseif State.restoreToken ~= State.restoreSettledToken then
		waiting = 'restore'
	end
	return Result.Ok({
		settled = State.AppearanceSettled(),
		announced = State.gameplayAnnounced,
		waiting = waiting,
		citizenId = State.citizenId,
	})
end

--- What this client knows, for a face that did not come back.
-- @author dop42
-- @return Result
function M.Contract.State()
	local report = State.Report()
	report.body = unavailable and nil or Runtime.BodyFamily()
	report.panel = M.Panel.IsOpen()
	report.wardrobe = M.Wardrobe.IsOpen()
	report.clothing = M.Clothing.Report()
	report.available = not unavailable
	return Result.Ok(report)
end

--- Puts this module's appearance panel up for a caller.
-- @author dop42
-- @param owner string the caller's own name
-- @return Result
function M.Contract.OpenPanel(owner)
	local gone = guard()
	if gone then return gone end
	local ok, reason = M.Panel.Open(owner)
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Takes the caller's own panel down.
-- @author dop42
-- @param owner string
-- @return Result
function M.Contract.ClosePanel(owner)
	if not M.Panel.IsOpen() then return Result.Err('no_panel_open') end
	if M.Panel.Owner() ~= owner then return Result.Err('not_owner') end
	M.Panel.Close('caller')
	return Result.Ok(true)
end

--- Puts the fitting room up for a caller.
-- @author dop42
-- @param owner string the caller's own name
-- @return Result
function M.Contract.OpenWardrobe(owner)
	local gone = guard()
	if gone then return gone end
	local ok, reason = M.Wardrobe.Open(owner)
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok({ queued = true, citizenId = State.citizenId })
end

--- Takes the fitting room down, putting back what the puppet wore.
-- @author dop42
-- @param owner string
-- @return Result
function M.Contract.CloseWardrobe(owner)
	if not M.Wardrobe.IsOpen() then return Result.Err('no_wardrobe_open') end
	if M.Wardrobe.Owner() ~= owner then return Result.Err('not_owner') end
	M.Wardrobe.Close('caller')
	return Result.Ok(true)
end

--- Lends the puppet to a fitting room, answering what it wears.
-- Nothing is saved and no look is published while it is lent, so a jacket a player
-- is only trying on never reaches the database or anybody else.
-- @author dop42
-- @param owner string the caller's own name
-- @return Result
function M.Contract.BeginClothingPreview(owner)
	local gone = guard()
	if gone then return gone end
	if Runtime.IsDown() then return Result.Err('player_down') end
	local worn, reason = M.Clothing.BeginPreview(owner)
	if worn == nil then return Result.Err(tostring(reason)) end
	return Result.Ok({
		clothing = worn,
		family = Runtime.BodyFamily(),
		citizenId = State.citizenId,
	})
end

--- Takes the puppet back: `keep` saves what it wears, otherwise the record goes on.
-- @author dop42
-- @param owner string
-- @param keep boolean|nil
-- @param records table|nil the record names put on, so their ids read back by name
-- @return Result
function M.Contract.EndClothingPreview(owner, keep, records)
	local ok, reason = M.Clothing.EndPreview(owner, keep == true, records)
	if not ok then return Result.Err(tostring(reason)) end
	return Result.Ok(true)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the held state. Never yields.
function M.Init()
	State.Reset()
	M.Clothing.Init()
	M.Presence.Init()
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
--
-- An appearance SERVICE, not a flow: it reads, applies, stores and edits the live
-- character's face and clothes, and never decides that a player should be sent to
-- a creator. `needsCreation` on the decision bus is how it asks, and `OpenCreator`
-- is how a caller answers.
function M.Api()
	OPX.Api.Provide('appearance', 1, {
		GetSkin = M.Contract.GetSkin,
		CaptureSkin = M.Contract.CaptureSkin,
		SetSkin = M.Contract.SetSkin,
		SaveSkin = M.Contract.SaveSkin,
		GetFamily = M.Contract.GetFamily,

		OpenEditor = M.Contract.OpenEditor,
		OpenCreator = M.Contract.OpenCreator,
		IsOpen = M.Contract.IsOpen,
		IsSettled = M.Contract.IsSettled,
		State = M.Contract.State,

		OpenPanel = M.Contract.OpenPanel,
		ClosePanel = M.Contract.ClosePanel,
		OpenWardrobe = M.Contract.OpenWardrobe,
		CloseWardrobe = M.Contract.CloseWardrobe,

		BeginClothingPreview = M.Contract.BeginClothingPreview,
		EndClothingPreview = M.Contract.EndClothingPreview,
	})
end

--- Wires every handler and registers the three scheduler passes.
-- @author dop42
--
-- The native appearance API is checked first: without it nothing below can run,
-- and every scheduler pass would raise on the first tick and be suspended. The
-- module still starts and still answers its contract -- with a refusal.
function M.Start()
	if type(Open77.appearance) ~= 'table' or type(Open77.session) ~= 'table' or
		type(Open77.character) ~= 'table' then
		unavailable = true
		Open77.log.error('[appearance] the native appearance API is unavailable on this client: ' ..
			'no face is stored or restored, and this client never announces gameplay-ready')
		return
	end

	registerEvents()
	M.Editor.Wire()
	M.Clothing.Wire()
	M.Presence.Wire()
	M.Wardrobe.Wire()

	adoptDownedState()

	-- A restart mid-session misses every broadcast and there is no replay, so the
	-- world, the bootstrap and a character already loaded are all picked up here.
	State.EnterWorld()
	markWorldEligibility('start')
	Runtime.BeginBootstrap('start')

	local api = OPX.Api.Get('character')
	if api ~= nil and type(api.GetPlayerData) == 'function' then
		adoptCharacter(api.GetPlayerData(), 'start')
	end

	-- The three passes. Each one pcalls its own steps, because a raise from a host
	-- read would otherwise end the pass -- and it is the first of them that ends a
	-- body reload and announces gameplay-ready.
	OPX.Scheduler.Every('appearance.watch', WATCH_MS, function()
		local ok, failure = pcall(M.Editor.Watch)
		if not ok then Open77.log.error('[appearance] watch: ' .. tostring(failure)) end
		local watched, reason = pcall(Runtime.WatchReload)
		if not watched then Open77.log.error('[appearance] reload watch: ' .. tostring(reason)) end
		local announced, problem = pcall(Runtime.Announce)
		if not announced then Open77.log.error('[appearance] announce: ' .. tostring(problem)) end
	end)

	OPX.Scheduler.Every('appearance.presence', 1000, function()
		local ok, failure = pcall(M.Clothing.Check)
		if not ok then Open77.log.error('[appearance] clothing: ' .. tostring(failure)) end
		local ran, reason = pcall(M.Presence.Check)
		if not ran then Open77.log.error('[appearance] presence: ' .. tostring(reason)) end
	end)

	OPX.Scheduler.Every('appearance.wardrobe', 250, function()
		M.Wardrobe.Check()
	end)
end

--- Releases the native transaction and takes both views down.
-- @author dop42
--
-- No native call removes a modal, so an editor open at this point stays on screen
-- until the player closes it. The transaction is released and the state forgets
-- the edit, so its confirmation stores nothing.
function M.Stop()
	if unavailable then return end
	M.Wardrobe.Close('stopped')
	M.Panel.Close('stopped')
	pcall(Runtime.FinishMutation)
end
