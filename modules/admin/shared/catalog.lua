--- The index over the vehicle allowlist, read by both halves.
-- @author dop42
--
-- VEHICLES ARE NOT INDEXED HERE. The host checks a script's load time every
-- 10,000 VM instructions and cancels the whole resource set when a check falls
-- past its deadline, so no single file may index them all: this file only reads
-- the classes, and each `shared/catalog-<n>.lua` indexes `PART` of the rows. The
-- last part calls `FinishVehicles`, which indexes whatever is left and says so
-- when that is more than one part's worth. A missing part costs load time, never
-- a vehicle.
--
-- The source resource indexed WEAPON classes here too, from a data file of its
-- own. That file is gone: the class of a weapon came from the inventory's
-- catalogue, and the `inventory` contract does not publish one. See the module
-- header.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

--- Malformed data rows, one English line each, logged by the server at start.
M.Problems = M.Problems or {}

M.Catalog = {}
local Catalog = M.Catalog

--- Vehicle rows one `shared/catalog-<n>.lua` part indexes.
Catalog.PART = 68

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

-- The classes in menu order, by key, and the two row lookups.
local classes, classIndex = {}, {}
local byName, byRecord = {}, {}

-- The raw rows the parts index, and the next one to take.
local rows, nextRow = {}, 1

do
	local source = (M.Data or {}).VEHICLES
	if type(source) ~= 'table' or type(source.CLASSES) ~= 'table' then
		problem('data/vehicles.lua: CLASSES must be a table')
	else
		for position, row in ipairs(source.CLASSES) do
			local key = type(row) == 'table' and Text.Slug(row.KEY) or nil
			if key == nil or classIndex[key] ~= nil then
				problem(('data/vehicles.lua: class #%d needs a unique KEY'):format(position))
			else
				local class = { key = key, label = M.Trimmed(row.LABEL, 48) or key, members = {} }
				classes[#classes + 1] = class
				classIndex[key] = class
			end
		end
		if type(source.VEHICLES) == 'table' then
			rows = source.VEHICLES
		else
			problem('data/vehicles.lua: VEHICLES must be a table')
		end
	end
end

-- The AV prefixes, lower-cased, read once from the config.
local avPrefixes

--- Whether a record is an AV, by the one rule: `VEHICLES.AV_PREFIXES`.
-- The same rule the garages module, the dealership and the platform's own
-- gamemodes use, so a record is in the air category everywhere or nowhere. The
-- catalogue marks the row with the answer, and no row declares its own category:
-- one owner, and a row cannot disagree with itself.
-- @author dop42
-- @param record string
-- @return boolean
local function isAir(record)
	if avPrefixes == nil then
		avPrefixes = {}
		for _, prefix in ipairs(M.Section('VEHICLES').AV_PREFIXES or {}) do
			if type(prefix) == 'string' and prefix ~= '' then
				avPrefixes[#avPrefixes + 1] = prefix:lower()
			end
		end
	end
	local lowered = record:lower()
	for index = 1, #avPrefixes do
		local prefix = avPrefixes[index]
		if lowered:sub(1, #prefix) == prefix then return true end
	end
	return false
end

--- Indexes the next `count` rows into their classes and both lookups.
-- @author dop42
-- @param count integer
function Catalog.IndexVehicles(count)
	local last = math.min(#rows, nextRow + count - 1)
	for position = nextRow, last do
		local row = rows[position]
		local name = type(row) == 'table' and Text.Slug(row.NAME) or nil
		local record = type(row) == 'table' and type(row.RECORD) == 'string'
			and row.RECORD:match('^[%w_%.]+$') and row.RECORD or nil
		local class = type(row) == 'table' and classIndex[tostring(row.CLASS or '')] or nil
		local lowered = record and record:lower()
		local wrong = name == nil and 'NAME must be 1..32 letters, digits, _ or -'
			or record == nil and 'RECORD must be a TweakDB record name'
			or class == nil and 'CLASS is not a KEY in CLASSES'
			or (byName[name] ~= nil or byRecord[lowered] ~= nil) and 'NAME or RECORD is declared twice'
			or nil
		if wrong then
			problem(('data/vehicles.lua: row #%d: %s'):format(position, wrong))
		else
			local entry = {
				name = name,
				label = M.Trimmed(row.LABEL, 48) or name,
				record = record,
				class = class.key,
				-- Derived from the record, never declared by the row (see `isAir`).
				av = isAir(record),
			}
			class.members[#class.members + 1] = entry
			byName[name] = entry
			byRecord[lowered] = entry
		end
	end
	nextRow = last + 1
end

--- Indexes every row left, naming an overloaded last part.
-- @author dop42
function Catalog.FinishVehicles()
	local left = #rows - nextRow + 1
	if left > Catalog.PART then
		problem(('data/vehicles.lua: %d rows were left to the last catalogue part; add a ' ..
			'modules/admin/shared/catalog-<n>.lua line to open77.lua for every %d rows past it')
			:format(left, Catalog.PART))
	end
	Catalog.IndexVehicles(left)
end

--- The classes in menu order, each with its indexed members.
-- @author dop42
-- @return table[]
function Catalog.Classes()
	return classes
end

--- A vehicle row by the name staff type or by its exact record, without case.
-- @author dop42
-- @param token any
-- @return table|nil
function Catalog.Vehicle(token)
	if type(token) ~= 'string' then return nil end
	local lowered = token:lower()
	return byName[lowered] or byRecord[lowered]
end
