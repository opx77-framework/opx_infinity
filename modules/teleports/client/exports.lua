--- The client half's lifecycle and its published contract.
-- @author dop42
--
-- The registry calls `Init`, `Api`, `Start` and `Stop` on the MODULE, and the
-- half that does the work lives in `Runtime`. This file is the only place that
-- knows the two shapes are the same thing: without it the client half is built
-- by nobody, no key is declared and no marker is ever drawn -- and the module
-- still reports as running, which is why it is worth saying out loud. The
-- garages, dealership and clothing modules each lost a session to exactly this.

local M = OPX.Modules.Get('teleports')
local Runtime = M.Runtime
local Result = OPX.Result

--- Answers what this client knows: entrances, markers, the nearest and the key.
-- @author dop42
-- @return Result
local function state()
	return Result.Ok(Runtime.Report())
end

--- Answers the entrance the player is standing on, or a refusal.
-- The label and the lock state only. A caller with no business teleporting
-- anybody has no business reading a destination coordinate either, and the
-- coordinates are not what anything downstream needs.
-- @author dop42
-- @return Result
local function nearest()
	local entrance = Runtime.Nearest()
	if entrance == nil then return Result.Err('teleports.noSuchTeleport') end
	return Result.Ok({ key = entrance.key, leg = entrance.leg, label = entrance.label,
		allowed = entrance.allowed })
end

--- Answers every entrance this client was told about.
-- @author dop42
-- @return Result
local function entrances()
	return Result.Ok({ entrances = Runtime.Entrances() })
end

--- Asks the server to take the teleport underfoot.
-- A caller's name is passed rather than a key: the destination is whatever the
-- player is standing on, which is the server's to decide, and `origin` is only
-- what tells two callers apart on the decision bus.
-- @author dop42
-- @param origin string|nil
-- @return Result
local function use(origin)
	local verdict = Runtime.Use(origin)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'teleports.refused') end
	return Result.Ok(verdict)
end

--- Builds the client state. Never yields.
-- @author dop42
function M.Init()
	Runtime.Init()
end

--- Publishes the client half of the teleports contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('teleports', 1, {
		State = state,
		Nearest = nearest,
		Entrances = entrances,
		Use = use,
	})
end

--- Declares the key and wires the two server events.
-- @author dop42
function M.Start()
	Runtime.Start()
end

--- Cancels the jobs, takes the markers down and hands the strip back.
-- @author dop42
function M.Stop()
	Runtime.Shutdown()
end
