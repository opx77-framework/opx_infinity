--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- Two input shapes arrive here and they are deliberately not the same function.
-- A DEFINITION is what an operator writes in `config/clothing.lua` and what a
-- captured row holds in the database: upper-case fields, the same spelling the
-- garages and elevators configs use. A WIRE store is what the server sends a
-- client: already normalised and lower-case. Each is validated on its own terms,
-- and both end in the one `build` below -- so there is one place that decides
-- what a store is and one place that decides whether one is usable.
--
-- A STORE IS A PLACE WITH NO FACING, and that is the whole of the difference
-- between this vocabulary and the garages one: no KIND (there is one category of
-- store), no HEADING (nothing is created at a store and nothing is turned by an
-- operator's yaw), and therefore no capture round-trip -- the position comes
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

-- Coerces to a number, rejecting NaN and both infinities. Kept module-local
-- rather than folded into `OPX.Text.Finite`, which also caps at 2^53: a world
-- coordinate is measured with this.
local function finiteNumber(value)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end
Access.FiniteNumber = finiteNumber

-- Box every accepted coordinate fits in.
local BOUND = 1000000

-- Coerces a world coordinate: finite and inside BOUND.
local function coordinate(value)
	local parsed = finiteNumber(value)
	if parsed == nil or parsed > BOUND or parsed < -BOUND then return nil end
	return parsed
end
Access.Coordinate = coordinate

-- Coerces a whole number inside BOUND.
local function integer(value)
	local parsed = coordinate(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	return math.floor(parsed)
end
Access.Integer = integer

-- The engine's own marker vocabulary. A style or a shape outside these sets is
-- refused by `Open77.markers` with a status, so picking one here would only move
-- the refusal to a place with less to say about it.
local SHAPES = { ring = true, cylinder = true }
local STYLES = { interaction = true, objective = true, spawn = true, danger = true }

--- The largest allowed store key, which is also the column width.
Access.MAX_KEY = 48

--- Builds one validated store, or answers why it was refused.
-- @author XEROX710
-- @param key string
-- @param label any
-- @param x any
-- @param y any
-- @param z any
-- @param bucket any
-- @return table|nil
-- @return string|nil
local function build(key, label, x, y, z, bucket)
	if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
		return nil, 'key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters'
	end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	if x == nil or y == nil or z == nil then
		return nil, ('%s: X, Y and Z must be finite numbers inside %d'):format(key, BOUND)
	end
	local bucketNumber = bucket == nil and 0 or integer(bucket)
	if bucketNumber == nil or bucketNumber < 0 then
		return nil, ('%s: BUCKET must be a whole number, 0 or more'):format(key)
	end
	if label ~= nil and type(label) ~= 'string' then
		return nil, ('%s: LABEL must be a string'):format(key)
	end
	return {
		key = key,
		label = (type(label) == 'string' and label ~= '') and label or key,
		x = x,
		y = y,
		z = z,
		bucket = bucketNumber,
	}
end

--- Normalises one config or database row, in the operator's upper-case spelling.
-- @author XEROX710
-- @param key string
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromDefinition(key, raw)
	if type(raw) ~= 'table' then return nil, tostring(key) .. ': every store must be a table' end
	return build(key, raw.LABEL, raw.X, raw.Y, raw.Z, raw.BUCKET)
end

--- Normalises one store off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	if type(raw) ~= 'table' then return nil, 'every store must be a table' end
	return build(raw.key, raw.label, raw.x, raw.y, raw.z, raw.bucket)
end

--- The fields of one store, as the wire and the SYNC event carry them.
-- @author XEROX710
-- @param store table
-- @return table
function Access.Serialise(store)
	return {
		key = store.key, label = store.label,
		x = store.x, y = store.y, z = store.z,
		bucket = store.bucket,
	}
end

--- Builds a key -> store table from a list of definitions.
-- @author XEROX710
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	local spots = {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'SPOTS must be a table of key -> definition'
		end
		return spots
	end
	for key, raw in pairs(definitions) do
		local store, why = Access.FromDefinition(key, raw)
		if store == nil then
			if problems ~= nil then problems[#problems + 1] = why end
		else
			spots[key] = store
		end
	end
	return spots
end

--- Answers one store by key, or nil.
-- @author XEROX710
-- @param spots table
-- @param key any
-- @return table|nil
function Access.Spot(spots, key)
	if type(key) ~= 'string' then return nil end
	return spots[key]
end

--- Every store in a bucket, sorted by key.
-- Sorted because `pairs` order would reshuffle a listing, a SYNC payload and a
-- determinism check between runs.
-- @author XEROX710
-- @param spots table
-- @param bucket integer
-- @return table[] array of stores
function Access.InBucket(spots, bucket)
	local list = {}
	for _, store in pairs(spots) do
		if store.bucket == bucket then list[#list + 1] = store end
	end
	table.sort(list, function(left, right) return left.key < right.key end)
	return list
end

--- Squared horizontal distance from a point to a store's declared position.
-- @author XEROX710
-- @param store table
-- @param x any
-- @param y any
-- @return number|nil
function Access.FlatDistanceSquared(store, x, y)
	x, y = coordinate(x), coordinate(y)
	if store == nil or x == nil or y == nil then return nil end
	local dx, dy = x - store.x, y - store.y
	return dx * dx + dy * dy
end

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
	radius = radius or Access.USE_RADIUS_SQ
	local best, bestDistance
	for _, store in pairs(spots) do
		local flat = Access.FlatDistanceSquared(store, x, y)
		if flat ~= nil and flat <= radius and
			(bestDistance == nil or flat < bestDistance or
				(flat == bestDistance and store.key < best.key)) then
			best, bestDistance = store, flat
		end
	end
	return best, bestDistance
end

--- The marker a store is drawn with.
-- Falls back per field rather than as a block, so a config that names a good
-- shape and a bad style keeps the shape.
--
-- The lift is part of the look and not of the store: a ring that is not lifted
-- off the floor is co-planar with it and draws nothing, so the offset belongs
-- here with the shape that decides it rather than at every call site.
-- @author XEROX710
-- @return table shape, style, radius, lift
function Access.Marker()
	local declared = type(Config.MARKER) == 'table' and Config.MARKER or {}
	local shape = type(declared.shape) == 'string' and declared.shape:lower() or 'cylinder'
	if not SHAPES[shape] then shape = 'cylinder' end
	local style = type(declared.style) == 'string' and declared.style:lower() or 'interaction'
	if not STYLES[style] then style = 'interaction' end

	local radius = finiteNumber(declared.RADIUS)
	if radius == nil or radius < 0.1 or radius > 50.0 then radius = 2.5 end

	-- 0 is a real choice -- a marker deliberately on the floor -- so only a
	-- broken value falls back.
	local lift = finiteNumber(Config.GROUND_OFFSET)
	if lift == nil or lift < 0.0 or lift > 2.0 then lift = 0.06 end
	return { shape = shape, style = style, radius = radius, lift = lift }
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author XEROX710
-- @return number
function Access.MaxDistance()
	local distance = finiteNumber(Config.MAX_DISTANCE)
	if distance == nil or distance < 1.0 or distance > 500.0 then return 150.0 end
	return distance
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

	local distance = finiteNumber(Config.MAX_DISTANCE)
	if distance == nil or distance < 1.0 or distance > 500.0 then
		lines[#lines + 1] = 'MAX_DISTANCE must be a finite number, 1 to 500 metres'
	end
	local groundOffset = finiteNumber(Config.GROUND_OFFSET)
	if groundOffset == nil or groundOffset < 0.0 or groundOffset > 2.0 then
		lines[#lines + 1] = 'GROUND_OFFSET must be a finite number, 0 to 2 metres'
	end

	local declared = type(Config.MARKER)
	if declared ~= 'table' then
		lines[#lines + 1] = 'MARKER must be a table of shape, style and RADIUS'
	else
		local shape = type(Config.MARKER.shape) == 'string' and Config.MARKER.shape:lower() or nil
		if shape ~= nil and not SHAPES[shape] then
			lines[#lines + 1] = 'MARKER.shape must be ring or cylinder'
		end
		local style = type(Config.MARKER.style) == 'string' and Config.MARKER.style:lower() or nil
		if style ~= nil and not STYLES[style] then
			lines[#lines + 1] = 'MARKER.style must be interaction, objective, spawn or danger'
		end
		local radius = finiteNumber(Config.MARKER.RADIUS)
		if radius == nil or radius < 0.1 or radius > 50.0 then
			lines[#lines + 1] = 'MARKER.RADIUS must be a finite number, 0.1 to 50'
		end
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
