--- The client half of the elevators contract, and its lifecycle.
-- @author dop42
--
-- Every function answers a Result and none of them ever raises: `checked` turns
-- a raise inside one into `internal_error` and a log line naming the function.
--
-- `RequestFloor` and `OpenPanel` answer "asked for": the server's verdict
-- arrives on `M.Event.ON_DECISION` with `source` set to `server`, `panel` or the
-- caller's own name, and a local refusal is published there too.
--
-- This file is last on purpose: publishing the surface asserts it exists.

local M = OPX.Modules.Get('elevators')
local Runtime = M.Runtime
local Panel = M.Panel

local Result = OPX.Result

-- Turns the internal decision shape into a Result, keeping its fields.
local function answered(decision)
	if decision.ok ~= true then
		local out = Result.Err(decision.error or 'refused')
		out.elevator, out.floor, out.reason = decision.elevator, decision.floor, decision.reason
		return out
	end
	decision.ok = nil
	return Result.Ok(decision)
end

-- Wraps a contract function so a raise inside it is a refusal, not a fault in
-- whatever called it.
local function checked(name, fn)
	return function(...)
		local ran, answer = pcall(fn, ...)
		if not ran then
			Open77.log.error(('[elevators] %s raised: %s'):format(name, tostring(answer)))
			return Result.Err('internal_error')
		end
		return answer
	end
end

--- Answers every floor at an elevator with this player's access.
-- @author dop42
-- @param elevator string|nil the nearest one when omitted
-- @return Result
local function floors(elevator)
	return answered(Runtime.Floors(elevator))
end

--- Answers the configured elevator the player is standing at.
-- @author dop42
-- @return Result
local function nearestElevator()
	local key = Runtime.Nearest()
	if key == nil then return Result.Err('no_elevator_nearby') end
	return Result.Ok({ elevator = key, id = Runtime.ElevatorId(key) })
end

--- Answers whether a floor would be allowed, sending nothing.
-- A hint: the server decides again before it moves a cabin.
-- @author dop42
-- @param elevator string|nil
-- @param floor integer
-- @return Result
local function isFloorAllowed(elevator, floor)
	return answered(Runtime.Check(elevator, floor))
end

--- Asks for a floor; the verdict arrives on the decision event.
-- @author dop42
-- @param elevator string|nil
-- @param floor integer
-- @param owner string|nil the caller, recorded as the decision's source
-- @return Result
local function requestFloor(elevator, floor, owner)
	return answered(Runtime.Use(elevator, floor, owner))
end

--- Opens the floor list through the menu contract.
-- @author dop42
-- @param elevator string|nil
-- @return Result
local function openPanel(elevator)
	return answered(Panel.Open(elevator))
end

--- Answers what this client knows: job, snapshot age and lifts in range.
-- @author dop42
-- @return Result
local function state()
	return Result.Ok(Runtime.Report())
end

--- Builds the client state and the panel state.
-- @author dop42
function M.Init()
	Runtime.Init()
	Panel.Init()
end

--- Publishes the client half of the elevators contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('elevators', 1, {
		Floors = checked('Floors', floors),
		NearestElevator = checked('NearestElevator', nearestElevator),
		IsFloorAllowed = checked('IsFloorAllowed', isFloorAllowed),
		RequestFloor = checked('RequestFloor', requestFloor),
		OpenPanel = checked('OpenPanel', openPanel),
		State = checked('State', state),
	})
end

--- Starts the scan, the character poll and the panel channels.
-- @author dop42
function M.Start()
	Runtime.Start()
	Panel.Start()
end

--- Takes the scan and the panel down.
-- @author dop42
function M.Stop()
	Panel.Shutdown()
	Runtime.Shutdown()
end
