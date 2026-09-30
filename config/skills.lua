--- The skill tree: what working a job earns, and what the points buy.
-- @author XEROX710
--
-- WHERE THE LEVELS COME FROM. The jobs bank pays for work -- a shift's wages on
-- the tick, an arrest or a delivery through `jobs.Award` -- and every credit it
-- actually makes arrives at `modules/skills/server/main.lua` as one local event.
-- Nothing here invents a second measure of work: the funnel is the one the
-- grade ladder already trusts.
--
-- TWO CURRENCIES, AND THEY BUY DIFFERENT THINGS. Total work raises the
-- CHARACTER's level, and a level banks a point. A point unlocks a node in a
-- trunk -- but only as deep as THAT TRUNK has been fed: NCPD work deepens the
-- NCPD trunk, a fixer's contracts the fixer trunk, and work no trunk names goes
-- to the street. A point cannot buy into a rank the work has not reached, which
-- is what makes this a skill tree rather than a shop: the tree is a map of what
-- this character has actually done.
--
-- SEVEN TRUNKS, AND THE ORDER IS THE PICTURE. The panel draws them left to
-- right in the order below, and the LAST one is drawn as the top of the tree:
-- the fixer, whose last node -- Night City Legend -- is the highest a character
-- can climb. Reordering this list re-draws the page; nothing else names an
-- index.
--
-- THE PERKS ARE DECLARED, NOT INVENTED. Each node names a perk id and a value.
-- Nothing in this repo applies them -- gameplay systems read them through
-- `OPX.Api.Get('skills', 1).Perk(citizenId, perkId)` when they want them, and a
-- server whose systems ignore the perks still has a tree that fills, ranks and
-- persists. The value on the node is content (rule 8): the one number the
-- surface may state as fact.
--
-- A NODE'S `id` IS WHAT A CHARACTER'S UNLOCK IS STORED UNDER, so an id is never
-- reused for a different perk by accident and never renamed at all: `ncpd_5`
-- and `street_5` are the NCPD and street capstones they always were, and Night
-- City Legend -- once NCPD's -- is `fixer_5` now, at the top of the fixer.
--
-- COSTS RAMP (1, 1, 2, 2, 3 per trunk). A level cap of 20 banks 19 points
-- against 63 points of nodes across the seven trunks, so a character can take
-- about two trunks to the top, and the choice of which is real.

OPX.Config.MODULES.skills = {
	-- THE TREE'S KEY. The same `ID`/`NAME`/`DEFAULT` block every other surface
	-- declares: `ID` is what a player's rebind is stored under and must not
	-- change between builds, `NAME` is the pause menu's label for it (a locale
	-- key), and `DEFAULT` is the key it arrives on -- `false` registers no
	-- mapping at all, which is how a server that binds it elsewhere turns this
	-- one off. The tree opens from this key and nothing else, which is why the
	-- block lives HERE: `M.Skill.KEY` in the module is only the shipped
	-- fallback, and this is the operator's answer.
	--
	-- F4, NOT F3: F3 is the animation picker's (`config/animations.lua`), and
	-- every mapping on a pressed key fires -- a tree shipped on F3 opened the
	-- picker over itself on every press. A player who rebound it keeps theirs:
	-- the rebind is stored under `ID`, which does not change.
	KEY = { ID = 'opx.skills.tree', NAME = 'skills.key.tree', DEFAULT = 'F4' },

	-- ACL-gated: refused unless the caller holds `command.<name>`.
	--   level  `/opx.skills.level <max|reset|1..cap> [playerId]` -- a staff or
	--          testing lever, never a player's: `max` puts a character at the
	--          cap with every trunk fed to its full depth, the points to buy
	--          every node still locked, AND the base game's own levels maxed on
	--          that player's machine (DEVELOP below); a number sets that level
	--          and re-banks the points it is worth; `reset` starts them over.
	--          The player defaults to the caller; the console must name one.
	COMMANDS = {
		level = 'opx.skills.level',
	},

	-- THE BASE GAME'S OWN LEVELS, which `max` also maxes. The preload named here
	-- exports `develop(code)` on the client (opx_sandy_view 1.4.9+): code 10 sets
	-- the base game's Level, Street Cred, attributes, skills, perk and relic
	-- points to their tops on THAT machine and answers `ok, why`. Nothing here
	-- can reach those numbers any other way -- they are the engine's, not ours --
	-- so a server without the preload gets the tree maxed and a toast saying the
	-- base game was not. `RESOURCE = false` turns the request off.
	DEVELOP = { RESOURCE = 'opx_sandy_view', EXPORT = 'develop', CODE = 10 },

	-- Jobs bank points -> character XP. A five-point arrest is fifty XP.
	XP_PER_POINT = 10,

	-- XP owed between one character level and the next: `LEVEL_STEP * level`,
	-- so level 2 costs 100 and level 10 costs 1,000.
	LEVEL_STEP = 100,
	LEVEL_CAP = 20,
	POINTS_PER_LEVEL = 1,

	-- Branch XP owed per rank of that trunk's chain: rank 1 is the first node
	-- (0 XP), rank 2 the second (100 XP into the trunk), and so on.
	BRANCH_STEP = 100,

	-- Per trunk:
	--   id     the trunk's durable name: stored work is keyed by it
	--   NAME   its locale key
	--   FEED   the locale key of the line that says what work feeds it
	--   ICON   its emblem: a name from the shared glyph set (`OPX.Glyphs`)
	--   JOBS   the jobs (the character catalogue's names) whose credited work
	--          deepens it. ONE trunk declares none: that one is the catch-all,
	--          and every job no other trunk names falls to it.
	--   NODES  its chain, rank 1 first
	BRANCHES = {
		{
			id = 'ncpd',
			NAME = 'skills.branch.ncpd',
			FEED = 'skills.feed.ncpd',
			ICON = 'shield',
			JOBS = { ncpd = true },
			NODES = {
				{ id = 'ncpd_1', NAME = 'skills.node.ncpd1', DESC = 'skills.desc.ncpd1',
					PERK = 'ncpd.vest', VALUE = 2, COST = 1 },
				{ id = 'ncpd_2', NAME = 'skills.node.ncpd2', DESC = 'skills.desc.ncpd2',
					PERK = 'ncpd.reload', VALUE = 5, COST = 1 },
				{ id = 'ncpd_3', NAME = 'skills.node.ncpd3', DESC = 'skills.desc.ncpd3',
					PERK = 'ncpd.stealth', VALUE = 10, COST = 2 },
				{ id = 'ncpd_4', NAME = 'skills.node.ncpd4', DESC = 'skills.desc.ncpd4',
					PERK = 'ncpd.command', VALUE = 15, COST = 2 },
				{ id = 'ncpd_5', NAME = 'skills.node.ncpd5', DESC = 'skills.desc.ncpd5',
					PERK = 'ncpd.response', VALUE = 25, COST = 3 },
			},
		},
		{
			id = 'maxtac',
			NAME = 'skills.branch.maxtac',
			FEED = 'skills.feed.maxtac',
			ICON = 'weapon',
			JOBS = { maxtac = true },
			NODES = {
				{ id = 'maxtac_1', NAME = 'skills.node.maxtac1', DESC = 'skills.desc.maxtac1',
					PERK = 'maxtac.gforce', VALUE = 5, COST = 1 },
				{ id = 'maxtac_2', NAME = 'skills.node.maxtac2', DESC = 'skills.desc.maxtac2',
					PERK = 'maxtac.boarding', VALUE = 10, COST = 1 },
				{ id = 'maxtac_3', NAME = 'skills.node.maxtac3', DESC = 'skills.desc.maxtac3',
					PERK = 'maxtac.drop', VALUE = 15, COST = 2 },
				{ id = 'maxtac_4', NAME = 'skills.node.maxtac4', DESC = 'skills.desc.maxtac4',
					PERK = 'maxtac.laser', VALUE = 20, COST = 2 },
				{ id = 'maxtac_5', NAME = 'skills.node.maxtac5', DESC = 'skills.desc.maxtac5',
					PERK = 'maxtac.reaper', VALUE = 30, COST = 3 },
			},
		},
		{
			id = 'corp',
			NAME = 'skills.branch.corp',
			FEED = 'skills.feed.corp',
			ICON = 'server',
			-- `corp` is the board's own corporate job; Arasaka and Militech are
			-- the catalogue's corporate employers, given by an operator.
			JOBS = { corp = true, arasaka = true, militech = true },
			NODES = {
				{ id = 'corp_1', NAME = 'skills.node.corp1', DESC = 'skills.desc.corp1',
					PERK = 'corp.access', VALUE = 5, COST = 1 },
				{ id = 'corp_2', NAME = 'skills.node.corp2', DESC = 'skills.desc.corp2',
					PERK = 'corp.expense', VALUE = 10, COST = 1 },
				{ id = 'corp_3', NAME = 'skills.node.corp3', DESC = 'skills.desc.corp3',
					PERK = 'corp.leverage', VALUE = 15, COST = 2 },
				{ id = 'corp_4', NAME = 'skills.node.corp4', DESC = 'skills.desc.corp4',
					PERK = 'corp.budget', VALUE = 20, COST = 2 },
				{ id = 'corp_5', NAME = 'skills.node.corp5', DESC = 'skills.desc.corp5',
					PERK = 'corp.board', VALUE = 30, COST = 3 },
			},
		},
		{
			id = 'nomad',
			NAME = 'skills.branch.nomad',
			FEED = 'skills.feed.nomad',
			ICON = 'vehicle',
			-- The road: the board's nomad clans and the Delamain drivers. Hauling
			-- pays its crates straight to the wallet and credits no job bank, so
			-- it has no job name to list here (see docs/jobs.md).
			JOBS = { nomad = true, cabbie = true },
			NODES = {
				{ id = 'nomad_1', NAME = 'skills.node.nomad1', DESC = 'skills.desc.nomad1',
					PERK = 'nomad.handling', VALUE = 5, COST = 1 },
				{ id = 'nomad_2', NAME = 'skills.node.nomad2', DESC = 'skills.desc.nomad2',
					PERK = 'nomad.clan', VALUE = 10, COST = 1 },
				{ id = 'nomad_3', NAME = 'skills.node.nomad3', DESC = 'skills.desc.nomad3',
					PERK = 'nomad.cargo', VALUE = 15, COST = 2 },
				{ id = 'nomad_4', NAME = 'skills.node.nomad4', DESC = 'skills.desc.nomad4',
					PERK = 'nomad.speed', VALUE = 20, COST = 2 },
				{ id = 'nomad_5', NAME = 'skills.node.nomad5', DESC = 'skills.desc.nomad5',
					PERK = 'nomad.chief', VALUE = 30, COST = 3 },
			},
		},
		{
			id = 'street',
			NAME = 'skills.branch.street',
			FEED = 'skills.feed.street',
			ICON = 'map',
			-- THE CATCH-ALL: no jobs declared means every job no other trunk
			-- names -- netrunning, bartending, whatever the server runs.
			JOBS = nil,
			NODES = {
				{ id = 'street_1', NAME = 'skills.node.street1', DESC = 'skills.desc.street1',
					PERK = 'street.haggle', VALUE = 5, COST = 1 },
				{ id = 'street_2', NAME = 'skills.node.street2', DESC = 'skills.desc.street2',
					PERK = 'street.sprint', VALUE = 5, COST = 1 },
				{ id = 'street_3', NAME = 'skills.node.street3', DESC = 'skills.desc.street3',
					PERK = 'street.craft', VALUE = 10, COST = 2 },
				{ id = 'street_4', NAME = 'skills.node.street4', DESC = 'skills.desc.street4',
					PERK = 'street.scavenge', VALUE = 15, COST = 2 },
				{ id = 'street_5', NAME = 'skills.node.street5', DESC = 'skills.desc.street5',
					PERK = 'street.cred', VALUE = 20, COST = 3 },
			},
		},
		{
			id = 'ripperdoc',
			NAME = 'skills.branch.ripperdoc',
			FEED = 'skills.feed.ripperdoc',
			ICON = 'heal',
			JOBS = { ripperdoc = true, trauma = true },
			NODES = {
				{ id = 'ripperdoc_1', NAME = 'skills.node.ripperdoc1', DESC = 'skills.desc.ripperdoc1',
					PERK = 'ripperdoc.precision', VALUE = 5, COST = 1 },
				{ id = 'ripperdoc_2', NAME = 'skills.node.ripperdoc2', DESC = 'skills.desc.ripperdoc2',
					PERK = 'ripperdoc.triage', VALUE = 10, COST = 1 },
				{ id = 'ripperdoc_3', NAME = 'skills.node.ripperdoc3', DESC = 'skills.desc.ripperdoc3',
					PERK = 'ripperdoc.calibration', VALUE = 15, COST = 2 },
				{ id = 'ripperdoc_4', NAME = 'skills.node.ripperdoc4', DESC = 'skills.desc.ripperdoc4',
					PERK = 'ripperdoc.surgery', VALUE = 20, COST = 2 },
				{ id = 'ripperdoc_5', NAME = 'skills.node.ripperdoc5', DESC = 'skills.desc.ripperdoc5',
					PERK = 'ripperdoc.mastery', VALUE = 30, COST = 3 },
			},
		},
		{
			-- THE TOP OF THE TREE: the last trunk is drawn as the apex, and its
			-- last node is the highest a character can reach.
			id = 'fixer',
			NAME = 'skills.branch.fixer',
			FEED = 'skills.feed.fixer',
			ICON = 'star',
			JOBS = { fixer = true, merc = true },
			NODES = {
				{ id = 'fixer_1', NAME = 'skills.node.fixer1', DESC = 'skills.desc.fixer1',
					PERK = 'fixer.contacts', VALUE = 5, COST = 1 },
				{ id = 'fixer_2', NAME = 'skills.node.fixer2', DESC = 'skills.desc.fixer2',
					PERK = 'fixer.cut', VALUE = 10, COST = 1 },
				{ id = 'fixer_3', NAME = 'skills.node.fixer3', DESC = 'skills.desc.fixer3',
					PERK = 'fixer.afterlife', VALUE = 15, COST = 2 },
				{ id = 'fixer_4', NAME = 'skills.node.fixer4', DESC = 'skills.desc.fixer4',
					PERK = 'fixer.kingmaker', VALUE = 20, COST = 2 },
				{ id = 'fixer_5', NAME = 'skills.node.fixer5', DESC = 'skills.desc.fixer5',
					PERK = 'fixer.legend', VALUE = 30, COST = 3 },
			},
		},
	},
}
