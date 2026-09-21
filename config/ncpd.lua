--- The law book: what is a crime, what it costs, and which division answers.
-- @author XEROX710
--
-- THE WANTED LEVEL IS A CRIME SCORE, NOT A FACT WE WRITE. The engine keeps
-- `m_totalCrimeScore` and raises `m_heatStage` (`EPreventionHeatStage.Heat_0 ..
-- Heat_5`) when the score reaches that stage's capacity, zeroing the score as it
-- crosses (`preventionSystem.script:2501`). The `wanted_level` quest fact is an
-- OUTPUT of that stage -- `TryUpdateWantedLevelFact` writes it `:2281`, and the
-- only reader in the whole script tree is a debug overlay `:4916` -- so setting
-- it moves nothing. This file therefore describes the SCORE, and the module
-- drives the engine's own ladder so the wanted bar, the siren stake, the police
-- radio and the spawn reinitialisation all happen inside the game's own path.
--
-- WHAT IS OURS AND WHAT IS THE ENGINE'S. Ours: which acts count, what they cost,
-- how fast the score falls, and who may answer. The engine's: the six stages,
-- the response each one already has wired to it, every vehicle and every
-- character record below, and the AV's own fly-in, propulsion note and red
-- warning lines -- those are properties of the entity template and its AI
-- package (`av_spawn_setup`, `summonDistanceMin/Max`, `verticalOffset`), so the
-- only thing this feature does about them is SUMMON them.
--
-- THE TWO DIVISIONS ARE THE ENGINE'S OWN SPLIT. `Heat_1 .. Heat_4` is the NCPD
-- ladder -- Cortes, Archer Hella, Emperor, Merrimac, and the Hellhound at
-- `Heat_5` -- and MaxTac is the separate division that arrives at `Heat_5` with
-- its own agent registry, its own tag (`MaxTac_NotPrevention`), its own status
-- effect (`BaseStatusEffect.MaxTacAlone`) and its own insertion vehicle. Both
-- are declared here so a server can run the police without MaxTac, or MaxTac
-- alone on a job, without editing any Lua.
--
-- A LAW IS { id, label, score, ceiling }. `ceiling` is the stage at or above
-- which that offence stops counting: a fist fight stops mattering once the city
-- is already hunting you, and murder-past-Heat_4 is what MaxTac is for. Unset
-- means no ceiling. The score scale is ours and deliberately small -- the
-- capacities below are the operator's dial, so a server that wants a slower city
-- raises them rather than editing every law.
--
-- Every value here is validated by `modules/ncpd/shared/law.lua` when the
-- resource loads, and a value it cannot use is named in a warning rather than
-- raised: a typo costs one law, not the session.

OPX.Config.MODULES.ncpd = {
	enabled = true,

	-- The two divisions, by the name the log and the HUD use. `LADDER` names one
	-- per stage; this table is what those names are checked against.
	DIVISIONS = {
		ncpd = { label = 'NCPD' },
		maxtac = { label = 'MaxTac' },
	},

	-- WHO ANSWERS AT EACH NCPD STAGE. The ground roster the module spawns when a
	-- stage's response has to put somebody on the street, and the records are the
	-- platform's own verified police peds (`modules/admin/data/peds.lua`). MaxTac
	-- has its own two rosters below, because the division is separable.
	--
	-- `RESPONSE.UNITS` on a ladder row is how many of these stand at the scene;
	-- `RESPONSE.VEHICLES` is the cars they arrive in. A record the client cannot
	-- resolve is a refused spawn, journalled by name, not a silent nothing.
	NCPD = {
		OFFICERS = {
			'Character.ncpd_base_ma',
			'Character.ncpd_base_wa',
			'Character.ncpd_base_mb',
		},
		-- The roadblock, when a stage declares `ROADBLOCK = true`: cars placed
		-- across the road, locked and immortal so the blockade is an obstacle to
		-- drive around rather than a wall that can be removed with a bumper.
		ROADBLOCK = {
			CARS = 2,
			SPACING_METERS = 4.0,
			AHEAD_METERS = 12.0,
			OFFICERS = 2,
		},
	},

	-- THE LADDER, KEYED BY THE ENGINE'S OWN HEAT NUMBER. `[0]` is `Heat_0` -- not
	-- wanted -- so a row's key is the heat stage it describes, and the `heat` name
	-- beside it is documentation of that: the validator refuses a row whose name
	-- and key disagree, which is how an inserted stage is caught instead of
	-- quietly handing one heat stage another's threshold.
	--
	-- CAPACITY is the score at which the player LEAVES that stage: the engine
	-- zeroes the accumulated score and raises the stage, once per crime, which is
	-- why the numbers climb -- the fifth star is meant to be hard to reach and
	-- harder to keep. `Heat_5`'s capacity is never used to advance (there is
	-- nothing above it) and is kept so a listing can print the whole ladder.
	--
	-- VEHICLES are the engine's own prevention records (`prevention_vehicles.tweak`),
	-- spelled the way a spawn call names them. A stage with no VEHICLES is a stage
	-- whose response is on foot, which is `Heat_1`'s whole point.
	--
	-- No AV here: the air unit at `Heat_5` belongs to the MaxTac division below,
	-- because that is where the engine puts it.
	LADDER = {
		[0] = {
			heat = 'Heat_0',
			-- Nobody answers at Heat_0, which is what makes it Heat_0 -- so this is
			-- the one row with no division -- but its capacity is the threshold the
			-- whole ladder is entered by: the score that makes a player wanted.
			division = nil,
			CAPACITY = 50.0,
			RESPONSE = { UNITS = 0, VEHICLES = {}, ROADBLOCK = false },
		},
		[1] = {
			heat = 'Heat_1',
			division = 'ncpd',
			CAPACITY = 120.0,
			RESPONSE = {
				UNITS = 2,
				VEHICLES = { 'Vehicle.ncpd_villefort_cortes_heat_1' },
				ROADBLOCK = false,
			},
		},
		[2] = {
			heat = 'Heat_2',
			division = 'ncpd',
			CAPACITY = 220.0,
			RESPONSE = {
				UNITS = 3,
				VEHICLES = {
					'Vehicle.ncpd_villefort_cortes_heat_2',
					'Vehicle.ncpd_archer_hella_heat_2',
					'Vehicle.ncpd_brennan_apollo_bike',
				},
				ROADBLOCK = false,
			},
		},
		[3] = {
			heat = 'Heat_3',
			division = 'ncpd',
			CAPACITY = 350.0,
			RESPONSE = {
				UNITS = 4,
				VEHICLES = {
					'Vehicle.ncpd_archer_hella_heat_3',
					'Vehicle.ncpd_villefort_cortes_heat_2',
				},
				ROADBLOCK = false,
			},
		},
		[4] = {
			heat = 'Heat_4',
			division = 'ncpd',
			CAPACITY = 500.0,
			RESPONSE = {
				UNITS = 5,
				VEHICLES = {
					'Vehicle.ncpd_suv_chevalier_emperor_heat_4',
					'Vehicle.ncpd_thorton_merrimac_police_heat_4',
				},
				-- The engine's own roadblock takes the MaxTac AV record for its
				-- overflight; the blockade itself is four NCPD vehicles.
				ROADBLOCK = true,
			},
		},
		[5] = {
			heat = 'Heat_5',
			division = 'maxtac',
			-- Never used to advance. The Hellhound and MaxTac both belong to this
			-- stage, and what ends it is the squad dying, not the score.
			CAPACITY = 500.0,
			RESPONSE = {
				UNITS = 6,
				VEHICLES = { 'Vehicle.ncpd_hellhound_heat_5' },
				ROADBLOCK = true,
			},
		},
	},

	-- WHAT COUNTS AS A CRIME, AND WHAT IT COSTS. The engine's own weights are the
	-- reference for the shape -- a civilian kill (`HeatKillCiv`), a police kill
	-- (`HeatKillPolice`), and vehicle damage scaled by the percentage dealt
	-- (`PoliceVehicleCrimeScoreMultiplier`, `CivVehicleCrimeScoreMultiplier`) --
	-- and these are ours to tune. `group` is what a law listing and the ACL
	-- surface filter on; it carries no behaviour of its own.
	--
	-- `ceiling` is a STAGE. `ceiling = 2` means the offence adds nothing once the
	-- player is at `Heat_2` or above: it did not stop being a crime, the city
	-- simply has bigger things pointed at them.
	LAWS = {
		{ id = 'assault', label = 'Assault', score = 8.0, ceiling = 2, group = 'violence' },
		{ id = 'murder', label = 'Murder', score = 40.0, group = 'violence' },
		{ id = 'murderPolice', label = 'Murder of an officer', score = 70.0, group = 'violence' },
		{ id = 'discharge', label = 'Discharging a weapon in public', score = 5.0, ceiling = 3, group = 'violence' },
		{ id = 'resisting', label = 'Resisting arrest', score = 20.0, ceiling = 4, group = 'obstruction' },
		{ id = 'vehicleTheft', label = 'Vehicle theft', score = 25.0, group = 'property' },
		{ id = 'vehicleDamage', label = 'Damaging a vehicle', score = 15.0, group = 'property' },
		{ id = 'propertyDamage', label = 'Property damage', score = 10.0, group = 'property' },
		{ id = 'trespass', label = 'Trespassing', score = 3.0, ceiling = 1, group = 'minor' },
		{ id = 'contraband', label = 'Contraband', score = 12.0, group = 'minor' },
		{ id = 'jobHeat', label = 'Job heat', score = 30.0, group = 'job' },
	},

	-- A district multiplier scales every score earned inside it. An unlisted
	-- district is 1.0, so a new district needs no entry -- and the names are the
	-- game's own districts, matched case-insensitively by the module.
	DISTRICTS = {
		watson = 1.0,
		westbrook = 1.2,
		['city_center'] = 1.5,
		heywood = 1.1,
		santo_domingo = 1.0,
		pacifica = 0.8,
		badlands = 0.6,
	},

	-- HOW THE SCORE FALLS. `HOLD_SECONDS` is how long a score survives a player
	-- who stops; after that it drains at `PER_SECOND`, and a player who has done
	-- nothing for `RESET_SECONDS` is dropped to zero outright -- the soft version
	-- of the engine's own `HeatCrimeScoreResetTime` zeroing, which is a hard
	-- timer inside `PreventionSystem`.
	DECAY = {
		HOLD_SECONDS = 15.0,
		PER_SECOND = 2.0,
		RESET_SECONDS = 90.0,
	},

	-- MAXTAC: the division that arrives when the NCPD ladder has failed.
	--
	-- WHO ANSWERS. A player is offered a seat in the squad if they hold
	-- `OPT_IN.RIGHT` or their job is one of `OPT_IN.JOBS`. Any seat still empty
	-- when `RESPONSE_SECONDS` have passed is filled by the engine's own troopers
	-- -- `FILL = 'bots'` -- so the squad always arrives: an empty division must
	-- not mean an empty street. `FILL = 'players'` is legal and makes the job
	-- player-only, which is a choice a server may want on a job night.
	MAXTAC = {
		STAGE = 5,
		HEAT = 'Heat_5',
		OPT_IN = {
			RIGHT = 'opx.ncpd.maxtac',
			JOBS = { 'maxtac', 'ncpd_maxtac' },
		},
		FILL = 'bots',
		RESPONSE_SECONDS = 20.0,

		-- The insertion. `Vehicle.max_tac_av` is a Zetatech Surveyor in MaxTac
		-- camo carrying a rifleman, a mantis-blade, a netrunner and an elite
		-- sniper; the variants below are the same airframe with swapped crew
		-- (`max_tac_av2` carries the LMG), and the `2nd_wave` set is what the
		-- engine sends after a squad is wiped. ONE_AT_A_TIME is the engine's own
		-- rule (`CanRequestAVSpawn` refuses a second), kept here so a server
		-- cannot ask for two and be silently refused.
		AV = {
			RECORD = 'Vehicle.max_tac_av',
			VARIANTS = { 'max_tac_av1', 'max_tac_av2', 'max_tac_av3', 'max_tac_av_LMG_mb' },
			SECOND_WAVE = { 'max_tac_av_2nd_wave1', 'max_tac_av_2nd_wave2', 'max_tac_av_2nd_wave3' },
			ONE_AT_A_TIME = true,
			COOLDOWN_SECONDS = 90.0,
			-- Metres above the pad a requested AV is placed, so it does not start
			-- half-buried: an AV record's pivot is the chassis centre.
			LIFT = 1.2,
		},

		-- The ground division: the Merrimac in MaxTac livery, and the two troopers
		-- that arrive with it.
		VEHICLE = 'Vehicle.ncpd_suv_thorton_merrimac_maxtac',
		-- NAMES THAT EXIST IN THIS BUILD'S TweakDB. `prevention_maxtac_wa` was
		-- written here for a year of passes and does not exist: the engine's
		-- ground-trooper pair is `..._rifle_ma` and `..._rifle_wa`. A record that
		-- does not exist is refused by the client (`npc_record_not_found`), the
		-- car still pulls up, and the division that arrives is EMPTY -- which is
		-- what "two trucks that get stuck and are not moving or fighting me" was.
		-- `tests/run.lua` now checks every name below against the 2.31 dump in
		-- `docs/generated/npc-records-2.31.csv`, so a name the engine cannot
		-- answer fails the suite instead of shipping an empty car.
		GROUND = {
			'Character.prevention_maxtac_rifle_ma',
			'Character.prevention_maxtac_rifle_wa',
		},

		-- The AV-borne family, in the order the engine's own record lists them.
		-- These are the bots a player seat falls back to.
		TROOPERS = {
			'Character.maxtac_av_riffle_ma',
			'Character.maxtac_av_mantis_wa',
			'Character.maxtac_av_netrunner_ma',
			'Character.maxtac_av_sniper_wa_elite',
		},

		-- A MaxTac NPC spawned outside the prevention system carries its own tag
		-- and its own heat rule; both are the engine's, and both are named here so
		-- a spawn call cannot quietly forget them.
		TAG = 'MaxTac_NotPrevention',
		ALONE_EFFECT = 'BaseStatusEffect.MaxTacAlone',

		-- The squad a summon aims for, and how far a trooper may be from the
		-- insertion point before it is recalled rather than left behind.
		SQUAD = {
			SEATS = 4,
			WAVES = 3,
			INSERTION_RADIUS = 40.0,
		},
	},
}
