--- Client half: the row at an aircraft's door, the key, the exit -- the fade and
--- the guard that stands the body beside the door -- and the MaxTac AV's voice
--- for everybody near it.
-- @author XEROX710
--
-- THE ROW IS THE SERVER'S WORD. The server is the only side that knows where
-- an aircraft stands (a client vehicle snapshot carries no world position), so
-- it measures this body against every aircraft in its bucket and says which
-- door, if any, is open to it (`DOOR`). The row is drawn from that word and
-- taken down the moment the body is seated or a menu holds the keyboard; the
-- key sends the hull's id and nothing else, and the server judges it again
-- from scratch. The server swings the seat's door before it seats the body, so
-- the press is answered (`BOARDED`) about half a second later.
--
-- THE EXIT. The platform carries the body out of an AV in one cut (its
-- animated exit crashed the game and is switched off in its own client) and,
-- measured in the client log of 2026-09-29, it does so INSIDE the hull: the
-- engine drops the body at the cockpit's exit point, the chassis wakes and
-- knocks the body down at +0.4 s, and the platform's own deferred eject sets
-- it 3.5 m behind and 2 m UNDER the hull's centre at about +1.7 s. So the
-- moment a seat in an aircraft starts to empty this half
--   1. covers the screen with the native quest fade (`EXIT_FADE`);
--   2. puts the body on the ground beside its seat's door, on the ground the
--      static ray finds there, and puts it back if the platform moves it
--      (`EXIT`, the guard);
--   3. keeps the screen covered until the body has been still for
--      `EXIT.SETTLE_MS` -- the player never sees a throw or an eject.
-- The server opens that door for everybody as the seat empties.
--
-- THE VOICE. While this client is the one flying a MaxTac AV (its seat is in
-- the hull and the hull is simulated here), the flight is read four times a
-- second -- the seated body's height over the ground under it
-- (`Open77.world.groundZ`) and the climb rate -- and the three moments the
-- base game gives that aircraft a voice for (lifting off, coming down to land,
-- touching down) are sent to the server, which sends every listener near the
-- hull the sound to play on the airframe -- this pilot included. Every
-- listener's client answers what it did with the sound (`PLAYED`), and the
-- answers are the server's evidence of who heard it.

local M = OPX.Modules.Get('avdoor')

local OWNER = 'avdoor'
local GROUP = 'door'

-- The door the server last named for this body, and the row as drawn.
local door = nil
local shown, shownLabel = false, nil
local keyRegistered = false
local reportedStrip = false

-- The seat this client held on the last read, and the fade that covers an exit.
local lastSeat = nil
local fading = nil

-- The exit guard (its state and its 50 ms job), and when the last exit ended,
-- so a seat the platform keeps flagged as leaving is one exit and not a loop of
-- fades.
local guard = nil
local guardJob = nil
local lastExit = nil

-- When the last press was sent, so a second press while the door swings is the
-- same press.
local askedAt = nil

-- Which vehicle ids are aircraft (and MaxTac voices), memoised per id.
local kinds = {}

-- The flight as last read, for the voice, and when it was last read.
local flight = nil
local flightAt = 0

-- Which events have already been said in the log, so a missing sound is one
-- line and not one per landing.
local heard = {}

-- The one scheduler job.
local watchJob = nil

-- How often the flight is read while this client flies a MaxTac AV.
local FLIGHT_MS = 250

-- The guard's pace, and how it judges a body it has moved: within this far of
-- the place it was put the move has landed; a placement that has not landed
-- after `PLACE_WAIT_MS` is made again; and it is made at most `MAX_PLACEMENTS`
-- times, so something else that keeps moving the body is not fought forever.
local GUARD_MS = 50
local ARRIVE_METRES = 1.5
local PLACE_WAIT_MS = 150
local MAX_PLACEMENTS = 8

-- How long after a press a second one is the same press.
local ASK_HOLD_MS = 1200

-- How long a seat the platform keeps flagged as leaving is still the exit that
-- began it: a second `leaving` for the same hull inside this is not a second
-- fade and a second placement.
local EXIT_HOLD_MS = 5000

local function settings()
	return type(M.Settings) == 'table' and M.Settings or {}
end

local function keySettings()
	local declared = settings().KEY
	if type(declared) == 'table' and type(declared.ID) == 'string' and declared.ID ~= ''
		and type(declared.NAME) == 'string' and declared.NAME ~= '' then
		return declared
	end
	return { ID = 'opx.avdoor.board', NAME = 'avdoor.key.board', DEFAULT = 'F' }
end

local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

local function vehiclesApi()
	local api = Open77.vehicles
	return type(api) == 'table' and api or nil
end

--- The local seat, or nil.
local function mySeat()
	local api = vehiclesApi()
	if api == nil or type(api.getPlayerSeat) ~= 'function' then return nil end
	local read, seat = pcall(api.getPlayerSeat)
	if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
	return nil
end

--- One streamed hull's snapshot, or nil. The host reads an id as an integer or
--- as its decimal string; the other spelling is tried before giving up.
local function hull(id)
	local api = vehiclesApi()
	if api == nil or type(api.get) ~= 'function' or id == nil then return nil end
	local read, snapshot = pcall(api.get, id)
	if read and type(snapshot) == 'table' then return snapshot end
	local number = tonumber(id)
	if number ~= nil and number ~= id then
		read, snapshot = pcall(api.get, number)
		if read and type(snapshot) == 'table' then return snapshot end
	end
	return nil
end

--- What a vehicle is to this module, memoised by id: `{ aircraft, voiced }`.
-- A vehicle's record never changes, so one snapshot read per id is enough.
-- @param id any
-- @return table|nil nil while the vehicle is not streamed
local function kindOf(id)
	local key = tostring(id)
	local known = kinds[key]
	if known ~= nil then return known end
	local snapshot = hull(id)
	if snapshot == nil then return nil end
	local sounds = type(settings().SOUNDS) == 'table' and settings().SOUNDS or nil
	known = {
		aircraft = M.IsAircraft(snapshot.record),
		voiced = sounds ~= nil and M.IsAircraft(snapshot.record, sounds.RECORDS) or false,
	}
	kinds[key] = known
	return known
end

--- Where the local body is, or nil. Seated, this is the seat: the body rides
--- the hull, which is why the flight is read from it.
-- @return table|nil `{ x, y, z }`
local function myself()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
	if x ~= x or y ~= y or z ~= z then return nil end
	return { x = x, y = y, z = z }
end

--- A finite number, or nil.
local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

--- Whether two spellings of a platform id name the same hull: the host's 64-bit
--- ids reach Lua as an integer, a float or a decimal string.
local function sameId(a, b)
	if a == nil or b == nil then return false end
	local x, y = M.DecimalId(a), M.DecimalId(b)
	if x ~= nil and y ~= nil then return x == y end
	return tostring(a) == tostring(b)
end

--- How far apart two points are on the ground.
local function across(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

--- Whether the local body is alive: an unreadable answer is "yes", because a
--- guard that does nothing for a body that is fine is worse than one too many.
local function alive()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.isAlive) ~= 'function' then return true end
	local read, answer = pcall(character.isAlive)
	return not read or answer ~= false
end

-- ── the row ───────────────────────────────────────────────────────────────────

local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	if OPX.Lib ~= nil and OPX.Lib.Input ~= nil and type(OPX.Lib.Input.KeyFor) == 'function' then
		return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
	end
	return declared.DEFAULT
end

--- Brings the strip in line with the server's word and the body.
-- THE COMMON PASS COSTS NOTHING: no door and no row is an early return before
-- a single native is read, which is what nearly every pass is.
-- @param seated boolean|nil a seat read the caller already made
local function syncRow(seated)
	if door == nil and not shown then return end
	if seated == nil then seated = mySeat() ~= nil end
	local want = door ~= nil and keyRegistered and not seated and not captured()
	local label = want and (door.role == 'passenger' and 'avdoor.prompt.passenger'
		or 'avdoor.prompt.pilot') or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[avdoor] no prompts contract; the door row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	shown, shownLabel = want, label
	local ran, result
	if want then
		ran, result = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			label = locale(label),
		} } })
	else
		ran, result = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(result)
	elseif type(result) ~= 'table' or result.ok ~= true then
		failure = type(result) == 'table' and tostring(result.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[avdoor] the door row was refused: ' .. failure)
	end
	if want then
		Open77.log.info(('[avdoor] the door of %s is open to you (%s): press %s')
			:format(tostring(door.id), tostring(door.role), tostring(keyLabel())))
	end
end

--- The key: board the hull whose row is up.
-- @param origin string|nil
-- @return table `{ ok, code }`
function M.Board(origin)
	if captured() then return { ok = false, code = 'captured' } end
	if door == nil or not shown then return { ok = false, code = 'no_aircraft' } end
	-- ONE PRESS IS ONE BOARDING: the server swings the door first and seats the
	-- body about half a second later, and the row is still up until it does, so
	-- a second press inside that time is the first one again and asks for nothing.
	local now = OPX.Now()
	if askedAt ~= nil and now - askedAt < ASK_HOLD_MS then return { ok = false, code = 'busy' } end
	askedAt = now
	TriggerServerEvent(M.Event.BOARD, { id = door.id })
	Open77.log.info(('[avdoor] board asked for %s (%s)'):format(tostring(door.id), tostring(origin or 'key')))
	return { ok = true, queued = true }
end

--- What this half knows, for a diagnostic or a test.
function M.Status()
	return {
		door = door ~= nil and door.id or nil,
		role = door ~= nil and door.role or nil,
		shown = shown,
		label = shownLabel,
		key = keyLabel(),
		seated = lastSeat ~= nil,
		aircraft = lastSeat ~= nil and lastSeat.aircraft == true or false,
		fading = fading ~= nil,
		guarding = guard ~= nil,
		placements = guard ~= nil and guard.placements or nil,
		flight = flight ~= nil and flight.state or nil,
		height = flight ~= nil and flight.height or nil,
	}
end

-- ── the exit ──────────────────────────────────────────────────────────────────

-- One look of the exit guard (defined with it, below): the fade asks for one
-- before it decides the body is still.
local guardTick

local function fadeSettings()
	local block = settings().EXIT_FADE
	if type(block) ~= 'table' then return nil end
	return {
		out = math.floor(M.Number(block.OUT_MS, 0, 5000, 160)),
		hold = math.floor(M.Number(block.HOLD_MS, 0, 10000, 1900)),
		passengerHold = math.floor(M.Number(block.PASSENGER_HOLD_MS, 0, 10000, 800)),
		max = math.floor(M.Number(block.MAX_HOLD_MS, 0, 15000, 3600)),
		back = math.floor(M.Number(block.IN_MS, 0, 5000, 550)),
	}
end

--- Covers the screen as a seat in an aircraft starts to empty.
-- @param was table|nil the seat that is being left, as `watchSeat` last read it
local function beginFade(was)
	if fading ~= nil then return end
	local block = fadeSettings()
	local screen = Open77.screen
	if block == nil or type(screen) ~= 'table' or type(screen.fadeOut) ~= 'function' then return end
	local read, id, why = pcall(screen.fadeOut, { durationMs = block.out })
	if not read or id == nil then
		Open77.log.info(('[avdoor] the exit fade was refused: %s'):format(tostring(read and why or id)))
		return
	end
	-- THE PILOT'S SEAT IS THE ONE THE PLATFORM EJECTS FROM, a second and a half
	-- after the mount drops; every other seat has only the engine's own drop. A
	-- seat whose name is unknown gets the longer hold: hiding too much is the
	-- safer mistake.
	local pilot = was == nil or was.seat == nil or was.seat == M.PILOT_SEAT
	fading = { id = id, since = OPX.Now(), block = block,
		hold = pilot and block.hold or block.passengerHold }
end

--- Whether the guard is still settling the body: it has not landed the last
--- placement, or the body was moved less than `SETTLE_MS` ago.
-- @param now number
-- @return boolean
local function guardBusy(now)
	if guard == nil or guard.over then return false end
	return guard.arrived ~= true or now - guard.movedAt < guard.exit.settle
end

--- Gives the image back once the body is out and still, or once the ceiling is
--- reached.
-- @param force boolean
-- @param seated boolean|nil
local function endFade(force, seated)
	if fading == nil then return end
	local now = OPX.Now()
	local held = now - fading.since
	if not force then
		if held < fading.block.out + fading.hold then return end
		if held < fading.block.max then
			if seated == nil then seated = mySeat() ~= nil end
			if seated then return end
			-- LOOK BEFORE DECIDING. The guard looks every `GUARD_MS`, and a body
			-- the platform moved a frame ago is a body the guard has not yet seen
			-- move: the screen must not come back on the strength of a look that
			-- is older than the move.
			if guard ~= nil then guardTick() end
			if guardBusy(now) then return end
		end
	end
	local screen = Open77.screen
	if type(screen) == 'table' and type(screen.fadeIn) == 'function' then
		pcall(screen.fadeIn, fading.id, { durationMs = fading.block.back })
	end
	fading = nil
end

-- ── the guard ─────────────────────────────────────────────────────────────────

--- Where the engine says a hull stands and which way it faces, or nil.
-- The typed reference is asked first (it names the hull the way the server and
-- the seat ledger do), then the engine entity the snapshot carries.
-- @param id any the hull, as the seat names it
-- @return table|nil `{ x, y, z, fx, fy }`
local function hullFrame(id)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.entityGeometry) ~= 'function' then return nil end
	local refs = { { kind = 'vehicle', id = id } }
	local decimal = M.DecimalId(id)
	if decimal ~= nil and decimal ~= id then refs[#refs + 1] = { kind = 'vehicle', id = decimal } end
	local snapshot = hull(id)
	if snapshot ~= nil and snapshot.entity ~= nil then refs[#refs + 1] = snapshot.entity end
	for _, ref in ipairs(refs) do
		local read, answer = pcall(world.entityGeometry, ref)
		if read and type(answer) == 'table' and type(answer.position) == 'table' then
			local at = answer.position
			local facing = type(answer.forward) == 'table' and answer.forward or {}
			local x, y, z = finite(at.x or at[1]), finite(at.y or at[2]), finite(at.z or at[3])
			local fx, fy = finite(facing.x or facing[1]), finite(facing.y or facing[2])
			if x ~= nil and y ~= nil and z ~= nil and fx ~= nil and fy ~= nil and (fx ~= 0 or fy ~= 0) then
				return { x = x, y = y, z = z, fx = fx, fy = fy }
			end
		end
	end
	return nil
end

--- The height of the static ground under a point, or nil.
local function groundBelow(x, y, fromZ)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil end
	local read, z = pcall(world.groundZ, x, y, fromZ)
	if not read then return nil end
	return finite(z)
end

--- Where the body belongs after the seat is left: beside the seat's door on
--- the ground there, or -- when that place has no ground within reach under it
--- (a hull parked at the edge of a roof) -- the first of the other places that
--- has. When none has ground, the door's own place is used and the body falls
--- from the door's height.
-- @param frame table `{ x, y, z, fx, fy }`
-- @param seat string|nil
-- @param exit table `M.ExitSettings()`
-- @return table|nil `{ x, y, z, attempt, airborne, height, ground }`
local function plan(frame, seat, exit)
	local first = nil
	for attempt = 1, M.EXIT_ATTEMPTS do
		local x, y = M.ExitPoint(frame, { x = frame.fx, y = frame.fy }, seat, exit, attempt)
		if x ~= nil then
			local ground = groundBelow(x, y, frame.z + 2.0)
			local z, airborne, height = M.ExitLevel(frame.z, ground, exit)
			local pick = { x = x, y = y, z = z, attempt = attempt, airborne = airborne,
				height = height, ground = ground }
			first = first or pick
			if ground ~= nil and not airborne then return pick end
		end
	end
	return first
end

--- Ends the guard and says how it went.
-- @param result string
local function endGuard(result)
	local g = guard
	if g == nil then return end
	g.over = true
	guard = nil
	if guardJob ~= nil then
		OPX.Scheduler.Cancel(guardJob)
		guardJob = nil
	end
	local now = OPX.Now()
	-- A body that boarded again has finished with that exit: its NEXT step out is
	-- a new exit and gets its own fade and its own guard. Every other ending keeps
	-- the seat's leaving flag from starting the same exit over.
	lastExit = result ~= 'boarded again' and { id = g.id, at = now } or nil
	local at = myself()
	Open77.log.info(('[avdoor] exit guard over (%s) after %.1fs: %d placement(s), %d platform move(s), '
		.. 'body %s from the hull, %s from the door')
		:format(result, (now - g.since) / 1000.0, g.placements, g.jumps,
			at ~= nil and ('%.1f m'):format(across(at, g.frame)) or '?',
			at ~= nil and ('%.1f m'):format(across(at, g.target)) or '?'))
end

--- Puts the body on the guard's target through the platform's own move.
-- @param g table the guard
-- @param why string for the journal
-- @param now number
-- @return boolean whether the move was queued
local function place(g, why, now)
	local travel = Open77.travel
	if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then
		if not heard['\1travel'] then
			heard['\1travel'] = true
			Open77.log.warn('[avdoor] no Open77.travel.teleport on this client: the exit cannot '
				.. 'put the body beside the door')
		end
		return false
	end
	local yaw = nil
	local character = Open77.character
	if type(character) == 'table' and type(character.yaw) == 'function' then
		local read, answer = pcall(character.yaw)
		if read then yaw = finite(answer) end
	end
	-- Facing the way the hull faces when the body's own heading is unreadable:
	-- REDengine's yaw is 0 toward +y and grows toward -x.
	yaw = yaw or (math.deg(math.atan(-g.frame.fx, g.frame.fy)) % 360.0)
	local read, ok, reason = pcall(travel.teleport, g.target.x, g.target.y, g.target.z, yaw)
	if not read or ok ~= true then
		Open77.log.warn(('[avdoor] the exit could not put the body beside the door (%s): %s')
			:format(why, tostring(read and reason or ok)))
		return false
	end
	g.placements = g.placements + 1
	g.placedAt, g.arrived, g.movedAt = now, false, now
	Open77.log.info(('[avdoor] exit: body put beside the %s door at %.1f, %.1f, %.1f (%s, placement %d)')
		:format(tostring(g.seat or 'seat'), g.target.x, g.target.y, g.target.z, why, g.placements))
	return true
end

--- One look at the body, every `GUARD_MS` while the guard lasts.
local function guardStep()
	local g = guard
	if g == nil then return end
	local now = OPX.Now()
	if not alive() then return endGuard('the body is down') end
	local seat = mySeat()
	if seat ~= nil and sameId(seat.vehicleId, g.id) and seat.exiting ~= true then
		-- Aboard again -- through the door it just left, say. Nothing to guard.
		return endGuard('boarded again')
	end
	local at = myself()
	if at == nil then
		if now >= g.endAt + 1000 then endGuard('the body could not be read') end
		return
	end

	-- A PLACEMENT IN FLIGHT: wait for it to land, and make it again when it did
	-- not (or when the platform moved the body again on top of it).
	if not g.arrived then
		if across(at, g.target) <= ARRIVE_METRES then
			g.arrived, g.last, g.movedAt = true, at, now
		elseif now - g.placedAt >= PLACE_WAIT_MS then
			if g.placements >= MAX_PLACEMENTS then return endGuard('gave up') end
			if not place(g, 'the last placement had not held', now) then return endGuard('refused') end
		end
		return
	end

	-- THE BODY IS WHERE IT WAS PUT: a jump between two looks is the platform's
	-- own eject (or anybody's), and is put back. The ground distance is the
	-- measure, so a body that is falling is not mistaken for one that was moved.
	if across(at, g.last) > g.exit.jump then
		g.jumps = g.jumps + 1
		g.movedAt = now
		Open77.log.info(('[avdoor] exit: something moved the body %.1f m in one look (%.1fs after the seat '
			.. 'was left): putting it back'):format(across(at, g.last), (now - g.since) / 1000.0))
		if g.placements >= MAX_PLACEMENTS then return endGuard('gave up') end
		if not place(g, 'the platform moved it', now) then return endGuard('refused') end
		return
	end
	g.last = at

	if now < g.endAt then return end
	-- THE LAST LOOK: a body that is still inside the hull is moved once more.
	if not g.final then
		g.final = true
		if across(at, g.frame) < g.exit.danger and g.placements < MAX_PLACEMENTS then
			if place(g, 'still inside the hull at the end', now) then
				g.endAt = now + PLACE_WAIT_MS + 200
				return
			end
		end
	end
	endGuard('done')
end

--- The scheduler's step: the guard's look, and nothing that raises out of it.
guardTick = function()
	if guard == nil then return end
	local ran, failure = pcall(guardStep)
	if not ran then
		Open77.log.error('[avdoor] the exit guard failed and stops: ' .. tostring(failure))
		endGuard('error')
	end
end

--- Starts the guard for a seat that is being left, or says why not.
-- @param was table the seat as `watchSeat` last read it
-- @return string `guarded`, `far` (a move the server made: leave it alone),
--   `off` (no guard by configuration) or `unknown` (the hull could not be read)
local function beginGuard(was)
	if guard ~= nil then return 'guarded' end
	local exit = M.ExitSettings()
	if exit.off or not exit.place then return 'off' end
	local at = myself()
	local frame = hullFrame(was.vehicleId)
	if at == nil or frame == nil then
		Open77.log.info(('[avdoor] exit from %s: the hull or the body could not be read, so the body '
			.. 'is not placed'):format(tostring(was.vehicleId)))
		return 'unknown'
	end
	local far = across(at, frame)
	if far > exit.near then
		Open77.log.info(('[avdoor] left %s %.1f m from it: a move made elsewhere, not an exit; '
			.. 'nothing is placed'):format(tostring(was.vehicleId), far))
		return 'far'
	end
	if not alive() then return 'unknown' end
	local target = plan(frame, was.seat, exit)
	if target == nil then return 'unknown' end
	local now = OPX.Now()
	guard = {
		id = was.vehicleId, seat = was.seat, since = now, endAt = now + exit.guard,
		frame = frame, target = target, exit = exit,
		placements = 0, jumps = 0, arrived = false, movedAt = now, final = false,
	}
	Open77.log.info(('[avdoor] exit from %s (%s): body %.1f m from the hull, door place %.1f, %.1f, %.1f '
		.. '(%s, ground %s, hull %s over it)')
		:format(tostring(was.vehicleId), tostring(was.seat), far, target.x, target.y, target.z,
			target.attempt == 1 and 'the seat\'s own side'
				or ('side ' .. target.attempt .. ' of ' .. M.EXIT_ATTEMPTS),
			target.ground ~= nil and ('%.1f'):format(target.ground) or 'unknown',
			target.height ~= nil and ('%.1f m'):format(target.height) or 'unknown'))
	if not place(guard, 'the seat was left', now) then
		endGuard('refused')
		return 'unknown'
	end
	guardJob = OPX.Scheduler.Every('avdoor:guard', GUARD_MS, guardTick)
	return 'guarded'
end

--- A seat in an aircraft is being left: the screen and the body.
-- @param was table the seat as `watchSeat` last read it
local function beginExit(was)
	-- The exit in progress, or one that began a moment ago and whose seat the
	-- platform has not yet stopped calling occupied.
	if guard ~= nil then return end
	local now = OPX.Now()
	if lastExit ~= nil and sameId(lastExit.id, was.vehicleId) and now - lastExit.at < EXIT_HOLD_MS then
		return
	end
	lastExit = { id = was.vehicleId, at = now }
	local verdict = beginGuard(was)
	-- A body that was left far from its hull was MOVED, not exited: a screen
	-- that fades for a respawn or a server teleport is a screen that flashes.
	if verdict == 'far' then return end
	beginFade(was)
end

--- The seat watch: an exit from an aircraft starts the fade and the guard;
--- standing outside (or the ceiling) ends the fade.
-- @param seat table|nil this pass's seat read
local function watchSeat(seat)
	if lastSeat ~= nil and lastSeat.aircraft == true then
		local leaving = seat == nil or seat.exiting == true
			or not sameId(seat.vehicleId, lastSeat.vehicleId)
		if leaving then beginExit(lastSeat) end
	end
	if seat ~= nil then
		-- Aboard and not leaving: the next exit is a new exit.
		if seat.exiting ~= true then lastExit = nil end
		local known = lastSeat ~= nil and sameId(lastSeat.vehicleId, seat.vehicleId)
		local kind = kindOf(seat.vehicleId)
		lastSeat = {
			vehicleId = seat.vehicleId,
			aircraft = (known and lastSeat.aircraft == true) or (kind ~= nil and kind.aircraft == true),
			seat = M.SeatName(seat.seat) or (known and lastSeat.seat or nil),
		}
	else
		lastSeat = nil
	end
	endFade(false, seat ~= nil)
end

-- ── the voice ─────────────────────────────────────────────────────────────────

local function soundSettings()
	local block = settings().SOUNDS
	return type(block) == 'table' and block or nil
end

--- Sends one moment of the flight to the server.
local function say(id, which)
	TriggerServerEvent(M.Event.SOUND, { id = tostring(id), which = which })
	Open77.log.info(('[avdoor] flight of %s: %s'):format(tostring(id), which))
end

--- Reads the flight of the MaxTac AV this client is flying, and names the
--- three moments.
-- @param seat table|nil this pass's seat read
local function readFlight(seat)
	local block = soundSettings()
	if block == nil or seat == nil then flight = nil return end
	local kind = kindOf(seat.vehicleId)
	if kind == nil or kind.voiced ~= true then flight = nil return end
	-- Only the client simulating the hull reads its flight: the other seats
	-- would each report the same landing.
	local snapshot = hull(seat.vehicleId)
	if snapshot == nil or snapshot.locallyOwned == false then flight = nil return end
	local at = myself()
	if at == nil then return end

	local world = Open77.world
	local ground = nil
	if type(world) == 'table' and type(world.groundZ) == 'function' then
		local read, z = pcall(world.groundZ, at.x, at.y, at.z + 1.0)
		if read then ground = tonumber(z) end
	end
	local height = ground ~= nil and (at.z - ground) or nil
	local now = OPX.Now()
	local band = M.Number(block.GROUND_METRES, 0.5, 30.0, 7.0)
	local still = M.Number(block.REST_CLIMB, 0.05, 10.0, 0.5)
	local settle = M.Number(block.SETTLE_MS, 0, 10000, 750)

	if flight == nil or tostring(flight.id) ~= tostring(seat.vehicleId) then
		-- A fresh seat: the state is what the hull is doing NOW, and nothing is
		-- said for it -- boarding a hull on the ground is not a landing.
		flight = { id = seat.vehicleId, z = at.z, at = now, height = height,
			state = (height ~= nil and height <= band) and 'ground' or 'air',
			descending = false, stillSince = nil }
		return
	end

	local dt = (now - flight.at) / 1000.0
	if dt <= 0 then return end
	local climb = (at.z - flight.z) / dt
	flight.z, flight.at, flight.height = at.z, now, height

	if math.abs(climb) <= still then
		flight.stillSince = flight.stillSince or now
	else
		flight.stillSince = nil
	end
	local low = height ~= nil and height <= band
	local settled = low and flight.stillSince ~= nil and now - flight.stillSince >= settle

	if flight.state == 'ground' then
		if climb >= M.Number(block.CLIMB_SPEED, 0.0, 50.0, 0.8) then
			flight.state = 'air'
			flight.descending = false
			say(flight.id, 'takeoff')
		end
		return
	end

	if settled then
		flight.state = 'ground'
		if flight.descending then say(flight.id, 'touchdown') end
		flight.descending = false
		return
	end

	local approach = height ~= nil and height <= M.Number(block.DESCENT_METRES, 1.0, 500.0, 30.0)
	if approach and climb <= -M.Number(block.DESCENT_SPEED, 0.1, 50.0, 1.5) then
		if not flight.descending then
			flight.descending = true
			say(flight.id, 'descent')
		end
	elseif climb > still then
		flight.descending = false
	end
end

--- Plays one of the airframe's sounds on it, here.
--
-- THE ANSWER IS WHAT THE SERVER LEARNS FROM: `streamed` says whether this client
-- has the hull at all (a hull that is not streamed here is one the platform's
-- own fan-out would drop just the same, so the server does not rescue it),
-- and `reason` says what the host said when it refused.
-- @param payload table `{ id, event, which, duration, token }`
-- @return table `{ ok, how, streamed, reason }`
local function play(payload)
	if type(payload) ~= 'table' or type(payload.event) ~= 'string' or payload.event == '' then
		return { ok = false, streamed = true, reason = 'malformed sound' }
	end
	local sfx = Open77.sfx
	if type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then
		if not heard['\1sfx'] then
			heard['\1sfx'] = true
			Open77.log.warn('[avdoor] no Open77.sfx.play on this client: the MaxTac AV plays silent here')
		end
		return { ok = false, streamed = true, reason = 'no Open77.sfx.play' }
	end
	local duration = M.Number(payload.duration, 0.05, 60.0, 8.0)
	local snapshot = hull(payload.id)
	local entity = snapshot ~= nil and snapshot.entity or nil
	local read, handle, why = false, nil, 'not streamed here'
	if entity ~= nil then
		-- THE BASE GAME'S OWN EMITTER: every one of these events is played on the
		-- airframe's `vehicle_general_emitter` in the 2.31 scripts
		-- (`GameObject.PlaySound(av, n"av_maxtac_descent_horn",
		-- n"vehicle_general_emitter")`), so that is asked for first, and the
		-- entity's default emitter only if the host refuses it.
		read, handle, why = pcall(sfx.play, payload.event,
			{ entity = entity, emitter = 'vehicle_general_emitter', duration = duration })
		if not read or handle == nil then
			read, handle, why = pcall(sfx.play, payload.event, { entity = entity, duration = duration })
		end
	end
	local how = 'on the airframe'
	if not read or handle == nil then
		-- A body aboard the hull is where the hull is: its own body is the
		-- emitter of last resort (`entity` omitted is the local player). A
		-- listener outside is not given a sound at their own feet instead.
		local seat = mySeat()
		if seat ~= nil and sameId(seat.vehicleId, payload.id) then
			read, handle, why = pcall(sfx.play, payload.event, { duration = duration })
			how = 'on the crew'
		end
	end
	local played = read and handle ~= nil
	if not heard[payload.event] then
		heard[payload.event] = true
		Open77.log.info(('[avdoor] %s on %s: %s'):format(payload.event, tostring(payload.id),
			played and ('playing ' .. how) or ('refused: ' .. tostring(read and why or handle))))
	end
	if played then return { ok = true, how = how, streamed = true } end
	return { ok = false, streamed = entity ~= nil or how == 'on the crew',
		reason = tostring(read and why or handle) }
end

--- Says what became of a sound, to the server that sent it.
-- @param payload table the `PLAY` payload
-- @param answer table `play`'s answer
local function acknowledge(payload, answer)
	if type(payload) ~= 'table' or payload.token == nil then return end
	TriggerServerEvent(M.Event.PLAYED, {
		token = payload.token,
		ok = answer.ok == true,
		how = answer.how,
		streamed = answer.streamed ~= false,
		reason = answer.reason,
	})
end

--- One pass: the seat, the fade, the row, and -- four times a second while
--- this client flies a MaxTac AV -- the flight.
local function watch()
	local seat = mySeat()
	watchSeat(seat)
	syncRow(seat ~= nil)
	local now = OPX.Now()
	if seat ~= nil or flight ~= nil then
		if now - flightAt >= FLIGHT_MS then
			flightAt = now
			readFlight(seat)
		end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

function M.Init()
	door = nil
	shown, shownLabel, keyRegistered, reportedStrip = false, nil, false, false
	lastSeat, fading, flight, flightAt, heard, kinds = nil, nil, nil, 0, {}, {}
	guard, guardJob, lastExit, askedAt = nil, nil, nil, nil
	watchJob = nil
end

function M.Start()
	local declared = keySettings()
	if declared.DEFAULT ~= false and type(RegisterKeyMapping) == 'function' then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(M.Board, 'key')
				if not ran then
					Open77.log.error(('[avdoor] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[avdoor] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	RegisterNetEvent(M.Event.DOOR, function(payload)
		if type(payload) ~= 'table' or payload.open ~= true or payload.id == nil then
			door = nil
		else
			door = { id = tostring(payload.id),
				role = payload.role == 'passenger' and 'passenger' or 'pilot' }
		end
		syncRow()
	end)

	RegisterNetEvent(M.Event.BOARDED, function(payload)
		if type(payload) ~= 'table' then return end
		-- Answered, either way: the next press is a new press.
		askedAt = nil
		TriggerEvent(M.Event.ON_DECISION, payload)
		if payload.ok == true then
			Open77.log.info(('[avdoor] boarded in %s as %s'):format(tostring(payload.seat), tostring(payload.role)))
			door = nil
			return syncRow(true)
		end
		local code = tostring(payload.reason or 'seat_refused')
		OPX.Toast.Locale(M.Refusal[code] or 'avdoor.refused.failed',
			{ reason = tostring(payload.detail or code) }, 'error')
		Open77.log.info(('[avdoor] boarding refused: %s'):format(code))
	end)

	RegisterNetEvent(M.Event.PLAY, function(payload)
		local ran, answer = pcall(play, payload)
		if not ran then
			Open77.log.warn('[avdoor] a flight sound failed: ' .. tostring(answer))
			answer = { ok = false, streamed = true, reason = ('error: %s'):format(tostring(answer):sub(1, 60)) }
		end
		acknowledge(payload, answer)
	end)

	-- One job for the whole half: a seat read and a row check every 100 ms is
	-- what catches the first frame of an exit, and the flight read inside it is
	-- rate-limited on its own.
	watchJob = OPX.Scheduler.Every('avdoor:watch', 100, watch)
end

function M.Stop()
	if watchJob ~= nil then OPX.Scheduler.Cancel(watchJob) end
	endGuard('stopped')
	endFade(true)
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, GROUP) end
	M.Init()
end
