--- Client half: the markers, the strip row and the key that opens the fitting room.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT. The nearest store and the radius decide only
-- which door this player is offered; what the door opens is the appearance
-- module's room, and every rule about who may be in it -- a loaded character, a
-- puppet that is not down, no other surface holding the body -- is that module's
-- own refusal, which arrives here as an answer and is said out loud.
--
-- The stores come from the server and never from `config/clothing.lua` directly:
-- captured stores live in the database, and the server filters the list to this
-- player's own routing bucket. A client that read the config alone would draw no
-- captured marker at all, and would draw one in a bucket it is not in.
--
-- Markers are engine primitives, so nothing is redrawn per frame: one is created
-- when a store comes into range and removed when it leaves, and `reconcile` is
-- the only thing that touches that set. Creation is guarded -- the
-- `world.markers` API may not be installed at all, and a raise here would take
-- the scan down with it.

local M = OPX.Modules.Get('clothing')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'clothing'
local GROUP = 'store'

-- The store list as the server last sent it, and the markers drawn for it.
local spots = {}
local markers = {}

-- The store the player is standing on, and whether its row is up.
local nearest, shown = nil, false

-- Whether the key mapping answered.
local keyRegistered = false

-- Whether each of the two failures was already logged: a marker that cannot be
-- drawn and a row that cannot be posted are different problems and a player
-- reading the log wants to know which one they have.
local reportedMarkers, reportedStrip = false, false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.clothing.use', NAME = 'clothing.key.use', DEFAULT = 'E' }
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

-- ── the markers ─────────────────────────────────────────────────────────────

-- Creates one marker, or answers why it could not be. Never raises.
local function createMarker(store)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = Access.Marker()
	local read, id, reason = pcall(api.create, {
		-- The store's declared height plus the look's own lift: a marker left at
		-- floor height is co-planar with the floor and draws nothing at all.
		position = { x = store.x, y = store.y, z = store.z + look.lift },
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

-- Brings the drawn set in line with what is in range: a store within
-- MAX_DISTANCE has a marker, one beyond it does not. Touches nothing when the
-- set would not change.
--
-- THE POSITION IS THREADED THROUGH, NOT READ AGAIN. `scan()` -- the only caller
-- -- has just read it for `Access.Nearest`, and reading it a second time here
-- made this module cost TWO host position reads per pass at SCAN_MS. Across
-- `clothing`, `dealership` and `garages` that was twelve host reads a second for
-- six distinct answers. `modules/teleports/client/main.lua` already threads it
-- (`reconcile(at)`); these three were never updated with it.
-- @param x number|nil the player's position, or nil where it could not be read
-- @param y number|nil
local function reconcile(x, y)
	local limit = Access.MaxDistance()
	local reach = limit * limit

	for key, store in pairs(spots) do
		local flat = nil
		if x ~= nil then flat = Access.FlatDistanceSquared(store, x, y) end
		local wanted = flat ~= nil and flat <= reach
		if wanted and markers[key] == nil then
			local id, failure = createMarker(store)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[clothing] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end

	-- A store the server no longer names loses its marker here rather than being
	-- left behind: it may have been removed while it was in range.
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

-- Brings the strip in line with where the player is standing.
local function syncPrompt()
	local want = nearest ~= nil and keyLabel() ~= nil and not captured()
	if want == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the room, and this is
		-- said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[clothing] no prompts contract; the strip row is not shown')
		end
		shown = false
		return
	end

	shown = want
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line.
			label = locale('clothing.prompt'),
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
		Open77.log.warn('[clothing] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Every verdict shares the one id, so the last thing said replaces the
-- one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.clothing.answer',
		kind = kind,
		title = locale('clothing.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[clothing] ' .. tostring(message)) end
end

-- ── the door ────────────────────────────────────────────────────────────────

--- Opens the fitting room at the store the player is standing on.
-- Every refusal here is local and changes nothing: the appearance module decides
-- again, and its own refusal is what a player is told when it has one.
-- @author XEROX710
-- @param origin string|nil the key or a caller's name
-- @return table
function Runtime.Open(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end
	if nearest == nil then
		result.ok, result.error = false, 'clothing.noSuchStore'
		publish(result)
		return result
	end
	result.store = nearest.key

	-- TOLD TO THE SERVER BEFORE THE ROOM GOES UP, and never waited on. The room
	-- itself is a local decision and stays one -- every reason it may not open is
	-- knowable here and nowhere else -- but the SAVE that comes out of it is not:
	-- `appearance` refuses a clothing write that no server-side door opened, and
	-- this is that door being reported. The server measures the distance to the
	-- store again for itself and ignores this entirely if the player is not at
	-- one, so a client that fires it from the other side of the city gets a room
	-- it cannot save anything out of.
	TriggerServerEvent(M.Event.OPEN)

	local api = OPX.Api.Get('appearance')
	if type(api) ~= 'table' or type(api.OpenWardrobe) ~= 'function' then
		-- Named rather than silent, and named as the missing CONTRACT: the
		-- markers drew, the row posted and the key was pressed, so "nothing
		-- happened" is the one answer that would leave a player guessing.
		result.ok, result.error = false, 'clothing.noWardrobe'
	else
		local ran, answer = pcall(api.OpenWardrobe, M.WARDROBE_OWNER)
		if not ran then
			Open77.log.error('[clothing] the fitting room raised: ' .. tostring(answer))
			result.ok, result.reason, result.error = false, 'call_failed', 'clothing.wardrobeRefused'
		elseif type(answer) ~= 'table' or answer.ok ~= true then
			local reason = type(answer) == 'table' and tostring(answer.error or 'refused')
				or 'malformed_answer'
			result.ok, result.reason, result.error = false, reason, 'clothing.wardrobeRefused'
		else
			result.ok = true
			result.citizenId = type(answer.value) == 'table' and answer.value.citizenId or nil
		end
	end

	publish(result)
	if not result.ok then
		say('error', locale(result.error, { reason = result.reason or result.error }))
	end
	return result
end

--- The store the player is standing on, or nil.
-- @author XEROX710
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every store this client was told about, by key.
-- @author XEROX710
-- @return table
function Runtime.Spots()
	return spots
end

--- What this client knows, for a diagnostic or a test.
-- @author XEROX710
-- @return table
function Runtime.Report()
	local count = OPX.Table.Count(spots)
	local drawn = OPX.Table.Count(markers)
	return {
		spots = count,
		markers = drawn,
		nearest = nearest and nearest.key or nil,
		shown = shown,
		key = keyLabel(),
	}
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- One pass: where the player is, which store they are on, and what is drawn.
-- A pass with no stores at all still reconciles, so a list that was cleared
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
	nearest, shown, keyRegistered = nil, false, false
	reportedMarkers, reportedStrip = false, false
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the one server event.
-- @author XEROX710
function Runtime.Start()
	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Open, 'key')
				if not ran then
					Open77.log.error(('[clothing] key %s: %s'):format(declared.ID, tostring(failure)))
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
			Open77.log.warn(('[clothing] key mapping %s (%s) not registered: %s')
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
			local store, why = Access.FromWire(listed[index])
			if store == nil then
				Open77.log.warn('[clothing] a store was refused: ' .. tostring(why))
			else
				accepted[store.key] = store
			end
		end
		spots = accepted
		-- A full pass, not just the markers: a list that arrives while the
		-- player is standing on a store must put its row up now rather than
		-- wait for the next scan.
		scan()
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[clothing] the store list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('clothing:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[clothing] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('clothing:scan', Access.SCAN_MS, scan)
	-- One pass now, so a store already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, takes the markers down and hands the strip back.
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
	clearMarkers()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
