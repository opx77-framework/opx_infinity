--- The staff menu: its screens, its navigation stack, and the menu key.
-- @author dop42
--
-- EVERY ROW IS A HINT. A row is greyed when the access map says the ACL would
-- refuse the command it ends in, and that is all the greying does: selecting it
-- would still send the line, and the host would still refuse it. Nothing here
-- decides anything.
--
-- ONE SCREEN AT A TIME, and not the whole tree in one spec. The `menu` contract
-- takes nested submenus, which is the right shape for a small static tree; this
-- one has 271 vehicles behind ten classes and every list arrives from the server
-- after the menu is already open. So each screen is a FLAT item list, this file
-- keeps the stack, and `Open` pushes while `Update` redraws in place. A whole
-- tree would also not fit: the contract bounds a spec at 400 nodes.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Catalog = M.Catalog
local Forms = M.Forms
local Keys = M.Keys
local Text = OPX.Text
local Command = M.Command

M.Menu = {}
local Menu = M.Menu

-- Most list rows one screen draws, leaving room for the navigation row under it.
local MAX_LISTED = 190

-- Rows one page of a catalogue list draws.
local PAGE_ROWS = 20

-- Milliseconds between two looks at whether the down screen should be aside.
local UPKEEP_MS = 250

-- Milliseconds a screen asked for before the opener answered is still wanted.
local LANDING_MS = 5000

-- What the server sent when the menu opened: the access map, whether the ACL
-- could be read at all, and whether the inventory answered.
local session

-- The roster, its index by id, and the chunks still arriving.
local roster, rosterById, rosterIncoming = {}, {}, {}

-- The destination rows, and the chunks still arriving.
local locations, locationsIncoming = {}, {}

-- The item catalogue and the one bag the removal picker draws.
local catalog = { rows = {}, incoming = {}, loaded = false, error = nil }
local bag = { target = nil, rows = {}, incoming = {}, loaded = false, error = nil }

-- Screen, argument and cursor from the root down.
local stack = {}

-- The open menu's handle, and whether it was taken down to put a form up.
local handle, suspended = nil, false

-- A status line to write when the next screen opens.
local queuedStatus

-- Bumped by every draw, so a stale open claims nothing.
local drawn = 0

-- The screen, argument and form to land on once the opener answers.
local landing

-- Whether the player is down, and whether this module has the down screen aside.
local playerDown, suspending, suspendReported = false, false, false

-- The scheduler handle for the upkeep pass.
local job

-- ── rows ────────────────────────────────────────────────────────────────────

-- Whether the access map grants a command. True without an ACL reader: a host
-- that cannot say greys nothing, and the host still refuses what it refuses.
local function permitted(name)
	if session == nil or type(name) ~= 'string' or name == '' then return false end
	if not session.aclKnown then return true end
	return session.access[name] == true
end

-- A catalogue key's text, or the words of a text table.
local function text(label)
	if type(label) == 'table' then return tostring(label.text) end
	return locale(label)
end

-- One menu row with its data and extra properties.
local function row(id, label, data, extra)
	local item = { id = id, label = label, data = data }
	for key, value in pairs(extra or {}) do item[key] = value end
	return item
end

-- Greys a row with a word beside it.
local function unavailable(item, key)
	item.disabled, item.value = true, locale(key or 'admin.menu.unavailable')
	return item
end

-- Greys a row when the access map says the ACL refuses the command it ends in.
local function denied(item, name)
	if not permitted(name) then unavailable(item, 'admin.menu.denied') end
	return item
end

-- The one disabled row a list shows when it has none.
local function empty(key)
	return row('empty', locale(key), nil, { disabled = true })
end

-- A row running a command line, greyed when the ACL refuses it.
local function command(id, label, tokens, refresh, extra)
	return denied(row(id, text(label), { run = tokens, refresh = refresh }, extra), tokens[1])
end

-- A command row that goes through a confirmation screen first.
local function guarded(id, labelKey, tokens, confirmKey)
	local item = command(id, labelKey, tokens)
	item.data = { confirm = tokens, key = confirmKey }
	return item
end

-- A row opening a form, greyed when the command it ends in is refused.
local function form(id, labelKey, kind, arg, name)
	return denied(row(id, locale(labelKey), { form = kind, arg = arg }), name)
end

-- A row that pushes another screen.
local function go(id, label, screen, arg, extra)
	return row(id, text(label), { go = screen, arg = arg }, extra)
end

-- A row to a picker, greyed when its final command is refused.
local function goFor(id, labelKey, screen, arg, name)
	return denied(go(id, labelKey, screen, arg), name)
end

-- A separator row, with a heading when one is given.
local function section(labelKey)
	return { separator = true, label = labelKey and locale(labelKey) or nil }
end

-- A checkbox row whose flip runs the command with `on` or `off`. A row whose
-- state cannot be read stays a plain command row that toggles: a checkbox drawn
-- from a guess is worse than no checkbox.
local function switch(id, labelKey, tokens, on)
	local item = command(id, labelKey, tokens)
	if not item.disabled and type(on) == 'boolean' then
		item.toggle = on
		item.data = { switch = tokens }
	end
	return item
end

-- One page of a long list, with a row to the next.
local function paged(list, screen, arg, title, build)
	local pages = math.max(1, math.ceil(#list / PAGE_ROWS))
	local page = math.min(math.max(math.floor(tonumber(arg.p) or 1), 1), pages)
	local first = (page - 1) * PAGE_ROWS + 1
	local items = {}
	for index = first, math.min(#list, first + PAGE_ROWS - 1) do
		items[#items + 1] = build(list[index])
	end
	if page < pages then
		local following = {}
		for key, value in pairs(arg) do following[key] = value end
		following.p = page + 1
		items[#items + 1] = go('more', 'admin.menu.more', screen, following,
			{ value = ('%d/%d'):format(page + 1, pages) })
	end
	if pages > 1 then title = ('%s %d/%d'):format(title, page, pages) end
	return title, items
end

-- Whether the server last reported the inventory contract answering.
local function inventoryUp()
	return session ~= nil and session.inventory == true
end

-- Greys a row that is otherwise enabled while the inventory is not answering.
local function offline(item)
	if not item.disabled and not inventoryUp() then unavailable(item) end
	return item
end

-- The one row a picker shows while loading, failed or empty.
local function placeholder(list, emptyKey)
	local key = not list.loaded and 'admin.menu.loading'
		or list.error and 'admin.menu.inventoryError' or emptyKey
	return empty(key)
end

-- Adds every row of a list to the end of another.
local function append(items, more)
	for _, item in ipairs(more) do items[#items + 1] = item end
	return items
end

-- A roster player's name and id, for a title.
local function nameOf(id)
	local entry = rosterById[id]
	return entry and ('%s [%d]'):format(entry.name, id) or ('[%s]'):format(tostring(id))
end

-- A player sub-screen title: Name [id] - Family.
local function playerTitle(id, key)
	return ('%s - %s'):format(nameOf(id), locale(key))
end

-- A picker title, naming the player when the target is not the operator.
local function titleFor(titleKey, target)
	if target == nil or target == 'me' then return locale(titleKey) end
	return ('%s: %s'):format(locale(titleKey), nameOf(tonumber(target) or target))
end

-- The LINKS table.
local function links()
	return M.Section('LINKS')
end

-- The weapon rows for a target.
local function weaponRows(target, giveKey)
	local items = {
		goFor('giveWeapon', giveKey, 'weaponList', { t = target }, Command.WEAPON_GIVE),
		goFor('giveAmmo', 'admin.menu.giveAmmo', 'ammoList', target, Command.WEAPON_GIVEAMMO),
		command('ammo', 'admin.menu.ammo', { Command.WEAPON_AMMO, target }),
		command('holster', 'admin.menu.holster', { Command.WEAPON_HOLSTER, target }),
		guarded('disarm', 'admin.menu.disarm', { Command.WEAPON_REMOVE, target, 'all' },
			'admin.confirm.disarm'),
		command('loadout', 'admin.menu.loadout', { Command.WEAPON_READ, target }),
	}
	for _, item in ipairs(items) do
		if item.id == 'holster' then
			-- The inventory contract publishes no way to put a weapon away; the row
			-- stays so the command's ACL name keeps a place in the menu.
			unavailable(item)
		else
			offline(item)
		end
	end
	return items
end

-- The bag rows for a target; the open row only for another player.
local function bagRows(target)
	local items = {
		command('invView', 'admin.menu.invView', { Command.INVENTORY_VIEW, target }),
	}
	if target ~= 'me' and links().INVENTORY_OPEN then
		items[#items + 1] = command('invOpen', 'admin.menu.invOpen',
			{ links().INVENTORY_OPEN, target })
		items[#items].data.closeAfter = true
	end
	items[#items + 1] = goFor('invGive', 'admin.menu.invGive', 'itemCategories',
		{ t = target, m = 'give' }, Command.INVENTORY_GIVE)
	items[#items + 1] = goFor('invRemove', 'admin.menu.invRemove', 'bag', target,
		Command.INVENTORY_REMOVE)
	items[#items + 1] = guarded('invClear', 'admin.menu.invClear',
		{ Command.INVENTORY_CLEAR, target }, 'admin.confirm.invClear')
	for _, item in ipairs(items) do offline(item) end
	return items
end

-- ── the screens ─────────────────────────────────────────────────────────────

local SCREENS = {}

SCREENS.root = function()
	return locale('admin.menu.title'), {
		section('admin.menu.section.quick'),
		switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()),
		section('admin.menu.section.manage'),
		go('players', 'admin.menu.players', 'players', nil, { value = tostring(#roster) }),
		go('self', 'admin.menu.self', 'self'),
		go('vehicles', 'admin.menu.vehicles', 'vehicles'),
		go('world', 'admin.menu.world', 'world'),
		go('server', 'admin.menu.server', 'server'),
	}
end

SCREENS.players = function()
	local items = {}
	for index = 1, math.min(#roster, MAX_LISTED) do
		local entry = roster[index]
		local value = locale('admin.state.' .. entry.state)
		if entry.bucket ~= 0 then value = value .. ' b' .. entry.bucket end
		if entry.distance then value = value .. ' ' .. entry.distance .. 'm' end
		items[#items + 1] = go('player_' .. entry.id,
			{ text = ('[%d] %s'):format(entry.id, entry.name) }, 'player', entry.id,
			{ value = value })
	end
	if #items == 0 then items[1] = empty('admin.menu.nobody') end
	return locale('admin.menu.players'), items
end

SCREENS.player = function(id)
	local target = tostring(id)
	local entry = rosterById[id]
	local items = {
		section('admin.menu.section.quick'),
		command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }),
		command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
		command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'),
		command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster',
			entry and entry.state == 'down' and { value = locale('admin.state.down') } or nil),

		section('admin.menu.section.actions'),
		go('move', 'admin.menu.movement', 'playerMove', id),
		go('health', 'admin.menu.healthActions', 'playerHealth', id),
	}
	local link = links()
	if link.WHERE or link.JOB or link.GANG or link.MONEY then
		items[#items + 1] = go('character', 'admin.menu.character', 'playerCharacter', id)
	end
	items[#items + 1] = go('items', 'admin.menu.items', 'playerItems', id)
	if inventoryUp() then
		items[#items + 1] = go('inventory', 'admin.menu.inventory', 'playerInventory', id)
	end

	items[#items + 1] = section('admin.menu.section.moderation')
	items[#items + 1] = form('kick', 'admin.menu.kick', 'kick', id, Command.MODERATE_KICK)
	items[#items + 1] = form('ban', 'admin.menu.ban', 'ban', id, Command.MODERATE_BAN)
	return nameOf(id), items
end

SCREENS.playerMove = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.movement'), {
		command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }),
		command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
		go('send', 'admin.menu.send', 'locations', id),
		form('coords', 'admin.menu.coords', 'coords', id, Command.PLAYER_TP),
		command('observe', 'admin.menu.observe', { Command.PLAYER_OBSERVE, target }),
	}
end

SCREENS.playerHealth = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.healthActions'), {
		command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'),
		command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster'),
		switch('god', 'admin.menu.god', { Command.PLAYER_GOD, target }, Client.GodMode(id)),
		switch('freeze', 'admin.menu.freeze', { Command.PLAYER_FREEZE, target },
			M.Target.IsFrozen(id)),
		form('health', 'admin.menu.health', 'health', id, Command.PLAYER_HEALTH),
		form('armor', 'admin.menu.armor', 'armor', id, Command.PLAYER_ARMOR),
		section(),
		guarded('kill', 'admin.menu.kill', { Command.PLAYER_KILL, target }, 'admin.confirm.kill'),
	}
end

SCREENS.playerCharacter = function(id)
	local target = tostring(id)
	local link = links()
	local items = {}
	if link.WHERE then
		items[#items + 1] = command('record', 'admin.menu.record', { link.WHERE, target })
	end
	if link.JOB then items[#items + 1] = form('job', 'admin.menu.job', 'job', id, link.JOB) end
	if link.GANG then items[#items + 1] = form('gang', 'admin.menu.gang', 'gang', id, link.GANG) end
	if link.MONEY then
		items[#items + 1] = form('money', 'admin.menu.money', 'money', id, link.MONEY)
	end
	if #items == 0 then items[1] = empty('admin.menu.catalogEmpty') end
	return playerTitle(id, 'admin.menu.character'), items
end

SCREENS.playerItems = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.items'), append({
		go('giveVehicle', 'admin.menu.giveVehicle', 'vehicleClasses', id),
		section('admin.menu.section.weapons'),
	}, weaponRows(target, 'admin.menu.giveWeapon'))
end

SCREENS.playerInventory = function(id)
	return playerTitle(id, 'admin.menu.inventory'), bagRows(tostring(id))
end

SCREENS.self = function()
	local items = append({
		section('admin.menu.section.movement'),
		switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()),
		command('maptravel', 'admin.menu.maptravel', { Command.SELF_MAPTRAVEL }),
		go('teleport', 'admin.menu.teleport', 'locations', 'me'),
		form('coords', 'admin.menu.coords', 'coords', 'me', Command.PLAYER_TP),
		command('pos', 'admin.menu.pos', { Command.SELF_POS }),

		section('admin.menu.section.view'),
		switch('tags', 'admin.menu.tags', { Command.SELF_TAGS }, M.Tags.IsShown()),
		switch('invisible', 'admin.menu.invisible', { Command.SELF_INVISIBLE },
			M.Target.IsInvisible()),

		section('admin.menu.section.health'),
		command('heal', 'admin.menu.heal', { Command.SELF_HEAL }),
		command('revive', 'admin.menu.revive', { Command.SELF_REVIVE }),
		switch('god', 'admin.menu.god', { Command.SELF_GOD }, Client.GodMode()),

		section('admin.menu.section.weapons'),
	}, weaponRows('me', 'admin.menu.giveMe'))
	if inventoryUp() then
		items[#items + 1] = section('admin.menu.section.inventory')
		append(items, bagRows('me'))
	end
	return locale('admin.menu.self'), items
end

SCREENS.vehicles = function()
	local items = {
		go('spawn', 'admin.menu.spawn', 'vehicleClasses', 'me'),
		section('admin.menu.section.nearest'),
		command('repair', 'admin.menu.repair', { Command.VEHICLE_REPAIR, 'near', 'full' }),
		command('repairVisual', 'admin.menu.repairVisual',
			{ Command.VEHICLE_REPAIR, 'near', 'visual' }),
		command('enter', 'admin.menu.enter', { Command.VEHICLE_ENTER, 'near' }),
	}
	for _, flag in ipairs(M.Section('VEHICLES').FLAGS or {}) do
		if type(flag) == 'string' and flag:match('^[%w_]+$') then
			items[#items + 1] = command('flag_' .. flag,
				{ text = locale('admin.menu.flag', { flag = flag }) },
				{ Command.VEHICLE_FLAG, 'near', flag })
		end
	end
	items[#items + 1] = command('remove', 'admin.menu.remove', { Command.VEHICLE_REMOVE, 'near' })
	items[#items + 1] = section('admin.menu.section.cleanup')
	items[#items + 1] = command('removeMine', 'admin.menu.removeMine',
		{ Command.VEHICLE_REMOVE, 'mine' })
	items[#items + 1] = guarded('cleanup', 'admin.menu.cleanup', { Command.VEHICLE_CLEANUP },
		'admin.confirm.cleanup')
	return locale('admin.menu.vehicles'), items
end

SCREENS.vehicleClasses = function(target)
	local items = {}
	for _, class in ipairs(Catalog.Classes()) do
		if #class.members > 0 then
			items[#items + 1] = go('class_' .. class.key, { text = class.label }, 'vehicleList',
				{ t = target, c = class.key }, { value = tostring(#class.members) })
		end
	end
	if #items == 0 then items[1] = empty('admin.menu.catalogEmpty') end
	return titleFor('admin.menu.vehicles', target), items
end

SCREENS.vehicleList = function(arg)
	local target = type(arg) == 'table' and arg.t or 'me'
	local found
	for _, class in ipairs(Catalog.Classes()) do
		if type(arg) == 'table' and class.key == arg.c then found = class end
	end
	local title, items = paged(found and found.members or {}, 'vehicleList',
		type(arg) == 'table' and arg or {}, found and found.label or '?', function(entry)
			local tokens = target == 'me' and { Command.VEHICLE_SPAWN, entry.name }
				or { Command.VEHICLE_GIVE, tostring(target), entry.name }
			return command('entry_' .. entry.name, { text = entry.label }, tokens)
		end)
	if #items == 0 then items[1] = empty('admin.menu.catalogEmpty') end
	return title, items
end

SCREENS.weaponList = function(arg)
	local target = type(arg) == 'table' and tostring(arg.t) or 'me'
	local weapons = {}
	for _, entry in ipairs(catalog.rows) do
		if entry.weapon then weapons[#weapons + 1] = entry end
	end
	local title, items = paged(weapons, 'weaponList', type(arg) == 'table' and arg or {},
		locale('admin.menu.weapons'), function(entry)
			local item = offline(command('entry_' .. entry.name, { text = entry.label },
				{ Command.WEAPON_GIVE, target, entry.name }))
			item.description = entry.name
			return item
		end)
	if #items == 0 then items[1] = placeholder(catalog, 'admin.menu.catalogEmpty') end
	return title, items
end

SCREENS.ammoList = function(target)
	local items = {}
	for _, entry in ipairs(catalog.rows) do
		if entry.ammo and #items < MAX_LISTED then
			local item = form('ammo_' .. entry.name, 'admin.menu.giveAmmo', 'ammoGive',
				{ t = tostring(target), n = entry.name, l = entry.label }, Command.WEAPON_GIVEAMMO)
			item.label = entry.label
			item.description = entry.name
			items[#items + 1] = offline(item)
		end
	end
	if #items == 0 then items[1] = placeholder(catalog, 'admin.menu.catalogEmpty') end
	return titleFor('admin.menu.giveAmmo', target), items
end

SCREENS.itemCategories = function(arg)
	local counts, names = {}, {}
	for _, entry in ipairs(catalog.rows) do
		if counts[entry.category] == nil then names[#names + 1] = entry.category end
		counts[entry.category] = (counts[entry.category] or 0) + 1
	end
	table.sort(names)
	local items = {}
	for _, name in ipairs(names) do
		items[#items + 1] = go('cat_' .. name, { text = name }, 'itemList',
			{ t = arg.t, m = arg.m, c = name }, { value = tostring(counts[name]) })
	end
	if #items == 0 then items[1] = placeholder(catalog, 'admin.menu.catalogEmpty') end
	local titleKey = arg.m == 'holders' and 'admin.menu.invHolders' or 'admin.menu.invGive'
	return titleFor(titleKey, arg.t), items
end

SCREENS.itemList = function(arg)
	local matching = {}
	for _, entry in ipairs(catalog.rows) do
		if entry.category == arg.c then matching[#matching + 1] = entry end
	end
	local title, items = paged(matching, 'itemList', arg, arg.c, function(entry)
		local item
		if arg.m == 'holders' then
			item = command('item_' .. entry.name, { text = entry.label },
				{ links().INVENTORY_HOLDERS, entry.name })
		else
			item = form('item_' .. entry.name, 'admin.menu.invGive', 'itemGive',
				{ t = arg.t, n = entry.name, l = entry.label }, Command.INVENTORY_GIVE)
			item.label = entry.label
		end
		item.description = entry.name
		return item
	end)
	if #items == 0 then items[1] = placeholder(catalog, 'admin.menu.catalogEmpty') end
	return title, items
end

SCREENS.bag = function(target)
	local items = {}
	if bag.target == tostring(target) then
		for _, entry in ipairs(bag.rows) do
			if #items >= MAX_LISTED then break end
			local item = form(('slot_%d'):format(entry.slot), 'admin.menu.invRemove', 'itemRemove',
				{ t = tostring(target), n = entry.name, l = entry.label, c = entry.count },
				Command.INVENTORY_REMOVE)
			item.label = ('%d  %s'):format(entry.slot, entry.label)
			if not item.disabled then item.value = 'x' .. tostring(entry.count) end
			item.description = entry.name
			items[#items + 1] = item
		end
	end
	if #items == 0 then
		items[1] = placeholder(bag.target == tostring(target) and bag or { loaded = false },
			'admin.menu.bagEmpty')
	end
	return titleFor('admin.menu.invRemove', target), items
end

SCREENS.locations = function(target)
	local items = {}
	for index = 1, math.min(#locations, MAX_LISTED) do
		local entry = locations[index]
		local item = command('loc_' .. entry.name, { text = entry.label },
			{ Command.PLAYER_SEND, tostring(target), entry.name })
		if not item.disabled and entry.runtime then item.value = locale('admin.menu.runtime') end
		items[#items + 1] = item
	end
	if #items == 0 then items[1] = empty('admin.menu.noLocations') end
	local title = target == 'me' and locale('admin.menu.teleport')
		or ('%s: %s'):format(locale('admin.menu.send'), nameOf(target))
	return title, items
end

SCREENS.saved = function()
	local items = {}
	for _, entry in ipairs(locations) do
		if #items >= MAX_LISTED then break end
		if entry.runtime then
			items[#items + 1] = command('forget_' .. entry.name,
				{ text = locale('admin.menu.forget', { label = entry.label }) },
				{ Command.WORLD_LOC_REMOVE, entry.name }, 'locations')
		end
	end
	if #items == 0 then items[1] = empty('admin.menu.noSaved') end
	return locale('admin.menu.saved'), items
end

SCREENS.world = function()
	local link = links()
	local items = {
		form('announce', 'admin.menu.announce', 'announce', nil, Command.WORLD_ANNOUNCE),
		section('admin.menu.section.combat'),
		switch('pvp', 'admin.menu.pvp', { Command.WORLD_PVP }, M.Combat.IsPvp()),
	}
	if link.WEATHER_SET or link.TIME then
		items[#items + 1] = section('admin.menu.section.sky')
		if link.WEATHER_SET then items[#items + 1] = go('weather', 'admin.menu.weather', 'weather') end
		if link.TIME then items[#items + 1] = go('time', 'admin.menu.time', 'time') end
	end
	items[#items + 1] = section('admin.menu.section.locations')
	items[#items + 1] = form('save', 'admin.menu.saveHere', 'location', nil, Command.WORLD_LOC_ADD)
	items[#items + 1] = go('saved', 'admin.menu.saved', 'saved')
	return locale('admin.menu.world'), items
end

SCREENS.weather = function()
	local link = links()
	local items = {}
	if link.WEATHER_SET then
		local presets = M.Settings.WEATHER_PRESETS
		for _, preset in ipairs(type(presets) == 'table' and presets or {}) do
			if type(preset) == 'string' and preset:match('^[%w_%-]+$') then
				items[#items + 1] = command('preset_' .. preset, { text = preset },
					{ link.WEATHER_SET, preset })
			end
		end
	end
	items[#items + 1] = section()
	if link.WEATHER_NEXT then
		items[#items + 1] = command('next', 'admin.menu.weatherNext', { link.WEATHER_NEXT })
	end
	if link.WEATHER_FREEZE then
		items[#items + 1] = command('hold', 'admin.menu.weatherHold', { link.WEATHER_FREEZE, 'on' })
		items[#items + 1] = command('release', 'admin.menu.weatherRelease',
			{ link.WEATHER_FREEZE, 'off' })
	end
	return locale('admin.menu.weather'), items
end

SCREENS.time = function()
	local link = links()
	local items = {}
	if link.TIME then
		local times = M.Settings.TIMES
		for _, clock in ipairs(type(times) == 'table' and times or {}) do
			if type(clock) == 'string' and clock:match('^%d%d?:%d%d$') then
				items[#items + 1] = command('at_' .. (clock:gsub(':', '_')), { text = clock },
					{ link.TIME, clock })
			end
		end
		items[#items + 1] = form('custom', 'admin.menu.timeCustom', 'time', nil, link.TIME)
	end
	items[#items + 1] = section()
	if link.TIME_FREEZE then
		items[#items + 1] = command('hold', 'admin.menu.clockHold', { link.TIME_FREEZE, 'on' })
		items[#items + 1] = command('release', 'admin.menu.clockRelease', { link.TIME_FREEZE, 'off' })
	end
	return locale('admin.menu.time'), items
end

SCREENS.server = function()
	local link = links()
	local items = {
		command('status', 'admin.menu.status', { Command.READ_STATUS }),
		command('audit', 'admin.menu.audit', { Command.READ_AUDIT }),
		section('admin.menu.section.chat'),
		command('list', 'admin.menu.playerList', { Command.READ_PLAYERS }),
		command('locations', 'admin.menu.locationList', { Command.READ_LOCATIONS }),
	}
	if link.PLAYERS or link.SAVE then
		items[#items + 1] = section('admin.menu.section.characters')
		if link.PLAYERS then
			items[#items + 1] = command('characters', 'admin.menu.characters', { link.PLAYERS })
		end
		if link.SAVE then
			items[#items + 1] = guarded('save', 'admin.menu.saveAll', { link.SAVE },
				'admin.confirm.save')
		end
	end
	if inventoryUp() and link.INVENTORY_HOLDERS then
		items[#items + 1] = section('admin.menu.section.inventory')
		items[#items + 1] = goFor('holders', 'admin.menu.invHolders', 'itemCategories',
			{ m = 'holders' }, link.INVENTORY_HOLDERS)
	end
	return locale('admin.menu.server'), items
end

SCREENS.confirm = function(arg)
	-- Cancel first, so the cursor starts on the harmless row.
	return locale(arg.key), {
		row('cancel', locale('admin.menu.cancel'), { back = true }),
		row('confirm', locale('admin.menu.confirm'), { confirmed = true },
			{ description = table.concat(arg.tokens, ' ') }),
	}
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local onAction

-- The screen at the top of the stack.
local function top()
	return stack[#stack]
end

-- Puts the top screen up, or rebuilds it in place.
local function draw(inPlace)
	local current = top()
	if current == nil or suspended then return end
	local builder = SCREENS[current.screen]
	if builder == nil then return end
	local contract = Client.Contract('menu')
	if contract == nil then return end

	local title, items = builder(current.arg)
	if current.screen ~= 'confirm' then
		items[#items + 1] = section()
		if #stack > 1 then
			items[#items + 1] = row('back', locale('admin.menu.back'), nil, { back = true })
		else
			local key = Keys.Effective(Keys.MENU)
			items[#items + 1] = { id = 'close', label = locale('admin.menu.close'), close = true,
				description = key and locale('admin.menu.closeKey', { key = key }) or nil }
		end
	end

	drawn = drawn + 1
	local mine = drawn
	local status = queuedStatus
	queuedStatus = nil

	if inPlace and handle ~= nil then
		local patched = contract.Update(handle, { title = title, items = items })
		if patched.ok then return end
	end

	local opened = contract.Open({
		owner = M.OWNER,
		id = 'admin.' .. current.screen,
		title = title,
		cursor = current.cursor,
		status = status and status.text or nil,
		statusBad = status and status.ok == false or nil,
		items = items,
		on = onAction,
	})
	if mine ~= drawn then return end
	if not opened.ok then
		handle = nil
		Open77.log.warn(('[admin] menu %s did not open: %s')
			:format(current.screen, tostring(opened.error)))
		if opened.error == 'menu_busy' then Client.Toast('admin.client.menuBusy', nil, 'warning') end
		return
	end
	handle = opened.value.handle
end

-- Pushes a screen, asks for its data again, and draws it.
local function push(screen, arg)
	stack[#stack + 1] = { screen = screen, arg = arg }
	-- Leaving the root is the moment to re-check what the ACL still grants.
	if #stack == 2 then TriggerServerEvent(M.Event.REFRESH, 'access') end
	if screen:match('^player') then
		TriggerServerEvent(M.Event.REFRESH, 'roster')
	elseif screen == 'locations' or screen == 'saved' then
		TriggerServerEvent(M.Event.REFRESH, 'locations')
	elseif (screen == 'itemCategories' or screen == 'weaponList' or screen == 'ammoList') and
		(not catalog.loaded or catalog.error) then
		TriggerServerEvent(M.Event.REFRESH, 'items')
	elseif screen == 'bag' then
		bag.target, bag.rows, bag.incoming, bag.loaded, bag.error = tostring(arg), {}, {}, false, nil
		TriggerServerEvent(M.Event.REFRESH, 'bag', tostring(arg))
	end
	draw()
end

-- Goes back a screen, or closes the menu at the root.
local function pop()
	if #stack <= 1 then return Menu.Close() end
	stack[#stack] = nil
	draw()
end

-- Pushes a screen over the root, or puts its form up with the screen under it.
local function land(wanted)
	if wanted.form then
		-- The form's cancel brings the screen back and its confirm pushes onto it.
		suspended = true
		push(wanted.screen, wanted.arg)
		Forms.Open(wanted.form, wanted.arg)
		return
	end
	if wanted.screen == 'root' then return draw() end
	push(wanted.screen, wanted.arg)
end

-- ── what another file calls ─────────────────────────────────────────────────

--- Writes the line under the list, or keeps it for the next screen.
-- @author dop42
-- @param line string
-- @param ok boolean
function Menu.Status(line, ok)
	if type(line) ~= 'string' then return end
	local one = line:match('^[^\n]*') or line
	if #one > 116 then one = Text.Bytes(one, 113) .. '...' end
	if handle == nil then
		queuedStatus = { text = one, ok = ok }
		return
	end
	local contract = Client.Contract('menu')
	if contract ~= nil then contract.SetStatus(handle, one, ok == false) end
end

--- Runs a command line and asks for a list again a moment later.
-- @author dop42
-- @param tokens table
-- @param refresh string|nil
function Menu.Run(tokens, refresh)
	suspended = false
	if #stack > 0 and handle == nil then draw() end
	if not Client.Execute(tokens) then
		Menu.Status(locale('admin.client.notSent'), false)
		return
	end
	if refresh == nil then return end
	local current = top()
	local arg = refresh == 'bag' and current and current.screen == 'bag' and tostring(current.arg)
		or nil
	if refresh == 'bag' and arg == nil then return end
	-- A one-shot thread, not a scheduler job: the list is asked for once, after
	-- the server has had time to do the thing that changes it.
	CreateThread(function()
		Wait(1200)
		TriggerServerEvent(M.Event.REFRESH, refresh, arg)
	end)
end

--- Pushes the confirmation screen for a command line.
-- @author dop42
-- @param tokens table
-- @param key string
function Menu.Confirm(tokens, key)
	suspended = false
	if #stack == 0 then return end
	top().cursor = nil
	stack[#stack + 1] = { screen = 'confirm', arg = { tokens = tokens, key = key } }
	draw()
end

-- Closes the open handle, if any.
local function takeDown()
	if handle == nil then return end
	local closing = handle
	handle = nil
	local contract = Client.Contract('menu')
	if contract ~= nil then contract.Close(closing, 'admin') end
end

--- Takes the menu down for a form, keeping the stack.
-- @author dop42
function Menu.Suspend()
	suspended = true
	takeDown()
end

--- Brings the menu back after a form, with an optional line under the list.
-- @author dop42
-- @param line string|nil
-- @param ok boolean|nil
function Menu.Resume(line, ok)
	suspended = false
	if line then queuedStatus = { text = line, ok = ok } end
	draw()
end

--- Takes the menu and any form down and empties the stack.
-- @author dop42
function Menu.Close()
	stack = {}
	suspended = false
	Forms.Close()
	takeDown()
end

--- Redraws the open screen in place, for text that changed under it.
-- @author dop42
function Menu.Refresh()
	if handle ~= nil and not suspended then draw(true) end
end

--- Whether the menu or one of its forms is up.
-- @author dop42
-- @return boolean
function Menu.IsOpen()
	return handle ~= nil or Forms.IsOpen()
end

--- The name of the screen at the top of the stack.
-- @author dop42
-- @return string|nil
function Menu.Screen()
	local current = top()
	return current and current.screen or nil
end

--- Opens the menu on one screen over the root, with a form over it when given.
-- @author dop42
-- @param screen string
-- @param arg any
-- @param formKind string|nil
-- @return boolean
function Menu.OpenAt(screen, arg, formKind)
	if SCREENS[screen] == nil then return false end
	local wanted = { screen = screen, arg = arg, form = formKind }
	if session ~= nil and #stack > 0 then
		Forms.Close()
		stack = { { screen = 'root' } }
		suspended = false
		land(wanted)
		return true
	end
	-- No session yet: the opener has to answer first, and the ACL decides whether
	-- it ever does. The wanted screen is held for a few seconds.
	wanted.atMs = Client.NowMs()
	landing = wanted
	return Client.Execute({ M.OPENER })
end

-- ── what the player did ─────────────────────────────────────────────────────

onAction = function(payload)
	if type(payload) ~= 'table' then return end

	if payload.action == 'close' then
		-- A reopen is this module replacing its own menu; the close belongs to the
		-- screen that has already gone.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		if suspended then return end
		-- The contract's own BACK at depth one closes the menu; here that means
		-- "up one of MY screens".
		if payload.reason == 'back' and #stack > 1 then
			stack[#stack] = nil
			return draw()
		end
		stack = {}
		return
	end

	local data = payload.data
	local current = top()
	if type(data) ~= 'table' or current == nil then return end

	-- A checkbox flips itself and reports the state it landed on; the command
	-- gets that state spelled out rather than a toggle, so a row that was already
	-- right cannot be flipped by a redraw.
	if payload.action == 'change' then
		if type(data.switch) ~= 'table' or type(payload.value) ~= 'boolean' then return end
		current.cursor = payload.itemId
		local tokens = {}
		for index, token in ipairs(data.switch) do tokens[index] = token end
		tokens[#tokens + 1] = payload.value and 'on' or 'off'
		return Menu.Run(tokens)
	end

	if payload.action ~= 'select' then return end
	current.cursor = payload.itemId

	if data.back then return pop() end
	if data.confirmed and current.screen == 'confirm' then
		local tokens = current.arg.tokens
		stack[#stack] = nil
		draw()
		return Menu.Run(tokens)
	end
	if type(data.go) == 'string' and SCREENS[data.go] then return push(data.go, data.arg) end
	if type(data.run) == 'table' then
		Menu.Run(data.run, data.refresh)
		if data.closeAfter then Menu.Close() end
		return
	end
	if type(data.confirm) == 'table' and type(data.key) == 'string' then
		return Menu.Confirm(data.confirm, data.key)
	end
	if type(data.form) == 'string' then return Forms.Open(data.form, data.arg) end
end

-- The menu key: closes an open menu, otherwise sends the opener.
local function pressed()
	if Menu.IsOpen() then return Menu.Close() end
	Client.Execute({ M.OPENER })
end

-- Sets the down screen aside while a downed operator has the menu or a form up.
local function syncSuspend()
	local downed = Client.Contract('downed')
	if downed == nil then
		suspending = false
		return
	end
	local wanted = playerDown and (#stack > 0 or Forms.IsOpen())
	if wanted == suspending then return end
	local result = downed.Suspend(M.OWNER, wanted)
	if result.ok then
		suspending = wanted
	elseif not suspendReported then
		suspendReported = true
		Open77.log.warn(('[admin] the downed module refused to set its screen aside: %s. Add ' ..
			'`admin = true` to SUSPENDERS in config/downed.lua.'):format(tostring(result.error)))
	end
end

-- ── collecting the server's lists ───────────────────────────────────────────

-- Gathers one chunk of a list, answering whether it is complete.
local function collect(list, payload, accept)
	if payload.offset == 0 then list.incoming = {} end
	for _, entry in ipairs(payload.rows) do
		local kept = type(entry) == 'table' and accept(entry) or nil
		if kept then list.incoming[#list.incoming + 1] = kept end
	end
	-- Swapped whole, never merged: a half-arrived list drawn as if it were the
	-- whole one is a picker missing rows with nothing to say so.
	if payload.done ~= true then return false end
	list.rows, list.incoming = list.incoming, {}
	list.loaded = true
	list.error = type(payload.error) == 'string' and payload.error or nil
	return true
end

-- Takes a session or a refreshed access map.
local function adopt(payload)
	session = {
		access = type(payload.access) == 'table' and payload.access or {},
		aclKnown = payload.aclKnown == true,
		inventory = payload.inventory == true,
	}
end

--- Registers the menu key and wires the events the menu draws from.
-- @author dop42
function Menu.Start()
	local configured = M.Section('KEYS')
	Keys.Register(Keys.MENU, 'admin.key.menu', Keys.Setting('KEYS.MENU', configured.MENU, 'F9'),
		pressed, nil, function() return playerDown end)
	Keys.OnChanged(Menu.Refresh)

	RegisterNetEvent(M.Event.OPEN, function(payload)
		if type(payload) ~= 'table' then return end
		M.Target.Access(payload)
		local wanted = landing
		landing = nil
		if wanted and Client.NowMs() - wanted.atMs > LANDING_MS then wanted = nil end
		-- The opener toggles: running it again with the menu up closes it.
		if #stack > 0 and not suspended and wanted == nil then return Menu.Close() end
		if Client.Contract('menu') == nil then
			Client.Toast('admin.client.menuMissing', nil, 'error')
			return
		end
		adopt(payload)
		catalog.rows, catalog.incoming, catalog.loaded, catalog.error = {}, {}, false, nil
		Forms.Close()
		stack = { { screen = 'root' } }
		suspended = false
		if wanted then return land(wanted) end
		draw()
	end)

	RegisterNetEvent(M.Event.ACCESS, function(payload)
		if type(payload) ~= 'table' or type(payload.access) ~= 'table' then return end
		M.Target.Access(payload)
		if session == nil then return end
		local hadInventory = session.inventory
		adopt(payload)
		if session.inventory and not hadInventory then
			TriggerServerEvent(M.Event.REFRESH, 'items')
		end
		draw(true)
	end)

	RegisterNetEvent(M.Event.ITEMS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		local done = collect(catalog, payload, function(entry)
			if type(entry.name) ~= 'string' then return nil end
			return { name = entry.name, label = tostring(entry.label or entry.name),
				category = tostring(entry.category or 'misc'),
				weapon = entry.weapon == true, ammo = entry.ammo == true }
		end)
		local screen = Menu.Screen()
		if done and (screen == 'itemCategories' or screen == 'itemList' or screen == 'weaponList'
			or screen == 'ammoList') then
			draw(true)
		end
	end)

	RegisterNetEvent(M.Event.BAG, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.target ~= bag.target then return end
		local done = collect(bag, payload, function(entry)
			local slot, amount = tonumber(entry.slot), tonumber(entry.count)
			if slot == nil or amount == nil or type(entry.name) ~= 'string' then return nil end
			return { slot = math.floor(slot), count = math.floor(amount), name = entry.name,
				label = tostring(entry.label or entry.name) }
		end)
		if done and Menu.Screen() == 'bag' then draw(true) end
	end)

	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then rosterIncoming = {} end
		for _, entry in ipairs(payload.rows) do
			local id = tonumber(type(entry) == 'table' and entry.id or nil)
			if id and type(entry.name) == 'string' then
				rosterIncoming[#rosterIncoming + 1] = {
					id = id, name = entry.name, bucket = tonumber(entry.bucket) or 0,
					distance = tonumber(entry.distance),
					state = (entry.state == 'up' or entry.state == 'down' or entry.state == 'gate')
						and entry.state or 'loading',
				}
			end
		end
		if payload.done ~= true then return end
		roster, rosterById = rosterIncoming, {}
		rosterIncoming = {}
		for _, entry in ipairs(roster) do rosterById[entry.id] = entry end
		local screen = Menu.Screen()
		if screen == 'root' or (screen and screen:match('^player')) then draw(true) end
	end)

	RegisterNetEvent(M.Event.LOCATIONS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then locationsIncoming = {} end
		for _, entry in ipairs(payload.rows) do
			if type(entry) == 'table' and type(entry.name) == 'string'
				and entry.name:match('^[%w_%-]+$') then
				locationsIncoming[#locationsIncoming + 1] = { name = entry.name,
					label = tostring(entry.label or entry.name), runtime = entry.runtime == true }
			end
		end
		if payload.done ~= true then return end
		locations, locationsIncoming = locationsIncoming, {}
		local screen = Menu.Screen()
		if screen == 'locations' or screen == 'saved' then draw(true) end
	end)

	AddEventHandler(M.Event.ON_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		playerDown = payload.down == true
	end)

	-- A poll, because a screen closes down several paths and none of them is an
	-- event this module could listen to.
	job = OPX.Scheduler.Every('admin.menu.upkeep', UPKEEP_MS, syncSuspend)

	local downed = Client.Contract('downed')
	if downed ~= nil then
		local answer = downed.IsDown()
		if answer.ok then playerDown = answer.value.down == true end
	end
end

--- Cancels the upkeep pass.
-- @author dop42
function Menu.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
end
