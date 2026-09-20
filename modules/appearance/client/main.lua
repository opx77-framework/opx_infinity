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
-- chosen, and the roster, the identity form and the face editor are all drawn in
-- the gameplay world afterwards.
--
-- THE CREATOR IS THE ONE THING THAT GOES BACK. The game's own character creator
-- is opened for a bootstrap TRANSACTION and not for a world, so a creation that
-- starts from the roster arms a new one (`RequestCreator`) and answers it with
-- the body that was built (`Editor.FinishCreation`). Everything that ends a
-- creation without one puts the bootstrap back where it found it: a transaction
-- nobody answers is a player behind the cover with no way out.

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
-- The downed module's own local bus. Optional: with it stopped nobody is down.
local EVENT_DOWNED_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Milliseconds between two looks at a world a face may go on, and between two
-- reads of the roster the character module already holds.
local WATCH_MS = 200
local ROSTER_POLL_MS = 250

-- Shipped values, for a configuration that lost one.
local CHOICE_WAIT_MS = 15000
local CHOICE_CEILING_MS = 45000
local DEFAULT_FAMILY = 'female'
local RELOAD_SETTLE_MS = 10000
local RELOAD_TIMEOUT_MS = 30000

-- Life phases a native modal may go up in.
local LIFE_OPEN = { alive = true, recovering = true }

-- How long a body that is attached but not alive is waited on before gameplay is
-- announced anyway, and when this world entry's wait started (0 when none).
local DEAD_ANNOUNCE_MS = 3000
local notAliveSinceMs = 0

-- How long a restore waits for an attached body to come alive before it settles
-- this world entry with no face on it.
local DEAD_WAIT_MS = 5000

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

-- The clauses that have already been reported as holding the announcement back
-- this world entry.
--
-- A SET AND NOT A LAST-VALUE, because `Announce` runs five times a second and
-- the clauses it reads flap: `AppearanceSettled` goes false again on every new
-- restore generation, and a last-value would then write one note per flap
-- against a budget of sixty for the whole session. Cleared at each world entry,
-- so the ceiling is the number of clauses -- five -- per entry.
local announceSaid = {}


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

--- Says something to the OPERATOR, in the server journal, not only here.
-- @author dop42
--
-- `Open77.log` on a client writes to a file on the PLAYER's machine. The devkit
-- card for it says so in as many words, and three days of this server's journal
-- confirm it: the only `[appearance]` lines in it are the ones that came through
-- this event. Every other line this module's client half writes -- the fitting
-- room being owed, the clothes going on, the clothes failing to read back, a
-- payload the host refused -- has never once reached the person running the
-- server, so a join that silently did nothing and a join that worked look
-- identical from the outside. That is why two separate diagnoses of the fitting
-- room were argued from lines that were never going to be there.
--
-- `modules/diagnostics` said the same thing about a client module that fails and
-- opened the same kind of door for it, and this module opened a second one for
-- the clothing read-back. Two independent inventions of one thing, which is why
-- it now lives in core: `OPX.Note` is the same relay with ONE bound, ONE counter
-- and one rate window, rather than two of each competing for the same journal.
-- This is kept as the module's own spelling of it -- every caller here reads
-- better as `Runtime.Note` than as a core call with the module id spelled out at
-- each of the seventeen sites, and the id can then be wrong in only one place.
--
-- It still carries DECISIONS, never a tick: it costs a net event per call.
-- @param text string
function M.Runtime.Note(text)
	OPX.Note('appearance', text)
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

--- Whether a puppet is attached at all, alive or not.
-- @author dop42
-- @return boolean
function M.Runtime.Attached()
	local ok, character = pcall(Open77.character.state)
	return ok and type(character) == 'table' and character.attached == true
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

M.Runtime.BootstrapPhase = bootstrapPhase

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

--- BODY_RELOAD_TIMEOUT_MS, or the shipped value; nil turns the recovery off.
-- An explicit zero or a negative number is an operator saying "do not do this",
-- and is the only thing that gets the old no-deadline behaviour back.
local function reloadTimeoutMs()
	local wanted = M.Settings.BODY_RELOAD_TIMEOUT_MS
	if wanted == nil then return RELOAD_TIMEOUT_MS end
	local value = tonumber(wanted)
	if not OPX.Math.IsFinite(value) then
		Open77.log.warn(('[appearance] BODY_RELOAD_TIMEOUT_MS %s is not a number of ms; ' ..
			'using %d'):format(tostring(wanted), RELOAD_TIMEOUT_MS))
		return RELOAD_TIMEOUT_MS
	end
	if value <= 0 then return nil end
	return math.floor(value)
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
	-- The three callers of this are exactly the three world entries, which is
	-- what `announceSaid` is counted in.
	announceSaid = {}
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
	if bootstrap and bootstrap.phase == 'ready' then
		-- BOTH SPELLINGS, and not out of indecision. This read was `.family`
		-- alone, and the devkit's card for `Open77.session.characterBootstrap`
		-- documents the field as `bodyFamily` -- its own example prints
		-- `bootstrap.bodyFamily`. So the fallback silently answered nil, and
		-- being the LAST fallback is exactly what made that invisible: the two
		-- readings above it usually succeed, and when they did not the caller
		-- simply got no family rather than a wrong one.
		--
		-- The devkit is pinned to op77.76 while this server runs 82+, and there
		-- is no game here to settle which spelling the live build answers. Both
		-- cost one comparison, and reading both is correct under either --
		-- guessing one and being wrong is another silent nil.
		local family = bootstrap.bodyFamily
		if not M.IsFamily(family) then family = bootstrap.family end
		if M.IsFamily(family) then return family end
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
		State.bodyReloadingSince = nowMs()
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
	State.bodyReloadingSince = 0
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
	if reset ~= nil then
		if reset ~= 'complete' then
			reloadResetSeen = true
		elseif reloadResetSeen then
			Runtime.FinishReload('reset_projection')
			return
		end
	end

	-- THE RELOAD'S COVER IS THE ONE NOBODY ELSE LIFTS. `FinishReload` is the only
	-- call that takes it down, and until this deadline existed the only route to
	-- it was the reset projection above: a projection that never leaves
	-- `complete`, or that cannot be read at all, left the player in front of an
	-- opaque loading screen for the rest of the session -- no roster, no editor,
	-- no toast, nothing to say what had happened.
	--
	-- So past the deadline the world itself is the evidence: an attached, alive
	-- puppet in the gameplay world is a reload that landed, whatever the host is
	-- projecting about it.
	local timeout = reloadTimeoutMs()
	local since = tonumber(State.bodyReloadingSince) or 0
	if timeout == nil or since == 0 then return end
	if nowMs() - since < timeout then return end
	if bootstrapPhase() ~= 'ready' or not inGameplay() then return end

	Open77.log.warn(('[appearance] the body reload has run %d ms with the reset projection at ' ..
		'%s: ending it on the world instead, and lifting its cover')
		:format(nowMs() - since, tostring(reset)))
	Runtime.FinishReload('reload_timeout')
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

--- Records WHY the announcement did not go out, and answers false for the caller.
-- @author dop42
--
-- THE ONE THING NOBODY COULD SEE. Every `return false` below used to be silent,
-- and the whole of the evidence that a client was stuck behind the platform hold
-- was an absence: no line here, no clothes, no fitting room, no spawn. The
-- clothing half's own gate then reported `not_announced`, which is true and says
-- nothing -- it is this function's answer, not its reason.
--
-- On `OPX.Note` and not `Open77.log`, for the reason written at `Runtime.Note`:
-- a client log is a file on the player's machine. Deduplicated per clause per
-- world entry -- see `announceSaid` -- because this runs on a 200 ms pass and a
-- note costs a net event.
local function held(clause)
	if not announceSaid[clause] then
		announceSaid[clause] = true
		Runtime.Note(('gameplay-ready is held by %s'):format(clause))
	end
	return false
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
	if State.gameplayAnnounced then return false end
	if not State.worldEligible then return held('no_gameplay_world') end
	-- NAMED SEPARATELY THOUGH `AppearanceSettled` ALREADY REFUSES IT, and that is
	-- the point: a creation is the one hold here with no deadline on it, and
	-- reporting it as `appearance_unsettled` is reporting a player standing in
	-- front of the game's own creator as a fault in this module.
	if State.creating or State.creatorUp then return held('creation_in_progress') end
	if not State.AppearanceSettled() then return held('appearance_unsettled') end

	if not inGameplay() then
		-- A BODY THAT IS ATTACHED AND NOT ALIVE IS STILL A BODY IN THE WORLD, and
		-- this announcement is what lets anybody reach it: nothing places, revives
		-- or teleports a player whose platform hold has never cleared. A client
		-- that waits for `alive` before announcing is therefore a player who
		-- spawned dead and whom NOBODY can bring back -- not an admin, not the
		-- downed module, not the server. Seen on 2026-09-17 on a character whose
		-- stored position put them in the ground: dead on arrival, gate shut, and
		-- every admin command refused with `gate_closed`.
		--
		-- So the wait is kept, because a live body is the honest thing to announce,
		-- and it is BOUNDED. An attached body that has not come alive in
		-- DEAD_ANNOUNCE_MS is announced as it is.
		if not Runtime.Attached() then
			notAliveSinceMs = 0
			return held('no_body')
		end
		if notAliveSinceMs == 0 then
			notAliveSinceMs = nowMs()
			return held('body_not_alive')
		end
		if nowMs() - notAliveSinceMs < DEAD_ANNOUNCE_MS then return false end
		Open77.log.warn(('[appearance] the body has been attached and not alive for %d ms: ' ..
			'announcing anyway, or nothing would ever be able to revive it')
			:format(nowMs() - notAliveSinceMs))
	end
	notAliveSinceMs = 0

	local sent, reason = TriggerServerEvent(OPX.Host.GAMEPLAY_READY)
	if not sent then
		Open77.log.warn('[appearance] gameplay-ready not sent: ' .. tostring(reason))
		return held('not_sent')
	end

	State.gameplayAnnounced = true
	Runtime.FinishMutation()
	Runtime.Publish({ ok = true, event = 'gameplayReady', citizenId = State.citizenId })
	-- IN THE JOURNAL AND NOT ONLY IN THE CLIENT'S LOG. It is the one moment that
	-- decides whether this player ever enters the world, and every clause that
	-- held it is noted above, so the line that says it finally went out has to
	-- land in the same place or the chain reads as though it never ended.
	Runtime.Note('gameplay-ready announced; the platform hold can clear')
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
	-- A FACE NEEDS A WORLD, AND A WORLD NEEDS THE BOOTSTRAP ANSWERED. Every caller
	-- here has a character, so either its own body is known or the one already
	-- loaded stands in. It is a no-op once the transaction has been spent, and it
	-- is the one thing standing between a client and a wait for a world that
	-- nobody is going to ask for -- the creation that was holding the bootstrap
	-- open has ended by the time anything here runs.
	Runtime.ResolveBootstrap(State.family or Runtime.BodyFamily() or Runtime.DefaultFamily())
	local waitedFrom, said = nowMs(), false
	local notAliveFrom = 0
	while not faceable() do
		if not State.Current(token) then return false end

		-- A BODY THAT IS ATTACHED AND NOT ALIVE ENDS NOTHING BY ITSELF. A face
		-- cannot go on it, this wait is what the readiness announcement sits
		-- behind, and nothing can revive a player whose platform hold has never
		-- cleared -- so waiting for it to come alive is waiting for something only
		-- the announcement would have allowed. Past DEAD_WAIT_MS the face is given
		-- up on for this world entry: the entry is marked settled so the
		-- announcement can go out, and the face goes on at the next one, on a body
		-- that is alive.
		if Runtime.Attached() then
			if notAliveFrom == 0 then
				notAliveFrom = nowMs()
			elseif nowMs() - notAliveFrom >= DEAD_WAIT_MS then
				Open77.log.warn(('[appearance] %s token=%d: the body has been attached and not ' ..
					'alive for %d ms, so this entry settles with no face rather than waiting ' ..
					'for one nothing can deliver'):format(label, token, nowMs() - notAliveFrom))
				State.restoreSettledToken = token
				Runtime.Announce()
				return false
			end
		else
			notAliveFrom = 0
		end
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

--- BOOTSTRAP.DEFAULT_FAMILY, or female with one log line.
local function defaultFamily()
	local bootstrap = type(M.Settings.BOOTSTRAP) == 'table' and M.Settings.BOOTSTRAP or {}
	if M.IsFamily(bootstrap.DEFAULT_FAMILY) then return bootstrap.DEFAULT_FAMILY end
	Open77.log.warn(('[appearance] BOOTSTRAP.DEFAULT_FAMILY %s is not "female" or "male"; ' ..
		'loading %q'):format(tostring(bootstrap.DEFAULT_FAMILY), DEFAULT_FAMILY))
	return DEFAULT_FAMILY
end

M.Runtime.DefaultFamily = defaultFamily

--- Whether this client has the natives the engine's own creator is opened with.
-- @author dop42
-- @return boolean
local function creatorAvailable()
	return type(Open77.session) == 'table'
		and type(Open77.session.requestCharacterCreator) == 'function'
		and type(Open77.session.takeCharacterCreatorResult) == 'function'
		and type(Open77.session.resetCharacterBootstrap) == 'function'
end
M.Runtime.CreatorAvailable = creatorAvailable

--- One attempt at the native creator, with whatever it refused with.
local function askCreator()
	local called, opened, reason = pcall(Open77.session.requestCharacterCreator)
	if not called then return false, tostring(opened) end
	if opened then return true end
	return false, tostring(reason or 'character_creator_unavailable')
end

--- Opens the engine's own character creator, when there is a bootstrap for it.
-- @author dop42
--
-- THE CREATOR IS A JOIN-TIME SCREEN. It is drawn by the game's own main menu and
-- it is opened for the character-bootstrap TRANSACTION in flight, so it exists
-- exactly as long as that transaction does -- before this client's first world.
--
-- A SPENT BOOTSTRAP IS NOT RESET TO OPEN ONE. `resetCharacterBootstrap` does arm
-- a fresh transaction and the request that follows IS granted: the phase moves to
-- `creator_requested`, the shell takes the world down for a bootstrap it now
-- expects to be answered -- and no creator ever comes, because the game is not in
-- its main menu any more. Measured on 2026-09-17 against 2.31.13+op77.81: the
-- player sat under the loading cover until they killed the connection. So a
-- creation started from the roster, which is drawn in the world and therefore
-- always after the bootstrap, is refused here and takes the mirror instead.
-- @return boolean
-- @return string|nil the refusal
function M.Runtime.RequestCreator()
	if not Runtime.CreatorReady() then return false, 'bootstrap_spent' end
	return askCreator()
end

--- Whether a bootstrap transaction is still open for a creator to be drawn in.
-- The one question a creation asks before it decides what to open: with this
-- true the game's own creator is reachable and needs no world, with it false the
-- only editor left is the mirror, which needs one.
-- @author dop42
-- @return boolean
function M.Runtime.CreatorReady()
	if not creatorAvailable() then return false end
	local phase = bootstrapPhase()
	return phase ~= 'ready' and phase ~= 'failed' and phase ~= 'unreadable'
end

--- The native creator's one-shot result, or nil while nothing has been confirmed.
-- It is a MAILBOX and not an event: reading it consumes it, so exactly one caller
-- may read it and it is read on this module's own pass.
-- @author dop42
-- @return string|nil
function M.Runtime.TakeCreatorResult()
	if not creatorAvailable() then return nil end
	local read, value = pcall(Open77.session.takeCharacterCreatorResult)
	if not read or type(value) ~= 'string' or value == '' then return nil end
	return value
end

--- BOOTSTRAP.CHOICE_CEILING_MS, nil when it is turned off.
-- The whole hold, screen or no screen. It exists because the screen this waits
-- for is drawn UNDER the shell's loading cover and asks for that cover to come
-- down: a screen that is up and not on the player's monitor would otherwise hold
-- the bootstrap for the rest of the session, which is the one failure the player
-- cannot tell from a frozen game. A value that is not a positive finite number
-- turns the ceiling off, and a screen then holds for as long as it is up.
local function choiceCeilingMs()
	local bootstrap = type(M.Settings.BOOTSTRAP) == 'table' and M.Settings.BOOTSTRAP or {}
	local wanted = bootstrap.CHOICE_CEILING_MS
	if wanted == nil then return CHOICE_CEILING_MS end
	local ceiling = M.ConfigMs(wanted)
	if ceiling == nil then
		Open77.log.warn(('[appearance] BOOTSTRAP.CHOICE_CEILING_MS %s is not a number of ms; ' ..
			'holding at most %d'):format(tostring(wanted), CHOICE_CEILING_MS))
		return CHOICE_CEILING_MS
	end
	if ceiling <= 0 then return nil end
	return ceiling
end

--- BOOTSTRAP.CHOICE_WAIT_MS, or the shipped value with one log line.
local function choiceWaitMs()
	local bootstrap = type(M.Settings.BOOTSTRAP) == 'table' and M.Settings.BOOTSTRAP or {}
	local wait = M.ConfigMs(bootstrap.CHOICE_WAIT_MS)
	if wait == nil then
		Open77.log.warn(('[appearance] BOOTSTRAP.CHOICE_WAIT_MS %s is not a number of ms; ' ..
			'waiting %d'):format(tostring(bootstrap.CHOICE_WAIT_MS), CHOICE_WAIT_MS))
		return CHOICE_WAIT_MS
	end
	return wait
end

--- Holds the join bootstrap for a choice, and spends it on a guess if none comes.
-- @author dop42
--
-- THE BOOTSTRAP IS THE CHOICE'S TO SPEND. It decides the body the world loads
-- with, so the character has to be picked before it is answered -- and it is
-- answered by `ResolveCharacter` for a selection, on that character's own body,
-- or by the creator for a creation, on the body it was built on. Either way this
-- waits and spends nothing.
--
-- The guess is the FALLBACK, and it is what this used to do at every join: with
-- no screen up and nothing chosen, a player would sit behind the loading cover
-- with nothing on it. Spending the bootstrap puts a world under them, and the
-- roster is then drawn in that world instead -- one reload worse, never stuck.
-- @param origin string
function M.Runtime.BeginBootstrap(origin)
	if bootstrapResolved or bootstrapPicking then return end
	if bootstrapPhase() ~= 'waiting' then return end
	bootstrapPicking = true

	CreateThread(function()
		local wait = choiceWaitMs()
		local ceiling = choiceCeilingMs()
		local startedAt = nowMs()
		local deadline = startedAt + wait
		while true do
			if bootstrapResolved or bootstrapPhase() ~= 'waiting' then break end
			-- The character the server is loading, or a creation under way, IS the
			-- answer: both spend the bootstrap themselves, on the body that belongs
			-- to the character.
			if State.citizenId ~= nil or State.creating then break end
			-- But never past the ceiling: see `choiceCeilingMs`.
			if ceiling ~= nil and deadline > startedAt + ceiling then
				deadline = startedAt + ceiling
			end
			if nowMs() >= deadline then
				bootstrapPicking = false
				local family = defaultFamily()
				Open77.log.warn(('[appearance] no character reached this client in %d ms (%s): ' ..
					'the bootstrap is spent on the %s body so that a world comes up at all')
					:format(nowMs() - startedAt, origin, family))
				Runtime.ResolveBootstrap(family)
				return
			end
			Wait(ROSTER_POLL_MS)
		end
		bootstrapPicking = false
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

-- ── the panel's own door ────────────────────────────────────────────────────

-- The name both state machines know this module's own door by. The panel
-- remembers WHO opened it and refuses to close for anybody else, so the key, the
-- two commands and `view.lua`'s own bridge all claim it under this one name.
local OWNER = 'appearance'

--- Whether another surface holds the keyboard: the chat box, a form, the pause
--- menu. Kept module-local rather than folded into `OPX.Lib.Input.IsCaptured`,
--- which answers captured when the read itself raises where this answers free.
-- @author dop42
-- @return boolean
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- Puts one of the two views up, or takes it down when it is already up.
-- @author dop42
--
-- WHY THERE IS A TOGGLE AT ALL. `OpenPanel` for a caller who already owns the
-- open panel refreshes it rather than refusing, so a key wired straight to it
-- could put the panel up and never take it down -- leaving Escape as the only
-- way out of a surface the player opened by accident.
-- @param kind string 'panel' or 'wardrobe'
-- @return Result
local function toggleView(kind)
	local room = kind == 'wardrobe'
	local open = room and M.Wardrobe.IsOpen() or M.Panel.IsOpen()
	local answer
	if room then
		answer = open and M.Contract.CloseWardrobe(OWNER) or M.Contract.OpenWardrobe(OWNER)
	else
		answer = open and M.Contract.ClosePanel(OWNER) or M.Contract.OpenPanel(OWNER)
	end
	if not answer.ok then
		-- NAMED, NOT SILENT. This is the line that answers "I pressed the key and
		-- nothing happened": every refusal here is one a player can be in
		-- (`no_character`, `player_down`, `appearance_busy`) and none of them is a
		-- fault in the module, which is exactly why they have to be sayable.
		Open77.log.warn(('[appearance] the %s was not %s: %s'):format(
			room and 'fitting room' or 'appearance panel',
			open and 'taken down' or 'put up', tostring(answer.error)))
	end
	return answer
end

--- Puts a view up because a COMMAND asked for it; a second run takes it down.
-- @author dop42
-- @param kind any the payload crosses the wire, so it is checked and not trusted
local function onShow(kind)
	if kind ~= 'panel' and kind ~= 'wardrobe' then return end
	local ran, failure = pcall(toggleView, kind)
	if not ran then Open77.log.error('[appearance] show ' .. tostring(kind) .. ': ' .. tostring(failure)) end
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

	-- The player asked for their own appearance panel. Nothing is trusted from
	-- the wire here -- there is nothing ON the wire -- and the panel refuses
	-- itself for every reason it already knows: no character, a native modal, a
	-- panel another caller holds. The refusal is shown, because a command that
	-- silently does nothing is the complaint this whole change answers.
	RegisterNetEvent(M.Event.OPEN_PANEL, function()
		local ok, reason = M.Panel.Open('appearance')
		if ok then return end
		Runtime.Notify('error', 'appearance.panelUnavailable', { reason = tostring(reason) })
	end)

	-- THE CLIENT STILL DECIDES. The server only says "staff asked for this"; every
	-- reason a room cannot open -- the puppet not alive, another surface holding
	-- the keyboard, a save in flight -- is knowable here and nowhere else, so the
	-- gate is unchanged and a refusal is reported to the player whose screen it
	-- is. The operator who asked sees their own answer through the admin menu.
	RegisterNetEvent(M.Event.OPEN_WARDROBE, function()
		local ok, reason = M.Wardrobe.Open('appearance')
		if ok then return end
		Runtime.Notify('error', 'wardrobe.unavailable', { reason = tostring(reason) })
	end)

	-- One door for both refusals, dispatched by the operation each one names.
	-- Registering the same net event name twice is a coin toss on which handler
	-- survives, and the answer to a face save must never be eaten by the clothing
	-- half or the other way round.
	RegisterNetEvent(M.Event.REFUSED, function(code, operation)
		M.Editor.OnRefused(code, operation)
		M.Clothing.OnRefused(code, operation)
	end)

	-- A command asked for one of the two views. The payload is the server's, and
	-- `onShow` checks it rather than believing it.
	RegisterNetEvent(M.Event.SHOW, onShow)

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
	-- Not the same question, and the difference is the one a "why is the spawn
	-- menu not up" report needs: a room that is OWED but not open is a join still
	-- waiting, which is invisible in every other field here.
	report.wardrobeOwed = M.Wardrobe.Owed()
	report.wardrobePolicy = M.WardrobeOffer
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

	-- WHICH WORLD ENTERS ARE HANDED THE FITTING ROOM, settled once here rather
	-- than read at the point of use. `M.ResolveWardrobePolicy` says why it lives
	-- in the shared file; what belongs here is the timing -- a typo is named in
	-- the block an operator scans after editing a config, not in the middle of
	-- every join's own log lines.
	M.WardrobeOffer = M.ResolveWardrobePolicy()
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
	-- BEFORE THE NATIVE CHECK, and deliberately. The view bridge calls no native
	-- and reads nothing this check guards: it is two contract lookups and one
	-- handler on a local bus. Attaching it first is what guarantees it is
	-- listening before anything can publish, which is the same ordering
	-- `chat/client/view.lua` documents -- and on a client with no appearance API
	-- nothing ever publishes, so the placement costs one handler and two log
	-- lines there.
	M.View.Start()

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
		-- After it, and never before: this is where a view that could not be
		-- drawn answers the state half, and the answer closes a room the pass
		-- above may have only just opened.
		M.View.Check()
	end)

	-- WHICH WORLD ENTERS ARE HANDED THE ROOM, said on every start rather than
	-- only on the unusual values. It is the first thing anybody debugging "the
	-- fitting room did not appear" needs, and a policy visible only by its
	-- absence from the journal is a policy nobody can confirm is theirs.
	Open77.log.info(('[appearance] WARDROBE.OFFER_POLICY is %s'):format(tostring(M.WardrobeOffer)))
end

--- Releases the native transaction and takes both views down.
-- @author dop42
--
-- No native call removes a modal, so an editor open at this point stays on screen
-- until the player closes it. The transaction is released and the state forgets
-- the edit, so its confirmation stores nothing.
function M.Stop()
	-- Outside the availability guard, like `M.View.Start` above it and for the
	-- same reason: whatever this bridge put up has to come down whether or not
	-- the native half ever ran.
	M.View.Stop()
	if unavailable then return end
	M.Wardrobe.Close('stopped')
	M.Panel.Close('stopped')
	pcall(Runtime.FinishMutation)
end
