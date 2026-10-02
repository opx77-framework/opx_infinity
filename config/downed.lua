--- How long a downed player waits, where they wake, and who may stand them up.
-- @author dop42

OPX.Config.MODULES.downed = {
	enabled = true,

	-- Seconds down before GIVE UP unlocks, and how long it is held so that a
	-- stray click respawns nobody. The server enforces both.
	GIVE_UP_AFTER_S = 120,
	GIVE_UP_HOLD_MS = 1500,

	-- How a player who gave up wakes, in the bucket they fell in: a fraction of
	-- full health, and the spawn protection that follows.
	RESPAWN = {
		HEALTH = 0.5,
		GRACE_MS = 5000,
	},

	-- Respawn points, the nearest to the fall winning. Replace the starter row
	-- with your own medical centers.
	HOSPITALS = {
		{ LABEL = 'Watson medical center', X = -667.14, Y = -382.61, Z = 9.16, HEADING = 0.0 },
	},

	-- What a revive through the contract leaves the player with.
	REVIVE = {
		HEALTH = 0.35,
		GRACE_MS = 3000,
	},

	-- THE TRAUMA TEAM: WHO HEARS A DISTRESS SIGNAL, AND WHO ANSWERS IT.
	--
	-- THE AUDIT OF 2026-09-30 FOUND THE JOB HAD NO GAMEPLAY. A paramedic could
	-- sign up and clock in, and then nothing: WAIT FOR HELP stored a flag and
	-- told the downed player "Help has been called" while nobody was called, and
	-- the only thing that could stand a body up was a staff command. This block is
	-- the other half of that button.
	--
	--   * THE PAGE. Pressing WAIT FOR HELP pages every connected player whose
	--     primary job is in `JOBS` and who is ON DUTY: a loud toast with the
	--     patient's name and where they fell (rounded to `PAGE.ROUND_METRES`), and
	--     a pin on their map for `PAGE.PIN_SECONDS` that comes down the moment the
	--     patient is up. A medic who clocks in while somebody is still waiting is
	--     paged too. The down screen says how many were paged -- or that nobody is
	--     on duty -- instead of a promise nobody keeps.
	--   * THE TREATMENT. An on-duty medic within `TREAT.REACH_METRES` of a downed
	--     body sees a row and presses `KEY` (or types `/opx.treat`): the SERVER
	--     checks the job, the duty, that the medic is up and the patient is down,
	--     the distance to the body and the cooldown, and starts a
	--     `TREAT.SECONDS` bar on the medic's screen; the patient is told a medic is
	--     working on them. When the bar runs out the server checks everything again
	--     -- a medic who walked off or went down, or a patient who is already up,
	--     is no treatment -- and revives the patient where they lie at
	--     `REVIVE.HEALTH`.
	--   * THE PAY. `REWARD.AMOUNT` into the medic's `REWARD.ACCOUNT` per revive, at
	--     most once per `REWARD.PER_PATIENT_MS` for the same patient's character,
	--     so two friends taking turns on the floor are not a money machine. `0`
	--     pays nothing; the job's salary is paid either way.
	--
	-- `enabled = false` (or `TRAUMA = false`) is the old screen: nobody is paged,
	-- nobody but staff revives, and the down screen says nobody is coming.
	TRAUMA = {
		enabled = true,
		JOBS = { 'trauma' },
		KEY = { ID = 'opx.downed.treat', NAME = 'medic.key.treat', DEFAULT = 'E' },
		PAGE = {
			ROUND_METRES = 5.0,
			PIN_SECONDS = 300,
			PIN_SPRITE = 'objective',
			TOAST_MS = 12000,
		},
		TREAT = {
			REACH_METRES = 4.0,
			SECONDS = 6,
			COOLDOWN_MS = 3000,
		},
		REWARD = {
			AMOUNT = 150,
			ACCOUNT = 'BANK',
			PER_PATIENT_MS = 600000,
		},
	},

	-- Callers allowed to revive, and callers allowed to set the screen aside
	-- while their own surface is up. A caller now gives its own name, so both are
	-- switches rather than boundaries.
	REVIVERS = '*',
	-- Keys are MODULE ids, the name a caller passes to the downed contract's
	-- `Suspend`. `admin` is the only caller: the staff menu sets the screen aside
	-- so a downed staff member can still use it. (`opx77_admin`, the resource
	-- `admin` replaced, was listed here too; another resource cannot reach this
	-- runtime's contracts at all, so that entry could never match a caller.)
	SUSPENDERS = { admin = true },

	-- Stock HUD components hidden while down.
	--
	-- ALL THIRTEEN, WHICH IS NOT WHAT `config/hud.lua` DOES, and the difference
	-- is the point. That list is a steady state and leaves the crosshair, the
	-- scanner and the phone to the game, because a player who is up needs to aim
	-- and scan. This is a player bleeding out: they cannot aim, cannot scan, and
	-- are not taking a call. Every stock component is chrome over a screen that
	-- has one thing to say.
	--
	-- Seven of these were named and six were absent, which read as a decision and
	-- was a gap. `Open77.hud.components()` is the authority on the set; a name
	-- this build does not know is refused per component and costs nothing.
	VANILLA_HUD = {
		'minimap', 'compass', 'clock', 'health', 'stamina', 'weapon', 'speedometer',
		'questTracker', 'phone', 'scanner', 'vanillaNotifications', 'crosshair', 'hubMenu',
	},
}
