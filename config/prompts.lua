--- Where the key strip sits, how much of it is drawn, and what takes it down.
-- @author dop42
--
-- The ceilings are the page's own, repeated here because the strip is bounded by
-- the screen it sits on and not by what a caller asks for: `MAX_ROWS` is one
-- budget across every group, so eight groups of eight rows is a wall rather than
-- a hint. The page repeats them again rather than trusting its sender.

OPX.Config.MODULES.prompts = {
	enabled = true,

	-- bottom-right, bottom-left, top-right or top-left.
	ANCHOR = 'bottom-right',
	-- Pixels above the anchored edge's inset, 0..540 on the 1080-high surface.
	OFFSET = 0,
	-- Widest a row grows, 200..960 pixels at 1920 wide.
	MAX_WIDTH = 420,
	-- Rows drawn at once across every group, 1..24.
	MAX_ROWS = 10,

	-- Step aside while the chat box, a form or the pause menu has the keyboard,
	-- and while the player has turned the HUD off.
	HIDE_WHEN_CAPTURED = true,
	FOLLOW_HUD = true,

	-- Milliseconds between two passes, and between two checks of every owner
	-- against the runtime. A pass over an empty store answers at once.
	TICK_MS = 150,
	OWNER_SWEEP_MS = 1000,
}
