--- Using, handing over, dropping, opening and who is nearby -- all checked again.
-- @author dop42
--
-- Nothing the screen believes is taken on trust here. Every entry point re-reads
-- the slot, the count, the readiness gate, whether the player is alive, their
-- position and their routing bucket, whatever the client already knew.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players
local World = M.World
local KIND = M.KIND

M.Actions = {}
local Actions = M.Actions

-- The handler another module wants called when an item is used, by item name.
local usables = {}

-- When each player's last accepted use was, for the cooldown.
local lastUse = {}

--- Registers the function to call when an item is used.
-- The last registration wins, and replacing one somebody else holds is a warning:
-- two modules fighting over one item is a bug in one of them, and only the
-- winner's handler would ever run.
-- @author dop42
-- @param name string an item name in the catalogue
-- @param handler fun(source: Source, info: table): table
-- @param owner string|nil who is registering, for the log line only
-- @return boolean
-- @return string|nil
function Actions.RegisterUsable(name, handler, owner)
	if not Catalog.Get(name) then return false, 'unknown_item' end
	if type(handler) ~= 'function' then return false, 'bad_request' end
	local previous = usables[name]
	if previous and previous.owner ~= owner then
		Open77.log.warn(('[inventory] %s now handles the use of %s, taking it from %s')
			:format(tostring(owner), name, tostring(previous.owner)))
	end
	usables[name] = { handler = handler, owner = owner }
	return true, nil
end

--- Removes an item's use handler, when the caller is the one that registered it.
-- @author dop42
-- @param name string
-- @param owner string|nil
-- @return boolean
function Actions.UnregisterUsable(name, owner)
	local current = usables[name]
	if not current or current.owner ~= owner then return false end
	usables[name] = nil
	return true
end

--- Asks a use handler whether the use goes ahead, inside its deadline.
--
-- The handler runs on a thread of its own and NOT under a pcall: it may reach the
-- database, a yield is not safe across a pcall boundary in this runtime, and a
-- handler that raises would take the request thread with it. On its own thread a
-- raise simply means `done` is never set, so the deadline answers
-- `handler_timeout` and the request is refused like any other.
local function ask(entry, source, info)
	local done, answer = false, nil
	CreateThread(function()
		answer = entry.handler(source, info)
		done = true
	end)

	local deadline = OPX.Now() + Options.USE_HANDLER_MS
	while not done and OPX.Now() < deadline do Wait(25) end
	if not done then
		Open77.log.warn(('[inventory] the use handler for %s took longer than %d ms or raised')
			:format(tostring(info.name), Options.USE_HANDLER_MS))
		return nil, 'handler_timeout'
	end

	if type(answer) ~= 'table' then return nil, 'handler_failed' end
	if answer.ok ~= true then
		return nil, Common.Word(answer.error, 64, '^[%w_%.%-]+$') or 'use_refused'
	end
	return answer, nil
end

--- Uses the item in a bag slot: draws a weapon, loads rounds, or consumes.
-- @author dop42
-- @param source Source
-- @param slot any
-- @return boolean
-- @return string|nil
function Actions.Use(source, slot)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return false, 'bad_request' end

	local now = OPX.Now()
	if now - (lastUse[source] or -math.huge) < OPX.Tune.Number('INVENTORY_USE_COOLDOWN_MS', 0) then
		return false, 'too_fast'
	end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end

	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end
	local entry = bag.items[slot]
	if not entry then return false, 'empty_slot' end
	local item = Catalog.Get(entry.name)
	if not item then return false, 'not_usable' end

	if item.weapon then
		lastUse[source] = now
		return M.Weapons.Use(source, bag, slot, item)
	end
	if item.ammo then
		lastUse[source] = now
		return M.Weapons.Reload(source, bag, slot)
	end

	local handler = usables[entry.name]
	if not item.usable and not handler then return false, 'not_usable' end
	lastUse[source] = now

	local use = item.use or {}
	local consume = use.consume or 0
	if handler then
		local answer, refusal = ask(handler, source, {
			name = entry.name,
			slot = slot,
			count = entry.count,
			metadata = Common.Copy(entry.metadata),
			label = Catalog.Label(entry.name),
			citizenId = Players.Citizen(source),
		})
		if not answer then return false, refusal end
		if answer.consume ~= nil then
			consume = Common.Integer(answer.consume, 0, Options.MAX_STACK) or consume
		end
	end

	if consume > 0 then
		-- The handler yielded, so the stack may have moved. The slot is trusted
		-- only while it still carries the same entry with enough units in it;
		-- otherwise the units go by name and metadata instead.
		local consumed
		if bag.items[slot] == entry and entry.count >= consume then
			consumed = Containers.TakeFromSlot(bag, slot, consume)
		else
			consumed = Containers.Remove(bag, entry.name, consume, entry.metadata)
		end
		if not consumed then return false, 'not_enough' end
	end

	TriggerClientEvent(M.Event.USED, source, {
		name = entry.name,
		slot = slot,
		label = Catalog.Label(entry.name),
		close = use.close ~= false,
		status = use.status,
		animation = use.animation,
	})
	return true, nil
end

--- Hands a stack from one player's bag to a nearby player's.
-- @author dop42
-- @param source Source
-- @param target any
-- @param slot any
-- @param count any
-- @return boolean
-- @return string|nil
function Actions.Give(source, target, slot, count)
	target = Common.Integer(target, 1, 2147483647)
	slot = Common.Integer(slot, 1, 65535)
	if not target or not slot or target == source then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	if not Players.GateOpen(target) then return false, 'not_ready' end

	local from, reason = Players.Bag(source)
	if not from then return false, reason end
	local to = Players.Bag(target)
	if not to then return false, 'target_unavailable' end

	local entry = from.items[slot]
	if not entry then return false, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return false, 'bad_count' end

	local here, there = World.Position(source), World.Position(target)
	if not World.InReach(here, there) then return false, 'too_far' end
	-- Loading the second bag yielded, so the source stack is read again.
	if from.items[slot] ~= entry or entry.count < count then return false, 'empty_slot' end

	local name = entry.name
	local moved, refusal = Containers.Move(from, slot, to, nil, count)
	if not moved then return false, refusal end

	local label = Catalog.Label(name)
	OPX.NotifyLocale(source, 'inventory.notify.gave', { count = count, item = label }, 'success')
	OPX.NotifyLocale(target, 'inventory.notify.received', { count = count, item = label }, 'info')
	return true, nil
end

--- Drops a stack onto the nearest pile that will take it, or onto a new one.
-- @author dop42
-- @param source Source
-- @param slot any
-- @param count any
-- @param yaw any the client's heading; it only turns the pile to fall in front
-- @return table|nil the pile
-- @return string|nil
function Actions.Drop(source, slot, count, yaw)
	if not Options.DROPS then return nil, 'drops_disabled' end
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return nil, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end

	local bag, reason = Players.Bag(source)
	if not bag then return nil, reason end
	local entry = bag.items[slot]
	if not entry then return nil, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return nil, 'bad_count' end

	-- WHAT MAY NOT BE LEFT ON THE FLOOR, and it is checked here rather than on
	-- the screen because the screen is a suggestion. A pile is memory-only: it is
	-- swept after `DROPS.LIFETIME_MINUTES` and nothing about it survives a
	-- restart. For a stack of eddies -- a bearer note drawn against a balance --
	-- that is not a lost item, it is a balance deleted, with no row, no audit line
	-- and nothing for staff to settle from. See `DROP` in shared/catalog.lua.
	local item = Catalog.Get(entry.name)
	if item and item.droppable == false then return nil, 'no_drop' end

	if World.Seat(source) then return nil, 'in_vehicle' end
	local position = World.Position(source)
	if not position then return nil, 'no_position' end
	position = World.Ahead(position, yaw)

	local pile = World.NearestDrop(position, Options.DROP_DISTANCE)
	if pile and not Containers.CanCarry(pile, entry.name, count, entry.metadata) then pile = nil end
	if not pile then
		local citizenId = Players.Citizen(source)
		if not citizenId or not World.MayCreateDrop(source, citizenId) then
			OPX.NotifyLocale(source, 'inventory.error.drop_limit', nil, 'error')
			return nil, 'drop_limit'
		end
		pile = World.CreateDrop(source, citizenId, position, entry.name)
	end

	local moved, refusal = Containers.Move(bag, slot, pile, nil, count)
	if not moved then
		-- A pile made for this drop and never filled goes again at once.
		World.CheckEmptyDrop(pile)
		return nil, refusal
	end
	return pile, nil
end

--- Moves every stack of a pile in reach into the bag, leaving what does not fit.
-- @author dop42
-- @param source Source
-- @param id any
-- @return boolean
-- @return string|nil
function Actions.TakeDrop(source, id)
	-- A pile's id is always negative: it is a memory-only container.
	id = Common.Integer(id, -2147483647, -1)
	if not id or not World.Drop(id) then return false, 'not_found' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	if World.Seat(source) then return false, 'in_vehicle' end
	local pile = Containers.Get(id)
	if not pile then return false, 'not_found' end
	if not World.WithinReach(source, pile) then return false, 'too_far' end
	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end

	local slots = {}
	for slot in pairs(pile.items) do slots[#slots + 1] = slot end
	table.sort(slots)

	local taken, refusal = 0, nil
	for index = 1, #slots do
		-- The last stack out empties the pile, which removes it and its container.
		local moved, code = Containers.Move(pile, slots[index], bag, nil, nil)
		if moved then taken = taken + 1 else refusal = refusal or code end
	end
	if taken == 0 then return false, refusal or 'not_found' end
	return true, refusal
end

--- Opens a configured stash beside the bag, when the player is standing at it.
-- @author dop42
-- @param source Source
-- @param name any
-- @return table|nil
-- @return string|nil
function Actions.OpenConfiguredStash(source, name)
	local stash = type(name) == 'string' and Options.STASHES[name] or nil
	if not stash then return nil, 'not_found' end
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end
	local anchor = { x = stash.position.x, y = stash.position.y, z = stash.position.z,
		bucket = stash.bucket }
	if not World.InReach(World.Position(source), anchor) then return nil, 'too_far' end

	local container, reason = World.Stash(stash.name, stash, anchor, Catalog.Rendered(stash.label))
	if not container then return nil, reason end
	Containers.View(source, container)
	return container, nil
end

--- Opens a vehicle's trunk, or the seat's glovebox, beside the bag.
-- A glovebox is always the one of the vehicle the player is sitting in, whatever
-- the client named. A trunk's id arrives as a DECIMAL STRING: a vehicle id carries
-- a generation and can pass 2^53, where a JSON number stops being exact.
-- @author dop42
-- @param source Source
-- @param kind string trunk or glovebox
-- @param vehicleId any
-- @return table|nil
-- @return string|nil
function Actions.OpenVehicle(source, kind, vehicleId)
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end
	if kind == KIND.GLOVEBOX then
		vehicleId = World.Seat(source)
		if not vehicleId then return nil, 'not_seated' end
	else
		if type(vehicleId) == 'string' and vehicleId:match('^%d+$') and #vehicleId <= 19 then
			vehicleId = math.tointeger(tonumber(vehicleId))
		end
		vehicleId = Common.Integer(vehicleId, 1, math.maxinteger)
		if not vehicleId then return nil, 'bad_request' end
		if World.Seat(source) == vehicleId then return nil, 'seated' end
	end

	local container, reason = World.VehicleContainer(vehicleId, kind)
	if not container then return nil, reason end

	-- A BOOT THAT BELONGS TO SOMEBODY ANSWERS TO THEM. Reach and "not sitting in
	-- it" were the only checks, so a stranger could empty a parked owned car; the
	-- vehicles module has no lock to consult, so ownership is the whole of the
	-- rule. Off by configuration for a server that wants theft.
	--
	-- The glovebox is exempt: it opens only while SEATED, and somebody sitting in
	-- the car has already been let into it.
	if kind ~= KIND.GLOVEBOX and Options.TRUNK_OWNER_ONLY and container.ownerCitizenId then
		if container.ownerCitizenId ~= Players.Citizen(source) then
			return nil, 'not_yours'
		end
	end

	if not World.WithinReach(source, container) then return nil, 'too_far' end
	Containers.View(source, container)
	return container, nil
end

--- The players in reach, nearest first, by id and rounded distance only.
-- Never a name: the list is drawn beside a bag, and who is standing near somebody
-- is not this module's to tell.
-- @author dop42
-- @param source Source
-- @return table[]
function Actions.Nearby(source)
	local out = {}
	if Options.NEARBY_MAX <= 0 then return out end
	local here = World.Position(source)
	if not here then return out end

	local players = Players.List()
	for index = 1, #players do
		local other = players[index].source
		if other ~= source then
			local there = World.Position(other)
			if there and there.bucket == here.bucket then
				local gap = World.Distance(here, there)
				if gap <= Options.REACH then
					out[#out + 1] = { id = other, distance = math.floor(gap * 10 + 0.5) / 10 }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	for index = #out, Options.NEARBY_MAX + 1, -1 do out[index] = nil end
	return out
end

--- Forgets a departed player's use and pile cooldowns.
-- @author dop42
-- @param source Source
function Actions.Forget(source)
	lastUse[source] = nil
	World.Forget(source)
end
