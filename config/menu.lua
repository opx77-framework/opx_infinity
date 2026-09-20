--- Where the strip sits, how much of it is drawn, and who opens one while down.
-- @author dop42
--
-- THESE ARE THE DEFAULTS, NOT THE RULE. A caller may name its own geometry in the
-- `Open` spec -- `anchor`, `width`, `maxHeight` and `rows` -- and these four values
-- are what a caller that names nothing is given. That is how a dealer's stock list
-- is a large centred panel while every other menu stays the strip it was: the size
-- belongs to the menu that needs it, not to the module every menu shares. Out of
-- range values are clamped (240..1200 px wide, 20..100 vh tall, 3..24 rows).
--
-- VISIBLE_ROWS is not a taste: only the window of rows ever crosses to the page,
-- because the host drops an event carrying more than 1024 value nodes and does
-- so in silence. A hundred-row level sent whole would simply never arrive.

OPX.Config.MODULES.menu = {
	enabled = true,

	-- top-left, top-right, left, right or center. Anything else reads as top-left.
	-- A caller may name any of the five per open; `center` is the one that is not
	-- hinged on an edge, so a centred menu draws flat and its chosen row steps
	-- straight out rather than away from a hinge.
	ANCHOR = 'top-left',
	WIDTH = 340,
	MAX_HEIGHT_VH = 56,

	VISIBLE_ROWS = 9,

	-- Milliseconds the status line stays up before it clears itself.
	STATUS_MS = 6000,

	-- Owners whose menu opens, and stays open, while the player is down.
	WHILE_DOWN = { admin = true },
}
