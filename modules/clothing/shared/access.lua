--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- WHAT A STORE IS, AND WHO DECIDES IT. The record, the two input shapes that
-- normalise into it, the marker look and the coordinate box are all
-- `lib/shared/spots.lua`. This file names this module's own words to them and
-- adds nothing: a store is a placed spot, drawn and stood on like every other,
-- and the copy of that vocabulary this file used to carry was the same code
-- `garages` and `dealership` carried with two fields removed.
--
-- A STORE IS A PLACE WITH NO FACING, and that is the whole of the difference.
-- No KIND, because there is one category of store, and no HEADING, because
-- nothing is created at a store and nothing is turned by an operator's yaw --
-- so the shared record simply carries neither field rather than carrying a
-- constant kind and a zero heading that a later author would wire up by
-- mistake. There is therefore no capture round-trip either: the position comes
-- from the server, and there is no second field for a client to contribute.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a NaN
-- or an unknown bucket reads as a warning at boot rather than a raise inside a
-- scan or a network handler. Only X and Y are ever measured against; Z is
-- validated and then carried to the marker call.

local M = OPX.Modules.Get('clothing')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box and the two coercions over it, in `lib/shared/spots.lua`. Kept
-- as names on `Access` because the whole module already reads store rules through
-- `Access` and a caller should not have to know which of them is shared.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer

--- The largest allowed store key, which is also the column width.
Access.MAX_KEY = 48

-- This module's words for the shared record. No `kinds` and no `heading`: see
-- the header -- a store is a place with one category and no facing.
local SPEC = {
	noun = 'store',
	maxKey = Access.MAX_KEY,
	kinds = nil,
	heading = false,
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

--- Normalises one store off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	return OPX.Spots.FromWire(SPEC, raw)
end

--- The fields of one store, as the wire and the SYNC event carry them.
-- @author XEROX710
-- @param store table
-- @return table
Access.Serialise = OPX.Spots.Serialise

--- Builds a key -> store table from a list of definitions.
-- @author XEROX710
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	return OPX.Spots.Coerce(SPEC, definitions, problems)
end

--- Answers one store by key, or nil.
-- @author XEROX710
-- @param spots table
-- @param key any
-- @return table|nil
Access.Spot = OPX.Spots.Spot

--- Every store in a bucket, sorted by key.
-- @author XEROX710
-- @param spots table
-- @param bucket integer
-- @return table[] array of stores
Access.InBucket = OPX.Spots.InBucket

--- Squared horizontal distance from a point to a store's declared position.
-- @author XEROX710
-- @param store table
-- @param x any
-- @param y any
-- @return number|nil
Access.FlatDistanceSquared = OPX.Spots.FlatDistanceSquared

--- Answers the store a point stands on, or nil. The nearest wins; at equal
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

-- What a marker falls back to when the operator named nothing usable. One block
-- and not one per kind, because there is one kind of store.
local FALLBACK = { shape = 'cylinder', style = 'interaction', RADIUS = 2.5 }

--- The marker a store is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the
-- shape above is this module's own choice and stays here.
-- @author XEROX710
-- @return table shape, style, radius, lift
function Access.Marker()
	return OPX.Spots.Marker(Config.MARKER, FALLBACK, Config.GROUND_OFFSET)
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

--- The configured stores, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.SPOTS = Access.Coerce(Config.SPOTS, nil)

-- Config keys that must be a finite number above zero.
local NUMBERS = { 'USE_RADIUS', 'SCAN_MS', 'POLL_MS' }

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
	OPX.Spots.MarkerProblems(Config.MARKER, 'MARKER', lines)

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
