--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- A BRANCH IS A PLACED SPOT with no kind and no facing, exactly like a
-- clothing store: the record, the two input shapes that normalise into it, the
-- marker look and the coordinate box are `lib/shared/spots.lua`, and this file
-- names this module's own words to them. What it adds is the money half of the
-- config -- which two accounts a transaction moves between, the quick amounts
-- and the ceiling -- read once and refused at boot rather than inside a
-- transaction.

local M = OPX.Modules.Get('bank')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer

--- The largest allowed branch key, which is also the column width.
Access.MAX_KEY = 48

local SPEC = {
	noun = 'branch',
	maxKey = Access.MAX_KEY,
	kinds = nil,
	heading = false,
}

--- Normalises one config or database row, in the operator's upper-case spelling.
function Access.FromDefinition(key, raw)
	return OPX.Spots.FromDefinition(SPEC, key, raw)
end

--- Normalises one branch off the wire, in the shape `Access.Serialise` writes.
function Access.FromWire(raw)
	return OPX.Spots.FromWire(SPEC, raw)
end

Access.Serialise = OPX.Spots.Serialise

--- Builds a key -> branch table from a list of definitions.
function Access.Coerce(definitions, problems)
	return OPX.Spots.Coerce(SPEC, definitions, problems)
end

Access.InBucket = OPX.Spots.InBucket
Access.FlatDistanceSquared = OPX.Spots.FlatDistanceSquared

--- The branch a point stands on, or nil. The nearest wins; at equal distance
--- the key decides.
function Access.Nearest(spots, x, y, radius)
	return OPX.Spots.Nearest(spots, x, y, radius or Access.USE_RADIUS_SQ)
end

local FALLBACK = { shape = 'cylinder', style = 'interaction', RADIUS = 1.2 }

--- The marker a branch is drawn with.
function Access.Marker()
	return OPX.Spots.Marker(Config.MARKER, FALLBACK, Config.GROUND_OFFSET)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 120.0)
end

local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)

--- The two accounts, as money-type names. Read from the server's own list of
--- money types, so a misspelt one is a boot warning and not a refused write.
Access.ACCOUNT = type(Config.ACCOUNT) == 'string' and Config.ACCOUNT or 'BANK'
Access.CASH = type(Config.CASH) == 'string' and Config.CASH or 'EDDIES'

--- The most one transaction moves.
Access.MAX_TRANSFER = math.floor(finiteNumber(Config.MAX_TRANSFER) or 10000000)
if Access.MAX_TRANSFER < 1 then Access.MAX_TRANSFER = 10000000 end

--- The quick amounts, whole and positive and under the ceiling, sorted.
Access.AMOUNTS = {}
do
	local seen = {}
	for _, raw in ipairs(type(Config.AMOUNTS) == 'table' and Config.AMOUNTS or {}) do
		local amount = M.Amount(raw, Access.MAX_TRANSFER)
		if amount ~= nil and not seen[amount] then
			seen[amount] = true
			Access.AMOUNTS[#Access.AMOUNTS + 1] = amount
		end
	end
	table.sort(Access.AMOUNTS)
end

--- The configured branches, already validated.
Access.SPOTS = Access.Coerce(Config.SPOTS, nil)

local NUMBERS = { 'USE_RADIUS', 'SCAN_MS', 'POLL_MS' }

--- Every configuration error visible without a world, sorted.
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
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)
	OPX.Spots.MarkerProblems(Config.MARKER, 'MARKER', lines)
	Access.Coerce(Config.SPOTS, lines)

	local types = OPX.Config.SHARED ~= nil and OPX.Config.SHARED.MONEY ~= nil
		and OPX.Config.SHARED.MONEY.TYPES or {}
	for _, name in ipairs({ 'ACCOUNT', 'CASH' }) do
		if types[Config[name]] == nil then
			lines[#lines + 1] = ('%s = %s is not a money type of this server'):format(name, tostring(Config[name]))
		end
	end
	if Config.ACCOUNT == Config.CASH then
		lines[#lines + 1] = 'ACCOUNT and CASH are the same money type: nothing would move'
	end
	if type(Config.AMOUNTS) ~= 'table' or #Access.AMOUNTS ~= #Config.AMOUNTS then
		lines[#lines + 1] = 'AMOUNTS must be a list of whole amounts from 1 to MAX_TRANSFER, each once'
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
