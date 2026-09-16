--- The client mirror of the server's character state, and the requests back.
-- @author dop42
--
-- The mirror is updated FIRST and the local event raised after it, so that a
-- handler reading the contract sees the change it was just told about.
--
-- Nothing here is authoritative. A modified client can rewrite every value below;
-- the server re-derives anything that matters.

local M = OPX.Modules.Get('character')

-- Degrees the yaw must move before a new report is sent.
local HEADING_EPSILON = 2.0

--- The server's PlayerData, mirrored. Empty until a character loads.
M.PlayerData = {}

--- The roster the server last sent: list, slots and origins.
M.Characters = {
	list = {},
	slots = 0,
	origins = {},
}

--- True between loaded and unloaded.
M.IsLoggedIn = false

--- Announces this client to the server, which answers with the roster or with
--- the character already loaded.
-- @author dop42
function M.Announce()
	TriggerServerEvent(M.Event.ANNOUNCE)
end

--- Asks the server to enter the world as one character.
-- @author dop42
-- @param citizenId string
-- @return boolean, string|nil
function M.SelectCharacter(citizenId)
	if type(citizenId) ~= 'string' then return false, 'error.badRequest' end
	TriggerServerEvent(M.Event.SELECT, { citizenId = citizenId })
	return true
end

--- Checks a registration locally, then asks the server to create it.
-- The local check is a courtesy to the form; the server checks it again, because
-- a modified client skips this one.
-- @author dop42
-- @param registration table
-- @return boolean, string|nil
function M.CreateCharacter(registration)
	if type(registration) ~= 'table' then return false, 'error.badRequest' end

	local firstName = M.ValidateName(registration.firstName)
	if not firstName.ok then return false, 'character.badName' end
	local lastName = M.ValidateName(registration.lastName)
	if not lastName.ok then return false, 'character.badName' end
	if not M.Settings.ORIGINS[registration.origin] then return false, 'character.badOrigin' end

	TriggerServerEvent(M.Event.CREATE, {
		firstName = firstName.value,
		lastName = lastName.value,
		origin = registration.origin,
		gender = registration.gender,
		birthDate = registration.birthDate,
	})
	return true
end

--- Asks the server to soft-delete one of this player's characters.
-- @author dop42
-- @param citizenId string
-- @return boolean, string|nil
function M.DeleteCharacter(citizenId)
	if type(citizenId) ~= 'string' then return false, 'error.badRequest' end
	TriggerServerEvent(M.Event.DELETE, { citizenId = citizenId })
	return true
end

--- Asks the server to send the roster again.
-- @author dop42
function M.RequestCharacters()
	TriggerServerEvent(M.Event.ANNOUNCE)
end

--- The mirrored PlayerData, an empty table before login.
-- @author dop42
-- @return table
function M.GetPlayerData()
	return M.PlayerData
end

--- The live character's citizen id, or nil.
-- @author dop42
-- @return string|nil
function M.GetCitizenId()
	return M.PlayerData.citizenId
end

--- The roster the server last sent.
-- @author dop42
-- @return table
function M.GetCharacters()
	return M.Characters
end

--- The live character's primary job, or nil.
-- @author dop42
-- @return table|nil
function M.GetJobData()
	return M.PlayerData.job
end

--- The live character's primary gang, or nil.
-- @author dop42
-- @return table|nil
function M.GetGangData()
	return M.PlayerData.gang
end

--- Whether the live character holds a job as primary.
-- @author dop42
-- @param name string
-- @param onDutyOnly boolean|nil
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.HasJob(name, onDutyOnly, minGrade)
	local job = M.PlayerData.job
	if not job or job.name ~= name then return false end
	if onDutyOnly and job.onDuty ~= true then return false end
	if minGrade ~= nil then
		local level = job.grade and job.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Whether the live character holds a gang as primary.
-- @author dop42
-- @param name string
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.HasGang(name, minGrade)
	local gang = M.PlayerData.gang
	if not gang or gang.name ~= name then return false end
	if minGrade ~= nil then
		local level = gang.grade and gang.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- The primary job's grade level, or -1 when the job is not held.
-- @author dop42
-- @param name string|nil
-- @return integer
function M.GetJobGrade(name)
	local job = M.PlayerData.job
	if not job or (name and job.name ~= name) then return -1 end
	return job.grade and job.grade.level or -1
end

--- The live character's balance of one money type.
-- @author dop42
-- @param moneyType string
-- @return integer
function M.GetMoney(moneyType)
	local money = M.PlayerData.money
	if not money then return 0 end
	return money[moneyType] or 0
end

--- One metadata value, or the whole metadata table.
-- @author dop42
-- @param key string|nil
-- @return any
function M.GetMetadata(key)
	local metadata = M.PlayerData.metadata
	if not metadata then return nil end
	if key == nil then return metadata end
	return metadata[key]
end

--- The local player's position as an x, y, z table.
-- @author dop42
-- @return table|nil
function M.GetPosition()
	local x, y, z = Open77.character.position()
	if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
	return { x = x, y = y, z = z }
end

--- Mirrors what the server sends, then raises the local event for it.
local function registerEvents()
	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' then return end

		local list = type(payload.characters) == 'table' and payload.characters or {}
		local slots = tonumber(payload.slots)
		slots = OPX.Math.IsFinite(slots) and math.floor(slots) or 0
		if slots < 0 then slots = 0 end

		M.Characters.list = list
		M.Characters.slots = slots
		M.Characters.origins = type(payload.origins) == 'table' and payload.origins or {}

		Open77.log.info(('[character] %d character(s) available, %d slot(s)'):format(#list, slots))
		TriggerEvent(M.Event.ON_ROSTER, M.Characters)
	end)

	RegisterNetEvent(M.Event.LOADED, function(playerData)
		if type(playerData) ~= 'table' then return end
		M.PlayerData = playerData
		M.IsLoggedIn = true

		Open77.log.info(('[character] loaded %s (%s %s)'):format(
			tostring(playerData.citizenId),
			tostring(playerData.charInfo and playerData.charInfo.firstName),
			tostring(playerData.charInfo and playerData.charInfo.lastName)))
		TriggerEvent(M.Event.ON_LOADED, playerData)
	end)

	RegisterNetEvent(M.Event.UNLOADED, function()
		M.PlayerData = {}
		M.IsLoggedIn = false
		TriggerEvent(M.Event.ON_UNLOADED)
	end)

	RegisterNetEvent(M.Event.DATA, function(playerData)
		if type(playerData) ~= 'table' then return end
		M.PlayerData = playerData
		TriggerEvent(M.Event.ON_CHANGED, playerData)
	end)

	RegisterNetEvent(M.Event.MONEY, function(moneyType, amount, action, balance)
		if M.PlayerData.money then M.PlayerData.money[moneyType] = balance end
		TriggerEvent(M.Event.ON_MONEY, moneyType, amount, action, balance)
	end)

	RegisterNetEvent(M.Event.JOB, function(job)
		M.PlayerData.job = job
		TriggerEvent(M.Event.ON_JOB, job)
	end)

	RegisterNetEvent(M.Event.GANG, function(gang)
		M.PlayerData.gang = gang
		TriggerEvent(M.Event.ON_GANG, gang)
	end)

	-- The world coming up is the second reason to announce: the first announce
	-- goes out before the rest of the client is running and usually arrives
	-- nowhere.
	AddEventHandler(OPX.Host.WORLD_READY, function()
		M.Announce()
	end)
end

--- Reports the local heading while a character is loaded.
-- Registered with the scheduler rather than spawned as a thread: exceeding the
-- per-resume instruction budget unwinds out of a coroutine body, and a
-- `while true` loop that hits it is never resumed again, silently.
local function headingReporter()
	local lastSent

	OPX.Scheduler.Every('character.heading',
		M.Number(M.Settings.HEADING_REPORT_MS, 1000), function()
			if not M.IsLoggedIn then
				lastSent = nil
				return
			end
			local yaw = Open77.character.yaw()
			if not OPX.Math.IsFinite(yaw) then return end
			if lastSent == nil or math.abs(yaw - lastSent) >= HEADING_EPSILON then
				lastSent = yaw
				TriggerServerEvent(M.Event.HEADING, { heading = yaw })
			end
		end)
end

--- Nothing to build before the contract: the mirror is empty by definition.
function M.Init()
end

--- Publishes the client half of the contract, the mirror and the requests.
function M.Api()
	OPX.Api.Provide('character', 1, {
		GetPlayerData = M.GetPlayerData,
		GetCitizenId = M.GetCitizenId,
		GetCharacters = M.GetCharacters,
		IsLoggedIn = function() return M.IsLoggedIn end,

		GetJobData = M.GetJobData,
		GetGangData = M.GetGangData,
		GetJobGrade = M.GetJobGrade,
		HasJob = M.HasJob,
		HasGang = M.HasGang,

		GetMoney = M.GetMoney,
		GetMetadata = M.GetMetadata,
		GetPosition = M.GetPosition,

		SelectCharacter = M.SelectCharacter,
		CreateCharacter = M.CreateCharacter,
		DeleteCharacter = M.DeleteCharacter,
		RequestCharacters = M.RequestCharacters,
	})
end

--- Registers the handlers, announces, and starts the heading reporter.
function M.Start()
	registerEvents()
	headingReporter()
	M.Announce()
end
