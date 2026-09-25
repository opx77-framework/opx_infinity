--- Client half: the markers, the strip row, the key and the garage list.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT. The nearest point, the radius and the list all
-- decide only what this player is offered; the server re-derives the distance,
-- the bucket, the ownership and which exit is free before a vehicle exists.
--
-- The points come from the server and never from `config/garages.lua` directly:
-- the server adopts garages out of the legacy table as well as reading the file,
-- and it filters the list to this player's own routing bucket. A client that
-- read the config alone would miss every adopted garage and would draw markers
-- for a bucket it is not in.
--
-- TWO KINDS OF POINT, AND THE KEY DOES A DIFFERENT THING ON EACH. A MENU point
-- opens the list of everything filed under that garage's key, wherever it was
-- stored; an ENTRY point takes in the vehicle the player is sitting in. Which
-- one a marker is travels with it on the wire, so this half never guesses.
--
-- THE LIST IS ASKED FOR EVERY TIME IT OPENS and never cached. A roster held
-- between two opens is a roster that has missed a purchase, a sale, or the same
-- garage's other door being used by the same player a minute ago.
--
-- Markers are engine primitives, so nothing is redrawn per frame: one is created
-- when a point comes into range and removed when it leaves. `reconcile` owns
-- that set for as long as the module is running, and `clearMarkers` empties it
-- on the way down; nothing else writes it. Creation is guarded -- the
-- `world.markers` API may not be installed at all, and a raise here would take
-- the scan down with it.

local M = OPX.Modules.Get('garages')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'garages'
local GROUP = 'spot'

-- The id the list is opened under, and the same id comes back on every payload.
local SPEC_ID = 'garages'

-- The point list as the server last sent it, and the markers drawn for it.
local spots = {}
local markers = {}

-- The point the player is standing on, whether its row is up, and which label
-- that row carries: one key does three things across two kinds of point, so the
-- row has several possible texts and a change between them is a redraw.
local nearest, shown, shownLabel = nil, false, nil

-- The open list's handle, and what it is listing.
local handle, listing = nil, nil

-- Whether the key mapping answered.
local keyRegistered = false

-- Whether each of the three failures was already logged: a marker that cannot be
-- drawn, a row that cannot be posted and a list that cannot be opened are
-- different problems and a player reading the log wants to know which one they
-- have.
local reportedMarkers, reportedStrip, reportedMenu = false, false, false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- Declared ahead of the functions that reference each other.
local syncPrompt, onRow

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.garages.use', NAME = 'garages.key.use', DEFAULT = 'E' }
end

-- Reads the list geometry, with the shipped panel as the fallback so a config
-- that lost its MENU block still opens a centred list rather than a strip down
-- the corner. The menu module clamps every value it is handed.
local function menuSettings()
	local declared = type(M.Settings.MENU) == 'table' and M.Settings.MENU or nil
	return declared or { ANCHOR = 'center', WIDTH = 560, HEIGHT = 560,
		MAX_HEIGHT_VH = 88, VISIBLE_ROWS = 12 }
end

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
-- folded into `OPX.Keys.IsCaptured`, which answers captured when the read itself
-- raises where this answers free.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

-- Whether the player is sitting in a vehicle. This is the client's half of the
-- one decision the door makes, and it is a HINT: it chooses which text the row
-- shows, and nothing else. The server asks the host the same question before it
-- puts anything away.
local function seated()
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then
		return false
	end
	local read, assignment = pcall(vehicles.getPlayerSeat)
	return read and type(assignment) == 'table'
end

-- What the key is about to do, as a locale key. A door says "put it away" while
-- the player is sitting in something and "drive in" while they are not; a menu
-- point says what it opens, per kind.
local function promptLabel()
	if nearest == nil then return nil end
	if nearest.role == M.ROLE.ENTRY then
		return seated() and 'garages.prompt.putAway' or 'garages.prompt.driveIn'
	end
	return 'garages.prompt.' .. tostring(nearest.kind)
end

-- ── the markers ─────────────────────────────────────────────────────────────

-- Creates one marker, or answers why it could not be. Never raises.
local function createMarker(spot)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	-- The ROLE as well as the kind: a door and a list are two different promises
	-- and a player who cannot tell them apart drives into the wrong one.
	local look = Access.Marker(spot.kind, spot.role)
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
-- set would not change.
--
-- THE POSITION IS THREADED THROUGH, NOT READ AGAIN. `scan()` -- the only caller
-- -- has just read it for `Access.Nearest`, and reading it a second time here
-- made this module cost TWO host position reads per pass at SCAN_MS.
-- @param x number|nil the player's position, or nil where it could not be read
-- @param y number|nil
local function reconcile(x, y)
	local limit = Access.MaxDistance()
	local reach = limit * limit

	for key, spot in pairs(spots) do
		local flat = nil
		if x ~= nil then flat = Access.FlatDistanceSquared(spot, x, y) end
		local wanted = flat ~= nil and flat <= reach
		if wanted and markers[key] == nil then
			local id, failure = createMarker(spot)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[garages] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end

	-- A point the server no longer names loses its marker here rather than being
	-- left behind: it may have gone while it was in range.
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

-- Names the key the row is bound to, or nil when it is off or was refused -- a
-- row with no key to name says nothing, which is why `RegisterKeyMapping`'s
-- answer is kept rather than assumed.
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

-- Brings the strip in line with where the player is standing AND with what they
-- are sitting in: a row that went on saying "bring out a vehicle" while the
-- player sat in one would be naming the wrong job for the key under it. The row
-- is down while the list is up, because the key then belongs to the list.
syncPrompt = function()
	local want = nearest ~= nil and handle == nil and keyLabel() ~= nil and not captured()
	local label = want and promptLabel() or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the command still brings the vehicle out,
		-- and this is said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[garages] no prompts contract; the strip row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	shown, shownLabel = want, label
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line.
			label = locale(label),
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
		Open77.log.warn('[garages] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Refusals and successes share the one id, so the last thing said
-- replaces the one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.garages.answer',
		kind = kind,
		title = locale('garages.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[garages] ' .. tostring(message)) end
end

-- ── the list ────────────────────────────────────────────────────────────────

-- The menu contract, or nil with one line said about it.
local function menuApi()
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.info('[garages] no menu contract: the garage list cannot be drawn, and ' ..
				'/opx.garages.bring still brings a vehicle out')
		end
		return nil
	end
	return api
end

-- Takes the list down for a reason of this file's own.
local function takeDown()
	local closing = handle
	handle, listing = nil, nil
	local api = OPX.Api.Get('menu')
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, 'garages')
	end
	syncPrompt()
	return closing ~= nil
end

-- Opens the list the server just answered with.
-- `here` is carried into the row rather than dropped, because "the car you left
-- at this garage" and "the car you left at the other end of the city, which will
-- be fetched here" are different facts about the same row and the player is
-- about to choose between them.
local function openList(payload)
	local rows = type(payload) == 'table' and payload.vehicles or nil
	if type(rows) ~= 'table' or #rows == 0 then
		takeDown()
		return say('error', locale('garages.nothingHere'))
	end
	local api = menuApi()
	if api == nil then return end

	local items = {}
	for index = 1, #rows do
		local row = rows[index]
		items[#items + 1] = {
			id = tostring(row.plate),
			label = tostring(row.plate),
			value = locale(row.here and 'garages.list.here' or 'garages.list.away'),
			data = { plate = row.plate },
		}
	end
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'close', label = locale('garages.close'), close = true }

	local where = menuSettings()
	local opened = api.Open({
		owner = OWNER,
		id = SPEC_ID,
		title = locale('garages.menu.title', { garage = tostring(payload.label) }),
		on = onRow,
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
			Open77.log.warn(('[garages] the list did not open: %s'):format(failure))
		end
		return takeDown()
	end
	handle = opened.value.handle
	listing = payload.spot
	syncPrompt()
end

-- Sends the bring-out this file has already decided to offer.
local function bring(plate)
	local key = listing
	takeDown()
	if type(key) ~= 'string' then return end
	local sent, reason = TriggerServerEvent(M.Event.REQUEST, key, plate)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		return say('error', locale('garages.refused'))
	end
	publish({ ok = true, queued = true, spot = key, plate = plate, source = 'menu' })
end

-- Acts on a row the list raised. The shape is checked because the menu also
-- raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end
	if payload.action == 'close' then
		-- A close for a list this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle, listing = nil, nil
		return syncPrompt()
	end
	if payload.action ~= 'select' or captured() then return end
	local data = payload.data
	if type(data) ~= 'table' or type(data.plate) ~= 'string' then return end
	bring(data.plate)
end

-- ── the request ─────────────────────────────────────────────────────────────

--- Presses the key on whatever the player is standing on.
-- Every refusal here is local and changes nothing: the server decides again.
-- @author XEROX710
-- @param origin string|nil the key or a caller's name
-- @return table
function Runtime.Use(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end
	-- The key closes an open list rather than asking for a second one.
	if handle ~= nil then
		takeDown()
		result.ok, result.closed = true, true
		publish(result)
		return result
	end
	if nearest == nil then
		result.ok, result.error = false, 'garages.noSuchSpot'
		publish(result)
		return result
	end

	-- WHICH EVENT IS DECIDED BY THE POINT AND NOT BY THIS FILE'S OPINION OF IT.
	-- A menu point asks for a roster; a door asks the server to act, and the
	-- server -- never the client -- decides whether that is a put-away or a
	-- bring-out, from the seat the host reports.
	local event = nearest.role == M.ROLE.MENU and M.Event.LIST or M.Event.REQUEST
	local sent, reason = TriggerServerEvent(event, nearest.key)
	if not sent then
		result.ok, result.error = false, tostring(reason or 'not_sent')
		publish(result)
		return result
	end
	result.ok, result.spot, result.queued = true, nearest.key, true
	publish(result)
	return result
end

--- The point the player is standing on, or nil.
-- @author XEROX710
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every point this client was told about, by key.
-- @author XEROX710
-- @return table
function Runtime.Spots()
	return spots
end

--- Every garage this client was told about, by the key a vehicle is filed under.
-- Derived from the points rather than sent twice: a second payload of the same
-- facts is a second payload to keep in step.
-- @author XEROX710
-- @return table
function Runtime.Garages()
	local listed = {}
	for _, spot in pairs(spots) do
		if listed[spot.garage] == nil then
			listed[spot.garage] = { key = spot.garage, label = spot.label, kind = spot.kind }
		end
	end
	return listed
end

--- What this client knows, for a diagnostic or a test.
-- @author XEROX710
-- @return table
function Runtime.Report()
	return {
		spots = OPX.Table.Count(spots),
		garages = OPX.Table.Count(Runtime.Garages()),
		markers = OPX.Table.Count(markers),
		nearest = nearest and nearest.key or nil,
		-- Which kind of point is underfoot, so a diagnostic can tell a door from
		-- a list without looking the key up.
		role = nearest and nearest.role or nil,
		shown = shown,
		label = shownLabel,
		listing = listing,
		key = keyLabel(),
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
		syncPrompt()
		return
	end
	nearest = Access.Nearest(spots, x, y)
	syncPrompt()
	reconcile(x, y)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author XEROX710
function Runtime.Init()
	spots, markers = {}, {}
	nearest, shown, shownLabel, keyRegistered = nil, false, nil, false
	handle, listing = nil, nil
	reportedMarkers, reportedStrip, reportedMenu = false, false, false
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the server events.
-- @author XEROX710
function Runtime.Start()
	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Use, 'key')
				if not ran then
					Open77.log.error(('[garages] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Reading only the second logged a working mapping as
		-- refused.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[garages] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT),
					tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	-- The strip redraws a rebound key itself; this only re-reads whether the row
	-- should be up at all.
	AddEventHandler(M.KEYBINDS_CHANGED, function()
		if shown and keyLabel() == nil then
			shown = false
		end
		syncPrompt()
	end)

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.spots or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local spot, why = Access.FromWire(listed[index])
			if spot == nil then
				Open77.log.warn('[garages] a point was refused: ' .. tostring(why))
			else
				accepted[spot.key] = spot
			end
		end
		spots = accepted
		-- A full pass, not just the markers: a list that arrives while the player
		-- is standing on a point must put its row up now rather than wait for the
		-- next scan.
		scan()
	end)

	RegisterNetEvent(M.Event.VEHICLES, function(payload)
		if type(payload) ~= 'table' then return end
		if type(payload.error) == 'string' then
			takeDown()
			return say('error', locale(payload.error))
		end
		openList(payload)
	end)

	RegisterNetEvent(M.Event.ANSWER, function(key, ok, failure, plate, action)
		local verdict = {
			spot = type(key) == 'string' and key or nil,
			ok = ok == true,
			error = ok ~= true and tostring(failure or 'garages.refused') or nil,
			plate = plate,
			-- 'brought', 'recalled' or 'stored': which of the key's jobs the server
			-- actually did. Carried rather than guessed at from the toast, because
			-- "a car came out" and "the car was already out and had to be moved"
			-- are different facts about the same marker.
			action = type(action) == 'string' and action or nil,
			source = 'server',
		}
		publish(verdict)
		if not verdict.ok then
			say('error', locale(verdict.error))
		end
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[garages] the point list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('garages:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[garages] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('garages:scan', Access.SCAN_MS, scan)
	-- One pass now, so a point already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, takes the markers and the list down and hands the strip
--- back.
-- @author XEROX710
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	takeDown()
	clearMarkers()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
