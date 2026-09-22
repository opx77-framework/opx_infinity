--- The law book as data, and the score arithmetic that turns crimes into stars.
-- @author XEROX710
--
-- PURE. Nothing here raises, spawns, persists or talks to a client: it decides
-- what a law is, what one crime does to a player's heat, and how that heat falls
-- again. The server's ledger owns WHO has heat and the client's half owns the
-- call into the engine's own `ChangeHeatStage` -- this file is the one place
-- that decides WHAT the numbers are, so the config, the ledger, the tests and
-- (later) the wanted HUD cannot disagree about them.
--
-- THE SHAPE IS THE ENGINE'S, THE NUMBERS ARE THE OPERATOR'S. The engine keeps an
-- accumulated crime score and raises one heat stage when that score reaches the
-- CURRENT stage's capacity, zeroing the score as it crosses -- one stage per
-- crime, never two, which is why `Advance` steps once and not in a loop. Every
-- threshold, weight and multiplier in `config/ncpd.lua` is validated here and a
-- value that cannot be used is NAMED IN A WARNING rather than raised: a typo
-- costs one law, not the session. `Law.Warnings` is the list, and the server
-- half journals it once at boot.
--
-- A LEDGER ENTRY is a plain table -- `{ stage = 3, score = 41.5 }` -- and it is
-- never mutated: `Accrue` and `Decay` answer with the numbers that replace it,
-- so the persistence layer can decide when to write and a test can pin an
-- arithmetic without a world.
--
-- THE LAW BOOK IS THE VOCABULARY, SO AN UNKNOWN LAW IS A REFUSAL and not a
-- silent nothing: a resource that reports `ncpd.report(id, 'murderr', …)` is
-- told its offence is not in the book rather than adding zero and looking like
-- it worked.

local M = OPX.Modules.Get('ncpd')

M.Law = {}
local Law = M.Law

-- Read once, at load: `config/ncpd.lua` is a `shared_script` and the platform
-- runs every shared script before any module declaration, so the table is
-- complete here. The registry rebinds `M.Settings` afterwards, which is why
-- nothing below keeps its own copy of this reference past the validation pass.
local Config = type(M.Settings) == 'table' and M.Settings or {}

--- Every value the config got wrong, as one line each, in the order found.
Law.Warnings = {}

--- The validated book, by law id. Only laws with a usable id and score are here.
Law.Book = {}

--- The book's ids in file order, so a listing reads the way the file does.
Law.Ids = {}

--- The validated ladder, indexed by stage, stage 1 first.
Law.Stages = {}

--- How many stages the ladder declares. Every stage index is bounded by this.
Law.StageCount = 0

--- The division each declared stage names, so a lookup cannot invent one.
Law.DivisionNames = {}

--- The multiplier an unlisted district earns.
Law.DefaultDistrict = 1.0

-- ── coercions ────────────────────────────────────────────────────────────────
-- A number from a config that rejects NaN and both infinities, or nil.

local function finite(value)
	if type(value) ~= 'number' then
		return nil
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- A number that must be strictly positive, or nil.

local function positive(value)
	local number = finite(value)
	if number == nil or number <= 0 then
		return nil
	end
	return number
end

-- A non-empty string, trimmed of nothing: a label is the operator's words and
-- is carried through as written.

local function name(value)
	if type(value) ~= 'string' or value == '' then
		return nil
	end
	return value
end

-- A law or division id: starts lower case, then letters, digits and
-- underscores, so it can be typed in a command and named in a log line without
-- quoting. Camel case is deliberate: the vocabulary an export takes and an error
-- code carries is spelled that way everywhere else here (`error.tooFast`), and
-- a law is a name, not a table key.

local function slug(value)
	local text = name(value)
	if text == nil or text:find('^[a-z][a-zA-Z0-9_]*$') == nil then
		return nil
	end
	return text
end

local function warn(message)
	Law.Warnings[#Law.Warnings + 1] = message
end

-- ── the divisions ────────────────────────────────────────────────────────────

do
	local divisions = Config.DIVISIONS
	if type(divisions) ~= 'table' then
		warn('ncpd: DIVISIONS is not a table, so no stage can name a division')
	else
		local count = 0
		for key, row in pairs(divisions) do
			local id = slug(key)
			if id == nil then
				warn(('ncpd: division %q is not a name a log line can carry'):format(tostring(key)))
			elseif type(row) ~= 'table' or name(row.label) == nil then
				warn(('ncpd: division %q has no label'):format(id))
			else
				Law.DivisionNames[id] = row.label
				count = count + 1
			end
		end
		if count == 0 then
			warn('ncpd: no division was accepted, so no stage can be answered')
		end
	end
end

-- ── the ladder ───────────────────────────────────────────────────────────────
-- Contiguous from stage 1: a gap would make a stage index mean two things.

do
	local ladder = Config.LADDER
	if type(ladder) ~= 'table' then
		warn('ncpd: LADDER is not a table, so no player can ever be wanted')
	else
		-- THE INDEX IS THE ENGINE'S OWN HEAT NUMBER, and stage 0 is `Heat_0`: not
		-- wanted, with the score that MAKES the player wanted. So the ladder runs
		-- from 0 and is contiguous, and `CAPACITY` on a row is the score at which
		-- the player leaves THAT stage.
		local highest = 0
		for key in pairs(ladder) do
			local index = finite(key)
			if index == nil or index < 0 or index ~= math.floor(index) then
				warn(('ncpd: LADDER has a key %q that is not a stage number'):format(tostring(key)))
			elseif index > highest then
				highest = index
			end
		end

		for stage = 0, highest do
			local row = ladder[stage]
			if type(row) ~= 'table' then
				warn(('ncpd: LADDER is missing stage %d'):format(stage))
			else
				-- The name is documentation of what the row IS, and the index is what
				-- everything else uses -- so a row shifted by an insertion is caught
				-- here instead of quietly giving one heat stage another's capacity.
				local expected = 'Heat_' .. stage
				local heat = name(row.heat)
				if heat == nil then
					warn(('ncpd: stage %d has no engine heat name'):format(stage))
				elseif heat ~= expected then
					warn(('ncpd: stage %d says it is %s, but the ladder is indexed by heat '
						.. 'number, so it is %s'):format(stage, heat, expected))
				end
				heat = expected

				-- A stage with no division is a stage nobody answers at, which is
				-- exactly what `Heat_0` is; a stage that NAMES one has to name a real one.
				local division = nil
				if row.division ~= nil then
					division = slug(row.division)
					if division == nil or Law.DivisionNames[division] == nil then
						warn(('ncpd: stage %d names the division %q, which is not declared'):format(
							stage, tostring(row.division)))
						division = nil
					end
				end

				local capacity = finite(row.CAPACITY)
				if capacity == nil or capacity < 0 then
					warn(('ncpd: stage %d has no capacity, so nothing can leave it'):format(stage))
					capacity = nil
				end

				local response = row.RESPONSE
				if type(response) ~= 'table' then
					warn(('ncpd: stage %d has no response table'):format(stage))
					response = nil
				else
					local units = finite(response.UNITS)
					if units == nil or units < 0 or units ~= math.floor(units) then
						warn(('ncpd: stage %d response has no unit count'):format(stage))
					end
					if type(response.VEHICLES) ~= 'table' then
						warn(('ncpd: stage %d response names no vehicle list'):format(stage))
					else
						for index, record in ipairs(response.VEHICLES) do
							if name(record) == nil then
								warn(('ncpd: stage %d vehicle %d is not a record name'):format(stage, index))
							end
						end
					end
					if type(response.ROADBLOCK) ~= 'boolean' then
						warn(('ncpd: stage %d response does not say whether it blocks the road'):format(stage))
					end
				end

				Law.Stages[stage] = {
					Stage = stage,
					-- Always the index's own name, whatever the row spelled.
					Heat = heat,
					Division = division,
					Capacity = capacity,
					Response = response,
					Raw = row,
				}
			end
		end
		Law.StageCount = highest
		if highest == 0 then
			warn('ncpd: the ladder declares no stages, so no player can ever be wanted')
		end
	end
end

-- ── decay ────────────────────────────────────────────────────────────────────

do
	local decay = Config.DECAY
	if type(decay) ~= 'table' then
		warn('ncpd: DECAY is not a table, so a score never falls')
		decay = {}
	end
	local hold = finite(decay.HOLD_SECONDS)
	if hold == nil or hold < 0 then
		warn('ncpd: DECAY.HOLD_SECONDS is not a duration, so the score drains at once')
		hold = 0
	end
	local perSecond = finite(decay.PER_SECOND)
	if perSecond == nil or perSecond < 0 then
		warn('ncpd: DECAY.PER_SECOND is not a rate, so the score never drains')
		perSecond = 0
	end
	local reset = finite(decay.RESET_SECONDS)
	if reset == nil or reset < 0 then
		warn('ncpd: DECAY.RESET_SECONDS is not a duration, so nothing is ever dropped')
		reset = 0
	end
	-- A reset inside the hold would mean a score that is dropped before it has
	-- had the chance to drain, which is a rule with two contradicting halves.
	if reset > 0 and reset <= hold then
		warn(('ncpd: DECAY.RESET_SECONDS (%s) is not longer than HOLD_SECONDS (%s), so the '
			.. 'drain never runs'):format(tostring(reset), tostring(hold)))
	end
	Law.DecayHold = hold
	Law.DecayRate = perSecond
	Law.DecayReset = reset
end

-- ── the law book ─────────────────────────────────────────────────────────────

do
	local laws = Config.LAWS
	if type(laws) ~= 'table' then
		warn('ncpd: LAWS is not a table, so no act is a crime')
	else
		local known = {
			id = true, label = true, score = true, ceiling = true, group = true,
		}
		for index, row in ipairs(laws) do
			if type(row) ~= 'table' then
				warn(('ncpd: law %d is not a table'):format(index))
			else
				local id = slug(row.id)
				if id == nil then
					warn(('ncpd: law %d has no id a command could name'):format(index))
				elseif Law.Book[id] ~= nil then
					warn(('ncpd: law %q is declared twice'):format(id))
				else
					local label = name(row.label)
					if label == nil then
						warn(('ncpd: law %q has no label'):format(id))
					end
					local score = positive(row.score)
					if score == nil then
						warn(('ncpd: law %q has no positive score'):format(id))
					end

					-- A ceiling above the ladder is not a law with a ceiling, it is
					-- a law that never stops counting: say so, and keep it unbounded.
					local ceiling = row.ceiling
					if ceiling ~= nil then
						local stage = finite(ceiling)
						if stage == nil or stage ~= math.floor(stage) or stage < 1 then
							warn(('ncpd: law %q has a ceiling that is not a stage'):format(id))
							ceiling = nil
						elseif Law.StageCount > 0 and stage >= Law.StageCount then
							warn(('ncpd: law %q has ceiling %d, which is the top of the ladder, '
								.. 'so it counts for ever'):format(id, stage))
							ceiling = nil
						end
					end

					local group = row.group
					if group ~= nil and name(group) == nil then
						warn(('ncpd: law %q has a group that is not a name'):format(id))
						group = nil
					end

					for key in pairs(row) do
						if not known[key] then
							warn(('ncpd: law %q carries an unknown key %q'):format(id, tostring(key)))
						end
					end

					if label ~= nil and score ~= nil then
						Law.Book[id] = {
							Id = id,
							Label = label,
							Score = score,
							Ceiling = ceiling,
							Group = group,
						}
						Law.Ids[#Law.Ids + 1] = id
					end
				end
			end
		end
		if #Law.Ids == 0 then
			warn('ncpd: no law was accepted, so nothing a player does can be charged')
		end
	end
end

-- ── districts ────────────────────────────────────────────────────────────────

do
	local districts = Config.DISTRICTS
	if type(districts) ~= 'table' then
		warn('ncpd: DISTRICTS is not a table, so every district scores the same')
	else
		for key, value in pairs(districts) do
			local id = name(key)
			local multiplier = positive(value)
			if id == nil then
				warn(('ncpd: district %q is not a name'):format(tostring(key)))
			elseif multiplier == nil then
				warn(('ncpd: district %q has no positive multiplier'):format(id))
			end
		end
	end
	local fallback = positive(Config.DEFAULT_DISTRICT)
	if fallback ~= nil then
		Law.DefaultDistrict = fallback
	end
end

-- ── the MaxTac division ─────────────────────────────────────────────────────
-- Validated here even though no stage of this module acts on it yet: the config
-- ships these records, and a division whose stage points at an NCPD row, or
-- whose bot fill names no troopers, is a summon that silently never arrives.

--- The division's validated settings, or nil when the config could not be used.
Law.Maxtac = nil

do
	local function records(value, what)
		if type(value) ~= 'table' then
			warn(('ncpd: MAXTAC.%s is not a list'):format(what))
			return {}
		end
		local list = {}
		for index, record in ipairs(value) do
			if name(record) == nil then
				warn(('ncpd: MAXTAC.%s entry %d is not a record name'):format(what, index))
			else
				list[#list + 1] = record
			end
		end
		return list
	end

	local maxtac = Config.MAXTAC
	if type(maxtac) ~= 'table' then
		warn('ncpd: MAXTAC is not a table, so the division can never answer')
	else
		local stage = finite(maxtac.STAGE)
		local row = (stage ~= nil and stage == math.floor(stage)) and Law.Stages[stage] or nil
		if row == nil then
			warn(('ncpd: MAXTAC.STAGE is %s, which is not a stage of the ladder'):format(
				tostring(maxtac.STAGE)))
			stage = nil
		elseif row.Division ~= 'maxtac' then
			warn(('ncpd: MAXTAC.STAGE is %d, whose division is %s'):format(stage, tostring(row.Division)))
		end
		-- The stage's own row is the authority on what heat it is; a division that
		-- spells a different one has been edited apart from its stage.
		if name(maxtac.HEAT) == nil then
			warn('ncpd: MAXTAC.HEAT is not an engine heat name')
		elseif row ~= nil and maxtac.HEAT ~= row.Heat then
			warn(('ncpd: MAXTAC.HEAT is %s but the stage it names is %s'):format(
				maxtac.HEAT, tostring(row.Heat)))
		end

		local fill = maxtac.FILL
		if fill ~= 'bots' and fill ~= 'players' then
			warn(('ncpd: MAXTAC.FILL is %s, which is neither `bots` nor `players`'):format(tostring(fill)))
			fill = nil
		end

		local optIn = maxtac.OPT_IN
		if type(optIn) ~= 'table' then
			warn('ncpd: MAXTAC.OPT_IN is not a table, so nobody can be offered a seat')
		else
			if name(optIn.RIGHT) == nil then
				warn('ncpd: MAXTAC.OPT_IN.RIGHT is not a right name')
			end
			if type(optIn.JOBS) ~= 'table' then
				warn('ncpd: MAXTAC.OPT_IN.JOBS is not a list of jobs')
			end
		end

		local av = maxtac.AV
		local insertion = nil
		if type(av) ~= 'table' then
			warn('ncpd: MAXTAC.AV is not a table, so nothing flies in')
			av = nil
		else
			if name(av.RECORD) == nil then
				warn('ncpd: MAXTAC.AV.RECORD is not a record name')
			end
			if type(av.ONE_AT_A_TIME) ~= 'boolean' then
				warn('ncpd: MAXTAC.AV.ONE_AT_A_TIME is not a boolean')
			end
			if finite(av.COOLDOWN_SECONDS) == nil or finite(av.COOLDOWN_SECONDS) < 0 then
				warn('ncpd: MAXTAC.AV.COOLDOWN_SECONDS is not a duration')
			end

			-- The insertion run. Every field is a distance, a duration or a pose
			-- cadence, and the altitudes are ordered or the airframe flies through
			-- the street. A plan with one unusable number is dropped WHOLE and
			-- named: a run that starts from a half-read plan is an AV buried in
			-- the road or one that never leaves, and both look like a broken
			-- feature rather than a bad config line.
			local plan = av.INSERTION
			if type(plan) ~= 'table' then
				warn('ncpd: MAXTAC.AV.INSERTION is not a table, so the AV is never flown in')
			else
				local usable = true
				for _, field in ipairs({
					'APPROACH_METRES', 'APPROACH_ALTITUDE', 'HOVER_ALTITUDE', 'DROP_ALTITUDE',
				}) do
					if positive(plan[field]) == nil then
						warn(('ncpd: MAXTAC.AV.INSERTION.%s is not a distance'):format(field))
						usable = false
					end
				end
				for _, field in ipairs({
					'CRUISE_SECONDS', 'DESCENT_SECONDS', 'DEPLOY_SECONDS', 'HOVER_SECONDS', 'EXIT_SECONDS',
				}) do
					if finite(plan[field]) == nil or plan[field] < 0 then
						warn(('ncpd: MAXTAC.AV.INSERTION.%s is not a duration'):format(field))
						usable = false
					end
				end
				local tick = finite(plan.TICK_MS)
				if tick == nil or tick ~= math.floor(tick) or tick < 25 or tick > 1000 then
					warn('ncpd: MAXTAC.AV.INSERTION.TICK_MS is not a cadence between 25 and 1000 ms')
					usable = false
				end
				if usable and not (positive(plan.DROP_ALTITUDE) < positive(plan.HOVER_ALTITUDE) and
					positive(plan.HOVER_ALTITUDE) <= positive(plan.APPROACH_ALTITUDE)) then
					warn('ncpd: MAXTAC.AV.INSERTION must order DROP_ALTITUDE < HOVER_ALTITUDE <= APPROACH_ALTITUDE')
					usable = false
				end
				if usable then
					insertion = {
						ApproachMetres = plan.APPROACH_METRES,
						ApproachAltitude = plan.APPROACH_ALTITUDE,
						HoverAltitude = plan.HOVER_ALTITUDE,
						DropAltitude = plan.DROP_ALTITUDE,
						CruiseSeconds = plan.CRUISE_SECONDS,
						DescentSeconds = plan.DESCENT_SECONDS,
						DeploySeconds = plan.DEPLOY_SECONDS,
						HoverSeconds = plan.HOVER_SECONDS,
						ExitSeconds = plan.EXIT_SECONDS,
						TickMs = tick,
					}
				end
			end
		end

		local troopers = records(maxtac.TROOPERS, 'TROOPERS')
		if fill == 'bots' and #troopers == 0 then
			warn('ncpd: MAXTAC.TROOPERS names no trooper, so an empty seat is filled by nobody')
		end

		local squad = maxtac.SQUAD
		if type(squad) ~= 'table' then
			warn('ncpd: MAXTAC.SQUAD is not a table, so a summon has no size')
		else
			local seats = finite(squad.SEATS)
			if seats == nil or seats ~= math.floor(seats) or seats < 1 then
				warn('ncpd: MAXTAC.SQUAD.SEATS is not a seat count')
			end
			local waves = finite(squad.WAVES)
			if waves == nil or waves ~= math.floor(waves) or waves < 1 then
				warn('ncpd: MAXTAC.SQUAD.WAVES is not a wave count')
			end
			if positive(squad.INSERTION_RADIUS) == nil then
				warn('ncpd: MAXTAC.SQUAD.INSERTION_RADIUS is not a distance')
			end
		end

		Law.Maxtac = {
			Stage = stage,
			Heat = row ~= nil and row.Heat or nil,
			Fill = fill,
			Right = type(optIn) == 'table' and name(optIn.RIGHT) or nil,
			Jobs = type(optIn) == 'table' and type(optIn.JOBS) == 'table' and optIn.JOBS or {},
			ResponseSeconds = finite(maxtac.RESPONSE_SECONDS),
			AvRecord = av ~= nil and name(av.RECORD) or nil,
			AvVariants = av ~= nil and records(av.VARIANTS, 'AV.VARIANTS') or {},
			AvSecondWave = av ~= nil and records(av.SECOND_WAVE, 'AV.SECOND_WAVE') or {},
			AvOneAtATime = av ~= nil and av.ONE_AT_A_TIME == true,
			AvCooldown = av ~= nil and finite(av.COOLDOWN_SECONDS) or nil,
			AvLift = av ~= nil and finite(av.LIFT) or nil,
			AvInsertion = insertion,
			Vehicle = name(maxtac.VEHICLE),
			Ground = records(maxtac.GROUND, 'GROUND'),
			Troopers = troopers,
			Tag = name(maxtac.TAG),
			AloneEffect = name(maxtac.ALONE_EFFECT),
			Squad = type(squad) == 'table' and squad or nil,
		}
	end
end

-- ── the readable surface ─────────────────────────────────────────────────────

--- Whether the book names this offence.
-- @param id string
-- @return boolean
function Law.Known(id)
	return type(id) == 'string' and Law.Book[id] ~= nil
end

--- What one of this offence costs, before multipliers.
-- @param id string
-- @return number|nil
function Law.Score(id)
	local law = type(id) == 'string' and Law.Book[id] or nil
	return law ~= nil and law.Score or nil
end

--- The stage at or above which this offence stops counting, or nil.
-- @param id string
-- @return number|nil
function Law.Ceiling(id)
	local law = type(id) == 'string' and Law.Book[id] or nil
	return law ~= nil and law.Ceiling or nil
end

--- The stage's validated row.
-- @param stage number
-- @return table|nil
function Law.Stage(stage)
	local index = finite(stage)
	if index == nil or index ~= math.floor(index) or index < 0 or index > Law.StageCount then
		return nil
	end
	return Law.Stages[index]
end

--- The score at which a player leaves this stage, or nil.
-- @param stage number
-- @return number|nil
function Law.Capacity(stage)
	local row = Law.Stage(stage)
	return row ~= nil and row.Capacity or nil
end

--- The engine's heat name for this stage, or nil.
-- @param stage number
-- @return string|nil
function Law.Heat(stage)
	local row = Law.Stage(stage)
	return row ~= nil and row.Heat or nil
end

--- The division that answers at this stage, or nil.
-- @param stage number
-- @return string|nil
function Law.Division(stage)
	local row = Law.Stage(stage)
	return row ~= nil and row.Division or nil
end

--- The engine records a stage's response sends, lower-cased as configured.
-- @param stage number
-- @return table the list, empty when the stage has none
function Law.Vehicles(stage)
	local row = Law.Stage(stage)
	if row == nil or row.Response == nil or type(row.Response.VEHICLES) ~= 'table' then
		return {}
	end
	return row.Response.VEHICLES
end

--- What a district multiplies every score earned in it by.
-- Unknown, unlisted and unreadable names all answer the default, so a report
-- from a resource that names no district is scored rather than dropped.
-- @param district string|nil
-- @return number
function Law.Multiplier(district)
	if type(district) ~= 'string' then
		return Law.DefaultDistrict
	end
	local value = positive(Law.DefaultDistrict) and Law.DefaultDistrict or 1.0
	for key, multiplier in pairs(Config.DISTRICTS or {}) do
		if type(key) == 'string' and key:lower() == district:lower() then
			local accepted = positive(multiplier)
			if accepted ~= nil then
				return accepted
			end
		end
	end
	return value
end

--- The score left after `since` seconds without a crime.
-- Held while the hold lasts, drained at the rate after it, dropped outright
-- once the reset has passed. A score that is already zero stays zero.
-- @param score number
-- @param since number seconds since the last crime
-- @return number
function Law.Decay(score, since)
	local value = finite(score) or 0
	if value <= 0 then
		return 0
	end
	local elapsed = finite(since) or 0
	if elapsed < 0 then
		elapsed = 0
	end
	if Law.DecayReset > 0 and elapsed >= Law.DecayReset then
		return 0
	end
	if elapsed <= Law.DecayHold then
		return value
	end
	local drained = value - Law.DecayRate * (elapsed - Law.DecayHold)
	if drained <= 0 then
		return 0
	end
	return drained
end

--- The next stage and score after `delta` is added.
-- ONE stage per call, and this mirrors the engine deliberately: the engine
-- checks its threshold once per crime request and zeroes the score as it
-- crosses (`preventionSystem.script:2501`), so a single enormous score does not
-- skip a division -- it crosses one stage and starts again from zero.
--
-- The score needed to leave a stage is ITS OWN row's capacity, which is why a
-- player who is not wanted still has a threshold to cross: it is `Heat_0`'s.
-- @param stage number the player's current stage, 0 for not wanted
-- @param score number the score accumulated inside that stage
-- @param delta number what the crime is worth
-- @return number stage
-- @return number score
-- @return boolean whether a stage was crossed
function Law.Advance(stage, score, delta)
	local current = finite(stage) or 0
	if current < 0 or current ~= math.floor(current) then
		current = 0
	end
	if current > Law.StageCount then
		current = Law.StageCount
	end
	local total = (finite(score) or 0) + (finite(delta) or 0)
	if total < 0 then
		total = 0
	end

	local row = Law.Stages[current]
	if row == nil or row.Capacity == nil or row.Capacity <= 0 then
		return current, total, false
	end
	if current >= Law.StageCount then
		-- The top of the ladder. A player already there keeps accumulating, and
		-- what ends it is the division dying or the score draining -- not another
		-- crossing, because there is nothing above.
		return current, total, false
	end
	if total < row.Capacity then
		return current, total, false
	end
	return current + 1, 0, true
end

--- One crime against one ledger entry.
-- The entry is `{ stage = number, score = number }` and is never modified.
-- `multiplier` scales a single report (a job, a weapon, a scripted event) and
-- `district` picks the config's district weight; both are optional and both are
-- validated, so a bad one is 1.0 rather than a NaN that poisons the score.
-- @param entry table { stage, score }
-- @param lawId string
-- @param multiplier number|nil
-- @param district string|nil
-- @return table a verdict: `{ ok, reason?, stage, score, delta, crossed, capped }`
function Law.Accrue(entry, lawId, multiplier, district)
	if Law.Known(lawId) == false then
		return { ok = false, reason = 'unknownLaw', law = tostring(lawId) }
	end
	local law = Law.Book[lawId]
	local stage = finite(entry and entry.stage) or 0
	if stage < 0 or stage ~= math.floor(stage) then
		stage = 0
	end
	local score = finite(entry and entry.score) or 0
	if score < 0 then
		score = 0
	end

	local scale = positive(multiplier)
	if scale == nil then
		scale = 1.0
	end
	local delta = law.Score * scale * Law.Multiplier(district)

	-- A ceiling does not refuse the crime: it happened, it simply earns nothing
	-- once the city is already looking for somebody this hard.
	local capped = law.Ceiling ~= nil and stage >= law.Ceiling
	if capped then
		delta = 0
	end

	local nextStage, nextScore, crossed = Law.Advance(stage, score, delta)
	return {
		ok = true,
		law = law.Id,
		delta = delta,
		capped = capped,
		crossed = crossed,
		stage = nextStage,
		score = nextScore,
		division = Law.Division(nextStage),
	}
end
