--- What the chrome is worth on the body: the numbers every fitted piece adds,
-- composed on top of whatever the rest of the server set, and applied through
-- the platform's own stat authority.
-- @author XEROX710
--
-- COMPOSED, NEVER OWNED. The character module sets a health pool at every
-- placement, staff set armor, and the platform has its own regeneration
-- defaults. So this file never decides a pool; it decides a BONUS and adds it
-- to whatever it finds. It remembers what it last wrote, and a value it finds
-- that is not the one it wrote is somebody else's new base -- the placement's
-- pool, a staff command -- which the bonus is then put back on top of. Taking
-- the chrome out writes the base back and forgets the player.
--
-- WHAT EACH NUMBER MEANS HERE:
--   healthMax / staminaMax      points on the canonical maximum
--   healthRegen / staminaRegen  points per second on the canonical rate
--   noFall                      landings stop hurting (a life flag, and death
--                               drops it, so it is re-asserted every pass)
--   armor                       the PLATING's rating. Platform armor is a pool
--                               that absorbs damage before health (docs/
--                               combat.md), so the plating recharges toward its
--                               rating once the body has gone unhurt for a
--                               moment -- a shield that comes back, not a pool
--                               refilled under fire. It only ever RAISES armor:
--                               staff-set armor above the rating is left alone.
--   capacity                    read by the offer rules, never applied here
-- A failing piece is worth `FAILING_EFFECT` of itself and a broken one nothing
-- (`M.Ripper.EffectFactor`), so the numbers follow the lifecycle on their own.

local M = OPX.Modules.Get('ripperdoc')

local CreateThread, Wait = CreateThread, Wait

M.Effects = {}

-- player -> { citizen, base = {}, applied = {}, noFall, damagedAt }
local state = {}
-- players whose numbers should be recomposed at the next pass, now
local urgent = {}
local running = false

--- One cap from the config, finite and non-negative.
-- @param key string
-- @param default number
-- @return number
local function cap(key, default)
	local block = type(M.Settings.EFFECTS) == 'table' and M.Settings.EFFECTS or {}
	local value = OPX.Math.Finite(block[key])
	if value == nil or value < 0 then return default end
	return value
end

--- The composer's own knobs.
-- @return table
function M.Effects.Policy()
	return {
		ARMOR_CAP = cap('ARMOR_CAP', 80),
		HEALTH_MAX_CAP = cap('HEALTH_MAX_CAP', 150),
		HEALTH_REGEN_CAP = cap('HEALTH_REGEN_CAP', 8),
		STAMINA_MAX_CAP = cap('STAMINA_MAX_CAP', 80),
		STAMINA_REGEN_CAP = cap('STAMINA_REGEN_CAP', 20),
		CAPACITY_CAP = cap('CAPACITY_CAP', 100),
		-- Milliseconds the body must go unhurt before the plating recharges.
		ARMOR_DELAY_MS = cap('ARMOR_DELAY_MS', 6000),
		-- The share of the rating recharged per second.
		ARMOR_RECHARGE = cap('ARMOR_RECHARGE', 0.25),
		RECONCILE_MS = math.max(250, cap('RECONCILE_MS', 1000)),
	}
end

--- What one citizen's chrome adds up to, right now.
-- @param citizenId string|nil
-- @return table { armor, healthMax, healthRegen, staminaMax, staminaRegen, noFall, capacity }
function M.Effects.Totals(citizenId)
	local totals = { armor = 0, healthMax = 0, healthRegen = 0, staminaMax = 0,
		staminaRegen = 0, noFall = false, capacity = 0 }
	for entryId, row in pairs(M.Chrome.Rows(citizenId)) do
		local entry = M.Ripper.Entry(entryId)
		local grade = entry ~= nil and tostring(row.grade or '') ~= ''
			and M.Ripper.Grade(entry, row.grade) or nil
		local effects = grade ~= nil and grade.EFFECTS or nil
		if type(effects) == 'table' then
			local factor = M.Ripper.EffectFactor(row.points, row.broken)
			if factor > 0 then
				for key, value in pairs(effects) do
					if key == 'noFall' then
						if value == true then totals.noFall = true end
					elseif key == 'capacity' then
						-- Capacity is the body's, not a performance: a failing
						-- compressor still holds what it holds; a broken one
						-- holds nothing.
						totals.capacity = totals.capacity + (tonumber(value) or 0)
					elseif totals[key] ~= nil then
						totals[key] = totals[key] + (tonumber(value) or 0) * factor
					end
				end
			end
		end
	end
	local policy = M.Effects.Policy()
	totals.armor = math.floor(math.min(totals.armor, policy.ARMOR_CAP))
	totals.healthMax = math.floor(math.min(totals.healthMax, policy.HEALTH_MAX_CAP))
	totals.staminaMax = math.floor(math.min(totals.staminaMax, policy.STAMINA_MAX_CAP))
	totals.healthRegen = math.min(totals.healthRegen, policy.HEALTH_REGEN_CAP)
	totals.staminaRegen = math.min(totals.staminaRegen, policy.STAMINA_REGEN_CAP)
	totals.capacity = math.floor(math.min(totals.capacity, policy.CAPACITY_CAP))
	return totals
end

--- The platform's stat snapshot, or nil.
-- @param player number
-- @return table|nil
local function statsOf(player)
	local api = type(Open77) == 'table' and Open77.stats or nil
	if api == nil or type(api.get) ~= 'function' then return nil end
	local ran, stats = pcall(api.get, player)
	return ran and type(stats) == 'table' and stats or nil
end

--- Calls one platform setter, logging a refusal once per player and key.
-- @param st table the player's state
-- @param name string for the log
-- @param fn function|nil
-- @return boolean
local function call(st, name, fn, ...)
	if type(fn) ~= 'function' then return false end
	local ran, ok, why = pcall(fn, ...)
	if ran and ok ~= false and ok ~= nil then return true end
	st.warned = st.warned or {}
	if not st.warned[name] then
		st.warned[name] = true
		Open77.log.warn(('[ripperdoc] %s was refused for the chrome: %s')
			:format(name, tostring((not ran and ok) or why or 'refused')))
	end
	return false
end

--- One pool's maximum and rate, composed: the base is what we find unless it
--- is what we wrote, and the bonus goes on top of it.
-- @param player number
-- @param st table
-- @param pool string `health` or `stamina`
-- @param snapshot table the pool out of `Open77.stats.get`
-- @param maxBonus number
-- @param regenBonus number
local function composePool(player, st, pool, snapshot, maxBonus, regenBonus)
	local api = Open77.stats
	if type(snapshot) ~= 'table' then return end
	local liveMax = tonumber(snapshot.maximum or snapshot.max)
	local liveRate = tonumber(snapshot.regenPerSecond) or 0
	local liveOn = snapshot.regenEnabled == true
	local maxKey, rateKey, onKey = pool .. 'Max', pool .. 'Regen', pool .. 'RegenOn'

	if liveMax ~= nil then
		if st.applied[maxKey] == nil or math.abs(liveMax - st.applied[maxKey]) > 0.5 then
			st.base[maxKey] = liveMax
		end
		local desired = st.base[maxKey] + maxBonus
		if maxBonus == 0 then
			if st.applied[maxKey] ~= nil and math.abs(liveMax - st.base[maxKey]) > 0.5 then
				call(st, 'setMax(' .. pool .. ')', api.setMax, player, pool, st.base[maxKey])
			end
			st.applied[maxKey] = nil
		elseif math.abs(liveMax - desired) > 0.5 then
			if call(st, 'setMax(' .. pool .. ')', api.setMax, player, pool, desired) then
				st.applied[maxKey] = desired
			end
		else
			st.applied[maxKey] = desired
		end
	end

	if st.applied[rateKey] == nil or math.abs(liveRate - st.applied[rateKey]) > 0.01
		or (st.applied[onKey] ~= nil and liveOn ~= st.applied[onKey]) then
		st.base[rateKey], st.base[onKey] = liveRate, liveOn
	end
	if regenBonus <= 0 then
		if st.applied[rateKey] ~= nil then
			call(st, 'setRegenRate(' .. pool .. ')', api.setRegenRate, player, pool, st.base[rateKey])
			call(st, 'setRegenEnabled(' .. pool .. ')', api.setRegenEnabled, player, pool,
				st.base[onKey] == true)
		end
		st.applied[rateKey], st.applied[onKey] = nil, nil
		return
	end
	-- A pool that did not regenerate at all gains the chrome's rate alone; one
	-- that did gains it on top of its own.
	local desired = (st.base[onKey] == true and st.base[rateKey] or 0) + regenBonus
	if math.abs(liveRate - desired) > 0.01 then
		call(st, 'setRegenRate(' .. pool .. ')', api.setRegenRate, player, pool, desired)
	end
	if not liveOn then
		call(st, 'setRegenEnabled(' .. pool .. ')', api.setRegenEnabled, player, pool, true)
	end
	st.applied[rateKey], st.applied[onKey] = desired, true
end

--- Puts one player's chrome on their body, or takes it off when they have
--- none. Never raises.
-- @param player number
-- @param citizenId string|nil the character to compose for; nil takes it off
-- @param dtSeconds number the time since the last pass, for the plating
function M.Effects.Apply(player, citizenId, dtSeconds)
	local st = state[player]
	if st ~= nil and citizenId ~= nil and st.citizen ~= nil and st.citizen ~= citizenId then
		-- A different character on the same connection: the last one's
		-- chrome comes off first, against the base it was composed on. The
		-- take-off pass is a nil citizen, which never comes back here.
		M.Effects.Apply(player, nil, 0)
		st = state[player]
	end
	if st ~= nil then st.citizen = citizenId end
	local totals = citizenId ~= nil and M.Effects.Totals(citizenId) or M.Effects.Totals(nil)
	local empty = totals.armor == 0 and totals.healthMax == 0 and totals.healthRegen == 0
		and totals.staminaMax == 0 and totals.staminaRegen == 0 and not totals.noFall
	if st == nil then
		if empty then return end
		st = { citizen = citizenId, base = {}, applied = {}, noFall = false, damagedAt = 0 }
		state[player] = st
	end

	local stats = statsOf(player)
	if stats ~= nil and type(Open77.stats) == 'table' then
		composePool(player, st, 'health', stats.health, totals.healthMax, totals.healthRegen)
		composePool(player, st, 'stamina', stats.stamina, totals.staminaMax, totals.staminaRegen)
	end

	-- NO FALL DAMAGE is a life bit that death clears, so it is asserted every
	-- pass while wanted and given back exactly once when not.
	local players = Open77.players
	if totals.noFall then
		local enabled = true
		if type(players.isFallDamageEnabled) == 'function' then
			local ran, answer = pcall(players.isFallDamageEnabled, player)
			enabled = not ran or answer ~= false
		end
		if enabled or not st.noFall then
			if call(st, 'setFallDamage', players.setFallDamage, player, false) then st.noFall = true end
		end
	elseif st.noFall then
		call(st, 'setFallDamage', players.setFallDamage, player, true)
		st.noFall = false
	end

	-- A RATING THAT FELL -- a plate pulled, failing or broken -- takes what it
	-- no longer backs off the body: the difference, and never armor some
	-- other source put there.
	local armorNow = stats ~= nil and (tonumber(stats.armor) or 0) or nil
	local rated = tonumber(st.applied.armor)
	if rated ~= nil and totals.armor < rated and armorNow ~= nil and armorNow > 0 then
		local after = math.max(0, armorNow - (rated - totals.armor))
		if call(st, 'setArmor', players.setArmor, player, after) then armorNow = after end
	end
	st.applied.armor = totals.armor > 0 and totals.armor or nil

	-- THE PLATING recharges toward its rating once the body is unhurt.
	if totals.armor > 0 and stats ~= nil then
		local policy = M.Effects.Policy()
		local current = armorNow or 0
		if current < totals.armor and OPX.Now() - (st.damagedAt or 0) >= policy.ARMOR_DELAY_MS then
			local step = math.max(1, math.floor(totals.armor * policy.ARMOR_RECHARGE
				* math.max(0, dtSeconds or 0) + 0.5))
			call(st, 'setArmor', players.setArmor, player, math.min(totals.armor, current + step))
		end
	end

	-- WHAT THE BODY CARRIES, journalled when it changes: the one line that
	-- says whether a fitted piece is doing anything.
	local said = ('armor %d, max health +%d, health regen +%.1f/s, max stamina +%d, ' ..
		'stamina regen +%.1f/s, fall damage %s'):format(totals.armor, totals.healthMax,
		totals.healthRegen, totals.staminaMax, totals.staminaRegen, totals.noFall and 'off' or 'on')
	if st.said ~= said then
		st.said = said
		Open77.log.info(('[ripperdoc] player %d chrome on the body: %s'):format(player, said))
	end

	if empty and st.noFall == false and next(st.applied) == nil then
		state[player] = nil
	end
end

--- Notes a hit, so the plating waits before it recharges.
-- @param player number
function M.Effects.Damaged(player)
	local st = state[player]
	if st ~= nil then st.damagedAt = OPX.Now() end
end

--- What one player's composition looks like now, for the diagnosis command.
-- @param player number
-- @return table|nil
function M.Effects.Snapshot(player)
	local st = state[player]
	if st == nil then return nil end
	return { citizen = st.citizen, base = st.base, applied = st.applied, noFall = st.noFall }
end

--- Asks for one player's numbers to be recomposed at the next pass.
-- @param player number
function M.Effects.Touch(player)
	if player ~= nil then urgent[player] = true end
end

--- One pass over every connected player.
-- @param dtSeconds number
local function pass(dtSeconds)
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	local seen = {}
	for _, raw in ipairs(ids) do
		local player = tonumber(raw)
		if player ~= nil then
			seen[player] = true
			local citizenId = M.Chrome.CitizenOf(player)
			if citizenId ~= nil or state[player] ~= nil then
				local ran, failure = pcall(M.Effects.Apply, player, citizenId, dtSeconds)
				if not ran then
					Open77.log.warn('[ripperdoc] the chrome pass raised: ' .. tostring(failure))
				end
			end
		end
	end
	for player in pairs(state) do
		if not seen[player] then state[player] = nil end
	end
	urgent = {}
end
M.Effects.Pass = pass

--- Starts the composer.
function M.Effects.Start()
	AddEventHandler('open77:playerDamaged', function(victim)
		local player = tonumber(victim)
		if player ~= nil then M.Effects.Damaged(player) end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then state[player], urgent[player] = nil, nil end
	end)
	-- A character put down on a connection that stays: its chrome comes off
	-- NOW, while the connection is still there to take it off.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(player)
		player = tonumber(player)
		if player ~= nil and state[player] ~= nil then
			pcall(M.Effects.Apply, player, nil, 0)
			state[player] = nil
		end
	end)
	AddEventHandler(M.Event.ON_CHANGED, function(payload)
		local citizen = type(payload) == 'table' and payload.citizen or nil
		local holder = citizen ~= nil and M.Chrome.Holders()[citizen] or nil
		if holder ~= nil then M.Effects.Touch(holder) end
	end)

	running = true
	CreateThread(function()
		local last = OPX.Now()
		while running do
			Wait(M.Effects.Policy().RECONCILE_MS)
			if not running then return end
			local now = OPX.Now()
			pass((now - last) / 1000)
			last = now
		end
	end)
end

--- Takes every player's chrome off and stops the composer: a resource that
--- stops must not leave bodies wearing numbers nobody will ever take back.
function M.Effects.Stop()
	running = false
	for player in pairs(state) do
		pcall(M.Effects.Apply, player, nil, 0)
	end
	state, urgent = {}, {}
end

--- Resets (a reload starts clean).
function M.Effects.Init()
	state, urgent = {}, {}
	running = false
end
