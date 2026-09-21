--- The timed-action bar: how long one may run, and whether it holds the player.
-- @author dop42
--
-- WHICH LEVERS A LOCK PULLS IS NOT HERE, and that is deliberate. `M.LOCKED` in
-- `modules/progress/module.lua` names the two input actions a bar takes away --
-- `Movement` and `Attack`, out of the platform's five-word vocabulary -- and it
-- is not a preference: a bar that let the player walk away from the thing they
-- are doing would not be holding them to it. What an operator decides here is
-- whether a bar holds at all, and the bounds a caller's duration must fall in.

OPX.Config.MODULES.progress = {
	enabled = true,

	-- Whether a bar takes the player's movement while it is up.
	--
	-- FALSE IS A REAL CHOICE AND NOT A BROKEN ONE: the bar still counts, still
	-- draws and still answers, and the player can walk out of it. A server that
	-- would rather not freeze anybody turns this off and loses only the holding.
	LOCK = true,

	-- The shortest and longest a caller may ask for, in milliseconds.
	--
	-- The floor is there because a bar shorter than a quarter of a second is a
	-- flash nobody reads, and the ceiling because a caller that asks for ten
	-- minutes has almost certainly passed seconds where milliseconds were
	-- wanted -- and a ten-minute lock on a player's movement is the kind of
	-- mistake that ends a session rather than a request.
	MIN_MS = 250,
	MAX_MS = 60000,
}
