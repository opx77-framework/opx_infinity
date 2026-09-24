--- The clinic's client half: the marker at the chair, the press, and the state
-- behind the page. It decides nothing -- every frame it draws was decided
-- server-side.
-- @author XEROX710
--
-- NO KEY OPENS THE MENU. The one binding is the interaction key (press E at the
-- chair, the convention `modules/garages`, `modules/dealership` and
-- `modules/clothing` all share), and the menu itself appears the moment the
-- server says the patient is seated -- an auto-open, which is what the request
-- asked for.
--
-- The markers draw from config and gate themselves: `maxDistance` is the
-- native's own, so there is no scan loop deciding visibility and no poll cost
-- beside it. The prompt row DOES poll, at half a second, because it states
-- where the player stands -- one position read every 500 ms, the same budget
-- `modules/clothing/client/main.lua` settled on.

local M = OPX.Modules.Get('ripperdoc')
local Event = M.Event

-- What the prompts contract records as this module's own.
local OWNER = 'ripperdoc'
local GROUP = 'clinic'

-- The markers drawn for the chairs, and the chair the player is standing on.
local markers = {}
local nearest, shown = nil, false

-- Whether the key mapping answered.
local keyRegistered = false

-- Whether each failure was already logged: a marker that cannot be drawn and a
-- row that cannot be posted are different problems.
local reportedMarkers, reportedStrip = false, false

-- The scan thread's run flag, so Stop can end it.
local running = false

--- The key declaration, with the shipped value as the fallback so a config that
-- lost its KEY block still names a key.
-- @return table
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or M.Ripper.KEY
end

--- The player's own position, or nil before there is a world to read. THREE
-- NUMBERS, not a table -- `Open77.character.position()`'s own shape.
-- @return number|nil, number|nil, number|nil
local function playerXYZ()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil, nil
	end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number'
		or x ~= x or y ~= y then
		return nil, nil, nil
	end
	return x, y, z
end

--- Whether another surface holds the keyboard (the same guard `modules/clothing`
-- uses: a press while typing belongs to whatever is being typed into).
-- @return boolean
--- The player's own facing in degrees, or nil. Read only when a capture is
--- asked for, because that is the only time it is used.
-- @return number|nil
local function playerYaw()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.yaw) ~= 'function' then return nil end
	local read, yaw = pcall(character.yaw)
	if not read or type(yaw) ~= 'number' or yaw ~= yaw then return nil end
	return yaw
end

local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- The key the player's own binding answers to, or nil when it is off.
-- @return string|nil
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	local lib = OPX.Lib
	if type(lib) == 'table' and type(lib.Input) == 'table' and type(lib.Input.KeyFor) == 'function' then
		local read, bound = pcall(lib.Input.KeyFor, declared.ID)
		if read and type(bound) == 'string' and bound ~= '' then return bound end
	end
	return declared.DEFAULT
end

--- Creates one marker, or answers why it could not. Never raises.
-- @param chair table
-- @return any|nil marker id
-- @return string|nil why
local function createMarker(chair)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = M.Ripper.Marker()
	local read, id, reason = pcall(api.create, {
		-- The chair's own height plus the look's lift: a marker left at floor
		-- height is co-planar with the floor and draws nothing at all.
		position = { x = chair.X, y = chair.Y, z = (chair.Z or 0) + (look.LIFT or 0) },
		shape = look.shape,
		style = look.style,
		radius = look.RADIUS,
		maxDistance = M.Ripper.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

--- Removes one marker without raising.
-- @param id any
local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

--- Brings the drawn set in line with what is in range: a chair within
--- MAX_DISTANCE has a marker, one beyond it does not. Touches nothing when the
--- set would not change -- the shape `modules/clothing/client/main.lua` keeps,
--- and for its reason too: `markers.list()` is read as the set that SHOULD
--- exist, so a chair across the city must not sit in it. `maxDistance` hides a
--- marker from players; only this bookkeeping keeps it out of the list.
-- @param inRange table chair id -> true
local function syncMarkers(inRange)
	for chairId, id in pairs(markers) do
		if not inRange[chairId] then
			removeMarker(id)
			markers[chairId] = nil
		end
	end
	for chairId in pairs(inRange) do
		if markers[chairId] == nil then
			local id, why = createMarker(M.Ripper.Chair(chairId))
			if id ~= nil then
				markers[chairId] = id
			elseif not reportedMarkers then
				reportedMarkers = true
				Open77.log.warn('[ripperdoc] the chair marker could not be drawn: ' .. tostring(why))
			end
		end
	end
end

--- The chair the player is standing on, if any -- and where the prompt row is.
local function scan()
	local x, y, z = playerXYZ()
	if x == nil then
		nearest = nil
		syncMarkers({})
		return
	end
	local reach = M.Ripper.Reach()
	local maxDistance = M.Ripper.MaxDistance()
	local best, bestAt = nil, reach * reach
	local inRange = {}
	for _, chair in ipairs(M.Ripper.Chairs()) do
		local dx = x - (chair.X or 0)
		local dy = y - (chair.Y or 0)
		local dz = (z or 0) - (chair.Z or 0)
		local at = dx * dx + dy * dy + dz * dz
		if at <= bestAt then
			best, bestAt = chair, at
		end
		if at <= maxDistance * maxDistance then
			inRange[chair.id] = true
		end
	end
	nearest = best
	syncMarkers(inRange)
end

--- Brings the prompt row in line with where the player is standing.
local function syncPrompt()
	local want = nearest ~= nil and keyLabel() ~= nil and not captured()
	if want == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the clinic, and this
		-- is said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[ripperdoc] no prompts contract; the strip row is not shown')
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
			label = locale('ripperdoc.prompt'),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	if not ran then
		shown = false
		Open77.log.warn('[ripperdoc] the strip row did not post: ' .. tostring(answer))
	end
end

--- The press. The server routes it (sit or attend) -- this half only says WHICH
-- chair was pressed.
local function press()
	if captured() then return end
	scan()
	if nearest == nil then return end
	TriggerServerEvent(M.Event.USE, nearest.id)
end

--- Turns the page's five intents into server events. The page decides nothing:
-- an offer names its entry and grade, an answer names what it answers, and the
-- server re-derives all of it.
-- @param verb string
-- @param payload table
function M.Ripper.FromView(verb, payload)
	payload = type(payload) == 'table' and payload or {}
	if verb == 'offer' then
		TriggerServerEvent(M.Event.OFFER,
			tostring(payload.entry or ''), tostring(payload.grade or ''), tostring(payload.mode or 'install'))
	elseif verb == 'answer' then
		TriggerServerEvent(M.Event.ANSWER, tostring(payload.what or ''), payload.accept == true)
	elseif verb == 'invite' then
		TriggerServerEvent(M.Event.INVITE, tonumber(payload.player) or payload.player)
	elseif verb == 'stand' then
		TriggerServerEvent(M.Event.STAND)
	elseif verb == 'close' then
		TriggerServerEvent(M.Event.CLOSE)
	end
end

--- Clears every marker and the row (Init and Stop both land here).
local function clear()
	for chairId, id in pairs(markers) do
		removeMarker(id)
		markers[chairId] = nil
	end
	nearest, shown = nil, false
end

--- Resets the surface (Init and a reload both start clean).
function M.Init()
	running = false
	keyRegistered = false
	reportedMarkers, reportedStrip = false, false
	markers = {}
	nearest, shown = nil, false
end

--- Draws the chairs, declares the key, and wires the frame door.
function M.Start()
	-- The markers come from the scan below, which draws only chairs in range
	-- (see `syncMarkers`).

	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				local ran, failure = pcall(press)
				if not ran then
					Open77.log.error(('[ripperdoc] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective
		-- key, or `true, key`.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		keyRegistered = called and (ok == true or effective ~= nil)
		if not keyRegistered then
			Open77.log.warn('[ripperdoc] the key mapping was refused; the chair answers the press only')
		end
	end

	-- The frame door, before anything can arrive on it.
	RegisterNetEvent(M.Event.FRAME, function(payload)
		if type(payload) ~= 'table' then return end
		TriggerEvent(M.Event.VIEW, payload)
	end)

	-- THE CAPTURE ROUND-TRIP. A command on the server cannot know a facing, so
	-- it asks this client for one: the answer carries the heading and nothing
	-- else this half decides.
	RegisterNetEvent(M.Event.CAPTURE, function(key, label)
		local yaw = playerYaw()
		local accepted, reason = TriggerServerEvent(M.Event.CAPTURED, key, label, yaw)
		if not accepted then
			Open77.log.warn(('[ripperdoc] the capture of %s was not answered: %s')
				:format(tostring(key), tostring(reason)))
			return
		end
		Open77.log.info(('[ripperdoc] answered the capture of %s yaw=%s')
			:format(tostring(key), tostring(yaw)))
	end)

	-- The captured chairs, merged into the list the scan draws from. Asked for
	-- once at start so the first scan has them, and re-sent by the server after
	-- every capture or removal.
	RegisterNetEvent(M.Event.CHAIRS, function(rows)
		local accepted = M.Ripper.SetCaptured(rows)
		Open77.log.info(('[ripperdoc] %d captured chair(s) received'):format(accepted))
		scan()
	end)
	TriggerServerEvent(M.Event.ASK)

	-- The page's intents come through the view seam into `FromView`.
	M.RipperView.Start()

	-- The scan: one position read per pass, at clothing's own half-second.
	running = true
	CreateThread(function()
		while running do
			local ran, failure = pcall(function()
				scan()
				syncPrompt()
			end)
			if not ran then
				Open77.log.warn('[ripperdoc] the scan raised: ' .. tostring(failure))
			end
			Wait(500)
		end
	end)
end

--- Takes the surface down with the module.
function M.Stop()
	running = false
	M.RipperView.Stop()
	local api = OPX.Api.Get('prompts')
	if api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	clear()
end
