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
		origin = entity.charInfo.origin,
		gender = entity.charInfo.gender,
		job = entity.job and entity.job.label,
		gang = entity.gang and entity.gang.name ~= 'none' and entity.gang.label or nil,
		lastLoggedOut = entity.lastLoggedOut,
	}
end

--- Records the account and sends its character roster to the client.
-- Calling it twice is harmless. The cooldown sits here rather than at a doorway
-- because the open command reaches this too; a send its caller has already rate
-- limited (`pushed`) is neither cooled nor cooling, or the client's announce a
-- second later would be discarded along with it.
-- @author dop42
-- @param source Source
-- @param pushed boolean|nil Already rate limited by its caller.
-- @return Result
function M.SendCharacters(source, pushed)
	if not pushed and OPX.Cooling(source, 'roster', 2000) then
		return Result.Err('error.tooFast', tostring(source))
	end
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end

	if OPX.BootError then
		OPX.Refuse(source, 'error.unavailable', M.Operation.ROSTER)
		return Result.Err('error.unavailable', OPX.BootError)
	end

	local account = M.Storage.UpsertAccount(session.userId, session.displayName)
	if not account.ok then return account end

	local characters = M.Storage.FetchAll(session.userId)
	if not characters.ok then return characters end

	local list = characters.value
	local summaries = {}
	for i = 1, #list do summaries[i] = toSummary(list[i]) end
	-- The roster is re-checked against the world after the two reads: a roster
	-- arriving after a character has loaded would reopen the selection screen, its
	-- camera and its control lock on a character already in the world. The
	-- summaries are still answered, for the command that asked.
	if M.Players[source] then return Result.Ok(summaries) end

	session.charactersSent = true
	TriggerClientEvent(M.Event.ROSTER, source, {
		characters = summaries,
		slots = slotsFor(session.userId),
		origins = M.Settings.ORIGINS,
	})

	Open77.log.info(('[character] %s has %d character(s)'):format(session.displayName, #list))
	return Result.Ok(summaries)
end

-- Days per month, February at its leap-year length: the year is not worth
-- resolving for a date written once.
local MONTH_DAYS = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Answers whether a YYYY-MM-DD date exists, from year 1900.
-- A well-formed date that does not exist is refused instead of being stored for
-- the life of the character.
local function realDate(text)
	local year, month, day = text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if year == nil or year < 1900 then return false end
	if month < 1 or month > 12 then return false end
	return day >= 1 and day <= MONTH_DAYS[month]
end

--- Checks a character registration received from a client.
-- The account is taken from the session and never from the payload: `source` is
-- the only value a client cannot forge.
local function validateRegistration(payload)
	if type(payload) ~= 'table' then
		return Result.Err('error.badRequest', 'payload is not a table')
	end

	local firstName = M.ValidateName(payload.firstName)
	if not firstName.ok then return Result.Err('character.badName', 'firstName') end

	local lastName = M.ValidateName(payload.lastName)
	if not lastName.ok then return Result.Err('character.badName', 'lastName') end

	local origin = OPX.Validate.OneOf(payload.origin, M.Settings.ORIGINS)
	if not origin.ok then return Result.Err('character.badOrigin', tostring(payload.origin)) end

	local gender = OPX.Validate.OneOf(payload.gender, { female = true, male = true })
	if not gender.ok then return Result.Err('error.badRequest', 'gender') end

	local birthDate = OPX.Validate.Text(payload.birthDate, {
		min = 8, max = 10, pattern = '^%d%d%d%d%-%d%d%-%d%d$',
	})
	if birthDate.ok and not realDate(birthDate.value) then
		return Result.Err('character.badBirthdate', birthDate.value)
	end

	return Result.Ok({
		firstName = firstName.value,
		lastName = lastName.value,
		origin = origin.value,
		gender = gender.value,
		birthDate = birthDate.ok and birthDate.value or '2050-01-01',
	})
end

--- Creates a character on the caller's own account.
-- @author dop42
-- @param source Source
-- @param payload table
-- @return Result
function M.CreateCharacter(source, payload)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local checked = validateRegistration(payload)
	if not checked.ok then return checked end
	local registration = checked.value

	-- The cooldown comes AFTER the validation: it protects the write, not a
	-- mistyped name.
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
			charInfo = {
				firstName = registration.firstName,
				lastName = registration.lastName,
				origin = registration.origin,
				gender = registration.gender,
				birthDate = registration.birthDate,
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
		message = ('%s %s'):format(registration.firstName, registration.lastName),
		citizenId = entity.citizenId,
		userId = session.userId,
		source = source,
	})
	Open77.log.info(('[character] %s created %s (%s)'):format(
		session.displayName, entity.citizenId, registration.firstName))

	return Result.Ok(toSummary(entity))
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

	-- Out of the world first, or the autosave rewrites the row a minute later.
	local online = M.GetPlayerByCitizenId(citizenId)
	if online then M.Logout(online.PlayerData.source) end

	local deleted = M.Storage.SoftDelete(citizenId)
	if not deleted.ok then return deleted end

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
-- @return boolean, string|nil
function M.PlaceCharacter(player)
	local data = player.PlayerData
	local source = data.source
	if not source then return false, 'offline' end

	local target = data.position
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

--- Logs in, places, then releases the gate for a chosen character.
-- THE ORDER IS THE CONTRACT: log in, place, then release the gate, last.
-- The cooldown sits here because the open command reaches this too.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.SelectCharacter(source, citizenId)
	if OPX.Cooling(source, 'select', 1000) then
		return Result.Err('error.tooFast', tostring(source))
	end
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

	-- A character loaded but not placed still leaves the selection bucket: they
	-- play where they stand, in the world rather than alone in a bucket.
	local placed, reason = M.PlaceCharacter(login.value)
	if not placed then
		Open77.log.warn(('[character] %s logged in but was not placed: %s')
			:format(parsed.value, tostring(reason)))
	end
	OPX.Buckets.Release(source, placed and 'character-placed' or 'character-loaded')

	OPX.Gate.Release(source, placed and 'character-placed' or 'character-loaded')
	return login
end
