--- Every animation this module can ask the platform for.
-- @author dop42
--
-- Shared so both halves agree on what a name and a variant number mean. `NAME`
-- is the platform's own profile id and each clip the engine's own clip name;
-- the labels are not here, because a player reads `animations.name.<NAME>`.
--
-- `STEM` is the part every clip of an entry shares; each `VARIANTS` line is
-- appended to it and also renders the words shown beside "Variant n". The first
-- line is the default variant.

local M = OPX.Modules.Get('animations')

M.Catalogue = {}
local Catalogue = M.Catalogue

--- Categories in the order the picker draws them.
Catalogue.CATEGORIES = { 'gestures', 'social', 'emotions', 'relaxation', 'consumables',
	'interactions' }

--- The glyph each category is drawn with, and the one every emote in it falls
--- back to. A name outside `menu.M.ICONS` would REFUSE the whole picker screen
--- rather than lose one picture, so the fallback below is what an unknown name
--- lands on.
Catalogue.CATEGORY_ICONS = {
	gestures = 'emote',
	social = 'talk',
	emotions = 'heart',
	relaxation = 'heal',
	consumables = 'drink',
	interactions = 'interact',
}

-- The glyphs an entry's own ICON may name. A CLOSED set for the reason above,
-- and a short one: this is the handful a body doing something is drawn with,
-- not the whole vocabulary the menu knows.
local ENTRY_ICONS = { emote = true, talk = true, heart = true, heal = true, drink = true,
	food = true, smoke = true, interact = true, info = true, eye = true, box = true,
	person = true, star = true }

-- Catalogue rows: profile name, category, clip stem and variant suffixes.
local ENTRIES = {
	{ NAME = 'handsup', CATEGORY = 'gestures', PLACEMENT = 'standing', WALK = 1,
		STEM = 'stand__2h_up__03__',
		VARIANTS = { 'look_around__01', 'look_left__01', 'look_right__01', 'shuffle__01' } },
	{ NAME = 'clap', CATEGORY = 'gestures', PLACEMENT = 'standing',
		STEM = 'stand__2h_on_sides__01__2h_clap__',
		VARIANTS = { 'happy__01', 'broad__01', 'narrow__01' } },

	{ NAME = 'dance', CATEGORY = 'social', PLACEMENT = 'standing', ICON = 'emote',
		STEM = 'stand__dance__02__',
		VARIANTS = { 'dancing__02', 'dancing__03', 'dancing__04', 'dancing__05', 'dancing__07',
			'dancing__08' } },
	{ NAME = 'phone', CATEGORY = 'social', PLACEMENT = 'standing', WALK = 1.4, PROP = 'phone', ICON = 'talk',
		STEM = 'stand__2h_phone__03__',
		VARIANTS = { 'tap_phone__01', 'shuffle__01' } },

	{ NAME = 'cry', CATEGORY = 'emotions', PLACEMENT = 'standing', WALK = 1.2,
		STEM = 'stand__rh_on_forehead__01__',
		VARIANTS = { 'cry__01', 'cry__02', 'rub_tears__01', 'blow_nose__02' } },
	{ NAME = 'think', CATEGORY = 'emotions', PLACEMENT = 'standing', WALK = 1.4, ICON = 'info',
		STEM = 'stand__rh_on_chin__01__',
		-- The space in 'rub_forehead__ 01' is in the platform's clip name, not a
		-- typo; it is also why Common.Text accepts a space.
		VARIANTS = { 'rub_chin__01', 'rub_forehead__ 01', 'shuffle__01', 'shuffle__02' } },

	{ NAME = 'sit', CATEGORY = 'relaxation', PLACEMENT = 'ground',
		STEM = 'sit_ground__2h_elbow_on_knees__01__',
		VARIANTS = { 'shuffle__01', 'shuffle__02', 'shuffle__03', 'shuffle__04' } },
	{ NAME = 'meditate', CATEGORY = 'relaxation', PLACEMENT = 'standing',
		STEM = 'stand__meditate__01__',
		VARIANTS = { 'breathe__01', 'breathe__02', 'raise_hands__01', 'look_left__01',
			'shuffle__01' } },
	{ NAME = 'stretch', CATEGORY = 'relaxation', PLACEMENT = 'standing',
		STEM = 'stand__2h_on_sides__01__',
		VARIANTS = { 'stretch_arms__01', 'stretch_arms__02', 'stretch_arms__03', 'stretch_arms__04',
			'stretch_neck__01', 'stretch_muscle_01', 'stretch_muscle_02', 'stretch_muscle_03',
			'stretch_muscle_04', 'stretch_muscle_05', 'stretch_muscle_06', 'stretch_muscle_07',
			'stretch_muscle_08', 'stretch_muscle_09', 'stretch_muscle_10' } },

	{ NAME = 'smoke', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.3, PROP = 'cigarette',
		ICON = 'smoke',
		STEM = 'stand__rh_cigarette__01__',
		VARIANTS = { 'smoke__01', 'smoke__02', 'smoke__03', 'drop_ash__01', 'drop_ash__04',
			'look_around__01', 'look_around__02', 'shuffle__01', 'shuffle__02', 'shuffle__04',
			'wipe_forehead__01' } },
	{ NAME = 'cigar', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.3, PROP = 'cigar', ICON = 'smoke',
		STEM = 'stand__rh_cigar__weight_right__01__',
		VARIANTS = { 'smoke__01', 'smoke__02', 'smoke__03', 'look_left__01', 'scratch_nose__01',
			'scratch_ball__01' } },
	{ NAME = 'drink', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.2, PROP = 'can', ICON = 'drink',
		STEM = 'stand__rh_can__01__',
		VARIANTS = { 'drink__01', 'drink__03', 'drink__04', 'shuffle__01', 'spill__01',
			'spill__02' } },

	{ NAME = 'give', CATEGORY = 'interactions', PLACEMENT = 'standing', ICON = 'box',
		STEM = 'stand__2h_on_sides__01__to__stand__rh_item__01__',
		VARIANTS = { 'turn0__01' } },
	{ NAME = 'examine', CATEGORY = 'interactions', PLACEMENT = 'ground', ICON = 'eye',
		STEM = 'kneel__rk_on_ground__01__',
		VARIANTS = { 'inspect_ground__01' } },
	{ NAME = 'wounded', CATEGORY = 'interactions', PLACEMENT = 'ground', ICON = 'heal',
		STEM = 'sit_ground_lean180__rh_on_belly__01__',
		VARIANTS = { 'deep_breath__01' } },
}

-- The wire bounds a profile id at 64 bytes and a clip name at 128.
local MAX_NAME, MAX_CLIP = 64, 128

local isCategory = {}
for index = 1, #Catalogue.CATEGORIES do isCategory[Catalogue.CATEGORIES[index]] = true end

-- Reduces a clip suffix to the words shown beside a variant:
-- 'rub_forehead__ 01' reads 'rub forehead 1'.
local function words(suffix)
	local spoken = suffix:gsub('[_%s]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
	spoken = spoken:gsub('%f[%d]0+(%d)', '%1')
	return spoken
end

-- Entries by name and in picker order, built once. A malformed row is dropped
-- rather than raised on: this file loads on every client.
local byName, ordered = {}, {}
for index = 1, #ENTRIES do
	local row = ENTRIES[index]
	local name, stem = row.NAME, row.STEM
	if type(name) == 'string' and #name <= MAX_NAME and name:match('^[%l%d_]+$') and
		isCategory[row.CATEGORY] and type(stem) == 'string' and type(row.VARIANTS) == 'table' and
		byName[name] == nil then
		local entry = {
			name = name,
			category = row.CATEGORY,
			-- The entry's own glyph where it has one worth having -- a cigarette
			-- for `smoke`, a can for `drink` -- and its category's otherwise, so
			-- that a row in a flat search result still says which family it came
			-- from. Never nil: a row with no glyph leaves a hole in a column the
			-- strip holds open either way.
			icon = (ENTRY_ICONS[row.ICON] and row.ICON)
				or Catalogue.CATEGORY_ICONS[row.CATEGORY] or 'emote',
			prop = row.PROP,
			placement = row.PLACEMENT or 'standing',
			-- Metres per second this emote may be walked at, or nil for one that
			-- holds the player still. See `client/walk.lua` for what the number
			-- actually buys: `Open77.movement.setWalkMode` is a LEASE on the
			-- player's body, not a property of the animation, and there is no
			-- `canWalk` anywhere in the platform.
			--
			-- ONLY A STANDING POSE MAY CARRY ONE, and the rule is enforced rather
			-- than trusted. `sit`, `examine` and `wounded` are authored against
			-- the ground: walking out of one does not produce a player strolling
			-- while seated, it produces a body sliding across the pavement in a
			-- pose that no longer means anything. A `WALK` on such a row is a
			-- config mistake and is dropped, not honoured.
			walk = nil,
			clips = {},
			words = {},
			variantOf = {},
		}
		-- Bounded to what `setWalkMode` accepts (0.5 to 2.5 m/s). Out of range is
		-- dropped here rather than refused once a second by the native, which
		-- would be a fault nobody sees: the emote would simply never walk and no
		-- line anywhere would say why.
		local wanted = tonumber(row.WALK)
		if wanted ~= nil and entry.placement == 'standing'
			and wanted >= 0.5 and wanted <= 2.5 then
			entry.walk = wanted
		end

		for position = 1, #row.VARIANTS do
			local suffix = row.VARIANTS[position]
			local clip = type(suffix) == 'string' and stem .. suffix or nil
			if clip ~= nil and #clip <= MAX_CLIP and entry.variantOf[clip] == nil then
				local at = #entry.clips + 1
				entry.clips[at] = clip
				entry.words[at] = words(suffix)
				entry.variantOf[clip] = at
			end
		end
		if #entry.clips > 0 then
			byName[name] = entry
			ordered[#ordered + 1] = entry
		end
	end
end

--- Answers one entry by its name, without case, or nil.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalogue.Entry(name)
	if type(name) ~= 'string' then return nil end
	return byName[name:lower()]
end

--- Answers every entry, in category order then as written.
-- @author dop42
-- @return table[]
function Catalogue.Entries()
	return ordered
end

--- Whether a value names a category, without case.
-- @author dop42
-- @param name any
-- @return boolean
function Catalogue.IsCategory(name)
	return type(name) == 'string' and isCategory[name:lower()] == true
end

--- Answers which variant of an entry a clip is, or nil.
-- @author dop42
-- @param name any
-- @param clip any
-- @return integer|nil
function Catalogue.VariantOf(name, clip)
	local entry = Catalogue.Entry(name)
	if entry == nil or type(clip) ~= 'string' then return nil end
	return entry.variantOf[clip]
end
