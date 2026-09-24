--- Staff rows on the target eye: yourself, players, vehicles, doors and the sky.
-- @author dop42
--
-- EVERY ROW ENDS IN A COMMAND LINE. `canInteract`, `checked` and `onSelect` are
-- plain functions called in-process -- that is what makes three dozen staff rows
-- affordable, where the same rows across a resource boundary were three dozen
-- host calls per pick -- but none of them decides anything. A row is offered when
-- the access map says the ACL would grant the command it sends, and the host
-- resolves that command again when the line arrives.
--
-- The checkbox states come from the SERVER (`bodies`) or from a replicated
-- snapshot, never from a guess: a box drawn from a guess flips the wrong way
-- exactly when it matters.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text
local Command = M.Command

M.Target = {}
local Target = M.Target

-- Rows sent in one registration. The registry takes at most 32 and refuses a
-- batch whole, so the batch is small enough that one bad row is easy to place.
--
-- FOUR AND NOT EIGHT, because the host's budget is measured per RESUME and one
-- registration is one resume's worth of work. Measured in the suite's harness
-- (2026-09-21, `probe-target-cost`), the registry costs about 1 100 instructions
-- a row: a batch of eight is 9 000, which is INSIDE one 10 000-instruction hook
-- interval only by luck, and sixteen is 17 000. Four is ~4 300 with the whole
-- interval as margin, and the batch boundary below keeps the registry's
-- whole-or-not-at-all promise -- the fix for the cost is the yield, not a
-- smaller promise.
local BATCH = 4

-- Milliseconds before the first access request, then between two. A grant taken
-- away has to reach the eye without the operator opening the menu.
local ACCESS_FIRST_MS, ACCESS_EVERY_MS = 5000, 60000

-- Weather presets the sky lists, leaving room for the other sky rows.
local MAX_PRESETS = 8

-- The register call for each kind, and the order they are registered in.
local REGISTERS = { self = 'RegisterSelf', player = 'RegisterPlayers',
	vehicle = 'RegisterVehicles', door = 'RegisterDoors', sky = 'RegisterSky' }
local KINDS = { 'self', 'player', 'vehicle', 'door', 'sky' }

-- Metres the rows reach, read once at start.
local distance = 10.0

-- The last access map, and whether the host could read the ACL at all.
local access, aclKnown = nil, false

-- Signature of the rows the eye holds for this module, nil for none.
local registered

-- Whether a registration is running, and whether another is wanted after it.
local syncing, dirty = false, false

-- Whether the server last said this player's body is hidden, and which players
-- it said are held still. Nil until it has said.
local invisible, frozenIds = nil, nil

-- The ped each player is wearing, by player id, the one this player is wearing,
-- and whether the server said this build can change a model at all. Nil until it
-- has said.
local wornPeds, wornSelf, modelsUp = nil, nil, nil

-- The scheduler handle for the access poll.
local job

-- Every row, built in Start once the locale and the settings are readable.
local ROWS, BY_ID = {}, {}

-- Sends a command line, answering whether it left.
local function run(tokens)
	return Client.Execute(tokens)
end

-- A positive whole id the context's target names under a key, as text.
local function idOf(context, key)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(target[key]) or nil
	if id == nil or id < 1 then return nil end
	return ('%d'):format(id)
end

-- The live snapshot of the door the context hit, or nil while the official door
-- service runs and owns every door.
local function doorOf(context)
	if Client.Running(M.NETWORKED_DOORS) then return nil end
	local target = type(context) == 'table' and context.target or nil
	local entity = type(target) == 'table' and target.engineEntity or nil
	local native = Open77.doors
	if type(entity) ~= 'string' or type(native) ~= 'table' or type(native.state) ~= 'function' then
		return nil
	end
	local read, door = pcall(native.state, entity)
	if not read or type(door) ~= 'table' or type(door.id) ~= 'string' then return nil end
	return door
end

-- A select that runs a command naming the targeted player.
local function onPlayer(name)
	return function(context)
		local id = idOf(context, 'playerId')
		return id ~= nil and run({ name, id })
	end
end

-- A select that runs a command naming the targeted vehicle, then extra words.
local function onVehicle(name, ...)
	local extra = { ... }
	return function(context)
		local id = idOf(context, 'vehicleId')
		if id == nil then return false end
		return run({ name, id, table.unpack(extra) })
	end
end

-- A check that the eye hit a door, a lift door only when lifts pass.
local function doorThere(lifts)
	return function(context)
		local door = doorOf(context)
		return door ~= nil and (lifts or not door.lift)
	end
end

-- A state reading one boolean field of the targeted door's snapshot.
local function doorReads(field)
	return function(context)
		local door = doorOf(context)
		if door == nil then return nil end
		return door[field] == true
	end
end

-- A select that sends the door the action undoing what one of its fields reads.
local function onDoorFlip(field, onAction, offAction)
	return function(context)
		local door = doorOf(context)
		if door == nil then return false end
		return run({ Command.WORLD_DOOR, door.id, door[field] == true and offAction or onAction })
	end
end

-- The states the checkboxes read.
local function noclipOn() return Client.IsNoclip() end
local function godOn() return Client.GodMode() end
local function invisibleOn() return invisible end
local function tagsOn() return M.Tags.IsShown() end
local function pvpOn() return M.Combat.IsPvp() end

local function frozenOn(context)
	local id = idOf(context, 'playerId')
	if id == nil or frozenIds == nil then return nil end
	return frozenIds[tonumber(id)] == true
end

local function lockedOn(context)
	local id = idOf(context, 'vehicleId')
	local vehicles = Open77.vehicles
	if id == nil or type(vehicles) ~= 'table' or type(vehicles.isLocked) ~= 'function' then
		return nil
	end
	local read, value = pcall(vehicles.isLocked, tonumber(id))
	if not read or type(value) ~= 'boolean' then return nil end
	return value
end

-- A select that runs a switch command with the word undoing what its state
-- reads, and with NO word -- so the server toggles -- when it reads nothing.
local function onFlip(state, name, key, ...)
	local extra = { ... }
	return function(context)
		local tokens = { name }
		if key ~= nil then
			local id = idOf(context, key)
			if id == nil then return false end
			tokens[2] = id
		end
		for _, word in ipairs(extra) do tokens[#tokens + 1] = word end
		local on = state(context)
		if type(on) == 'boolean' then tokens[#tokens + 1] = on and 'off' or 'on' end
		return run(tokens)
	end
end

--- Whether the server last said the operator's own body is hidden.
-- @author dop42
-- @return boolean|nil
function Target.IsInvisible()
	return invisible
end

--- Whether the server last said a player is held still.
-- @author dop42
-- @param playerId integer
-- @return boolean|nil
function Target.IsFrozen(playerId)
	if frozenIds == nil then return nil end
	return frozenIds[playerId] == true
end

--- The ped the server last said a player is wearing, or nil for their own body.
-- A row NAME out of `data/peds.lua` where the record is one this module knows,
-- and the bare record where another resource put it on.
-- @author dop42
-- @param playerId integer
-- @return string|nil
function Target.ModelOf(playerId)
	if wornPeds == nil then return nil end
	return wornPeds[playerId]
end

--- The ped the server last said THIS player is wearing, or nil.
-- Beside `ModelOf` rather than through it: the operator's own row is drawn
-- before the roster has named this client to itself.
-- @author dop42
-- @return string|nil
function Target.SelfModel()
	return wornSelf
end

--- Whether the server last said this build can change a player's model.
-- True before it has said: a row greyed on a guess is worse than one the host
-- refuses with a reason the operator can read.
-- @author dop42
-- @return boolean
function Target.HasModels()
	return modelsUp ~= false
end

-- Builds every row. Called once from Start, so the locale is readable and the
-- configured presets have been checked.
local function buildRows()
	local links = M.Section('LINKS')
	local rows = {
		{ id = 'selfNoclip', folder = 'move', kind = 'self', label = 'admin.target.noclip',
			icon = 'bolt', grant = Command.SELF_NOCLIP, state = noclipOn,
			select = onFlip(noclipOn, Command.SELF_NOCLIP) },
		{ id = 'selfGod', folder = 'state', kind = 'self', label = 'admin.target.god', icon = 'shield',
			grant = Command.SELF_GOD, state = godOn, select = onFlip(godOn, Command.SELF_GOD) },
		{ id = 'selfInvisible', folder = 'state', kind = 'self', label = 'admin.target.invisible',
			icon = 'hidden', grant = Command.SELF_INVISIBLE, state = invisibleOn,
			select = onFlip(invisibleOn, Command.SELF_INVISIBLE) },
		{ id = 'selfHeal', folder = 'state', kind = 'self', label = 'admin.target.heal', icon = 'heal',
			grant = Command.SELF_HEAL, select = function() return run({ Command.SELF_HEAL }) end },
		{ id = 'selfAmmo', folder = 'state', kind = 'self', label = 'admin.target.ammo', icon = 'ammo',
			grant = Command.WEAPON_AMMO,
			select = function() return run({ Command.WEAPON_AMMO, 'me' }) end },
		{ id = 'selfTags', folder = 'state', kind = 'self', label = 'admin.target.tags', icon = 'tag',
			grant = Command.SELF_TAGS, state = tagsOn, select = onFlip(tagsOn, Command.SELF_TAGS) },
		{ id = 'selfMap', folder = 'move', kind = 'self', label = 'admin.target.maptravel',
			icon = 'map', grant = Command.SELF_MAPTRAVEL,
			select = function() return run({ Command.SELF_MAPTRAVEL }) end },
		{ id = 'selfPos', folder = 'move', kind = 'self', label = 'admin.target.pos', icon = 'info',
			grant = Command.SELF_POS, select = function() return run({ Command.SELF_POS }) end },
		{ id = 'selfMenu', kind = 'self', label = 'admin.target.selfMenu', icon = 'gear',
			grant = M.OPENER, select = function() return M.Menu.OpenAt('self') end },

		{ id = 'playerManage', kind = 'player', label = 'admin.target.manage', icon = 'person',
			grant = M.OPENER, select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id))
			end },
		{ id = 'playerHeal', kind = 'player', label = 'admin.target.heal', icon = 'heal',
			grant = Command.PLAYER_HEAL, select = onPlayer(Command.PLAYER_HEAL) },
		{ id = 'playerRevive', kind = 'player', label = 'admin.target.revive', icon = 'heart',
			grant = Command.PLAYER_REVIVE, select = onPlayer(Command.PLAYER_REVIVE) },
		{ id = 'playerFreeze', kind = 'player', label = 'admin.target.freeze', icon = 'lock',
			grant = Command.PLAYER_FREEZE, state = frozenOn,
			select = onFlip(frozenOn, Command.PLAYER_FREEZE, 'playerId') },
		{ id = 'playerBag', kind = 'player', label = 'admin.target.bag', icon = 'box',
			grant = links.INVENTORY_OPEN,
			select = links.INVENTORY_OPEN and onPlayer(links.INVENTORY_OPEN) or nil },
		{ id = 'playerKick', folder = 'moderation', kind = 'player', label = 'admin.target.kick',
			icon = 'door', danger = true, grant = Command.MODERATE_KICK, select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id), 'kick')
			end },
		{ id = 'playerBan', folder = 'moderation', kind = 'player', label = 'admin.target.ban',
			icon = 'ban', danger = true, grant = Command.MODERATE_BAN, select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id), 'ban')
			end },

		{ id = 'vehicleEnter', kind = 'vehicle', label = 'admin.target.enter', icon = 'door',
			grant = Command.VEHICLE_ENTER, select = onVehicle(Command.VEHICLE_ENTER) },
		{ id = 'vehicleRepair', kind = 'vehicle', label = 'admin.target.repair', icon = 'tool',
			grant = Command.VEHICLE_REPAIR, select = onVehicle(Command.VEHICLE_REPAIR, 'full') },
		{ id = 'vehicleBody', kind = 'vehicle', label = 'admin.target.repairVisual', icon = 'tool',
			grant = Command.VEHICLE_REPAIR, select = onVehicle(Command.VEHICLE_REPAIR, 'visual') },
		{ id = 'vehicleLock', kind = 'vehicle', label = 'admin.target.vehicleLocked', icon = 'lock',
			grant = Command.VEHICLE_FLAG, state = lockedOn,
			select = onFlip(lockedOn, Command.VEHICLE_FLAG, 'vehicleId', 'locked') },
		{ id = 'vehicleRemove', kind = 'vehicle', label = 'admin.target.removeVehicle', icon = 'trash',
			danger = true, grant = Command.VEHICLE_REMOVE, select = onVehicle(Command.VEHICLE_REMOVE) },

		{ id = 'doorOpen', kind = 'door', label = 'admin.target.doorOpen', icon = 'door',
			grant = Command.WORLD_DOOR, check = doorThere(false), state = doorReads('open'),
			select = onDoorFlip('open', 'open', 'close') },
		{ id = 'doorLock', kind = 'door', label = 'admin.target.doorLocked', icon = 'lock',
			grant = Command.WORLD_DOOR, check = doorThere(true), state = doorReads('locked'),
			select = onDoorFlip('locked', 'lock', 'unlock') },
		{ id = 'doorReset', kind = 'door', label = 'admin.target.doorReset', icon = 'refresh',
			grant = Command.WORLD_DOOR,
			check = function(context) return doorOf(context) ~= nil end,
			select = function(context)
				local door = doorOf(context)
				return door ~= nil and run({ Command.WORLD_DOOR, door.id, 'reset' })
			end },
		{ id = 'doorCopy', kind = 'door', label = 'admin.target.doorCopy', icon = 'tag',
			grant = Command.WORLD_DOOR,
			check = function(context) return doorOf(context) ~= nil end,
			select = function(context)
				local door = doorOf(context)
				local clipboard = Open77.clipboard
				if door == nil or type(clipboard) ~= 'table'
					or type(clipboard.setText) ~= 'function' then
					return false
				end
				local read, copied = pcall(clipboard.setText, door.id)
				local ok = read and copied == true
				Client.Toast(ok and 'admin.target.doorCopied' or 'admin.target.clipboardMissing',
					{ door = door.id }, ok and 'success' or 'error')
				return ok
			end },

		{ id = 'skyNoclip', kind = 'sky', label = 'admin.target.noclip', icon = 'bolt',
			grant = Command.SELF_NOCLIP, state = noclipOn,
			select = onFlip(noclipOn, Command.SELF_NOCLIP) },
		{ id = 'skyPvp', kind = 'sky', label = 'admin.target.pvp', icon = 'weapon',
			grant = Command.WORLD_PVP, state = pvpOn, select = onFlip(pvpOn, Command.WORLD_PVP) },
	}

	local listed = 0
	local presets = M.Settings.WEATHER_PRESETS
	for _, preset in ipairs(type(presets) == 'table' and presets or {}) do
		if listed < MAX_PRESETS and type(preset) == 'string' and preset:match('^[%w_%-]+$') then
			listed = listed + 1
			local key = 'admin.weather.' .. preset
			rows[#rows + 1] = { id = 'skyWeather_' .. preset, folder = 'weather', kind = 'sky',
				icon = 'weather', grant = links.WEATHER_SET,
				text = function()
					local name = locale(key)
					if name == key then name = preset end
					return locale('admin.target.weatherPreset', { preset = name })
				end,
				select = links.WEATHER_SET and function() return run({ links.WEATHER_SET, preset }) end
					or nil }
		end
	end
	rows[#rows + 1] = { id = 'skyWeatherNext', folder = 'weather', kind = 'sky',
		label = 'admin.target.weatherNext', icon = 'refresh', grant = links.WEATHER_NEXT,
		select = links.WEATHER_NEXT and function() return run({ links.WEATHER_NEXT }) end or nil }
	rows[#rows + 1] = { id = 'skyTime', folder = 'weather', kind = 'sky', label = 'admin.target.time',
		icon = 'clock',
		grant = links.TIME, select = function() return M.Menu.OpenAt('time') end }

	ROWS, BY_ID = {}, {}
	for _, definition in ipairs(rows) do
		-- A row whose command is switched off in LINKS has no select at all and is
		-- dropped here rather than registered and refused later.
		if definition.select ~= nil then
			ROWS[#ROWS + 1] = definition
			BY_ID[definition.id] = definition
		end
	end
end

-- Whether the last access map grants a command. The opener's grant is what makes
-- a player staff at all, so nothing is offered without it.
local function granted(name)
	if access == nil or access[M.OPENER] ~= true or type(name) ~= 'string' or name == '' then
		return false
	end
	return not aclKnown or access[name] == true
end

-- The row an observation names, or nil for anything that is not one of ours or
-- is no longer granted.
local function rowOf(context)
	if type(context) ~= 'table' then return nil end
	local option = type(context.option) == 'table' and context.option or nil
	local data = option and type(option.data) == 'table' and option.data or nil
	local row = data and BY_ID[data.row] or nil
	if row == nil or not granted(row.grant) then return nil end
	return row
end

--- The grants the last access map REFUSED, once each, in the order the rows ask
--- for them.
--
-- THE OWNER REPORTED THIS AS A MISSING FEATURE AND IT IS A MISSING GRANT.
-- "pour le target quand je interagis avec le ciel j'ai pas les options admin pour
-- modifier la meteo etc." -- the ten weather and time rows were not drawn on the
-- sky, and nothing anywhere said why.
--
-- The rows were built, the config had the command names, and the server's access
-- map did ask the ACL about them -- `menuCommands` in `server/menu.lua` walks
-- every value in LINKS as well as this module's own commands, so the first guess,
-- that the map covered only admin's own, is wrong. The ACL simply said no.
-- `opx.weather.set`, `opx.weather.next` and `opx.time` are the WEATHER module's
-- commands, and a staff role written the way `README.md` writes one --
-- `command.opx.admin` plus `command.opx.admin.*` -- holds neither. So `granted`
-- correctly dropped every row that ends in one, and the sky was left with the two
-- rows whose grants ARE admin's own, Noclip and PvP. The same mechanism takes
-- `playerBag` off a player, which ends in `opx.inventory.open`.
--
-- The MENU does not have this problem, and the difference is the whole of the
-- fix: it draws the row and greys it with "Refusé" (`denied` in `client/menu.lua`),
-- so an operator can see that the row exists and that their role is what is in
-- the way. The eye has no greyed state -- `Registry.Matches` refuses a row that
-- is not enabled, so a row it cannot run is a row it cannot draw -- and an
-- omission on a list nobody has ever seen complete is indistinguishable from a
-- feature that was never written. Hence this: the eye cannot show the operator,
-- so it tells the SERVER, in the one line it already sends per registration, and
-- the names it prints are exactly the `command.<name>` entries to add to
-- `acl.jsonc`.
local function refusals()
	local names, seen = {}, {}
	for _, row in ipairs(ROWS) do
		local grant = row.grant
		if type(grant) == 'string' and grant ~= '' and not seen[grant] and not granted(grant) then
			seen[grant] = true
			names[#names + 1] = grant
		end
	end
	return names
end

-- The definitions the access map grants, by kind, and their signature.
local function wanted()
	local byKind, ids = {}, {}
	for index, row in ipairs(ROWS) do
		if granted(row.grant) then
			byKind[row.kind] = byKind[row.kind] or {}
			local group = locale('admin.target.group')
			if row.folder then
				group = ('%s/%s'):format(group, locale('admin.target.folder.' .. row.folder))
			end
			table.insert(byKind[row.kind], {
				id = 'admin_' .. row.id,
				label = row.text and row.text() or locale(row.label),
				group = group,
				icon = row.icon,
				danger = row.danger == true,
				distance = distance,
				order = 100 + index,
				-- Plain functions, called in-process. This is what makes three dozen
				-- rows cost a table lookup each instead of a host call each.
				canInteract = row.check and function(context)
					local found = rowOf(context)
					if found == nil then return false end
					return found.check == nil or found.check(context) == true
				end or nil,
				checked = row.state and function(context)
					local found = rowOf(context)
					if found == nil or found.state == nil then return nil end
					local on = found.state(context)
					if type(on) ~= 'boolean' then return nil end
					return on
				end or nil,
				onSelect = function(context)
					local found = rowOf(context)
					if found == nil then return false end
					if found.check ~= nil and found.check(context) ~= true then return false end
					return found.select(context) == true
				end,
				data = { row = row.id },
			})
			ids[#ids + 1] = row.id
		end
	end
	return byKind, table.concat(ids, ',')
end

-- Tells the server how the registration went, so it lands in the server log: a
-- row refused on one machine is otherwise only visible on that machine.
local function report(line)
	TriggerServerEvent(M.Event.TARGET_REPORT, line)
end

-- Replaces this module's rows on the eye with the granted ones.
local function register(contract, byKind, signature)
	if signature == registered then return true end
	local cleared = contract.Clear(M.OWNER)
	if not cleared.ok then
		report('clear refused: ' .. tostring(cleared.error))
		return false
	end
	registered = ''
	for _, kind in ipairs(KINDS) do
		local rows = byKind[kind] or {}
		for first = 1, #rows, BATCH do
			local batch = {}
			for index = first, math.min(first + BATCH - 1, #rows) do batch[#batch + 1] = rows[index] end
			local answer = contract[REGISTERS[kind]](M.OWNER, batch)
			if not answer.ok then
				local line = ('the %s staff rows were not registered: %s')
					:format(kind, tostring(answer.error))
				Open77.log.warn('[admin] ' .. line)
				report(line)
				contract.Clear(M.OWNER)
				registered = nil
				return false
			end
			-- ONE BATCH PER RESUME. The whole pass is ~31 rows across five kinds,
			-- which is 36 000 instructions if it runs in one go -- and it did:
			--
			--   opx_infinity/modules/target/shared/model.lua:283: Open77 script
			--   execution budget exceeded
			--     in field 'Register' ... in field 'RegisterMany'
			--     modules/admin/client/target.lua:554: in field 'Access'
			--     modules/admin/client/menu.lua:2222
			--
			-- The line it named was a table lookup, because the raise fires at the
			-- first hook interval past the slice and not at anything hot. What it
			-- cost was every staff row: the coroutine that raised is the one that
			-- asked, so the eye came up with no admin options on it and the only
			-- trace was an error line in a client log.
			if Wait ~= nil then Wait(0) end
		end
	end
	registered = signature
	local total = 0
	for _, rows in pairs(byKind) do total = total + #rows end
	-- THE ROWS THAT ARE NOT THERE ARE THE HALF WORTH READING. A count alone said
	-- "26 staff rows on the eye" whether that was all 37 this module has or, as it
	-- was for the operator who reported the missing weather, 26 of them -- so the
	-- line was true and answered nothing. `refusals` names the grants, and a name
	-- here is the `command.<name>` to put in `acl.jsonc`.
	local missing = refusals()
	if #missing == 0 then
		report(('%d staff rows on the eye'):format(total))
	else
		report(('%d staff rows on the eye; %d hidden, this ACL does not grant: %s')
			:format(total, #ROWS - total, table.concat(missing, ' ')))
	end
	return true
end

-- Brings the eye's rows in line with the access map, one registration at a time.
--
-- IN A THREAD, AND THAT IS WHAT MAKES THE YIELD ABOVE POSSIBLE. This is reached
-- from `RegisterNetEvent(M.Event.ACCESS, ...)`, and an event handler is not a
-- coroutine: a `Wait` in that stack raises `attempt to yield from outside a
-- coroutine` instead of splitting the work, so the registration ran to the end
-- in one resume however large the access map was. The thread owns the loop now;
-- the `syncing`/`dirty` pair that was already here is what makes a second access
-- map arriving mid-registration safe, and it had to be -- every yield is a frame
-- in which one can.
local function sync()
	local contract = Client.Contract('target')
	if contract == nil then
		registered = nil
		return
	end
	if syncing then
		dirty = true
		return
	end
	syncing = true
	CreateThread(function()
		repeat
			dirty = false
			local built, byKind, signature = pcall(wanted)
			if built then
				register(contract, byKind, signature)
			else
				registered = nil
				Open77.log.warn('[admin] staff rows: ' .. tostring(byKind))
				report('staff rows not built: ' .. tostring(byKind))
			end
		until not dirty
		syncing = false
	end)
end

--- Takes an access map from the opener or from a refresh, and registers what it
--- grants.
-- @author dop42
-- @param payload table
function Target.Access(payload)
	if type(payload) ~= 'table' or type(payload.access) ~= 'table' then return end
	access, aclKnown = payload.access, payload.aclKnown == true
	sync()
end

--- Builds the rows, wires the body states and starts the access poll.
-- @author dop42
function Target.Start()
	distance = math.min(12, math.max(1, Text.Finite(M.Section('TARGET').DISTANCE) or 10))
	buildRows()

	RegisterNetEvent(M.Event.BODIES, function(payload)
		if type(payload) ~= 'table' then return end
		local held = {}
		-- An empty list may not survive the trip as a table: none reads as nobody
		-- held, which is the truthful answer either way.
		for _, value in ipairs(type(payload.frozen) == 'table' and payload.frozen or {}) do
			local id = math.tointeger(tonumber(value) or 0)
			if id ~= nil and id > 0 then held[id] = true end
		end
		local peds = {}
		for _, row in ipairs(type(payload.worn) == 'table' and payload.worn or {}) do
			local id = type(row) == 'table' and math.tointeger(tonumber(row.id) or 0) or nil
			local ped = type(row) == 'table' and M.Trimmed(row.ped, 64) or nil
			if id ~= nil and id > 0 and ped ~= nil then peds[id] = ped end
		end
		invisible, frozenIds, wornPeds = payload.invisible == true, held, peds
		wornSelf = M.Trimmed(payload.wornSelf, 64)
		modelsUp = payload.models ~= false
		M.Menu.Refresh()
	end)

	-- A grant taken away has to reach the eye without the operator opening the
	-- menu, so the access map is asked for on its own schedule.
	local first = true
	job = OPX.Scheduler.Every('admin.target.access', ACCESS_FIRST_MS, function()
		TriggerServerEvent(M.Event.REFRESH, 'access')
		if first then
			first = false
			OPX.Scheduler.Cancel(job)
			job = OPX.Scheduler.Every('admin.target.access', ACCESS_EVERY_MS, function()
				TriggerServerEvent(M.Event.REFRESH, 'access')
			end)
		end
	end)
end

--- Takes every staff row off the eye.
-- @author dop42
function Target.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local contract = Client.Contract('target')
	if contract ~= nil then contract.Clear(M.OWNER) end
	registered = nil
end
