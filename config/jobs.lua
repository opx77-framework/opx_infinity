--- Where a job is joined, where its boss sits, and what a rank costs in seniority.
-- @author XEROX710
--
-- THIS MODULE OWNS THE TERMS OF EMPLOYMENT, NOT THE EMPLOYMENT. Who holds what,
-- at which grade, on duty or not, and what each grade is called and pays is
-- `config/character.lua`'s `JOBS` -- the character module stores it, replicates
-- it and gates elevators, armouries and teleports with it. What is decided here
-- is the part that catalogue has no field for: WHERE a job is joined, WHO may
-- join it, and HOW LONG somebody has to work before the next rank is theirs.
--
-- The two tables therefore have to agree and are not allowed to drift: every
-- `JOBS` key below must be a job the character catalogue defines, and every
-- LEVEL in a `LADDER` must be a grade that job actually has. A ladder that names
-- a grade nobody defined would promote somebody into a rank with no name, and a
-- board for a job nobody defined would offer work that does not exist. Both are
-- named at boot -- see `Access.Problems` -- rather than discovered by a player.
--
-- BOARDS ARE PLACES AND NOT RULES, exactly like a garage or a dealership: a
-- marker is drawn where the operator put it, the server re-derives the player's
-- distance to the DECLARED position before it does anything, and
-- `/opx.jobs.add <signup|boss> <key> <job>` is what writes one. The shipped
-- office stands at an arrival point rather than at a spot on the map, because a
-- feature nobody can find is a feature nobody has; move either kind to where you
-- want it. A DESK IS ONLY DRAWN FOR ITS JOB'S BOSS (and for whoever captured it,
-- so an operator can see where they put it), which is why a placed desk can be
-- invisible to the player who placed it until somebody holds that job's boss
-- grade.
--
--   signup  a public noticeboard: stand on it, press the key, and read EVERY
--           job in JOBS below with your own standing against each -- the grade
--           you hold, how far the next rank is, or what the terms are missing
--   boss    a desk: one per division. Only the holder of that job's boss grade
--           is shown it at all, and it is where a roster is managed -- hired,
--           promoted, demoted, dismissed
--
-- A SIGN-UP BOARD IS ONE OFFICE AND NOT ONE QUEUE PER JOB, which is why its own
-- `JOB` is only the board's headline: any job JOBS offers may be taken at any
-- sign-up board, and the terms are re-derived on the server at the moment of
-- signing either way. A desk is the other way round -- its `JOB` is the only
-- roster behind it.

OPX.Config.MODULES.jobs = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a board may be used.
	USE_RADIUS = 4.0,

	-- What each kind of board looks like. Both are engine presets and both glow,
	-- for the same reason the garage and pad presets do: the vocabulary is the
	-- engine's own, and a style or a shape outside it is refused by
	-- `Open77.markers` with a status rather than drawn as something else.
	-- The desk is deliberately the louder of the two.
	MARKER = {
		signup = { shape = 'cylinder', style = 'interaction', RADIUS = 2.5 },
		boss = { shape = 'cylinder', style = 'objective', RADIUS = 3.0 },
	},

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2. Not decoration: a
	-- marker left at exact floor height is co-planar with the floor and draws
	-- nothing at all -- the entity exists, the marker is listed, and the board
	-- looks empty.
	GROUND_OFFSET = 0.06,

	-- The marker/scan loop, and how often the client re-asks for its boards so a
	-- change of routing bucket is picked up without a rejoin.
	SCAN_MS = 500,
	POLL_MS = 15000,

	-- One request in this window, per connection. A board is a place a player
	-- stands on, so the ceiling is about a stuck key and not about fairness.
	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 8,
	-- Floor between two actions of the same kind from one connection.
	COOLDOWN_MS = 2000,
	-- How long `add` waits for the client's answer before it says the capture did
	-- not happen: a chat command has no facing of its own.
	CAPTURE_TIMEOUT_MS = 5000,

	-- ── seniority ───────────────────────────────────────────────────────────
	--
	-- SENIORITY IS WORKED TIME, AND IT IS THE ONLY THING A RANK COSTS. A holder
	-- on duty in a job that has a ladder banks POINTS_PER_TICK every TICK_MS,
	-- and a `LADDER` level's number is the bank that rank wants: `LADDER = { [1] =
	-- 90 }` on a job whose grade 1 is named in the character catalogue means
	-- ninety minutes of work at the shipped rate.
	--
	-- WHO TICKS. Only a character who is ON DUTY -- which a job with
	-- `defaultDuty = true` always is, so a freelancer banks while they play and a
	-- police officer banks while they are clocked in. Duty is the character
	-- module's own field; nothing here invents a second one.
	--
	-- WHAT AUTO_PROMOTE DOES. With it on, a bank that reaches the next level
	-- promotes its holder without anybody's approval, and the promotion is
	-- announced the way `/opx.job` announces one. With it off the bank keeps
	-- filling and the rank only moves when a boss or an operator moves it --
	-- which is the setting a server that wants its ranks *earned in front of
	-- somebody* will pick. `APPROVAL = true` on a job overrides both: that job's
	-- ranks are never granted by a clock.
	SENIORITY = {
		enabled = true,
		TICK_MS = 60000,
		POINTS_PER_TICK = 1.0,
		-- A ceiling on the bank, so a job whose ladder has a level nobody defined
		-- cannot run away with the number. Reached, the highest defined rank
		-- simply holds.
		MAX_POINTS = 1000000.0,
		AUTO_PROMOTE = true,
		-- How often the bank is written back to the database, and the floor
		-- between two promotions of one character.
		SAVE_MS = 60000,
		PROMOTION_COOLDOWN_MS = 5000,
	},

	-- Metres from a desk a candidate has to be standing for a boss to hire them
	-- on the spot. Hiring somebody across the map is not a scene anybody can see.
	HIRE_RADIUS = 8.0,

	-- How many members one roster payload carries, oldest-first by grade.
	ROSTER_LIMIT = 200,

	-- The key that opens the board the player is standing on. ID is stable,
	-- because a player's rebind is stored under it; NAME is the catalogue key of
	-- the pause-menu label.
	KEY = { ID = 'opx.jobs.use', NAME = 'jobs.key.use', DEFAULT = 'E' },

	-- Where the list opens. A job board is a menu of text, so it opens centred
	-- and large like the dealership's does, and the `menu` module clamps every
	-- value it is handed. VISIBLE_ROWS is how many rows are on screen before the
	-- list scrolls; HEIGHT is asked for together with WIDTH so the panel stays
	-- square whatever the level holds.
	MENU = { ANCHOR = 'center', WIDTH = 708, HEIGHT = 708, MAX_HEIGHT_VH = 88, VISIBLE_ROWS = 15 },

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	-- The boss actions are NOT here: a boss is granted a desk by their grade and
	-- not by an operator's ACL list, and the server checks that grade itself.
	COMMANDS = {
		add = 'opx.jobs.add',
		remove = 'opx.jobs.remove',
		list = 'opx.jobs.list',
		join = 'opx.jobs.join',
		leave = 'opx.jobs.leave',
		roster = 'opx.jobs.roster',
		rank = 'opx.jobs.rank',
		promote = 'opx.jobs.promote',
		demote = 'opx.jobs.demote',
		fire = 'opx.jobs.fire',
		hire = 'opx.jobs.hire',
	},

	-- ── the jobs a board may offer ──────────────────────────────────────────
	--
	-- Keyed by the CHARACTER catalogue's own job name. A job absent here is not
	-- offered at a board at all: it exists, characters can be put in it by an
	-- operator, and no player will be handed it by walking up to a sign.
	--
	--   OPEN       shown on a sign-up board and joinable by whoever meets the
	--              terms. `false` keeps the job off the board entirely.
	--   APPROVAL   shown, but not joinable: the rank is granted at a desk by
	--              somebody who holds the boss grade. What a division like MaxTac
	--              wants and what a rank served in front of a desk is.
	--   REQUIRES   the terms a joiner has to already meet. Every clause is
	--              checked on the server at the moment of joining:
	--                JOB, GRADE   must hold that job at that grade or better
	--                ACL          must hold that right (`acl.isAllowed`)
	--   LADDER     points needed to HOLD each level, keyed by the character
	--              catalogue's grade number. Level 0 is free by definition and is
	--              not written here; a level named that the job has no grade for
	--              is refused at boot rather than promoting somebody into it.
	--
	-- The shipped ladders are drawn so that a rank is a shift or two of work and
	-- the top of an NCPD career is a commitment -- edit the numbers and they are
	-- read at boot, so a server can make its ranks cheap or make them a career.
	JOBS = {
		ncpd = {
			OPEN = true,
			-- Cadet -> Officer -> Detective -> Captain over a career.
			LADDER = { [1] = 90.0, [2] = 360.0, [3] = 1080.0 },
		},

		maxtac = {
			OPEN = true,
			-- MaxTac does not take walk-ins: the sign says so, and the rank is
			-- granted at the desk by whoever holds Squad Lead. A player who is
			-- already an NCPD detective is told THAT rather than told no.
			APPROVAL = true,
			REQUIRES = { JOB = 'ncpd', GRADE = 2 },
			LADDER = { [1] = 240.0 },
		},

		trauma = {
			OPEN = true,
			LADDER = { [1] = 120.0, [2] = 480.0, [3] = 1200.0 },
		},

		ripperdoc = {
			OPEN = true,
			LADDER = { [1] = 120.0, [2] = 480.0 },
		},

		merc = {
			OPEN = true,
			LADDER = { [1] = 60.0, [2] = 300.0, [3] = 900.0 },
		},

		fixer = {
			OPEN = true,
			LADDER = { [1] = 60.0, [2] = 300.0 },
		},

		netrunner = {
			OPEN = true,
			LADDER = { [1] = 60.0, [2] = 300.0 },
		},
	},

	-- ── the boards ──────────────────────────────────────────────────────────
	--
	-- A board is a PLACE. `KIND` is `signup` or `boss`, `JOB` is the key in the
	-- character catalogue, and `LABEL` is the operator's own words and is never
	-- translated.
	--
	-- A BOARD IS CAPTURED IN GAME, and the command prints the line to check in
	-- here, the way the garages command does:
	--   /opx.jobs.add signup jobs_signup ncpd
	--   /opx.jobs.add boss   jobs_desk_city ncpd
	--
	--   jobs_signup = { LABEL = 'EMPLOYMENT', KIND = 'signup', JOB = 'ncpd',
	--     X = -469.47, Y = 930.99, Z = 56.45, HEADING = -68.0, BUCKET = 0 },
	BOARDS = {
		-- ── the office, ON AN ARRIVAL POINT ─────────────────────────────
		--
		-- IT STOOD AT THE PLATFORM'S OLD DEFAULT SPAWN, which no spawn this server
		-- offers is near: the launcher's spawn menu lands a character on one of the
		-- entries in config/spawn.lua, and the closest of those (`coast`) was 141 m
		-- away while the rest were kilometres. A marker is drawn only within
		-- MAX_DISTANCE below, so the office was a place nobody could ever see --
		-- reported on a live server as "the job marker isn't appearing in game".
		--
		-- It now stands on the Northside promenade arrival point itself
		-- (config/spawn.lua, the coordinates are that entry's to the number), with
		-- each division's desk spaced 7 m off it, along the spawn's own heading.
		-- 7 m and not less because USE_RADIUS is 4: two boards closer than that
		-- are two boards whose presses cannot be told apart.
		--
		-- Its services are every job in JOBS above, so `JOB` here is only what the
		-- board is described by.
		jobs_signup = {
			LABEL = 'EMPLOYMENT', KIND = 'signup', JOB = 'ncpd',
			X = -469.47, Y = 930.99, Z = 56.45, HEADING = -68.0, BUCKET = 0,
		},
		jobs_desk_city = {
			LABEL = 'NCPD DESK', KIND = 'boss', JOB = 'ncpd',
			X = -462.98, Y = 933.61, Z = 56.45, HEADING = -68.0, BUCKET = 0,
		},
		jobs_desk_maxtac = {
			LABEL = 'MAXTAC DESK', KIND = 'boss', JOB = 'maxtac',
			X = -456.49, Y = 936.23, Z = 56.45, HEADING = -68.0, BUCKET = 0,
		},
		jobs_desk_trauma = {
			LABEL = 'TRAUMA TEAM DESK', KIND = 'boss', JOB = 'trauma',
			X = -450.00, Y = 938.85, Z = 56.45, HEADING = -68.0, BUCKET = 0,
		},
	},
}
