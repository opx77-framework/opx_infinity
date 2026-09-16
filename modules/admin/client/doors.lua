--- Applies the door states staff set to the doors streamed around this player.
-- @author dop42
--
-- Door state is client-side: the server holds what staff asked for, per routing
-- bucket, and every client in that bucket puts its own streamed doors into it.
-- A door that streams in later is caught by the scan, which is also what puts
-- back a lock the game itself lifted.
--
-- The whole file stands down while the official `open77_doors` runs: it owns
-- every door, and two owners would fight over each one every second.

local M = OPX.Modules.Get('admin')

local Client = M.Client

M.Doors = {}
local Doors = M.Doors

-- The three fields a state may carry.
local FIELDS = { 'open', 'locked', 'sealed' }

-- Door id to the state staff set, for this player's bucket, and the full list
-- still arriving.
local known, incoming = {}, {}

-- Doors the last scan found streamed, so one streaming in gets its state once
-- rather than on every pass.
local streamed = {}

-- Metres around the player doors are looked for, and the scheduler handle.
local radius, job = 80, nil

-- `Open77.doors`, or nil on a client without the door natives or while the
-- official service runs.
local function doors()
	local native = Open77.doors
	if type(native) ~= 'table' or type(native.near) ~= 'function'
		or type(native.setOpen) ~= 'function' then
		return nil
	end
	if Client.Running(M.NETWORKED_DOORS) then return nil end
	return native
end

-- A state from the server, kept to its three booleans, or nil.
local function stateOf(value)
	if type(value) ~= 'table' then return nil end
	local state = {}
	for _, field in ipairs(FIELDS) do
		if type(value[field]) == 'boolean' then state[field] = value[field] end
	end
	return state
end

-- The live snapshot of a streamed door, or nil.
local function live(native, id)
	local read, door = pcall(native.state, id)
	if not read or type(door) ~= 'table' or type(door.id) ~= 'string' then return nil end
	return door
end

-- Puts one streamed door into a state. The order matters: a hold is released
-- first, then the door is moved, then the holds are put back -- setting `open` on
-- a door that is still locked does nothing at all.
local function apply(native, door, state)
	local id = door.id
	if state.locked == false then pcall(native.setLocked, id, false, true) end
	if state.sealed == false then pcall(native.setSealed, id, false, true) end
	-- A lift door follows its cabin and must not be driven from here.
	if state.open ~= nil and not door.lift then pcall(native.setOpen, id, state.open, true) end
	if state.locked == true then pcall(native.setLocked, id, true, true) end
	if state.sealed == true then pcall(native.setSealed, id, true, true) end
end

-- Gives a streamed door back to its authored default.
local function release(native, id)
	if live(native, id) then pcall(native.reset, id) end
end

-- One pass: gives each door that streamed in its state, and puts back a lock or
-- a seal the game lifted.
local function scan()
	local native = doors()
	if native == nil or (next(known) == nil and next(streamed) == nil) then return end
	local read, list = pcall(native.near, radius)
	if not read or type(list) ~= 'table' then return end
	local current = {}
	for _, door in ipairs(list) do
		local state = type(door) == 'table' and type(door.id) == 'string' and known[door.id] or nil
		if state then
			current[door.id] = true
			local drifted = (state.locked ~= nil and door.locked ~= state.locked)
				or (state.sealed ~= nil and door.sealed ~= state.sealed)
			if not streamed[door.id] or drifted then apply(native, door, state) end
		end
	end
	streamed = current
end

--- Wires the two door events and registers the scan.
-- @author dop42
function Doors.Start()
	local settings = M.Section('DOORS')
	radius = M.Bounded('DOORS.SCAN_RADIUS', settings.SCAN_RADIUS, 1, 100, 80)
	local everyMs = math.floor(M.Bounded('DOORS.SCAN_MS', settings.SCAN_MS, 100, 60000, 1000))

	RegisterNetEvent(M.Event.DOOR, function(id, value)
		if type(id) ~= 'string' or #id > 18 then return end
		local native = doors()
		if value == false then
			known[id] = nil
			if native then release(native, id) end
			return
		end
		local state = stateOf(value)
		if state == nil then return end
		known[id] = state
		local door = native and live(native, id) or nil
		if door then apply(native, door, state) end
	end)

	RegisterNetEvent(M.Event.DOORS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then incoming = {} end
		for _, row in ipairs(payload.rows) do
			local state = stateOf(row)
			if state and type(row.id) == 'string' and #row.id <= 18 then incoming[row.id] = state end
		end
		if payload.done ~= true then return end
		local previous = known
		known, incoming, streamed = incoming, {}, {}
		local native = doors()
		if native == nil then return end
		-- A door this bucket no longer names goes back to its authored default,
		-- or it would stay locked after the state that locked it was reset.
		for id in pairs(previous) do
			if known[id] == nil then release(native, id) end
		end
	end)

	job = OPX.Scheduler.Every('admin.doors', everyMs, scan)
	TriggerServerEvent(M.Event.DOORS_HELLO)
end

--- Gives every streamed door this module held back to its default.
-- @author dop42
function Doors.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local native = doors()
	if native then
		for id in pairs(known) do release(native, id) end
	end
	known, incoming, streamed = {}, {}, {}
end
