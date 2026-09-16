--- The Player object, the roster it lives in, money, metadata and position.
-- @author dop42
--
-- A Player is a character that is in the world. `M.Players` is keyed by player id
-- and `M.Registry` is its reverse index, so that a lookup by citizen id or by
-- account is one hash read and never a walk.
--
-- A player id is recycled and a user id is durable, so a player id is only ever a
-- search key: every read re-checks the user id behind the slot. A departure
-- nobody reported becomes a non-event instead of a hole.
--
-- Sessions, the readiness gate and routing buckets are runtime singletons that
-- belong to core; everything this file needs from them goes through `M.Core`,
-- which is defined in server/main.lua.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

--- Every loaded character by player id.
M.Players = {}

--- Player ids by citizen id and by user id.
M.Registry = {
	byCitizenId = {},
	byUserId = {},
}

--- Whether a money type exists on this server.
-- @author dop42
-- @param moneyType any
-- @return boolean
function M.IsMoneyType(moneyType)
	return OPX.Config.SHARED.MONEY.TYPES[moneyType] ~= nil
end

--- Formats an amount for display with its currency.
-- @author dop42
-- @param amount number
-- @param moneyType MoneyType|nil
-- @return string
function M.FormatMoney(amount, moneyType)
	local grouped = OPX.Math.GroupDigits(math.floor(amount + 0.5))
	if moneyType == nil or moneyType == 'EDDIES' then
		return grouped .. ' \u{20AC}$'
	end
	return ('%s %s'):format(grouped, moneyType)
end

--- Fills in whatever a stored entity is missing, in place.
-- So that a character written before a field existed loads instead of being
-- refused.
-- @author dop42
-- @param entity table
-- @return table
function M.NormaliseEntity(entity)
	local settings = M.Settings
	entity.charInfo = entity.charInfo or {}
	entity.metadata = entity.metadata or {}
	entity.money = entity.money or {}

	-- An absent currency is worth ZERO, not the configured starting amount: a
	-- starting amount is a new character's endowment.
	for moneyType in pairs(OPX.Config.SHARED.MONEY.TYPES) do
		entity.money[moneyType] = math.floor(tonumber(entity.money[moneyType]) or 0)
	end

	for key, value in pairs(settings.PLAYER.STARTING_METADATA) do
		-- Deep-copied: a default taken by reference would be one table shared by
		-- every character on the server.
		if entity.metadata[key] == nil then
			entity.metadata[key] = OPX.Table.DeepCopy(value)
		end
	end

	if type(entity.appearance) ~= 'table' then entity.appearance = nil end

	-- A job or gang dropped from the definitions falls back to the default one.
	-- The membership row is left intact, being edited or not.
	local job = M.Groups.ResolveJob(entity.job and entity.job.name, entity.job and entity.job.grade
		and entity.job.grade.level)
	if not job.ok then
		job = M.Groups.ResolveJob(settings.PLAYER.DEFAULT_JOB, 0)
	end
	entity.job = job.value

	local gang = M.Groups.ResolveGang(entity.gang and entity.gang.name,
		entity.gang and entity.gang.grade and entity.gang.grade.level)
	if not gang.ok then
		gang = M.Groups.ResolveGang(settings.PLAYER.DEFAULT_GANG, 0)
	end
	entity.gang = gang.value

	return entity
end

--- Builds a Player, with its Functions, around a stored entity.
-- @author dop42
-- @param entity table
-- @param offline boolean|nil An offline Player sends and places nothing.
-- @return Player
function M.CreatePlayer(entity, offline)
	local self = { Offline = offline == true }

	-- The dirty flag the autosave reads: incremented on every change, never reset,
	-- and moved nowhere but in UpdatePlayerData.
	self.Revision = 0

	-- False until the world agrees with the stored row. PlaceCharacter is the only
	-- thing that sets it true.
	self.MaySample = false

	self.PlayerData = M.NormaliseEntity(entity)

	-- An explicit `if`, not `offline and nil or entity.source`, which would answer
	-- `entity.source` in both branches.
	if self.Offline then
		self.PlayerData.source = nil
	else
		self.PlayerData.source = entity.source
	end

	local Functions = {}
	self.Functions = Functions

	function Functions.UpdatePlayerData()
		self.Revision = self.Revision + 1
		if self.Offline then return end
		TriggerClientEvent(M.Event.DATA, self.PlayerData.source, self.PlayerData)
	end

	function Functions.SetPlayerData(key, value)
		if key == 'citizenId' or key == 'userId' or key == 'source' then
			error(('PlayerData.%s is identity and cannot be set'):format(key), 2)
		end
		self.PlayerData[key] = value
		Functions.UpdatePlayerData()
	end

	function Functions.SetMetaData(key, value)
		self.PlayerData.metadata[key] = value
		Functions.UpdatePlayerData()
	end

	function Functions.GetMetaData(key)
		if key == nil then return self.PlayerData.metadata end
		return self.PlayerData.metadata[key]
	end

	function Functions.SetCharInfo(key, value)
		self.PlayerData.charInfo[key] = value
		Functions.UpdatePlayerData()
	end

	-- The money, group, Save and Logout functions are the module-level mutators
	-- themselves, so a rule added to one is followed by both.
	function Functions.AddMoney(moneyType, amount, reason)
		return M.AddMoney(self, moneyType, amount, reason)
	end

	function Functions.RemoveMoney(moneyType, amount, reason)
		return M.RemoveMoney(self, moneyType, amount, reason)
	end

	function Functions.SetMoney(moneyType, amount, reason)
		return M.SetMoney(self, moneyType, amount, reason)
	end

	function Functions.GetMoney(moneyType)
		return M.GetMoney(self, moneyType)
	end

	function Functions.SetJob(name, grade)
		return M.Groups.SetJob(self, name, grade)
	end

	function Functions.SetGang(name, grade)
		return M.Groups.SetGang(self, name, grade)
	end

	function Functions.SetJobDuty(onDuty)
		return M.Groups.SetJobDuty(self, onDuty)
	end

	function Functions.Save()
		return M.Save(self)
	end

	function Functions.Logout()
		return M.Logout(self.PlayerData.source)
	end

	return self
end

--- Puts a loaded character into the roster and both indexes.
-- Any other occupant of the slot is dropped first: it means a second connection
-- raced this one.
-- @author dop42
-- @param player Player
function M.RegisterPlayer(player)
	local data = player.PlayerData
	local occupant = M.Players[data.source]
	if occupant and occupant ~= player then M.UnregisterPlayer(occupant) end
	M.Players[data.source] = player
	M.Registry.byCitizenId[data.citizenId] = data.source
	M.Registry.byUserId[data.userId] = data.source
end

--- Takes a character out of the roster and its own index entries.
-- An index entry goes only if it still points at this player: an account that
-- reconnects briefly has both its sessions in the roster.
-- @author dop42
-- @param player Player
function M.UnregisterPlayer(player)
	local data = player.PlayerData
	M.Players[data.source] = nil
	if M.Registry.byCitizenId[data.citizenId] == data.source then
		M.Registry.byCitizenId[data.citizenId] = nil
	end
	if M.Registry.byUserId[data.userId] == data.source then
		M.Registry.byUserId[data.userId] = nil
	end
end

--- Answers the loaded character at a player id, or nil.
-- Nil for somebody still at the selection screen is not an error: that is a
-- session without a player.
-- @author dop42
-- @param source Source|string
-- @return Player|nil
function M.GetPlayer(source)
	return M.Players[tonumber(source) or -1]
end

--- Answers the loaded character carrying a citizen id, or nil.
-- @author dop42
-- @param citizenId CitizenId
-- @return Player|nil
function M.GetPlayerByCitizenId(citizenId)
	local source = M.Registry.byCitizenId[citizenId]
	return source and M.Players[source] or nil
end

--- Answers the loaded character of an account, or nil.
-- @author dop42
-- @param userId UserId
-- @return Player|nil
function M.GetPlayerByUserId(userId)
	local source = M.Registry.byUserId[userId]
	return source and M.Players[source] or nil
end

--- Lists every loaded character, evicting slots whose account changed.
-- This, not `pairs(M.Players)`, is the walk to use. Stale slots are collected
-- during the walk and evicted AFTER it: the logout handlers would otherwise
-- modify the table being iterated.
-- @author dop42
-- @return Player[]
function M.GetPlayers()
	local out, n = {}, 0
	local stale, staleCount = nil, 0

	for source, player in pairs(M.Players) do
		if M.Core.UserIdOf(source) == player.PlayerData.userId then
			n = n + 1
			out[n] = player
		else
			staleCount = staleCount + 1
			stale = stale or {}
			stale[staleCount] = source
		end
	end

	for i = 1, staleCount do
		M.Core.ForgetSession(stale[i])
	end
	return out
end

--- Counts the characters in the world without building a table.
-- @author dop42
-- @return integer
function M.GetPlayerCount()
	local n = 0
	for source, player in pairs(M.Players) do
		if M.Core.UserIdOf(source) == player.PlayerData.userId then n = n + 1 end
	end
	return n
end

--- Resolves a Player, a player id or a citizen id to a Player.
-- The three shapes a caller can be holding.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Player|nil
function M.ResolvePlayer(identifier)
	if type(identifier) == 'table' and identifier.PlayerData then return identifier end
	if type(identifier) == 'number' then return M.GetPlayer(identifier) end
	if type(identifier) == 'string' then return M.GetPlayerByCitizenId(identifier) end
	return nil
end

local resolve = M.ResolvePlayer

--- Answers a character online, or its stored entity when offline.
-- The only reader here that reaches the database, so coroutine only.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.GetCharacter(citizenId)
	local online = M.GetPlayerByCitizenId(citizenId)
	if online then return Result.Ok({ player = online, offline = false }) end

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end
	return Result.Ok({ entity = fetched.value, offline = true })
end

--- Answers a positive, finite, rounded amount, or nil.
-- NaN arrives from a client through JSON and passes every comparison, including
-- the one that would stop the player spending it.
local function amountOf(value)
	local n = tonumber(value)
	if not OPX.Math.IsFinite(n) then return nil end
	n = math.floor(n + 0.5)
	if n <= 0 then return nil end
	return n
end

--- Announces a balance change to its four audiences: the owning client, the
--- other modules, the audit log and PlayerData itself.
local function announceMoney(player, moneyType, amount, action, reason)
	local data = player.PlayerData
	player.Functions.UpdatePlayerData()

	TriggerClientEvent(M.Event.MONEY, data.source,
		moneyType, amount, action, data.money[moneyType])

	TriggerEvent(M.Event.IN_MONEY,
		data.source, data.citizenId, moneyType, amount, action, reason,
		data.money[moneyType])

	OPX.Audit.Player(player, 'money.' .. action, reason, {
		moneyType = moneyType,
		amount = amount,
		balance = data.money[moneyType],
	})
end

--- Adds money to a loaded character, hooked and audited.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.AddMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	-- No money column is ever written for a Player outside the roster.
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then
		Open77.log.error(('[character] AddMoney: %q is not a money type on this server')
			:format(tostring(moneyType)))
		return false, 'money.badType'
	end

	local value = amountOf(amount)
	if not value then
		OPX.Audit.Security('money.badAmount',
			('AddMoney refused %s'):format(tostring(amount)),
			{ citizenId = player.PlayerData.citizenId, moneyType = moneyType },
			player.PlayerData.source)
		return false, 'money.badAmount'
	end

	if not OPX.Hooks.Trigger('money:beforeAdd', {
		player = player, moneyType = moneyType, amount = value, reason = reason,
	}) then
		return false, 'money.vetoed'
	end

	local money = player.PlayerData.money
	money[moneyType] = money[moneyType] + value
	announceMoney(player, moneyType, value, 'add', reason)
	return true
end

--- Removes money, refusing rather than truncating when short.
-- A half-successful purchase is worse than one that fails.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.RemoveMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then
		Open77.log.error(('[character] RemoveMoney: %q is not a money type on this server')
			:format(tostring(moneyType)))
		return false, 'money.badType'
	end

	local value = amountOf(amount)
	if not value then
		OPX.Audit.Security('money.badAmount',
			('RemoveMoney refused %s'):format(tostring(amount)),
			{ citizenId = player.PlayerData.citizenId, moneyType = moneyType },
			player.PlayerData.source)
		return false, 'money.badAmount'
	end

	local money = player.PlayerData.money
	if money[moneyType] - value < 0
		and not OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] then
		return false, 'money.insufficient'
	end

	if not OPX.Hooks.Trigger('money:beforeRemove', {
		player = player, moneyType = moneyType, amount = value, reason = reason,
	}) then
		return false, 'money.vetoed'
	end

	money[moneyType] = money[moneyType] - value
	announceMoney(player, moneyType, value, 'remove', reason)
	return true
end

--- Sets a balance outright, zero included.
-- The only mutator that accepts zero, and so the only way to empty an account.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.SetMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then return false, 'money.badType' end

	local n = tonumber(amount)
	if not OPX.Math.IsFinite(n) then return false, 'money.badAmount' end
	n = math.floor(n + 0.5)
	if n < 0 and not OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] then
		return false, 'money.negative'
	end

	if not OPX.Hooks.Trigger('money:beforeSet', {
		player = player, moneyType = moneyType, amount = n, reason = reason,
	}) then
		return false, 'money.vetoed'
	end

	player.PlayerData.money[moneyType] = n
	announceMoney(player, moneyType, n, 'set', reason)
	return true
end

--- Answers one balance, or the whole money table.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType|nil
-- @return integer|table|nil
function M.GetMoney(identifier, moneyType)
	local player = resolve(identifier)
	if not player then return nil end
	if moneyType == nil then return player.PlayerData.money end
	return player.PlayerData.money[moneyType]
end

--- Sets one key of a loaded character's free-form metadata.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param key string
-- @param value any
-- @return boolean
function M.SetMetadata(identifier, key, value)
	local player = resolve(identifier)
	if not player then return false end
	player.Functions.SetMetaData(key, value)
	return true
end

--- Answers one metadata key, or the whole metadata table.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param key string|nil
-- @return any
function M.GetMetadata(identifier, key)
	local player = resolve(identifier)
	if not player then return nil end
	return player.Functions.GetMetaData(key)
end

--- Re-reads a character's position from the host, with the reported heading.
-- Heading is the only field kept from what the client reported: x, y and z come
-- from the server snapshot, so a client lying about them lies to nobody. The
-- sample is refused while MaySample is false, and refused when the user id behind
-- the player id has changed -- the id may have been recycled, and another
-- account's coordinates must never land in this row.
-- @author dop42
-- @param player Player
-- @return boolean
function M.SamplePosition(player)
	local data = player.PlayerData
	if not data.source then return false end
	if not player.MaySample then return false end
	if M.Core.UserIdOf(data.source) ~= data.userId then return false end

	local snapshot = Open77.players.position(data.source)
	if type(snapshot) ~= 'table' or snapshot.x == nil then return false end

	local previous = data.position
	data.position = {
		x = snapshot.x,
		y = snapshot.y,
		z = snapshot.z,
		heading = data.reportedHeading or (previous and previous.heading) or 0.0,
		bucket = snapshot.bucket or 0,
	}
	return true
end

--- Loads a character the session owns into the roster. Coroutine only.
-- THE ORDER IS THE CONTRACT. The groups are read before the Player is built, the
-- Player is in the roster before the client is told, and the session is re-read
-- after the reads because the player may have left while we waited.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.Login(source, citizenId)
	local session = M.Core.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end

	if OPX.BootError then
		return Result.Err('error.unavailable', OPX.BootError)
	end

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end

	local entity = fetched.value
	-- Somebody else's character answers the SAME code as one that does not exist.
	-- "that is not yours" would be an existence oracle; the attempt is audited.
	if entity.userId ~= session.userId then
		OPX.Audit.Security('character.notYours',
			('player %d asked for %s'):format(source, citizenId),
			{ userId = session.userId, owner = entity.userId }, source)
		return Result.Err('character.notFound', citizenId)
	end

	-- Two Players writing one row is the last save winning in silence.
	local already = M.GetPlayerByCitizenId(citizenId)
	if already and already.PlayerData.source ~= source then
		return Result.Err('character.inUse', citizenId)
	end

	local groups = M.Storage.FetchGroups(citizenId)
	if not groups.ok then return groups end

	-- Another read used to sit here, and other modules hang theirs on this hook.
	-- It yields exactly where that read did, which is what makes the session
	-- re-read below meaningful. The verdict is ignored on purpose: loading extras
	-- never refuses a login, and an unreadable row gives nil, which is neither
	-- worn nor saved by anybody.
	local extras = { citizenId = citizenId, entity = entity, data = {} }
	OPX.Hooks.Trigger('character:loading', extras)

	-- The session is re-read after those reads: if the player left while we waited
	-- (departing, or another session on the slot), the login is refused before
	-- anything is registered. The departure's own Logout has already run and would
	-- not run again, so the ghost would sit in the roster until the autosave
	-- evicted it, its reconnecting owner would be told `character.inUse`, and a
	-- recycled player id would inherit its PlayerData.
	if M.Core.Session(source) ~= session or session.departing then
		return Result.Err('entry.noIdentity', tostring(source))
	end

	entity.source = source
	local player = M.CreatePlayer(entity, false)
	player.PlayerData.jobs = groups.value.jobs
	player.PlayerData.gangs = groups.value.gangs
	for key, value in pairs(extras.data) do player.PlayerData[key] = value end

	M.RegisterPlayer(player)
	session.citizenId = citizenId

	TriggerClientEvent(M.Event.LOADED, source, player.PlayerData)
	TriggerEvent(M.Event.IN_LOADED, source, player.PlayerData)

	OPX.Audit.Player(player, 'character.login', 'logged in')
	Open77.log.info(('[character] %s (%s) logged in as %s %s'):format(
		session.displayName, citizenId,
		player.PlayerData.charInfo.firstName or '?',
		player.PlayerData.charInfo.lastName or '?'))

	return Result.Ok(player)
end

--- Writes a character back, sampling its position first. Coroutine only.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param loggedOut boolean|nil Stamps last_logged_out.
-- @return Result
function M.Save(identifier, loggedOut)
	local player = resolve(identifier)
	if not player then return Result.Err('error.notLoggedIn') end

	if not player.Offline then M.SamplePosition(player) end

	local saved = M.Storage.Save(player.PlayerData, loggedOut)
	if not saved.ok then
		Open77.log.error(('[character] save failed for %s: %s')
			:format(player.PlayerData.citizenId, tostring(saved.detail)))
	end
	return saved
end

--- Takes a loaded character out of the roster and announces it.
local function unload(source)
	local player = source and M.Players[source]
	if not player then return nil end

	M.UnregisterPlayer(player)

	local session = M.Core.Session(source)
	if session then session.citizenId = nil end

	TriggerClientEvent(M.Event.UNLOADED, source)
	TriggerEvent(M.Event.IN_UNLOADED, source, player.PlayerData)
	return player
end

--- Unloads a character and dispatches its save, idempotently.
-- Idempotent because both departure events can arrive for the same departure.
-- THE ORDER IS THE CONTRACT. The Player leaves the roster BEFORE the save, which
-- yields: otherwise a lookup would answer "still here" during the write. The
-- position is sampled immediately and not inside the save, because the move that
-- follows would store it in the selection bucket.
-- @author dop42
-- @param source Source
function M.Logout(source)
	source = tonumber(source)
	local player = unload(source)
	if not player then return end

	M.SamplePosition(player)
	player.MaySample = false
	M.Core.Isolate(source, 'unloaded')

	CreateThread(function()
		M.Save(player, true)
		OPX.Audit.Player(player, 'character.logout', 'logged out')
	end)
end

--- Unloads a character and waits for its row to be written.
-- What a character switch needs: Logout dispatches, and the read of the next
-- character would beat that thread to the database.
-- @author dop42
-- @param source Source
-- @return Result
function M.LogoutAndWait(source)
	source = tonumber(source)
	local player = unload(source)
	if not player then return Result.Ok(false) end

	local saved = M.Save(player, true)
	OPX.Audit.Player(player, 'character.logout', 'logged out')
	return saved
end
