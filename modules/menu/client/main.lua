--- The one open menu: its validated tree, the cursor, and the surface it draws on.
-- @author dop42

local M = OPX.Modules.Get('menu')

local Result = OPX.Result
local Text = OPX.Text

local SURFACE = 'interactive'
local OWNER = 'menu'

-- Rows across the whole tree, submenus and separators counted. Every bound in
-- this block exists because the host discards an event carrying more than 1024
-- value nodes and says nothing: a menu that quietly stopped answering is far
-- worse to debug than one that refused to open.
local MAX_NODES = 400
local MAX_ROWS = 200
local MAX_DEPTH = 8
local MAX_DATA_NODES = 64
local MAX_DATA_DEPTH = 4

local MAX_LABEL = 96
local MAX_VALUE = 48
local MAX_DESCRIPTION = 160
local MAX_STATUS = 120
local MAX_SUFFIX = 8

local MAX_NAME = 64

-- How often the status line and the owner sweep are looked at. Neither is
-- frame work: the page reads the keyboard now, so there is no input tick left
-- to hang them off.
local UPKEEP_MS = 250

-- The keys the page forwards.
local KEYS = { up = true, down = true, left = true, right = true, enter = true, back = true }

-- What each focus owner on this surface is given. The page names an owner and
-- never says what it wants: asking for the cursor is not the page's decision.
-- All three view modules install an identical copy of this table and of the
-- handler below, because one surface channel carries one handler -- whichever
-- module starts last owns it, and every copy answers the same way.
local FOCUS = {
	menu = { keyboard = true, cursor = false },
	form = { keyboard = true, cursor = false },
	panel = { keyboard = true, cursor = true },
	['panel.confirm'] = { keyboard = true, cursor = true },
}

-- The one open menu, or nil.
local record

-- Handle the next opened menu receives. Unique for the life of the session.
local nextHandle = 0

-- True while `menu:open` has not reached the page. The interactive surface is
-- built on first use and a send made before it reports ready is dropped, not
-- queued, so the open is re-sent from the upkeep job until it lands.
local pendingOpen = false

-- Whether the page channels have been wired. Wiring them builds the surface,
-- so it is deferred to the first Open: a player who never opens a menu should
-- not pay for a CEF page.
local wired = false

-- Whether the player is down, and how many state messages have been heard, so
-- a late catch-up read never overrides a newer one.
local down = false
local downHeard = 0

-- ── text and names ──────────────────────────────────────────────────────────

--- Whether a value is a number that is neither NaN nor infinite.
local function finite(value)
	return OPX.Math.IsFinite(value)
end

--- Whether a value is a bounded identifier: word characters, `_`, `:`, `-`, `.`.
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Whether a value is text the status line accepts. A table would sanitise to
--- nil and silently clear the line, so it is refused rather than accepted.
local function validStatus(value)
	return value == nil or type(value) == 'string' or type(value) == 'number'
end

-- ── the spec ────────────────────────────────────────────────────────────────

--- Counts a caller's opaque table against the payload budget.
local function fitsInPayload(value, depth, budget)
	budget.nodes = budget.nodes + 1
	if budget.nodes > MAX_DATA_NODES then return false end
	if type(value) ~= 'table' then return true end
	if depth > MAX_DATA_DEPTH then return false end
	for key, nested in pairs(value) do
		if not fitsInPayload(key, depth + 1, budget) then return false end
		if not fitsInPayload(nested, depth + 1, budget) then return false end
	end
	return true
end

--- Validates a caller's opaque table whole, answering a refusal code or nil.
local function dataFault(value, notTable, tooLarge)
	if value == nil then return nil end
	if type(value) ~= 'table' then return notTable end
	if not fitsInPayload(value, 1, { nodes = 0 }) then return tooLarge end
	return nil
end

--- Validates a slider and settles its range, step and starting value.
local function normalizeSlider(slider)
	if type(slider) ~= 'table' then return nil, 'invalid_slider' end
	local low = finite(slider.min) and slider.min + 0.0 or 0.0
	local high = finite(slider.max) and slider.max + 0.0 or 100.0
	if high <= low then return nil, 'invalid_slider_range' end
	local step = finite(slider.step) and math.abs(slider.step) + 0.0 or 1.0
	if step <= 0 then step = 1.0 end
	local value = finite(slider.value) and slider.value + 0.0 or low
	if value < low then value = low end
	if value > high then value = high end
	return { min = low, max = high, step = step, value = value,
		suffix = Text.Clean(slider.suffix, MAX_SUFFIX) or '' }
end

--- Validates a choice list and settles which entry starts current.
local function normalizeChoices(item)
	if type(item.choices) ~= 'table' then return nil, 'invalid_choices' end
	local labels = {}
	for index = 1, #item.choices do
		local label = Text.Clean(item.choices[index], MAX_VALUE)
		if label == nil then return nil, 'invalid_choice' end
		labels[index] = label
	end
	if #labels == 0 then return nil, 'empty_choices' end
	local selected = finite(item.selected) and math.floor(item.selected) or 1
	-- Advisory, like every cursor: an out-of-range selection falls back rather
	-- than refusing a menu over a stale index.
	if selected < 1 or selected > #labels then selected = 1 end
	return { labels = labels, selected = selected }
end

-- Recurses, so it is declared before the row normaliser reaches for it.
local normalizeItems

--- Normalises one row and derives its kind from its shape.
-- The tests run in a fixed order and the first match wins, so a row carrying
-- both `toggle` and `choices` is a toggle and the choice list is dropped.
local function normalizeItem(item, index, depth, budget)
	if type(item) ~= 'table' then return nil, 'item_must_be_a_table' end

	budget.nodes = budget.nodes + 1
	if budget.nodes > MAX_NODES then return nil, 'menu_too_large' end

	local id = item.id
	if id == nil then
		id = 'item_' .. tostring(index)
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_item_id'
	end

	-- A separator returns before anything else is read: a description, a data
	-- table or a disabled flag on one is dropped rather than refused.
	if item.separator == true then
		return { id = id, kind = 'separator', label = Text.Clean(item.label, MAX_LABEL) or '' }
	end

	local label = Text.Clean(item.label or item.text, MAX_LABEL)
	if label == nil or label == '' then return nil, 'invalid_item_label' end

	if item.description ~= nil and Text.Clean(item.description, MAX_DESCRIPTION) == nil then
		return nil, 'invalid_item_description'
	end
	local fault = dataFault(item.data, 'invalid_item_data', 'item_data_too_large')
	if fault then return nil, fault end

	local entry = {
		id = id,
		label = label,
		description = Text.Clean(item.description, MAX_DESCRIPTION),
		data = item.data,
		disabled = item.disabled == true,
		close = item.close == true or nil,
		act = type(item.act) == 'function' and item.act or nil,
	}

	if item.items ~= nil then
		if depth >= MAX_DEPTH then return nil, 'menu_too_deep' end
		local children, reason = normalizeItems(item.items, depth + 1, budget)
		if children == nil then return nil, reason end
		entry.kind = 'submenu'
		entry.items = children
		entry.title = Text.Clean(item.title, MAX_LABEL) or label
		entry.value = Text.Clean(item.value, MAX_VALUE)
		entry.cursor = item.cursor
		return entry
	end

	-- The TYPE of `toggle` is what makes a toggle, never its truthiness: a
	-- toggle that starts false is the common case.
	if type(item.toggle) == 'boolean' then
		entry.kind = 'toggle'
		entry.on = item.toggle
		entry.labels = {
			on = Text.Clean(item.onLabel, MAX_VALUE),
			off = Text.Clean(item.offLabel, MAX_VALUE),
		}
		return entry
	end

	if item.choices ~= nil then
		local choices, reason = normalizeChoices(item)
		if choices == nil then return nil, reason end
		entry.kind = 'choices'
		entry.choices = choices.labels
		entry.selected = choices.selected
		return entry
	end

	if item.slider ~= nil then
		local slider, reason = normalizeSlider(item.slider)
		if slider == nil then return nil, reason end
		entry.kind = 'slider'
		entry.slider = slider
		return entry
	end

	if item.back == true then
		entry.kind = 'back'
		return entry
	end

	-- A close row is `close` with no callback of its own. A row carrying both
	-- stays an action that also closes, which is why the test looks at `act`.
	if item.close == true and entry.act == nil then
		entry.kind = 'close'
		return entry
	end

	entry.kind = 'action'
	entry.value = Text.Clean(item.value, MAX_VALUE)
	return entry
end

--- Normalises one level, refusing it whole on the first fault.
normalizeItems = function(items, depth, budget)
	if type(items) ~= 'table' then return nil, 'items_must_be_a_table' end
	local total = #items
	-- Counted before any row is normalised, so a caller handing over a thousand
	-- rows is told at once rather than after nine hundred of them were built.
	if total > MAX_ROWS then return nil, 'too_many_items' end

	local list = {}
	for index = 1, total do
		local entry, reason = normalizeItem(items[index], index, depth, budget)
		if entry == nil then return nil, reason end
		list[index] = entry
	end
	if #list == 0 then return nil, 'empty_menu' end

	local substantial = false
	for index = 1, #list do
		if list[index].kind ~= 'separator' then substantial = true break end
	end
	-- A level of nothing but disabled rows is a real menu; a level of nothing
	-- but separators leaves the cursor nowhere to stand.
	if not substantial then return nil, 'only_separators' end
	return list
end

-- ── the navigation stack ────────────────────────────────────────────────────

--- Whether the cursor may rest on a row.
local function selectable(entry)
	return entry ~= nil and entry.kind ~= 'separator' and not entry.disabled
end

--- The row a named cursor resolves to, or the first selectable one.
local function cursorIndex(items, wanted)
	if type(wanted) == 'string' then
		for index = 1, #items do
			if items[index].id == wanted and selectable(items[index]) then return index end
		end
	elseif finite(wanted) and wanted % 1 == 0 then
		local index = math.floor(wanted)
		if selectable(items[index]) then return index end
	end
	for index = 1, #items do
		if selectable(items[index]) then return index end
	end
	return 1
end

--- One screen of the navigation stack.
local function screen(items, title, id, cursor)
	return { items = items, title = title, id = id, index = cursorIndex(items, cursor) }
end

--- The screen on top of the stack.
local function top(owned)
	return owned.stack[#owned.stack]
end

--- The row under the cursor.
local function current(owned)
	local screenAt = top(owned)
	return screenAt.items[screenAt.index]
end

--- Moves the cursor to the next selectable row, wrapping around.
local function move(owned, delta)
	local screenAt = top(owned)
	local total = #screenAt.items
	local index = screenAt.index
	for _ = 1, total do
		index = ((index - 1 + delta) % total) + 1
		if selectable(screenAt.items[index]) then
			if index == screenAt.index then return false end
			screenAt.index = index
			return true
		end
	end
	return false
end

--- Puts the cursor back on a selectable row after a rebuild disabled its own.
local function settle(owned)
	local screenAt = top(owned)
	if selectable(screenAt.items[screenAt.index]) then return end
	for index = 1, #screenAt.items do
		if selectable(screenAt.items[index]) then screenAt.index = index return end
	end
end

--- Whether LEFT and RIGHT change this row's value rather than navigate.
local function holdsValue(entry)
	local kind = entry.kind
	return kind == 'toggle' or kind == 'choices' or kind == 'slider'
end

--- Steps a toggle, a choice list or a slider, answering whether it moved.
local function adjust(entry, delta)
	if entry.disabled then return false end
	local kind = entry.kind
	if kind == 'toggle' then
		entry.on = not entry.on
		return true
	elseif kind == 'choices' then
		local total = #entry.choices
		if total <= 1 then return false end
		entry.selected = ((entry.selected - 1 + delta) % total) + 1
		return true
	elseif kind == 'slider' then
		local slider = entry.slider
		local before = slider.value
		local value = slider.value + (slider.step * delta)
		-- Clamped, never wrapped: a volume that jumps from 0 to 100 is a
		-- complaint, not a feature.
		if value < slider.min then value = slider.min end
		if value > slider.max then value = slider.max end
		-- Snapped back onto the step grid after every move, because 0.1 added
		-- ten times is not 1.0.
		local steps = math.floor(((value - slider.min) / slider.step) + 0.5)
		value = slider.min + (steps * slider.step)
		if value > slider.max then value = slider.max end
		slider.value = value
		return value ~= before
	end
	return false
end

--- The right-hand text drawn for a row.
local function shownValue(entry)
	local kind = entry.kind
	if kind == 'toggle' then
		if entry.on then return entry.labels.on end
		return entry.labels.off
	elseif kind == 'choices' then
		return entry.choices[entry.selected]
	elseif kind == 'slider' then
		local slider = entry.slider
		local number = slider.value
		local shown = number % 1 == 0 and tostring(math.floor(number))
			or string.format('%.2f', number)
		return shown .. slider.suffix
	end
	return entry.value
end

--- A row's machine-readable value, for the payload the caller reads.
local function rawValue(entry)
	local kind = entry.kind
	if kind == 'toggle' then return entry.on end
	if kind == 'choices' then return entry.choices[entry.selected] end
	if kind == 'slider' then return entry.slider.value end
	return entry.value
end

-- ── building and rebuilding ─────────────────────────────────────────────────

--- Builds a menu record from a caller's spec, or refuses it whole.
local function build(owner, spec)
	if type(spec.on) ~= 'function' then return nil, 'callback_required' end

	local id = spec.id
	if id == nil then
		id = owner
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_menu_id'
	end

	local title = Text.Clean(spec.title, MAX_LABEL)
	if title == nil or title == '' then title = owner:upper() end

	if not validStatus(spec.status) then return nil, 'invalid_status' end

	local fault = dataFault(spec.data, 'invalid_menu_data', 'menu_data_too_large')
	if fault then return nil, fault end

	local budget = { nodes = 0 }
	local items, reason = normalizeItems(spec.items, 1, budget)
	if items == nil then return nil, reason end

	return {
		owner = owner,
		id = id,
		title = title,
		on = spec.on,
		data = spec.data,
		closeOnSelect = spec.closeOnSelect == true,
		reportFocus = spec.reportFocus == true,
		items = items,
		nodes = budget.nodes,
		stack = { screen(items, title, nil, spec.cursor) },
	}
end

--- Re-walks the navigation stack onto a rebuilt tree, by id.
-- An update must not throw the player back to the root: a submenu they are
-- standing in stays open while a row with the same id and kind is still there,
-- and the walk stops at the first level where it is not.
local function rewalk(owned, items, title)
	local root = math.min(owned.stack[1].index, #items)
	local stack = { screen(items, title, nil, root) }
	local level = items
	for depth = 2, #owned.stack do
		local previous = owned.stack[depth]
		local found
		for index = 1, #level do
			local entry = level[index]
			if entry.id == previous.id and entry.kind == 'submenu' then found = entry break end
		end
		if found == nil then break end
		stack[#stack + 1] = screen(found.items, found.title, found.id, previous.index)
		level = found.items
	end
	return stack
end

--- Patches a live menu from a spec, keeping the player's position.
-- `items` is all-or-nothing: the whole tree is rebuilt, or the whole call is
-- refused and the live menu is untouched.
local function rebuild(owned, spec)
	if not validStatus(spec.status) then return false, 'invalid_status' end
	if spec.on ~= nil and type(spec.on) ~= 'function' then return false, 'callback_required' end

	local items, nodes
	if spec.items ~= nil then
		local budget = { nodes = 0 }
		local built, reason = normalizeItems(spec.items, 1, budget)
		if built == nil then return false, reason end
		items, nodes = built, budget.nodes
	end

	local title
	if spec.title ~= nil then
		title = Text.Clean(spec.title, MAX_LABEL)
		if title == nil or title == '' then title = owned.owner:upper() end
	end

	local fault = dataFault(spec.data, 'invalid_menu_data', 'menu_data_too_large')
	if fault then return false, fault end

	if items ~= nil then
		owned.items = items
		owned.nodes = nodes
	end
	if title ~= nil then owned.title = title end
	if spec.on ~= nil then owned.on = spec.on end
	if spec.data ~= nil then owned.data = spec.data end
	if spec.closeOnSelect ~= nil then owned.closeOnSelect = spec.closeOnSelect == true end
	if spec.reportFocus ~= nil then owned.reportFocus = spec.reportFocus == true end

	owned.stack = rewalk(owned, owned.items, owned.title)
	return true
end

-- ── the frame ───────────────────────────────────────────────────────────────

--- The first row drawn, keeping the cursor near the middle of the window.
local function windowFirst(index, total, rows)
	if total <= rows then return 1 end
	local first = index - (rows // 2)
	if first < 1 then first = 1 end
	if first > total - rows + 1 then first = total - rows + 1 end
	return first
end

--- The breadcrumb, built from the titles on the stack.
local function trail(owned)
	local parts = {}
	for depth = 1, #owned.stack do parts[depth] = owned.stack[depth].title or '' end
	return table.concat(parts, ' / ')
end

--- How many rows the page draws at once.
local function visibleRows()
	local rows = M.Settings.VISIBLE_ROWS
	if finite(rows) and rows >= 1 then return math.floor(rows) end
	return 9
end

--- The window of rows the page draws, and everything around it.
local function frame(owned)
	local screenAt = top(owned)
	local rows = visibleRows()
	local total = #screenAt.items
	local first = windowFirst(screenAt.index, total, rows)
	local window = {}
	for index = first, math.min(first + rows - 1, total) do
		local entry = screenAt.items[index]
		local kind = entry.kind
		local toggle = kind == 'toggle'
		window[index - first + 1] = {
			label = entry.label,
			value = shownValue(entry),
			check = toggle or nil,
			ticked = (toggle and entry.on) or nil,
			arrow = kind == 'submenu' or nil,
			spin = holdsValue(entry) or nil,
			rule = kind == 'separator' or nil,
			off = entry.disabled or nil,
			on = (index == screenAt.index) or nil,
		}
	end

	return {
		handle = owned.handle,
		title = screenAt.title,
		trail = #owned.stack > 1 and trail(owned) or nil,
		rows = window,
		first = first,
		total = total,
		hint = current(owned).description,
		status = owned.status and owned.status.text or nil,
		statusBad = (owned.status ~= nil and owned.status.bad) or nil,
	}
end

-- ── the surface ─────────────────────────────────────────────────────────────

--- Sends the open payload: the configuration and the first frame in one, which
--- is what the page's open handler reads.
local function sendOpen()
	local payload = frame(record)
	payload.anchor = M.Settings.ANCHOR
	payload.width = M.Settings.WIDTH
	payload.maxHeight = M.Settings.MAX_HEIGHT_VH
	return OPX.UI.Send(SURFACE, 'menu:open', payload)
end

--- Draws whatever is open. While the open has not landed it is re-sent instead
--- of a frame: a frame for a menu the page has never heard of is dropped.
local function draw()
	if record == nil then return end
	if pendingOpen then
		pendingOpen = not sendOpen()
		return
	end
	OPX.UI.Send(SURFACE, 'menu:frame', frame(record))
end

-- ── the answers a caller gets ───────────────────────────────────────────────

--- Builds the one payload shape every menu action carries.
local function payloadOf(owned, entry, action)
	local screenAt = top(owned)
	local payload = {
		menu = owned.id,
		handle = owned.handle,
		owner = owned.owner,
		action = action,
		itemId = entry and entry.id or nil,
		label = entry and entry.label or nil,
		index = screenAt.index,
		depth = #owned.stack,
		data = entry and entry.data or nil,
		menuData = owned.data,
	}
	-- Assigned by presence, never folded through an `and`/`or`: a false toggle
	-- is a legitimate value and nil means no row was involved.
	if entry ~= nil then payload.value = rawValue(entry) end
	return payload
end

--- Hands one payload to the caller and to the local bus.
-- The callback runs under pcall because it may open, update or close a menu --
-- including this one -- and a raise inside it must not take the page handler
-- down with it.
local function dispatch(owned, entry, action, reason)
	local payload = payloadOf(owned, entry, action)
	payload.reason = reason

	if entry ~= nil and entry.act ~= nil then
		local ran, failure = pcall(entry.act, payload)
		if not ran then
			Open77.log.error(('[menu] %s row %s raised: %s')
				:format(owned.owner, tostring(entry.id), tostring(failure)))
		end
	end

	local ran, failure = pcall(owned.on, payload)
	if not ran then
		Open77.log.error(('[menu] %s callback raised on %s: %s')
			:format(owned.owner, action, tostring(failure)))
	end
	TriggerEvent(M.Event.ACTION, payload)
end

--- Raises focus for the row under the cursor, for a menu that asked for it.
local function reportFocus(repeated)
	if record == nil or not record.reportFocus then return end
	local payload = payloadOf(record, current(record), 'focus')
	-- The browser repeats a held arrow far faster than the old 55 ms machine
	-- did, so a caller that has to follow the cursor can cheapen a repeat.
	payload.repeated = repeated == true or nil
	local owned = record
	local ran, failure = pcall(owned.on, payload)
	if not ran then
		Open77.log.error(('[menu] %s callback raised on focus: %s')
			:format(owned.owner, tostring(failure)))
	end
	TriggerEvent(M.Event.ACTION, payload)
end

-- ── opening, closing and patching ───────────────────────────────────────────

local wire

--- Stores or clears the status line without drawing. Answers whether it moved.
local function writeStatus(owned, text, bad)
	local clean = text ~= nil and Text.Clean(text, MAX_STATUS) or nil
	if clean == nil or clean == '' then
		if owned.status == nil then return false end
		owned.status = nil
	else
		owned.status = { text = clean, bad = bad == true, atMs = OPX.Now() }
	end
	return true
end

--- Closes the open menu and tells its owner why.
local function closeNow(handle, reason)
	if record == nil then return false, 'no_menu_open' end
	if handle ~= nil and handle ~= record.handle then return false, 'stale_handle' end

	local closing = record
	record = nil
	pendingOpen = false
	OPX.UI.Send(SURFACE, 'menu:close', { handle = closing.handle })
	-- Released here rather than waited for: the page announces the release on
	-- `focus:set` too, but a page that is gone never will, and a focus held
	-- across a close is a player who cannot move.
	OPX.UI.ReleaseFocus(OWNER)
	-- The menu is already gone when this is raised, so a close handler may open
	-- another one.
	dispatch(closing, nil, 'close', reason)
	return true
end

--- Whether an owner's menu opens, and stays open, while the player is down.
local function allowedWhileDown(owner)
	local allowed = M.Settings.WHILE_DOWN
	return type(allowed) == 'table' and allowed[owner] == true
end

--- Opens a menu, replacing the caller's own or, with `steal`, another's.
-- @author dop42
-- @param spec table
-- @return Result
local function Open(spec)
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local owner = spec.owner
	-- There is no invoking resource inside one runtime, so a caller names
	-- itself. Two anonymous callers would look like one owner and replace each
	-- other's menus in silence instead of refusing with menu_busy.
	if not validName(owner, MAX_NAME) then return Result.Err('invalid_owner') end

	-- Nothing to draw on, and there never will be at this start.
	if OPX.UI.Interactive() == nil then return Result.Err('no_surface') end

	if down and not allowedWhileDown(owner) then return Result.Err('player_down') end
	if record ~= nil and record.owner ~= owner and spec.steal ~= true then
		return Result.Err('menu_busy')
	end

	-- Built before the live menu is taken down, so a refused spec costs the
	-- player nothing.
	local built, reason = build(owner, spec)
	if built == nil then return Result.Err(reason) end

	if record ~= nil then
		closeNow(record.handle, record.owner == owner and 'reopened' or 'superseded')
	end

	nextHandle = nextHandle + 1
	built.handle = nextHandle
	record = built
	settle(record)
	if spec.status ~= nil then writeStatus(record, spec.status, spec.statusBad) end

	wire()
	pendingOpen = true
	draw()
	return Result.Ok({ handle = record.handle, id = record.id, nodes = record.nodes })
end

--- Closes a menu the caller holds the handle of.
-- The handle is the capability: a caller answering about a menu that has
-- already gone would otherwise kill the view that replaced it.
-- @author dop42
-- @param handle integer
-- @param reason string|nil
-- @return Result
local function Close(handle, reason)
	if handle == nil then return Result.Err('handle_required') end
	local clean = Text.Clean(reason, 32)
	local closed, failure = closeNow(handle, (clean ~= nil and clean ~= '') and clean or 'caller')
	if not closed then return Result.Err(failure) end
	return Result.Ok(true)
end

--- Rebuilds the open menu from a fresh spec, keeping the player where they are.
-- @author dop42
-- @param handle integer|table the handle, or the spec for the open menu
-- @param spec table|nil
-- @return Result
local function Update(handle, spec)
	if spec == nil and type(handle) == 'table' then handle, spec = nil, handle end
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end
	if record == nil then return Result.Err('no_menu_open') end
	if handle ~= nil and handle ~= record.handle then return Result.Err('stale_handle') end

	local ok, reason = rebuild(record, spec)
	if not ok then return Result.Err(reason) end
	settle(record)
	if spec.status ~= nil then writeStatus(record, spec.status, spec.statusBad) end
	draw()
	return Result.Ok(true)
end

--- Writes the transient line under the list, or clears it with a nil text.
-- @author dop42
-- @param handle integer
-- @param text string|number|nil
-- @param bad boolean|nil True draws the line as a failure.
-- @return Result
local function SetStatus(handle, text, bad)
	if record == nil then return Result.Err('no_menu_open') end
	if handle ~= nil and handle ~= record.handle then return Result.Err('stale_handle') end
	if not validStatus(text) then return Result.Err('invalid_status') end
	if writeStatus(record, text, bad) then draw() end
	return Result.Ok(true)
end

--- What is on screen: the menu, the screen, and the row under the cursor.
-- @author dop42
-- @return Result
local function State()
	if record == nil then return Result.Ok({ open = false }) end
	local screenAt = top(record)
	local entry = current(record)
	return Result.Ok({
		open = true,
		handle = record.handle,
		owner = record.owner,
		menu = record.id,
		title = screenAt.title,
		depth = #record.stack,
		index = screenAt.index,
		total = #screenAt.items,
		itemId = entry.id,
		label = entry.label,
		value = rawValue(entry),
	})
end

--- The keys that drive the menu, for a caller printing its own hint.
-- The page reads them now, so they are the browser's own names and are not
-- rebindable; `backend` is `none` when there is no surface to read them on.
-- @author dop42
-- @return Result
local function Keys()
	if OPX.UI.Interactive() == nil then
		return Result.Ok({ backend = 'none', keys = {}, labels = {} })
	end
	return Result.Ok({
		backend = 'page',
		keys = {
			UP = 'ARROW UP', DOWN = 'ARROW DOWN',
			LEFT = 'ARROW LEFT', RIGHT = 'ARROW RIGHT',
			SELECT = 'ENTER', BACK = 'BACKSPACE',
		},
		labels = {
			UP = locale('menu.key.choose'), DOWN = locale('menu.key.choose'),
			LEFT = locale('menu.key.change'), RIGHT = locale('menu.key.change'),
			SELECT = locale('menu.key.select'), BACK = locale('menu.key.back'),
		},
	})
end

-- ── what the player did ─────────────────────────────────────────────────────

--- ENTER on the row under the cursor. Answers whether the frame changed.
local function activate()
	local entry = current(record)
	if entry.disabled or entry.kind == 'separator' then return false end
	local kind = entry.kind

	if kind == 'submenu' then
		record.stack[#record.stack + 1] =
			screen(entry.items, entry.title, entry.id, entry.cursor)
		settle(record)
		-- Raised after the push, so depth and index already describe the child.
		dispatch(record, entry, 'open')
		return true
	end

	if kind == 'back' then
		if #record.stack > 1 then
			record.stack[#record.stack] = nil
			dispatch(record, entry, 'back')
			return true
		end
		-- Nothing left to pop: at the root a back row closes the menu.
		closeNow(record.handle, 'back')
		return false
	end

	if kind == 'close' then
		closeNow(record.handle, 'item')
		return false
	end

	if holdsValue(entry) then
		if adjust(entry, 1) then
			dispatch(record, entry, 'change')
			return true
		end
		return false
	end

	local closeAfter = entry.close or record.closeOnSelect
	local handle = record.handle
	dispatch(record, entry, 'select')
	-- The handler may have closed this menu, or opened another over it.
	if record == nil or record.handle ~= handle then return false end
	if closeAfter then
		closeNow(handle, 'select')
		return false
	end
	return true
end

--- The open menu when a page payload names it, or nil for a stale one.
local function fromPage(payload)
	if record == nil or type(payload) ~= 'table' then return nil end
	if payload.handle ~= record.handle then return nil end
	return record
end

--- One key the page forwarded.
local function onKey(payload)
	if fromPage(payload) == nil then return end
	local key = payload.key
	if type(key) ~= 'string' or not KEYS[key] then return end
	local repeated = payload['repeat'] == true

	local dirty = false
	local handle = record.handle

	if key == 'down' or key == 'up' then
		if move(record, key == 'down' and 1 or -1) then
			dirty = true
			reportFocus(repeated)
		end
	elseif key == 'right' then
		local entry = current(record)
		if adjust(entry, 1) then
			dispatch(record, entry, 'change')
			dirty = true
		elseif entry.kind == 'submenu' and not entry.disabled then
			dirty = activate()
		end
	elseif key == 'left' then
		local entry = current(record)
		if holdsValue(entry) then
			if adjust(entry, -1) then
				dispatch(record, entry, 'change')
				dirty = true
			end
		elseif #record.stack > 1 then
			record.stack[#record.stack] = nil
			-- No itemId: this is how a handler tells the key from the BACK row.
			dispatch(record, nil, 'back')
			dirty = true
		end
	elseif key == 'enter' then
		-- A held ENTER must not fire the same row twice. The old resource ran
		-- its own 260 ms/55 ms machine and did repeat it; the browser repeats
		-- far faster, and a repeated select is a player who bought ten.
		if repeated then return end
		dirty = activate()
	elseif key == 'back' then
		if repeated then return end
		if #record.stack > 1 then
			record.stack[#record.stack] = nil
			dispatch(record, nil, 'back')
			dirty = true
		else
			closeNow(record.handle, 'back')
			return
		end
	end

	-- Every branch above can close this menu, or open another under a handler.
	if dirty and record ~= nil and record.handle == handle then draw() end
end

--- A row the player pointed at, by its absolute index in the level.
local function onChoose(payload)
	if fromPage(payload) == nil then return end
	local index = Text.Integer(payload.index)
	if index == nil then return end

	local screenAt = top(record)
	-- Re-resolved here, never trusted: the drawn window may be a frame behind.
	if not selectable(screenAt.items[index]) then return end

	local handle = record.handle
	local moved = false
	if screenAt.index ~= index then
		screenAt.index = index
		moved = true
		-- The originals raised focus for UP and DOWN only, because they had no
		-- pointer. A caller following the cursor would be on the wrong row.
		reportFocus(false)
		if record == nil or record.handle ~= handle then return end
	end
	-- Drawn for the move as well as for the landing: pointing at a row that
	-- turns out not to change anything still moved the cursor.
	local changed = activate()
	if (moved or changed) and record ~= nil and record.handle == handle then draw() end
end

--- Escape. The page keeps focus until this answers with a close: the close
--- reason belongs to Lua and the page never decides it.
local function onDismiss(payload)
	if fromPage(payload) == nil then return end
	closeNow(record.handle, 'dismissed')
end

--- What the page's focus stack now holds on this surface.
local function onFocus(payload)
	if payload.focus ~= true then
		-- The stack emptied: nothing on this surface holds anything.
		for owner in pairs(FOCUS) do OPX.UI.ReleaseFocus(owner) end
		return
	end
	local owner = payload.owner
	local wants = type(owner) == 'string' and FOCUS[owner] or nil
	if wants == nil then return end
	OPX.UI.AcquireFocus(owner, wants)
end

--- Wires the page channels once, on the first open.
wire = function()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'menu:key', onKey)
	OPX.UI.On(SURFACE, 'menu:choose', onChoose)
	OPX.UI.On(SURFACE, 'menu:dismiss', onDismiss)
	OPX.UI.On(SURFACE, 'focus:set', onFocus)
end

-- ── upkeep ──────────────────────────────────────────────────────────────────

--- Clears the status line once it has been up long enough.
local function expireStatus(atMs)
	if record == nil or record.status == nil then return end
	local life = finite(M.Settings.STATUS_MS) and M.Settings.STATUS_MS or 6000
	if atMs - record.status.atMs < life then return end
	record.status = nil
	draw()
end

--- Closes a menu whose owner is a module that has stopped.
-- Only a declared module is swept: an owner this runtime knows nothing about
-- is left alone rather than guessed at.
local function sweepOwner()
	if record == nil then return end
	local owner = OPX.Modules.Record(record.owner)
	if owner ~= nil and owner.State ~= 'started' then
		closeNow(record.handle, 'owner_stopped')
	end
end

-- ── the player being down ───────────────────────────────────────────────────

--- Holds the down flag and closes a menu not allowed to stay up.
local function setDown(value)
	down = value == true
	if down and record ~= nil and not allowedWhileDown(record.owner) then
		closeNow(record.handle, 'player_down')
	end
end

--- Catches up once with a player who went down before this module started.
-- A state heard while the read was in flight is newer than the read, and wins.
local function adoptDownState()
	local downed = OPX.Api.Get('downed')
	if downed == nil then return end
	local heard = downHeard
	local answer = downed.IsDown()
	if not answer.ok then
		Open77.log.warn(('[menu] the downed contract did not answer: %s')
			:format(tostring(answer.error)))
		return
	end
	if downHeard ~= heard then return end
	setDown(answer.value.down == true)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Builds the held state.
-- @author dop42
function M.Init()
	record = nil
	nextHandle = 0
	pendingOpen = false
	wired = false
	down = false
	downHeard = 0
end

--- Publishes the menu contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('menu', 1, {
		Open = Open,
		Close = Close,
		Update = Update,
		SetStatus = SetStatus,
		State = State,
		Keys = Keys,
	})
end

--- Wires the down state, the pause key and the upkeep pass.
-- @author dop42
function M.Start()
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
	end)

	-- Escape is swallowed by the plugin before any surface sees it; when it
	-- arrives here rather than on `menu:dismiss`, the reason is the pause menu.
	AddEventHandler(M.Host.PAUSE_KEY, function()
		if record ~= nil then closeNow(record.handle, 'pause') end
	end)

	OPX.Scheduler.Every('menu:upkeep', UPKEEP_MS, function()
		if record == nil then return end
		-- The open is re-sent until the page reports ready: a surface built on
		-- first use is not ready when the first menu opens on it.
		if pendingOpen then draw() end
		expireStatus(OPX.Now())
		sweepOwner()
	end)

	adoptDownState()
end

--- Closes whatever is open and hands the keyboard back.
-- @author dop42
function M.Stop()
	if record ~= nil then closeNow(record.handle, 'stopped') end
	-- A close with no handle blanks whatever the page still holds, which is the
	-- one case where this module cannot know what that is.
	OPX.UI.Send(SURFACE, 'menu:close', {})
	OPX.UI.ReleaseFocus(OWNER)
end
