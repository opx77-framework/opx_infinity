--- Staff door states, per routing bucket, held in memory only.
-- @author dop42
--
-- WHY THIS EXISTS AT ALL. The official `open77_doors` owns every door on a server
-- where it runs, and this file stands down the moment it does -- one
-- `GetResourceState` before anything is written. But `open77_doors` depends on
-- `open77_elevators`, which adopts the same cabins as this runtime's `elevators`
-- module and refuses one already adopted by anything else, so an operator who
-- takes the official door service gives up job-gated lifts. This is the staff
-- door switch for the operators who keep the lifts.
--
-- It is deliberately small, and an operator should know exactly what it is not:
-- states live in memory, are gone at a restart, are bounded per bucket, and only
-- reach the doors streamed around a client. There is no authored door data, no
-- persistence and no per-job lock. A state is applied by every client in the
-- bucket rather than by the server, because door state is client-side.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local count = Server.Count

M.Doors = {}
local Doors = M.Doors

-- Rows per full state list event. The host discards an event carrying more than
-- 1024 value nodes and says nothing.
local CHUNK = 40

-- The fields each action writes over a door's state. `lock` and `seal` also
-- close: a door held shut that is drawn open is worse than either.
local ACTIONS = {
	open = { open = true },
	close = { open = false },
	lock = { locked = true, open = false },
	unlock = { locked = false },
	seal = { sealed = true, open = false },
	unseal = { sealed = false },
}

-- Bucket to door id to the state staff set, and the bucket each player was last
-- sent a full list for.
local states, sentBucket = {}, {}

-- Whether the official door service is running, in which case nothing here does.
local function networked()
	local read, state = pcall(GetResourceState, M.NETWORKED_DOORS)
	return read and state == 'running'
end

-- A typed door id in its canonical 0x spelling, or nil.
local function doorId(token)
	if type(token) ~= 'string' then return nil end
	local digits = token:match('^0[xX](%x+)$')
	if digits == nil or #digits > 16 or digits:match('^0+$') then return nil end
	return '0x' .. digits:upper()
end

-- Every staff door state of one bucket, as rows.
local function rowsOf(bucket)
	local rows = {}
	for id, state in pairs(states[bucket] or {}) do
		rows[#rows + 1] = { id = id, open = state.open, locked = state.locked, sealed = state.sealed }
	end
	return rows
end

-- Sends one player every door state of their bucket, in chunks.
local function pushAll(playerId, bucket)
	local rows = rowsOf(bucket)
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + CHUNK, #rows) do chunk[#chunk + 1] = rows[index] end
		TriggerClientEvent(M.Event.DOORS, playerId, { rows = chunk, offset = offset,
			done = offset + #chunk >= #rows })
		offset = offset + #chunk
	until offset >= #rows
	sentBucket[playerId] = bucket
end

-- Sends one door's state, or its reset, to every player in the bucket.
local function pushOne(bucket, id, state)
	for _, playerId in ipairs(Server.PlayerIds()) do
		local position = Server.PositionOf(playerId)
		if position and position.bucket == bucket then
			TriggerClientEvent(M.Event.DOOR, playerId, id, state or false)
		end
	end
end

--- Registers the door command and the bucket sweep.
-- @author dop42
function Doors.Register()
	Server.Command(Command.WORLD_DOOR, {
		help = 'admin.help.door',
		params = { { name = 'doorId', help = 'admin.help.doorId' },
			{ name = 'open|close|lock|unlock|seal|unseal|reset', help = 'admin.help.doorAction' } },
		inGame = true,
		handler = function(source, args, raw)
			local action = type(args[2]) == 'string' and args[2]:lower() or nil
			if count(args) ~= 2 or (action ~= 'reset' and ACTIONS[action] == nil) then
				return answer(source, raw, false, 'admin.usage.door')
			end
			local id = doorId(args[1])
			if id == nil then return refuse(source, raw, 'bad_door') end
			if networked() then return refuse(source, raw, 'doors_networked') end
			local position = Server.PositionOf(source)
			if position == nil then return refuse(source, raw, 'no_position') end

			local limit = math.floor(M.Bounded('DOORS.MAX_PER_BUCKET',
				M.Section('DOORS').MAX_PER_BUCKET, 1, 4096, 256))
			local bucket = states[position.bucket] or {}
			local door = bucket[id]
			if action == 'reset' then
				door = nil
			else
				if door == nil then
					local held = OPX.Table.Count(bucket)
					if held >= limit then return refuse(source, raw, 'door_limit', { max = limit }) end
					door = {}
				end
				for field, value in pairs(ACTIONS[action]) do door[field] = value end
			end
			bucket[id] = door
			-- An empty bucket is dropped rather than kept as an empty table: the
			-- sweep walks every bucket that has one.
			states[position.bucket] = next(bucket) ~= nil and bucket or nil
			pushOne(position.bucket, id, door)
			audit(source, 'admin.world.door', true, nil,
				('%s %s bucket %d'):format(id, action, position.bucket))
			answer(source, raw, true, 'admin.done.door',
				{ door = id, action = locale('admin.door.' .. action) })
		end,
	})

	-- A client half started: its full list goes out on the next sweep.
	RegisterNetEvent(M.Event.DOORS_HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 or Server.Cooled(player, 'doors:hello', 2000) then return end
		sentBucket[player] = nil
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		sentBucket[tonumber(playerId) or 0] = nil
	end)

	if networked() then
		Open77.log.info(('[admin] %s is running and owns every door: %s stands down')
			:format(M.NETWORKED_DOORS, Command.WORLD_DOOR))
		return
	end

	-- A player who moves between buckets has to be given that bucket's list, and
	-- there is no host event for a bucket change, so this is a poll.
	local sweepMs = math.floor(M.Bounded('DOORS.SWEEP_MS', M.Section('DOORS').SWEEP_MS,
		250, 60000, 2000))
	OPX.Scheduler.Every('admin:door-sweep', sweepMs, function()
		for _, playerId in ipairs(Server.PlayerIds()) do
			local position = Server.PositionOf(playerId)
			if position and sentBucket[playerId] ~= position.bucket then
				pushAll(playerId, position.bucket)
			end
		end
	end)
end

--- Resets every door this module held, so a stop gives them back.
-- @author dop42
function Doors.Release()
	for bucket, held in pairs(states) do
		for id in pairs(held) do pcall(pushOne, bucket, id, false) end
	end
	states, sentBucket = {}, {}
end
