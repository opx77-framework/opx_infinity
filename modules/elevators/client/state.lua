--- Client state: the job snapshot, lifts in range and bound ids.
-- @author dop42

local M = OPX.Modules.Get('elevators')
local Access = M.Access

M.State = {}
local State = M.State

-- How long a sighting is believed: two scans, so a missed pass does not close a
-- panel.
local STALE_MS = Access.SCAN_MS * 2

--- The character's job snapshot, or nil before the character contract answers.
State.snapshot = nil

--- Elevator key to the id the server bound.
State.bound = {}

--- Elevator key to what the last scan saw of its lift.
State.seen = {}

--- Keeps the job fields of a character's PlayerData, stamped now.
-- @author dop42
-- @param playerData table|nil
-- @param nowMs integer
function State.Adopt(playerData, nowMs)
	if type(playerData) ~= 'table' then return end
	State.snapshot = {
		job = type(playerData.job) == 'table' and playerData.job or nil,
		jobs = type(playerData.jobs) == 'table' and playerData.jobs or nil,
		atMs = nowMs,
	}
end

--- Drops the snapshot once there is no character.
-- @author dop42
function State.Forget()
	State.snapshot = nil
end

--- Records what one scan saw of a configured lift.
-- @author dop42
-- @param key string
-- @param lift table
-- @param nowMs integer
-- @param playerX number|nil
-- @param playerY number|nil
function State.Sighted(key, lift, nowMs, playerX, playerY)
	local flat = nil
	if type(playerX) == 'number' and type(playerY) == 'number' then
		flat = Access.FlatDistanceSquared(key, playerX, playerY)
	end
	State.seen[key] = {
		reach = flat ~= nil and math.sqrt(flat) or nil,
		distance = lift.distance,
		id = lift.id,
		managed = lift.managed == true,
		atMs = nowMs,
	}
end

-- Whether a sighting is recent enough to answer with.
local function current(lift, nowMs)
	return type(lift.atMs) == 'number' and nowMs - lift.atMs <= STALE_MS
end

--- Answers the nearest sighted elevator within USE_RADIUS, or nil.
-- At equal distance the key decides, exactly as `Access.Locate` does, so `pairs`
-- order never chooses between two shafts of one lobby.
-- @author dop42
-- @param nowMs integer
-- @return string|nil
function State.Nearest(nowMs)
	local bestKey, bestDistance
	for key, lift in pairs(State.seen) do
		local reach = lift.reach or lift.distance
		if current(lift, nowMs) and type(reach) == 'number' and
			reach <= Access.USE_RADIUS and (bestDistance == nil or reach < bestDistance or
			(reach == bestDistance and key < bestKey)) then
			bestKey, bestDistance = key, reach
		end
	end
	return bestKey
end

--- Summarises what this client knows, for the State contract function.
-- `seen` keeps a lift the player has walked away from, so only the current ones
-- are counted here.
-- @author dop42
-- @param nowMs integer
-- @return table
function State.Report(nowMs)
	local seen = 0
	for _, lift in pairs(State.seen) do
		if current(lift, nowMs) then seen = seen + 1 end
	end
	-- The lifts are counted by hand above because only the CURRENT ones
	-- count; the bindings are a plain size and the library says so.
	local bound = OPX.Table.Count(State.bound)
	local snapshot = State.snapshot
	return {
		job = snapshot and snapshot.job and snapshot.job.name or nil,
		grade = snapshot and snapshot.job and snapshot.job.grade
			and snapshot.job.grade.level or nil,
		onDuty = snapshot and snapshot.job and snapshot.job.onDuty == true or false,
		fresh = snapshot ~= nil and (nowMs - snapshot.atMs) <= Access.JOB_MAX_AGE_MS,
		ageMs = snapshot and (nowMs - snapshot.atMs) or nil,
		seen = seen,
		bound = bound,
		nearest = State.Nearest(nowMs),
	}
end

--- Clears everything this client knows.
-- @author dop42
function State.Reset()
	State.snapshot = nil
	State.bound = {}
	State.seen = {}
end
