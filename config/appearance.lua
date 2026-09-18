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

	-- Body-family attempts per character: world reloads onto `charInfo.gender`.
	-- Past it the player keeps the body they are on. A CREATION spends none of
	-- these -- the game's own creator opens on the body choice, so there is no
	-- body to reload onto before it and nothing to disagree with afterwards.
	FAMILY_RETRIES = 2,

	-- After a body reload's new puppet has been through its reset, how long a face
	-- or the creation editor may wait for the respawn the platform replays onto it
	-- to end. A life phase that reads `alive` sooner ends the wait sooner.
	BODY_RELOAD_SETTLE_MS = 10000,

	-- How long a body reload may run before it is ended on the evidence of the
	-- world alone, rather than on the reset projection it normally waits for.
	--
	-- A reload is a COVERED world transition: the host puts the loading cover up
	-- for it and nothing takes it down, so the one call that lifts it is the end
	-- of this reload. Waiting for the reset projection with no deadline means a
	-- projection that never moves is a player left in front of an opaque cover
	-- for the rest of the session, with no way out and nothing on screen to say
	-- so. Past this, a puppet that is attached, alive and in the gameplay world is
	-- taken as the reload having landed.
	--
	-- Generous on purpose: this is the recovery, not the normal path, and ending
	-- a reload that is genuinely still running costs a face applied to a body
	-- about to be replaced. A value that is not a positive number turns the
	-- recovery off, which is the old behaviour.
	BODY_RELOAD_TIMEOUT_MS = 30000,

	-- How long a character with no stored face waits for something to answer
	-- `needsCreation` before the player is let in on the default face. This module
	-- never opens the creator itself.
	CREATION_WAIT_MS = 15000,

	BOOTSTRAP = {
		-- How long the join waits for SOMEBODY TO ASK for a character before it
		-- gives up and loads a body of its own choosing.
		--
		-- The bootstrap is the choice's to spend: it decides the body the world
		-- loads with, so a character picked before it is answered enters on its own
		-- body with no reload, and a character created before it is answered
		-- reaches the game's own creator, which exists only while it is open. The
		-- clock here only runs while NOTHING is on screen -- a screen that is up
		-- holds it for as long as the player takes.
		--
		-- Past it the old behaviour happens: the body below is loaded, a world
		-- comes up, and whatever draws the roster draws it in that world. That is
		-- one body reload worse per selection, and the mirror instead of the
		-- creator -- never a player stuck in front of a loading cover.
		CHOICE_WAIT_MS = 15000,

		-- The whole hold, whether a screen is up or not. The screen this waits for
		-- is drawn under the shell's loading cover and asks for that cover to come
		-- down; a screen that is up and NOT on the player's monitor would hold the
		-- bootstrap for the rest of the session, and a player cannot tell that from
		-- a frozen game. Past this the world comes up regardless, which is the
		-- fallback above. 0, or anything that is not a number, turns it off.
		CHOICE_CEILING_MS = 45000,

		-- 'female' or 'male': the body loaded for an account with no played
		-- character, or whose roster did not arrive in time. Anything else reads
		-- 'female', with one log line.
		--
		-- It is a body to stand in, not a body anybody is given: a character with
		-- no stored face is handed to the game's own creator, and the family it
		-- answers is what the character is written down as.
		DEFAULT_FAMILY = 'female',
	},

	WARDROBE = {
		-- Open the fitting room once a new character's face is stored.
		OPEN_AFTER_CREATION = true,

		-- How long a created character's starting clothes are waited for.
		CREATION_WAIT_MS = 60000,
	},
}
