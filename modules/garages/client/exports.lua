--- The client half's lifecycle and its published contract.
-- @author XEROX710
--
-- The registry calls `Init`, `Api`, `Start` and `Stop` on the MODULE, and the
-- half that does the work lives in `Runtime`. This file is the only place that
-- knows the two shapes are the same thing: without it the client half is built
-- by nobody, no key is declared and no marker is ever drawn -- and the module
-- still reports as running, which is why it is worth saying out loud.

local M = OPX.Modules.Get('garages')
local Runtime = M.Runtime
local Result = OPX.Result

--- Answers what this client knows: spots, markers, the nearest one and the key.
-- @author XEROX710
-- @return Result
local function state()
	return Result.Ok(Runtime.Report())
end

--- Answers the spot the player is standing on, or a refusal.
-- @author XEROX710
-- @return Result
local function nearest()
	local spot = Runtime.Nearest()
	if spot == nil then return Result.Err('garages.noSuchSpot') end
	return Result.Ok({ key = spot.key, label = spot.label, kind = spot.kind })
end

--- Answers every spot this client was told about, by key.
-- @author XEROX710
-- @return Result
local function spots()
	return Result.Ok({ spots = Runtime.Spots() })
end

--- Brings the player's own vehicle out at the spot underfoot.
-- A caller's name is passed rather than a key: the verdict travels on the local
-- bus, and `origin` is what tells two callers apart.
-- @author XEROX710
-- @param origin string|nil
-- @return Result
local function bring(origin)
	local verdict = Runtime.Use(origin)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'garages.refused') end
	return Result.Ok(verdict)
end

--- Builds the client state. Never yields.
-- @author XEROX710
function M.Init()
	Runtime.Init()
end

--- Publishes the client half of the garages contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('garages', 1, {
		State = state,
		Nearest = nearest,
		Spots = spots,
		Bring = bring,
	})
end

--- Declares the key and wires the three server events.
-- @author XEROX710
function M.Start()
	Runtime.Start()
end

--- Cancels the jobs, takes the markers down and hands the strip back.
-- @author XEROX710
function M.Stop()
	Runtime.Shutdown()
end
