--- Client half: the markers, and the one row that names the place.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT. The marker is a light on the floor and the row
-- is a name; neither decides anything, and nothing happens when one is touched.
-- A headquarters DESIGNATES -- it says where the station is, so an operator can
-- place the MaxTac AV pads, the garages and the stores around it and a player
-- can find the door. The moment it does something it is a different module.
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

-- The point list as the server last sent it, and the markers drawn for it.
local spots, markers = {}, {}

-- The point the player is standing on, and what the row is currently saying.
local nearest, shown, shownLabel = nil, false, nil

-- Whether each of the three failures was already logged: a marker that cannot
-- be drawn, a row that cannot be posted and a config that named no usable cap
-- are different problems and a player reading the log wants to know which one
-- they have.
local reportedMarkers, reportedStrip, reportedCap = false, false, false

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

-- Brings the row in line with where the player is standing: on a headquarters,
-- it names the place; anywhere else, it is down. The row carries ONE literal
-- cap and no key, because the prompts contract draws no row without a cap and
-- there is nothing to press at a designation.
local function syncPrompt()
	local cap = Access.KEYCAP
	if cap == nil then
		if nearest ~= nil and not reportedCap then
			reportedCap = true
			Open77.log.warn('[headquarters] KEYCAP is not a usable literal; the name row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	local want = nearest ~= nil and not captured()
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
			keys = { cap },
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
		keycap = Access.KEYCAP,
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
function M.Init()
	spots, markers = {}, {}
	nearest, shown, shownLabel = nil, false, nil
	reportedMarkers, reportedStrip, reportedCap = false, false, false
	scanJob, askJob = nil, nil
end

--- Wires the server's one event and the two loops.
function M.Start()
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
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	M.Init()
end
