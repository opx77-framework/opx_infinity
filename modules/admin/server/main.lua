--- The server half's spine: answers, the audit, the readiness gate, placement and
--- the command registry every staff command file registers through.
-- @author dop42
--
-- THE ACL IS THE ONLY AUTHORITY. `M.Server.Command` is a thin wrapper over
-- `OPX.Command.Register(name, { restricted = true }, handler)`: the host resolves
-- `command.<name>` before the handler runs, and core owns the suggestion list and
-- only offers a restricted command to a player the ACL would let run it. No
-- handler in this module checks a permission, and none should -- the host has
-- already decided, and a second check would only diverge from it. There is no
-- argument for registering an unrestricted command: every one of them acts on the
-- world or on somebody.
--
-- `M.Server.Permitted` asks the ACL the same question, but only where there is no
-- command to resolve: the menu's access map, the refresh event, the travel-mode
-- revocation sweep, and who counts as staff for a name tag badge. It answers nil
-- when the host has no ACL reader, which callers read as "cannot say"; the
-- console is always allowed.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

--- Server-half helpers every staff command file reads.
M.Server = {}
local Server = M.Server

-- What a placement kill is attributed to.
local RESOURCE = GetCurrentResourceName()

-- Catalogue key a player reads for each refusal code. The codes stay codes in the
-- audit and the log; only a player reads the catalogue.
local ERRORS = {
	in_game_only = 'admin.error.inGameOnly',
	too_fast = 'admin.error.tooFast',
	failed = 'admin.error.failed',
	no_target = 'admin.error.noTarget',
	bad_target = 'admin.error.badTarget',
	console_has_no_player = 'admin.error.consoleNoPlayer',
	not_connected = 'admin.error.notConnected',
	self_target = 'admin.error.selfTarget',
	not_incarnated = 'admin.error.notIncarnated',
	gate_closed = 'admin.error.gateClosed',
	gate_unreadable = 'admin.error.gateUnreadable',
	no_position = 'admin.error.noPosition',
	kill_refused = 'admin.error.killRefused',
	respawn_refused = 'admin.error.respawnRefused',
	refused = 'admin.error.refused',
	bad_coordinates = 'admin.error.badCoordinates',
	bad_switch = 'admin.error.badSwitch',
	bad_duration = 'admin.error.badDuration',
	empty_text = 'admin.error.emptyText',
	unknown_vehicle = 'admin.error.unknownVehicle',
	vehicle_cap = 'admin.error.vehicleCap',
	no_vehicle = 'admin.error.noVehicle',
	occupied = 'admin.error.occupied',
	unsafe_repair = 'admin.error.unsafeRepair',
	bad_scope = 'admin.error.badScope',
	unknown_flag = 'admin.error.unknownFlag',
	not_ours = 'admin.error.notOurs',
	vehicles_unavailable = 'admin.error.vehiclesUnavailable',
	unknown_weapon = 'admin.error.unknownWeapon',
	holster_unavailable = 'admin.error.holsterUnavailable',
	unknown_ammo = 'admin.error.unknownAmmo',
	give_partial = 'admin.error.givePartial',
	inventory_unavailable = 'admin.error.inventoryUnavailable',
	bad_holder = 'admin.error.badHolder',
	no_character = 'admin.error.noCharacter',
	unknown_citizen = 'admin.error.unknownCitizen',
	unknown_item = 'admin.error.unknownItem',
	bad_count = 'admin.error.badCount',
	not_enough = 'admin.error.notEnough',
	bad_amount = 'admin.error.badAmount',
	bad_type = 'admin.error.badType',
	vetoed = 'admin.error.vetoed',
	bag_no_room = 'admin.error.bagNoRoom',
	bag_too_heavy = 'admin.error.bagTooHeavy',
	unknown_location = 'admin.error.unknownLocation',
	bad_location_name = 'admin.error.badLocationName',
	seeded_location = 'admin.error.seededLocation',
	bad_door = 'admin.error.badDoor',
	door_limit = 'admin.error.doorLimit',
	doors_networked = 'admin.error.doorsNetworked',
	doors_unavailable = 'admin.error.doorsUnavailable',
	combat_unavailable = 'admin.error.combatUnavailable',
	unknown_ped = 'admin.error.unknownPed',
	models_unavailable = 'admin.error.modelsUnavailable',
	bad_name = 'admin.error.badName',
	characters_unavailable = 'admin.error.charactersUnavailable',
	search_short = 'admin.error.searchShort',
	bad_request = 'admin.error.badRequest',
}

-- Refusal codes about typed input, answered as warnings rather than errors.
local TYPED = {
	too_fast = true, no_target = true, bad_target = true, self_target = true,
	bad_coordinates = true, bad_switch = true, bad_duration = true, empty_text = true,
	unknown_vehicle = true, bad_scope = true, unknown_flag = true, unknown_weapon = true,
	unknown_location = true, bad_location_name = true, bad_holder = true, unknown_citizen = true,
	unknown_item = true, bad_count = true, not_enough = true, unknown_ammo = true,
	bad_door = true, unknown_ped = true, bad_name = true, search_short = true,
	bad_amount = true, bad_type = true,
}

-- The catalogue key a multi-line report is answered with.
local REPORT = 'admin.text.lines'

--- Host-monotonic milliseconds.
-- @author dop42
-- @return integer
function Server.NowMs()
	return OPX.Now()
end

--- A configured number, or the fallback for anything arithmetic would raise on.
-- @author dop42
-- @param value any
-- @param fallback number
-- @return number
function Server.Setting(value, fallback)
	return M.Number(value, fallback)
end

--- How many arguments were typed.
-- `args.n` is authoritative: `#args` reads a hole as the end of the list.
-- @author dop42
-- @param args table
-- @return integer
function Server.Count(args)
	local given = Text.Integer(args.n)
	if given == nil or given < 0 then return #args end
	return given
end

--- One answer back to whoever ran the command.
-- A report goes to the chat log through core's own answer channel, so that
-- whatever draws a chat log draws it and nothing has to name this module. Every
-- other answer goes to this module's client half on its own channel, because it
-- carries the typed line: that is what lets the menu put the answer under its
-- own list instead of only raising a toast.
-- @author dop42
-- @param source Source
-- @param raw string the typed line
-- @param ok boolean
-- @param key string catalogue key
-- @param params table|nil
-- @param kind string|nil info, success, warning or error; inferred when nil
-- @return boolean ok
function Server.Answer(source, raw, ok, key, params, kind)
	local player = tonumber(source) or 0
	if player <= 0 then
		local line = locale(key, params)
		if ok then Open77.log.info(line) else Open77.log.warn(line) end
		return ok == true
	end

	if key == REPORT then
		return OPX.CommandResult(player, ok == true, locale(key, params)) or ok == true
	end

	if kind == nil then
		if ok then
			kind = 'success'
		else
			kind = key:sub(1, 12) == 'admin.usage.' and 'warning' or 'error'
		end
	end
	TriggerClientEvent(M.Event.ANSWER, player, raw or '', ok == true, locale(key, params), kind)
	return ok == true
end

--- Answers a refusal by its code, with the host's own reason when it gave one.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param code string
-- @param params table|nil
-- @return boolean false
function Server.Refuse(source, raw, code, params)
	params = params or {}
	params.code = code
	params.reason = params.reason and M.Trimmed(params.reason, 64) or code
	Server.Answer(source, raw, false, ERRORS[code] or ERRORS.failed, params,
		TYPED[code] and 'warning' or 'error')
	return false
end

--- Raises a toast on the target player's screen, best effort.
-- A missing notification surface never fails the action that already happened.
-- @author dop42
-- @param playerId Source
-- @param key string catalogue key
-- @param params table|nil
-- @param kind string|nil
function Server.Tell(playerId, key, params, kind)
	pcall(OPX.Notify, playerId, locale(key, params), kind or 'info',
		math.floor(OPX.Tune.Number('ADMIN_TOAST_MS', 1000)))
end

--- The Master-verified display name, cleaned for a log line or a row.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.NameOf(playerId)
	local read, name = pcall(OPX.DisplayNameOf, playerId)
	if not read then return nil end
	return M.Trimmed(name, 32)
end

--- The durable account id of a connected player.
-- A player id is recycled; this is what an audit line keeps.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.UserOf(playerId)
	if (tonumber(playerId) or 0) <= 0 then return nil end
	local read, identifier = pcall(OPX.UserIdOf, playerId)
	if not read then return nil end
	return M.Trimmed(identifier, 64)
end

--- The name of the CHARACTER a player is playing, or nil.
--
-- Read off the replicated state bag and not through the `character` contract, and
-- that is the point rather than a shortcut: this module then says nothing at all
-- about who publishes the key. A runtime whose characters come from somewhere
-- else writes the same `name` and every staff line here follows it; a runtime
-- with no character module at all loses a name and keeps working.
--
-- Nil is an ordinary answer twice over: for somebody still at the selection
-- screen, and for a character that has not been named yet -- a character is a row
-- before it is anybody.
-- @author dop42
-- @param playerId Source
-- @return string|nil
-- One string key off a player's replicated bag, or nil. Reading a bag costs no
-- permission and no round trip; a host that does not replicate them answers nil
-- for everything, which is the same answer as a slot with no character on it.
local function bagKey(playerId, key)
	local state = Open77.state
	if type(state) ~= 'table' or type(state.player) ~= 'function' then return nil end
	if (tonumber(playerId) or 0) <= 0 then return nil end
	local read, bag = pcall(state.player, playerId)
	if not read or type(bag) ~= 'table' then return nil end
	-- `bag:get(key)` and not `bag.key`: five key names are shadowed by the handle's
	-- own methods, and a reader that used the sugar would answer a function for a
	-- key called `name` on a platform that ever added one.
	local got, value = pcall(bag.get, bag, key)
	if not got then return nil end
	return value
end

function Server.CharacterOf(playerId)
	return M.Trimmed(bagKey(playerId, 'name'), 64)
end

--- The public id of the character a player is playing, off the same bag.
-- Seven symbols in a three-dash-four group, and the one thing on a staff line
-- that survives a rename. Nil before a character is loaded.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.CitizenBagOf(playerId)
	return M.Trimmed(bagKey(playerId, 'citizenId'), 32)
end

--- What a staff line calls a player: the character, and the account behind it.
--
-- BOTH, ALWAYS, and never one or the other. A staff line naming only the
-- character cannot be matched to a ban, an audit row or a support ticket, all of
-- which are keyed on the account; a line naming only the account says nothing
-- about the person everybody else in the city was talking to. Nil means not
-- connected, which is what every caller of `NameOf` used it to mean.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.LabelOf(playerId)
	local user = Server.NameOf(playerId)
	if user == nil then return nil end
	local character = Server.CharacterOf(playerId)
	if character == nil then return user end
	return ('%s (%s)'):format(character, user)
end

--- The citizen id of the character a player has loaded, or nil.
-- Read through the `character` contract, never off that module's namespace.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.CitizenOf(playerId)
	local character = OPX.Api.Get('character')
	if character == nil or (tonumber(playerId) or 0) <= 0 then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	return player.PlayerData.citizenId
end

--- Every connected player id, sorted.
-- @author dop42
-- @return integer[]
function Server.PlayerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = tonumber(value)
		if id and id > 0 then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

-- Resolves a typed target to a connected player id, or the caller.
local function targetOf(source, token)
	if token == nil then return nil, 'no_target' end
	local word = tostring(token):lower()
	if word == 'me' or word == 'self' then
		if source <= 0 then return nil, 'console_has_no_player' end
		return source, nil
	end
	local playerId = Text.Integer(token)
	if playerId == nil or playerId <= 0 then return nil, 'bad_target' end
	if Server.NameOf(playerId) == nil then return nil, 'not_connected' end
	return playerId, nil
end

--- Resolves a typed target to a connected player, or answers why not.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param token any
-- @return integer|nil
function Server.Target(source, raw, token)
	local playerId, code = targetOf(source, token)
	if playerId == nil then Server.Refuse(source, raw, code) end
	return playerId
end

--- The replicated position and routing bucket, or nil before the world is up.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function Server.PositionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = Text.Finite(position.x), Text.Finite(position.y), Text.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = Text.Integer(position.bucket) or 0 }
end

--- The host's life state for a player, or nil: loading and the selection screen
--- have none.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function Server.LifeOf(playerId)
	local read, life = pcall(Open77.players.getLifeState, playerId)
	if not read or type(life) ~= 'table' then return nil end
	return life
end

--- Whether a player's body may be acted on at all.
-- Fails CLOSED when the gate cannot be read: nothing may teleport, spawn, kill or
-- respawn a player until their readiness gate has opened, and an unreadable gate
-- is not an open one. Kick and ban do not come through here.
-- @author dop42
-- @param playerId Source
-- @return boolean admitted
-- @return table|string the life state, or the refusal code
function Server.Admit(playerId)
	local life = Server.LifeOf(playerId)
	if life == nil then return false, 'not_incarnated' end
	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then
		return false, 'gate_unreadable'
	end
	local read, open = pcall(ready.isReady, playerId)
	if not read then return false, 'gate_unreadable' end
	if open ~= true then return false, 'gate_closed' end
	return true, life
end

--- `Admit`, with a closed gate answered to the operator and audited.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param playerId Source
-- @param event string
-- @return boolean
function Server.Admitted(source, raw, playerId, event)
	local admitted, code = Server.Admit(playerId)
	if admitted then return true end
	Server.Refuse(source, raw, code, { id = playerId })
	Server.Audit(source, event, false, playerId, code)
	return false
end

--- Health fraction and grace window a moved or revived player gets back.
-- @author dop42
-- @return table
function Server.Recovery()
	local placement = M.Section('PLACEMENT')
	return {
		health = math.min(1.0, math.max(0.01, Server.Setting(placement.HEALTH, 1.0))),
		graceMs = math.floor(OPX.Tune.Number('ADMIN_PLACEMENT_GRACE_MS', 0)),
	}
end

--- Moves a player through kill then respawn, reviving them in place on a refusal.
-- Never a transform write: a transform written on a client that is not incarnated
-- is exactly what the readiness gate exists to stop, and `respawn` is the one call
-- that places a body, a bucket and a health value together.
-- @author dop42
-- @param playerId Source
-- @param point table x, y, z
-- @param heading number|nil
-- @param bucket integer|nil nil keeps the bucket they are in
-- @param why string what the kill is attributed to
-- @return boolean ok
-- @return string|nil code
-- @return string|nil reason
function Server.Place(playerId, point, heading, bucket, why)
	local admitted, code = Server.Admit(playerId)
	if not admitted then return false, code end

	local recovery = Server.Recovery()
	if bucket == nil then
		local position = Server.PositionOf(playerId)
		bucket = position and position.bucket or 0
	end

	local killed = false
	local deadRead, dead = pcall(Open77.players.isDead, playerId)
	if not (deadRead and dead == true) then
		local ok, reason = Open77.players.kill(playerId, {
			cause = 'script',
			weapon = RESOURCE .. ':' .. why,
		})
		if not ok then return false, 'kill_refused', tostring(reason) end
		killed = true
	end

	local respawned, reason = Open77.players.respawn(playerId, {
		position = { x = point.x, y = point.y, z = point.z },
		heading = heading or 0.0,
		bucket = bucket,
		health = recovery.health,
		graceMs = recovery.graceMs,
	})
	if not respawned then
		-- The player is dead on the floor where they stood; put them back up
		-- rather than leaving them there because a move failed.
		if killed then pcall(Open77.players.revive, playerId, recovery) end
		return false, 'respawn_refused', tostring(reason)
	end
	return true
end

-- The in-memory audit ring, oldest entry first, and the sequence it is numbered
-- by. The platform log line written beside every entry is the record; this is
-- only what `opx.admin.read.audit` can read back, and it is gone at a restart.
local ledger = {}
local sequence = 0

--- Records one staff action: an `[audit]` line and an entry in the ring.
-- @author dop42
-- @param source Source 0 for the console
-- @param event string stable and greppable, like admin.player.kill
-- @param ok boolean
-- @param target Source|nil the player acted on, if any
-- @param detail string|nil English, for the log
function Server.Audit(source, event, ok, target, detail)
	local actor = tonumber(source) or 0
	sequence = sequence + 1
	local entry = {
		seq = sequence,
		atMs = Server.NowMs(),
		event = event,
		ok = ok == true,
		actor = actor,
		-- The character AND the account, because an audit row that names only one
		-- of them is a row nobody can act on. See `Server.LabelOf`.
		actorName = actor > 0 and (Server.LabelOf(actor) or '?') or 'console',
		target = target,
		targetName = target and Server.LabelOf(target) or nil,
		detail = M.Trimmed(detail, 120) or '',
	}
	ledger[#ledger + 1] = entry
	local keep = math.floor(OPX.Tune.Number('ADMIN_AUDIT_ENTRIES', 10))
	while #ledger > keep do table.remove(ledger, 1) end

	OPX.Audit.Log({
		event = event,
		severity = entry.ok and 'info' or 'warn',
		message = entry.detail,
		source = actor > 0 and actor or nil,
		userId = actor > 0 and Server.UserOf(actor) or nil,
		citizenId = actor > 0 and Server.CitizenOf(actor) or nil,
		data = {
			actorName = entry.actorName,
			target = target,
			targetUser = target and Server.UserOf(target) or nil,
			targetName = entry.targetName,
		},
	})
end

--- The most recent audit entries, newest last.
-- @author dop42
-- @param count integer
-- @return table[]
function Server.Recent(count)
	local out = {}
	for index = math.max(1, #ledger - count + 1), #ledger do out[#out + 1] = ledger[index] end
	return out
end

-- Registered commands, in registration order, and the set of names.
local commands = {}
local byName = {}

--- Whether this run falls inside the operator's floor for a command or a topic,
--- recording the attempt when it does not.
-- The window is core's, per player and per key, and a departing player's windows
-- are dropped by core. The console is never cooled.
-- @author dop42
-- @param player Source
-- @param key string
-- @param intervalMs number
-- @return boolean cooled true when the run is to be dropped
function Server.Cooled(player, key, intervalMs)
	if (tonumber(player) or 0) <= 0 then return false end
	return OPX.Cooling(player, 'admin:' .. key, intervalMs)
end

--- Registers one restricted staff command with its floor and its raise guard.
-- Always restricted: the host resolves `command.<name>` before the handler runs.
-- @author dop42
-- @param name string
-- @param spec table help, params, read, inGame, handler
function Server.Command(name, spec)
	if byName[name] ~= nil then
		Open77.log.error(('[admin] command %s is registered twice; the second is dropped')
			:format(name))
		return
	end

	local entry = { name = name, help = spec.help, params = spec.params or {} }
	commands[#commands + 1] = entry
	byName[name] = entry

	-- Core renders a command's own help at send time, from the key, so a language
	-- change is reflected without re-registering. It does NOT render a
	-- PARAMETER's help, so that one is rendered here or the key itself would
	-- reach the chat box. The catalogue is loaded before any module starts and
	-- the active language is settled at load, so there is nothing to re-render.
	local params = {}
	for index, parameter in ipairs(entry.params) do
		params[index] = {
			name = parameter.name,
			help = parameter.help and locale(parameter.help) or nil,
			optional = parameter.optional == true or nil,
		}
	end

	OPX.Command.Register(name, {
		restricted = true,
		help = spec.help,
		params = params,
	}, function(source, args, raw)
		local player = tonumber(source) or 0
		raw = type(raw) == 'string' and raw or name
		args = type(args) == 'table' and args or { n = 0 }
		if spec.inGame and player <= 0 then return Server.Refuse(player, raw, 'in_game_only') end
		-- Read at the moment of use, never captured: the floor is a live tunable.
		local floor = spec.read and OPX.Tune.Number('ADMIN_RATE_READ_MS', 0)
			or OPX.Tune.Number('ADMIN_RATE_ACTION_MS', 0)
		if Server.Cooled(player, name, floor) then return Server.Refuse(player, raw, 'too_fast') end
		-- Guarded: a raise inside a command handler is otherwise swallowed with no
		-- answer at all, which reads to an operator as a command that did nothing.
		local ran, failure = pcall(spec.handler, player, args, raw)
		if not ran then
			Open77.log.error(('[admin] %s raised: %s'):format(name, tostring(failure)))
			Server.Refuse(player, raw, 'failed')
		end
	end)
end

--- Every registered command name, in registration order.
-- @author dop42
-- @return table[]
function Server.Commands()
	return commands
end

--- Whether the host ACL grants a command, nil when it cannot say.
-- For the places that are NOT a command: the access map, the refresh event, the
-- travel revocation sweep and the name tag badge. The console is always true.
-- @author dop42
-- @param playerId Source
-- @param name string
-- @return boolean|nil
function Server.Permitted(playerId, name)
	if playerId <= 0 then return true end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return nil end
	local read, allowed = pcall(acl.isAllowed, playerId, 'command.' .. name)
	if not read then return nil end
	return allowed == true
end

--- The contracts this half reads, resolved once in `Start`.
-- A nil answer is one feature off and never a fault; every caller checks.
M.Contracts = M.Contracts or {}

--- One optional contract, logging its absence once.
-- @author dop42
-- @param name string
-- @return table|nil
function Server.Contract(name)
	return M.Contracts[name]
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state and declares the tunables. Never yields, and reaches no
--- other module: nothing has published a contract yet.
-- @author dop42
function M.Init()
	M.Contracts = {}
	ledger = {}
	sequence = 0
	commands = {}
	byName = {}

	-- The configured value becomes the panel entry's default, so an operator sets
	-- the starting point in config and moves it live from the panel.
	local rate = M.Section('RATE')
	local placement = M.Section('PLACEMENT')
	local vehicles = M.Section('VEHICLES')
	local announce = M.Section('ANNOUNCE')
	local inventory = M.Section('INVENTORY')
	local tags = M.Section('TAGS')

	local block = {}
	for key, spec in pairs(M.TUNABLES) do
		local copy = {}
		for field, value in pairs(spec) do copy[field] = value end
		block[key] = copy
	end
	block.ADMIN_RATE_ACTION_MS.value = math.floor(M.Bounded('RATE.ACTION_MS', rate.ACTION_MS,
		0, 60000, 400))
	block.ADMIN_RATE_READ_MS.value = math.floor(M.Bounded('RATE.READ_MS', rate.READ_MS,
		0, 60000, 1000))
	block.ADMIN_RATE_REFRESH_MS.value = math.floor(M.Bounded('RATE.REFRESH_MS', rate.REFRESH_MS,
		0, 60000, 750))
	block.ADMIN_AUDIT_ENTRIES.value = math.floor(M.Bounded('AUDIT_ENTRIES', M.Settings.AUDIT_ENTRIES,
		10, 2000, 200))
	block.ADMIN_TOAST_MS.value = math.floor(M.Bounded('TOAST_MS', M.Settings.TOAST_MS,
		1000, 60000, 6000))
	block.ADMIN_PLACEMENT_GRACE_MS.value = math.floor(M.Bounded('PLACEMENT.GRACE_MS',
		placement.GRACE_MS, 0, 60000, 5000))
	block.ADMIN_ANNOUNCE_MS.value = math.floor(M.Bounded('ANNOUNCE.DURATION_MS',
		announce.DURATION_MS, 1000, 120000, 12000))
	block.ADMIN_VEHICLE_PER_OWNER.value = math.floor(M.Bounded('VEHICLES.PER_OWNER',
		vehicles.PER_OWNER, 1, 100, 8))
	block.ADMIN_VEHICLE_NEAR_RADIUS.value = M.Bounded('VEHICLES.NEAR_RADIUS',
		vehicles.NEAR_RADIUS, 1, 200, 30.0)
	block.ADMIN_INVENTORY_MAX_COUNT.value = math.floor(M.Bounded('INVENTORY.MAX_COUNT',
		inventory.MAX_COUNT, 1, 1000000, 10000))
	block.ADMIN_TAGS_REFRESH_MS.value = math.floor(M.Bounded('TAGS.REFRESH_MS', tags.REFRESH_MS,
		500, 60000, 2000))

	OPX.Tune.Declare(block)
end

--- Publishes the server half of the contract.
-- Deliberately small: what another module may want is the roster this module
-- already builds and the audit it already keeps. Everything that CHANGES the
-- world stays a restricted command, because a contract call is no ACL check.
-- @author dop42
function M.Api()
	OPX.Api.Provide('admin', 1, {
		IsStaff = function(playerId)
			return OPX.Result.Ok({ staff = Server.Permitted(playerId, M.OPENER) == true })
		end,
		Roster = function() return OPX.Result.Ok({ rows = M.World.Roster(nil) }) end,
		RecentActions = function(count)
			local wanted = math.min(200, math.max(1, Text.Integer(count) or 15))
			return OPX.Result.Ok({ entries = Server.Recent(wanted) })
		end,
	})
end

--- Registers every command and starts the background passes. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.character = OPX.Api.Get('character')
	M.Contracts.inventory = OPX.Api.Get('inventory')
	M.Contracts.vehicles = OPX.Api.Get('vehicles')
	M.Contracts.downed = OPX.Api.Get('downed')
	M.Contracts.prompts = OPX.Api.Get('prompts')
	-- RESOLVED HERE OR NOT AT ALL. `Server.Contract` reads this table rather than
	-- asking the registry, so a contract absent from this block answers nil for
	-- the whole session however well it is running -- which is exactly how the
	-- new fitting-room row refused every player with `appearance_unavailable` on
	-- a server where appearance was up and serving everybody else.
	M.Contracts.appearance = OPX.Api.Get('appearance')

	if M.Contracts.inventory == nil then
		Open77.log.warn('[admin] no inventory contract: every weapon and bag command refuses, ' ..
			'and the menu greys their rows. Every other command is unaffected.')
	end

	for _, line in ipairs(M.Problems or {}) do Open77.log.warn('[admin] config: ' .. line) end

	if type(Open77.acl) ~= 'table' or type(Open77.acl.isAllowed) ~= 'function' then
		Open77.log.warn('[admin] Open77.acl is unavailable: the menu cannot grey out what the ' ..
			'ACL would refuse, and a travel mode is not revoked when its grant goes. Every ' ..
			'command is still gated by the host before its handler runs.')
	end

	M.Players.Register()
	M.Models.Register()
	M.Vehicles.Register()
	M.Inventory.Register()
	M.Weapons.Register()
	M.World.Register()
	M.Tags.Register()
	M.Combat.Register()
	M.Doors.Register()
	M.Characters.Register()
	M.Offline.Register()
	M.Recovery.Register()
	-- Last: the access map it sends lists what every other file registered.
	M.Menu.Register()

	Open77.log.info(('[admin] ready -- %d restricted commands; grant command.%s to open the menu')
		:format(#commands, M.OPENER))
end

--- Gives back every body this module hid or held, and takes down what it armed.
-- @author dop42
function M.Stop()
	M.Players.Release()
	M.Models.Release()
	M.Tags.Release()
	M.Doors.Release()
end
