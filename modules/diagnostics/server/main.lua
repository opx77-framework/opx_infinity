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

-- Page reports one player may put in the journal per window, and the window.
-- A throwing render loop is capped on the page and again on the client, and this
-- is the third floor: the two above it live on the machine being diagnosed.
local REPORTS_PER_WINDOW = 20
local WINDOW_MS = 60000
local windows = {}

--- Writes one page failure to the server log, attributed to the player it came
--- from and cleaned of anything that could forge a line.
local function onPageReport(text)
	local player = tonumber(source) or 0
	if player <= 0 or type(text) ~= 'string' then return end

	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= WINDOW_MS then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= REPORTS_PER_WINDOW then return end
	window.count = window.count + 1

	-- Through `Clean` before a format string: the text came off the wire and a
	-- newline in it would forge a whole journal line.
	Open77.log.warn(('[page] player %d: %s'):format(player, OPX.Text.Clean(text, 400, '...') or ''))
end

function M.Start()
	RegisterNetEvent(M.PAGE, onPageReport)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId) or 0
		if player > 0 then windows[player] = nil end
	end)

	-- Restricted: the module list names what is installed and what failed, which
	-- is a map of the server for anyone deciding where to probe.
	RegisterCommand('opx.modules', function(source)
		answer(source, moduleLines())
	end, true)

	RegisterCommand('opx.version', function(source)
		answer(source, versionLines())
	end, true)
end
