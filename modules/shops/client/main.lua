--- The shop floor: a row on the eye, and the bill that follows a fitting.
-- @author dop42
--
-- THIS HALF ASKS AND REPORTS. It does not decide. It puts a row where a shop
-- stands, it asks the server to open the room, and when the room closes it
-- reports WHICH SLOTS CHANGED -- the one fact the server cannot see for itself,
-- because `Open77.equipment.records` and the fitting room's own draft live only
-- here. Every other question -- the distance, the price, the money, the job --
-- is answered on the server, from its own tables. See `server/main.lua`.
--
-- THE SLOT LIST IS NOT COMPUTED HERE EITHER. It rides on `wardrobeClosed`,
-- published by the fitting room, which is the only place that holds both what
-- the player walked in wearing and what they walked out with. A shop that
-- re-read the body afterwards would be racing the clothing module's own save.

local M = OPX.Modules.Get('shops')

-- The eye, resolved in Start. Absent on a runtime without it, which makes the
-- shops unreachable rather than broken.
local target = nil

-- The `appearance` contract, for borrowing the puppet. A CONTRACT and not the
-- module namespace: this half needs `BeginClothingPreview` and nothing else,
-- and reaching past the contract for the rest would tie a shop to how the
-- fitting room happens to be written today.
local wardrobe = nil

-- The name `appearance` publishes its decisions on, rebuilt rather than reached
-- for. Every module here rebuilds another's event names the same way -- see the
-- character-delete handler in `server/main.lua` -- because a bare string is a
-- typo waiting to happen and an import is a dependency that does not exist.
local ON_DECISION = OPX.Event(OPX.Channel.LOCAL, 'appearance', 'decision')

-- The shop the player is currently being served at, or nil. Set when the room
-- is asked for and cleared when the bill goes out: a room opened for any other
-- reason -- the join offer, a staff member -- must not be billed to a shop
-- somebody happened to be standing near.
local serving = nil

-- The ready-made looks the server said this player may take here.
local offered = {}

-- What the eye owns, so it can be taken down on stop.
local OWNER = 'shops'
local ROW = 'shops.fitting'

--- The shops, read from config on this side too.
--
-- THE SAME LIST, READ TWICE, and that is correct rather than duplicated state:
-- the config is a `shared_script`, so both halves read the same file, and the
-- client needs the positions to draw anything at all. What it must never do is
-- read the PRICES for anything other than showing them -- and it does not read
-- them at all, because the server states the bill.
local function shopList()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local declared = type(settings.SHOPS) == 'table' and settings.SHOPS or {}

	local out = {}
	for key, raw in pairs(declared) do
		local x, y, z = tonumber(raw.X), tonumber(raw.Y), tonumber(raw.Z)
		if type(key) == 'string' and x ~= nil and y ~= nil and z ~= nil then
			out[#out + 1] = { key = key, x = x, y = y, z = z,
				label = type(raw.LABEL) == 'string' and raw.LABEL or key }
		end
	end
	-- Sorted so the sphere index a row carries is stable between two boots; the
	-- eye answers with the index it matched and nothing else would tie it back.
	table.sort(out, function(left, right) return left.key < right.key end)
	return out
end

--- Metres a shop serves from, mirrored from the server's own reach.
local function reach()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local metres = tonumber(settings.REACH)
	if metres == nil or metres < 0.5 or metres > 50.0 then return 3.0 end
	return metres
end

-- ── the floor ───────────────────────────────────────────────────────────────

--- Puts one row on every shop position.
local function placeRows()
	if target == nil then return end

	local shops = shopList()
	if #shops == 0 then return end

	local spheres = {}
	for index = 1, #shops do
		local shop = shops[index]
		spheres[index] = { x = shop.x, y = shop.y, z = shop.z, radius = reach() }
	end

	local placed = target.RegisterSpheres(OWNER, spheres, {
		id = ROW,
		label = locale('shops.row'),
		icon = 'person',
		distance = reach(),
		order = 20,
		onSelect = function(payload)
			-- The eye answers with the sphere it matched; the order above is what
			-- makes that index mean the same shop it meant when it was registered.
			local at = tonumber(type(payload) == 'table' and payload.index or nil)
			local shop = at and shops[at] or nil
			if shop == nil then return end
			serving = shop.key
			TriggerServerEvent(M.Event.OPEN, shop.key)
		end,
	})

	if not placed.ok then
		Open77.log.warn(('[shops] the shop rows were refused: %s'):format(tostring(placed.error)))
	end
end

-- ── what comes back ─────────────────────────────────────────────────────────

--- Puts a partial look on, slot by slot, through the fitting room's own door.
--
-- THROUGH THE CONTRACT, NOT THROUGH THE MODULE. `appearance` publishes
-- `BeginClothingPreview` / `EndClothingPreview` for exactly this, and reaching
-- into its `Clothing` table instead would be this module learning another's
-- internals -- the thing `config/entry.lua` writes the rule about. The borrow
-- also gives the two guarantees a shop needs and could not build: while it is
-- held nothing is saved and no look is published, and ending it with `keep`
-- hands the save to the half that owns it.
local function putOn(wear)
	if type(wear) ~= 'table' then return end
	if wardrobe == nil then return OPX.Toast.Locale('shops.cannotDress', nil, 'error') end

	local borrowed = wardrobe.BeginClothingPreview(OWNER)
	if not borrowed.ok then
		return OPX.Toast.Locale('shops.cannotDress', { reason = tostring(borrowed.error) },
			'error')
	end

	local worn = type(borrowed.value) == 'table' and borrowed.value.clothing or nil
	local equipment = type(worn) == 'table' and type(worn.equipment) == 'table'
		and worn.equipment or nil
	if equipment == nil then
		wardrobe.EndClothingPreview(OWNER, false)
		return OPX.Toast.Locale('shops.cannotDress', nil, 'error')
	end

	-- A PARTIAL RECORD OVER WHAT IS ALREADY ON, which is what makes a uniform a
	-- jacket and trousers rather than a whole silhouette. The slots the look does
	-- not name keep whatever the player had.
	local slots, records = {}, {}
	for index = 1, #M.SLOTS do
		local slot = M.SLOTS[index]
		local wanted = wear[slot]
		if wanted == nil then wanted = equipment[slot] end
		if wanted == nil then wanted = false end
		slots[slot] = wanted
		if type(wanted) == 'string' then records[#records + 1] = wanted end
	end

	-- `allowRestricted`, like the fitting room: a record the character is being
	-- handed is not this module's to second-guess. Sequential and able to apply
	-- part of a set before failing, which is why the borrow is ended either way
	-- -- a half-applied look still has to be given back.
	local called, ok, reason = pcall(Open77.equipment.apply, slots,
		{ allowRestricted = true })
	if not called or not ok then
		wardrobe.EndClothingPreview(OWNER, false)
		return OPX.Toast.Locale('shops.cannotDress',
			{ reason = tostring(called and reason or ok) }, 'error')
	end

	wardrobe.EndClothingPreview(OWNER, true, records)
end

--- Wires the doors.
-- @author dop42
function M.Start()
	wardrobe = OPX.Api.Get('appearance')
	target = OPX.Api.Get('target')
	if target == nil then
		Open77.log.warn('[shops] no target contract: the shops are on the map but unreachable')
	else
		placeRows()
	end

	-- THE BILL IS RAISED BY THE ROOM CLOSING, and only when this module asked for
	-- it. `serving` is what separates "a fitting at a shop" from every other
	-- reason a fitting room opens -- the join offer, a staff member -- and it is
	-- cleared here whatever the outcome, so a later close cannot be billed twice.
	AddEventHandler(ON_DECISION, function(decision)
		if type(decision) ~= 'table' then return end
		if decision.event ~= 'wardrobeClosed' then return end

		local shop = serving
		serving, offered = nil, {}
		if shop == nil or decision.kept ~= true then return end

		local slots = type(decision.slots) == 'table' and decision.slots or {}
		if #slots == 0 then return end
		TriggerServerEvent(M.Event.BILL, { shop = shop, slots = slots })
	end)

	RegisterNetEvent(M.Event.LOOKS, function(payload)
		offered = type(payload) == 'table' and type(payload.looks) == 'table'
			and payload.looks or {}
	end)

	RegisterNetEvent(M.Event.PUT_ON, function(payload)
		if type(payload) ~= 'table' then return end
		putOn(payload.wear)
	end)

	-- THE BILL COULD NOT BE TAKEN, so the clothes go back. The record comes from
	-- the server because by this point the client's own idea of what it walked in
	-- wearing is exactly what is in doubt.
	RegisterNetEvent(M.Event.RESTORE, function(record)
		if type(record) ~= 'table' or type(record.equipment) ~= 'table' then return end
		putOn(record.equipment)
	end)

	RegisterNetEvent(M.Event.SAVED, function(payload)
		TriggerEvent(M.Event.ON_STATE, { saved = type(payload) == 'table'
			and payload.outfits or {} })
	end)

	RegisterNetEvent(M.Event.CODE, function(payload)
		if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
		TriggerEvent(M.Event.ON_STATE, { code = payload.code, id = payload.id })
	end)
end

--- Takes the rows down.
-- @author dop42
function M.Stop()
	if target ~= nil then pcall(target.Clear, OWNER) end
	serving, offered = nil, {}
end
