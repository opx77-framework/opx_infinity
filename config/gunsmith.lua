--- Gunsmith: every armoury, who may work it, what it makes and where its chest is.
-- @author dop42
--
-- An ARMOURY is three things in one place: a bench the crafting module owns, a
-- chest the inventory module owns, and a job gate this module owns. Add a fourth
-- key below and there is a fourth armoury; nothing else has to change.
--
-- THE POSITIONS BELOW ARE PLACEHOLDERS AND NOT ONE OF THEM HAS BEEN SURVEYED.
-- They are written in the shape a real one takes so the file reads as it will
-- read when it is true, and they are wrong in a way nothing can detect:
-- `Access.Problems` checks SHAPE -- a finite coordinate, a label, a job name
-- against a grade -- and a placeholder passes all of it. The failure is silent
-- and total. A bench whose position is off by more than REACH metres is a bench
-- nobody can ever reach, the target row sits in mid-air somewhere nobody stands,
-- and the only symptom is that the armoury does not work.
--
-- To make one real, stand where the bench should be and read the position off
-- the client developer console, then do the same for the chest -- they are two
-- positions on purpose, because a workbench and a gun locker are not the same
-- piece of furniture and a player walks between them.
--
-- THE JOB NAMES ARE NOT CHECKED EITHER, and cannot be: a job lives in the
-- character module's own tables and this file is read at load, with nothing
-- waited on. `arasaka` and `ncpd` below are the same names `config/elevators.lua`
-- uses, so the two at least agree with each other; whether this server has
-- either is the operator's to answer.
--
-- THE RECIPES NAME REAL CATALOGUE ITEMS, and that part IS checked -- the
-- crafting module asks the inventory catalogue about every OUTPUT and every
-- INPUT when it registers the bench, and a name it does not carry is a boot
-- warning and a dropped recipe. What the recipes are NOT is balanced: the costs,
-- the durations and the fees below are placeholders in the same sense as the
-- positions, and they are the operator's to set.

OPX.Config.MODULES.gunsmith = {
	enabled = true,

	-- primary reads the worked job; any counts every membership for the grade but
	-- never for ON_DUTY. The same two words, with the same two meanings, as
	-- `config/elevators.lua` -- a second vocabulary for the same question would
	-- be a second thing to get wrong.
	MEMBERSHIP = 'primary',

	-- Past this snapshot age a gated armoury closes. An UNGATED one -- no JOBS at
	-- all -- stays open, because a broken character read must not shut a public
	-- workshop, which is the rule the elevators module already states for a
	-- public floor.
	JOB_MAX_AGE_MS = 60000,

	-- Metres the bench and the chest are worked from, measured on the server.
	-- The bench's reach is handed to the crafting module; the chest's is the
	-- inventory module's own REACH.DISTANCE and is not set here.
	REACH = 2.5,

	-- Metres within which the target eye registers the two spheres.
	PROMPT_RADIUS = 2.5,

	ARMOURIES = {
		arasaka_armoury = {
			LABEL = 'ARASAKA ARMOURY',

			-- Job name -> minimum grade level. Absent or empty is a public bench.
			JOBS = { arasaka = 0 },
			-- true means the grade is not enough: the job must be the one being
			-- WORKED, and worked on duty.
			ON_DUTY = true,

			BENCH = { X = -1519.10, Y = 889.30, Z = 42.10, BUCKET = 0 },

			-- THE CHEST IS A STASH, and NAME is its storage key. It must never be
			-- reused for somewhere else and it must never be changed once people
			-- have put things in it: the key is what the row is keyed on, so a
			-- renamed chest is an empty chest and the old contents are reachable
			-- by nothing. Letters, digits, `_`, `-` and `.` only, up to 48 -- the
			-- crafting module's keys allow a colon and a stash name does not.
			CHEST = {
				NAME = 'gunsmith_arasaka_armoury',
				LABEL = 'ARASAKA ARMOURY STOCK',
				SLOTS = 100,
				MAX_WEIGHT = 500000,
				X = -1522.40, Y = 889.80, Z = 42.10, BUCKET = 0,
			},

			-- Orders one character may have on this bench at once.
			QUEUE = 3,

			-- GRADE is THIS MODULE'S field and the crafting module never reads it:
			-- crafting asks `canUse(player, recipe)` and this module answers from
			-- here. Everything else in a row is crafting's own vocabulary and is
			-- validated by `modules/crafting/shared/recipes.lua`.
			RECIPES = {
				{ KEY = 'handgun_rounds', ICON = 'ammo',
					LABEL = 'Handgun rounds',
					INPUTS = { scrap_metal = 2 },
					OUTPUT = 'ammo_handgun', COUNT = 30,
					SECONDS = 120, PRICE = 40, MONEY = 'EDDIES', GRADE = 0 },

				{ KEY = 'rifle_rounds', ICON = 'ammo',
					LABEL = 'Rifle rounds',
					INPUTS = { scrap_metal = 3 },
					OUTPUT = 'ammo_rifle', COUNT = 30,
					SECONDS = 180, PRICE = 60, MONEY = 'EDDIES', GRADE = 0 },

				{ KEY = 'shotgun_shells', ICON = 'ammo',
					LABEL = 'Shotgun shells',
					INPUTS = { scrap_metal = 4 },
					OUTPUT = 'ammo_shotgun', COUNT = 20,
					SECONDS = 240, PRICE = 80, MONEY = 'EDDIES', GRADE = 1 },

				{ KEY = 'sidearm', ICON = 'weapon',
					LABEL = 'Unity sidearm',
					INPUTS = { scrap_metal = 12, electronics = 4 },
					OUTPUT = 'weapon_cheetah', COUNT = 1,
					SECONDS = 1800, PRICE = 2500, MONEY = 'EDDIES', GRADE = 2 },
			},
		},

		ncpd_watson_armoury = {
			LABEL = 'NCPD WATSON ARMOURY',

			JOBS = { ncpd = 1, maxtac = 0 },
			ON_DUTY = true,

			BENCH = { X = -654.80, Y = 1391.20, Z = 12.40, BUCKET = 0 },

			CHEST = {
				NAME = 'gunsmith_ncpd_watson',
				LABEL = 'NCPD WATSON ARMOURY STOCK',
				SLOTS = 120,
				MAX_WEIGHT = 600000,
				X = -657.10, Y = 1391.20, Z = 12.40, BUCKET = 0,
			},

			QUEUE = 4,

			RECIPES = {
				{ KEY = 'handgun_rounds', ICON = 'ammo',
					LABEL = 'Service rounds',
					INPUTS = { scrap_metal = 2 },
					OUTPUT = 'ammo_handgun', COUNT = 60,
					SECONDS = 120, PRICE = 0, GRADE = 1 },

				{ KEY = 'rifle_rounds', ICON = 'ammo',
					LABEL = 'Patrol rifle rounds',
					INPUTS = { scrap_metal = 3 },
					OUTPUT = 'ammo_rifle', COUNT = 60,
					SECONDS = 180, PRICE = 0, GRADE = 1 },

				{ KEY = 'sniper_rounds', ICON = 'ammo',
					LABEL = 'Marksman rounds',
					INPUTS = { scrap_metal = 5, electronics = 1 },
					OUTPUT = 'ammo_sniper', COUNT = 10,
					SECONDS = 600, PRICE = 0, GRADE = 2 },
			},
		},

		-- A PUBLIC BENCH, and it is here to prove the gate can be absent. No JOBS,
		-- so anybody who can stand at it may use it -- and the ungated case is the
		-- one a fail-open rule has to be checked against, because it is the one
		-- where a broken character read must change nothing at all.
		kabuki_workshop = {
			LABEL = 'KABUKI WORKSHOP',

			BENCH = { X = -1247.30, Y = 405.80, Z = 8.90, BUCKET = 0 },

			CHEST = {
				NAME = 'gunsmith_kabuki_workshop',
				LABEL = 'KABUKI WORKSHOP CRATE',
				SLOTS = 40,
				MAX_WEIGHT = 200000,
				X = -1249.60, Y = 405.80, Z = 8.90, BUCKET = 0,
			},

			QUEUE = 2,

			RECIPES = {
				{ KEY = 'handgun_rounds', ICON = 'ammo',
					LABEL = 'Back-alley rounds',
					INPUTS = { scrap_metal = 3 },
					OUTPUT = 'ammo_handgun', COUNT = 15,
					SECONDS = 300, PRICE = 120, MONEY = 'EDDIES' },

				{ KEY = 'lockpick', ICON = 'key',
					LABEL = 'Lockpick',
					INPUTS = { scrap_metal = 1, electronics = 1 },
					OUTPUT = 'lockpick', COUNT = 2,
					SECONDS = 90, PRICE = 25, MONEY = 'EDDIES' },
			},
		},
	},
}
