--- The base-game menu recorder: what the game's own ripperdoc (and every other
-- vanilla menu) looked like from the outside, written down in detail so the
-- clinic's tray can be built from it.
-- @author XEROX710
--
-- WHAT IT CAN SEE, AND WHAT IT CANNOT. A Lua resource never touches the engine
-- (docs/redengine-data-access.md: "Lua resources never receive raw REDengine
-- function access"), so the vanilla vendor screen's own rows are out of reach.
-- What the platform DOES publish is recorded, at the moment a vanilla menu
-- opens and again when it closes, and the two are compared:
--   the menu     `Open77.session.menuState()` -- which layer, which scenario
--   the body     canonical health, stamina and armor (`Open77.stats.get`)
--   the chrome   `open77_cyberware`'s own capability report (the native
--                projection of arms/legs/slam) and the Gorilla attack state
--   the place    position, facing, district
--   the doctor   what the crosshair is on (a vanilla ripperdoc such as Viktor
--                reads as a `populationNpc` with a class and a name) and every
--                object around -- the chair among them
-- So "I bought X from Viktor" is recorded as: the ripperdoc screen opened
-- here, next to these objects, and the body's numbers and native chrome read
-- THIS before and THAT after. Every line goes to the server journal as
-- `[ripperdoc:rec]` and to this client's own log; `/opx.clinic.record dump`
-- copies the whole session to the clipboard as JSON.
--
-- WHEN IT RECORDS. With `RECORDER.AUTO` on (shipped), any vanilla menu whose
-- scenario name matches one of `RECORDER.SCENARIOS` -- the vendor screen the
-- ripperdoc opens is one -- is recorded by itself. `/opx.clinic.record on`
-- records every vanilla menu on this client until `off`.

local M = OPX.Modules.Get('ripperdoc')

M.Recorder = {}

-- Whether the operator switched this client on (every vanilla menu), the
-- snapshot taken when the current menu opened, and the session's lines.
local manual = false
local opened = nil
local session = {}
local SESSION_MAX = 200
-- The send queue: lines leave one at a time, under the server's floor.
local queue = {}
local sending = false
local running = false
local subscribed = false

--- The recorder policy.
-- @return table
local function policy()
	return type(M.Settings.RECORDER) == 'table' and M.Settings.RECORDER or {}
end

--- A value as JSON, or its string when the host has no encoder.
-- @param value any
-- @return string
local function encode(value)
	-- The CLIENT spells it `Open77.json`; the plain `json` global is the
	-- server's (and a test host's), kept as the fallback.
	local codec = type(Open77) == 'table' and type(Open77.json) == 'table' and Open77.json
		or (type(json) == 'table' and json or nil)
	if codec ~= nil and type(codec.encode) == 'function' then
		local ran, text = pcall(codec.encode, value)
		if ran and type(text) == 'string' then return text end
	end
	return tostring(value)
end

--- Sends one line to the server journal and keeps it in the session. A line
--- longer than the journal takes is sent in numbered parts.
-- @param line string
local function emit(line)
	Open77.log.info('[ripperdoc:rec] ' .. line)
	session[#session + 1] = line
	if #session > SESSION_MAX then table.remove(session, 1) end
	local size = 1400
	if #line <= size then
		queue[#queue + 1] = line
	else
		local parts = math.ceil(#line / size)
		for index = 1, parts do
			queue[#queue + 1] = ('[%d/%d] '):format(index, parts)
				.. line:sub((index - 1) * size + 1, index * size)
		end
	end
	if sending then return end
	sending = true
	CreateThread(function()
		while #queue > 0 do
			local next = table.remove(queue, 1)
			pcall(TriggerServerEvent, M.Event.RECORDED, next)
			Wait(150)
		end
		sending = false
	end)
end

--- One platform read, guarded: a refused permission or an absent namespace
--- answers nil and the reason, never a raise.
-- @param fn function|nil
-- @return any value
-- @return string|nil why not
local function read(fn, ...)
	if type(fn) ~= 'function' then return nil, 'unavailable' end
	local ran, value, why = pcall(fn, ...)
	if not ran then return nil, tostring(value) end
	if value == nil then return nil, why ~= nil and tostring(why) or nil end
	return value, nil
end

--- Rounds a number for a journal line.
local function round(value, places)
	local number = OPX.Math.Finite(value)
	if number == nil then return nil end
	local scale = 10 ^ (places or 2)
	return math.floor(number * scale + 0.5) / scale
end

--- What is around the player: every object within the radius, bodies and
--- all -- the ripperdoc is a body, the chair is not -- nearest first.
-- @return table
local function around()
	local rows = {}
	local world = Open77.world
	local radius = tonumber(policy().NEARBY_RADIUS) or 12
	local limit = tonumber(policy().MAX_NEARBY) or 12
	local found, why = read(type(world) == 'table' and world.nearby or nil, radius)
	if type(found) ~= 'table' then return { error = why or 'none' } end
	for index = 1, math.min(#found, limit) do
		local row = found[index]
		if type(row) == 'table' then
			local position = type(row.position) == 'table' and row.position or {}
			rows[#rows + 1] = {
				class = row.className, kind = row.kind, family = row.family,
				engine = row.engineEntity ~= nil and tostring(row.engineEntity) or nil,
				d = round(row.distance, 2),
				at = { round(position.x, 2), round(position.y, 2), round(position.z, 2) },
				npc = row.npcId, player = row.playerId,
			}
		end
	end
	return rows
end

--- One snapshot of everything the platform publishes about this moment.
--- YIELDS between its sections (the client's per-resume budget is one hook
--- interval, and a snapshot is a dozen platform reads and a list walk), so it
--- is only ever called from a thread.
-- @param tag string
-- @return table
local function snapshot(tag)
	local shot = { tag = tag, t = OPX.Now() }
	local sessionApi = Open77.session
	shot.menu = read(type(sessionApi) == 'table' and sessionApi.menuState or nil)
	local character = Open77.character
	if type(character) == 'table' and type(character.position) == 'function' then
		local ran, x, y, z = pcall(character.position)
		if ran then shot.at = { round(x, 2), round(y, 2), round(z, 2) } end
		shot.yaw = round(read(character.yaw), 1)
	end
	local world = Open77.world
	local district = read(type(world) == 'table' and world.district or nil)
	if type(district) == 'table' then shot.district = district.subDistrict or district.district end
	local stats = read(type(Open77.stats) == 'table' and Open77.stats.get or nil)
	if type(stats) == 'table' then
		local health = type(stats.health) == 'table' and stats.health or {}
		local stamina = type(stats.stamina) == 'table' and stats.stamina or {}
		shot.stats = {
			health = round(health.value or health.current, 1), healthMax = health.maximum or health.max,
			healthRegen = round(health.regenPerSecond, 2),
			stamina = round(stamina.value or stamina.current, 1), staminaMax = stamina.maximum or stamina.max,
			staminaRegen = round(stamina.regenPerSecond, 2),
			armor = stats.armor,
		}
	end
	Wait(0)
	-- THE NATIVE CHROME, as the support resource on this machine reports it:
	-- its projections of the arms, the legs and the slam (the calling VM's own
	-- `legsActivity` would only ever describe this resource).
	local exports = Open77.exports
	if type(exports) == 'table' and type(exports.call) == 'function' then
		local ran, pending = pcall(exports.call, 'open77_cyberware', 'capabilities')
		if ran and type(pending) == 'table' and type(pending.await) == 'function' then
			local done, value = pcall(pending.await, pending)
			if done and type(value) == 'table' then
				shot.legs = value.legsProjection
				shot.projection = value.localProjection
				shot.slam = value.slamProjection
			end
		end
	end
	local cyberware = Open77.cyberware
	if type(cyberware) == 'table' then
		local attack = read(cyberware.attackState)
		if type(attack) == 'table' then shot.attack = attack end
		local arms = read(cyberware.captureArms)
		if type(arms) == 'table' then
			-- The profile is hashes; the journal needs to know it changed, and
			-- how, not every key.
			local groups = type(arms.groups) == 'table' and arms.groups or {}
			local names = {}
			for index = 1, #groups do
				local group = groups[index]
				names[#names + 1] = type(group) == 'table'
					and (tostring(group.name) .. '#' .. tostring(type(group.keys) == 'table' and #group.keys or 0))
					or '?'
			end
			shot.arms = { family = arms.family, groups = names }
		end
	end
	Wait(0)
	local aimed = read(type(character) == 'table' and character.aimedEntity or nil)
	if type(aimed) == 'table' then
		shot.aim = { class = aimed.className, kind = aimed.kind, family = aimed.family,
			d = round(aimed.distance, 2), engine = aimed.engineEntity ~= nil and tostring(aimed.engineEntity) or nil,
			npc = aimed.npcId, player = aimed.playerId }
	end
	local inspector = Open77.inspector
	local target = read(type(inspector) == 'table' and inspector.target or nil)
	if type(target) == 'table' and target.valid == true then
		shot.look = { name = target.name, class = target.class, kind = target.kind,
			d = round(target.distance, 2), engine = target.engineId ~= nil and tostring(target.engineId) or nil }
	end
	Wait(0)
	shot.around = around()
	Wait(0)
	return shot
end

--- What changed between two snapshots, field by field, for the lines that
--- matter: the body's numbers and the native chrome.
-- @param before table
-- @param after table
-- @return table
local function changes(before, after)
	local out = {}
	local function walk(prefix, a, b)
		if type(a) == 'table' or type(b) == 'table' then
			local keys = {}
			for key in pairs(type(a) == 'table' and a or {}) do keys[key] = true end
			for key in pairs(type(b) == 'table' and b or {}) do keys[key] = true end
			for key in pairs(keys) do
				walk(prefix .. '.' .. tostring(key), type(a) == 'table' and a[key] or nil,
					type(b) == 'table' and b[key] or nil)
			end
		elseif a ~= b then
			out[#out + 1] = ('%s: %s -> %s'):format(prefix:sub(2), tostring(a), tostring(b))
		end
	end
	walk('', { stats = before.stats, arms = before.arms, legs = before.legs, attack = before.attack,
		projection = before.projection, slam = before.slam },
		{ stats = after.stats, arms = after.arms, legs = after.legs, attack = after.attack,
			projection = after.projection, slam = after.slam })
	table.sort(out)
	return out
end

--- Whether a vanilla menu's scenario is one this client records on its own.
-- @param scenario string
-- @return boolean
local function wanted(scenario)
	if manual then return true end
	if policy().AUTO == false then return false end
	local lowered = tostring(scenario or ''):lower()
	for _, word in ipairs(type(policy().SCENARIOS) == 'table' and policy().SCENARIOS or {}) do
		if lowered:find(tostring(word):lower(), 1, true) then return true end
	end
	return false
end

--- The menu edge: a vanilla menu opened, or the one that opened closed. The
--- work runs on its own thread, a section per resume (see `snapshot`).
-- @param open string `"1"` or `"0"`
-- @param source string the layer
-- @param scenario string the vanilla scenario name
local function onMenu(open, _, source, scenario)
	if not running then return end
	if tostring(open) == '1' and tostring(source) == 'vanilla' then
		if opened ~= nil or not wanted(scenario) then return end
		local mark = { scenario = tostring(scenario or ''), shot = nil }
		opened = mark
		CreateThread(function()
			local shot = snapshot('open')
			mark.shot = shot
			emit(('vanilla menu OPEN scenario=%s'):format(mark.scenario))
			Wait(0)
			emit('vanilla menu OPEN snapshot ' .. encode(shot))
		end)
		return
	end
	if opened ~= nil and (tostring(open) == '0' or tostring(source) ~= 'vanilla') then
		local before = opened
		opened = nil
		CreateThread(function()
			local after = snapshot('close')
			-- An open whose own snapshot had not finished is compared to
			-- nothing rather than to half a picture.
			local shot = before.shot or {}
			local diff = changes(shot, after)
			emit(('vanilla menu CLOSE scenario=%s after %d ms; %d change(s): %s')
				:format(before.scenario, (after.t or 0) - (shot.t or after.t or 0), #diff,
					#diff > 0 and table.concat(diff, '; ') or 'none'))
			Wait(0)
			emit('vanilla menu CLOSE snapshot ' .. encode(after))
		end)
	end
end

--- The operator's switch.
-- @param mode string `on`, `off`, `snap` or `dump`
function M.Recorder.Command(mode)
	CreateThread(function()
		if mode == 'on' then
			manual = true
			emit('recorder ON: every vanilla menu on this client is recorded')
			emit('snapshot ' .. encode(snapshot('on')))
		elseif mode == 'off' then
			manual = false
			emit('recorder OFF (automatic recording follows RECORDER.AUTO)')
		elseif mode == 'snap' then
			emit('snapshot ' .. encode(snapshot('snap')))
		elseif mode == 'dump' then
			local text = encode(session)
			local clipboard = Open77.clipboard
			local copied, why = read(type(clipboard) == 'table' and clipboard.setText or nil, text)
			emit(('dump: %d line(s), %d bytes %s'):format(#session, #text,
				copied and 'copied to the clipboard' or ('NOT copied: ' .. tostring(why))))
		end
	end)
end

--- Starts listening to the menu edge.
function M.Recorder.Start()
	running = true
	if not subscribed then
		subscribed = true
		AddEventHandler('open77:menuStateChanged', function(...)
			local ran, failure = pcall(onMenu, ...)
			if not ran then Open77.log.warn('[ripperdoc] the recorder raised: ' .. tostring(failure)) end
		end)
	end
end

--- Stops recording (the handler stays registered and goes quiet).
function M.Recorder.Stop()
	running = false
	opened = nil
end

--- The session's lines, for the tests.
-- @return table
function M.Recorder.Lines()
	return session
end
