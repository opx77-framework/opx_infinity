--- Requests to the server, their verdicts, refusals shown, and the offer.
-- @author dop42
--
-- `Play` and `Stop` answer "asked for", not "done": the verdict arrives on
-- `M.Event.ON_RESULT` under the request id, which is the only way a caller
-- learns the end of one. A refused request from a caller raises no toast: the
-- caller decides what to show.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt
local Presenter = M.Presenter

M.Runtime = {}
local Runtime = M.Runtime

-- How long a request waits for its verdict, and how often that is checked.
local PENDING_MS = 15000
local SWEEP_MS = 5000

-- Catalogue key a player reads for each refusal code. A code with no entry
-- reads as the generic sentence, never as a raw code.
local REFUSAL = {
	unknown_animation = 'animations.error.unknownAnimation',
	invalid_variant = 'animations.error.invalidVariant',
	invalid_options = 'animations.error.invalidOptions',
	player_not_ready = 'animations.error.notReady',
	player_not_alive = 'animations.error.notAlive',
	player_in_vehicle = 'animations.error.inVehicle',
	animation_owned = 'animations.error.owned',
	animation_locked = 'animations.error.locked',
	interrupted = 'animations.error.interrupted',
	timeout = 'animations.error.timeout',
	request_timeout = 'animations.error.timeout',
	rate_limited = 'animations.error.rateLimited',
	service_unavailable = 'animations.error.unavailable',
	resource_stopped = 'animations.error.unavailable',
	not_sent = 'animations.error.notSent',
	presentation_failed = 'animations.error.presentationFailed',
}

-- Origins that end a playback for the platform, not for the player.
local SYSTEM_ORIGINS = { presenter = true, owner_stopped = true }

-- Requests waiting for their verdict: action, origin, owner, time.
local pending = {}

-- Last request serial used, and the owner that started each playback.
local serial, owners = 0, {}

-- The local playback its player may not stop: playbackId, owner, end, seen.
local lock = nil

-- Offered variants per name as the server said, or nil before the offer lands.
local offer = nil

-- The scheduler handle of the sweep, so Stop can cancel it.
local sweepJob = nil

-- Writes a chat line when no toast can be raised. Optional: without the chat
-- contract the refusal is a log line and nothing else.
local function chatLine(message)
	local chat = OPX.Api.Get('chat')
	if chat == nil or type(chat.AddMessage) ~= 'function' then
		Open77.log.info('[animations] ' .. message)
		return
	end
	chat.AddMessage({ kind = 'error', author = locale('animations.title'), text = message })
end

--- Tells the player a rendered text, as a toast or a chat line.
-- One replaced slot: a player hammering a refused row sees one toast, not a pile.
-- @author dop42
-- @param kind string info, success, warning or error
-- @param message string
function Runtime.Say(kind, message)
	if not Opt.NOTIFY then
		chatLine(message)
		return
	end
	local raised = OPX.Toast.Show({
		id = 'opx.animations.refusal',
		kind = kind,
		title = locale('animations.title'),
		message = message,
		durationMs = Opt.TOAST_MS,
	})
	if raised == nil then chatLine(message) end
end

--- Tells the player a catalogue text, as a toast or a chat line.
-- @author dop42
-- @param kind string
-- @param key string
-- @param params table|nil
function Runtime.Notify(kind, key, params)
	Runtime.Say(kind, locale(key, params))
end

--- Shows the player why a request of theirs was refused.
-- @author dop42
-- @param code string|nil
function Runtime.Refuse(code)
	-- The down screen is the answer; a toast over it would not be read.
	if code == 'player_down' then return end
	if code == 'menu_not_running' then
		local command = Opt.PlayCommand()
		if command then
			return Runtime.Notify('warning', 'animations.error.menuNotRunningHint',
				{ command = command })
		end
		return Runtime.Notify('warning', 'animations.error.menuNotRunning')
	end
	Runtime.Notify('warning', REFUSAL[code or ''] or 'animations.error.refused')
end

--- Answers an offered entry and its variant set, or nil.
-- Until the server answers the hello this is the catalogue less DISABLED; the
-- server refuses whatever that stand-in got wrong.
-- @author dop42
-- @param name any
-- @return table|nil
-- @return table|nil
function Runtime.Offered(name)
	local entry = Catalogue.Entry(name)
	if entry == nil then return nil, nil end
	if offer ~= nil then
		local set = offer[entry.name]
		if set == nil then return nil, nil end
		return entry, set
	end
	if Opt.DISABLED[entry.name] then return nil, nil end
	local set = {}
	for position = 1, #entry.clips do set[position] = true end
	return entry, set
end

--- Answers the offered variant numbers of a name, ascending.
-- @author dop42
-- @param name any
-- @return integer[]
function Runtime.Variants(name)
	local entry, set = Runtime.Offered(name)
	local numbers = {}
	if entry == nil then return numbers end
	for position = 1, #entry.clips do
		if set[position] then numbers[#numbers + 1] = position end
	end
	return numbers
end

--- Answers one entry as a contract caller is given it.
-- @author dop42
-- @param entry table
-- @return table
function Runtime.Listing(entry)
	local variants = {}
	local numbers = Runtime.Variants(entry.name)
	for index = 1, #numbers do
		local position = numbers[index]
		variants[index] = { variant = position, clip = entry.clips[position],
			words = entry.words[position] }
	end
	return {
		name = entry.name,
		label = locale('animations.name.' .. entry.name),
		category = entry.category,
		categoryLabel = locale('animations.category.' .. entry.category),
		prop = entry.prop,
		placement = entry.placement,
		variants = variants,
	}
end

--- Answers every offered entry, optionally in one category.
-- @author dop42
-- @param category string|nil
-- @return table[]
function Runtime.Entries(category)
	local rows = {}
	local entries = Catalogue.Entries()
	for index = 1, #entries do
		local entry = entries[index]
		if (category == nil or entry.category == category) and Runtime.Offered(entry.name) then
			rows[#rows + 1] = entry
		end
	end
	return rows
end

-- Raises a verdict locally, and toasts a refusal the player asked for.
local function publish(payload)
	TriggerEvent(M.Event.ON_RESULT, payload)
	if not payload.ok and payload.source ~= 'contract' then Runtime.Refuse(payload.error) end
end

-- Records a pending request and answers its serial.
local function remember(action, origin, owner)
	serial = serial + 1
	if serial > M.MAX_REQUEST_ID then serial = 1 end
	pending[serial] = { action = action, origin = origin, owner = owner, atMs = OPX.Now() }
	return serial
end

--- Whether the local player's playback may not be stopped by the player.
-- @author dop42
-- @return boolean
function Runtime.Locked()
	if lock == nil then return false end
	if OPX.Now() >= lock.untilMs then
		lock = nil
		return false
	end
	return true
end

-- Whether a request may end or replace a locked playback.
local function overrides(origin, owner)
	if SYSTEM_ORIGINS[origin] then return true end
	return lock ~= nil and lock.owner ~= nil and owner ~= nil and owner == lock.owner
end

-- Shows the stop row while the local playback plays and may be stopped.
local function showPrompt(active)
	local Prompt = M.Prompt
	if not Prompt then return end
	local shown = active and not Runtime.Locked()
	for _, request in pairs(pending) do
		-- A playback asked not to be stoppable hides the row before its verdict
		-- lands.
		if request.action == 'play' and request.cancelable == false then shown = false end
	end
	Prompt.Changed(shown)
end

--- Asks the server to play an animation on this player.
-- @author dop42
-- @param name any
-- @param options table|nil
-- @param origin string
-- @param owner string|nil the caller that owns the playback
-- @return table
function Runtime.Play(name, options, origin, owner)
	local entry, set = Runtime.Offered(name)
	if entry == nil then return { ok = false, error = 'unknown_animation' } end
	if options ~= nil and type(options) ~= 'table' then
		return { ok = false, error = 'invalid_options', animation = entry.name }
	end
	options = options or {}

	local variant = options.variant
	if variant == nil and options.clip ~= nil then
		variant = Catalogue.VariantOf(entry.name, options.clip)
		if variant == nil then
			return { ok = false, error = 'invalid_variant', animation = entry.name }
		end
	end
	if variant ~= nil then
		variant = Common.Integer(variant, 1, #entry.clips)
		if variant == nil or not set[variant] then
			return { ok = false, error = 'invalid_variant', animation = entry.name }
		end
	end

	local loop = 'default'
	if options.loop == true then
		loop = 'loop'
	elseif options.loop == false then
		loop = 'once'
	elseif options.loop ~= nil then
		return { ok = false, error = 'invalid_options', animation = entry.name }
	end
	local duration = 0
	if options.durationMs ~= nil then
		duration = Common.Integer(options.durationMs, M.MIN_DURATION_MS, Opt.MAX_DURATION_MS)
		if duration == nil then
			return { ok = false, error = 'invalid_options', animation = entry.name }
		end
	end
	if options.cancelable ~= nil and type(options.cancelable) ~= 'boolean' then
		return { ok = false, error = 'invalid_options', animation = entry.name }
	end
	local cancelable = options.cancelable ~= false
	local loops = loop == 'loop' or (loop == 'default' and Opt.LOOP_BY_DEFAULT)
	if not cancelable and loops and duration == 0 then
		return { ok = false, error = 'invalid_options', animation = entry.name }
	end

	local override = overrides(origin, owner)
	if Runtime.Locked() and not override then
		return { ok = false, error = 'animation_locked', animation = entry.name }
	end

	local id = remember('play', origin, owner)
	pending[id].cancelable = cancelable
	-- Never a nil inside the payload: the codec's treatment of one is
	-- unspecified, so the loop is a word and an absent duration is 0.
	local sent, reason = TriggerServerEvent(M.Event.PLAY, id, entry.name, variant or 0,
		{ loop = loop, durationMs = duration, cancelable = cancelable, override = override })
	if sent == false then
		pending[id] = nil
		Open77.log.warn('[animations] play request not sent: ' .. tostring(reason))
		return { ok = false, error = 'not_sent', animation = entry.name }
	end
	return { ok = true, queued = true, requestId = id, animation = entry.name, variant = variant }
end

--- Asks for this player's animation to end, whoever started it, unless locked.
-- The playback is released on the service's wire whatever started it, AND the
-- server is asked to stop what the server started.
-- @author dop42
-- @param origin string
-- @param owner string|nil
-- @return table
function Runtime.Stop(origin, owner)
	local override = overrides(origin, owner)
	if Runtime.Locked() then
		if not override then return { ok = false, error = 'animation_locked' } end
		lock = nil
	end
	local released = Presenter.ReleaseOwn()
	local id = remember('stop', origin, nil)
	local sent, reason = TriggerServerEvent(M.Event.STOP, id, override)
	if sent == false then
		pending[id] = nil
		Open77.log.warn('[animations] stop request not sent: ' .. tostring(reason))
		if not released then return { ok = false, error = 'not_sent' } end
		return { ok = true, queued = false }
	end
	return { ok = true, queued = true, requestId = id }
end

-- Takes the offer the server sent, dropping what the catalogue lacks.
local function onOffer(list)
	if type(list) ~= 'table' or #list > 256 then return end
	local built = {}
	for index = 1, #list do
		local row = list[index]
		local entry = type(row) == 'table' and Catalogue.Entry(row.name) or nil
		if entry ~= nil and type(row.variants) == 'table' then
			local set, any = {}, false
			for position = 1, math.min(#row.variants, 64) do
				local variant = Common.Integer(row.variants[position], 1, #entry.clips)
				if variant ~= nil then set[variant], any = true, true end
			end
			if any then built[entry.name] = set end
		end
	end
	offer = built
end

-- Resolves a pending request with the server's verdict and publishes it. A
-- verdict that is not ours, or that nobody is waiting on, changes nothing.
local function onAnswer(requestId, action, ok, code, detail)
	requestId = Common.Integer(requestId, 0, M.MAX_REQUEST_ID)
	if requestId == nil or (action ~= 'play' and action ~= 'stop') or type(ok) ~= 'boolean' then
		return
	end
	local request = nil
	if requestId > 0 then
		request = pending[requestId]
		if request == nil or request.action ~= action then return end
		pending[requestId] = nil
	end

	detail = type(detail) == 'table' and detail or {}
	local payload = {
		requestId = requestId,
		action = action,
		ok = ok,
		error = (not ok) and (Common.Code(code) or 'refused') or nil,
		animation = Common.Text(detail.animation, 64) and detail.animation or nil,
		variant = Common.Integer(detail.variant, 1, 64),
		playbackId = Common.Text(detail.playbackId, 64) and detail.playbackId or nil,
		source = request and request.origin or 'command',
		owner = request and request.owner or nil,
	}
	if ok and action == 'play' and payload.playbackId and request and request.owner then
		owners[payload.playbackId] = request.owner
	end
	if ok and action == 'play' then
		local duration = Common.Integer(detail.durationMs, 1, M.SERVICE_MAX_MS)
		lock = nil
		if detail.cancelable == false and duration ~= nil then
			local own = Presenter.State()
			lock = {
				playbackId = payload.playbackId,
				owner = request and request.owner or nil,
				untilMs = OPX.Now() + duration,
				seen = own.active == true and own.playbackId == payload.playbackId,
			}
		end
	end
	if action == 'play' then showPrompt(Presenter.State().active == true) end
	publish(payload)
end

-- Forgets owners and the lock of ended playbacks, and updates the stop prompt.
local function onOwnChanged(payload)
	for playbackId in pairs(owners) do
		if not payload.active or playbackId ~= payload.playbackId then owners[playbackId] = nil end
	end
	if lock ~= nil then
		if payload.active and payload.playbackId == lock.playbackId then
			lock.seen = true
		elseif (payload.active and lock.playbackId ~= nil) or
			(not payload.active and lock.seen) then
			lock = nil
		end
	end
	showPrompt(payload.active == true)
end

-- Ends a playback whose body could not be posed, rather than leaving the other
-- players to watch it alone, and says so.
local function onOwnFailed(_, reason)
	Runtime.Stop('presenter')
	Runtime.Notify('warning', REFUSAL[reason] or 'animations.error.presentationFailed')
end

-- Expires requests with no verdict and ends a playback whose owning module has
-- stopped: a caller that started a playback takes it with it.
local function sweep()
	local atMs = OPX.Now()
	for id, request in pairs(pending) do
		if atMs - request.atMs > PENDING_MS then
			pending[id] = nil
			publish({ requestId = id, action = request.action, ok = false,
				error = 'request_timeout', source = request.origin, owner = request.owner })
			if request.cancelable == false then
				showPrompt(Presenter.State().active == true)
			end
		end
	end

	local own = Presenter.State()
	local owner = own.active and owners[own.playbackId] or nil
	if owner ~= nil and OPX.Modules.Record(owner) ~= nil and not OPX.Modules.IsRunning(owner) then
		Open77.log.info(('[animations] %s stopped; ending the animation it started'):format(owner))
		Runtime.Stop('owner_stopped')
	end
end

--- Builds the request state.
-- @author dop42
function Runtime.Init()
	pending, owners, offer, lock, serial, sweepJob = {}, {}, nil, nil, 0, nil
	-- Posted here rather than at load: the presenter only calls them from its
	-- tick, which starts later, and this keeps it from depending on Runtime.
	Presenter.OnOwnChanged = onOwnChanged
	Presenter.OnOwnFailed = onOwnFailed
end

--- Wires the verdict channels, asks for the offer and starts the sweep.
-- @author dop42
function Runtime.Start()
	RegisterNetEvent(M.Event.OFFER, onOffer)
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.CANCEL, function()
		if Runtime.Locked() then return end
		Presenter.ReleaseOwn()
	end)

	local sent, reason = TriggerServerEvent(M.Event.HELLO)
	if sent == false then
		Open77.log.warn('[animations] offer not asked for: ' .. tostring(reason))
	end

	sweepJob = OPX.Scheduler.Every('animations:pending', SWEEP_MS, sweep)
end

--- Cancels the sweep and forgets every pending request.
-- Named apart from `Runtime.Stop`, which is the request that ends a playback.
-- @author dop42
function Runtime.Shutdown()
	if sweepJob ~= nil then
		OPX.Scheduler.Cancel(sweepJob)
		sweepJob = nil
	end
	pending, owners, lock = {}, {}, nil
end
