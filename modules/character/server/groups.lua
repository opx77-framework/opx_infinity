--- Job and gang memberships, for characters online or offline.
-- @author dop42
--
-- Jobs and gangs are multi-membership: a character holds a grade in any number of
-- them and one of each is primary. Every function here yields when the character
-- is not in the world, so every one of them is coroutine only.
--
-- The definitions come from the module's own configuration. They are definitions
-- and not settings: the key is stored on the character's row, so entries are
-- added freely and never renamed.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

M.Groups = {}

--- Answers a job definition by name, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.Groups.GetJob(name)
	return M.Settings.JOBS[name]
end

--- Answers a gang definition by name, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.Groups.GetGang(name)
	return M.Settings.GANGS[name]
end

--- Resolves a job and grade into the PlayerData.job shape.
-- A Result rather than nil, so a caller can tell "no such job" from "no such
-- grade in that job".
-- @author dop42
-- @param name string
-- @param grade integer|string|nil
-- @return Result
function M.Groups.ResolveJob(name, grade)
	local job = M.Settings.JOBS[name]
	if not job then return Result.Err('job.notFound', tostring(name)) end

	grade = tonumber(grade) or 0
	local rank = job.grades[grade]
	if not rank then return Result.Err('job.gradeNotFound', ('%s:%s'):format(name, grade)) end

	return Result.Ok({
		name = name,
		label = job.label,
		type = job.type,
		payment = rank.payment or 0,
		onDuty = job.defaultDuty == true,
		isBoss = rank.isBoss == true,
		bankAuth = rank.bankAuth == true,
		grade = { name = rank.name, level = grade },
	})
end

--- Resolves a gang and grade into the PlayerData.gang shape.
-- @author dop42
-- @param name string
-- @param grade integer|string|nil
-- @return Result
function M.Groups.ResolveGang(name, grade)
	local gang = M.Settings.GANGS[name]
	if not gang then return Result.Err('gang.notFound', tostring(name)) end

	grade = tonumber(grade) or 0
	local rank = gang.grades[grade]
	if not rank then return Result.Err('gang.gradeNotFound', ('%s:%s'):format(name, grade)) end

	return Result.Ok({
		name = name,
		label = gang.label,
		isBoss = rank.isBoss == true,
		bankAuth = rank.bankAuth == true,
		grade = { name = rank.name, level = grade },
	})
end

--- Answers the highest grade a contiguous grade table defines.
-- So that a caller can clamp instead of failing.
-- @author dop42
-- @param grades table
-- @return integer
function M.Groups.TopGrade(grades)
	local top = 0
	while grades[top + 1] do top = top + 1 end
	return top
end

--- Runs a change against the live Player, or a temporary offline one.
-- The Player is RE-RESOLVED after every wait: a login can arrive in the middle of
-- a change, and the change is then re-applied against the live player instead of
-- being written over the top of it.
-- @param identifier Player|Source|CitizenId
-- @param column string|nil job or gang; nil touches memberships only.
-- @param apply fun(player: Player, offline: boolean): Result
-- @return Result
local function withCharacter(identifier, column, apply)
	local player = M.ResolvePlayer(identifier)
	if player then return apply(player, false) end

	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end

	local fetched = M.Storage.FetchOne(identifier)
	if not fetched.ok then return fetched end

	local groups = M.Storage.FetchGroups(identifier)
	if not groups.ok then return groups end

	player = M.ResolvePlayer(identifier)
	if player then return apply(player, false) end

	local offline = M.CreatePlayer(fetched.value, true)
	offline.PlayerData.jobs = groups.value.jobs
	offline.PlayerData.gangs = groups.value.gangs

	local outcome = apply(offline, true)
	if not outcome.ok then return outcome end

	player = M.ResolvePlayer(identifier)
	if player then
		Open77.log.debug(('[groups] %s came online mid-change; re-applying against the live ' ..
			'player'):format(identifier))
		return apply(player, false)
	end

	-- An operation that only touches membership rows writes no column at all.
	if not column then return outcome end

	local saved = M.Storage.SavePrimary(identifier, column, offline.PlayerData[column])
	if not saved.ok then return saved end
	return outcome
end

--- Writes a membership row, then records it on PlayerData.
-- The row goes first; announcing is the caller's, and no caller may skip it,
-- because the announcement is what reaches the autosave through `Revision`.
local function joinGroup(player, groupType, name, grade)
	local citizenId = player.PlayerData.citizenId
	local written = M.Storage.UpsertGroup(citizenId, groupType, name, grade)
	if not written.ok then return written end

	local bucket = groupType == 'job' and player.PlayerData.jobs or player.PlayerData.gangs
	bucket[name] = grade
	return Result.Ok(true)
end

--- Deletes a membership row, then drops it from PlayerData.
local function leaveGroup(player, groupType, name)
	local citizenId = player.PlayerData.citizenId
	local removed = M.Storage.RemoveGroup(citizenId, groupType, name)
	if not removed.ok then return removed end

	local bucket = groupType == 'job' and player.PlayerData.jobs or player.PlayerData.gangs
	bucket[name] = nil
	return Result.Ok(true)
end

--- Makes a job at a grade the primary one, joining it if need be.
-- Duty comes from the job's own `defaultDuty` rather than being carried over.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.SetJob(identifier, name, grade)
	return withCharacter(identifier, 'job', function(player)
		local resolved = M.Groups.ResolveJob(name, grade)
		if not resolved.ok then return resolved end

		local joined = joinGroup(player, 'job', name, resolved.value.grade.level)
		if not joined.ok then return joined end

		player.PlayerData.job = resolved.value
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.JOB, player.PlayerData.source, resolved.value)
		end
		TriggerEvent(M.Event.IN_JOB, player.PlayerData.source, resolved.value)

		OPX.Audit.Player(player, 'job.set', ('%s grade %d'):format(name, resolved.value.grade.level))
		return Result.Ok(resolved.value)
	end)
end

--- Clocks a character in or out of their primary job.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param onDuty boolean
-- @return Result
function M.Groups.SetJobDuty(identifier, onDuty)
	return withCharacter(identifier, 'job', function(player)
		local job = player.PlayerData.job
		local definition = M.Groups.GetJob(job.name)
		if not definition then return Result.Err('job.notFound', job.name) end
		-- A job that is on duty by definition has no shift to clock into.
		if definition.defaultDuty then
			return Result.Err('job.noDuty', job.name)
		end

		job.onDuty = onDuty == true
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.JOB, player.PlayerData.source, job)
			OPX.NotifyLocale(player.PlayerData.source, job.onDuty and 'job.onDuty' or 'job.offDuty')
		end
		TriggerEvent(M.Event.IN_JOB, player.PlayerData.source, job)
		return Result.Ok(job.onDuty)
	end)
end

--- Adds a job membership without changing the primary job.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.AddPlayerToJob(identifier, name, grade)
	return withCharacter(identifier, nil, function(player)
		local resolved = M.Groups.ResolveJob(name, grade)
		if not resolved.ok then return resolved end
		local joined = joinGroup(player, 'job', name, resolved.value.grade.level)
		if not joined.ok then return joined end
		player.Functions.UpdatePlayerData()
		return joined
	end)
end

--- Removes a job membership, falling back to the default job.
-- The fallback matters: a fired employee would otherwise keep drawing the salary.
-- The announcement happens even for a job that was not primary, because
-- `leaveGroup` has changed `PlayerData.jobs`.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.RemovePlayerFromJob(identifier, name)
	return withCharacter(identifier, 'job', function(player)
		local left = leaveGroup(player, 'job', name)
		if not left.ok then return left end

		local announced = false
		if player.PlayerData.job.name == name then
			local fallback = M.Groups.ResolveJob(M.Settings.PLAYER.DEFAULT_JOB, 0)
			if fallback.ok then
				player.PlayerData.job = fallback.value
				player.Functions.UpdatePlayerData()
				announced = true
				if not player.Offline then
					TriggerClientEvent(M.Event.JOB, player.PlayerData.source, fallback.value)
				end
			end
		end

		if not announced then player.Functions.UpdatePlayerData() end

		OPX.Audit.Player(player, 'job.removed', name)
		return Result.Ok(true)
	end)
end

--- Makes one of a character's existing jobs the primary one.
-- Refuses a job the character is not a member of rather than joining it.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.SetPlayerPrimaryJob(identifier, name)
	return withCharacter(identifier, 'job', function(player)
		local grade = player.PlayerData.jobs[name]
		if grade == nil then return Result.Err('job.notMember', name) end
		return M.Groups.SetJob(player, name, grade)
	end)
end

--- Makes a gang at a grade the primary one, joining it if need be.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.SetGang(identifier, name, grade)
	return withCharacter(identifier, 'gang', function(player)
		local resolved = M.Groups.ResolveGang(name, grade)
		if not resolved.ok then return resolved end

		local joined = joinGroup(player, 'gang', name, resolved.value.grade.level)
		if not joined.ok then return joined end

		player.PlayerData.gang = resolved.value
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.GANG, player.PlayerData.source, resolved.value)
		end
		TriggerEvent(M.Event.IN_GANG, player.PlayerData.source, resolved.value)

		OPX.Audit.Player(player, 'gang.set',
			('%s grade %d'):format(name, resolved.value.grade.level))
		return Result.Ok(resolved.value)
	end)
end

--- Adds a gang membership without changing the primary gang.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.AddPlayerToGang(identifier, name, grade)
	return withCharacter(identifier, nil, function(player)
		local resolved = M.Groups.ResolveGang(name, grade)
		if not resolved.ok then return resolved end
		local joined = joinGroup(player, 'gang', name, resolved.value.grade.level)
		if not joined.ok then return joined end
		player.Functions.UpdatePlayerData()
		return joined
	end)
end

--- Removes a gang membership, falling back to the default gang.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.RemovePlayerFromGang(identifier, name)
	return withCharacter(identifier, 'gang', function(player)
		local left = leaveGroup(player, 'gang', name)
		if not left.ok then return left end

		local announced = false
		if player.PlayerData.gang.name == name then
			local fallback = M.Groups.ResolveGang(M.Settings.PLAYER.DEFAULT_GANG, 0)
			if fallback.ok then
				player.PlayerData.gang = fallback.value
				player.Functions.UpdatePlayerData()
				announced = true
				if not player.Offline then
					TriggerClientEvent(M.Event.GANG, player.PlayerData.source, fallback.value)
				end
			end
		end

		if not announced then player.Functions.UpdatePlayerData() end

		OPX.Audit.Player(player, 'gang.removed', name)
		return Result.Ok(true)
	end)
end

--- Makes one of a character's existing gangs the primary one.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.SetPlayerPrimaryGang(identifier, name)
	return withCharacter(identifier, 'gang', function(player)
		local grade = player.PlayerData.gangs[name]
		if grade == nil then return Result.Err('gang.notMember', name) end
		return M.Groups.SetGang(player, name, grade)
	end)
end

--- Answers everyone in a job or gang, online or not. Coroutine only: it reads
--- the database.
-- @author dop42
-- @param groupType GroupType
-- @param name string
-- @return Result
function M.Groups.GetGroupMembers(groupType, name)
	if groupType ~= 'job' and groupType ~= 'gang' then
		return Result.Err('error.badRequest', tostring(groupType))
	end
	return M.Storage.MembersOf(groupType, name)
end

--- Whether a loaded character holds a job as their primary one.
-- Memory only; never yields.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param onDutyOnly boolean|nil
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.Groups.HasJob(identifier, name, onDutyOnly, minGrade)
	local player = M.ResolvePlayer(identifier)
	local job = player and player.PlayerData.job
	if not job or job.name ~= name then return false end
	if onDutyOnly and job.onDuty ~= true then return false end
	if minGrade ~= nil then
		local level = job.grade and job.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Whether a loaded character holds a gang as their primary one.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.Groups.HasGang(identifier, name, minGrade)
	local player = M.ResolvePlayer(identifier)
	local gang = player and player.PlayerData.gang
	if not gang or gang.name ~= name then return false end
	if minGrade ~= nil then
		local level = gang.grade and gang.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Lists loaded characters whose primary job is the one named.
-- Memory only; never yields.
-- @author dop42
-- @param name string
-- @param onDutyOnly boolean|nil
-- @return Player[]
function M.Groups.GetPlayersByJob(name, onDutyOnly)
	local out, n = {}, 0
	local players = M.GetPlayers()
	for i = 1, #players do
		local job = players[i].PlayerData.job
		if job.name == name and (not onDutyOnly or job.onDuty) then
			n = n + 1
			out[n] = players[i]
		end
	end
	return out
end

--- Lists loaded characters whose primary gang is the one named.
-- @author dop42
-- @param name string
-- @return Player[]
function M.Groups.GetPlayersByGang(name)
	local out, n = {}, 0
	local players = M.GetPlayers()
	for i = 1, #players do
		if players[i].PlayerData.gang.name == name then
			n = n + 1
			out[n] = players[i]
		end
	end
	return out
end
