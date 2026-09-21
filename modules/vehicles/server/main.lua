--- Owned vehicles: the policy. Every statement it runs lives in server/storage.lua.
-- @author dop42

local M = OPX.Modules.Get('vehicles')

local Result = OPX.Result
local Store = M.Storage
local STATE = M.Storage.STATE

-- Spawned vehicles by plate, with their runtime id and owner. Rebuilt empty by
-- `Init`: the host removes what this resource created when it stops.
local live

-- Plates a `M.Spawn` is part-way through, so a second one is refused rather than
-- creating a second car from the same row. SEPARATE FROM `live`, which means "a
-- vehicle is out" and is read for exactly that by six other functions: a plate
-- is claimed both when nothing is out (a fresh spawn) and when something is (a
-- recall, which puts the old one away first and leaves `live` empty while it
-- does), and neither state fits in there. Rebuilt empty by `Init` with `live`,
-- because a claim held across a restart would be a plate nobody can ever bring
-- out again.
local claiming

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

--- Answers a value as a finite number, or nil. Named for what it RETURNS: four
--- other files use a local called `finite` for the predicate, and one name for
--- both is an `if finite(x) then` that is true for nil.
local finiteNumber = OPX.Math.Finite

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
	vehicle.health = finiteNumber(snapshot.health) or vehicle.health
	vehicle.damage = Open77.vehicles.getDamage(record.id)
	vehicle.metadata = vehicle.metadata or {}
	vehicle.metadata.flags = finiteNumber(snapshot.flags)
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
--
-- A NAMED PLACE IS ALSO A PROMISE ABOUT A VEHICLE THAT IS ALREADY OUT. See the
-- block below: the vehicle is put away and created again AT the place, so a
-- marker delivers what it says it delivered. Beside-the-player carries no such
-- promise, so it keeps answering with the id the vehicle already has.
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

	-- ── the plate is claimed HERE, before anything else can be ───────────────
	-- THE DUPLICATION RACE, AND WHY THE GUARD BELOW IS NOT ONE ON ITS OWN.
	-- `Store.FetchOne` is a database read and it YIELDS -- `lib/server/storage`
	-- awaits it -- and it happens ABOVE the "already out" test, so two `M.Spawn`
	-- threads for one plate reach that test together.
	--
	-- On the beside-the-player path that is survivable by luck: whichever thread
	-- the database answers first then runs the test, `vehicles.create` and the
	-- `live` write with nothing in between that suspends, so the second finds the
	-- car out. THE RECALL PATH IS NOT. A caller that names a place -- every
	-- garage marker, every pad, every dealer handover -- goes through `M.Store`,
	-- which clears `live` and yields, and then fetches again and yields again.
	-- The plate stands empty in the middle of that, the second thread walks
	-- through, creates a car and writes `live`, and the recaller wakes and
	-- creates another over the top. Two cars from one row, and the first is
	-- ORPHANED: `live` holds one entry per plate, so nothing knows it exists and
	-- nothing will ever put it away, save it or remove it.
	-- `modules/garages/server/main.lua:330` names this race; this is it shut.
	--
	-- A SEPARATE TABLE AND NOT A PLACEHOLDER IN `live`. `live` means "a vehicle
	-- is out" and six other functions read it for exactly that; a plate can be
	-- claimed while nothing is out (a fresh spawn) and while something is (a
	-- recall, which puts the old one away first), and neither is a state `live`
	-- can express without every one of those readers learning about it.
	--
	-- CLAIM FIRST, THEN DO THE WORK, the shape `modules/hauling/server/claim.lua`
	-- uses: there is no yield between the test and the write, so two threads
	-- cannot both pass it. From here to the end of this function EVERY exit goes
	-- through `done`, or a spawn that failed locks the plate for the session.
	--
	-- The three doors in (`vehicle.spawn`, `garages.bring`, `dealership.buy`)
	-- still hold three separate per-player cooldowns, and deliberately: they are
	-- three operations an operator prices separately, and a per-player floor was
	-- never the right shape for this anyway. The thing that must not be done
	-- twice is a PLATE, and that is what is claimed.
	if claiming[plateId] then return Result.Err('vehicle.busy', plateId) end
	claiming[plateId] = true

	--- Gives the claim back and answers. Every exit below goes through it.
	local function done(result)
		claiming[plateId] = nil
		return result
	end

	-- ── already out: recalled to the named place, or answered as it is ────
	-- WHAT HAPPENS NEXT IS THE WHOLE OF A MARKER'S PROMISE. Answering `Ok` with
	-- the id the vehicle already has, while it sits on the other side of the map,
	-- is a marker that spawns nothing and says it did: the player is told "brought
	-- out", stands there looking at an empty spot, and presses the key again.
	-- That is the bug this block exists for.
	--
	-- So a caller that NAMED a place -- a garage marker, a pad, a dealer handing
	-- a bought car over -- gets the vehicle THERE: it is put away first, which is
	-- what writes its condition back, and created again below, on the marker and
	-- facing the marker's heading. A caller that named nothing keeps the old
	-- answer, because moving a player's car for a request that said "somewhere
	-- near me" would be a surprise rather than a service.
	local recalled = false
	if live[plateId] ~= nil then
		if type(at) ~= 'table' then
			return done(Result.Ok({ plate = plateId, id = live[plateId].id, alreadyOut = true }))
		end
		-- NOTHING IS YANKED OUT FROM UNDER ANYBODY. The occupant of a live vehicle
		-- is not necessarily the player who asked -- a marker is a public place --
		-- and removing it would take the car out of a driver's hands.
		local snapshot = Open77.vehicles.get(live[plateId].id)
		local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
		if type(occupants) == 'table' and #occupants > 0 then
			return done(Result.Err('vehicle.occupied', plateId))
		end
		local put = M.Store(plateId)
		if not put.ok then return done(put) end
		-- Read again, because putting it away is what wrote the condition back:
		-- the vehicle created below has to be the row as it now stands.
		fetched = Store.FetchOne(plateId)
		if not fetched.ok then return done(fetched) end
		vehicle = fetched.value
		recalled = true
	end

	local position = Open77.players.position(source)
	if position == nil then
		return done(Result.Err('vehicle.noPosition', tostring(source)))
	end

	-- A named place is read through the same coercions as the player's own, so a
	-- NaN or a string from a caller cannot reach the engine as a coordinate.
	local place, yaw, bucket = nil, nil, finiteNumber(position.bucket)
	if type(at) == 'table' then
		local x, y, z = finiteNumber(at.x), finiteNumber(at.y), finiteNumber(at.z)
		if x ~= nil and y ~= nil and z ~= nil then
			place = { x = x, y = y, z = z }
		end
		yaw = finiteNumber(at.yaw)
		local atBucket = finiteNumber(at.bucket)
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
	if id == nil then return done(Result.Err('vehicle.spawnRefused', tostring(reason))) end

	-- The stored damage and flags are given back, or a put-away-and-fetch cycle
	-- would repair windows, lights, tyres, dents and the destroyed flag for free.
	-- Both answer a boolean, and both were discarded -- so the free repair the
	-- comment above says this prevents happened anyway whenever the host refused,
	-- with nothing said. It is not worth refusing the spawn over, but it is worth
	-- an operator being able to find it.
	if type(vehicle.damage) == 'table' then
		if Open77.vehicles.setDamage(id, vehicle.damage) ~= true then
			Open77.log.warn(('[vehicles] %s came out with its stored damage unapplied; ' ..
				'this fetch repaired it for free'):format(plateId))
		end
	end
	local flags = finiteNumber(vehicle.metadata and vehicle.metadata.flags)
	if flags ~= nil and Open77.vehicles.update(id, { flags = flags }) ~= true then
		Open77.log.warn(('[vehicles] %s came out without its stored flags'):format(plateId))
	end

	-- The connection is read again after the database read, which yielded:
	-- writing `live` for a character that left meanwhile would leave a vehicle
	-- nothing will ever put away, so it is removed instead.
	local still = characterOf(source)
	if not still or still.citizenId ~= data.citizenId then
		-- The removal is the whole point of this branch -- the comment above says
		-- it is here so there is no vehicle "nothing will ever put away" -- and a
		-- discarded refusal produces precisely that orphan. It cannot be undone
		-- from here, so it is named where an operator will find it.
		if Open77.vehicles.remove(id) ~= true then
			Open77.log.error(('[vehicles] %s was spawned for a character who left and could ' ..
				'not be removed; it is in the world with nothing owning it'):format(plateId))
		end
		return done(Result.Err('vehicle.notLoggedIn', tostring(source)))
	end

	live[plateId] = { id = id, citizenId = data.citizenId }
	owners[source] = data.citizenId
	Store.SetState(plateId, STATE.OUT)
	OPX.Audit.Player(character.GetPlayer(source), 'vehicle.spawn', plateId,
		{ id = tostring(id) })
	-- The claim is given back only now, with `live` already written: a gap
	-- between the two would be the same window in miniature.
	return done(Result.Ok({ plate = plateId, id = id, recalled = recalled or nil }))
end

--- The engine id one plate is out as right now, or nil when it is not out.
-- @author XEROX710
--
-- THE ONE READ IN THIS CONTRACT THAT DOES NOT TOUCH THE DATABASE, and that is
-- the whole reason it exists beside `Get`, which answers the same fact among
-- several others. `garages` asks it once per bring-out, to leave the vehicle it
-- is about to fetch out of its own occupancy check -- a car left standing on the
-- only exit of its own garage would otherwise be a car that can never be
-- recalled. Through `Get` that question cost a `FetchOne`, which YIELDS: one
-- more database round trip on the hottest path this module has, for a fact
-- already sitting in memory.
--
-- It says nothing about ownership on purpose. A caller that needs to know whose
-- vehicle it is has `Get` or `Spawn`, both of which prove it; this answers only
-- "is there an entity for this plate, and which one".
-- @param plateId string
-- @return any|nil the engine id
function M.LiveId(plateId)
	if type(plateId) ~= 'string' then return nil end
	local record = live[plateId]
	return record and record.id or nil
end

--- Answers the plate of a vehicle this connection is sitting in, when it OWNS it.
-- The oracle for "put this away": the seat assignment names the vehicle and the
-- plate table names its owner, so nothing on the wire is consulted -- a plate in
-- a payload is a claim, and this is the one door where the claim would be worth
-- making. A vehicle this module never spawned has no plate and answers nothing;
-- neither does one the connection is only riding in.
-- @author XEROX710
-- @param source Source
-- @return Result Ok({ plate, id }) | Ok(nil) when the connection is on foot
function M.Occupied(source)
	local data = characterOf(source)
	if data == nil then return Result.Err('vehicle.notLoggedIn', tostring(source)) end

	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then
		return Result.Ok(nil)
	end
	local read, assignment = pcall(players.getVehicleSeat, source)
	if not read or type(assignment) ~= 'table' then return Result.Ok(nil) end

	-- Compared as text on purpose: the id is opaque to Lua and the host answers
	-- it as an integer, so an equality test would refuse a vehicle it just made.
	local id = assignment.vehicleId
	if id == nil then return Result.Ok(nil) end
	for plateId, record in pairs(live) do
		if tostring(record.id) == tostring(id) and record.citizenId == data.citizenId then
			return Result.Ok({ plate = plateId, id = record.id })
		end
	end
	return Result.Ok(nil)
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

	-- THE ANSWER IS READ, AND IT WAS NOT. `Open77.vehicles.remove` answers a
	-- boolean and this discarded it, after the row had already been moved to
	-- STORED. A refused removal therefore ended as: the database says the car is
	-- in the garage, and the car is still standing in the street. Fetching it
	-- again spawns a second one on the same plate -- one row, two cars. That is
	-- a duplication vector, not a cosmetic leak, so the state does not move
	-- until the world has actually given the vehicle up.
	if Open77.vehicles.remove(record.id) ~= true then
		Open77.log.error(('[vehicles] %s could not be removed from the world; leaving it ' ..
			'spawned rather than recording it as stored'):format(plateId))
		Store.SetState(plateId, STATE.OUT, garage)
		return Result.Err('vehicle.storeRefused', plateId)
	end

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
	claiming = {}
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
		LiveId = M.LiveId,
		Occupied = M.Occupied,
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
