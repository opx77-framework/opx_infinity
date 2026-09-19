--- Multicharacter: the roster, creation, deletion, selection and placement.
-- @author dop42
--
-- Everything here reads the database, so every function in this file is
-- coroutine only.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

--- Answers how many characters an account may hold.
local function slotsFor(userId)
	return M.Settings.CHARACTERS.SLOTS_BY_USER[userId]
		or M.Number(M.Settings.CHARACTERS.DEFAULT_SLOTS, 1)
end

--- Trims a character entity to what the selection screen shows.
-- Deliberately not the whole entity: the money, the metadata and the stored
-- position are nobody's business until a character is loaded, not even the
-- account holder's.
local function toSummary(entity)
	return {
		citizenId = entity.citizenId,
		cid = entity.cid,
		firstName = entity.charInfo.firstName,
		lastName = entity.charInfo.lastName,
		gender = entity.charInfo.gender,
		job = entity.job and entity.job.label,
		gang = entity.gang and entity.gang.name ~= 'none' and entity.gang.label or nil,
		lastLoggedOut = entity.lastLoggedOut,
	}
end

--- The account's characters, and which one it is locked on. Coroutine only.
-- @author dop42
--
-- Nothing is sent to the client: there is no selection screen to fill. This is
-- read by the command that prints the list, and by nothing else.
-- @param source Source
-- @return Result `{ characters, slots, active }`
function M.ListCharacters(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local account = M.Storage.UpsertAccount(session.userId, session.displayName)
	if not account.ok then return account end

	local characters = M.Storage.FetchAll(session.userId)
	if not characters.ok then return characters end

	local active = M.Storage.FetchActive(session.userId)

	local list = characters.value
	local summaries = {}
	for i = 1, #list do summaries[i] = toSummary(list[i]) end

	return Result.Ok({
		characters = summaries,
		slots = slotsFor(session.userId),
		active = active.ok and active.value or nil,
	})
end

--- Creates a character on the caller's own account. Coroutine only.
-- @author dop42
--
-- IT CARRIES NOTHING. A character is a row before it is anybody: the body family
-- is the game's own creator's answer (`SetBodyFamily`), the name is typed once
-- the player is in the world (`SetName`), and both are written to this row after
-- the fact, once each. There is nothing to validate here and nothing a client
-- could send that would be believed -- the account comes from the session, which
-- is the only value a client cannot forge.
-- @param source Source
-- @return Result the summary of the row that was made
function M.CreateCharacter(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	if OPX.Cooling(source, 'create', 3000) then
		return Result.Err('error.tooFast', tostring(source))
	end

	-- The ceiling counts ROWS and not characters: a soft delete keeps the row
	-- while `NextCid` frees the slot.
	local rows = M.Storage.CountRows(session.userId)
	if not rows.ok then return rows end
	local ceiling = M.Number(M.Settings.CHARACTERS.ROW_CEILING, 5)
	if rows.value >= ceiling then
		Open77.log.warn(('[character] %s has %d character rows, at the ceiling of %d')
			:format(session.userId, rows.value, ceiling))
		return Result.Err('character.rowLimit', tostring(ceiling))
	end

	local slots = slotsFor(session.userId)
	local cid = M.Storage.NextCid(session.userId, slots)
	if not cid.ok then return cid end

	local job = M.Groups.ResolveJob(M.Settings.PLAYER.DEFAULT_JOB, 0)
	if not job.ok then return job end
	local gang = M.Groups.ResolveGang(M.Settings.PLAYER.DEFAULT_GANG, 0)
	if not gang.ok then return gang end

	local money = {}
	for moneyType in pairs(OPX.Config.SHARED.MONEY.TYPES) do
		money[moneyType] = math.floor(tonumber(M.Settings.MONEY.STARTING[moneyType]) or 0)
	end

	local entity
	for attempt = 1, 5 do
		entity = {
			citizenId = OPX.CitizenId.Generate(),
			userId = session.userId,
			cid = cid.value,
			name = session.displayName,
			-- Names and `gender` are absent ON PURPOSE, and nothing may read either
			-- as though it were there: the body family is unknown until the creator
			-- answers one, and the name until the player has typed it. `M.IsFamily`
			-- is false for nil on both sides, and a nameless row draws as its slot.
			charInfo = {
				phone = OPX.String.Random('111-111-1111'),
			},
			money = money,
			job = job.value,
			gang = gang.value,
			position = nil,
			metadata = OPX.Table.DeepCopy(M.Settings.PLAYER.STARTING_METADATA),
		}

		local inserted = M.Storage.Insert(entity)
		if inserted.ok then break end

		-- Only a collision is worth another draw; any other error would fail five
		-- times over.
		if not tostring(inserted.detail or ''):lower():find('duplicate') then
			return inserted
		end
		if attempt == 5 then
			return Result.Err('error.unavailable', 'no free citizen id after 5 draws')
		end
		Open77.log.warn('[character] citizen id collision, drawing another')
	end

	-- The two membership rows are not optional: making a job primary checks the
	-- membership row, and a character without one would be refused its own default
	-- job for ever. If they fail the character is removed rather than answered --
	-- the row is seconds old, holds nothing, and the memberships cascade.
	local jobRow = M.Storage.UpsertGroup(entity.citizenId, 'job', entity.job.name, 0)
	local gangRow = M.Storage.UpsertGroup(entity.citizenId, 'gang', entity.gang.name, 0)
	if not jobRow.ok or not gangRow.ok then
		local failed = not jobRow.ok and jobRow or gangRow
		local undone = M.Storage.DeleteRow(entity.citizenId)
		if not undone.ok then
			Open77.log.error(('[character] %s was inserted, its memberships failed (%s), and the ' ..
				'row could not be removed either (%s): it has to go by hand')
				:format(entity.citizenId, tostring(failed.detail), tostring(undone.detail)))
		end
		return Result.Err('error.unavailable', tostring(failed.detail))
	end

	OPX.Audit.Log({
		event = 'character.create',
		message = ('slot %d'):format(entity.cid),
		citizenId = entity.citizenId,
		userId = session.userId,
		source = source,
	})
	Open77.log.info(('[character] %s created %s, slot %d, with no name and no body yet')
		:format(session.displayName, entity.citizenId, entity.cid))

	return Result.Ok(toSummary(entity))
end

-- Forward-declared: `M.SwitchTo` below takes the other character here in the
-- world when the operator asked for a relog, and the function that does it is
-- three hundred lines further down. Declared here rather than moving either of
-- them, because without the `local` the call in `SwitchTo` would compile against
-- a GLOBAL of the same name -- nil, and a raise inside a command thread rather
-- than anything a reader would look for.
local enterCharacter

--- Ends a session so that the next one enters on the lock as it now stands.
-- @author dop42
--
-- THE DISCONNECT IS THE MECHANISM, not a punishment, and it is why moving the
-- lock is a command and not a menu. The body a world is loaded with is the
-- character bootstrap's answer, and that transaction is spent before the world
-- exists -- so the only honest way to play another character is to arrive as one.
-- The departure path saves the character that was loaded, exactly as a quit does.
local function endSession(source, reason)
	local dropped, why = Open77.players.disconnect(source, reason)
	if dropped then return true end
	Open77.log.error(('[character] %d could not be disconnected for a character change: %s')
		:format(source, tostring(why)))
	return false
end

--- Locks the account on another of its characters and ends the session.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result the summary of the character that was locked
function M.SwitchTo(source, citizenId)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end

	local wanted = M.Storage.FetchOne(parsed.value)
	if not wanted.ok then return wanted end

	-- Somebody else's character answers the same code as one that does not exist:
	-- anything else is an oracle for which citizen ids are real.
	if wanted.value.userId ~= session.userId then
		OPX.Audit.Security('character.notYours',
			('player %d asked to be locked on %s'):format(source, parsed.value),
			{ userId = session.userId, owner = wanted.value.userId }, source)
		return Result.Err('character.notFound', parsed.value)
	end

	local current = M.GetPlayer(source)
	if current ~= nil and current.PlayerData.citizenId == parsed.value then
		return Result.Err('character.alreadyPlaying', parsed.value)
	end

	local already = M.GetPlayerByCitizenId(parsed.value)
	if already ~= nil and already.PlayerData.source ~= source then
		return Result.Err('character.inUse', parsed.value)
	end

	local locked = M.Storage.SetActive(session.userId, parsed.value)
	if not locked.ok then return locked end

	OPX.Audit.Log({
		event = 'character.switch',
		message = parsed.value,
		citizenId = current and current.PlayerData.citizenId or nil,
		userId = session.userId,
		source = source,
	})

	-- THE SOFT PATH, when the operator asked for it. `enterCharacter` was written
	-- for exactly this and had nothing calling it: it awaits the save of the
	-- character being left, refuses the switch rather than losing it, loads the
	-- other one, and -- because the gate is already open for somebody standing in
	-- the world -- places the body on the spot instead of queueing it. It sets the
	-- lock itself at the end, so the next connection comes back to whatever
	-- actually entered.
	--
	-- Only an EXISTING character can go this way, which is all this function ever
	-- handles: a new one needs the game's own creator, and that is a join-time
	-- screen. See `M.Switch` for the measurement behind that.
	if M.SwitchMode == M.Switch.RELOG then
		local entered = enterCharacter(source, parsed.value)
		if entered.ok then return Result.Ok(toSummary(wanted.value)) end
		-- FALLING BACK RATHER THAN STOPPING. The lock has already moved, so a
		-- player left standing here is on a character they asked to leave and
		-- would get the other one on their next connection anyway. The disconnect
		-- makes that connection now, and saves them again on the way out.
		Open77.log.warn(('[character] the in-world switch to %s was refused (%s); ' ..
			'ending the session instead'):format(parsed.value, tostring(entered.error)))
	end

	endSession(source, locale('session.switching'))
	return Result.Ok(toSummary(wanted.value))
end

--- Takes the account off every character, so the next session builds one.
-- Nothing is created here: the row is made by the connection that needs it, which
-- is also what hands the player to the creator.
-- @author dop42
-- @param source Source
-- @return Result
function M.NewCharacter(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local rows = M.Storage.CountRows(session.userId)
	if not rows.ok then return rows end
	local ceiling = M.Number(M.Settings.CHARACTERS.ROW_CEILING, 5)
	if rows.value >= ceiling then return Result.Err('character.rowLimit', tostring(ceiling)) end

	local characters = M.Storage.FetchAll(session.userId)
	if not characters.ok then return characters end
	local slots = slotsFor(session.userId)
	if #characters.value >= slots then return Result.Err('character.limit', tostring(slots)) end

	local cleared = M.Storage.ClearActive(session.userId)
	if not cleared.ok then return cleared end

	OPX.Audit.Log({
		event = 'character.new',
		message = ('%d of %d slots used'):format(#characters.value, slots),
		userId = session.userId,
		source = source,
	})
	endSession(source, locale('session.newCharacter'))
	return Result.Ok({ used = #characters.value, slots = slots })
end

--- Soft-deletes one of the caller's own characters.
-- The cooldown also protects the audit log, since every refused delete writes a
-- security line.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.DeleteCharacter(source, citizenId)
	if OPX.Cooling(source, 'delete', 3000) then
		return Result.Err('error.tooFast', tostring(source))
	end
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end

	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end
	-- Somebody else's character answers the same code as a missing one.
	if fetched.value.userId ~= session.userId then
		OPX.Audit.Security('character.deleteRefused',
			('player %d tried to delete %s'):format(source, citizenId),
			{ userId = session.userId, owner = fetched.value.userId }, source)
		return Result.Err('character.notFound', citizenId)
	end

	-- Read BEFORE the delete: the lock is joined against living characters, so a
	-- soft-deleted one answers as no lock at all and this would never match.
	local active = M.Storage.FetchActive(session.userId)
	local wasActive = active.ok and active.value == citizenId

	-- Out of the world first, or the autosave rewrites the row a minute later.
	local online = M.GetPlayerByCitizenId(citizenId)
	if online then M.Logout(online.PlayerData.source) end

	local deleted = M.Storage.SoftDelete(citizenId)
	if not deleted.ok then return deleted end

	-- A lock naming a character that is gone would cost the next connection a
	-- failed entry before it gave up on it.
	if wasActive then M.Storage.ClearActive(session.userId) end

	local cascades = M.Settings.CHARACTERS.CASCADE_TABLES
	for i = 1, #cascades do
		local target = cascades[i]
		M.Storage.DeleteCascade(target[1], target[2], citizenId)
	end

	OPX.Audit.Log({
		event = 'character.delete',
		severity = 'warn',
		citizenId = citizenId,
		userId = session.userId,
		source = source,
	})
	TriggerEvent(M.Event.IN_DELETED, source, citizenId)

	-- Deleting the character you are playing leaves you in the world as nobody,
	-- and there is no screen left to choose another one on. The session ends, and
	-- the next one enters on whatever the lock now says -- a new character, when
	-- this one was it.
	if online ~= nil then endSession(source, locale('session.characterDeleted')) end
	return Result.Ok(citizenId)
end

--- Answers whether a life state is alive or dead, and not in transition.
local function isSettled(life)
	return type(life) == 'table' and (life.phase == 'alive' or life.phase == 'dead')
end

--- Lets the position sampler write this character's position.
local function allowSampling(player)
	player.MaySample = true
end

--- Places a loaded character by kill then respawn, never a raw transform.
-- The respawn transaction carries the fade, the streaming preload and the grace
-- window that a teleport skips. Every failing exit leaves `MaySample` false, so
-- the stored position survives for the next attempt.
-- @author dop42
-- @param player Player
-- @param target table|nil an explicit position to use instead of the row's
-- @return boolean, string|nil
function M.PlaceCharacter(player, target)
	local data = player.PlayerData
	local source = data.source
	if not source then return false, 'offline' end

	-- AN EXPLICIT TARGET WINS, and there is no fallback behind it. It is a
	-- position the caller has already decided on -- the spawn module's answer for
	-- a player who picked a place to start -- and quietly falling back to the row
	-- or to the default here would put somebody where they did not ask to go.
	target = type(target) == 'table' and target or data.position
	if not target then
		local spawn = M.Settings.DEFAULT_SPAWN
		if spawn.SET then
			target = { x = spawn.X, y = spawn.Y, z = spawn.Z, heading = spawn.HEADING }
		else
			local standing = Open77.players.position(source)
			if type(standing) ~= 'table' or not OPX.Math.IsFinite(tonumber(standing.x)) then
				-- Sampling is allowed on THIS failure alone: nothing was restored, so
				-- wherever the player is standing becomes their position.
				allowSampling(player)
				return false, 'no-default-spawn'
			end
			target = {
				x = standing.x,
				y = standing.y,
				z = standing.z,
				heading = data.reportedHeading or 0.0,
			}
		end
	end
	-- Never a selection bucket: that belongs to whoever holds a player id now, and
	-- never to a character.
	local bucket = OPX.Buckets.PlacementOf(target.bucket)

	-- The gate is not open yet, and this poll is all that separates placing a
	-- player from placing one mid-transition -- which lays a respawn on top of
	-- another.
	local life
	for _ = 1, 5 do
		life = Open77.players.getLifeState(source)
		if isSettled(life) then break end
		Wait(200)
	end
	if not isSettled(life) then
		return false, 'life-state-' .. tostring(life and life.phase or 'unknown')
	end

	-- Out of the selection bucket BEFORE the kill, as the platform's own modes
	-- move a player before placing them: the respawn names the same bucket, and
	-- nothing replicated from the selection bucket is left to carry over.
	OPX.Buckets.Move(source, bucket, 'placement')

	local killed, killError = Open77.players.kill(source, {
		cause = 'script',
		weapon = 'opx_infinity:placement',
	})
	if not killed then return false, tostring(killError) end

	local health = tonumber(data.metadata.health)
	if not OPX.Math.IsFinite(health) then health = 100 end
	local respawned, respawnError = Open77.players.respawn(source, {
		position = { x = target.x, y = target.y, z = target.z },
		heading = target.heading or 0.0,
		bucket = bucket,
		health = OPX.Math.Clamp(health / 100, 0.15, 1.0),
		graceMs = 5000,
	})
	if not respawned then
		-- A revive picks the body up where it fell and not where the row says, so
		-- MaySample stays false and the stored position survives.
		local revived, reviveError = Open77.players.revive(source, {
			health = OPX.Math.Clamp(health / 100, 0.15, 1.0),
			graceMs = 5000,
		})
		if not revived then
			Open77.log.error(('[character] %d was killed for placement and neither respawn (%s) ' ..
				'nor revive (%s) put them back')
				:format(source, tostring(respawnError), tostring(reviveError)))
		end
		return false, tostring(respawnError)
	end

	-- Armor goes on AFTER the transaction: it is not an option of the respawn, and
	-- the body was about to be replaced.
	local armor = tonumber(data.metadata.armor)
	if OPX.Math.IsFinite(armor) and armor > 0 then Open77.players.setArmor(source, armor) end

	allowSampling(player)
	return true
end

--- Characters loaded at a join, by player id, waiting for a body to be put on.
-- Written by `enterCharacter` and spent by `PlacePending`, once each. A slot that
-- changes hands leaves an entry behind, which is why the citizen id is recorded
-- and checked again rather than trusted.
M.AwaitingPlacement = {}

--- Places the character a join loaded, now that the gate has opened.
-- @author dop42
-- @param source Source
-- @return boolean whether the placement was taken care of -- which includes the
-- case where the spawn menu has taken it over and will place it itself
function M.PlacePending(source)
	local citizenId = M.AwaitingPlacement[source]
	if citizenId == nil then return false end
	M.AwaitingPlacement[source] = nil

	local player = M.GetPlayer(source)
	if not player or player.PlayerData.citizenId ~= citizenId then return false end

	-- EVERY JOIN IS PUT TO THE SPAWN MODULE, and WHICH of them turn into a menu is
	-- that module's decision and not this one's -- its `OFFER_POLICY` names three
	-- answers and this block is deliberately blind to all three. A player who is
	-- asked and picks a spot is placed there; one who is not asked, or who picks
	-- nothing, or who never opens the menu, falls through to `PlaceCharacter` with
	-- no explicit target, which resolves to the row's own position (see the target
	-- resolution above). Choosing is the exception; resuming is still the default.
	--
	-- `position` therefore does not gate this block, and must not: it used to,
	-- which meant a character that had ever stood anywhere was never asked again
	-- -- a policy, hard-wired into the wrong module, that no operator could turn
	-- off. It is a hint the spawn module reads for itself under `first`, and here
	-- it is only what the answer falls back to.
	--
	-- Read through `Get` and NOT declared in `requires`: this module is the one
	-- the spawn module depends on, so a declaration in both directions is a cycle,
	-- which the registry refuses at boot. Absent -- or switched off, or configured
	-- with nowhere to go -- it answers nil and everything past this block is
	-- exactly what happened before it existed.
	local spawn = OPX.Api.Get('spawn')
	if spawn ~= nil and type(spawn.Offer) == 'function' then
		-- `Offer` must not yield, which it does not: it records the choice and
		-- starts a thread. The pcall is here so that a spawn module that raises
		-- costs the player the MENU and not the body -- a raise falling out of
		-- here would kill this thread and leave the character unplaced for the
		-- session.
		local asked, taken = pcall(spawn.Offer, source, citizenId)
		if not asked then
			Open77.log.error(('[character] the spawn module raised for %s: %s')
				:format(citizenId, tostring(taken)))
		elseif taken == true then
			Open77.log.info(('[character] %s is choosing where to start'):format(citizenId))
			return true
		end
	end

	local placed, reason = M.PlaceCharacter(player)
	if placed then
		Open77.log.info(('[character] %s was placed once the gate opened'):format(citizenId))
		return true
	end
	-- Not fatal: the player is in the world, on the body the game gave them, and
	-- their position is sampled from where they stand instead.
	Open77.log.warn(('[character] %s could not be placed when the gate opened: %s')
		:format(citizenId, tostring(reason)))
	return false
end

--- Forgets a placement nobody is waiting for any more.
-- @author dop42
-- @param source Source
function M.ForgetPlacement(source)
	M.AwaitingPlacement[source] = nil
end

--- Logs in, places, then releases the gate for a chosen character.
-- THE ORDER IS THE CONTRACT: log in, place, then release the gate, last.
-- The cooldown sits here because the open command reaches this too.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
enterCharacter = function(source, citizenId)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end

	local current = M.GetPlayer(source)

	-- Re-selecting the character already loaded answers early: on the SAME row the
	-- read below would outrun the write and answer pre-save values.
	if current ~= nil and current.PlayerData.citizenId == parsed.value then
		return Result.Ok(current)
	end

	-- On a switch the target is checked -- exists, owned, not already in play --
	-- BEFORE the current character is dismounted. Otherwise a refused switch would
	-- leave the player in the world with nothing loaded and nothing to save them.
	if current then
		local wanted = M.Storage.FetchOne(parsed.value)
		if not wanted.ok then return wanted end
		local session = OPX.Sessions[source]
		if not session or wanted.value.userId ~= session.userId then
			OPX.Audit.Security('character.notYours',
				('player %d asked to switch to %s'):format(source, parsed.value),
				{ userId = session and session.userId, owner = wanted.value.userId }, source)
			return Result.Err('character.notFound', parsed.value)
		end
		local already = M.GetPlayerByCitizenId(parsed.value)
		if already and already.PlayerData.source ~= source then
			return Result.Err('character.inUse', parsed.value)
		end
	end

	-- The dismount is AWAITED and not handed to a thread: the read of the next
	-- character would outrun a save started in parallel. If that save fails the
	-- switch is refused; the character is already unloaded, so the player chooses
	-- again and goes back to their selection bucket.
	if current then
		local saved = M.LogoutAndWait(source)
		if saved and saved.ok == false then
			Open77.log.error(('[character] refusing the switch: %s could not be saved (%s)')
				:format(current.PlayerData.citizenId, tostring(saved.error)))
			OPX.Buckets.Isolate(source, 'switch-refused')
			return Result.Err('error.unavailable', tostring(saved.error))
		end
	end

	-- A refused login does NOT release the gate: that would put the player in the
	-- world with no character. A switch that dismounted the last one leaves them
	-- choosing, and so out of the world too.
	local login = M.Login(source, parsed.value)
	if not login.ok then
		if current then OPX.Buckets.Isolate(source, 'switch-refused') end
		return login
	end

	-- NOTHING MAY PLACE A PLAYER BEFORE THEIR GATE HAS OPENED, and placement is a
	-- kill and a respawn -- that is how the platform puts a body somewhere. A kill
	-- aimed at a client that has not incarnated yet lands on nothing: the body
	-- that attaches afterwards is DEAD, the client never announces gameplay-ready
	-- because it has no living body, and nothing can revive it because the hold
	-- that would let anybody touch it never clears. Measured on 2026-09-17, when
	-- entry moved from a selection screen to a lock read at the connection: dead
	-- on arrival, "joining" for ever, every admin command refused `gate_closed`.
	--
	-- So a JOIN only loads the character here, and `onPlayerReady` places it once
	-- the platform says there is a body to place. A character taken up while the
	-- gate is already open -- a switch in the world -- is placed on the spot,
	-- because then there is a body right now.
	if OPX.Gate.IsReady(source) then
		local placed, reason = M.PlaceCharacter(login.value)
		if not placed then
			Open77.log.warn(('[character] %s logged in but was not placed: %s')
				:format(parsed.value, tostring(reason)))
		end
		OPX.Buckets.Release(source, placed and 'character-placed' or 'character-loaded')
	else
		M.AwaitingPlacement[source] = parsed.value
		-- Out of the selection bucket either way: nobody plays alone in one.
		OPX.Buckets.Release(source, 'character-loaded')
	end

	OPX.Gate.Release(source, 'character-loaded')

	-- The lock follows what actually entered the world, so the next connection
	-- comes back to this character whatever moved it here.
	local session = OPX.Sessions[source]
	if session then
		local locked = M.Storage.SetActive(session.userId, parsed.value)
		if not locked.ok then
			Open77.log.error(('[character] %s entered but the account was not locked on it: %s')
				:format(parsed.value, tostring(locked.detail)))
		end
	end
	return login
end

--- Enters the world as one character the caller owns. Coroutine only.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.SelectCharacter(source, citizenId)
	if OPX.Cooling(source, 'select', 1000) then
		return Result.Err('error.tooFast', tostring(source))
	end
	return enterCharacter(source, citizenId)
end

--- Brings a connection into the world, on the character it is locked on.
-- @author dop42
--
-- THE WHOLE OF ENTRY, and there is no screen in it. An account is locked on one
-- character; that is the one this loads. An account locked on nothing gets a new
-- row, locked to it on the spot -- which is what a player sees as "the creator
-- opened by itself": the row has no body and no name, so the client is handed to
-- the game's own character creator and then asked to type a name.
--
-- The lock is moved by a command. `opx.create` ALWAYS disconnects, because a new
-- character needs the game's own creator and that is drawn by the game's main
-- menu, for a bootstrap transaction spent before the world exists -- see
-- `M.Switch`. `opx.select` takes an EXISTING character, which needs no creator,
-- so `CHARACTERS.SWITCH` decides whether it is taken here in the world or at the
-- next connection. Coroutine only.
-- @param source Source
-- @return Result
function M.EnterSession(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local account = M.Storage.UpsertAccount(session.userId, session.displayName)
	if not account.ok then return account end

	local locked = M.Storage.FetchActive(session.userId)
	if not locked.ok then return locked end

	if locked.value ~= nil then
		local entered = enterCharacter(source, locked.value)
		if entered.ok then return entered end
		-- The lock names something this account cannot enter -- deleted between two
		-- reads, or in play on another connection. It is dropped rather than
		-- retried, and the connection goes on to a new character.
		Open77.log.warn(('[character] %s is locked on %s and could not enter it (%s): ' ..
			'the lock is cleared'):format(session.displayName, locked.value,
				tostring(entered.error)))
		local cleared = M.Storage.ClearActive(session.userId)
		if not cleared.ok then return cleared end
	end

	local created = M.CreateCharacter(source)
	if not created.ok then return created end
	return enterCharacter(source, created.value.citizenId)
end
