--- The server half: validating a face, validating what is worn, storing both, and
--- handing every player's look to the other players.
-- @author dop42
--
-- Nothing a client sends is trusted here. The character written is always the one
-- on the connection, resolved before any thread; a citizen id inside a payload is
-- only ever used to REFUSE a save captured for the character before a switch.
--
-- The validators below are the whole value of this file. They are written against
-- what the engine actually renders, not against what a well-behaved client would
-- send, and every guard in them answers a specific way a client can lie.

local M = OPX.Modules.Get('appearance')

local Result = OPX.Result

-- The character contract, looked up in `Start`: contracts only exist from the api
-- phase on. Never the module by name.
local character

-- The host announces a bucket change under a name `OPX.Host` does not list; it is
-- in `M.HostEvent` with the other host names this module knows.
local HOST_BUCKET_CHANGE = M.HostEvent.BUCKET_CHANGE

-- ── the face ─────────────────────────────────────────────────────────────────

M.Appearance = {}
local Appearance = M.Appearance

--- The schema version written into every stored snapshot.
M.Appearance.VERSION = 1

-- The three parts the engine's catalogue is divided into.
local PARTS = { head = true, body = true, arms = true }

-- The ceiling on an option index and on its choice count.
local MAX_CHOICES = 512

-- The most options one snapshot may carry.
local MAX_OPTIONS = 256

--- Whether a value is a finite whole number.
-- Deliberately NOT `tonumber`: an option index arriving as the string "3" is a
-- client that no longer speaks this protocol, and accepting it would let a
-- rewritten client decide what the catalogue means.
local function isInteger(value)
	return type(value) == 'number' and OPX.Math.IsFinite(value) and value % 1 == 0
end

--- Whether a value is a 64-bit engine id as the platform renders it.
-- `0x` and sixteen hex digits, compared as text and NEVER through `tonumber`,
-- which a 64-bit hash does not survive: the two largest halves of the id space
-- both collapse onto the same double.
-- @param allowZero boolean true for the body-family hash, which may be null
local function isHash(value, allowZero)
	if type(value) ~= 'string' or #value ~= 18 then return false end
	if value:sub(1, 2) ~= '0x' or value:sub(3):match('^%x+$') == nil then return false end
	return allowZero or value ~= '0x0000000000000000'
end

--- Lower-cases a SHA-256 catalogue fingerprint, or answers nil.
local function digest(value)
	if type(value) ~= 'string' then return nil end
	local lowered = value:lower()
	if #lowered ~= 64 or lowered:match('^%x+$') == nil then return nil end
	return lowered
end

--- Answers a snapshot in canonical form, or nil and a code.
-- @author dop42
--
-- Canonical means dense options, lower-cased names, and each field the type its
-- column expects. Two guards are worth naming: `choices = 0` is a catalogue entry
-- with nothing to choose, which the engine really does report, and is the only
-- case where the index cannot be bounded by it; and `#value.options` stops at the
-- first hole, so the loop has only proved a PREFIX -- a final pass refuses any
-- numeric key outside `1..count`.
-- @param value any
-- @return table|nil
-- @return string|nil the code
function M.Appearance.Canonical(value)
	if type(value) ~= 'table' then return nil, 'invalid_snapshot' end
	if value.schemaVersion ~= Appearance.VERSION then return nil, 'unsupported_schema' end
	if not M.BuildAccepted(value.gameBuild) then return nil, 'unsupported_game_build' end

	local catalog = digest(value.catalogDigest)
	if catalog == nil then return nil, 'invalid_catalog_digest' end

	-- The engine's opaque body hash, not the female/male string: that one is
	-- `charInfo.gender` and lives on the character row.
	if not isHash(value.gender, true) then return nil, 'invalid_gender' end

	if type(value.options) ~= 'table' then return nil, 'invalid_options' end
	local count = #value.options
	if count < 1 or count > MAX_OPTIONS then return nil, 'invalid_option_count' end

	local canonical = {
		schemaVersion = Appearance.VERSION,
		gameBuild = value.gameBuild,
		catalogDigest = catalog,
		gender = value.gender,
		options = {},
	}

	local seen = {}
	for index = 1, count do
		local option = value.options[index]
		if type(option) ~= 'table' then return nil, 'invalid_option' end
		if not PARTS[option.part] then return nil, 'invalid_option_part' end
		if not isHash(option.name, false) then return nil, 'invalid_option_name' end
		if not isInteger(option.value) or option.value < 0 or option.value >= MAX_CHOICES then
			return nil, 'invalid_option_value'
		end
		if not isInteger(option.choices) or option.choices < 0 or option.choices > MAX_CHOICES then
			return nil, 'invalid_option_choices'
		end
		if option.choices > 0 and option.value >= option.choices then
			return nil, 'option_out_of_range'
		end
		local key = option.part .. ':' .. option.name:lower()
		if seen[key] then return nil, 'duplicate_option' end
		seen[key] = true
		canonical.options[index] = {
			part = option.part,
			name = option.name:lower(),
			value = option.value,
			choices = option.choices,
		}
	end

	for key in pairs(value.options) do
		if type(key) == 'number' and (not isInteger(key) or key < 1 or key > count) then
			return nil, 'sparse_options'
		end
	end

	return canonical
end

--- Whether two canonical snapshots are the same face.
-- @author dop42
-- @param left table|nil
-- @param right table|nil
-- @return boolean
function M.Appearance.Same(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end
	if left.gameBuild ~= right.gameBuild or left.catalogDigest ~= right.catalogDigest then
		return false
	end
	if left.gender ~= right.gender then return false end
	local count = #left.options
	if count ~= #right.options then return false end
	for index = 1, count do
		local a, b = left.options[index], right.options[index]
		if a.part ~= b.part or a.name ~= b.name or a.value ~= b.value then return false end
	end
	return true
end

--- Tells the client its PlayerData changed, when the character module offers it.
local function republish(player)
	local functions = player.Functions
	if type(functions) == 'table' and type(functions.UpdatePlayerData) == 'function' then
		functions.UpdatePlayerData()
	end
end

--- Validates, stores and publishes a character's captured face. Coroutine only.
-- @author dop42
--
-- THE ORDER IS THE CONTRACT. `Same` is compared BEFORE the encoding, so the size
-- check cannot answer differently for a face that is already stored. And
-- `PlayerData.appearance` is set BEFORE the write and put back only if nothing
-- else replaced it meanwhile: the character module's disconnect save rewrites
-- that column from memory, and started while this write waited it would otherwise
-- clobber the face that was just stored.
-- @param identifier Player|Source|CitizenId
-- @param snapshot any
-- @return Result
function M.SaveAppearance(identifier, snapshot)
	local player = character and character.ResolvePlayer(identifier) or nil
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end

	local canonical, reason = Appearance.Canonical(snapshot)
	if not canonical then return Result.Err('appearance.invalid', reason) end

	local data = player.PlayerData
	if Appearance.Same(data.appearance, canonical) then return Result.Ok(data.appearance) end

	local encoded = json.encode(canonical)
	if #encoded > M.MaxFaceBytes then
		return Result.Err('appearance.tooLarge', tostring(#encoded))
	end

	local previous = data.appearance
	data.appearance = canonical
	local written = M.Storage.SaveAppearance(data.citizenId, canonical)
	if not written.ok then
		if data.appearance == canonical then data.appearance = previous end
		return written
	end

	-- The write yielded, so this only goes out while this Player is still the one
	-- loaded on that source.
	if not player.Offline and character.GetPlayer(data.source) == player then
		republish(player)
		TriggerClientEvent(M.Event.FACE_SAVED, data.source, canonical)
	end
	TriggerEvent(M.Event.IN_FACE, data.source, data.citizenId, canonical)

	OPX.Audit.Player(player, 'appearance.saved', canonical.gameBuild,
		{ options = #canonical.options })
	return Result.Ok(canonical)
end

--- Writes the body a character was built on to its row, once. Coroutine only.
-- @author dop42
--
-- THE ONLY FIELD OF AN IDENTITY THAT ARRIVES WITH A FACE. It has to: the body
-- family is the engine's own character creator's answer, and the creator runs
-- after the row exists. The client is trusted to name one of the two families
-- and with nothing else -- the character module refuses a second write, so the
-- family that is stored is the one that came with the character's first face and
-- can never be moved afterwards.
--
-- A refusal is logged and goes no further. The face itself IS saved, and a
-- character whose row kept the body it already had is not a reason to refuse a
-- player their own face.
-- @param player Player
-- @param family any
-- @return boolean
function M.AdoptBodyFamily(player, family)
	if character == nil or type(character.SetBodyFamily) ~= 'function' then return false end
	local citizen = tostring(player.PlayerData.citizenId)

	if family ~= 'female' and family ~= 'male' then
		Open77.log.warn(('[appearance] %s named %s as a body family')
			:format(citizen, tostring(family)))
		return false
	end

	local written = character.SetBodyFamily(player, family)
	if written.ok then return true end
	Open77.log.warn(('[appearance] the %s body was not written for %s: %s (%s)')
		:format(family, citizen, tostring(written.error), tostring(written.detail)))
	return false
end

--- The stored face of a character, online or not. Coroutine only when offline.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Result
function M.GetAppearance(identifier)
	local player = character and character.ResolvePlayer(identifier) or nil
	if player then return Result.Ok(player.PlayerData.appearance) end
	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end
	return M.Storage.FetchAppearance(identifier)
end

-- ── what the character wears ─────────────────────────────────────────────────

M.Clothing = {}
local Clothing = M.Clothing

--- The schema version written into every stored record.
M.Clothing.VERSION = 1

-- The nine equipment slots, as the platform names them.
local SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit',
	'UnderwearTop', 'UnderwearBottom' }

local IS_SLOT = {}
for index = 1, #SLOTS do IS_SLOT[SLOTS[index]] = true end

-- The seven visible slots an outfit may override. Underwear is worn but never
-- replaced by an outfit, which is why it is absent here and present above.
local IS_OUTFIT_SLOT = { Head = true, Face = true, InnerChest = true, OuterChest = true,
	Legs = true, Feet = true, Outfit = true }

-- How many wardrobe outfits exist, indexed 0 to 6 as the platform indexes them.
local OUTFITS = 7

-- The longest record name, as the equipment service bounds one.
local MAX_RECORD_BYTES = 160

-- The largest encoded clothing document stored. Not a setting, and deliberately
-- separate from the face ceiling: it only catches a shape the checks above it
-- should already have caught, since nine slots and forty-nine overrides of 160
-- bytes stay under 10 KiB.
local MAX_CLOTHING_JSON_BYTES = 16384

-- Milliseconds between two saves of either kind from one player.
local COOLDOWN_MS = 2000

--- Answers a worn record name, false for an empty slot, nil otherwise.
-- There is no catalogue on a server, so this is a shape and not a lookup -- the
-- same shape the look distribution below accepts.
--
-- ANCHORED TO `Items.`, WHICH IS AS FAR AS A SHAPE CAN GO. The pattern used to be
-- `[%w_%.%-]+` and nothing else, so `Character.Judy` and `Vehicle.Cthulhu` were
-- accepted as things to wear; every clothing record the equipment service knows
-- is in the `Items` namespace, so one anchor turns a whole family of nonsense
-- into a refusal. It is NOT membership validation and must not grow into one:
-- `Open77.equipment.records` and `.info` are client-only, there is no catalogue
-- on this side to check against, and asking the client for one would be trusting
-- the thing the check exists to distrust.
local function recordOf(value)
	if value == false then return false end
	if type(value) ~= 'string' or #value < 1 or #value > MAX_RECORD_BYTES then return nil end
	if value:match('^Items%.[%w_%.%-]+$') == nil then return nil end
	return value
end

--- Reads an outfit index from a number or from a single-digit string key.
-- JSON turns a table's integer keys into strings, so both shapes arrive.
local function outfitIndex(key)
	local number
	if type(key) == 'number' then
		number = key
	elseif type(key) == 'string' and key:match('^%d$') then
		number = tonumber(key)
	end
	if not isInteger(number) or number < 0 or number >= OUTFITS then return nil end
	return math.floor(number)
end

--- Answers a clothing record in canonical form, or nil and a code.
-- @author dop42
--
-- `"0"` and `0` are the same outfit: receiving both is a client that means two
-- different things at once, and it is refused rather than resolved.
-- @param value any
-- @return table|nil
-- @return string|nil the code
function M.Clothing.Canonical(value)
	if type(value) ~= 'table' then return nil, 'invalid_record' end
	for key in pairs(value) do
		if key ~= 'schemaVersion' and key ~= 'equipment' and key ~= 'wardrobe' then
			return nil, 'unknown_field'
		end
	end
	if value.schemaVersion ~= Clothing.VERSION then return nil, 'unsupported_schema' end

	local equipment = value.equipment
	if type(equipment) ~= 'table' then return nil, 'invalid_equipment' end
	local canonical = {
		schemaVersion = Clothing.VERSION, equipment = {}, wardrobe = { outfits = {} },
	}
	for slot, item in pairs(equipment) do
		if not IS_SLOT[slot] then return nil, 'invalid_slot' end
		if recordOf(item) == nil then return nil, 'invalid_item' end
	end
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		canonical.equipment[slot] = recordOf(equipment[slot]) or false
	end

	local wardrobe = value.wardrobe
	if type(wardrobe) ~= 'table' then return nil, 'invalid_wardrobe' end
	for key in pairs(wardrobe) do
		if key ~= 'active' and key ~= 'outfits' then return nil, 'unknown_wardrobe_field' end
	end
	if wardrobe.active ~= nil then
		local active = outfitIndex(wardrobe.active)
		if active == nil or type(wardrobe.active) ~= 'number' then return nil, 'invalid_active' end
		canonical.wardrobe.active = active
	end

	local outfits = wardrobe.outfits
	if outfits ~= nil and type(outfits) ~= 'table' then return nil, 'invalid_outfits' end
	local seen, count = {}, 0
	for key, overrides in pairs(outfits or {}) do
		count = count + 1
		local index = outfitIndex(key)
		if count > OUTFITS or index == nil or seen[index] then return nil, 'invalid_outfit' end
		seen[index] = true
		if type(overrides) ~= 'table' then return nil, 'invalid_outfit' end
		local clean, any = {}, false
		for slot, item in pairs(overrides) do
			if not IS_OUTFIT_SLOT[slot] then return nil, 'invalid_outfit_slot' end
			local record = recordOf(item)
			if record == nil then return nil, 'invalid_item' end
			clean[slot], any = record, true
		end
		if any then canonical.wardrobe.outfits[tostring(index)] = clean end
	end

	return canonical
end

--- Whether two canonical records are the same clothing.
-- @author dop42
-- @param left table|nil
-- @param right table|nil
-- @return boolean
function M.Clothing.Same(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		if left.equipment[slot] ~= right.equipment[slot] then return false end
	end
	if left.wardrobe.active ~= right.wardrobe.active then return false end
	for index = 0, OUTFITS - 1 do
		local a, b = left.wardrobe.outfits[tostring(index)], right.wardrobe.outfits[tostring(index)]
		if (a == nil) ~= (b == nil) then return false end
		if a ~= nil then
			for slot in pairs(IS_OUTFIT_SLOT) do
				if a[slot] ~= b[slot] then return false end
			end
		end
	end
	return true
end

--- Reads and validates a character's stored clothing record. Coroutine only.
local function fetchClothing(citizenId)
	local fetched = M.Storage.FetchClothing(citizenId)
	if not fetched.ok then return fetched end
	if fetched.value == nil then return Result.Ok(false) end
	local canonical, reason = Clothing.Canonical(fetched.value)
	if not canonical then return Result.Err('clothing.unreadable', reason) end
	return Result.Ok(canonical)
end

--- What `PlayerData.clothing` starts as at login. Coroutine only.
-- @author dop42
--
-- NEVER refuses a login. A failure answers nil, which the client reads as 'dress
-- nothing, save nothing', and which `SaveClothing` refuses to write over: a
-- record nobody was able to show the player must not be replaced by one the
-- player never chose.
-- @param citizenId CitizenId
-- @return table|false|nil
function M.Clothing.Load(citizenId)
	local fetched = fetchClothing(citizenId)
	if fetched.ok then return fetched.value end
	Open77.log.warn(('[appearance] %s: the stored clothing could not be read (%s: %s); it is ' ..
		'neither restored nor overwritten this session'):format(OPX.Audit.Safe(citizenId),
			tostring(fetched.error), tostring(fetched.detail)))
	return nil
end

--- Validates, stores and publishes what a character wears. Coroutine only.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param clothing any
-- @return Result
function M.SaveClothing(identifier, clothing)
	local player = character and character.ResolvePlayer(identifier) or nil
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end

	local canonical, reason = Clothing.Canonical(clothing)
	if not canonical then return Result.Err('clothing.invalid', reason) end

	local data = player.PlayerData
	-- nil is 'the stored record could not be read', never 'nothing stored'.
	if data.clothing == nil then
		return Result.Err('error.unavailable', 'clothing_unavailable')
	end
	if Clothing.Same(data.clothing, canonical) then return Result.Ok(data.clothing) end

	local encoded = json.encode(canonical)
	if #encoded > MAX_CLOTHING_JSON_BYTES then
		return Result.Err('clothing.tooLarge', tostring(#encoded))
	end

	local written = M.Storage.SaveClothing(data.citizenId, encoded)
	if not written.ok then return written end
	data.clothing = canonical

	-- The write yielded: a player who switched character meanwhile is not sent
	-- this one's clothes.
	if not player.Offline and character.GetPlayer(data.source) == player then
		republish(player)
		TriggerClientEvent(M.Event.CLOTHING_SAVED, data.source, canonical)
	end
	TriggerEvent(M.Event.IN_CLOTHING, data.source, data.citizenId, canonical)

	OPX.Audit.Player(player, 'clothing.saved', nil, { bytes = #encoded })
	return Result.Ok(canonical)
end

--- The stored clothing of a character, online or not. Coroutine only when offline.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Result
function M.GetClothing(identifier)
	local player = character and character.ResolvePlayer(identifier) or nil
	if player then return Result.Ok(player.PlayerData.clothing) end
	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end
	return fetchClothing(identifier)
end

-- ── the looks other players are drawn from ───────────────────────────────────
-- Another client draws this player only from what it is handed: the engine
-- replicates the position, the vehicle and the actions, never the look. A proxy
-- nobody dresses is never drawn at all, so the player simply is not there.
--
-- What is checked below is the SHAPE and not the truth: a client can only ever
-- describe its own player, which is the trust the platform's own package extends.

-- Least milliseconds between two publications or replays from one player.
local FLOOR_MS = 500

-- Most bytes one encoded body, and one encoded equipment plus wardrobe, may weigh.
local MAX_BODY_BYTES = 49152
local MAX_CLOTHING_BYTES = 4096

-- The last look accepted for each player, players whose body is away during a
-- reload, when each player last got through the floor, and whose unreadable body
-- was already logged.
local looks, absent, lastAt, warned = {}, {}, {}, {}

--- Whether this half hands looks out at all.
local function presenting()
	return M.Settings.PRESENT_BODIES ~= false
end

--- Whether a player's request of this kind falls inside the floor.
local function cooled(kind, player)
	local key, atMs = kind .. ':' .. player, OPX.Now()
	if lastAt[key] and atMs - lastAt[key] < FLOOR_MS then return true end
	lastAt[key] = atMs
	return false
end

--- Whether a value is a non-zero sixteen-digit engine hash.
local function fixedHash(value)
	return isHash(value, false)
end

--- Whether a body has the shape and the bounds the platform accepts.
-- Refused whole when it is wrong, and answered, so the client stops sending it
-- rather than retrying a body this server will never read.
local function validBody(body)
	if type(body) ~= 'table' or type(body.groups) ~= 'table' then return false end
	if not M.IsFamily(body.family) then return false end
	local count = #body.groups
	if count == 0 or count > 64 then return false end
	local seen = {}
	for index, group in pairs(body.groups) do
		if not isInteger(index) or index < 1 or index > count or type(group) ~= 'table' then
			return false
		end
		if not PARTS[group.part] then return false end
		if not fixedHash(group.name) or type(group.keys) ~= 'table' then return false end
		local id = group.part .. ':' .. group.name:lower()
		if seen[id] then return false end
		seen[id] = true
		local keys = #group.keys
		if keys == 0 or keys > 64 then return false end
		for keyIndex, key in pairs(group.keys) do
			if not isInteger(keyIndex) or keyIndex < 1 or keyIndex > keys or type(key) ~= 'table' or
				#key ~= 2 or not fixedHash(key[1]) or not fixedHash(key[2]) then
				return false
			end
		end
	end
	local encoded, text = pcall(json.encode, body)
	return encoded and type(text) == 'string' and #text <= MAX_BODY_BYTES
end

--- Whether a value is a record name or false.
local function validItem(value)
	return recordOf(value) ~= nil
end

--- All nine slots, an unreadable one as empty.
-- An item that cannot be read costs its slot and never the whole body: being
-- drawn in the wrong jacket beats not being drawn at all.
local function equipmentOf(value)
	local clean = {}
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local item = type(value) == 'table' and value[slot] or false
		clean[slot] = validItem(item) and item or false
	end
	return clean
end

--- The readable active outfit and outfit overrides.
local function wardrobeOf(value)
	local wardrobe = { outfits = {} }
	if type(value) ~= 'table' then return wardrobe end
	if isInteger(value.active) and value.active >= 0 and value.active < OUTFITS then
		wardrobe.active = value.active
	end
	for index, slots in pairs(type(value.outfits) == 'table' and value.outfits or {}) do
		local number = tonumber(index)
		if isInteger(number) and number >= 0 and number < OUTFITS and type(slots) == 'table' then
			local clean = {}
			for slot, item in pairs(slots) do
				if IS_OUTFIT_SLOT[slot] and validItem(item) then clean[slot] = item end
			end
			wardrobe.outfits[tostring(math.floor(number))] = clean
		end
	end
	return wardrobe
end

--- The numeric player ids of a host list.
local function playerIds(list)
	local ids = {}
	for _, id in ipairs(list) do
		id = tonumber(id)
		if id then ids[#ids + 1] = id end
	end
	return ids
end

--- Every connected player id, empty when it cannot be read.
local function everybody()
	local read, list = pcall(Open77.players.all)
	return playerIds(read and type(list) == 'table' and list or {})
end

--- Sends one player's look, or its absence, to one other viewer.
-- Never to its owner: that player's own look is the engine's.
local function deliver(viewer, player)
	if viewer == player then return end
	local look = looks[player]
	if look == nil then return end
	if absent[player] then
		TriggerClientEvent(M.Event.LOOK, viewer, player, false)
	else
		TriggerClientEvent(M.Event.LOOK, viewer, player, look)
	end
end

--- Sends a player's look to everybody else.
local function broadcast(player)
	for _, other in ipairs(everybody()) do deliver(other, player) end
end

--- The players in a routing bucket, or everybody when it cannot be read.
local function playersIn(bucket)
	local read, list = pcall(Open77.players.inBucket, bucket)
	if not read or type(list) ~= 'table' then return everybody() end
	return playerIds(list)
end

--- A player's current routing bucket, nil when it cannot be read.
local function bucketOf(player)
	local read, bucket = pcall(Open77.routingBuckets.getPlayer, player)
	return read and tonumber(bucket) or nil
end

--- Forgets a departed player's look, absence, warning and floors.
local function forget(player)
	looks[player], absent[player], warned[player] = nil, nil, nil
	local prefix = ':' .. player
	for key in pairs(lastAt) do
		if key:sub(-#prefix) == prefix then lastAt[key] = nil end
	end
end

-- ── the wire doors ───────────────────────────────────────────────────────────

--- Registers every event handler.
-- Each save door checks its cooldown and resolves the connection's character
-- BEFORE its `CreateThread`: the payload names a character only so that a save
-- captured for the one before a switch can be refused.
local function registerEvents()
	RegisterNetEvent(M.Event.SAVE_FACE, function(payload)
		local src = tonumber(source)
		if not src then return end
		local operation = M.Operation.SAVE_FACE
		if type(payload) ~= 'table' then
			return M.RefuseSave(src, 'error.badRequest', operation)
		end
		if OPX.Cooling(src, 'appearance.request', COOLDOWN_MS) then
			return M.RefuseSave(src, 'error.tooFast', operation)
		end

		local player = character and character.GetPlayer(src) or nil
		if not player then return M.RefuseSave(src, 'error.notLoggedIn', operation) end
		-- Optional, and only ever a reason to refuse: a client that does not send
		-- it still saves.
		if payload.citizenId ~= nil and payload.citizenId ~= player.PlayerData.citizenId then
			return M.RefuseSave(src, 'appearance.stale', operation)
		end

		local snapshot = payload.snapshot or payload
		-- Sent by a creation and by nothing else: an edit cannot change a body
		-- family, so an edit has no reason to name one.
		local family = payload.family
		CreateThread(function()
			local saved = M.SaveAppearance(player, snapshot)
			if not saved.ok then
				Open77.log.warn(('[appearance] %d sent an unusable face: %s (%s)')
					:format(src, tostring(saved.error), tostring(saved.detail)))
				return M.RefuseSave(src, saved.error, operation)
			end
			-- After the face and never before it: a face the server would not take
			-- is a creation that did not happen, and its body belongs to nobody.
			if family ~= nil then M.AdoptBodyFamily(player, family) end
		end)
	end)

	RegisterNetEvent(M.Event.SAVE_CLOTHING, function(payload)
		local src = tonumber(source)
		if not src then return end
		local operation = M.Operation.SAVE_CLOTHING
		if type(payload) ~= 'table' then
			return M.RefuseSave(src, 'error.badRequest', operation)
		end
		if OPX.Cooling(src, 'clothing.request', COOLDOWN_MS) then
			return M.RefuseSave(src, 'error.tooFast', operation)
		end

		local player = character and character.GetPlayer(src) or nil
		if not player then return M.RefuseSave(src, 'error.notLoggedIn', operation) end
		if payload.citizenId ~= player.PlayerData.citizenId then
			return M.RefuseSave(src, 'clothing.stale', operation)
		end

		CreateThread(function()
			local saved = M.SaveClothing(player, payload.clothing)
			if not saved.ok then
				Open77.log.warn(('[appearance] %d: clothing not saved: %s (%s)')
					:format(src, tostring(saved.error), tostring(saved.detail)))
				M.RefuseSave(src, saved.error, operation)
			end
		end)
	end)

	RegisterNetEvent(M.Event.PRESENT, function(body, equipment, wardrobe, sequence)
		local player = tonumber(source)
		if not player or player <= 0 or not isInteger(sequence) or sequence < 1 then return end
		if not presenting() or cooled('present', player) then return end

		if not validBody(body) then
			if not warned[player] then
				warned[player] = true
				Open77.log.warn(('[appearance] player %d published a body this server cannot read; ' ..
					'other players cannot draw them'):format(player))
			end
			TriggerClientEvent(M.Event.PRESENT_ACK, player, sequence, false)
			return
		end

		local look = { body = body, equipment = equipmentOf(equipment), wardrobe = wardrobeOf(wardrobe) }
		local encoded, text = pcall(json.encode, { look.equipment, look.wardrobe })
		if not encoded or type(text) ~= 'string' or #text > MAX_CLOTHING_BYTES then
			look.equipment, look.wardrobe = equipmentOf(nil), wardrobeOf(nil)
		end

		warned[player] = nil
		looks[player] = look
		absent[player] = nil
		broadcast(player)
		TriggerClientEvent(M.Event.PRESENT_ACK, player, sequence, true)
	end)

	RegisterNetEvent(M.Event.REPLAY, function(sequence)
		local player = tonumber(source)
		if not player or player <= 0 or not isInteger(sequence) then return end
		if not presenting() or cooled('replay', player) then return end
		for other in pairs(looks) do deliver(player, other) end
		TriggerClientEvent(M.Event.REPLAYED, player, sequence)
	end)

	RegisterNetEvent(M.Event.ABSENT, function()
		local player = tonumber(source)
		if not player or player <= 0 or not presenting() or absent[player] then return end
		absent[player] = true
		if looks[player] ~= nil then broadcast(player) end
	end)

	-- The `DIAGNOSTIC` handler was here: forty lines per player per session, its
	-- own counter, its own truncation. `core/server/note.lua` is that door now,
	-- with one budget, one rate window and one counter for every module -- which
	-- is the point, since two separate bounds on the same journal each think they
	-- are the only one.

	-- The native roster retires the replicas of a player who changes bucket, and
	-- a character being placed moves them out of their selection bucket. So both
	-- sides are handed each other's looks again, and a move another one has
	-- already superseded is ignored.
	AddEventHandler(HOST_BUCKET_CHANGE, function(player, bucket, previous)
		player, bucket, previous = tonumber(player), tonumber(bucket), tonumber(previous)
		if not player or player <= 0 or not bucket or bucket == previous then return end
		if not presenting() then return end
		local read, name = pcall(Open77.players.name, player)
		if not read or name == nil then return end
		local current = bucketOf(player)
		if current ~= nil and current ~= bucket then return end
		for _, other in ipairs(playersIn(bucket)) do
			if other ~= player then
				deliver(player, other)
				deliver(other, player)
			end
		end
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player then forget(player) end
	end)
end

--- Tells a client which save was refused, and with what code.
-- @author dop42
--
-- A face refusal also goes through `OPX.Refuse`, whose catalogue guarantee means
-- the player reads it in their own language. A clothing refusal does not: those
-- codes are not catalogue keys and were never meant to be shown -- the client
-- publishes and logs them and drops the look. Both carry the operation, without
-- which a client waiting on a face save and a clothing save at once cannot tell
-- which refusal is whose.
-- @param source Source
-- @param code string
-- @param operation string
function M.RefuseSave(source, code, operation)
	source = tonumber(source)
	if not source or source <= 0 then return end
	if operation == M.Operation.SAVE_FACE then OPX.Refuse(source, code, operation) end
	TriggerClientEvent(M.Event.REFUSED, source, tostring(code), operation)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds state and contributes this module's table. Never yields.
function M.Init()
	looks, absent, lastAt, warned = {}, {}, {}, {}

	-- Resolved once: a ceiling read per save would let a changed setting measure a
	-- half-finished save against something else.
	local ceiling = tonumber(M.Settings.MAX_JSON_BYTES)
	if not OPX.Math.IsFinite(ceiling) or ceiling < 1024 then ceiling = 49152 end
	M.MaxFaceBytes = math.floor(ceiling)

	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the contract. Nothing may read one before this phase ends.
function M.Api()
	OPX.Api.Provide('appearance', 1, {
		GetAppearance = M.GetAppearance,
		SaveAppearance = M.SaveAppearance,
		GetClothing = M.GetClothing,
		SaveClothing = M.SaveClothing,
	})
end

--- Wires the doors and hooks the character load. Runs on a coroutine.
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.error('[appearance] no character contract: no face or clothing can be stored')
		return
	end

	-- A DELETED CHARACTER TAKES ITS CLOTHES WITH IT, and this is what does it: the
	-- table's foreign key never fires, because a character delete is a soft one.
	-- See `character.Event.IN_DELETED`, whose name is rebuilt here the way every
	-- module rebuilds another's -- a bare string would be a typo waiting to happen.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[appearance] the clothing of the deleted %s was not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	registerEvents()

	-- THE OTHER HALF OF THE OFFER POLICY. `WARDROBE.OFFER_POLICY` decides which
	-- world enters are HANDED a fitting room; this is how a player asks for one
	-- that was not handed to them, which under 'first' and 'never' is every
	-- session after the first. Open to everybody, because it opens nothing but
	-- the asking player's own appearance -- the client half re-checks the whole
	-- of it, and the ACL has nothing to say about a player looking at their own
	-- clothes. The cooldown is the whole of the abuse surface: the panel is one
	-- outgoing event and the client refuses a second one anyway.
	OPX.Command.Register('opx.appearance',
		{ help = 'command.help.appearance', cooldownMs = 2000, key = 'appearance.panel' },
		function(source)
			local player = tonumber(source) or 0
			if player <= 0 then
				return Open77.log.warn('[appearance] the appearance panel is opened by a player, ' ..
					'not the console')
			end
			TriggerClientEvent(M.Event.OPEN_PANEL, player)
		end)

	-- The seam the character module left exactly where its own clothing read used
	-- to be: it yields where that read yielded, which is what makes the session
	-- re-check below it meaningful. Whatever is put in `extras.data` is merged
	-- into PlayerData after the Player is built.
	--
	-- Nothing here may refuse a login. `Load` answers nil for a row it could not
	-- read, and a nil field is not merged at all -- which is exactly right:
	-- PlayerData.clothing then stays nil, the client dresses nothing, and
	-- SaveClothing refuses to write over a record nobody ever saw.
	OPX.Hooks.Register('character:loading', function(extras)
		if OPX.BootError then return end
		extras.data.clothing = M.Clothing.Load(extras.citizenId)
	end)

	if not presenting() then
		Open77.log.info('[appearance] PRESENT_BODIES is false: something else must hand every ' ..
			'look out, or nobody sees anybody')
		return
	end

	-- A restart of this half means every client is holding a look nobody here
	-- knows about any more.
	TriggerClientEvent(M.Event.RESEND, -1)
end

--- Drops the looks held in memory. Nothing here is stored, so there is nothing
--- to write: the next publication rebuilds all of it.
function M.Stop()
	looks, absent, lastAt, warned = {}, {}, {}, {}
end
