--- The readiness gate: participation, hold, release, and the give-up watch.
-- @author dop42
--
-- > Nothing may teleport, spawn, kill or respawn a player until their readiness
-- > gate has opened.
--
-- Core declares its participation once, at load, which puts a hold on every
-- player who connects afterwards: it never races to take one before something
-- else moves the player, it already holds one before the player exists.
--
-- Two deadlines, and ours is the shorter. `livenessIntervalMs` is a watchdog on
-- the HOLDER, not a limit on the player -- someone may sit in a creator for an
-- hour as long as the holder refreshes. It fires only on proof that the holder
-- vanished, and the host then opens the gate itself with the detail
-- `liveness_lost:<resource>` or `timeout:<resource>` (the two sources disagree;
-- both are matched, see the handler at the foot of this file) -- possibly with
-- the player still choosing and no puppet at all. So the watch deadline sits
-- BELOW the declared interval: the runtime gives up first, and says why.
--
-- Ours is not the only hold. Every player carries a second one named
-- `__platform`, with no deadline, that no Lua can take or release: it clears only
-- once a client has announced `open77:session:gameplayReady`, with the puppet
-- really attached and alive. That is what an open gate means -- "this player is
-- incarnated", not merely "the other resources have finished". Without a
-- resource emitting it, every gate stays shut forever, hence the warning at
-- startup.
--
-- Core holds and releases; it does not decide who may come in. Loading a
-- character and reading a roster belong to whichever module provides the
-- `character` contract, so the entry sequence lives there: it holds, isolates,
-- sends its own roster, and hands the give-up decision to `Watch` as `onGiveUp`.
-- The two announcements below are the seam a module hooks to learn that a gate
-- has closed or opened without core having to know that module's name.

OPX.Gate = {}
local Gate = OPX.Gate

local Config = OPX.Config.SERVER

-- Announced after core takes a hold, and after it lets one go.
local HELD = OPX.Event(OPX.Channel.INTERNAL, 'gate', 'held')
local RELEASED = OPX.Event(OPX.Channel.INTERNAL, 'gate', 'released')

-- What the platform log shows against our hold, and the prefix on every release
-- note, which reaches every resource as the `detail` of `onPlayerReady`.
local REASON = 'opx_infinity:entry'
local NOTE_PREFIX = 'opx_infinity:'

-- Resources known to emit `open77:session:gameplayReady`. Without one of them
-- the `__platform` hold never clears and no gate ever opens.
local INCARNATORS = { 'opx77_appearance', 'open77_appearance' }

-- How often the watch looks at the slot it is watching.
local WATCH_TICK_MS = 1000

-- The shortest deadline that is worth declaring at all.
local FLOOR_MS = 1000

-- The gate configuration, validated once at load: a bad value is named once and
-- the shipped one is used in its place.
local liveness, deadlineMs = 300000, 240000
do
	local wanted = type(Config.ENTRY) == 'table' and Config.ENTRY or nil
	if wanted == nil then
		if Config.ENTRY ~= nil then
			Open77.log.warn('[gate] ENTRY is not a table: the shipped gate deadlines are used')
		end
		wanted = {}
	end

	local function milliseconds(value)
		return OPX.Math.IsFinite(value) and value % 1 == 0 and value >= FLOOR_MS
	end

	if wanted.GATE_MS ~= nil then
		if milliseconds(wanted.GATE_MS) then
			-- Clamped rather than refused: an operator who asked for ten minutes
			-- meant something by it, and the bounds are the host's, not ours.
			liveness = math.floor(OPX.Math.Clamp(wanted.GATE_MS, FLOOR_MS, 600000))
			if liveness ~= wanted.GATE_MS then
				Open77.log.warn(('[gate] ENTRY.GATE_MS is outside 1000..600000: %d ms is used')
					:format(liveness))
			end
		else
			Open77.log.warn(('[gate] ENTRY.GATE_MS is not a whole number of ms: %d is used')
				:format(liveness))
		end
	end

	if wanted.WATCH_MS ~= nil then
		if milliseconds(wanted.WATCH_MS) then
			deadlineMs = math.floor(wanted.WATCH_MS)
		else
			Open77.log.warn(('[gate] ENTRY.WATCH_MS is not a whole number of ms: %d is used')
				:format(deadlineMs))
		end
	end

	-- The whole point of the watch is to give up BEFORE the host concludes we are
	-- dead: a deadline at or above the liveness interval hands that decision back
	-- to the host, which opens the gate without knowing whether the player is
	-- incarnated at all.
	if deadlineMs >= liveness then
		deadlineMs = math.max(FLOOR_MS, math.floor(liveness * 0.8))
		Open77.log.error(('[gate] ENTRY.WATCH_MS must sit below ENTRY.GATE_MS (%d ms): %d ms is used')
			:format(liveness, deadlineMs))
	end
end

-- A caller's own deadline still has to sit below the declared liveness interval,
-- and an absent or unusable one falls back to the configured deadline.
local function deadlineFor(timeoutMs)
	if not OPX.Math.IsFinite(timeoutMs) or timeoutMs < FLOOR_MS then return deadlineMs end
	return math.floor(OPX.Math.Clamp(timeoutMs, FLOOR_MS, deadlineMs))
end

--- Declares core's participation in the gate. Called once, at load, so that every
--- connection afterwards arrives already held in core's name.
-- @author dop42
function OPX.Gate.Participate()
	Open77.ready.participate({
		livenessIntervalMs = liveness,
		reason = REASON,
	})
	Open77.log.info(('[gate] declaring a %d ms liveness interval on the readiness gate')
		:format(liveness))

	-- This runtime's own appearance module announces it, so ask the registry
	-- first: a module inside this resource does not appear in `GetResourceState`,
	-- and checking only the external names would warn that no gate ever opens
	-- while they all do.
	local incarnates = OPX.Modules.Record('appearance') ~= nil
	if not incarnates then
		for _, name in ipairs(INCARNATORS) do
			local state = GetResourceState(name)
			if state == 'running' or state == 'starting' then
				incarnates = true
				break
			end
		end
	end
	if not incarnates then
		Open77.log.warn(('[gate] no resource here emits `%s`, so the `__platform` hold never clears ' ..
			'and every gate stays shut'):format(OPX.Host.GAMEPLAY_READY))
	end
end

--- Takes the gate hold for one player and records its session number.
--- The session number is what keeps a later release honest: releasing by a
--- recycled player id alone could lift somebody else's hold.
-- @author dop42
-- @param source Source
-- @param reason string|nil what the platform log shows against the hold
-- @return boolean
function OPX.Gate.Hold(source, reason)
	source = tonumber(source)
	local session = source and OPX.Sessions[source]
	if not session then return false end

	-- `hold` answers ONE value, the session, or nil and a reason.
	local gateSession, refused = Open77.ready.hold(source, reason or REASON)
	if gateSession == nil then
		Open77.log.warn(('[gate] the hold for %d was refused: %s'):format(source, tostring(refused)))
		return false
	end

	session.gateSession = gateSession
	session.heldAt = OPX.Now()
	session.released = nil

	TriggerEvent(HELD, source)
	return true
end

--- Releases a player's gate hold, idempotently, with a note.
--- Safe for a player who never held one. With no known gate session the status is
--- asked of the host rather than the release skipped: a hold nobody releases has
--- no deadline, and blocks that player for as long as this resource answers.
-- @author dop42
-- @param source Source
-- @param note string|nil reaches every resource as the detail of onPlayerReady
-- @return boolean
function OPX.Gate.Release(source, note)
	source = tonumber(source)
	if not source then return false end

	local session = OPX.Sessions[source]
	local gateSession = session and session.gateSession
	if gateSession == nil then
		-- THE INDEX IS INSIDE THE PCALL. `pcall(Open77.ready.status, source)`
		-- resolves `Open77.ready.status` BEFORE pcall is called, so a host that
		-- does not install it raised on the index, outside the protection written
		-- for exactly that. Same correction as `IsReady` below and as `permitted`
		-- in `core/server/commands.lua`.
		local read, status = pcall(function() return Open77.ready.status(source) end)
		gateSession = read and type(status) == 'table' and status.session or nil
	end

	-- THE HOST'S ANSWER IS READ, and it was not. `release` answers true, or false
	-- plus a reason -- "a session that no longer matches is dropped rather than
	-- releasing a newer hold" -- and this function returned a hard-coded `true`
	-- whatever came back. `Hold` twenty lines above has always read its refusal;
	-- the two halves of one mechanism disagreed.
	--
	-- Only an explicit `false` counts as a refusal. A host that answers nothing
	-- at all is not refusing, and reading nil as a refusal would turn every
	-- release on such a build into a player stuck behind the gate -- the exact
	-- failure this is here to prevent.
	local opened, refused = Open77.ready.release(source, gateSession, NOTE_PREFIX .. (note or 'done'))
	if opened == false then
		-- OUR STATE IS CLEARED ONLY ON SUCCESS, and it was cleared BEFORE the
		-- call. `session.released = true` with the host still holding is the one
		-- combination nothing recovers from: `Watch` exits on `released`, so the
		-- hold then belongs to nobody, and the player waits behind a shut gate
		-- until the host's own liveness interval expires. Leaving the session
		-- marked held lets the watch, or a later release, try again.
		Open77.log.error(('[gate] the release for %d was refused: %s')
			:format(source, tostring(refused)))
		return false
	end

	if session then
		session.gateSession = nil
		session.released = true
	end

	Open77.log.debug(('[gate] released for %d (%s)'):format(source, note or 'done'))

	TriggerEvent(RELEASED, source, note or 'done')
	return true
end

--- Whether the gate has opened for this player.
--- A read the host raises on reads as open: the alternative is holding a player
--- the host cannot answer for behind a gate nothing will ever open.
-- @author dop42
-- @param source Source
-- @return boolean
function OPX.Gate.IsReady(source)
	-- The index is inside the pcall, for the reason spelled out in `Release`: a
	-- host with no `Open77.ready.isReady` raised on the index rather than being
	-- caught here.
	local read, open = pcall(function() return Open77.ready.isReady(source) end)
	return not read or open == true
end

--- Watches one player and gives up on them at a deadline, so that nobody holds
--- the gate for a whole session.
--- One thread per watched player. It exits on its own once the slot empties,
--- changes hands, or the gate is released -- which is what a caller loading a
--- character does anyway.
---
--- `onGiveUp` is the seam for everything core cannot know. It is called once, at
--- the deadline, before anything is released: answering `false` means "this
--- player is mine now" -- a character is loaded or loading -- and the watch stops
--- without touching the hold, leaving it for that caller to release. Any other
--- answer, and an absent `onGiveUp`, mean core releases the hold itself. That is
--- the safe default: an unreleased hold has no deadline.
-- @author dop42
-- @param source Source
-- @param timeoutMs integer|nil clamped below the declared liveness interval
-- @param onGiveUp function|nil called as onGiveUp(source) at the deadline
-- @return boolean whether a watch was started
function OPX.Gate.Watch(source, timeoutMs, onGiveUp)
	source = tonumber(source)
	local session = source and OPX.Sessions[source]
	if not session then return false end

	local userId = session.userId
	local deadline = OPX.Now() + deadlineFor(timeoutMs)

	CreateThread(function()
		while true do
			Wait(WATCH_TICK_MS)

			local live = OPX.Sessions[source]
			if not live or live.userId ~= userId or live.released then return end

			-- The whole decision runs under `pcall`: a raise here would leave this
			-- player holding the gate for the rest of the session.
			local ok, done = pcall(function()
				if OPX.Now() < deadline then return false end
				if onGiveUp ~= nil and onGiveUp(source) == false then return true end

				Open77.log.warn(('[gate] %d spent too long behind the gate; releasing without them')
					:format(source))
				Gate.Release(source, 'watch-timeout')
				return true
			end)

			if not ok then
				Open77.log.error(('[gate] the watch for %d raised: %s'):format(source, tostring(done)))
				return
			end
			if done then return end
		end
	end)

	return true
end

-- The host opens a gate itself when it decides a holder has vanished, and names
-- the holders it gave up on. If this runtime is one of them the player is in the
-- world with the gate open and, very possibly, no character -- which then looks
-- like a bug in whatever they touch next rather than like what it is.
--
-- Two sources disagree about what `detail` actually says, so this matches both.
-- `opx77_core` read the shipped assemblies on op77.11 and found
-- `liveness_lost:<resource>` and no sign of `timeout:` or `no_holds`. The
-- platform's own documentation for op77.75 says the set is `cleared`,
-- `no_holds`, `resource_reloaded`, `resource_stopped` and `timeout:<resource>`,
-- and never mentions `liveness_lost`. Both were checked; neither is guessed.
-- Betting on one spelling is how a real timeout goes unnoticed, and the cost of
-- matching all of them is one extra comparison.
local GAVE_UP = { 'liveness_lost:', 'timeout:' }

AddEventHandler(OPX.Host.PLAYER_READY, function(rawPlayerId, detail)
	local source = tonumber(rawPlayerId)
	if source == nil or type(detail) ~= 'string' then return end

	if detail == 'no_holds' then
		-- Nobody was holding at all, which means this runtime never took its
		-- hold for that player: the entry sequence did not run for them.
		Open77.log.warn(('[gate] %d was admitted with no hold taken at all'):format(source))
		return
	end

	local prefix
	for index = 1, #GAVE_UP do
		if detail:sub(1, #GAVE_UP[index]) == GAVE_UP[index] then prefix = GAVE_UP[index] break end
	end
	if prefix == nil then return end
	if not detail:find(GetCurrentResourceName(), #prefix + 1, true) then return end

	Open77.log.warn(('[gate] the host gave up on this runtime holding %d (%s)')
		:format(source, detail))
	Open77.log.warn('  that player may be in the world with no character loaded.')
end)

Gate.Participate()
