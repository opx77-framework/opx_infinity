--- The client half's lifecycle and its published contract.
-- @author XEROX710
--
-- The registry calls `Init`, `Api`, `Start` and `Stop` on the MODULE, and the
-- half that does the work lives in `Runtime`. This file is the only place that
-- knows the two shapes are the same thing: without it the client half is built
-- by nobody, no key is declared and no marker is ever drawn -- and the module
-- still reports as running, which is why it is worth saying out loud.

local M = OPX.Modules.Get('dealership')
local Runtime = M.Runtime
local Result = OPX.Result

--- Answers what this client knows: dealers, markers, the nearest one, the key,
--- the open list and its screen.
-- @author XEROX710
-- @return Result
local function state()
	return Result.Ok(Runtime.Report())
end

--- Answers the dealer the player is standing on, or a refusal.
-- @author XEROX710
-- @return Result
local function nearest()
	local spot = Runtime.Nearest()
	if spot == nil then return Result.Err('dealership.noSuchSpot') end
	return Result.Ok({ key = spot.key, label = spot.label, kind = spot.kind })
end

--- Answers every dealer this client was told about, by key.
-- @author XEROX710
-- @return Result
local function spots()
	return Result.Ok({ spots = Runtime.Spots() })
end

--- Opens the list for the dealer underfoot, or closes the one this file opened.
-- A caller's name is passed rather than a key: the verdict travels on the local
-- bus, and `origin` is what tells two callers apart.
-- @author XEROX710
-- @param origin string|nil
-- @return Result
local function open(origin)
	local verdict = Runtime.Open(origin)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'dealership.refused') end
	return Result.Ok(verdict)
end

--- Closes the list this file opened, if it is up.
-- @author XEROX710
-- @return Result
local function close()
	local verdict = Runtime.Close()
	if verdict.ok ~= true then return Result.Err(verdict.error or 'dealership.notOpen') end
	return Result.Ok(true)
end

--- Whether the list this file opened is up.
-- @author XEROX710
-- @return boolean
local function isOpen()
	return Runtime.IsOpen()
end

--- Places a showroom car where this client is standing, facing where it looks.
-- @author XEROX710
--
-- PUBLISHED FOR THE STAFF MENU, which is the placement menu the operator uses.
-- Publishing it grants nothing: this half only asks, and the server refuses
-- anybody who does not hold `PLACEMENT_RIGHT`. A contract call from a client is
-- no permission check at all, which is why the check is not here.
-- @param key string
-- @param entryKey string
-- @return Result
local function place(key, entryKey)
	local verdict = Runtime.Place(key, entryKey)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'dealership.placeFailed') end
	return Result.Ok(verdict)
end

--- Takes one showroom car away by its key, on the same terms.
-- @author XEROX710
-- @param key string
-- @return Result
local function unplace(key)
	local verdict = Runtime.Unplace(key)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'dealership.placeFailed') end
	return Result.Ok(verdict)
end

--- Answers the offer this player is deciding about, or a refusal.
-- @author XEROX710
-- @param yes boolean
-- @return Result
local function decide(yes)
	local verdict = Runtime.Decide(yes == true)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'dealership.noOffer') end
	return Result.Ok(verdict)
end

--- Builds the client state. Never yields.
-- @author XEROX710
function M.Init()
	Runtime.Init()
end

--- Publishes the client half of the dealership contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('dealership', 1, {
		State = state,
		Nearest = nearest,
		Spots = spots,
		Open = open,
		Close = close,
		IsOpen = isOpen,
		Place = place,
		Unplace = unplace,
		Decide = decide,
	})
end

--- Declares the key and wires the four server events.
-- @author XEROX710
function M.Start()
	Runtime.Start()
end

--- Cancels the jobs, closes the list, takes the markers down and hands the strip
--- back.
-- @author XEROX710
function M.Stop()
	Runtime.Shutdown()
end
