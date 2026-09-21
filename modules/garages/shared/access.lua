--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- WHAT A SPOT IS, AND WHO DECIDES IT. The record, the two input shapes that
-- normalise into it, the marker look and the coordinate box are all
-- `lib/shared/spots.lua`, and this file only names this module's own words to
-- them: its noun, its two KINDs, its key width and its fallback marker. That is
-- not tidying. `modules/dealership/shared/access.lua` held 334 `diff`-clean
-- identical lines of it, and the two must agree exactly or a car bought at a
-- dealer cannot be recalled at the garage beside it.
--
-- WHAT IS STILL THIS MODULE'S. Everything below the vocabulary: which distances
-- and cadences it scans at, how long a capture may take, and what a broken one
-- of those reads as. Those are numbers about THIS surface, not about what a spot
-- is, and a shared file that owned them would be forcing a dealer and a garage
-- to poll at the same rate for no reason.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a radius outside the engine's range reads as a
-- warning at boot rather than a raise inside a scan or a network handler. Only X
-- and Y are ever measured against; Z is validated and then carried to the create
-- call.

local M = OPX.Modules.Get('garages')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box and the two coercions over it, in `lib/shared/spots.lua`. Kept
-- as names on `Access` because the whole module already reads spot rules through
-- `Access` and a caller should not have to know which of them is shared.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer

-- The two kinds. A style or a shape outside the engine's own sets is refused by
-- `Open77.markers` with a status, so those live in `lib/shared/spots.lua` beside
-- the resolver that falls back to them.
local KINDS = { [M.KIND.GARAGE] = true, [M.KIND.AVPAD] = true }
Access.KINDS = KINDS

-- The two roles a DRAWN point may have. An exit is not one: nothing is drawn at
-- an exit and no key is pressed on one.
local ROLES = { [M.ROLE.MENU] = true, [M.ROLE.ENTRY] = true }
Access.ROLES = ROLES

--- The largest allowed GARAGE key, which is what a vehicle's `garage` column
--- holds and therefore the width that column is declared at.
Access.MAX_KEY = 48

--- The largest allowed POINT key. Longer than a garage key because a point key
--- is DERIVED from one -- `<garage>#<location>` and `<garage>#<location>.in` --
--- and a garage named at the full 48 would otherwise build points nothing would
--- accept. Nothing stores a point key: it exists on the wire and in this
--- process, which is why it may be wider than any column.
Access.MAX_POINT_KEY = 64

-- This module's words for the shared record: a point has a KIND, because a
-- garage and an AV pad are drawn and used differently, and a HEADING, because a
-- vehicle is CREATED at an entry and at an exit and something has to say which
-- way it faces.
local SPEC = {
	noun = 'spot',
	maxKey = Access.MAX_POINT_KEY,
	kinds = KINDS,
	kindNames = 'garage, avpad',
	heading = true,
}

--- Normalises one config or database row, in the operator's upper-case spelling.
-- @author XEROX710
-- @param key string
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromDefinition(key, raw)
	local spot, why = OPX.Spots.FromDefinition(SPEC, key, raw)
	if spot == nil then return nil, why end
	return Access.Attach(spot, raw)
end

--- Hangs the three fields the shared record knows nothing about onto a point.
-- @author XEROX710
--
-- `lib/shared/spots.lua` IS THE VOCABULARY OF A PLACE and deliberately not of a
-- garage: it knows a key, a position, a bucket and a look, and five modules
-- share it on those terms. Which GARAGE a point belongs to, which of its
-- LOCATIONS, and whether it is the menu or the door are facts about this module
-- alone, so they are attached here rather than pushed into a record four other
-- modules would then carry three unread fields of.
--
-- The defaults are what a point with nothing said about it means: it belongs to
-- the garage of its own name, at its first location, and it is the menu. That is
-- exactly a spot of the shape this module had before the rework, which is what
-- lets a legacy row and a test's hand-built spot both go straight through.
-- @param spot table
-- @param raw table|nil the definition or wire row it came from
-- @return table the same spot
function Access.Attach(spot, raw)
	raw = type(raw) == 'table' and raw or {}
	local garage = raw.GARAGE or raw.garage
	spot.garage = (type(garage) == 'string' and garage ~= '') and garage or spot.key
	local role = raw.ROLE or raw.role
	role = type(role) == 'string' and role:lower() or nil
	spot.role = (role ~= nil and ROLES[role]) and role or M.ROLE.MENU
	local at = OPX.Spots.Integer(raw.LOCATION or raw.location)
	spot.location = (at ~= nil and at >= 1) and at or 1
	return spot
end

--- Normalises one point off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	local spot, why = OPX.Spots.FromWire(SPEC, raw)
	if spot == nil then return nil, why end
	return Access.Attach(spot, raw)
end

--- The fields of one point, as the wire and the SYNC event carry them.
-- The three this module adds travel with it: a client that knew a point's
-- position and not which garage it opens could draw a marker and could not name
-- what pressing the key would list.
-- @author XEROX710
-- @param spot table
-- @return table
function Access.Serialise(spot)
	local wire = OPX.Spots.Serialise(spot)
	wire.garage = spot.garage
	wire.role = spot.role
	wire.location = spot.location
	return wire
end

--- The key one drawn point is known by, derived from its garage and never
--- stored. `<garage>#<location>` is the menu and `<garage>#<location>.in` the
--- door, so a key read in a log names the garage, which location, and which of
--- the two it is, without a lookup.
-- @author XEROX710
-- @param garageKey string
-- @param location integer
-- @param role string
-- @return string
function Access.PointKey(garageKey, location, role)
	if role == M.ROLE.ENTRY then
		return ('%s#%d.in'):format(garageKey, location)
	end
	return ('%s#%d'):format(garageKey, location)
end

--- Builds a key -> spot table from a list of definitions.
-- @author XEROX710
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	return OPX.Spots.Coerce(SPEC, definitions, problems)
end

--- Answers one spot by key, or nil.
-- @author XEROX710
-- @param spots table
-- @param key any
-- @return table|nil
Access.Spot = OPX.Spots.Spot

--- Every spot in a bucket, sorted by key.
-- @author XEROX710
-- @param spots table
-- @param bucket integer
-- @return table[] array of spots
Access.InBucket = OPX.Spots.InBucket

--- Squared horizontal distance from a point to a spot's declared position.
-- @author XEROX710
-- @param spot table
-- @param x any
-- @param y any
-- @return number|nil
Access.FlatDistanceSquared = OPX.Spots.FlatDistanceSquared

--- Answers the spot a point stands on, or nil. The nearest wins; at equal
-- distance the key decides, so `pairs` order never chooses between two markers
-- a metre apart.
-- @author XEROX710
-- @param spots table
-- @param x any
-- @param y any
-- @param radius number|nil squared radius; USE_RADIUS_SQ by default
-- @return table|nil
-- @return number|nil squared distance
function Access.Nearest(spots, x, y, radius)
	return OPX.Spots.Nearest(spots, x, y, radius or Access.USE_RADIUS_SQ)
end

--- Whether a TweakDB vehicle record is an AV.
--
-- ONE RULE, OVER ONE CONFIG KEY: `OPX.Vehicle.IsAvRecord` and
-- `OPX.Config.SHARED.AV_PREFIXES`. This module, the dealership and the admin
-- catalogue each carried their own copy over their own key, and the copies had
-- already stopped agreeing about what a non-string or an emptied list means.
-- Whether a record flies is a fact about the record; a car you can buy at a pad
-- you cannot recall it at is what two answers to it costs.
--
-- Kept as a name on `Access` because the whole module already reads spot rules
-- through `Access`, and a caller should not have to know which of them is local.
-- @author XEROX710
-- @param record any
-- @return boolean
function Access.IsAv(record)
	return OPX.Vehicle.IsAvRecord(record)
end

-- What a marker falls back to per kind when the operator named nothing usable. A
-- pad is a RING, because an AV lands inside it and a filled cylinder would be
-- drawn through the hull; a garage is a cylinder you walk into.
-- A DOOR IS NOT A LIST, and the third entry is why this table is keyed by two
-- different things. `garage` and `avpad` are KINDS and describe the menu point;
-- `entry` is a ROLE and describes the door, whatever the garage holds. A player
-- who cannot tell the two apart drives into the one that opens a menu.
local FALLBACK = {
	[M.KIND.AVPAD] = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
	[M.KIND.GARAGE] = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
	[M.ROLE.ENTRY] = { shape = 'ring', style = 'interaction', RADIUS = 3.0 },
}

--- The marker one drawn point is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the
-- three looks below are this module's own choice and stay here.
--
-- The ROLE decides first and the KIND second: a door is a door at a garage and
-- at an AV pad alike. `role` omitted is the menu point, which is what every
-- caller meant before there were roles at all.
-- @author XEROX710
-- @param kind string
-- @param role string|nil
-- @return table shape, style, radius, lift
function Access.Marker(kind, role)
	local slot = (role == M.ROLE.ENTRY) and M.ROLE.ENTRY
		or (kind == M.KIND.AVPAD and M.KIND.AVPAD or M.KIND.GARAGE)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[slot] or nil
	return OPX.Spots.Marker(declared, FALLBACK[slot], Config.GROUND_OFFSET)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author XEROX710
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 150.0)
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise inside a
-- scan.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)
Access.COOLDOWN_MS = math.floor(finiteNumber(Config.COOLDOWN_MS) or 0)
Access.REQUEST_WINDOW_MS = math.floor(finiteNumber(Config.REQUEST_WINDOW_MS) or 0)
Access.REQUESTS_PER_WINDOW = math.floor(finiteNumber(Config.REQUESTS_PER_WINDOW) or 0)

-- How much room an exit needs to count as free, squared once because every
-- occupancy test is a squared comparison -- no square root is ever taken of a
-- distance that is only ever compared.
local EXIT_CLEARANCE = finiteNumber(Config.EXIT_CLEARANCE) or 0
Access.EXIT_CLEARANCE = EXIT_CLEARANCE
Access.EXIT_CLEARANCE_SQ = EXIT_CLEARANCE * EXIT_CLEARANCE

--- The AV lift, clamped to something a chassis will not fall through.
-- The rule is `lib/shared/vehicle.lua`, beside the one that says whether a
-- record is an AV at all: the staff spawner had a third copy with no bound.
-- @author XEROX710
-- @return number
function Access.AvLift()
	return OPX.Vehicle.AvLift(Config.AV_LIFT)
end

-- ── a garage, its locations and the points they draw ────────────────────────

--- Builds one garage from a config block, or answers why it was refused.
-- @author XEROX710
--
-- A GARAGE IS REFUSED WHOLE, never repaired. A location with no exits is a
-- location nothing can ever come out of, and a garage half-loaded is a garage
-- whose second door silently does nothing -- which is the failure mode an
-- operator cannot diagnose from inside the game. Every refusal is a boot warning
-- naming the garage and the location by their own numbering.
--
-- The three kinds of point are validated through the SAME `build` every spot in
-- this resource goes through, so a NaN in an exit is refused in the place a NaN
-- in a menu point is, and by the same rule.
-- @param key any
-- @param raw any
-- @param problems table|nil collector, appended to
-- @return table|nil
local function garage(key, raw, problems)
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
		return nil
	end

	if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
		return refuse('a garage key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters')
	end
	if type(raw) ~= 'table' then return refuse(key .. ': every garage must be a table') end

	local kind = type(raw.KIND) == 'string' and raw.KIND:lower() or ''
	if not KINDS[kind] then
		return refuse(('%s: KIND must be one of garage, avpad'):format(key))
	end
	if raw.LABEL ~= nil and type(raw.LABEL) ~= 'string' then
		return refuse(('%s: LABEL must be a string'):format(key))
	end
	local locations = raw.LOCATIONS
	if type(locations) ~= 'table' or #locations == 0 then
		return refuse(('%s: LOCATIONS must be a list of at least one location'):format(key))
	end

	local built = {
		key = key,
		label = (type(raw.LABEL) == 'string' and raw.LABEL ~= '') and raw.LABEL or key,
		kind = kind,
		locations = {},
	}

	for index = 1, #locations do
		local place = locations[index]
		local where = ('%s location %d'):format(key, index)
		if type(place) ~= 'table' then return refuse(where .. ': must be a table') end

		-- The bucket is the LOCATION'S, not a point's: a location whose menu and
		-- door were in two routing buckets would be a location half of which no
		-- player can ever see.
		local bucket = place.BUCKET

		local function point(block, role, needHeading)
			local fields = type(block) == 'table' and block or {}
			return Access.FromDefinition(Access.PointKey(key, index, role), {
				KIND = kind,
				LABEL = built.label,
				X = fields.X, Y = fields.Y, Z = fields.Z,
				HEADING = needHeading and fields.HEADING or 0.0,
				BUCKET = bucket,
				GARAGE = key, ROLE = role, LOCATION = index,
			})
		end

		local menu, menuWhy = point(place.MENU, M.ROLE.MENU, false)
		if menu == nil then return refuse(where .. ' MENU: ' .. tostring(menuWhy)) end
		local entry, entryWhy = point(place.ENTRY, M.ROLE.ENTRY, true)
		if entry == nil then return refuse(where .. ' ENTRY: ' .. tostring(entryWhy)) end

		local exits = place.EXITS
		if type(exits) ~= 'table' or #exits == 0 then
			return refuse(where .. ': EXITS must be a list of at least one exit')
		end
		local out = {}
		for slot = 1, #exits do
			local spot, why = Access.FromDefinition(
				('%s#%d.out%d'):format(key, index, slot), {
					KIND = kind, LABEL = built.label,
					X = type(exits[slot]) == 'table' and exits[slot].X or nil,
					Y = type(exits[slot]) == 'table' and exits[slot].Y or nil,
					Z = type(exits[slot]) == 'table' and exits[slot].Z or nil,
					HEADING = type(exits[slot]) == 'table' and exits[slot].HEADING or nil,
					BUCKET = bucket,
					GARAGE = key, LOCATION = index,
				})
			if spot == nil then
				return refuse(('%s EXITS[%d]: %s'):format(where, slot, tostring(why)))
			end
			out[slot] = spot
		end

		built.locations[index] = {
			index = index,
			bucket = menu.bucket,
			menu = menu,
			entry = entry,
			exits = out,
		}
	end

	return built
end

--- Builds every garage, and the flat table of drawn points they add up to.
-- @author XEROX710
-- @param definitions any map of key -> garage block
-- @param problems table|nil collector, appended to
-- @return table key -> garage
-- @return table pointKey -> point
function Access.CoerceGarages(definitions, problems)
	local garages, points = {}, {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'GARAGES must be a table of key -> garage'
		end
		return garages, points
	end
	for key, raw in pairs(definitions) do
		local built = garage(key, raw, problems)
		if built ~= nil then
			garages[key] = built
			for _, place in ipairs(built.locations) do
				points[place.menu.key] = place.menu
				points[place.entry.key] = place.entry
			end
		end
	end
	return garages, points
end

--- Every drawn point of one garage, so a caller that has the garage does not
--- have to walk the flat table to find its own.
-- @author XEROX710
-- @param built table a garage
-- @return table[] array of points
function Access.PointsOf(built)
	local listed = {}
	for _, place in ipairs(built.locations) do
		listed[#listed + 1] = place.menu
		listed[#listed + 1] = place.entry
	end
	return listed
end

--- The configured garages and their points, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.GARAGES, Access.SPOTS = Access.CoerceGarages(Config.GARAGES, nil)

-- Config keys that must be a finite number above zero.
local NUMBERS = { 'USE_RADIUS', 'EXIT_CLEARANCE', 'SCAN_MS', 'POLL_MS', 'COOLDOWN_MS',
	'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW' }

--- Lists every configuration error visible without a world, sorted.
-- @author XEROX710
-- @return string[]
function Access.Problems()
	local lines = {}
	for index = 1, #NUMBERS do
		local name = NUMBERS[index]
		local value = finiteNumber(Config[name])
		if value == nil or value <= 0 then
			lines[#lines + 1] = name .. ' must be a finite number above zero'
		end
	end

	-- The draw distance and the ground offset are reported against the same
	-- bounds `Access.Marker` and `Access.MaxDistance` clamp to, because they are
	-- literally the same constants.
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)

	OPX.Vehicle.AvLiftProblem(Config.AV_LIFT, lines)

	-- The door's look is reported beside the two kinds, because `Access.Marker`
	-- falls back to the same table for all three and a validator that checked two
	-- of them would hand an operator a silently substituted third.
	for _, slot in ipairs({ M.KIND.GARAGE, M.KIND.AVPAD, M.ROLE.ENTRY }) do
		local declared = type(Config.MARKER) == 'table' and Config.MARKER[slot] or nil
		OPX.Spots.MarkerProblems(declared, 'MARKER.' .. slot, lines)
	end

	-- GARAGES are validated once at load; the errors are re-derived here so the
	-- diagnostic reports them rather than only the boot log.
	Access.CoerceGarages(Config.GARAGES, lines)

	-- A CONFIG THAT STILL CARRIES THE OLD BLOCK IS SAID OUT LOUD. `SPOTS` was
	-- what a garage was before the rework, and a file that still has one is a
	-- file whose garages are all silently missing -- which reads from inside the
	-- game as a server with no markers at all and nothing anywhere saying why.
	if Config.SPOTS ~= nil then
		lines[#lines + 1] = 'SPOTS is no longer read: a garage is a key with LOCATIONS now, ' ..
			'see the header of config/garages.lua'
	end

	local key = type(Config.KEY) == 'table' and Config.KEY or nil
	if key == nil then
		lines[#lines + 1] = 'KEY must be a table of ID, NAME and DEFAULT'
	else
		if type(key.ID) ~= 'string' or key.ID == '' then lines[#lines + 1] = 'KEY.ID must be a string' end
		if type(key.NAME) ~= 'string' or key.NAME == '' then
			lines[#lines + 1] = 'KEY.NAME must be a catalogue key'
		end
		if key.DEFAULT ~= false and (type(key.DEFAULT) ~= 'string' or key.DEFAULT == '') then
			lines[#lines + 1] = 'KEY.DEFAULT must be a key name, or false for no key at all'
		end
	end

	table.sort(lines)
	return lines
end
