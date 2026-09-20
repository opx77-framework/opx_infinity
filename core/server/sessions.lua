--- Connected machines, keyed by the account the host vouches for.
-- @author dop42
--
-- A session is a connected machine; a character is something a module loads onto
-- one. They are not the same thing and confusing them is how a framework either
-- refuses a legitimate connection or trusts a character that was never loaded:
-- someone sitting in a selection screen has a session and no character.
--
-- `playerId` is recycled and `userId` is durable, so the id is only ever a lookup
-- key and every read re-checks the account behind the slot. A departure nobody
-- reported then becomes a non-event instead of a hole.
--
-- Core owns sessions. It does NOT own the character roster -- that belongs to
-- whichever module provides the `character` contract, and core must not know its
-- name. `ForgetSession` announces on the internal channel and lets that module
-- do its own unloading.

OPX.Sessions = {}

local FORGOTTEN = OPX.Event(OPX.Channel.INTERNAL, 'session', 'forgotten')

-- Kept once found. During boot the global may not be installed yet, and a nil
-- cached now would answer "nobody" for every call afterwards.
local identifierOf

--- The durable account id the host vouches for, or nil before it can be read.
-- @author dop42
-- @param playerId Source
-- @return UserId|nil
function OPX.UserIdOf(playerId)
	if identifierOf then return identifierOf(playerId) end
	local fn = GetPlayerIdentifier
	if not fn then return nil end
	identifierOf = fn
	return fn(playerId)
end

--- The player's chosen display name, which the Master has verified.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function OPX.DisplayNameOf(playerId)
	local fn = GetPlayerName
	return fn and fn(playerId) or nil
end

--- The session on a slot, creating it or evicting a stale one. The only way a
--- session is ever made: without a verified identity nothing can be attributed
--- to it, so the session is forgotten and the answer is nil.
-- @author dop42
-- @param playerId Source|string host events carry strings
-- @return table|nil
function OPX.EnsureSession(playerId)
	playerId = tonumber(playerId)
	if not playerId or playerId <= 0 then return nil end

	local userId = OPX.UserIdOf(playerId)
	if userId == nil or userId == '' then
		OPX.ForgetSession(playerId)
		return nil
	end

	local session = OPX.Sessions[playerId]
	if session then
		if session.userId == userId then return session end
		Open77.log.warn(('[session] slot %d now belongs to a different account, evicting')
			:format(playerId))
		OPX.ForgetSession(playerId)
	end

	session = {
		source = playerId,
		userId = userId,
		displayName = OPX.DisplayNameOf(playerId) or '',
		connectedAt = OPX.Now(),
		gateSession = nil,
	}
	OPX.Sessions[playerId] = session
	return session
end

--- Drops a session. This disconnects, it does not discard: the session is marked
--- `departing` first, so a module unloading a character knows not to put a
--- leaving player back into a selection bucket, and the announcement happens
--- while the session can still be read.
-- @author dop42
-- @param playerId Source
function OPX.ForgetSession(playerId)
	playerId = tonumber(playerId)
	if not playerId then return end

	local session = OPX.Sessions[playerId]
	if session then session.departing = true end

	TriggerEvent(FORGOTTEN, playerId)

	OPX.Sessions[playerId] = nil
end

--- Whether the account behind a slot is still the one the session was made for.
--- A false answer means the id was recycled, and anything keyed on it is stale.
-- @author dop42
-- @param playerId Source
-- @return boolean
function OPX.SessionHolds(playerId)
	local session = OPX.Sessions[playerId]
	if not session then return false end
	return session.userId == OPX.UserIdOf(playerId)
end
