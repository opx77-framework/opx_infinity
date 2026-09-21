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

--- The largest allowed spot key, which is also the column width.
Access.MAX_KEY = 48

-- This module's words for the shared record: a spot has a KIND, because a garage
-- and an AV pad are drawn and used differently, and a HEADING, because a vehicle
-- is CREATED at one and something has to say which way it faces.
local SPEC = {
	noun = 'spot',
	maxKey = Access.MAX_KEY,
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
	return OPX.Spots.FromDefinition(SPEC, key, raw)
end

--- Normalises one spot off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	return OPX.Spots.FromWire(SPEC, raw)
end

--- The fields of one spot, as the wire and the SYNC event carry them.
-- @author XEROX710
-- @param spot table
-- @return table
Access.Serialise = OPX.Spots.Serialise

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
local FALLBACK = {
	[M.KIND.AVPAD] = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
	[M.KIND.GARAGE] = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
}

--- The marker an engine spot of this kind is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the two
-- shapes below are this module's own choice and stay here.
-- @author XEROX710
-- @param kind string
-- @return table shape, style, radius, lift
function Access.Marker(kind)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
	local fallback = kind == M.KIND.AVPAD and FALLBACK[M.KIND.AVPAD] or FALLBACK[M.KIND.GARAGE]
	return OPX.Spots.Marker(declared, fallback, Config.GROUND_OFFSET)
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
Access.CAPTURE_TIMEOUT_MS = math.floor(finiteNumber(Config.CAPTURE_TIMEOUT_MS) or 0)

--- The AV lift, clamped to something a chassis will not fall through.
-- The rule is `lib/shared/vehicle.lua`, beside the one that says whether a
-- record is an AV at all: the staff spawner had a third copy with no bound.
-- @author XEROX710
-- @return number
function Access.AvLift()
	return OPX.Vehicle.AvLift(Config.AV_LIFT)
end

--- The configured spots, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.SPOTS = Access.Coerce(Config.SPOTS, nil)

-- Config keys that must be a finite number above zero.
local NUMBERS = { 'USE_RADIUS', 'SCAN_MS', 'POLL_MS', 'COOLDOWN_MS',
	'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW', 'CAPTURE_TIMEOUT_MS' }

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

	for _, kind in ipairs({ M.KIND.GARAGE, M.KIND.AVPAD }) do
		local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
		OPX.Spots.MarkerProblems(declared, 'MARKER.' .. kind, lines)
	end

	-- SPOTS are validated once at load; the errors are re-derived here so the
	-- diagnostic reports them rather than only the boot log.
	Access.Coerce(Config.SPOTS, lines)

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
