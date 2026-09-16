--- The stage: the camera on the player's own character, the mouse off it, and the hold.
-- @author dop42
--
-- `client/main.lua` decides when the stage is up; this file only executes. Every
-- call below is guarded twice -- the function is checked before it is called and
-- the call is pcall'd -- because `Open77.camera`, `Open77.players` and
-- `Open77.travel` are installed by permission and a client may have none of them.
--
-- TWO THINGS ARE NOT THE SAME. The player controls set bits in the player's
-- control mask natively; a focused WebUI surface takes the keyboard. This module
-- now has the focused surface, which the platform documents as its own way to
-- keep the camera still -- and the controls are still asked for, because the
-- mouse is not the keyboard and a client whose focus does not mute the walk keys
-- must still stand still.

local M = OPX.Modules.Get('entry')

M.Stage = {}
local Stage = M.Stage

-- Player controls that hold the body, each a name and the value it is set to.
local BODY_CONTROLS = {
	{ 'freezePosition', true },
	{ 'allowJump', false },
	{ 'allowCrouch', false },
	{ 'allowDodge', false },
	{ 'allowWeapons', false },
	{ 'allowAim', false },
	{ 'allowShoot', false },
	{ 'allowInteraction', false },
}

-- The one control that keeps the mouse off the camera: the native camera and
-- turn restriction. It stops the mouse turning the character, and the orbit
-- with it, since the orbit is a yaw around the character.
local CAMERA_CONTROL = { 'freezeRotation', true }

-- Drift in metres under which the hold corrects nothing: a standing puppet
-- drifts a few millimetres while its animation settles.
local PIN_FLOOR_M = 0.05

-- A move over this, between two reads, is a placement and not a walk: the
-- character is held from where it was put, not dragged back to where it was.
local PIN_CEILING_M = 3.0

-- Degrees the facing may turn before the hold puts it back, so the camera keeps
-- looking at the front of the character.
local PIN_TURN_DEGREES = 10.0

-- The orbit used when the configured one cannot be read.
local ORBIT_DEFAULT = 180.0

local enabled, orbitDegrees, freeze, lockCamera = true, ORBIT_DEFAULT, true, true

local problems = {}

-- Whether the stage orbit is asked for right now.
local up = false

-- The perspective the player asked for, handed back when the stage goes.
local savedPerspective

-- Whether main.lua wants the character held.
local holdWanted = false

-- Whether the fallback hold is wanted, and whether it is usable at all.
local pinWanted, pinBroken = false, false

-- Whether the player controls are unusable for the session.
local controlsBroken = false

-- Whether a control block may be standing, so the way down releases it.
local controlsHeld = false

-- Where the fallback hold holds the character from.
local anchor

-- One log line per run of failures, not one per tick.
local orbitFailing, pinFailing, controlsFailing = false, false, false

--- Reads the stage switches once, and lists what could not be read.
-- Resolved in one place so a value of the wrong type is said once at start and
-- the shipped value is used, rather than re-read and re-judged on every tick.
-- @author dop42
function Stage.Configure()
	enabled, orbitDegrees, freeze, lockCamera = true, ORBIT_DEFAULT, true, true
	problems = {}

	local wanted = M.Settings.STAGE
	if type(wanted) ~= 'table' then
		problems[#problems + 1] =
			'STAGE is not a table: the stage is up, facing, with the camera locked and the freeze on'
		wanted = {}
	end

	if wanted.ENABLED == false then
		enabled = false
	elseif wanted.ENABLED ~= true and wanted.ENABLED ~= nil then
		problems[#problems + 1] = 'STAGE.ENABLED is not a boolean: the stage is up'
	end

	local degrees = tonumber(wanted.ORBIT_DEGREES)
	if not OPX.Math.IsFinite(degrees) then
		if wanted.ORBIT_DEGREES ~= nil then
			problems[#problems + 1] = ('STAGE.ORBIT_DEGREES is not a number: %d is used')
				:format(ORBIT_DEFAULT)
		end
	elseif degrees < -180 or degrees > 180 then
		orbitDegrees = OPX.Math.Clamp(degrees, -180, 180)
		problems[#problems + 1] = ('STAGE.ORBIT_DEGREES is outside -180..180: clamped to %d')
			:format(orbitDegrees)
	else
		orbitDegrees = degrees
	end

	if wanted.FREEZE == false then
		freeze = false
	elseif wanted.FREEZE ~= true and wanted.FREEZE ~= nil then
		problems[#problems + 1] = 'STAGE.FREEZE is not a boolean: the character is held'
	end

	if wanted.LOCK_CAMERA == false then
		lockCamera = false
	elseif wanted.LOCK_CAMERA ~= true and wanted.LOCK_CAMERA ~= nil then
		problems[#problems + 1] = 'STAGE.LOCK_CAMERA is not a boolean: the camera is locked'
	end
end

--- The configuration problems to log once at start.
-- @author dop42
-- @return string[]
function Stage.Problems()
	return problems
end

--- Whether the stage is configured to come up at all.
-- @author dop42
-- @return boolean
function Stage.Enabled()
	return enabled
end

--- Whether the camera is on the character right now.
-- @author dop42
-- @return boolean
function Stage.Up()
	return up
end

--- Whether the controls or the fallback hold are holding the character.
-- @author dop42
-- @return boolean
function Stage.Frozen()
	if not up or not freeze or not holdWanted then return false end
	if not controlsBroken then return controlsHeld end
	return pinWanted and not pinBroken
end

--- Whether the mouse is kept off the camera right now.
-- @author dop42
-- @return boolean
function Stage.CameraLocked()
	return up and lockCamera and controlsHeld and not controlsBroken
end

--- Asks the perspective arbiter for third person.
-- The orbit is a VIEW of third person, so it has to be third person first; a
-- policy that forces first person refuses, and the orbit refuses after it.
local function askThirdPerson()
	local perspective = Open77.perspective
	if type(perspective) ~= 'table' or type(perspective.set) ~= 'function' then return end
	pcall(perspective.set, 'tps')
end

--- Remembers the perspective the player asked for.
local function savePerspective()
	savedPerspective = nil
	local perspective = Open77.perspective
	if type(perspective) ~= 'table' then return end
	local read, state = pcall(perspective.state)
	if read and type(state) == 'table' and type(state.requested) == 'string' then
		savedPerspective = state.requested
		return
	end
	local got, current = pcall(perspective.get)
	if got and type(current) == 'string' then savedPerspective = current end
end

--- Turns the camera to the configured side of the character.
local function orbit()
	local camera = Open77.camera
	if type(camera) ~= 'table' or type(camera.orbit) ~= 'function' then
		if not orbitFailing then
			Open77.log.warn('[entry] Open77.camera.orbit is not on this client: ' ..
				'the stage has no camera')
		end
		orbitFailing = true
		return false
	end
	local called, ok, reason = pcall(camera.orbit, orbitDegrees)
	if called and ok then
		if orbitFailing then Open77.log.info('[entry] the stage camera is on the character again') end
		orbitFailing = false
		return true
	end
	if not orbitFailing then
		Open77.log.warn('[entry] the stage camera was refused: ' .. tostring(called and reason or ok))
	end
	orbitFailing = true
	return false
end

--- Settles the controls as unusable for the session and releases what stood.
local function breakControls(reason)
	controlsBroken = true
	Open77.log.error('[entry] ' .. reason)
	local players = Open77.players
	if controlsHeld and type(players) == 'table' and type(players.resetControls) == 'function' then
		pcall(players.resetControls)
	end
	controlsHeld = false
end

--- Asks for one player control, settling them all as broken on a denied grant.
local function acquire(entry)
	local players = Open77.players
	local fn = type(players) == 'table' and players[entry[1]] or nil
	if type(fn) ~= 'function' then
		breakControls(('Open77.players.%s is not on this client: the camera is not locked, ' ..
			'and the character is held by teleport'):format(entry[1]))
		return false
	end
	local called, ok, reason = pcall(fn, entry[2])
	if called and ok then return true end
	reason = tostring(called and reason or ok)
	if reason:find('permission_denied', 1, true) then
		breakControls(('the player controls were refused (%s) -- the manifest must grant ' ..
			'players.controls'):format(reason))
		return false
	end
	if not controlsFailing then
		Open77.log.warn(('[entry] Open77.players.%s was refused: %s'):format(entry[1], reason))
	end
	controlsFailing = true
	return false
end

--- Asks again for every control the stage wants now.
-- Asked again on every tick rather than trusted to stand: the host drops every
-- block on death and on a body replacement, and a creation's body change is one.
local function applyControls()
	if controlsBroken then return end
	local wantBody = freeze and holdWanted
	if not wantBody and not lockCamera then return end
	local all = true
	if lockCamera then
		controlsHeld = true
		all = acquire(CAMERA_CONTROL) and all
	end
	if wantBody and not controlsBroken then
		controlsHeld = true
		for index = 1, #BODY_CONTROLS do
			if controlsBroken then break end
			all = acquire(BODY_CONTROLS[index]) and all
		end
	end
	if all and controlsFailing and not controlsBroken then
		Open77.log.info('[entry] the stage controls are held again')
		controlsFailing = false
	end
end

--- Releases every control block this runtime holds.
-- `resetControls` releases this VM's blocks and nothing else: another resource's
-- blocks and the game's own restrictions are untouched.
local function releaseControls()
	if not controlsHeld then return end
	controlsHeld = false
	controlsFailing = false
	local players = Open77.players
	if type(players) ~= 'table' or type(players.resetControls) ~= 'function' then return end
	local called, ok, reason = pcall(players.resetControls)
	if not called or not ok then
		Open77.log.warn('[entry] the stage controls did not release: ' ..
			tostring(called and reason or ok))
	end
end

--- Horizontal distance and turn from the anchor.
local function drift(x, y, yaw)
	local dx, dy = x - anchor.x, y - anchor.y
	local turned = math.abs((yaw - anchor.yaw + 180) % 360 - 180)
	return math.sqrt(dx * dx + dy * dy), turned
end

--- Puts a character that walked off back where it stood.
local function pinPass()
	local read, character = pcall(Open77.character.state)
	if not read or type(character) ~= 'table' or character.attached ~= true or
		character.alive ~= true then
		anchor = nil
		return
	end
	-- A placement or a respawn in progress is held from wherever it lands, and a
	-- character in a vehicle is not standing anywhere to be held.
	if character.inVehicle == true then
		anchor = nil
		return
	end

	local position = type(character.position) == 'table' and character.position or {}
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if not OPX.Math.IsFinite(x) or not OPX.Math.IsFinite(y) or not OPX.Math.IsFinite(z) then
		return
	end
	local yaw = tonumber(character.yaw)
	if not OPX.Math.IsFinite(yaw) then yaw = anchor ~= nil and anchor.yaw or 0.0 end

	if anchor == nil then
		anchor = { x = x, y = y, yaw = yaw }
		return
	end
	local metres, turned = drift(x, y, yaw)
	if metres > PIN_CEILING_M then
		anchor = { x = x, y = y, yaw = yaw }
		return
	end
	if metres <= PIN_FLOOR_M and turned <= PIN_TURN_DEGREES then return end

	local travel = Open77.travel
	if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then
		pinBroken = true
		Open77.log.warn('[entry] Open77.travel.teleport is not on this client: ' ..
			'the character is not held')
		return
	end
	-- The height is left to the game: a character held in the air while it lands
	-- would stay there.
	local called, ok, reason = pcall(travel.teleport, anchor.x, anchor.y, z, anchor.yaw)
	if called and ok then
		pinFailing = false
		return
	end
	reason = tostring(called and reason or ok)
	if reason:find('permission_denied', 1, true) then
		pinBroken = true
		Open77.log.error('[entry] the character cannot be held (' .. reason ..
			') -- the manifest must grant player.travel')
		return
	end
	if not pinFailing then
		Open77.log.warn('[entry] holding the character was refused: ' .. reason)
	end
	pinFailing = true
end

--- Starts or stops the fallback hold from a fresh anchor.
-- Every start takes a new anchor: the character is held from where it stands
-- now, not from where a previous hold left it.
local function setPin(wanted)
	if wanted == pinWanted then return end
	pinWanted = wanted
	anchor = nil
	pinFailing = false
end

--- Saves the perspective and puts the stage camera up.
local function raise()
	if up then return end
	up = true
	orbitFailing = false
	savePerspective()
	askThirdPerson()
	orbit()
end

--- Releases the hold, the controls, the orbit and the perspective.
local function lower()
	setPin(false)
	holdWanted = false
	releaseControls()
	if not up then return end
	up = false
	local camera = Open77.camera
	if type(camera) == 'table' and type(camera.clearOrbit) == 'function' then
		local called, failure = pcall(camera.clearOrbit)
		if not called then
			Open77.log.warn('[entry] the stage camera did not clear: ' .. tostring(failure))
		end
	end
	local perspective = Open77.perspective
	if savedPerspective ~= nil and type(perspective) == 'table' and
		type(perspective.set) == 'function' then
		pcall(perspective.set, savedPerspective)
	end
	savedPerspective = nil
	orbitFailing = false
end

--- Puts the stage up or takes it down; repeating either costs nothing.
-- @author dop42
-- @param wanted boolean
-- @param hold boolean|nil Whether the fallback hold may run.
function Stage.Set(wanted, hold)
	if not wanted then
		lower()
		return
	end
	if not enabled then return end
	raise()
	local fresh = freeze and not holdWanted
	if fresh then holdWanted = true end
	-- Asked for at once rather than on the next tick: a walk key already held
	-- down must not win a step while the block is a quarter of a second away.
	if fresh or not controlsHeld then applyControls() end
	setPin(freeze and controlsBroken and hold == true)
end

--- Asks for the orbit and the controls again, and corrects the fallback hold.
-- @author dop42
function Stage.Tick()
	if not up then return end
	-- A refused orbit asks for third person again before the next try: a world
	-- entry can have reset the perspective under it.
	if orbitFailing then askThirdPerson() end
	orbit()
	applyControls()
	if pinWanted and not pinBroken then pinPass() end
end
