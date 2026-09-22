--- Where a floating surface sits on the screen, as one vocabulary.
-- @author dop42
--
-- THE OWNER ASKED WHETHER THE UI CONFIGURATION COULD GO FURTHER FOR SERVER
-- OWNERS, and measuring it first is what produced this file. Eight config
-- blocks expose an `ANCHOR`. They do not agree:
--
--   `modules/menu`     accepts top-left, top-right, left, right, center
--                      -- and no bottom position at all
--   `modules/prompts`  accepts the four corners -- and no centre at all
--   `config/hud`       is written with bottom-center and top-center
--   `config/form`      is written with center
--
-- So an operator who reads one config block and writes the same word in another
-- gets a surface in a corner they did not choose, silently, because each module
-- falls back to its own default for a name it does not know. That is not eight
-- copies of one rule -- it is three rules wearing the same name, which is worse,
-- because it looks consistent.
--
-- ONE SET, NAMED ONCE. Nine positions: four corners, three edge centres, and the
-- two vertical middles the menu already used. Every module that adopts this
-- accepts all of them, so the word means the same thing everywhere it appears.
--
-- WHAT THIS FILE DOES NOT DO is move anybody. Adopting it is a per-module change
-- with its own page-side CSS, and doing eight of those in one sweep is the shape
-- of change that has cost this project the most. `modules/calls` is the first
-- caller because its projection has no anchor today at all -- pure gain, nothing
-- migrated -- and the rest follow one at a time.

OPX = OPX or {}
OPX.Anchors = OPX.Anchors or {}

--- Every position a surface may be anchored to.
--
-- THE NAMES ARE THE PAGE'S TOO. Each maps to an `anchor-<name>` class, which is
-- why they are hyphenated lower case rather than a Lua-shaped identifier: a
-- vocabulary that needed translating at the seam would be two vocabularies
-- again, one of them invisible.
OPX.Anchors.ALL = {
	'top-left', 'top-center', 'top-right',
	'left', 'center', 'right',
	'bottom-left', 'bottom-center', 'bottom-right',
}

local KNOWN = {}
for _, name in ipairs(OPX.Anchors.ALL) do KNOWN[name] = true end

-- Whether a value is one of the nine. FILE-LOCAL: it is one table lookup, and a
-- published predicate with no caller outside this file is the kind of surface
-- this project's own suite refuses -- rightly, since the first version of this
-- file shipped two of them.
local function valid(value)
	return type(value) == 'string' and KNOWN[value] == true
end

--- Settles a configured anchor, naming a refusal rather than swallowing it.
---
--- A TYPO IS A SURFACE IN THE WRONG CORNER AND NOTHING ELSE, which is precisely
--- why it is said out loud. `'bottomleft'`, `'bottom left'` and `'botom-left'`
--- are each one keystroke from a real name and each one produces a screen the
--- operator did not ask for, with no error anywhere -- the same silence that
--- made `--op-downed-veil` look like a working knob for months.
---
--- The fallback is the CALLER'S default and never a global one: where a surface
--- belongs when nobody said is a decision about that surface.
-- @author dop42
-- @param value any what the config holds
-- @param fallback string the caller's own default, which must itself be valid
-- @param where string what to name in the journal, e.g. 'calls.ANCHOR'
-- @return string one of `OPX.Anchors.ALL`
function OPX.Anchors.Resolve(value, fallback, where)
	if valid(value) then return value end

	-- A caller passing a fallback that is not itself one of the nine is a bug in
	-- the caller, not a configuration fault, so it is loud and lands on the
	-- centre rather than on whatever the caller meant.
	local safe = valid(fallback) and fallback or 'center'

	if value ~= nil then
		Open77.log.warn(('[anchors] %s is not a position: %q. Using %q. One of: %s')
			:format(tostring(where), tostring(value), safe,
				table.concat(OPX.Anchors.ALL, ', ')))
	end
	return safe
end

