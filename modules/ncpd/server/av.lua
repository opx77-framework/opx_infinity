--- The MaxTac insertion: the AV, flown, the squad that steps out of it, and the
--- crew door.
-- @author XEROX710
--
-- WHY THIS IS OURS AND NOT THE ENGINE'S. `gamePreventionSpawnSystem.RequestAVSpawn`
-- is the engine's own route and the bridge already asks for it (`prevention.av`,
-- `client/redscript/Open77ScriptBridge.reds`). On the live node it answers
-- `prevention.av.ticket.0`: the call lands, the engine schedules no aircraft, and
-- the only thing that ever reaches the street is the squad the response placed
-- there. Nothing renders on any client, which is exactly what a player reports as
-- "no AV, and the troopers just stand on the ground".
--
-- The AV is therefore an Open77 vehicle, created here and flown by
-- `Open77.vehicles.setTransform`. That call is server-authoritative: it revokes an
-- active physics lease, advances the authority epoch and republishes the complete
-- canonical transform to every current viewer, so every player sees the same
-- airframe in the same place rather than a private aircraft on one screen. It is
-- the primitive the platform's own vehicle guide names for a resource driving a
-- body ("`setTransform` per update ... a resource driving the follower, not the
-- engine carrying it"), and it is the one used here.
--
-- `setFrozen` goes up with the create for the same reason the guide gives: it
-- masks native physics on every client, so no viewer's own simulation argues with
-- the server's pose for an aircraft nobody is sitting in. The two together are a
-- kinematic insertion; neither is a physics lease anyone has to win.
--
-- THE CREW DOOR HANDS THE HULL OVER, AND THAT IS THE PLATFORM'S OWN RULE. A
-- player seated in an AV is its pilot as far as `client/src/network/VehicleReplication.cpp`
-- is concerned: the claim test is `IsAvRecord(record)` and a seat occupied and the
-- physics owner holding no seat, and the AV flight envelope is deliberately
-- seat-agnostic ("AV crew counts as seated for this purpose at ANY seat"). So a
-- boarded player's client claims the aircraft and flies it. Two hands on one
-- airframe -- this file's `setTransform` at the configured cadence and the crew's
-- own physics -- is a fight, not a ride: the server revokes the lease on every
-- pose and the client re-claims 250 ms later. The moment somebody is aboard this
-- controller therefore STOPS POSING, clears the freeze and steps out of the way.
-- What it keeps is the BOOKS: who is aboard, and the exit lock that keeps them
-- aboard while the aircraft is flying.
--
-- NOBODY IS EVER DROPPED. Three properties, each with a reason:
--   * the exit lock comes off once the hull is standing at street level
--     (`BOARDING.REST_SPEED`, `REST_HEIGHT`, `REST_SECONDS`), because a lock that
--     never lifts is a trap rather than a ride;
--   * a retracted insertion clears the locks first, and only removes an airframe
--     whose crew have already stepped out or are on the ground;
--   * an airframe is never removed while a player holds a seat in it.
--
-- WHAT THE PLATFORM ALREADY DOES, SO THIS FILE DOES NOT. `Vehicle.max_tac_av` is
-- the one curated freeroam AV and the client already treats it as one:
-- `client/src/api/VehicleFlight.cpp` `IsAvRecord` and `client/src/api/Vehicles.cpp`
-- `IsAvRecordName` both name it, its hover voice resolves through
-- `ResolveAvHoverVoice` to the engine's own `TraumaEngine` loop -- AV records
-- author no `audioResourceName`, so a ground car's traffic loop is silence for
-- an aircraft -- and `client/src/network/VehicleReplication.cpp`
-- `ReconcilePassengerHides` re-homes remote occupants into AV seats. The model,
-- the jet flames and the propulsion note are therefore the record's and the
-- platform's, not something re-implemented here: the hover voice starts from the
-- canonical engine bit this file sets with `setEngine`, so an unoccupied airframe
-- is already audible to every viewer without a second call from us.
--
-- WHAT THIS FILE DOES NOT CLAIM. The red warning lines under a MaxTac AV are a
-- property of the engine's own spawn setup (`av_spawn_setup`,
-- `summonDistanceMin/Max`, `verticalOffset`), and an unoccupied server-flown AV
-- cannot command them. The authored entry workspots a crew rides are the
-- record's and the platform's mount path's, which is the path used here.

local M = OPX.Modules.Get('ncpd')
M.Av = {}
local Av = M.Av

--- The vehicle contract, resolved per call rather than cached at load: `vehicles`
--- is optional to this module, and a resource that starts before it must still be
--- able to say WHY nothing flies rather than failing at load.
local function vehicles()
	return Open77 and Open77.vehicles or nil
end

--- The crew door's own config, read through the law book on every run rather than
--- captured at load. A config that turned the door off -- or declared it badly --
--- is then a run with no boarding window at all, which is what the validator
--- means by dropping the table whole.
--- @return table|nil
local function doorSettings()
	local law = M.Law
	local maxtac = law ~= nil and law.Maxtac or nil
	return maxtac ~= nil and maxtac.Boarding or nil
end

--- Live runs, by the citizen the insertion was called for.
local runs = {}

--- The run in flight, when `AV.ONE_AT_A_TIME` is set. The config's own rule, kept
--- here so a second summon is refused by name instead of quietly queueing behind
--- an aircraft that is already inbound.
local inbound = nil

local PHASE = {
	APPROACH = 'approach',
	DESCEND = 'descend',
	DEPLOY = 'deploy',
	-- The street hold: the squad is out, the aircraft is at the drop altitude and
	-- the crew door is open for `BOARDING.SECONDS`. It is the only phase a player
	-- may board in, and the reason is the same one that makes the phase
	-- necessary: a body can only walk to a hull that is low and still.
	BOARD = 'board',
	CLIMB = 'climb',
	HOVER = 'hover',
	EXIT = 'exit',
	-- A crew holds the hull. Nothing is posed, the freeze is off, and the only
	-- thing left here is to read the seats back and lift the exit lock at the
	-- right moment.
	CREW = 'crew',
}

local function lerp(a, b, t) return a + (b - a) * t end

--- Ease-in-out, so a leg starts and ends at rest. A linear lerp snaps the
--- airframe through every phase boundary, which reads as a stutter per phase.
local function smooth(t) return t * t * (3.0 - 2.0 * t) end

local function bearingTo(from, to)
	local dx = to.x - from.x
	local dy = to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(dy, dx))
end

--- Distance between two points, altitude included.
-- @param from table `{ x, y, z }`
-- @param to table
-- @return number
local function apart(from, to)
	local dx = (tonumber(from.x) or 0.0) - (tonumber(to.x) or 0.0)
	local dy = (tonumber(from.y) or 0.0) - (tonumber(to.y) or 0.0)
	local dz = (tonumber(from.z) or 0.0) - (tonumber(to.z) or 0.0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- A deterministic approach bearing per citizen, so two operators summoning the
--- same stage file do not both fly in on the same compass line, and the same
--- player's second summon does not fly the identical path as the first.
local function bearingFor(citizenId)
	local hash = 0
	for index = 1, #citizenId do
		hash = (hash * 31 + citizenId:byte(index)) % 360
	end
	return hash + 0.0, (hash + 180.0) % 360.0
end

local function pointAt(origin, bearing, distance)
	local radians = math.rad(bearing)
	return {
		x = origin.x + math.cos(radians) * distance,
		y = origin.y + math.sin(radians) * distance,
		z = origin.z,
	}
end

--- One run: the airframe's own geometry, so every phase reads the same fields.
local function geometry(target, plan, bearing)
	local ground = target.z
	local approach = pointAt(target, bearing, plan.ApproachMetres)
	local hover = pointAt(target, bearing, 12.0)
	return {
		-- Where the run starts: out along the approach bearing and high.
		start = { x = approach.x, y = approach.y, z = ground + plan.ApproachAltitude },
		-- Where it holds: beside the player, not on top of them, so the squad
		-- steps out between the aircraft and the person it came for.
		hover = { x = hover.x, y = hover.y, z = ground + plan.HoverAltitude },
		-- Where the squad leaves and the crew door opens: the same ground point,
		-- low. `drop.z` is also the last height this module knows the street to
		-- be at, which is what `Av.AtRest` measures the crew's release against.
		drop = { x = hover.x, y = hover.y, z = ground + plan.DropAltitude },
		-- Where it leaves: back out along the same line, climbing.
		exit = { x = approach.x, y = approach.y, z = ground + plan.ApproachAltitude },
		target = { x = target.x, y = target.y, z = target.z },
	}
end

--- The pose for a phase at `u` in [0, 1].
local function pose(run, phase, u)
	local g = run.geometry
	local eased = smooth(u)
	if phase == PHASE.APPROACH then
		return {
			x = lerp(g.start.x, g.hover.x, eased),
			y = lerp(g.start.y, g.hover.y, eased),
			z = lerp(g.start.z, g.hover.z, eased),
			yaw = bearingTo(g.start, g.hover),
		}
	end
	if phase == PHASE.DESCEND then
		return { x = g.hover.x, y = g.hover.y, z = lerp(g.hover.z, g.drop.z, eased), yaw = bearingTo(g.drop, g.target) }
	end
	if phase == PHASE.DEPLOY then
		return { x = g.drop.x, y = g.drop.y, z = g.drop.z, yaw = bearingTo(g.drop, g.target) }
	end
	-- The street hold is the same pose as the drop, held rather than passed
	-- through: a hull that drifted during the window would make `REACH_METRES` a
	-- moving target for a body walking up to it.
	if phase == PHASE.BOARD then
		return { x = g.drop.x, y = g.drop.y, z = g.drop.z, yaw = bearingTo(g.drop, g.target) }
	end
	if phase == PHASE.CLIMB then
		return { x = g.drop.x, y = g.drop.y, z = lerp(g.drop.z, g.hover.z, eased), yaw = bearingTo(g.hover, g.target) }
	end
	if phase == PHASE.HOVER then
		return { x = g.hover.x, y = g.hover.y, z = g.hover.z, yaw = bearingTo(g.hover, g.target) }
	end
	-- EXIT
	return {
		x = lerp(g.hover.x, g.exit.x, eased),
		y = lerp(g.hover.y, g.exit.y, eased),
		z = lerp(g.hover.z, g.exit.z, eased),
		yaw = bearingTo(g.hover, g.exit),
	}
end

--- How long a phase lasts, from the validated plan.
local function duration(run, phase)
	local plan = run.plan
	if phase == PHASE.APPROACH then return plan.CruiseSeconds end
	if phase == PHASE.DESCEND then return plan.DescentSeconds end
	if phase == PHASE.DEPLOY then return plan.DeploySeconds end
	if phase == PHASE.BOARD then return run.boardSeconds end
	if phase == PHASE.CLIMB then return plan.DescentSeconds end
	if phase == PHASE.HOVER then return plan.HoverSeconds end
	return plan.ExitSeconds
end

--- The phase after this one. The street hold is skipped when the door is off, so
--- a switched-off door is a run of exactly the old shape rather than a pause
--- nobody can use.
local function nextPhase(run, phase)
	if phase == PHASE.APPROACH then return PHASE.DESCEND end
	if phase == PHASE.DESCEND then return PHASE.DEPLOY end
	if phase == PHASE.DEPLOY then
		return run.boardSeconds > 0 and PHASE.BOARD or PHASE.CLIMB
	end
	if phase == PHASE.BOARD then return PHASE.CLIMB end
	if phase == PHASE.CLIMB then return PHASE.HOVER end
	if phase == PHASE.HOVER then return PHASE.EXIT end
	return nil
end

--- One player's position as the SERVER reads it.
-- Every distance in this tree is measured against the host's own read rather than
-- a client's word, and the crew door is the one place where believing the client
-- would hand a seat to anybody who can spell a coordinate.
-- @param playerId number
-- @return table|nil `{ x, y, z }`
local function positionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- The door, as the client half needs to hear it: where the hull is and how
--- close a body has to be. One shape, built here rather than twice.
-- @param run table
-- @return table|nil
local function doorState(run)
	local boarding = run.boarding
	if boarding == nil then return nil end
	local contract = vehicles()
	local hull = contract ~= nil and type(contract.get) == 'function' and contract.get(run.avId)
		or nil
	if type(hull) ~= 'table' then return nil end
	return {
		citizenId = run.citizenId,
		avId = run.avId,
		position = { x = hull.x, y = hull.y, z = hull.z },
		reach = boarding.ReachMetres,
		seats = boarding.Seats,
		seconds = run.boardSeconds,
	}
end

--- Tells the caller that the door opened or closed, so one decision reaches the
--- people who can walk through it instead of being restated on every client.
-- @param run table
-- @param state table|nil
local function announceDoor(run, state)
	if type(run.onDoor) ~= 'function' then return end
	local ok, failure = pcall(run.onDoor, state)
	if not ok then
		Open77.log.error(('[ncpd] the crew door of %s could not be announced: %s')
			:format(tostring(run.citizenId), tostring(failure)))
	end
end

--- Puts a run's pose tick back where the caller found it. Used when a seat the
--- host refused has to leave the hull in exactly the state it was found in.
-- @param run table
local function rearm(run)
	if run.handle ~= nil then return end
	run.handle = OPX.Scheduler.Every(('ncpd.av.%s'):format(run.citizenId), run.plan.TickMs, function()
		Av.Step(run.citizenId)
	end)
end

--- Lifts the exit lock on one crew member.
-- The lock is the whole point of the door -- a body glued in a hull that is
-- flying is the feature -- so the only thing that may drop it is a named reason,
-- and that reason is journalled with the line.
--
-- `notice` is whether the crew member is told. It is set at the landing and
-- nowhere else: a lock lifted because the insertion was retracted or the module
-- stopped is the end of the ride rather than a moment to act on, and a toast for
-- it would be a sentence about a seat that no longer exists.
-- @param run table
-- @param entry table
-- @param why string
-- @param notice boolean|nil tell the seated player the lock is off
-- @return boolean whether the lock was on
local function unlock(run, entry, why, notice)
	if entry.locked ~= true then return false end
	local contract = vehicles()
	if contract == nil or type(contract.setPlayerExitLocked) ~= 'function' then
		entry.locked = false
		return false
	end
	local cleared, reason = contract.setPlayerExitLocked(entry.playerId, false, run.avId)
	if cleared ~= true then
		Open77.log.warn(('[ncpd] the exit lock on %s would not come off (%s): %s')
			:format(tostring(entry.playerId), tostring(why), tostring(reason)))
		return false
	end
	entry.locked = false
	Open77.log.info(('[ncpd] crew %s may step out of the MaxTac AV: %s')
		:format(tostring(entry.playerId), tostring(why)))
	if notice == true then
		-- The one channel a seated player has. A refused toast is not a refused
		-- unlock: the seat is already theirs to leave.
		local told, failure = pcall(TriggerClientEvent, M.Event.RELEASED, entry.playerId,
			{ seat = entry.seat, avId = run.avId })
		if not told then
			Open77.log.warn(('[ncpd] the release notice for %s did not go out: %s')
				:format(tostring(entry.playerId), tostring(failure)))
		end
	end
	return true
end

--- Takes every crew member out of the hull and lets go of the run's books.
-- @param run table
-- @param why string
local function disband(run, why)
	local contract = vehicles()
	for _, entry in ipairs(run.crew) do
		unlock(run, entry, why)
		if entry.aboard ~= false and contract ~= nil
			and type(contract.forcePlayerOutOfVehicle) == 'function' then
			contract.forcePlayerOutOfVehicle(entry.playerId, run.avId)
		end
	end
	run.crew = {}
end

--- How many of this run's crew are still in the hull, by the last read.
-- @param run table
-- @return integer
local function aboard(run)
	local count = 0
	for _, entry in ipairs(run.crew) do
		if entry.aboard ~= false then count = count + 1 end
	end
	return count
end

--- Hands a crewing hull over: our poses stop, its freeze comes off and the seats
--- are read on the custody cadence until the last body is out.
-- @param run table
-- @param why string
local function handOver(run, why)
	if run.handedOver == true then return end
	run.handedOver = true
	announceDoor(run, nil)
	if run.handle ~= nil then OPX.Scheduler.Cancel(run.handle) end
	local contract = vehicles()
	if contract ~= nil and type(contract.setFrozen) == 'function' then
		contract.setFrozen(run.avId, false)
	end
	run.handle = OPX.Scheduler.Every(('ncpd.av.crew.%s'):format(run.citizenId), run.custodyMs, function()
		Av.Custody(run.citizenId)
	end)
	local crew = aboard(run)
	Open77.log.info(('[ncpd] the MaxTac AV for %s is the crew\'s (%s): %d aboard, the crew flies her')
		:format(tostring(run.citizenId), tostring(why), crew))
	M.Radio.Push('maxtac', 'ncpd.radio.maxtac.crew', { citizen = run.citizenId, crew = crew })
end

--- Stops a run, takes the airframe down and frees the one-at-a-time slot.
--
-- A crew changes what "down" means. An airframe with somebody still seated in it
-- is not removed; it stops being ours -- the crew flies it, and `Av.Custody` is
-- what ends the run when they have all stepped out. `force` is the module-stop
-- path, where the host is about to remove our vehicles anyway.
-- @param citizenId string
-- @param why string named reason, for the log line
-- @param force boolean take it down even with a crew aboard
-- @return boolean whether the airframe was taken out of the world
local function finish(citizenId, why, force)
	local run = runs[citizenId]
	if run == nil then return false end

	if aboard(run) > 0 and force ~= true then
		handOver(run, why)
		return false
	end

	runs[citizenId] = nil
	if inbound == run then inbound = nil end
	announceDoor(run, nil)
	if run.handle ~= nil then
		OPX.Scheduler.Cancel(run.handle)
		run.handle = nil
	end
	disband(run, why)
	local contract = vehicles()
	if contract ~= nil then
		-- Named so a failed removal is visible: an aircraft nobody can remove is
		-- a permanent object in the bucket, not a cosmetic leftover.
		local removed, reason = contract.remove(run.avId)
		if removed ~= true then
			Open77.log.warn(('[ncpd] the MaxTac AV for %s could not be removed (%s): %s')
				:format(tostring(citizenId), tostring(why), tostring(reason)))
		end
	end
	Open77.log.info(('[ncpd] MaxTac AV down for %s after %s: %.0fs in the air')
		:format(tostring(citizenId), tostring(why), run.clock))
	M.Radio.Push('maxtac', 'ncpd.radio.maxtac.down',
		{ citizen = citizenId, seconds = math.floor(run.clock + 0.5) })
	return true
end

--- Calls one hook of a run, naming a failure rather than taking the run down.
-- @param citizenId string
-- @param hook function|nil
-- @param what string the sentence a failure completes
-- @param drop table the point the aircraft is over
-- @param run table
local function callHook(citizenId, hook, what, drop, run)
	if type(hook) ~= 'function' then return end
	local ok, failure = pcall(hook, drop, run)
	if not ok then
		Open77.log.error(('[ncpd] %s for %s: %s'):format(what, tostring(citizenId), tostring(failure)))
	end
end

--- One pose. A removed airframe ends the run rather than being re-posed forever.
-- @param citizenId string
function Av.Step(citizenId)
	local run = runs[citizenId]
	if run == nil then return end
	if run.phase == PHASE.CREW or run.handedOver == true then return end

	local contract = vehicles()
	if contract == nil then
		finish(citizenId, 'the vehicle contract went away')
		return
	end
	if contract.get(run.avId) == nil then
		finish(citizenId, 'the airframe was taken away')
		return
	end

	local phase = run.phase
	local length = duration(run, phase)
	local dt = run.plan.TickMs / 1000.0
	run.clock = run.clock + dt
	run.phaseClock = run.phaseClock + dt
	local u = length > 0.0 and math.min(1.0, run.phaseClock / length) or 1.0

	local at = pose(run, phase, u)
	-- `yaw` is passed every tick on purpose: the platform's `setTransform` reads
	-- an absent heading as 0, not as "keep the current one".
	local moved, reason = contract.setTransform(run.avId, { x = at.x, y = at.y, z = at.z, yaw = at.yaw })
	if moved ~= true then
		run.refused = run.refused + 1
		if run.refused == 1 then
			Open77.log.warn(('[ncpd] the MaxTac AV for %s refused a pose: %s')
				:format(tostring(citizenId), tostring(reason)))
		end
	end

	if u < 1.0 then return end

	-- The squad takes the seats as the descent begins, so the bodies that step
	-- out of the doors at the bottom are bodies that were inside the hull on the
	-- way down. A caller that passed no mount hook keeps the old shape: the squad
	-- appears on the ring at the drop.
	if phase == PHASE.DESCEND and run.mounted == false then
		run.mounted = true
		callHook(citizenId, run.onMount, 'the squad could not take their seats in the AV',
			run.geometry.drop, run)
	end

	-- The squad steps out at the bottom of the descent, before the street hold:
	-- one call, once, at the only moment the aircraft is close enough to the
	-- street for it to be where they came from.
	if phase == PHASE.DEPLOY and run.deployed == false then
		run.deployed = true
		callHook(citizenId, run.onDeploy, 'the MaxTac squad could not leave the AV',
			run.geometry.drop, run)
	end

	local following = nextPhase(run, phase)
	if following == nil then
		finish(citizenId, 'the insertion run finished')
		return
	end
	if phase == PHASE.DEPLOY and following == PHASE.BOARD then
		Open77.log.info(('[ncpd] the MaxTac AV holds at the street for %s: %.0fs of crew door')
			:format(tostring(citizenId), run.boardSeconds))
		-- The door is open on the air too, so a trooper across town knows the
		-- window exists before the strip row could ever reach them.
		M.Radio.Push('maxtac', 'ncpd.radio.maxtac.holds',
			{ citizen = citizenId, seconds = math.floor(run.boardSeconds + 0.5) })
	elseif phase == PHASE.BOARD then
		-- The window is shutting on its own: the people who were told where the
		-- door is are told it is closed, in the same breath as the climb.
		announceDoor(run, nil)
	end
	run.phase = following
	run.phaseClock = 0.0
	if following == PHASE.BOARD then announceDoor(run, doorState(run)) end
	run.phaseClock = 0.0
end

--- Whether the hull is standing still at street level.
--
-- The reference is the run's own drop point, the last height this module knows
-- the street to be at (`REST_HEIGHT` metres of tolerance). A hull flown a
-- kilometre away and set down on a rooftop is therefore not "at rest" by this
-- read; a crew in that aircraft is released by the insertion being retracted,
-- which is the door's other way out.
-- @param hull table the canonical vehicle snapshot
-- @param run table
-- @return boolean
function Av.AtRest(hull, run)
	local boarding = run.boarding
	if boarding == nil then return true end
	local speed = tonumber(hull.speed) or 0.0
	local z = tonumber(hull.z)
	if speed > boarding.RestSpeed or z == nil or z > run.geometry.drop.z + boarding.RestHeight then
		run.restClock = 0.0
		return false
	end
	run.restClock = (run.restClock or 0.0) + (run.custodyMs / 1000.0)
	return run.restClock >= boarding.RestSeconds
end

--- The custody read: who is still in the hull, and whether the lock may come off.
--
-- A SEAT READ BACK IS THE ONLY PROOF. What the door asked for is a seat
-- assignment; what a body actually holds is `getPlayerSeat`, and the two differ
-- for as long as a client takes to confirm the native mount -- and forever if that
-- client never does. The lock is therefore lifted on the read, never on the
-- promise, and a crew member the read cannot find ends the run rather than
-- holding a seat on somebody's behalf.
-- @param citizenId string
function Av.Custody(citizenId)
	local run = runs[citizenId]
	if run == nil or run.handedOver ~= true then return end

	local contract = vehicles()
	if contract == nil then
		finish(citizenId, 'the vehicle contract went away', true)
		return
	end
	local hull = contract.get(run.avId)
	if hull == nil then
		finish(citizenId, 'the airframe was taken away', true)
		return
	end

	for _, entry in ipairs(run.crew) do
		local seat = type(contract.getPlayerSeat) == 'function'
			and contract.getPlayerSeat(entry.playerId) or nil
		entry.aboard = seat ~= nil and tostring(seat.vehicleId) == tostring(run.avId)
		if entry.aboard and entry.locked == true and Av.AtRest(hull, run) then
			unlock(run, entry, 'the aircraft is standing at the street', true)
		end
	end

	if aboard(run) == 0 then
		Open77.log.info(('[ncpd] the crew of the MaxTac AV for %s has stepped out')
			:format(tostring(citizenId)))
		finish(citizenId, 'the crew stepped out', true)
	end
end

--- Flies a MaxTac AV in and puts the squad on the street from it.
--
-- @param request table `{ citizenId, target = {x,y,z}, bucket, record, plan,
--   onMount = function(dropPoint, run), onDeploy = function(dropPoint, run),
--   tag, effect }`
-- @return string|nil the airframe's vehicle id, or nil
-- @return string|nil reason when nothing was flown
function Av.Insert(request)
	local contract = vehicles()
	if contract == nil then return nil, 'vehicles_api_unavailable' end
	if type(contract.create) ~= 'function' or type(contract.setTransform) ~= 'function' then
		return nil, 'vehicles_api_unavailable'
	end

	local citizenId = request.citizenId
	if type(citizenId) ~= 'string' or citizenId == '' then return nil, 'no_citizen' end
	if runs[citizenId] ~= nil then return nil, 'already_inbound' end
	if inbound ~= nil and request.oneAtATime ~= false then return nil, 'one_at_a_time' end

	local plan = request.plan
	if type(plan) ~= 'table' then return nil, 'no_insertion_plan' end
	local target = request.target
	if type(target) ~= 'table' or type(target.x) ~= 'number' then return nil, 'no_target_position' end

	-- The door is read from the law book rather than from the request, so a
	-- caller cannot open a window the config closed.
	local boarding = doorSettings()
	local boardSeconds = boarding ~= nil and boarding.Seconds or 0.0

	local bearing, _ = bearingFor(citizenId)
	local geometry = geometry(target, plan, bearing)

	-- The host's flag table, and only when it really is one: `vehicles.flags`
	-- is a table of masks on the platform and a function in the test harness,
	-- and the same shape `response.lua` reads through. An absent table is no
	-- flags, not a crash -- the aircraft is still flown, just without the
	-- create-time mask, and `setEngine`/`setLights` below switch it on anyway.
	local flagMasks = contract.flags
	local flags = type(flagMasks) == 'table' and flagMasks or {}
	local createFlags = (flags.engineOn or 0) + (flags.lightsOn or 0)
	local avId, reason = contract.create({
		record = request.record or 'Vehicle.max_tac_av',
		position = { x = geometry.start.x, y = geometry.start.y, z = geometry.start.z },
		yaw = bearingTo(geometry.start, geometry.hover),
		bucket = request.bucket,
		flags = createFlags > 0 and createFlags or nil,
	})
	if avId == nil then return nil, tostring(reason or 'vehicle_create_refused') end

	-- Frozen so no client's own simulation argues with the pose the server
	-- publishes, engine on and lights high so the insertion is audible and lit
	-- from the first packet rather than after the first client streams it.
	contract.setFrozen(avId, true)
	contract.setEngine(avId, true)
	contract.setLights(avId, 'high')

	local run = {
		avId = avId,
		citizenId = citizenId,
		plan = plan,
		geometry = geometry,
		phase = PHASE.APPROACH,
		phaseClock = 0.0,
		clock = 0.0,
		refused = 0,
		deployed = false,
		mounted = false,
		onMount = request.onMount,
		onDeploy = request.onDeploy,
		boarding = boarding,
		boardSeconds = boardSeconds,
		custodyMs = boarding ~= nil and boarding.CustodyMs or 1000,
		onDoor = request.onDoor,
		crew = {},
		handedOver = false,
		restClock = 0.0,
	}
	run.handle = OPX.Scheduler.Every(('ncpd.av.%s'):format(citizenId), plan.TickMs, function()
		Av.Step(citizenId)
	end)
	runs[citizenId] = run
	inbound = run

	Open77.log.info(('[ncpd] MaxTac AV inbound for %s: %s from %.0fm out at %.0fm altitude, %.0fs to the drop%s')
		:format(citizenId, tostring(request.record or 'Vehicle.max_tac_av'),
			plan.ApproachMetres, plan.ApproachAltitude, plan.CruiseSeconds,
			boardSeconds > 0 and (', %.0fs of crew door'):format(boardSeconds) or ''))
	-- On the air the moment she is committed: the MaxTac band hears the inbound,
	-- seconds rounded because a line is words, not a telemetry readout.
	M.Radio.Push('maxtac', 'ncpd.radio.maxtac.inbound',
		{ citizen = citizenId, seconds = math.floor(plan.CruiseSeconds + 0.5) })
	return avId
end

--- Whether this character has an aircraft in the air.
-- @param citizenId string
-- @return boolean
function Av.IsInbound(citizenId)
	return runs[citizenId] ~= nil
end

--- Everything in the air, for a status surface.
-- @return integer
function Av.Inbound()
	local count = 0
	for _ in pairs(runs) do count = count + 1 end
	return count
end

--- The run whose hull is holding low in front of this player, if any.
-- Ambiguity is refused rather than guessed: `AV.ONE_AT_A_TIME` is the config's
-- own rule, and two hulls in reach would mean this read cannot tell which seat a
-- body is walking to.
-- @param playerId number
-- @return table|nil the run
-- @return string|nil why not, when nothing may be boarded
local function boardable(playerId)
	local at = positionOf(playerId)
	if at == nil then return nil, 'no_position' end

	local found, nearest, why = nil, math.huge, 'no_aircraft'
	for _, run in pairs(runs) do
		if run.boarding == nil then
			why = 'no_door'
		elseif run.phase == PHASE.CLIMB or run.phase == PHASE.HOVER or run.phase == PHASE.EXIT then
			-- Named from the run that exists: "the aircraft has already left" and
			-- "there is no aircraft" are different answers to a player standing on
			-- an empty street, and the door is the thing that closed.
			why = 'departed'
		elseif run.handedOver == true then
			why = 'crewed'
		elseif run.phase ~= PHASE.BOARD then
			why = 'not_boarding'
		else
			local contract = vehicles()
			local hull = contract ~= nil and contract.get(run.avId) or nil
			if hull ~= nil then
				local away = apart(hull, at)
				if away <= run.boarding.ReachMetres and away < nearest then
					found, nearest = run, away
				elseif found == nil then
					why = 'too_far'
				end
			end
		end
	end
	return found, found == nil and why or nil
end

--- The seat a crew member takes: the first offered seat the host says is free.
-- The seat is the host's answer, not ours: `seatFree` treats a seat whose entry
-- animation is still running as TAKEN, which is what stops two bodies being
-- booked into one seat.
-- @param contract table the vehicle API
-- @param run table
-- @param want string|nil a named seat, canonicalised, or nil for the first free
-- @return string|nil
-- @return string|nil the refusal
local function pickSeat(contract, run, want)
	--- Whether one seat may be offered.
	-- THREE ANSWERS, NOT TWO. `seatFree` answers `true`, `false`, or `nil, reason`
	-- (`wiki/vehicles.md`), and the third is not "taken": it is a ledger this build
	-- cannot read. Treating it as taken would make boarding impossible on a plugin
	-- that predates the read -- so an unreadable seat is OFFERED, and the mount's
	-- own answer is what refuses it. Absent entirely is the same case.
	-- @param seat string canonical
	-- @return boolean offered
	local function free(seat)
		if type(contract.seatFree) ~= 'function' then return true end
		local read, answer = pcall(contract.seatFree, run.avId, seat)
		if not read then return true end
		return answer ~= false
	end

	if want ~= nil then
		local law = M.Law
		local canonical = law ~= nil and law.InSeat ~= nil and law.InSeat(want) or nil
		if canonical == nil then return nil, 'invalid_seat' end
		if free(canonical) then return canonical, nil end
		return nil, 'seat_taken'
	end
	for _, offered in ipairs(run.boarding.Seats) do
		if free(offered) then return offered, nil end
	end
	return nil, 'no_seat'
end

--- Puts one player in the crew of the MaxTac AV holding at the street.
--
-- THE DIVISION'S DECISION IS NOT MADE HERE. Whether this player may hold the
-- division at all -- the job, the ACL right, duty -- belongs to the module's own
-- books, so the caller resolves it and passes the verdict in; what this function
-- owns is the AIRCRAFT half: that a hull is standing low in front of them, that
-- it still has a seat, and that the host accepted the mount.
-- @param playerId number
-- @param permit boolean|string `true`, or the reason the caller refused
-- @param want string|nil a named seat, for a caller that wants a particular one
-- @return string|nil the canonical seat, or nil
-- @return string|nil the refusal
function Av.Board(playerId, permit, want)
	if permit ~= true then return nil, tostring(permit or 'not_allowed') end
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return nil, 'invalid_player' end

	local contract = vehicles()
	if contract == nil or type(contract.warpPlayerIntoVehicle) ~= 'function' then
		return nil, 'vehicles_api_unavailable'
	end

	local run, why = boardable(playerId)
	if run == nil then return nil, tostring(why) end

	local chosen, seatWhy = pickSeat(contract, run, want)
	if chosen == nil then return nil, tostring(seatWhy) end

	-- STOP POSING BEFORE THE SEAT EXISTS. A seat assignment is confirmed by the
	-- client a moment later, and the platform lets a seated client claim the hull
	-- at any seat; a pose tick still running when that claim lands is the server
	-- and the crew fighting over one airframe. The order here is the whole
	-- hand-over: stop, unfreeze, then seat them.
	if run.handle ~= nil then
		OPX.Scheduler.Cancel(run.handle)
		run.handle = nil
	end
	if type(contract.setFrozen) == 'function' then contract.setFrozen(run.avId, false) end

	local seated, refusal = contract.warpPlayerIntoVehicle(playerId, run.avId, chosen, {
		-- The hull is already in the player's own bucket; moving them would be a
		-- routing change nobody asked for.
		moveBucket = false,
		-- THE FEATURE, in one flag: while it holds, native unmount and manual
		-- seat switches are refused and reconciliation remounts any divergent
		-- local state, so a body aboard a flying hull stays aboard.
		exitLocked = true,
	})
	if seated ~= true then
		-- Nothing was taken. The tick goes back on and the hull is left exactly
		-- as it was found, still frozen, still ours.
		rearm(run)
		return nil, tostring(refusal or 'seat_refused')
	end

	run.crew[#run.crew + 1] = {
		playerId = playerId,
		seat = chosen,
		locked = true,
		aboard = true,
	}
	run.phase = PHASE.CREW
	handOver(run, 'a crew is aboard')
	Open77.log.info(('[ncpd] %s boarded the MaxTac AV for %s in %s')
		:format(tostring(playerId), tostring(run.citizenId), tostring(chosen)))
	M.Radio.Push('maxtac', 'ncpd.radio.maxtac.boarded',
		{ citizen = run.citizenId, seat = tostring(chosen) })
	return chosen
end

--- The crew of a character's insertion, for a status surface.
-- @param citizenId string
-- @return table[] `{ playerId, seat, locked, aboard }`, by boarding order
function Av.Crew(citizenId)
	local run = runs[citizenId]
	local list = {}
	if run == nil then return list end
	for index, entry in ipairs(run.crew) do
		list[index] = { playerId = entry.playerId, seat = entry.seat, locked = entry.locked,
			aboard = entry.aboard }
	end
	return list
end

--- Whether an insertion is holding its door open for a crew right now, and where.
-- The client half draws its row from this rather than from a second rule of its
-- own: one decision, one place.
-- @return table|nil `{ citizenId, avId, position, reach, seconds }`
function Av.Door()
	for _, run in pairs(runs) do
		if run.phase == PHASE.BOARD and run.handedOver ~= true then
			local state = doorState(run)
			if state ~= nil then return state end
		end
	end
	return nil
end

--- Clears every exit lock a character's insertion holds, without taking the
--- aircraft down. The operator's own way out of a door that would not open.
-- @param citizenId string
-- @param why string|nil
-- @return integer how many locks came off
function Av.Release(citizenId, why)
	local run = runs[citizenId]
	if run == nil then return 0 end
	local lifted = 0
	for _, entry in ipairs(run.crew) do
		if unlock(run, entry, why or 'released') then lifted = lifted + 1 end
	end
	return lifted
end

--- Takes a character's insertion down now: a cleared wanted level, a stage that
--- fell, or the module stopping. Idempotent.
--
-- A CREWED AIRCRAFT IS NOT DROPPED OUT OF THE SKY. Its locks are cleared and the
-- hull is handed over; it is removed when the last of them is out, or right here
-- when they are already standing on the ground.
-- @param citizenId string
-- @param why string|nil
-- @return boolean whether the airframe was taken out of the world
function Av.Retract(citizenId, why)
	local run = runs[citizenId]
	if run == nil then return false end
	if aboard(run) > 0 then
		for _, entry in ipairs(run.crew) do
			unlock(run, entry, why or 'the insertion was retracted')
		end
		handOver(run, why or 'the insertion was retracted')
		return false
	end
	return finish(citizenId, why or 'retracted')
end

--- Takes every insertion down. The module's `Stop` uses it, so a resource restart
--- does not leave an aircraft holding a bucket it can no longer pose.
-- @param why string|nil
-- @return integer how many were taken down
function Av.RetractAll(why)
	local taken = 0
	for citizenId in pairs(runs) do
		if finish(citizenId, why or 'the module stopped', true) then taken = taken + 1 end
	end
	return taken
end
