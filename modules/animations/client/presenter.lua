--- Mirrors the service's playback states and poses streamed bodies to match.
-- @author dop42
--
-- The presenter decides nothing: the service is the only producer of a playback
-- state. Without the presentation natives the mirror stays empty and the `State`
-- contract function answers `presentation_unavailable`.
--
-- `validState` bounds a profile and a clip without looking them up in the
-- catalogue: a profile this catalogue does not carry is still the service's to
-- replicate, and the natives validate it.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt

M.Presenter = {}
local Presenter = M.Presenter

-- Presenter tick. A snapshot is asked for every SYNC_MS, a paged one abandoned
-- after BATCH_MS, and a playback this client released stays unposed HOLD_MS
-- while the finished state travels.
local TICK_MS = 100
local SYNC_MS = 5000
local HOLD_MS = 5000
local BATCH_MS = 10000

-- Change events raised per tick at most: arriving in a loaded bucket would
-- otherwise raise hundreds in one resume.
local DRAIN = 32

local MAX_BUCKET = 4294967295
local MAX_ID = Common.MAX_INTEGER

local integer, text = Common.Integer, Common.Text

-- Service incarnation mirrored, and the last committed snapshot revision.
local epoch, floor = nil, -1

-- Active state per player, and the newest revision seen.
local mirror, seen = {}, {}

-- What is posed per player: entity, signature, profile, clip.
local posedBy = {}

-- Entity and signature the natives refused, retried when either changes.
local failed = {}

-- Playbacks this client released, left unposed until a deadline.
local held = {}

-- Changes waiting to be raised; false means no longer playing.
local changes = {}

-- The paged snapshot being assembled, and the last context read.
local batch, context = nil, nil

-- This generation's request id prefix, and the last serial used.
local nonce, serial = nil, 0

-- When the next snapshot request and presenter decision are due.
local nextSyncMs, nextLookMs = 0, 0

-- Whether this client poses bodies; nil before the first decision.
local presenting = nil

-- The scheduler handle of the tick, so Stop can cancel it.
local tickJob = nil

-- Read at the moment of use: at load the host may not have installed the API.
local function api()
	local native = Open77.animations
	return type(native) == 'table' and native or nil
end

--- Whether this client has the presentation natives at all.
-- @author dop42
-- @return boolean
function Presenter.Available()
	local native = api()
	return native ~= nil and type(native._context) == 'function' and
		type(native._playProfile) == 'function' and type(native.stop) == 'function'
end

-- Answers the next request id carrying this generation's nonce. Every client
-- shares `open77:animations:result`, so only an id carrying the nonce is ours.
local function wireId()
	serial = serial + 1
	return nonce .. ':' .. serial
end

-- Whether a state's steps are a bounded, well-formed sequence.
local function validSteps(steps)
	if type(steps) ~= 'table' then return false end
	local count = #steps
	if count < 1 or count > 16 then return false end
	local keys = 0
	for key in pairs(steps) do
		if integer(key, 1, count) == nil then return false end
		keys = keys + 1
	end
	if keys ~= count then return false end
	for index = 1, count do
		local step = steps[index]
		if type(step) ~= 'table' or not text(step.profile, 64) or not text(step.clip, 128) or
			integer(step.durationMs, 0, M.SERVICE_MAX_MS) == nil then
			return false
		end
	end
	return true
end

-- Whether a value is a well-formed playback state off the wire.
local function validState(s)
	if type(s) ~= 'table' then return false end
	if not text(s.epoch, 64) or not text(s.playbackId, 64) then return false end
	if integer(s.revision, 0, MAX_ID) == nil or integer(s.playerId, 1, MAX_ID) == nil then
		return false
	end
	if type(s.active) ~= 'boolean' or integer(s.bucket, 0, MAX_BUCKET) == nil then return false end
	if not validSteps(s.steps) then return false end
	return integer(s.step, 0, #s.steps - 1) ~= nil and integer(s.cycle, 0, MAX_ID) ~= nil
end

-- Answers what a listener is told about one player's playback. The raw state,
-- which has the service's shape, is never handed out.
local function describe(playerId, s)
	if not s or not s.active then return { playerId = playerId, active = false } end
	local step = s.steps[s.step + 1]
	local entry = Catalogue.Entry(step.profile)
	return {
		playerId = playerId,
		active = true,
		playbackId = s.playbackId,
		animation = step.profile,
		clip = step.clip,
		variant = entry and Catalogue.VariantOf(entry.name, step.clip) or nil,
		known = entry ~= nil,
		step = s.step + 1,
		steps = #s.steps,
		cycle = s.cycle,
	}
end

-- Stops posing one player's body.
local function undraw(playerId)
	local posed = posedBy[playerId]
	if posed == nil then return end
	posedBy[playerId] = nil
	local native = api()
	if native ~= nil then pcall(native.stop, posed.entity) end
end

local function undrawAll()
	for playerId in pairs(posedBy) do undraw(playerId) end
end

-- Takes one validated state into the mirror, ordered by revision. A live state
-- at or below the last snapshot is older than what that snapshot said.
local function accept(s, fromSnapshot)
	local playerId = s.playerId
	if seen[playerId] ~= nil and seen[playerId] >= s.revision then return false end
	if not fromSnapshot and s.revision <= floor then return false end
	seen[playerId] = s.revision

	local old = mirror[playerId]
	if old == nil or old.playbackId ~= s.playbackId then failed[playerId] = nil end
	if s.active then
		mirror[playerId] = s
	else
		mirror[playerId], failed[playerId], held[playerId] = nil, nil, nil
		undraw(playerId)
	end
	changes[playerId] = s.active and s or false
	return true
end

-- Takes one live state from the service's wire.
local function onState(s)
	if not validState(s) then return end
	if epoch ~= nil and s.epoch ~= epoch then return end
	if context ~= nil and s.active and s.bucket ~= context.bucket then return end
	epoch = epoch or s.epoch
	accept(s, false)
end

-- Replaces the mirror with a complete snapshot; absence in one means an end.
-- Only a complete snapshot may move the mirror to another incarnation of the
-- service: a different epoch means it restarted and nothing it said before holds.
local function commit(snapshotEpoch, revision, states)
	if epoch ~= nil and epoch ~= snapshotEpoch then
		for playerId in pairs(mirror) do changes[playerId] = false end
		undrawAll()
		mirror, seen, failed, held, floor = {}, {}, {}, {}, -1
	end
	epoch = snapshotEpoch

	for playerId, old in pairs(mirror) do
		if states[playerId] == nil and old.revision <= revision then
			mirror[playerId], failed[playerId], held[playerId] = nil, nil, nil
			undraw(playerId)
			changes[playerId] = false
		end
	end
	for _, s in pairs(states) do accept(s, true) end

	if revision > floor then floor = revision end
	for playerId, known in pairs(seen) do
		if mirror[playerId] == nil and known <= floor then seen[playerId] = nil end
	end
end

-- Takes one snapshot page, committing once every page has arrived. One assembly
-- at a time: the service sends its pages in order on a single channel.
local function onSnapshot(page)
	if type(page) ~= 'table' or not text(page.epoch, 64) then return end
	local revision = integer(page.revision, 0, MAX_ID)
	local bucket = integer(page.bucket, 0, MAX_BUCKET)
	if revision == nil or bucket == nil then return end
	if context ~= nil and bucket ~= context.bucket then return end
	if epoch == page.epoch and revision < floor then return end

	local states = page.states
	if type(states) ~= 'table' or #states > 64 then return end
	local slice = {}
	for index = 1, #states do
		local s = states[index]
		if not validState(s) or s.epoch ~= page.epoch or s.bucket ~= bucket or not s.active or
			s.revision > revision or slice[s.playerId] ~= nil then
			return
		end
		slice[s.playerId] = s
	end

	local total, part = 1, 1
	if page.total ~= nil then
		total = integer(page.total, 1, 128)
		part = total and integer(page.slice, 1, total)
		if total == nil or part == nil or not text(page.snapshotId, 64) then return end
	end
	if total == 1 then return commit(page.epoch, revision, slice) end

	if batch == nil or batch.id ~= page.snapshotId then
		batch = { id = page.snapshotId, epoch = page.epoch, revision = revision, bucket = bucket,
			total = total, parts = {}, arrived = 0, atMs = OPX.Now() }
	end
	if batch.epoch ~= page.epoch or batch.revision ~= revision or batch.bucket ~= bucket or
		batch.total ~= total then
		batch = nil
		return
	end
	if batch.parts[part] == nil then batch.arrived = batch.arrived + 1 end
	batch.parts[part] = slice
	if batch.arrived < total then return end

	local merged = {}
	for index = 1, total do
		for playerId, s in pairs(batch.parts[index]) do
			if merged[playerId] ~= nil then
				batch = nil
				return
			end
			merged[playerId] = s
		end
	end
	batch = nil
	commit(page.epoch, revision, merged)
end

-- Answers a player's body entity on this client, or nil. The local player is
-- entity 0 to the natives.
local function entityOf(playerId)
	if playerId == context.playerId then return 0 end
	local players = context.players
	if type(players) ~= 'table' then return nil end
	local entity = players[playerId]
	if entity == nil then entity = players[tostring(playerId)] end
	return entity
end

-- Records a refused pose, raises the failure and tells the hook.
local function fail(playerId, s, entity, signature, reason)
	failed[playerId] = { entity = entity, signature = signature }
	undraw(playerId)
	local code = Common.Code(reason) or 'presentation_failed'
	TriggerEvent(M.Event.ON_FAILED, { playerId = playerId, playbackId = s.playbackId,
		reason = code })
	if playerId == context.playerId then
		Open77.log.warn(('[animations] own playback %s could not be posed: %s')
			:format(s.playbackId, code))
		Presenter.OnOwnFailed(s.playbackId, code)
	else
		Open77.log.debug(('[animations] player %d playback could not be posed: %s')
			:format(playerId, code))
	end
end

-- Poses every streamed body to match the mirror. The same clip again is a
-- restart, so a looping cycle does not blend into itself; `device_pending` is a
-- prop or workspot still streaming, not a failure.
local function present(atMs)
	local native = api()
	for playerId, posed in pairs(posedBy) do
		if mirror[playerId] == nil or entityOf(playerId) ~= posed.entity then undraw(playerId) end
	end

	for playerId, s in pairs(mirror) do
		local hold = held[playerId]
		if hold ~= nil and (hold.playbackId ~= s.playbackId or atMs >= hold.untilMs) then
			held[playerId], hold = nil, nil
		end
		local entity = entityOf(playerId)
		if entity ~= nil and hold == nil then
			local step = s.steps[s.step + 1]
			local signature = s.playbackId .. ':' .. s.cycle .. ':' .. s.step
			local failure = failed[playerId]
			if failure ~= nil and (failure.signature ~= signature or failure.entity ~= entity) then
				failed[playerId], failure = nil, nil
			end
			if failure == nil then
				local posed = posedBy[playerId]
				if posed == nil or posed.signature ~= signature then
					local restart = posed ~= nil and posed.profile == step.profile and
						posed.clip == step.clip
					local called, played, reason = pcall(native._playProfile, entity, step.profile,
						step.clip, restart)
					if called and played then
						posedBy[playerId] = { entity = entity, signature = signature,
							profile = step.profile, clip = step.clip }
					else
						fail(playerId, s, entity, signature, called and reason or 'play_raised')
					end
				elseif type(native._profileStatus) == 'function' then
					local called, status = pcall(native._profileStatus, entity)
					if called and status ~= 'ok' and status ~= 'device_pending' then
						fail(playerId, s, entity, signature, status)
					end
				end
			end
		end
	end
end

-- Decides, once a second rather than every tick, whether this client poses.
local function decide(atMs)
	if atMs < nextLookMs then return end
	nextLookMs = atMs + 1000
	local wanted
	if Opt.PRESENTER == 'always' then
		wanted = true
	elseif Opt.PRESENTER == 'never' then
		wanted = false
	else
		local state = tostring(GetResourceState(M.OFFICIAL) or ''):lower()
		wanted = state ~= 'running' and state ~= 'starting'
	end
	if wanted ~= presenting then
		presenting = wanted
		if wanted then
			Open77.log.info('[animations] posing bodies on this client (PRESENTER ' ..
				Opt.PRESENTER .. ')')
		else
			undrawAll()
			Open77.log.info(('[animations] leaving bodies to %s (PRESENTER %s)')
				:format(M.OFFICIAL, Opt.PRESENTER))
		end
	end
end

-- Forgets every mirrored state, ending each one for listeners.
local function reset()
	undrawAll()
	for playerId in pairs(mirror) do changes[playerId] = false end
	epoch, floor, batch = nil, -1, nil
	mirror, seen, failed, held = {}, {}, {}, {}
	nextSyncMs = 0
end

-- Raises up to DRAIN pending change events.
local function drain()
	local raised = 0
	for playerId, s in pairs(changes) do
		changes[playerId] = nil
		local payload = describe(playerId, s)
		TriggerEvent(M.Event.ON_CHANGED, payload)
		if context ~= nil and playerId == context.playerId then
			Presenter.OnOwnChanged(payload)
		end
		raised = raised + 1
		if raised >= DRAIN then break end
	end
end

-- Reads the context, syncs, drains changes and poses bodies. Another
-- generation, bucket or player, or a context that stops being ready, means
-- every mirrored state belongs to the world before.
local function tick()
	local native = api()
	if native == nil then return end
	local atMs = OPX.Now()
	local read, raw = pcall(native._context)
	if not read or type(raw) ~= 'table' then return end
	local current = {
		generation = raw.generation,
		bucket = tonumber(raw.bucket),
		playerId = tonumber(raw.playerId),
		ready = raw.ready == true,
		players = raw.players,
	}
	if context ~= nil and (context.generation ~= current.generation or
		context.bucket ~= current.bucket or context.playerId ~= current.playerId or
		(context.ready and not current.ready)) then
		reset()
	end
	context = current
	if not current.ready or current.playerId == nil then return end

	if atMs >= nextSyncMs then
		nextSyncMs = atMs + SYNC_MS
		TriggerServerEvent(M.Wire.SYNC, wireId())
	end
	if batch ~= nil and atMs - batch.atMs > BATCH_MS then batch = nil end

	drain()
	decide(atMs)
	if presenting then present(atMs) end
end

-- This client's own player id, or nil before the world.
local function ownId()
	return context and context.ready and context.playerId or nil
end

--- Answers a player's playback as mirrored, the local player by default.
-- @author dop42
-- @param playerId integer|nil
-- @return table
function Presenter.State(playerId)
	playerId = playerId or ownId()
	if playerId == nil then return { active = false } end
	return describe(playerId, mirror[playerId])
end

--- Whether this client is posing bodies right now.
-- @author dop42
-- @return boolean
function Presenter.Presenting()
	return presenting == true
end

--- Releases the local player's playback over the service's wire.
-- @author dop42
-- @return boolean
function Presenter.ReleaseOwn()
	local own = ownId()
	local s = own and mirror[own] or nil
	if s == nil or nonce == nil then return false end
	held[own] = { playbackId = s.playbackId, untilMs = OPX.Now() + HOLD_MS }
	undraw(own)
	TriggerServerEvent(M.Wire.STOP, wireId(), s.playbackId)
	return true
end

--- Called with the local player's change; replaced by client/main.lua.
-- @author dop42
-- @param _ table
function Presenter.OnOwnChanged(_) end

--- Called when the local player's body could not be posed; replaced likewise.
-- @author dop42
-- @param _ string
-- @param _reason string
function Presenter.OnOwnFailed(_, _reason) end

--- Builds the empty mirror.
-- @author dop42
function Presenter.Init()
	epoch, floor, batch, context = nil, -1, nil, nil
	mirror, seen, posedBy, failed, held, changes = {}, {}, {}, {}, {}, {}
	nonce, serial = nil, 0
	nextSyncMs, nextLookMs, presenting, tickJob = 0, 0, nil, nil
end

--- Wires the service's channels and registers the tick.
-- @author dop42
function Presenter.Start()
	if not Presenter.Available() then
		Open77.log.warn('[animations] presentation natives unavailable; no body is posed here ' ..
			'and the State contract answers everyone as idle')
		return
	end

	-- The host refuses these names from anything but the server, so a
	-- neighbouring resource cannot forge a state; every value is checked anyway.
	RegisterNetEvent(M.Wire.STATE, onState)
	RegisterNetEvent(M.Wire.SNAPSHOT, onSnapshot)
	RegisterNetEvent(M.Wire.RESULT, function(result)
		if nonce == nil or type(result) ~= 'table' or type(result.requestId) ~= 'string' then
			return
		end
		if result.requestId:sub(1, #nonce + 1) ~= nonce .. ':' then return end
		-- `stale_playback` means the playback had already ended, which is what
		-- was asked for.
		if result.ok == false and result.error ~= 'stale_playback' then
			Open77.log.info('[animations] release refused: ' .. tostring(Common.Code(result.error)))
		end
	end)

	local read, generation = pcall(Open77.resource.generation)
	nonce = ('opx:%s:%d'):format(read and tostring(generation) or '0', OPX.Now())

	tickJob = OPX.Scheduler.Every('animations:presenter', TICK_MS, tick)
end

--- Hands every posed body back rather than leaving it frozen with nothing to
--- drive it.
-- @author dop42
function Presenter.Shutdown()
	if tickJob ~= nil then
		OPX.Scheduler.Cancel(tickJob)
		tickJob = nil
	end
	if Presenter.Available() then undrawAll() end
end
