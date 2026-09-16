--- The face, the clothes, the join bootstrap and the looks other players are sent.
-- @author dop42
--
-- Read by both halves as `M.Settings`, so the two cannot disagree: the server
-- validates a stored face against `GAME_BUILDS` and the client refuses to apply
-- one from any other build, and both read the same table.
--
-- The deadlines below bound work that waits on the engine. There is deliberately
-- NO deadline on building a face once the editor is open: a player deliberating
-- for an hour leaves the readiness gate closed for an hour, and that is correct.

OPX.Config.MODULES.appearance = {
	enabled = true,

	-- The catalogue builds a stored face may be read back into. A snapshot is a
	-- list of positions in the customization catalogue, not a mesh, so it only
	-- means anything against the catalogue it was captured on: a face from any
	-- other build is refused rather than applied, because applying it would put a
	-- different face on the puppet instead of failing.
	GAME_BUILDS = { ['2.31'] = true },

	-- The largest encoded face and the largest encoded clothing record stored.
	-- Neither is a real limit on a correct client: they only catch a shape the
	-- checks above them should already have caught.
	MAX_JSON_BYTES = 49152,

	-- Hand every player's look -- body, equipment, outfit -- to everybody else and
	-- put theirs on here. The engine replicates the position and the vehicle, not
	-- the look, so a proxy nobody dresses is never drawn at all. False only when
	-- another resource hands looks out.
	PRESENT_BODIES = true,

	-- How long the server has to answer a captured face or a clothing save.
	COMMIT_MS = 20000,

	-- The server's own cooldown on the two save doors, waited out before a save
	-- goes out rather than tripped.
	SAVE_COOLDOWN_MS = 2000,

	CLOTHING = {
		-- Put the stored clothing on once the face has settled, and save changes.
		-- False leaves clothing to something else: nothing is put on, nothing saved.
		PERSIST = true,

		-- How long a clothing change has to hold before it is saved: a player
		-- trying three jackets saves the one they kept.
		SAVE_DEBOUNCE_MS = 2000,
	},

	-- Re-dispatches of a join-time restore the mirror aborted before confirming.
	RESTORE_RETRIES = 3,

	-- Body-family attempts per character: world reloads onto `charInfo.gender`,
	-- and creation editors reopened after coming back on the other body. Past it
	-- the player keeps the body they are on.
	FAMILY_RETRIES = 2,

	-- After a body reload's new puppet has been through its reset, how long a face
	-- or the creation editor may wait for the respawn the platform replays onto it
	-- to end. A life phase that reads `alive` sooner ends the wait sooner.
	BODY_RELOAD_SETTLE_MS = 10000,

	-- How long a character with no stored face waits for something to answer
	-- `needsCreation` before the player is let in on the default face. This module
	-- never opens the creator itself.
	CREATION_WAIT_MS = 15000,

	BOOTSTRAP = {
		-- How long the join waits for the character roster before loading
		-- DEFAULT_FAMILY. The platform's loading cover stays up until the character
		-- bootstrap is spent, so keep it short.
		ROSTER_WAIT_MS = 3000,

		-- 'female' or 'male': the body loaded for an account with no played
		-- character, or whose roster did not arrive in time. Anything else reads
		-- 'female', with one log line.
		DEFAULT_FAMILY = 'female',
	},

	WARDROBE = {
		-- Open the fitting room once a new character's face is stored.
		OPEN_AFTER_CREATION = true,

		-- How long a created character's starting clothes are waited for.
		CREATION_WAIT_MS = 60000,
	},
}
