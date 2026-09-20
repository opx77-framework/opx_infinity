--- Brings the client half up: modules, then the one loop.
-- @author dop42

local RESOURCE = GetCurrentResourceName()

AddEventHandler(OPX.Host.CLIENT_RESOURCE_START, function(name)
	if name ~= RESOURCE then return end

	CreateThread(function()
		-- BEFORE the modules, not after. A module's `Start` may well draw on the
		-- surface, and anything sent before it exists is dropped for want of one.
		OPX.UI.Surface()
		OPX.Toast.Attach()

		local started, fatal = OPX.Modules.Run()
		if not started then
			Open77.log.error(('client module failed: %s'):format(tostring(fatal)))
		end

		-- After the modules, so a module registering work in `Start` is picked up
		-- on the first pass rather than a tick later.
		OPX.Scheduler.Start()

		for _, line in ipairs(OPX.Modules.Report()) do
			Open77.log.info('[module] ' .. line)
		end
	end)
end)

AddEventHandler(OPX.Host.CLIENT_RESOURCE_STOP, function(name)
	if name ~= RESOURCE then return end
	OPX.Scheduler.Stop()
	OPX.Modules.Stop()
	-- AFTER the modules, and it was missing entirely. `OPX.UI.Teardown` says in
	-- its own docstring that this is the stop path, and nothing called it: the
	-- CEF page outlived the resource that built it. After `Modules.Stop` because
	-- a module stopping may still want to tell its page it is going.
	OPX.UI.Teardown()
end)
