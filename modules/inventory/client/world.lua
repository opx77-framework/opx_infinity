--- The client's view of the containers in the world: piles and their rows.
-- @author dop42
--
-- A row only ever ASKS. The server finds the pile again from its own position and
-- decides; nothing drawn here is believed by anything.
--
-- The pile list is kept whatever happens to the rows: additions and removals keep
-- arriving from the server, and a hello made close to the previous one is
-- swallowed by its own two-second limit, so a list thrown away is a list that
-- would not come back for a while.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options

M.World = {}
local World = M.World

-- Every known pile by id: id, x, y, z and bucket.
local drops = {}

-- Piles arriving in parts, gathered until the part marked `done`.
local incoming = nil

-- The name this module registers its target rows under. It is the module id, and
-- the target registry reads a module id as an owner that is always live.
local OWNER = 'inventory'

-- The id of the target row every nearby pile shares, the token it is registered
-- under, and the ids it was registered for -- so it is only redone on a change.
local PILE_ROW = 'inventory.pile'
local pileToken = nil
local pileKey = nil

-- Metres around a pile's point the row answers to: its prop and the ground under
-- it, and no more.
local PILE_RADIUS = 0.8

-- Piles one row carries at once, which is the target eye's own list limit.
local PILE_ROW_MAX = 32

--- The local character's position, or nil.
-- `Open77.character.position()` answers THREE NUMBERS and not a table. Read as a
-- table it answers nil for every field, no pile is ever near, and neither the key
-- nor a row finds one.
local function position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read then return nil end
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		return nil
	end
	return { x = x, y = y, z = z }
end

local function gap(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Whether the local character is sitting in a vehicle.
-- @author dop42
-- @return boolean
function World.Seated()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.isInVehicle) ~= 'function' then return false end
	local read, inside = pcall(character.isInVehicle)
	return read and inside == true
end

--- The nearest known pile within reach, or nil.
-- A HINT for the open key only: the server finds the pile again from its own
-- position. It looks within reach and not within the join distance, because the
-- join distance only says which pile a drop lands in.
-- @author dop42
-- @return table|nil
function World.NearestDrop()
	local here = position()
	if here == nil then return nil end
	local best, bestGap = nil, Options.REACH
	for _, drop in pairs(drops) do
		local away = gap(here, drop)
		if away <= bestGap then best, bestGap = drop, away end
	end
	return best
end

--- The nearest known piles within the prompt radius, nearest first.
local function nearbyDrops(here, limit)
	local near = {}
	if here == nil then return near end
	for _, drop in pairs(drops) do
		local away = gap(here, drop)
		if away <= Options.DROP_PROMPT_RADIUS then near[#near + 1] = { drop = drop, gap = away } end
	end
	table.sort(near, function(left, right) return left.gap < right.gap end)
	local out = {}
	for index = 1, math.min(#near, limit) do out[index] = near[index].drop end
	return out
end

--- Points the target rows at the nearest piles, or takes the row away.
-- Only redone when the set of ids changes: registering a row is a call into
-- another module, and a one-second loop that did it every pass would make one
-- per second for ever.
local function syncPileRow(target, near)
	local ids = {}
	for index, drop in ipairs(near) do ids[index] = drop.id end
	table.sort(ids)
	local key = table.concat(ids, ',')
	if key == pileKey then return end
	pileKey = key

	local previous = pileToken
	pileToken = nil
	if previous then target.Unregister(OWNER, previous) end
	if #near == 0 then return end

	local spheres = {}
	for index, drop in ipairs(near) do
		spheres[index] = { x = drop.x, y = drop.y, z = drop.z, radius = PILE_RADIUS }
	end

	-- One definition and not a list, so the answer carries a single token. The
	-- callbacks are plain functions: the registry keeps a function by reference,
	-- which is what an in-process row is.
	local registered = target.RegisterSpheres(OWNER, spheres, {
		id = PILE_ROW,
		label = locale('inventory.context.pile'),
		icon = 'box',
		distance = Options.REACH,
		canInteract = World.CanTakePile,
		onSelect = World.TakePile,
		-- The thing itself: a pile on the floor is what the player walked up to.
		order = 5,
	})
	if registered.ok then
		pileToken = registered.value.token
	else
		Open77.log.warn('[inventory] the pile row was not registered: ' ..
			tostring(registered.error))
	end
end

--- Whether the pile row applies: on foot, and not down.
-- @author dop42
-- @return boolean
function World.CanTakePile()
	return not M.Screen.IsDown() and not World.Seated()
end

--- Takes the pile closest to where the row landed, leaving the screen closed.
-- @author dop42
-- @param context table carries the position the eye landed on
-- @return boolean
function World.TakePile(context)
	if M.Screen.IsDown() then return false end
	local at = type(context) == 'table' and context.position or nil
	if type(at) ~= 'table' then return false end
	if not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y) and OPX.Math.IsFinite(at.z)) then
		return false
	end

	local best, bestGap = nil, PILE_RADIUS
	for _, drop in pairs(drops) do
		local away = gap(at, drop)
		if away <= bestGap then best, bestGap = drop, away end
	end
	if best == nil then return false end
	M.Screen.Request('takeDrop', { id = best.id })
	return true
end

--- Whether the trunk row applies: outside a vehicle, and not down.
-- @author dop42
-- @return boolean
function World.CanOpenTrunk()
	return not M.Screen.IsDown() and not World.Seated()
end

--- Opens the screen with the targeted vehicle's trunk.
-- The id travels as a DECIMAL STRING: a vehicle id carries a generation and can
-- pass 2^53, where a JSON number stops being exact.
-- @author dop42
-- @param context table
-- @return boolean
function World.OpenTrunk(context)
	if M.Screen.IsDown() then return false end
	local target = type(context) == 'table' and context.target or nil
	local vehicleId = type(target) == 'table' and math.tointeger(target.vehicleId) or nil
	if vehicleId == nil or vehicleId < 1 then return false end
	M.Screen.Open('openTrunk', { vehicleId = ('%d'):format(vehicleId) }, true)
	return true
end

--- Whether the glovebox row applies: from a seat, and not down.
-- @author dop42
-- @return boolean
function World.CanOpenGlovebox()
	return not M.Screen.IsDown() and World.Seated()
end

--- Opens the screen with the seat's vehicle glovebox.
-- @author dop42
-- @return boolean
function World.OpenGlovebox()
	if M.Screen.IsDown() then return false end
	M.Screen.Open('openGlovebox', nil, true)
	return true
end

--- Registers the trunk and glovebox rows with the target contract.
local function registerVehicleRows(target)
	local registered = target.RegisterVehicles(OWNER, {
		{
			id = 'inventory.trunk',
			label = locale('inventory.context.trunk'),
			icon = 'vehicle',
			distance = Options.REACH_VEHICLE,
			canInteract = World.CanOpenTrunk,
			onSelect = World.OpenTrunk,
			-- What it holds.
			order = 22,
		},
		{
			id = 'inventory.glovebox',
			label = locale('inventory.context.glovebox'),
			icon = 'vehicle',
			distance = Options.REACH_VEHICLE,
			canInteract = World.CanOpenGlovebox,
			onSelect = World.OpenGlovebox,
			order = 23,
		},
	})
	if not registered.ok then
		Open77.log.warn('[inventory] the vehicle rows were not registered: ' ..
			tostring(registered.error))
	end
end

--- Registers one row per configured stash, at the position it stands at.
-- A stash row stays registered when the character is unloaded: it only appears
-- within reach of a fixed point, and using it then is refused by the server
-- rather than drawn wrongly here.
local function registerStashRows(target)
	for _, stash in ipairs(Options.STASH_LIST) do
		local name = stash.name
		local registered = target.RegisterSpheres(OWNER,
			{ { x = stash.position.x, y = stash.position.y, z = stash.position.z,
				radius = PILE_RADIUS } },
			{
				id = 'inventory.stash.' .. name,
				label = M.Catalog.Rendered(stash.label) or locale('inventory.prompt.stash'),
				icon = 'box',
				distance = Options.REACH,
				canInteract = function() return not M.Screen.IsDown() end,
				-- `onlyWith`: the screen stays closed when the stash is refused, so
				-- a player out of reach is not shown their own bag instead.
				onSelect = function() M.Screen.Open('openStash', { name = name }, true) end,
				order = 20,
			})
		if not registered.ok then
			Open77.log.warn(('[inventory] the row of stash %s was not registered: %s')
				:format(name, tostring(registered.error)))
		end
	end
end

--- One pass of the pile rows: follow the player, and follow the character.
-- With no bag pushed -- before a character loads, or after a reset -- no row is
-- drawn and any that is left is taken away.
local function pass()
	local target = M.Contracts.target
	if target == nil or not Options.DROPS then return end
	local here = M.Screen.Own() ~= nil and position() or nil
	syncPileRow(target, nearbyDrops(here, PILE_ROW_MAX))
end

--- Registers the handlers the server pushes piles on.
-- @author dop42
function World.Wire()
	RegisterNetEvent(M.Event.DROPS, function(part)
		if type(part) ~= 'table' then return end
		-- Gathered until the part marked `done`, and started over on `first`: a
		-- half-arrived list must not replace a whole one.
		if part.first == true or incoming == nil then incoming = {} end
		local list = type(part.drops) == 'table' and part.drops or {}
		for index = 1, #list do
			local drop = list[index]
			if type(drop) == 'table' and Common.Integer(drop.id, -2147483647, -1) then
				incoming[drop.id] = drop
			end
		end
		if part.done ~= true then return end
		drops, incoming = incoming, nil
		pileKey = nil
	end)

	RegisterNetEvent(M.Event.DROP, function(action, value)
		if action == 'add' and type(value) == 'table' and
			Common.Integer(value.id, -2147483647, -1) then
			drops[value.id] = value
			if incoming then incoming[value.id] = value end
		elseif action == 'remove' then
			drops[value] = nil
			if incoming and value ~= nil then incoming[value] = nil end
		else
			return
		end
		pileKey = nil
	end)

	AddEventHandler(M.Event.ON_CHARACTER_UNLOADED, function()
		local target = M.Contracts.target
		local token = pileToken
		pileToken, pileKey = nil, nil
		if target and token then target.Unregister(OWNER, token) end
	end)

	local target = M.Contracts.target
	if target == nil then
		Open77.log.info('[inventory] no target contract: piles and vehicle storage have no ' ..
			'world rows, and the open key is the only way to reach them')
		return
	end
	registerVehicleRows(target)
	registerStashRows(target)
	OPX.Scheduler.Every('inventory.piles', 1000, pass)
end
