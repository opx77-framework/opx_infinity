--- Drives every declared module through resolve, init, api, start and stop.
-- @author dop42
--
--   declare -> resolve -> init -> api -> start -> running -> stop
--
-- `init` builds state and may not yield or reach another module. `api` publishes
-- contracts, and nothing may read one before this phase ends. `start` runs on a
-- coroutine and may hit the database. `stop` runs in reverse dependency order.

local PHASES = { 'Init', 'Api', 'Start' }

local resolved
local ran = false

--- Reports a module out of the running set, keeping the first reason.
local function halt(module, state, reason)
	if module.State == 'failed' then return end
	module.State = state
	module.Reason = reason
end

--- Depth-first walk producing dependency order, with the cycle reported by name.
-- A cycle found at boot is an error someone can read; the same cycle found at
-- runtime is a module reading a half-built neighbour.
local function visit(module, seen, out, trail)
	if seen[module.Id] == 'done' then return end
	if seen[module.Id] == 'open' then
		local cycle = {}
		for index = 1, #trail do cycle[index] = trail[index] end
		cycle[#cycle + 1] = module.Id
		error(('module dependency cycle: %s'):format(table.concat(cycle, ' -> ')), 0)
	end

	seen[module.Id] = 'open'
	trail[#trail + 1] = module.Id

	for _, list in ipairs({ module.Requires, module.Optional }) do
		for _, id in ipairs(list) do
			local other = OPX.Modules.Record(id)
			if other then visit(other, seen, out, trail) end
		end
	end

	trail[#trail] = nil
	seen[module.Id] = 'done'
	out[#out + 1] = module
end

--- Orders every declared module and marks the ones that cannot run.
-- @author dop42
-- @return table[] the modules to run, in dependency order
function OPX.Modules.Resolve()
	if resolved then return resolved end

	local out, seen, trail = {}, {}, {}
	for _, module in ipairs(OPX.Modules.All()) do
		visit(module, seen, out, trail)
	end

	-- A module is only runnable once every module it requires is runnable, and
	-- that answer has to settle: dropping one module can drop its dependants.
	local settling = true
	while settling do
		settling = false
		for _, module in ipairs(out) do
			if module.State == 'declared' then
				for _, id in ipairs(module.Requires) do
					local other = OPX.Modules.Record(id)
					if other == nil then
						halt(module, 'unavailable', ('requires %q, which is not installed'):format(id))
						settling = true
						break
					elseif other.State ~= 'declared' then
						halt(module, 'unavailable', ('requires %q, which is %s'):format(id, other.State))
						settling = true
						break
					end
				end
			end
		end
	end

	resolved = out
	return out
end

--- Runs one phase over the runnable modules, in order.
--
-- `Start` YIELDS BETWEEN MODULES, and that is not politeness to the frame rate.
--
-- The host bounds a task by a PER-FRAME instruction budget and stops it dead when
-- it is passed; a `Wait(0)` moves to the next frame and the budget starts again.
-- Every module's `Start` used to run in one frame, so the whole client boot spent
-- ONE budget between them: each module made the next one likelier to trip, and the
-- one that actually tripped depended on how much the frame had already spent.
--
-- That is exactly what was seen. The inventory reported, intermittently:
--
--   client module: inventory failed
--     start failed: modules/target/shared/model.lua:334: script execution budget exceeded
--
-- It is not the inventory's fault and it was never reliably the inventory: it
-- registers its world rows in `Start`, late in dependency order, so it was simply
-- often the module holding the parcel. And because `Start` raising marks a module
-- `failed`, the rest of its `Start` never ran -- which is why the symptom was "no
-- inventory AND no keybinds", with no error anywhere a player could see.
--
-- `Init` is NOT given the same treatment: it is documented never to yield, it
-- builds state rather than touching the world, and a yield there would let an
-- event reach a module whose state is half built.
-- @return string|nil the id of a fatal module that failed
local function runPhase(phase)
	local fatal
	-- Guarded on the native rather than on the side: a build without `Wait` must
	-- still boot, just in one frame, as it did before.
	local yielding = phase == 'Start' and type(Wait) == 'function'
	for _, module in ipairs(OPX.Modules.Resolve()) do
		if module.State == 'declared' then
			-- Phases live on the namespace; everything else the loop reads is on
			-- the record. The two were one table once, and a module field named
			-- after a lifecycle field overwrote it, silently.
			local step = module.Module[phase]
			if type(step) == 'function' then
				-- `Provide` reads this to name the owner of a contract; the
				-- phases never interleave, so a single field is enough.
				OPX.Api.Owner = module.Id
				local ok, failure = pcall(step)
				OPX.Api.Owner = nil
				if not ok then
					halt(module, 'failed', ('%s failed: %s'):format(phase:lower(), tostring(failure)))
					Open77.log.error(('[%s] %s'):format(module.Id, module.Reason))
					if module.Fatal then fatal = module.Id end
				end
				-- AFTER the module, not before: a fresh budget is worth nothing to
				-- the module that has already spent it, and this way the last one
				-- in the list is the only frame that pays for two.
				--
				-- UNDER pcall, because the real condition is not "does `Wait`
				-- exist" but "may this stack yield at all". `Run` is documented
				-- to be called from a thread and both boot files do -- but a
				-- caller that does not (the test host calls it straight) would
				-- otherwise raise `attempt to yield from outside a coroutine` and
				-- take the whole boot down for the sake of a budget reset. A yield
				-- that cannot happen just means the frame is shared, which is what
				-- every build did until now.
				if yielding then pcall(Wait, 0) end
			end
		end
	end
	return fatal
end

--- Runs init, api and start. Call from a thread: `Start` may yield.
--- `between` runs after every contract is published and before any module starts,
--- which is where the server applies the schema: modules contribute their tables
--- during `Init`, and `Start` is the first phase allowed to read the database.
-- @author dop42
-- @param between? function
-- @return boolean ok
-- @return string|nil the id of the fatal module that failed
function OPX.Modules.Run(between)
	-- Idempotent. The host can raise a resource-start event more than once, and
	-- running the phases twice publishes every contract twice -- which `Provide`
	-- correctly refuses, failing every module that owns one.
	if ran then return true end
	ran = true

	for _, phase in ipairs(PHASES) do
		if phase == 'Start' and between then
			local ok, failure = pcall(between)
			if not ok then return false, tostring(failure) end
		end
		local fatal = runPhase(phase)
		if fatal then return false, fatal end
	end

	for _, module in ipairs(OPX.Modules.Resolve()) do
		if module.State == 'declared' then module.State = 'started' end
	end

	-- A fatal module that never failed but never ran is still fatal.
	for _, module in ipairs(OPX.Modules.Resolve()) do
		if module.Fatal and module.State ~= 'started' then
			return false, module.Id
		end
	end

	return true
end

--- Stops every started module, newest dependency first.
-- @author dop42
function OPX.Modules.Stop()
	local running = OPX.Modules.Resolve()
	for index = #running, 1, -1 do
		local module = running[index]
		if module.State == 'started' and type(module.Module.Stop) == 'function' then
			local ok, failure = pcall(module.Module.Stop)
			if not ok then
				Open77.log.error(('[%s] stop failed: %s'):format(module.Id, tostring(failure)))
			end
			module.State = 'stopped'
		end
	end
end

--- One line per module: id, state and reason. What the diagnostic command prints.
-- @author dop42
-- @return string[]
function OPX.Modules.Report()
	local lines = {}
	for _, module in ipairs(OPX.Modules.Resolve()) do
		lines[#lines + 1] = ('%-14s %-12s %s')
			:format(module.Id, module.State, module.Reason or '')
	end
	return lines
end
