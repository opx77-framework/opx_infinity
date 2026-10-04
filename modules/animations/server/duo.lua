--- Emotes with a nearby player: the invitation, the answer and the pair.
-- @author dop42
--
-- THE PLATFORM PLAYS THE PAIR; THIS FILE ONLY ASKS. `Open77.playerInteractions`
-- is the platform's two-player coordinator: it reserves both players, checks
-- the distance against the positions the server observes, schedules one start
-- for both bodies and cancels on death, a vehicle, a bucket change, separation
-- or a presentation failure. Kind `custom` takes one RP profile per body, which
-- is what a configured pair names.
--
-- WHAT IT DOES NOT DO is ask the other player in this resource's voice. Its own
-- invitation is a chat line ("/interaction accept"), so the consent is taken
-- here instead -- an invitation on the invited player's screen, answered from
-- the picker's menu or `/e accept` -- and the coordinator is called with
-- `consent = false` only once that answer is in, which is the case its guide
-- names: "gameplay whose authorization is already established".
--
-- Every player id here comes from an authenticated connection; the invited
-- player is chosen by the server, as the nearest one in range, never named by
-- the client asking.

local M = OPX.Modules.Get('animations')
local Common = M.Common
local Opt = M.Opt
local Service = M.Service

M.Duo = {}
local Duo = M.Duo

-- Invitations by id, and the invitation each player is part of, either side.
local invites, inviteOf = {}, {}

-- Pairs the coordinator accepted, by interaction id, and each player's.
local running, runningOf = {}, {}

-- Last invitation serial handed out.
local serial = 0

-- The sweep that expires unanswered invitations.
local sweepJob = nil

-- Read at the moment of use: at load the host may not have installed the API.
local function coordinator()
	local native = Open77.playerInteractions
	return type(native) == 'table' and type(native.request) == 'function' and native or nil
end

--- Whether emotes with a nearby player can be offered at all.
-- @author dop42
-- @return boolean
function Duo.Available()
	return Opt.SHARED and coordinator() ~= nil
end

-- Answers a configured pair whose two profiles this build offers, or nil.
-- Both must be stationary: the coordinator plays a `custom` pair on workspots.
local function playable(id)
	for _, pair in ipairs(Opt.SHARED_PAIRS) do
		if pair.id == id then
			local actor = Service.Offered(pair.actor)
			local target = Service.Offered(pair.target)
			if actor ~= nil and target ~= nil and actor.kind == 'workspot'
				and target.kind == 'workspot' then
				return pair
			end
			return nil
		end
	end
	return nil
end

--- Answers the ids of the pairs this build can play, in config order.
-- @author dop42
-- @return string[]
function Duo.Offered()
	local ids = {}
	if not Duo.Available() then return ids end
	for _, pair in ipairs(Opt.SHARED_PAIRS) do
		if playable(pair.id) then ids[#ids + 1] = pair.id end
	end
	return ids
end

-- A player's finite position and bucket, or nil.
local function positionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y),
		OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(position.bucket) or 0) }
end

-- Squared distance between two positions, or nil across buckets: two players
-- in different buckets can stand on the same coordinates and never see each
-- other.
local function apart(here, there)
	if here == nil or there == nil or here.bucket ~= there.bucket then return nil end
	local dx, dy, dz = here.x - there.x, here.y - there.y, here.z - there.z
	return dx * dx + dy * dy + dz * dz
end

-- Whether two players stand within range of each other right now.
local function near(a, b)
	local squared = apart(positionOf(a), positionOf(b))
	return squared ~= nil and squared <= Opt.SHARED_RANGE * Opt.SHARED_RANGE
end

-- The name the other player reads: the CHARACTER'S, the account's as a fallback.
local function nameOf(playerId)
	local character = OPX.Api.Get('character')
	if character ~= nil and type(character.GetPlayer) == 'function' then
		local read, loaded = pcall(character.GetPlayer, playerId)
		local data = read and type(loaded) == 'table' and loaded.PlayerData or nil
		local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo
			or nil
		if info ~= nil then
			local first = type(info.firstName) == 'string' and info.firstName or ''
			local last = type(info.lastName) == 'string' and info.lastName or ''
			local full = OPX.String.Trim(first .. ' ' .. last)
			if full ~= '' then return (full:gsub('%c', ' ')):sub(1, 32) end
		end
	end
	local read, name = pcall(Open77.players.name, playerId)
	if read and type(name) == 'string' and name ~= '' then return (name:gsub('%c', ' ')):sub(1, 32) end
	return '#' .. tostring(playerId)
end

-- Tells one player how their emote with somebody went.
local function notify(player, kind, code, params)
	TriggerClientEvent(M.Event.NOTICE, player, kind, code, params or {})
end

-- The nearest player who may be invited, or nil.
local function nearest(player)
	local here = positionOf(player)
	if here == nil then return nil end
	local read, everyone = pcall(Open77.players.all)
	if not read or type(everyone) ~= 'table' then return nil end
	local best, bestSquared = nil, Opt.SHARED_RANGE * Opt.SHARED_RANGE
	for _, value in ipairs(everyone) do
		local other = tonumber(value)
		if other ~= nil and other ~= player and inviteOf[other] == nil and runningOf[other] == nil
			and Service.Ready(other) then
			local squared = apart(here, positionOf(other))
			if squared ~= nil and squared <= bestSquared then
				best, bestSquared = other, squared
			end
		end
	end
	return best
end

-- Forgets an invitation on both sides.
local function drop(invite)
	invites[invite.id] = nil
	if inviteOf[invite.actor] == invite.id then inviteOf[invite.actor] = nil end
	if inviteOf[invite.target] == invite.id then inviteOf[invite.target] = nil end
end

-- Forgets a running pair on both sides.
local function release(id)
	local pair = running[id]
	if pair == nil then return nil end
	running[id] = nil
	if runningOf[pair.actor] == id then runningOf[pair.actor] = nil end
	if runningOf[pair.target] == id then runningOf[pair.target] = nil end
	return pair
end

--- Invites the nearest player to an emote together.
-- @author dop42
-- @param player Source the authenticated requester
-- @param id any a configured pair id
-- @return table result: ok, error, quiet
function Duo.Request(player, id)
	if not Duo.Available() then return { ok = false, error = 'duo_unavailable' } end
	local pair = type(id) == 'string' and playable(id) or nil
	if pair == nil then return { ok = false, error = 'unknown_animation' } end
	local allowed, first = Service.Within(player)
	if not allowed then return { ok = false, error = 'rate_limited', quiet = not first } end
	if not Service.Ready(player) then return { ok = false, error = 'player_not_ready' } end
	if inviteOf[player] ~= nil or runningOf[player] ~= nil then
		return { ok = false, error = 'duo_busy' }
	end
	local target = nearest(player)
	if target == nil then return { ok = false, error = 'no_player_nearby' } end

	serial = serial + 1
	if serial > M.MAX_REQUEST_ID then serial = 1 end
	local invite = { id = serial, actor = player, target = target, pair = pair,
		untilMs = OPX.Now() + Opt.SHARED_INVITE_MS }
	invites[invite.id], inviteOf[player], inviteOf[target] = invite, invite.id, invite.id
	TriggerClientEvent(M.Event.INVITE, target, invite.id, pair.id, nameOf(player),
		Opt.SHARED_INVITE_MS)
	return { ok = true, name = nameOf(target), pair = pair.id }
end

--- Takes the invited player's answer and, on a yes, starts the pair.
-- @author dop42
-- @param target Source the authenticated answerer
-- @param inviteId any
-- @param accepted any
function Duo.Reply(target, inviteId, accepted)
	local invite = invites[Common.Integer(inviteId, 1, M.MAX_REQUEST_ID) or 0]
	-- Somebody else's invitation is not theirs to answer.
	if invite == nil or invite.target ~= target then
		if accepted == true then notify(target, 'warning', 'expired') end
		return
	end
	drop(invite)
	local actor = invite.actor
	if OPX.Now() > invite.untilMs then
		notify(target, 'warning', 'expired')
		notify(actor, 'info', 'expired')
		return
	end
	if accepted ~= true then
		notify(actor, 'info', 'declined', { name = nameOf(target) })
		return
	end
	-- MEASURED AGAIN AT THE YES: the invitation can wait fifteen seconds, and
	-- whoever walked off in that time is not dragged into a pose.
	if not near(actor, target) then
		notify(actor, 'warning', 'too_far')
		notify(target, 'warning', 'too_far')
		return
	end
	local native = coordinator()
	if native == nil or not Opt.SHARED then
		notify(actor, 'warning', 'duo_unavailable')
		notify(target, 'warning', 'duo_unavailable')
		return
	end
	local range = Opt.SHARED_RANGE
	local called, state, reason = pcall(native.request, actor, target, 'custom', {
		actorAnimation = invite.pair.actor,
		targetAnimation = invite.pair.target,
		durationMs = invite.pair.durationMs,
		startDistance = range,
		breakDistance = math.min(20, range + 2),
		consent = false,
	})
	if not called or type(state) ~= 'table' or type(state.id) ~= 'string' then
		local code = called and Common.Code(reason) or 'play_raised'
		Open77.log.warn(('[animations] pair %s for %d and %d refused: %s'):format(invite.pair.id,
			actor, target, tostring(called and reason or state)))
		notify(actor, 'warning', code or 'play_refused')
		notify(target, 'warning', code or 'play_refused')
		return
	end
	running[state.id] = { actor = actor, target = target }
	runningOf[actor], runningOf[target] = state.id, state.id
	notify(actor, 'success', 'accepted', { name = nameOf(target) })
end

--- Answers the invitation a player has been sent, from a typed command.
-- @author dop42
-- @param player Source
-- @param accepted boolean
-- @return boolean whether there was one to answer
function Duo.Answer(player, accepted)
	local invite = invites[inviteOf[player] or 0]
	if invite == nil or invite.target ~= player then return false end
	Duo.Reply(player, invite.id, accepted)
	return true
end

--- Withdraws a player's invitation and ends their pair, whichever side they are.
-- @author dop42
-- @param player Source
-- @param reason string
function Duo.Cancel(player, reason)
	local invite = invites[inviteOf[player] or 0]
	if invite ~= nil then
		drop(invite)
		if player == invite.actor then
			TriggerClientEvent(M.Event.UNINVITE, invite.target, invite.id)
		else
			notify(invite.actor, 'info', 'declined', { name = nameOf(player) })
		end
	end
	local id = runningOf[player]
	if id ~= nil then
		release(id)
		local native = Open77.playerInteractions
		if type(native) == 'table' and type(native.cancel) == 'function' then
			local called, _, refused = pcall(native.cancel, id, reason)
			if not called or refused ~= nil then
				Open77.log.debug(('[animations] pair %s not cancelled: %s'):format(id,
					tostring(refused)))
			end
		end
	end
end

--- Forgets a departing player, ending what they were part of.
-- @author dop42
-- @param playerId any
function Duo.Forget(playerId)
	local player = tonumber(playerId)
	if player ~= nil then Duo.Cancel(player, 'disconnected') end
end

-- Reads a coordinator state, a table or the JSON the server events may carry.
local function stateOf(value)
	if type(value) == 'string' and type(json) == 'table' then
		local read, decoded = pcall(json.decode, value)
		value = read and decoded or nil
	end
	return type(value) == 'table' and type(value.id) == 'string' and value or nil
end

-- A pair ended on the coordinator's side. Only one this resource started is
-- ours to follow; one ended by something other than a stop says so to both.
local function ended(value)
	local state = stateOf(value)
	if state == nil then return end
	local pair = release(state.id)
	if pair == nil then return end
	local reason = Common.Code(state.reason)
	if state.phase == 'completed' or reason == 'completed' or reason == 'stopped'
		or reason == 'disconnected' then
		return
	end
	notify(pair.actor, 'warning', reason or 'interrupted')
	notify(pair.target, 'warning', reason or 'interrupted')
end

-- Expires invitations nobody answered.
local function sweep()
	local atMs = OPX.Now()
	for id, invite in pairs(invites) do
		if atMs > invite.untilMs then
			drop(invite)
			TriggerClientEvent(M.Event.UNINVITE, invite.target, id)
			notify(invite.actor, 'info', 'expired')
		end
	end
end

--- Wires the two inbound requests, the coordinator's events and the sweep.
-- @author dop42
function Duo.Start()
	invites, inviteOf, running, runningOf = {}, {}, {}, {}

	RegisterNetEvent(M.Event.DUO, function(id)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		local result = Duo.Request(player, id)
		if result.quiet then return end
		if result.ok then
			notify(player, 'info', 'sent', { name = result.name })
		else
			notify(player, 'warning', result.error)
		end
	end)

	RegisterNetEvent(M.Event.REPLY, function(inviteId, accepted)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		Duo.Reply(player, inviteId, accepted == true)
	end)

	AddEventHandler('onPlayerInteractionCompleted', ended)
	AddEventHandler('onPlayerInteractionCancelled', ended)

	sweepJob = OPX.Scheduler.Every('animations:duo', 1000, sweep)

	if Opt.SHARED and coordinator() == nil then
		Open77.log.warn('[animations] Open77.playerInteractions is unavailable (a build without ' ..
			'open77_player_interactions, or players.interactions.control not granted); no ' ..
			'emote with a nearby player is offered')
	end
end

--- Ends every pair and invitation this resource holds.
-- @author dop42
function Duo.Stop()
	if sweepJob ~= nil then
		OPX.Scheduler.Cancel(sweepJob)
		sweepJob = nil
	end
	for player in pairs(inviteOf) do Duo.Cancel(player, 'stopped') end
	for player in pairs(runningOf) do Duo.Cancel(player, 'stopped') end
	invites, inviteOf, running, runningOf = {}, {}, {}, {}
end
