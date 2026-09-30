--- The hit relay: a player's shot at one of this module's bodies, admitted and priced.
-- @author XEROX710
--
-- WHY THIS FILE EXISTS. A police unit, a MaxTac trooper and a body of the test
-- crowd are NPCs the SERVER owns (`Open77.npcs.create`), and the platform does
-- not carry a player's shot at one of them to the server. The shooter's client
-- raises `open77:npcHit` for its own player and stops there -- `docs/combat.md`
-- calls the three NPC combat events "observations, not applications", and the
-- platform's own research (E6/F8) puts it in one line: "no client-side hit on an
-- NPC reaches the server today". A resource has to forward the report and apply
-- the damage itself, exactly as the platform's own deathmatch and cordon modes
-- do. This one did neither, so an officer stood at 100/100 for ever, nobody could
-- kill one server-side, `onNpcDied` never fired, and the murder call-out
-- (`HOMICIDE` in `config/ncpd.lua`) waited for a death no player could cause --
-- which is the whole of "I killed NCPD and nothing was called in".
--
-- THE CLIENT FORWARDS AND THE SERVER DECIDES. `client/hits.lua` sends one small
-- report per body per tenth of a second: the body's id, the engine's damage and
-- the absolute height of the intercept. This file is where it is admitted, and
-- what it will not take from the client is the point of it:
--
--   * THE BODY MUST BE OURS. A hit on an NPC some other resource owns is
--     answered `not_ours` and costs nothing; the two tables that placed a body
--     (the response's and the crowd's) are the only authority on whose it is, and
--     the platform refuses a resource's `applyDamage` on anything it does not own
--     anyway.
--   * THE NUMBER IS THE SERVER'S. The engine's damage is a hint, clamped into
--     `MIN_DAMAGE..MAX_DAMAGE` -- a gang record's rifle is priced for a levelled
--     solo player -- and a report with no usable number is worth
--     `FALLBACK_DAMAGE`. The body part is derived here, from the intercept's height
--     against the body's own canonical position; a client that named a body part
--     would be choosing its own headshot multiplier.
--   * THE SHOOTER MUST BE ABLE TO HAVE FIRED. A character loaded, alive, in the
--     body's own bucket and inside `MAX_RANGE_METRES`; no faster than
--     `MIN_INTERVAL_MS`; no more than `MAX_DPS` in a second.
--   * AN OFFICER DOES NOT SHOOT THE CITY'S OWN. An on-duty holder of the call-out's
--     jobs who hits a police unit is refused `friendly`; the same officer can still
--     shoot a suspect's crowd, and the kill is not charged (`EXEMPT_ON_DUTY`).
--
-- THE DEATH IS NOT ASSUMED. `Open77.npcs.applyDamage` is documented to raise
-- `onNpcDied` when the health reaches zero, and `server/main.lua` charges the kill
-- from that event. A hit that looked lethal is nevertheless checked again
-- `DEATH_CHECK_MS` later, and a body that is dead with no event heard is booked
-- from its own health -- a missing event must not be a murder nobody was told
-- about, and the one door (`deps.died`) is idempotent, so a late real event and
-- the check cannot charge one body twice.
--
-- EVERYTHING IS COUNTED AND MOST OF IT IS SAID. `Hits.Status()` is what the
-- status command prints; a refusal is journalled once per reason every ten
-- seconds (the ordinary `not_ours` is only counted), so a relay that admits
-- nothing says why in the log instead of looking like a quiet street.

local M = OPX.Modules.Get('ncpd')

--- The shipped knobs. `HITS` in `config/ncpd.lua` wins per field when the value
--- is usable (see `Hits.Knobs`).
M.Hits = {
	MIN_DAMAGE = 12.0,
	MAX_DAMAGE = 60.0,
	FALLBACK_DAMAGE = 34.0,
	HEAD_METRES = 1.55,
	HEADSHOT = 2.0,
	MAX_RANGE_METRES = 120.0,
	MIN_INTERVAL_MS = 45,
	MAX_DPS = 480.0,
	DEATH_CHECK_MS = 900,
}
local Hits = M.Hits

--- The number knobs and the range each one means, so a typo cannot turn the relay
--- into a wall (a negative interval) or a laser (a million damage a hit).
local RANGES = {
	MIN_DAMAGE = { 0.1, 1000.0 },
	MAX_DAMAGE = { 0.1, 1000.0 },
	FALLBACK_DAMAGE = { 0.1, 1000.0 },
	HEAD_METRES = { 0.1, 3.0 },
	HEADSHOT = { 1.0, 10.0 },
	MAX_RANGE_METRES = { 1.0, 1000.0 },
	MIN_INTERVAL_MS = { 0, 5000 },
	MAX_DPS = { 1.0, 100000.0 },
	DEATH_CHECK_MS = { 0, 60000 },
}

--- The dependencies `server/main.lua` hands over when it starts the relay: the
--- character and position reads it already owns, the duty rule, the two tables
--- that know whose a body is, and the one door a death is booked through.
local env = nil

--- One row per shooter: when their last hit was accepted, and the second-long
--- window their damage is summed over.
local shooters = {}

local counters = { seen = 0, applied = 0, lethal = 0, booked = 0 }
local refusals = {}

--- When each refusal reason was last written to the journal.
local journaled = {}

--- When each body's `onNpcDied` was last heard, by id as text.
local heardDead = {}

--- When a hit's acceptance was last written to the journal, per shooter.
local spoke = {}

--- Bumped by `Stop`, so a death check scheduled by a stopped relay stands down.
local ticket = 0

--- Whether the two event handlers are subscribed: `M.Start` runs again on a
--- module restart and a second pair would admit every hit twice.
local subscribed = false

--- A finite number, or nil.
-- @param value any
-- @return number|nil
local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return number
end

--- The knobs as the config declares them, each field falling back to the shipped
--- one rather than trusting a shape. `HITS = false` or `enabled = false` answers
--- nil: an operator who switched the relay off means it.
-- @return table|nil
function Hits.Knobs()
	-- NOT `... and M.Settings.HITS or nil`: that idiom swallows `false`.
	local raw = nil
	if type(M.Settings) == 'table' then raw = M.Settings.HITS end
	if raw == false then return nil end
	if type(raw) == 'table' and raw.enabled == false then return nil end

	local knobs = {}
	for name in pairs(RANGES) do knobs[name] = Hits[name] end
	if type(raw) ~= 'table' then return knobs end

	for name, range in pairs(RANGES) do
		local value = finite(raw[name])
		if value ~= nil and value >= range[1] and value <= range[2] then knobs[name] = value end
	end
	if knobs.MIN_DAMAGE > knobs.MAX_DAMAGE then knobs.MIN_DAMAGE = knobs.MAX_DAMAGE end
	if knobs.FALLBACK_DAMAGE < knobs.MIN_DAMAGE then knobs.FALLBACK_DAMAGE = knobs.MIN_DAMAGE end
	if knobs.FALLBACK_DAMAGE > knobs.MAX_DAMAGE then knobs.FALLBACK_DAMAGE = knobs.MAX_DAMAGE end
	return knobs
end

--- An NPC id as text, or nil when it cannot be one. The platform's ids are 64-bit
--- and cross the wire as decimal strings; nothing here runs them through a float.
-- @param raw any
-- @return string|nil
local function keyOf(raw)
	if type(raw) == 'number' then
		local whole = math.tointeger(raw)
		if whole == nil or whole <= 0 then return nil end
		return tostring(whole)
	end
	if type(raw) ~= 'string' then return nil end
	if #raw < 1 or #raw > 32 or raw:find('[^%w_%-]') ~= nil then return nil end
	return raw
end

--- A point as `{ x, y, z }` from either shape the host answers in -- flat fields or
--- a `position` table -- or nil.
-- @param value any
-- @return table|nil
local function pointOf(value)
	if type(value) ~= 'table' then return nil end
	local at = type(value.position) == 'table' and value.position or value
	local x, y, z = finite(at.x), finite(at.y), finite(at.z)
	if x == nil or y == nil then return nil end
	return { x = x, y = y, z = z or 0.0 }
end

--- Counts a refusal, and says it once per reason every ten seconds. `not_ours` is
--- the ordinary answer for every NPC some other resource owns and is only counted.
-- @param playerId any
-- @param reason string
-- @param detail any
-- @return boolean false
-- @return string reason
local function refuse(playerId, reason, detail)
	refusals[reason] = (refusals[reason] or 0) + 1
	if reason == 'not_ours' then return false, reason end
	local now = OPX.Now()
	local last = journaled[reason]
	if last == nil or now - last >= 10000 then
		journaled[reason] = now
		Open77.log.info(('[ncpd] npc hit refused (%s): player %s, %s')
			:format(reason, tostring(playerId), tostring(detail)))
	end
	return false, reason
end

--- The body's snapshot, or nil.
-- @param id any the id as the module that placed it holds it
-- @return table|nil
local function snapshotOf(id)
	local npcs = Open77 and Open77.npcs
	if type(npcs) ~= 'table' or type(npcs.get) ~= 'function' then return nil end
	local read, snapshot = pcall(npcs.get, id)
	if not read or type(snapshot) ~= 'table' then return nil end
	return snapshot
end

--- Whether the host says this player is dead. An unreadable answer is "not dead":
--- a relay that refused every shot when the life read failed would be a wall.
-- @param playerId number
-- @return boolean
local function isDead(playerId)
	local players = Open77 and Open77.players
	if type(players) ~= 'table' or type(players.isDead) ~= 'function' then return false end
	local read, dead = pcall(players.isDead, playerId)
	return read and dead == true
end

--- Books a body's death from its own health, when the platform said nothing.
-- @param key string
-- @param id any
-- @param playerId number
-- @param hitAt integer when the lethal-looking hit was accepted
local function checkDeath(key, id, playerId, hitAt)
	if env == nil then return end
	local heard = heardDead[key]
	if heard ~= nil and heard >= hitAt then return end

	local after = snapshotOf(id)
	local health = after ~= nil and finite(after.health) or nil
	-- A body that is gone from the platform's own list, or whose health has
	-- reached zero, is dead; one still standing on health is not.
	if after ~= nil and (health == nil or health > 0) then return end

	counters.booked = counters.booked + 1
	Open77.log.info(('[ncpd] npc %s died from a hit relayed for player %d, and the platform raised no ' ..
		'onNpcDied: booked from its health'):format(key, playerId))
	local ran, failure = pcall(env.died, id, 'player:' .. tostring(playerId), 'firearm')
	if not ran then
		Open77.log.error('[ncpd] a relayed kill could not be booked: ' .. tostring(failure))
	end
end

--- Admits one report, prices it and applies it. Called by the net handler with the
--- connection the report arrived on, and by tests with anything at all.
-- @param playerId number the shooter, from the connection and never the payload
-- @param payload table `{ npcId, damage, hitZ, weapon, seq }`
-- @return boolean whether the damage was applied
-- @return string|table|nil the refusal reason, or `{ npcId, amount, head, health }`
function Hits.Relay(playerId, payload)
	counters.seen = counters.seen + 1

	local knobs = Hits.Knobs()
	if knobs == nil then return refuse(playerId, 'off', 'HITS is off') end
	if env == nil then return refuse(playerId, 'not_started', 'the module is stopped') end
	if type(playerId) ~= 'number' or playerId ~= math.floor(playerId) or playerId <= 0 then
		return refuse(playerId, 'no_player', 'no connection')
	end
	if type(payload) ~= 'table' then return refuse(playerId, 'malformed', type(payload)) end

	local key = keyOf(payload.npcId)
	if key == nil then return refuse(playerId, 'bad_id', tostring(payload.npcId)) end

	-- WHOSE BODY. The id as the module that placed it holds it goes to every host
	-- call below, never the client's spelling of it.
	local id, kind = env.resolve(key)
	if id == nil then return refuse(playerId, 'not_ours', key) end

	local data = env.characterOf(playerId)
	if data == nil then return refuse(playerId, 'no_character', key) end
	if kind == 'police' and env.onCall(data) then return refuse(playerId, 'friendly', key) end
	if isDead(playerId) then return refuse(playerId, 'shooter_dead', key) end

	-- CADENCE FIRST: the cheapest gate, and the one a flood meets.
	local now = OPX.Now()
	local state = shooters[playerId]
	if state == nil then
		state = { at = -math.huge, windowAt = now, windowDamage = 0.0 }
		shooters[playerId] = state
	end
	if now - state.at < knobs.MIN_INTERVAL_MS then return refuse(playerId, 'cadence', key) end

	local snapshot = snapshotOf(id)
	if snapshot == nil then return refuse(playerId, 'unknown_npc', key) end
	local health = finite(snapshot.health)
	if health ~= nil and health <= 0 then return refuse(playerId, 'dead_npc', key) end

	local body = pointOf(snapshot)
	local shooter = env.positionOf(playerId)
	if body == nil or shooter == nil then return refuse(playerId, 'position_unknown', key) end
	if (tonumber(snapshot.bucket) or 0) ~= (tonumber(shooter.bucket) or 0) then
		return refuse(playerId, 'bucket_mismatch', key)
	end
	local dx, dy, dz = shooter.x - body.x, shooter.y - body.y, shooter.z - body.z
	local range = math.sqrt(dx * dx + dy * dy + dz * dz)
	if range > knobs.MAX_RANGE_METRES then
		return refuse(playerId, 'range', ('%.0f m from body %s'):format(range, key))
	end

	-- THE NUMBER. The engine's damage is a hint clamped into the knobs' range; the
	-- head is the intercept's height over the body's own feet.
	local reported = finite(payload.damage)
	local amount = knobs.FALLBACK_DAMAGE
	if reported ~= nil and reported > 0 then
		amount = math.max(knobs.MIN_DAMAGE, math.min(knobs.MAX_DAMAGE, reported))
	end
	local intercept = finite(payload.hitZ)
	local head = intercept ~= nil and intercept - body.z >= knobs.HEAD_METRES
	if head then amount = amount * knobs.HEADSHOT end

	if now - state.windowAt >= 1000 then
		state.windowAt = now
		state.windowDamage = 0.0
	end
	if state.windowDamage + amount > knobs.MAX_DPS then return refuse(playerId, 'dps_cap', key) end

	local npcs = Open77 and Open77.npcs
	if type(npcs) ~= 'table' or type(npcs.applyDamage) ~= 'function' then
		return refuse(playerId, 'no_contract', 'Open77.npcs.applyDamage')
	end
	local called, accepted, why = pcall(npcs.applyDamage, id, amount, 'player:' .. tostring(playerId), 'firearm')
	if not called then
		Open77.log.error(('[ncpd] applyDamage raised for npc %s: %s'):format(key, tostring(accepted)))
		return refuse(playerId, 'apply_raised', key)
	end
	if accepted ~= true then return refuse(playerId, 'apply_refused', tostring(why or accepted)) end

	state.at = now
	state.windowDamage = state.windowDamage + amount
	counters.applied = counters.applied + 1

	local remaining = health ~= nil and health - amount or nil
	local lethal = remaining ~= nil and remaining <= 0
	if lethal then counters.lethal = counters.lethal + 1 end

	-- Said once a second and a half per shooter, and always for the hit that ends
	-- a body: a burst is not a log line per bullet, a kill is.
	local said = spoke[playerId]
	if lethal or said == nil or now - said >= 1500 then
		spoke[playerId] = now
		Open77.log.info(('[ncpd] player %d hit npc %s (%s) for %.0f%s%s'):format(playerId, key, kind,
			amount, head and ' (head)' or '',
			remaining ~= nil and (', health %.0f'):format(math.max(0, remaining)) or ''))
	end

	if lethal and knobs.DEATH_CHECK_MS > 0 then
		local mine = ticket
		CreateThread(function()
			Wait(math.floor(knobs.DEATH_CHECK_MS))
			if mine ~= ticket then return end
			local ran, failure = pcall(checkDeath, key, id, playerId, now)
			if not ran then
				Open77.log.error('[ncpd] a relayed death check failed: ' .. tostring(failure))
			end
		end)
	end

	return true, nil, { npcId = key, amount = amount, head = head, health = remaining }
end

--- What the relay has done, for the status command and the tests.
-- @return table `{ seen, applied, lethal, booked, refused }`
function Hits.Status()
	local refused = {}
	for reason, count in pairs(refusals) do refused[reason] = count end
	return {
		seen = counters.seen, applied = counters.applied, lethal = counters.lethal,
		booked = counters.booked, refused = refused,
	}
end

--- Starts the relay. `deps` is `{ characterOf, positionOf, onCall, resolve, died }`.
-- @param deps table
function Hits.Start(deps)
	env = deps
	ticket = ticket + 1
	if subscribed then return end
	subscribed = true

	-- No `source` parameter: the sender is the host's `source` global, and a
	-- parameter of that name shadows it with the empty payload.
	RegisterNetEvent(M.Event.NPC_HIT, function(payload)
		local playerId = tonumber(source)
		local ran, failure = pcall(Hits.Relay, playerId, payload)
		if not ran then
			Open77.log.error('[ncpd] an npc hit could not be read: ' .. tostring(failure))
		end
	end)

	-- Who the platform itself reported dead, so the check above only books a body
	-- nobody was told about.
	AddEventHandler('onNpcDied', function(npcId)
		local now = OPX.Now()
		heardDead[tostring(npcId)] = now
		for key, when in pairs(heardDead) do
			if now - when >= 60000 then heardDead[key] = nil end
		end
	end)
end

--- Stops the relay: a report that arrives afterwards is refused, and a death check
--- already scheduled stands down.
function Hits.Stop()
	env = nil
	ticket = ticket + 1
	shooters = {}
	spoke = {}
	heardDead = {}
end
