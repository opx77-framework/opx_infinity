--- The client's only loop. Modules register work here instead of spawning threads.
-- @author dop42
--
-- Twenty-one resources used to get twenty-one budgets. One runtime gets one, and
-- the platform's is unforgiving: exceeding the per-resume instruction budget
-- raises `Open77 script execution budget exceeded`, which unwinds straight out of
-- the coroutine body. A `while true do ... Wait(n) end` loop that hits it is never
-- resumed again -- it does not crash the resource, it does not repeat, and it logs
-- nothing. A loop that quietly stopped is almost always this.
--
-- So there is one loop, and it is defensive:
--   * at most MAX_PER_TICK jobs run in a single resume, rotating so none starves
--   * a job is wrapped in pcall, and one that raises repeatedly is suspended
--   * registration staggers first runs, so N jobs on the same interval do not all
--     land on the same tick for the rest of the session

OPX.Scheduler = OPX.Scheduler or {}

local jobs = {}
local cursor = 0
local running = false

local MAX_PER_TICK = 4
local MAX_FAILURES = 3
local IDLE_MS = 100

--- Registers repeating work. Returns a handle for `Cancel`.
-- @author dop42
-- @param name string owner and purpose, for the log line if it fails
-- @param intervalMs integer
-- @param step function
-- @return integer handle
function OPX.Scheduler.Every(name, intervalMs, step)
	if type(name) ~= 'string' or type(step) ~= 'function' then
		error('Every(name, intervalMs, step)', 2)
	end
	local interval = math.max(0, math.floor(tonumber(intervalMs) or 0))

	jobs[#jobs + 1] = {
		name = name,
		interval = interval,
		-- Staggered so that ten jobs sharing an interval spread across it rather
		-- than colliding on one resume forever.
		nextAt = OPX.Now() + (interval > 0 and (#jobs * 17) % interval or 0),
		step = step,
		failures = 0,
	}
	return #jobs
end

--- Stops a registered job. Safe for a handle that is already cancelled.
-- @author dop42
-- @param handle integer
function OPX.Scheduler.Cancel(handle)
	local job = jobs[handle]
	if job then job.step = nil end
end

--- Runs one job, suspending it after MAX_FAILURES consecutive raises.
local function runJob(job, atMs)
	local ok, failure = pcall(job.step)
	if ok then
		job.failures = 0
	else
		job.failures = job.failures + 1
		if job.failures == 1 or job.failures == MAX_FAILURES then
			Open77.log.error(('[scheduler] %s: %s'):format(job.name, tostring(failure)))
		end
		if job.failures >= MAX_FAILURES then
			-- Suspended rather than left to raise every tick: a job that is
			-- broken now is broken next tick, and the log is not the place to
			-- discover that thirty times a second.
			Open77.log.error(('[scheduler] %s suspended after %d failures')
				:format(job.name, job.failures))
			job.step = nil
			return
		end
	end
	job.nextAt = atMs + job.interval
end

--- One pass: runs up to MAX_PER_TICK due jobs, resuming where the last pass left
--- off so a long list cannot starve its tail.
-- @return boolean whether anything was due
local function tick()
	local atMs = OPX.Now()
	local count = #jobs
	if count == 0 then return false end

	local ran, examined = 0, 0
	while examined < count and ran < MAX_PER_TICK do
		cursor = cursor % count + 1
		examined = examined + 1
		local job = jobs[cursor]
		if job and job.step and atMs >= job.nextAt then
			runJob(job, atMs)
			ran = ran + 1
		end
	end
	return ran > 0
end

--- Starts the loop. Called once by the client boot; further calls are ignored.
-- @author dop42
function OPX.Scheduler.Start()
	if running then return end
	running = true

	CreateThread(function()
		while running do
			-- The pcall is around the pass, not only around each job: OPX.Now
			-- is a host read too, and a raise from it would end the loop for the
			-- whole session.
			local ok, busy = pcall(tick)
			if not ok then
				Open77.log.error(('[scheduler] pass failed: %s'):format(tostring(busy)))
				busy = false
			end
			Wait(busy and 0 or IDLE_MS)
		end
	end)
end

--- Stops the loop at the next tick.
-- @author dop42
function OPX.Scheduler.Stop()
	running = false
end

--- One line per job: name, interval and state. For the diagnostic command.
-- @author dop42
-- @return string[]
function OPX.Scheduler.Report()
	local lines = {}
	for index = 1, #jobs do
		local job = jobs[index]
		lines[#lines + 1] = ('%-28s %6dms %s')
			:format(job.name, job.interval, job.step and 'running' or 'stopped')
	end
	return lines
end
