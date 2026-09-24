--- The client half's lifecycle and its published contract.
-- @author XEROX710
--
-- The registry calls `Init`, `Api`, `Start` and `Stop` on the MODULE, and the
-- half that does the work lives in `Runtime`. This file is the only place that
-- knows the two shapes are the same thing: without it the client half is built
-- by nobody, no key is declared and no marker is ever drawn -- and the module
-- still reports as running, which is why it is worth saying out loud.

local M = OPX.Modules.Get('jobs')
local Runtime = M.Runtime
local Result = OPX.Result

--- Answers what this client knows: boards, markers, the board underfoot, the
--- key, the open list and its screen.
-- @author XEROX710
-- @return Result
local function state()
	return Result.Ok(Runtime.Report())
end

--- Answers the board the player is standing on, or a refusal.
-- @author XEROX710
-- @return Result
local function nearest()
	local board = Runtime.Nearest()
	if board == nil then return Result.Err('jobs.noSuchBoard') end
	return Result.Ok({ key = board.key, label = board.label, kind = board.kind, job = board.job })
end

--- Answers every board this client was told about, by key.
-- @author XEROX710
-- @return Result
local function boards()
	return Result.Ok({ boards = Runtime.Boards() })
end

--- Answers what the server said about one board for this player.
-- @author XEROX710
-- @param key string
-- @return Result
local function boardState(key)
	local answer = Runtime.State(key)
	if answer == nil then return Result.Err('jobs.noSuchBoard') end
	return Result.Ok(answer)
end

--- Answers a desk's roster, or a refusal when this player may not manage it.
-- @author XEROX710
-- @param job string
-- @return Result
local function roster(job)
	local answer = Runtime.Roster(job)
	if answer == nil then return Result.Err('jobs.rosterFailed', tostring(job)) end
	return Result.Ok(answer)
end

--- Opens the list for the board underfoot, or closes the one this file opened.
-- A caller's name is passed rather than a key: the verdict travels on the local
-- bus, and `origin` is what tells two callers apart.
-- @author XEROX710
-- @param origin string|nil
-- @return Result
local function open(origin)
	local verdict = Runtime.Open(origin)
	if verdict.ok ~= true then return Result.Err(verdict.error or 'jobs.refused') end
	return Result.Ok(verdict)
end

--- Closes the list this file opened, if it is up.
-- @author XEROX710
-- @return Result
local function close()
	local verdict = Runtime.Close()
	if verdict.ok ~= true then return Result.Err(verdict.error or 'jobs.noList') end
	return Result.Ok(true)
end

--- Whether the list this file opened is up.
-- @author XEROX710
-- @return boolean
local function isOpen()
	return Runtime.IsOpen()
end

--- Builds the client state. Never yields.
-- @author XEROX710
function M.Init()
	Runtime.Init()
end

--- Publishes the client half of the jobs contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('jobs', 1, {
		State = state,
		Nearest = nearest,
		Boards = boards,
		BoardState = boardState,
		Roster = roster,
		Open = open,
		Close = close,
		IsOpen = isOpen,
	})
end

--- Declares the key and wires the five server events.
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
