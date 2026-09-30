--- Server half of the watch: an aircraft's authority, its canonical moves, and
--- where each viewer says it DRAWS it.
-- @author XEROX710
--
-- WHY THIS EXISTS. The owner, 2026-09-30: "the av is driving away on other
-- player screen going through buildings but when i move it comes back to same
-- spot on other play screen". The pilot's own client log of that flight is the
-- log of the screen that was RIGHT, the platform's vehicle authority service
-- writes no line of its own, and nothing in this resource journalled an
-- aircraft's physics owner, its epoch or a viewer's picture of it -- so a drift
-- on somebody else's screen left no evidence anywhere `logs.cmd` reaches. This
-- file is that evidence, in the one journal every test already collects:
--
--   * AUTHORITY: every `onVehicleAuthorityChanged` of an aircraft -- who
--     simulates it now, the epoch, the platform's reason, who is seated -- with
--     a per-hull ceiling so a hull two controllers fight over is a count, not a
--     flood;
--   * JUMPS: a canonical move between two scans bigger than `JUMP_METRES`,
--     which no AV flies (the platform caps boost at 34 m/s), on a hull nobody
--     froze -- a frozen hull is one a server is posing on purpose;
--   * SIGHTS: a client that draws an aircraft it does not simulate far from
--     where its last sample put it says so (`client/main.lua`, the watch); the
--     line written here puts the server's own reads beside that word.
--
-- THE ONE THING IT DOES, AND ONLY FOR AN EMPTY HULL. A sight of an EMPTY,
-- unfrozen aircraft drawn far from where the SERVER has it is answered by
-- re-publishing the hull where it stands: `setTransform` to its own canonical
-- position and heading, which is the platform's documented way to put one pose
-- in front of every viewer ("revokes an active physics lease, advances the
-- authority epoch and republishes the complete canonical transform to every
-- current viewer", `wiki/vehicles.md`), and an epoch change makes every
-- observer drop its buffered path. Nothing moves that was not already there
-- on the server. A hull with anybody aboard is never touched: a seated
-- pilot's lease is theirs, and a server pose would fight it (the fight
-- `modules/ncpd/server/av.lua` documents).

local M = OPX.Modules.Get('avdoor')

M.Watch = {}
local Watch = M.Watch

-- The last scan's aircraft, `{ id, at, bucket, entry }`, so a sight is matched
-- against what the server already listed instead of a host call per report.
local listed = {}

-- Where each hull was at the last scan, by id as text: `{ at, t }`.
local lastSeen = {}

-- Authority lines per hull: `{ windowStart, count, suppressed }`.
local authority = {}

-- When each hull was last healed, by id as text.
local healed = {}

-- Open sights per reporter and hull, `player|id` -> `{ since, worst }`, so a
-- client that never sends its `closed` does not hold memory forever.
local sights = {}

-- The handler registrations are made once per start.
local started = false

-- How many authority lines one hull may write in `AUTHORITY_WINDOW_MS`.
local AUTHORITY_LINES = 6
local AUTHORITY_WINDOW_MS = 10000

-- A reporter must be within this of the hull the server has: the platform
-- streams a vehicle to 425 m, and a client cannot draw what it was never sent.
local SIGHT_REACH = 450.0

-- A coordinate a client may report: the platform's own validation bound.
local MAX_COORDINATE = 1000000.0

local function settings()
	return M.WatchSettings()
end

local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

--- A point out of a table with `x/y/z` (or a nested `position`), or nil.
local function pointOf(value)
	if type(value) ~= 'table' then return nil end
	local at = type(value.position) == 'table' and value.position or value
	local x, y, z = finite(at.x), finite(at.y), finite(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- A point a CLIENT sent: finite and inside the world.
local function reported(value)
	local at = pointOf(value)
	if at == nil then return nil end
	if math.abs(at.x) > MAX_COORDINATE or math.abs(at.y) > MAX_COORDINATE
		or math.abs(at.z) > MAX_COORDINATE then
		return nil
	end
	return at
end

local function apart(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The id as the text every table here is keyed by.
local function keyOf(id)
	return M.DecimalId(id) or tostring(id)
end

local function sameHull(a, b)
	if a == nil or b == nil then return false end
	local x, y = M.DecimalId(a), M.DecimalId(b)
	if x ~= nil and y ~= nil then return x == y end
	return tostring(a) == tostring(b)
end

--- Who sits where, as `2:seat_front_left, 5:seat_back_left`, or `nobody`.
local function seatedOf(snapshot)
	local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
	if type(occupants) ~= 'table' then return 'nobody', 0 end
	local parts = {}
	for _, occupant in ipairs(occupants) do
		if type(occupant) == 'table' and occupant.playerId ~= nil then
			parts[#parts + 1] = ('%s:%s%s'):format(tostring(occupant.playerId),
				tostring(M.SeatName(occupant.seat) or occupant.seat),
				occupant.exiting == true and '(leaving)' or '')
		end
	end
	if #parts == 0 then return 'nobody', 0 end
	return table.concat(parts, ', '), #parts
end

--- Whether the server has the hull frozen. The platform's own read first, the
--- raw bit (`flags.frozen`) when that read is absent.
local function frozenOf(snapshot, id)
	local api = Open77.vehicles
	if type(api) == 'table' and type(api.isFrozen) == 'function' then
		local read, answer = pcall(api.isFrozen, id)
		if read and type(answer) == 'boolean' then return answer end
	end
	if type(snapshot) == 'table' and snapshot.frozen ~= nil then return snapshot.frozen == true end
	local flags = type(api) == 'table' and type(api.flags) == 'table' and tonumber(api.flags.frozen) or nil
	local bits = type(snapshot) == 'table' and tonumber(snapshot.flags) or nil
	if flags ~= nil and bits ~= nil and flags == math.floor(flags) and bits == math.floor(bits) then
		return (math.floor(bits) & math.floor(flags)) ~= 0
	end
	return false
end

--- A snapshot's owner and epoch, as the journal spells them.
local function ownerText(snapshot)
	if type(snapshot) ~= 'table' then return 'owner ?, epoch ?' end
	local owner = tonumber(snapshot.physicsOwner)
	return ('owner %s, epoch %s'):format(
		(owner == nil and '?') or (owner == 0 and 'nobody') or ('player ' .. tostring(owner)),
		tostring(snapshot.authorityEpoch or '?'))
end

--- The full canonical snapshot of a listed hull.
local function snapshotOf(id)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, id)
	if read and type(snapshot) == 'table' then return snapshot end
	return nil
end

--- The listed hull a report names, or nil.
local function listedHull(raw)
	if raw == nil then return nil end
	for _, hull in ipairs(listed) do
		if sameHull(hull.id, raw) then return hull end
	end
	return nil
end

--- Forgets everything. Shared by `Init` and `Stop`. The two registrations
--- `Watch.Start` made stay: a host handler cannot be taken back, and a second
--- registration after a restart would write every line twice.
function Watch.Reset()
	listed, lastSeen, authority, healed, sights = {}, {}, {}, {}, {}
end

--- One scan's aircraft, measured against the last one: a canonical move no
--- aircraft flies is a line. Called by `M.Scan` with the list it already read.
-- @param hulls table[] `{ id, at, bucket, entry }`
-- @param now number|nil
-- @return integer how many jumps were journalled
function Watch.Observe(hulls, now)
	local watch = settings()
	if watch.off or type(hulls) ~= 'table' then return 0 end
	now = now or OPX.Now()
	listed = hulls
	local present, jumps = {}, 0
	local ceiling = 2 * math.floor(M.Number(M.Settings and M.Settings.SCAN_MS, 100, 5000, 500))
	for _, hull in ipairs(hulls) do
		local key = keyOf(hull.id)
		present[key] = true
		local was = lastSeen[key]
		if was ~= nil and now - was.t <= ceiling and hull.at ~= nil then
			local moved = apart(was.at, hull.at)
			if moved > watch.jump then
				local snapshot = hull.entry or snapshotOf(hull.id)
				if not frozenOf(snapshot, hull.id) then
					jumps = jumps + 1
					Open77.log.warn(('[avdoor] jump: aircraft %s moved %.1f m in %.1f s on the server '
						.. '(%s, seated %s): %.1f, %.1f, %.1f -> %.1f, %.1f, %.1f')
						:format(key, moved, (now - was.t) / 1000.0, ownerText(snapshot),
							(seatedOf(snapshot)), was.at.x, was.at.y, was.at.z,
							hull.at.x, hull.at.y, hull.at.z))
				end
			end
		end
		if hull.at ~= nil then lastSeen[key] = { at = hull.at, t = now } end
	end
	for key in pairs(lastSeen) do
		if not present[key] then lastSeen[key] = nil end
	end
	for key in pairs(healed) do
		if not present[key] then healed[key] = nil end
	end
	for key in pairs(authority) do
		if not present[key] then authority[key] = nil end
	end
	return jumps
end

--- An aircraft's physics owner changed: one line, with the platform's reason
--- and who is seated. Raised by the platform with every argument as text.
-- @param rawId any
-- @param owner any
-- @param epoch any
-- @param reason any
-- @return boolean whether a line was written
function Watch.Authority(rawId, owner, epoch, reason)
	local watch = settings()
	if watch.off or rawId == nil then return false end
	local snapshot = snapshotOf(rawId)
	if snapshot == nil and tonumber(rawId) ~= nil then snapshot = snapshotOf(tonumber(rawId)) end
	if snapshot == nil or not M.IsAircraft(snapshot.record) then return false end
	local key = keyOf(rawId)
	local now = OPX.Now()
	local book = authority[key]
	if book == nil or now - book.windowStart >= AUTHORITY_WINDOW_MS then
		if book ~= nil and book.suppressed > 0 then
			Open77.log.info(('[avdoor] authority: aircraft %s changed hands %d more time(s) in the last %.0f s')
				:format(key, book.suppressed, AUTHORITY_WINDOW_MS / 1000.0))
		end
		book = { windowStart = now, count = 0, suppressed = 0 }
		authority[key] = book
	end
	book.count = book.count + 1
	if book.count > AUTHORITY_LINES then
		book.suppressed = book.suppressed + 1
		return false
	end
	local who = tonumber(owner)
	local at = pointOf(snapshot)
	Open77.log.info(('[avdoor] authority: aircraft %s is simulated by %s now (epoch %s, %s); seated %s%s; '
		.. 'at %s')
		:format(key, (who == nil and tostring(owner)) or (who == 0 and 'nobody') or ('player ' .. tostring(who)),
			tostring(epoch), tostring(reason or '?'), (seatedOf(snapshot)),
			frozenOf(snapshot, rawId) and ', FROZEN' or '',
			at ~= nil and ('%.1f, %.1f, %.1f'):format(at.x, at.y, at.z) or '?'))
	return true
end

--- A client's word about where it draws an aircraft it does not simulate.
--
-- CHECKED BEFORE IT IS BELIEVED, and believed only as far as a log line and
-- the one heal: the hull must be one the server listed, in the reporter's
-- bucket, within streaming reach of the reporter's body; every number must be
-- finite and in the world. The heal re-publishes the SERVER's pose, never the
-- client's, so a client that lies can at worst make an empty hull be
-- re-published where it already is, once per `HEAL_EVERY_MS`.
-- @param playerId number
-- @param payload table
-- @return string what was done: `ignored`, `logged`, `healed`
function Watch.Sight(playerId, payload)
	local watch = settings()
	if watch.off or type(payload) ~= 'table' then return 'ignored' end
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return 'ignored' end
	local state = payload.state
	if state ~= 'open' and state ~= 'still' and state ~= 'closed' then return 'ignored' end
	local raw = payload.id
	if (type(raw) ~= 'string' and type(raw) ~= 'number') or #tostring(raw) > 24 then return 'ignored' end
	local hull = listedHull(raw)
	if hull == nil or hull.at == nil then return 'ignored' end
	local key = keyOf(hull.id)

	local players = Open77.players
	local body, bucket = nil, 0
	if type(players) == 'table' and type(players.position) == 'function' then
		local read, at = pcall(players.position, playerId)
		if read and type(at) == 'table' then
			body = pointOf(at)
			bucket = tonumber(at.bucket) or 0
		end
	end
	if body == nil or bucket ~= hull.bucket or apart(body, hull.at) > SIGHT_REACH then return 'ignored' end

	local drawn = reported(payload.drawn)
	local sampled = reported(payload.sampled)
	if drawn == nil then return 'ignored' end
	local worst = finite(payload.worst)
	local seconds = finite(payload.seconds)
	local sightKey = tostring(playerId) .. '|' .. key

	local snapshot = snapshotOf(hull.id) or hull.entry
	local server = pointOf(snapshot) or hull.at
	local fromServer = apart(drawn, server)
	local seatedText, seatedCount = seatedOf(snapshot)
	local frozen = frozenOf(snapshot, hull.id)

	if state == 'closed' then
		sights[sightKey] = nil
		Open77.log.info(('[avdoor] sight: player %d draws aircraft %s where the server has it again '
			.. '(%.1f m off) after %s, %s at worst'):format(playerId, key, fromServer,
			seconds ~= nil and ('%.1f s'):format(math.max(0, seconds)) or '?',
			worst ~= nil and ('%.1f m'):format(math.max(0, worst)) or '?'))
		return 'logged'
	end

	sights[sightKey] = sights[sightKey] or { since = OPX.Now() }
	local clientOwner = tonumber(payload.owner)
	local clientEpoch = tonumber(payload.epoch)
	local age = finite(payload.sampleAgeMs)
	Open77.log.warn(('[avdoor] sight: player %d draws aircraft %s %.1f m from where the server has it%s '
		.. '(%s). Server: %s, seated %s%s, speed %.1f m/s, at %.1f, %.1f, %.1f. Client: %s, %s epoch %s%s%s%s, '
		.. 'drawn %.1f, %.1f, %.1f%s')
		:format(playerId, key, fromServer,
			state == 'still' and ' still' or '',
			state == 'still' and (seconds ~= nil and ('%.0f s so far, %.1f m at worst'):format(seconds, worst or 0)
				or 'still') or 'new',
			ownerText(snapshot), seatedText, frozen and ', FROZEN' or '',
			finite(snapshot and snapshot.speed) or 0.0, server.x, server.y, server.z,
			payload.seated == true and 'seated in it' or 'on foot or elsewhere',
			clientOwner == nil and 'owner ?' or (clientOwner == 0 and 'owner nobody'
				or ('owner player ' .. tostring(clientOwner))),
			clientEpoch == nil and '?' or tostring(clientEpoch),
			payload.frozen == true and ', frozen' or '',
			age ~= nil and (', last sample %.0f ms old'):format(age) or '',
			payload.extrapolating == true and ', extrapolating' or '',
			drawn.x, drawn.y, drawn.z,
			sampled ~= nil and (', its own last sample %.1f m from the server\'s'):format(apart(sampled, server))
				or ''))

	-- THE HEAL: an empty, unfrozen hull that a viewer draws far from the
	-- server's pose is re-published where the server has it.
	if not watch.heal or seatedCount > 0 or frozen then return 'logged' end
	if fromServer <= M.DriftLimit(watch, 0.0) then return 'logged' end
	local now = OPX.Now()
	if healed[key] ~= nil and now - healed[key] < watch.healEvery then return 'logged' end
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.setTransform) ~= 'function' then return 'logged' end
	local heading = finite(snapshot and (snapshot.heading or snapshot.yaw)) or 0.0
	healed[key] = now
	-- `yaw` is passed on purpose: the platform's `setTransform` reads an absent
	-- heading as 0, not as "keep the current one".
	local called, moved, why = pcall(api.setTransform, hull.id,
		{ x = server.x, y = server.y, z = server.z, yaw = heading })
	if called and moved == true then
		Open77.log.info(('[avdoor] heal: aircraft %s re-published where the server has it (%.1f, %.1f, %.1f, '
			.. 'heading %.0f) because player %d drew it %.1f m away with nobody aboard')
			:format(key, server.x, server.y, server.z, heading, playerId, fromServer))
		return 'healed'
	end
	Open77.log.warn(('[avdoor] heal: aircraft %s could not be re-published: %s')
		:format(key, tostring(called and (why or moved) or moved)))
	return 'logged'
end

--- A reporter left: its open sights go with it.
-- @param playerId number
function Watch.Forget(playerId)
	local prefix = tostring(tonumber(playerId) or playerId) .. '|'
	for sightKey in pairs(sights) do
		if sightKey:sub(1, #prefix) == prefix then sights[sightKey] = nil end
	end
end

--- Wires the platform's authority event and the sight report.
function Watch.Start()
	if started then return end
	started = true
	AddEventHandler(OPX.Host.VEHICLE_AUTHORITY_CHANGED, function(id, owner, epoch, reason)
		local ran, failure = pcall(Watch.Authority, id, owner, epoch, reason)
		if not ran then
			Open77.log.error('[avdoor] an authority change could not be read: ' .. tostring(failure))
		end
	end)
	RegisterNetEvent(M.Event.SIGHT, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- The client sends at most one report per look (`SIGHT_MS`), so a tighter
		-- pace than that is not a client of ours.
		if OPX.Cooling(player, 'avdoor.sight', 300) then return end
		local ran, failure = pcall(Watch.Sight, player, payload)
		if not ran then
			Open77.log.error('[avdoor] a sight report could not be read: ' .. tostring(failure))
		end
	end)
end

--- How many hulls and sights this half holds, for the suite and the console.
function Watch.Status()
	local open = 0
	for _ in pairs(sights) do open = open + 1 end
	local seen = 0
	for _ in pairs(lastSeen) do seen = seen + 1 end
	return { hulls = #listed, seen = seen, sights = open }
end
