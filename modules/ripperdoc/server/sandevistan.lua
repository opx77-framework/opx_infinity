--- The Sandevistan on the body: the look the players around a boosted player
-- see, and a power that went missing on the player's own machine.
-- @author XEROX710
--
-- WHAT A SANDEVISTAN IS HERE. `open77_reflex` makes the owner's body faster --
-- speed, attack speed, reload, evasion -- and changes no clock: in a shared
-- world nobody else can be slowed (`wiki/reflex-overdrive.md`). So everything
-- the OTHER players get of a Sandevistan is what the boosted body looks like,
-- and the platform's own answer is an Open77 picture: a blue glow, sparks at
-- the feet, the Berserk's two sounds.
--
-- A PIECE WITH A LOOK (`SANDEVISTAN.LOOK` in `config/ripperdoc.lua`, the
-- Militech Apogee out of the box) is registered with `presentation = 'none'`
-- instead, so the platform draws nothing, and this file draws the look: on
-- every phase of `onReflexChanged` for a player whose armed overdrive is that
-- piece, one event to every client (`M.Event.SANDY`) naming whose body, which
-- phase, which look and how long the boost has left. Each client plays the
-- look's authored effects on that body for exactly that long and stops them
-- on the terminal phase (`client/sandevistan.lua`), because a client-owned
-- handle is the only one that can be stopped: the server's `playOn` is
-- fire-and-forget and would keep an afterimage on a body that had already
-- been cancelled -- by a death, a car door or a staff `cancel`.
--
-- THE WORLD AROUND IT SLOWS. A slowdown is a per-client simulation rate, so
-- every player within the look's `TIME.RADIUS` (same bucket, alive) is told
-- to run their own clock at `TIME.NEARBY_SCALE` for what is left of the boost,
-- and handed it back when they walk out past 1.25 x the radius or the boost
-- ends (`slowAround`, re-read every half second). Each slow and each release
-- is a journal line with the distance; each slowed client reports back what
-- its engine really runs at (role `slowed`), and a boost that slows nobody
-- names the nearest player and how far off they stood.
--
-- The sound is the one part the SERVER plays, positioned on the body through
-- `Open77.effects.sound`, so a player next to the user hears where it came
-- from, deduplicated per activation by the sound service's own `actionId`.
--
-- A POWER THAT WENT MISSING. The platform re-projects nothing on its own: a
-- client that dropped its projection -- a body it could not use, a restart of
-- `open77_reflex` -- keeps a dead key while the server reads `ready`. The
-- player's machine can see that (`open77_reflex`'s own `capabilities`
-- export answers `projection = "absent"`) and asks once; `Recover` projects
-- the overdrive again, at most once per `RECOVER.AFTER_MS` and never inside
-- the cooldown of its last use, so asking cannot be a way to skip one.
--
-- THE BOOST GROWS WITH THE CHARACTER (`M.Ripper.SandyBoostMs`). At the
-- `active` phase the look and the time run for the level-scaled boost: the
-- platform's own remaining time plus what the level adds. The platform's
-- overdrive -- its speed, capped at 15 s by its own client -- still ends when
-- its definition says, so its `completed` arrives first; the ripperdoc's boost
-- goes on to its own deadline (a platform `cancelled` still ends it, and so
-- does the owner's death). The platform starts its cooldown when ITS overdrive
-- ends, which is too early, so the reflex grant is HELD BACK from that moment
-- (`M.Chrome.HoldBack`: revoked, and re-armed by nothing) until the
-- ripperdoc's boost is over and `cooldownMs` more has passed. An activation
-- that still lands inside that window is journalled and never redrawn.

local M = OPX.Modules.Get('ripperdoc')

M.Sandy = {}

-- player -> { activation, look, expires, ... } while a styled boost runs: `real`
-- for an overdrive (not a test), `entryId`, `extendMs` (what the level adds to
-- the platform's boost), `cooldownMs`, `platformDone` once the platform's own
-- overdrive completed and the ripperdoc's goes on
local active = {}
-- player -> { at, cooldownMs }: from the last accepted activation -- and, once
-- a boost ends, from its end -- for Recover
local lastUse = {}
-- player -> when a recovery was last granted
local recovered = {}
-- player -> { entry, activation, since, releaseAt }: a reflex grant held back
-- until the ripperdoc's own boost has ended and its cooldown passed
local holds = {}
-- player -> activation id: the last racing activation journalled, so a race
-- is said once, not once per phase
local raced = {}
-- Whether the sound door was found missing (said once)
local warnedSound = false
-- The deadline watch's run flag, so Stop ends it.
local watching = false

-- THE CLIENTS' CEILING ON ONE BOOST: a level-scaled boost of up to 44 s
-- (`M.Ripper.SANDY_MAX_SECONDS`) plus the 250 ms delivery margin every boost
-- carries, inside the 45 s opx_sandy_view 1.4.9 holds the owner's clock for.
-- `client/sandevistan.lua` holds the same number.
local CAP_MS = 45000
M.Sandy.CAP_MS = CAP_MS

-- How much longer than the platform's overdrive a boost must run before the
-- grant is held back for it. At level 1 the ripperdoc's boost IS the
-- platform's (plus its delivery margin), and the platform's own cooldown is
-- the boost's: nothing is held, and the platform's `completed` ends it.
local HOLD_SLACK_MS = 1000

-- Defined below, used above it.
local slowAround

--- The JSON decoder the reflex events arrive through, or nil.
-- @param encoded any
-- @return table|nil
local function decode(encoded)
	if type(encoded) == 'table' then return encoded end
	if type(json) == 'table' and type(json.decode) == 'function' then
		local ran, result = pcall(json.decode, tostring(encoded or ''))
		if ran and type(result) == 'table' then return result end
	end
	return nil
end

--- The recovery policy. Never nil.
-- @return table { AFTER_MS }
local function recoverPolicy()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local recover = type(sandy.RECOVER) == 'table' and sandy.RECOVER or {}
	return { AFTER_MS = math.max(5000, math.floor(tonumber(recover.AFTER_MS) or 15000)) }
end

--- The config the player's armed overdrive was granted with -- the
--- DEFINITION's, which is not always the grade's own: past the platform's
--- definition limit a grade is served by the nearest kept config, and that one
--- is what the platform really runs. Never nil.
-- @param player number
-- @param entry table
-- @return table
local function configOf(player, entry)
	local definitionId = M.Chrome.ArmedDefinition(player, entry.id)
	if definitionId ~= nil then
		for _, def in ipairs(M.Ripper.GrantPlan().defs) do
			if def.id == definitionId and type(def.config) == 'table' then return def.config end
		end
	end
	local citizenId = M.Chrome.CitizenOf(player)
	local grade = M.Ripper.Grade(entry, M.Chrome.Row(citizenId, entry.id).grade)
	return grade ~= nil and M.Ripper.GrantConfig(entry, grade) or {}
end

--- The cooldown the player's armed overdrive runs on, in ms.
-- @param player number
-- @param entry table
-- @return number
local function cooldownOf(player, entry)
	return math.max(0, tonumber(configOf(player, entry).cooldownMs) or 0)
end

--- How long this player's boost runs: the level-scaled time for the grade
--- they wear, from the platform's own duration at level 1
--- (`M.Ripper.SandyBoostMs`).
-- @param player number
-- @param entry table
-- @return integer ms the boost
-- @return integer ms the platform's own (what level 1 runs)
-- @return number level
-- @return number cap
local function boostMs(player, entry)
	local citizenId = M.Chrome.CitizenOf(player)
	local level, cap = M.Ripper.LevelOf(citizenId)
	local base = math.max(500, tonumber(configOf(player, entry).durationMs) or 6000)
	local grade = M.Ripper.Grade(entry, M.Chrome.Row(citizenId, entry.id).grade)
	local tier = grade ~= nil and grade.TIER or entry.TIER or 1
	return M.Ripper.SandyBoostMs(tier, base, level, cap), base, level, cap
end
M.Sandy.BoostMs = boostMs

--- One positioned sound on the boosted body, once per activation.
-- @param player number
-- @param event string|nil
-- @param activation string
local function sound(player, event, activation)
	if type(event) ~= 'string' or event == '' then return end
	local effects = type(Open77) == 'table' and Open77.effects or nil
	if type(effects) ~= 'table' or type(effects.sound) ~= 'function' then
		if not warnedSound then
			warnedSound = true
			Open77.log.warn('[ripperdoc] no Open77.effects.sound on this host: the Sandevistan plays silent')
		end
		return
	end
	local ran, ok, why = pcall(effects.sound, { kind = 'player', id = tostring(player) }, event,
		{ duration = 3, actionId = 'opx-sandy:' .. tostring(activation) })
	if not ran or ok == false or ok == nil then
		Open77.log.warn(('[ripperdoc] the Sandevistan sound %s was refused: %s')
			:format(event, tostring((ran and why) or ok)))
	end
end

--- Tells every client about one phase of one styled boost.
-- @param payload table
local function broadcast(payload)
	local ran, failure = pcall(TriggerClientEvent, M.Event.SANDY, -1, payload)
	if not ran then
		Open77.log.warn('[ripperdoc] the Sandevistan look did not go out: ' .. tostring(failure))
	end
end

--- Tells one client about a phase that is theirs alone (a slowdown).
-- @param target number
-- @param payload table
local function tell(target, payload)
	pcall(TriggerClientEvent, M.Event.SANDY, target, payload)
end

--- A player's position and bucket, or nil.
-- @param player number
-- @return table|nil
local function positionOf(player)
	local api = type(Open77) == 'table' and Open77.players or nil
	if api == nil or type(api.position) ~= 'function' then return nil end
	local ran, position = pcall(api.position, player)
	if not ran or type(position) ~= 'table' or tonumber(position.x) == nil then return nil end
	return position
end

--- The look's time block, with every number bounded. Never nil.
-- @param look table
-- @return table { SELF_SCALE, SELF_FALLBACK_SCALE, NEARBY_SCALE, RADIUS, EASE_MS }
local function timeOf(look)
	local time = type(look.TIME) == 'table' and look.TIME or {}
	local function scale(value, fallback)
		value = tonumber(value)
		if value == nil or value ~= value then return fallback end
		return math.max(0.05, math.min(1, value))
	end
	local selfScale = scale(time.SELF_SCALE, 1)
	return {
		SELF_SCALE = selfScale,
		SELF_FALLBACK_SCALE = scale(time.SELF_FALLBACK_SCALE, 1),
		NEARBY_SCALE = scale(time.NEARBY_SCALE, selfScale),
		RADIUS = math.max(0, math.min(100, tonumber(time.RADIUS) or 0)),
		EASE_MS = math.max(0, math.min(2000, math.floor(tonumber(time.EASE_MS) or 250))),
	}
end

--- Whether the base game's own Sandevistan screen ships with this world: the
--- VIEW resource (`extras/opx_sandy_view`) is running here, so every player
--- joined with its REDscript installed (a required mod is installed before the
--- game boots, or the join is refused).
-- @return boolean
local function viewReady()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local name = type(sandy.VIEW) == 'table' and sandy.VIEW.RESOURCE or nil
	if type(name) ~= 'string' or name == '' or type(GetResourceState) ~= 'function' then return false end
	local ran, state = pcall(GetResourceState, name)
	return ran and state == 'running'
end
M.Sandy.ViewReady = viewReady

--- The players close enough to a boosted body to be slowed by it: same
--- bucket, within the look's radius, alive. The owner is never one. Also
--- answers how far every other live player of that bucket stands (the
--- journal names the nearest when nobody is in range), and whether the
--- boosted body itself has a position at all.
-- @param player number
-- @param radius number
-- @return table array of player ids
-- @return table player id -> metres
-- @return boolean whether the boosted player has a position
local function nearby(player, radius)
	if radius <= 0 then return {}, {}, true, {} end
	local origin = positionOf(player)
	if origin == nil then return {}, {}, false, {} end
	local api = Open77.players
	local read, ids = pcall(api.all)
	local out, distances, seatedSet = {}, {}, {}
	for _, raw in ipairs(read and type(ids) == 'table' and ids or {}) do
		local other = tonumber(raw)
		if other ~= nil and other ~= player then
			local at = positionOf(other)
			local dead = false
			if type(api.isDead) == 'function' then
				local asked, answer = pcall(api.isDead, other)
				dead = asked and answer == true
			end
			-- A SEATED PLAYER IS NEVER SLOWED. Their client is simulating the
			-- vehicle they sit in (the platform's physics owner), and a slowed
			-- clock is a slowed aircraft or car that every other player watches
			-- crawl and then lurch: measured 2026-09-28 23:45:12, a pilot 11 s
			-- into a MaxTac AV flight had their world put at 0.15 for 21 s by a
			-- boost nearby, and the owner reported the AV "moving around" and
			-- "disappearing on other player screen". The boost still shows on
			-- them; their clock is left alone. Leaving the seat puts them back in
			-- range on the next sweep.
			local seated = false
			local vehicles = Open77.vehicles
			if type(vehicles) == 'table' and type(vehicles.getPlayerSeat) == 'function' then
				local asked, seat = pcall(vehicles.getPlayerSeat, other)
				seated = asked and type(seat) == 'table' and seat.vehicleId ~= nil
			end
			if seated then seatedSet[other] = true end
			if at ~= nil and not dead and not seated
				and (tonumber(at.bucket) or 0) == (tonumber(origin.bucket) or 0) then
				local dx, dy, dz = at.x - origin.x, at.y - origin.y, (at.z or 0) - (origin.z or 0)
				local squared = dx * dx + dy * dy + dz * dz
				distances[other] = math.sqrt(squared)
				if squared <= radius * radius then out[#out + 1] = other end
			end
		end
	end
	return out, distances, true, seatedSet
end

--- The nearest other player in `distances`, as words for the journal.
-- @param distances table player id -> metres
-- @return string
local function nearestText(distances)
	local who, best = nil, nil
	for other, metres in pairs(distances) do
		if best == nil or metres < best or (metres == best and other < who) then who, best = other, metres end
	end
	if who == nil then return 'no other live player in this bucket has a position' end
	return ('nearest: player %d at %.1f m'):format(who, best)
end

--- A look's optional SERVER-bound layers (`ATTACH`), on the boosted body for
--- everybody in range. The `smasher` look carries none: every client binds
--- its layers itself (`client/sandevistan.lua`), because only a client knows
--- the slot names of the body it draws on and can restart a two-second trail.
--- The look's ATTACH layers for the boost's tier, each a cooked `.effect` bound to
--- a body slot by the platform's durable attachment (streamed, leased, and
--- removed with the boost). Answers the handles it got.
-- @param player number
-- @param look table
-- @param tier string
-- @param ttlMs number
-- @return table handles
local function attach(player, look, tier, ttlMs)
	local effects = type(Open77) == 'table' and Open77.effects or nil
	local layers = type(look.ATTACH) == 'table' and (look.ATTACH[tier] or look.ATTACH.reflex_heavy) or nil
	local handles = {}
	if type(effects) ~= 'table' or type(effects.attach) ~= 'function' or type(layers) ~= 'table' then
		return handles
	end
	for _, layer in ipairs(layers) do
		if type(layer) == 'table' and type(layer.effect) == 'string' and type(layer.slot) == 'string' then
			local ran, handle, why = pcall(effects.attach, { kind = 'player', id = tostring(player) },
				layer.effect, { slot = layer.slot, ttlMs = ttlMs, streamingRadius = 90,
					streamingHysteresis = 20 })
			if ran and handle ~= nil and handle ~= false then
				handles[#handles + 1] = handle
			else
				Open77.log.warn(('[ripperdoc] the Sandevistan layer %s on %s was refused: %s')
					:format(layer.effect, layer.slot, tostring((ran and why) or handle)))
			end
		end
	end
	return handles
end

--- One short burst on the body (the look's BURST.START or BURST.END): a
--- cooked `.effect` bound to a slot for its own few hundred milliseconds. The
--- lease ends it; nothing is kept.
-- @param player number
-- @param layer table|nil { effect, slot, ms }
local function burst(player, layer)
	local effects = type(Open77) == 'table' and Open77.effects or nil
	if type(layer) ~= 'table' or type(layer.effect) ~= 'string' or type(layer.slot) ~= 'string'
		or type(effects) ~= 'table' or type(effects.attach) ~= 'function' then
		return
	end
	local ttl = math.max(100, math.min(5000, math.floor(tonumber(layer.ms) or 1000)))
	pcall(effects.attach, { kind = 'player', id = tostring(player) }, layer.effect,
		{ slot = layer.slot, ttlMs = ttl, streamingRadius = 90, streamingHysteresis = 20 })
end

--- Ends one styled boost everywhere: the attached layers come off, every
--- player it slowed gets their clock back, and every client takes the look down.
-- @param player number
-- @param phase string `completed` or `cancelled`
-- @param activation string
local function finish(player, phase, activation)
	local row = active[player]
	active[player] = nil
	-- THE COOLDOWN RUNS FROM HERE, the end of the ripperdoc's own boost: what
	-- Recover measures, and when a grant held back for it comes back.
	if row ~= nil and row.real then
		local now = OPX.Now()
		lastUse[player] = { at = now, cooldownMs = row.cooldownMs or 0 }
		local hold = holds[player]
		if hold ~= nil and hold.releaseAt == nil and hold.activation == row.activation then
			hold.releaseAt = now + (row.cooldownMs or 0)
			Open77.log.info(('[ripperdoc] player %d: the Sandevistan is over (%s); its %s grant comes back ' ..
				'after the %d ms cooldown'):format(player, tostring(phase), tostring(hold.entry),
				math.floor(row.cooldownMs or 0)))
		end
	end
	local effects = type(Open77) == 'table' and Open77.effects or nil
	for _, handle in ipairs(row ~= nil and row.handles or {}) do
		if type(effects) == 'table' and type(effects.remove) == 'function' then
			pcall(effects.remove, handle)
		end
	end
	for other in pairs(row ~= nil and row.slowed or {}) do
		tell(other, { player = player, phase = 'release', activation = activation })
		Open77.log.info(('[ripperdoc] player %d: Sandevistan no longer slows player %d (the boost %s)'):format(player,
			other, tostring(phase)))
	end
	-- The end blink only for a boost that really reached the body.
	local look = row ~= nil and M.Settings.SANDEVISTAN ~= nil and type(M.Settings.SANDEVISTAN.LOOKS) == 'table'
		and M.Settings.SANDEVISTAN.LOOKS[row.look] or nil
	if type(look) == 'table' and type(look.BURST) == 'table' then burst(player, look.BURST.END) end
	broadcast({ player = player, phase = phase, activation = activation,
		look = row ~= nil and row.look or nil })
end

--- Brings one boost's slowdown in line with who is around it now: a player
--- inside RADIUS who is not slowed yet is told to slow for what is left of
--- the boost; a slowed player now past RADIUS x 1.25 (the margin keeps a
--- player on the edge from flickering) -- or dead, or gone -- is let go.
-- @param player number the boosted player
-- @param row table the boost
-- @return integer how many players the boost slows now
slowAround = function(player, row)
	local time = row.time or {}
	local radius = tonumber(time.RADIUS) or 0
	local remaining = math.floor(row.expires - OPX.Now())
	local count = 0
	local distances, placed, seatedSet = {}, true, {}
	if radius > 0 and remaining >= 250 then
		local inside
		inside, distances, placed, seatedSet = nearby(player, radius)
		for _, other in ipairs(inside) do
			if not row.slowed[other] then
				row.slowed[other] = true
				tell(other, { player = player, phase = 'slow', activation = row.activation,
					scale = time.NEARBY_SCALE, remainingMs = remaining, easeMs = time.EASE_MS })
				-- THE JOURNAL: every player a boost slows, and how far off they stood.
				Open77.log.info(('[ripperdoc] player %d: Sandevistan slows player %d (%.1f m away) to %.2f for %d ms')
					:format(player, other, distances[other] or -1, tonumber(time.NEARBY_SCALE) or -1, remaining))
			end
		end
	end
	local keep = {}
	for _, other in ipairs(radius > 0 and remaining >= 250 and nearby(player, radius * 1.25) or {}) do
		keep[other] = true
	end
	for other in pairs(row.slowed) do
		if keep[other] then
			count = count + 1
		else
			row.slowed[other] = nil
			tell(other, { player = player, phase = 'release', activation = row.activation })
			Open77.log.info(('[ripperdoc] player %d: Sandevistan no longer slows player %d (%s)'):format(player, other,
				remaining < 250 and 'the boost is ending'
					or distances[other] ~= nil and ('%.1f m away, past %.1f m'):format(distances[other], radius * 1.25)
					or seatedSet[other] and 'seated in a vehicle'
					or 'gone, dead or in another bucket'))
		end
	end
	row.nearest = count == 0 and (placed and nearestText(distances) or 'the boosted player has no position') or nil
	return count
end

--- One pass of the sweep: every running boost's slowdown, re-read.
function M.Sandy.Sweep()
	for player, row in pairs(active) do
		if OPX.Now() < row.expires then slowAround(player, row) end
	end
end

--- One phase of one styled boost: the look on every client, the layers on
--- the body, the clock of everybody near. `entry` is nil for a test boost.
-- @param player number
-- @param phase string
-- @param activation string
-- @param value table the phase record (tier, expiresAtMs, serverTimeMs)
-- @param look table
-- @param lookName string
-- @param entry table|nil
local function run(player, phase, activation, value, look, lookName, entry)
	local terminal = phase == 'completed' or phase == 'cancelled'
	if phase == 'accepted' then
		broadcast({ player = player, phase = 'accepted', activation = activation, look = lookName,
			tier = value.tier })
		sound(player, look.SOUND, activation)
		if type(look.BURST) == 'table' then burst(player, look.BURST.START) end
		return
	end
	if phase == 'active' then
		-- Remaining time read as a difference INSIDE one payload, so nothing
		-- assumes this VM's clock and the authority's agree.
		local remaining = (tonumber(value.expiresAtMs) or 0) - (tonumber(value.serverTimeMs) or 0)
		-- A payload without a deadline is held for the grade's own duration.
		if remaining <= 0 then
			remaining = entry ~= nil and tonumber(configOf(player, entry).durationMs) or 6000
		end
		-- THE LEVEL'S SHARE: what the character's level adds to the
		-- platform's own boost runs on top of it (nothing at level 1).
		local extend, level, cap = 0, 1, 1
		if entry ~= nil then
			local boost, base
			boost, base, level, cap = boostMs(player, entry)
			extend = math.max(0, boost - base)
		end
		remaining = math.max(500, math.min(CAP_MS, math.floor(remaining + extend + 250)))
		local tier = value.tier == 'reflex' and 'reflex' or 'reflex_heavy'
		local time = timeOf(look)
		-- A second `active` for the same boost is not a second boost.
		if active[player] ~= nil and active[player].activation == activation then return end
		if active[player] ~= nil then finish(player, 'cancelled', active[player].activation) end
		local row = { activation = activation, look = lookName, expires = OPX.Now() + remaining,
			handles = attach(player, look, tier, remaining), slowed = {}, time = time,
			real = entry ~= nil, entryId = entry ~= nil and entry.id or nil, extendMs = extend,
			cooldownMs = entry ~= nil and cooldownOf(player, entry) or 0, level = level, cap = cap }
		active[player] = row
		local view = viewReady()
		broadcast({ player = player, phase = 'active', activation = activation, look = lookName,
			tier = tier, remainingMs = remaining, scale = time.SELF_SCALE,
			fallbackScale = time.SELF_FALLBACK_SCALE, easeMs = time.EASE_MS, view = view })
		-- THE WORLD AROUND THEM SLOWS. A slowdown is a per-client simulation
		-- rate -- nobody can slow another machine -- so every player close
		-- enough is asked to run their own clock at the look's rate for as long
		-- as the boost lasts, and handed it back when it ends (`slowAround`,
		-- and again every half second by the sweep for whoever walks in or out).
		local count = slowAround(player, row)
		Open77.log.info(('[ripperdoc] player %d: Sandevistan (%s, %s) for %d ms, drawn by every client%s, ' ..
			'%d player(s) slowed nearby%s, base-game screen %s%s'):format(player, lookName, tier, remaining,
			#row.handles > 0 and (' + ' .. #row.handles .. ' server layer(s)') or '', count,
			count == 0 and row.nearest ~= nil and (' (within %d m; %s)'):format(math.floor(tonumber(time.RADIUS) or 0),
				row.nearest) or '',
			view and 'shipped' or 'not shipped (stand-in)',
			entry ~= nil and ('; level %d of %d adds %d ms to the platform\'s own'):format(math.floor(level),
				math.floor(cap), extend) or ''))
		return
	end
	-- Only the boost it names: a late end of an older boost (this file's own
	-- deadline, then the platform's) must not cut a newer one short.
	if terminal then M.Sandy.PlatformEnded(player, phase, activation) end
end

--- The platform says its overdrive is over. A boost the level lengthened
--- goes on to its own deadline when the platform merely COMPLETED -- and the
--- grant is held back from now until the boost is over and its cooldown has
--- passed, because the platform's own cooldown starts now; anything else ends
--- it here (a `cancelled`, a boost at the platform's own length, a deadline
--- that has come).
-- @param player number
-- @param phase string `completed` or `cancelled`
-- @param activation string
function M.Sandy.PlatformEnded(player, phase, activation)
	local row = active[player]
	if row ~= nil and row.activation ~= activation then return end
	local now = OPX.Now()
	if row ~= nil and phase == 'completed' and row.real and (row.extendMs or 0) > HOLD_SLACK_MS
		and row.expires - now > HOLD_SLACK_MS then
		if row.platformDone then return end
		row.platformDone = true
		local entry = M.Ripper.Entry(tostring(row.entryId))
		if entry ~= nil then
			M.Chrome.HoldBack(player, entry)
			holds[player] = { entry = entry.id, activation = activation, since = now }
		end
		Open77.log.info(('[ripperdoc] player %d: the platform\'s overdrive completed and the Sandevistan runs ' ..
			'on for %d ms more (level %d of %d) -- the %s grant is HELD until that ends and its %d ms cooldown ' ..
			'has passed'):format(player, math.floor(row.expires - now), math.floor(row.level or 1),
			math.floor(row.cap or 1), tostring(row.entryId), math.floor(row.cooldownMs or 0)))
		return
	end
	finish(player, phase, activation)
end

--- One phase of one overdrive, as the authority reports it.
-- @param rawPlayer any the host's player id
-- @param encoded any the JSON record
function M.Sandy.OnReflex(rawPlayer, encoded)
	local value = decode(encoded)
	local player = tonumber(rawPlayer)
	if value == nil or player == nil or player <= 0 then return end
	if type(value.player) == 'number' and value.player ~= player then return end
	local phase = tostring(value.phase or '')
	local activation = tostring(value.activation or '')
	if activation == '' then return end
	local entry = M.Chrome.ArmedEntry(player, 'reflex')
	local row = active[player]
	local ours = row ~= nil and row.activation == activation
	-- The boost's own piece while its grant is held back (revoked, so nothing
	-- is armed): the phases of THAT boost are still its piece's.
	if entry == nil and ours and row.entryId ~= nil then entry = M.Ripper.Entry(row.entryId) end

	local terminal = phase == 'completed' or phase == 'cancelled'
	local look, lookName = nil, nil
	if entry ~= nil then look, lookName = M.Ripper.SandyLook(entry) end
	-- THE JOURNAL, for every phase of every overdrive: what the platform ran
	-- and what the ripperdoc made of it. A test in game is read back from here.
	if phase == 'accepted' or phase == 'active' or terminal then
		Open77.log.info(('[ripperdoc] player %d: overdrive %s (definition %s, tier %s%s) -- armed piece %s, look %s')
			:format(player, phase, tostring(value.definition or '?'), tostring(value.tier or '?'),
				value.reason ~= nil and (', ' .. tostring(value.reason)) or '',
				entry ~= nil and entry.id or 'NONE', lookName or 'none (the platform draws it)'))
	end

	-- A RACE: an activation that still landed inside the running boost or its
	-- cooldown (a press on its way as the grant was held back, a second charge)
	-- is never drawn -- the boost on screen and its cooldown stand -- and it
	-- touches no clock. Said once per activation.
	if (phase == 'accepted' or phase == 'active') and not ours
		and ((row ~= nil and row.real) or holds[player] ~= nil) then
		if raced[player] ~= activation then
			raced[player] = activation
			Open77.log.warn(('[ripperdoc] player %d: overdrive %s arrived %s -- not drawn; the running boost ' ..
				'and its cooldown stand'):format(player, activation, row ~= nil and 'inside the running Sandevistan'
				or 'inside the Sandevistan\'s cooldown (its grant is held)'))
		end
		return
	end

	-- The cooldown clock Recover respects runs for every overdrive, styled or
	-- not -- from the ACCEPT, over the boost (as long as the level makes it)
	-- and then the cooldown; once the boost ends, from its end (`finish`).
	if phase == 'accepted' and entry ~= nil then
		local boost = boostMs(player, entry)
		lastUse[player] = { at = OPX.Now(), cooldownMs = cooldownOf(player, entry) + math.max(0, boost) }
	end

	if look == nil then
		-- Not ours to draw -- unless a styled boost of this player is still on
		-- screen and this is its end (a piece pulled mid-boost).
		if terminal and ours then M.Sandy.PlatformEnded(player, phase, activation) end
		return
	end
	run(player, phase, activation, value, look, lookName, entry)
end

-- The test boosts running, so a second test cuts the first.
local tests = 0

--- A whole Sandevistan on one player WITHOUT the overdrive (`/opx.sandy.test`):
--- the same accepted, active and completed phases the platform would send,
--- through the same code, so the look, the layers, the clock and the screen
--- can be tested on their own. The body is not boosted -- nothing here touches
--- the platform's overdrive.
-- @param player number
-- @param ms integer
-- @param tier string|nil
-- @return boolean
-- @return string|nil why not
function M.Sandy.Simulate(player, ms, tier)
	player = tonumber(player)
	if player == nil or player <= 0 then return false, 'no_player' end
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local looks = type(sandy.LOOKS) == 'table' and sandy.LOOKS or {}
	local lookName = nil
	for _, name in pairs(type(sandy.LOOK) == 'table' and sandy.LOOK or {}) do
		if type(looks[name]) == 'table' then lookName = name break end
	end
	if lookName == nil then lookName = next(looks) end
	local look = lookName ~= nil and looks[lookName] or nil
	if type(look) ~= 'table' then return false, 'no_look_configured' end
	ms = math.max(500, math.min(CAP_MS - 500, math.floor(tonumber(ms) or 9000)))
	tier = tier == 'reflex' and 'reflex' or 'reflex_heavy'
	tests = tests + 1
	local activation = ('opxtest%025d'):format(tests)
	if active[player] ~= nil then finish(player, 'cancelled', active[player].activation) end
	Open77.log.info(('[ripperdoc] player %d: TEST Sandevistan (%s, %s) for %d ms, without the overdrive')
		:format(player, lookName, tier, ms))
	run(player, 'accepted', activation, { tier = tier }, look, lookName, nil)
	run(player, 'active', activation, { tier = tier, serverTimeMs = 0, expiresAtMs = ms - 250 }, look,
		lookName, nil)
	CreateThread(function()
		local deadline = OPX.Now() + ms
		while OPX.Now() < deadline do Wait(100) end
		if active[player] ~= nil and active[player].activation == activation then
			run(player, 'completed', activation, { tier = tier }, look, lookName, nil)
		end
	end)
	return true
end

-- player -> { since, count }: the report rate, so a client cannot fill the journal.
local reports = {}

--- What one client did with a Sandevistan phase (`client/sandevistan.lua`,
--- `report`), written to the journal beside the server's own lines.
-- @param source any the reporting player
-- @param fields table
function M.Sandy.OnReport(source, fields)
	local player = tonumber(source)
	if player == nil or player <= 0 or type(fields) ~= 'table' then return end
	local now = OPX.Now()
	local mine = reports[player]
	if mine == nil or now - mine.since > 60000 then
		mine = { since = now, count = 0 }
		reports[player] = mine
	end
	mine.count = mine.count + 1
	if mine.count > 20 then return end
	local function text(value, most)
		value = tostring(value == nil and '-' or value):gsub('[%c]', ' ')
		return #value > most and value:sub(1, most) or value
	end
	local function flag(value) return value == true and 'yes' or 'no' end
	local doors = type(fields.doors) == 'table' and fields.doors or {}
	local door = ('lease=%s timescale=%s screen=%s playEntity=%s callSync=%s'):format(flag(doors.lease),
		flag(doors.timescale), flag(doors.screen), flag(doors.playEntity), flag(doors.callSync))
	if fields.role == 'owner' then
		Open77.log.info(('[ripperdoc] player %d\'s client: Sandevistan engaged for %s ms -- world %s%s; screen %s; ' ..
			'view shipped %s; doors %s'):format(player, text(fields.remainingMs, 8), text(fields.clock, 80),
			fields.why ~= nil and (' (' .. text(fields.why, 200) .. ')') or '', text(fields.screen, 80),
			flag(fields.view), door))
	elseif fields.role == 'observer' then
		Open77.log.info(('[ripperdoc] player %d\'s client drew player %s\'s Sandevistan: %s effect(s) on the ' ..
			'body (%s layer(s) of the look), plate %s; doors %s'):format(player, text(fields.owner, 12),
			text(fields.plays, 6), text(fields.layers, 6), flag(fields.plated), door))
	elseif fields.role == 'clock' then
		Open77.log.info(('[ripperdoc] player %d\'s client: Sandevistan clock -- %s'):format(player,
			text(fields.clock, 240)))
	elseif fields.role == 'slowed' then
		-- A machine the boost slowed (`slowAround`), once its ease has landed:
		-- which door holds its clock and what the engine really runs at.
		Open77.log.info(('[ripperdoc] player %d\'s client: slowed by player %s\'s Sandevistan -- %s; clock %s; ' ..
			'doors %s'):format(player, text(fields.owner, 12),
			fields.door ~= nil and ('held by ' .. text(fields.door, 16)) or ('REFUSED: ' .. text(fields.why, 160)),
			text(fields.clock, 200), door))
	end
end

--- What the platform says about one player's overdrive projection right now.
-- @param entry table
-- @param player number
-- @return string `ready`, `pending`, `absent`... or `unknown`
local function status(entry, player)
	local module = M.Ripper.GrantModule(entry)
	if module == nil or type(module.current) ~= 'function' then return 'unknown' end
	local ran, current = pcall(module.current, player)
	if not ran then return 'unknown' end
	if type(current) ~= 'table' then return 'absent' end
	local projection = type(current.projection) == 'table' and current.projection or nil
	local value = projection ~= nil and projection.status or current.status
	return type(value) == 'string' and value ~= '' and value or 'unknown'
end

--- A player's own machine says its overdrive projection is gone while the
--- server still holds the grant: project it again, when that cannot be a way
--- around a cooldown. `chair` is the stand-up from the clinic chair, which
--- the server itself vouches for (a one-use token), so the time floor between
--- two recoveries does not apply to it -- the cooldown still does.
-- @param player number
-- @param chair boolean|nil
-- @return boolean done
-- @return string|nil why not
function M.Sandy.Recover(player, chair)
	player = tonumber(player)
	if player == nil then return false, 'no_player' end
	-- A grant held back for a boost and its cooldown is not lost: it comes back
	-- when that is over, and asking cannot bring it back sooner.
	if holds[player] ~= nil or M.Chrome.HeldBack(player) then return false, 'held' end
	local entry = M.Chrome.ArmedEntry(player, 'reflex')
	if entry == nil then return false, 'not_armed' end
	local now = OPX.Now()
	local policy = recoverPolicy()
	if chair ~= true and recovered[player] ~= nil and now - recovered[player] < policy.AFTER_MS then
		return false, 'too_soon'
	end
	local use = lastUse[player]
	if use ~= nil and now - use.at < use.cooldownMs then return false, 'cooling_down' end
	if active[player] ~= nil and now < active[player].expires then return false, 'boosted' end
	-- A projection the platform is still delivering is not a lost one.
	local current = status(entry, player)
	if current == 'pending' then return false, 'pending' end
	recovered[player] = now
	local done = M.Chrome.Reproject(player, 'reflex')
	Open77.log.info(('[ripperdoc] player %d: the overdrive (%s) was lost on their client and ' ..
		'projected again (%d)'):format(player, entry.id, done))
	return done > 0, done > 0 and nil or 'refused'
end

--- Whether a styled boost is on this player's body right now.
-- @param player number
-- @return boolean
function M.Sandy.Active(player)
	local row = active[tonumber(player)]
	return row ~= nil and OPX.Now() < row.expires
end

--- Wires the reflex phases and the departures.
function M.Sandy.Start()
	RegisterNetEvent(M.Event.SANDYREPORT, function(fields)
		local ran, failure = pcall(M.Sandy.OnReport, source, fields)
		if not ran then Open77.log.warn('[ripperdoc] a Sandevistan report raised: ' .. tostring(failure)) end
	end)
	AddEventHandler('onReflexChanged', function(player, encoded)
		local ran, failure = pcall(M.Sandy.OnReflex, player, encoded)
		if not ran then
			Open77.log.warn('[ripperdoc] the Sandevistan look raised: ' .. tostring(failure))
		end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player == nil then return end
		if active[player] ~= nil then finish(player, 'cancelled', active[player].activation) end
		-- The hold goes with the session (the grant already has).
		lastUse[player], recovered[player], reports[player] = nil, nil, nil
		holds[player], raced[player] = nil, nil
	end)
	-- A BOOST THE LEVEL LENGTHENED OUTLIVES THE PLATFORM'S OVERDRIVE, and with
	-- it every release the platform would have made: a death ends it here.
	AddEventHandler('onPlayerLifeStateChanged', function(playerId, _, phase)
		local player = tonumber(playerId)
		if player == nil or tostring(phase) ~= 'dead' or active[player] == nil then return end
		Open77.log.info(('[ripperdoc] player %d: the Sandevistan ends -- the owner is down'):format(player))
		finish(player, 'cancelled', active[player].activation)
	end)
	-- A character put down on a connection that stays: its boost ends, and its
	-- hold goes with its grants (`server/chrome.lua` drops them).
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(playerId)
		local player = tonumber(playerId)
		if player == nil then return end
		if active[player] ~= nil then finish(player, 'cancelled', active[player].activation) end
		holds[player], raced[player] = nil, nil
	end)
	-- THE DEADLINE BEHIND THE PHASES: a terminal phase that never arrives
	-- still ends the look, the layers and every slowdown on time. A boost the
	-- platform already finished its part of ends exactly at its deadline:
	-- nothing more is coming from the platform for it.
	watching = true
	CreateThread(function()
		while watching do
			Wait(500)
			local ran, failure = pcall(M.Sandy.Watch, OPX.Now())
			if not ran then Open77.log.warn('[ripperdoc] the Sandevistan watch raised: ' .. tostring(failure)) end
			ran, failure = pcall(M.Sandy.Sweep)
			if not ran then Open77.log.warn('[ripperdoc] the Sandevistan sweep raised: ' .. tostring(failure)) end
		end
	end)
end

--- One pass of the deadline watch: every boost past its deadline ends, and
--- every grant held back whose boost is over and whose cooldown has passed
--- comes back. Public for the tests, which drive it with their own clock.
-- @param now number `OPX.Now()`
function M.Sandy.Watch(now)
	local due = {}
	for player, row in pairs(active) do
		if now >= row.expires + (row.platformDone and 0 or 1000) then due[#due + 1] = player end
	end
	for _, player in ipairs(due) do finish(player, 'completed', active[player].activation) end
	local back = {}
	for player, hold in pairs(holds) do
		-- A boost that ended by any door that did not start the cooldown
		-- (none should) starts it now: a hold never outlives its purpose.
		if hold.releaseAt == nil and (active[player] == nil or active[player].activation ~= hold.activation) then
			hold.releaseAt = now + cooldownOf(player, M.Ripper.Entry(hold.entry) or { id = hold.entry })
		end
		if hold.releaseAt ~= nil and now >= hold.releaseAt then back[#back + 1] = player end
	end
	for _, player in ipairs(back) do
		local hold = holds[player]
		holds[player] = nil
		local armed = M.Chrome.GiveBack(player, hold.entry)
		Open77.log.info(('[ripperdoc] player %d: the Sandevistan\'s cooldown is over -- its %s grant is back%s')
			:format(player, tostring(hold.entry), armed and '' or ' (not armed yet: asked again)'))
	end
end

--- Whether a player's reflex grant is held back for a boost and its cooldown.
-- @param player number
-- @return boolean
function M.Sandy.Held(player)
	return holds[tonumber(player)] ~= nil
end

--- Ends every styled boost with the resource.
function M.Sandy.Stop()
	watching = false
	local players = {}
	for player in pairs(active) do players[#players + 1] = player end
	for _, player in ipairs(players) do finish(player, 'cancelled', active[player].activation) end
	active, holds, raced = {}, {}, {}
end

--- A reload starts clean.
function M.Sandy.Init()
	active, lastUse, recovered, holds, raced = {}, {}, {}, {}, {}
	warnedSound = false
end
