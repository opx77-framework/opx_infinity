--- The noclip speed keys, and the travel controls on the key strip.
-- @author dop42
--
-- The keys do not set a speed: they CHOOSE one, and send it as
-- `opx.admin.self.speed` once the player has stopped pressing. The server applies
-- it and answers, which is what this file then draws. A key that wrote the native
-- directly would be a travel mode nobody granted.
--
-- The pass is registered with `OPX.Scheduler` and never spawned as a loop of its
-- own: exceeding the per-resume instruction budget unwinds out of a coroutine
-- body and a `while true ... Wait(n)` loop that hits it is never resumed again,
-- silently. The pass returns at once while nothing is armed.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Keys = M.Keys

M.Controls = {}
local Controls = M.Controls

-- The strip group ids, and the priority that puts them above gameplay groups.
local GROUP_NOCLIP, GROUP_MAP = 'noclip', 'maptravel'
local NOCLIP_PRIORITY = 50

-- Milliseconds before a held speed key first repeats, and between repeats.
local REPEAT_DELAY_MS, REPEAT_MS = 350, 110

-- Milliseconds between two passes over the native, the body and the strip.
local TICK_MS = 100

-- Consecutive off readings, and the settling time, before the strip believes the
-- native rather than what the server last said. One reading is not enough: the
-- native answers off for a frame or two after it is switched on.
local OFF_READS, OFF_SETTLE_MS = 3, 1000

-- Milliseconds a keyed send's answer is taken as belonging to the keys.
local ANSWER_WINDOW_MS = 5000

-- The settings, read once at start and bounded there.
local minSpeed, maxSpeed, step, startSpeed = 1.0, 500.0, 0.15, 40.0
local sendAfterMs, showPrompts = 500, true

-- Whether a server command switched noclip on, or armed map travel, here.
local noclipOn, mapOn = false, false

-- When noclip was last switched, and how many ticks the native has said off.
local noclipSinceMs, offReads = 0, 0

-- The speed the server applied, the one the keys chose, and the one on its way.
local applied, wanted, sent = nil, nil, nil
local sentAtMs = -math.huge

-- When a speed key last stepped, which direction is held, and when it repeats.
local lastStepMs, held, nextRepeatMs = 0, 0, 0

-- Signature of the noclip group last put in the strip, and whether the map group
-- is up. Nil and false mean the strip holds nothing of ours.
local shownNoclip, shownMap = nil, false

-- The scheduler handle, so Stop takes the pass down with the module.
local job

-- Whether a missing or refusing strip was reported.
local promptsReported = false

-- A speed written the way commands and the strip show it.
local function format(speed)
	return ('%g'):format(speed)
end

-- The speed to show: chosen, applied, or the configured starting one.
local function current()
	return wanted or applied or startSpeed
end

-- One proportional speed step up or down, rounded and bounded.
local function stepped(speed, direction)
	local nextSpeed = direction > 0 and speed * (1 + step) or speed / (1 + step)
	-- A proportional step is under half a metre a second at walking speed, which
	-- a player cannot feel; below that it becomes a fixed step.
	if math.abs(nextSpeed - speed) < 0.5 then nextSpeed = speed + 0.5 * direction end
	if nextSpeed < 10 then
		nextSpeed = math.floor(nextSpeed * 2 + 0.5) / 2
	else
		nextSpeed = math.floor(nextSpeed + 0.5)
	end
	return math.max(minSpeed, math.min(maxSpeed, nextSpeed))
end

-- Whether the native still reports noclip on; true when it cannot be read, so a
-- build without the reader never switches the strip off by itself.
local function nativeNoclip()
	local read = Client.TravelNative('isNoclip')
	if read == nil then return true end
	local ok, on = pcall(read)
	return not ok or on == true
end

-- Whether the character is alive; true when it cannot be read.
local function alive()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return true end
	local ok, state = pcall(character.state)
	if not ok or type(state) ~= 'table' then return true end
	return state.alive ~= false
end

-- The strip, or nil when it is not wanted or not running.
local function strip()
	if not showPrompts then return nil end
	local contract = Client.Contract('prompts')
	if contract ~= nil then return contract end
	if not promptsReported then
		promptsReported = true
		Open77.log.info('[admin] no prompts contract: the travel controls are not drawn')
	end
	return nil
end

-- The noclip group's rows, named by the keys the player actually has.
local function noclipSpec()
	local rows = {
		{ id = 'move', keys = 'W A S D', label = locale('admin.prompt.move') },
		{ id = 'updown', keys = { 'SPACE', 'CTRL' }, label = locale('admin.prompt.upDown') },
	}
	local speedKeys = {}
	if Keys.Effective(Keys.FASTER) then speedKeys[#speedKeys + 1] = { action = Keys.FASTER } end
	if Keys.Effective(Keys.SLOWER) then speedKeys[#speedKeys + 1] = { action = Keys.SLOWER } end
	if #speedKeys > 0 then
		rows[#rows + 1] = { id = 'speed', keys = speedKeys, label = locale('admin.prompt.speed'),
			value = locale('admin.prompt.speedValue', { speed = format(current()) }) }
	end
	rows[#rows + 1] = { id = 'fast', keys = 'SHIFT', hold = true, label = locale('admin.prompt.fast') }
	rows[#rows + 1] = { id = 'slow', keys = 'ALT', hold = true, label = locale('admin.prompt.slow') }
	if Keys.Effective(Keys.MENU) then
		rows[#rows + 1] = { id = 'off', keys = { action = Keys.MENU },
			label = locale('admin.prompt.off') }
	end
	return { title = locale('admin.prompt.noclip'), priority = NOCLIP_PRIORITY, rows = rows }
end

-- The map travel group, which says a double-click travels.
local function mapSpec()
	return { title = locale('admin.prompt.map'), priority = NOCLIP_PRIORITY - 1, rows = {
		{ id = 'travel', keys = locale('admin.prompt.doubleClick'),
			label = locale('admin.prompt.mapTravel') },
	} }
end

-- Brings the strip groups in line with the modes, the body and the speed.
local function sync()
	local body = alive()
	local wantNoclip = noclipOn and body
	local wantMap = mapOn and body
	-- The signature holds everything the group DRAWS, so a rebind or a speed
	-- change redraws it and nothing else does.
	local signature = wantNoclip and table.concat({ format(current()),
		tostring(Keys.Effective(Keys.FASTER) ~= nil), tostring(Keys.Effective(Keys.SLOWER) ~= nil),
		tostring(Keys.Effective(Keys.MENU) ~= nil) }, '|') or nil
	if signature == shownNoclip and wantMap == shownMap then return end

	local prompts = strip()
	if prompts == nil then
		shownNoclip, shownMap = nil, false
		return
	end

	local noclipChanged, mapChanged = signature ~= shownNoclip, wantMap ~= shownMap
	shownNoclip, shownMap = signature, wantMap

	if noclipChanged then
		local result
		if signature == nil then
			result = prompts.Hide(M.OWNER, GROUP_NOCLIP)
		else
			result = prompts.Show(M.OWNER, GROUP_NOCLIP, noclipSpec())
		end
		if not result.ok and not promptsReported then
			promptsReported = true
			Open77.log.warn('[admin] noclip prompts refused: ' .. tostring(result.error))
		end
	end
	if mapChanged then
		if wantMap then
			prompts.Show(M.OWNER, GROUP_MAP, mapSpec())
		else
			prompts.Hide(M.OWNER, GROUP_MAP)
		end
	end
end

-- Chooses the next speed in one direction and redraws.
local function chooseStep(direction)
	local nextSpeed = stepped(current(), direction)
	lastStepMs = Client.NowMs()
	if nextSpeed == current() then return end
	wanted = nextSpeed
	sync()
end

-- Sends the chosen speed once the keys have been quiet long enough.
local function flush(atMs)
	if wanted == nil or held ~= 0 or atMs - lastStepMs < sendAfterMs then return end
	if applied ~= nil and math.abs(wanted - applied) < 0.001 then
		wanted = nil
		return
	end
	-- One line in flight at a time: the server's own floor would refuse a second.
	if sent ~= nil and math.abs(wanted - sent) < 0.001 and atMs - sentAtMs < ANSWER_WINDOW_MS then
		return
	end
	if Client.Execute({ M.Command.SELF_SPEED, format(wanted) }) then
		sent, sentAtMs = wanted, atMs
	else
		wanted = nil
		sync()
	end
end

-- One pass: follows the native, repeats a held key, sends and redraws.
local function pass()
	if not (noclipOn or mapOn or wanted ~= nil) then return end
	local atMs = Client.NowMs()
	if noclipOn and not nativeNoclip() then
		offReads = offReads + 1
		if offReads >= OFF_READS and atMs - noclipSinceMs >= OFF_SETTLE_MS then
			noclipOn, held, wanted = false, 0, nil
		end
	else
		offReads = 0
	end
	if OPX.Keys.IsCaptured() then held = 0 end
	if held ~= 0 and atMs >= nextRepeatMs then
		nextRepeatMs = atMs + REPEAT_MS
		chooseStep(held)
	end
	flush(atMs)
	sync()
end

-- A speed key went down while noclip is on.
local function pressed(direction)
	if not noclipOn then return end
	held = direction
	nextRepeatMs = Client.NowMs() + REPEAT_DELAY_MS
	chooseStep(direction)
end

-- A speed key went up.
local function released(direction)
	if held == direction then held = 0 end
end

--- Noclip was switched by a server command and the native took it.
-- @author dop42
-- @param on boolean
function Controls.Noclip(on)
	noclipOn = on == true
	noclipSinceMs, offReads = Client.NowMs(), 0
	if not noclipOn then held, wanted = 0, nil end
	sync()
end

--- Map travel was armed or disarmed by a server command.
-- @author dop42
-- @param on boolean
function Controls.MapPick(on)
	mapOn = on == true
	sync()
end

--- The server applied a noclip speed.
-- @author dop42
-- @param speed number
function Controls.Speed(speed)
	applied = speed
	if wanted ~= nil and math.abs(wanted - speed) < 0.001 then wanted = nil end
	sync()
end

--- Whether an accepted answer to a keyed speed stays off the toasts.
-- A player holding a key is not asking to be told eight times that it worked.
-- @author dop42
-- @param raw string
-- @param accepted boolean
-- @return boolean
function Controls.Answered(raw, accepted)
	local name = (raw:match('^/?(%S+)') or ''):lower()
	if name ~= M.Command.SELF_SPEED or sent == nil then return false end
	if Client.NowMs() - sentAtMs > ANSWER_WINDOW_MS then return false end
	if accepted then return true end
	sent, wanted = nil, nil
	sync()
	return false
end

--- Reads the settings, declares the two speed keys and registers the pass.
-- @author dop42
function Controls.Start()
	local noclip = M.Section('NOCLIP')
	local rate = M.Section('RATE')
	minSpeed = M.Bounded('NOCLIP.MIN_SPEED', noclip.MIN_SPEED, 0.1, 500, 1.0)
	maxSpeed = M.Bounded('NOCLIP.MAX_SPEED', noclip.MAX_SPEED, minSpeed, 500, 500.0)
	step = M.Bounded('NOCLIP.STEP', noclip.STEP, 0.01, 1, 0.15)
	startSpeed = M.Bounded('NOCLIP.SPEED', noclip.SPEED, 0.1, 500, 40.0)
	showPrompts = noclip.PROMPTS ~= false
	-- Never quicker than the server's own floor plus a little: a send inside it
	-- is refused, and the refusal would undo the speed the player just chose.
	local floor = math.floor(M.Bounded('RATE.ACTION_MS', rate.ACTION_MS, 0, 60000, 400)) + 100
	sendAfterMs = math.max(floor,
		math.floor(M.Bounded('NOCLIP.SEND_AFTER_MS', noclip.SEND_AFTER_MS, 0, 10000, 500)))

	local configured = M.Section('KEYS')
	Keys.Register(Keys.FASTER, 'admin.key.speedUp',
		Keys.Setting('KEYS.SPEED_UP', configured.SPEED_UP, 'PAGEUP'),
		function() pressed(1) end, function() released(1) end)
	Keys.Register(Keys.SLOWER, 'admin.key.speedDown',
		Keys.Setting('KEYS.SPEED_DOWN', configured.SPEED_DOWN, 'PAGEDOWN'),
		function() pressed(-1) end, function() released(-1) end)

	Keys.OnChanged(sync)
	job = OPX.Scheduler.Every('admin.controls', TICK_MS, pass)
end

--- Takes the travel groups off the strip.
-- @author dop42
function Controls.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local prompts = Client.Contract('prompts')
	if prompts ~= nil then prompts.HideAll(M.OWNER) end
	shownNoclip, shownMap = nil, false
	noclipOn, mapOn, held, wanted = false, false, 0, nil
end
