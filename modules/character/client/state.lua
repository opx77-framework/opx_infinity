--- Reading the OTHER people: the replicated character bag, mirrored locally.
-- @author dop42
--
-- `client/main.lua` mirrors the LOCAL character and nothing else, because that is
-- all `M.Event.DATA` ever carried. This file is the other half: anybody in the
-- bucket, read off the state bag the server writes in `server/state.lua`.
--
--   local who = OPX.Api.Get('character').GetPlayerState(playerId)
--   who.name        --> 'Vincent Kowalski', or nil while the character is nameless
--   who.username    --> the Master-verified account name
--   who.citizenId   --> '4A7-KM9C'
--   who.job.label   --> 'NCPD'
--
-- NO PERMISSION, NO EVENT, NO ROUND TRIP. Reading a bag is free and needs nothing
-- declared; the server decided what was fit to replicate when it wrote it, and a
-- bag a client cannot see is a bag in another routing bucket, which is a player
-- this client has no business drawing anyway.
--
-- WHY THERE IS A CACHE AT ALL. `bag:all()` is a host call that copies the whole
-- bag, and the callers are draw loops: the name tags ask for up to thirty-two
-- players four times a second. So a bag is pulled once and then PATCHED from the
-- change handler -- one subscription for every player bag, filtered on the host
-- side, which is the shape the platform asks for. A player the cache has never
-- seen costs exactly one call, once.

local M = OPX.Modules.Get('character')

M.PlayerState = {}
local PlayerState = M.PlayerState

-- Answered for anybody there is nothing to say about, so a caller may always
-- index the result. Never handed out to be written: it is shared.
local EMPTY = {}

-- Mirrored bags by player id, and how many are held.
local mirror, held = {}, 0

-- Past this the cache is dropped whole rather than walked. Player ids are
-- recycled and nothing on the client is told when one leaves, so entries for
-- people who have gone accumulate slowly and for ever. A city bucket does not
-- hold this many bodies at once, so the sweep never fires while anybody is being
-- drawn -- and if it does, the cost is one host call per player still on screen.
local CEILING = 256

-- The subscription handle, so `Stop` can retire it.
local watch = nil

-- Logged once.
local reported = false

--- Whether this client's host replicates bags.
-- `Open77.state` also carries the resource-private `save`/`load`/`clear`, which
-- have nothing to do with bags, so the test names the accessor.
-- @author dop42
-- @return boolean
function PlayerState.Available()
	local state = Open77.state
	return type(state) == 'table' and type(state.player) == 'function'
end

--- Everything the server published about one player, or an empty table.
-- The answer is the cache's own table: read it, never write it.
-- @author dop42
-- @param playerId Source
-- @return table
function PlayerState.Of(playerId)
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 or not PlayerState.Available() then return EMPTY end

	local known = mirror[playerId]
	if known ~= nil then return known end

	local read, bag = pcall(Open77.state.player, playerId)
	if not read or type(bag) ~= 'table' then return EMPTY end
	local pulled, all = pcall(bag.all, bag)
	if not pulled or type(all) ~= 'table' then return EMPTY end

	if held >= CEILING then mirror, held = {}, 0 end
	mirror[playerId] = all
	held = held + 1
	-- The delta handler only fires on a CHANGE, so somebody who was named before
	-- this client ever saw them would keep the account's plate for ever. The
	-- first pull is the other half of that: whoever asks about a player also
	-- gets their plate put right.
	if type(all.name) == 'string' and all.name ~= '' then
		PlayerState.Label(playerId, all.name)
	end
	return all
end

--- The character name of a player, or nil.
-- Nil is an ordinary answer and not a failure: a character is a row before it is
-- anybody, and somebody who has not been named yet has no name to draw.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function PlayerState.NameOf(playerId)
	local name = PlayerState.Of(playerId).name
	return type(name) == 'string' and name ~= '' and name or nil
end

--- The identity of a player as three strings, any of which may be nil.
-- What anything drawing a body over somebody's head wants, in one read: who the
-- character is, who is playing them, and the character's public id.
-- @author dop42
-- @param playerId Source
-- @return table
function PlayerState.IdentityOf(playerId)
	local state = PlayerState.Of(playerId)
	local function textOf(value)
		return type(value) == 'string' and value ~= '' and value or nil
	end
	return {
		name = textOf(state.name),
		username = textOf(state.username),
		citizenId = textOf(state.citizenId),
	}
end

-- Players this VM has put a plate override on, so `Stop` can take them back.
local plated = {}

--- Puts a character's name on the plate above their head, or takes the override
--- back when they have no name yet.
---
--- NOTHING READ THIS KEY. The server has always written the character's name to
--- the bag, at the right moment -- and the plate above a head is drawn by the
--- platform, labelled with the displayName the Master vouches for. So a player
--- who had just named their character still walked around under their gamertag,
--- on the first connection and on the hundredth. `opx_infinity` never called
--- `Open77.nameplates.set` and never declared `ui.nameplates`.
---
--- Indexed by name before it is called: a client build without the namespace
--- would otherwise raise on the index, and this runs from a state delta.
-- @author dop42
-- @param playerId Source
-- @param label string|nil the character's name, or nil to hand the plate back
function PlayerState.Label(playerId, label)
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return false end

	local api = Open77.nameplates
	if type(api) ~= 'table' then return false end

	if type(label) ~= 'string' or label == '' then
		if not plated[playerId] then return false end
		plated[playerId] = nil
		if type(api.remove) ~= 'function' then return false end
		local called, dropped, why = pcall(api.remove, playerId)
		if not called or dropped == false then
			Open77.log.warn(('[character] the plate override for %d was not taken back: %s')
				:format(playerId, tostring(called and why or dropped)))
			return false
		end
		return true
	end

	if type(api.set) ~= 'function' then return false end
	local called, applied, why = pcall(api.set, playerId, { label = label })
	if not called or applied == false then
		Open77.log.warn(('[character] the plate for %d still says the account name: %s')
			:format(playerId, tostring(called and why or applied)))
		return false
	end
	plated[playerId] = true
	return true
end

--- Subscribes to every player bag and mirrors the deltas.
-- @author dop42
function PlayerState.Start()
	if not PlayerState.Available() then
		if reported then return end
		reported = true
		return Open77.log.warn('[character] this client does not replicate state bags: only the ' ..
			'local character is known')
	end

	local state = Open77.state
	if type(state.onChange) ~= 'function' then return end

	-- ONE subscription for every player bag and every key. The filter lives on the
	-- host side, so a key moving on somebody this runtime never asks about costs
	-- this VM nothing; the alternative -- a subscription per player as they are
	-- first seen -- pays a watcher limit for the same answer.
	local made, handle = pcall(state.onChange, 'player', nil, function(selector, key, value)
		local playerId = tonumber(type(selector) == 'table' and selector.id or nil)
		if playerId == nil then return end
		-- THE PLATE FIRST, AND WITHOUT THE MIRROR. The name is what the plate
		-- above a head says, and it must be applied whether or not anything has
		-- ever asked this VM about that player: a body walking past is drawn by
		-- the platform long before anybody calls `Of` on it.
		if key == 'name' then PlayerState.Label(playerId, value) end
		local known = mirror[playerId]
		-- A bag nobody has asked about is left unpulled: the next `Of` reads it
		-- whole, which is cheaper than mirroring changes for a body off screen.
		if known == nil then return end
		known[key] = value
	end)
	-- `made` IS THE PCALL, NOT THE NATIVE. `onChange` answers nil plus a reason
	-- -- `invalid_state_selector`, `invalid_state_key`,
	-- `invalid_handler_or_watcher_limit` -- and this read only whether the call
	-- raised. A refused subscription left `watch` nil and said nothing, so every
	-- bag cached before a name arrived stayed anonymous for the whole session,
	-- which is exactly the first connection.
	if made and handle ~= nil then
		watch = handle
	else
		Open77.log.error(('[character] no subscription to player state: %s')
			:format(tostring(made and 'the host refused it' or handle)))
		Open77.log.error('  names will not appear above heads or update in place.')
	end
end

--- Retires the subscription and forgets everybody.
-- @author dop42
function PlayerState.Stop()
	local state = Open77.state
	if watch ~= nil and type(state) == 'table' and type(state.offChange) == 'function' then
		pcall(state.offChange, watch)
	end
	watch = nil
	mirror, held = {}, 0

	-- The overrides go back with the module. The platform cleans them up when the
	-- RESOURCE stops, which is not the same thing: a module stopped on its own
	-- would otherwise leave every plate frozen on the name it last wrote.
	for playerId in pairs(plated) do
		local api = Open77.nameplates
		if type(api) == 'table' and type(api.remove) == 'function' then
			pcall(api.remove, playerId)
		end
	end
	plated = {}
end
