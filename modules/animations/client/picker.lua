--- The picker, one screen at a time, and its two keys.
-- @author dop42
--
-- Each screen is its own `Open` on the menu contract, NOT one sub-menu tree: the
-- whole catalogue in a single spec went past the host's 1024-value bound on an
-- export call, which dropped the call without a word and left the key doing
-- nothing. The screen stack is kept here. A screen lists at most MAX_LISTED
-- rows and then says how many were left out.
--
-- Do not fold the screens back into one tree.
--
-- The picker is optional: without the menu contract every command, key and
-- contract function still works, and its absence costs one logged line a session.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Opt = M.Opt
local Runtime = M.Runtime
local Keys = M.Keys

M.Picker = {}
local Picker = M.Picker

-- What the menu contract records as this module's own: the owner is how it tells
-- two callers apart, and the id names this particular menu.
local OWNER = 'animations'
local SPEC_ID = 'animations.picker'

-- Stable mapping ids; a player's rebind is stored under them.
local KEY_PICKER = 'opx.animations.picker'
local KEY_STOP = 'opx.animations.stop'

-- Rows listed on one screen before the rest are left out.
local MAX_LISTED = 40

-- How often an open picker checks whether the player has gone down.
local DOWN_MS = 500

-- Screens from the root down; empty while the picker is down.
local stack = {}

-- Handle of the menu screen this file has up, and the stack entry it draws.
local handle, shown = nil, nil

-- Whether the missing menu was already logged this session.
local warned = false

-- The scheduler handle of the down watch.
local downJob = nil

-- Forward-declared: the menu spec carries this callback, and it is written below
-- the drawing it calls back into.
local onRow

-- Calls one function of the menu contract. Answers its value, or a failure code;
-- `menu_not_running` is the one the player is told about by name.
local function call(name, ...)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api[name]) ~= 'function' then return nil, 'menu_not_running' end
	local ran, answer = pcall(api[name], ...)
	if not ran then
		Open77.log.error(('[animations] menu %s raised: %s'):format(name, tostring(answer)))
		return nil, 'menu_raised'
	end
	if type(answer) ~= 'table' then return nil, 'malformed_answer' end
	if answer.ok ~= true then return nil, tostring(answer.error or 'refused') end
	return answer.value or answer, nil
end

-- Whether the menu contract is there to draw with.
local function available()
	local api = OPX.Api.Get('menu')
	return api ~= nil and type(api.Open) == 'function'
end

-- Whether the player is down right now, read from the contract at the moment of
-- use. Without the contract nobody is down.
local function isDown()
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local ran, answer = pcall(api.IsDown)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

-- The Back row every screen below the root ends with. A screen is its own menu,
-- so the menu's own back row closes it with `back`, which is what steps us up.
local function backRow()
	return { id = 'back', label = locale('animations.picker.back'), back = true }
end

-- A row that plays or stops. With CLOSE_ON_SELECT the handler closes the menu
-- itself: a row carrying the menu's own `close` flag becomes a row that ONLY
-- closes, and its data would never reach the handler.
local function choice(id, label, data, extra)
	local item = { id = id, label = label, data = data }
	for key, value in pairs(extra or {}) do item[key] = value end
	return item
end

-- A row that opens another screen.
local function go(id, label, screen, arg, value)
	return { id = id, label = label, value = value, data = { go = screen, arg = arg } }
end

-- Cuts a row list to MAX_LISTED, saying how many were left out.
local function capped(items)
	if #items <= MAX_LISTED then return items end
	local kept = table.move(items, 1, MAX_LISTED, 1, {})
	kept[#kept + 1] = { id = 'more', disabled = true,
		label = locale('animations.picker.more', { count = #items - MAX_LISTED }) }
	return kept
end

-- Screen builders, each answering a title and its rows.
local SCREENS = {}

SCREENS.root = function()
	local stopKey = Keys.Effective(KEY_STOP)
	local items = {
		choice('stop', locale('animations.picker.stop'), { stop = true }, {
			description = stopKey and locale('animations.picker.stopHintKey', { key = stopKey })
				or locale('animations.picker.stopHint'),
		}),
		{ separator = true },
	}
	local categories = {}
	for index = 1, #Catalogue.CATEGORIES do
		local category = Catalogue.CATEGORIES[index]
		-- A category with nothing offered is not drawn.
		if #Runtime.Entries(category) > 0 then
			categories[#categories + 1] = go(category, locale('animations.category.' .. category),
				'category', category)
		end
	end
	for _, item in ipairs(capped(categories)) do items[#items + 1] = item end
	return locale('animations.picker.title'), items
end

SCREENS.category = function(category)
	local rows = {}
	local entries = Catalogue.IsCategory(category) and Runtime.Entries(category:lower()) or {}
	for position = 1, #entries do
		local entry = entries[position]
		local label = locale('animations.name.' .. entry.name)
		local variants = Runtime.Variants(entry.name)
		if #variants == 1 then
			rows[#rows + 1] = choice(entry.name, label, { name = entry.name, variant = variants[1] })
		else
			rows[#rows + 1] = go(entry.name, label, 'variants', entry.name, #variants)
		end
	end
	local title = Catalogue.IsCategory(category) and
		locale('animations.category.' .. category:lower()) or locale('animations.picker.title')
	return title, capped(rows)
end

SCREENS.variants = function(name)
	local rows = {}
	local entry = Runtime.Offered(name)
	local variants = Runtime.Variants(name)
	for number = 1, #variants do
		local variant = variants[number]
		rows[number] = choice('v' .. variant,
			locale('animations.picker.variant', { index = variant }),
			{ name = entry.name, variant = variant },
			{ value = Opt.SHOW_VARIANT_WORDS and entry.words[variant] or nil })
	end
	local title = entry and locale('animations.name.' .. entry.name)
		or locale('animations.picker.title')
	return title, capped(rows)
end

-- Closes whatever screen of ours is up and forgets the stack. Only ever closes
-- what this file opened: a caller cannot close another module's menu.
local function takeDown()
	local closing, waiting = handle, #stack > 0
	handle, shown, stack = nil, nil, {}
	if closing ~= nil then call('Close', closing, 'picker') end
	return closing ~= nil or waiting
end

-- Tells the player why the picker is not up. A log line alone would leave the
-- key looking broken.
local function refused(failure)
	if failure == 'menu_busy' then return Runtime.Notify('info', 'animations.picker.busy') end
	if failure == 'menu_not_running' then return Runtime.Refuse('menu_not_running') end
	Runtime.Notify('warning', 'animations.picker.failed')
end

-- Puts the top screen up, or rebuilds the open one in place.
local function draw(inPlace)
	local current = stack[#stack]
	if current == nil then return end
	local title, items = SCREENS[current.screen](current.arg)
	if #stack > 1 then items[#items + 1] = backRow() end

	if inPlace then
		if handle == nil then return end
		local _, failure = call('Update', handle, { title = title, items = items })
		if failure ~= nil then
			Open77.log.debug('[animations] picker not redrawn: ' .. failure)
		end
		return
	end

	local result, failure = call('Open', {
		owner = OWNER,
		id = SPEC_ID,
		title = title,
		on = onRow,
		cursor = current.cursor,
		items = items,
	})
	if result == nil then
		Open77.log.warn(('[animations] picker %s did not open: %s')
			:format(current.screen, tostring(failure)))
		refused(failure)
		-- A refused open replaces nothing: fall back to the screen still shown
		-- when it is ours, and take everything down otherwise.
		for depth = #stack, 1, -1 do
			if handle ~= nil and stack[depth] == shown then
				for above = #stack, depth + 1, -1 do stack[above] = nil end
				return
			end
		end
		takeDown()
		return
	end
	handle, shown = result.handle, current
end

-- Stacks a screen and draws it.
local function push(screen, arg)
	stack[#stack + 1] = { screen = screen, arg = arg }
	draw()
end

-- Steps up a screen, closing the picker from the root.
local function pop()
	if #stack <= 1 then
		takeDown()
		return
	end
	stack[#stack] = nil
	draw()
end

--- Opens the picker at the root, or on a named category.
-- A screen of ours already up is replaced. The root is stacked under the named
-- category with its cursor on that row, so Back lands there; a category with
-- nothing offered has no row and opens the root.
-- @author dop42
-- @param category string|nil
-- @return table
function Picker.Open(category)
	if isDown() then return { ok = false, error = 'player_down' } end
	if Runtime.Locked() then return { ok = false, error = 'animation_locked' } end
	if not available() then
		if not warned then
			warned = true
			Open77.log.warn('[animations] no menu contract: no picker, the commands and the ' ..
				'animations contract still work')
		end
		return { ok = false, error = 'menu_not_running' }
	end
	if category ~= nil and not Catalogue.IsCategory(category) then
		return { ok = false, error = 'unknown_category' }
	end
	local named = category and category:lower() or nil
	stack = { { screen = 'root', cursor = named } }
	if named ~= nil and #Runtime.Entries(named) > 0 then
		stack[2] = { screen = 'category', arg = named }
	end
	draw()
	return { ok = true, queued = true }
end

--- Closes the picker this file opened.
-- @author dop42
-- @return table
function Picker.Close()
	if not takeDown() then return { ok = false, error = 'picker_not_open' } end
	return { ok = true, queued = true }
end

--- Whether a picker screen of ours is up.
-- @author dop42
-- @return boolean
function Picker.IsOpen()
	return handle ~= nil
end

-- Navigates, plays or stops for a row the menu raised. The shape is checked
-- because the menu also raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then
		return
	end
	if payload.action == 'close' then
		-- A close for a screen this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		-- Back on a one-level screen would close it; step up instead.
		if payload.reason == 'back' and #stack > 1 then return pop() end
		stack = {}
		return
	end
	-- A row arriving from a screen that is closing is ignored while down: a
	-- navigation would reopen one.
	if payload.action ~= 'select' or isDown() then return end

	local data = payload.data
	local current = stack[#stack]
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId
	if (data.go == 'category' or data.go == 'variants') and type(data.arg) == 'string' then
		return push(data.go, data.arg)
	end

	-- Taken down before the request, so the key opens rather than closes and the
	-- refusal toast is not raised under a menu.
	if Opt.CLOSE_ON_SELECT then takeDown() end
	if data.stop == true then
		local stopped = Runtime.Stop('picker')
		if stopped.error == 'animation_locked' then Runtime.Refuse(stopped.error) end
		return
	end
	local result = Runtime.Play(data.name, { variant = data.variant }, 'picker', nil)
	if not result.ok then Runtime.Refuse(result.error) end
end

-- Toggles the picker from its key.
local function pickerPressed()
	if Picker.IsOpen() then
		Picker.Close()
		return
	end
	local result = Picker.Open(nil)
	if not result.ok then Runtime.Refuse(result.error) end
end

-- Stops the local player's animation from the stop key. Nothing in progress is
-- not a refusal.
local function stopPressed()
	local result = Runtime.Stop('key')
	if not result.ok then Runtime.Refuse(result.error) end
end

--- Clears the screen stack.
-- @author dop42
function Picker.Init()
	stack, handle, shown, warned, downJob = {}, nil, nil, false, nil
end

--- Registers both keys, the row channel and the down watch.
-- @author dop42
function Picker.Start()
	Keys.Register(KEY_PICKER, 'animations.key.picker', Opt.KEY_PICKER, pickerPressed)
	Keys.Register(KEY_STOP, 'animations.key.stop', Opt.KEY_STOP, stopPressed)

	RegisterNetEvent(M.Event.PICKER, function(category)
		if type(category) ~= 'string' or category == '' then category = nil end
		local result = Picker.Open(category)
		if not result.ok then Runtime.Refuse(result.error) end
	end)

	-- The Stop row names the stop key, so a rebind redraws an open root in
	-- place; the menu keeps the cursor across an update.
	Keys.OnChanged(function()
		local current = stack[#stack]
		if handle == nil or current == nil or current.screen ~= 'root' or not available() then
			return
		end
		draw(true)
	end)

	-- Going down only ever closes the picker and keeps it closed; standing back
	-- up opens nothing.
	downJob = OPX.Scheduler.Every('animations:down', DOWN_MS, function()
		if handle == nil and #stack == 0 then return end
		if isDown() then takeDown() end
	end)
end

--- Closes the picker and cancels the down watch.
-- @author dop42
function Picker.Shutdown()
	if downJob ~= nil then
		OPX.Scheduler.Cancel(downJob)
		downJob = nil
	end
	takeDown()
end
