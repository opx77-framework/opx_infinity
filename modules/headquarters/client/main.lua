--- Client half: the markers, and the one row that names the place.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT WITH ONE KEY BEHIND IT. The marker is a light
-- on the floor and the row is a name; the key the row wears is what the station
-- DOES when touched, and that is the operator's `PRESS` block: say the
-- station's own name, or open the options `MENU.ROWS` declares. A headquarters
-- still DESIGNATES -- it says where the station is, so an operator can place
-- the MaxTac AV pads, the garages and the stores around it -- and the one
-- thing it does beyond that is the operator's own list of options, which is
-- what keeps it a designation rather than a door.
--
-- The points come from the server and never from `config/headquarters.lua`
-- directly: the server filters the list to this player's own routing bucket,
-- and a client that read the config alone would draw markers for a bucket it is
-- not in.
--
-- Markers are engine primitives, so nothing is redrawn per frame: one is
-- created when a point comes into range and removed when it leaves.
-- `reconcile` owns that set for as long as the module is running, and
-- `clearMarkers` empties it on the way down. Creation is guarded -- the
-- `world.markers` API may not be installed at all, and a raise here would take
-- the scan down with it.

local M = OPX.Modules.Get('headquarters')
local Access = M.Access

-- What the prompts contract records as this module's own.
local OWNER = 'headquarters'
local GROUP = 'spot'

-- What the MENU contract records as this module's own: `owner` and `id` come
-- back on every row action, and they are how this file knows a close is its
-- close.
local MENU_ID = 'headquarters.options'

-- The point list as the server last sent it, and the markers drawn for it.
local spots, markers = {}, {}

-- The point the player is standing on, and what the row is currently saying.
local nearest, shown, shownLabel = nil, false, nil

-- Whether each of the three failures was already logged: a marker that cannot
-- be drawn, a row that cannot be posted and a config that named no usable key
-- are different problems and a player reading the log wants to know which one
-- they have.
local reportedMarkers, reportedStrip, reportedKey, reportedMenu = false, false, false, false

-- Whether the host took the key mapping. The row wears no cap until it has:
-- a row that promises a press with no key behind it is the `!` problem again.
local keyRegistered = false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- The player's own ground position, or nil before there is a world to read.
local function playerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- Whether another surface holds the keyboard. Kept module-local rather than
-- folded into a shared helper that answers captured where the read itself
-- raises: a row is not a key row and this half presses nothing, so a captured
-- surface costs it nothing at all. It is read anyway so the row comes down
-- while a player is typing rather than shouting a place name over their chat.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

-- ── the markers ─────────────────────────────────────────────────────────────

-- Creates one marker, or answers why it could not be. Never raises.
local function createMarker(spot)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = Access.Marker()
	local read, id, reason = pcall(api.create, {
		-- The point's declared height plus the look's own lift: a ring left at
		-- floor height is co-planar with the floor and draws nothing at all.
		position = { x = spot.x, y = spot.y, z = spot.z + look.lift },
		shape = look.shape,
		style = look.style,
		radius = look.radius,
		maxDistance = Access.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

-- Removes one marker without raising.
local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

-- Brings the drawn set in line with what is in range: a point within
-- MAX_DISTANCE has a marker, one beyond it does not. Touches nothing when the
-- set would not change. The position is threaded through, not read again --
-- the scan has just read it.
local function reconcile(x, y)
	local reach = Access.MaxDistance()
	reach = reach * reach

	for key, spot in pairs(spots) do
		local flat = nil
		if x ~= nil then flat = Access.FlatDistanceSquared(spot, x, y) end
		local wanted = flat ~= nil and flat <= reach
		if wanted and markers[key] == nil then
			local id, failure = createMarker(spot)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[headquarters] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end

	-- A point the server no longer names loses its marker here rather than
	-- being left behind: it may have gone while it was in range.
	for key, id in pairs(markers) do
		if spots[key] == nil then
			removeMarker(id)
			markers[key] = nil
		end
	end
end

-- Drops every marker this module drew.
local function clearMarkers()
	for key, id in pairs(markers) do
		removeMarker(id)
		markers[key] = nil
	end
end

-- ── the strip ───────────────────────────────────────────────────────────────

-- Names the key the row is bound to, or nil when it is off or was refused --
-- a row with no key to name says nothing.
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = Access.KEY
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

-- Brings the row in line with where the player is standing: on a headquarters,
-- it names the place; anywhere else, it is down. The row wears the REGISTERED
-- key -- the same binding the press answers to -- because a cap that names no
-- real key is a key the player presses to nothing.
local function syncPrompt()
	local key = Access.KEY
	if key == nil then
		if nearest ~= nil and not reportedKey then
			reportedKey = true
			Open77.log.warn('[headquarters] KEY is not a usable keybind block; the name row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	local want = nearest ~= nil and keyLabel() ~= nil and not captured()
	local label = want and nearest.label or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the markers still draw, and this is said
		-- once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[headquarters] no prompts contract; the name row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	shown, shownLabel = want, label
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = key.ID },
			-- The operator's own words, and beside them the one word this
			-- module knows in the player's own language.
			label = label,
			value = locale('headquarters.prompt.value'),
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
		Open77.log.warn('[headquarters] the name row was refused: ' .. failure)
	end
end

-- ── the press ────────────────────────────────────────────────────────────────

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. One id, so a second press replaces the first rather than stacking.
-- How long it stays is the operator's `PRESS.TOAST_MS`.
local function say(message)
	local raised = OPX.Toast.Show({
		id = 'opx.headquarters.read',
		kind = 'info',
		title = locale('headquarters.title'),
		message = message,
		durationMs = Access.Press().toastMs,
	})
	if raised == nil then Open77.log.info('[headquarters] ' .. tostring(message)) end
end

-- THE DESIGNATION'S OWN ANSWER, AND THE FALLBACK FOR EVERY OTHER ONE. It says
-- its own name. The row is already naming the place while the player stands on
-- it, so this is the same fact asked for rather than stumbled over -- and it
-- is what the press does when the menu has no rows, when no menu contract is
-- installed, or when `PRESS.ACTION` says `read`. The key always answers.
local function readBack()
	if nearest == nil then return end
	say(tostring(nearest.label))
end

-- ── the options ──────────────────────────────────────────────────────────────────

-- The open menu's handle, and the row handler declared ahead of the function
-- that installs it.
local menuHandle, onMenuRow = nil, nil

-- The menu contract, or nil with one line said about it.
local function menuApi()
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.info('[headquarters] no menu contract: the press only reads the station name')
		end
		return nil
	end
	return api
end

-- Takes the options down for a reason of this file's own.
local function takeMenuDown()
	local closing = menuHandle
	menuHandle = nil
	local api = OPX.Api.Get('menu')
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, 'headquarters')
	end
end

-- Runs one option row. A COMMAND row is executed exactly as the chat box would
-- -- the same event, the same tokens, and the same ACL waiting on the far end
-- -- and a row that carries no command speaks the station's own name.
local function runRow(row)
	if row.command == nil then
		readBack()
		return
	end
	local tokens = {}
	for piece in tostring(row.command):gsub('^/', ''):gmatch('%S+') do
		tokens[#tokens + 1] = piece
	end
	if #tokens == 0 then return end
	local sent, reason = TriggerServerEvent(M.Host.COMMAND_EXECUTE, table.unpack(tokens))
	if not sent then
		Open77.log.warn(('[headquarters] option %s not sent: %s')
			:format(tostring(row.id), tostring(reason)))
	end
end

-- Opens the operator's options on the station the player stands on. Answers
-- whether it opened, so the press can fall back to reading the name.
local function openMenu()
	local rows = Access.MenuRows()
	local api = nil
	if #rows > 0 then api = menuApi() end
	if api == nil then return false end

	local items = {}
	for index = 1, #rows do
		local row = rows[index]
		items[#items + 1] = {
			id = row.id,
			-- The operator's own words, shown as written.
			label = row.label,
			data = { row = index },
		}
	end
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'close', label = locale('headquarters.menu.close'), close = true }

	local where = Access.MenuChrome()
	local opened = api.Open({
		owner = OWNER,
		id = MENU_ID,
		title = tostring(nearest.label),
		on = onMenuRow,
		anchor = where.ANCHOR,
		width = where.WIDTH,
		height = where.HEIGHT,
		maxHeight = where.MAX_HEIGHT_VH,
		rows = where.VISIBLE_ROWS,
		items = items,
	})
	if opened == nil or opened.ok ~= true then
		local failure = type(opened) == 'table' and tostring(opened.error or 'refused') or 'refused'
		if not reportedMenu then
			reportedMenu = true
			Open77.log.warn('[headquarters] the options did not open: ' .. failure)
		end
		return false
	end
	menuHandle = opened.value.handle
	return true
end

-- Acts on a row the menu raised. The shape is checked because the menu also
-- raises every action on its own public bus.
onMenuRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= MENU_ID then return end
	if payload.action == 'close' then
		-- A close for a menu this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= menuHandle then return end
		menuHandle = nil
		return
	end
	if payload.action ~= 'select' or captured() then return end
	local data = payload.data
	local index = type(data) == 'table' and tonumber(data.row) or nil
	local row = index ~= nil and Access.MenuRows()[index] or nil
	if row == nil then return end
	-- The pick takes the options down first: whatever the row does next
	-- speaks for itself and should not compete with the panel.
	takeMenuDown()
	local ran, failure = pcall(runRow, row)
	if not ran then
		Open77.log.error(('[headquarters] option %s: %s')
			:format(tostring(row.id), tostring(failure)))
	end
end

-- THE PRESS. `PRESS.ACTION` decides what the station does when touched:
-- `menu` opens the operator's options and `read` says the name. A menu that
-- cannot open -- no rows, no contract -- falls back to the name, so the key
-- always answers. A second press takes the options down, the same bargain the
-- garages list makes.
local function press()
	if nearest == nil then return end
	if menuHandle ~= nil then
		return takeMenuDown()
	end
	if Access.Press().action == 'menu' and openMenu() then
		return
	end
	readBack()
end

-- ── the surface the blips module reads ─────────────────────────────────────

M.Runtime = {}

--- Every point this client was told about, by key, each carrying the map-pin
-- look its own config row declares (`BLIP`) or none at all. `modules/blips`
-- reads this on its own scan, the same way it reads the garages and
-- dealership clients' `Runtime.Spots()`.
-- @author XEROX710
-- @return table
function M.Runtime.Spots()
	-- The look is resolved on every read rather than held: config is live and
	-- the blips module re-reads on its own cadence, so a BLIP block fixed
	-- between two passes takes effect on the next one without a re-SYNC.
	for key, spot in pairs(spots) do
		spot.blip = Access.BlipLook(key)
	end
	return spots
end

--- What this client knows, for a diagnostic or a test.
-- @return table
function M.Report()
	return {
		spots = OPX.Table.Count(spots),
		markers = OPX.Table.Count(markers),
		nearest = nearest and nearest.key or nil,
		label = nearest and nearest.label or nil,
		shown = shown,
		key = keyLabel(),
		menu = menuHandle ~= nil,
		press = Access.Press().action,
	}
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- One pass: where the player is, which point they are on, and what is drawn.
-- A pass with no points at all still reconciles, so a list that was cleared
-- takes its markers down with it.
local function scan()
	local x, y = playerXY()
	if x == nil then
		nearest = nil
		takeMenuDown()
		syncPrompt()
		return
	end
	nearest = Access.Nearest(spots, x, y)
	-- The options belong to the station: walking off it takes them down, the
	-- same as the row coming off.
	if nearest == nil then takeMenuDown() end
	syncPrompt()
	reconcile(x, y)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
function M.Init()
	spots, markers = {}, {}
	nearest, shown, shownLabel, keyRegistered = nil, false, nil, false
	reportedMarkers, reportedStrip, reportedKey, reportedMenu = false, false, false, false
	menuHandle = nil
	scanJob, askJob = nil, nil
end

--- Declares the key, wires the server's one event and the two loops.
function M.Start()
	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local key = Access.KEY
	if key ~= nil and key.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, key.ID, locale(key.NAME),
			key.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(press)
				if not ran then
					Open77.log.error(('[headquarters] key %s: %s'):format(key.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Reading only one of them logs a working mapping as
		-- refused.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[headquarters] key mapping %s (%s) not registered: %s')
				:format(key.ID, tostring(key.DEFAULT), tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	elseif key ~= nil then
		-- Off on purpose rather than broken: `DEFAULT = false` is how an
		-- operator turns the press and the row off together.
		Open77.log.info('[headquarters] KEY.DEFAULT is off: the name row is not shown')
	end

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.spots or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local spot, why = Access.FromWire(listed[index])
			if spot == nil then
				Open77.log.warn('[headquarters] a point was refused: ' .. tostring(why))
			else
				accepted[spot.key] = spot
			end
		end
		spots = accepted
		-- A full pass, not just the markers: a list that arrives while the
		-- player is standing on a point must put its row up now rather than
		-- wait for the next scan.
		scan()
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[headquarters] the point list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('headquarters:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[headquarters] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('headquarters:scan', Access.SCAN_MS, scan)
	-- One pass now, so a point already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, takes the markers down and hands the strip back.
function M.Stop()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	clearMarkers()
	takeMenuDown()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	M.Init()
end
