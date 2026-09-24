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
-- NCPD trunk, MaxTac work the air trunk, and everything a street job earns goes
-- to the street trunk. A point cannot buy into a rank the work has not reached,
-- which is what makes this a skill tree rather than a shop: the tree is a map
-- of what this character has actually done.
--
-- THE PERKS ARE DECLARED, NOT INVENTED. Each node names a perk id and a value.
-- Nothing in this repo applies them -- gameplay systems read them through
-- `OPX.Api.Get('skills', 1).Perk(citizenId, perkId)` when they want them, and a
-- server whose systems ignore the perks still has a tree that fills, ranks and
-- persists. The value on the node is content (rule 8): the one number the
-- surface may state as fact.
--
-- COSTS RAMP (1, 1, 2, 2, 3 per trunk). A level cap of 20 banks 19 points
-- against 27 points of nodes across the three trunks, so a character cannot
-- have everything and the choice is real.

OPX.Config.MODULES.skills = {
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

	BRANCHES = {
		{
			id = 'ncpd',
			NAME = 'skills.branch.ncpd',
			-- Work fed to this trunk. A job no trunk names falls to the trunk
			-- that declares no jobs at all (the street, below).
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
					PERK = 'ncpd.legend', VALUE = 25, COST = 3 },
			},
		},
		{
			id = 'maxtac',
			NAME = 'skills.branch.maxtac',
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
			id = 'street',
			NAME = 'skills.branch.street',
			-- THE CATCH-ALL: no jobs declared means every job no other trunk
			-- names -- hauling, gunsmithing, whatever the server runs.
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
					PERK = 'street.fixer', VALUE = 20, COST = 3 },
			},
		},
	},
}
