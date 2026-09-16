--- The item catalogue both halves read, normalised once at load.
-- @author dop42
--
-- A malformed row is a boot warning and is left out, never an error raised in
-- the middle of a request. The name of an item is constrained because it is
-- stored in an `ascii_bin` column and typed into a command.
--
-- WEAPONS ARE NOT INDEXED HERE. The host checks a script's load time every 10,000
-- VM instructions and cancels the whole resource set when a check falls past its
-- deadline, so no single file may reach one. A weapon costs roughly 160
-- instructions: this file only queues their names, and each `shared/catalog-<n>.lua`
-- indexes `PART` of them. The last part calls `Finish`, which indexes whatever is
-- left and sorts every name. A missing part costs load time, never a weapon.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options

M.Catalog = {}
local Catalog = M.Catalog

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

--- Pattern an item name matches: stored in a column, typed in commands.
Catalog.NAME = '^[%w_%-%.]+$'

--- Longest item name in bytes. The column is VARCHAR(48).
Catalog.NAME_MAX = 48

--- Weapons one `shared/catalog-<n>.lua` part indexes.
Catalog.PART = 40

local DEFAULT_WEIGHT = Options.DEFAULT_ITEM_WEIGHT

-- Normalised entries by name, and every name, sorted once the last part runs.
local entries = {}
local names = {}

local function validName(name, where)
	if Common.Word(name, Catalog.NAME_MAX, Catalog.NAME) then return true end
	problem(('%s: %q is not a usable item name (letters, digits, _ - . up to %d)')
		:format(where, tostring(name), Catalog.NAME_MAX))
	return false
end

local function weightOf(name, raw, where)
	local weight = Common.Integer(raw.WEIGHT, 0, 1000000000)
	if weight == nil then
		problem(('%s %s: WEIGHT must be whole grams; using %d'):format(where, name, DEFAULT_WEIGHT))
		return DEFAULT_WEIGHT
	end
	return weight
end

--- A catalogue key or a piece of plain text, or nil.
local function textField(value)
	if type(value) ~= 'string' or value == '' or #value > 160 then return nil end
	return value
end

--- Normalises an item's USE table: how many units it spends, whether the screen
--- closes, what it moves and what it plays.
local function useOf(name, use, where)
	if use == nil then return nil end
	if type(use) ~= 'table' then
		problem(('%s %s: USE must be a table; not usable'):format(where, name))
		return nil
	end
	local out = {
		consume = Common.Integer(use.CONSUME == nil and 1 or use.CONSUME, 0, 1000000),
		close = use.CLOSE ~= false,
	}
	if out.consume == nil then
		problem(('%s %s: USE.CONSUME must be a whole number; using 1'):format(where, name))
		out.consume = 1
	end
	if type(use.STATUS) == 'table' then
		local status = {}
		for key, amount in pairs(use.STATUS) do
			local value = tonumber(amount)
			if type(key) == 'string' and OPX.Math.IsFinite(value) then
				status[key] = value
			else
				problem(('%s %s: USE.STATUS.%s is not a number'):format(where, name, tostring(key)))
			end
		end
		if next(status) ~= nil then out.status = status end
	end
	if type(use.ANIMATION) == 'table' and Common.Word(use.ANIMATION.NAME, 32, '^[%w_]+$') then
		out.animation = {
			name = use.ANIMATION.NAME,
			variant = Common.Integer(use.ANIMATION.VARIANT, 1, 64),
			durationMs = Common.Integer(use.ANIMATION.DURATION_MS, 1000, 600000),
		}
	elseif use.ANIMATION ~= nil then
		problem(('%s %s: USE.ANIMATION needs a NAME'):format(where, name))
	end
	return out
end

--- The prop a pile of this item is drawn with: a props alias or a .mesh path.
local function modelOf(name, value, where)
	if value == nil then return nil end
	local model = Common.Word(value, 256, '^[%w_%-%.\\/]+$')
	if model == nil or (model:find('[\\/]') and not model:lower():match('%.mesh$')) then
		problem(('%s %s: MODEL must be a prop alias or a .mesh path; the pile model is used')
			:format(where, name))
		return nil
	end
	return model
end

--- The fields every kind of catalogue entry shares.
local function base(name, raw, where)
	return {
		name = name,
		weight = weightOf(name, raw, where),
		stackable = raw.STACK ~= false,
		category = Common.Word(raw.CATEGORY, 32, '^[%w_]+$') or 'misc',
		label = textField(raw.LABEL),
		description = textField(raw.DESCRIPTION),
		image = Common.Word(raw.IMAGE, 64, '^[%w_%-%.]+$'),
		model = modelOf(name, raw.MODEL, where),
	}
end

--- Adds an entry, keeping the first of two carrying one name.
local function add(entry, where)
	if entries[entry.name] then
		problem(('%s: %s is declared twice; the first one is kept'):format(where, entry.name))
		return
	end
	entries[entry.name] = entry
	names[#names + 1] = entry.name
end

local data = M.Data or {}

local items = type(data.ITEMS) == 'table' and data.ITEMS or {}
if type(data.ITEMS) ~= 'table' then problem('data/items.lua declares no ITEMS') end
for name, raw in pairs(items) do
	if validName(name, 'data/items.lua') then
		if type(raw) ~= 'table' then
			problem(('data/items.lua %s: not a table'):format(name))
		else
			local entry = base(name, raw, 'data/items.lua')
			entry.use = useOf(name, raw.USE, 'data/items.lua')
			entry.usable = entry.use ~= nil
			add(entry, 'data/items.lua')
		end
	end
end

local weapons = type(data.WEAPONS) == 'table' and data.WEAPONS or {}
if type(data.WEAPONS) ~= 'table' then problem('data/weapons.lua declares no WEAPONS') end

-- Ammunition before the weapons, so a weapon class can be checked against the
-- ammunition it names rather than loading nothing at the moment it is drawn.
for name, raw in pairs(type(weapons.AMMO) == 'table' and weapons.AMMO or {}) do
	if validName(name, 'data/weapons.lua AMMO') then
		if type(raw) ~= 'table' then
			problem(('data/weapons.lua AMMO %s: not a table'):format(name))
		else
			local entry = base(name, raw, 'data/weapons.lua AMMO')
			entry.category = 'ammo'
			entry.stackable = true
			entry.usable = true
			local max = Common.Integer(raw.MAX, 1, 100000)
			entry.ammo = { max = max or 250 }
			if max == nil then
				problem(('data/weapons.lua AMMO %s: MAX must be a whole number; using 250')
					:format(name))
			end
			add(entry, 'data/weapons.lua AMMO')
		end
	end
end

local classes = type(weapons.CLASSES) == 'table' and weapons.CLASSES or {}
local weaponRows = type(weapons.WEAPONS) == 'table' and weapons.WEAPONS or {}

-- Weapon names left to index, in the order the parts take them. The order comes
-- from `pairs`, so which part carries a given weapon changes from one start to
-- the next -- of no consequence while the names are unique, which `add` enforces.
local queue = {}
for name in pairs(weaponRows) do queue[#queue + 1] = name end

local nextWeapon = 1

--- Indexes the next `count` weapons. Each part file calls this once.
-- @author dop42
-- @param count integer
function Catalog.IndexWeapons(count)
	local last = math.min(#queue, nextWeapon + count - 1)
	for position = nextWeapon, last do
		local name = queue[position]
		local raw = weaponRows[name]
		if validName(name, 'data/weapons.lua WEAPONS') and type(raw) == 'table' then
			local record = Common.Word(raw.RECORD, 256, '^Items%.[%w_%.]+$')
			local class = classes[raw.CLASS]
			if record == nil then
				problem(('data/weapons.lua %s: RECORD must be an Items.* TweakDB record; left out')
					:format(name))
			elseif type(class) ~= 'table' then
				problem(('data/weapons.lua %s: CLASS %q is not in CLASSES; left out')
					:format(name, tostring(raw.CLASS)))
			else
				local ammo = class.AMMO
				if ammo ~= nil and not (entries[ammo] and entries[ammo].ammo) then
					problem(('data/weapons.lua class %s names ammo %q, which AMMO does not ' ..
						'declare; %s loads nothing'):format(tostring(raw.CLASS), tostring(ammo), name))
					ammo = nil
				end
				local entry = base(name, raw, 'data/weapons.lua')
				entry.model = entry.model
					or modelOf(tostring(raw.CLASS), class.MODEL, 'data/weapons.lua class')
				entry.category = 'weapon'
				entry.stackable = false
				entry.usable = true
				entry.weapon = { record = record, class = raw.CLASS, ammo = ammo }
				add(entry, 'data/weapons.lua')
			end
		end
	end
	nextWeapon = last + 1
end

--- Indexes the weapons left over, then sorts every item name.
-- @author dop42
function Catalog.Finish()
	local left = #queue - nextWeapon + 1
	if left > Catalog.PART then
		problem(('data/weapons.lua: %d weapons were left to the last catalogue part; add a ' ..
			'shared/catalog-<n>.lua part to open77.lua for every %d weapons past it')
			:format(left, Catalog.PART))
	end
	Catalog.IndexWeapons(left)
	table.sort(names)
end

--- One catalogue entry by name, or nil.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalog.Get(name)
	if type(name) ~= 'string' then return nil end
	return entries[name]
end

--- Every item name, sorted.
-- @author dop42
-- @return string[]
function Catalog.Names()
	return names
end

--- The grams a count of an item weighs, defaulting for one the catalogue no
--- longer carries.
-- @author dop42
-- @param name string
-- @param count integer|nil
-- @return integer
function Catalog.WeightOf(name, count)
	local entry = entries[name]
	return (entry and entry.weight or DEFAULT_WEIGHT) * (count or 1)
end

--- The grams per unit of an item nothing knows about.
-- @author dop42
-- @return integer
function Catalog.DefaultWeight()
	return DEFAULT_WEIGHT
end

--- Resolves a field that may be a catalogue key, keeping it as text when it is
--- not one. The same rule serves an item's LABEL and a configured stash's.
-- @author dop42
-- @param value string|nil
-- @return string|nil
function Catalog.Rendered(value)
	if value == nil then return nil end
	if OPX.Locale.Exists(value) then return locale(value) end
	return value
end

--- An item's display name in the configured language.
-- @author dop42
-- @param name string
-- @return string
function Catalog.Label(name)
	local entry = entries[name]
	if entry and entry.label then return Catalog.Rendered(entry.label) end
	local key = 'inventory.item.' .. tostring(name)
	if OPX.Locale.Exists(key) then return locale(key) end
	return tostring(name)
end

--- An item's description in the configured language, or nil.
-- @author dop42
-- @param name string
-- @return string|nil
function Catalog.Description(name)
	local entry = entries[name]
	if entry and entry.description then return Catalog.Rendered(entry.description) end
	local key = 'inventory.item.' .. tostring(name) .. '.description'
	if OPX.Locale.Exists(key) then return locale(key) end
	return nil
end

--- One entry as the screen reads it, or nil.
-- Roughly sixty VM instructions: a client walking the whole catalogue does it in
-- parts and yields between them, which is why there is no read-it-all-at-once.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalog.ViewOf(name)
	local entry = type(name) == 'string' and entries[name] or nil
	if entry == nil then return nil end
	return {
		label = Catalog.Label(entry.name),
		description = Catalog.Description(entry.name),
		weight = entry.weight,
		image = entry.image,
		usable = entry.usable == true,
		stackable = entry.stackable,
		category = entry.category,
		weapon = entry.weapon ~= nil,
		ammo = entry.ammo ~= nil,
	}
end
