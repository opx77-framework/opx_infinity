--- Brings the client half up: modules, then the one loop.
-- @author dop42

local RESOURCE = GetCurrentResourceName()

AddEventHandler(OPX.Host.CLIENT_RESOURCE_START, function(name)
	if name ~= RESOURCE then return end

	CreateThread(function()
		local started, fatal = OPX.Modules.Run()
		if not started then
			Open77.log.error(('client module failed: %s'):format(tostring(fatal)))
		end

		-- The overlay is the always-on layer, so it comes up whether or not
		-- anything has drawn on it yet. The interactive layer stays lazy: a
		-- player who never opens anything should not pay for a second CEF page.
		OPX.UI.Overlay()
		OPX.Toast.Attach()

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
end)
