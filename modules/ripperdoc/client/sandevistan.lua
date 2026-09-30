--- The Sandevistan on this machine: the look on every boosted body, the world
-- slowing around it, the owner's screen, the key that engages it, and the
-- power this client lost.
-- @author XEROX710
--
-- THE TIME. The owner's own world slows while their body does not (where the
-- player's build carries the platform's dilation lease; elsewhere their whole
-- view slows at the look's fallback rate), every player close to them runs
-- slower for the boost -- which is also what makes those players move in slow
-- motion on the owner's screen -- and the owner's screen wears the look's
-- overlay. See "time, and the owner's own screen" below. What took, and why
-- not, is written to the client log as the boost engages -- on the owner's
-- machine AND on every machine it slows, whose clock is read back from the
-- engine once the ease has landed and told to the server (role `slowed`), so
-- the server's journal alone says who really ran slow.
--
-- THE LOOK. The server names a boosted body, a phase, a look and how long the
-- boost has left (`M.Event.SANDY`, from `server/sandevistan.lua`); this half
-- draws the look on that body -- the owner's own included -- and takes it
-- down on the end: Adam Smasher's own Sandevistan, out of his 2.31 entity
-- (see `SANDEVISTAN` in `config/ripperdoc.lua`). Its blink goes off at the
-- body's feet as the boost is accepted and as it ends (`BLINK`, a world
-- effect at the body's position), its trails and loops are bound to the
-- body's slots for the whole boost (`LAYERS`, `Open77.vfx.play` +
-- `Open77.vfx.attach`, the first slot of each layer the body has -- the
-- owner's own body names them differently from everybody else's -- a 2 s
-- trail restarted every `every` seconds), and on everybody else's body the
-- effects that body AUTHORS are played by name (`START`, `LOOP`). Client-owned
-- handles are the whole reason it is drawn here: they are the only ones that
-- can be stopped when a boost is cut short. A body that is not streamed yet
-- is tried again every quarter second until the boost runs out, so somebody
-- who walks round a corner into a running Sandevistan still sees it. Past
-- about 20 m no particle survives, so the plate carries it (`PLATE`): this
-- resource owns the plates, which is also why the platform's own OVERDRIVE
-- marker can never draw here.
--
-- THE JOURNAL. Every link of the chain is one line in this machine's client
-- log, written on a change and never per frame: what the server says this
-- player holds, the platform's overdrive projection (ready or lost), the
-- overdrive engaging on this body (read from `open77_reflex`'s own `state`
-- export), each Sandevistan phase the server sends, the clock (read back
-- from the engine through `Open77.world.getTimeScale`), the screen, and how
-- many of the look's effects went onto each body. The view resource's
-- REDscript writes its own lines (`opx_sandy_view on: ...`). A test in game
-- is read back from here.
--
-- THE KEY. The platform registers the engage action itself (`open77_reflex`'s
-- `reflex_overdrive`) with the server's default, and the player rebinds it in
-- Pause > Settings > KEY BINDINGS -- or with `/opx.sandy.key`, which lands
-- here and goes through the same `Open77.input.rebind`. Whatever this client
-- says about "press X" reads the EFFECTIVE key, never the default.
--
-- THE REAL ITEM. A piece named in `SANDEVISTAN.WEAR` is also the base
-- game's own item in the Operating System slot. Only the view resource's
-- REDscript can fit it, and this resource reaches that script through nothing
-- but the clock: the view's `wear(code)` export holds a half-second message
-- claim the REDscript decodes. It is sent when the kit changes and again 4 s
-- and 12 s later (a new body, a loading screen), whenever the overdrive
-- projection comes back, never over a boost -- and "none" (0) only once this
-- machine has asked for an item, so a player who never held one is never
-- touched.
--
-- THE CHAIR, AND A LOST POWER. A power armed while its owner sat in the
-- clinic chair reached a body in a workspot, which `open77_reflex` does not
-- keep. The server hands this machine a one-use token when the patient
-- stands; it is sent back once the body is really free (out of the workspot,
-- alive, on foot), and the server projects those powers again. Past that, a
-- watch every two seconds asks `open77_reflex` itself whether it still holds
-- the overdrive the server says it holds, and asks for it once when not.

local M = OPX.Modules.Get('ripperdoc')
local Event = M.Event

M.Sandy = {}
local Sandy = M.Sandy

-- kind -> { entry, name, key, look }: what the server holds on this player
local kit = {}
-- player -> { look, tier, expires, handles, plated, started }
local shown = {}
-- The watch threads' run flag, so Stop ends them.
local running = false
-- The reprojection token being waited on, so a newer one supersedes it.
local waiting = nil
-- The lost-power watch: since when the projection read absent, and when a
-- recovery was last asked for.
local absentSince, askedAt = nil, nil
-- Whether the current loss was already written to the log.
local lostSaid = false

-- How long the watch lets `absent` stand before it asks, and how often it asks.
local ABSENT_GRACE_MS = 4000
local ASK_EVERY_MS = 5000
-- A BOOST IS NEVER LONGER THAN THIS: the longest the character's level makes
-- one (44 s, `M.Ripper.SANDY_MAX_SECONDS`) and its 250 ms margin, inside the
-- 45 s opx_sandy_view 1.4.9 holds the owner's clock for. The server holds the
-- same number (`server/sandevistan.lua`). Everything this file times a boost
-- by -- the owner's clock, a slowed player's claim, the layers, the plate, the
-- screen, the owner's end -- follows the boost's own `remainingMs` under it.
local CAP_MS = 45000
Sandy.CAP_MS = CAP_MS

--- The look a name stands for, from the shared config. Nil for anything the
--- config does not carry: the wire names a look, it never defines one.
-- @param name any
-- @return table|nil
local function lookOf(name)
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local looks = type(sandy.LOOKS) == 'table' and sandy.LOOKS or {}
	return type(name) == 'string' and type(looks[name]) == 'table' and looks[name] or nil
end

--- This machine's own player id, or nil when the host cannot say.
---
--- `Open77.players.localId` FIRST: it reads the roster of bodies this client
--- renders and the platform gates none of it. `Open77.network.status` is
--- behind `network.client`, a permission this resource does not declare --
--- relied on alone it answered `nil, permission_denied:network.client` on
--- every call, so every "is this boost mine?" said no and the owner's own
--- Sandevistan never ran its clock, screen or sounds: the look drew (the
--- platform resolves the owner's body as `1` anyway) and the world did not
--- slow. Found on staging, 2026-09-27.
-- @return number|nil
local function selfId()
	local players = Open77.players
	if type(players) == 'table' and type(players.localId) == 'function' then
		local ran, id = pcall(players.localId)
		id = ran and tonumber(id) or nil
		if id ~= nil and id > 0 then return id end
	end
	local network = Open77.network
	if type(network) ~= 'table' or type(network.status) ~= 'function' then return nil end
	local ran, status = pcall(network.status)
	if not ran or type(status) ~= 'table' then return nil end
	return tonumber(status.playerId)
end

--- Whether a player is this machine's own. With no id to compare, the body
--- the platform resolves for that player IS this machine's own when it
--- answers `1` -- the local body's handle -- which is the one answer that
--- cannot be wrong.
-- @param player number
-- @return boolean
local function isMine(player)
	local me = selfId()
	if me ~= nil then return player == me end
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.resolveTarget) ~= 'function' then return false end
	local ran, handle = pcall(vfx.resolveTarget, { kind = 'player', id = tostring(player) })
	return ran and handle ~= nil and handle ~= false and tostring(handle) == '1'
end

--- Whether the local body is one the movement clients will use: attached,
--- alive, out of any workspot and not in a vehicle -- `open77_reflex`'s own
--- test, so "free" here means free there.
-- @return boolean
function Sandy.BodyFree()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return false end
	local ran, state = pcall(character.state)
	if not ran or type(state) ~= 'table' then return false end
	local mounted = type(state.vehicle) == 'table' and state.vehicle.mounted == true
	return state.attached == true and state.alive == true and state.inWorkspot ~= true
		and type(state.vehicle) == 'table' and not mounted
end

--- The key one power engages on, as this player has it bound right now.
-- @param kind string `reflex`, `dash` or `ability`
-- @return string
function Sandy.EffectiveKey(kind)
	local held = kit[kind]
	local fallback = (held ~= nil and type(held.key) == 'string' and held.key)
		or M.Ripper.POWER_KEYS[kind] or '?'
	if kind == 'reflex' then
		local mapping = M.Ripper.SandyMapping()
		local input = Open77.input
		if type(input) == 'table' and type(input.mappings) == 'function' then
			local ran, rows = pcall(input.mappings)
			if ran and type(rows) == 'table' then
				for _, row in ipairs(rows) do
					if type(row) == 'table' and row.resource == mapping.RESOURCE and row.id == mapping.ID
						and type(row.key) == 'string' and row.key ~= '' then
						return row.key:upper()
					end
				end
			end
		end
	end
	return tostring(fallback):upper()
end

--- A toast from the catalogue, when the toast layer is up.
-- @param key string
-- @param params table|nil
-- @param kind string|nil
local function toast(key, params, kind)
	if type(OPX.Toast) == 'table' and type(OPX.Toast.Locale) == 'function' then
		pcall(OPX.Toast.Locale, key, params, kind or 'info')
	end
end

-- ── the look ────────────────────────────────────────────────────────────

--- The receiver-local handle of a player's body, or nil while it is not
--- streamed here. The local player is answered as nil-with-self: `playEntity`
--- with no entity is the local body.
-- @param player number
-- @return string|nil handle
-- @return boolean self
local function bodyOf(player)
	if player == selfId() then return nil, true end
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.resolveTarget) ~= 'function' then return nil, false end
	local ran, handle = pcall(vfx.resolveTarget, { kind = 'player', id = tostring(player) })
	if not ran or handle == nil or handle == false then return nil, false end
	if tostring(handle) == '1' then return nil, true end
	return tostring(handle), false
end

--- One line in this machine's client log.
-- @param text string
local function say(text)
	if type(Open77) == 'table' and type(Open77.log) == 'table' and type(Open77.log.info) == 'function' then
		Open77.log.info('[ripperdoc] ' .. text)
	end
end

--- Plays a list of authored names on one body for `seconds`, and answers how
--- many started. A name the body's template does not author plays nothing:
--- the engine's own rule.
-- @param names table|nil
-- @param entity string|nil nil for the local body
-- @param seconds number
-- @param into table|nil the handle list to append to
-- @return integer
local function playNames(names, entity, seconds, into)
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.playEntity) ~= 'function' then return 0 end
	local count = 0
	for index, name in ipairs(type(names) == 'table' and names or {}) do
		if type(name) == 'string' and name ~= '' then
			local ran, handle = pcall(vfx.playEntity, name, {
				entity = entity,
				instance = 'opx_sandy_' .. tostring(index) .. '_' .. name,
				duration = seconds,
				persistOnDetach = false,
				breakAllLoops = true,
				breakAllOnDestroy = true,
			})
			if ran and handle ~= nil and handle ~= false then
				count = count + 1
				if into ~= nil then into[#into + 1] = handle end
			end
		end
	end
	return count
end

--- Whether this player is looking at themselves from behind (the platform's
--- third-person view): their own body's hands are then posed for a camera
--- that is not there, so the look's hand layers stay off them.
-- @return boolean
local function thirdPerson()
	local api = Open77.perspective
	if type(api) ~= 'table' or type(api.state) ~= 'function' then return false end
	local ran, state = pcall(api.state)
	return ran and type(state) == 'table' and state.mode == 'tps'
end

-- (self|other) .. slot list -> the slot that took last time, so a body is not
-- asked for a slot it does not have on every restart.
local slotTook = {}

--- One cooked `.effect` bound to the first of `slots` the body has. Answers
--- the handle and the slot, or nil and why not.
-- @param effect string
-- @param entity any the body (1 for this player's own)
-- @param slots table
-- @param seconds number
-- @param kind string 'self' or 'other'
-- @return any|nil handle
-- @return string slot or why
local function attachLayer(effect, entity, slots, seconds, kind)
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.play) ~= 'function' or type(vfx.attach) ~= 'function' then
		return nil, 'no_vfx_attach'
	end
	local key = kind .. ':' .. table.concat(slots, '|')
	local order = {}
	if slotTook[key] ~= nil then order[1] = slotTook[key] end
	for _, slot in ipairs(slots) do
		if slot ~= slotTook[key] then order[#order + 1] = slot end
	end
	local why = 'no_slot'
	for _, slot in ipairs(order) do
		local ran, handle, refused = pcall(vfx.play, effect, { position = { x = 0, y = 0, z = 0 },
			duration = seconds, ignoreTimeDilation = true })
		if not ran or handle == nil or handle == false then
			return nil, 'play: ' .. tostring(ran and refused or handle)
		end
		local tied, ok, notTied = pcall(vfx.attach, handle, entity, slot)
		if tied and ok == true then
			slotTook[key] = slot
			return handle, slot
		end
		if type(vfx.stop) == 'function' then pcall(vfx.stop, handle) end
		why = slot .. ': ' .. tostring(tied and notTied or ok)
	end
	return nil, why
end

--- Where a body stands, or nil.
-- @param entity any
-- @param isSelf boolean
-- @return table|nil { x, y, z }
local function standing(entity, isSelf)
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local id = nil
	if not isSelf then
		id = math.tointeger(tonumber(entity))
		if id == nil then return nil end
	end
	local ran, x, y, z
	if id == nil then ran, x, y, z = pcall(character.position) else ran, x, y, z = pcall(character.position, id) end
	if not ran then return nil end
	if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- The body's entity for the look: 1 for this player's own, the streamed
--- handle for anybody else's (nil while it is not streamed here).
-- @param player number
-- @return any|nil
-- @return boolean self
local function lookEntity(player)
	local entity, isSelf = bodyOf(player)
	if isSelf then return 1, true end
	return entity, false
end

--- The look's blink (`BLINK.START` or `BLINK.END`) at the body's feet, left
--- where it went off. Answers whether it went off.
-- @param player number
-- @param spec table|nil { effect, seconds }
-- @return boolean
local function blink(player, spec)
	if type(spec) ~= 'table' or type(spec.effect) ~= 'string' then return false end
	local entity, isSelf = lookEntity(player)
	if entity == nil then return false end
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.play) ~= 'function' then return false end
	local seconds = math.max(1, math.min(30, tonumber(spec.seconds) or 15))
	local at = standing(entity, isSelf)
	if at ~= nil then
		local ran, handle = pcall(vfx.play, spec.effect, { position = at, duration = seconds })
		return ran and handle ~= nil and handle ~= false
	end
	-- Nowhere to put it: on the body instead, for a moment.
	local handle = attachLayer(spec.effect, entity, { 'Chest' }, 1.5, isSelf and 'self' or 'other')
	return handle ~= nil
end

--- The look's layers on one body, started or restarted where they are due.
-- Answers how many are on the body now and which slots took.
-- @param player number
-- @param row table
-- @param now number
-- @return integer on
-- @return integer tried
local function layers(player, row, now)
	local specs = type(row.look.LAYERS) == 'table' and row.look.LAYERS or {}
	local entity, isSelf = lookEntity(player)
	if entity == nil or (isSelf and row.look.SELF == false) then return 0, 0, 0 end
	local remaining = (row.expires - now) / 1000
	if remaining <= 0.2 then return 0, 0, 0 end
	local tps = isSelf and thirdPerson()
	-- The owner's third-person model, where the world ships the base-game
	-- view: its REDscript plays the look's `body` layers ON the model, by the
	-- names its template authors, so their copies on this body stand down.
	local worn = isSelf and tps and row.view == true
	row.layers = row.layers or {}
	local on, tried, model = 0, 0, 0
	for index, spec in ipairs(specs) do
		if type(spec) == 'table' and type(spec.effect) == 'string' and type(spec.slots) == 'table' then
			local only = spec.self or (spec.hands == true and 'fpp' or nil)
			local skip = (spec.who == 'self' and not isSelf) or (spec.who == 'others' and isSelf)
				or (isSelf and only == 'fpp' and tps) or (isSelf and only == 'tps' and not tps)
			local state = row.layers[index]
			if state == nil then
				state = { plays = 0, fails = 0 }
				row.layers[index] = state
			end
			if not skip and worn and spec.body == true then
				model = model + 1
				-- A copy already on this body (first person a moment ago) comes
				-- off; a start not played yet is spent, never played late; a
				-- held layer comes back the moment the view is first person.
				if state.handle ~= nil then
					local vfx = Open77.vfx
					if type(vfx) == 'table' and type(vfx.stop) == 'function' then pcall(vfx.stop, state.handle) end
					state.handle = nil
				end
				if spec.once then
					if state.plays == 0 then state.next = math.huge end
				else
					state.next = nil
				end
			elseif not skip then
				tried = tried + 1
				local every = tonumber(spec.every)
				local due = state.next == nil or (now >= state.next and (not spec.once or state.plays == 0))
				if due and state.fails < 3 then
					-- A restarted layer outlives its successor's start by a
					-- little, so a late tick never leaves a gap.
					local seconds = every ~= nil and math.min(remaining, every + 0.8) or remaining
					local handle, slot = attachLayer(spec.effect, entity, spec.slots, seconds,
						isSelf and 'self' or 'other')
					if handle ~= nil then
						row.handles[#row.handles + 1] = handle
						state.handle = handle
						state.plays, state.slot, state.why = state.plays + 1, slot, nil
						state.next = (every ~= nil and not spec.once) and (now + every * 1000) or math.huge
					else
						state.fails, state.why = state.fails + 1, slot
						state.next = now + 1000
					end
				end
				if state.plays > 0 then on = on + 1 end
			end
		end
	end
	return on, tried, model
end

--- The plate over a boosted player: their name and the look's suffix, in its
--- colour. Remote players only -- nobody reads their own plate.
-- @param player number
-- @param look table
-- @return boolean raised
local function plateOn(player, look)
	local plate = type(look.PLATE) == 'table' and look.PLATE or nil
	local api = Open77.nameplates
	if plate == nil or type(api) ~= 'table' or type(api.set) ~= 'function' then return false end
	local character = OPX.Api.Get('character')
	local name = character ~= nil and type(character.GetPlayerName) == 'function'
		and character.GetPlayerName(player) or nil
	if type(name) ~= 'string' or name == '' then return false end
	local suffix = type(plate.SUFFIX) == 'string' and plate.SUFFIX or ''
	local options = { label = name:sub(1, math.max(1, 96 - #suffix)) .. suffix }
	if type(plate.COLOR) == 'string' then options.color = plate.COLOR end
	local ran, ok = pcall(api.set, player, options)
	return ran and ok ~= false
end

--- Gives the plate back to what the character module keeps on it: the
--- character's name, or no override at all.
-- @param player number
local function plateOff(player)
	local api = Open77.nameplates
	if type(api) ~= 'table' then return end
	local character = OPX.Api.Get('character')
	local name = character ~= nil and type(character.GetPlayerName) == 'function'
		and character.GetPlayerName(player) or nil
	if type(name) == 'string' and name ~= '' and type(api.set) == 'function' then
		pcall(api.set, player, { label = name })
	elseif type(api.remove) == 'function' then
		pcall(api.remove, player)
	end
end

--- Starts a held look on its body, if the body is here to wear it, and
--- writes once what went onto it.
-- @param player number
-- @param row table
local function start(player, row)
	local entity, isSelf = bodyOf(player)
	if entity == nil and not isSelf then return end
	local now = OPX.Now()
	local seconds = math.max(0.5, (row.expires - now) / 1000)
	local names = 0
	if not isSelf then names = playNames(row.look.LOOP, entity, seconds, row.handles) end
	local on, tried, model = layers(player, row, now)
	row.started = true
	row.entity = entity or (isSelf and 1 or nil)
	if not isSelf and not row.plated then row.plated = plateOn(player, row.look) end
	local slots, refused = {}, {}
	for _, state in pairs(row.layers or {}) do
		if state.slot ~= nil and state.plays > 0 then slots[#slots + 1] = state.slot end
		if state.plays == 0 and state.why ~= nil then refused[#refused + 1] = state.why end
	end
	table.sort(slots)
	say(('Sandevistan look on %s: %d of %d layer(s) on the body%s%s, %d authored effect(s) by name%s%s'):format(
		isSelf and 'this player\'s own body' or ('player ' .. player), on, tried,
		#slots > 0 and (' (' .. table.concat(slots, ', ') .. ')') or '',
		#refused > 0 and (', refused: ' .. table.concat(refused, '; ')) or '', names,
		isSelf and (thirdPerson() and ', third person' or ', first person') or '',
		model > 0 and (', %d worn by the third-person model itself (the base-game view plays them on it by name)')
			:format(model) or ''))
end

--- Takes one body's look down: every handle, and the plate.
-- @param player number
local function stop(player)
	local row = shown[player]
	if row == nil then return end
	shown[player] = nil
	local vfx = Open77.vfx
	for _, handle in ipairs(row.handles) do
		if type(vfx) == 'table' and type(vfx.stop) == 'function' then pcall(vfx.stop, handle) end
	end
	if row.plated then plateOff(player) end
end

-- ── time, and the owner's own screen ────────────────────────────────────
--
-- A SLOWDOWN IS A PER-CLIENT SIMULATION RATE: no machine can slow another, so
-- "the world around a Sandevistan slows" is every nearby client running its
-- own clock slower for the boost, and the owner's own view of the world
-- slowing while they do not.
--
-- Two platform doors:
--   `Open77.dilation` (the lease the Sandevistan episode work added): the
--      engine's own dilation, WITH the vanilla exemption -- the owner's world
--      slows and their body does not, under the base game's own reason
--      `sandevistan` and ease-out `SandevistanEaseOut`, exactly what
--      `SandevistanEvents` does. The OWNER's door. With the world's view
--      REDscript (opx_sandy_view) the camera's `Sandevistan` curve rides it,
--      and the owner's screen is the base game's own.
--   `Open77.world.setTimeScale` (every current build): a client time scale,
--      which slows the body with the world. The door for the players AROUND
--      the owner, whose bodies are meant to slow (the lease is their fallback),
--      and the owner's own only where the lease is missing, at the look's
--      gentler SELF_FALLBACK_SCALE, so the overdrive's speed buff still leaves
--      them far faster than everybody slowed around them.

-- The engine's own Sandevistan key and ease, so the curve is the base game's.
local REASON, EASE_OUT = 'sandevistan', 'SandevistanEaseOut'

-- owner player id -> { activation, scale, expires }: the boosts slowing THIS
-- client right now (two Sandevistans can overlap; the slowest one wins).
local slowedBy = {}
-- How this client is dilated right now: nil, 'dilation' or 'timescale'.
local slowMode = nil
-- The owner's own boost: { activation, screen, dilated }.
local own = nil

--- The platform's dilation lease door, when this build has it.
-- @return table|nil
local function dilation()
	local api = Open77.dilation
	if type(api) == 'table' and type(api.authorise) == 'function' and type(api.apply) == 'function' then
		return api
	end
	return nil
end

--- Dilates this client through the lease door. Answers whether it took.
-- @param scale number how fast the world runs
-- @param ms integer
-- @param exemptSelf boolean
-- @return boolean
local function dilate(scale, ms, exemptSelf)
	local api = dilation()
	if api == nil then return false end
	local ran, leased = pcall(api.authorise, REASON, math.max(250, math.min(CAP_MS, ms)))
	if not ran or leased == false or leased == nil then return false end
	local request = { reason = REASON, worldScale = scale, durationMs = ms, easeOut = EASE_OUT,
		exemptSelf = exemptSelf == true }
	if not exemptSelf then request.playerScale = scale end
	local ran, ok = pcall(api.apply, request)
	return ran and ok ~= false and ok ~= nil
end

--- Gives the clock back through the lease door.
local function undilate()
	local api = Open77.dilation
	if type(api) ~= 'table' then return end
	if type(api.release) == 'function' then pcall(api.release, REASON, EASE_OUT) end
	if type(api.clear) == 'function' then pcall(api.clear, REASON) end
end

--- A client time scale (every body here slows, this player's included).
-- @param scale number
-- @param ms integer|nil nil releases
-- @param easeMs integer
-- @return boolean
-- @return string|nil why not
local function timeScale(scale, ms, easeMs)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.setTimeScale) ~= 'function' then return false, 'no_timescale' end
	local options = { easeMs = easeMs }
	if ms ~= nil then options.durationMs = math.floor(ms) end
	local ran, ok, why = pcall(world.setTimeScale, scale, options)
	if ran and ok == true then return true end
	return false, tostring(ran and why or ok)
end

--- The resource that ships the base game's own Sandevistan (config
--- `SANDEVISTAN.VIEW.RESOURCE`, opx_sandy_view), or nil when it is off.
-- @return string|nil
local function viewResource()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local name = type(sandy.VIEW) == 'table' and sandy.VIEW.RESOURCE or nil
	return type(name) == 'string' and name ~= '' and name or nil
end

--- One call into the view resource's client exports, synchronously. Answers
--- ok and, when not, why.
-- @param name string `engage`, `release` or `wear`
-- @return boolean
-- @return string|nil
local function viewCall(name, ...)
	local exports = Open77.exports
	local resource = viewResource()
	if resource == nil then return false, 'view_off' end
	if type(exports) ~= 'table' or type(exports.callSync) ~= 'function' then return false, 'no_sync_exports' end
	local ran, ok, why = pcall(exports.callSync, resource, name, ...)
	if not ran then return false, tostring(ok) end
	return ok == true, why ~= nil and tostring(why) or nil
end

--- The doors this build has, for the report.
-- @return table
local function doors()
	local world, vfx, exports = Open77.world, Open77.vfx, Open77.exports
	return {
		lease = dilation() ~= nil,
		timescale = type(world) == 'table' and type(world.setTimeScale) == 'function',
		screen = type(vfx) == 'table' and type(vfx.screen) == 'function',
		playEntity = type(vfx) == 'table' and type(vfx.playEntity) == 'function',
		callSync = type(exports) == 'table' and type(exports.callSync) == 'function',
	}
end

--- Sends the server what this machine did with one phase, for its journal.
-- @param fields table
local function report(fields)
	if type(TriggerServerEvent) ~= 'function' then return end
	pcall(TriggerServerEvent, Event.SANDYREPORT, fields)
end

--- Brings this client's clock in line with every boost slowing it: the
--- slowest live one, for as long as the longest lasts -- or real time.
--- Answers what holds the clock now: `timescale` or `dilation` (a door this
--- call took), `real` (nothing slows it), `own` (this player's own boost holds
--- it) -- or nil and why, when every door refused.
-- @param easeMs integer
-- @return string|nil
-- @return string|nil why not
local function reslow(easeMs)
	local now, scale, until_ = OPX.Now(), nil, 0
	for owner, row in pairs(slowedBy) do
		if row.expires <= now then
			slowedBy[owner] = nil
		else
			scale = scale == nil and row.scale or math.min(scale, row.scale)
			until_ = math.max(until_, row.expires)
		end
	end
	-- The owner's own boost owns this clock while it runs: a player in their
	-- own Sandevistan is not slowed by somebody else's (`ownStop` hands the
	-- clock back here when it ends).
	if own ~= nil then return 'own' end
	if scale == nil then
		if slowMode == 'dilation' then undilate() elseif slowMode == 'timescale' then timeScale(1, nil, easeMs) end
		slowMode = nil
		return 'real'
	end
	local ms = math.max(250, until_ - now)
	-- A player slowed by somebody ELSE's Sandevistan runs the platform's time
	-- scale, not a `sandevistan` dilation: that reason is the owner's alone, so
	-- the base game's Sandevistan screen (which answers to it) stays on the
	-- owner's eyes. The lease is the fallback for a build without the scale.
	local scaled, why = timeScale(scale, ms, easeMs)
	if scaled then
		slowMode = 'timescale'
		return 'timescale'
	end
	if dilate(scale, ms, false) then
		slowMode = 'dilation'
		return 'dilation'
	end
	return nil, why or 'refused'
end

--- The owner's screen for the boost: the look's SCREEN overlay, if any.
-- @param look table
-- @param seconds number
-- @return any handle
-- @return string|nil why not
local function screenOn(look, seconds)
	local screen = type(look.SCREEN) == 'table' and look.SCREEN or nil
	local vfx = Open77.vfx
	if screen == nil or type(screen.ALIAS) ~= 'string' then return nil, 'no_screen_in_look' end
	if type(vfx) ~= 'table' or type(vfx.screen) ~= 'function' then return nil, 'no_vfx_screen' end
	local options = { duration = math.max(0.5, math.min(600, seconds)) }
	if tonumber(screen.STRENGTH) ~= nil then options.strength = math.max(0, math.min(1, screen.STRENGTH)) end
	-- The engage flash first: a one-shot alias, nothing to stop.
	if type(screen.START) == 'string' and screen.START ~= '' then
		pcall(vfx.screen, screen.START, { duration = 1 })
	end
	local ran, handle, why = pcall(vfx.screen, screen.ALIAS, options)
	if ran and handle ~= nil and handle ~= false then return handle end
	return nil, tostring(ran and why or handle)
end

-- Defined below, used by ownStart.
local ownStop
local selfSound, clockRead, finish

-- The overdrive on this body, as `open77_reflex` itself reports it: whether it
-- is engaged, since when, and whether the server's Sandevistan for it came.
local watch = { active = false }

--- One of the look's own sounds on this player's own body (`SELF_SOUND`).
-- @param look table|nil
-- @param which string 'ENTER' or 'EXIT'
-- @return boolean
selfSound = function(look, which)
	local sounds = type(look) == 'table' and type(look.SELF_SOUND) == 'table' and look.SELF_SOUND or nil
	local event = sounds ~= nil and sounds[which] or nil
	local sfx = Open77.sfx
	if type(event) ~= 'string' or event == '' or type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then
		return false
	end
	local ran, handle = pcall(sfx.play, event, { entity = 1, duration = 4 })
	return ran and handle ~= nil and handle ~= false
end

--- What the engine's clock is on this machine right now, in words:
--- `Open77.world.getTimeScale`, the effective dilation and every claim.
-- @return string
clockRead = function()
	local world = Open77.world
	if type(world) ~= 'table' or type(world.getTimeScale) ~= 'function' then return 'unreadable on this build' end
	local ran, view, why = pcall(world.getTimeScale)
	if not ran or type(view) ~= 'table' then return 'unreadable (' .. tostring(ran and why or view) .. ')' end
	local claims = {}
	for _, claim in ipairs(type(view.claims) == 'table' and view.claims or {}) do
		claims[#claims + 1] = ('%s %.2f (%s)'):format(tostring(claim.owner), tonumber(claim.applied) or -1,
			tostring(claim.phase))
	end
	return ('world at %.2f, engine dilation %s; claims: %s'):format(tonumber(view.scale) or -1,
		view.engineActive == true and 'active' or 'off', #claims > 0 and table.concat(claims, ', ') or 'none')
end

--- A body's look ends: Smasher's end blink at its feet, and everything down.
-- @param player number
finish = function(player)
	local row = shown[player]
	if row ~= nil and row.started and not (row.mine and row.look.SELF == false) then
		blink(player, type(row.look.BLINK) == 'table' and row.look.BLINK.END or nil)
	end
	stop(player)
end

--- The owner's own boost begins: their screen, and the world slowing -- around
--- a body that does not where the build can exempt it, with it where not.
-- @param payload table
-- @param look table
-- @param remaining integer ms
local function ownStart(payload, look, remaining)
	if own ~= nil and own.activation == payload.activation then return end
	if own ~= nil then ownStop() end
	-- What somebody else's boost had this clock at, if anything.
	local previous = slowMode
	own = { activation = payload.activation, look = look, expires = OPX.Now() + remaining }
	local easeMs = math.max(0, math.min(2000, math.floor(tonumber(payload.easeMs) or 250)))
	local scale, fallback = tonumber(payload.scale), tonumber(payload.fallbackScale)
	local clock, clockWhy = 'real time', nil
	-- A SEATED OWNER KEEPS REAL TIME. This client simulates the vehicle it sits
	-- in for everybody else (the platform's physics owner), and a slowed world
	-- here is a slowed car or aircraft on every other screen -- the desync the
	-- server's own sweep now spares seated bystanders from. The boost, its look
	-- and its speed still land; only the clock is left alone.
	local vehicles = Open77.vehicles
	if type(vehicles) == 'table' and type(vehicles.getPlayerSeat) == 'function' then
		local asked, seat = pcall(vehicles.getPlayerSeat)
		if asked and type(seat) == 'table' and seat.vehicleId ~= nil then
			scale, fallback, clockWhy = nil, nil, 'seated in a vehicle: the clock stays real time'
		end
	end
	-- THE BASE GAME'S ASYMMETRY where the build has the lease: the world
	-- slows, this body does not.
	if scale ~= nil and scale > 0 and scale < 1 then
		own.dilated = dilate(math.max(0.05, scale), remaining, true)
		if own.dilated then
			slowMode, clock = 'dilation', ('%.2f, this body exempt'):format(scale)
		else
			clockWhy = dilation() == nil and 'no_dilation_lease_on_this_build' or 'dilation_refused'
		end
	end
	-- THE BASE GAME'S ASYMMETRY on every current build: the owner's clock
	-- claimed by the view resource at the look's own scale -- its reason is
	-- the owner's alone -- and its REDscript exempts this body from it and
	-- puts the camera on the Sandevistan curve. Only where the world ships
	-- the view (`payload.view`): the REDscript is what keeps this body fast.
	if not own.dilated and payload.view == true and scale ~= nil and scale > 0 and scale < 1 then
		local why
		own.viewed, why = viewCall('engage', math.max(0.05, scale), remaining, easeMs)
		if own.viewed then
			clock, clockWhy = ('%.2f, this body exempt (base game)'):format(scale), nil
		else
			clockWhy = (clockWhy and (clockWhy .. ', ') or '') .. 'view: ' .. tostring(why)
		end
	end
	-- Everywhere else: the whole view slows, this body with it.
	if not own.dilated and not own.viewed and scale ~= nil and scale < 1
		and fallback ~= nil and fallback > 0 and fallback < 1 then
		local why
		own.scaled, why = timeScale(math.max(0.05, fallback), remaining, easeMs)
		if own.scaled then
			slowMode, clock = 'timescale', ('%.2f, whole view'):format(fallback)
		else
			clockWhy = (clockWhy and (clockWhy .. ', ') or '') .. tostring(why)
		end
	end
	-- Being slowed by somebody else's boost ends with this one's start: a
	-- door this boost did not take over is let go.
	if previous == 'dilation' and not own.dilated then undilate() end
	if previous == 'timescale' and not own.scaled then timeScale(1, nil, easeMs) end
	if not own.dilated and not own.scaled then slowMode = nil end
	-- THE SCREEN. The base game's own is the camera's `Sandevistan` curve over
	-- a `sandevistan` dilation: with the lease taken and the world's view
	-- REDscript installed (`payload.view`, opx_sandy_view), that curve is what
	-- this player sees, set by the REDscript the frame the dilation lands, and
	-- nothing is laid over it. Anywhere else the look's stand-in overlay plays.
	local screen
	if (own.dilated or own.viewed) and payload.view == true then
		screen = 'the base game\'s own (camera curve Sandevistan)'
	else
		local why
		own.screen, why = screenOn(look, remaining / 1000)
		screen = own.screen ~= nil and 'stand-in overlay' or ('off (' .. tostring(why) .. ')')
	end
	Open77.log.info(('[ripperdoc] Sandevistan engaged for %d ms: world %s%s; screen %s'):format(
		remaining, clock, clockWhy and (' (' .. clockWhy .. ')') or '', screen))
	own.sounded = selfSound(look, 'ENTER')
	report({ activation = payload.activation, role = 'owner', clock = clock, why = clockWhy, screen = screen,
		view = payload.view == true, doors = doors(), remainingMs = remaining })
	-- THE CLOCK, READ BACK FROM THE ENGINE once the ease has landed: what the
	-- world really runs at on this machine, and whose claims hold it.
	local activation = payload.activation
	if type(CreateThread) == 'function' then
		CreateThread(function()
			Wait(math.max(300, easeMs + 400))
			if own == nil or own.activation ~= activation then return end
			local read = clockRead()
			own.read = read
			say('Sandevistan clock on this machine: ' .. read)
			report({ activation = activation, role = 'clock', clock = read })
		end)
	end
end

--- The owner's own boost ends.
ownStop = function()
	local row = own
	own = nil
	if row == nil then return end
	local vfx = Open77.vfx
	if row.screen ~= nil and type(vfx) == 'table' and type(vfx.stop) == 'function' then
		pcall(vfx.stop, row.screen)
	end
	if row.dilated then
		undilate()
	elseif row.viewed then
		viewCall('release', 250)
	elseif row.scaled then
		timeScale(1, nil, 250)
	end
	if row.dilated or row.scaled then slowMode = nil end
	if row.sounded then selfSound(row.look, 'EXIT') end
	say(('Sandevistan over on this body: %s'):format(row.dilated and 'the lease given back'
		or row.viewed and 'the view\'s claim given back' or row.scaled and 'real time again'
		or 'nothing held the clock'))
	-- Somebody else's Sandevistan may still be slowing this client.
	reslow(250)
end

--- The owner sat down in a vehicle mid-boost: this machine's clock goes back
--- to real time and the boost itself goes on. See `ownStart`: a seated client
--- simulates its vehicle for every other screen, and a slowed world here is a
--- vehicle that crawls and lurches everywhere else (a MaxTac AV pilot boarded
--- mid-boost on 2026-09-28 at 23:44:07 and flew the first 25 s of the flight on
--- a slowed clock).
-- @return boolean whether the clock was handed back
function Sandy.OwnSeated()
	if own == nil or not (own.dilated or own.viewed or own.scaled) then return false end
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return false end
	local asked, seat = pcall(vehicles.getPlayerSeat)
	if not asked or type(seat) ~= 'table' or seat.vehicleId == nil then return false end
	if own.dilated then
		undilate()
	elseif own.viewed then
		viewCall('release', 250)
	elseif own.scaled then
		timeScale(1, nil, 250)
	end
	own.dilated, own.viewed, own.scaled = false, false, false
	slowMode = nil
	say('Sandevistan: seated in a vehicle -- this machine\'s clock is back to real time, the boost goes on')
	return true
end

--- A slowdown for somebody else's boost, in this machine's journal: what
--- took it, once per boost, then -- once the ease has landed -- the engine's
--- own clock, told to the server too (role `slowed`). "The other player's time
--- did not slow" is read back from here, and from the server's journal.
-- @param player number the boosted player
-- @param activation string
-- @param scale number
-- @param remaining integer ms
-- @param easeMs integer
-- @param door string|nil what `reslow` answered
-- @param why string|nil
local function slowSaid(player, activation, scale, remaining, easeMs, door, why)
	local how = door == 'timescale' and 'this client\'s time scale (the world and this body)'
		or door == 'dilation' and 'the dilation lease (the world and this body)'
		or door == 'own' and 'not yet: this player\'s own boost holds the clock'
		or ('REFUSED: ' .. tostring(why))
	say(('Sandevistan: player %d\'s boost slows this machine -- world %.2f for %d ms, %s'):format(player, scale,
		math.floor(remaining), how))
	if type(CreateThread) ~= 'function' then return end
	CreateThread(function()
		Wait(math.max(300, easeMs + 400))
		local row = slowedBy[player]
		if row == nil or row.activation ~= activation then return end
		local read = clockRead()
		say(('Sandevistan clock on this machine, slowed by player %d: %s'):format(player, read))
		report({ activation = activation, role = 'slowed', owner = player, door = door, why = why, clock = read,
			doors = doors() })
	end)
end

--- One phase of one boost, from the server.
-- @param payload table
function Sandy.OnPhase(payload)
	if type(payload) ~= 'table' then return end
	local player = tonumber(payload.player)
	if player == nil or player <= 0 or player % 1 ~= 0 then return end
	local phase = payload.phase
	local easeMs = math.max(0, math.min(2000, math.floor(tonumber(payload.easeMs) or 250)))
	-- THIS client is asked to slow for somebody else's boost, or let go.
	if phase == 'slow' then
		local scale = tonumber(payload.scale)
		if scale == nil or scale <= 0 or scale >= 1 or isMine(player) then return end
		local remaining = math.max(250, math.min(CAP_MS, tonumber(payload.remainingMs) or 6000))
		local before = slowedBy[player]
		slowedBy[player] = { activation = payload.activation, scale = math.max(0.05, scale),
			expires = OPX.Now() + remaining }
		local door, why = reslow(easeMs)
		if before == nil or before.activation ~= payload.activation then
			slowSaid(player, payload.activation, math.max(0.05, scale), remaining, easeMs, door, why)
		end
		return
	end
	if phase == 'release' then
		if slowedBy[player] == nil then return end
		slowedBy[player] = nil
		local door = reslow(easeMs)
		say(('Sandevistan: player %d\'s boost no longer slows this machine -- %s'):format(player,
			door == 'real' and 'real time again' or door == 'own' and 'this player\'s own boost holds the clock'
				or 'another boost still slows it'))
		return
	end
	local mine = isMine(player)
	if mine and (phase == 'accepted' or phase == 'active' or phase == 'completed' or phase == 'cancelled') then
		watch.phaseSeen = true
		say(('Sandevistan %s from the server for this player: look %s, tier %s%s%s'):format(tostring(phase),
			tostring(payload.look or '-'), tostring(payload.tier or '-'),
			phase == 'active' and (', ' .. tostring(payload.remainingMs) .. ' ms') or '',
			phase == 'active' and (', base-game view ' .. (payload.view == true and 'shipped' or 'NOT shipped')) or ''))
	end
	if phase == 'completed' or phase == 'cancelled' then
		-- Only the boost it names: a late end of an older one (the server's
		-- own deadline, then the platform's) must not cut a newer boost short.
		local named = payload.activation
		if mine and own ~= nil and (named == nil or own.activation == nil or own.activation == named) then ownStop() end
		local row = shown[player]
		if row ~= nil and (named == nil or row.activation == nil or row.activation == named) then finish(player) end
		return
	end
	local look = lookOf(payload.look)
	if look == nil then
		if mine then say('Sandevistan: the server named a look this client does not carry: ' .. tostring(payload.look)) end
		return
	end
	if phase == 'accepted' then
		-- Smasher's blink at the body's feet, and the effects the body itself
		-- authors for a Sandevistan's start (everybody else's body only).
		local entity, isSelf = bodyOf(player)
		if entity == nil and not isSelf then return end
		if not (isSelf and look.SELF == false) then blink(player, type(look.BLINK) == 'table' and look.BLINK.START or nil) end
		if not isSelf then
			playNames(look.START, entity, math.max(0.2, tonumber(look.START_SECONDS) or 1.5), nil)
		end
		return
	end
	if phase ~= 'active' then return end
	local remaining = math.max(500, math.min(CAP_MS, tonumber(payload.remainingMs) or 6000))
	if mine then ownStart(payload, look, remaining) end
	stop(player)
	local row = { look = look, tier = tostring(payload.tier or 'reflex'),
		expires = OPX.Now() + remaining, handles = {}, plated = false, started = false,
		activation = payload.activation, mine = mine, view = mine and payload.view == true }
	shown[player] = row
	start(player, row)
	Sandy.Observed(player, row)
end

--- Reports, once per boost, what this machine drew on somebody ELSE's body:
--- how many of the look's authored effects it started on it. A body that is
--- not streamed yet is reported the moment it arrives.
-- @param player number
-- @param row table
function Sandy.Observed(player, row)
	if row == nil or row.reported or not row.started or row.mine then return end
	row.reported = true
	local on = 0
	for _, state in pairs(row.layers or {}) do if state.plays > 0 then on = on + 1 end end
	report({ activation = row.activation, role = 'observer', owner = player, plays = #row.handles,
		layers = on, plated = row.plated == true, doors = doors() })
end

-- ── the chair and the lost power ────────────────────────────────────────

--- Waits for the body to be really free, then hands the token back. One wait
--- at a time; a newer token supersedes it.
-- @param token string
local function awaitFreeBody(token)
	waiting = token
	CreateThread(function()
		local deadline, free = OPX.Now() + 60000, 0
		while running and waiting == token and OPX.Now() < deadline do
			-- Two reads in a row, half a second apart: the workspot's exit is
			-- an animation, and a body read free on its first frame of it is
			-- not free yet.
			free = Sandy.BodyFree() and free + 1 or 0
			if free >= 2 then
				waiting = nil
				TriggerServerEvent(Event.REPROJECT, token)
				return
			end
			Wait(500)
		end
		if waiting == token then waiting = nil end
	end)
end

-- What the journal last said of the projection ('ready' / 'absent').
local projectionSaid = nil

--- `open77_reflex`'s own reading of the overdrive on this body -- `phase`,
--- `kind`, `remainingMs` -- or nil when it holds none or cannot be asked.
-- @return table|nil
local function overdriveState()
	local exports = Open77.exports
	if type(exports) ~= 'table' or type(exports.callSync) ~= 'function' then return nil end
	local ran, state = pcall(exports.callSync, M.Ripper.SandyMapping().RESOURCE, 'state')
	if not ran then return nil, true end
	if type(state) ~= 'table' then return nil end
	return state
end

--- One pass of the overdrive watch: the overdrive engaging on this body is
--- written to the journal, and so is a Sandevistan the server never sent for
--- it -- the one line that says which half of the chain to look at.
-- @param now number
function Sandy.WatchOverdrive(now)
	if kit.reflex == nil then return end
	if watch.quietUntil ~= nil and now < watch.quietUntil then return end
	local state, unanswered = overdriveState()
	if unanswered then
		watch.quietUntil = now + 5000
		return
	end
	local engaged = state ~= nil and state.phase == 'active'
	if engaged and not watch.active then
		watch.active, watch.since, watch.phaseSeen, watch.warned = true, now, false, false
		say(('the overdrive engaged on this body (%s, %s ms left) -- %s'):format(tostring(state.kind),
			tostring(state.remainingMs), own ~= nil and 'the Sandevistan is already on' or
			'waiting for the server\'s Sandevistan'))
		if own ~= nil then watch.phaseSeen = true end
	elseif not engaged and watch.active then
		watch.active = false
		-- A boost the level lengthened goes on after the platform's overdrive
		-- (its speed) is over: the look, the slowed world and the screen are
		-- the ripperdoc's, to their own end.
		say(own ~= nil and own.expires ~= nil and own.expires > now
			and ('the overdrive on this body ended; the Sandevistan runs on for %d ms (the character\'s level)')
				:format(math.floor(own.expires - now))
			or 'the overdrive on this body ended')
	end
	if watch.active and not watch.phaseSeen and not watch.warned and now - watch.since >= 3000
		and type(kit.reflex) == 'table' and kit.reflex.look ~= nil then
		watch.warned = true
		say(('the overdrive engaged here %d ms ago and the server sent no Sandevistan for it: the server ' ..
			'did not draw it -- its journal says why ("overdrive accepted ... look ...")'):format(now - watch.since))
	end
end

--- Whether `open77_reflex` on this machine holds an overdrive projection,
--- or nil when it cannot be asked. Yields (an export answers a promise).
-- @return boolean|nil
local function holdsOverdrive()
	local exports = Open77.exports
	if type(exports) ~= 'table' or type(exports.call) ~= 'function' then return nil end
	local ran, pending = pcall(exports.call, M.Ripper.SandyMapping().RESOURCE, 'capabilities')
	if not ran or pending == nil then return nil end
	local value = pending
	if type(pending) == 'table' and type(pending.await) == 'function' then
		local done, answer = pcall(pending.await, pending)
		if not done then return nil end
		value = answer
	end
	if type(value) ~= 'table' or type(value.projection) ~= 'string' then return nil end
	return value.projection ~= 'absent'
end

--- One pass of the lost-power watch. Yields.
function Sandy.Watch()
	-- A power the server HOLDS BACK until its cooldown ends (the boost ran
	-- longer than the platform's) is not lost: nothing is asked for it.
	if kit.reflex == nil or kit.reflex.held == true or waiting ~= nil or not Sandy.BodyFree() then
		absentSince = nil
		return
	end
	local holds = holdsOverdrive()
	-- The answer is a promise: the kit may have changed while it came.
	if kit.reflex == nil then return end
	if holds == true and projectionSaid ~= 'ready' then
		projectionSaid = 'ready'
		Sandy.WearAgain(OPX.Now())
		say(('the overdrive is on this client (open77_reflex projection ready): %s engages %s'):format(
			Sandy.EffectiveKey('reflex'), tostring(kit.reflex.entry)))
	end
	if holds ~= false then
		absentSince, lostSaid = nil, false
		return
	end
	projectionSaid = 'absent'
	local now = OPX.Now()
	absentSince = absentSince or now
	if now - absentSince < ABSENT_GRACE_MS then return end
	if askedAt ~= nil and now - askedAt < ASK_EVERY_MS then return end
	askedAt = now
	-- Said once per loss, not once per ask: the server may answer "not yet"
	-- (the power's own cooldown) for a while, and this asks again meanwhile.
	if not lostSaid then
		lostSaid = true
		Open77.log.info('[ripperdoc] the overdrive the server holds is not on this client; asking for it again')
	end
	-- '' AND NOT nil: a nil first argument is exactly what a transport that
	-- packs arguments may drop, which would shift 'reflex' into the token.
	TriggerServerEvent(Event.REPROJECT, '', 'reflex')
end

-- ── the real item ───────────────────────────────────────────────────────

-- code: what this machine asks for now (nil before the first kit); sent: the
-- last code the view took; due: when to send it (ms, ascending); said: the
-- journal's last line about it.
local wear = { code = nil, sent = nil, due = {}, said = nil }
local WEAR_AGAIN_MS = { 0, 4000, 12000 }

--- The code the held Sandevistan asks for (`SANDEVISTAN.WEAR`), 0 for none.
-- @return integer
local function wearCode()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local codes = type(sandy.WEAR) == 'table' and sandy.WEAR or {}
	local held = type(kit.reflex) == 'table' and kit.reflex or nil
	if held == nil then return 0 end
	local code = tonumber(codes[held.entry])
	if code == nil or code ~= math.floor(code) or code < 1 or code > 9 then return 0 end
	return code
end

--- Asks for the item again from `now` on (the kit changed, or a new body).
-- @param now number ms
function Sandy.WearAgain(now)
	local code = wearCode()
	-- Nothing to take off from a player this machine never fitted.
	if code == 0 and wear.sent == nil and wear.code == nil then return end
	wear.code = code
	wear.due = {}
	for _, after in ipairs(WEAR_AGAIN_MS) do wear.due[#wear.due + 1] = now + after end
end

--- One pass of the item's sender, from the quarter-second watch.
-- @param now number ms
function Sandy.WearTick(now)
	if wear.code == nil or #wear.due == 0 or wear.due[1] > now then return end
	-- Never over a boost: the boost's claim is the one that must hold.
	if own ~= nil then return end
	table.remove(wear.due, 1)
	local ok, why = viewCall('wear', wear.code)
	if ok then wear.sent = wear.code end
	local line = ('Sandevistan real item: asked the view for code %d (%s) -- %s'):format(wear.code,
		wear.code == 0 and 'none' or 'the base game\'s own item in the Operating System slot',
		ok and 'sent' or ('not sent: ' .. tostring(why)))
	if line ~= wear.said then
		wear.said = line
		say(line)
	end
end

--- What the item's sender holds, for the tests.
-- @return table
function Sandy.Wear()
	return wear
end

-- ── the key ─────────────────────────────────────────────────────────────

--- `/opx.sandy.key`, on this machine: '' says the key, 'reset' restores the
--- default, anything else is the new key (already checked by the server).
-- @param wanted string
function Sandy.Rebind(wanted)
	local mapping = M.Ripper.SandyMapping()
	local input = Open77.input
	wanted = type(wanted) == 'string' and wanted or ''
	if wanted ~= '' and (type(input) ~= 'table' or type(input.rebind) ~= 'function'
		or type(input.reset) ~= 'function') then
		return toast('ripperdoc.key.unavailable', nil, 'error')
	end
	if wanted == 'reset' then
		local ran, ok, detail = pcall(input.reset, mapping.RESOURCE, mapping.ID)
		if not ran or ok == false then
			return toast('ripperdoc.key.refused', { why = tostring(ran and detail or ok) }, 'error')
		end
	elseif wanted ~= '' then
		local ran, ok, detail = pcall(input.rebind, mapping.RESOURCE, mapping.ID, wanted)
		if not ran or ok == false then
			return toast('ripperdoc.key.refused', { why = tostring(ran and detail or ok) }, 'error')
		end
	end
	toast(wanted == '' and 'ripperdoc.key.current' or 'ripperdoc.key.set',
		{ key = Sandy.EffectiveKey('reflex') }, 'info')
end

-- ── the doors ───────────────────────────────────────────────────────────

-- What the journal last said of the kit, and of a power held back.
local kitSaid = nil
local heldSaid = false

--- What the server holds on this player, and what it asks this machine to do.
-- @param payload table
function Sandy.OnKit(payload)
	if type(payload) ~= 'table' then return end
	kit = type(payload.grants) == 'table' and payload.grants or {}
	if kit.reflex == nil then absentSince, askedAt = nil, nil end
	-- The journal: what the server says this player holds, once per change.
	local held = type(kit.reflex) == 'table' and kit.reflex or nil
	local said = held ~= nil and (tostring(held.entry) .. '|' .. tostring(held.look) .. '|' .. tostring(held.key))
		or 'none'
	if said ~= kitSaid then
		kitSaid = said
		Sandy.WearAgain(OPX.Now())
		if held ~= nil then
			say(('Sandevistan: the server says this player holds %s (look %s); engaged on %s'):format(
				tostring(held.entry), tostring(held.look or 'the platform\'s own'), Sandy.EffectiveKey('reflex')))
		else
			say('Sandevistan: the server says this player holds no overdrive')
			projectionSaid = nil
		end
	end
	-- HELD BACK: the power is still this player's (its real item stays on) but
	-- nothing engages it until the boost it gave is over and its cooldown has
	-- passed. Said once each way.
	local heldNow = held ~= nil and held.held == true
	if heldNow ~= heldSaid then
		heldSaid = heldNow
		if heldNow then
			absentSince, askedAt = nil, nil
			say(('Sandevistan: %s is held back until the boost is over and its cooldown has passed')
				:format(tostring(held.entry)))
		elseif held ~= nil then
			say(('Sandevistan: %s is back -- its cooldown is over'):format(tostring(held.entry)))
		end
	end
	if type(payload.announce) == 'string' then
		for kind, held in pairs(kit) do
			if type(held) == 'table' and held.entry == payload.announce then
				toast('ripperdoc.howto.' .. kind, {
					name = locale(type(held.name) == 'string' and held.name or held.entry),
					key = Sandy.EffectiveKey(kind),
				}, 'info')
			end
		end
	end
	-- The token rides every kit until it is handed back; a wait already
	-- running for it is not started twice.
	if type(payload.reproject) == 'string' and payload.reproject ~= ''
		and payload.reproject ~= waiting then
		awaitFreeBody(payload.reproject)
	end
end

--- What this machine holds, for the tests and the page.
-- @return table
function Sandy.Kit()
	return kit
end

--- The bodies wearing a look right now, for the tests.
-- @return table player -> row
function Sandy.Shown()
	return shown
end

--- One body's look, one quarter second on: its deadline, its first draw,
--- a body that came back under a new handle (drawn again whole), and the
--- trails that are due.
-- @param player number
-- @param row table
-- @param now number
function Sandy.Tick(player, row, now)
	if now >= row.expires then
		if row.mine then ownStop() end
		return finish(player)
	end
	if not row.started then
		start(player, row)
		return Sandy.Observed(player, row)
	end
	local entity = lookEntity(player)
	if entity ~= nil and row.entity ~= nil and tostring(entity) ~= tostring(row.entity) then
		local vfx = Open77.vfx
		for _, handle in ipairs(row.handles) do
			if type(vfx) == 'table' and type(vfx.stop) == 'function' then pcall(vfx.stop, handle) end
		end
		row.handles, row.layers, row.started = {}, nil, false
		return start(player, row)
	end
	-- A trail is two seconds long: restarted where it is due.
	layers(player, row, now)
end

--- Wires the doors and the two watches.
function Sandy.Start()
	running = true
	RegisterNetEvent(Event.KIT, function(payload)
		local ran, failure = pcall(Sandy.OnKit, payload)
		if not ran then Open77.log.warn('[ripperdoc] the kit raised: ' .. tostring(failure)) end
	end)
	RegisterNetEvent(Event.SANDY, function(payload)
		local ran, failure = pcall(Sandy.OnPhase, payload)
		if not ran then Open77.log.warn('[ripperdoc] the Sandevistan look raised: ' .. tostring(failure)) end
	end)
	RegisterNetEvent(Event.KEYBIND, function(wanted)
		local ran, failure = pcall(Sandy.Rebind, wanted)
		if not ran then Open77.log.warn('[ripperdoc] the key command raised: ' .. tostring(failure)) end
	end)
	-- THE LOOKS: a held look whose body was not streamed is started when it
	-- arrives, and every look ends at its own deadline whatever the wire says --
	-- and so does every slowdown and the owner's own boost.
	CreateThread(function()
		while running do
			Wait(250)
			local now = OPX.Now()
			for player, row in pairs(shown) do
				local ran, failure = pcall(Sandy.Tick, player, row, now)
				if not ran then Open77.log.warn('[ripperdoc] the Sandevistan look raised: ' .. tostring(failure)) end
			end
			-- The owner's own boost ends at its own deadline, whatever else is read.
			if own ~= nil and own.expires ~= nil and now >= own.expires + 500 then pcall(ownStop) end
			-- And gives the clock back the moment the owner sits in a vehicle.
			if own ~= nil then pcall(Sandy.OwnSeated) end
			local ran, failure = pcall(Sandy.WatchOverdrive, now)
			if not ran then Open77.log.warn('[ripperdoc] the overdrive watch raised: ' .. tostring(failure)) end
			ran, failure = pcall(Sandy.WearTick, now)
			if not ran then Open77.log.warn('[ripperdoc] the real item raised: ' .. tostring(failure)) end
			local stale = false
			for _, row in pairs(slowedBy) do
				if row.expires <= now then stale = true end
			end
			if stale then reslow(250) end
		end
	end)
	-- THE LOST-POWER WATCH, every two seconds.
	CreateThread(function()
		while running do
			Wait(2000)
			if not running then return end
			local ran, failure = pcall(Sandy.Watch)
			if not ran then Open77.log.warn('[ripperdoc] the overdrive watch raised: ' .. tostring(failure)) end
		end
	end)
end

--- Takes every look down with the module.
function Sandy.Stop()
	running = false
	waiting = nil
	for player in pairs(shown) do stop(player) end
	shown = {}
	-- The clock goes back with the module, whichever door moved it.
	slowedBy = {}
	ownStop()
	reslow(0)
end

--- Who is slowing this client, for the tests.
-- @return table owner -> row
function Sandy.SlowedBy()
	return slowedBy
end
