--- Repeating server work, under the same name the client half uses.
-- @author dop42
--
-- `OPX.Scheduler.Every` means the same thing on both sides -- register work,
-- get a handle, cancel it, read the report -- and is implemented differently on
-- each, because the two runtimes fail differently.
--
--   CLIENT  one loop for every job. Exceeding the per-resume instruction budget
--           unwinds out of the coroutine body and the loop is never resumed
--           again, silently, so the work is pooled, capped per pass, and a job
--           that keeps raising is suspended rather than left to poison the pass.
--   SERVER  one managed task per job, which is what the platform documents:
--           `CreateThread` costs a task, a resource may hold 1,024 of them, and
--           there is no per-resume budget to trip. Nothing is pooled, nothing
--           starves, and a job is NEVER suspended -- a save loop that stopped
--           itself after three bad passes would lose everything written after
--           them, which is worse than a noisy journal.
--
-- What it replaces: six copies of `CreateThread(function() while true do Wait(n)
-- ... end end)`, each with its own hand-rolled pcall and its own "log the first
-- failure of a run and then be quiet" flag -- and one copy, the vehicle save
-- loop, that had no guard at all and would have died on the first raise from a
-- host read, taking every later write with it.

OPX.Scheduler = OPX.Scheduler or {}

local jobs = {}
local order = {}
local nextHandle = 0

local MIN_INTERVAL_MS = 50

--- This pass's interval. A function is re-read every pass, which is what a job
--- whose cadence is a live tunable needs: a number captured at registration is
--- frozen for the life of the resource.
local function intervalOf(job)
	local value = job.interval
	if type(value) == 'function' then
		local ok, answered = pcall(value)
		value = ok and answered or nil
	end
	value = math.floor(tonumber(value) or 0)
	if value < MIN_INTERVAL_MS then return MIN_INTERVAL_MS end
	return value
end

--- Registers repeating work on its own managed task. Returns a handle for
--- `Cancel`. The first pass runs one interval from now, never at registration:
--- a module's `Start` is not the place to do a sweep, and a caller that wants
--- one calls its own step before registering.
-- @author dop42
-- @param name string owner and purpose, for the log line if it raises
-- @param intervalMs integer|function milliseconds, or a function answering them
-- @param step function
-- @return integer handle
function OPX.Scheduler.Every(name, intervalMs, step)
	if type(name) ~= 'string' or type(step) ~= 'function' then
		error('Every(name, intervalMs, step)', 2)
	end

	nextHandle = nextHandle + 1
	local job = {
		handle = nextHandle,
		name = name,
		interval = intervalMs,
		step = step,
		live = true,
		failing = false,
	}
	jobs[nextHandle] = job
	order[#order + 1] = nextHandle

	CreateThread(function()
		while job.live do
			Wait(intervalOf(job))
			-- Read again after the wait: a cancel during it means this pass must
			-- not run, and a stopping resource is exactly that case.
			if not job.live then return end

			local ok, failure = pcall(job.step)
			if ok then
				job.failing = false
			elseif not job.failing then
				-- Once per run of failures. A job that raises every pass at 500ms
				-- would otherwise write two lines a second for the session.
				job.failing = true
				Open77.log.error(('[scheduler] %s: %s'):format(job.name, tostring(failure)))
			end
		end
	end)

	return nextHandle
end

--- Stops a registered job at its next wake. Safe for a handle already cancelled.
-- @author dop42
-- @param handle integer
function OPX.Scheduler.Cancel(handle)
	local job = jobs[handle]
	if job == nil then return end
	job.live = false
	jobs[handle] = nil
end

--- Stops every job. The resource is going down; the tasks go with it either way,
--- but a job that wakes between now and then must not run against torn-down state.
-- @author dop42
function OPX.Scheduler.Stop()
	for handle, job in pairs(jobs) do
		job.live = false
		jobs[handle] = nil
	end
end

--- One line per live job: name and interval. For the diagnostic command.
-- @author dop42
-- @return string[]
function OPX.Scheduler.Report()
	local lines = {}
	for index = 1, #order do
		local job = jobs[order[index]]
		if job ~= nil then
			lines[#lines + 1] = ('%-28s %6dms %s')
				:format(job.name, intervalOf(job), job.failing and 'failing' or 'running')
		end
	end
	return lines
end
