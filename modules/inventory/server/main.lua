--- The phases, the contract, the background loops and the last-chance writes.
-- @author dop42
--
-- Nothing here decides anything about a container: each contract function checks
-- its arguments and calls into `Containers`, `Actions` or `World`.
--
-- WHAT THIS RUNTIME DELETED. The contract below used to be seventeen exports,
-- each wrapped in a guard that read the calling resource off the host, checked it
-- against a read list and a writer list, refused it with an audit line, and bounded
-- the encoded answer against a 32 KiB ceiling with `GetInventory` and `GetItems`
-- paging under it. A contract inside one Lua state has no caller to identify, no
-- wire to fit under and no page to turn.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players
local World = M.World
local Actions = M.Actions
local Weapons = M.Weapons
local Requests = M.Requests
local Commands = M.Commands
local Currency = M.Currency

local Result = OPX.Result

-- Set by `Stop` so the background thread ends with the module.
local stopped = false

--- The bag of a player id or of a citizen id, online or not.
-- The second answer is true when this call is what loaded the bag, so the caller
-- knows it has to settle it again afterwards.
local function bagOf(target)
	if type(target) == 'number' then
		local source = Common.Integer(target, 1, 2147483647)
		if not source then return nil, false, 'bad_target' end
		local bag, reason = Players.Bag(source)
		if not bag and reason == 'not_loaded' then bag, reason = Players.Attach(source) end
		return bag, false, reason
	end
	local citizenId, reason = Players.Identify(target)
	if not citizenId then return nil, false, reason end
	local online = Players.SourceOf(citizenId)
	if online then
		local bag, bagReason = Players.Bag(online)
		return bag, false, bagReason
	end
	return Players.LoadBag(citizenId)
end

--- An item name argument when it is well formed, or nil.
local function itemName(value)
	return Common.Word(value, Catalog.NAME_MAX, Catalog.NAME)
end

--- Runs `body` against a target's bag, settling a borrowed one afterwards.
-- Yields. Every writing contract function goes through it, so that no path can
-- load an offline bag and forget to put it away again.
local function withBag(target, body)
	local bag, borrowed, reason = bagOf(target)
	if not bag then return Result.Err(reason or 'not_found', tostring(target)) end
	local answer = body(bag)
	if borrowed then Players.Settle(bag) end
	return answer
end

--- Turns the two answers of a container operation into a Result.
local function outcome(ok, code)
	if ok then return Result.Ok(true) end
	return Result.Err(code or 'failed')
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- Adds catalogue items to a bag, copying the metadata onto each unit added.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result
function M.AddItem(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withBag(target, function(bag)
		local ok, code = Containers.Add(bag, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.add', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name), citizenId = bag.owner,
			data = { item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- Takes items out of a bag, from the last slot backwards.
-- A nil metadata matches any stack of that item, which is what a caller taking
-- "three bandages" means.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result
function M.RemoveItem(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withBag(target, function(bag)
		local ok, code = Containers.Remove(bag, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.remove', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name), citizenId = bag.owner,
			data = { item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- Takes units out of one precise slot, never a look-alike elsewhere.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @param count integer|nil
-- @return Result
function M.RemoveFromSlot(target, slot, count)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end

	return withBag(target, function(bag)
		local entry = Containers.GetSlot(bag, slot)
		if not entry then return Result.Err('empty_slot', tostring(slot)) end
		local ok, code = Containers.TakeFromSlot(bag, slot, count == nil and entry.count or count)
		OPX.Audit.Log({ event = 'inventory.removeSlot', severity = ok and 'info' or 'warn',
			message = ('slot %d'):format(slot), citizenId = bag.owner,
			data = { slot = slot, item = entry.name, error = code } })
		return outcome(ok, code)
	end)
end

--- Replaces the metadata of one stack.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @param metadata table|nil
-- @return Result
function M.SetMetadata(target, slot, metadata)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end

	return withBag(target, function(bag)
		local ok, code = Containers.SetMetadata(bag, slot, kept)
		OPX.Audit.Log({ event = 'inventory.metadata', severity = ok and 'info' or 'warn',
			message = ('slot %d'):format(slot), citizenId = bag.owner,
			data = { slot = slot, error = code } })
		return outcome(ok, code)
	end)
end

--- Empties a bag.
-- @author dop42
-- @param target Source|CitizenId
-- @return Result
function M.ClearInventory(target)
	return withBag(target, function(bag)
		local stacks = OPX.Table.Count(bag.items)
		local ok, code = Containers.Clear(bag)
		OPX.Audit.Log({ event = 'inventory.clear', severity = ok and 'info' or 'warn',
			message = ('%d stack(s)'):format(stacks), citizenId = bag.owner,
			data = { stacks = stacks, error = code } })
		return outcome(ok, code)
	end)
end

--- How many units of an item a bag holds.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param metadata table|nil nil counts every stack of that item
-- @return Result integer
function M.GetItemCount(target, name, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	return withBag(target, function(bag)
		return Result.Ok(Containers.CountIn(bag, name, kept))
	end)
end

--- Whether a bag holds at least `count` of an item.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @return Result boolean
function M.HasItem(target, name, count)
	local counted = M.GetItemCount(target, name, nil)
	if not counted.ok then return counted end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end
	return Result.Ok(counted.value >= count)
end

--- Whether a bag would take the units, by slots and by weight.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result boolean
function M.CanCarry(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end
	return withBag(target, function(bag)
		local ok = Containers.CanCarry(bag, name, count, kept)
		return Result.Ok(ok)
	end)
end

--- A bag as a screen would draw it: the slots, the stacks and the weight.
-- Answered whole. It used to be paged by 64 stacks under a 32 KiB ceiling because
-- it crossed a network argument; it does not cross anything now.
-- @author dop42
-- @param target Source|CitizenId
-- @return Result
function M.GetInventory(target)
	return withBag(target, function(bag)
		return Result.Ok(Containers.Describe(bag))
	end)
end

--- The stack in one slot of a bag, or nil.
-- A COPY, so a caller cannot edit a container by editing the answer.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @return Result
function M.GetSlot(target, slot)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end
	return withBag(target, function(bag)
		local entry = Containers.GetSlot(bag, slot)
		if not entry then return Result.Ok(nil) end
		return Result.Ok({ slot = slot, name = entry.name, count = entry.count,
			metadata = Common.Copy(entry.metadata) })
	end)
end

--- One catalogue entry as a screen reads it, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.GetItem(name)
	return Catalog.ViewOf(name)
end

--- Every catalogue entry, by name.
-- @author dop42
-- @return table<string, table>
function M.GetItems()
	local out = {}
	local names = Catalog.Names()
	for index = 1, #names do out[names[index]] = Catalog.ViewOf(names[index]) end
	return out
end

--- Opens a stash beside a player's bag and raises their screen.
-- The CALLER answers for whether this player may open this stash -- a job, a key,
-- a code. This module only checks the reach, and only when a position is given: a
-- stash opened with no position has no anchor and stays in reach.
-- @author dop42
-- @param playerId Source
-- @param name string the storage key; never reuse one for somewhere else
-- @param options table|nil slots, maxWeight, label, position, bucket
-- @return Result the container id
function M.OpenStash(playerId, name, options)
	playerId = Common.Integer(playerId, 1, 2147483647)
	name = Common.Word(name, 48, '^[%w_%-%.]+$')
	if not playerId or not name then return Result.Err('bad_argument', 'playerId or name') end
	options = type(options) == 'table' and options or {}

	local size = {
		slots = options.slots == nil and 50 or Common.Integer(options.slots, 1, 200),
		maxWeight = options.maxWeight == nil and 100000 or
			Common.Integer(options.maxWeight, 0, 4000000000),
	}
	if not size.slots or not size.maxWeight then return Result.Err('bad_argument', 'size') end
	if not Players.GateOpen(playerId) then return Result.Err('not_ready') end
	if not Players.Bag(playerId) then return Result.Err('not_loaded') end

	local anchor
	if type(options.position) == 'table' then
		local x, y, z = tonumber(options.position.x), tonumber(options.position.y),
			tonumber(options.position.z)
		if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
			return Result.Err('bad_argument', 'position')
		end
		anchor = { x = x, y = y, z = z,
			bucket = Common.Integer(options.bucket, 0, 2147483647) or 0 }
		if not World.InReach(World.Position(playerId), anchor) then
			return Result.Err('too_far')
		end
	end

	local container, reason = World.Stash(name, size, anchor, Common.Clean(options.label, 64))
	if not container then return Result.Err(reason or 'unavailable', name) end
	Containers.View(playerId, container)
	TriggerClientEvent(M.Event.OPEN, playerId)
	OPX.Audit.Log({ event = 'inventory.openStash', message = name, source = playerId,
		data = { stash = name } })
	return Result.Ok(container.id)
end

--- Closes a player's screen and whatever it had open beside the bag.
-- @author dop42
-- @param playerId Source
-- @return Result
function M.CloseInventory(playerId)
	playerId = Common.Integer(playerId, 1, 2147483647)
	if not playerId then return Result.Err('bad_argument', 'playerId') end
	Containers.CloseSecondary(playerId, true)
	TriggerClientEvent(M.Event.RESET, playerId)
	return Result.Ok(true)
end

--- The weapon this module has put in a player's hands, or nil.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function M.GetHeldWeapon(playerId)
	local held = Weapons.Held(Common.Integer(playerId, 1, 2147483647) or -1)
	if not held then return nil end
	return { name = held.name, serial = held.serial, slot = Options.WEAPON_SLOT }
end

--- Changes a stored container's slot count and weight limit.
-- `Ensure` only writes a size for the row that creates it, so a container keeps
-- the size it was made with for ever; this is the one way that changes. The copy
-- in memory is moved with it, or the two would disagree until it was unloaded.
-- @author dop42
-- @param kind string
-- @param owner string
-- @param slots integer
-- @param maxWeight integer
-- @return Result
function M.ResizeContainer(kind, owner, slots, maxWeight)
	if M.KIND[kind:upper()] == nil then return Result.Err('bad_argument', 'kind') end
	owner = Common.Word(owner, 64, '^[%w_%-%.:]+$')
	slots = Common.Integer(slots, 1, 200)
	maxWeight = Common.Integer(maxWeight, 0, 4000000000)
	if not owner or not slots or not maxWeight then
		return Result.Err('bad_argument', 'owner or size')
	end

	local held = Containers.Find(kind, owner)
	local id = held and not held.transient and held.id or nil
	if id == nil then
		local loaded, reason = Containers.Load(kind, owner, slots, maxWeight)
		if not loaded then return Result.Err(reason or 'not_found', owner) end
		if loaded.transient then return Result.Err('not_found', owner) end
		held, id = loaded, loaded.id
	end

	local written = M.Storage.Resize(id, slots, maxWeight)
	if not written.ok then return written end
	held.slots = slots
	held.maxWeight = maxWeight
	-- Stacks beyond the new slot count are kept, counted and removable; they are
	-- simply not drawn and nothing new is put there.
	Containers.Publish(held)
	OPX.Audit.Log({ event = 'inventory.resize', message = ('%s %s'):format(kind, owner),
		data = { kind = kind, owner = owner, slots = slots, maxWeight = maxWeight } })
	return Result.Ok(id)
end

--- Deletes a stored container. Its stacks go by cascade, and EVERYTHING IN IT
--- goes with them.
-- The copy in memory is discarded first and without writing: writing it back
-- would put the rows that were just deleted straight in again.
-- @author dop42
-- @param kind string
-- @param owner string
-- @return Result
function M.DeleteContainer(kind, owner)
	if M.KIND[kind:upper()] == nil then return Result.Err('bad_argument', 'kind') end
	owner = Common.Word(owner, 64, '^[%w_%-%.:]+$')
	if not owner then return Result.Err('bad_argument', 'owner') end

	local held = Containers.Find(kind, owner)
	if held then
		if held.transient then return Result.Err('bad_argument', 'kind') end
		Containers.Discard(held.id)
	end

	-- `Find` and never `Ensure`: ensuring would CREATE the row it is about to
	-- delete, and for a linked kind it would create it with no owner column set.
	local found = M.Storage.Find(kind, owner)
	if not found.ok then return found end
	if not found.value then return Result.Err('not_found', owner) end
	local removed = M.Storage.Delete(found.value.id)
	if not removed.ok then return removed end
	OPX.Audit.Log({ event = 'inventory.delete', severity = 'warn',
		message = ('%s %s'):format(kind, owner), data = { kind = kind, owner = owner } })
	return Result.Ok(true)
end

--- The containers holding an item, largest stacks first.
-- @author dop42
-- @param name string
-- @param limit integer|nil
-- @return Result
function M.Holders(name, limit)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	return M.Storage.Holders(name, Common.Integer(limit, 1, 200) or 20)
end

-- ── the background pass ──────────────────────────────────────────────────────

--- Runs a loop body forever, reading its period on every pass.
-- `OPX.Scheduler` is the client's loop; the server VM has none, so each loop
-- keeps its own thread. `guarded` says whether the pass may run under a `pcall` --
-- which it may only if it never yields, because a yield does not cross one.
local function every(periodMs, label, guarded, body)
	CreateThread(function()
		local failing = false
		while not stopped do
			Wait(periodMs())
			if not stopped and not OPX.BootError then
				if guarded then
					local ok, failure = pcall(body)
					if ok then
						failing = false
					elseif not failing then
						failing = true
						Open77.log.error(('[inventory] the %s pass raised: %s')
							:format(label, tostring(failure)))
					end
				else
					body()
				end
			end
		end
	end)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state, contributes the tables and declares the tunables. Never yields.
-- @author dop42
function M.Init()
	-- Filled in `Start`: `Init` runs before any contract is published, so reading
	-- one here would answer nil for the life of the resource. It exists now so
	-- that a read before `Start` is a nil field and not a nil index.
	M.Contracts = {}

	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Tune.Declare(M.TUNABLES)
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
function M.Api()
	OPX.Api.Provide('inventory', 1, {
		AddItem = M.AddItem,
		RemoveItem = M.RemoveItem,
		RemoveFromSlot = M.RemoveFromSlot,
		SetMetadata = M.SetMetadata,
		ClearInventory = M.ClearInventory,

		GetItemCount = M.GetItemCount,
		HasItem = M.HasItem,
		CanCarry = M.CanCarry,
		GetInventory = M.GetInventory,
		GetSlot = M.GetSlot,

		GetItem = M.GetItem,
		GetItems = M.GetItems,
		Holders = M.Holders,

		ResizeContainer = M.ResizeContainer,
		DeleteContainer = M.DeleteContainer,

		OpenStash = M.OpenStash,
		CloseInventory = M.CloseInventory,

		RegisterUsable = Actions.RegisterUsable,
		UnregisterUsable = Actions.UnregisterUsable,

		-- THE MONEY BRIDGE, and the only two functions that may move a balance
		-- and a stack of notes in the same breath. Published so that a job, a
		-- heist or an ATM asks for a conversion instead of writing its own pair
		-- of calls -- a caller that debits and inserts by hand is a caller that
		-- will one day do only one of the two. See `server/currency.lua`.
		Withdraw = Currency.Withdraw,
		Deposit = Currency.Deposit,
		CurrencyWired = Currency.Wired,

		GetHeldWeapon = M.GetHeldWeapon,
	})
end

--- Wires the doors, registers the commands and starts the loops. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.character = OPX.Api.Get('character')
	M.Contracts.vehicles = OPX.Api.Get('vehicles')

	if M.Contracts.character == nil then
		Open77.log.warn('[inventory] no character contract: no bag can be identified, so every ' ..
			'request is refused')
	end
	if M.Contracts.vehicles == nil then
		Open77.log.warn('[inventory] no vehicles contract: no vehicle is owned here, so every ' ..
			'trunk and glovebox is memory-only and nothing in one survives a restart')
	end

	for _, line in ipairs(M.Problems) do Open77.log.warn('[inventory] config: ' .. line) end

	Players.Wire()
	Weapons.Wire()
	Requests.Wire()
	Commands.Register()

	-- AFTER the contracts are resolved above, and not in `Init`: the money-to-item
	-- bridge refuses to wire itself at all without a `character` contract to draw
	-- a note against, and `Init` runs before any contract is published.
	Currency.Register()

	-- A DELETED CHARACTER TAKES ITS CONTAINERS WITH IT, and their stacks with
	-- them: the item rows really do cascade off `inventory_id`, and this is a real
	-- DELETE on the parent, so that one fires. The cascade that does NOT fire is
	-- the one from the character table, because a character delete is a soft one.
	-- Left to it, every bag, every trunk and every glovebox of a deleted character
	-- stayed, full, owned by a citizen id nothing can log in as. See
	-- `character.Event.IN_DELETED`.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[inventory] the containers of the deleted %s were not ' ..
					'removed: %s'):format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	Open77.log.info(('[inventory] ready: %d item(s), %d stash(es), bag %d slots / %d g')
		:format(#Catalog.Names(), #Options.STASH_LIST, Options.BAG_SLOTS, Options.BAG_MAX_WEIGHT))

	-- These four reach the database or another module's state and yield, so they
	-- may not be guarded: a yield does not cross a `pcall`.
	every(function() return Options.SAVE_SWEEP_MS end, 'save', false, M.Storage.Sweep)
	every(function() return 1000 end, 'reach', false, World.SweepReach)
	every(function() return 5000 end, 'vehicles', false, World.SweepVehicles)
	every(function() return 30000 end, 'prune', false, Players.PruneVanished)

	-- These four only touch host calls and tables of this module, and are guarded:
	-- a raise from a host read must end the pass, not the loop.
	every(function() return 60000 end, 'drop sweep', true, World.SweepDrops)
	every(function() return Options.AMMO_SYNC_MS end, 'ammo sync', true, Weapons.SyncAmmo)
	every(function() return Options.WEAPON_SCAN_MS end, 'weapon scan', true, Weapons.Scan)
	every(function() return 10000 end, 'weapon steps', true, Weapons.SweepPending)

	if Options.WEAPONS and type(Open77.weapons) ~= 'table' then
		Open77.log.warn('[inventory] this host installs no weapon relay: drawing a weapon from ' ..
			'the bag is refused')
	end
end

--- The last chance to write: one thread per container, never one loop.
-- A single loop would send the first transaction, suspend, and never be resumed.
-- This is best effort, and the log line says so. It is also all that is needed
-- now: the write used to have to cross into another resource, which a stopping VM
-- cannot do at all, and the whole carry-across-a-reload protocol existed for that.
-- @author dop42
function M.Stop()
	stopped = true
	local pending = M.Storage.Pending()
	local dispatched = M.Storage.FlushAll()
	if pending > 0 then
		Open77.log.info(('[inventory] stopping: dispatched a write for %d of %d unwritten ' ..
			'container(s), best effort'):format(dispatched, pending))
	end
end
