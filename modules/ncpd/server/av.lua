--- The MaxTac insertion: the AV, flown, and the squad that steps out of it.
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
-- WHAT THE PLATFORM ALREADY DOES, SO THIS FILE DOES NOT. `Vehicle.max_tac_av` is
-- the one curated freeroam AV and the client already treats it as one:
-- `client/src/api/VehicleFlight.cpp` `IsAvRecord` and `client/src/api/Vehicles.cpp`
-- `IsAvRecordName` both name it, its hover voice resolves through
-- `ResolveAvHoverVoice` to the engine's own `TraumaEngine` loop -- AV records
-- author no `audioResourceName`, so a ground car's traffic loop is silence for an
-- aircraft -- and `client/src/network/VehicleReplication.cpp`
-- `ReconcilePassengerHides` re-homes remote occupants into AV seats. The model,
-- the jet flames and the propulsion note are therefore the record's and the
-- platform's, not something re-implemented here.
--
-- WHAT THIS FILE DOES NOT CLAIM. The red warning lines under a MaxTac AV are a
-- property of the entity template and its AI package (`av_spawn_setup`,
-- `summonDistanceMin/Max`, `verticalOffset` in `config/ncpd.lua`'s own words), and
-- an unoccupied server-flown AV cannot command them. What is done about them is
-- the aircraft's lights and a nose that stays on the player it came for.

local M = OPX.Modules.Get('ncpd')
M.Av = {}
local Av = M.Av

--- The vehicle contract, resolved per call rather than cached at load: `vehicles`
--- is optional to this module, and a resource that starts before it must still be
--- able to say WHY nothing flies rather than failing at load.
local function vehicles()
	return Open77 and Open77.vehicles or nil
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
	CLIMB = 'climb',
	HOVER = 'hover',
	EXIT = 'exit',
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
		-- Where the squad leaves: the same ground point, low.
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
	if phase == PHASE.CLIMB then return plan.DescentSeconds end
	if phase == PHASE.HOVER then return plan.HoverSeconds end
	return plan.ExitSeconds
end

local function nextPhase(phase)
	if phase == PHASE.APPROACH then return PHASE.DESCEND end
	if phase == PHASE.DESCEND then return PHASE.DEPLOY end
	if phase == PHASE.DEPLOY then return PHASE.CLIMB end
	if phase == PHASE.CLIMB then return PHASE.HOVER end
	if phase == PHASE.HOVER then return PHASE.EXIT end
	return nil
end

--- Stops a run, takes the airframe down and frees the one-at-a-time slot.
-- @param citizenId string
-- @param why string named reason, for the log line
local function finish(citizenId, why)
	local run = runs[citizenId]
	if run == nil then return false end
	runs[citizenId] = nil
	if inbound == run then inbound = nil end
	if run.handle ~= nil then OPX.Scheduler.Cancel(run.handle) end
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
	return true
end

--- One pose. A removed airframe ends the run rather than being re-posed forever.
local function step(citizenId)
	local run = runs[citizenId]
	if run == nil then return end

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

	-- The squad steps out at the bottom of the descent, before the climb: one
	-- call, once, at the only moment the aircraft is close enough to the street
	-- for it to be where they came from.
	if phase == PHASE.DEPLOY and run.deployed == false then
		run.deployed = true
		if type(run.onDeploy) == 'function' then
			local ok, failure = pcall(run.onDeploy, run.geometry.drop, run)
			if not ok then
				Open77.log.error(('[ncpd] the MaxTac squad could not leave the AV for %s: %s')
					:format(tostring(citizenId), tostring(failure)))
			end
		end
	end

	local following = nextPhase(phase)
	if following == nil then
		finish(citizenId, 'the insertion run finished')
		return
	end
	run.phase = following
	run.phaseClock = 0.0
end

--- Flies a MaxTac AV in and puts the squad on the street from it.
--
-- @param request table `{ citizenId, target = {x,y,z}, bucket, record, plan,
--   onDeploy = function(dropPoint, run), tag, effect }`
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
		onDeploy = request.onDeploy,
	}
	run.handle = OPX.Scheduler.Every(('ncpd.av.%s'):format(citizenId), plan.TickMs, function()
		step(citizenId)
	end)
	runs[citizenId] = run
	inbound = run

	Open77.log.info(('[ncpd] MaxTac AV inbound for %s: %s from %.0fm out at %.0fm altitude, %.0fs to the drop')
		:format(citizenId, tostring(request.record or 'Vehicle.max_tac_av'),
			plan.ApproachMetres, plan.ApproachAltitude, plan.CruiseSeconds))
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

--- Takes a character's insertion down now: a cleared wanted level, a stage that
--- fell, or the module stopping. Idempotent.
-- @param citizenId string
-- @param why string|nil
-- @return boolean whether anything was flying
function Av.Retract(citizenId, why)
	return finish(citizenId, why or 'retracted')
end

--- Takes every insertion down. The module's `Stop` uses it, so a resource restart
--- does not leave an aircraft holding a bucket it can no longer pose.
-- @return integer how many were taken down
function Av.RetractAll(why)
	local taken = 0
	for citizenId in pairs(runs) do
		if finish(citizenId, why or 'the module stopped') then taken = taken + 1 end
	end
	return taken
end
