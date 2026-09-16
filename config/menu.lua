--- Where the strip sits, how much of it is drawn, and who opens one while down.
-- @author dop42
--
-- VISIBLE_ROWS is not a taste: only the window of rows ever crosses to the page,
-- because the host drops an event carrying more than 1024 value nodes and does
-- so in silence. A hundred-row level sent whole would simply never arrive.

OPX.Config.MODULES.menu = {
	enabled = true,

	-- top-left, top-right, left or right. Anything else reads as top-left.
	ANCHOR = 'top-left',
	WIDTH = 340,
	MAX_HEIGHT_VH = 56,

	VISIBLE_ROWS = 9,

	-- Milliseconds the status line stays up before it clears itself.
	STATUS_MS = 6000,

	-- Owners whose menu opens, and stays open, while the player is down.
	WHILE_DOWN = { admin = true },
}
