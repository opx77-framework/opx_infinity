--- The projection: command answers, snapshot validation and applying the sky.
-- @author dop42
--
-- The client decides nothing. It accepts a snapshot, anchors it on its own
-- monotonic clock and projects from there, so a client that can no longer reach
-- the authority keeps the last sky it was given and goes on telling the time.

local M = OPX.Modules.Get('weather')
local Clock = M.Clock
local SYNC = M.SYNC

M.Projection = {}
local Projection = M.Projection

-- Client to server event asking for a snapshot.
local EVENT_REQUEST = OPX.Event(OPX.Channel.NET, 'weather', 'request')

-- Server to client event carrying a snapshot.
local EVENT_SYNC = OPX.Event(OPX.Channel.NET, 'weather', 'sync')

-- Server to client answer to a staff command.
local EVENT_NOTICE = OPX.Event(OPX.Channel.NET, 'weather', 'notice')

-- Local event raised after a snapshot is accepted, and the integration point
-- other resources listen on: a client's local events cross resources, a
-- server's do not. It must stay on the LOCAL channel -- the host dispatcher
-- matches on the name alone, so a local raise on the NET name would re-enter the
-- snapshot handler below.
local EVENT_UPDATED = OPX.Event(OPX.Channel.LOCAL, 'weather', 'updated')

-- Game seconds of drift tolerated before the clock is corrected.
local DRIFT_TOLERANCE = SYNC.DRIFT_TOLERANCE_SECONDS

-- Resource that raises toasts for command answers. Not a dependency: without it
-- the answers become chat lines and the weather is unaffected.
local NOTIFY = 'opx77_notify'

-- Whether a failed toast has already been logged once.
local notifyReported = false

-- Environment natives the client half requires before doing anything else.
local NATIVES = { 'setWeather', 'setTime', 'getTime', 'setWeatherFrozen', 'isWeatherFrozen',
	'setTimeFrozen' }

-- When the last snapshot was applied, for the sync handler floor.
local lastApplyMs

-- Id of the last sync request sent.
local requestSequence = 0

-- Local send time of each pending sync request.
local requests = {}

-- Second-of-day the clock was last applied or accepted at.
local lastAppliedSecond = nil

-- Weather revision last submitted to the engine.
local lastWeatherRevision = nil

-- Whether the engine clock is held, as last set.
local lastTimeFrozen = nil

-- Whether this module has stopped, so a deferred snapshot is not applied after
-- the locks have been handed back.
local stopped = false

-- Configured command names, lowercased, to recognise our own answers.
local COMMAND_NAMES = {}

-- Prints a command answer as a chat line. It carries its type and no colour:
-- opx77_chat's `.line.info` and `.line.error` tokens colour it.
local function chatLine(kind, message)
	local accepted = kind == 'success' or kind == 'report'
	TriggerEvent('chat:addMessage', {
		type = accepted and 'info' or 'error',
		author = locale('weather.title'),
		text = message,
	})
end

-- Shows the server's command answer as a toast or a chat line. A report someone
-- asked to read stays in the chat box, where it can be re-read and compared; an
-- action answers with a toast in one replaced slot, so staff walking the clock
-- forward sees the last answer rather than a stack.
local function onNotice(raw, kind, message)
	if type(raw) ~= 'string' or type(message) ~= 'string' or message == '' then return end
	if kind ~= 'report' and kind ~= 'success' and kind ~= 'warning' and kind ~= 'error' then
		kind = 'error'
	end
	local accepted = kind == 'success' or kind == 'report'
	local line = ('command answered: %s (%s)'):format(raw, accepted and 'accepted' or 'refused')
	if accepted then Open77.log.info(line) else Open77.log.warn(line) end

	if kind == 'report' then return chatLine(kind, message) end
	CreateThread(function()
		-- Its own thread: the call yields on the remote's promise.
		local shown = OPX.Lib.Rpc.Call(NOTIFY, 'show', {
			id = 'opx.weather.answer',
			replace = true,
			type = kind,
			title = locale('weather.title'),
			message = message,
			durationMs = 6000,
		})
		if shown.ok then return end
		if not notifyReported then
			notifyReported = true
			Open77.log.warn(('no toast (%s): answers go to the chat box instead'):format(shown.error))
		end
		chatLine(kind, message)
	end)
end

-- Asks the authority for an addressed snapshot.
local function requestSync()
	local atMs = OPX.Now()
	for id, sentAt in pairs(requests) do
		if atMs - sentAt > SYNC.CLIENT_SYNC_MS * 4 then requests[id] = nil end
	end

	requestSequence = requestSequence + 1
	requests[requestSequence] = atMs
	local ok, reason = TriggerServerEvent(EVENT_REQUEST, requestSequence)
	if not ok then
		requests[requestSequence] = nil
		Open77.log.warn('sync request failed: ' .. tostring(reason))
	end
end

-- Whether a snapshot carries every field, in bounds, worth acting on. One false
-- field and nothing is applied. `nextRollInMs` absent is an answer and not an
-- omission: it is missing while the schedule is held. `weather` and
-- `weatherPreset` are empty together or not at all -- the empty pair is an
-- authority with no usable preset, one of the two empty is an incoherent
-- payload.
local function valid(value)
	if type(value) ~= 'table' then return false end
	if value.protocol ~= M.PROTOCOL then return false end
	if not Clock.Whole(value.authorityEpoch, 0) then return false end
	if not Clock.Whole(value.revision, 1) then return false end
	if not Clock.Whole(value.weatherRevision, 1) then return false end
	if not Clock.Finite(value.secondsOfDay) or value.secondsOfDay < 0
		or value.secondsOfDay >= Clock.DAY_SECONDS then
		return false
	end
	-- Past MAX_RATE every drift correction is a jump of the world.
	if not Clock.Finite(value.rate) or value.rate <= 0 or value.rate > Clock.MAX_RATE then
		return false
	end
	if type(value.timeFrozen) ~= 'boolean' then return false end
	if type(value.weatherFrozen) ~= 'boolean' then return false end
	if type(value.weather) ~= 'string' or type(value.weatherPreset) ~= 'string' then return false end
	if (value.weather == '') ~= (value.weatherPreset == '') then return false end
	if not Clock.Whole(value.weatherPriority, 0) then return false end
	if not Clock.Finite(value.transitionSeconds) or value.transitionSeconds < 0
		or value.transitionSeconds > M.MAX_TRANSITION_SECONDS then
		return false
	end
	if not Clock.Finite(value.weatherTransitionRemainingMs)
		or value.weatherTransitionRemainingMs < 0
		or value.weatherTransitionRemainingMs > M.MAX_TRANSITION_SECONDS * 1000 then
		return false
	end
	if value.nextRollInMs ~= nil
		and (not Clock.Finite(value.nextRollInMs) or value.nextRollInMs < 0) then
		return false
	end
	if type(value.reason) ~= 'string' then return false end
	return true
end

-- Where the clock should stand locally, from the accepted snapshot.
local function projectedSeconds()
	local state = Projection.state
	if state == nil then return nil end
	return Clock.At(state.secondsOfDay, state.anchorLocalMs, state.rate,
		state.timeFrozen, OPX.Now())
end

-- Holds and corrects the engine clock past the drift tolerance. Between two
-- corrections the engine's own clock runs the seconds.
-- `allowRewind` is true when a mutation or a new epoch really moved the
-- authority.
local function applyTime(allowRewind)
	local expected = projectedSeconds()
	if expected == nil then return end
	-- The freeze is set in the engine too, and only on a change: a held
	-- authority projects one second forever, and the "second unchanged" return
	-- below would then never look at the engine again, leaving the engine's own
	-- clock running free.
	local held = Projection.state.timeFrozen
	if held ~= lastTimeFrozen then
		local frozenOk, frozenReason = Open77.environment.setTimeFrozen(held)
		if frozenOk then
			lastTimeFrozen = held
		else
			Open77.log.warn('time freeze failed: ' .. tostring(frozenReason))
		end
	end

	local whole = math.floor(expected)
	if lastAppliedSecond ~= nil and whole == lastAppliedSecond then return end

	-- `setTime` goes to the NEXT occurrence of an hour, so a packet one second
	-- stale would be applied as a jump of a whole day.
	if lastAppliedSecond ~= nil and not allowRewind then
		if Clock.ForwardDelta(whole, lastAppliedSecond) > Clock.DAY_SECONDS / 2 then return end
	end

	local live = Open77.environment.getTime()
	if type(live) == 'table' then
		local liveSeconds = Clock.Normalize(
			(tonumber(live.hour) or 0) * 3600 + (tonumber(live.minute) or 0) * 60
			+ (tonumber(live.second) or 0))
		local target = Clock.Normalize(whole)
		local drift = math.min(Clock.ForwardDelta(target, liveSeconds),
			Clock.ForwardDelta(liveSeconds, target))
		if drift <= DRIFT_TOLERANCE then
			-- Remembered even though nothing was written: the next pass compares
			-- against this decision.
			lastAppliedSecond = whole
			return
		end
	end

	local hour, minute, second = Clock.ToHms(whole)
	local ok, reason = Open77.environment.setTime(hour, minute, second)
	if ok then
		lastAppliedSecond = whole
	else
		Open77.log.warn('time apply failed: ' .. tostring(reason))
	end
end

-- Seconds of the shared transition still to run locally.
local function remainingTransition()
	local state = Projection.state
	if state == nil then return 0 end
	return math.max(0, state.weatherTransitionEndLocalMs - OPX.Now()) / 1000
end

-- Submits the accepted preset to the engine when it changed. Unforced, it is a
-- no-op once the revision is applied, and retries while it is not.
local function applyWeather(force, transitionSeconds)
	local state = Projection.state
	if state == nil or state.weatherPreset == '' then return end
	if not force and lastWeatherRevision == state.weatherRevision then return end

	local ok, appliedOrReason = Open77.environment.setWeather(
		state.weatherPreset,
		transitionSeconds ~= nil and transitionSeconds or remainingTransition(),
		state.weatherPriority)
	if not ok then
		Open77.log.warn('weather apply failed: ' .. tostring(appliedOrReason))
		return
	end
	lastWeatherRevision = state.weatherRevision
end

-- Accepts a snapshot ordered by epoch then revision, and applies it.
-- `receivedAt` is when it arrived on the local clock, and stays the anchor even
-- for a snapshot the floor held back.
local function apply(value, requestId, receivedAt)
	if not valid(value) then
		Open77.log.warn('invalid snapshot rejected')
		return
	end

	-- A newer epoch wins outright, its revision counter having restarted at 1;
	-- inside one epoch a lower revision is stale.
	local held = Projection.state
	if held ~= nil then
		if value.authorityEpoch < held.authorityEpoch then return end
		if value.authorityEpoch == held.authorityEpoch and value.revision < held.revision then return end
	end

	-- Converted once: a NaN would raise on the way back out as a table key.
	local id = tonumber(requestId)
	if not Clock.Finite(id) then id = nil end
	local sentAt = id ~= nil and requests[id] or nil
	local compensationMs = 0
	if sentAt ~= nil then
		compensationMs = math.min(SYNC.MAX_LATENCY_MS,
			math.max(0, receivedAt - sentAt) / 2)
		requests[id] = nil
	end

	local previousEpoch = held and held.authorityEpoch or nil
	local previousRevision = held and held.revision or nil
	local previousWeatherRevision = held and held.weatherRevision or nil

	-- Half the round trip is added to the hour and taken off the transition; a
	-- broadcast has no round trip and compensates by nothing.
	local seconds = value.secondsOfDay
	if not value.timeFrozen then seconds = seconds + value.rate * compensationMs / 1000 end
	local transitionRemainingMs = math.max(0, value.weatherTransitionRemainingMs - compensationMs)

	Projection.state = {
		authorityEpoch = value.authorityEpoch,
		revision = value.revision,
		weatherRevision = value.weatherRevision,
		secondsOfDay = Clock.Normalize(seconds),
		anchorLocalMs = receivedAt,
		rate = value.rate,
		timeFrozen = value.timeFrozen,
		weather = value.weather,
		weatherPreset = value.weatherPreset,
		weatherPriority = value.weatherPriority,
		weatherFrozen = value.weatherFrozen,
		transitionSeconds = value.transitionSeconds,
		weatherTransitionEndLocalMs = receivedAt + transitionRemainingMs,
		nextRollInMs = value.nextRollInMs,
		latencyCompensationMs = compensationMs,
		reason = value.reason,
	}

	-- Taken on every accepted snapshot that carries a preset, so REDengine does
	-- not run its own cycle under ours. An authority with no usable preset hands
	-- the lock back instead, leaving the engine its own cycle rather than a
	-- frozen sky.
	Open77.environment.setWeatherFrozen(value.weatherPreset ~= '')

	local epochChanged = previousEpoch ~= nil and previousEpoch ~= value.authorityEpoch
	local timeMoved = epochChanged or (previousRevision ~= nil and previousRevision ~= value.revision)
	local weatherMoved = epochChanged or previousWeatherRevision == nil
		or previousWeatherRevision ~= value.weatherRevision

	applyTime(timeMoved)
	applyWeather(weatherMoved, transitionRemainingMs / 1000)
	TriggerEvent(EVENT_UPDATED, Projection.state)

	if previousRevision == nil then
		local hour, minute, second = Clock.ToHms(projectedSeconds())
		Open77.log.info(('synchronized at %02d:%02d:%02d on %s (rtt/2 %.0fms)')
			:format(hour, minute, second, value.weather ~= '' and value.weather or 'no preset',
				compensationMs))
	elseif epochChanged then
		Open77.log.info(('authority changed; adopted revision %d'):format(value.revision))
	end
end

-- Shortest gap in milliseconds between two applied snapshots. On the client a
-- plain `TriggerEvent` also reaches `RegisterNetEvent` handlers and the local bus
-- is shared by every resource, so a resource on the player's machine could forge
-- a snapshot and, with a higher epoch, take this client off the real authority.
-- The floor makes forgery race the server's message instead of looping.
local SYNC_FLOOR_MS = 100

-- Latest snapshot that arrived inside the floor (value, requestId, receivedAt).
local deferred = nil

-- Applies the latest snapshot the floor held back, unless stopped. Deferring
-- rather than dropping: a dropped snapshot made the client wait for the next
-- heartbeat after a staff change, and with a held client clock it refused every
-- snapshot after the first, since a `SetTimeout` delay does not depend on the
-- monotonic reading.
local function applyDeferred()
	local held = deferred
	deferred = nil
	if held == nil or stopped then return end
	lastApplyMs = OPX.Now()
	apply(held.value, held.requestId, held.receivedAt)
end

-- Applies the authority's snapshot, deferring one that lands inside the floor.
local function onSync(value, requestId)
	local atMs = OPX.Now()
	local elapsed = lastApplyMs ~= nil and atMs - lastApplyMs or nil
	if elapsed ~= nil and elapsed < SYNC_FLOOR_MS then
		if deferred == nil then SetTimeout(math.max(0, SYNC_FLOOR_MS - elapsed), applyDeferred) end
		deferred = { value = value, requestId = requestId, receivedAt = atMs }
		return
	end
	deferred = nil
	lastApplyMs = atMs
	apply(value, requestId, atMs)
end

-- Whether a typed command line names one of this module's commands. Compared
-- against the configured names rather than against the word "weather", so a
-- rename in the config follows.
local function ours(raw)
	local typed = raw:match('^/?(%S+)')
	return typed ~= nil and COMMAND_NAMES[typed:lower()] == true
end

-- Mirrors the dispatcher's word on our commands into the log. The channel is
-- shared with other resources, hence the name test.
local function onDispatched(raw, accepted)
	if type(raw) ~= 'string' then return end
	if not ours(raw) then return end
	local line = ('command dispatched: %s (%s)')
		:format(raw, accepted and 'accepted' or 'refused')
	if accepted then Open77.log.info(line) else Open77.log.warn(line) end
end

-- Keeps the engine's weather lock on and re-submits the preset. A lock found
-- false means something else took the sky.
local function enforce()
	if Projection.state == nil or Projection.state.weatherPreset == '' then return end
	local frozen = Open77.environment.isWeatherFrozen()
	if frozen ~= true then
		local ok, reason = Open77.environment.setWeatherFrozen(true)
		if not ok then Open77.log.warn('weather lock restore failed: ' .. tostring(reason)) end
		if remainingTransition() <= 0 then applyWeather(true, 0) end
	end
	applyWeather(false)
end

-- Answers the synchronized time and weather at the instant of the call, and
-- never raises.
local function projectedState()
	if not Projection.available then
		return { ok = false, error = 'environment_unavailable' }
	end
	local state = Projection.state
	if state == nil then return { ok = false, error = 'not_synchronized' } end

	local seconds = Clock.At(state.secondsOfDay, state.anchorLocalMs, state.rate,
		state.timeFrozen, OPX.Now())
	local hour, minute, second = Clock.ToHms(seconds)
	return {
		ok = true,
		hour = hour,
		minute = minute,
		second = second,
		secondsOfDay = seconds,
		weather = state.weather,
		weatherPreset = state.weatherPreset,
		timeFrozen = state.timeFrozen,
		weatherFrozen = state.weatherFrozen,
		revision = state.revision,
		weatherRevision = state.weatherRevision,
		latencyCompensationMs = state.latencyCompensationMs,
	}
end

--- Reads the configured command names and looks for the environment natives.
-- @author dop42
function M.Init()
	--- Whether the environment natives are installed in this client.
	Projection.available = false

	--- Last accepted snapshot, anchored on the local clock.
	Projection.state = nil

	for _, entry in pairs(type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}) do
		local name = type(entry) == 'table' and entry.NAME or nil
		if type(name) == 'string' and name ~= '' then
			COMMAND_NAMES[name:lower()] = true
		end
	end

	local installed = type(Open77.environment) == 'table'
	for index = 1, installed and #NATIVES or 0 do
		installed = type(Open77.environment[NATIVES[index]]) == 'function'
		if not installed then break end
	end
	if not installed then
		Open77.log.warn('environment natives unavailable; restart Cyberpunk to activate them')
		return
	end
	Projection.available = true
end

--- Publishes the read-only view of the synchronized time and weather.
-- @author dop42
function M.Api()
	OPX.Api.Provide('weather', 1, { State = projectedState })
end

--- Wires the command answers, then the projection when the natives are there.
-- @author dop42
function M.Start()
	-- Registered whether or not the natives are installed: staff on such a
	-- client must still read the answers to their own commands.
	RegisterNetEvent(EVENT_NOTICE, onNotice)
	RegisterNetEvent('open77:command:result', onDispatched)

	-- Everything below calls an environment native, which would be a call on nil.
	if not Projection.available then return end

	RegisterNetEvent(EVENT_SYNC, onSync)

	-- The clock lock is released before anything else: a client returning into a
	-- lock left by a previous generation would never thaw.
	Open77.environment.setTimeFrozen(false)
	lastTimeFrozen = false
	requestSync()

	OPX.Scheduler.Every('weather:time', SYNC.APPLY_MS, applyTime)
	OPX.Scheduler.Every('weather:sync', SYNC.CLIENT_SYNC_MS, requestSync)
	OPX.Scheduler.Every('weather:enforce', SYNC.ENFORCE_MS, enforce)
end

--- Hands the clock and the weather back to the engine.
-- @author dop42
function M.Stop()
	-- Read by `applyDeferred`, so that a snapshot held by the floor cannot take
	-- back a lock that stopping has just released.
	stopped = true
	if not Projection.available then return end
	Open77.environment.setTimeFrozen(false)
	Open77.environment.setWeatherFrozen(false)
end
