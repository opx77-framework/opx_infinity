--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- Two vocabularies live here and they are deliberately separate things. A SPOT
-- is a place: where a dealer stands, which category it sells, and how it is
-- drawn. A STOCK ROW is a thing for sale: a name, a class, a TweakDB record and
-- a price. A purchase names one of each, and the server proves both again.
--
-- THE SPOT HALF IS NOT WRITTEN HERE. The record, the two input shapes that
-- normalise into it, the marker look and the coordinate box are all
-- `lib/shared/spots.lua`, and this file only names this module's own words to
-- them. `modules/garages/shared/access.lua` held 334 `diff`-clean identical
-- lines of it, and the two must agree exactly: a car bought at a dealer is
-- recalled at a garage, and a spot one of them accepts and the other refuses is
-- a car that exists nowhere.
--
-- THE STOCK HALF IS, and stays. What is for sale, at what price, and which kind
-- of dealer sells it is this module's own question -- no other module asks it --
-- and a shared catalogue would be a shape with one user.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a price that is not a whole number above zero reads
-- as a warning at boot rather than a raise inside a scan, a menu or a purchase.

local M = OPX.Modules.Get('dealership')

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

-- The largest record and the longest text a stock row may carry. Both are
-- refused here rather than at the vehicles contract, which caps a record too.
local MAX_RECORD = 256
local MAX_STOCK_LABEL = 64
local MAX_CLASS = 32

-- ── spots ───────────────────────────────────────────────────────────────────

-- This module's words for the shared record: a dealer has a KIND, because a
-- showroom and an AV pad sell different halves of the catalogue, and a HEADING,
-- because a bought vehicle is CREATED at one and something has to say which way
-- it faces.
local SPEC = {
	noun = 'dealer',
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
-- `OPX.Config.SHARED.AV_PREFIXES`. The comment that used to sit here claimed
-- this WAS the rule the garages module uses; it was a second copy over a second
-- key, and the admin catalogue had a third that behaved differently again. It is
-- one rule now, which is what makes a record air for every part of the server or
-- for none of it.
-- @author XEROX710
-- @param record any
-- @return boolean
function Access.IsAv(record)
	return OPX.Vehicle.IsAvRecord(record)
end

-- What a marker falls back to per kind when the operator named nothing usable. A
-- pad is a RING, because an AV lands inside it and a filled cylinder would be
-- drawn through the hull; a showroom is a cylinder you walk into.
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

--- The AV lift, clamped to something a chassis will not fall through.
-- The rule is `lib/shared/vehicle.lua`, beside the one that says whether a
-- record is an AV at all: the staff spawner had a third copy with no bound.
-- @author XEROX710
-- @return number
function Access.AvLift()
	return OPX.Vehicle.AvLift(Config.AV_LIFT)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author XEROX710
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 150.0)
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

	-- The draw distance and the ground offset are reported against the same
	-- bounds `Access.Marker` and `Access.MaxDistance` clamp to, because they are
	-- literally the same constants.
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)

	OPX.Vehicle.AvLiftProblem(Config.AV_LIFT, lines)

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
