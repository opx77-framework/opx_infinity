--- The keyboard-driven strip: one menu on screen, and the tree behind it.
-- @author dop42
--
-- A renderer and a model, split the way the resource this replaces split them.
-- Lua owns the navigation stack, the cursor, every value a row holds and the
-- window of rows that is drawn; the page draws that window and reports what the
-- player pressed or pointed at. Nothing the page sends is a fact.
--
-- ONE THING MOVED, and the move is why `client/input.lua` is not ported. The old
-- page was created on a layer that could never be focused, so Lua read the six
-- keys itself through `Open77.input.isDown` behind a 260 ms/55 ms repeat
-- machine. This surface takes focus, which makes the page the only thing that
-- can see a keystroke: it forwards each one as an intent and the browser's own
-- key repeat is the same edge detector, with `repeat` riding along so a press is
-- still tellable from a hold.
--
-- The surface is shared with four other views, so every payload in either
-- direction carries the handle this module minted. A payload naming a handle
-- that is not the open one is a late message about a menu that has already gone,
-- and is discarded rather than applied.

local M = OPX.Modules.Declare{
	id = 'menu',
	side = 'client',
	fatal = false,
	-- Not a requirement. With it, a menu does not open over a player who is
	-- down; without it the module simply never hears about it and opens.
	optional = { 'downed' },
}

local LOCAL = OPX.Channel.LOCAL

M.Event = {
	-- Raised beside the caller's own callback for every action on every menu,
	-- for anything that wants to watch the surface rather than own it. It must
	-- stay on the LOCAL channel: the host dispatcher matches on the name alone,
	-- so a local raise on a NET name would re-enter the wire handlers.
	ACTION = OPX.Event(LOCAL, 'menu', 'action'),
}

--- Names the host owns. Escape is swallowed by the plugin before any surface
--- sees it and arrives as this instead, so it cannot be renamed here.
M.Host = {
	PAUSE_KEY = 'open77:pauseKey',
}

--- The glyphs a row may carry, as a CLOSED set.
-- RECOPIED from `modules/target/shared/model.lua`, which validates the same
-- names for the same reason: the page selects a LOCAL path by this name, and an
-- unknown one would reach the DOM as an attribute nobody wrote. A module may not
-- read another module's namespace, so the two lists are kept in step by hand --
-- a name that drifts costs a row its icon, never a row.
--
-- The second band exists so that EVERY row can say what it is. With the first
-- fourteen alone a staff screen drew `tool` fourteen times, which reads as no
-- picture at all. Anything added here is added to `ui/src/modules/target/
-- glyphs.ts`, `Model.ICONS` and `Catalog.ICONS` in the same change.
M.ICONS = {
	interact = true, person = true, vehicle = true, info = true, lock = true,
	tool = true, location = true, box = true, door = true, heal = true,
	money = true, talk = true, folder = true, back = true,
	-- finding something in a long list
	search = true, filter = true, list = true, star = true,
	-- force, and the refusal of it
	weapon = true, ammo = true, shield = true, ban = true, warning = true,
	-- what is shown, and what is not
	eye = true, hidden = true, tag = true,
	-- the world, and the clock over it
	flag = true, map = true, world = true, clock = true, weather = true,
	-- machinery
	gear = true, refresh = true, bolt = true, server = true, key = true,
	-- going somewhere, and the plain arithmetic of a list
	arrow = true, plus = true, minus = true, trash = true,
	-- a body, and what it does with its hands
	heart = true, emote = true, food = true, drink = true, smoke = true,
}

--- How a menu takes input, as a CLOSED set.
-- `full` is the default and what every menu did before this existed: the page
-- takes the keyboard, so the arrows and Enter reach it and the player cannot
-- walk. `cursor` gives the page the MOUSE ONLY -- the game keeps the movement
-- keys, the player walks while the menu is up, and rows are chosen by clicking
-- them. `none` takes nothing: the menu is a readout.
--
-- The platform decides the pair; this only names it. `WebUI.Page.setFocus` takes
-- keyboard and cursor separately for exactly this reason.
M.FOCUS_MODES = {
	full   = { keyboard = true,  cursor = true  },
	cursor = { keyboard = false, cursor = true  },
	none   = { keyboard = false, cursor = false },
}
