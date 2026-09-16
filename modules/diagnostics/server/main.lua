--- `/opx.modules` and `/opx.version`, server side.
-- @author dop42

local M = OPX.Modules.Get('diagnostics')

local LINES = OPX.Event(OPX.Channel.NET, 'diagnostics', 'lines')

--- Answers the player who typed the command, or the console for source 0.
local function answer(source, lines)
	if source == nil or source == 0 then
		for index = 1, #lines do print(lines[index]) end
		return
	end
	TriggerClientEvent(LINES, source, lines)
end

local function moduleLines()
	local lines = { ('%-14s %-12s %s'):format('module', 'state', 'reason') }
	for _, line in ipairs(OPX.Modules.Report()) do lines[#lines + 1] = line end
	return lines
end

local function versionLines()
	local contracts = {}
	for name, version in pairs(OPX.Api.Versions()) do
		contracts[#contracts + 1] = ('contract %-14s v%d'):format(name, version)
	end
	-- pairs has no order, and two runs of a diagnostic should compare line by line.
	table.sort(contracts)

	local lines = { ('opx_infinity %s'):format(OPX.VERSION) }
	if OPX.BootError then lines[#lines + 1] = ('degraded: %s'):format(OPX.BootError) end
	for index = 1, #contracts do lines[#lines + 1] = contracts[index] end
	return lines
end

function M.Start()
	-- Restricted: the module list names what is installed and what failed, which
	-- is a map of the server for anyone deciding where to probe.
	RegisterCommand('opx.modules', function(source)
		answer(source, moduleLines())
	end, true)

	RegisterCommand('opx.version', function(source)
		answer(source, versionLines())
	end, true)
end
