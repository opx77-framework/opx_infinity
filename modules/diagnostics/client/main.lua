--- Prints what the server answered, and `/opx.client` for the client's own state.
-- @author dop42

local M = OPX.Modules.Get('diagnostics')

function M.Start()
	RegisterNetEvent(OPX.Event(OPX.Channel.NET, 'diagnostics', 'lines'), function(lines)
		if type(lines) ~= 'table' then return end
		for index = 1, #lines do Open77.log.info(tostring(lines[index])) end
	end)

	RegisterCommand('opx.client', function()
		Open77.log.info(('opx_infinity %s, client'):format(OPX.VERSION))
		for _, line in ipairs(OPX.Modules.Report()) do Open77.log.info('[module] ' .. line) end
		for _, line in ipairs(OPX.Scheduler.Report()) do Open77.log.info('[job] ' .. line) end
	end, false)
end
