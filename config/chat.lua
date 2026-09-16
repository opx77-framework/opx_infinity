--- Where the box sits, how much it keeps, and the two floors it applies.
-- @author dop42
--
-- Read by both halves: the caps are applied on the client for what a player can
-- type and on the server for what arrives, and the two must agree.

OPX.Config.MODULES.chat = {
	enabled = true,

	-- bottom-left or top-left; anything else reads as bottom-left.
	ANCHOR = 'bottom-left',

	-- Pixels above the anchored inset on a 1080-high surface, and the box width
	-- on a 1920-wide one.
	OFFSET = 155,
	WIDTH = 620,

	-- Lines kept on screen; older ones fall off the top.
	HISTORY = 60,

	-- Milliseconds a line stays visible while the box is closed; 0 never fades.
	FADE_MS = 12000,

	-- Longest message a player may send, in characters and not in bytes.
	MAX_LENGTH = 240,

	-- Milliseconds between two messages from one player.
	RATE_MS = 800,

	-- Milliseconds between two suggestion lists for one player. Anyone can ask
	-- and the answer is kilobytes, so it keeps a floor of its own.
	READY_MS = 5000,

	-- Refused commands as toasts; false puts a red line in the box instead.
	NOTIFY = true,
}
