--- The authoritative half of the clothing shops.
-- @author dop42
--
-- WHAT IS DECIDED HERE AND NOWHERE ELSE: whether a player is standing at the
-- shop they name, what a change costs, whether they can pay for it, whether
-- their job lets them take a uniform, and what they are allowed to do with a
-- saved look. The client is believed about exactly one thing -- WHICH SLOTS
-- CHANGED -- because it is the only half that can see them.
--
-- THE ORDER, AND ITS WINDOW. The room closes on the client, the clothing half
-- of `appearance` starts its own debounced save, and this module is told what
-- changed. It then takes the money, and a bill that CANNOT be taken is answered
-- by pushing the old look back. That is compensation and not a transaction:
-- money is on the character row and clothing is in its own table, written
-- through a debounce this module does not own, and nothing spans the two. The
-- window is the couple of seconds of that debounce. It is named rather than
-- hidden, and the compensation path is tested.

local M = OPX.Modules.Get('shops')


-- The `character` contract, resolved in Start. Money, jobs, and who a source is.
local character = nil

-- The `appearance` contract, for the fitting room and the stored look.
local appearance = nil

-- The shops, normalised once at Init: key -> { label, x, y, z, bucket, prices,
-- jobs, onDuty }.
local shops = {}

-- The ready-made looks, normalised once: key -> { label, cost, jobs, onDuty,
-- at, wear }.
local looks = {}

-- The settings that are read on every request, resolved once.
local tuning = {}

--- One boot line naming a config row that was dropped, and why.
-- Never fatal: a mistyped shop is one shop missing, not a server that will not
-- start, and an operator who cannot see WHICH one is an operator who cannot fix
-- it.
local function problem(text)
	Open77.log.warn('[shops] ' .. text)
end

--- A finite number within bounds, or nil.
local function bounded(value, low, high)
	local number = tonumber(value)
	if number == nil or number ~= number then return nil end
	if number < low or number > high then return nil end
	return number
end

--- Reads `JOBS = { name = minimumGrade }` into a clean table, or nil.
local function jobGate(raw, where)
	if raw == nil then return nil end
	if type(raw) ~= 'table' then
		problem(('%s: JOBS is not a table; the gate is ignored'):format(where))
		return nil
	end
	local gate, any = {}, false
	for name, grade in pairs(raw) do
		local level = bounded(grade, 0, 100)
		if type(name) ~= 'string' or name == '' or level == nil then
			problem(('%s: JOBS has an entry that is not name = grade; it is dropped')
				:format(where))
		else
			gate[name] = math.floor(level)
			any = true
		end
	end
	return any and gate or nil
end

--- Whether a player passes a job gate. No gate is no obstacle.
local function passes(source, gate, onDuty)
	if gate == nil then return true end
	if character == nil then return false end
	for name, grade in pairs(gate) do
		if character.HasJob(source, name, onDuty == true, grade) then return true end
	end
	return false
end

--- Reads the config once. Called from Init, which may not yield.
local function resolve()
	local settings = type(M.Settings) == 'table' and M.Settings or {}

	tuning.charge = settings.CHARGE ~= false
	tuning.currency = type(settings.CURRENCY) == 'string' and settings.CURRENCY or 'EDDIES'
	tuning.reach = bounded(settings.REACH, 0.5, 50.0) or 3.0

	local outfits = type(settings.OUTFITS) == 'table' and settings.OUTFITS or {}
	tuning.maxOutfits = math.floor(bounded(outfits.MAX_PER_CHARACTER, 1, 200) or 24)
	tuning.maxNameBytes = math.floor(bounded(outfits.MAX_NAME_BYTES, 4, 64) or 48)
	tuning.sharing = outfits.SHARING ~= false
	tuning.codeLength = math.floor(bounded(outfits.CODE_LENGTH, 4, 16) or 8)

	local defaults = M.Prices(settings.PRICES, nil)

	shops = {}
	local declared = type(settings.SHOPS) == 'table' and settings.SHOPS or {}
	for key, raw in pairs(declared) do
		local where = ('shop "%s"'):format(tostring(key))
		local x, y, z = bounded(raw.X, -1e6, 1e6), bounded(raw.Y, -1e6, 1e6),
			bounded(raw.Z, -1e6, 1e6)
		if type(key) ~= 'string' or key == '' then
			problem('a shop has no key; it is dropped')
		elseif type(raw) ~= 'table' then
			problem(('%s: the entry is not a table; it is dropped'):format(where))
		elseif x == nil or y == nil or z == nil then
			problem(('%s: X, Y or Z is not a finite number; it is dropped'):format(where))
		else
			shops[key] = {
				key = key,
				label = type(raw.LABEL) == 'string' and raw.LABEL or key,
				x = x, y = y, z = z,
				bucket = math.floor(bounded(raw.BUCKET, 0, 2147483647) or 0),
				prices = M.Prices(defaults, raw.PRICES),
				jobs = jobGate(raw.JOBS, where),
				onDuty = raw.ON_DUTY == true,
			}
		end
	end

	looks = {}
	local offered = type(settings.LOOKS) == 'table' and settings.LOOKS or {}
	for key, raw in pairs(offered) do
		local where = ('look "%s"'):format(tostring(key))
		if type(key) ~= 'string' or key == '' or type(raw) ~= 'table' then
			problem(('%s: the entry is not a keyed table; it is dropped'):format(where))
		elseif type(raw.WEAR) ~= 'table' then
			problem(('%s: WEAR is not a table, so it dresses nobody; it is dropped')
				:format(where))
		else
			-- The slots are filtered HERE rather than when the look is worn, so a
			-- typo is one boot line instead of a refusal every time somebody buys.
			local wear, any = {}, false
			for slot, record in pairs(raw.WEAR) do
				if not M.IsSlot(slot) then
					problem(('%s: "%s" is not a clothing slot; it is dropped')
						:format(where, tostring(slot)))
				elseif record == false or (type(record) == 'string'
					and record:match('^Items%.[%w_%.%-]+$') ~= nil) then
					wear[slot] = record
					any = true
				else
					problem(('%s: %s is not false and not an Items.* record; it is dropped')
						:format(where, tostring(slot)))
				end
			end

			if not any then
				problem(('%s: nothing in WEAR survived; it is dropped'):format(where))
			else
				looks[key] = {
					key = key,
					label = type(raw.LABEL) == 'string' and raw.LABEL or key,
					cost = math.floor(bounded(raw.COST, 0, 100000000) or 0),
					jobs = jobGate(raw.JOBS, where),
					onDuty = raw.ON_DUTY == true,
					at = type(raw.AT) == 'table' and raw.AT or nil,
					wear = wear,
				}
			end
		end
	end
end

--- Where a player is, and in which bucket, or nil.
local function positionOf(source)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, position = pcall(players.position, source)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(tonumber(position.bucket) or 0) }
end

--- The shop a player named, IF they are standing at it. Nil and a reason
--- otherwise.
--
-- THE DISTANCE IS MEASURED HERE, and this is the reason the whole request shape
-- is "name a shop" rather than "here is a price". A client asks; a client can
-- ask from anywhere and can ask about a shop on the other side of the city.
local function shopAt(source, key)
	local shop = type(key) == 'string' and shops[key] or nil
	if shop == nil then return nil, 'no_such_shop' end

	local position = positionOf(source)
	if position == nil then return nil, 'position_unknown' end
	if position.bucket ~= shop.bucket then return nil, 'too_far' end

	local dx, dy, dz = position.x - shop.x, position.y - shop.y, position.z - shop.z
	if math.sqrt(dx * dx + dy * dy + dz * dz) > tuning.reach then return nil, 'too_far' end

	if not passes(source, shop.jobs, shop.onDuty) then return nil, 'not_for_you' end
	return shop
end

--- Tells one player something went wrong, in their own words.
--- Tells one player something went wrong, in their own words.
--
-- `OPX.NotifyLocale` is the house path: it renders the catalogue key, and a key
-- that is NOT in the catalogue becomes `error.unavailable` with the real code
-- logged, rather than a raw token being shown to a player.
local function refuse(source, key, data)
	OPX.NotifyLocale(source, key, data, 'error')
end

-- ── the fitting room ────────────────────────────────────────────────────────

--- The looks this shop carries that THIS player may take.
--
-- Gated before the list is sent, not after it is clicked: a uniform nobody may
-- wear is not a row somebody has to be refused at.
local function looksFor(source, shop)
	local out = {}
	for key, look in pairs(looks) do
		local here = look.at == nil
		if not here then
			for index = 1, #look.at do
				if look.at[index] == shop.key then here = true break end
			end
		end
		if here and passes(source, look.jobs, look.onDuty) then
			out[#out + 1] = { id = key, label = look.label, cost = look.cost }
		end
	end
	table.sort(out, function(left, right) return left.id < right.id end)
	return out
end

--- "I am at this shop and I want the room."
local function onOpen(source, key)
	local shop, why = shopAt(source, key)
	if shop == nil then return refuse(source, 'shops.' .. why) end
	if appearance == nil or type(appearance.OpenWardrobe) ~= 'function' then
		return refuse(source, 'shops.unavailable')
	end

	TriggerClientEvent(M.Event.LOOKS, source, { shop = shop.key, looks = looksFor(source, shop) })

	local ok, reason = appearance.OpenWardrobe(source)
	if not ok then refuse(source, 'shops.unavailable', { reason = tostring(reason) }) end
end

--- "I closed the room having changed these slots."
--
-- THE SLOT LIST IS THE ONLY THING BELIEVED, and it is still validated: every
-- entry must be one of the nine, duplicates are collapsed, and the list is
-- bounded by the number of slots that exist. A client naming `Legs` forty times
-- pays for legs once.
local function onBill(source, payload)
	if type(payload) ~= 'table' then return end
	if not tuning.charge then return end

	local shop, why = shopAt(source, payload.shop)
	if shop == nil then return refuse(source, 'shops.' .. why) end

	local seen, slots = {}, {}
	local given = type(payload.slots) == 'table' and payload.slots or {}
	for index = 1, math.min(#given, #M.SLOTS) do
		local slot = given[index]
		if M.IsSlot(slot) and not seen[slot] then
			seen[slot] = true
			slots[#slots + 1] = slot
		end
	end
	if #slots == 0 then return end

	local total = M.Bill(shop.prices, slots)
	if total <= 0 then return end

	local paid, reason = character.RemoveMoney(source, tuning.currency, total,
		('clothing at %s'):format(shop.label))
	if paid then
		return OPX.NotifyLocale(source, 'shops.paid',
			{ total = total, shop = shop.label }, 'success')
	end

	-- COULD NOT PAY, SO THE CLOTHES GO BACK. The stored look is the one the
	-- character walked in wearing -- the room's own save is debounced and has
	-- most likely not landed -- so it is both the right thing to restore and the
	-- thing that is still true in the database.
	refuse(source, reason or 'shops.cannotPay', { total = total })
	if appearance ~= nil and type(appearance.GetClothing) == 'function' then
		local stored = appearance.GetClothing(source)
		if type(stored) == 'table' then
			TriggerClientEvent(M.Event.RESTORE, source, stored)
		end
	end
end

--- "Put this ready-made look on me."
local function onWear(source, payload)
	if type(payload) ~= 'table' then return end
	local shop, why = shopAt(source, payload.shop)
	if shop == nil then return refuse(source, 'shops.' .. why) end

	local look = type(payload.look) == 'string' and looks[payload.look] or nil
	if look == nil then return refuse(source, 'shops.noSuchLook') end
	if not passes(source, look.jobs, look.onDuty) then
		return refuse(source, 'shops.notForYou')
	end
	if look.at ~= nil then
		local here = false
		for index = 1, #look.at do
			if look.at[index] == shop.key then here = true break end
		end
		if not here then return refuse(source, 'shops.notHere') end
	end

	if tuning.charge and look.cost > 0 then
		local paid, reason = character.RemoveMoney(source, tuning.currency, look.cost,
			('%s at %s'):format(look.label, shop.label))
		if not paid then return refuse(source, reason or 'shops.cannotPay',
			{ total = look.cost }) end
	end

	TriggerClientEvent(M.Event.PUT_ON, source, { look = look.key, wear = look.wear })
end

-- ── saved looks ─────────────────────────────────────────────────────────────
-- A SAVED LOOK IS NOT A PURCHASE and costs nothing. It is the record the
-- character is already wearing, written down so they can come back to it -- you
-- have already paid for these clothes. What a shop sells is a CHANGE, and
-- loading a saved look at a shop is a change like any other: it goes through
-- the fitting room and is billed by the slots it moves.
--
-- WHICH IS WHY LOADING DOES NOT NEED A SHOP. A code somebody read out is a
-- costume you can put on anywhere; the money question is asked where the
-- clothes change, not where the list is kept.

--- The `equipment` half of a stored record, or nil.
-- Only the nine slots survive: a saved look is what is worn, and the seven
-- wardrobe outfits under it are a separate thing the player flips between.
local function equipmentOf(record)
	if type(record) ~= 'table' or type(record.equipment) ~= 'table' then return nil end
	local out, any = {}, false
	for index = 1, #M.SLOTS do
		local slot = M.SLOTS[index]
		local worn = record.equipment[slot]
		if worn == false or type(worn) == 'string' then
			out[slot] = worn
			any = true
		end
	end
	return any and out or nil
end

--- The citizen a source is playing, or nil.
local function citizenOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	local citizen = player and player.PlayerData and player.PlayerData.citizenId
	return type(citizen) == 'string' and citizen ~= '' and citizen or nil
end

--- Sends one player their whole saved list.
local function pushList(source, citizen)
	local listed = M.Storage.List(citizen)
	if not listed.ok then return refuse(source, 'shops.listFailed') end

	local rows = {}
	for index = 1, #listed.value do
		local row = listed.value[index]
		rows[index] = {
			id = tonumber(row.outfit_id),
			name = tostring(row.name),
			code = type(row.share_code) == 'string' and row.share_code or nil,
		}
	end
	TriggerClientEvent(M.Event.SAVED, source, { outfits = rows, max = tuning.maxOutfits })
end

--- "Write down what I am wearing, under this name."
local function onSave(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local name = type(payload) == 'table' and payload.name or nil
	name = type(name) == 'string' and OPX.Text.Bytes(name, tuning.maxNameBytes) or nil
	if name ~= nil then name = name:match('^%s*(.-)%s*$') end
	if name == nil or name == '' then return refuse(source, 'shops.nameNeeded') end

	local counted = M.Storage.Count(citizen)
	if not counted.ok then return refuse(source, 'shops.listFailed') end
	if tonumber(counted.value or 0) >= tuning.maxOutfits then
		return refuse(source, 'shops.tooMany', { max = tuning.maxOutfits })
	end

	-- THE STORED RECORD AND NOT THE CLIENT'S. What a player is wearing is already
	-- authoritative on the server; taking the client's word for it would let
	-- anybody save a look they never wore.
	local worn = equipmentOf(appearance.GetClothing(source))
	if worn == nil then return refuse(source, 'shops.nothingWorn') end

	local saved = M.Storage.Save(citizen, name, json.encode({ equipment = worn }))
	if not saved.ok then return refuse(source, 'shops.saveFailed') end

	OPX.NotifyLocale(source, 'shops.saved', { name = name }, 'success')
	pushList(source, citizen)
end

--- "Put one of my saved looks on."
local function onLoad(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = tonumber(type(payload) == 'table' and payload.id or nil)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end

	local found = M.Storage.Own(citizen, math.floor(outfitId))
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchOutfit')
	end

	local wear = equipmentOf(OPX.Storage.Decode(found.value.look, nil))
	if wear == nil then return refuse(source, 'shops.outfitUnreadable') end
	TriggerClientEvent(M.Event.PUT_ON, source, { look = tostring(found.value.name), wear = wear })
end

--- "Forget this saved look."
local function onDelete(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = tonumber(type(payload) == 'table' and payload.id or nil)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end

	local removed = M.Storage.Delete(citizen, math.floor(outfitId))
	if not removed.ok then return refuse(source, 'shops.saveFailed') end
	pushList(source, citizen)
end

--- "Give me a code for this look so I can read it out."
--
-- MINTED UNTIL IT LANDS. The code is short by design -- it is read aloud -- so
-- collisions are possible and the unique index is what actually decides. A
-- refused insert is a retry, not an error, and after a handful of tries it
-- really is something else and says so.
local function onShare(source, payload)
	if not tuning.sharing then return refuse(source, 'shops.sharingOff') end
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = tonumber(type(payload) == 'table' and payload.id or nil)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end
	outfitId = math.floor(outfitId)

	local found = M.Storage.Own(citizen, outfitId)
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchOutfit')
	end
	-- Already shared: the same code comes back, because a look that changed its
	-- code every time somebody asked would make every code already read out into
	-- a wrong one.
	if type(found.value.share_code) == 'string' and found.value.share_code ~= '' then
		return TriggerClientEvent(M.Event.CODE, source,
			{ id = outfitId, code = found.value.share_code })
	end

	for _ = 1, 5 do
		local code = M.MintCode(tuning.codeLength, math.random)
		local set = M.Storage.SetCode(citizen, outfitId, code)
		if set.ok and tonumber(set.value or 0) > 0 then
			return TriggerClientEvent(M.Event.CODE, source, { id = outfitId, code = code })
		end
		if set.ok then return refuse(source, 'shops.noSuchOutfit') end
	end
	refuse(source, 'shops.codeFailed')
end

--- "Somebody read me this code."
local function onRedeem(source, payload)
	if not tuning.sharing then return refuse(source, 'shops.sharingOff') end

	local typed = type(payload) == 'table' and payload.code or nil
	local code = M.CleanCode(typed, tuning.codeLength)
	if code == nil then return refuse(source, 'shops.badCode') end

	local found = M.Storage.ByCode(code)
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchCode')
	end

	local wear = equipmentOf(OPX.Storage.Decode(found.value.look, nil))
	if wear == nil then return refuse(source, 'shops.outfitUnreadable') end
	TriggerClientEvent(M.Event.PUT_ON, source, { look = tostring(found.value.name), wear = wear })
end

--- Reads the config and declares the table. Never yields.
-- @author dop42
function M.Init()
	resolve()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Nothing is published yet: a shop is a place, not a service other modules call.
-- @author dop42
function M.Api()
end

--- Wires the doors.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	appearance = OPX.Api.Get('appearance')
	if character == nil or appearance == nil then
		Open77.log.error('[shops] no character or appearance contract: no shop can serve anybody')
		return
	end

	-- `source` is read through `tonumber` at the door of every handler, the way
	-- every other module here reads it: the platform delivers it as a string on
	-- some lifecycle paths, and a string id silently matches nothing.
	RegisterNetEvent(M.Event.OPEN, function(key)
		local src = tonumber(source)
		if src then onOpen(src, key) end
	end)
	RegisterNetEvent(M.Event.BILL, function(payload)
		local src = tonumber(source)
		if src then onBill(src, payload) end
	end)
	RegisterNetEvent(M.Event.WEAR, function(payload)
		local src = tonumber(source)
		if src then onWear(src, payload) end
	end)

	-- EVERY ONE OF THESE READS THE DATABASE, and `OPX.Storage` yields, so each
	-- runs on its own thread. A net handler that yields holds the event pump.
	RegisterNetEvent(M.Event.SAVE, function(payload)
		local src = tonumber(source)
		if src then CreateThread(function() onSave(src, payload) end) end
	end)
	RegisterNetEvent(M.Event.LIST, function()
		local src = tonumber(source)
		if src then CreateThread(function()
			local citizen = citizenOf(src)
			if citizen ~= nil then pushList(src, citizen) end
		end) end
	end)
	RegisterNetEvent(M.Event.LOAD, function(payload)
		local src = tonumber(source)
		if src then CreateThread(function() onLoad(src, payload) end) end
	end)
	RegisterNetEvent(M.Event.DELETE, function(payload)
		local src = tonumber(source)
		if src then CreateThread(function() onDelete(src, payload) end) end
	end)
	RegisterNetEvent(M.Event.SHARE, function(payload)
		local src = tonumber(source)
		if src then CreateThread(function() onShare(src, payload) end) end
	end)
	RegisterNetEvent(M.Event.REDEEM, function(payload)
		local src = tonumber(source)
		if src then CreateThread(function() onRedeem(src, payload) end) end
	end)

	-- A DELETED CHARACTER TAKES ITS SAVED LOOKS WITH IT. The foreign key above
	-- cascades, but a character delete here is soft, so the cascade never fires
	-- and this is what actually clears them -- the same note, for the same
	-- reason, as the appearance module's own purge.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[shops] the saved looks of the deleted %s were not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	local count = 0
	for _ in pairs(shops) do count = count + 1 end
	Open77.log.info(('[shops] %d shop(s) and %d ready-made look(s); charging is %s')
		:format(count, (function() local n = 0 for _ in pairs(looks) do n = n + 1 end return n end)(),
			tuning.charge and 'on' or 'off'))
end

--- Nothing to flush: every write is made as it happens.
-- @author dop42
function M.Stop()
end
