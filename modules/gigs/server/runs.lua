--- The runs in flight: build one, hand out its legs, check every claim, pay.
-- @author dop42
--
-- THE SERVER HOLDS THE ROUTE AND THE CLIENT HOLDS ONE LEG. A run is built here
-- the moment it is taken, kept here, and the client is told the leg it is
-- standing at and nothing else -- not the next point, not the pool it came from,
-- not what the run pays. That is not secrecy for its own sake: a client holding
-- the whole route could walk it without an eye, without an animation and without
-- waiting, and nothing but a number it also holds would be in the way.
--
-- FOUR THINGS ARE RE-DERIVED ON EVERY CLAIM, and none is taken from the payload:
--
--   1. WHICH LEG. The claim names an index and it must be the index this server
--      last handed out. A replayed packet names the leg before it and is refused.
--   2. WHERE THEY ARE. `Open77.players.position` is the server's own snapshot.
--      A grace metre is added to the gig's reach, because that snapshot and the
--      body the player sees are never the same tick.
--   3. WHICH BUCKET. The gig's, and never the player's: a gig in bucket 0 is not
--      worked from an instance of it.
--   4. HOW LONG. The leg carries the pace the action is drawn at and the claim is
--      refused until that long has passed since the leg was HANDED OUT. It is a
--      floor on the whole leg, travel included, which is why it is generous
--      rather than exact: it exists to make an instant claim impossible, not to
--      time an animation nobody here can see.
--
-- WHEN THE MONEY MOVES. Each paying leg pays as it lands, and the bonus waits for
-- the end. Someone who collects every bag and never walks to the compactor keeps
-- the legs and loses the bonus, which is the trade an operator can tune with the
-- two bands. Paying it all at the end reads better on paper and worse to a player
-- who has been here twenty minutes, and this module is for that player.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog
local Ledger = M.Ledger

M.Runs = {}
local Runs = M.Runs

-- Metres added to a gig's reach before a claim is measured against it. The
-- server's snapshot of a walking player is a tick or two behind the body they
-- are looking at, and refusing them for that would read as a broken row.
local REACH_GRACE = 1.5

-- Milliseconds subtracted from a leg's pace before a claim is measured against
-- it, for the round trip the claim itself took.
local PACE_GRACE = 250

-- Player to the run they hold, and the sequence the run ids come from.
local runs = {}
local sequence = 0

-- Player to their request window.
local windows = {}

-- Whether the module is taking claims. `Stop` clears it, so a claim that lands
-- between the last leg and the handler going away is refused rather than paid.
local running = false

-- Counts one request in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(player)
	local rate = M.Settings.RATE
	local limit = Catalog.Integer(type(rate) == 'table' and rate.REQUESTS, 1, 1000) or 12
	local spanMs = Catalog.Integer(type(rate) == 'table' and rate.WINDOW_MS, 100, 600000) or 10000

	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

-- The server's own snapshot of where a player stands, or nil.
local function position(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, at = pcall(players.position, player)
	if not read or type(at) ~= 'table' then return nil end
	local x = Catalog.Number(at.x, -100000, 100000)
	local y = Catalog.Number(at.y, -100000, 100000)
	local z = Catalog.Number(at.z, -100000, 100000)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = Catalog.Integer(at.bucket, 0, 65535) or 0 }
end

-- Whether a player stands within reach of a point, in the gig's own bucket.
-- Answers the refusal code rather than a bare false, because "too far" and "not
-- in this instance" are different sentences to the player.
local function standingAt(player, gig, point)
	local at = position(player)
	if at == nil then return false, 'no_position' end
	if at.bucket ~= gig.start.bucket then return false, 'wrong_bucket' end
	local reach = gig.reach + REACH_GRACE
	if Catalog.GapSquared(at, point) > reach * reach then return false, 'too_far' end
	return true
end

-- One leg of a run, in the shape both halves read.
local function leg(kind, point, gig, pays)
	return {
		kind = kind,
		x = point.x, y = point.y, z = point.z,
		label = point.label,
		actionMs = point.actionMs or gig.actionMs,
		animation = point.animation or gig.animation,
		pays = pays == true,
	}
end

-- Draws `count` points from a pool without repeating one, by shuffling a copy.
-- `math.random` seeded or not, the shuffle is the same shape; what matters is
-- that a run does not send the player to the same bag twice.
local function draw(points, count)
	local pool = {}
	for index = 1, #points do pool[index] = points[index] end
	for index = #pool, 2, -1 do
		local other = math.random(1, index)
		pool[index], pool[other] = pool[other], pool[index]
	end
	local out = {}
	for index = 1, math.min(count, #pool) do out[index] = pool[index] end
	return out
end

--- Turns a gig into the list of legs one run walks.
-- @author dop42
-- @param gig table
-- @return table[]
function Runs.Build(gig)
	local legs = {}

	if gig.kind == 'courier' then
		-- One point per leg pair, and a pool smaller than the run repeats a
		-- customer rather than cutting the run short: a courier gig's pool is a
		-- list of addresses, not a list of things that can each be taken once.
		local picked = draw(gig.points, gig.steps)
		for step = 1, gig.steps do
			local point = picked[step] or gig.points[math.random(1, #gig.points)]
			legs[#legs + 1] = leg('pick', gig.pickup, gig, false)
			legs[#legs + 1] = leg('drop', point, gig, true)
		end
		return legs
	end

	-- collect: every drawn point pays, and the drop-off closes the run.
	local picked = draw(gig.points, gig.steps)
	for index = 1, #picked do
		legs[#legs + 1] = leg('pick', picked[index], gig, true)
	end
	if gig.dropoff ~= nil then
		legs[#legs + 1] = leg('drop', gig.dropoff, gig, false)
	end
	return legs
end

-- The payload one leg travels in. The index is what the claim must name back.
local function legPayload(run)
	local current = run.legs[run.index]
	local gig = Catalog.Get(run.gig)
	if current == nil or gig == nil then return nil end
	return {
		run = run.id,
		gig = run.gig,
		title = gig.label,
		icon = gig.icon,
		kind = current.kind,
		index = run.index,
		total = #run.legs,
		x = current.x, y = current.y, z = current.z,
		label = current.label,
		actionMs = current.actionMs,
		animation = current.animation,
		reach = gig.reach,
		radius = gig.radius,
		earned = run.earned,
	}
end

-- Hands the current leg to its player, stamping when it went out.
local function issue(player, run)
	run.issuedAtMs = OPX.Now()
	local payload = legPayload(run)
	if payload == nil then return false end
	TriggerClientEvent(M.Event.LEG, player, payload)
	return true
end

-- Ends a run and tells its player why. `pay` is nil for anything but a run that
-- was finished.
local function finish(player, run, reason, pay)
	runs[player] = nil
	TriggerClientEvent(M.Event.ENDED, player, {
		run = run.id,
		gig = run.gig,
		reason = reason,
		earned = run.earned,
		pay = pay,
	})
end

--- The run a player holds, or nil.
-- @author dop42
-- @param player Source
-- @return table|nil
function Runs.Held(player)
	return runs[player]
end

--- Takes a gig for a player, building the run and handing out its first leg.
-- @author dop42
-- @param player Source
-- @param gigId any
-- @return table { ok = boolean, error = string|nil, wait = integer|nil }
function Runs.Take(player, gigId)
	if not running then return { ok = false, error = 'not_running' } end
	if not within(player) then return { ok = false, error = 'rate_limited' } end

	local gig = Catalog.Get(gigId)
	if gig == nil then return { ok = false, error = 'no_such_gig' } end
	if runs[player] ~= nil then return { ok = false, error = 'already_working' } end

	local near, why = standingAt(player, gig, gig.start)
	if not near then return { ok = false, error = why } end

	local record = Ledger.Read(player)
	local allowed, refusal, wait = Ledger.MayTake(record, gig)
	if not allowed then return { ok = false, error = refusal, wait = wait } end

	local legs = Runs.Build(gig)
	if #legs == 0 then return { ok = false, error = 'no_such_gig' } end

	sequence = sequence + 1
	local run = {
		id = ('r%d'):format(sequence),
		gig = gig.id,
		legs = legs,
		index = 1,
		earned = 0,
		startedAtMs = OPX.Now(),
		issuedAtMs = OPX.Now(),
	}
	runs[player] = run

	-- Counted on the way in, not on the way out: taking a run and walking away
	-- still spends the attempt, or the cooldown would be a cooldown on finishing.
	Ledger.Taken(player, gig)

	if not issue(player, run) then
		runs[player] = nil
		return { ok = false, error = 'internal_error' }
	end
	return { ok = true, run = run.id, total = #legs }
end

--- Works the leg a player is standing at, paying it and handing out the next.
-- @author dop42
-- @param player Source
-- @param runId any
-- @param index any
-- @return table { ok = boolean, error = string|nil }
function Runs.Work(player, runId, index)
	if not running then return { ok = false, error = 'not_running' } end
	if not within(player) then return { ok = false, error = 'rate_limited' } end

	local run = runs[player]
	if run == nil then return { ok = false, error = 'not_working' } end
	if runId ~= run.id then return { ok = false, error = 'stale_run' } end
	if Catalog.Integer(index, 1, 1000) ~= run.index then return { ok = false, error = 'stale_leg' } end

	local gig = Catalog.Get(run.gig)
	if gig == nil then
		-- The gig was switched off under a run in flight. The run ends rather
		-- than hanging on a leg nothing can answer for.
		finish(player, run, 'gig_gone')
		return { ok = false, error = 'no_such_gig' }
	end

	local current = run.legs[run.index]
	if current == nil then return { ok = false, error = 'stale_leg' } end

	local near, why = standingAt(player, gig, current)
	if not near then return { ok = false, error = why } end

	local waited = OPX.Now() - run.issuedAtMs
	if waited + PACE_GRACE < current.actionMs then return { ok = false, error = 'too_soon' } end

	if current.pays then
		run.earned = run.earned + Ledger.PayLeg(player, gig)
	end

	run.index = run.index + 1
	if run.index <= #run.legs then
		if not issue(player, run) then
			finish(player, run, 'internal_error')
			return { ok = false, error = 'internal_error' }
		end
		return { ok = true, run = run.id, index = run.index }
	end

	-- The run is done: the bonus, the items and the reputation, in that order,
	-- so a bag that refuses an item never costs the eddies that came first.
	local bonus = Ledger.PayBonus(player, gig)
	run.earned = run.earned + bonus
	local items = Ledger.GiveItems(player, gig)
	local reputation = Ledger.Completed(player, gig)

	finish(player, run, 'completed', {
		bonus = bonus,
		items = items,
		reputation = reputation,
		gained = gig.reputation,
	})
	return { ok = true, completed = true }
end

--- Drops the run a player holds, at their own asking or at the module's.
-- @author dop42
-- @param player Source
-- @param reason string
-- @return table { ok = boolean, error = string|nil }
function Runs.Quit(player, reason)
	local run = runs[player]
	if run == nil then return { ok = false, error = 'not_working' } end
	finish(player, run, reason or 'abandoned')
	return { ok = true }
end

--- Forgets everything held for a player who left. No event is sent: there is
--- nobody on the other end of it.
-- @author dop42
-- @param player Source
function Runs.Forget(player)
	runs[player] = nil
	windows[player] = nil
end

--- Drops the runs nobody has touched inside the timeout, and collects the rate
--- windows of players who are gone.
-- @author dop42
-- @return integer how many runs were dropped
function Runs.Sweep()
	local timeout = Catalog.Integer(M.Settings.RUN_TIMEOUT_MS, 10000, 86400000) or 1800000
	local at = OPX.Now()

	local dropped = 0
	for player, run in pairs(runs) do
		if at - run.issuedAtMs > timeout then
			dropped = dropped + 1
			finish(player, run, 'expired')
		end
	end

	-- `within` builds a window on demand, so a packet landing after a player left
	-- recreates the entry `Forget` had just cleared. The collection window is far
	-- longer than any configured one, so a present player never loses a counter.
	for player, window in pairs(windows) do
		if at - (window.started or at) > 60000 then windows[player] = nil end
	end

	return dropped
end

--- What a player is doing right now, for the command and for the contract.
-- @author dop42
-- @param player Source
-- @return table|nil
function Runs.State(player)
	local run = runs[player]
	if run == nil then return nil end
	return {
		run = run.id,
		gig = run.gig,
		index = run.index,
		total = #run.legs,
		earned = run.earned,
		forMs = OPX.Now() - run.startedAtMs,
	}
end

--- Clears every run. Called from `Init`, which is also what a reload runs.
-- @author dop42
function Runs.Reset()
	runs, windows, sequence = {}, {}, 0
	running = false
end

--- Starts taking claims.
-- @author dop42
function Runs.Open()
	running = true
end

--- Stops taking claims and ends every run in flight, so nobody is left holding a
--- leg this VM will never answer for.
-- @author dop42
function Runs.Close()
	running = false
	for player in pairs(runs) do Runs.Quit(player, 'stopped') end
end
