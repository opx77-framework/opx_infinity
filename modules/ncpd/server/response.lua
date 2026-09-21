--- The response: what the city puts on the street for a wanted player.
-- @author XEROX710
--
-- THE LEDGER DECIDES THE STAGE; THIS FILE PUTS SOMETHING AT IT. It never scores
-- anything, never reads a crime and never decides who is wanted -- it takes a
-- stage, reads the config's own response rows for it, and stands the configured
-- records in the world around the player the ledger named.
--
-- WHY THE MODULE SPAWNS ANYTHING AT ALL. The engine already wires a response to
-- each heat stage (`OnHeatChanged` spawns that stage's units), and the platform
-- deliberately suppresses it for the session because vanilla prevention would
-- otherwise police every player in the world from one player's stars. The units
-- here are the platform's OWN entities -- `Open77.vehicles.create` and
-- `Open77.npcs.create` -- which are server-authoritative, carry network identity
-- and are therefore kept, exactly like the pursuit mode's own roadblocks. That
-- is what makes a wanted player's response real today without changing the
-- session's population policy, which is an operator decision and not this
-- module's to make.
--
-- THE AV IS NOT SPAWNED HERE, AND CANNOT BE. `PreventionSpawnSystem.RequestAVSpawn`
-- is a scripted method that runs inside a client's own script frame, so the AV is
-- REQUESTED by the wanted player's own client (see `client/main.lua`) and the
-- frame's own fly-in, propulsion note and red warning lines arrive with it. What
-- this file does at the MaxTac stage is mark the crossing so the client asks.
--
-- TROOPERS ARE BOTS BY DEFAULT, AND THE CONFIG SAYS SO. `MAXTAC.FILL` decides
-- whether an empty seat becomes an engine trooper; this file counts the players
-- who hold the division's right or job and fills the rest of `SQUAD.SEATS` with
-- the engine's own trooper records, so an empty division never means an empty
-- street. Seating a PLAYER as a trooper needs a duty/teleport half the platform
-- does not have yet, and pretending otherwise here would be a squad that never
-- arrives.
--
-- EVERY SPAWN IS NAMED IN THE LOG, INCLUDING THE FAILURES. A refused record is a
-- street with nobody on it, and `%s_api_unavailable:%s` is the shape that says
-- which permission or which host contract is missing rather than leaving the
-- reader to infer it from an empty scene.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

local Response = {}
M.Response = Response

--- What this module has standing in the world, per character.
-- @field stage number the stage these units answer
-- @field vehicles table[] ids returned by the host
-- @field npcs table[] ids returned by the host
local deployed = {}

--- A host call that cannot take the module down with it.
-- The pursuit mode's own idiom, and the reason is the same: a record the host
-- refuses answers `nil, reason`, while a call on a host that does not have the
-- contract at all raises. Both have to be a named refusal here.
-- @param namespace string `vehicles` or `npcs`
-- @param name string
-- @return any id, or nil
-- @return string|nil the refusal
local function safeCall(namespace, name, ...)
	local api = Open77 and Open77[namespace]
	if type(api) ~= 'table' or type(api[name]) ~= 'function' then
		return nil, ('%s_api_unavailable:%s'):format(namespace, name)
	end
	local ok, result, reason = pcall(api[name], ...)
	if not ok then return nil, tostring(result) end
	if result == nil then return nil, reason or 'rejected' end
	return result, reason
end

--- Where one player is, and the bucket they are in.
-- @param playerId number
-- @return table|nil `{ x, y, z, bucket }`
local function where(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = tonumber(position.bucket) or 0 }
end

--- A point `radius` metres from `centre`, on one of `count` evenly spaced bearings.
-- The first bearing is always +X, so a two-unit response stands either side of
-- the player rather than both on the same side.
-- @param centre table `{ x, y, z }`
-- @param index number 1-based
-- @param count number
-- @param radius number
-- @return table a position
local function bearing(centre, index, count, radius)
	local radians = (index - 1) / math.max(1, count) * math.pi * 2.0
	return {
		x = centre.x + math.cos(radians) * radius,
		y = centre.y + math.sin(radians) * radius,
		z = centre.z,
	}
end

--- The heading from one point to another, in the game's degrees.
-- @param from table
-- @param to table
-- @return number
local function facing(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(dy, dx))
end

--- The host's own vehicle flag mask.
-- @param spec table `{ siren = boolean, locked = boolean, immortal = boolean }`
-- @return integer|nil nil when the host's flag table is unavailable
local function vehicleFlags(spec)
	local flags = Open77 and Open77.vehicles and Open77.vehicles.flags
	if type(flags) ~= 'table' then return nil end
	local mask = flags.lightsOn or 0
	if spec.siren ~= false then mask = mask | (flags.sirenOn or 0) end
	if spec.locked == true then mask = mask | (flags.locked or 0) end
	if spec.immortal == true then mask = mask | (flags.immortal or 0) end
	return mask
end

--- Stands one configured vehicle at a position.
-- @return string|nil id
-- @return string|nil refusal
local function carry(record, at, yaw, bucket, spec)
	local definition = {
		record = record,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = yaw,
		bucket = bucket,
		health = 1.0,
		flags = vehicleFlags(spec),
	}
	return safeCall('vehicles', 'create', definition)
end

--- Stands one configured character at a position, facing the player.
-- @return string|nil id
-- @return string|nil refusal
local function officer(record, at, yaw, bucket)
	local ai = Open77 and Open77.npcs and Open77.npcs.ai
	local damage = Open77 and Open77.npcs and Open77.npcs.damage
	return safeCall('npcs', 'create', {
		record = record,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = yaw,
		bucket = bucket,
		-- Mortal on purpose: a wanted player is allowed to fight their way out,
		-- and an immortal response is a wall rather than a chase.
		damagePolicy = damage and damage.mortal or nil,
		aiMode = ai and ai.native or nil,
		despawnWhenUnobserved = false,
		persistent = false,
	})
end

--- The roster a stage's officers are drawn from.
-- MaxTac answers with its own ground records; every NCPD stage with the config's
-- police roster.
-- @param division string|nil
-- @return table[] records
local function rosterFor(division)
	local ncpd = M.Settings.NCPD
	local officers = type(ncpd) == 'table' and ncpd.OFFICERS or {}
	if division == M.DIVISION.MAXTAC then
		local maxtac = Law.Maxtac
		if maxtac ~= nil and type(maxtac.Ground) == 'table' and #maxtac.Ground > 0 then
			return maxtac.Ground
		end
	end
	if type(officers) ~= 'table' then return {} end
	return officers
end

--- Takes everything this character's response put down.
-- @param citizenId string
-- @return integer how many units were removed
local function dismantle(citizenId)
	local held = deployed[citizenId]
	if held == nil then return 0 end
	deployed[citizenId] = nil

	local removed = 0
	for _, id in ipairs(held.vehicles or {}) do
		if safeCall('vehicles', 'remove', id) then removed = removed + 1 end
	end
	for _, id in ipairs(held.npcs or {}) do
		if safeCall('npcs', 'remove', id) then removed = removed + 1 end
	end
	return removed
end

--- Removes everything a character's response owns. Safe to call for anybody.
-- @param citizenId string
-- @return integer how many units were removed
function Response.Release(citizenId)
	return dismantle(citizenId)
end

--- Stands the response for one stage up, and takes the previous stage down.
--
-- The previous stage is always removed first, including when the new stage is 0:
-- a player who has been cleared has nothing standing, and a player who climbed
-- must not keep the cars of three stages at once.
-- @param citizenId string
-- @param playerId number
-- @param stage number the engine's heat stage to answer
-- @return table a `Result`: `{ ok, value = { stage, vehicles, npcs, refused, av } }`
function Response.Apply(citizenId, playerId, stage)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end

	local freed = dismantle(citizenId)
	if stage == nil or stage == 0 then
		return OPX.Result.Ok({ stage = 0, vehicles = 0, npcs = 0, freed = freed, av = false })
	end

	local row = Law.Stage(stage)
	if row == nil or row.Response == nil then
		return OPX.Result.Err('ncpd.unknownStage', tostring(stage))
	end

	local at = where(playerId)
	if at == nil then
		return OPX.Result.Err('ncpd.noPosition', tostring(playerId))
	end

	local division = row.Division
	local response = row.Response
	local held = { stage = stage, division = division, vehicles = {}, npcs = {}, refused = {} }
	deployed[citizenId] = held

	-- How many officers this stage tried to stand. A stage whose officers were
	-- all refused is not a response with fewer officers -- it is cars parked in
	-- the street, which in game reads as a squad that arrived and stopped. The
	-- count is what lets the guard at the end tell those two apart.
	local attempted = 0

	-- ── the cars ────────────────────────────────────────────────────────────
	local vehicles = type(response.VEHICLES) == 'table' and response.VEHICLES or {}
	for index = 1, #vehicles do
		local at2 = bearing(at, index, #vehicles, 14.0)
		local id, reason = carry(vehicles[index], at2, facing(at2, at), at.bucket, { siren = true })
		if id == nil then
			held.refused[#held.refused + 1] = ('%s:%s'):format(vehicles[index], tostring(reason))
		else
			held.vehicles[#held.vehicles + 1] = id
		end
	end

	-- ── the officers ────────────────────────────────────────────────────────
	local roster = rosterFor(division)
	local units = tonumber(response.UNITS) or 0
	for index = 1, units do
		local record = roster[((index - 1) % math.max(1, #roster)) + 1]
		if record == nil then break end
		local at2 = bearing(at, index, units, 8.0)
		attempted = attempted + 1
		local id, reason = officer(record, at2, facing(at2, at), at.bucket)
		if id == nil then
			held.refused[#held.refused + 1] = ('%s:%s'):format(record, tostring(reason))
		else
			held.npcs[#held.npcs + 1] = id
		end
	end

	-- ── the roadblock, at the stages that declare one ────────────────────────
	local ncpd = M.Settings.NCPD
	local blockSpec = type(ncpd) == 'table' and ncpd.ROADBLOCK or nil
	if response.ROADBLOCK == true and type(blockSpec) == 'table' and #vehicles > 0 then
		local ahead = tonumber(blockSpec.AHEAD_METERS) or 12.0
		local spacing = tonumber(blockSpec.SPACING_METERS) or 4.0
		local centre = { x = at.x, y = at.y + ahead, z = at.z }
		local cars = math.max(1, math.floor(tonumber(blockSpec.CARS) or 2))
		for index = 1, cars do
			local slot = index - (cars + 1) / 2
			local at2 = { x = centre.x + slot * spacing, y = centre.y, z = centre.z }
			-- Across the player's path rather than along it: the blockade
			-- presents its flank, which is what makes it a wall.
			local id, reason = carry(vehicles[1], at2, facing(at, at2) + 90.0, at.bucket,
				{ siren = true, locked = true, immortal = true })
			if id == nil then
				held.refused[#held.refused + 1] = ('roadblock:%s:%s'):format(vehicles[1], tostring(reason))
			else
				held.vehicles[#held.vehicles + 1] = id
			end
		end
		local standing = math.max(0, math.floor(tonumber(blockSpec.OFFICERS) or 0))
		for index = 1, standing do
			local record = roster[((index - 1) % math.max(1, #roster)) + 1]
			if record == nil then break end
			local at2 = bearing(centre, index, standing, 4.0)
			attempted = attempted + 1
			local id, reason = officer(record, at2, facing(at, at2), at.bucket)
			if id == nil then
				held.refused[#held.refused + 1] = ('roadblock:%s:%s'):format(record, tostring(reason))
			else
				held.npcs[#held.npcs + 1] = id
			end
		end
	end

	-- ── MaxTac: the squad, and the AV the client is about to ask for ─────────
	local av = false
	local maxtac = Law.Maxtac
	if division == M.DIVISION.MAXTAC and maxtac ~= nil then
		av = true

		-- The ground car, unless the squad is already arriving by air.
		if type(maxtac.Vehicle) == 'string' and maxtac.Vehicle ~= '' then
			local at2 = bearing(at, 1, 2, 18.0)
			local id, reason = carry(maxtac.Vehicle, at2, facing(at2, at), at.bucket, { siren = true })
			if id == nil then
				held.refused[#held.refused + 1] = ('%s:%s'):format(maxtac.Vehicle, tostring(reason))
			else
				held.vehicles[#held.vehicles + 1] = id
			end
		end

		-- The squad. Seats come from the config; the engine's own trooper
		-- records fill every one of them when `FILL` is `bots`.
		local seats = type(maxtac.Squad) == 'table' and tonumber(maxtac.Squad.SEATS) or nil
		seats = math.max(0, math.floor(seats or #maxtac.Troopers))
		local radius = type(maxtac.Squad) == 'table' and tonumber(maxtac.Squad.INSERTION_RADIUS) or 40.0
		local filling = maxtac.Fill ~= 'players'
		local placeable = math.min(seats, #maxtac.Troopers)
		if filling and placeable > 0 then
			for index = 1, placeable do
				local at2 = bearing(at, index, placeable, radius)
				attempted = attempted + 1
				local id, reason = officer(maxtac.Troopers[index], at2, facing(at2, at), at.bucket)
				if id == nil then
					held.refused[#held.refused + 1] = ('%s:%s'):format(maxtac.Troopers[index], tostring(reason))
				else
					held.npcs[#held.npcs + 1] = id
				end
			end
		end

		held.seats = seats
		held.filled = filling and placeable or 0
	end

	-- ── a unit is the car AND the officers in it ────────────────────────────
	--
	-- The last refusal shape this can stand down is the empty one: every officer
	-- the stage asked for was refused, so what is left on the street is metal
	-- nobody is in. Taking those cars back down makes a missing permission read
	-- as nothing standing plus a named refusal rather than as a squad that
	-- arrived, parked and stopped -- the difference between a bug an operator
	-- can see and a scene that just looks broken in game.
	if attempted > 0 and #held.npcs == 0 and #held.vehicles > 0 then
		local parked = #held.vehicles
		for _, id in ipairs(held.vehicles) do
			if safeCall('vehicles', 'remove', id) then freed = freed + 1 end
		end
		held.vehicles = {}
		held.refused[#held.refused + 1] =
			('ncpd.noOfficers:%d_car(s):%d_officer(s)_refused'):format(parked, attempted)
	end

	return OPX.Result.Ok({
		stage = stage,
		division = division,
		vehicles = #held.vehicles,
		npcs = #held.npcs,
		freed = freed,
		av = av,
		refused = held.refused,
		seats = held.seats,
		filled = held.filled,
	})
end

--- What one character's response has standing, without touching the world.
-- @param citizenId string
-- @return table `{ stage, division, vehicles, npcs }`, zeroes when nothing is up
function Response.Status(citizenId)
	local held = deployed[citizenId]
	if held == nil then
		return { stage = 0, division = nil, vehicles = 0, npcs = 0 }
	end
	return {
		stage = held.stage,
		division = held.division,
		vehicles = #(held.vehicles or {}),
		npcs = #(held.npcs or {}),
	}
end

--- How many characters have a response standing.
-- @return integer
function Response.Count()
	local total = 0
	for _ in pairs(deployed) do total = total + 1 end
	return total
end

--- Takes every response down. The module's `Stop` uses it: a restart must not
--- leave a stage's cars standing with nothing left to remove them.
-- @return integer how many units were removed
function Response.ReleaseAll()
	local removed = 0
	for citizenId in pairs(deployed) do
		removed = removed + dismantle(citizenId)
	end
	return removed
end
