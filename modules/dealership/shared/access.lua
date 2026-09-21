--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- Two vocabularies live here and they are deliberately separate things. A SPOT
-- is a place: where a dealer stands, which category it sells, and how it is
-- drawn. A STOCK ROW is a thing for sale: a name, a class, a TweakDB record and
-- a price. A purchase names one of each, and the server proves both again.
--
-- Two input shapes arrive for a spot and they are not the same function. A
-- DEFINITION is what an operator writes in `config/dealership.lua` and what a
-- captured row holds in the database: upper-case fields, the same spelling the
-- garages and elevators configs use. A WIRE spot is what the server sends a
-- client: already normalised and lower-case. Each is validated on its own terms
-- and both end in the one `build` below, so there is one place that decides
-- what a spot is and one place that decides whether one is usable.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a price that is not a whole number above zero reads
-- as a warning at boot rather than a raise inside a scan, a menu or a purchase.

local M = OPX.Modules.Get('dealership')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a number, rejecting NaN and both infinities. Kept module-local
-- rather than folded into `OPX.Text.Finite`, which also caps at 2^53: a price, a
-- yaw or a millisecond clock is measured with this.
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

-- The two kinds, and the engine's own marker vocabulary. A style or a shape
-- outside these sets is refused by `Open77.markers` with a status, so picking
-- one here would only move the refusal somewhere with less to say about it.
local KINDS = { [M.KIND.GARAGE] = true, [M.KIND.AVPAD] = true }
Access.KINDS = KINDS

local SHAPES = { ring = true, cylinder = true }
local STYLES = { interaction = true, objective = true, spawn = true, danger = true }

--- The largest allowed spot key, which is also the column width.
Access.MAX_KEY = 48

-- The largest record and the longest text a stock row may carry. Both are
-- refused here rather than at the vehicles contract, which caps a record too.
local MAX_RECORD = 256
local MAX_STOCK_LABEL = 64
local MAX_CLASS = 32

-- ── spots ───────────────────────────────────────────────────────────────────

--- Builds one validated spot, or answers why it was refused.
-- @author XEROX710
-- @param key string
-- @param kind any
-- @param label any
-- @param x any
-- @param y any
-- @param z any
-- @param heading any
-- @param bucket any
-- @return table|nil
-- @return string|nil
local function build(key, kind, label, x, y, z, heading, bucket)
	if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
		return nil, 'key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters'
	end
	if type(kind) ~= 'string' or not KINDS[kind:lower()] then
		return nil, ('%s: KIND must be one of garage, avpad'):format(key)
	end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	if x == nil or y == nil or z == nil then
		return nil, ('%s: X, Y and Z must be finite numbers inside %d'):format(key, BOUND)
	end
	local headingNumber = heading == nil and 0.0 or finiteNumber(heading)
	if headingNumber == nil then
		return nil, ('%s: HEADING must be a finite number'):format(key)
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
		kind = kind:lower(),
		x = x,
		y = y,
		z = z,
		heading = headingNumber,
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
	if type(raw) ~= 'table' then return nil, tostring(key) .. ': every dealer must be a table' end
	return build(key, raw.KIND, raw.LABEL, raw.X, raw.Y, raw.Z, raw.HEADING, raw.BUCKET)
end

--- Normalises one spot off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	if type(raw) ~= 'table' then return nil, 'every dealer must be a table' end
	return build(raw.key, raw.kind, raw.label, raw.x, raw.y, raw.z, raw.heading, raw.bucket)
end

--- The fields of one spot, as the wire and the SYNC event carry them.
-- @author XEROX710
-- @param spot table
-- @return table
function Access.Serialise(spot)
	return {
		key = spot.key, label = spot.label, kind = spot.kind,
		x = spot.x, y = spot.y, z = spot.z,
		heading = spot.heading, bucket = spot.bucket,
	}
end

--- Builds a key -> spot table from a list of definitions.
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
		local spot, why = Access.FromDefinition(key, raw)
		if spot == nil then
			if problems ~= nil then problems[#problems + 1] = why end
		else
			spots[key] = spot
		end
	end
	return spots
end

--- Answers one spot by key, or nil.
-- @author XEROX710
-- @param spots table
-- @param key any
-- @return table|nil
function Access.Spot(spots, key)
	if type(key) ~= 'string' then return nil end
	return spots[key]
end

--- Every spot in a bucket, sorted by key.
-- Sorted because `pairs` order would reshuffle a listing, a SYNC payload and a
-- determinism check between runs.
-- @author XEROX710
-- @param spots table
-- @param bucket integer
-- @return table[] array of spots
function Access.InBucket(spots, bucket)
	local list = {}
	for _, spot in pairs(spots) do
		if spot.bucket == bucket then list[#list + 1] = spot end
	end
	table.sort(list, function(left, right) return left.key < right.key end)
	return list
end

--- Squared horizontal distance from a point to a spot's declared position.
-- @author XEROX710
-- @param spot table
-- @param x any
-- @param y any
-- @return number|nil
function Access.FlatDistanceSquared(spot, x, y)
	x, y = coordinate(x), coordinate(y)
	if spot == nil or x == nil or y == nil then return nil end
	local dx, dy = x - spot.x, y - spot.y
	return dx * dx + dy * dy
end

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
	radius = radius or Access.USE_RADIUS_SQ
	local best, bestDistance
	for _, spot in pairs(spots) do
		local flat = Access.FlatDistanceSquared(spot, x, y)
		if flat ~= nil and flat <= radius and
			(bestDistance == nil or flat < bestDistance or
				(flat == bestDistance and spot.key < best.key)) then
			best, bestDistance = spot, flat
		end
	end
	return best, bestDistance
end

--- Whether a TweakDB vehicle record is an AV.
--
-- ONE RULE, OVER ONE CONFIG KEY: `OPX.Text.IsAvRecord` and
-- `OPX.Config.SHARED.AV_PREFIXES`. The comment that used to sit here claimed
-- this WAS the rule the garages module uses; it was a second copy over a second
-- key, and the admin catalogue had a third that behaved differently again. It is
-- one rule now, which is what makes a record air for every part of the server or
-- for none of it.
-- @author XEROX710
-- @param record any
-- @return boolean
function Access.IsAv(record)
	return OPX.Text.IsAvRecord(record)
end

--- The marker an engine spot of this kind is drawn with.
-- Falls back per field rather than as a block, so a config that names a good
-- shape and a bad style keeps the shape. The lift is part of the look and not of
-- the spot: a ring that is not lifted off the floor draws nothing.
-- @author XEROX710
-- @param kind string
-- @return table shape, style, radius, lift
function Access.Marker(kind)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
	declared = type(declared) == 'table' and declared or {}
	local fallback = kind == M.KIND.AVPAD and
		{ shape = 'ring', style = 'objective', RADIUS = 3.5 } or
		{ shape = 'cylinder', style = 'spawn', RADIUS = 2.5 }

	local shape = type(declared.shape) == 'string' and declared.shape:lower() or fallback.shape
	if not SHAPES[shape] then shape = fallback.shape end
	local style = type(declared.style) == 'string' and declared.style:lower() or fallback.style
	if not STYLES[style] then style = fallback.style end

	local radius = finiteNumber(declared.RADIUS)
	if radius == nil or radius < 0.1 or radius > 50.0 then radius = fallback.RADIUS end

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

--- The AV lift, clamped to something a chassis will not fall through.
-- @author XEROX710
-- @return number
function Access.AvLift()
	local lift = finiteNumber(Config.AV_LIFT)
	if lift == nil or lift < 0.0 or lift > 10.0 then return 1.2 end
	return lift
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)
Access.COOLDOWN_MS = math.floor(finiteNumber(Config.COOLDOWN_MS) or 0)
Access.REQUEST_WINDOW_MS = math.floor(finiteNumber(Config.REQUEST_WINDOW_MS) or 0)
Access.REQUESTS_PER_WINDOW = math.floor(finiteNumber(Config.REQUESTS_PER_WINDOW) or 0)
Access.CAPTURE_TIMEOUT_MS = math.floor(finiteNumber(Config.CAPTURE_TIMEOUT_MS) or 0)

--- The configured dealers, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.SPOTS = Access.Coerce(Config.SPOTS, nil)

-- ── the stock ───────────────────────────────────────────────────────────────

--- Builds the catalogue from config, naming every row it refused.
-- @author XEROX710
--
-- A ROW IS REFUSED WHOLE, never repaired: a car the operator priced at nothing,
-- or one whose record is empty, is a row that would sell something nobody meant
-- to sell. Whether a row is a vehicle or an AV is DERIVED from its record, so a
-- row cannot disagree with itself about which category it is in.
-- @param problems table|nil collector, appended to
-- @return table key -> entry
local function stock(problems)
	local listed = {}
	local rows = Config.STOCK
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
	end

	if type(rows) ~= 'table' then
		refuse('STOCK must be an array of KEY, LABEL, CLASS, RECORD and PRICE')
		return listed
	end

	for index = 1, #rows do
		local raw = rows[index]
		local where = ('STOCK[%d]'):format(index)
		if type(raw) ~= 'table' then
			refuse(where .. ': every row must be a table')
		else
			local key = raw.KEY
			local price = finiteNumber(raw.PRICE)
			if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
				refuse(where .. ': KEY must be a string of 1 to ' .. Access.MAX_KEY .. ' characters')
			elseif listed[key] ~= nil then
				refuse(where .. ': KEY ' .. key .. ' is declared twice')
			elseif type(raw.RECORD) ~= 'string' or raw.RECORD == '' or #raw.RECORD > MAX_RECORD then
				refuse(where .. ' (' .. key .. '): RECORD must be a TweakDB record name')
			elseif price == nil or price <= 0 or price % 1 ~= 0 then
				-- Zero is refused and not honoured: a free car is a stock-list
				-- mistake, and honouring it hands out something nobody meant to
				-- give away.
				refuse(where .. ' (' .. key .. '): PRICE must be a whole number above zero')
			elseif type(raw.LABEL) ~= 'string' or raw.LABEL == '' or #raw.LABEL > MAX_STOCK_LABEL then
				refuse(where .. ' (' .. key .. '): LABEL must be a string of 1 to ' .. MAX_STOCK_LABEL .. ' characters')
			elseif type(raw.CLASS) ~= 'string' or raw.CLASS == '' or #raw.CLASS > MAX_CLASS then
				refuse(where .. ' (' .. key .. '): CLASS must be a string of 1 to ' .. MAX_CLASS .. ' characters')
			else
				listed[key] = {
					key = key,
					label = raw.LABEL,
					class = raw.CLASS,
					record = raw.RECORD,
					price = price,
					av = Access.IsAv(raw.RECORD),
				}
			end
		end
	end
	return listed
end

--- Everything for sale, by key.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.STOCK = stock(nil)

--- Answers one stock row by key, or nil. The key is matched exactly.
-- @author XEROX710
-- @param key any
-- @return table|nil
function Access.Entry(key)
	if type(key) ~= 'string' then return nil end
	return Access.STOCK[key]
end

--- Whether a dealer of this kind may sell this entry.
-- The one rule that decides it: a `garage` dealer sells ground vehicles, an
-- `avpad` dealer sells AVs, and the entry's own record is what says which it is.
-- @author XEROX710
-- @param kind string
-- @param entry table|nil
-- @return boolean
function Access.SoldHere(kind, entry)
	if kind ~= M.KIND.GARAGE and kind ~= M.KIND.AVPAD then return false end
	if type(entry) ~= 'table' then return false end
	return (kind == M.KIND.AVPAD) == (entry.av == true)
end

--- What one dealer sells, sorted by class and then by name.
-- Sorted for the same reason a spot list is: `pairs` order would reshuffle the
-- menu between two opens and a determinism check between two runs.
-- @author XEROX710
-- @param kind string
-- @return table[] array of entries
function Access.For(kind)
	local list = {}
	for _, entry in pairs(Access.STOCK) do
		if Access.SoldHere(kind, entry) then list[#list + 1] = entry end
	end
	table.sort(list, function(left, right)
		if left.class ~= right.class then return left.class < right.class end
		if left.label ~= right.label then return left.label < right.label end
		return left.key < right.key
	end)
	return list
end

--- Normalises one stock row off the wire.
-- The client draws what it is sent and re-checks the shape rather than trusting
-- it: a row with no key or an unreadable price is dropped, so a malformed
-- catalogue costs one row and not the whole list.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWireRow(raw)
	if type(raw) ~= 'table' then return nil, 'every row must be a table' end
	if type(raw.key) ~= 'string' or raw.key == '' or #raw.key > Access.MAX_KEY then
		return nil, 'a row key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters'
	end
	if type(raw.label) ~= 'string' or raw.label == '' or #raw.label > MAX_STOCK_LABEL then
		return nil, ('%s: LABEL must be a string of 1 to %d characters'):format(raw.key, MAX_STOCK_LABEL)
	end
	local price = finiteNumber(raw.price)
	if price == nil or price <= 0 then
		return nil, ('%s: PRICE must be a number above zero'):format(raw.key)
	end
	return {
		key = raw.key,
		label = raw.label,
		class = type(raw.class) == 'string' and raw.class or '',
		price = price,
		-- What the row shows in the affordance column. The server formats it and
		-- this is a display string only: the price above is what a purchase is
		-- checked against, on the server.
		text = type(raw.text) == 'string' and raw.text or tostring(price),
	}
end

--- One stock row as the client reads it, with the price already formatted.
-- The SERVER formats it: it owns the currency table and the grouping rule, and a
-- client that formatted its own would be a second answer to the same question.
-- @author XEROX710
-- @param entry table
-- @param text string the formatted price
-- @return table
function Access.Wire(entry, text)
	return {
		key = entry.key,
		label = entry.label,
		class = entry.class,
		price = entry.price,
		text = text,
	}
end

-- ── the configuration, read back ────────────────────────────────────────────

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

	local distance = finiteNumber(Config.MAX_DISTANCE)
	if distance == nil or distance < 1.0 or distance > 500.0 then
		lines[#lines + 1] = 'MAX_DISTANCE must be a finite number, 1 to 500 metres'
	end
	local groundOffset = finiteNumber(Config.GROUND_OFFSET)
	if groundOffset == nil or groundOffset < 0.0 or groundOffset > 2.0 then
		lines[#lines + 1] = 'GROUND_OFFSET must be a finite number, 0 to 2 metres'
	end
	local lift = finiteNumber(Config.AV_LIFT)
	if lift == nil or lift < 0.0 or lift > 10.0 then
		lines[#lines + 1] = 'AV_LIFT must be a finite number, 0 to 10 metres'
	end

	-- An empty stock is not an error -- an operator may be between suppliers --
	-- but a row that was refused is.
	stock(lines)

	if type(Config.STOCK) == 'table' then
		local total = OPX.Table.Count(Access.STOCK)
		if total > 0 and #Access.For(M.KIND.GARAGE) + #Access.For(M.KIND.AVPAD) == 0 then
			lines[#lines + 1] = 'STOCK has rows but no dealer kind can sell any of them'
		end
	end

	for _, kind in ipairs({ M.KIND.GARAGE, M.KIND.AVPAD }) do
		local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
		if type(declared) ~= 'table' then
			lines[#lines + 1] = ('MARKER.%s must be a table of shape, style and RADIUS'):format(kind)
		else
			local shape = type(declared.shape) == 'string' and declared.shape:lower() or nil
			if shape ~= nil and not SHAPES[shape] then
				lines[#lines + 1] = ('MARKER.%s.shape must be ring or cylinder'):format(kind)
			end
			local style = type(declared.style) == 'string' and declared.style:lower() or nil
			if style ~= nil and not STYLES[style] then
				lines[#lines + 1] = ('MARKER.%s.style must be interaction, objective, spawn or danger')
					:format(kind)
			end
			local radius = finiteNumber(declared.RADIUS)
			if radius == nil or radius < 0.1 or radius > 50.0 then
				lines[#lines + 1] = ('MARKER.%s.RADIUS must be a finite number, 0.1 to 50'):format(kind)
			end
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
