--- Server half: the crates, the wire, the refill pass and the pay.
-- @author dop42
--
-- THE SERVER OWNS EVERY CRATE. It creates them, in the SITE's bucket and never in
-- the reporting player's -- the mistake `modules/elevators/server/main.lua:5-8`
-- already warns about for lifts, and the one `rp_nomade` makes for crates: it
-- creates them in the accepting driver's bucket, so nobody outside that instance
-- can ever see one and the race the whole feature is built on never happens.
--
-- Every value off the wire goes through `safe` before it reaches a format string:
-- a newline would forge a whole log line.
--
-- The shape is `modules/elevators/server/main.lua`'s, because that is this
-- resource's house pattern for a server-owned world thing: a table of what we
-- own, an explicit release that tells everyone who was told, a `forget` on
-- disconnect, and a periodic sweep. It teaches the two lessons this module needs
-- most -- verify against the host before committing, and release rather than keep
-- a half-good claim.
--
-- WHAT IS DELIBERATELY NOT HERE:
--
--   `Open77.world.nearby` -- a CLIENT game native. On the server it answers
--   `part_layout_not_proven` and is not a proximity query at all.
--
--   `Open77.props.catalog()` -- always an empty table on the server, so a model
--   alias cannot be validated against a list. `probe` below validates it by
--   TRYING, once, at boot.
--
--   `Open77.props.remove`'s truthiness as a test of existence -- the server card
--   lists `not_found` while the client card says removing an already-gone prop
--   SUCCEEDS, and that contradiction is unresolved. Nothing branches on it here.
--
--   `Open77.kvp.compareAndSet` -- a real typed CAS and a genuine third belt, and
--   two are enough: the non-yielding claim guards our own table and the prop
--   `revision` guards the host's. A third store to keep in step is a third store
--   that can disagree with the other two.

local M = OPX.Modules.Get('hauling')
local Access, Claim = M.Access, M.Claim
local Where, Step = M.Where, M.Step

-- Prop id to the crate record this module owns. The one source of truth for who
-- has what; `Claim` is the only thing allowed to change the ownership fields.
local crates = {}

-- Site key to point index to the earliest millisecond that point may be refilled.
-- A delivered crate's point cools for RESPAWN_MS so a worked site reads as worked
-- rather than replacing a crate before the driver is out of the yard.
local cooling = {}

-- Vehicle id to how many crates are in its bed, so the nth crate gets the nth
-- slot and the ones past the last slot stack instead of overlapping.
local bedCount = {}

-- Players handed the snapshot, so a delta reaches all of them and a release tells
-- everyone who was told.
local told = {}

-- Per-player rate-limit windows: requests and log lines.
local requestWindows, logWindows = {}, {}

-- Requests one player may make per window, and the window.
local REQUESTS_PER_WINDOW = 10
local REQUEST_WINDOW_MS = 5000

-- Age past which the sweep collects a rate-limit window. Far longer than the
-- widest window asked for, so a present player's counter is never lost.
local WINDOW_GC_MS = 60000

-- Crates in one snapshot part. The same reason `modules/inventory` chunks its
-- piles: one message per crate is a packet storm at login and one message for
-- sixty-four crates is a payload the host may refuse whole.
local SNAPSHOT_PART = 24

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- The refill pass's handle, so `Stop` can cancel it.
local refillJob = nil

local coordinate, integer = Access.Coordinate, Access.Integer

--- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

--- Calls a host native that answers `true`, or `nil, reason`, and flattens every
--- way it can go into one pair.
--
-- THREE SHAPES REACH A CALLER and two of them are easy to read as success. The
-- native raises (and `pcall` puts the message where the value goes); it answers
-- `nil, reason`; or it answers `true`. Written out at each site, the middle case
-- is the one that gets dropped -- `local ok = pcall(attach, ...)` is `true` for a
-- refused attach, and a refused attach read as success is a claim held over a
-- crate that is in nobody's hands.
-- @author dop42
-- @param fn function
-- @return boolean
-- @return string|nil
local function hostCall(fn, ...)
	if type(fn) ~= 'function' then return false, 'native_unavailable' end
	local called, value, detail = pcall(fn, ...)
	if not called then return false, 'raised: ' .. tostring(value) end
	if value == true then return true, nil end
	return false, tostring(detail or value or 'refused')
end

--- Counts one event in a player's window, refusing AT the limit rather than
--- counting on through the rest of it.
local function within(windows, player, limit, spanMs)
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

--- Whether this host has the prop API at all.
-- Read at the moment of use and never cached: the table belongs to the native
-- layer and a reference kept across a resource reload would outlive the layer
-- that published it.
local function propsReady()
	local props = Open77.props
	return type(props) == 'table' and type(props.create) == 'function'
end

--- The revision the host currently records for a prop, or nil.
--
-- READ BY THE CALLER AND HANDED TO THE CLAIM, never read inside it. This is a
-- host call: it is not on the documented list of things that yield, and that is
-- exactly why it must not be inside `Claim.Take` -- the claim's rule is "no host
-- call at all", which is checkable by reading the function, where "no host call
-- that yields today" is not.
local function revisionOf(propId)
	if not propsReady() or type(Open77.props.get) ~= 'function' then return nil end
	local read, snapshot = pcall(Open77.props.get, propId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return integer(snapshot.revision)
end

--- One crate in the shape a client is sent.
-- The POSITION IS THE POINT and not the prop's live transform: a carried crate
-- moves every frame and the client only needs to know where its home is, which
-- is what the world-mode target row matches against and what a put-back returns
-- it to.
local function wireOf(crate)
	return { id = crate.id, site = crate.site, x = crate.x, y = crate.y, z = crate.z,
		bucket = crate.bucket, where = crate.where }
end

--- Tells one player about one crate.
local function tell(player, crate)
	TriggerClientEvent(M.Event.CRATE, player, wireOf(crate))
end

--- Tells every player handed the snapshot about one crate.
local function announce(crate)
	for player in pairs(told) do tell(player, crate) end
end

--- Tells every player handed the snapshot that a crate is gone.
local function announceGone(propId)
	for player in pairs(told) do TriggerClientEvent(M.Event.GONE, player, propId) end
end

--- Answers one player's request, and tells them what they are holding.
-- `carrying` rides on every answer rather than on an event of its own: a client
-- that missed one refusal would otherwise keep drawing a carry row for a crate it
-- no longer has, and the next answer would not correct it.
local function answer(player, ok, reason)
	local held = Claim.HeldBy(crates, player)
	TriggerClientEvent(M.Event.ANSWER, player, ok == true, reason,
		held ~= nil and held.id or false)
end

--- Sends one player every crate, in parts.
--
-- EVERY BUCKET'S CRATES GO TO EVERY CLIENT and the server refuses on bucket at
-- the moment of use. Filtering at send time is the obvious fix and is wrong for
-- the same reason it is wrong in `modules/inventory/server/world.lua:180-186`: a
-- player changes bucket with no hello -- character selection, an instance -- and
-- would never receive the crates of the bucket they arrive in.
local function sendSnapshot(player)
	local list = {}
	for _, crate in pairs(crates) do list[#list + 1] = wireOf(crate) end
	-- Sorted, because `pairs` order would reshuffle the snapshot between two
	-- players who joined a second apart and make a wire bug look intermittent.
	table.sort(list, function(left, right) return tostring(left.id) < tostring(right.id) end)

	local first = 1
	repeat
		local last = math.min(#list, first + SNAPSHOT_PART - 1)
		local part = {}
		for index = first, last do part[#part + 1] = list[index] end
		TriggerClientEvent(M.Event.SNAPSHOT, player,
			{ first = first == 1, done = last >= #list, crates = part })
		first = last + 1
	until first > #list
end

--- Takes a crate out of whatever it was attached to and stands it back on its point.
--
-- PUT BACK AND NOT DELETED, which is the whole difference between a carry that
-- ended and a crate that was denied to everybody else. The platform detaches
-- automatically on death, disconnect, parent removal and bucket change, and if
-- this deleted the crate instead then disconnecting would be how a player takes a
-- crate away from the competition -- press alt-F4 and nobody gets it.
--
-- DETACH FIRST. `Open77.props.setTransform` answers `prop_attached` for a bound
-- prop, so the order here is not a style choice: reversed, the crate would stay
-- wherever the coarse detach anchor left it and the point would look occupied by
-- a crate standing somewhere else.
local function putBack(crate, reason)
	if crate.vehicle ~= nil then
		bedCount[crate.vehicle] = math.max(0, (bedCount[crate.vehicle] or 1) - 1)
		crate.vehicle = nil
	end
	if propsReady() and type(Open77.props.detach) == 'function' then
		pcall(Open77.props.detach, crate.id)
	end
	if propsReady() and type(Open77.props.setTransform) == 'function' then
		local moved, why = pcall(Open77.props.setTransform, crate.id,
			{ position = { x = crate.x, y = crate.y, z = crate.z }, yaw = crate.yaw })
		if not moved then
			Open77.log.warn(('[hauling] crate %s could not be stood back up: %s')
				:format(safe(crate.id), safe(why)))
		end
	end
	crate.where = Where.GROUND
	crate.owner = nil
	crate.step = nil
	crate.claimedAtMs = nil
	crate.pendingVehicle = nil
	crate.revision = revisionOf(crate.id) or crate.revision
	announce(crate)
	Open77.log.info(('[hauling] crate %s back on %s point %d: %s'):format(safe(crate.id),
		safe(crate.site), crate.index, safe(reason)))
end

--- Drops a crate from the world and from this module, and cools its point.
local function retire(crate, reason)
	-- OUT OF THE REGISTRY FIRST. `Open77.props.remove` raises
	-- `onPropAttachmentChanged` and `onPropRemoved`, and both handlers look the
	-- crate up here: a crate still present when the attachment event lands would be
	-- stood back up on its point a millisecond after being paid for and removed.
	crates[crate.id] = nil
	if crate.vehicle ~= nil then
		bedCount[crate.vehicle] = math.max(0, (bedCount[crate.vehicle] or 1) - 1)
	end
	local points = cooling[crate.site]
	if points == nil then
		points = {}
		cooling[crate.site] = points
	end
	points[crate.index] = OPX.Now() + Access.RespawnMs(crate.site)

	if propsReady() and type(Open77.props.remove) == 'function' then
		pcall(Open77.props.remove, crate.id)
	end
	announceGone(crate.id)
	Open77.log.info(('[hauling] crate %s removed from %s point %d: %s'):format(
		safe(crate.id), safe(crate.site), crate.index, safe(reason)))
end

--- Puts one crate on one point of one site, or answers why not.
-- @return string|nil prop id
-- @return string|nil reason
local function spawn(siteKey, index)
	if not propsReady() then return nil, 'props_unavailable' end
	local point = Access.Point(siteKey, index)
	if point == nil then return nil, 'no_such_point' end

	-- THE SITE'S BUCKET. See the file header: the reporting player's bucket is the
	-- bug, not the shortcut.
	local created, id, reason = pcall(Open77.props.create, {
		model = Access.Model(siteKey),
		position = { x = point.x, y = point.y, z = point.z },
		yaw = point.yaw,
		bucket = Access.Bucket(siteKey),
		physics = 'static',
		collision = true,
	})
	if not created then return nil, 'create_raised' end
	if id == nil then return nil, tostring(reason) end

	local crate = {
		id = id,
		site = siteKey,
		index = index,
		x = point.x, y = point.y, z = point.z, yaw = point.yaw,
		bucket = Access.Bucket(siteKey),
		where = Where.GROUND,
		owner = nil,
		revision = revisionOf(id),
	}
	crates[id] = crate
	announce(crate)
	return id
end

--- How many crates this module has standing, across every site.
local function crateCount()
	return OPX.Table.Count(crates)
end

--- Which point indexes of a site have no crate and are not cooling.
local function freePoints(siteKey, atMs)
	local site = Access.Site(siteKey)
	if site == nil or type(site.POINTS) ~= 'table' then return {} end
	local taken = {}
	for _, crate in pairs(crates) do
		if crate.site == siteKey then taken[crate.index] = true end
	end
	local points = cooling[siteKey] or {}
	local free = {}
	for index = 1, #site.POINTS do
		if not taken[index] and (points[index] == nil or atMs >= points[index]) then
			free[#free + 1] = index
		end
	end
	return free
end

--- One refill-and-reap pass.
--
-- REAP FIRST, SPAWN SECOND, and in that order on purpose: a claim that expired
-- this pass frees a crate that is already standing on its point, so a spawn that
-- ran first would have counted that point as taken and the site would refill one
-- crate slower than it should for ever.
local function refillOnce()
	local at = OPX.Now()

	local stale = Claim.Expired(crates, at, Access.CLAIM_GRACE_MS, Access.StepMs)
	for index = 1, #stale do
		local crate = crates[stale[index]]
		if crate ~= nil then
			local was = crate.owner
			Claim.Release(crates, crate.id)
			crate.pendingVehicle = nil
			announce(crate)
			Open77.log.info(('[hauling] crate %s: player %s claimed it and never finished; ' ..
				'released'):format(safe(crate.id), tostring(was)))
			if was ~= nil then answer(was, false, 'claim_expired') end
		end
	end

	local ceiling = Access.MAX_CRATES
	for _, siteKey in ipairs(Access.UsableKeys()) do
		local allowance = Access.SpawnPerPass(siteKey)
		local free = freePoints(siteKey, at)
		for index = 1, #free do
			if allowance <= 0 then break end
			if crateCount() >= ceiling then break end
			local id, reason = spawn(siteKey, free[index])
			if id == nil then
				-- A SITE WHOSE MODEL THE ENGINE DOES NOT KNOW IS CONDEMNED, not
				-- retried every minute for the session. `unknown_alias` is a config
				-- mistake and no number of passes will fix it; the alternative is one
				-- log line a minute for ever, which is the same as silence.
				if reason == 'unknown_alias' or reason == 'invalid_model' then
					Access.Condemn(siteKey)
					Open77.log.error(('[hauling] SITE %s IS DISABLED: the engine does not know ' ..
						'the model %q. It must be a curated prop alias -- crate.small is the one ' ..
						'that has actually been carried -- and never a .mesh path, which renders ' ..
						'as placeholder geometry and cannot be attached at all')
						:format(safe(siteKey), safe(Access.Model(siteKey))))
					break
				end
				Open77.log.warn(('[hauling] %s point %d: no crate (%s)'):format(safe(siteKey),
					free[index], safe(reason)))
			end
			allowance = allowance - 1
		end
	end

	for _, windows in ipairs({ requestWindows, logWindows }) do
		for player, window in pairs(windows) do
			if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
		end
	end
end

--- The player's position, or nil. One host read, which answers the point AND the
--- bucket -- the two things every reach test here needs.
--
-- `Open77.players.nearby` and `Open77.zones.playersIn` are the server's proximity
-- queries and both would work, but both SEARCH: they answer "who is near this
-- point", and the question here is "how far is this one player from that one
-- point", which is one subtraction once this read has happened. The searches earn
-- their keep for a drop-off with a crowd in it; they are the wrong shape for a
-- reach test.
--
-- THE SERVER HAS NO PHYSICS WORLD, so none of this is line of sight: a player on
-- the floor above a crate is within three metres of it and nothing here can tell.
local function standing(player)
	if type(Open77.players) ~= 'table' or type(Open77.players.position) ~= 'function' then
		return nil
	end
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = coordinate(position.x), coordinate(position.y), coordinate(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = integer(position.bucket) or 0 }
end

--- A live vehicle's snapshot, or nil.
local function vehicleAt(vehicleId)
	if type(Open77.vehicles) ~= 'table' or type(Open77.vehicles.get) ~= 'function' then
		return nil
	end
	local read, snapshot = pcall(Open77.vehicles.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	-- The host nests the transform under `position` and also flattens it; either
	-- shape is legal and a build answers one of them.
	local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
	local x, y, z = coordinate(at.x), coordinate(at.y), coordinate(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { id = snapshot.id or vehicleId, record = snapshot.record, x = x, y = y, z = z }
end

--- Whether the character holding this connection may work a site.
-- JOBS IS ABSENT FROM THE SHIPPED SITES ON PURPOSE -- the owner asked for a job
-- that needs no job -- so this answers true for every site that declares none,
-- and the whole read of the character roster is skipped rather than made and
-- ignored.
local function mayWork(player, siteKey)
	local site = Access.Site(siteKey)
	if site == nil then return false, 'no_such_site' end
	if type(site.JOBS) ~= 'table' or next(site.JOBS) == nil then return true end

	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return false, 'no_character' end
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then
		return false, 'no_character'
	end
	local job = loaded.PlayerData.job
	if type(job) ~= 'table' or type(job.name) ~= 'string' then return false, 'job_required' end
	local minimum = Access.FiniteNumber(site.JOBS[job.name])
	if minimum == nil then return false, 'job_required' end
	local grade = type(job.grade) == 'table' and Access.FiniteNumber(job.grade.level) or nil
	if grade == nil or grade < minimum then return false, 'grade_too_low' end
	return true
end

--- Begins the pickup bar on a crate, if this player may have it.
--
-- THE ORDER OF THIS FUNCTION IS THE DESIGN. Everything that reads the host, asks
-- another contract or could conceivably yield happens ABOVE the claim; the claim
-- itself is table arithmetic; nothing below it can undo the fact that this player
-- won. The inventory question in particular is a contract call that goes through
-- `withBag` and really does yield, which is why it is asked before rather than
-- inside -- a yield there is the whole bug this module was written around.
local function beginPickup(player, propId)
	local crate = crates[propId]
	if crate == nil then return false, 'no_such_crate' end
	if crate.where ~= Where.GROUND then return false, 'already_claimed' end

	local allowed, refusal = mayWork(player, crate.site)
	if not allowed then return false, refusal end

	local here = standing(player)
	if here == nil then return false, 'no_position' end
	if here.bucket ~= crate.bucket then return false, 'wrong_bucket' end
	local gap = Access.GapSquared(here, crate)
	if gap == nil or gap > Access.REACH_SQ then return false, 'too_far' end

	if Claim.HeldBy(crates, player) ~= nil then return false, 'already_carrying' end

	-- Read here, one line above the claim, with nothing between. The claim hands
	-- it straight to `Open77.props.attach` as `expectedRevision` when the bar
	-- completes, so a prop something else re-bound in the meantime is refused by
	-- the host before any mutation happens.
	local revision = revisionOf(propId)

	local granted, why = Claim.Take(crates, propId, player, Step.PICKUP, revision, OPX.Now())
	if not granted then return false, why end

	announce(crate)
	return true
end

--- Begins the load bar: the carried crate into a vehicle the player is standing at.
local function beginLoad(player, vehicleId)
	local crate = Claim.HeldBy(crates, player)
	if crate == nil then return false, 'not_carrying' end
	if crate.where ~= Where.CARRIED then return false, 'not_carrying' end

	local vehicle = vehicleAt(vehicleId)
	if vehicle == nil then return false, 'no_such_vehicle' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end
	local gap = Access.GapSquared(here, vehicle)
	if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

	local ok, why = Claim.Restamp(crates, crate.id, player, Step.LOAD, OPX.Now())
	if not ok then return false, why end
	crate.pendingVehicle = vehicleId
	return true
end

--- Begins the deliver bar on a crate that is in a vehicle standing at a drop-off.
local function beginDeliver(player, propId)
	local crate = crates[propId]
	if crate == nil then return false, 'no_such_crate' end
	if crate.where ~= Where.LOADED or crate.vehicle == nil then return false, 'not_loaded' end

	local vehicle = vehicleAt(crate.vehicle)
	if vehicle == nil then return false, 'no_such_vehicle' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end
	local gap = Access.GapSquared(here, vehicle)
	if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

	-- THE VEHICLE is what has to be at the drop-off, not the player: the crate is
	-- in the bed, and a driver who parks on the pad and walks the last two metres
	-- has delivered it.
	local dropoff = nil
	for _, row in ipairs(Access.Dropoffs(crate.site)) do
		local reach = Access.GapSquared(vehicle, row)
		if reach ~= nil and reach <= row.radius * row.radius then
			dropoff = row
			break
		end
	end
	if dropoff == nil then return false, 'not_at_dropoff' end

	-- The crate has no owner while it is in a bed -- loading releases it so the
	-- loader can go and fetch another -- so the deliverer takes it for the length
	-- of the bar. `Restamp` refuses a stranger, so it is claimed and then stamped.
	crate.owner = player
	local ok, why = Claim.Restamp(crates, crate.id, player, Step.DELIVER, OPX.Now())
	if not ok then
		crate.owner = nil
		return false, why
	end
	crate.pendingDropoff = dropoff.key
	return true
end

--- The bar a begun step asks the client to draw.
local function runBar(player, crate)
	TriggerClientEvent(M.Event.RUN, player, {
		id = crate.id, step = crate.step, durationMs = Access.StepMs(crate.step),
		site = crate.site,
	})
end

--- Completes whatever the player had begun.
local function complete(player)
	local crate = Claim.HeldBy(crates, player)
	if crate == nil or crate.step == nil then return false, 'nothing_running' end

	-- THE SERVER'S CLOCK AND NOT THE CLIENT'S. `modules/progress` counts down on
	-- the player's own machine, so the arrival of a `finish` proves only that a
	-- client sent one. The stamp is the rule.
	if Claim.TooSoon(crate, OPX.Now(), Access.StepMs(crate.step),
		Access.CLOCK_TOLERANCE_MS) then
		return false, 'too_soon'
	end

	local step = crate.step

	if step == Step.PICKUP then
		local carry = Access.Carry()
		if carry == nil then return false, 'no_carry_config' end
		-- The reach is checked AGAIN, because the bar took seconds and the player
		-- could have walked away during it. The claim is theirs either way; what
		-- this refuses is finishing a pickup from across the yard.
		local here = standing(player)
		if here == nil then return false, 'no_position' end
		local gap = Access.GapSquared(here, crate)
		if gap == nil or gap > Access.REACH_SQ then return false, 'too_far' end

		-- THE COMPARE-AND-SWAP. `expectedRevision` is the revision read one line
		-- above the claim: a prop something else re-bound while the bar ran is
		-- refused here, before any mutation, rather than producing a carry over a
		-- stale binding.
		local attached, why = hostCall(Open77.props.attach, crate.id, {
			parentType = 'player',
			parentId = player,
			bone = carry.bone,
			offset = carry.offset,
			rotation = carry.rotation,
		}, crate.revision)
		if not attached then
			-- RELEASED RATHER THAN KEPT. A claim whose attach was refused is a crate
			-- nobody can see in anybody's hands and that nobody else may take; that
			-- is strictly worse than the crate standing on its point.
			Claim.Release(crates, crate.id, player)
			announce(crate)
			-- THE HOST'S OWN WORDS GO TO THE JOURNAL, NOT TO THE CLIENT. What
			-- `Open77.props.attach` answers is the platform's vocabulary and it
			-- grows with the build -- `invalid_attachment_parent`,
			-- `invalid_attachment_bone`, whatever comes next -- and the client has
			-- a sentence for none of it. Handing it over made the refusal a
			-- description of our own internals that a player reads as gibberish
			-- and an attacker reads as a map. One stable code out, the detail in.
			Open77.log.warn(('[hauling] crate %s would not attach to player %d: %s')
				:format(safe(crate.id), player, safe(why)))
			return false, 'attach_refused'
		end
		crate.where = Where.CARRIED
		crate.step = nil
		crate.revision = revisionOf(crate.id) or crate.revision
		announce(crate)
		return true
	end

	if step == Step.LOAD then
		local vehicleId = crate.pendingVehicle
		local vehicle = vehicleAt(vehicleId)
		if vehicle == nil then return false, 'no_such_vehicle' end
		local here = standing(player)
		if here == nil then return false, 'no_position' end
		local gap = Access.GapSquared(here, vehicle)
		if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

		local n = (bedCount[vehicleId] or 0) + 1
		local slot = Access.BedSlot(vehicle.record, n)
		if slot == nil then return false, 'no_bed_slot' end

		-- The bucket is NOT checked here: `Open77.props.attach` refuses a parent in
		-- another bucket itself, with `invalid_attachment_parent`, and the host's
		-- own answer is better than a second reading of a bucket the vehicle
		-- snapshot does not reliably carry.
		local attached, why = hostCall(Open77.props.attach, crate.id, {
			parentType = 'vehicle', parentId = vehicleId, bone = '',
			offset = { x = slot.x, y = slot.y, z = slot.z },
			rotation = { x = 0.0, y = 0.0, z = slot.yaw },
		}, crate.revision)
		if not attached then
			-- As on the pickup path: the host's reason is for the operator.
			Open77.log.warn(('[hauling] crate %s would not attach to vehicle %s: %s')
				:format(safe(crate.id), safe(vehicleId), safe(why)))
			return false, 'attach_refused'
		end
		bedCount[vehicleId] = n
		crate.where = Where.LOADED
		crate.vehicle = vehicleId
		crate.pendingVehicle = nil
		crate.step = nil
		crate.claimedAtMs = nil
		-- OWNERSHIP IS RELEASED BY LOADING, on purpose: the crate is in a bed now,
		-- the loader's hands are free to fetch another, and whoever drives it to
		-- the drop-off is the one who delivers it. That is the convoy, and it comes
		-- out of this one line.
		crate.owner = nil
		crate.revision = revisionOf(crate.id) or crate.revision
		announce(crate)
		return true
	end

	if step == Step.DELIVER then
		local dropoff = Access.Dropoff(crate.site, crate.pendingDropoff)
		if dropoff == nil then return false, 'not_at_dropoff' end
		local vehicle = vehicleAt(crate.vehicle)
		if vehicle == nil then return false, 'no_such_vehicle' end
		local reach = Access.GapSquared(vehicle, dropoff)
		if reach == nil or reach > dropoff.radius * dropoff.radius then
			return false, 'not_at_dropoff'
		end

		local pay = Access.Pay(crate.site)
		local character = OPX.Api.Get('character')
		if character == nil or type(character.AddMoney) ~= 'function' then
			return false, 'no_character'
		end
		-- NOTHING BETWEEN THE PAY AND THE RETIRE MAY YIELD. The rule
		-- `claim.lua`'s header states for `Claim.Take` applies to this window for
		-- the same reason and with a worse consequence: `AddMoney` is the last
		-- yield, and from the line after it to `retire` the crate is still
		-- claimed, still owned, and already paid for. A yield in there -- a log
		-- that awaits, a notify that round-trips, a second contract call -- lets
		-- another `FINISH` for the same crate through the `TooSoon` window and
		-- pays the same delivery twice. `retire` is the only thing that takes the
		-- crate out of reach, so it must be the very next thing that happens.
		--
		-- PAID BEFORE THE CRATE IS RETIRED, and that order is deliberate. The
		-- other one loses a crate and pays nothing when the money call refuses,
		-- and there is then nothing left to retry with -- the crate is gone and
		-- so is the evidence.
		--
		-- `AddMoney` answers `(boolean, localeKey)` and NOT a Result, which is the
		-- convention this contract alone uses; `pcall` in front of it because a
		-- non-table answer from a foreign contract raises at the call site, and the
		-- one place that must not happen is between a delivery and its pay.
		local called, paid, why = pcall(character.AddMoney, player, Access.CURRENCY, pay,
			('hauling:%s:%s'):format(tostring(crate.site), tostring(dropoff.key)))
		if not called or paid ~= true then
			Open77.log.warn(('[hauling] player %d delivered to %s and was not paid: %s')
				:format(player, safe(dropoff.key), safe(called and why or paid)))
			return false, 'not_paid'
		end
		retire(crate, ('delivered to %s by player %d'):format(tostring(dropoff.key), player))
		OPX.NotifyLocale(player, 'hauling.paid',
			{ amount = pay, dropoff = dropoff.label }, 'success')
		return true
	end

	return false, 'nothing_running'
end

--- Ends whatever the player had begun, without completing it.
local function abort(player, reason)
	local crate = Claim.HeldBy(crates, player)
	if crate == nil then return end
	if crate.where == Where.CLAIMED then
		Claim.Release(crates, crate.id, player)
		crate.pendingVehicle = nil
		announce(crate)
		return
	end
	if crate.where == Where.LOADED then
		-- A deliver bar that ended: hand the crate back to the bed rather than to
		-- the player, which is where it physically still is.
		crate.owner = nil
		crate.step = nil
		crate.claimedAtMs = nil
		crate.pendingDropoff = nil
		announce(crate)
		return
	end
	crate.step = nil
	crate.claimedAtMs = nil
	crate.pendingVehicle = nil
	announce(crate)
	Open77.log.debug(('[hauling] player %d ended a bar early: %s'):format(player, safe(reason)))
end

--- Forgets a departing player and stands their crate back up.
--
-- A LOADED CRATE IS LEFT ALONE. It is in a vehicle, not in their hands, and the
-- truck it is in is still there for whoever drives it. Only a reservation and a
-- carry belong to the connection that left.
local function forget(playerId)
	local player = tonumber(playerId) or 0
	if player <= 0 then return end
	requestWindows[player] = nil
	logWindows[player] = nil
	told[player] = nil

	for _, crate in pairs(crates) do
		if crate.owner == player then
			if crate.where == Where.CARRIED then
				putBack(crate, 'the carrier disconnected')
			elseif crate.where == Where.LOADED then
				-- ONLY THE NAME COMES OFF, and `Claim.Release` is deliberately not
				-- used: it sets `where` back to `ground`, which for a crate bolted
				-- into a truck's bed is a lie the refill pass then acts on -- it would
				-- count the crate's point as occupied by a crate that is three
				-- districts away, and the drop-off row would vanish from the driver's
				-- eye mid-run. A delivery bar owns the crate only for its own length.
				crate.owner = nil
				crate.step = nil
				crate.claimedAtMs = nil
				crate.pendingDropoff = nil
				announce(crate)
			else
				Claim.Release(crates, crate.id, player)
				crate.pendingVehicle = nil
				crate.pendingDropoff = nil
				announce(crate)
			end
		end
	end
end

--- Creates one crate at each site's first point to find out whether its model is
--- a model the engine knows.
--
-- THE ONLY WAY TO VALIDATE AN ALIAS ON THE SERVER. `Open77.props.catalog()` is
-- always an empty table here, so there is no list to check against and a typo'd
-- alias is otherwise a site whose crates silently never appear -- which looks
-- exactly like a site nobody has visited. This turns that into one loud line at
-- boot and a site that is switched off rather than left pretending.
local function probe()
	for _, siteKey in ipairs(Access.UsableKeys()) do
		local id, reason = spawn(siteKey, 1)
		if id == nil then
			if reason == 'unknown_alias' or reason == 'invalid_model' then
				Access.Condemn(siteKey)
				Open77.log.error(('[hauling] SITE %s IS DISABLED: the engine does not know the ' ..
					'model %q. A MODEL must be a curated prop alias and never a .mesh path -- a ' ..
					'raw mesh renders as placeholder geometry AND cannot be attached at all, so ' ..
					'the pickup would appear to work and nothing would ever be carried')
					:format(safe(siteKey), safe(Access.Model(siteKey))))
			else
				Open77.log.warn(('[hauling] %s: the boot crate was refused (%s); the refill pass ' ..
					'will try again'):format(safe(siteKey), safe(reason)))
			end
		end
	end
end

--- Answers what this server has standing, by site. For the diagnostic.
-- @author dop42
-- @return Result
local function state()
	local sites = {}
	for _, siteKey in ipairs(Access.UsableKeys()) do
		sites[siteKey] = { standing = 0, claimed = 0, carried = 0, loaded = 0 }
	end
	for _, crate in pairs(crates) do
		local row = sites[crate.site]
		if row ~= nil then
			row.standing = row.standing + 1
			if crate.where == Where.CLAIMED then row.claimed = row.claimed + 1 end
			if crate.where == Where.CARRIED then row.carried = row.carried + 1 end
			if crate.where == Where.LOADED then row.loaded = row.loaded + 1 end
		end
	end
	return OPX.Result.Ok({ sites = sites, total = crateCount() })
end

--- Builds the crate registry and declares the operator numbers.
-- @author dop42
function M.Init()
	crates, cooling, bedCount, told = {}, {}, {}, {}
	requestWindows, logWindows = {}, {}

	OPX.Tune.Declare{
		HAUL_REFILL_MS = { value = Access.REFILL_MS, type = 'integer', min = 1000, max = 600000,
			unit = 'ms', apply = 'live', label = 'Crate refill interval', group = 'Hauling',
			order = 1,
			description = 'How often the hauling pass reaps expired claims and puts new crates ' ..
				'on free points.' },
		HAUL_PAY_PER_CRATE = { value = Access.PAY_PER_CRATE, type = 'integer', min = 0,
			max = 100000, apply = 'live', label = 'Pay per crate', group = 'Hauling', order = 2,
			description = 'What one delivered crate pays at a site that names no PAY of its own.' },
	}
end

--- Publishes the server half of the hauling contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('hauling', 1, {
		State = state,
	})
end

--- Wires the requests, the host events and the refill pass.
-- @author dop42
function M.Start()
	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[hauling] config: ' .. line)
	end

	if not propsReady() then
		Open77.log.error('[hauling] the world prop API is unavailable; no crate will be created')
		return
	end

	RegisterNetEvent(M.Event.HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return
		end
		told[player] = true
		sendSnapshot(player)
		answer(player, true, nil)
	end)

	RegisterNetEvent(M.Event.BEGIN, function(step, subject)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end

		-- THE SUBJECT IS A NAME, and a name is a string or a number. Everything
		-- below hands it to a host native or to a format string, and a client is
		-- free to put a table on the wire: `Open77.vehicles.get({})` is a raise
		-- inside a network handler, which takes the handler down for the rest of the
		-- request rather than refusing one player.
		if type(subject) ~= 'string' and type(subject) ~= 'number' then
			return answer(player, false, 'invalid_subject')
		end

		local ok, reason
		if step == Step.PICKUP then
			ok, reason = beginPickup(player, subject)
		elseif step == Step.LOAD then
			ok, reason = beginLoad(player, subject)
		elseif step == Step.DELIVER then
			ok, reason = beginDeliver(player, subject)
		else
			ok, reason = false, 'unknown_step'
		end

		if ok then
			local crate = Claim.HeldBy(crates, player)
			if crate ~= nil then runBar(player, crate) end
		end
		answer(player, ok, reason)
		if not ok and within(logWindows, player, 1, 1000) then
			Open77.log.info(('[hauling] player %d refused %s on %s: %s'):format(player,
				safe(step), safe(subject), safe(reason)))
		end
	end)

	RegisterNetEvent(M.Event.FINISH, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end
		local ok, reason = complete(player)
		answer(player, ok, reason)
		if not ok and within(logWindows, player, 1, 1000) then
			Open77.log.info(('[hauling] player %d could not finish: %s'):format(player,
				safe(reason)))
		end
	end)

	RegisterNetEvent(M.Event.ABORT, function(reason)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		abort(player, tostring(reason))
		answer(player, true, 'aborted')
	end)

	-- THE AUTHORITATIVE END OF A CARRY. Death, disconnect, parent removal and a
	-- bucket change all detach a prop without this module being asked, and this
	-- event is the only thing that reports all four. `current` nil is the prop
	-- coming loose; anything else is a rebinding we asked for.
	AddEventHandler(M.PROP_ATTACHMENT_CHANGED, function(id, current, _, reason, revision)
		local crate = crates[id]
		if crate == nil then return end
		local fresh = integer(revision)
		if fresh ~= nil then crate.revision = fresh end
		if current ~= nil then return end
		if crate.where ~= Where.CARRIED and crate.where ~= Where.LOADED then return end
		putBack(crate, ('the attachment ended (%s)'):format(safe(reason)))
	end)

	AddEventHandler(M.PROP_REMOVED, function(id, reason)
		local crate = crates[id]
		if crate == nil then return end
		-- The host dropped a crate this module still thought it had. Forget it and
		-- let the point cool, rather than leaving a record nothing can ever satisfy.
		retire(crate, ('the host removed it (%s)'):format(safe(reason)))
	end)

	-- GETTING INTO A CAR IS NOT A WAY TO LOAD A CRATE. The platform detaches on
	-- death, disconnect, parent removal and bucket change -- and a seat is none of
	-- those, so without this the carrier keeps the crate stuck to their chest
	-- inside the cabin and drives off with it, bypassing the load action that is
	-- the only thing that puts the crate in the bed where everybody can see it.
	AddEventHandler(M.PLAYER_ENTERED_VEHICLE, function(playerId)
		local player = tonumber(playerId) or 0
		if player <= 0 then return end
		local crate = Claim.HeldBy(crates, player)
		if crate == nil or crate.where ~= Where.CARRIED then return end
		putBack(crate, ('player %d got into a vehicle while carrying it'):format(player))
		answer(player, false, 'carry_dropped')
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)

	-- The boot probe, on a thread: `Start` may yield and the probe is a host call
	-- per site, which is work that has no business delaying the rest of the phase.
	CreateThread(function()
		local ok, failure = pcall(probe)
		if not ok then
			Open77.log.error('[hauling] the boot crate probe failed: ' .. tostring(failure))
		end
	end)

	-- `integer|function`, and a function is re-read EVERY PASS, which is the whole
	-- reason the tunable is worth declaring: an operator retunes the spawn rate
	-- from the panel and the next pass uses it. The client half of `Every` takes a
	-- number only and raises on a function; this is the server half.
	refillJob = OPX.Scheduler.Every('hauling:refill', function()
		return OPX.Tune.Number('HAUL_REFILL_MS', Access.REFILL_MS)
	end, refillOnce)

	local keys = Access.UsableKeys()
	if #keys == 0 then
		Open77.log.error('[hauling] NOT ONE SITE IS USABLE, so no crate will ever appear. ' ..
			'The lines above say why; the shipped sites are placeholders and every position ' ..
			'in config/hauling.lua has to be surveyed in game before this job exists')
		return
	end
	Open77.log.info(('[hauling] ready: %d site(s) -- %s'):format(#keys, table.concat(keys, ', ')))
end

--- Stops the refill pass and stands every carried crate back up.
-- @author dop42
function M.Stop()
	if refillJob ~= nil then
		OPX.Scheduler.Cancel(refillJob)
		refillJob = nil
	end
	for _, crate in pairs(crates) do
		if crate.where == Where.CARRIED or crate.where == Where.LOADED then
			pcall(putBack, crate, 'the resource stopped')
		end
	end
end
