--- The client half: one stage from the server becomes this client's own heat.
-- @author XEROX710
--
-- WHY THE CLIENT DOES THIS AND NOT THE SERVER. `PreventionSystem`'s 287 methods
-- are all scripted -- not one is native -- and the ones that raise a stage are
-- private, so nothing outside the game's script frame can move a star. `open77-base`
-- therefore carries a narrow seam: `Open77.prevention.heat(playerId, stage)` and
-- `.av(playerId)` queue the request into the REDscript bridge, which executes it
-- inside the script frame the client owns, on the LOCAL player only. The address
-- is the safety property -- a command naming a player this client is not is
-- refused by the bridge and counted -- so this file passes the id the server
-- named and never substitutes its own.
--
-- THE ENGINE OWNS EVERYTHING VISIBLE. The wanted bar, the stars, the siren audio
-- stake, the police radio and the per-stage effects all happen inside the game's
-- own `OnHeatChanged`, which is why there is no HUD drawn here: drawing a second
-- wanted bar over the engine's would be two answers to "how wanted am I".
--
-- A CLIENT WITHOUT THE SEAM SAYS SO ONCE. The seam arrived after the build that
-- shipped it, so an older plugin answers `nil` for `Open77.prevention`. That is a
-- warning once and a named refusal per request, never a silent nothing: the
-- server's ledger still holds the score, and the one line in the log says which
-- half is missing.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

--- Whether this client has already complained about a missing seam.
local seamWarned = false

--- The stage this client has asked the engine for.
local applied = 0

--- The prevention seam, or nil when this build does not have it.
--
-- ONE SHAPE, AND IT IS THE PLATFORM'S. The seam is `Open77.prevention`, gated by
-- `world.prevention`: `setWanted(stage)` moves this client's own wanted level,
-- `requestAv()` asks the engine's spawn system for the MaxTac AV, and `state()`
-- reports what was asked and what the script loop answered. There is no player
-- argument on any of them, because the engine's wanted level is scalar on a
-- singleton system and the spawn system holds one player handle -- the world
-- this client is simulating is the only world there is to move. The player id in
-- the payload below is therefore the server's bookkeeping and this module's own
-- correlation, never something the engine is told.
-- @return table|nil
local function seam()
	local prevention = Open77 and Open77.prevention
	if type(prevention) ~= 'table' then return nil end
	if type(prevention.setWanted) ~= 'function' then return nil end
	return prevention
end

--- Asks the engine for a heat stage: this client's own wanted level.
-- @param playerId number the player the server named (bookkeeping, not a target)
-- @param stage number 0..5
-- @return boolean accepted
-- @return string|nil why not
local function applyHeat(playerId, stage)
	local prevention = seam()
	if prevention == nil then
		if not seamWarned then
			seamWarned = true
			Open77.log.warn('[ncpd] this client has no Open77.prevention seam ' ..
				'(the plugin is older than the module): heat cannot be raised')
		end
		return false, 'seam_unavailable'
	end

	-- The id stops here, deliberately: a resource that cannot name a puppet
	-- cannot reach the wrong one, and the only world this lever can move is the
	-- one this client is simulating.
	local read, accepted, why = pcall(prevention.setWanted, stage)
	if not read then return false, tostring(accepted) end
	if accepted ~= true then return false, tostring(why or 'refused') end
	return true
end

--- Asks the engine for the MaxTac AV, for the player the server named.
--
-- `true` means the request was QUEUED. Whether the engine's spawn system took it
-- is a separate fact and it is the ticket: `state().avTicket` carries the number
-- `RequestAVSpawn` returned, and the trace below reads it back one poll later so
-- "nothing happened" is never the whole story.
-- @param playerId number the player the server named (bookkeeping, not a target)
-- @return boolean accepted
-- @return string|nil why not
local function requestAv(playerId)
	local prevention = seam()
	if prevention == nil then return false, 'seam_unavailable' end
	if type(prevention.requestAv) ~= 'function' then
		return false, 'seam_av_unavailable'
	end

	local read, accepted, why = pcall(prevention.requestAv)
	if not read then return false, tostring(accepted) end
	if accepted ~= true then return false, tostring(why or 'refused') end

	-- The ticket is read a moment later rather than assumed here: the script loop
	-- is asynchronous by construction, and a zero ticket is the engine saying no.
	-- One line, on the client that owns the AV, because that is where the answer
	-- exists; a node that wants it reads the client's log rather than being told a
	-- second-hand number it cannot verify.
	CreateThread(function()
		Wait(AV_TICKET_DELAY_MS)
		local reading = prevention.state and prevention.state() or nil
		local ticket = type(reading) == 'table' and tonumber(reading.avTicket) or nil
		if ticket ~= nil then
			Open77.log.info(('[ncpd] MaxTac AV asked for player %s: ticket %d (%s)')
				:format(tostring(playerId), ticket,
					ticket > 0 and 'the engine took it' or 'REFUSED by the spawn system'))
		else
			Open77.log.info('[ncpd] MaxTac AV asked for: this client reports no ticket ' ..
				'channel (Open77.prevention.state has no avTicket)')
		end
	end)
	return true
end

--- One line per instruction, naming both halves: what the server asked for and
--- whether the engine took it. A stage that never shows is then read rather than
--- guessed at.
-- @param payload table
-- @return boolean heat accepted
-- @return boolean av accepted
local function act(payload)
	local playerId = tonumber(payload.playerId)
	local stage = tonumber(payload.stage) or 0
	local division = tostring(payload.division or 'nobody')
	local av = payload.av == true

	local heat, heatWhy = applyHeat(playerId, stage)
	local asked, avWhy = false, nil
	-- THE AV IS NOT A PROPERTY OF THE STAGE. `/opx.ncpd.av` arrives with
	-- `av = true` and `stage = 0` by design -- asking for the aircraft is not
	-- asking to be wanted -- and the engine's spawn system reads this client's
	-- own wanted level rather than the payload's. Gating the call on
	-- `stage > 0` made that command a no-op that still logged
	-- `av=refused:nil`: "i typed ncpd av and nothing happened", with an
	-- operator line naming no cause. `av` alone decides it.
	if av then
		asked, avWhy = requestAv(playerId)
	end

	Open77.log.info(('[ncpd] %s: stage %d -> %d, division %s, heat=%s%s, av=%s%s')
		:format(tostring(payload.reason or 'server'), tonumber(payload.previous) or 0, stage, division,
			heat and 'accepted' or 'refused',
			heat and '' or (':' .. tostring(heatWhy)),
			av and (asked and 'accepted' or ('refused:' .. tostring(avWhy))) or 'not-asked',
			''))

	if heat then applied = stage end
	return heat, asked
end

--- The one wire handler: a stage, an optional AV, and nothing else.
RegisterNetEvent(M.Event.STAGE, function(payload)
	if type(payload) ~= 'table' then return end
	local playerId = tonumber(payload.playerId)
	if playerId == nil or playerId <= 0 then return end

	local stage = tonumber(payload.stage) or 0
	local heat, asked = act(payload)
	local maxtacStage = Law.Maxtac ~= nil and tonumber(Law.Maxtac.Stage) or 5

	if heat ~= true then
		-- The ledger is the city's; the client only says it cannot show it.
		OPX.Toast.Locale('ncpd.seamUnavailable', nil, 'error')
	elseif stage == 0 then
		OPX.Toast.Locale('ncpd.cleared', nil, 'success')
	elseif asked then
		OPX.Toast.Locale('ncpd.maxtacInbound', nil, 'error')
	elseif stage >= maxtacStage then
		OPX.Toast.Locale('ncpd.heatRaised',
			{ division = tostring(payload.label or payload.division or 'MaxTac'), stage = stage }, 'error')
	else
		OPX.Toast.Locale('ncpd.heatRaised',
			{ division = tostring(payload.label or payload.division or 'NCPD'), stage = stage }, 'warning')
	end

	-- The local bus, so a HUD or a job resource hears the crossing without
	-- asking the server for what it was already told.
	TriggerEvent(M.Event.ON_STAGE, {
		playerId = playerId,
		stage = stage,
		previous = tonumber(payload.previous) or 0,
		division = payload.division,
		heat = heat == true,
		av = asked == true,
	})
end)

-- ── the engine's own heat, reported back ───────────────────────────────────────
--
-- THIS IS HOW A CRIME REACHES THE LEDGER. The engine charges its own crime score
-- when a player kills, steals or drives a car through a crowd -- `PreventionSystem`
-- owns it, 287 scripted methods and not one readable from native code -- so the
-- only place a real crime is visible is that client's own reading of it, and the
-- only way the server learns of one is that client saying so. `Open77.prevention.state()`
-- is that read: it names no player, so a client reports what it is holding and
-- nothing else, and the server attributes the report to the connection it arrived
-- on rather than to anything the payload claims.
--
-- THE STAGE, NOT THE SCORE. The engine zeroes its score as it crosses a stage, so
-- a score reported second-hand would be a number our ledger re-scores from -- two
-- answers to "how wanted am I", the newer one wrong. The stage is what the player
-- can see, so the stage is what is mirrored.

--- How often the engine's own reading is polled. The engine's heat moves on the
--- scale of a crime and a quiet minute, so a second is finer than it can change.
local POLL_MS = 1000

--- How long to wait before reading the AV ticket back. One engine tick is enough
--- for the script loop to run the request; a second is well inside that and long
--- enough that a busy frame cannot read the previous answer.
local AV_TICKET_DELAY_MS = 700

--- How often an unchanged stage is repeated.
--
-- The repeat is not decoration: the server's ledger lets a stage go after its own
-- quiet window, and the engine's heat can outlast that window -- a player pinned at
-- two stars with nobody left to chase has nothing to report and nothing to stop
-- them being reported as free. So a stage still held is restated well inside the
-- window, which also means a client that stops talking (a crash, a dropped
-- connection) lets its own response stand down on schedule.
local HEARTBEAT_MS = 30000

--- Whether this client has already said that it cannot report engine heat.
local mirrorWarned = false

--- The stage this client last told the server about, or nil before the first.
local reported = nil

--- When the last report went out, on the module's own clock.
local reportedAtMs = 0

--- The engine's own stage, or nil while no reading has arrived.
--
-- `engineHeat` and not `requestedLevel`. Those are two different facts: one is
-- what the engine's `PreventionSystem` currently holds, the other is what this
-- client asked it for a moment ago. Reporting the request would let a raise the
-- engine refused come back to the server as a crime the engine charged itself,
-- which is the one thing this mirror must never do.
-- @return number|nil
local function engineStage()
	local prevention = seam()
	if prevention == nil or type(prevention.state) ~= 'function' then return nil end

	local read, reading = pcall(prevention.state)
	if not read or type(reading) ~= 'table' then return nil end
	local stage = tonumber(reading.engineHeat)
	if stage == nil or stage < 0 or stage > 5 then return nil end
	return stage
end

--- Reports the engine's own heat to the server: once per change, and at least once
--- per heartbeat while a stage is held.
-- The first reading is sent even when it is zero: a client that has just stood up
-- is telling the server where it stands, and a ledger that never heard otherwise
-- holds whatever the last session left behind.
-- @return boolean whether a report went out
function M.Report()
	local stage = engineStage()
	if stage == nil then
		-- Said once, and named, rather than looking like a quiet world: a client
		-- whose platform has no engine reading can still be charged by a command,
		-- but nothing it does in the street will ever reach the ledger.
		if not mirrorWarned then
			mirrorWarned = true
			Open77.log.warn('[ncpd] this client reports no engine heat ' ..
				'(Open77.prevention.state has no engineHeat): crimes cannot charge the ledger')
		end
		return false
	end

	local now = OPX.Now()
	local previous = reported
	local changed = previous ~= stage
	local due = now - reportedAtMs >= HEARTBEAT_MS
	if not changed and not due then return false end

	reported = stage
	reportedAtMs = now
	TriggerServerEvent(M.Event.REPORT, stage)

	-- Only a change is worth a line: a heartbeat is the same fact restated, and a
	-- line a second would bury the reading it exists to show.
	if changed then
		Open77.log.info(('[ncpd] engine heat %d reported (was %s)')
			:format(stage, previous == nil and 'nothing yet' or tostring(previous)))
	end
	return true
end

--- What this client has asked the engine for. Read by the `server.status` probe
--- (`Open77.modules`), and the only way to tell "the server never asked" from
--- "the engine refused" when a stage is missing in game.
-- @return table
function M.Status()
	return { applied = applied, reported = reported, seam = seam() ~= nil }
end

--- Begins polling the engine's own heat.
function M.Start()
	M.running = true
	CreateThread(function()
		while M.running do
			Wait(POLL_MS)
			pcall(M.Report)
		end
	end)
end

--- Stops the poll. The next session reports its reading again from scratch.
function M.Stop()
	M.running = false
	reported = nil
	reportedAtMs = 0
end
