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
		-- WHICH WORLD ENTERS ARE HANDED THE FITTING ROOM. Three values, and no
		-- fourth:
		--
		--   'first'   only a character the game's own creator has just built.
		--             `created` on the decision bus is what says so, and it is
		--             raised once per character ever -- so this is "dress the new
		--             one, and never interrupt anybody else".
		--   'always'  every world enter, a returning character included, once its
		--             stored clothes are on. The room opens over a DRESSED puppet
		--             and not a pristine one, so cancelling really does put back
		--             what the player walked in wearing.
		--   'never'   nobody is ever handed one. The room is still reachable from
		--             the appearance panel; it is only the join that stops
		--             offering it.
		--
		-- WHY THIS IS A SETTING AND NOT A GUESS. The two defensible answers are
		-- opposite and both are somebody's server: a roleplay server dresses a
		-- character once, at creation, and never interrupts a returning player
		-- again; a server whose sessions are one-offs may want the choice every
		-- time. This shipped hard-wired to the first, as the boolean
		-- `OPEN_AFTER_CREATION`, which could say no but could not say 'always'.
		--
		-- IT IS PART OF THE JOIN SEQUENCE, which is the thing to know before
		-- changing it. A brand new character is asked for a NAME by the entry
		-- module and for a SPAWN POINT by the spawn module, and all three are
		-- answers to the same instant. The order is name -> fitting room -> spawn
		-- menu, and it is held by one rule: the spawn menu stands aside while the
		-- entry module reports the join still busy, and the entry module reports
		-- the join busy while a fitting room is owed. Set this to 'never' and the
		-- spawn menu simply follows the name form, as it did before.
		--
		-- THE SPAWN MODULE'S HOLD BOUNDS THE WHOLE OF IT. `HOLD_MAX_SECONDS` in
		-- `config/spawn.lua` is how long an offer nobody has opened may hold a
		-- character unplaced, and a player deliberating in the fitting room is
		-- inside that hold. Past it the spawn choice is settled from the
		-- character's own row and the menu is never drawn -- so an operator who
		-- shortens that number below the time a player plausibly spends dressing
		-- has taken the spawn choice away from them, silently.
		--
		-- An unknown value is REFUSED WITH A LINE IN THE JOURNAL and falls back
		-- to 'first', which is what this module did when the setting was a
		-- boolean. It is never guessed at: 'creation', 'once' and true are each a
		-- typo, and a typo that silently turned the room off would look exactly
		-- like the module being broken.
		OFFER_POLICY = 'first',

		-- How long the room is waited for before the join gives up on it, in
		-- milliseconds.
		--
		-- The room cannot open the instant it is owed and is not meant to: the
		-- puppet has to be alive on foot, the stored clothes have to be ON it
		-- (there is nothing to put back otherwise), and the name form is holding
		-- the keyboard. Every one of those is a 'not yet' that is retried, and
		-- this is the bound on retrying -- the one thing that stops a character
		-- who can never be dressed from holding the spawn menu shut for the
		-- session. Past it the join moves on and the player keeps the clothes the
		-- platform gave them.
		CREATION_WAIT_MS = 60000,
	},

	-- THE PANEL'S OWN DOOR. `ID` is stable because a player's rebind is stored
	-- under it; `NAME` is the catalogue key of the pause-menu label; `DEFAULT`
	-- is the key out of the box. `false` declares no mapping at all, which is
	-- how an operator turns the key off -- `/opx.appearance` still opens the
	-- panel, and the fitting room is still behind it.
	--
	-- THIS KEY IS THE FIX FOR A HOLE, NOT A CONVENIENCE. The module owns two
	-- state machines -- the appearance panel and the fitting room -- and draws
	-- neither: `client/view.lua` hands the first to `menu` and the second to
	-- `panel`, and the contract that opens them (`OpenPanel`, `OpenWardrobe`) is
	-- exported on the API. Until now NOTHING CALLED IT. `WARDROBE.OFFER_POLICY`
	-- hands the room to a character the game's own creator has just built and to
	-- nobody else, so for a RETURNING player the fitting room had no door at
	-- all: the state machines ran, the catalogue streamed, and nothing was ever
	-- drawn on anybody's screen. F7 because the other modules hold F3, F9, I, T,
	-- X, E, ALT and the page keys, and a player's rebind lands here.
	KEY = { ID = 'opx.appearance.panel', NAME = 'appearance.key.panel', DEFAULT = 'F7' },
}
