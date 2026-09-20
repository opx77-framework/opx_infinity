--- The one job gate: does this character snapshot satisfy a job requirement.
-- @author dop42
--
-- FACTORED OUT OF `modules/elevators/shared/access.lua`, WHICH WROTE IT FIRST,
-- and moved here the moment a second module wanted the same rule. The elevators
-- copy was the only one on disk; `modules/teleports` needed it verbatim --
-- `JOBS = { name = minimumGrade }`, an `ON_DUTY` flag, a staleness bound, a
-- primary-job-versus-any-membership distinction and a refusal that names the
-- CLOSEST near-miss -- and a second hand-kept copy of a five-branch access rule
-- is how two surfaces end up disagreeing about who may pass. `core/shared/glyphs.lua`
-- is the same story told about icons: three copies, 47 names, 45 and 14, and no
-- test looking.
--
-- WHAT A SNAPSHOT IS. The job fields of a loaded character, plus the millisecond
-- it was read at:
--
--   { job  = { name = 'ncpd', grade = { level = 2 }, onDuty = true },
--     jobs = { ncpd = 2, fixer = 0 },   -- every membership, grade only
--     atMs = 1723... }
--
-- The server stamps `atMs` at the moment it reads its own roster, so its age
-- test always passes; a CLIENT holds a replicated copy that can be minutes old,
-- and that is the whole reason the bound exists. Both halves call this function
-- so the panel a client draws and the answer a server gives are the same
-- decision made twice, rather than two decisions that happen to agree.
--
-- IT IS PURE, and deliberately so: no clock of its own, no config read, no
-- module namespace. `nowMs` and the policy are arguments because the caller's
-- module owns both, and because a pure function is one a test can drive to
-- every branch without a world.

OPX.JobGate = {}

-- Failure ranking, so a refusal names the closest near-miss rather than the
-- first one `pairs` happens to meet. Somebody who holds the job at the right
-- grade but is off duty must be told THAT, and not `job_required` because a
-- second, irrelevant job was visited first.
local RANK = { off_duty = 3, grade_too_low = 2, job_required = 1 }

-- Read when the caller passes no policy at all, so a missing table is a gate
-- that still closes rather than an index of nil.
local NO_POLICY = {}

-- Coerces to a number, rejecting NaN and both infinities. Kept local rather
-- than folded into `OPX.Text.Finite`, which also caps at 2^53: a millisecond
-- clock is measured with this and must not be bounded like a coordinate. It is
-- the same helper `modules/elevators/shared/access.lua` keeps, for the same
-- stated reason.
local function finiteNumber(value)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- The grade of a job this character holds, or nil for one they do not.
--
-- `membership = 'any'` counts a membership for the GRADE and never for
-- ON_DUTY: the memberships table carries grades, not a clock, so a row in it
-- can never answer "is this person working right now". Under the default,
-- `primary`, only the worked job counts at all.
local function heldGrade(snapshot, name, membership)
	local job = snapshot.job
	if type(job) == 'table' and job.name == name then
		-- A job with no grade table at all reads as grade 0 rather than as no
		-- job: the character holds it, and a minimum of 0 is the common case an
		-- operator writes for "anybody on the payroll".
		return type(job.grade) == 'table' and finiteNumber(job.grade.level) or 0
	end
	if membership ~= 'any' then return nil end
	if type(snapshot.jobs) ~= 'table' then return nil end
	return finiteNumber(snapshot.jobs[name])
end

--- Decides whether a character snapshot satisfies one job requirement.
-- @author dop42
--
-- A requirement with no JOBS is PUBLIC and stays open with no snapshot at all:
-- a broken character read must not lock a lobby, a door or a walkway. That is
-- the single most load-bearing line in this file -- it is what keeps a database
-- hiccup from turning every ungated surface on the server into a wall.
--
-- A gated requirement closes on every doubt: no snapshot, a snapshot older than
-- `maxAgeMs`, a clock that cannot be read, a snapshot with no job table. The
-- asymmetry is the point. Refusing a public floor costs a player nothing they
-- had; granting a gated one costs the operator the gate.
--
-- @param requirement table|nil { jobs = { name = minimumGrade }, onDuty = boolean }
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @param policy table|nil { maxAgeMs = number, membership = 'primary'|'any' }
-- @return boolean
-- @return string|nil one of no_character, job_stale, job_required,
--   grade_too_low, off_duty
function OPX.JobGate.Evaluate(requirement, snapshot, nowMs, policy)
	local required = type(requirement) == 'table' and requirement.jobs or nil
	if type(required) ~= 'table' or next(required) == nil then return true, nil end

	policy = type(policy) == 'table' and policy or NO_POLICY
	local maxAgeMs = finiteNumber(policy.maxAgeMs) or 0

	local atMs = type(snapshot) == 'table' and finiteNumber(snapshot.atMs) or nil
	if atMs == nil then return false, 'no_character' end

	-- A CLOCK THAT CANNOT BE READ IS A STALE READ, and not a raise. The elevators
	-- original subtracted the two raw, so a `nowMs` that arrived as a string --
	-- from a host whose timer answered oddly, or from a caller that forgot the
	-- argument -- took down whatever network handler was asking. Refusing a gated
	-- surface is the safe direction and it is the one branch of this function
	-- that changed in the move.
	local at = finiteNumber(nowMs)
	if at == nil or at - atMs > maxAgeMs then return false, 'job_stale' end
	if type(snapshot.job) ~= 'table' then return false, 'no_character' end

	local worst, worstRank = 'job_required', RANK.job_required
	for name, minimum in pairs(required) do
		local held = heldGrade(snapshot, name, policy.membership)
		if held ~= nil then
			if held < (finiteNumber(minimum) or 0) then
				if RANK.grade_too_low > worstRank then
					worst, worstRank = 'grade_too_low', RANK.grade_too_low
				end
			elseif requirement.onDuty == true and
				not (snapshot.job.name == name and snapshot.job.onDuty == true) then
				if RANK.off_duty > worstRank then worst, worstRank = 'off_duty', RANK.off_duty end
			else
				return true, nil
			end
		end
	end
	return false, worst
end

--- Lists what is wrong with one JOBS block, in the caller's own words.
-- @author dop42
--
-- The messages are the elevators module's, kept to the letter so its diagnostic
-- reads exactly as it did. Job NAMES are not checked and cannot be: they live in
-- the character module's config, and every caller of this runs at load with
-- nothing waited on.
-- @param jobs any the JOBS block as an operator wrote it
-- @param where string what to name in the message, e.g. 'ncpd_watson floor #3'
-- @param lines table|nil collector, appended to and returned
-- @return string[]
function OPX.JobGate.Problems(jobs, where, lines)
	lines = lines or {}
	if jobs == nil then return lines end
	if type(jobs) ~= 'table' then
		lines[#lines + 1] = where .. ': JOBS must be a table of name -> minimum grade'
		return lines
	end
	for name, minimum in pairs(jobs) do
		if type(name) ~= 'string' or finiteNumber(minimum) == nil then
			lines[#lines + 1] = where ..
				': JOBS entries are job name -> minimum grade level, e.g. { ncpd = 0 }'
		end
	end
	return lines
end
