--- One routing bucket per player, for anyone the world must not see yet.
-- @author dop42
--
-- Core owns the mechanism and nothing else. WHO deserves to be isolated is a
-- question about characters, and core does not know that characters exist: the
-- caller decides, and `Isolate` refuses only on what core itself owns -- a
-- session that is on its way out, whose slot may already belong to someone else.
--
-- A bucket move is NOT a placement. It changes which bodies, props and vehicles
-- the host replicates to and from the player, without writing transform, life
-- state or puppet -- which are exactly what the readiness gate protects a client
-- that is not incarnated yet from. So a move is made deliberately with the gate
-- still CLOSED, from the first moment the runtime knows the player.
--
-- Every `Open77.routingBuckets` call goes through a `pcall`, and a read that
-- raises answers "unknown bucket". That API needs no manifest permission.

OPX.Buckets = {}
local Buckets = OPX.Buckets

local Config = OPX.Config.SERVER

-- The largest bucket id the host accepts.
local UINT32_MAX = 4294967295

-- Player ids are small recycled integers, so a selection bucket is BASE + id
-- over this span.
local ID_SPAN = 65535

local LOCKDOWN_MODES = { inactive = true, relaxed = true, strict = true, full = true }

-- The bucket configuration, validated once at load: a bad value is named once
-- and the shipped one is used in its place.
local isolate, base, world, population, lockdown = true, 77000, 0, false, 'relaxed'
do
	local wanted = type(Config.ENTRY) == 'table' and Config.ENTRY.BUCKET or nil
	if type(wanted) ~= 'table' then
		if wanted ~= nil then
			Open77.log.warn('[bucket] ENTRY.BUCKET is not a table: the shipped selection bucket is used')
		end
		wanted = {}
	end

	if wanted.ISOLATE == false then
		isolate = false
	elseif wanted.ISOLATE ~= nil and wanted.ISOLATE ~= true then
		Open77.log.warn('[bucket] ENTRY.BUCKET.ISOLATE is not a boolean: players are isolated')
	end

	local function integer(value, low, high)
		return OPX.Math.IsFinite(value) and value % 1 == 0 and value >= low and value <= high
	end

	if wanted.WORLD ~= nil then
		if integer(wanted.WORLD, 0, UINT32_MAX) then
			world = wanted.WORLD
		else
			Open77.log.warn('[bucket] ENTRY.BUCKET.WORLD is not a bucket id: 0 is used')
		end
	end

	if wanted.BASE ~= nil then
		if integer(wanted.BASE, 0, UINT32_MAX - ID_SPAN) then
			base = wanted.BASE
		else
			Open77.log.warn(('[bucket] ENTRY.BUCKET.BASE is not a bucket id at most %d: %d is used')
				:format(UINT32_MAX - ID_SPAN, base))
		end
	end

	-- A world bucket inside the selection range is no bucket to release anyone
	-- into: it would leave them alone in somebody's selection bucket. Isolation
	-- is switched off rather than left broken.
	if world > base and world <= base + ID_SPAN then
		Open77.log.error(('[bucket] ENTRY.BUCKET.WORLD %d is inside the selection range %d..%d: ' ..
			'players are not isolated'):format(world, base + 1, base + ID_SPAN))
		isolate = false
	end

	if wanted.POPULATION ~= nil then
		if type(wanted.POPULATION) == 'boolean' then
			population = wanted.POPULATION
		else
			Open77.log.warn('[bucket] ENTRY.BUCKET.POPULATION is not a boolean: population is off')
		end
	end

	if wanted.LOCKDOWN == false then
		lockdown = nil
	elseif wanted.LOCKDOWN ~= nil then
		if LOCKDOWN_MODES[wanted.LOCKDOWN] then
			lockdown = wanted.LOCKDOWN
		else
			Open77.log.warn('[bucket] ENTRY.BUCKET.LOCKDOWN is not a lockdown mode: relaxed is used')
		end
	end
end

-- Selection buckets whose policy this VM has already set.
local prepared = {}

-- The host API is read at call time and never captured at load: during boot the
-- global may not be installed yet, and a nil captured now would be captured
-- forever. The answer is the `pcall` pair every caller here already reads.
local function host(verb, ...)
	local api = Open77.routingBuckets
	local fn = api and api[verb]
	if fn == nil then return false, 'no routing bucket api' end
	return pcall(fn, ...)
end

-- A player's own selection bucket, or nil when nobody is isolated or the id
-- falls outside the span.
local function selectionOf(source)
	if not isolate or not source or source < 1 or source > ID_SPAN or source % 1 ~= 0 then
		return nil
	end
	return base + source
end

-- The bucket a player is in, or nil when the read raised.
local function current(source)
	local read, bucket = host('getPlayer', source)
	return read and tonumber(bucket) or nil
end

-- The policy belongs to the bucket, not to the player: it outlives whoever is
-- standing in it, and it is set again after a reload because `prepared` is this
-- VM's own table.
local function prepare(bucket)
	if prepared[bucket] then return end
	prepared[bucket] = true
	host('setPopulationEnabled', bucket, population)
	if lockdown ~= nil then
		host('setLockdownMode', bucket, lockdown)
	end
end

--- Whether a bucket id lies in the selection range. Answers even with isolation
--- switched off, so a position stored there by an earlier configuration is still
--- recognised for what it is.
-- @author dop42
-- @param bucket any
-- @return boolean
function OPX.Buckets.IsSelection(bucket)
	return type(bucket) == 'number' and bucket > base and bucket <= base + ID_SPAN
end

--- The bucket a stored position places someone in.
--- A stored bucket inside the selection range, or one that is not a bucket id at
--- all, reads as WORLD: a selection bucket belongs to whoever holds that player
--- id now, never to a character.
-- @author dop42
-- @param stored any the bucket of a stored position
-- @return integer
function OPX.Buckets.PlacementOf(stored)
	local bucket = tonumber(stored)
	if bucket == nil or bucket % 1 ~= 0 or bucket < 0 or bucket > UINT32_MAX then return world end
	if Buckets.IsSelection(bucket) then return world end
	return bucket
end

--- Moves one player to a bucket.
--- Not a placement: it writes no transform, no life state and no puppet, so it is
--- safe -- and meant -- to be made while the readiness gate is still closed.
-- @author dop42
-- @param source Source
-- @param bucket integer
-- @param why string|nil what the log line says the move was for
-- @return boolean
function OPX.Buckets.Move(source, bucket, why)
	why = why or 'move'
	local from = current(source)
	if from == bucket then return true end

	local called, moved, reason = host('setPlayer', source, bucket)
	if called and moved then
		Open77.log.debug(('[bucket] %s moved from %s to %s (%s)')
			:format(tostring(source), tostring(from), tostring(bucket), why))
		return true
	end

	-- A warning and not a debug line: the player is then waiting in the wrong
	-- world, or walking into it.
	Open77.log.warn(('[bucket] %s could not be moved from %s to %s (%s): %s')
		:format(tostring(source), tostring(from), tostring(bucket), why,
			tostring(called and reason or moved)))
	return false
end

--- Moves a player into their own selection bucket.
--- The caller must NOT call this for a player who has a character loaded: that
--- player is in the world, and core cannot tell -- the roster belongs to whoever
--- provides the `character` contract. Core refuses on the one thing it does own:
--- a session marked `departing`, whose player id may already have been handed to
--- somebody else.
-- @author dop42
-- @param source Source
-- @param why string|nil what the log line says the move was for
-- @return boolean
function OPX.Buckets.Isolate(source, why, expectedUserId)
	source = tonumber(source)
	local bucket = source and selectionOf(source)
	if bucket == nil then return false end

	local session = OPX.Sessions[source]
	if not session or session.departing then return false end
	-- The same check `OPX.Gate.Release` makes, for the same reason: this is
	-- called from paths that yield, and a slot recycled in between would put
	-- the player who now holds it into a selection bucket of their own.
	if expectedUserId ~= nil and session.userId ~= expectedUserId then return false end

	prepare(bucket)
	return Buckets.Move(source, bucket, why or 'isolated')
end

--- Moves a player out of their selection bucket and into the world.
--- Touches only a player inside the selection range: a bucket another resource
--- has chosen since is left exactly as it is. Answers true when there was
--- nothing to release, and says separately whether a move happened.
-- @author dop42
-- @param source Source
-- @param why string|nil what the log line says the move was for
-- @param expectedUserId string|nil the account the caller loaded a character
--        for; a slot that belongs to anybody else by now is left alone
-- @return boolean ok
-- @return boolean moved
function OPX.Buckets.Release(source, why, expectedUserId)
	-- WHOSE SLOT IS THIS. This moved whoever stood on the slot into the world,
	-- checking nothing at all, and it is called from the end of the entry
	-- sequence -- after every database read that yields. Paired with the gate
	-- release beside it, a late arrival admitted the player who had taken the
	-- recycled slot: out of their selection bucket AND through the gate, with no
	-- character loaded. `Isolate` above makes the same check.
	if expectedUserId ~= nil then
		local session = OPX.Sessions[tonumber(source) or -1]
		if not session or session.userId ~= expectedUserId then return false, false end
	end

	local held = current(source)
	if held == nil or not Buckets.IsSelection(held) then return true, false end
	local moved = Buckets.Move(source, world, why or 'released')
	return moved, moved
end

-- On stop, nobody is left in a bucket that no running resource knows about.
AddEventHandler(OPX.Host.RESOURCE_STOP, function(name)
	if name ~= GetCurrentResourceName() then return end

	local count = 0
	for source in pairs(OPX.Sessions) do
		local _, moved = Buckets.Release(source, 'resource stopped')
		if moved then count = count + 1 end
	end

	if count > 0 then
		Open77.log.info(('[bucket] stopping: %d player(s) moved out of their selection bucket')
			:format(count))
	end
end)
