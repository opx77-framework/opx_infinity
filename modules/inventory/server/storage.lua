--- Every SQL statement this module runs, and the deferred write that drives them.
-- @author dop42
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: `server/containers.lua` decides.
--
-- Statements bind named parameters (`@id`), never `?`, because the bridge
-- rewrites `?` by walking the query text; `Save` is the single exception and says
-- why. No comment may appear inside a SQL string for the same reason. Every
-- statement yields and answers a `Result`, so every one of them has to be reached
-- from a `CreateThread`.
--
-- WHAT IS NOT HERE ANY MORE. These two tables used to belong to another resource,
-- and a write crossed the boundary as a staging protocol: rows chunked to
-- `ROWS_PER_STAGE` and `BYTES_PER_STAGE` under a transaction token, a per-caller
-- token budget with a TTL, a commit call, and a `waitReady` spin so a read could
-- not overtake a write carried across a reload. None of that was a rule about
-- inventories -- it existed because one network argument caps at 48 KiB and the
-- two halves lived in different Lua states. `Save` below is the whole of it now.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}
local Store = M.Storage

--- One CREATE TABLE IF NOT EXISTS per table this module owns, in foreign-key
--- order: the container before the stacks that cascade from it.
--
-- `citizen_id` keeps its foreign key: `character` is a hard requirement, so
-- `opx77_characters` exists whenever this module does.
--
-- `plate` deliberately has NONE, although the column is still indexed and still
-- keyed on a vehicle. `vehicles` is only OPTIONAL here, and a server that turns
-- it off in config has no `opx77_vehicles` for the constraint to name --
-- `OPX.Schema.Apply` would stop at that statement and set `OPX.BootError`,
-- degrading the whole runtime because one optional module is off.
--
-- Making the constraint conditional on `vehicles` being enabled was the obvious
-- alternative and is worse: `CREATE TABLE IF NOT EXISTS` never alters a table
-- that already exists, so a server that enabled vehicles later would keep a
-- table without the key, and two servers with the same configuration would have
-- different schemas depending on the order they were switched on. A uniform
-- schema is worth more than the cascade.
--
-- What the cascade gave is covered on the read side instead: `Store.Read`
-- refuses a plate no owned vehicle carries, so a container for a vehicle that
-- has gone is never opened. The row outlives the vehicle, which costs a row.
Store.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_inventories (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    kind VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    owner VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    plate VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    slots SMALLINT UNSIGNED NOT NULL,
    max_weight INT UNSIGNED NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_opx77_inventories_identity (kind, owner),
    KEY idx_opx77_inventories_citizen (citizen_id),
    KEY idx_opx77_inventories_plate (plate),
    CONSTRAINT fk_opx77_inventory_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],

	[[
CREATE TABLE IF NOT EXISTS opx77_inventory_items (
    inventory_id INT UNSIGNED NOT NULL,
    slot SMALLINT UNSIGNED NOT NULL,
    name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    quantity INT UNSIGNED NOT NULL,
    metadata JSON NULL DEFAULT NULL,
    PRIMARY KEY (inventory_id, slot),
    KEY idx_opx77_inventory_items_name (name),
    CONSTRAINT fk_opx77_inventory_item_inventory
        FOREIGN KEY (inventory_id) REFERENCES opx77_inventories (id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],
}

-- Item rows one INSERT carries inside a save. Past this the rows of one container
-- go out as several statements of the same transaction, which keeps each
-- statement's parameter list short.
local ROWS_PER_INSERT = 50

-- Stacks one page of `Contents` reads. A page is bounded so a container nobody
-- expected to be large cannot become one query that holds a connection.
local ROWS_PER_PAGE = 512

-- A slot number is a SMALLINT UNSIGNED, so no container can have more stacks than
-- this; the read loop is bounded by it rather than trusting the cursor to end.
local MAX_SLOT = 65535

--- Turns a container row into its header shape.
local function toHeader(row)
	if not row then return nil end
	return {
		id = tonumber(row.id),
		kind = row.kind,
		owner = row.owner,
		slots = tonumber(row.slots),
		maxWeight = tonumber(row.max_weight),
	}
end

--- Whether a LIVING character carries this citizen id.
-- `deleted_at IS NULL` is the whole point: a deleted character's bag stays in the
-- table, and nobody opens it.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function Store.CharacterExists(citizenId)
	local row = Storage.Single([[
SELECT 1 AS found FROM opx77_characters
 WHERE citizen_id = @citizen AND deleted_at IS NULL
 LIMIT 1
  ]], { citizen = citizenId })
	if not row.ok then return row end
	return Result.Ok(row.value ~= nil)
end

--- Whether an owned vehicle carries this plate.
-- @author dop42
-- @param plate string
-- @return Result
function Store.VehicleExists(plate)
	local row = Storage.Single(
		'SELECT 1 AS found FROM opx77_vehicles WHERE plate = @plate LIMIT 1', { plate = plate })
	if not row.ok then return row end
	return Result.Ok(row.value ~= nil)
end

--- One container's header by its identity, or nil.
-- The read half of `Ensure`, and the only way to reach a container that must NOT
-- be created if it is absent -- deleting one, for instance.
-- @author dop42
-- @param kind string
-- @param owner string
-- @return Result
function Store.Find(kind, owner)
	local row = Storage.Single([[
SELECT id, kind, owner, slots, max_weight FROM opx77_inventories
 WHERE kind = @kind AND owner = @owner
 LIMIT 1
  ]], { kind = kind, owner = owner })
	if not row.ok then return row end
	return Result.Ok(toHeader(row.value))
end

--- Finds or creates one container keyed on kind and owner.
-- INSERT IGNORE and then a SELECT, never a SELECT and then an INSERT: two callers
-- in the same tick both pass a SELECT, and the unique key on `(kind, owner)` is
-- the only thing that can settle which of them created the row. The size given
-- therefore only serves whoever creates; an existing container answers the size
-- it was created with.
-- @author dop42
-- @param entity table kind, owner, citizenId, plate, slots, maxWeight
-- @return Result header and whether this call created it
function Store.Ensure(entity)
	local inserted = Storage.Update([[
INSERT IGNORE INTO opx77_inventories (kind, owner, citizen_id, plate, slots, max_weight)
VALUES (@kind, @owner, NULLIF(@citizen, ''), NULLIF(@plate, ''), @slots, @maxWeight)
  ]], {
		kind = entity.kind,
		owner = entity.owner,
		-- The bridge DROPS a nil parameter instead of binding NULL, so absence
		-- travels as '' and the statement turns it back with NULLIF.
		citizen = entity.citizenId or '',
		plate = entity.plate or '',
		slots = entity.slots,
		maxWeight = entity.maxWeight,
	})
	if not inserted.ok then return inserted end

	local affected = inserted.value
	if type(affected) == 'table' then affected = affected.affectedRows end

	local found = Store.Find(entity.kind, entity.owner)
	if not found.ok then return found end
	if not found.value then return Result.Err('inventory.noOwner', entity.owner) end
	return Result.Ok({ header = found.value, created = tonumber(affected) == 1 })
end

--- One container's header by id, or nil.
-- @author dop42
-- @param id integer
-- @return Result
function Store.Header(id)
	local row = Storage.Single([[
SELECT id, kind, owner, slots, max_weight FROM opx77_inventories
 WHERE id = @id
 LIMIT 1
  ]], { id = id })
	if not row.ok then return row end
	return Result.Ok(toHeader(row.value))
end

--- One page of a container's stacks, after a slot.
-- Paged by SLOT NUMBER and never by offset: a save landing between two pages
-- shifts every offset after it, and a stack would come out in both pages or in
-- neither. A slot only ever names one stack. The limit is a constant of this
-- file, formatted into the statement rather than bound, because a LIMIT is not a
-- parameter the bridge will take.
-- @author dop42
-- @param id integer
-- @param after integer the highest slot already read
-- @return Result
function Store.Contents(id, after)
	local rows = Storage.Query(([[
SELECT slot, name, quantity, metadata FROM opx77_inventory_items
 WHERE inventory_id = @id AND slot > @after
 ORDER BY slot
 LIMIT %d
  ]]):format(ROWS_PER_PAGE), { id = id, after = after })
	if not rows.ok then return rows end

	local list = rows.value or {}
	local out = {}
	for i = 1, #list do
		local row = list[i]
		out[i] = {
			slot = tonumber(row.slot),
			name = row.name,
			count = tonumber(row.quantity),
			metadata = Storage.Decode(row.metadata),
		}
	end
	return Result.Ok(out)
end

--- Rewrites every listed container's stacks as one unit.
-- A container is a DELETE, then the INSERTs, then the timestamp, all inside one
-- transaction: half a container is not a state anything can read, and a container
-- staged with no rows is a container that has been emptied.
--
-- This is the ONE place positional parameters are used. A transaction statement
-- is bound the way the platform's own resources bind one, and the bridge rewrites
-- `?` by walking the query text -- so the count of `?` is compared to the values
-- before anything is sent, and a mismatch is refused rather than dispatched.
-- @author dop42
-- @param containers table[] each { id, rows }
-- @return Result
function Store.Save(containers)
	local statements = {}

	local function add(query, values)
		local placeholders = 0
		for _ in query:gmatch('%?') do placeholders = placeholders + 1 end
		if placeholders ~= #values then
			return ('%d placeholder(s) against %d value(s)'):format(placeholders, #values)
		end
		statements[#statements + 1] = { query = query, values = values }
		return nil
	end

	for c = 1, #containers do
		local container = containers[c]
		local wrong = add('DELETE FROM opx77_inventory_items WHERE inventory_id = ?',
			{ container.id })
		if wrong then return Result.Err('bad-statement', wrong) end

		local rows = container.rows
		for first = 1, #rows, ROWS_PER_INSERT do
			local placeholders, values = {}, {}
			for r = first, math.min(first + ROWS_PER_INSERT - 1, #rows) do
				local row = rows[r]
				placeholders[#placeholders + 1] = "(?, ?, ?, ?, NULLIF(?, ''))"
				values[#values + 1] = container.id
				values[#values + 1] = row.slot
				values[#values + 1] = row.name
				values[#values + 1] = row.count
				values[#values + 1] = Storage.Nullable(row.metadata)
			end
			wrong = add('INSERT INTO opx77_inventory_items (inventory_id, slot, name, quantity, ' ..
				'metadata) VALUES ' .. table.concat(placeholders, ', '), values)
			if wrong then return Result.Err('bad-statement', wrong) end
		end

		wrong = add('UPDATE opx77_inventories SET updated_at = CURRENT_TIMESTAMP WHERE id = ?',
			{ container.id })
		if wrong then return Result.Err('bad-statement', wrong) end
	end

	if #statements == 0 then return Result.Ok(0) end
	return Storage.Transaction(statements)
end

--- Writes a container's slot count and weight limit.
-- @author dop42
-- @param id integer
-- @param slots integer
-- @param maxWeight integer
-- @return Result
function Store.Resize(id, slots, maxWeight)
	return Storage.Execute(
		'UPDATE opx77_inventories SET slots = @slots, max_weight = @maxWeight WHERE id = @id',
		{ id = id, slots = slots, maxWeight = maxWeight })
end

--- Deletes a container; its stacks go by cascade.
-- @author dop42
-- @param id integer
-- @return Result
function Store.Delete(id)
	return Storage.Execute('DELETE FROM opx77_inventories WHERE id = @id', { id = id })
end

--- The containers holding an item, largest stacks first.
-- The limit is a caller constant formatted into the statement, as in `Contents`.
-- @author dop42
-- @param name string
-- @param limit integer
-- @return Result
function Store.Holders(name, limit)
	local rows = Storage.Query(([[
SELECT i.id, i.kind, i.owner, it.slot, it.quantity
  FROM opx77_inventory_items it
  JOIN opx77_inventories i ON i.id = it.inventory_id
 WHERE it.name = @name
 ORDER BY it.quantity DESC
 LIMIT %d
  ]]):format(math.floor(limit)), { name = name })
	if not rows.ok then return rows end

	local list = rows.value or {}
	local out = {}
	for i = 1, #list do
		local row = list[i]
		out[i] = {
			id = tonumber(row.id),
			kind = row.kind,
			owner = row.owner,
			slot = tonumber(row.slot),
			count = tonumber(row.quantity),
		}
	end
	return Result.Ok(out)
end

-- ── reading a container ──────────────────────────────────────────────────────

--- Reads one stored container, creating it at the given size if it is absent.
-- A LINKED owner must exist first: a living character for a bag, an owned vehicle
-- for a trunk or a glovebox. Without that check a bag would be created for a
-- citizen id that never existed, and the foreign key would refuse the row with a
-- message nobody can act on.
-- @author dop42
-- @param kind string
-- @param owner string
-- @param slots integer
-- @param maxWeight integer
-- @return table|nil the container
-- @return string|nil the refusal code
function Store.Read(kind, owner, slots, maxWeight)
	if OPX.BootError then return nil, 'storage' end

	local link = M.LINKED[kind]
	local entity = { kind = kind, owner = owner, slots = slots, maxWeight = maxWeight }
	if link == 'citizen' then
		local exists = Store.CharacterExists(owner)
		if not exists.ok then return nil, 'storage' end
		if exists.value ~= true then return nil, 'no_character' end
		entity.citizenId = owner
	elseif link == 'plate' then
		local exists = Store.VehicleExists(owner)
		if not exists.ok then return nil, 'storage' end
		if exists.value ~= true then return nil, 'no_vehicle' end
		entity.plate = owner
	end

	local ensured = Store.Ensure(entity)
	if not ensured.ok then return nil, 'storage' end

	local header = ensured.value.header
	local id = Common.Integer(header.id, 1, 4294967295)
	if not id then return nil, 'storage' end

	local container = {
		id = id,
		kind = kind,
		owner = owner,
		slots = Common.Integer(header.slots, 1, MAX_SLOT) or slots,
		maxWeight = Common.Integer(header.maxWeight, 0, 4294967295) or maxWeight,
		items = {},
	}

	local after = 0
	-- Bounded by the slot space and not by the cursor: a page that does not
	-- advance `after` ends the read, and there can never be more pages than
	-- slots.
	for _ = 1, math.ceil(MAX_SLOT / ROWS_PER_PAGE) do
		local page = Store.Contents(id, after)
		if not page.ok then return nil, 'storage' end
		local rows = page.value
		for index = 1, #rows do
			local row = rows[index]
			local slot = Common.Integer(row.slot, 1, MAX_SLOT)
			local count = slot and Common.Integer(row.count, 1, 2147483647) or nil
			local name = slot and Common.Word(row.name, 48) or nil
			if slot and count and name then
				local metadata = row.metadata
				if type(metadata) ~= 'table' or next(metadata) == nil then metadata = nil end
				-- A stack of something the catalogue no longer carries is kept as
				-- it stands: dropping it here would delete it on the next write.
				container.items[slot] = { name = name, count = count, metadata = metadata }
				if slot > after then after = slot end
			end
		end
		if #rows < ROWS_PER_PAGE then break end
	end

	return container, nil
end

-- ── the deferred write ───────────────────────────────────────────────────────

-- When each container's OLDEST unwritten change happened, and which writes are in
-- flight. A change made while a write is in flight re-marks the container, which
-- goes out on the next sweep.
local dirty = {}
local saving = {}

--- Marks a container unwritten, keeping the time of its oldest change.
-- @author dop42
-- @param id integer
function Store.MarkDirty(id)
	if dirty[id] == nil then dirty[id] = OPX.Now() end
end

--- Forgets the unwritten mark of a container that is no longer loaded.
-- @author dop42
-- @param id integer
function Store.Forget(id)
	dirty[id] = nil
end

--- Whether a container is waiting to be written.
-- @author dop42
-- @param id integer
-- @return boolean
function Store.IsDirty(id)
	return dirty[id] ~= nil
end

--- The containers holding an unwritten change.
-- @author dop42
-- @return integer
function Store.Pending()
	local count = 0
	for _ in pairs(dirty) do count = count + 1 end
	return count
end

--- Copies a container's stacks as they stand, in slot order.
-- A snapshot, because the write yields: a move landing between two statements
-- must not tear what is being written.
local function rowsOf(container)
	local rows = {}
	for slot, entry in pairs(container.items) do
		rows[#rows + 1] = { slot = slot, name = entry.name, count = entry.count,
			metadata = Common.Copy(entry.metadata) }
	end
	table.sort(rows, function(a, b) return a.slot < b.slot end)
	return rows
end

--- Writes a list of containers, re-marking every one of them when it fails.
-- The mark is lifted BEFORE the write: a change made while it is in flight
-- re-marks the container, which then goes out again rather than being counted as
-- written. On a failure the older of the two marks is kept, so the change that
-- failed stays the oldest unwritten one.
-- @author dop42
-- @param list table[] containers
-- @return boolean
-- @return string|nil
function Store.Write(list)
	local snapshots, ids = {}, {}
	for index = 1, #list do
		local container = list[index]
		if not container.transient and not saving[container.id] then
			snapshots[#snapshots + 1] = { id = container.id, rows = rowsOf(container) }
			ids[#ids + 1] = container.id
			saving[container.id] = true
		end
	end
	if #ids == 0 then return true, nil end

	local since = {}
	for index = 1, #ids do
		since[ids[index]] = dirty[ids[index]]
		dirty[ids[index]] = nil
	end

	local written = Store.Save(snapshots)

	for index = 1, #ids do
		local id = ids[index]
		saving[id] = nil
		if not written.ok and M.Containers.Get(id) then
			dirty[id] = math.min(dirty[id] or math.huge, since[id] or OPX.Now())
		end
	end

	if not written.ok then
		Open77.log.warn(('[inventory] writing %d container(s) failed: %s')
			:format(#ids, tostring(written.detail or written.error)))
		return false, written.error
	end

	for index = 1, #list do
		local container = list[index]
		if container.unloadWhenClean and not dirty[container.id] then
			CreateThread(function() M.Containers.Unload(container.id) end)
		end
	end
	return true, nil
end

--- Writes one container until it holds nothing unwritten, giving up after three
--- failures a second apart.
-- @author dop42
-- @param container table
-- @return boolean
function Store.SaveUntilClean(container)
	local failures = 0
	while true do
		local deadline = OPX.Now() + 35000
		while saving[container.id] and OPX.Now() < deadline do Wait(50) end
		if not dirty[container.id] then return true end
		local written = Store.Write({ container })
		if not written then
			failures = failures + 1
			if failures >= 3 then return false end
			Wait(1000)
		end
	end
end

--- Writes every container that has been quiet for the configured delay.
-- The delay is read here, at the moment of use: a tunable captured into a local
-- at load is frozen for the life of the resource.
-- @author dop42
function Store.Sweep()
	if OPX.BootError then return end

	local delayMs = OPX.Tune.Number('INVENTORY_SAVE_DELAY_MS', 0)
	local now = OPX.Now()
	local due = {}
	for id, since in pairs(dirty) do
		if not saving[id] and now - since >= delayMs then
			local container = M.Containers.Get(id)
			if container then due[#due + 1] = container else dirty[id] = nil end
		end
	end

	for first = 1, #due, Options.SAVE_BATCH do
		local batch = {}
		for index = first, math.min(first + Options.SAVE_BATCH - 1, #due) do
			batch[#batch + 1] = due[index]
		end
		-- A batch that failed because the database is not answering means the rest
		-- of the pass would fail the same way; the sweep stops and tries again.
		if not Store.Write(batch) then return end
	end
end

--- Dispatches one write per unwritten container, for the stop path.
-- One thread each and never one loop: a single loop would send the first
-- transaction, suspend, and never be resumed. Best effort, and the caller says so.
-- @author dop42
-- @return integer how many writes were dispatched
function Store.FlushAll()
	local dispatched = 0
	for id in pairs(dirty) do
		local container = M.Containers.Get(id)
		if container and not container.transient then
			dispatched = dispatched + 1
			CreateThread(function() Store.Write({ container }) end)
		end
	end
	return dispatched
end
