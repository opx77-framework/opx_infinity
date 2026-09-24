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
-- how fast the score falls, who may answer, and -- since the engine's own route
-- was measured to refuse it -- the MaxTac AV's insertion run. The engine's: the
-- six stages, the response each one already has wired to it, and every vehicle
-- and character record below.
--
-- THE AV IS SUMMONED THROUGH THE ENGINE AND, WHEN THAT IS REFUSED, FLOWN BY US.
-- `gamePreventionSpawnSystem.RequestAVSpawn` is the engine's own route and the
-- bridge asks for it (`prevention.av`). On the live node it answers
-- `prevention.av.ticket.0` -- the call lands, no aircraft is scheduled, nothing
-- renders for anybody -- so `MAXTAC.AV.INSERTION` below is the run the server
-- flies instead, on an Open77 vehicle every client can see. The airframe's
-- authored visuals (jet flames, thrusters, the model's own lights) come with
-- the record; the red warning lines are a property of the entity template and
-- its AI package (`av_spawn_setup`, `summonDistanceMin/Max`, `verticalOffset`)
-- and an unoccupied server-flown AV cannot command them, so what this feature
-- does about them is keep the aircraft's lights on and point its nose at the
-- player it came for.
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
	-- ── the call-out ────────────────────────────────────────────────────────
	--
	-- WHO IS TOLD THAT THE CITY HAS A PROBLEM. A stage that RISES is broadcast
	-- to every player who is ON DUTY in one of the jobs below, with the place it
	-- happened: this is the half of a wanted level a roleplay server has and a
	-- bot response cannot be -- the engine's units answer on their own, and the
	-- people PLAYING the police go and do it because somebody told them.
	--
	-- IT SPAWNS NOTHING AND REPLACES NOTHING. The engine's own units and this
	-- module's response are already on their way when it runs, so a call-out
	-- that fails to send cannot leave the city unprotected; what it costs is
	-- that the people playing the police never hear about it, which is why the
	-- count and the failure are both journalled rather than swallowed.
	--
	-- A RISE, AND ONLY A RISE. Every poll that crosses a stage passes through the
	-- same function, and so does the ledger's own decay back to zero --
	-- repeatedly, once per poll. Neither is news. What is news is the instant a
	-- stage goes up.
	ALERTS = {
		enabled = true,

		-- The heat stage a call-out is worth making at, 1..5. Stage 1 is a
		-- wanted player; a server that wants radio silence until somebody is
		-- actually dangerous raises this.
		MIN_STAGE = 1,

		-- Which jobs are on the air. A player is on call when their PRIMARY job
		-- is one of these AND they are ON DUTY -- duty is the character
		-- module's own field and not a second one, so a clocked-off officer
		-- hears nothing, which is what clocking off is for.
		JOBS = { 'ncpd', 'maxtac', 'ncpd_maxtac' },

		-- Floor between two call-outs about the SAME suspect, so one firefight
		-- that climbs three stages is one message rather than three.
		COOLDOWN_MS = 20000,

		-- Metres a suspect's position is rounded to before it is named. A
		-- call-out is radio traffic and not a coordinate: ten metres is a place
		-- somebody can walk to, and it does not hand every officer a
		-- metre-perfect fix on a player who is trying to get away.
		ROUND_METRES = 10.0,

		-- Whether the call-out names the suspect. Off is the setting for a
		-- server whose radio should not be a nameplate detector.
		NAME_SUSPECT = true,
	},

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

			-- THE INSERTION RUN. The engine's own route -- `RequestAVSpawn`, asked
			-- for by the client as `prevention.av` -- answers `ticket 0` on the
			-- live node: the call lands, no aircraft is scheduled, and the only
			-- thing on the street is the squad the response placed there. So the
			-- AV below is an Open77 vehicle flown by the server. Every number here
			-- is metres, seconds or milliseconds, and the order the aircraft flies
			-- is: APPROACH_METRES out at APPROACH_ALTITUDE, in over CRUISE_SECONDS
			-- to HOVER_ALTITUDE, down over DESCENT_SECONDS to DROP_ALTITUDE, hold
			-- DEPLOY_SECONDS while the squad steps out, back up to HOVER_ALTITUDE,
			-- hold HOVER_SECONDS, then out and away over EXIT_SECONDS.
			INSERTION = {
				APPROACH_METRES = 320.0,
				APPROACH_ALTITUDE = 95.0,
				HOVER_ALTITUDE = 26.0,
				DROP_ALTITUDE = 5.0,
				CRUISE_SECONDS = 6.0,
				DESCENT_SECONDS = 3.5,
				DEPLOY_SECONDS = 2.5,
				HOVER_SECONDS = 14.0,
				EXIT_SECONDS = 6.0,
				-- The pose cadence. `setTransform` revokes the physics lease and
				-- republishes the canonical transform on every call, so this is a
				-- cost on every viewer: ten a second is smooth at cruise and does
				-- not make one aircraft the most expensive thing in the bucket.
				TICK_MS = 100,
			},
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

		-- THE CREW DOOR. A MaxTac worker walks up to the aircraft while it holds
		-- at the street and presses `KEY.DEFAULT` to get aboard.
		--
		-- THE MOUNT IS THE PLATFORM'S, NOT OURS. Boarding is
		-- `Open77.vehicles.warpPlayerIntoVehicle(player, hull, seat,
		-- { moveBucket = false, exitLocked = true })` -- the host's own
		-- authoritative seat assignment, which reserves the seat, publishes the
		-- forced entry and keeps the order until the client confirms the native
		-- mount. Proximity and the vehicle's locked flag are bypassed by that
		-- call on purpose: the reach rule below is OURS and is decided from the
		-- player's position as the SERVER reads it, never from the client's.
		--
		-- THE HULL IS HANDED OVER, NOT SHARED. The aircraft is flown by the
		-- server while nobody is aboard (`setTransform` per tick). A player
		-- seated in an AV is its pilot as far as the platform is concerned --
		-- `VehicleReplication` lets a seated client claim an AV at ANY seat --
		-- so the moment somebody boards, this run STOPS POSING the hull, clears
		-- its freeze and lets the crew fly it. Two hands on one airframe at
		-- 10 Hz is a fight, not a ride.
		--
		-- NOBODY IS EVER DROPPED. A crew member is released when the aircraft is
		-- down and at rest (see `REST_SPEED`), when the insertion is retracted,
		-- or when this module stops. The aircraft is only removed from the world
		-- when no player holds a seat in it.
		BOARDING = {
			ENABLED = true,
			-- Who may board: the division's jobs, and only while ON DUTY. The
			-- check is the character module's own `job.onDuty`, the same one the
			-- call-out uses, so a clocked-off officer cannot take a seat.
			JOBS = { 'maxtac', 'ncpd_maxtac' },
			-- How long the aircraft holds at the street after the squad is out.
			-- This is the window the crew walks up in; it is also the window in
			-- which the row is on screen.
			SECONDS = 20.0,
			-- How close the asker has to be, measured by the server against the
			-- hull's own canonical transform. The aircraft holds at
			-- `AV.INSERTION.DROP_ALTITUDE`, so this is a radius around a hull 5 m
			-- up: a walkable distance, not a reach through a wall.
			REACH_METRES = 12.0,
			-- The seats a crew takes, in the order they fill. The pilot seat is
			-- not offered: any seat of an AV can fly it, and the seat closest to
			-- the door is the one a body reaches first.
			SEATS = { 'seat_front_right', 'seat_back_left', 'seat_back_right' },
			-- The strip row names the player's own binding; the id is what a
			-- rebind is stored under, so it must not change between builds.
			KEY = { ID = 'opx.ncpd.board', NAME = 'ncpd.key.board', DEFAULT = 'F' },
			-- While the hull is flying, an aboard body stays aboard: the exit lock
			-- goes up with the seat and comes off when the aircraft is down and
			-- slower than `REST_SPEED` for `REST_SECONDS`. "Down" is the hull
			-- within `REST_HEIGHT` metres of the height the insertion dropped at,
			-- because that is the last height this module knows the street to be
			-- at. Without all three numbers the lock is a trap -- a crew that can
			-- never step out of a parked aircraft.
			REST_SPEED = 2.0,
			REST_HEIGHT = 3.0,
			REST_SECONDS = 1.0,
			-- How often the crew's seats are read while they hold the hull.
			CUSTODY_MS = 1000,
		},
	},
}
