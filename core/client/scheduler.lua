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
local byHandle = {}
local cursor = 0
local nextHandle = 0
local dead = 0
local registered = 0
local running = false

local MAX_PER_TICK = 4
local MAX_FAILURES = 3
local IDLE_MS = 100

--- Registers repeating work. Returns a handle for `Cancel`.
---
--- THE HANDLE IS NOT A POSITION. A cancelled job is dropped from the list at the
--- next pass -- a menu that registers its key poll on open and cancels it on
--- close would otherwise leave one dead entry per open, for the session -- and
--- an index would name a different job after the first drop.
-- @author dop42
-- @param name string owner and purpose, for the log line if it fails
-- @param intervalMs integer milliseconds; NOT a function, unlike the server
-- @param step function
-- @return integer handle
function OPX.Scheduler.Every(name, intervalMs, step)
	if type(name) ~= 'string' or type(step) ~= 'function' then
		error('Every(name, intervalMs, step)', 2)
	end
	-- A BAD INTERVAL IS REFUSED, not rounded down to zero. This read used to be
	-- `math.max(0, math.floor(tonumber(intervalMs) or 0))`, which turned every
	-- mistake -- a nil, a string, a function -- into an interval of 0, and an
	-- interval of 0 on this scheduler means the job runs on every single pass.
	-- On a client with a per-resume instruction budget that is the worst thing a
	-- typo can do: the resource does not crash, it quietly eats the budget until
	-- something unrelated is cut off mid-coroutine with no log line.
	--
	-- A FUNCTION IS THE CASE WORTH NAMING. The SERVER'S `Every` takes
	-- `integer|function` and re-reads a function every pass, which is how a job
	-- follows a live tunable; the two functions share a name and a signature on
	-- paper. This one cannot do it and should not pretend to -- `OPX.Tune` is
	-- server-only, so there is no live number on the client to follow -- so a
	-- function is refused here rather than silently becoming frame-rate.
	--
	-- Zero itself stays legal: a caller that means "every pass" may say so.
	local interval = tonumber(intervalMs)
	if type(intervalMs) == 'function' or interval == nil or interval < 0 then
		error(('Every(%q, intervalMs, step): intervalMs must be a number of '
			.. 'milliseconds, got %s'):format(name, type(intervalMs)), 2)
	end
	interval = math.floor(interval)

	nextHandle = nextHandle + 1
	registered = registered + 1

	local job = {
		handle = nextHandle,
		name = name,
		interval = interval,
		-- Staggered so that ten jobs sharing an interval spread across it rather
		-- than colliding on one resume forever. Off the count of everything ever
		-- registered, not of what is live: two jobs landing on the same offset
		-- because one in between was cancelled is the collision this avoids.
		nextAt = OPX.Now() + (interval > 0 and (registered * 17) % interval or 0),
		step = step,
		failures = 0,
	}

	jobs[#jobs + 1] = job
	byHandle[nextHandle] = job
	return nextHandle
end

--- Stops a registered job. Safe for a handle that is already cancelled.
-- @author dop42
-- @param handle integer
function OPX.Scheduler.Cancel(handle)
	local job = byHandle[handle]
	if job == nil or job.step == nil then return end
	job.step = nil
	byHandle[handle] = nil
	dead = dead + 1
end

--- Drops cancelled jobs. Run at the top of a pass rather than inside `Cancel`,
--- which may itself be called from a job this loop is walking.
local function compact()
	if dead == 0 then return end
	local live = {}
	for index = 1, #jobs do
		local job = jobs[index]
		if job.step then live[#live + 1] = job end
	end
	jobs = live
	cursor = 0
	dead = 0
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
			OPX.Scheduler.Cancel(job.handle)
			return
		end
	end
	job.nextAt = atMs + job.interval
end

--- One pass: runs up to MAX_PER_TICK due jobs, resuming where the last pass left
--- off so a long list cannot starve its tail.
-- @return integer milliseconds to wait before the next pass is worth making
local function tick()
	compact()

	local atMs = OPX.Now()
	local count = #jobs
	if count == 0 then return IDLE_MS end

	local ran, examined = 0, 0
	while examined < count and ran < MAX_PER_TICK do
		cursor = cursor % count + 1
		examined = examined + 1
		local job = jobs[cursor]
		if job.step and atMs >= job.nextAt then
			runJob(job, atMs)
			ran = ran + 1
		end
	end

	-- WHAT THE LOOP SLEEPS IS THE NEAREST DEADLINE, not a constant. A flat
	-- hundred is longer than most intervals registered here: the vitals stream
	-- asks for 33ms and was served every ~116ms whenever the pass before it
	-- happened to find nothing else due, so the health bar ran at a third of the
	-- rate its own config names. The cap stays as the idle floor, and a pass that
	-- hit MAX_PER_TICK with more still due comes straight back.
	if ran >= MAX_PER_TICK then return 0 end

	local soonest
	for index = 1, count do
		local job = jobs[index]
		if job.step and (soonest == nil or job.nextAt < soonest) then soonest = job.nextAt end
	end
	if soonest == nil then return IDLE_MS end

	local waitMs = soonest - atMs
	if waitMs < 0 then waitMs = 0 end
	if waitMs > IDLE_MS then waitMs = IDLE_MS end
	return waitMs
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
			local ok, waitMs = pcall(tick)
			if not ok then
				Open77.log.error(('[scheduler] pass failed: %s'):format(tostring(waitMs)))
				waitMs = IDLE_MS
			end
			Wait(waitMs)
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
