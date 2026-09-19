--- Owned vehicles: the policy. Every statement it runs lives in server/storage.lua.
-- @author dop42

local M = OPX.Modules.Get('vehicles')

local Result = OPX.Result
local Store = M.Storage
local STATE = M.Storage.STATE

-- Spawned vehicles by plate, with their runtime id and owner. Rebuilt empty by
-- `Init`: the host removes what this resource created when it stops.
local live

-- The last citizen id each connection had a vehicle out for. The character
-- module logs a player out on its own disconnect handler, which runs before
-- this module's -- this module requires it, so it starts after it and registers
-- after it -- so by the time the departure reaches here the contract no longer
-- names the character that left.
local owners

-- The character contract, resolved in `Start`. Nil means nobody can prove they
-- own anything, and every door refuses.
local character

-- Floor between two spawn or store requests from one connection.
local REQUEST_MS = 3000

-- Plates drawn before the answer is `vehicle.plateExhausted`.
local PLATE_TRIES = 5

-- Longest TweakDB record accepted. Refused here for a reason a caller can read,
-- although the host caps it too.
local MAX_RECORD = 256

--- Answers a value as a finite number, or nil.
local function finite(value)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return nil end
	return value
end

--- Draws a plate in the configured shape.
-- `OPX.String.Random` draws ASCII capitals and digits, which is what the column
-- needs: `plate` is `ascii_bin`, so a lower-case or accented character would
-- either be refused or compare as a different plate.
local function plate()
	return OPX.String.Random(M.Settings.PLATE_FORMAT)
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Whether the character owning a plate is still loaded somewhere.
-- Unknown, when there is no contract to ask, reads as loaded: putting a vehicle
-- away because the question could not be answered would empty the world.
local function ownerLoaded(citizenId)
	if character == nil then return true end
	return character.GetPlayerByCitizenId(citizenId) ~= nil
end

--- Copies a spawned vehicle's health, damage and flags onto its row.
local function applyCondition(vehicle, record, snapshot)
	vehicle.health = finite(snapshot.health) or vehicle.health
	vehicle.damage = Open77.vehicles.getDamage(record.id)
	vehicle.metadata = vehicle.metadata or {}
	vehicle.metadata.flags = finite(snapshot.flags)
end

--- Stores a new vehicle for a character under a fresh plate.
-- @author dop42
-- @param citizenId CitizenId
-- @param record string A TweakDB vehicle record.
-- @param options table|nil appearance, garage, paint and metadata.
-- @return Result
function M.Register(citizenId, record, options)
	options = options or {}
	if type(citizenId) ~= 'string' or type(record) ~= 'string' or record == '' then
		return Result.Err('error.badRequest', 'citizenId and record are required')
	end
	if #record > MAX_RECORD then return Result.Err('vehicle.badRecord', 'record is too long') end

	if M.Settings.PER_CHARACTER > 0 then
		local owned = Store.CountByOwner(citizenId)
		if not owned.ok then return owned end
		if owned.value >= M.Settings.PER_CHARACTER then
			return Result.Err('vehicle.limit', tostring(M.Settings.PER_CHARACTER))
		end
	end

	local entity
	for _ = 1, PLATE_TRIES do
		entity = {
			plate = plate(),
			citizenId = citizenId,
			record = record,
			appearance = options.appearance,
			garage = options.garage or M.Settings.DEFAULT_GARAGE,
			state = STATE.STORED,
			health = 1.0,
			paint = options.paint,
			metadata = options.metadata or {},
		}
		local inserted = Store.Insert(entity)
		if inserted.ok then
			Open77.log.info(('[vehicles] %s given %s (%s)')
				:format(citizenId, entity.plate, record))
			return Result.Ok(entity)
		end
		-- A duplicate plate is the only insertion failure worth another draw;
		-- every other one is the database, and drawing again would hide it. The
		-- detail is lowered first: the wording of the message depends on the
		-- bridge and on the server version.
		if not tostring(inserted.detail or ''):lower():find('duplicate', 1, true) then
			return inserted
		end
	end
	return Result.Err('vehicle.plateExhausted', entity and entity.plate or '?')
end

--- Answers every vehicle a character owns.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.List(citizenId)
	return Store.FetchByOwner(citizenId)
end

--- Answers the plate and owner of a vehicle this module spawned.
-- Only those: a vehicle created by anything else has no row, and nothing durable
-- may be attached to it.
-- @author dop42
-- @param vehicleId integer
-- @return string|nil plate
-- @return CitizenId|nil owner
function M.PlateOf(vehicleId)
	for plateId, record in pairs(live) do
		if record.id == vehicleId then return plateId, record.citizenId end
	end
	return nil, nil
end

--- Answers the stored row and whether it is spawned now.
-- @author dop42
-- @param plateId string
-- @return Result
function M.Get(plateId)
	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return fetched end
	local record = live[plateId]
	fetched.value.id = record and record.id or nil
	fetched.value.spawned = record ~= nil
	return fetched
end

--- Spawns a loaded character's own vehicle beside them, or at a named place.
-- `at` is the marker path: a caller that names a position has already decided
-- where the vehicle belongs -- a garage or a pad, validated by whoever owns that
-- spot -- and it is created THERE and turned to `at.yaw`, with no offset, so a
-- marker puts the vehicle on the marker rather than a car's width to one side.
-- A caller that names nothing keeps the beside-the-player behaviour.
-- @author dop42
-- @param source Source
-- @param plateId string
-- @param at table|nil position { x, y, z }, yaw, bucket
-- @return Result
function M.Spawn(source, plateId, at)
	local data = characterOf(source)
	if not data then return Result.Err('vehicle.notLoggedIn', tostring(source)) end
	if type(plateId) ~= 'string' then return Result.Err('error.badRequest', 'plate') end

	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return fetched end
	local vehicle = fetched.value
	-- Somebody else's vehicle answers exactly what a plate nobody owns answers:
	-- a distinct refusal would tell an attacker the plate is real.
	if vehicle.citizenId ~= data.citizenId then
		OPX.Audit.Security('vehicle.notYours',
			('%s asked for %s'):format(data.citizenId, plateId),
			{ owner = vehicle.citizenId }, source)
		return Result.Err('vehicle.notFound', plateId)
	end
	if live[plateId] then return Result.Ok({ plate = plateId, id = live[plateId].id }) end

	local position = Open77.players.position(source)
	if position == nil then return Result.Err('vehicle.noPosition', tostring(source)) end

	-- A named place is read through the same coercions as the player's own, so a
	-- NaN or a string from a caller cannot reach the engine as a coordinate.
	local place, yaw, bucket = nil, nil, finite(position.bucket)
	if type(at) == 'table' then
		local x, y, z = finite(at.x), finite(at.y), finite(at.z)
		if x ~= nil and y ~= nil and z ~= nil then
			place = { x = x, y = y, z = z }
		end
		yaw = finite(at.yaw)
		local atBucket = finite(at.bucket)
		if place ~= nil and atBucket ~= nil then bucket = math.floor(atBucket) end
	end
	if place == nil then
		place = {
			x = position.x + M.Settings.SPAWN_OFFSET,
			y = position.y,
			z = position.z + 0.25,
		}
	end

	local id, reason = Open77.vehicles.create({
		record = vehicle.record,
		appearance = vehicle.appearance,
		position = place,
		yaw = yaw,
		bucket = bucket,
		health = vehicle.health,
		primaryColor = vehicle.paint and vehicle.paint.primary or nil,
		secondaryColor = vehicle.paint and vehicle.paint.secondary or nil,
	})
	if id == nil then return Result.Err('vehicle.spawnRefused', tostring(reason)) end

	-- The stored damage and flags are given back, or a put-away-and-fetch cycle
	-- would repair windows, lights, tyres, dents and the destroyed flag for free.
	if type(vehicle.damage) == 'table' then
		Open77.vehicles.setDamage(id, vehicle.damage)
	end
	local flags = finite(vehicle.metadata and vehicle.metadata.flags)
	if flags ~= nil then Open77.vehicles.update(id, { flags = flags }) end

	-- The connection is read again after the database read, which yielded:
	-- writing `live` for a character that left meanwhile would leave a vehicle
	-- nothing will ever put away, so it is removed instead.
	local still = characterOf(source)
	if not still or still.citizenId ~= data.citizenId then
		Open77.vehicles.remove(id)
		return Result.Err('vehicle.notLoggedIn', tostring(source))
	end

	live[plateId] = { id = id, citizenId = data.citizenId }
	owners[source] = data.citizenId
	Store.SetState(plateId, STATE.OUT)
	OPX.Audit.Player(character.GetPlayer(source), 'vehicle.spawn', plateId,
		{ id = tostring(id) })
	return Result.Ok({ plate = plateId, id = id })
end

--- Removes a spawned vehicle and writes its condition back.
-- @author dop42
-- @param plateId string
-- @param garage string|nil Omitted keeps the current garage.
-- @return Result
function M.Store(plateId, garage)
	local record = live[plateId]
	if record == nil then return Result.Err('vehicle.notSpawned', tostring(plateId)) end

	-- The snapshot is read BEFORE the removal: it disappears with the vehicle.
	local snapshot = Open77.vehicles.get(record.id)
	if snapshot ~= nil then
		local fetched = Store.FetchOne(plateId)
		if not fetched.ok then
			-- The removal happens anyway, and the line says the condition is
			-- lost rather than deferred: nothing retries it.
			Open77.log.error(('[vehicles] %s is being removed but its row could not be read (%s); ' ..
				'its condition is not written'):format(plateId, tostring(fetched.detail)))
		else
			local vehicle = fetched.value
			applyCondition(vehicle, record, snapshot)
			vehicle.state = STATE.STORED
			if garage ~= nil then vehicle.garage = garage end
			Store.Save(vehicle)
		end
	else
		Store.SetState(plateId, STATE.STORED, garage)
	end

	Open77.vehicles.remove(record.id)
	live[plateId] = nil
	return Result.Ok({ plate = plateId })
end

--- Puts away every spawned vehicle of one character, or of everyone.
-- @author dop42
-- @param citizenId CitizenId|nil
-- @return integer how many were put away
function M.StoreAll(citizenId)
	-- The plates are collected BEFORE anything yields: a spawn during the walk
	-- would insert a key into the table being walked, which `next` leaves
	-- undefined in Lua.
	local plates = {}
	for plateId, record in pairs(live) do
		if citizenId == nil or record.citizenId == citizenId then plates[#plates + 1] = plateId end
	end

	local stored = 0
	for index = 1, #plates do
		local plateId = plates[index]
		-- Read again: it may have been put away or removed while an earlier one
		-- was awaited.
		if live[plateId] ~= nil and M.Store(plateId).ok then stored = stored + 1 end
	end
	return stored
end

--- Saves, or puts away, one vehicle that is out.
local function savePlate(plateId)
	local record = live[plateId]
	if record == nil then return end

	-- A character going back to a selection screen is not a departure and
	-- nothing announces it, so the roster is asked instead: a vehicle whose
	-- owner is no longer loaded is put away rather than saved in place.
	if not ownerLoaded(record.citizenId) then
		M.Store(plateId)
		return
	end

	local snapshot = Open77.vehicles.get(record.id)
	if snapshot == nil then return end
	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return end
	local vehicle = fetched.value
	applyCondition(vehicle, record, snapshot)
	Store.Save(vehicle)
end

--- One pass of the save loop over everything that is out.
-- This loop, and not the stop handler, is what guarantees damage survives: it
-- photographs the keys and wraps each save in a `pcall`, because one raise would
-- end persistence for the whole process, silently.
local function savePass()
	local plates = {}
	for plateId in pairs(live) do plates[#plates + 1] = plateId end

	for index = 1, #plates do
		local plateId = plates[index]
		local ok, failure = pcall(savePlate, plateId)
		if not ok then
			Open77.log.error(('[vehicles] saving %s: %s'):format(plateId, tostring(failure)))
		end
	end
end

--- Puts away what a departing character left out.
local function departed(rawPlayerId)
	local source = tonumber(rawPlayerId)
	if source == nil then return end

	-- The contract first for a departure nobody else has handled yet, then the
	-- id this connection last had a vehicle out for.
	local data = characterOf(source)
	local citizenId = data and data.citizenId or owners[source]
	owners[source] = nil
	if citizenId == nil then return end

	-- On a thread: this handler must return, and every write yields.
	CreateThread(function()
		local stored = M.StoreAll(citizenId)
		if stored > 0 then
			Open77.log.debug(('[vehicles] %s left with %d vehicle(s) out')
				:format(citizenId, stored))
		end
	end)
end

--- Forgets a spawned vehicle the host removed and marks it stored.
local function removed(id, reason)
	id = tonumber(id)
	for plateId, record in pairs(live) do
		if record.id == id then
			-- Forgotten immediately, and the state written on a thread: the
			-- platform lets an event handler yield, but this one returns at once
			-- and the write waits for nobody.
			live[plateId] = nil
			CreateThread(function() Store.SetState(plateId, STATE.STORED) end)
			Open77.log.info(('[vehicles] %s removed: %s'):format(plateId, tostring(reason)))
			return
		end
	end
end

--- Spawns one of the connection's own vehicles by plate.
local function onSpawnRequested(payload)
	local src = tonumber(source)
	if not src then return end
	local operation = M.Operation.SPAWN
	local plateId = type(payload) == 'table' and payload.plate or nil
	if type(plateId) ~= 'string' then
		return OPX.Refuse(src, 'error.badRequest', operation)
	end
	if OPX.Cooling(src, 'vehicle.spawn', REQUEST_MS) then
		return OPX.Refuse(src, 'error.tooFast', operation)
	end

	CreateThread(function()
		local spawned = M.Spawn(src, plateId)
		if not spawned.ok then
			-- The refusal AND a toast of the same code: nothing else in this
			-- runtime listens for these two operations, and without the toast
			-- the player would not know why nothing happened.
			OPX.Refuse(src, spawned.error, operation)
			OPX.NotifyLocale(src, spawned.error, nil, 'error')
			return
		end
		OPX.NotifyLocale(src, 'vehicle.spawned', { plate = plateId }, 'success')
	end)
end

--- Puts away one of the connection's own spawned vehicles by plate.
local function onStoreRequested(payload)
	local src = tonumber(source)
	if not src then return end
	local operation = M.Operation.STORE
	local plateId = type(payload) == 'table' and payload.plate or nil
	if type(plateId) ~= 'string' then
		return OPX.Refuse(src, 'error.badRequest', operation)
	end
	if OPX.Cooling(src, 'vehicle.store', REQUEST_MS) then
		return OPX.Refuse(src, 'error.tooFast', operation)
	end

	CreateThread(function()
		-- Ownership is proved before anything leaves the world: `live` is keyed
		-- by plate, so a player could otherwise put away someone else's car by
		-- naming it.
		local data = characterOf(src)
		local record = live[plateId]
		if not data or record == nil or record.citizenId ~= data.citizenId then
			OPX.Refuse(src, 'vehicle.notFound', operation)
			OPX.NotifyLocale(src, 'vehicle.notFound', nil, 'error')
			return
		end
		local put = M.Store(plateId)
		if not put.ok then
			OPX.Refuse(src, put.error, operation)
			OPX.NotifyLocale(src, put.error, nil, 'error')
			return
		end
		OPX.NotifyLocale(src, 'vehicle.stored', { plate = plateId }, 'success')
	end)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state and contributes this module's table. Never yields.
-- @author dop42
function M.Init()
	live = {}
	owners = {}
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
function M.Api()
	OPX.Api.Provide('vehicles', 1, {
		Register = M.Register,
		List = M.List,
		Get = M.Get,
		PlateOf = M.PlateOf,
		Spawn = M.Spawn,
		Store = M.Store,
		StoreAll = M.StoreAll,
	})
end

--- Wires the two doors and starts the save loop. Runs on a coroutine.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('[vehicles] no character contract: nobody can prove they own a vehicle, ' ..
			'so every spawn and every store is refused')
	end

	RegisterNetEvent(M.Event.SPAWN, onSpawnRequested)
	RegisterNetEvent(M.Event.STORE, onStoreRequested)
	AddEventHandler(OPX.Host.VEHICLE_REMOVED, removed)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- A DELETED CHARACTER TAKES ITS CARS WITH IT, and this is what does it: the
	-- table's foreign key never fires, because a character delete is a soft one.
	-- Left to the cascade, a deleted character's vehicles stayed in the table for
	-- ever, owned by a citizen id nothing can ever log in as. See
	-- `character.Event.IN_DELETED`.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[vehicles] the cars of the deleted %s were not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	local everyMs = math.max(1000, math.floor(tonumber(M.Settings.SAVE_SECONDS) or 120) * 1000)
	OPX.Scheduler.Every('vehicles:save', everyMs, savePass)
end

--- Writes back everything that is out before the resource goes.
-- @author dop42
--
-- On the stop handler's own stack and NOT on a thread: a stop does not resume
-- one. The save loop is what guarantees the condition survives; this is the last
-- chance to write the rest.
function M.Stop()
	local stored = M.StoreAll(nil)
	if stored > 0 then
		Open77.log.info(('[vehicles] stored %d vehicle(s) on stop'):format(stored))
	end
end
