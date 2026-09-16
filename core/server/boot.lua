--- Brings the server half up: database, schema, modules.
-- @author dop42
--
-- Runs on its own thread. Creating tables waits on round trips to the database,
-- and the file's main chunk has to yield straight back to the scheduler.

OPX.Schema = OPX.Schema or {}

local statements = {}

--- Adds `CREATE TABLE IF NOT EXISTS` statements, in foreign-key order. Modules
--- call this from `Init`; the schema is applied once, before any module starts.
-- @author dop42
-- @param list string[]
function OPX.Schema.Add(list)
	for index = 1, #list do statements[#statements + 1] = list[index] end
end

--- False until boot has settled the schema question, either way.
OPX.Booted = false

--- Why no character can be loaded, or nil. Set once and never cleared: a database
--- that comes back after boot is only picked up by restarting the resource.
OPX.BootError = nil

--- Applies every contributed statement, stopping at the first failure.
--- `OPX.Storage.ApplySchema` answers a Result; this is where it becomes the
--- plain pair the boot sequence reads.
-- @author dop42
-- @return boolean ok
-- @return string|nil the table that failed
function OPX.Schema.Apply()
	if #statements == 0 then return true end
	local applied = OPX.Storage.ApplySchema(statements)
	if applied.ok then return true end
	return false, applied.detail or applied.error
end

--- Warns for each running resource that also places players. Asking the host is
--- the only way to know: server resources cannot call each other, so there is
--- nobody to ask directly. A `starting` state counts -- a resource coming up will
--- be placing players in a moment.
local function warnAboutPlacementConflicts()
	local names = OPX.Config.SERVER.CONFLICTING_PLACERS or {}
	local mine = GetCurrentResourceName()
	for index = 1, #names do
		local name = names[index]
		local state = GetResourceState(name)
		if name ~= mine and (state == 'running' or state == 'starting') then
			Open77.log.warn(('[boot] %s is running and also places players; see ' ..
				'CONFLICTING_PLACERS in config/server.lua'):format(name))
		end
	end
end

CreateThread(function()
	-- Under pcall: a diagnostic must never be what stops the runtime coming up.
	local warned, why = pcall(warnAboutPlacementConflicts)
	if not warned then
		Open77.log.error('[boot] the placement-conflict check raised: ' .. tostring(why))
	end

	if not OPX.Storage.Ready() then
		OPX.BootError = 'no database'
		Open77.log.error('no database: nobody will be able to connect until this is fixed.')
		Open77.log.error('  check the credentials in the host configuration, then restart.')
	end

	local started, fatal = OPX.Modules.Run(function()
		-- Between api and start: modules contributed their tables and their
		-- tunables during init, and start is the first phase allowed to read
		-- either. The panel is declared once for the whole resource -- a second
		-- declaration would replace the first, losing every other module's block.
		OPX.Tune.Publish()

		if OPX.BootError then return end
		local ok, failed = OPX.Schema.Apply()
		if not ok then OPX.BootError = ('schema failed: %s'):format(tostring(failed)) end
	end)

	if not started then
		OPX.BootError = OPX.BootError or ('module failed: %s'):format(tostring(fatal))
		Open77.log.error(OPX.BootError)
	end

	OPX.Booted = true

	for _, line in ipairs(OPX.Modules.Report()) do
		Open77.log.info('[module] ' .. line)
	end
	Open77.log.info(('opx-infinity %s up%s')
		:format(OPX.VERSION, OPX.BootError and (' -- degraded: ' .. OPX.BootError) or ''))
end)

AddEventHandler(OPX.Host.RESOURCE_STOP, function(name)
	if name ~= GetCurrentResourceName() then return end
	OPX.Modules.Stop()
end)
