--- What this build offers, and every play or stop request.
-- @author dop42
--
-- Nothing here plays anything: `Play` checks, in order, that the service exists,
-- that the name is offered, that the variant is offered, that the options are
-- well formed, that the rate allows it and that the readiness gate is open, and
-- then asks the platform. The service's own verdict is passed straight back.
--
-- `player` always comes from the authenticated connection and never from a
-- payload: every field of an inbound request is a claim by that player.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt

M.Service = {}
local Service = M.Service

-- Offered variants per name, less DISABLED and the clips this build lacks.
local offer = {}

-- The same offer, in the shape a client is sent.
local wire = {}

local built = false

-- Read at the moment of use: at load the host may not have installed the API.
local function api()
	local native = Open77.animations
	return type(native) == 'table' and native or nil
end

--- Whether the play and stop natives exist to serve requests.
-- @author dop42
-- @return boolean
function Service.Available()
	local native = api()
	return native ~= nil and type(native.play) == 'function' and type(native.stop) == 'function'
end

-- Answers a profile's clip set, false when the build cannot be asked, nil when
-- the build does not carry the profile.
local function nativeClips(native, name)
	local profile
	if type(native.get) == 'function' then
		local read, answer = pcall(native.get, name)
		if not read then return false end
		profile = answer
	elseif type(native.list) == 'function' then
		local read, answer = pcall(native.list)
		if not read or type(answer) ~= 'table' then return false end
		for index = 1, #answer do
			local row = answer[index]
			if type(row) == 'table' and row.id == name then profile = row break end
		end
	else
		return false
	end
	if type(profile) ~= 'table' then return nil end
	if type(profile.clips) ~= 'table' then return false end
	local clips = {}
	for index = 1, #profile.clips do
		if type(profile.clips[index]) == 'string' then clips[profile.clips[index]] = true end
	end
	return clips
end

--- Resolves the offer against the running build, once.
-- Lazy on purpose: at file load the host may not have finished installing the
-- animation API, so the first slice or the first request is what triggers it.
-- @author dop42
function Service.Build()
	if built then return end
	built = true
	local native = api()
	if not Service.Available() then return end

	local unchecked = 0
	local entries = Catalogue.Entries()
	for index = 1, #entries do
		local entry = entries[index]
		if Opt.DISABLED[entry.name] then
			Open77.log.info(('[animations] %s is disabled in config'):format(entry.name))
		else
			local clips = nativeClips(native, entry.name)
			if clips == nil then
				Open77.log.warn(('[animations] %s is not a profile on this build; not offered')
					:format(entry.name))
			else
				local variants, numbers = {}, {}
				for position = 1, #entry.clips do
					local clip = entry.clips[position]
					if clips == false or clips[clip] then
						variants[position] = true
						numbers[#numbers + 1] = position
					else
						Open77.log.warn(('[animations] %s variant %d (%s) is not on this build; ' ..
							'not offered'):format(entry.name, position, clip))
					end
				end
				if clips == false then unchecked = unchecked + 1 end
				if #numbers > 0 then
					offer[entry.name] = variants
					wire[#wire + 1] = { name = entry.name, variants = numbers }
				end
			end
		end
	end
	if unchecked > 0 then
		Open77.log.warn(('[animations] %d catalogue entries could not be checked against this ' ..
			'build; offered as written'):format(unchecked))
	end
end

--- Answers the offer in the shape a client is sent.
-- @author dop42
-- @return table[]
function Service.Wire()
	Service.Build()
	return wire
end

--- Answers an offered entry and its variant set, or nil.
-- @author dop42
-- @param name any
-- @return table|nil
-- @return table|nil
function Service.Offered(name)
	Service.Build()
	local entry = Catalogue.Entry(name)
	if entry == nil or offer[entry.name] == nil then return nil, nil end
	return entry, offer[entry.name]
end

-- Rate windows per request kind, then per player.
local windows = { play = {}, stop = {} }

-- Whether one more request fits, and whether this refusal is the first one in
-- the window: a held key must cost one toast, not one per press. The refusals
-- after it carry `quiet`, and Answer drops them.
local function within(kind, player, multiplier)
	local limit = math.floor(OPX.Tune.Number('ANIM_RATE_REQUESTS', 1)) * multiplier
	local spanMs = OPX.Tune.Number('ANIM_RATE_WINDOW_MS', 250)
	local atMs = OPX.Now()
	local window = windows[kind][player]
	if window == nil or atMs - window.started >= spanMs then
		window = { started = atMs, count = 0, told = false }
		windows[kind][player] = window
	end
	if window.count >= limit then
		local first = not window.told
		window.told = true
		return false, first
	end
	window.count = window.count + 1
	return true, false
end

-- `isReady` raises on an invalid id, and answers false for ever on a server with
-- no appearance resource, so the read is guarded and a raise is a closed gate.
local function gateOpen(player)
	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then return false end
	local read, open = pcall(ready.isReady, player)
	return read and open == true
end

-- The playback a player may not stop, per player: playbackId and end time.
local locks = {}

-- Whether a player's playback may not be stopped, forgetting an ended one.
local function locked(player)
	local lock = locks[player]
	if lock == nil then return false end
	if OPX.Now() >= lock.untilMs then
		locks[player] = nil
		return false
	end
	local native = api()
	if lock.playbackId ~= nil and native ~= nil and type(native.current) == 'function' then
		-- Only a clean answer ends the lock early: a refused read keeps it until
		-- its end time.
		local called, state, reason = pcall(native.current, player)
		if called and ((state == nil and reason == nil) or (type(state) == 'table' and
			(state.active == false or state.playbackId ~= lock.playbackId))) then
			locks[player] = nil
			return false
		end
	end
	return true
end

-- The loop words a client sends, resolved. The client never sends nil inside a
-- payload: the codec's treatment of one is unspecified, so loop is a word and an
-- absent duration is 0.
local LOOP_WORDS = { default = 'default', loop = true, once = false }

-- Resolves request options against config, or answers a refusal code.
local function resolveOptions(options)
	if options == nil then options = {} end
	if type(options) ~= 'table' then return nil, 'invalid_options' end

	local loop = LOOP_WORDS[options.loop == nil and 'default' or options.loop]
	if loop == nil then return nil, 'invalid_options' end
	if loop == 'default' then loop = Opt.LOOP_BY_DEFAULT end

	local maximum = math.floor(OPX.Tune.Number('ANIM_MAX_DURATION_MS', M.MIN_DURATION_MS))
	local duration = options.durationMs
	if duration == nil or duration == 0 then
		duration = nil
	else
		duration = Common.Integer(duration, M.MIN_DURATION_MS, maximum)
		if duration == nil then return nil, 'invalid_options' end
	end
	-- A playback that does not loop has to end somewhere.
	if not loop and duration == nil then
		duration = math.floor(OPX.Tune.Number('ANIM_ONE_SHOT_MS', M.MIN_DURATION_MS))
	end

	if options.cancelable ~= nil and type(options.cancelable) ~= 'boolean' then
		return nil, 'invalid_options'
	end
	if options.override ~= nil and type(options.override) ~= 'boolean' then
		return nil, 'invalid_options'
	end
	local cancelable = options.cancelable ~= false
	-- A playback nobody may stop has to end by itself.
	if not cancelable and duration == nil then return nil, 'invalid_options' end
	return { loop = loop, durationMs = duration, cancelable = cancelable,
		override = options.override == true }, nil
end

--- Plays one animation on one player, answering a result table.
-- @author dop42
-- @param player Source the authenticated session, never a payload value
-- @param name any
-- @param variant any 1-based; nil, 0 or empty for the default
-- @param options any
-- @return table
function Service.Play(player, name, variant, options)
	if not Service.Available() then return { ok = false, error = 'service_unavailable' } end

	local entry, variants = Service.Offered(name)
	if entry == nil then return { ok = false, error = 'unknown_animation' } end

	-- Without a variant it is the first OFFERED one: variant 1 can be missing
	-- from this build.
	if variant == nil or variant == 0 or variant == '' then
		for position = 1, #entry.clips do
			if variants[position] then variant = position break end
		end
	else
		variant = Common.Integer(tonumber(variant), 1, #entry.clips)
		if variant == nil or not variants[variant] then
			return { ok = false, error = 'invalid_variant', animation = entry.name }
		end
	end

	local resolved, malformed = resolveOptions(options)
	if resolved == nil then return { ok = false, error = malformed, animation = entry.name } end

	local allowed, first = within('play', player, 1)
	if not allowed then
		return { ok = false, error = 'rate_limited', quiet = not first, animation = entry.name }
	end

	if not resolved.override and locked(player) then
		return { ok = false, error = 'animation_locked', animation = entry.name }
	end

	if not gateOpen(player) then
		return { ok = false, error = 'player_not_ready', animation = entry.name }
	end

	local clip = entry.clips[variant]
	local called, state, reason = pcall(api().play, player, entry.name, {
		clip = clip,
		loop = resolved.loop,
		durationMs = resolved.durationMs,
	})
	if not called then
		Open77.log.warn(('[animations] play raised for player %d (%s): %s'):format(player,
			entry.name, tostring(state)))
		return { ok = false, error = 'play_raised', animation = entry.name }
	end
	if not state then
		-- Reduced by Common.Code: anything that is not a code becomes a generic
		-- refusal rather than reaching a log line or a catalogue lookup.
		return { ok = false, error = Common.Code(reason) or 'play_refused', animation = entry.name,
			variant = variant }
	end

	local playbackId = type(state) == 'table' and Common.Text(state.playbackId, 64) and
		state.playbackId or nil
	locks[player] = nil
	if not resolved.cancelable then
		locks[player] = { playbackId = playbackId, untilMs = OPX.Now() + resolved.durationMs }
	end

	return {
		ok = true,
		animation = entry.name,
		variant = variant,
		clip = clip,
		playbackId = playbackId,
		cancelable = resolved.cancelable,
		durationMs = resolved.durationMs,
	}
end

--- Stops what this module's server half started on a player.
-- Nothing in progress is not a failure worth a toast: only an explicit refusal
-- carrying a code is one.
-- @author dop42
-- @param player Source
-- @param override boolean|nil true when the playback's owner or the platform asks
-- @return table
function Service.Stop(player, override)
	if not Service.Available() then return { ok = false, error = 'service_unavailable' } end
	local allowed, first = within('stop', player, 2)
	if not allowed then return { ok = false, error = 'rate_limited', quiet = not first } end
	if override ~= true and locked(player) then
		return { ok = false, error = 'animation_locked' }
	end

	local called, stopped, reason = pcall(api().stop, player)
	if not called then
		Open77.log.warn(('[animations] stop raised for player %d: %s'):format(player,
			tostring(stopped)))
		return { ok = false, error = 'stop_raised' }
	end
	if stopped == false and Common.Code(reason) ~= nil then
		return { ok = false, error = reason }
	end
	locks[player] = nil
	return { ok = true }
end

--- Sends a request's verdict to the player's client, unless it is quiet.
-- @author dop42
-- @param player Source
-- @param requestId integer 0 for a typed command
-- @param action string play or stop
-- @param result table
function Service.Answer(player, requestId, action, result)
	if result.quiet then return end
	TriggerClientEvent(M.Event.ANSWER, player, requestId, action, result.ok == true,
		result.error or '', {
			animation = result.animation or '',
			variant = result.variant or 0,
			playbackId = result.playbackId or '',
			cancelable = result.cancelable ~= false,
			durationMs = result.durationMs or 0,
		})
end

--- Forgets a departing player's rate windows and lock.
-- @author dop42
-- @param playerId any
function Service.Forget(playerId)
	local player = tonumber(playerId) or 0
	windows.play[player] = nil
	windows.stop[player] = nil
	locks[player] = nil
end
