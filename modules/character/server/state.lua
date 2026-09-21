--- The replicated character bag: what the city is allowed to know about the
--- person standing in front of it.
-- @author dop42
--
-- Everything this module knew about a character reached exactly one client --
-- its own -- on `M.Event.DATA`. Anybody else who needed to put a name to a body
-- had to ask the server for a list and be sent one, which is the whole of what
-- the staff name tags used to be. A state bag replaces that: the server writes a
-- key, every client entitled to see it has it in the same tick, and a reader
-- needs no event, no permission and no round trip.
--
--   -- any client, any module, no wiring at all
--   local who = Open77.state.player(playerId)
--   print(who.name, who.job.label)
--
-- THE AUDIENCE IS THE BUCKET, and that is the one thing to hold on to while
-- adding a key here. A player bag goes to every player in that player's routing
-- bucket, the subject included. It is not a private channel and it is not a staff
-- channel: a key written here is a key every client in the city can read and a
-- modified client can keep. So the rule for this file is
--
--   IF IT WOULD BE A LEAK ON A NAME TAG, IT DOES NOT GO IN THE BAG.
--
-- which is why `money`, `metadata`, `userId`, `payment` and `bankAuth` are all
-- absent, and will read as conspicuous absences to anybody who has seen
-- PlayerData. They stay on `M.Event.DATA`, which goes to the owner alone.
--
-- WHAT A KEY COSTS. A write is a delta to the bucket, and this file is called
-- from `UpdatePlayerData`, which fires on every metadata write anybody makes -- a
-- needs tick, an armour change, a door opening. So nothing is written that has
-- not moved: each key is encoded once and compared against what was last
-- published, and an unchanged key is not touched. The cost of a busy character is
-- then one JSON encode per key per change, and no network at all.

local M = OPX.Modules.Get('character')

M.State = {}
local State = M.State

-- The keys this module owns on a player's bag. Nothing outside this list is
-- written here, and a key leaving the list has to be cleared off the bags that
-- already carry it -- which is what `Release` is for.
local KEYS = { 'citizenId', 'name', 'charInfo', 'job', 'gang', 'username', 'life' }

-- The encoded value last published, per player id and key, so an unchanged key is
-- never written twice.
local published = {}

-- Refusals already logged, one line each: a cap breached on one character is
-- breached on the next one too, and the log is not the place to find that out
-- sixty times a second.
local reported = {}

local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	Open77.log.warn('[character] ' .. message)
end

--- Whether this host replicates bags at all.
-- `Open77.state` also carries `save`/`load`/`clear`, which are resource-private
-- storage and have nothing to do with bags, so the feature test names the
-- accessor and not the table.
-- @author dop42
-- @return boolean
function State.Available()
	local state = Open77.state
	return type(state) == 'table' and type(state.player) == 'function'
end

-- A non-empty string, or nil. A nil clears the key rather than writing the word
-- "nil" onto somebody's nameplate.
local function textOr(value)
	if type(value) ~= 'string' or value == '' then return nil end
	return value
end

-- The two halves of a name as one line, or nil while the character is still
-- nobody. A character is a row before it is anybody -- created nameless, named
-- once it is in the world -- so this key is legitimately absent for a while.
local function displayName(charInfo)
	local first, last = textOr(charInfo.firstName), textOr(charInfo.lastName)
	if first and last then return first .. ' ' .. last end
	return first or last
end

-- The public half of a job or gang row: who they are and what rank, never what it
-- pays and never what it authorises.
local function groupOf(group)
	if type(group) ~= 'table' then return nil end
	local grade = type(group.grade) == 'table' and group.grade or {}
	return {
		name = textOr(group.name),
		label = textOr(group.label),
		type = textOr(group.type),
		onDuty = group.onDuty == true,
		isBoss = group.isBoss == true,
		grade = { name = textOr(grade.name), level = tonumber(grade.level) or 0 },
	}
end

-- Everything this file publishes, built from PlayerData in one pass and keyed
-- exactly as it lands on the bag, so the writer below knows nothing about
-- characters.
local function fieldsOf(player)
	local data = player.PlayerData
	local charInfo = type(data.charInfo) == 'table' and data.charInfo or {}
	local metadata = type(data.metadata) == 'table' and data.metadata or {}
	local source = data.source

	return {
		citizenId = textOr(data.citizenId),
		name = displayName(charInfo),
		charInfo = {
			firstName = textOr(charInfo.firstName),
			lastName = textOr(charInfo.lastName),
			gender = textOr(charInfo.gender),
			origin = textOr(charInfo.origin),
		},
		job = groupOf(data.job),
		gang = groupOf(data.gang),

		-- The Master-verified account name, on the bag so a client drawing a body
		-- has both names from one read. It is already public -- it is what chat
		-- and the platform's own nameplates show -- and it is NOT the account id,
		-- which is durable, attributable, and stays on the server.
		username = textOr(source and OPX.DisplayNameOf(source)),

		-- The two flags anybody drawing a body actually asks about. The rest of
		-- `metadata` is free-form and owner-private by default.
		life = {
			dead = metadata.isDead == true,
			lastStand = metadata.inLastStand == true,
		},
	}
end

-- Writes one key when it moved, and answers whether it did.
local function write(bag, source, key, value)
	local slot = published[source]
	local encoded = value == nil and '' or json.encode(value)
	if slot[key] == encoded then return false end

	-- `bag:set` and not `bag.key = value`: the sugar raises on a refusal and a
	-- refused key is not a reason to abandon the other six.
	local called, ok, reason = pcall(bag.set, bag, key, value)
	if not called then ok, reason = false, ok end
	if not ok then
		warnOnce('set:' .. tostring(reason),
			('the state bag refused %s: %s'):format(key, tostring(reason)))
		return false
	end
	slot[key] = encoded
	return true
end

--- Publishes a loaded character's public fields onto its player bag.
-- Safe to call as often as anything changes: an unchanged key costs one encode
-- and no write. An offline Player has no session to replicate to and is ignored.
-- @author dop42
-- @param player Player
function State.Publish(player)
	if not State.Available() or type(player) ~= 'table' or player.Offline then return end
	local source = type(player.PlayerData) == 'table' and player.PlayerData.source or nil
	if type(source) ~= 'number' or source <= 0 then return end

	-- Protected, and the selector is the reason: a slot that went while this was
	-- being called answers `invalid_state_selector`, and a host that answers it by
	-- raising rather than returning would take the caller down with it -- and the
	-- caller is `UpdatePlayerData`, which is on the path of every mutator there is.
	local read, bag = pcall(Open77.state.player, source)
	if not read or type(bag) ~= 'table' then
		return warnOnce('bag',
			'Open77.state.player answered no bag: character state is not replicated')
	end

	published[source] = published[source] or {}
	local fields = fieldsOf(player)
	for _, key in ipairs(KEYS) do write(bag, source, key, fields[key]) end
end

--- Takes this module's keys off a player's bag.
--
-- A DISCONNECT NEEDS NONE OF THIS: the bag dies with the session and every holder
-- is told to drop it. This is for the other unload -- a character switch, or a
-- logout that leaves the session connected -- where the slot is still there and
-- the bag would otherwise go on naming a character nobody is playing.
-- @author dop42
-- @param source Source
function State.Clear(source)
	source = tonumber(source)
	if not State.Available() or source == nil or source <= 0 then return end
	published[source] = nil

	local read, bag = pcall(Open77.state.player, source)
	if not read or type(bag) ~= 'table' then return end
	for _, key in ipairs(KEYS) do
		-- `unknown_bag` is the ordinary answer for a session that has already gone,
		-- so THAT refusal is not worth a line -- but it was the only one being
		-- discarded. Any other refusal leaves the departed character's name and
		-- citizen id replicated on a bag every other client still reads, which is
		-- the one failure here anybody would notice from the game.
		local called, cleared, why = pcall(bag.clear, bag, key)
		if (not called or cleared == false) and tostring(called and why or cleared)
			:find('unknown_bag', 1, true) == nil then
			Open77.log.warn(('[character] bag key %s was not cleared for %s: %s')
				:format(tostring(key), tostring(source), tostring(called and why or cleared)))
		end
	end
end

--- Clears every bag this module wrote, so a stop leaves no character standing on
--- a client with nothing left to update it.
-- @author dop42
function State.Release()
	for source in pairs(published) do pcall(State.Clear, source) end
	published = {}
end
