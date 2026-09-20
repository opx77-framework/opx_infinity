--- Config reads, the job gate and the problem report, for both halves.
-- @author dop42
--
-- THE GATE IS `lib/shared/jobgate.lua` AND NOT A COPY OF IT. That file exists
-- because the elevators module wrote the five branches -- the JOBS map, the
-- ON_DUTY flag, the staleness bound, primary-versus-any-membership and a refusal
-- that names the closest near-miss -- and `modules/teleports` then wanted them
-- verbatim. This module is the third to want them, and a third hand-kept copy of
-- an access rule is how three surfaces end up disagreeing about who may pass. So
-- what is left here is the ADAPTER: the words `config/gunsmith.lua` uses,
-- translated into the words the gate takes.
--
-- The rule it inherits, and the one worth restating because it is the reason to
-- inherit rather than invent:
--
--   A PLACE THAT DECLARES NO JOBS IS OPEN, AND STAYS OPEN WHATEVER HAPPENS TO
--   THE CHARACTER READ. A place that declares JOBS is SHUT when the read is
--   missing, shut when it is stale, and shut when the grade is short.
--
-- Fail-open for the ungated, fail-closed for the gated. A public workshop that
-- shuts because the roster hiccuped is a bug that looks like a design, and a
-- gated armoury that opens for the same reason is a rifle handed to anybody.
--
-- WHAT THIS MODULE ADDS TO THE GATE is one thing the other two had no use for: a
-- FLOOR under every grade, so a recipe may ask for a rank of its own inside the
-- job the armoury already asks for. It is expressed as a requirement DERIVED
-- from the armoury's own JOBS rather than as a second gate -- see
-- `Access.Requirement` -- so a recipe bar and an armoury door can never disagree
-- about staleness, duty or which membership counts.
--
-- WHAT THIS FILE DOES NOT DO is decide anything about a recipe's COST, its
-- duration or its yield. Those are the crafting module's and are validated
-- there; the RECIPES list below is carried through untouched and handed over.
-- The one recipe field this module reads is `GRADE`, which crafting has no
-- business knowing about.

local M = OPX.Modules.Get('gunsmith')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

--- Coerces to a number, rejecting NaN and both infinities.
-- Not `OPX.Text.Finite`, which also caps at 2^53: a millisecond clock is
-- measured with this and must not be bounded like a coordinate.
-- @author dop42
-- @param value any
-- @return number|nil
function Access.FiniteNumber(value)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

local finite = Access.FiniteNumber

-- Box every accepted coordinate fits in.
local BOUND = 1000000

--- Coerces a world coordinate: finite and inside BOUND.
-- @author dop42
-- @param value any
-- @return number|nil
function Access.Coordinate(value)
	local parsed = finite(value)
	if parsed == nil or parsed > BOUND or parsed < -BOUND then return nil end
	return parsed
end

local coordinate = Access.Coordinate

--- Coerces a whole number inside a range.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return integer|nil
function Access.Integer(value, low, high)
	local parsed = finite(value)
	if parsed == nil or parsed % 1 ~= 0 or parsed < low or parsed > high then return nil end
	return math.floor(parsed)
end

local integer = Access.Integer

--- Past this snapshot age a gated armoury closes.
Access.JOB_MAX_AGE_MS = finite(Config.JOB_MAX_AGE_MS) or 0

--- Metres the bench is worked from.
Access.REACH = finite(Config.REACH) or 0

--- Metres within which the eye registers a sphere.
Access.PROMPT_RADIUS = finite(Config.PROMPT_RADIUS) or 0

--- The armouries as configured, or an empty table when missing.
-- Read as empty rather than refused, because every read below is reachable from
-- the contract and a raise there is a raise inside a network handler.
Access.ARMOURIES = type(Config.ARMOURIES) == 'table' and Config.ARMOURIES or {}
local ARMOURIES = Access.ARMOURIES

-- Armoury key -> its validated bench position, its validated chest, and the
-- minimum grade each of its recipes asks for. BUILT ONCE AT LOAD, like the
-- elevators module's POSITIONS table and for the same reason: the eye walks
-- every armoury on every scan, and a coordinate converted there would be
-- converted again every pass.
local BENCHES, CHESTS, GRADES = {}, {}, {}

--- One CHEST block, validated, or nil.
--
-- A chest is an inventory STASH and its NAME obeys that module's rule -- letters,
-- digits, `_`, `-`, `.`, up to 48 -- which is NOT the crafting key rule: a colon
-- is legal in a bench key and is not legal in a stash name. A name that would be
-- refused at the far end is refused here instead, where it becomes a boot warning
-- rather than a chest that silently never opens.
--
-- Public rather than local because it is the one piece of chest handling that is
-- a pure function of a table, and a test that could only reach it through the
-- shipped config could only ever check the names that ship.
-- @author dop42
-- @param raw any
-- @return table|nil
function Access.ChestFrom(raw)
	if type(raw) ~= 'table' then return nil end
	local name = raw.NAME
	if type(name) ~= 'string' then return nil end
	name = OPX.String.Trim(name)
	if name == '' or #name > 48 or not name:match('^[%w_%-%.]+$') then return nil end

	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil end

	return {
		name = name,
		label = type(raw.LABEL) == 'string' and OPX.String.Trim(raw.LABEL) or nil,
		slots = integer(raw.SLOTS, 1, 200) or 50,
		maxWeight = integer(raw.MAX_WEIGHT, 0, 4000000000) or 100000,
		x = x, y = y, z = z,
		bucket = integer(raw.BUCKET, 0, 2147483647) or 0,
	}
end

for key, armoury in pairs(ARMOURIES) do
	if type(key) == 'string' and type(armoury) == 'table' then
		local bench = armoury.BENCH
		local x = type(bench) == 'table' and coordinate(bench.X) or nil
		local y = type(bench) == 'table' and coordinate(bench.Y) or nil
		local z = type(bench) == 'table' and coordinate(bench.Z) or nil
		if x ~= nil and y ~= nil and z ~= nil then
			BENCHES[key] = { x = x, y = y, z = z,
				bucket = integer(bench.BUCKET, 0, 2147483647) or 0 }
		end

		CHESTS[key] = Access.ChestFrom(armoury.CHEST)

		local grades = {}
		local recipes = type(armoury.RECIPES) == 'table' and armoury.RECIPES or {}
		for index = 1, #recipes do
			local row = recipes[index]
			if type(row) == 'table' and type(row.KEY) == 'string' then
				-- A recipe with no GRADE asks for nothing beyond the armoury's own
				-- gate, and zero is a real answer: grade 0 is the bottom rung of a
				-- job and not the absence of one.
				grades[row.KEY] = integer(row.GRADE, 0, 255) or 0
			end
		end
		GRADES[key] = grades
	end
end

--- One configured armoury by key, or nil.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Armoury(key)
	if type(key) ~= 'string' then return nil end
	local armoury = ARMOURIES[key]
	if type(armoury) ~= 'table' then return nil end
	return armoury
end

--- An armoury's validated bench position, or nil when it has none.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Bench(key)
	return type(key) == 'string' and BENCHES[key] or nil
end

--- An armoury's validated chest, or nil when it has none.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Chest(key)
	return type(key) == 'string' and CHESTS[key] or nil
end

--- The minimum grade a recipe asks for at an armoury, or nil when it has none.
-- @author dop42
-- @param key any
-- @param recipeKey any
-- @return integer|nil
function Access.Grade(key, recipeKey)
	local grades = type(key) == 'string' and GRADES[key] or nil
	if grades == nil or type(recipeKey) ~= 'string' then return nil end
	return grades[recipeKey]
end

--- One armoury as a requirement the shared gate understands.
--
-- `atMinimum` IS A FLOOR RAISED UNDER EVERY GRADE, NOT A SECOND GATE, and that
-- is the whole trick of the per-recipe rank. An armoury asking `{ arasaka = 0 }`
-- with a recipe that wants grade 2 becomes `{ arasaka = 2 }`, and the shared
-- gate then answers the one question it already knows how to answer -- with the
-- same staleness bound, the same duty rule, the same membership rule and the
-- same near-miss ranking it used for the door. A separate grade check written
-- here would be a second rule, and the second rule is always the one that drifts.
--
-- An armoury with NO JOBS comes back with no jobs, floor or no floor: a grade is
-- a rank inside a job, and a public bench has no job to rank in.
-- @author dop42
-- @param armoury table
-- @param atMinimum integer|nil
-- @return table { jobs, onDuty }
function Access.Requirement(armoury, atMinimum)
	if type(armoury) ~= 'table' then return { jobs = nil, onDuty = false } end
	local required = armoury.JOBS
	if type(required) ~= 'table' or next(required) == nil then
		return { jobs = nil, onDuty = armoury.ON_DUTY == true }
	end

	local bar = finite(atMinimum) or 0
	local raised = {}
	for name, minimum in pairs(required) do
		-- A malformed minimum is carried through UNTOUCHED rather than coerced to
		-- the bar: `OPX.JobGate.Problems` is what names it, and repairing it here
		-- would hide the typo behind a gate that quietly works.
		local level = finite(minimum)
		raised[name] = level ~= nil and math.max(level, bar) or minimum
	end
	return { jobs = raised, onDuty = armoury.ON_DUTY == true }
end

--- Decides whether a character snapshot may work an armoury.
--
-- A thin adapter over `OPX.JobGate.Evaluate`, which is where the five branches
-- live; the two arguments this module supplies are the ones only this module
-- knows -- its own staleness bound and its own MEMBERSHIP word.
-- @author dop42
-- @param armoury table
-- @param snapshot table|nil
-- @param nowMs integer
-- @param atMinimum integer|nil a floor under every JOBS grade, for a recipe
-- @return boolean
-- @return string|nil
function Access.Evaluate(armoury, snapshot, nowMs, atMinimum)
	return OPX.JobGate.Evaluate(Access.Requirement(armoury, atMinimum), snapshot, nowMs,
		{ maxAgeMs = Access.JOB_MAX_AGE_MS, membership = Config.MEMBERSHIP })
end

--- Whether a character may make one recipe at one armoury.
--
-- The armoury gate first and the recipe's own bar second, in one call, because
-- the two must never be asked in the other order: a recipe that asks for grade 3
-- at an armoury this character may not enter at all should answer "not your
-- armoury" and not "not senior enough", which reads as an invitation to ask for
-- a promotion to a job they do not hold.
--
-- A GRADE ON AN UNGATED ARMOURY DOES NOTHING, and that is right rather than an
-- oversight. A grade is a rank inside a job; an armoury that names no JOBS has
-- no rank to compare against, so `Evaluate` answers true before the bar is ever
-- read. An operator who wants a recipe held back at a public bench is asking for
-- a gate, and the way to ask for one is to name a job.
-- @author dop42
-- @param key string
-- @param recipeKey string
-- @param snapshot table|nil
-- @param nowMs integer
-- @return boolean
-- @return string|nil
function Access.MayMake(key, recipeKey, snapshot, nowMs)
	local armoury = Access.Armoury(key)
	if armoury == nil then return false, 'no_such_bench' end

	local allowed, refusal = Access.Evaluate(armoury, snapshot, nowMs, nil)
	if not allowed then return false, refusal end

	local grade = Access.Grade(key, recipeKey)
	if grade == nil then return false, 'no_such_recipe' end
	if grade <= 0 then return true, nil end
	return Access.Evaluate(armoury, snapshot, nowMs, grade)
end

--- Every armoury a surface can draw, sorted by key.
--
-- SORTED, because the target eye answers with the INDEX of the sphere it
-- matched and nothing else ties that index back to an armoury. `pairs` order
-- would reshuffle between two boots, and a row would then open the wrong
-- armoury's bench -- silently, and only on some machines.
-- @author dop42
-- @return table[]
function Access.List()
	local out = {}
	for key in pairs(ARMOURIES) do
		local bench = BENCHES[key]
		if bench ~= nil then
			local armoury = ARMOURIES[key]
			out[#out + 1] = {
				key = key,
				label = type(armoury.LABEL) == 'string' and armoury.LABEL or key,
				bench = bench,
				chest = CHESTS[key],
			}
		end
	end
	table.sort(out, function(left, right) return left.key < right.key end)
	return out
end

--- The bench definition one armoury is registered with, for the crafting module.
--
-- `canUse` is supplied by the caller rather than built here, because answering
-- it needs a character roster and this file is shared: the client half has a
-- snapshot and the server half has the roster, and neither of those belongs in
-- a load-time table.
-- @author dop42
-- @param key string
-- @param canUse function|nil
-- @return table|nil
function Access.BenchDefinition(key, canUse)
	local armoury = Access.Armoury(key)
	local bench = Access.Bench(key)
	if armoury == nil or bench == nil then return nil end
	return {
		label = type(armoury.LABEL) == 'string' and armoury.LABEL or key,
		owner = 'gunsmith',
		position = bench,
		reach = Access.REACH,
		queue = integer(armoury.QUEUE, 1, 100),
		recipes = type(armoury.RECIPES) == 'table' and armoury.RECIPES or {},
		canUse = canUse,
	}
end

-- The coordinate axes, in report order.
local AXES = { 'X', 'Y', 'Z' }

--- Every configuration error visible without a world, sorted.
--
-- Job NAMES are not checked and cannot be: they live in the character module and
-- this runs at load with nothing waited on. RECIPES are not checked either --
-- the crafting module validates them when the bench is registered and warns in
-- its own voice, and a second validator here would be a second answer to "is
-- this recipe legal" that could disagree with the one that decides.
-- @author dop42
-- @return string[]
function Access.Problems()
	local lines = {}
	if type(Config.ARMOURIES) ~= 'table' then
		lines[#lines + 1] = 'ARMOURIES must be a table of armoury key -> definition'
	end
	if Access.REACH <= 0 then
		lines[#lines + 1] = 'REACH must be a finite number above zero'
	end
	if Access.PROMPT_RADIUS <= 0 then
		lines[#lines + 1] = 'PROMPT_RADIUS must be a finite number above zero'
	end
	if Access.JOB_MAX_AGE_MS <= 0 then
		lines[#lines + 1] = 'JOB_MAX_AGE_MS must be a finite number above zero'
	end

	-- Chest NAMES across every armoury. A stash key is what the stored row is
	-- keyed on, so two armouries sharing one is not two chests -- it is one chest
	-- with two doors, and whichever operator wrote the second one did not mean
	-- that.
	local chestNames = {}

	for key, armoury in pairs(ARMOURIES) do
		if type(key) ~= 'string' or key == '' then
			lines[#lines + 1] = 'every ARMOURIES key must be a non-empty string'
		elseif type(armoury) ~= 'table' then
			lines[#lines + 1] = key .. ': every ARMOURIES entry must be a table'
		else
			if type(armoury.LABEL) ~= 'string' or armoury.LABEL == '' then
				lines[#lines + 1] = key .. ': no LABEL'
			end

			if type(armoury.BENCH) ~= 'table' then
				lines[#lines + 1] = key .. ': no BENCH, so there is nowhere to make anything'
			else
				for _, axis in ipairs(AXES) do
					if coordinate(armoury.BENCH[axis]) == nil then
						lines[#lines + 1] = ('%s: BENCH %s must be a finite number inside %d')
							:format(key, axis, BOUND)
					end
				end
			end

			if armoury.CHEST ~= nil then
				local chest = CHESTS[key]
				if chest == nil then
					lines[#lines + 1] = key ..
						': CHEST needs a NAME of letters, digits, _ - . up to 48 and a finite X, Y and Z'
				elseif chestNames[chest.name] ~= nil then
					lines[#lines + 1] = ('%s: CHEST NAME %s is already used by %s; a stash key is ' ..
						'one chest'):format(key, chest.name, chestNames[chest.name])
				else
					chestNames[chest.name] = key
				end
			end

			-- The JOBS block goes through the same checker the gate that reads it
			-- uses, so the two can never drift into accepting different shapes.
			OPX.JobGate.Problems(armoury.JOBS, key, lines)

			if type(armoury.RECIPES) ~= 'table' or #armoury.RECIPES == 0 then
				lines[#lines + 1] = key .. ': no RECIPES, so its bench would open empty'
			else
				for index = 1, #armoury.RECIPES do
					local row = armoury.RECIPES[index]
					if type(row) == 'table' and row.GRADE ~= nil and
						integer(row.GRADE, 0, 255) == nil then
						lines[#lines + 1] = ('%s recipe #%d: GRADE must be a whole number from 0 to 255')
							:format(key, index)
					end
				end
			end
		end
	end

	-- Sorted, because `pairs` order would reshuffle the report between runs.
	table.sort(lines)
	return lines
end
