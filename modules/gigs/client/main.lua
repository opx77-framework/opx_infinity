--- Client half: the lifecycle, the three wire handlers and the contract.
-- @author dop42
--
-- Thin, like the server's. The board is `client/board.lua` and the run is
-- `client/run.lua`; this file wires them to the wire and to the two local events
-- that matter -- the character going away, and the player hitting the floor.
--
-- `target` is optional and its absence is not fatal: without the eye there is no
-- way to take a gig from the world, the module says so once, and the server half
-- still answers the list command. Losing a feature is not the same as breaking,
-- and a satellite module that took the runtime down with it would be a worse
-- trade than a missing row.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog
local Board = M.Board
local Run = M.Run

local Result = OPX.Result

-- Wraps a contract function so a raise inside it is a refusal, and not a fault in
-- whatever called it.
local function checked(name, fn)
	return function(...)
		local ran, answer = pcall(fn, ...)
		if not ran then
			Open77.log.error(('[gigs] %s raised: %s'):format(name, tostring(answer)))
			return Result.Err('internal_error')
		end
		return answer
	end
end

--- What this client is standing at, or that it holds no run.
-- @author dop42
-- @return Result
local function state()
	local held = Run.State()
	if held == nil then return Result.Ok({ working = false }) end
	held.working = true
	return Result.Ok(held)
end

--- Asks for a gig by id. The answer says the request went out, never that it was
--- accepted: the verdict arrives as a leg or as a refusal.
-- @author dop42
-- @param gigId string
-- @return Result
local function take(gigId)
	if Catalog.Get(gigId) == nil then return Result.Err('no_such_gig') end
	if not Run.Take(gigId) then return Result.Err('refused') end
	return Result.Ok({ asked = true, gig = gigId })
end

--- Drops the run this client holds.
-- @author dop42
-- @return Result
local function abandon()
	if not Run.Abandon() then return Result.Err('not_working') end
	return Result.Ok({ asked = true })
end

--- Every gig this client knows about, in a stable order. The same reading the
--- board rows are drawn from, and not a list the server sent.
-- @author dop42
-- @return Result
local function list()
	local out = {}
	local gigs = Catalog.List()
	for index = 1, #gigs do
		local gig = gigs[index]
		out[index] = {
			id = gig.id, kind = gig.kind, label = gig.label, description = gig.description,
			icon = gig.icon, steps = gig.steps, minReputation = gig.minReputation,
			x = gig.start.x, y = gig.start.y, z = gig.start.z,
		}
	end
	return Result.Ok({ gigs = out })
end

--- Reads the catalogue and clears both halves of the client state.
-- @author dop42
function M.Init()
	Catalog.Read()
	Run.Init()
	Board.Init()
end

--- Publishes the client half of the gigs contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('gigs', 1, {
		State = checked('State', state),
		Take = checked('Take', take),
		Abandon = checked('Abandon', abandon),
		List = checked('List', list),
		Working = Run.Working,
	})
end

--- Wires the wire, the floor and the character, then draws the board.
-- @author dop42
function M.Start()
	for _, line in ipairs(Catalog.Problems()) do Open77.log.warn('[gigs] config: ' .. line) end

	RegisterNetEvent(M.Event.LEG, function(payload)
		Run.Took(payload)
	end)

	RegisterNetEvent(M.Event.ENDED, function(payload)
		Run.Ended(payload)
	end)

	RegisterNetEvent(M.Event.ANSWER, function(payload)
		if type(payload) ~= 'table' then return end
		Run.Refused(tostring(payload.error), payload.key, tonumber(payload.wait))
	end)

	AddEventHandler(M.DOWNED_CHANGED, function(payload)
		if type(payload) ~= 'table' then return end
		Run.SetDown(payload.down == true)
	end)

	-- A character that goes away takes its run with it. The server has already
	-- forgotten it; this is the screen catching up rather than asking.
	AddEventHandler(M.CHARACTER.UNLOADED, function()
		Run.Ended({ reason = 'stopped', earned = 0 })
	end)

	-- The contract is read now rather than at the moment of use, because a state
	-- event that lands while this is being read is newer than the answer and wins.
	local downed = OPX.Api.Get('downed')
	if downed ~= nil and type(downed.IsDown) == 'function' then
		local read, answer = pcall(downed.IsDown)
		if read and type(answer) == 'table' and answer.ok == true and type(answer.value) == 'table' then
			Run.SetDown(answer.value.down == true)
		end
	end

	Board.Start()

	Open77.log.info(('[gigs] ready: %d gig(s) on the board'):format(#Catalog.List()))
end

--- Takes every row, mappin and animation this module put up back down.
-- @author dop42
function M.Stop()
	Run.Shutdown()
	Board.Shutdown()
end
