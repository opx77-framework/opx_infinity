--- The crowd: mortal civilians a player can kill, so the wanted ladder can be
--- driven with real bodies instead of a console line.
-- @author XEROX710
--
-- WHY THIS FILE EXISTS. `/opx.ncpd.report` can charge a crime and `/opx.ncpd.heat`
-- can put a player on a stage, but neither proves the thing an operator actually
-- wants to watch: somebody is killed on the street and the CITY notices. The
-- victims have to exist, be mortal, and die like anybody else -- so this is that
-- crowd. Server-owned NPCs (`Open77.npcs.create`, `wiki/npcs.md`), standing
-- around a spot like pedestrians, wandering from it, scattering when they are
-- shot, and `damage.mortal`: a bullet ends them, and the platform's own
-- `onNpcDied` names who did it.
--
-- THE KILL IS CHARGED THROUGH THE ONE PATH. A death with a player behind it is
-- charged as `BOTS.LAW` (murder, by default) through `M.ChargePlayer` -- the
-- same door the contract's `ReportPlayer` opens -- so a bot's death climbs the
-- ladder, stands the response up and answers MaxTac exactly like any other
-- crime. `BOTS.CHARGE = false` shuts that door for a server whose engine
-- already scores these kills on the client's own heat mirror (see
-- `onEngineStage` in `server/main.lua`): one death must not be scored twice.
--
-- THE CROWD IS AN OPERATOR'S RIG, NOT CONTENT. It is placed on demand
-- (`/opx.ncpd.bots spawn`), around the caller, and taken back off the street
-- by `clear`. What it looks like, how many stand and what a kill costs is
-- `BOTS` in `config/ncpd.lua`, read on every ask -- the same live-config rule
-- as `M.Radio.KeySettings`.

local M = OPX.Modules.Get('ncpd')

--- The shipped knobs. `BOTS` in `config/ncpd.lua` wins per field when the
-- value is usable (see `M.Bots.Knobs`).
M.Bots = {
	-- Which law a bot's death is charged as. Any id from the book
	-- (`/opx.ncpd.laws`); the book itself refuses one it does not know,
	-- by name, at the charge.
	LAW = 'murder',

	-- Whether a death is charged at all. TRUE books the killer through the
	-- law; FALSE leaves the ladder to whatever else scores the kill (the
	-- engine's own heat, mirrored by the client), for a server where both
	-- would otherwise count one death.
	CHARGE = true,

	-- How many one `spawn` places, and how many may stand at once. The
	-- platform caps a resource at 512 bodies and the wanted response shares
	-- that budget with this crowd, so `MAX` is this module's own promise.
	COUNT = 24,
	MAX = 64,

	-- How far from the asker the crowd stands (metres), and how far each
	-- body wanders from its own spot. `WANDER = 0` pins every body where it
	-- was placed.
	SPREAD = 45.0,
	WANDER = 12.0,

	-- A shot crowd scatters: the first wound sends the body fleeing from the
	-- player who landed it, the way a pedestrian would. FALSE keeps the
	-- crowd standing where it was placed.
	FLEE = true,

	-- A killed body comes back this many seconds later, at the spot it fell,
	-- so a long test does not run out of victims. `RESPAWN = false` is a
	-- crowd that thins as it is killed.
	RESPAWN = true,
	RESPAWN_SECONDS = 25.0,

	-- The bodies themselves: the civilian family of the admin ped catalogue
	-- (`modules/admin/data/peds.lua`), records the platform's own 2.31
	-- research verified present. The list is the crowd's variety; a row that
	-- is not a usable record id is dropped rather than placed.
	RECORDS = {
		'Character.DefaultNCResidentMale',
		'Character.DefaultNCResidentFemale',
		'Character.AsianMale',
		'Character.AsianFemale',
		'Character.CreoleMan',
		'Character.CreoleWoman',
		'Character.TenantMale',
		'Character.TenantWoman',
		'Character.YoungsterMale',
		'Character.YoungsterFemale',
		'Character.SlackerMale',
		'Character.SlackerFemale',
		'Character.MorningCrowdMan',
		'Character.MorningCrowdWoman',
		'Character.NightlifeMale',
		'Character.NightlifeWoman',
	},
}

-- THE CROWD'S STATE, one row per standing body, keyed by the id as the events
-- spell it (a host resource event's arguments are strings). `generation` is the
-- ticket a respawn thread must still hold to place a body: a `clear` reprints
-- the tickets, and a scheduled body from a cleared crowd never stands again.
local live = {}
local generation = 0
local placed = 0
local booked = 0
local handlers = false

-- Bodies of the crowd that died a moment ago, by id, with when. THE KILL
-- HANDLER IN `server/main.lua` ASKS `Owns` about the same `onNpcDied` this file
-- answers, and the order two handlers of one host event run in is not a promise
-- anybody wrote down: had this file already dropped the body from `live`, the
-- other would have read a stranger and charged the kill a second time. A minute
-- is far longer than one event's delivery and short enough to stay tiny.
local fallen = {}
local FALLEN_MS = 60000

--- Whether a body is (or a moment ago was) one of the crowd's. The door the
--- module's own kill handler uses to leave the crowd's kills to this file.
-- @param id any the npc id as the host spells it
-- @return boolean
function M.Bots.Owns(id)
	local key = tostring(id)
	if live[key] ~= nil then return true end
	local when = fallen[key]
	return when ~= nil and OPX.Now() - when < FALLEN_MS
end

--- The id of a body that is STILL STANDING, exactly as `Open77.npcs.create` handed
--- it back, or nil. Unlike `Owns` this forgets a body the moment it falls: it is
--- what the hit relay (`server/hits.lua`) resolves a client's report through, and
--- a report about a corpse is not a hit.
-- @param id any the npc id as a client or the host spells it
-- @return any|nil
function M.Bots.IdOf(id)
	local bot = live[tostring(id)]
	if bot == nil then return nil end
	return bot.id
end

--- Whether a record id is one the platform could spawn: `Character.` followed
-- by its own identifier alphabet (ASCII letters, digits, `_`, `-`, `.`), as
-- `wiki/npcs.md` states it.
-- @param record any
-- @return boolean
local function usableRecord(record)
	return type(record) == 'string' and #record <= 255
		and record:match('^Character%.[%w_%-%.]+$') ~= nil
end

--- The knobs as the config declares them, each field falling back to the
-- shipped one rather than trusting a shape. `BOTS = false` answers nil: this
-- is an operator's rig, and an operator who switched it off means it.
-- @return table|nil `{ LAW, CHARGE, COUNT, MAX, SPREAD, WANDER, FLEE, RESPAWN, RESPAWN_SECONDS, RECORDS }`
function M.Bots.Knobs()
	-- NOT `... and M.Settings.BOTS or nil`: that idiom swallows `false`, and
	-- `false` is the one value that must reach the gate below.
	local raw = nil
	if type(M.Settings) == 'table' then raw = M.Settings.BOTS end
	if raw == false then return nil end

	local knobs = {}
	for _, name in ipairs({ 'LAW', 'CHARGE', 'COUNT', 'MAX', 'SPREAD', 'WANDER',
		'FLEE', 'RESPAWN', 'RESPAWN_SECONDS', 'RECORDS' }) do
		knobs[name] = M.Bots[name]
	end
	if type(raw) ~= 'table' then return knobs end

	if type(raw.LAW) == 'string' and raw.LAW ~= '' then knobs.LAW = raw.LAW end
	if type(raw.CHARGE) == 'boolean' then knobs.CHARGE = raw.CHARGE end
	if type(raw.FLEE) == 'boolean' then knobs.FLEE = raw.FLEE end
	if type(raw.RESPAWN) == 'boolean' then knobs.RESPAWN = raw.RESPAWN end

	-- NUMBERS ARE CLAMPED TO THE RANGE THE KNOB MEANS: a count is whole and
	-- positive, a reach is finite, and the platform's own 512-body ceiling
	-- is the last word on `MAX` whatever the config says.
	local count = tonumber(raw.COUNT)
	if count ~= nil and count >= 1 then knobs.COUNT = math.floor(count) end
	local max = tonumber(raw.MAX)
	if max ~= nil and max >= 1 then knobs.MAX = math.min(math.floor(max), 512) end
	if knobs.COUNT > knobs.MAX then knobs.COUNT = knobs.MAX end
	local spread = tonumber(raw.SPREAD)
	if spread ~= nil and spread > 0 then knobs.SPREAD = math.min(spread, 500.0) end
	local wander = tonumber(raw.WANDER)
	if wander ~= nil and wander >= 0 then knobs.WANDER = math.min(wander, 200.0) end
	local respawn = tonumber(raw.RESPAWN_SECONDS)
	if respawn ~= nil and respawn >= 0 then knobs.RESPAWN_SECONDS = math.min(respawn, 3600.0) end

	-- RECORDS: usable ids only, and a configured list with none left is the
	-- shipped one -- an operator who typos every row still has a crowd.
	local records = {}
	if type(raw.RECORDS) == 'table' then
		for _, record in ipairs(raw.RECORDS) do
			if usableRecord(record) then records[#records + 1] = record end
		end
	end
	if #records > 0 then knobs.RECORDS = records end
	return knobs
end

--- How many bodies the crowd is holding.
-- @return integer
function M.Bots.Live()
	local count = 0
	for _ in pairs(live) do count = count + 1 end
	return count
end

--- Places bodies around a spot. One body stands AT the spot (that is what a
-- respawn wants -- where the body fell); a crowd fans out in a sunflower, the
-- golden angle keeping every body off the last one's line and the square root
-- keeping the pile an even disc rather than a ring of huddles.
-- @param at table `{ x, y, z, bucket }`
-- @param count number|nil how many to place (`BOTS.COUNT` when nil)
-- @return integer how many this call placed
-- @return string|nil why it placed none: `off`, `no position`, `full`, `no npc contract`
function M.Bots.Spawn(at, count)
	local knobs = M.Bots.Knobs()
	if knobs == nil then return 0, 'off' end
	local x = type(at) == 'table' and tonumber(at.x) or nil
	local y = type(at) == 'table' and tonumber(at.y) or nil
	local z = type(at) == 'table' and tonumber(at.z) or nil
	if x == nil or y == nil or z == nil then return 0, 'no position' end
	local bucket = tonumber(at.bucket) or 0

	local want = math.floor(tonumber(count) or knobs.COUNT)
	if want < 1 then return 0, 'no position' end
	local room = knobs.MAX - M.Bots.Live()
	if room <= 0 then return 0, 'full' end
	if want > room then want = room end

	local npcs = Open77.npcs
	if type(npcs) ~= 'table' or type(npcs.create) ~= 'function' then
		return 0, 'no npc contract'
	end
	local ai = npcs.ai or {}
	local damage = npcs.damage or {}
	local tasks = npcs.tasks

	local golden = 2.399963229728653
	local made = 0
	for index = 1, want do
		local turn = (placed + index) * golden
		local reach = want > 1 and knobs.SPREAD * math.sqrt((index - 0.5) / want) or 0
		local spot = {
			x = x + math.cos(turn) * reach,
			y = y + math.sin(turn) * reach,
			z = z,
			bucket = bucket,
		}
		local record = knobs.RECORDS[((placed + index - 1) % #knobs.RECORDS) + 1]
		local id, why = npcs.create({
			record = record,
			position = { x = spot.x, y = spot.y, z = spot.z },
			yaw = ((placed + index) * 47) % 360,
			bucket = bucket,
			aiMode = ai.tasks,
			damagePolicy = damage.mortal,
			health = 100,
			maxHealth = 100,
			despawnWhenUnobserved = false,
			persistent = false,
		})
		if id == nil then
			-- A refused spawn is journalled by name, never silent: a crowd
			-- that quietly places nothing is a test that quietly proves
			-- nothing.
			Open77.log.warn(('[ncpd] the crowd could not place %s: %s')
				:format(tostring(record), tostring(why)))
		else
			placed = placed + 1
			made = made + 1
			live[tostring(id)] = { id = id, record = record, bucket = bucket, at = spot }
			if knobs.WANDER > 0 and type(tasks) == 'table' and type(tasks.wander) == 'function' then
				tasks.wander(id, {
					x = spot.x, y = spot.y, z = spot.z,
					radius = knobs.WANDER, speed = 'walk', seed = placed,
				})
			end
		end
	end
	return made
end

--- Takes the crowd off the street. Any respawn already scheduled stands down:
-- `generation` is the ticket a thread must still hold to place a body, and a
-- clear reprints the tickets.
-- @param why string|nil for the log
-- @return integer how many were removed
function M.Bots.Clear(why)
	generation = generation + 1
	local npcs = Open77.npcs
	local removed = 0
	for key, bot in pairs(live) do
		live[key] = nil
		removed = removed + 1
		if type(npcs) == 'table' and type(npcs.remove) == 'function' then
			npcs.remove(bot.id)
		end
	end
	if removed > 0 then
		Open77.log.info(('[ncpd] the crowd is off the street: %d body(ies), %s')
			:format(removed, tostring(why or 'gone')))
	end
	return removed
end

--- What the crowd is, for the command's `status`.
-- @return table `{ live, placed, booked }`
function M.Bots.Status()
	return { live = M.Bots.Live(), placed = placed, booked = booked }
end

--- The player a death's source names, or nil when it names nobody alive.
-- The platform passes the source as it has it -- a player id as text, or an
-- opaque script name like `resource:arena` -- and the character contract is
-- the real test of whether a connection was behind it at all, so this only
-- rules out the shapes that cannot be a player.
-- @param killer any the `source` argument of `onNpcDied`/`onNpcDamaged`
-- @return number|nil
local function killerOf(killer)
	local id = tonumber(killer)
	if id == nil then id = tonumber(tostring(killer):match('player:(%d+)')) end
	if id == nil or id ~= math.floor(id) or id <= 0 then return nil end
	return id
end

--- One body of the crowd has died: it is booked against whoever the source names,
--- the body is remembered as fallen, and a respawn is scheduled when the knobs say
--- so. A body that is not the crowd's is ignored, and a second report of the same
--- death finds the body already gone and does nothing.
-- @param npcId any
-- @param killer any the `source` argument of `onNpcDied`
-- @param cause any
function M.Bots.Died(npcId, killer, cause)
	local key = tostring(npcId)
	local knobs = M.Bots.Knobs()
	local bot = live[key]
	if bot == nil or knobs == nil then return end
	live[key] = nil
	local now = OPX.Now()
	for id, when in pairs(fallen) do
		if now - when >= FALLEN_MS then fallen[id] = nil end
	end
	fallen[key] = now

	local by = killerOf(killer)
	if knobs.CHARGE and by ~= nil then
		-- THE ONE PATH. `M.ChargePlayer` is `charge` under a connection:
		-- the ledger moves, the response stands up, the client is told.
		booked = booked + 1
		local charged = M.ChargePlayer(by, knobs.LAW)
		if charged == nil or charged.ok ~= true then
			booked = booked - 1
			Open77.log.warn(('[ncpd] a crowd death could not be charged to player %d: %s')
				:format(by, tostring(charged ~= nil and charged.error or 'no answer')))
		end
	elseif knobs.CHARGE then
		Open77.log.info(('[ncpd] a crowd body died with nobody to charge (source %s, %s)')
			:format(tostring(killer), tostring(cause)))
	end

	if knobs.RESPAWN then
		local ticket = generation
		CreateThread(function()
			Wait(math.floor(knobs.RESPAWN_SECONDS * 1000))
			if ticket ~= generation or M.Bots.Knobs() == nil then return end
			M.Bots.Spawn(bot.at, 1)
		end)
	end
end

--- Subscribes to the platform's own death and damage reports. ONCE: a resource
-- restart re-runs `M.Start`, and two handlers would book every kill twice.
function M.Bots.Start()
	if handlers then return end
	handlers = true

	-- `onNpcDied(npcId, source, cause)`, host-wide (`wiki/npcs.md`), so the
	-- crowd filters by the ids it placed. The arguments are strings, as
	-- every server resource event's are. The body of the handler is `M.Bots.Died`,
	-- a door of its own, so a death the hit relay books from a body's health
	-- (`server/hits.lua`) is the same booking as one the platform announced.
	AddEventHandler('onNpcDied', function(npcId, killer, cause)
		M.Bots.Died(npcId, killer, cause)
	end)

	-- `onNpcDamaged(npcId, source, amount, health, cause)`, also host-wide.
	-- The scatter is one flight per body: `flee` re-measures its target every
	-- cycle, so one task keeps the body running until the distance says done.
	AddEventHandler('onNpcDamaged', function(npcId, attacker)
		local bot = live[tostring(npcId)]
		if bot == nil or bot.fled then return end
		local knobs = M.Bots.Knobs()
		if knobs == nil or knobs.FLEE ~= true then return end
		local tasks = Open77.npcs.tasks
		if type(tasks) ~= 'table' or type(tasks.flee) ~= 'function' then return end
		local by = killerOf(attacker)
		if by == nil then return end
		bot.fled = true
		tasks.flee(bot.id, { playerId = by }, { distance = 60 })
	end)
end

--- Takes the crowd down with the module.
function M.Bots.Stop()
	M.Bots.Clear('the module stopped')
end
