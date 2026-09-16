--- Where the form sits, how wide it is, and who opens one while down.
-- @author dop42

OPX.Config.MODULES.form = {
	enabled = true,

	-- center, top-left, top-right, left or right. Anything else reads as center.
	ANCHOR = 'center',
	WIDTH = 420,

	-- Dim the scene behind an open form.
	DIM = true,

	-- Milliseconds the status line stays up before it clears itself.
	STATUS_MS = 6000,

	-- Owners whose form opens, and stays open, while the player is down.
	WHILE_DOWN = { admin = true },
}
