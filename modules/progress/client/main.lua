--- The bar, the clock and the lock.
-- @author dop42
--
-- ONE BAR AT A TIME and one place that ends it. `finish` is the only function
-- that takes a bar down: it releases the lock, stops the gesture, tells the
-- page and answers the caller, in that order and on every path -- the clock
-- running out, a caller stopping it, the player going down, the character
-- leaving, the module stopping. A second exit written anywhere else is a lock
-- left on a player who can no longer move, which is the one failure this file
-- must not have.
--
-- THE LOCK IS A CLAIM, NOT A SWITCH, which is what makes it safe to hold.
-- `Open77.input.setActionBlocked` is owned by the calling resource: two
-- resources may block the same action, `false` removes only ours, and
-- everything a resource holds is released when it stops. So a bar cannot free a
-- player another module is holding, and a crash cannot leave them frozen for
-- the session.

local M = OPX.Modules.Get('progress')

M.Runtime = {}
local Runtime = M.Runtime

local Ending = M.Ending

-- The page channels. `OPX.UI.Send` prefixes the surface id.
local SURFACE = 'overlay'
local CHANNEL_SHOW = 'progress:show'
local CHANNEL_HIDE = 'progress:hide'

-- How often the bar is re-decided. The page animates between frames off the
-- deadline it was given, so this is the rate at which the CLOCK is checked and
-- not the rate at which the bar moves: a caller cannot see the difference and
-- the scheduler runs four jobs a resume.
local TICK_MS = 100

-- The bar that is up, or nil. `{ owner, label, untilMs, lockable, canCancel,
-- animation, ending }`.
local live = nil

-- The actions this module currently holds, so a release names exactly what a
-- take named. Reading the config again at release time would free the wrong set
-- if it changed under a live bar.
local locked = nil

local job = nil

--- Reads the settings once, with the shipped values for anything unusable.
local function tuning()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local floor = tonumber(settings.MIN_MS)
	local ceiling = tonumber(settings.MAX_MS)
	return {
		min = (floor ~= nil and floor >= 100 and floor <= 60000) and math.floor(floor) or 250,
		max = (ceiling ~= nil and ceiling >= 1000 and ceiling <= 600000)
			and math.floor(ceiling) or 60000,
		lock = settings.LOCK ~= false,
	}
end

--- Takes or releases the input claim.
--
-- EVERY REFUSAL IS REPORTED ONCE AND NONE IS FATAL. A build that cannot block an
-- action still shows the bar; the player can walk out of it, which is worse than
-- being held and far better than no bar at all. The names come from `M.LOCKED`,
-- which is the platform's own five-word vocabulary -- anything else answers
-- `unknown_action`.
local function hold(on)
	local input = Open77.input
	if type(input) ~= 'table' or type(input.setActionBlocked) ~= 'function' then return end

	if on then
		locked = {}
		for index = 1, #M.LOCKED do
			local action = M.LOCKED[index]
			local ok, reason = pcall(input.setActionBlocked, action, true)
			if ok then
				locked[#locked + 1] = action
			else
				Open77.log.warn(('[progress] %s could not be blocked: %s')
					:format(action, tostring(reason)))
			end
		end
		return
	end

	-- RELEASES WHAT WAS TAKEN, not what the config says to take. The two are the
	-- same today and would stop being the same the moment somebody edits the
	-- list while a bar is up.
	for index = 1, #(locked or {}) do
		pcall(input.setActionBlocked, locked[index], false)
	end
	locked = nil
end

--- Ends the bar that is up, however it ended. The only exit.
-- @author dop42
-- @param ending string one of `M.Ending`
local function finish(ending)
	local ended = live
	if ended == nil then return end
	live = nil

	hold(false)

	-- The gesture goes with the bar. Asked for by name and not required: a
	-- runtime without `animations` simply never had one to stop.
	if ended.animation ~= nil then
		local animations = OPX.Api.Get('animations')
		if animations ~= nil then pcall(animations.Stop, ended.owner) end
	end

	OPX.UI.Send(SURFACE, CHANNEL_HIDE, {})
	TriggerEvent(M.Event.ON_STATE, { open = false })
	TriggerEvent(M.Event.ON_DONE, {
		owner = ended.owner,
		label = ended.label,
		ending = ending,
		finished = ending == Ending.FINISHED,
	})
end

--- One pass: ends a bar whose clock ran out, or whose player is no longer there.
local function pass()
	if live == nil then return end

	-- DOWN TAKES THE BAR WITH IT, and it is checked here rather than wired to an
	-- event because a bar has to end on the one that is true NOW, not on the one
	-- that fired while nothing was up.
	local downed = OPX.Api.Get('downed')
	if downed ~= nil then
		local answer = downed.IsDown()
		if answer ~= nil and answer.ok == true and answer.value.down == true then
			return finish(Ending.INTERRUPTED)
		end
	end

	if OPX.Now() >= live.untilMs then return finish(Ending.FINISHED) end
end

--- Puts a bar up.
--
-- Answers whether the bar is UP, not whether the action happened: the outcome
-- arrives on `ON_DONE`. A caller that needs to act on completion listens; one
-- that only wanted the picture ignores it.
-- @author dop42
-- @param owner string the caller's own name, for expiry and for `Stop`
-- @param spec table { label, durationMs, animation, cancelable }
-- @return table a Result
function Runtime.Start(owner, spec)
	if type(owner) ~= 'string' or owner == '' then
		return OPX.Result.Err('invalid_caller', 'a progress bar needs an owner name')
	end
	if type(spec) ~= 'table' then
		return OPX.Result.Err('invalid_spec', 'a progress bar needs a spec table')
	end
	-- ONE AT A TIME. A second bar over the first is two clocks and two locks
	-- racing to release the same actions; the caller decides whether that is an
	-- error for them.
	if live ~= nil then
		return OPX.Result.Err('progress_busy', ('%s already has one up'):format(live.owner))
	end

	local settings = tuning()
	local duration = tonumber(spec.durationMs)
	if duration == nil or duration < settings.min or duration > settings.max then
		return OPX.Result.Err('invalid_duration',
			('durationMs must be %d to %d'):format(settings.min, settings.max))
	end
	duration = math.floor(duration)

	local label = type(spec.label) == 'string' and OPX.Text.Bytes(spec.label, 64) or nil
	if label == nil or label == '' then
		return OPX.Result.Err('invalid_label', 'a progress bar needs something to say')
	end

	live = {
		owner = owner,
		label = label,
		untilMs = OPX.Now() + duration,
		animation = type(spec.animation) == 'table' and spec.animation or nil,
		-- Cancelling is opt-IN. The case this was written for is one the player
		-- must see through, so a caller that wants an escape says so.
		canCancel = spec.cancelable == true,
	}

	if settings.lock then hold(true) end

	-- THE GESTURE IS STARTED HERE AND NOT BY THE CALLER, so the two cannot drift:
	-- one call puts both up and `finish` takes both down. `cancelable = false` on
	-- the animation as well, or the player could end the gesture and leave the
	-- bar counting over a body standing still.
	if live.animation ~= nil then
		local animations = OPX.Api.Get('animations')
		if animations == nil then
			Open77.log.debug('[progress] no animations contract: the bar has no gesture')
			live.animation = nil
		else
			local played = animations.Play(live.animation.name, {
				variant = live.animation.variant,
				loop = true,
				durationMs = duration,
				cancelable = false,
			}, owner)
			if type(played) == 'table' and played.ok ~= true then
				Open77.log.debug(('[progress] %s was refused: %s')
					:format(tostring(live.animation.name), tostring(played.error)))
				live.animation = nil
			end
		end
	end

	-- The page is given the DEADLINE and not a percentage: it animates between
	-- our passes off its own clock, so the bar is smooth at any tick rate and a
	-- dropped frame costs nothing.
	OPX.UI.Send(SURFACE, CHANNEL_SHOW, {
		label = label,
		durationMs = duration,
		cancelable = live.canCancel,
	})
	TriggerEvent(M.Event.ON_STATE, { open = true, owner = owner, label = label })

	return OPX.Result.Ok({ owner = owner, durationMs = duration })
end

--- Takes a bar down early. Only its own owner may.
-- @author dop42
-- @param owner string
-- @param ending string|nil defaults to `stopped`
-- @return table a Result
function Runtime.Stop(owner, ending)
	if live == nil then return OPX.Result.Err('progress_not_active', 'no bar is up') end
	if live.owner ~= owner then
		return OPX.Result.Err('not_owner', ('%s put it up'):format(live.owner))
	end
	finish(ending == Ending.CANCELLED and Ending.CANCELLED or Ending.STOPPED)
	return OPX.Result.Ok(true)
end

--- Whether a bar is up, and whose.
-- @author dop42
-- @return table a Result
function Runtime.State()
	if live == nil then return OPX.Result.Ok({ open = false }) end
	return OPX.Result.Ok({
		open = true,
		owner = live.owner,
		label = live.label,
		remainingMs = math.max(0, live.untilMs - OPX.Now()),
	})
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	live, locked, job = nil, nil, nil
end

--- Publishes the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('progress', 1, {
		Start = Runtime.Start,
		Stop = Runtime.Stop,
		State = Runtime.State,
	})
end

--- Wires the doors and starts the pass.
-- @author dop42
function M.Start()
	-- The page's own cancel. Believed only when the bar allowed one, and named
	-- `cancelled` rather than `stopped` so a listener can tell a player giving up
	-- from a caller changing its mind.
	OPX.UI.On(SURFACE, 'progress:cancel', function()
		if live ~= nil and live.canCancel then finish(Ending.CANCELLED) end
	end)

	RegisterNetEvent(M.Event.START, function(spec)
		if type(spec) ~= 'table' then return end
		-- A server-sent bar is owned by the SERVER and not by whatever module
		-- happens to be listening, so a client caller's `Stop` cannot take it
		-- down. Same shape and same reason as the prompts module's prefix.
		Runtime.Start('@server', spec)
	end)

	RegisterNetEvent(M.Event.CANCEL, function()
		if live ~= nil and live.owner == '@server' then finish(Ending.STOPPED) end
	end)

	-- A CHARACTER LEAVING TAKES THE BAR, and this is the path that would
	-- otherwise leave a lock on somebody who is no longer the person who took it.
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), function()
		finish(Ending.INTERRUPTED)
	end)

	job = OPX.Scheduler.Every('progress.pass', TICK_MS, pass)
end

--- Takes the bar down and gives the lock back.
-- @author dop42
function M.Stop()
	if job ~= nil then
		OPX.Scheduler.Cancel(job)
		job = nil
	end
	finish(Ending.INTERRUPTED)
end
