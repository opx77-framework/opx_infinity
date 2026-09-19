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
local Peds = M.Peds
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

-- The characters of the one account the roster screen is looking into. Same
-- shape as `bag` and for the same reason: it is a per-target list fetched from
-- the server, so it carries the target it was read for and a late answer for
-- somebody else is dropped rather than drawn as theirs.
local chars = { target = nil, rows = {}, incoming = {}, loaded = false, error = nil }

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

-- Puts a glyph on a row built by a helper that takes no `extra`. The menu module
-- refuses a name outside `menu.M.ICONS`, so a typo here is a refused menu rather
-- than a row that quietly loses its picture.
local function icon(item, name)
	item.icon = name
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
	return row('empty', locale(key), nil, { disabled = true, icon = 'info' })
end

-- A row running a command line, greyed when the ACL refuses it.
local function command(id, label, tokens, refresh, extra)
	return denied(row(id, text(label), { run = tokens, refresh = refresh }, extra), tokens[1])
end

-- A command row that goes through a confirmation screen first.
local function guarded(id, labelKey, tokens, confirmKey, refresh, popAfter)
	local item = command(id, labelKey, tokens)
	-- `refresh` and `popAfter` are carried through the confirmation the same way
	-- the tokens are: a row that destroys what the screen under it draws has to
	-- say so HERE, where the caller knows, rather than have the dispatch guess
	-- from the screen's name.
	--
	-- IT IS `popAfter` AND NOT `back`, and that is the whole bug this name fixes.
	-- `back` already means something on a row -- "pressing me pops the screen",
	-- which is what Cancel is -- and `onRow` tests it FIRST, before it ever looks
	-- for a confirmation. A guarded row carrying `back = true` therefore popped on
	-- press and never confirmed and never ran: the delete row did nothing at all,
	-- silently, while looking exactly like a row that had been pressed.
	item.data = { confirm = tokens, key = confirmKey, refresh = refresh, popAfter = popAfter }
	return item
end

-- A row opening a form, greyed when the command it ends in is refused.
local function form(id, labelKey, kind, arg, name)
	return denied(row(id, locale(labelKey), { form = kind, arg = arg }), name)
end

-- A row that pushes another screen.
--
-- `submenu = true` IS THE POINT OF THIS HELPER AND NOT A DETAIL. This menu keeps
-- its own stack and opens one flat screen at a time, so nothing it sends the
-- contract has `items` under it and the contract could not derive the affordance
-- itself: every navigation row drew exactly like the rows that fire a command,
-- and the only way to learn that `Players` was a list and `Heal` was not was to
-- press one of them. The flag puts the `>` back in the affordance column, and it
-- rides on THIS function so that a screen added later cannot forget it.
local function go(id, label, screen, arg, extra)
	local item = row(id, text(label), { go = screen, arg = arg }, extra)
	item.submenu = true
	return item
end

-- A row to a picker, greyed when its final command is refused.
local function goFor(id, labelKey, screen, arg, name, extra)
	return denied(go(id, labelKey, screen, arg, extra), name)
end

-- A separator row, with a heading when one is given.
local function section(labelKey)
	return { separator = true, label = labelKey and locale(labelKey) or nil }
end

-- ── the filter ──────────────────────────────────────────────────────────────
--
-- WHY A LIST THIS LONG NEEDS ONE. The catalogues behind this menu are 271
-- vehicles under ten classes, every ped family the build ships, and the whole
-- item catalogue -- paged twenty rows at a time. Finding `quadra` in that meant
-- walking fourteen pages with an arrow key, and the operator already knew the
-- word they were looking for.
--
-- WHY IT IS A FORM AND NOT A TEXT FIELD ON THE STRIP. The strip reads six keys
-- and no letters: it is drawn by a page that forwards arrows, Enter and
-- Backspace and nothing else, on purpose, so that a menu can be open while the
-- game still has the keyboard. The one surface in this resource that takes typed
-- text is the form, so the search row opens one, and the answer comes back
-- through `Menu.Filter`.
--
-- WHERE IT APPEARS. Only on a list long enough to be worth searching, or one
-- already filtered -- see `SEARCH_FROM`. A three-player roster with a search box
-- over it is a box in the way.

-- Rows a list must hold before it offers to be searched.
local SEARCH_FROM = 12

-- Whether a row's words match the query. Case-insensitive, plain substring, and
-- EVERY word of the query has to appear somewhere: `mil tech` finds the
-- Militech rows without the operator having to remember which field the word is
-- in. Plain `find`, never a pattern -- a typed `(` is a character, not syntax.
local function matches(query, ...)
	if query == nil then return true end
	local hay = ''
	for index = 1, select('#', ...) do
		local part = select(index, ...)
		if part ~= nil then hay = hay .. ' ' .. tostring(part):lower() end
	end
	for word in query:lower():gmatch('%S+') do
		if not hay:find(word, 1, true) then return false end
	end
	return true
end

-- The stack entry the screen being built belongs to.
local function building()
	return stack[#stack]
end

-- The query the screen on top of the stack is under, or nil. Read off the stack
-- rather than passed down, because a screen builder is handed its `arg` and
-- nothing else, and the filter belongs to the SCREEN and not to the argument
-- that named it -- going back to a list has to bring its filter back with it.
local function filtering()
	local current = building()
	local typed = current and current.filter
	if type(typed) ~= 'string' or typed == '' then return nil end
	return typed
end

-- The block at the top of a list: the search box, what it is holding, whatever
-- else that list filters by, and the rule under the lot.
--
-- Empty for a short unfiltered list carrying no filters of its own, which is
-- most of them -- so this can be called from EVERY list screen without asking
-- each one whether it is long enough to deserve it.
local function searchRows(shown, total, extras)
	local query = filtering()
	local items = {}
	if query ~= nil or total >= SEARCH_FROM then
		items[1] = row('search', locale('admin.menu.search'), { form = 'search', arg = query },
			{ icon = 'search', value = query, description = locale('admin.menu.searchHint') })
		if query ~= nil then
			items[2] = row('searchClear', locale('admin.menu.searchClear'), { clearFilter = true },
				{ icon = 'minus', value = ('%d/%d'):format(shown, total) })
		end
	end
	for _, item in ipairs(extras or {}) do items[#items + 1] = item end
	if #items == 0 then return items end
	items[#items + 1] = section()
	return items
end

-- The states a roster row can be in, in the order the filter cycles them.
-- `all` is first so the list starts whole.
local STATES = { 'all', 'up', 'down', 'gate', 'loading' }

-- The words beside the state filter, in the same order.
local function stateLabels()
	local labels = {}
	for index, key in ipairs(STATES) do
		labels[index] = key == 'all' and locale('admin.menu.stateAll')
			or locale('admin.state.' .. key)
	end
	return labels
end

-- The state filter: LEFT and RIGHT cycle it where a submenu would have cost a
-- screen. The row carries the key list, so the dispatch can read the chosen
-- LABEL back to the key it stands for without either side holding an index.
local function stateRow(current)
	local labels = stateLabels()
	local selected = 1
	for index, key in ipairs(STATES) do
		if key == current then selected = index end
	end
	return row('state', locale('admin.menu.stateFilter'), { states = true },
		{ icon = 'filter', choices = labels, selected = selected })
end

-- The state key a chosen label stands for, or nil for a word from a stale draw.
local function stateOf(label)
	for index, word in ipairs(stateLabels()) do
		if word == label then return STATES[index] end
	end
	return nil
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

-- A checkbox that flips a CLIENT flag, with no command line behind it.
--
-- `switch` above sends a command to the server dispatcher, which is right for
-- anything the server decides. This is for the ones it does not: a preference
-- that changes what this client draws for itself, needs no grant, is audited
-- nowhere, and would be a round trip for nothing. The row carries the NAME of
-- the flip and the menu's own dispatch looks it up; nothing about it reaches the
-- wire.
--
-- `enabled` is the condition the preference is only meaningful under. False
-- greys the row rather than hiding it, which says the option exists and what has
-- to be true for it to do anything.
local function flip(id, labelKey, name, on, enabled, offKey)
	local item = row(id, locale(labelKey), { flip = name })
	if enabled == false then
		unavailable(item, offKey)
	else
		item.toggle = on == true
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
			{ value = ('%d/%d'):format(page + 1, pages), icon = 'arrow' })
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

-- A roster player's name and id, for a title. `name` is the CHARACTER's, with the
-- account behind it as the fallback -- see `World.RosterRow` on the server.
local function nameOf(id)
	local entry = rosterById[id]
	return entry and ('%s [%d]'):format(entry.name, id) or ('[%s]'):format(tostring(id))
end

-- The other two names a roster row carries: the account playing the character,
-- and the character's public id. A disabled row, because it is a fact and not an
-- action, and nil when the row has neither -- a slot with no character loaded has
-- nothing here that the title is not already saying.
local function identityRow(entry)
	if type(entry) ~= 'table' then return nil end
	local user = type(entry.user) == 'string' and entry.user ~= '' and entry.user or nil
	local citizen = type(entry.citizenId) == 'string' and entry.citizenId ~= '' and entry.citizenId
		or nil
	if user == nil and citizen == nil then return nil end
	return row('identity', user or locale('admin.menu.noAccount'), nil,
		{ disabled = true, value = citizen, icon = 'person' })
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
		goFor('giveWeapon', giveKey, 'weaponList', { t = target }, Command.WEAPON_GIVE,
			{ icon = 'weapon' }),
		goFor('giveAmmo', 'admin.menu.giveAmmo', 'ammoList', target, Command.WEAPON_GIVEAMMO,
			{ icon = 'ammo' }),
		icon(command('ammo', 'admin.menu.ammo', { Command.WEAPON_AMMO, target }), 'ammo'),
		icon(command('holster', 'admin.menu.holster', { Command.WEAPON_HOLSTER, target }), 'lock'),
		icon(guarded('disarm', 'admin.menu.disarm', { Command.WEAPON_REMOVE, target, 'all' },
			'admin.confirm.disarm'), 'trash'),
		icon(command('loadout', 'admin.menu.loadout', { Command.WEAPON_READ, target }), 'list'),
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

-- The command line that dresses a target in a ped, or takes one off. The self
-- command for the operator's own body and the player one for anybody else, so
-- that a server may grant staff the right to morph themselves and not others.
local function modelTokens(target, name)
	if target == nil or target == 'me' then return { Command.SELF_MODEL, name } end
	return { Command.PLAYER_MODEL, tostring(target), name }
end

-- The row that opens the ped picker, showing the ped already being worn. Greyed
-- on a build with no model API: the server says so in the body states, and the
-- reason is worth reading once rather than on every refused pick.
local function modelRow(target, worn)
	local item = goFor('model', 'admin.menu.model', 'pedFamilies', target,
		modelTokens(target, 'x')[1], { icon = 'person' })
	if worn ~= nil then item.value = Peds.LabelOf(worn) end
	if not item.disabled and not M.Target.HasModels() then
		unavailable(item, 'admin.menu.modelsOff')
	end
	return item
end

-- The bag rows for a target; the open row only for another player.
local function bagRows(target)
	local items = {
		icon(command('invView', 'admin.menu.invView', { Command.INVENTORY_VIEW, target }), 'list'),
	}
	if target ~= 'me' and links().INVENTORY_OPEN then
		items[#items + 1] = icon(command('invOpen', 'admin.menu.invOpen',
			{ links().INVENTORY_OPEN, target }), 'box')
		items[#items].data.closeAfter = true
	end
	items[#items + 1] = goFor('invGive', 'admin.menu.invGive', 'itemCategories',
		{ t = target, m = 'give' }, Command.INVENTORY_GIVE, { icon = 'plus' })
	items[#items + 1] = goFor('invRemove', 'admin.menu.invRemove', 'bag', target,
		Command.INVENTORY_REMOVE, { icon = 'minus' })
	items[#items + 1] = icon(guarded('invClear', 'admin.menu.invClear',
		{ Command.INVENTORY_CLEAR, target }, 'admin.confirm.invClear'), 'trash')
	for _, item in ipairs(items) do offline(item) end
	return items
end

-- ── the screens ─────────────────────────────────────────────────────────────

local SCREENS = {}

-- EVERY ROW CARRIES A GLYPH NOW, and the note that used to stand here said the
-- opposite: that the root was "the one screen a glyph earns", because a list of
-- players or vehicles would be the same icon fourteen times. That was true of
-- the fourteen glyphs the set then had -- `tool` stood for the noclip switch,
-- the weather presets, the ped families and the vehicle flags at once, so half
-- the menu was one picture. The set is wider now (see `menu.M.ICONS`) and the
-- rule is the plain one: a row says what KIND of thing it is, and a list of one
-- kind repeats its glyph on purpose, which is how the eye finds where that list
-- ends. Names outside the set are REFUSED by the menu module, not dropped.
SCREENS.root = function()
	return locale('admin.menu.title'), {
		section('admin.menu.section.quick'),
		icon(switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()), 'bolt'),
		section('admin.menu.section.manage'),
		go('players', 'admin.menu.players', 'players', nil,
			{ value = tostring(#roster), icon = 'person' }),
		go('self', 'admin.menu.self', 'self', nil, { icon = 'star' }),
		go('vehicles', 'admin.menu.vehicles', 'vehicles', nil, { icon = 'vehicle' }),
		go('world', 'admin.menu.world', 'world', nil, { icon = 'world' }),
		go('server', 'admin.menu.server', 'server', nil, { icon = 'server' }),
	}
end

SCREENS.players = function()
	local query = filtering()
	local current = building()
	local state = (current and current.state) or 'all'

	-- Filtered before anything is drawn, so the count beside the clear row is the
	-- count of what the operator is actually looking at. The state word is part of
	-- the haystack as well as its own filter: typing `down` finds the same rows
	-- the state filter would, which is the answer to a search box that silently
	-- ignores the word somebody typed into it.
	local matched = {}
	for index = 1, #roster do
		local entry = roster[index]
		local word = locale('admin.state.' .. entry.state)
		if (state == 'all' or entry.state == state)
			and matches(query, entry.id, entry.name, entry.user, entry.citizenId, word) then
			matched[#matched + 1] = entry
		end
	end

	local extras = {}
	if #roster >= SEARCH_FROM or state ~= 'all' then extras[1] = stateRow(state) end
	local items = searchRows(#matched, #roster, extras)

	for index = 1, math.min(#matched, MAX_LISTED) do
		local entry = matched[index]
		local value = locale('admin.state.' .. entry.state)
		if entry.bucket ~= 0 then value = value .. ' b' .. entry.bucket end
		if entry.distance then value = value .. ' ' .. entry.distance .. 'm' end
		items[#items + 1] = go('player_' .. entry.id,
			{ text = ('[%d] %s'):format(entry.id, entry.name) }, 'player', entry.id,
			{ value = value, icon = entry.state == 'down' and 'heal' or 'person' })
	end
	if #matched == 0 then
		items[#items + 1] = empty(#roster > 0 and 'admin.menu.noMatch' or 'admin.menu.nobody')
	end
	return locale('admin.menu.players'), items
end

SCREENS.player = function(id)
	local target = tostring(id)
	local entry = rosterById[id]
	local items = {}

	-- Above the first separator on purpose: the title carries the character and the
	-- slot, and this is who is actually holding the keyboard.
	local identity = identityRow(entry)
	if identity then items[#items + 1] = identity end

	append(items, {
		section('admin.menu.section.quick'),
		icon(command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }), 'location'),
		icon(command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
			'arrow'),
		icon(command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster',
			entry and entry.state == 'down' and { value = locale('admin.state.down') } or nil),
			'heart'),

		section('admin.menu.section.actions'),
		go('move', 'admin.menu.movement', 'playerMove', id, { icon = 'map' }),
		go('health', 'admin.menu.healthActions', 'playerHealth', id, { icon = 'heal' }),
		modelRow(target, M.Target.ModelOf(id)),
	})
	local link = links()
	if link.WHERE or link.JOB or link.GANG or link.MONEY then
		items[#items + 1] = go('character', 'admin.menu.character', 'playerCharacter', id,
			{ icon = 'tag' })
	end
	-- THE ACCOUNT'S CHARACTERS, which is a different question from the row above
	-- it: that one acts on the character being PLAYED -- its job, its gang, its
	-- money -- and this one lists every character the person owns, played or not.
	-- Greyed rather than hidden when the ACL refuses the listing, so an operator
	-- can see that the door exists and is not theirs.
	items[#items + 1] = goFor('characters', 'admin.menu.charList', 'playerCharacters', id,
		Command.CHARACTER_LIST, { icon = 'folder' })
	items[#items + 1] = go('items', 'admin.menu.items', 'playerItems', id, { icon = 'weapon' })
	if inventoryUp() then
		items[#items + 1] = go('inventory', 'admin.menu.inventory', 'playerInventory', id,
			{ icon = 'box' })
	end

	items[#items + 1] = section('admin.menu.section.moderation')
	items[#items + 1] = icon(form('kick', 'admin.menu.kick', 'kick', id, Command.MODERATE_KICK),
		'door')
	items[#items + 1] = icon(form('ban', 'admin.menu.ban', 'ban', id, Command.MODERATE_BAN), 'ban')
	return nameOf(id), items
end

SCREENS.playerMove = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.movement'), {
		icon(command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }), 'location'),
		icon(command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
			'arrow'),
		go('send', 'admin.menu.send', 'locations', id, { icon = 'map' }),
		icon(form('coords', 'admin.menu.coords', 'coords', id, Command.PLAYER_TP), 'location'),
		icon(command('observe', 'admin.menu.observe', { Command.PLAYER_OBSERVE, target }), 'eye'),
	}
end

SCREENS.playerHealth = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.healthActions'), {
		icon(command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster'),
			'heart'),
		icon(switch('god', 'admin.menu.god', { Command.PLAYER_GOD, target }, Client.GodMode(id)),
			'shield'),
		icon(switch('freeze', 'admin.menu.freeze', { Command.PLAYER_FREEZE, target },
			M.Target.IsFrozen(id)), 'lock'),
		icon(form('health', 'admin.menu.health', 'health', id, Command.PLAYER_HEALTH), 'heal'),
		icon(form('armor', 'admin.menu.armor', 'armor', id, Command.PLAYER_ARMOR), 'shield'),
		section('admin.menu.section.danger'),
		icon(guarded('kill', 'admin.menu.kill', { Command.PLAYER_KILL, target },
			'admin.confirm.kill'), 'warning'),
	}
end

SCREENS.playerCharacter = function(id)
	local target = tostring(id)
	local link = links()
	local items = {}
	if link.WHERE then
		items[#items + 1] = icon(command('record', 'admin.menu.record', { link.WHERE, target }),
			'info')
	end
	if link.JOB then
		items[#items + 1] = icon(form('job', 'admin.menu.job', 'job', id, link.JOB), 'tag')
	end
	if link.GANG then
		items[#items + 1] = icon(form('gang', 'admin.menu.gang', 'gang', id, link.GANG), 'flag')
	end
	if link.MONEY then
		items[#items + 1] = icon(form('money', 'admin.menu.money', 'money', id, link.MONEY), 'money')
	end
	if #items == 0 then items[1] = empty('admin.menu.catalogEmpty') end
	return playerTitle(id, 'admin.menu.character'), items
end

-- ── an account's characters ─────────────────────────────────────────────────
-- EVERY CHARACTER THE PERSON OWNS, played or not, which is a different question
-- from the screen above: that one acts on the body in the world and dies with
-- the connection, these are the rows behind it and outlive it. The list is
-- served by the server against the ACL and arrives tagged with the player it was
-- read for, so this draws nothing until the tag matches the screen's own target.

--- One character out of the list the server sent, or nil.
local function characterRow(citizenId)
	for _, entry in ipairs(chars.rows) do
		if entry.citizenId == citizenId then return entry end
	end
	return nil
end

--- A character's display name, or the word for one that was never named.
local function characterName(entry)
	if entry == nil or entry.firstName == nil then return locale('admin.menu.charUnnamed') end
	return ('%s %s'):format(entry.firstName, entry.lastName or '')
end

SCREENS.playerCharacters = function(id)
	local query = filtering()
	local held, rows = 0, {}
	if chars.target == tostring(id) then
		for _, entry in ipairs(chars.rows) do
			held = held + 1
			local name = characterName(entry)
			if matches(query, name, entry.citizenId, entry.job, entry.gang)
				and #rows < MAX_LISTED then
				local item = go('char_' .. entry.citizenId, { text = name }, 'character',
					entry.citizenId, { icon = entry.live and 'star' or 'person' })
				-- `live` is the one being played right now and `active` the one the
				-- ACCOUNT is locked on. They are usually the same and are not while a
				-- switch is in flight, so the value says which claim is being made.
				item.value = entry.live and locale('admin.menu.charLive')
					or (entry.active and locale('admin.menu.charActive'))
					or entry.gender or nil
				-- The citizen id is what every command here takes, so it is on the
				-- row rather than a level in; the date is what tells two unnamed
				-- characters apart.
				item.description = entry.createdAt
					and ('%s  %s'):format(entry.citizenId, entry.createdAt) or entry.citizenId
				rows[#rows + 1] = item
			end
		end
	end
	local items = append(searchRows(#rows, held), rows)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(chars.target == tostring(id) and chars or { loaded = false },
				'admin.menu.charNone')
	end
	return titleFor('admin.menu.charList', id), items
end

SCREENS.character = function(citizenId)
	local entry = characterRow(citizenId)
	local items = {}

	-- WHAT THE ROW IS, as readouts and not as controls: a readout is a line of
	-- type and takes no frame. None of it is editable and that is the point --
	-- the dates are a RECORD of what happened, and a date this menu could rewrite
	-- is an audit trail nobody can trust. There is no birth date in this schema;
	-- lifepath, origin and date of birth were dropped from it.
	append(items, {
		row('id', locale('admin.menu.charId'), nil,
			{ value = tostring(citizenId), disabled = true, icon = 'info' }),
		row('name', locale('admin.menu.charName'), nil,
			{ value = characterName(entry), disabled = true, icon = 'person' }),
	})
	if entry ~= nil and entry.gender then
		items[#items + 1] = row('body', locale('admin.menu.charBody'), nil,
			{ value = entry.gender, disabled = true, icon = 'person' })
	end
	if entry ~= nil and entry.job then
		items[#items + 1] = row('job', locale('admin.menu.charJob'), nil,
			{ value = entry.job, disabled = true, icon = 'tag' })
	end
	if entry ~= nil and entry.gang then
		items[#items + 1] = row('gang', locale('admin.menu.charGang'), nil,
			{ value = entry.gang, disabled = true, icon = 'flag' })
	end
	if entry ~= nil and entry.createdAt then
		items[#items + 1] = row('created', locale('admin.menu.charCreated'), nil,
			{ value = entry.createdAt, disabled = true, icon = 'clock' })
	end
	if entry ~= nil and entry.lastLoggedOut then
		items[#items + 1] = row('seen', locale('admin.menu.charSeen'), nil,
			{ value = entry.lastLoggedOut, disabled = true, icon = 'clock' })
	end

	-- THE ONE EDITABLE THING. Job, gang and money are the modules that own them,
	-- reachable a screen away on the character being played; the name is the only
	-- part of a character's identity this module writes, and it is here because a
	-- player may only write it once and cannot fix a typo afterwards.
	items[#items + 1] = section('admin.menu.section.actions')
	items[#items + 1] = icon(form('rename', 'admin.menu.charRename', 'charRename', citizenId,
		Command.CHARACTER_RENAME), 'tool')

	items[#items + 1] = section('admin.menu.section.danger')
	-- `back` because this page is about to be about nothing, and `characters`
	-- because the list above it has one row fewer.
	items[#items + 1] = icon(guarded('delete', 'admin.menu.charDelete',
		{ Command.CHARACTER_DELETE, tostring(citizenId) }, 'admin.confirm.charDelete',
		'characters', true), 'trash')

	return ('%s: %s'):format(locale('admin.menu.charList'), characterName(entry)), items
end

SCREENS.playerItems = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.items'), append({
		section('admin.menu.section.vehicles'),
		go('giveVehicle', 'admin.menu.giveVehicle', 'vehicleClasses', id, { icon = 'vehicle' }),
		section('admin.menu.section.weapons'),
	}, weaponRows(target, 'admin.menu.giveWeapon'))
end

SCREENS.playerInventory = function(id)
	return playerTitle(id, 'admin.menu.inventory'), bagRows(tostring(id))
end

SCREENS.self = function()
	local items = append({
		section('admin.menu.section.movement'),
		icon(switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()),
			'bolt'),
		icon(command('maptravel', 'admin.menu.maptravel', { Command.SELF_MAPTRAVEL }), 'map'),
		go('teleport', 'admin.menu.teleport', 'locations', 'me', { icon = 'location' }),
		icon(form('coords', 'admin.menu.coords', 'coords', 'me', Command.PLAYER_TP), 'location'),
		icon(command('pos', 'admin.menu.pos', { Command.SELF_POS }), 'info'),

		section('admin.menu.section.view'),
		icon(switch('tags', 'admin.menu.tags', { Command.SELF_TAGS }, M.Tags.IsShown()), 'tag'),
		icon(flip('tagsOwn', 'admin.menu.tagsOwn', 'tagsOwn', M.Tags.IsOwnShown(), M.Tags.IsShown(),
			'admin.menu.tagsOwnOff'), 'tag'),
		icon(switch('invisible', 'admin.menu.invisible', { Command.SELF_INVISIBLE },
			M.Target.IsInvisible()), 'hidden'),

		section('admin.menu.section.body'),
		modelRow('me', M.Target.SelfModel()),
		icon(command('modelOff', 'admin.menu.modelOff', { Command.SELF_MODEL, 'off' }), 'refresh'),

		section('admin.menu.section.health'),
		icon(command('heal', 'admin.menu.heal', { Command.SELF_HEAL }), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.SELF_REVIVE }), 'heart'),
		icon(switch('god', 'admin.menu.god', { Command.SELF_GOD }, Client.GodMode()), 'shield'),

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
		section('admin.menu.section.spawn'),
		go('spawn', 'admin.menu.spawn', 'vehicleClasses', 'me', { icon = 'vehicle' }),
		section('admin.menu.section.nearest'),
		icon(command('repair', 'admin.menu.repair', { Command.VEHICLE_REPAIR, 'near', 'full' }),
			'tool'),
		icon(command('repairVisual', 'admin.menu.repairVisual',
			{ Command.VEHICLE_REPAIR, 'near', 'visual' }), 'tool'),
		icon(command('enter', 'admin.menu.enter', { Command.VEHICLE_ENTER, 'near' }), 'door'),
	}
	local flags = {}
	for _, flag in ipairs(M.Section('VEHICLES').FLAGS or {}) do
		if type(flag) == 'string' and flag:match('^[%w_]+$') then
			flags[#flags + 1] = icon(command('flag_' .. flag,
				{ text = locale('admin.menu.flag', { flag = flag }) },
				{ Command.VEHICLE_FLAG, 'near', flag }), 'flag')
		end
	end
	-- The flags are a band of their own: they are the only rows on this screen
	-- that change a state rather than do a thing, and without a rule over them
	-- they read as five more verbs in the same list.
	if #flags > 0 then
		items[#items + 1] = section('admin.menu.section.flags')
		append(items, flags)
	end
	items[#items + 1] = section('admin.menu.section.cleanup')
	items[#items + 1] = icon(command('remove', 'admin.menu.remove',
		{ Command.VEHICLE_REMOVE, 'near' }), 'trash')
	items[#items + 1] = icon(command('removeMine', 'admin.menu.removeMine',
		{ Command.VEHICLE_REMOVE, 'mine' }), 'trash')
	items[#items + 1] = icon(guarded('cleanup', 'admin.menu.cleanup', { Command.VEHICLE_CLEANUP },
		'admin.confirm.cleanup'), 'warning')
	return locale('admin.menu.vehicles'), items
end

SCREENS.vehicleClasses = function(target)
	local classes = {}
	for _, class in ipairs(Catalog.Classes()) do
		if #class.members > 0 then classes[#classes + 1] = class end
	end
	local items = searchRows(#classes, #classes)
	for _, class in ipairs(classes) do
		items[#items + 1] = go('class_' .. class.key, { text = class.label }, 'vehicleList',
			{ t = target, c = class.key }, { value = tostring(#class.members), icon = 'folder' })
	end
	if #classes == 0 then items[#items + 1] = empty('admin.menu.catalogEmpty') end
	return titleFor('admin.menu.vehicles', target), items
end

SCREENS.vehicleList = function(arg)
	local target = type(arg) == 'table' and arg.t or 'me'
	local query = filtering()
	local found
	for _, class in ipairs(Catalog.Classes()) do
		if type(arg) == 'table' and class.key == arg.c then found = class end
	end
	local all = found and found.members or {}
	local matching = {}
	for _, entry in ipairs(all) do
		if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
	end
	local title, listed = paged(matching, 'vehicleList',
		type(arg) == 'table' and arg or {}, found and found.label or '?', function(entry)
			local tokens = target == 'me' and { Command.VEHICLE_SPAWN, entry.name }
				or { Command.VEHICLE_GIVE, tostring(target), entry.name }
			local item = icon(command('entry_' .. entry.name, { text = entry.label }, tokens),
				'vehicle')
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.pedFamilies = function(target)
	local families = {}
	for _, family in ipairs(Peds.Families()) do
		if #family.members > 0 then families[#families + 1] = family end
	end
	local items = searchRows(#families, #families)
	for _, family in ipairs(families) do
		items[#items + 1] = go('family_' .. family.key, { text = family.label }, 'pedList',
			{ t = target, f = family.key }, { value = tostring(#family.members), icon = 'folder' })
	end
	if #families == 0 then items[#items + 1] = empty('admin.menu.catalogEmpty') end
	items[#items + 1] = section()
	items[#items + 1] = icon(command('modelOff', 'admin.menu.modelOff', modelTokens(target, 'off')),
		'refresh')
	return titleFor('admin.menu.model', target), items
end

SCREENS.pedList = function(arg)
	local target = type(arg) == 'table' and arg.t or 'me'
	local query = filtering()
	local found
	for _, family in ipairs(Peds.Families()) do
		if type(arg) == 'table' and family.key == arg.f then found = family end
	end
	local all = found and found.members or {}
	local matching = {}
	for _, entry in ipairs(all) do
		if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
	end
	local title, listed = paged(matching, 'pedList',
		type(arg) == 'table' and arg or {}, found and found.label or '?', function(entry)
			local item = icon(command('ped_' .. entry.name, { text = entry.label },
				modelTokens(target, entry.name)), 'person')
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.weaponList = function(arg)
	local target = type(arg) == 'table' and tostring(arg.t) or 'me'
	local query = filtering()
	local weapons, matching = {}, {}
	for _, entry in ipairs(catalog.rows) do
		if entry.weapon then
			weapons[#weapons + 1] = entry
			if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
		end
	end
	local title, listed = paged(matching, 'weaponList', type(arg) == 'table' and arg or {},
		locale('admin.menu.weapons'), function(entry)
			local item = offline(icon(command('entry_' .. entry.name, { text = entry.label },
				{ Command.WEAPON_GIVE, target, entry.name }), 'weapon'))
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #weapons), listed)
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.ammoList = function(target)
	local query = filtering()
	local kinds, rows = 0, {}
	for _, entry in ipairs(catalog.rows) do
		if entry.ammo then
			kinds = kinds + 1
			if matches(query, entry.label, entry.name) and #rows < MAX_LISTED then
				local item = form('ammo_' .. entry.name, 'admin.menu.giveAmmo', 'ammoGive',
					{ t = tostring(target), n = entry.name, l = entry.label },
					Command.WEAPON_GIVEAMMO)
				item.label = entry.label
				item.description = entry.name
				rows[#rows + 1] = offline(icon(item, 'ammo'))
			end
		end
	end
	local items = append(searchRows(#rows, kinds), rows)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return titleFor('admin.menu.giveAmmo', target), items
end

SCREENS.itemCategories = function(arg)
	local query = filtering()
	local counts, names = {}, {}
	for _, entry in ipairs(catalog.rows) do
		if counts[entry.category] == nil then names[#names + 1] = entry.category end
		counts[entry.category] = (counts[entry.category] or 0) + 1
	end
	table.sort(names)
	local matching = {}
	for _, name in ipairs(names) do
		if matches(query, name) then matching[#matching + 1] = name end
	end
	local items = searchRows(#matching, #names)
	for _, name in ipairs(matching) do
		items[#items + 1] = go('cat_' .. name, { text = name }, 'itemList',
			{ t = arg.t, m = arg.m, c = name }, { value = tostring(counts[name]), icon = 'folder' })
	end
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	local titleKey = arg.m == 'holders' and 'admin.menu.invHolders' or 'admin.menu.invGive'
	return titleFor(titleKey, arg.t), items
end

SCREENS.itemList = function(arg)
	local query = filtering()
	local all, matching = {}, {}
	for _, entry in ipairs(catalog.rows) do
		if entry.category == arg.c then
			all[#all + 1] = entry
			if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
		end
	end
	local title, listed = paged(matching, 'itemList', arg, arg.c, function(entry)
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
		return icon(item, arg.m == 'holders' and 'search' or 'box')
	end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.bag = function(target)
	local query = filtering()
	local held, rows = 0, {}
	if bag.target == tostring(target) then
		for _, entry in ipairs(bag.rows) do
			held = held + 1
			if matches(query, entry.label, entry.name, entry.slot) and #rows < MAX_LISTED then
				local item = form(('slot_%d'):format(entry.slot), 'admin.menu.invRemove',
					'itemRemove',
					{ t = tostring(target), n = entry.name, l = entry.label, c = entry.count },
					Command.INVENTORY_REMOVE)
				item.label = ('%d  %s'):format(entry.slot, entry.label)
				if not item.disabled then item.value = 'x' .. tostring(entry.count) end
				item.description = entry.name
				rows[#rows + 1] = icon(item, 'box')
			end
		end
	end
	local items = append(searchRows(#rows, held), rows)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(bag.target == tostring(target) and bag or { loaded = false },
				'admin.menu.bagEmpty')
	end
	return titleFor('admin.menu.invRemove', target), items
end

SCREENS.locations = function(target)
	local query = filtering()
	local rows = {}
	for index = 1, #locations do
		local entry = locations[index]
		if matches(query, entry.label, entry.name) and #rows < MAX_LISTED then
			local item = icon(command('loc_' .. entry.name, { text = entry.label },
				{ Command.PLAYER_SEND, tostring(target), entry.name }), 'location')
			if not item.disabled and entry.runtime then item.value = locale('admin.menu.runtime') end
			rows[#rows + 1] = item
		end
	end
	local items = append(searchRows(#rows, #locations), rows)
	if #rows == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.noLocations')
	end
	local title = target == 'me' and locale('admin.menu.teleport')
		or ('%s: %s'):format(locale('admin.menu.send'), nameOf(target))
	return title, items
end

SCREENS.saved = function()
	local query = filtering()
	local runtime, rows = 0, {}
	for _, entry in ipairs(locations) do
		if entry.runtime then
			runtime = runtime + 1
			if matches(query, entry.label, entry.name) and #rows < MAX_LISTED then
				rows[#rows + 1] = icon(command('forget_' .. entry.name,
					{ text = locale('admin.menu.forget', { label = entry.label }) },
					{ Command.WORLD_LOC_REMOVE, entry.name }, 'locations'), 'trash')
			end
		end
	end
	local items = append(searchRows(#rows, runtime), rows)
	if #rows == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.noSaved')
	end
	return locale('admin.menu.saved'), items
end

SCREENS.world = function()
	local link = links()
	local items = {
		section('admin.menu.section.broadcast'),
		icon(form('announce', 'admin.menu.announce', 'announce', nil, Command.WORLD_ANNOUNCE),
			'talk'),
		section('admin.menu.section.combat'),
		icon(switch('pvp', 'admin.menu.pvp', { Command.WORLD_PVP }, M.Combat.IsPvp()), 'weapon'),
	}
	if link.WEATHER_SET or link.TIME then
		items[#items + 1] = section('admin.menu.section.sky')
		if link.WEATHER_SET then
			items[#items + 1] = go('weather', 'admin.menu.weather', 'weather', nil,
				{ icon = 'weather' })
		end
		if link.TIME then
			items[#items + 1] = go('time', 'admin.menu.time', 'time', nil, { icon = 'clock' })
		end
	end
	items[#items + 1] = section('admin.menu.section.locations')
	items[#items + 1] = icon(form('save', 'admin.menu.saveHere', 'location', nil,
		Command.WORLD_LOC_ADD), 'plus')
	items[#items + 1] = go('saved', 'admin.menu.saved', 'saved', nil, { icon = 'list' })
	return locale('admin.menu.world'), items
end

SCREENS.weather = function()
	local link = links()
	local items = {}
	if link.WEATHER_SET then
		local presets = M.Settings.WEATHER_PRESETS
		for _, preset in ipairs(type(presets) == 'table' and presets or {}) do
			if type(preset) == 'string' and preset:match('^[%w_%-]+$') then
				items[#items + 1] = icon(command('preset_' .. preset, { text = preset },
					{ link.WEATHER_SET, preset }), 'weather')
			end
		end
		if #items > 0 then table.insert(items, 1, section('admin.menu.section.presets')) end
	end
	items[#items + 1] = section('admin.menu.section.clock')
	if link.WEATHER_NEXT then
		items[#items + 1] = icon(command('next', 'admin.menu.weatherNext', { link.WEATHER_NEXT }),
			'refresh')
	end
	if link.WEATHER_FREEZE then
		items[#items + 1] = icon(command('hold', 'admin.menu.weatherHold',
			{ link.WEATHER_FREEZE, 'on' }), 'lock')
		items[#items + 1] = icon(command('release', 'admin.menu.weatherRelease',
			{ link.WEATHER_FREEZE, 'off' }), 'refresh')
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
				items[#items + 1] = icon(command('at_' .. (clock:gsub(':', '_')), { text = clock },
					{ link.TIME, clock }), 'clock')
			end
		end
		if #items > 0 then table.insert(items, 1, section('admin.menu.section.presets')) end
		items[#items + 1] = icon(form('custom', 'admin.menu.timeCustom', 'time', nil, link.TIME),
			'clock')
	end
	items[#items + 1] = section('admin.menu.section.clock')
	if link.TIME_FREEZE then
		items[#items + 1] = icon(command('hold', 'admin.menu.clockHold',
			{ link.TIME_FREEZE, 'on' }), 'lock')
		items[#items + 1] = icon(command('release', 'admin.menu.clockRelease',
			{ link.TIME_FREEZE, 'off' }), 'refresh')
	end
	return locale('admin.menu.time'), items
end

SCREENS.server = function()
	local link = links()
	local items = {
		section('admin.menu.section.reports'),
		icon(command('status', 'admin.menu.status', { Command.READ_STATUS }), 'info'),
		icon(command('audit', 'admin.menu.audit', { Command.READ_AUDIT }), 'list'),
		section('admin.menu.section.chat'),
		icon(command('list', 'admin.menu.playerList', { Command.READ_PLAYERS }), 'person'),
		icon(command('locations', 'admin.menu.locationList', { Command.READ_LOCATIONS }),
			'location'),
	}
	if link.PLAYERS or link.SAVE then
		items[#items + 1] = section('admin.menu.section.characters')
		if link.PLAYERS then
			items[#items + 1] = icon(command('characters', 'admin.menu.characters', { link.PLAYERS }),
				'person')
		end
		if link.SAVE then
			items[#items + 1] = icon(guarded('save', 'admin.menu.saveAll', { link.SAVE },
				'admin.confirm.save'), 'refresh')
		end
	end
	if inventoryUp() and link.INVENTORY_HOLDERS then
		items[#items + 1] = section('admin.menu.section.inventory')
		items[#items + 1] = goFor('holders', 'admin.menu.invHolders', 'itemCategories',
			{ m = 'holders' }, link.INVENTORY_HOLDERS, { icon = 'search' })
	end
	return locale('admin.menu.server'), items
end

SCREENS.confirm = function(arg)
	-- Cancel first, so the cursor starts on the harmless row.
	return locale(arg.key), {
		row('cancel', locale('admin.menu.cancel'), { back = true }, { icon = 'back' }),
		row('confirm', locale('admin.menu.confirm'), { confirmed = true },
			{ description = table.concat(arg.tokens, ' '), icon = 'warning' }),
	}
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local onAction

-- The screen at the top of the stack.
local function top()
	return stack[#stack]
end

-- The ids of the filter block, which is not part of the list it sits over.
local HEAD_ROWS = { search = true, searchClear = true, state = true }

-- WHERE THE CURSOR STARTS on a screen that has not been visited yet.
--
-- The contract's own rule is "the first row it can stand on", which was right
-- until a filter block appeared above the list: from then on, opening Players
-- landed the cursor on the search box, and Enter -- the key an operator presses
-- without looking -- asked them to type instead of opening the first player.
-- The box is a way INTO a list and not the list, so it is skipped. A screen with
-- nothing under the block lands on Back, which is the only thing left to do.
local function firstBelowHead(items)
	for _, item in ipairs(items) do
		if not item.separator and not item.disabled and not HEAD_ROWS[item.id] then
			return item.id
		end
	end
	return nil
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
			items[#items + 1] = row('back', locale('admin.menu.back'), nil, { back = true, icon = 'back' })
		else
			local key = Keys.Effective(Keys.MENU)
			items[#items + 1] = { id = 'close', label = locale('admin.menu.close'), close = true, icon = 'door',
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
		-- A remembered row first, then the first row UNDER the filter block. Only
		-- the open path needs it: an update keeps the cursor where the player left
		-- it, which is the whole point of updating in place.
		cursor = current.cursor or firstBelowHead(items),
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
	-- A FILTER SURVIVES A PAGE TURN. `more` pushes the SAME screen with `p + 1`,
	-- which is a new stack entry -- and a new entry carries no filter, so page two
	-- of a search came back unfiltered and showed the twenty rows the operator had
	-- just filtered away. Only the same screen inherits: pushing from a list into
	-- one of its rows is a different question and starts clean.
	local current = stack[#stack]
	local carried = current and current.screen == screen and current.filter or nil
	stack[#stack + 1] = { screen = screen, arg = arg, filter = carried }
	-- Leaving the root is the moment to re-check what the ACL still grants.
	if #stack == 2 then TriggerServerEvent(M.Event.REFRESH, 'access') end
	-- BEFORE the `^player` prefix test below, which this name also matches: that
	-- branch would win the chain and ask only for the roster, and the list would
	-- sit on 'loading' for ever. The roster is asked for here as well, because the
	-- screen's title names the player.
	if screen == 'playerCharacters' then
		chars.target, chars.rows, chars.incoming = tostring(arg), {}, {}
		chars.loaded, chars.error = false, nil
		TriggerServerEvent(M.Event.REFRESH, 'characters', tostring(arg))
		TriggerServerEvent(M.Event.REFRESH, 'roster')
	elseif screen:match('^player') then
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

-- The refresh topics that are read FOR somebody, and are dropped by the server
-- without one. Everything else -- the roster, the locations, the catalogue -- is
-- the whole world's and takes no argument.
local PER_TARGET = { bag = true, characters = true }

--- Who a per-target topic is asked for, or nil.
-- The two are read from different places on purpose. A bag is read off the
-- screen the operator is standing on, because that screen IS the bag. A
-- character list is read off the list's own tag, because the screen asking for
-- it is usually the single-character page BELOW the list, whose own argument is
-- a citizen id rather than the player the account belongs to.
local function refreshArg(topic)
	if topic == 'bag' then
		local current = top()
		return current and current.screen == 'bag' and tostring(current.arg) or nil
	end
	if topic == 'characters' then return chars.target end
	return nil
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
	local arg = refreshArg(refresh)
	-- A per-target topic with no target is a request the server drops anyway, so
	-- it is not sent: the list stays as it was rather than silently not arriving.
	if PER_TARGET[refresh] and arg == nil then return end
	-- A one-shot thread, not a scheduler job: the list is asked for once, after
	-- the server has had time to do the thing that changes it.
	CreateThread(function()
		Wait(1200)
		TriggerServerEvent(M.Event.REFRESH, refresh, arg)
	end)
end

--- Puts a typed query on the open list screen, or clears it.
-- Called by the search form; nothing else sets a filter. The page number goes
-- back to one with it, because page four of the unfiltered list is almost never
-- a page of the filtered one -- and a filter that lands the operator on an empty
-- page reads as a search that found nothing.
-- @author dop42
-- @param query string|nil
function Menu.Filter(query)
	suspended = false
	local current = top()
	if current == nil then return end
	local typed = type(query) == 'string' and Text.Bytes(query, 48) or nil
	if typed ~= nil then typed = typed:match('^%s*(.-)%s*$') end
	current.filter = (typed ~= nil and typed ~= '') and typed or nil
	current.cursor = nil
	if type(current.arg) == 'table' then current.arg.p = 1 end
	draw()
end

--- Pushes the confirmation screen for a command line.
-- @author dop42
-- @param tokens table
-- @param key string
function Menu.Confirm(tokens, key, refresh, popAfter)
	suspended = false
	if #stack == 0 then return end
	top().cursor = nil
	stack[#stack + 1] = { screen = 'confirm',
		arg = { tokens = tokens, key = key, refresh = refresh, back = popAfter == true } }
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
		-- THE STATE FILTER, which is a client flip by another name: it changes what
		-- THIS screen lists and nothing else, so it is answered here and the list is
		-- redrawn at once. The chosen LABEL comes back and is read to the key it
		-- stands for -- a word from a draw that has since been replaced resolves to
		-- nothing and is dropped rather than filtering to a state nobody picked.
		if data.states == true then
			local state = stateOf(payload.value)
			if state == nil then return end
			current.cursor = payload.itemId
			current.state = state ~= 'all' and state or nil
			return draw()
		end
		-- A CLIENT FLIP is answered here and the list is redrawn AT ONCE, rather
		-- than after the round trip a `switch` waits on -- because there is no
		-- round trip: the state the next draw reads is already the new one.
		if type(data.flip) == 'string' and type(payload.value) == 'boolean' then
			current.cursor = payload.itemId
			if data.flip == 'tagsOwn' then M.Tags.SetOwnShown(payload.value) end
			return draw()
		end
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
	if data.clearFilter then return Menu.Filter(nil) end
	if data.confirmed and current.screen == 'confirm' then
		local held = current.arg
		stack[#stack] = nil
		-- `back` LEAVES THE PAGE THE ACTION DESTROYED. A confirmed delete drops the
		-- thing the screen underneath was drawing -- a deleted character's own page
		-- would come back reading its id and a blank name out of a list that no
		-- longer holds it -- so the caller that knows that says so, and the list
		-- above is what the operator lands on and what the refresh then redraws.
		if held.back and #stack > 1 then stack[#stack] = nil end
		draw()
		return Menu.Run(held.tokens, held.refresh)
	end
	if type(data.go) == 'string' and SCREENS[data.go] then return push(data.go, data.arg) end
	if type(data.run) == 'table' then
		Menu.Run(data.run, data.refresh)
		if data.closeAfter then Menu.Close() end
		return
	end
	if type(data.confirm) == 'table' and type(data.key) == 'string' then
		return Menu.Confirm(data.confirm, data.key, data.refresh, data.popAfter)
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

	RegisterNetEvent(M.Event.CHARACTERS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		-- The tag, exactly as the bag above it: an answer for a player the operator
		-- has already moved on from is dropped rather than drawn as this one's.
		if payload.target ~= chars.target then return end
		local done = collect(chars, payload, function(entry)
			if type(entry.citizenId) ~= 'string' or entry.citizenId == '' then return nil end
			-- Rebuilt field by field rather than kept: everything on this payload
			-- is drawn, and a row that carried a table where a label belongs would
			-- reach the menu contract and be refused there -- taking the whole
			-- screen with it, because a spec is refused whole.
			return {
				citizenId = entry.citizenId,
				firstName = type(entry.firstName) == 'string' and entry.firstName or nil,
				lastName = type(entry.lastName) == 'string' and entry.lastName or nil,
				gender = type(entry.gender) == 'string' and entry.gender or nil,
				job = type(entry.job) == 'string' and entry.job or nil,
				gang = type(entry.gang) == 'string' and entry.gang or nil,
				createdAt = type(entry.createdAt) == 'string' and entry.createdAt or nil,
				lastLoggedOut = type(entry.lastLoggedOut) == 'string' and entry.lastLoggedOut or nil,
				active = entry.active == true or nil,
				live = entry.live == true or nil,
			}
		end)
		-- Both screens: the list draws the rows and the one below it draws a single
		-- row out of the same store, so a refresh after a rename redraws either.
		local screen = Menu.Screen()
		if done and (screen == 'playerCharacters' or screen == 'character') then draw(true) end
	end)

	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then rosterIncoming = {} end
		for _, entry in ipairs(payload.rows) do
			local id = tonumber(type(entry) == 'table' and entry.id or nil)
			if id and type(entry.name) == 'string' then
				rosterIncoming[#rosterIncoming + 1] = {
					id = id, name = entry.name,
					-- Both optional: a slot with no character loaded sends neither.
					user = type(entry.user) == 'string' and entry.user or nil,
					citizenId = type(entry.citizenId) == 'string' and entry.citizenId or nil,
					bucket = tonumber(entry.bucket) or 0,
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
