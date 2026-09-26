--- Config reads, coercions and the marker look, for the headquarters spots.
-- @author XEROX710
--
-- WHAT A SPOT IS IS NOT HERE. The record, the coordinate box and the marker
-- resolution are `lib/shared/spots.lua`, shared with `garages`, `dealership`,
-- `clothing`, `teleports` and `elevators` -- five modules that all agree on
-- what a placed point is because none of them owns a copy of it. This file
-- only names this module's own words to that vocabulary: its noun, its one
-- marker look and its own distances.
--
-- A HEADQUARTERS SPOT HAS NO KIND AND NO HEADING, and both absences are
-- decisions. There is one kind of station; and nothing is created at a
-- headquarters, so no facing is ever read. `lib/shared/spots.lua` spells a
-- field nothing turns as a field a later author wires up by mistake, which is
-- why the spec below asks for neither.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN or a radius outside the engine's range reads as a boot warning rather
-- than a raise inside a scan or a network handler.

local M = OPX.Modules.Get('headquarters')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a millisecond clock is measured
-- with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite

-- The world box and its two coercions, in `lib/shared/spots.lua`. Kept as names
-- on `Access` because the whole module reads spot rules through `Access` and a
-- caller should not have to know which of them is shared.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer

--- The largest allowed key, and the words the refusals speak in.
Access.MAX_KEY = 48

local SPEC = {
	noun = 'headquarters',
	maxKey = Access.MAX_KEY,
}

--- Normalises one config row, in the operator's upper-case spelling.
-- @param key string
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
Access.FromDefinition = function(key, raw)
	return OPX.Spots.FromDefinition(SPEC, key, raw)
end

--- Normalises one point off the wire, in the shape `Access.Serialise` writes.
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
Access.FromWire = function(raw)
	return OPX.Spots.FromWire(SPEC, raw)
end

--- The fields of one point, as the wire and the SYNC event carry them.
-- @param spot table
-- @return table
Access.Serialise = OPX.Spots.Serialise

--- Builds a key -> spot table from a block of definitions.
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	return OPX.Spots.Coerce(SPEC, definitions, problems)
end

--- Answers one spot by key, or nil.
Access.Spot = OPX.Spots.Spot

--- Every spot in a bucket, sorted by key.
Access.InBucket = OPX.Spots.InBucket

--- Squared horizontal distance from a point to a spot's declared position.
Access.FlatDistanceSquared = OPX.Spots.FlatDistanceSquared

-- What the marker falls back to when the operator named nothing usable: the
-- same ring an AV pad wears, because a headquarters is where the pads are.
local FALLBACK = { shape = 'ring', style = 'objective', RADIUS = 3.0 }

--- The marker a headquarters is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the
-- look above is this module's own choice and stays here.
-- @return table shape, style, radius, lift
function Access.Marker()
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[M.SLOT.HQ] or nil
	return OPX.Spots.Marker(declared, FALLBACK, Config.GROUND_OFFSET)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 150.0)
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise inside a
-- scan.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)

--- The one glyph the name row carries, or nil when the config named nothing a
-- prompts row may hold.
--
-- The prompts contract draws no row without a key cap, so a headquarters row
-- carries one LITERAL cap -- see the header of `config/headquarters.lua`. A
-- value holding a space is not one literal but several, which is still legal
-- (`addKeys` splits on spaces) but is two caps wearing one name's clothes; a
-- control character is refused by that same rule. Neither is repaired here:
-- the row is drawn with no cap refused and the fault reported by `Problems`.
local KEYCAP = type(Config.KEYCAP) == 'string' and Config.KEYCAP or nil
if KEYCAP ~= nil and (KEYCAP == '' or #KEYCAP > 8 or KEYCAP:find('%c')) then KEYCAP = nil end
Access.KEYCAP = KEYCAP

--- Answers the spot a point stands on, or nil. The nearest wins; at equal
-- distance the key decides, so `pairs` order never chooses between two markers
-- a metre apart.
-- @param spots table
-- @param x number|nil
-- @param y number|nil
-- @return table|nil
-- @return number|nil squared distance
function Access.Nearest(spots, x, y)
	return OPX.Spots.Nearest(spots, x, y, Access.USE_RADIUS_SQ)
end

-- ── the map pin ─────────────────────────────────────────────────────────────

-- Whether a string is usable as a custom blip icon: a resource-relative .svg
-- path, which is the only thing the platform compiles (`blip_icon_requires_svg`
-- refuses PNG and friends by name). The engine refuses an absolute path or an
-- undeclared file in turn; the shape is checked here so the refusal lands at
-- boot, naming the row, instead of as a pin that is simply absent.
local function svgPath(value)
	return type(value) == 'string' and value ~= '' and value:lower():match('%.svg$') ~= nil
end

-- Whether a value is the platform's own colour spelling: exactly #RRGGBB or
-- #RRGGBBAA, never a name and never a palette id.
local function hexColor(value)
	return type(value) == 'string'
		and (value:match('^#%x%x%x%x%x%x$') ~= nil or value:match('^#%x%x%x%x%x%x%x%x$') ~= nil)
end

--- Resolves one station's BLIP block, appending any faults to `problems`.
--
-- THE PIN IS THE STATION'S OWN CHOICE. A headquarters designates where the
-- station is; the marker says so to whoever walks past it, and the map pin
-- says so to whoever is reading the map from the other side of the city. Not
-- every server wants every station on a public map, so a station is pinned
-- only when its own row asks:
--
--   BLIP = true                                          -- the category defaults
--   BLIP = { SPRITE = 'objective', COLOR = '#FFCC00' }   -- its own look
--   BLIP = { ICON = { ASSET = 'assets/blips/hq.svg', SIZE = 56 } }
--
-- PER FIELD AND NOT AS A BLOCK, the way `OPX.Spots.Marker` resolves a marker:
-- a good colour with a bad sprite keeps the colour and falls back to the
-- category's sprite. A value that cannot be honoured is DROPPED here rather
-- than sent to the engine, where the refusal would cost the whole pin; the
-- dropped value is named by `Problems` instead.
--
-- THE LOOK IS READ FROM THE CONFIG AND NEVER FROM THE WIRE. A capture is a
-- position and a name -- the answer's config line is the permanent record --
-- and a station whose key is in this file is pinned whether the row under that
-- key came from the file or from the database. A captured key with no config
-- row is deliberately unpinned: the pin is declared in `config/headquarters.lua`,
-- the one place an operator can read what the map will show.
-- @param key string
-- @param problems table|nil collector, appended to
-- @return table|nil nil when the station declares no pin; otherwise
--   { sprite, icon, color }, each nil where the block declared nothing usable
local function blipOf(key, problems)
	local rows = type(Config.HEADQUARTERS) == 'table' and Config.HEADQUARTERS or nil
	local raw = rows ~= nil and rows[key] or nil
	if type(raw) ~= 'table' then return nil end
	local declared = raw.BLIP
	if declared == nil then return nil end
	local where = ('HEADQUARTERS.%s.BLIP'):format(tostring(key))
	if declared == true then return {} end
	if type(declared) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = where .. ' must be true or a table of SPRITE, ICON and COLOR'
		end
		return nil
	end

	local look = {}

	-- A sprite is an alias, a 2.31 variant name, or a whole number: the same
	-- vocabulary `config/blips.lua`'s categories speak, and the engine refuses
	-- an unknown one in turn. NOT bounds-checked here on purpose -- the set is
	-- the engine's, not this file's, and a second opinion about 146 would go
	-- stale the first time the platform adds a variant.
	local sprite = declared.SPRITE
	if sprite ~= nil then
		local number = math.tointeger(sprite)
		if number ~= nil then
			look.sprite = number
		elseif type(sprite) == 'string' and sprite ~= '' then
			look.sprite = sprite
		elseif problems ~= nil then
			problems[#problems + 1] = where .. '.SPRITE must be a sprite name or a whole number'
		end
	end

	-- A custom icon is a resource-relative .svg path, optionally with its own
	-- size (16..128, which are the engine's own bounds on `icon.size`). It wins
	-- over the sprite visually, but the sprite stays as the fallback the engine
	-- draws when the SVG cannot be compiled.
	local icon = declared.ICON
	if icon ~= nil then
		if svgPath(icon) then
			look.icon = icon
		elseif type(icon) == 'table' then
			local size = icon.SIZE == nil and nil or math.tointeger(icon.SIZE)
			if svgPath(icon.ASSET) and (size == nil or (size >= 16 and size <= 128)) then
				look.icon = size ~= nil and { asset = icon.ASSET, size = size } or icon.ASSET
			elseif problems ~= nil then
				problems[#problems + 1] = where ..
					'.ICON must be a table of ASSET (a .svg path) and SIZE (16..128)'
			end
		elseif problems ~= nil then
			problems[#problems + 1] = where .. '.ICON must be a .svg path or a table of ASSET and SIZE'
		end
	end

	if declared.COLOR ~= nil then
		if hexColor(declared.COLOR) then
			look.color = declared.COLOR
		elseif problems ~= nil then
			problems[#problems + 1] = where .. '.COLOR must be #RRGGBB or #RRGGBBAA'
		end
	end

	return look
end

--- The look of one station's map pin, or nil when the station declares none.
-- Resolved on every read rather than held: the blips module re-reads this on
-- its own scan, and config is live, so a block fixed between two passes takes
-- effect on the next one.
-- @param key string
-- @return table|nil
function Access.BlipLook(key)
	return blipOf(key, nil)
end

--- The configured headquarters, already validated, under both of their names.
-- Read as empty rather than refused: every read is reachable from the contract.
--
-- BOTH NAMES, BECAUSE A HEADQUARTERS IS A SPOT. There is no second table: the
-- points a client draws and the places a config names are one set here, unlike
-- garages where a garage holds several points. `Access.SPOTS` is the name the
-- shared vocabulary speaks; `Access.HEADQUARTERS` is this module's own.
Access.HEADQUARTERS = Access.Coerce(Config.HEADQUARTERS, nil)
Access.SPOTS = Access.HEADQUARTERS

--- Lists every configuration error visible without a world, sorted.
-- @return string[]
function Access.Problems()
	local lines = {}

	if finiteNumber(Config.USE_RADIUS) == nil or Access.USE_RADIUS <= 0 then
		lines[#lines + 1] = 'USE_RADIUS must be a finite number above zero'
	end
	if Access.SCAN_MS <= 0 then
		lines[#lines + 1] = 'SCAN_MS must be a finite number above zero'
	end
	if Access.POLL_MS <= 0 then
		lines[#lines + 1] = 'POLL_MS must be a finite number above zero'
	end

	-- The draw distance and the ground offset are reported against the same
	-- bounds `Access.Marker` and `Access.MaxDistance` clamp to, because they
	-- are literally the same constants.
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)
	OPX.Spots.MarkerProblems(
		type(Config.MARKER) == 'table' and Config.MARKER[M.SLOT.HQ] or nil,
		'MARKER.' .. M.SLOT.HQ, lines)

	if KEYCAP == nil then
		lines[#lines + 1] = 'KEYCAP must be a short string of printable characters'
	end

	-- The spots are validated once at load; the errors are re-derived here so
	-- the diagnostic reports them rather than only the boot log. The BLIP
	-- blocks ride the same re-derivation for the same reason: a look the
	-- resolver dropped is a pin that is quietly wrong, and a name it never
	-- dropped is a fault this diagnostic is the only place to say.
	if type(Config.HEADQUARTERS) == 'table' then
		for key in pairs(Config.HEADQUARTERS) do
			blipOf(key, lines)
		end
	end
	Access.Coerce(Config.HEADQUARTERS, lines)

	table.sort(lines)
	return lines
end
