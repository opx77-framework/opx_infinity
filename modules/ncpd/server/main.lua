--- The server half: the book is journalled, crimes are charged, the city answers.
-- @author XEROX710
--
-- THE ONE PATH FROM A CRIME TO A WANTED PLAYER. `charge` is the only function
-- that writes the ledger, and `publish` the only one that tells a client and
-- stands a response up. Everything else -- the commands, the contract other
-- resources call, the decay pass -- goes through those two, so there is exactly
-- one place where a stage changes and exactly one place where the street reacts
-- to it. A second door would be two answers to "why are there police here".
--
-- THE LEDGER IS THE AUTHORITY AND THE ENGINE IS THE ACTOR. Nothing here writes a
-- wanted level fact or draws a star: the client is told the stage and asks the
-- engine's own scripted `PreventionSystem` for it, which is what makes the wanted
-- bar, the siren audio, the police radio and the stage's own effects real. A
-- client that cannot do that says so in its log and the ledger still holds the
-- score -- the city knows, the client cannot show it.
--
-- THE BOOK IS VALIDATED ELSEWHERE AND JOURNALLED HERE. `shared/law.lua` names
-- every value the config could not use; those warnings are worthless unless
-- somebody says them out loud, so `M.Start` prints them and then the book it did
-- accept, as one line an operator can read after editing a config.

local M = OPX.Modules.Get('ncpd')

local Law = M.Law
local Ledger = M.Ledger
local Response = M.Response

local character, hud

--- The ladder as one phrase: `ncpd 1-4, maxtac 5`.
-- @return string
local function ladder()
	local parts = {}
	local first = nil
	local division = nil
	for stage = 1, Law.StageCount do
		local row = Law.Stages[stage]
		local current = row ~= nil and row.Division or '?'
		if division == nil then
			first = stage
			division = current
		elseif current ~= division then
			local last = stage - 1
			parts[#parts + 1] = first == last and (division .. ' ' .. first)
				or (division .. ' ' .. first .. '-' .. last)
			first = stage
			division = current
		end
	end
	if division ~= nil then
		parts[#parts + 1] = first == Law.StageCount and (division .. ' ' .. first)
			or (division .. ' ' .. first .. '-' .. Law.StageCount)
	end
	return table.concat(parts, ', ')
end

--- The label a division is shown by, from the config, falling back to its id.
-- @param division string|nil
-- @return string|nil
local function labelOf(division)
	local divisions = M.Settings.DIVISIONS
	local row = type(divisions) == 'table' and divisions[division] or nil
	if type(row) == 'table' and type(row.label) == 'string' then return row.label end
	return division
end

--- The character a connection has loaded, as the character contract sees it.
-- The contract is optional: without it nobody can be charged, which is a refusal
-- with a line rather than a module that takes the resource down.
-- @param playerId number
-- @return table|nil `{ citizenId, source, job }`
local function characterOf(playerId)
	if character == nil then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' then return nil end
	local citizenId = data.citizenId
	if type(citizenId) ~= 'string' or citizenId == '' then return nil end
	return data
end

--- The connection a character is on, or nil when they are not in the world.
-- @param citizenId string
-- @return number|nil
local function sourceOf(citizenId)
	if character == nil then return nil end
	local read, player = pcall(character.GetPlayerByCitizenId, citizenId)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' then return nil end
	local source = tonumber(data.source)
	if source == nil or source <= 0 then return nil end
	return source
end

--- Whether this player holds the MaxTac division's right or one of its jobs.
-- Read only for the log at a summon: the seats are filled with bots either way
-- until the platform can put a player on duty somewhere.
-- @param data table PlayerData
-- @return boolean
local function isDivision(data)
	local maxtac = Law.Maxtac
	if maxtac == nil or type(data) ~= 'table' then return false end
	local job = data.job
	local name = type(job) == 'table' and job.name or nil
	if type(name) == 'string' then
		for _, listed in ipairs(maxtac.Jobs or {}) do
			if listed == name then return true end
		end
	end
	local acl = Open77.acl
	if maxtac.Right ~= nil and type(acl) == 'table' and type(acl.isAllowed) == 'function' then
		local read, allowed = pcall(acl.isAllowed, data.source, maxtac.Right)
		if read and allowed == true then return true end
	end
	return false
end

--- Stands the response up for a stage and tells the player's client about it.
--
-- The order matters: the ledger is already written when this runs, so a client
-- that never answers still leaves a city that knows what the player did. The
-- response is applied first because it is the half that can fail loudly, and the
-- event last because it is the half that can be delivered once.
-- @param citizenId string
-- @param verdict table what the ledger decided
-- @param options table|nil `{ silence = boolean }`
-- @return table the applied response, or nil when the stage did not move
local function publish(citizenId, verdict, options)
	local stage = tonumber(verdict.stage) or 0
	local playerId = sourceOf(citizenId)
	local previous = tonumber(verdict.previous) or 0
	local opts = type(options) == 'table' and options or {}

	local applied = Response.Apply(citizenId, playerId, stage)
	if applied.ok ~= true then
		Open77.log.warn(('[ncpd] response refused for %s at stage %d: %s')
			:format(citizenId, stage, tostring(applied.error)))
	end

	-- A dropped stage is a cleared city: the units come down and the client is
	-- told to stand the engine's own heat back to zero.
	local clear = stage == 0
	local division = Law.Division(stage)

	if playerId ~= nil then
		TriggerClientEvent(M.Event.STAGE, playerId, {
			playerId = playerId,
			stage = stage,
			previous = previous,
			division = division,
			label = labelOf(division),
			heat = Law.Heat(stage),
			clear = clear,
			av = applied.ok == true and applied.value.av == true,
			reason = opts.reason or 'crime',
		})
	end

	if applied.ok == true and applied.value.av == true then
		local maxtac = Law.Maxtac
		local seats = tonumber(applied.value.seats) or 0
		local filled = tonumber(applied.value.filled) or 0
		local crew = 0
		if playerId ~= nil then
			local data = characterOf(playerId)
			-- Counted, not seated: a player trooper needs a duty half this
			-- platform does not have yet, and a squad that never arrives is
			-- worse than a squad of bots. The number is in the log so a server
			-- that wants that half knows what it is asking for.
			local read, others = pcall(function()
				local list = character.GetPlayers and character.GetPlayers() or {}
				local total = 0
				for _, player in ipairs(list) do
					local data2 = player.PlayerData
					if type(data2) == 'table' and isDivision(data2) then total = total + 1 end
				end
				return total
			end)
			crew = read and tonumber(others) or 0
		end
		Open77.log.info(('[ncpd] %s is wanted: stage %d/%d, %s answering, AV requested%s')
			:format(citizenId, stage, Law.StageCount, tostring(division),
				maxtac ~= nil and maxtac.Fill == 'players' and ' (player-only squad)' or ''))
		Open77.log.info(('[ncpd] squad: %d seat(s), %d filled by bots, %d player(s) hold the division')
			:format(seats, filled, crew))
	end

	Open77.log.info(('[ncpd] charge %s: %s (+%.1f) -> stage %d/%d %s, %d unit(s), %d vehicle(s), %d refusal(s)')
		:format(citizenId, tostring(verdict.law or 'stage'), tonumber(verdict.delta) or 0.0,
			stage, Law.StageCount, tostring(division),
			applied.ok == true and applied.value.npcs or 0,
			applied.ok == true and applied.value.vehicles or 0,
			applied.ok == true and #(applied.value.refused or {}) or 0))

	if applied.ok == true then
		for _, refusal in ipairs(applied.value.refused or {}) do
			Open77.log.warn(('[ncpd] %s: refused spawn: %s'):format(citizenId, tostring(refusal)))
		end
	end

	TriggerEvent(M.Event.ON_STAGE, {
		citizenId = citizenId,
		playerId = playerId,
		stage = stage,
		previous = previous,
		division = division,
	})

	return applied.ok == true and applied.value or nil
end

--- Charges one character and publishes whatever the charge did.
-- @param citizenId string
-- @param lawId string
-- @param options table|nil
-- @return table a `Result`
local function charge(citizenId, lawId, options)
	local charged = Ledger.Report(citizenId, lawId, options)
	if charged.ok ~= true then return charged end

	local verdict = charged.value
	if verdict.crossed == true or verdict.stage ~= verdict.previous then
		publish(citizenId, verdict, { reason = 'crime' })
	end
	return charged
end

--- One decay pass: drain every score, and publish the characters that fell free.
-- @param nowMs integer|nil
-- @return integer how many characters were dropped
local function decayPass(nowMs)
	local now = tonumber(nowMs) or OPX.Now()
	local dropped = 0
	for _, item in ipairs(Ledger.All()) do
		local _, freed = Ledger.Decay(item.citizenId, now)
		if freed then
			dropped = dropped + 1
			local playerId = sourceOf(item.citizenId)
			local stage = 0
			publish(item.citizenId, {
				citizenId = item.citizenId, stage = stage, previous = item.entry.stage or 0,
				law = 'decay', delta = 0.0,
			}, { reason = 'decay' })
			if playerId ~= nil then
				OPX.NotifyLocale(playerId, 'ncpd.cleared', nil, 'success')
			end
		end
	end
	return dropped
end

-- ── the surfaces ─────────────────────────────────────────────────────────────

--- Whether the ACL lets this player run one of this module's commands.
-- @param player number
-- @param name string the command name without its prefix
-- @return boolean
local function aclAllows(player, name)
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

--- Registers one command, ACL-gated, with the same shape every module uses.
-- @param name string
-- @param spec table `{ help, params }`
-- @param handler function(source, args)
local function register(name, spec, handler)
	if type(OPX.Command) ~= 'table' or type(OPX.Command.Register) ~= 'function' then return end
	OPX.Command.Register(name, {
		restricted = true,
		help = spec.help,
		params = spec.params or {},
	}, function(source, args)
		if not aclAllows(source, name) then
			return OPX.CommandResult(source, false, 'not allowed')
		end
		return handler(source, args)
	end)
end

--- The player a command is acting on: the id given, or the caller.
-- @param source number
-- @param args table
-- @param index number
-- @return number|nil
local function targetOf(source, args, index)
	local named = tonumber(args[index])
	if named == nil then return source end
	if named <= 0 then return nil end
	return named
end

local function registerCommands()
	local names = M.Command

	register(names.STATUS, {
		help = 'ncpd.help.status',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		local status = Ledger.Status(data.citizenId)
		local response = Response.Status(data.citizenId)
		OPX.CommandResult(source, true, table.concat({
			('citizen   : %s'):format(data.citizenId),
			('stage     : %d/%d (%s)%s'):format(status.stage, Law.StageCount,
				tostring(status.division or 'nobody'),
				status.wanted and '' or ' -- not wanted'),
			('score     : %.1f'):format(status.score),
			('quiet for : %.0fs'):format(status.sinceSeconds),
			('on street : %d unit(s), %d vehicle(s) [stage %d]'):format(
				response.npcs, response.vehicles, response.stage),
		}, '\n'))
	end)

	register(names.REPORT, {
		help = 'ncpd.help.report',
		params = {
			{ name = 'law', help = 'ncpd.help.law' },
			{ name = 'player', optional = true, help = 'ncpd.help.player' },
		},
	}, function(source, args)
		local target = targetOf(source, args, 2)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		CreateThread(function()
			local charged = charge(data.citizenId, tostring(args[1]))
			if charged.ok ~= true then
				return OPX.CommandResult(source, false, tostring(charged.error))
			end
			local value = charged.value
			OPX.CommandResult(source, true, ('%s charged with %s: %.1f -> stage %d (%s)')
				:format(data.citizenId, tostring(value.law), value.delta, value.stage,
					tostring(value.division or 'nobody')))
		end)
	end)

	register(names.HEAT, {
		help = 'ncpd.help.heat',
		params = {
			{ name = 'stage', help = 'ncpd.help.stage' },
			{ name = 'player', optional = true, help = 'ncpd.help.player' },
		},
	}, function(source, args)
		local target = targetOf(source, args, 2)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		CreateThread(function()
			local set = Ledger.Set(data.citizenId, tonumber(args[1]))
			if set.ok ~= true then
				return OPX.CommandResult(source, false, tostring(set.error))
			end
			publish(data.citizenId, set.value, { reason = 'command' })
			OPX.CommandResult(source, true, ('%s is on stage %d (%s)')
				:format(data.citizenId, set.value.stage, tostring(set.value.division or 'nobody')))
		end)
	end)

	register(names.AV, {
		help = 'ncpd.help.av',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		-- The AV is the client's own request: the engine's spawn system runs in
		-- its script frame, so this re-publishes the current stage with the AV
		-- flag set rather than pretending the server can ask for one.
		local status = Ledger.Status(data.citizenId)
		TriggerClientEvent(M.Event.STAGE, target, {
			playerId = target,
			stage = status.stage,
			previous = status.stage,
			division = status.division,
			label = labelOf(status.division),
			heat = status.heat,
			clear = false,
			av = true,
			reason = 'command',
		})
		OPX.CommandResult(source, true, 'asked their client for the MaxTac AV')
	end)

	register(names.CLEAR, {
		help = 'ncpd.help.clear',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		local cleared = Ledger.Clear(data.citizenId)
		if cleared.ok ~= true then
			return OPX.CommandResult(source, false, tostring(cleared.error))
		end
		publish(data.citizenId, { stage = 0, previous = cleared.value.previous, law = 'clear' },
			{ reason = 'command' })
		OPX.CommandResult(source, true, ('%s is forgotten (was stage %d)')
			:format(data.citizenId, cleared.value.previous))
	end)

	register(names.LAWS, {
		help = 'ncpd.help.laws',
		params = {},
	}, function(source)
		local lines = { ('the law book: %d offence(s), ladder %s'):format(#Law.Ids, ladder()) }
		for _, id in ipairs(Law.Ids) do
			local law = Law.Book[id]
			lines[#lines + 1] = ('  %-16s %6.1f  ceiling %-4s %s')
				:format(id, law.Score or 0.0, law.Ceiling ~= nil and tostring(law.Ceiling) or '-',
					tostring(law.Group or ''))
		end
		OPX.CommandResult(source, true, table.concat(lines, '\n'))
	end)
end

-- ── the engine's own heat, mirrored ───────────────────────────────────────────

--- Mirrors the stage one client's own engine is holding into the ledger.
--
-- WHY THIS IS THE CRIME PATH AND NOT A SHORTCUT. The engine scores its own crimes
-- -- a kill, a theft, a car through a crowd -- and nothing native can read that
-- score: `PreventionSystem`'s 287 methods are all scripted. So the ledger cannot
-- charge a crime it cannot see, and the one place a real crime is visible at all is
-- the client that committed it. That client reads its own engine and states the
-- stage; this function applies it, stands the response up and lets the log name it.
--
-- THE STAGE IS COPIED, NEVER SCORED. Charging the book for a reported stage would
-- be a second scorer: the engine would climb, we would charge a law, our stage would
-- cross higher than the engine's, the client would be told to climb, and it would
-- report that back -- each loop a stage. `Set` is the only write here, so the ledger
-- follows the engine and can never amplify it.
--
-- ATTRIBUTED BY CONNECTION. The payload is one stage and nothing else; the citizen
-- is resolved from the connection the report arrived on, so the worst a modified
-- client can do is lie about its OWN heat -- which the engine on its own client
-- would immediately contradict, one report later.
-- @param source number the connection the report arrived on
-- @param stage any
local function onEngineStage(source, stage)
	local data = characterOf(source)
	if data == nil then
		Open77.log.warn(('[ncpd] engine report from player %d refused: no character loaded')
			:format(tonumber(source) or 0))
		return
	end

	local wanted = tonumber(stage)
	if wanted == nil or wanted ~= math.floor(wanted)
		or wanted < 0 or wanted > Law.StageCount then
		Open77.log.warn(('[ncpd] engine report from %s refused: stage %s is not 0-%d')
			:format(data.citizenId, tostring(stage), Law.StageCount))
		return
	end

	local set = Ledger.Set(data.citizenId, wanted)
	if set.ok ~= true then
		Open77.log.warn(('[ncpd] engine report for %s refused: %s')
			:format(data.citizenId, tostring(set.error)))
		return
	end

	-- Unchanged is the heartbeat, not an event: the stage is already on the street
	-- and re-publishing it would rebuild the response once a poll.
	if set.value.crossed ~= true then return end

	publish(data.citizenId, set.value, { reason = 'engine' })
	Open77.log.info(('[ncpd] %s crossed to stage %d on the engine\'s own heat')
		:format(data.citizenId, wanted))
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Reads what the module needs. Never yields.
function M.Init()
	M.running = false
end

--- Publishes the contract other resources charge crimes through.
function M.Api()
	OPX.Api.Provide('ncpd', 1, {
		--- Charges an offence to a citizen id.
		-- @param citizenId string
		-- @param lawId string
		-- @param options table|nil
		-- @return table a `Result`
		Report = function(citizenId, lawId, options)
			return charge(citizenId, lawId, options)
		end,

		--- Charges an offence to the character a connection has loaded.
		-- @param playerId number
		-- @param lawId string
		-- @param options table|nil
		-- @return table a `Result`
		ReportPlayer = function(playerId, lawId, options)
			local data = characterOf(playerId)
			if data == nil then return OPX.Result.Err('ncpd.noCitizen') end
			return charge(data.citizenId, lawId, options)
		end,

		--- Where a citizen stands, after the drain.
		-- @param citizenId string
		-- @return table
		Status = function(citizenId)
			return Ledger.Status(citizenId)
		end,

		--- Where the connection's own character stands.
		-- @param playerId number
		-- @return table|nil
		StatusPlayer = function(playerId)
			local data = characterOf(playerId)
			if data == nil then return nil end
			return Ledger.Status(data.citizenId)
		end,

		--- Puts a citizen on a stage without a crime: a job's floor.
		-- @param citizenId string
		-- @param stage number
		-- @return table a `Result`
		Set = function(citizenId, stage)
			local set = Ledger.Set(citizenId, stage)
			if set.ok ~= true then return set end
			publish(citizenId, set.value, { reason = 'contract' })
			return set
		end,

		--- Forgets a citizen.
		-- @param citizenId string
		-- @return table a `Result`
		Clear = function(citizenId)
			local cleared = Ledger.Clear(citizenId)
			if cleared.ok ~= true then return cleared end
			publish(citizenId, { stage = 0, previous = cleared.value.previous, law = 'clear' },
				{ reason = 'contract' })
			return cleared
		end,

		--- The book, as the config stands now.
		-- @return table `{ ids, book, stages, count }`
		Book = function()
			return {
				ids = Law.Ids,
				book = Law.Book,
				stages = Law.Stages,
				count = Law.StageCount,
				maxtac = Law.Maxtac,
			}
		end,
	})
end

--- Registers what the module answers to, and starts the decay pass.
function M.Start()
	character = OPX.Api.Get('character')
	hud = OPX.Api.Get('hud')

	for _, line in ipairs(Law.Warnings) do
		Open77.log.warn('[ncpd] config: ' .. line)
	end

	-- The street half, named before it is needed: a host without the vehicle or
	-- the npc contract is a response that cannot arrive, and that is worth one
	-- line at boot rather than a silent empty street at stage 4.
	local canSpawn = type(Open77.vehicles) == 'table' and type(Open77.npcs) == 'table'
	Open77.log.info(('[ncpd] ready: %d law(s), %d heat stage(s): %s; %s')
		:format(#Law.Ids, Law.StageCount, ladder(),
			canSpawn and 'the street can answer' or 'NO spawn contract: units will be refused'))

	-- Named at BOOT, not at the first charge. The client refuses to raise its own
	-- heat while its ambient policy has not heard that this bucket allows police,
	-- so a stage applied before the policy lands is a star with no unit behind it
	-- -- and the one window that cannot be retried is the first one. See
	-- `allowPolice` in `response.lua` for what the bit is and why it is the
	-- server's to set.
	-- Only the refusal is said HERE. The write that succeeds already prints its
	-- own line, with the crowd and traffic it preserved, and a second line for
	-- the same fact at the same moment is noise -- the first boot after the
	-- policy was ever empty is the only boot that needs either of them.
	local police, policeWhy = Response.AllowPolice(0)
	if not police then
		Open77.log.warn('[ncpd] bucket 0 does NOT allow police (' .. tostring(policeWhy) ..
			'): stages will set with no unit behind them')
	end
	if character == nil then
		Open77.log.warn('[ncpd] no character contract: nobody can be charged')
	end

	registerCommands()
	RegisterNetEvent(M.Event.REPORT, onEngineStage)

	M.running = true
	CreateThread(function()
		while M.running do
			Wait(1000)
			decayPass()
		end
	end)
end

--- Deregisters the surface and takes every response down.
function M.Stop()
	M.running = false
	-- The aircraft first: `Response.ReleaseAll` walks the responses it still
	-- holds, and an insertion is not one of them -- it is a run of its own that
	-- would otherwise keep posing an airframe in a bucket nothing owns again.
	local av = M.Av
	local flying = av ~= nil and type(av.RetractAll) == 'function' and av.RetractAll('the module stopped') or 0
	local removed = Response.ReleaseAll()
	Ledger.Forget()
	if flying > 0 then
		Open77.log.info(('[ncpd] stopped: %d MaxTac AV(s) taken down'):format(flying))
	end
	if removed > 0 then
		Open77.log.info(('[ncpd] stopped: %d unit(s) taken down'):format(removed))
	end
end
