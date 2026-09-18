--- The gig catalogue: one normalised definition per configured gig.
-- @author dop42
--
-- Shared, and that is the point: the client draws a board row from the same
-- reading of `config/gigs.lua` the server pays from, so a gig the client offers
-- is a gig the server admits exists. Nothing here reaches the host, asks who is
-- standing where or knows what a run is.
--
-- A MALFORMED GIG IS DROPPED, NEVER RAISED ON. This file loads on every client
-- as well as on the server, and an operator's typo in one coordinate must cost
-- that gig and not the whole module. What was dropped and why is collected in
-- `Problems`, which both halves print at start.

local M = OPX.Modules.Get('gigs')

M.Catalog = {}
local Catalog = M.Catalog

-- Gigs on the board at once. Each holds one target row, and the eye bounds an
-- owner at 48.
local MAX_GIGS = 24

-- Points one gig's pool may hold, which is the target eye's own list limit, and
-- the fewest a pool may have.
local MAX_POINTS = 32
local MIN_POINTS = 1

-- Legs one run may hold. A collect gig of 20 steps is 21 legs and a courier gig
-- of 20 steps is 40, so this bounds STEPS rather than the legs it becomes.
local MAX_STEPS = 20

-- Milliseconds one action may take. The floor is what stops a gig configured at
-- zero from being a click marathon.
local MIN_ACTION_MS = 500
local MAX_ACTION_MS = 60000

-- Eddies one leg or one bonus may pay. A gig above this is an operator mistake
-- and is refused rather than quietly clamped.
local MAX_PAY = 100000

-- Bonus item rows one gig may roll, and the largest stack one row may hand over.
local MAX_ITEM_ROWS = 6
local MAX_ITEM_COUNT = 20

-- Metres a leg may be worked from, and the radius of the sphere its row answers
-- inside.
local MIN_REACH, MAX_REACH = 0.5, 12.0
local MIN_RADIUS, MAX_RADIUS = 0.2, 10.0

-- Normalised gigs by id, and their ids in a stable order.
Catalog.GIGS = {}
Catalog.ORDER = {}

-- One line per configuration fault, in the order they were found.
local problems = {}

-- Kinds a gig may declare.
local KINDS = { collect = true, courier = true }

-- Glyphs the eye will draw. RECOPIED from `modules/target/shared/model.lua` for
-- the reason that file gives: the page selects a local path by this name, and
-- core may not read a module's namespace. A gig naming a glyph outside the set
-- keeps its gig and loses its picture.
--
-- Published, because the CLIENT checks it a second time. The eye refuses a whole
-- ROW over an unknown glyph rather than dropping the picture, and so does a
-- toast, so a name that reached the client off the wire is measured against this
-- set before it is passed on -- otherwise one bad letter in one gig's ICON would
-- cost that leg its row entirely.
Catalog.ICONS = { interact = true, person = true, vehicle = true, info = true, lock = true,
	tool = true, location = true, box = true, door = true, heal = true, money = true, talk = true,
	folder = true, back = true,
	search = true, filter = true, list = true, star = true,
	weapon = true, ammo = true, shield = true, ban = true, warning = true,
	eye = true, hidden = true, tag = true,
	flag = true, map = true, world = true, clock = true, weather = true,
	gear = true, refresh = true, bolt = true, server = true, key = true,
	arrow = true, plus = true, minus = true, trash = true,
	heart = true, emote = true, food = true, drink = true, smoke = true }
local ICONS = Catalog.ICONS

--- The catalogue key a player reads for each refusal code. Shared, because both
--- halves answer refusals: the client for what it can decide alone, the server
--- for everything it re-derives. A code with no entry here reads as the generic
--- sentence rather than reaching a player as an internal word.
Catalog.REFUSAL = {
	no_such_gig = 'gigs.refuse.noSuchGig',
	not_running = 'gigs.refuse.notRunning',
	already_working = 'gigs.refuse.alreadyWorking',
	not_working = 'gigs.refuse.notWorking',
	stale_run = 'gigs.refuse.staleRun',
	stale_leg = 'gigs.refuse.staleLeg',
	rate_limited = 'gigs.refuse.rateLimited',
	no_position = 'gigs.refuse.noPosition',
	wrong_bucket = 'gigs.refuse.wrongBucket',
	too_far = 'gigs.refuse.tooFar',
	too_soon = 'gigs.refuse.tooSoon',
	not_trusted = 'gigs.refuse.notTrusted',
	day_full = 'gigs.refuse.dayFull',
	cooling = 'gigs.refuse.cooling',
	player_down = 'gigs.refuse.playerDown',
	no_character = 'gigs.refuse.noCharacter',
	not_sent = 'gigs.refuse.notSent',
	internal_error = 'gigs.refuse.internalError',
}

--- Whether a value is a finite number.
-- @author dop42
-- @param value any
-- @return boolean
function Catalog.Finite(value)
	return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

--- A finite number within bounds, or nil.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return number|nil
function Catalog.Number(value, low, high)
	local number = tonumber(value)
	if not Catalog.Finite(number) or number < low or number > high then return nil end
	return number
end

--- A whole number within bounds, or nil.
-- @author dop42
-- @param value any
-- @param low integer
-- @param high integer
-- @return integer|nil
function Catalog.Integer(value, low, high)
	local number = Catalog.Number(value, low, high)
	if number == nil or number % 1 ~= 0 then return nil end
	return math.tointeger(number) or math.floor(number)
end

--- One line of text no longer than max bytes, or nil.
-- @author dop42
-- @param value any
-- @param max integer
-- @return string|nil
function Catalog.Text(value, max)
	if type(value) ~= 'string' or value == '' or #value > max then return nil end
	if value:find('%c') then return nil end
	return value
end

--- The distance between two points, squared.
-- @author dop42
-- @param left table
-- @param right table
-- @return number
function Catalog.GapSquared(left, right)
	local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
	return dx * dx + dy * dy + dz * dz
end

-- Records a fault against a gig, keeping the order they were found in.
local function fault(id, line)
	problems[#problems + 1] = ('%s: %s'):format(tostring(id), line)
end

-- Reads a point: three coordinates and the operator's own words for it. The
-- label is optional, because a point in a pool of eight rarely deserves one.
local function readPoint(raw)
	if type(raw) ~= 'table' then return nil end
	local x = Catalog.Number(raw.X, -100000, 100000)
	local y = Catalog.Number(raw.Y, -100000, 100000)
	local z = Catalog.Number(raw.Z, -100000, 100000)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, label = Catalog.Text(raw.LABEL, 60) }
end

-- Reads a leg point -- a drop-off or a pickup -- which may carry its own pace
-- and its own animation. Both fall back to the gig's.
local function readStation(raw, actionMs, animation)
	local point = readPoint(raw)
	if point == nil then return nil end
	point.actionMs = Catalog.Integer(raw.ACTION_MS, MIN_ACTION_MS, MAX_ACTION_MS) or actionMs
	point.animation = Catalog.Text(raw.ANIMATION, 64) or animation
	return point
end

-- Reads a payout band. A band whose MIN is above its MAX is swapped rather than
-- refused: the gig still pays, and the line says what was read.
local function readBand(raw, id, name)
	if type(raw) ~= 'table' then return { min = 0, max = 0 } end
	local low = Catalog.Integer(raw.MIN, 0, MAX_PAY)
	local high = Catalog.Integer(raw.MAX, 0, MAX_PAY)
	if low == nil or high == nil then
		fault(id, ('%s is not a pair of whole numbers in 0..%d; it pays nothing')
			:format(name, MAX_PAY))
		return { min = 0, max = 0 }
	end
	if low > high then
		fault(id, ('%s has MIN above MAX; they were swapped'):format(name))
		low, high = high, low
	end
	return { min = low, max = high }
end

-- Reads the bonus item rows. A row naming nothing is dropped and said so; the
-- item NAME itself is not checked here, because the catalogue that could answer
-- lives in another module and may not be running at all.
local function readItems(raw, id)
	local rows = {}
	if raw == nil or raw == false then return rows end
	if type(raw) ~= 'table' then
		fault(id, 'ITEMS is not a list; no bonus item is rolled')
		return rows
	end
	for index = 1, #raw do
		local row = raw[index]
		local name = type(row) == 'table' and Catalog.Text(row.NAME, 64) or nil
		local count = type(row) == 'table' and Catalog.Integer(row.COUNT, 1, MAX_ITEM_COUNT) or nil
		local chance = type(row) == 'table' and Catalog.Integer(row.CHANCE, 0, 100) or nil
		if name == nil or count == nil or chance == nil then
			fault(id, ('ITEMS row %d needs NAME, COUNT 1..%d and CHANCE 0..100; it was dropped')
				:format(index, MAX_ITEM_COUNT))
		elseif #rows >= MAX_ITEM_ROWS then
			fault(id, ('ITEMS holds more than %d rows; the rest were dropped'):format(MAX_ITEM_ROWS))
			break
		else
			rows[#rows + 1] = { name = name, count = count, chance = chance }
		end
	end
	return rows
end

-- Reads one gig, or answers nil with the reason already recorded.
local function readGig(id, raw, defaults)
	if type(raw) ~= 'table' then
		fault(id, 'is not a table')
		return nil
	end
	if raw.ENABLED == false then return nil end

	local kind = type(raw.KIND) == 'string' and raw.KIND or nil
	if kind == nil or not KINDS[kind] then
		fault(id, ('KIND is %s; expected collect or courier'):format(tostring(raw.KIND)))
		return nil
	end

	local label = Catalog.Text(raw.LABEL, 80)
	if label == nil then
		fault(id, 'LABEL is missing or is not one line of at most 80 bytes')
		return nil
	end

	local start = readPoint(raw.START)
	if start == nil then
		fault(id, 'START needs finite X, Y and Z')
		return nil
	end
	start.bucket = Catalog.Integer(raw.BUCKET or (type(raw.START) == 'table' and raw.START.BUCKET),
		0, 65535) or 0

	local actionMs = Catalog.Integer(raw.ACTION_MS, MIN_ACTION_MS, MAX_ACTION_MS)
	if actionMs == nil then
		fault(id, ('ACTION_MS must be a whole %d..%d'):format(MIN_ACTION_MS, MAX_ACTION_MS))
		return nil
	end

	local steps = Catalog.Integer(raw.STEPS, 1, MAX_STEPS)
	if steps == nil then
		fault(id, ('STEPS must be a whole 1..%d'):format(MAX_STEPS))
		return nil
	end

	local animation = Catalog.Text(raw.ANIMATION, 64)

	local points = {}
	if type(raw.POINTS) == 'table' then
		for index = 1, #raw.POINTS do
			local point = readPoint(raw.POINTS[index])
			if point == nil then
				fault(id, ('POINTS row %d needs finite X, Y and Z; it was dropped'):format(index))
			elseif #points >= MAX_POINTS then
				fault(id, ('POINTS holds more than %d rows; the rest were dropped'):format(MAX_POINTS))
				break
			else
				points[#points + 1] = point
			end
		end
	end
	if #points < MIN_POINTS then
		fault(id, 'POINTS holds no usable point')
		return nil
	end

	-- A collect gig asking for more steps than it has points would repeat one,
	-- and a repeated point reads as a leg that did not advance. The run is
	-- shortened to the pool instead, once, here, rather than at every start.
	if kind == 'collect' and steps > #points then
		fault(id, ('STEPS is %d but POINTS holds %d; the run is %d legs long')
			:format(steps, #points, #points))
		steps = #points
	end

	local pickup = nil
	if kind == 'courier' then
		pickup = readStation(raw.PICKUP, actionMs, animation)
		if pickup == nil then
			fault(id, 'a courier gig needs a PICKUP with finite X, Y and Z')
			return nil
		end
	end

	local dropoff = nil
	if raw.DROPOFF ~= nil and raw.DROPOFF ~= false then
		dropoff = readStation(raw.DROPOFF, actionMs, animation)
		if dropoff == nil then
			fault(id, 'DROPOFF is set but has no finite X, Y and Z; the run ends on its last point')
		end
	end

	local pay = type(raw.PAY) == 'table' and raw.PAY or {}
	local moneyType = Catalog.Text(pay.TYPE, 32) or 'EDDIES'

	return {
		id = id,
		kind = kind,
		label = label,
		description = Catalog.Text(raw.DESCRIPTION, 180),
		icon = ICONS[raw.ICON] and raw.ICON or 'interact',

		start = start,
		steps = steps,
		actionMs = actionMs,
		animation = animation,
		points = points,
		pickup = pickup,
		dropoff = dropoff,

		pay = {
			moneyType = moneyType,
			perStep = readBand(pay.PER_STEP, id, 'PAY.PER_STEP'),
			bonus = readBand(pay.BONUS, id, 'PAY.BONUS'),
		},
		items = readItems(raw.ITEMS, id),

		cooldownMs = Catalog.Integer(raw.COOLDOWN_MS, 0, 86400000) or 0,
		maxRunsPerDay = Catalog.Integer(raw.MAX_RUNS_PER_DAY, 0, 1000) or 0,
		minReputation = Catalog.Integer(raw.MIN_REPUTATION, 0, 100000) or 0,
		reputation = Catalog.Integer(raw.REPUTATION, 0, 1000) or 0,

		reach = Catalog.Number(raw.REACH, MIN_REACH, MAX_REACH) or defaults.reach,
		radius = Catalog.Number(raw.POINT_RADIUS, MIN_RADIUS, MAX_RADIUS) or defaults.radius,
	}
end

--- Reads `config/gigs.lua` into the catalogue. Called from both halves' `Init`,
--- and idempotent: a second call rebuilds from the same configuration.
-- @author dop42
function Catalog.Read()
	Catalog.GIGS, Catalog.ORDER, problems = {}, {}, {}

	local settings = M.Settings
	local defaults = {
		reach = Catalog.Number(settings.REACH, MIN_REACH, MAX_REACH) or 2.5,
		radius = Catalog.Number(settings.POINT_RADIUS, MIN_RADIUS, MAX_RADIUS) or 1.6,
	}

	local declared = settings.GIGS
	if type(declared) ~= 'table' then
		problems[#problems + 1] = 'GIGS is not a table; the board is empty'
		return
	end

	-- Sorted, because `pairs` order would put the board rows and the command's
	-- listing in a different order on every restart.
	local ids = {}
	for id in pairs(declared) do
		if type(id) == 'string' then ids[#ids + 1] = id end
	end
	table.sort(ids)

	for index = 1, #ids do
		local id = ids[index]
		if Catalog.Text(id, 40) == nil or id:match('^[%l%d_]+$') == nil then
			fault(id, 'is not a lowercase slug of letters, digits and underscores')
		elseif #Catalog.ORDER >= MAX_GIGS then
			fault(id, ('more than %d gigs are enabled; the rest were dropped'):format(MAX_GIGS))
		else
			local gig = readGig(id, declared[id], defaults)
			if gig ~= nil then
				Catalog.GIGS[id] = gig
				Catalog.ORDER[#Catalog.ORDER + 1] = id
			end
		end
	end
end

--- One gig by id, or nil when it is not configured or was switched off.
-- @author dop42
-- @param id any
-- @return table|nil
function Catalog.Get(id)
	if type(id) ~= 'string' then return nil end
	return Catalog.GIGS[id]
end

--- Every runnable gig, in a stable order.
-- @author dop42
-- @return table[]
function Catalog.List()
	local out = {}
	for index = 1, #Catalog.ORDER do out[index] = Catalog.GIGS[Catalog.ORDER[index]] end
	return out
end

--- One line per configuration fault. Printed at start by both halves.
-- @author dop42
-- @return string[]
function Catalog.Problems()
	local out = {}
	for index = 1, #problems do out[index] = problems[index] end
	return out
end
