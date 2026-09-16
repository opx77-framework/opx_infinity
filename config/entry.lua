--- The first screen: the stage, the roster retry and the two deadlines.
-- @author dop42
--
-- Nothing here is authoritative. Every rule the creation form applies is applied
-- again by the server, and a modified client skips this file entirely.

OPX.Config.MODULES.entry = {
	enabled = true,

	-- The camera on the player's own character while they choose, the mouse kept
	-- off it and the character held where it stands.
	STAGE = {
		-- false leaves the camera alone and the character free.
		ENABLED = true,
		-- -180..180, clamped: 180 faces the character, 0 stands behind it.
		ORBIT_DEGREES = 180,
		-- Keeps the native camera and turn restriction on (players.controls).
		LOCK_CAMERA = true,
		-- Holds the character in place; false lets it walk.
		FREEZE = true,
	},

	-- Milliseconds between two roster requests. The server DROPS a second request
	-- inside its own 2000 ms cooldown without answering it, so anything under the
	-- floor the module enforces (2500 ms) buys nothing; the margin covers the
	-- network between the two clocks.
	ROSTER_RETRY_MS = 3000,

	-- How long a selection, and a registration, may stay unanswered before the
	-- screen unlocks itself. Without them a lost answer leaves a player in front
	-- of a greyed screen with no way out. A value that is not a positive finite
	-- number turns the deadline off.
	SELECT_TIMEOUT_MS = 20000,
	CREATE_TIMEOUT_MS = 20000,

	-- Bounds on each half of a character name, in characters and not bytes. They
	-- MIRROR the character module's own bounds: this form repeats the server's
	-- rules, it does not replace them. A module may not read another module's
	-- settings, so the two are kept in step by hand; raising these past the
	-- server's only moves the refusal from the form to the server.
	NAME = { MIN = 2, MAX = 32 },
}
