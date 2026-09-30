--- Client half: the branch markers, the strip row, the key and the branch menu.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT. The branches come from the server, filtered to
-- this player's routing bucket; the row goes up while the body stands on one;
-- the key asks the server for the branch and both balances, and the menu is
-- drawn from that answer. Every row names a direction and an amount and
-- nothing more: the server measures the distance, reads the balance and moves
-- the money, and its answer -- the new balances -- is what the menu is redrawn
-- from.

local M = OPX.Modules.Get('bank')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

local OWNER = 'bank'
local GROUP = 'branch'
local MENU_ID = 'bank_branch'
local FORM_ID = 'bank_amount'

-- The branch list as the server last sent it, and the markers drawn for it.
local spots, markers = {}, {}
-- The branch underfoot, and whether its row is up.
local nearest, shown = nil, false
local keyRegistered = false
local reportedMarkers, reportedStrip, reportedMenu = false, false, false
local scanJob, askJob = nil, nil

-- The branch menu: its handle and the state it was drawn from.
local menuHandle, drawnState = nil, nil

local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.bank.use', NAME = 'bank.key.use', DEFAULT = 'E' }
end

local function playerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil, nil end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil, nil end
	return x, y
end

local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- Eddies, as the player reads them.
local function money(amount)
	local whole = math.floor((tonumber(amount) or 0) + 0.5)
	local grouped = OPX.Math.GroupDigits(whole)
	return tostring(grouped) .. ' \u{20AC}$'
end

-- ── the markers ─────────────────────────────────────────────────────────────

local function createMarker(branch)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = Access.Marker()
	local read, id, reason = pcall(api.create, {
		position = { x = branch.x, y = branch.y, z = branch.z + look.lift },
		shape = look.shape,
		style = look.style,
		radius = look.radius,
		maxDistance = Access.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

local function reconcile(x, y)
	local limit = Access.MaxDistance()
	local reach = limit * limit
	for key, branch in pairs(spots) do
		local flat = x ~= nil and Access.FlatDistanceSquared(branch, x, y) or nil
		local wanted = flat ~= nil and flat <= reach
		if wanted and markers[key] == nil then
			local id, failure = createMarker(branch)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[bank] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end
	for key, id in pairs(markers) do
		if spots[key] == nil then
			removeMarker(id)
			markers[key] = nil
		end
	end
end

local function clearMarkers()
	for key, id in pairs(markers) do
		removeMarker(id)
		markers[key] = nil
	end
end

-- ── the strip ───────────────────────────────────────────────────────────────

local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

local function syncPrompt()
	local want = nearest ~= nil and menuHandle == nil and keyLabel() ~= nil and not captured()
	if want == shown then return end
	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[bank] no prompts contract; the strip row is not shown')
		end
		shown = false
		return
	end
	shown = want
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			label = locale('bank.prompt'),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[bank] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.bank.answer',
		kind = kind,
		title = locale('bank.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[bank] ' .. tostring(message)) end
end

-- ── the menu ────────────────────────────────────────────────────────────────

local onRow

--- Asks the server to move money. The payload is a direction and an amount.
-- @param kind string
-- @param amount integer|nil
-- @param all boolean|nil
local function move(kind, amount, all)
	if not M.KINDS[kind] then return end
	TriggerServerEvent(M.Event.MOVE, { kind = kind, amount = amount, all = all == true or nil })
	publish({ ok = true, queued = true, kind = kind, amount = amount, all = all == true or nil })
end

--- The rows of one direction: the quick amounts, all of it, another amount.
local function directionRows(items, kind, available, state)
	local sign = kind == 'withdraw' and 'minus' or 'plus'
	items[#items + 1] = { separator = true, label = locale('bank.menu.' .. kind) }
	for _, amount in ipairs(type(state.amounts) == 'table' and state.amounts or Access.AMOUNTS) do
		items[#items + 1] = {
			id = ('%s_%d'):format(kind, amount),
			icon = sign,
			label = locale('bank.menu.' .. kind .. 'Amount', { amount = money(amount) }),
			disabled = amount > available,
			data = { kind = kind, amount = amount },
		}
	end
	items[#items + 1] = {
		id = kind .. '_all',
		icon = sign,
		label = locale('bank.menu.' .. kind .. 'All'),
		value = money(math.min(available, tonumber(state.max) or Access.MAX_TRANSFER)),
		disabled = available <= 0,
		data = { kind = kind, all = true },
	}
	items[#items + 1] = {
		id = kind .. '_other',
		icon = 'list',
		label = locale('bank.menu.other'),
		description = locale('bank.menu.otherHint'),
		disabled = available <= 0,
		submenu = true,
		data = { kind = kind, ask = true },
	}
end

--- The whole menu, built from the server's answer.
local function menuSpec(state)
	local items = {
		{ id = 'account', icon = 'money', label = locale('bank.menu.account'),
			value = money(state.account), disabled = true },
		{ id = 'cash', icon = 'money', label = locale('bank.menu.cash'),
			value = money(state.cash), disabled = true },
	}
	directionRows(items, 'withdraw', tonumber(state.account) or 0, state)
	directionRows(items, 'deposit', tonumber(state.cash) or 0, state)
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'close', label = locale('bank.menu.close'), close = true }
	local branch = type(state.branch) == 'table' and state.branch or {}
	return {
		owner = OWNER,
		id = MENU_ID,
		title = locale('bank.menu.title', { branch = tostring(branch.label or branch.key or '') }),
		items = items,
		on = onRow,
		steal = true,
	}
end

--- Opens the branch menu on a state the server just sent, or redraws it.
local function showMenu(state)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.warn('[bank] no menu contract: the branch menu cannot be drawn')
		end
		return say('error', locale('bank.noMenu'))
	end
	drawnState = state
	if menuHandle ~= nil and type(api.Update) == 'function' then
		local spec = menuSpec(state)
		local updated = api.Update(menuHandle, { title = spec.title, items = spec.items })
		if type(updated) == 'table' and updated.ok == true then return end
	end
	local opened = api.Open(menuSpec(state))
	if type(opened) ~= 'table' or opened.ok ~= true then
		menuHandle = nil
		local failure = type(opened) == 'table' and tostring(opened.error or 'refused') or 'refused'
		Open77.log.warn(('[bank] the branch menu did not open: %s'):format(failure))
		return say('error', locale('bank.noMenu'))
	end
	menuHandle = opened.value.handle
	syncPrompt()
end

local function closeMenu()
	local api = OPX.Api.Get('menu')
	local closing = menuHandle
	menuHandle = nil
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, 'bank')
	end
end

--- The "other amount" form, for one direction.
local function askAmount(kind)
	local api = OPX.Api.Get('form')
	if api == nil or type(api.Open) ~= 'function' then return say('error', locale('bank.noMenu')) end
	closeMenu()
	local ceiling = drawnState ~= nil and tonumber(drawnState.max) or Access.MAX_TRANSFER
	local opened = api.Open({
		owner = OWNER,
		id = FORM_ID,
		title = locale('bank.form.' .. kind),
		fields = { {
			id = 'amount',
			label = locale('bank.form.amount'),
			description = locale('bank.form.hint', { max = money(ceiling) }),
			charset = 'digits',
			maxLength = #tostring(math.floor(ceiling)),
			required = true,
		} },
		on = function(payload)
			if type(payload) ~= 'table' then return end
			if payload.action == 'submit' and type(payload.values) == 'table' then
				local amount = M.Amount(payload.values.amount, ceiling)
				if amount == nil then
					say('error', locale('bank.refused.badAmount'))
					return TriggerServerEvent(M.Event.OPEN)
				end
				return move(kind, amount, false)
			end
			-- Cancelled: back to the branch, as the server says it is now.
			TriggerServerEvent(M.Event.OPEN)
		end,
	})
	if type(opened) ~= 'table' or opened.ok ~= true then
		Open77.log.warn(('[bank] the amount form did not open: %s')
			:format(type(opened) == 'table' and tostring(opened.error) or 'refused'))
		say('error', locale('bank.noMenu'))
	end
end

onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= MENU_ID then return end
	if payload.action == 'close' then
		if payload.reason == 'reopened' or payload.handle ~= menuHandle then return end
		menuHandle, drawnState = nil, nil
		return syncPrompt()
	end
	if payload.action ~= 'select' or captured() then return end
	local data = payload.data
	if type(data) ~= 'table' or not M.KINDS[data.kind] then return end
	if data.ask == true then return askAmount(data.kind) end
	move(data.kind, data.amount, data.all == true)
end

-- ── the door ────────────────────────────────────────────────────────────────

--- Opens the branch the player is standing on: asks the server for it.
-- @param origin string|nil
-- @return table
function Runtime.Open(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end
	if nearest == nil then
		result.ok, result.error = false, 'bank.refused.notAtBranch'
		publish(result)
		return result
	end
	result.branch = nearest.key
	TriggerServerEvent(M.Event.OPEN)
	result.ok, result.queued = true, true
	publish(result)
	return result
end

function Runtime.Nearest() return nearest end
function Runtime.Spots() return spots end
function Runtime.Report()
	return {
		spots = OPX.Table.Count(spots),
		markers = OPX.Table.Count(markers),
		nearest = nearest and nearest.key or nil,
		shown = shown,
		key = keyLabel(),
		menu = menuHandle ~= nil,
	}
end

local function scan()
	local x, y = playerXY()
	if x == nil then
		nearest = nil
		syncPrompt()
		return
	end
	nearest = Access.Nearest(spots, x, y)
	-- Walking away from the counter takes the menu down with it: a branch menu
	-- open across the street is a menu whose every row the server refuses.
	if nearest == nil and menuHandle ~= nil then
		closeMenu()
		drawnState = nil
	end
	syncPrompt()
	reconcile(x, y)
end

-- ── the phases ──────────────────────────────────────────────────────────────

function M.Init()
	spots, markers = {}, {}
	nearest, shown, keyRegistered = nil, false, false
	reportedMarkers, reportedStrip, reportedMenu = false, false, false
	scanJob, askJob = nil, nil
	menuHandle, drawnState = nil, nil
end

function M.Start()
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Open, 'key')
				if not ran then
					Open77.log.error(('[bank] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[bank] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.spots or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local branch, why = Access.FromWire(listed[index])
			if branch == nil then
				Open77.log.warn('[bank] a branch was refused: ' .. tostring(why))
			else
				accepted[branch.key] = branch
			end
		end
		spots = accepted
		scan()
	end)

	RegisterNetEvent(M.Event.STATE, function(payload)
		if type(payload) ~= 'table' then return end
		if payload.ok ~= true then
			local code = tostring(payload.reason or 'failed')
			publish({ ok = false, error = code, source = 'server' })
			return say('error', locale(M.Refusal[code] or 'bank.refused.failed', { reason = code }))
		end
		showMenu(payload)
	end)

	RegisterNetEvent(M.Event.RESULT, function(payload)
		if type(payload) ~= 'table' then return end
		publish({ ok = payload.ok == true, result = payload, source = 'server' })
		if payload.ok ~= true then
			local code = tostring(payload.reason or 'failed')
			say('error', locale(M.Refusal[code] or 'bank.refused.failed',
				{ reason = tostring(payload.detail or code) }))
			-- The menu is redrawn from the server's word, not left on a stale one.
			return TriggerServerEvent(M.Event.OPEN)
		end
		say('success', locale('bank.done.' .. tostring(payload.kind), {
			amount = money(payload.amount), account = money(payload.account), cash = money(payload.cash),
		}))
		local state = {
			branch = payload.branch,
			account = payload.account,
			cash = payload.cash,
			amounts = drawnState ~= nil and drawnState.amounts or Access.AMOUNTS,
			max = drawnState ~= nil and drawnState.max or Access.MAX_TRANSFER,
		}
		if nearest ~= nil then showMenu(state) end
	end)

	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then Open77.log.warn('[bank] the branch list could not be asked for: ' .. tostring(reason)) end
	end
	ask()
	askJob = OPX.Scheduler.Every('bank:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	if Access.SCAN_MS <= 0 then
		Open77.log.error('[bank] SCAN_MS is not a whole number of milliseconds above zero; no marker is drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('bank:scan', Access.SCAN_MS, scan)
	scan()
end

function M.Stop()
	if scanJob ~= nil then OPX.Scheduler.Cancel(scanJob) end
	if askJob ~= nil then OPX.Scheduler.Cancel(askJob) end
	closeMenu()
	clearMarkers()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, GROUP) end
	M.Init()
end
