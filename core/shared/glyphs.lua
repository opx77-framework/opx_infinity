--- The one glyph vocabulary. Every surface that draws a picture draws from here.
-- @author dop42
--
-- ONE TABLE BECAUSE THE INSTRUCTION TO KEEP FOUR IN STEP BY HAND FAILED, and it
-- failed in every direction at once. `modules/target/shared/model.lua`, `M.ICONS`
-- in `modules/menu/module.lua` and `OPX.Toast.ICONS` in `core/client/notify.lua`
-- each carried their own copy under a comment telling the next author to change
-- all of them in the same change. What was actually on disk was 47 names, 45
-- names and 14 -- three different answers to "what may a row show", none of them
-- the page's, and no test looking.
--
-- WHAT THE 14 WERE is the useful part of the story: they are exactly the first
-- band below, the target eye's original vocabulary. When the second band was
-- added -- so a menu of thirty rows would stop saying `tool` thirty times -- it
-- reached the page, `Model.ICONS` and `menu.M.ICONS`, and never reached the
-- toast. Nothing broke, because no caller in this resource passes a toast an
-- icon; the drift was a trap set for whoever first did.
--
-- THE SET IS THE PAGE'S SET, and that direction matters. A name here that the
-- page has no path for is a promise Lua cannot keep: the row validates, reaches
-- the DOM, and draws `interact` or nothing. So this list is generated from what
-- `ui/src/modules/target/glyphs.ts` can actually draw, and `tests/` reads both
-- files and holds them together -- the one seam no shared file can close, since
-- a `.ts` file is not loadable from Lua.
--
-- Two names were dropped getting here. `inside` and `named` were in
-- `Model.ICONS` alone, had no path on the page, and were passed by nobody;
-- `named` is a ped-FAMILY key from `modules/admin/data/peds.lua` that appears to
-- have been copied into a glyph set by mistake.
--
-- IT IS A SET OF DOMAINS, NOT OF VERDICTS. There is no tick in it and no
-- exclamation mark, which is why no toast kind has a default glyph: a default
-- would have to draw a padlock on `error.tooFast`. A kind reaches the player as
-- the frame and the tone; a glyph that guessed would be the one thing on the
-- surface saying something untrue.
--
-- SHARED, not client-only: `Model.Definition` validates a target row's icon and
-- runs on both halves, so the server must refuse the same names the client does.

OPX.Glyphs = {
	-- THE FIRST BAND: the target eye's own vocabulary, in the order the page
	-- declares it. These fourteen were the whole set for as long as the only
	-- thing drawing a glyph was a row under the crosshair.
	interact = true, person = true, vehicle = true, info = true, lock = true,
	tool = true, location = true, box = true, door = true, heal = true,
	money = true, talk = true, folder = true, back = true,

	-- THE SECOND BAND, added so every row of every list can say what it is. With
	-- the first fourteen alone a staff screen drew `tool` fourteen times, which
	-- reads as no picture at all. Same rules as above: 24x24, stroke only, no
	-- fill, no colour of their own. The groupings are the menu's, kept because
	-- they are how an author finds the name they want.
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
