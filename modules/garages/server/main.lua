--- Server half: the garages, what may come out of each, and where it comes out.
-- @author XEROX710
--
-- Everything the client believes is re-derived here before a vehicle exists: an
-- ask is a hint, and the mask is these checks. The distance is measured across
-- the ground against the DECLARED position, exactly as the client measures it,
-- and the bucket must agree -- a marker drawn for another routing bucket is not
-- one a player can use.
--
-- This module creates no vehicle of its own: it hands the plate to the
-- `vehicles` contract, which re-proves the ownership from the character roster
-- before it moves anything. Two owners of the same question would be one too
-- many, and the plate is the one this half does not own.
--
-- A GARAGE IS A KEY AND THE KEY IS IN SEVERAL PLACES. What a player walks up to
-- is a POINT -- a menu point or a door -- and every point knows which garage it
-- belongs to and which of that garage's locations it is at. A vehicle is filed
-- under the GARAGE, never under a point, which is what makes storing at one
-- location and fetching at another one garage rather than two.
--
-- WHERE A VEHICLE COMES OUT IS DECIDED HERE AND NOWHERE ELSE. The location's
-- EXITS are tried in the order the operator wrote them and the first one with
-- nothing parked on it wins. When all of them are taken the request is REFUSED
-- and the player told so: the owner chose that over the two alternatives, which
-- are queueing the player behind a car nobody may move and creating a vehicle
-- inside the one already there.
--
-- THE PLACEMENT COMMANDS ARE GONE. `/opx.garages.add` and `.remove` wrote into
-- `opx77_garages`, so the shape of the world lived in a table nobody had a copy
-- of. A garage is written in `config/garages.lua` now. What did NOT go is the
-- READ of that table: see "the legacy adoption" below, which is the whole of the
-- migration and the reason removing the commands loses nothing.
--
-- ONE COMMAND IS BACK, and only for the AV pads: `/opx.avgarages.add` captures
-- a pad where the operator stands and which way they face, prints the block to
-- check into `config/avgarages.lua`, and sets it live for everyone at once --
-- the headquarters bargain (`/opx.headquarters.add` is the worked example), on
-- a table of its own (`opx77_avpads`) rather than the legacy one above, which
-- stays read-only for ever.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('garages')
local Access = M.Access

local Result = OPX.Result
local Store = M.Storage

-- The garages an operator wrote in config, the ones adopted out of the legacy
-- table at boot, and the pads an operator captured in game with
-- `/opx.avgarages.add`: three layers, merged by `rebuild` below.
local configGarages = {}
local adopted = {}
local captures = {}

-- Config overlaid by the adoption, and the flat point table every read below
-- uses. Both are rebuilt together and never separately: a point whose garage is
-- not in `garages` is a marker that opens a list of nothing.
local garages = {}
local spots = {}

-- Per-player rate-limit windows for requests that are not rate-limited by
-- `OPX.Cooling`.
local windows = {}

-- The contracts, resolved in `Start`. Nil means nothing can be proved and every
-- request is refused.
local vehicles, character

-- Whether the sweep is running. Set in `Start`.
local running = false

-- Whether the missing occupancy read was already said: without
-- `Open77.vehicles.all` no exit can be told apart from a free one, and every
-- bring-out takes the first exit. That is the old behaviour and it is not worth
-- refusing over, but it is worth an operator being able to find it.
local reportedOccupancy = false

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- How long a rate-limit window lives past a player's last request.
local WINDOW_GC_MS = 60000

local coordinate, integer = Access.Coordinate, Access.Integer

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(player, limit, spanMs)
	if limit <= 0 or spanMs <= 0 then return true end
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Whether this connection may use the garage a point belongs to, and when it
-- may not, the catalogue key that says why.
--
-- ONLY THE ANNEX GATES. A garage of `config/garages.lua` carries no requirement
-- and is open to whoever owns what comes out of it -- the ownership is the
-- vehicles contract's question and always was. A pad of `config/avgarages.lua`
-- is behind the job gate instead: `Access.Evaluate` is the one adapter over
-- `lib/shared/jobgate.lua`, so `JOBS` and `ON_DUTY` there mean exactly what
-- they mean on a lift floor and an armory bench.
--
-- THE GATE IS ON THE SERVER AND ON EVERY DOOR: the list, the bring-out and the
-- put-away all pass through here, so a client that never draws the marker can
-- still name the pad and must still be refused.
-- @param source Source
-- @param built table|nil the garage
-- @return boolean
-- @return string|nil the refusal key, when there is one
local function mayUse(source, built)
	if type(built) ~= 'table' or type(built.requirement) ~= 'table' then return true end
	local data = characterOf(source)
	local now = OPX.Now()
	local snapshot = nil
	if data ~= nil then
		snapshot = {
			job = type(data.job) == 'table' and data.job or nil,
			jobs = type(data.jobs) == 'table' and data.jobs or nil,
			atMs = now,
		}
	end
	local ok, code = Access.Evaluate(built, snapshot, now)
	if ok then return true end
	return false, Access.GATE_REFUSAL[code] or 'garages.jobRequired'
end

--- Reads a connection's ground position and bucket, or nil.
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local x, y = coordinate(position.x), coordinate(position.y)
	if x == nil or y == nil then return nil end
	local bucket = integer(position.bucket)
	return { x = x, y = y, bucket = bucket or 0 }
end

--- Rebuilds the merged garages and the flat point table under them.
-- Called once at load and once when the legacy adoption has finished.
local function rebuild()
	garages, spots = {}, {}
	for key, built in pairs(configGarages) do garages[key] = built end
	for key, built in pairs(adopted) do
		-- CONFIG WINS, and this is the one precedence the rework reverses. A
		-- captured row used to overlay the config file, because the command was
		-- the authority and the file was the backup. There is no command now:
		-- the file IS the garage, and a stale row of the same name silently
		-- moving it would be a garage an operator cannot move by editing the one
		-- place they are told to edit.
		if garages[key] == nil then garages[key] = built end
	end
	-- AND A CAPTURE WINS OVER BOTH, which is not a second exception but the
	-- same rule read in the other direction: a legacy row is a leftover of a
	-- command nobody runs any more and must never move what the file says, but
	-- a capture is an operator moving a pad RIGHT NOW -- "capture and set" is
	-- the whole promise of `/opx.avgarages.add`. What it set is what the server
	-- serves until the operator checks the printed block in and drops the
	-- capture with `/opx.avgarages.remove`.
	for key, built in pairs(captures) do garages[key] = built end
	for _, built in pairs(garages) do
		for _, point in ipairs(Access.PointsOf(built)) do spots[point.key] = point end
	end
end

--- The location a point belongs to, or nil.
local function locationOf(point)
	if type(point) ~= 'table' then return nil end
	local built = garages[point.garage]
	if built == nil then return nil end
	return built.locations[point.location]
end

--- The points of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the points of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

--- Sends every connected player their own list. Guarded: the adoption must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[garages] sync failed: ' .. tostring(failure))
		end
	end
end

--- Whether a stored row may come out of a garage.
-- The kind is the only thing decided here, and it is the whole rule: a ground
-- garage takes a ground vehicle and a pad takes an AV. Whether a row may come
-- out at all is the vehicles contract's question, not this module's.
local function eligible(row, built)
	if type(row) ~= 'table' or type(row.plate) ~= 'string' then return false end
	local av = Access.IsAv(row.record)
	if built.kind == M.KIND.AVPAD then return av end
	return not av
end

--- Picks what comes out: a named plate when one was named, otherwise the
--- player's own vehicle stored at THIS garage, and failing that any eligible one.
-- Ties are broken by plate because the order the rows arrive in is ANOTHER
-- MODULE'S. `vehicles.List` answers them `ORDER BY created_at`, which is not
-- part of that contract and not this module's to lean on: a stored vehicle
-- landing on a second row with the same timestamp, or that query gaining an
-- index, would change which of two equally eligible cars the same press hands
-- over. The plate is the row's own and never ties.
--
-- THE RANK IS THE GARAGE'S KEY AND NOT A POINT'S, which is the difference the
-- rework turns on: a car put away at the Watson door of `garage1` ranks first at
-- the Japantown menu of `garage1`, because both of them ARE `garage1`.
local function choose(rows, built, wanted)
	local ranked = {}
	for index = 1, #rows do
		local row = rows[index]
		if eligible(row, built) then
			ranked[#ranked + 1] = {
				row = row,
				rank = (row.garage == built.key) and 0 or 1,
			}
		end
	end
	table.sort(ranked, function(left, right)
		if left.rank ~= right.rank then return left.rank < right.rank end
		return left.row.plate < right.row.plate
	end)

	if type(wanted) ~= 'string' or wanted == '' then
		return ranked[1] and ranked[1].row or nil
	end
	for index = 1, #ranked do
		if ranked[index].row.plate == wanted then return ranked[index].row end
	end
	return nil, 'vehicle.notFound'
end

--- The first exit of a location with nothing parked on it, or nil.
-- @author XEROX710
--
-- IN THE ORDER THE OPERATOR WROTE THEM, which is the contract `config/garages.lua`
-- states: the first exit is the one the bay is meant to use and the rest are the
-- fallbacks, in preference order. Answering nil is a REFUSAL and never a licence
-- to use the last one anyway.
--
-- Measured flat, against the DECLARED exit position, and only against vehicles
-- in the location's own routing bucket -- a car in another instance is not
-- standing in this bay. `skipId` is the vehicle being fetched: a car left
-- standing on the only exit of its own garage would otherwise be a car that can
-- never be recalled, which is the one occupancy that must not count.
--
-- A HOST THAT CANNOT LIST VEHICLES ANSWERS THE FIRST EXIT. There is then nothing
-- to measure and every exit reads as free, which is exactly what this module did
-- before there were exits at all; it is said once rather than refused, because a
-- garage that stops working on an older host is worse than one that occasionally
-- drops a car on another.
-- @param place table a location
-- @param skipId any the engine id of the vehicle being fetched, or nil
-- @return table|nil the exit
-- @return integer|nil which one it was, so the log can say
local function freeExit(place, skipId)
	local parked = {}
	local api = Open77.vehicles
	if type(api) == 'table' and type(api.all) == 'function' then
		local read, listed = pcall(api.all, place.bucket)
		if read and type(listed) == 'table' then
			for index = 1, #listed do
				local car = listed[index]
				local at = type(car) == 'table' and (type(car.position) == 'table' and car.position
					or car) or nil
				local x = at ~= nil and coordinate(at.x) or nil
				local y = at ~= nil and coordinate(at.y) or nil
				local id = type(car) == 'table' and car.id or nil
				if x ~= nil and y ~= nil and
					(skipId == nil or id == nil or tostring(id) ~= tostring(skipId)) then
					parked[#parked + 1] = { x = x, y = y }
				end
			end
		end
	elseif not reportedOccupancy then
		reportedOccupancy = true
		Open77.log.warn('[garages] this host cannot list vehicles, so no exit can be told from ' ..
			'an occupied one: every bring-out takes the first exit written')
	end

	for slot = 1, #place.exits do
		local exit = place.exits[slot]
		local free = true
		for index = 1, #parked do
			local dx, dy = parked[index].x - exit.x, parked[index].y - exit.y
			if dx * dx + dy * dy <= Access.EXIT_CLEARANCE_SQ then
				free = false
				break
			end
		end
		if free then return exit, slot end
	end
	return nil, nil
end

--- The point a request names, resolved against where the connection is standing.
-- THE ONE RESOLVER. The point underfoot, the routing bucket and the reach are
-- the same three questions whether the key is about to open a list, take a
-- vehicle out or put one away, and a second copy for the second job would be a
-- second answer to them.
--
-- A NAME MAY BE A POINT OR A GARAGE. `/opx.garages.bring garage1` is what an
-- operator types, and `garage1` is a garage with several points; the nearest
-- point OF THAT GARAGE is what they mean. A point key -- which only ever comes
-- off the wire -- is matched exactly.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point or garage name; the nearest point when omitted
-- @return spot|nil
-- @return Result|nil the refusal, when there is one
local function resolve(source, key)
	local at = pointOf(source)
	if at == nil then return nil, Result.Err('garages.noPosition') end

	local point = nil
	if key == nil or key == '' then
		point = Access.Nearest(spots, at.x, at.y)
	else
		point = Access.Spot(spots, key)
		if point == nil and garages[key] ~= nil then
			local mine = {}
			for _, candidate in ipairs(Access.PointsOf(garages[key])) do
				mine[candidate.key] = candidate
			end
			-- UNBOUNDED, and that is the difference between two refusals an
			-- operator reads. Asking for the nearest point WITHIN REACH answers
			-- nil for somebody standing across the street from the garage they
			-- named, and nil here means `noSuchSpot` -- "there is no garage
			-- here", about a garage that plainly exists. The reach is applied
			-- below, once, where its refusal says it was the distance.
			point = Access.Nearest(mine, at.x, at.y, math.huge)
		end
	end
	if point == nil then return nil, Result.Err('garages.noSuchSpot') end
	if point.bucket ~= at.bucket then return nil, Result.Err('garages.wrongBucket') end

	local flat = Access.FlatDistanceSquared(point, at.x, at.y)
	if flat == nil or flat > Access.USE_RADIUS_SQ then
		return nil, Result.Err('garages.tooFar', point.key)
	end
	return point, nil
end

--- Every vehicle the connection may bring out of the garage a point belongs to.
-- @author XEROX710
--
-- THE GARAGE'S WHOLE LIST, and that is the feature: a player standing at one
-- location sees what they left at every other one. `here` says which rows were
-- filed at this garage, so the list can show the rest as what they are -- a car
-- that is somewhere else and will be fetched to here.
-- @param source Source
-- @param key string|nil the point name; the nearest one when omitted
-- @return Result
function M.List(source, key)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end
	local point, refusal = resolve(source, key)
	if point == nil then return refusal end
	local built = garages[point.garage]
	if built == nil then return Result.Err('garages.noSuchSpot') end
	local allowed, gateRefusal = mayUse(source, built)
	if not allowed then return Result.Err(gateRefusal, built.label) end

	local owned = vehicles.List(data.citizenId)
	if not owned.ok then return owned end
	local rows = type(owned.value) == 'table' and owned.value or {}

	local listed = {}
	for index = 1, #rows do
		local row = rows[index]
		if eligible(row, built) then
			listed[#listed + 1] = {
				plate = row.plate,
				record = row.record,
				here = row.garage == built.key,
			}
		end
	end
	table.sort(listed, function(left, right)
		if left.here ~= right.here then return left.here end
		return left.plate < right.plate
	end)

	return Result.Ok({
		spot = point.key,
		garage = built.key,
		label = built.label,
		kind = built.kind,
		vehicles = listed,
	})
end

--- Places the recalling pilot at the controls of the aircraft just brought out.
-- @author XEROX710
--
-- THE HAND-OFF, AND THE ONLY ONE THERE IS. An AV that comes out of a pad
-- materialises hovering a lift above the marker, and the mount of a hovering
-- airframe is a thing a player has to go find. "Pilotable from inside" begins
-- INSIDE, so the seat the flight controls are authored at is handed over the
-- moment the hull exists -- the platform's own
-- `Open77.vehicles.warpPlayerIntoVehicle`, the same authoritative mount the
-- crew door uses, with `moveBucket = false` because the exit is already in the
-- player's own bucket and no exit lock because this is a recall and not a ride.
--
-- BEST-EFFORT, AND THAT IS DELIBERATE. A host too old for the call, a seat the
-- mount refuses, a pilot already seated (the command path can be typed from a
-- car) -- every one of those answers is "the player climbs in themselves",
-- which is what this call site always did. Nothing about the bring-out itself
-- depends on the seat being taken.
-- @param playerId number the recalling connection
-- @param vehicleId any the hull just created
-- @return string|nil the seat taken, when one was
local function seatPilot(playerId, vehicleId)
	local seat = Access.PilotSeat()
	if seat == nil then return nil end
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.warpPlayerIntoVehicle) ~= 'function' then
		return nil
	end
	-- Only a body on foot. A recall through the command may be typed while
	-- seated, and yanking a player out of one vehicle into another is not a
	-- hand-off, it is a hijack.
	if type(api.getPlayerSeat) == 'function' then
		local read, held = pcall(api.getPlayerSeat, playerId)
		if read and type(held) == 'table' then return nil end
	end
	local called, placed, refusal = pcall(api.warpPlayerIntoVehicle, playerId, vehicleId, seat, {
		-- The hull was created in the player's own bucket; moving them would be
		-- a routing change nobody asked for.
		moveBucket = false,
	})
	if not called or placed ~= true then
		Open77.log.warn(('[garages] %s is not placed at the controls of their own aircraft: %s')
			:format(tostring(playerId), tostring(called and refusal or placed)))
		return nil
	end
	Open77.log.info(('[garages] %s took the controls of their recalled aircraft in %s')
		:format(tostring(playerId), seat))
	return seat
end

--- Brings one of the connection's own vehicles out at a free exit of the
--- location it is standing at.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point or garage name; the nearest point when omitted
-- @param wanted string|nil a plate the caller claims
-- @return Result
function M.Bring(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end
	local point, refusal = resolve(source, key)
	if point == nil then return refusal end
	local built = garages[point.garage]
	local place = locationOf(point)
	if built == nil or place == nil then return Result.Err('garages.noSuchSpot') end
	local allowed, gateRefusal = mayUse(source, built)
	if not allowed then return Result.Err(gateRefusal, built.label) end

	local owned = vehicles.List(data.citizenId)
	if not owned.ok then return owned end
	local rows = type(owned.value) == 'table' and owned.value or {}
	local pick, why = choose(rows, built, wanted)
	if pick == nil then return Result.Err(why or 'garages.nothingHere', built.key) end

	-- THE VEHICLE BEING FETCHED DOES NOT BLOCK ITS OWN BAY. It is read through
	-- the contract that owns it rather than guessed at: a plate that is not out
	-- has no id, and an id that is not out cannot be standing on anything.
	--
	-- `LiveId` AND NOT `Get`, deliberately. `Get` answers the same fact among
	-- several others and reaches the database to do it, which YIELDS -- one more
	-- round trip on the hottest path here, for something already in that module's
	-- memory. A contract too old to have it costs the exemption and nothing else:
	-- the car then blocks its own bay, which is the behaviour a single-exit
	-- garage had before there were exits.
	local outNow = type(vehicles.LiveId) == 'function' and vehicles.LiveId(pick.plate) or nil

	local exit, slot = freeExit(place, outNow)
	if exit == nil then
		-- REFUSED AND SAID, which is the owner's own choice: "if no exit point is
		-- free, refuse and notify the player". The alternatives were a queue
		-- behind a car nobody may move and a vehicle created inside one.
		Open77.log.info(('[garages] %s: every exit of %s location %d is occupied; %s stays in')
			:format(tostring(data.citizenId), safe(built.key), place.index, safe(pick.plate)))
		return Result.Err('garages.noFreeExit', built.label)
	end

	-- The exit itself, never the player's side: that is the whole point of a
	-- marker. An AV is lifted clear of the pad it materialises on.
	local z = exit.z
	if Access.IsAv(pick.record) then z = z + Access.AvLift() end

	-- Flat, the shape the vehicles contract reads a named place in: a nested
	-- position would be read as no place at all and the car would land beside the
	-- player, a car's width off the marker.
	local spawned = vehicles.Spawn(source, pick.plate, {
		x = exit.x, y = exit.y, z = z,
		yaw = exit.heading,
		bucket = exit.bucket,
	})
	if not spawned.ok then return spawned end

	-- THE PILOT IS PLACED, NOT LEFT TO CLIMB. Only at a pad, and only for an
	-- AV: a ground garage hands over keys, not seats, and the seat is the one
	-- `config/avgarages.lua` names.
	local seated = nil
	if built.kind == M.KIND.AVPAD and Access.IsAv(pick.record)
		and type(spawned.value) == 'table' and spawned.value.id ~= nil then
		seated = seatPilot(source, spawned.value.id)
	end

	return Result.Ok({
		spot = point.key,
		garage = built.key,
		label = built.label,
		exit = slot,
		plate = pick.plate,
		id = spawned.value and spawned.value.id or nil,
		-- Forwarded, not decided here: whether the vehicle had to be moved is
		-- the vehicles contract's answer, and this half only repeats it.
		recalled = spawned.value and spawned.value.recalled or nil,
		-- The seat the recall placed the pilot in, when it placed them at all.
		seated = seated,
	})
end

--- The marker's one door: PUT AWAY when the connection is sitting in its own
--- vehicle, and BRING OUT otherwise.
-- ONE DECISION, MADE HERE. The player presses one key on one marker, and which
-- of the two things that key does is not something the client may claim: it is
-- read from the seat the host reports and the plate this module's own table
-- holds, both through the vehicles contract. A client that said "I am in my car"
-- would be a client deciding what gets stored.
--
-- Putting away is filed UNDER THE GARAGE and never under the point, which is the
-- whole of the rework: a car taken in at one door comes out at every location of
-- that garage, and `choose` ranks it first at all of them.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point name; the nearest one when omitted
-- @param wanted string|nil a plate the caller claims, for the bring-out half
-- @return Result
function M.Use(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end

	-- Read without trusting it: a contract too old to answer is "on foot", which
	-- is the bring-out half -- the behaviour every marker had before this.
	local seated = type(vehicles.Occupied) == 'function' and vehicles.Occupied(source) or nil
	if seated ~= nil and seated.ok and seated.value ~= nil then
		local point, refusal = resolve(source, key)
		if point == nil then return refusal end
		local built = garages[point.garage]
		if built == nil then return Result.Err('garages.noSuchSpot') end
		-- The put-away is a door too. A pad the player may not use is a pad
		-- they may not FILL: a division's hangar is not a garage anybody may
		-- leave a car in.
		local allowed, gateRefusal = mayUse(source, built)
		if not allowed then return Result.Err(gateRefusal, built.label) end
		local put = vehicles.Store(seated.value.plate, built.key)
		if not put.ok then return put end
		return Result.Ok({
			spot = point.key,
			garage = built.key,
			label = built.label,
			plate = seated.value.plate,
			stored = true,
		})
	end

	return M.Bring(source, key, wanted)
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- One request off the wire. Rate-limited, then answered either way.
local function onRequested(key, plate)
	local src = tonumber(source)
	if src == nil then return end
	if key ~= nil and type(key) ~= 'string' then key = nil end
	if plate ~= nil and type(plate) ~= 'string' then plate = nil end

	-- THE DECLARED COOLDOWN, WHICH WAS DECLARED AND NOT ENFORCED. `COOLDOWN_MS`
	-- is written in `config/garages.lua`, read into `Access.COOLDOWN_MS` and
	-- validated at boot -- and then nothing anywhere applied it. Only the
	-- six-per-ten-seconds window ran, so six bring-outs could land in one tick.
	--
	-- That is not merely untidy. `Store.FetchOne` YIELDS before the already-out
	-- guard in `modules/vehicles/server/main.lua`, so two `M.Bring` threads for
	-- the same plate both pass it and both reach `vehicles.create` -- two cars
	-- from one row. The race lives in `vehicles` and wants fixing there; this is
	-- the caller that can drive it, and the floor its own config already asked
	-- for is what stops it being driven.
	if Access.COOLDOWN_MS > 0 and OPX.Cooling(src, 'garages.bring', Access.COOLDOWN_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, key, false, 'garages.rateLimited')
		return
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, key, false, 'garages.rateLimited')
		return
	end

	CreateThread(function()
		local used = M.Use(src, key, plate)
		if not used.ok then
			-- The refusal AND a toast of the same code: without the toast the
			-- player would not know why nothing happened.
			OPX.Refuse(src, used.error, M.Operation.BRING)
			OPX.NotifyLocale(src, used.error, { garage = safe(used.detail) }, 'error')
			TriggerClientEvent(M.Event.ANSWER, src, key, false, used.error)
			Open77.log.info(('[garages] player %d refused %s: %s'):format(src, safe(key),
				tostring(used.error)))
			return
		end
		-- The action travels with the answer and into the line, because the three
		-- outcomes read the same from the outside and do not mean the same thing:
		-- a car that came from the roster, one that had to be moved to this
		-- marker first, and one the player just handed over.
		local value = used.value
		local action = value.stored and 'stored' or (value.recalled and 'recalled' or 'brought')
		if value.stored then
			OPX.NotifyLocale(src, 'garages.storedAway', { plate = value.plate }, 'success')
		else
			OPX.NotifyLocale(src, 'garages.broughtOut', { plate = value.plate }, 'success')
		end
		TriggerClientEvent(M.Event.ANSWER, src, key, true, nil, value.plate, action)
		Open77.log.info(('[garages] player %d %s %s at %s%s'):format(src,
			action == 'stored' and 'put away' or (action == 'recalled' and 'moved' or 'brought out'),
			safe(value.plate), safe(value.garage),
			value.exit ~= nil and (' exit ' .. tostring(value.exit)) or ''))
	end)
end

--- One list off the wire, for the menu point the player is standing on.
-- Counted against the same window a bring-out is: a client asking for a roster
-- in a loop is a client reading the database in a loop.
local function onListed(key)
	local src = tonumber(source)
	if src == nil then return end
	if key ~= nil and type(key) ~= 'string' then key = nil end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.LIST)
	end

	CreateThread(function()
		local listed = M.List(src, key)
		if not listed.ok then
			OPX.Refuse(src, listed.error, M.Operation.LIST)
			TriggerClientEvent(M.Event.VEHICLES, src, { spot = key, error = listed.error })
			return
		end
		TriggerClientEvent(M.Event.VEHICLES, src, listed.value)
	end)
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

-- Prints every garage: its kind, each location's points, and whether the garage
-- came from config or was adopted out of the legacy table.
local function report(source)
	local lines = {}
	local keys, adoptedCount, capturedCount = {}, 0, 0
	for key in pairs(garages) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local built = garages[keys[index]]
		local legacy = adopted[built.key] ~= nil and configGarages[built.key] == nil
		if legacy then adoptedCount = adoptedCount + 1 end
		local captured = captures[built.key] ~= nil
		if captured then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s %s %d location(s) %s'):format(
			built.key, built.kind, built.label, #built.locations,
			captured and 'captured' or legacy and 'legacy' or 'config')
		for _, place in ipairs(built.locations) do
			lines[#lines + 1] = ('  %d menu=%.2f,%.2f,%.2f in=%.2f,%.2f,%.2f yaw=%.1f ' ..
				'exits=%d bucket=%d'):format(place.index,
				place.menu.x, place.menu.y, place.menu.z,
				place.entry.x, place.entry.y, place.entry.z, place.entry.heading,
				#place.exits, place.bucket)
		end
	end
	lines[#lines + 1] = ('%d garage(s): %d from config, %d adopted, %d captured'):format(
		#keys, #keys - adoptedCount - capturedCount, adoptedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

-- Forward declaration (the same idiom as `askState` in jobs): the export
-- below formats with `configLines`, which is defined with the legacy adoption
-- AFTER the command block, and without this line the call reaches for a GLOBAL
-- `configLines` -- nil -- and dies inside the answer thread. The declaration
-- must stand before the closures that call it.
local configLines

--- The blocks that would check the legacy garages in, to whoever runs the
-- export. The journal is the HOST's copy of the same lines; this is the one a
-- person in game can read and paste.
--
-- ONE ANSWER PER GARAGE, and not one message for the lot: the answer channel
-- cuts a message at 8192 bytes, so eighteen blocks in one message is a dump the
-- operator receives half of, with the warning in a log they cannot see.
--
-- AND ONLY THE DB-ONLY GARAGES. A garage this file already names has nothing to
-- paste, and a block pasted twice is a duplicate key and a config error.
local function export(source)
	local keys = {}
	for key in pairs(adopted) do
		if configGarages[key] == nil then keys[#keys + 1] = key end
	end
	table.sort(keys)
	if #keys == 0 then
		return OPX.CommandResult(source, true,
			'every garage on this server is already named in config/garages.lua; nothing to paste')
	end
	CreateThread(function()
		for index = 1, #keys do
			-- ONE RESUME PER GARAGE, for the reason the boot loop above yields
			-- per row: every block formats a dozen strings, and a loop that
			-- formats the whole table in one resume is the shape of failure
			-- that has cost this codebase four outages.
			Wait(0)
			OPX.CommandResult(source, true,
				table.concat(configLines(adopted[keys[index]]), '\n'))
		end
		OPX.CommandResult(source, true,
			('%d garage(s) live only in opx77_garages; the block for each is above, ' ..
				'paste them into config/garages.lua'):format(#keys))
	end)
end

-- ── the pad capture ─────────────────────────────────────────────────────────

--- Builds one captured pad: one location whose menu, door and only exit are
-- the captured point -- the shape `adopt` gives a legacy spot and the
-- commented block in `config/avgarages.lua` declares -- with the annex's job
-- gate hung on it, because a captured pad is a pad like any other and is not a
-- door around the gate.
-- @param key string
-- @param label string
-- @param x number
-- @param y number
-- @param z number
-- @param heading number
-- @param bucket number
-- @return table|nil built
-- @return string|nil why
local function buildPad(key, label, x, y, z, heading, bucket)
	local block = {
		KIND = M.KIND.AVPAD,
		LABEL = label ~= '' and label or key,
		LOCATIONS = { {
			BUCKET = bucket,
			MENU = { X = x, Y = y, Z = z },
			ENTRY = { X = x, Y = y, Z = z, HEADING = heading },
			EXITS = { { X = x, Y = y, Z = z, HEADING = heading } },
		} },
	}
	local problems = {}
	local built = select(1, Access.CoerceGarages({ [key] = block }, problems))
	built = built[key]
	if built == nil then return nil, problems[1] or 'that pad was refused' end
	local annex = Access.Annex()
	if annex ~= nil then built.requirement = annex.gate end
	return built
end

--- Captures one AV pad where the operator stands and sets it live. The facing
-- is read because it is not decoration here: HEADING is the yaw a recalled AV
-- is created with, and it is the one fact a pad capture cannot guess. Yields.
-- @param player number
-- @param key string
-- @param label string
local function capture(player, key, label)
	local read, position = pcall(Open77.players.position, player)
	position = read and type(position) == 'table' and position or nil
	local x = position ~= nil and coordinate(position.x) or nil
	local y = position ~= nil and coordinate(position.y) or nil
	local z = position ~= nil and coordinate(position.z) or nil
	if x == nil or y == nil or z == nil then
		return OPX.CommandResult(player, false,
			'your position could not be read; stand in the world first')
	end
	local heading = coordinate(position.heading) or 0.0
	local bucket = integer(position.bucket) or 0
	-- One validator, and it is the config file's own: a captured pad is read
	-- through `CoerceGarages` exactly as a block pasted into
	-- `config/avgarages.lua` is.
	local built, why = buildPad(key, label, x, y, z, heading, bucket)
	if built == nil then
		Open77.log.warn(('[garages] player %d capture of %s refused: %s')
			:format(player, tostring(key), tostring(why)))
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = Store.UpsertPad({
		key = built.key, label = built.label,
		x = x, y = y, z = z,
		heading = heading, bucket = bucket, capturedBy = tostring(player),
	})
	if type(saved) ~= 'table' or saved.ok ~= true then
		local detail = type(saved) == 'table' and saved.detail or 'no answer'
		Open77.log.warn(('[garages] player %d could not save the capture of %s: %s')
			:format(player, tostring(built.key), tostring(detail)))
		return OPX.CommandResult(player, false, 'could not save: ' .. tostring(detail))
	end

	captures[built.key] = built
	rebuild()
	syncAll()
	Open77.log.info(('[garages] pad %s captured at %.2f,%.2f,%.2f heading=%.1f bucket=%d by %d')
		:format(built.key, x, y, z, heading, bucket, player))
	OPX.CommandResult(player, true,
		('%s set -- paste this into config/avgarages.lua to survive a database reset:\n%s')
			:format(built.key, table.concat(configLines(built), '\n')))
end

--- Takes one captured pad away, and nothing else: a pad config names is not
-- the command's to take, and the answer says which file does own it. Yields.
-- @param player number
-- @param key string
local function uncapture(player, key)
	if captures[key] == nil then
		return OPX.CommandResult(player, false, configGarages[key] ~= nil
			and 'that pad comes from config; edit config/avgarages.lua to move or remove it'
			or 'no captured pad named ' .. key)
	end
	local gone = Store.DeletePad(key)
	if type(gone) ~= 'table' or gone.ok ~= true then
		return OPX.CommandResult(player, false, 'could not delete: '
			.. tostring(type(gone) == 'table' and gone.detail or 'no answer'))
	end
	captures[key] = nil
	rebuild()
	syncAll()
	Open77.log.info(('[garages] pad %s removed by %d'):format(key, player))
	OPX.CommandResult(player, true, key .. ' removed.')
end

--- Registers the three commands that are left.
-- `add` and `remove` are gone: they wrote a place every player uses into a table
-- only one host had. See the header. `export` reads that table and writes
-- nothing -- it hands back the blocks that would check it in.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.list, { restricted = true, help = 'garages.help.list' }, function(source)
		report(source)
	end)

	register(names.export, { restricted = true, help = 'garages.help.export' }, function(source)
		export(source)
	end)

	register(names.bring, {
		restricted = true,
		help = 'garages.help.bring',
		params = {
			{ name = 'key', optional = true, help = locale('garages.help.bringKey') },
			{ name = 'plate', optional = true, help = locale('garages.help.bringPlate') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or nil
		local plate = type(args[2]) == 'string' and args[2] or nil
		CreateThread(function()
			local brought = M.Bring(source, key, plate)
			if not brought.ok then
				OPX.NotifyLocale(source, brought.error, { garage = safe(brought.detail) }, 'error')
				return OPX.CommandResult(source, false, tostring(brought.error))
			end
			OPX.NotifyLocale(source, 'garages.broughtOut', { plate = brought.value.plate }, 'success')
			OPX.CommandResult(source, true, ('%s out at %s'):format(brought.value.plate,
				brought.value.label))
		end)
	end)

	-- THE PAD CAPTURE, the same bargain as `/opx.headquarters.add`. The names
	-- come from `config/avgarages.lua` COMMANDS, and an annex that is off names
	-- nothing -- which registers nothing.
	local annex = Access.Annex()
	local padNames = annex ~= nil and annex.commands or {}

	register(padNames.add, {
		restricted = true,
		help = 'avgarages.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('avgarages.help.addKey') },
			{ name = 'label', optional = true, help = locale('avgarages.help.addLabel') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > Access.MAX_KEY then
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(Access.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a pad whose key the operator never
			-- learned could not be removed or checked in afterwards.
			local index = 0
			repeat index = index + 1
				until captures['maxtac_av' .. index] == nil and garages['maxtac_av' .. index] == nil
			key = 'maxtac_av' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end
		CreateThread(function()
			capture(source, key, label)
		end)
	end)

	register(padNames.remove, {
		restricted = true,
		help = 'avgarages.help.remove',
		params = { { name = 'key', help = locale('avgarages.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		CreateThread(function()
			uncapture(source, key)
		end)
	end)
end

-- ── the legacy adoption ─────────────────────────────────────────────────────

--- Turns one row of `opx77_garages` into a garage of one location.
-- @author XEROX710
--
-- THIS IS THE WHOLE MIGRATION, and it is written as code rather than as a SQL
-- script for one reason: a spot in that table is a spot NOBODY HAS A COPY OF.
-- The commands that wrote it are gone, so without this every marker an operator
-- ever placed in game disappears the moment this version starts -- silently,
-- because an empty `GARAGES` block is a valid config.
--
-- A legacy spot was ONE POINT that did everything: you stood on it, pressed the
-- key, and the car appeared where you were standing. So it adopts as one
-- location whose menu, door and only exit are that same point, which is exactly
-- what it did before. The key is kept, which is what makes it seamless: a
-- vehicle's `garage` column already holds it, so not one row is rewritten.
--
-- It is READ-ONLY. Nothing writes to `opx77_garages` any more and nothing drops
-- it: an operator who has not yet checked their spots in can roll back to the
-- previous version and still have them.
local function adopt(row)
	local key = row.spot_key
	local block = {
		KIND = row.kind,
		LABEL = row.label,
		LOCATIONS = { {
			BUCKET = row.bucket,
			MENU = { X = row.x, Y = row.y, Z = row.z },
			ENTRY = { X = row.x, Y = row.y, Z = row.z, HEADING = row.heading },
			EXITS = { { X = row.x, Y = row.y, Z = row.z, HEADING = row.heading } },
		} },
	}
	local problems = {}
	local built = select(1, Access.CoerceGarages({ [key] = block }, problems))
	return built[key], problems[1]
end

--- The block an operator pastes into `config/garages.lua` to keep a garage.
-- CLEAN LINES, with no log prefix on them: the journal at every start and the
-- export command below answer the SAME block -- the host's copy and the
-- person's -- and a prefix is a thing you have to strip before pasting. Written
-- at every start for every adopted garage, for the reason the old capture line
-- was written once into one player's chat box and then lost.
function configLines(built)
	local lines = { ('%s = { LABEL = %q, KIND = %q, LOCATIONS = {')
		:format(built.key, built.label, built.kind) }
	for _, place in ipairs(built.locations) do
		lines[#lines + 1] = ('  { BUCKET = %d,'):format(place.bucket)
		lines[#lines + 1] = ('    MENU = { X = %.2f, Y = %.2f, Z = %.2f },')
			:format(place.menu.x, place.menu.y, place.menu.z)
		lines[#lines + 1] = ('    ENTRY = { X = %.2f, Y = %.2f, Z = %.2f, ' ..
			'HEADING = %.1f },'):format(place.entry.x, place.entry.y, place.entry.z,
			place.entry.heading)
		lines[#lines + 1] = '    EXITS = {'
		for _, exit in ipairs(place.exits) do
			lines[#lines + 1] = ('      { X = %.2f, Y = %.2f, Z = %.2f, ' ..
				'HEADING = %.1f },'):format(exit.x, exit.y, exit.z, exit.heading)
		end
		lines[#lines + 1] = '    } },'
	end
	lines[#lines + 1] = '} },'
	return lines
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and contributes this module's table. Never yields.
-- @author XEROX710
function M.Init()
	configGarages = Access.GARAGES
	adopted = {}
	captures = {}
	rebuild()
	windows = {}
	running = false
	reportedOccupancy = false
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the garages contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('garages', 1, {
		Bring = M.Bring,
		Use = M.Use,
		List = M.List,
		-- The DRAWN POINTS, by point key. What a marker is, and nothing about
		-- what a vehicle is filed under.
		Spots = function() return spots end,
		-- THE GARAGES, by the key a vehicle's `garage` column holds. The
		-- dealership names one of these as a delivery destination, and naming a
		-- point there would file a car under a marker rather than under a
		-- garage -- which is a car that comes out of exactly one door of one
		-- location and nowhere else.
		Garages = function() return garages end,
		State = function()
			local listed = {}
			for key, built in pairs(garages) do
				listed[key] = { kind = built.kind, label = built.label,
					locations = #built.locations,
					gated = built.requirement ~= nil,
					adopted = adopted[key] ~= nil and configGarages[key] == nil }
			end
			return Result.Ok({ garages = listed })
		end,
	})
end

--- Resolves the contracts, adopts the legacy rows and wires the doors.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	vehicles = OPX.Api.Get('vehicles')
	if character == nil then
		Open77.log.warn('[garages] no character contract: nothing can be proved owned, so ' ..
			'every request is refused')
	end
	if vehicles == nil then
		Open77.log.error('[garages] no vehicles contract: no marker can bring anything out')
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[garages] config: ' .. line)
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.REQUEST, onRequested)
	RegisterNetEvent(M.Event.LIST, onListed)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then windows[player] = nil end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[garages] the legacy spots could not be read: ' ..
				tostring(rows.detail))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted, refused, shadowed = 0, 0, 0
		for index = 1, #loaded do
			-- ONE RESUME PER ROW. Every adoption coerces a whole garage and every
			-- config line below formats a dozen strings, and a loop that did all
			-- of both in the resume that read the database would run out of
			-- instruction budget partway down -- the coroutine unwinding with no
			-- error, no log and no refusal, leaving the garages it got to and
			-- silently dropping the rest. That failure has cost this codebase
			-- four outages; `modules/admin/client/target.lua` `register()` is the
			-- worked example and says so at length. A frame per row costs nothing
			-- at boot.
			Wait(0)
			local built, why = adopt(loaded[index])
			if built == nil then
				refused = refused + 1
				Open77.log.warn('[garages] a legacy spot was refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				adopted[built.key] = built
			end
		end
		rebuild()
		for key in pairs(adopted) do
			if configGarages[key] ~= nil then shadowed = shadowed + 1 end
		end
		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
		Open77.log.info(('[garages] ready: %d from config, %d adopted from the legacy table, ' ..
			'%d refused, %d shadowed by a garage of the same name in config'):format(
			OPX.Table.Count(configGarages), accepted - shadowed, refused, shadowed))

		-- EVERY ADOPTED GARAGE, AS THE CONFIG BLOCK THAT WOULD RECREATE IT.
		--
		-- The line the old `add` command handed the operator was handed to one
		-- player, once, in a chat box, and is a line nobody has. The whole set is
		-- written at every start instead, so emptying the table, restoring an
		-- older dump or moving to another host costs a scroll of the journal
		-- rather than every garage on the server. THIS IS THE OTHER HALF OF THE
		-- MIGRATION: the adoption keeps the server running, and these lines are
		-- how an operator stops needing it.
		local keys = {}
		for key in pairs(adopted) do
			if configGarages[key] == nil then keys[#keys + 1] = key end
		end
		table.sort(keys)
		for index = 1, #keys do
			Wait(0)
			for _, line in ipairs(configLines(adopted[keys[index]])) do
				Open77.log.info('[garages] config line: ' .. line)
			end
		end
		if #keys > 0 then
			Open77.log.warn(('[garages] %d garage(s) exist only in opx77_garages. The commands ' ..
				'that made them are gone: paste the config line(s) above into ' ..
				'config/garages.lua, or they are one dropped database away from lost')
				:format(#keys))
		end
	end)

	-- THE PADS THE CAPTURE COMMAND ALREADY PLACED. Read up whatever the table
	-- answers -- an operator has to be able to capture into a table that had
	-- nothing -- one resume per row for the reason above, and the merge runs
	-- when the last one is in.
	CreateThread(function()
		local rows = Store.FetchPads()
		if type(rows) ~= 'table' or rows.ok ~= true then
			Open77.log.error('[garages] captured pads could not be read: '
				.. tostring(type(rows) == 'table' and rows.detail or 'no answer'))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted = 0
		for index = 1, #loaded do
			Wait(0)
			local record = loaded[index]
			local built, why = nil, 'not a row'
			if type(record) == 'table' then
				built, why = buildPad(record.pad_key, record.label, record.x, record.y,
					record.z, record.heading, record.bucket)
			end
			if built ~= nil then
				accepted = accepted + 1
				captures[built.key] = built
			else
				Open77.log.warn('[garages] a captured pad row was refused and skipped: '
					.. tostring(why))
			end
		end
		rebuild()
		syncAll()
		Open77.log.info(('[garages] %d captured pad(s) read from opx77_avpads'):format(accepted))
	end)

	-- A sweep for the rate-limit windows, so a long session does not accumulate
	-- one per player that ever asked.
	CreateThread(function()
		while running do
			Wait(WINDOW_GC_MS)
			local at = OPX.Now()
			for player, window in pairs(windows) do
				if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
			end
		end
	end)
end

--- Stops the sweep. The garages are config, so there is nothing to write.
-- @author XEROX710
function M.Stop()
	running = false
	windows = {}
end
