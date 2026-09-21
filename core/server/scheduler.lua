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

-- What a job runs at when its own interval cannot be read at all and it has
-- never yet produced a usable one. It is deliberately SLOW. `MIN_INTERVAL_MS`
-- was the old fallback and it is the wrong direction by three orders of
-- magnitude: a save job configured at 30s that starts raising became a 50ms loop
-- for the life of the resource. Running late costs a delayed pass; running 600x
-- too fast costs the server.
local FALLBACK_INTERVAL_MS = 60000

--- This pass's interval. A function is re-read every pass, which is what a job
--- whose cadence is a live tunable needs: a number captured at registration is
--- frozen for the life of the resource.
---
--- A RAISE AND A LEGITIMATE NUMBER ARE NOW DISTINGUISHED, and they were not:
--- `value = ok and answered or nil` collapsed a raising closure, a closure
--- answering nil and a closure answering 0 into the same `nil`, which then
--- floored to `MIN_INTERVAL_MS`. Nothing logged it -- step failures are reported
--- once per run, interval failures never were -- and `Report` printed a confident
--- `50ms` with no hint it was a fallback.
local function intervalOf(job)
	local value = job.interval

	if type(value) == 'function' then
		local ok, answered = pcall(value)
		if not ok then
			-- Once per run of failures, the same rule the step below follows: an
			-- interval closure that raises every pass would otherwise write a line
			-- per pass, at the very rate this fallback exists to avoid.
			if not job.intervalFailing then
				job.intervalFailing = true
				Open77.log.error(('[scheduler] %s: its interval raised (%s); running at %dms')
					:format(job.name, tostring(answered), job.lastIntervalMs or FALLBACK_INTERVAL_MS))
			end
			return job.lastIntervalMs or FALLBACK_INTERVAL_MS
		end
		value = answered
	end

	-- NaN and both infinities go the same way as a nil: `math.floor(math.huge)` is
	-- an infinite `Wait`, which is a job that never runs again and says nothing.
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then
		-- A cadence nobody can read is not a cadence of zero. Same fallback and
		-- same one-line-per-run rule as the raise above.
		if not job.intervalFailing then
			job.intervalFailing = true
			Open77.log.error(('[scheduler] %s: its interval is not a number (%s); running at %dms')
				:format(job.name, type(value), job.lastIntervalMs or FALLBACK_INTERVAL_MS))
		end
		return job.lastIntervalMs or FALLBACK_INTERVAL_MS
	end

	job.intervalFailing = false
	number = math.floor(number)
	if number < MIN_INTERVAL_MS then number = MIN_INTERVAL_MS end
	job.lastIntervalMs = number
	return number
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
	-- DROPPED FROM `order` TOO, and it was not. `order` is the registration
	-- sequence `Report` walks; cancelling cleared `jobs[handle]` and left the
	-- handle in it forever, so a caller that registers and cancels on a cycle --
	-- a sweep that follows a session, say -- grew a list nothing ever shortened
	-- for the life of the resource. `Report` reads correctly either way, which
	-- is why nothing ever noticed.
	for index = 1, #order do
		if order[index] == handle then
			table.remove(order, index)
			break
		end
	end
end

--- Stops every job. The resource is going down; the tasks go with it either way,
--- but a job that wakes between now and then must not run against torn-down state.
-- @author dop42
function OPX.Scheduler.Stop()
	for handle, job in pairs(jobs) do
		job.live = false
		jobs[handle] = nil
	end
	-- And the sequence with them: leaving it behind would have `Report` walk a
	-- list of handles to nothing after a stop.
	order = {}
end

--- One line per live job: name and interval. For the diagnostic command.
-- @author dop42
-- @return string[]
function OPX.Scheduler.Report()
	local lines = {}
	for index = 1, #order do
		local job = jobs[order[index]]
		if job ~= nil then
			-- THE INTERVAL IS NAMED AS A FALLBACK WHEN IT IS ONE. This printed a
			-- confident `50ms` for a job whose interval closure was raising, which
			-- is the one reading an operator would never question.
			-- READ, NOT RE-ASKED. `intervalOf` CALLS the caller's interval
			-- closure and writes `job.lastIntervalMs` and `job.intervalFailing`
			-- back onto the job, so a diagnostic command ran arbitrary module
			-- code and, by clearing `intervalFailing`, re-armed the once-per-run
			-- log line the job had just emitted. Printing a job's state must not
			-- change it. The last value the scheduler itself resolved is the
			-- honest answer, and the fallback below is the one this line already
			-- documents.
			local interval = job.lastIntervalMs or intervalOf(job)
			local state = job.failing and 'failing' or 'running'
			if job.intervalFailing then state = state .. ' (interval unreadable)' end
			lines[#lines + 1] = ('%-28s %6dms %s'):format(job.name, interval, state)
		end
	end
	return lines
end
