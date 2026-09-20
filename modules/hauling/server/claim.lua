--- The claim, and nothing else.
-- @author dop42
--
-- ============================================================================
-- NOTHING IN `Claim.Take` MAY YIELD. NOT ONE LINE. THAT IS THE WHOLE FILE.
-- ============================================================================
--
-- The server Lua runtime is single-threaded and coroutines interleave ONLY at a
-- yield. So a read-then-write with nothing yielding between the read and the
-- write cannot be interleaved, and two players who ALT the same crate in the
-- same tick are served strictly one after the other: the first sets `where` to
-- `claimed`, the second reads `claimed` and is refused.
--
-- That invariant belongs to the RUNTIME and not to the code, and it is invisible
-- at the call site. Both shipped examples rely on it and neither says so. One
-- inserted yield inside the body below and two players hold the same crate, with
-- NOTHING IN THE LOG to say it happened -- each of them saw a successful pickup.
--
-- The things that yield, and that will therefore bite:
--
--   Wait, SetTimeout, anything `:await()`ed, any callback,
--   Open77.database.*, Open77.http.*,
--   and Open77.world.groundZ, WHICH ROUND-TRIPS TO A CLIENT
--
-- The last is the one that catches people: it reads like a world query and it is
-- a network request. None of them appears below, and none may be added. Anything
-- expensive -- reading a position, measuring reach, resolving a bucket, asking
-- the inventory whether the player has room, reading the prop's revision off the
-- host -- happens in the CALLER, before `Take` or after it. That is why the
-- revision is a parameter here and not a `Open77.props.get` on line one.
--
-- WHY IT STILL RESERVES BEFORE IT VERIFIES. Under the rule above, checking then
-- writing would be enough. It is written reserve-then-verify-then-rollback so
-- that if the rule is ever broken by a later edit, the failure is a refused claim
-- and not a shared one: the reservation goes up first, so anything that
-- interleaved after it meets `claimed` and loses, and if our own claim then turns
-- out to be invalid we put the crate back exactly as we found it.
--
-- THE PLATFORM'S OWN COMPARE-AND-SWAP IS THE OTHER BELT, and it is not in this
-- file: the caller reads `Open77.props.get(propId).revision` before calling
-- `Take`, hands it in, and passes it to `Open77.props.attach(id, binding,
-- expectedRevision)` when the bar completes. A prop somebody else re-bound in
-- between is refused by the host before any mutation happens. Two independent
-- mechanisms guard the same thing on purpose: this table is ours, the prop
-- registry is not.

local M = OPX.Modules.Get('hauling')

M.Claim = {}
local Claim = M.Claim

local Where = M.Where

--- Puts one crate in one player's name, or refuses and says why.
--
-- NOTHING HERE MAY YIELD -- see the file header. Every argument is a value the
-- caller has already resolved; this function asks the host nothing.
--
-- @author dop42
-- @param crates table propId -> crate record, the server's own registry
-- @param propId string the crate's decimal-string prop id
-- @param player integer the claiming connection, from `source` and never the payload
-- @param step string an `M.Step` value, the bar about to run
-- @param revision integer|nil the prop revision the caller read, for the host CAS
-- @param nowMs integer the claim stamp, so the reap pass can expire it
-- @return boolean granted
-- @return string|nil reason when it was not
function Claim.Take(crates, propId, player, step, revision, nowMs)
	if type(crates) ~= 'table' then return false, 'no_registry' end
	local crate = crates[propId]
	if crate == nil then return false, 'no_such_crate' end

	-- THE RACE GUARD. Delete these two lines and two players in one tick both
	-- walk away with the same crate; that is exactly what the mutation test on
	-- this function breaks, and it must go red when it does.
	if crate.where ~= Where.GROUND then return false, 'already_claimed' end
	if crate.owner ~= nil then return false, 'already_claimed' end

	-- One crate per pair of hands. Checked here rather than in the caller because
	-- it is the same invariant -- who holds what -- and splitting it across a
	-- yield boundary would let a player claim two crates from two clicks.
	for _, other in pairs(crates) do
		if other.owner == player then return false, 'already_carrying' end
	end

	-- What to put back if the verify below refuses. A record and not a flag: the
	-- crate must come out of a failed claim byte-identical to how it went in, or
	-- the refusal has bricked it for everybody.
	local before = { where = crate.where, owner = crate.owner, step = crate.step,
		claimedAtMs = crate.claimedAtMs, revision = crate.revision }

	-- RESERVE.
	crate.where = Where.CLAIMED
	crate.owner = player
	crate.step = step
	crate.claimedAtMs = nowMs

	-- VERIFY. The revision the caller read off the host must not be OLDER than the
	-- one this registry already recorded for the crate: that means the prop moved
	-- under us between the read and this call and the caller's read is stale, so
	-- the `expectedRevision` it would hand to `Open77.props.attach` is stale too
	-- and the attach would be refused after the bar had already run. Better to
	-- refuse now, with the crate still on the ground for whoever is next.
	if revision ~= nil and before.revision ~= nil and revision < before.revision then
		-- ROLLBACK.
		crate.where = before.where
		crate.owner = before.owner
		crate.step = before.step
		crate.claimedAtMs = before.claimedAtMs
		return false, 'stale_revision'
	end

	-- COMMIT: the revision the attach will be held to.
	if revision ~= nil then crate.revision = revision end
	return true
end

--- Re-stamps the clock on a crate its owner already holds.
--
-- Load and deliver are UNCONTESTED: the crate is already in one player's hands or
-- in the vehicle they loaded it into, and no second player can reach it. So there
-- is no race to win here and no claim to take -- only the clock to restart, so
-- `TooSoon` measures the new bar rather than the one before it.
--
-- It still refuses a caller who does not own the crate, because the step and the
-- stamp are what the completion is checked against and a stranger writing them
-- would be a stranger choosing how long their own bar has to run.
-- @author dop42
-- @param crates table
-- @param propId string
-- @param player integer
-- @param step string
-- @param nowMs integer
-- @return boolean
-- @return string|nil
function Claim.Restamp(crates, propId, player, step, nowMs)
	if type(crates) ~= 'table' then return false, 'no_registry' end
	local crate = crates[propId]
	if crate == nil then return false, 'no_such_crate' end
	if crate.owner ~= player then return false, 'not_yours' end
	crate.step = step
	crate.claimedAtMs = nowMs
	return true
end

--- Hands a crate back, whoever was holding it.
-- Idempotent: a crate already on the ground is left alone and answers true, so
-- the disconnect path, the reap pass and an explicit cancel may all reach the
-- same crate without racing each other into a refusal.
-- @author dop42
-- @param crates table
-- @param propId string
-- @param player integer|nil when given, only that player's claim is released
-- @return boolean released whether this call was the one that let it go
function Claim.Release(crates, propId, player)
	if type(crates) ~= 'table' then return false end
	local crate = crates[propId]
	if crate == nil then return false end
	if crate.owner == nil then return false end
	if player ~= nil and crate.owner ~= player then return false end
	crate.where = Where.GROUND
	crate.owner = nil
	crate.step = nil
	crate.claimedAtMs = nil
	return true
end

--- The crate one player holds, or nil.
-- @author dop42
-- @param crates table
-- @param player integer
-- @return table|nil
function Claim.HeldBy(crates, player)
	if type(crates) ~= 'table' then return nil end
	for _, crate in pairs(crates) do
		if crate.owner == player then return crate end
	end
	return nil
end

--- Every claim that has outlived the bar it was taken for, oldest first.
--
-- THE THING BOTH SHIPPED EXAMPLES ARE MISSING. `rp_ferrailleur` and `rp_nomade`
-- release a claim on disconnect and on nothing else, so a player who claims a
-- crate and then stands in a menu, alt-tabs, or simply walks off holds it until
-- the process restarts. One such player on a four-point site has taken a quarter
-- of the job away from everybody, permanently, and no log line anywhere says so.
--
-- A claim is dead when it is older than the bar it was taken for plus a grace
-- that covers the round trip. Sorted oldest first so a pass that is capped still
-- frees the crates that have been stuck longest.
-- @author dop42
-- @param crates table
-- @param nowMs integer
-- @param graceMs integer
-- @param stepMs fun(step: string): integer
-- @return string[] prop ids
function Claim.Expired(crates, nowMs, graceMs, stepMs)
	local out = {}
	if type(crates) ~= 'table' then return out end
	for propId, crate in pairs(crates) do
		-- Only a CLAIM expires. A crate in somebody's hands or in a vehicle bed is
		-- not a reservation waiting on a bar -- it is a carry, and a carry ends
		-- through `onPropAttachmentChanged` or through a delivery, never through a
		-- clock. Expiring one would teleport a crate out of a moving truck.
		if crate.where == Where.CLAIMED and crate.claimedAtMs ~= nil then
			local allowed = stepMs(crate.step) + graceMs
			if nowMs - crate.claimedAtMs > allowed then
				out[#out + 1] = { id = propId, at = crate.claimedAtMs }
			end
		end
	end
	table.sort(out, function(left, right)
		if left.at ~= right.at then return left.at < right.at end
		return tostring(left.id) < tostring(right.id)
	end)
	local ids = {}
	for index = 1, #out do ids[index] = out[index].id end
	return ids
end

--- Whether a completion arrived too soon to be believed.
--
-- THE SERVER OWNS THE CLOCK. `modules/progress` is client-side only: the bar is
-- counted down by the player's own machine and a patched client counts it to zero
-- the moment it appears. The stamp taken at `Take` is the real clock, and a
-- `finish` that arrives sooner than the bar could possibly have run is a client
-- saying it did work it did not do.
--
-- The tolerance covers the round trip and the client's frame granularity. It is
-- subtracted and never added: a completion that arrives LATE is fine -- the reap
-- pass is what deals with one that never arrives at all.
-- @author dop42
-- @param crate table
-- @param nowMs integer
-- @param requiredMs integer
-- @param toleranceMs integer
-- @return boolean
function Claim.TooSoon(crate, nowMs, requiredMs, toleranceMs)
	if type(crate) ~= 'table' or crate.claimedAtMs == nil then return true end
	local elapsed = nowMs - crate.claimedAtMs
	return elapsed < requiredMs - toleranceMs
end
