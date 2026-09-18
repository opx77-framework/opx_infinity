--- Server half: the wire, the two commands, the sweep and the contract.
-- @author dop42
--
-- Thin on purpose. Everything a claim has to prove lives in `server/runs.lua`
-- and everything a character carries between runs lives in `server/ledger.lua`;
-- this file is the doorway and the lifecycle.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog
local Ledger = M.Ledger
local Runs = M.Runs

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- Whether the sweep should keep running.
local sweeping = false

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Sends a refusal to the player who earned it, as one replaced toast. `wait` is
-- the seconds left on a cooldown, which the sentence carries.
local function refuse(player, code, wait)
	local key = Catalog.REFUSAL[code] or 'gigs.refuse.generic'
	TriggerClientEvent(M.Event.ANSWER, player, { error = code, key = key, wait = wait })
end

-- Whether a player holds a loaded character. A gig pays a character and counts
-- against one; a connection without one has nothing to take a run with.
local function hasCharacter(player)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return false end
	local read, loaded = pcall(api.GetPlayer, player)
	return read and type(loaded) == 'table' and type(loaded.PlayerData) == 'table'
end

-- Prints every gig, what it pays and where the caller stands with it.
local function listing(source)
	local lines = {}
	for _, line in ipairs(Catalog.Problems()) do lines[#lines + 1] = 'config: ' .. line end

	local gigs = Catalog.List()
	if #gigs == 0 then
		lines[#lines + 1] = locale('gigs.command.none')
		OPX.CommandResult(source, true, table.concat(lines, '\n'))
		return
	end

	local record = source > 0 and Ledger.Read(source) or nil
	for index = 1, #gigs do
		local gig = gigs[index]
		local taken = record and (record.runs[gig.id] or 0) or 0
		local cap = gig.maxRunsPerDay > 0 and tostring(gig.maxRunsPerDay) or '-'
		lines[#lines + 1] = ('%-10s %-9s %-34s %d legs  %d-%d + %d-%d  today %d/%s  rep>=%d')
			:format(gig.id, gig.kind, gig.label, gig.steps,
				gig.pay.perStep.min, gig.pay.perStep.max,
				gig.pay.bonus.min, gig.pay.bonus.max,
				taken, cap, gig.minReputation)
	end

	if record ~= nil then
		lines[#lines + 1] = locale('gigs.command.reputation', { value = record.rep })
	end
	local state = source > 0 and Runs.State(source) or nil
	if state ~= nil then
		lines[#lines + 1] = locale('gigs.command.working',
			{ gig = state.gig, index = state.index, total = state.total, earned = state.earned })
	end

	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

-- Registers the two commands a configuration asks for. Neither is restricted:
-- both act on the caller alone and read nothing an operator owns.
local function registerCommands()
	local names = M.Settings.COMMANDS
	if type(names) ~= 'table' then return end

	local list = Catalog.Text(names.LIST, 64)
	if list ~= nil then
		OPX.Command.Register(list, { restricted = false, help = 'gigs.help.list' },
			function(source)
				listing(tonumber(source) or 0)
			end)
	end

	local cancel = Catalog.Text(names.CANCEL, 64)
	if cancel ~= nil then
		OPX.Command.Register(cancel, { restricted = false, help = 'gigs.help.cancel' },
			function(source)
				local player = tonumber(source) or 0
				if player <= 0 then
					OPX.CommandResult(source, false, locale('gigs.refuse.notWorking'))
					return
				end
				local answer = Runs.Quit(player, 'abandoned')
				if not answer.ok then refuse(player, answer.error) end
			end)
	end
end

--- Answers what one player is doing, for another module that wants to know.
-- @author dop42
-- @param player Source
-- @return Result
local function state(player)
	local held = Runs.State(player)
	if held == nil then return OPX.Result.Ok({ working = false }) end
	held.working = true
	return OPX.Result.Ok(held)
end

--- Answers a player's reputation and the runs they have taken today.
-- @author dop42
-- @param player Source
-- @return Result
local function record(player)
	if not hasCharacter(player) then return OPX.Result.Err('no_character') end
	local held = Ledger.Read(player)
	return OPX.Result.Ok({ reputation = held.rep, day = held.day, runs = held.runs, done = held.done })
end

--- Ends the run a player holds, for a module that has a reason to -- a jail, an
--- arrest, a staff command.
-- @author dop42
-- @param player Source
-- @param reason string|nil
-- @return Result
local function cancel(player, reason)
	local answer = Runs.Quit(player, Catalog.Text(reason, 40) or 'cancelled')
	if not answer.ok then return OPX.Result.Err(answer.error or 'refused') end
	return OPX.Result.Ok({ cancelled = true })
end

--- Reads the catalogue and clears the run table.
-- @author dop42
function M.Init()
	Catalog.Read()
	Runs.Reset()
end

--- Publishes the server half of the gigs contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('gigs', 1, {
		State = state,
		Record = record,
		Cancel = cancel,
		List = Catalog.List,
	})
end

--- Wires the three wire events, the commands, the departures and the sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Catalog.Problems()) do Open77.log.warn('[gigs] config: ' .. line) end

	-- Registered whether or not anything else came up: an operator has to be able
	-- to read back what the configuration says.
	registerCommands()

	local gigs = Catalog.List()
	if #gigs == 0 then
		Open77.log.warn('[gigs] no gig is enabled; the board is empty and no run can be taken')
		return
	end

	if type(Open77.players) ~= 'table' or type(Open77.players.position) ~= 'function' then
		Open77.log.error('[gigs] this host answers no player position: a claim cannot be checked, ' ..
			'so no run is taken')
		return
	end

	Runs.Open()

	RegisterNetEvent(M.Event.TAKE, function(gigId)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not hasCharacter(player) then return refuse(player, 'no_character') end

		local answer = Runs.Take(player, gigId)
		if answer.ok then return end
		refuse(player, answer.error, answer.wait)
		Open77.log.debug(('[gigs] player %d was refused %s: %s')
			:format(player, safe(gigId), tostring(answer.error)))
	end)

	RegisterNetEvent(M.Event.WORK, function(runId, index)
		local player = tonumber(source) or 0
		if player <= 0 then return end

		local answer = Runs.Work(player, runId, index)
		if answer.ok then return end
		refuse(player, answer.error)
	end)

	RegisterNetEvent(M.Event.QUIT, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		local answer = Runs.Quit(player, 'abandoned')
		if not answer.ok then refuse(player, answer.error) end
	end)

	-- The departure of an ADMITTED player. A connection refused at the gate
	-- raises a different event this module has no reason to hear.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId) or 0
		if player > 0 then Runs.Forget(player) end
	end)

	sweeping = true
	CreateThread(function()
		local interval = Catalog.Integer(M.Settings.SWEEP_MS, 1000, 600000) or 30000
		while sweeping do
			Wait(interval)
			-- Guarded per pass: a raise from a host call in a bare thread would end
			-- the sweep for the life of the process.
			local swept, failure = pcall(Runs.Sweep)
			if not swept then
				Open77.log.error('[gigs] the run sweep failed: ' .. tostring(failure))
			end
		end
	end)

	Open77.log.info(('[gigs] ready: %d gig(s) on the board'):format(#gigs))
end

--- Stops the sweep and ends every run in flight.
-- @author dop42
function M.Stop()
	sweeping = false
	Runs.Close()
end
