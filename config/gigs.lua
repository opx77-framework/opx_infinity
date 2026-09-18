--- Petits boulots: the gate, the pace, and every gig on the board.
-- @author dop42
--
-- A gig is NOT a job. Nothing here calls `SetJob`, nothing writes a grade and no
-- character comes out of a run holding anything but eddies, an item or a point of
-- reputation. It is day work for someone who logged in an hour ago: walk to a
-- point, hold the target key, do the thing, get paid.
--
-- Each gig is one entry of `GIGS`, and `ENABLED = false` takes that one off the
-- board while leaving the rest running. `enabled = false` at the top takes the
-- whole module off, board rows included.
--
-- TWO KINDS, and they are the same machine underneath. The server turns a gig
-- into a LIST OF LEGS at the moment a run starts and hands the client one leg at
-- a time; the client never learns the rest of the route.
--
--   collect  STEPS legs drawn from POINTS, then the DROPOFF leg when there is
--            one. Rubbish, cans, scrap: gather, then hand in.
--   courier  STEPS times the pair (PICKUP leg, one leg drawn from POINTS).
--            Noodles, a shard, a parcel: fetch, carry, repeat.
--
-- EVERY COORDINATE BELOW IS A PLACEHOLDER. They are in the right shape and the
-- right part of the map, and not one of them has been stood on. Run `opx.here`
-- in game at the spot you want and paste what it prints. A gig whose points are
-- wrong is a gig whose target rows answer over thin air.
--
-- LABEL, DESCRIPTION and a point's LABEL are the operator's own words and are
-- never translated; everything the module says for itself lives in
-- `modules/gigs/locales.lua`.

OPX.Config.MODULES.gigs = {
	enabled = true,

	-- Draw a vanilla mappin on the point the run is waiting for, and on every
	-- gig's start point. Needs `ui.vanilla.map` in the manifest; without the
	-- permission the module says so once and runs on target rows alone.
	BLIPS = true,

	-- Also move the player's own waypoint to each leg. Off by default: it
	-- replaces whatever they were tracking, which is theirs and not ours.
	WAYPOINT = false,

	-- Toast every leg, every payout and every refusal.
	NOTIFY = true,

	-- Offer "give up" on the player's own body through the target eye. The
	-- command works either way.
	ABANDON_ROW = true,

	-- Milliseconds a run may stand still before the server drops it. A player who
	-- logs out mid-run loses it at once; this is for the one who wandered off.
	RUN_TIMEOUT_MS = 1800000,

	-- Milliseconds between two sweeps of the abandoned runs.
	SWEEP_MS = 30000,

	-- Requests one player may send per window, across every gig. A leg costs one.
	RATE = { WINDOW_MS = 10000, REQUESTS = 12 },

	-- Metres the eye must be within to work a leg, and the radius of the sphere
	-- its row answers inside.
	REACH = 2.5,
	POINT_RADIUS = 1.6,

	-- NAME = false registers no command. Neither is restricted: both act on the
	-- caller alone.
	COMMANDS = {
		LIST = 'opx.gigs',
		CANCEL = 'opx.gig.cancel',
	},

	-- Where the reputation and the daily counters are kept on the character. One
	-- metadata key holds the whole table; it is persisted with the character row,
	-- which is why this module contributes no table of its own.
	METADATA_KEY = 'gigs',

	GIGS = {
		-- rubbish ------------------------------------------------------------
		trash = {
			ENABLED = true,
			KIND = 'collect',
			LABEL = 'NC SANITATION / JOURNALIER',
			DESCRIPTION = 'Ramasser les sacs laissés dans les ruelles et les porter au compacteur.',
			ICON = 'box',

			-- Where the run is taken. A target row stands here for as long as the
			-- module runs.
			START = { X = -684.20, Y = 1421.65, Z = 12.40, BUCKET = 0 },

			-- Legs drawn from POINTS, without repeating one inside a run.
			STEPS = 6,
			ACTION_MS = 4500,
			ANIMATION = 'examine',

			POINTS = {
				{ X = -691.10, Y = 1408.80, Z = 12.35, LABEL = 'Benne, arrière du bar' },
				{ X = -702.45, Y = 1415.20, Z = 12.30, LABEL = 'Sacs contre le mur' },
				{ X = -698.70, Y = 1432.90, Z = 12.55, LABEL = 'Cartons éventrés' },
				{ X = -676.35, Y = 1436.10, Z = 12.60, LABEL = 'Bacs renversés' },
				{ X = -668.90, Y = 1424.45, Z = 12.45, LABEL = 'Coin du kiosque' },
				{ X = -671.20, Y = 1410.05, Z = 12.35, LABEL = "Grille d'aération" },
				{ X = -709.80, Y = 1424.70, Z = 12.40, LABEL = "Bas de l'escalier" },
				{ X = -686.55, Y = 1444.30, Z = 12.70, LABEL = 'Passage couvert' },
			},

			DROPOFF = { X = -683.40, Y = 1418.90, Z = 12.40,
				LABEL = 'Compacteur', ACTION_MS = 6000, ANIMATION = 'give' },

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 11, MAX = 19 },
				BONUS = { MIN = 45, MAX = 80 },
			},
			-- Rolled once at the end of a completed run. CHANCE is a percentage.
			ITEMS = {
				{ NAME = 'water', COUNT = 1, CHANCE = 60 },
				{ NAME = 'scrap_metal', COUNT = 1, CHANCE = 25 },
			},

			COOLDOWN_MS = 120000,
			MAX_RUNS_PER_DAY = 10,
			MIN_REPUTATION = 0,
			REPUTATION = 1,
		},

		-- consigne -----------------------------------------------------------
		cans = {
			ENABLED = true,
			KIND = 'collect',
			LABEL = 'CONSIGNE / CANETTES',
			DESCRIPTION = 'Les canettes valent trois eddies pièce. Il en faut beaucoup.',
			ICON = 'box',

			START = { X = -1198.55, Y = 336.20, Z = 8.85, BUCKET = 0 },

			STEPS = 8,
			ACTION_MS = 2600,
			ANIMATION = 'examine',

			POINTS = {
				{ X = -1205.30, Y = 327.45, Z = 8.80, LABEL = 'Sous le banc' },
				{ X = -1191.85, Y = 344.10, Z = 8.90, LABEL = 'Bordure du trottoir' },
				{ X = -1213.60, Y = 349.75, Z = 8.95, LABEL = 'Grille du caniveau' },
				{ X = -1187.20, Y = 320.90, Z = 8.75, LABEL = 'Pied du lampadaire' },
				{ X = -1176.95, Y = 338.40, Z = 8.85, LABEL = 'Arrêt de bus' },
				{ X = -1220.10, Y = 331.55, Z = 8.90, LABEL = 'Derrière le distributeur' },
				{ X = -1199.40, Y = 356.25, Z = 9.05, LABEL = 'Muret du parking' },
				{ X = -1183.75, Y = 351.80, Z = 8.95, LABEL = 'Jardinière' },
				{ X = -1210.05, Y = 316.30, Z = 8.70, LABEL = 'Entrée de service' },
				{ X = -1168.40, Y = 329.15, Z = 8.80, LABEL = "Sous l'escalier" },
			},

			DROPOFF = { X = -1197.80, Y = 337.95, Z = 8.85,
				LABEL = 'Automate de consigne', ACTION_MS = 4000, ANIMATION = 'give' },

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 3, MAX = 6 },
				BONUS = { MIN = 20, MAX = 35 },
			},
			ITEMS = {
				{ NAME = 'nicola', COUNT = 1, CHANCE = 45 },
			},

			COOLDOWN_MS = 90000,
			MAX_RUNS_PER_DAY = 12,
			MIN_REPUTATION = 0,
			REPUTATION = 1,
		},

		-- ferraille ----------------------------------------------------------
		scrap = {
			ENABLED = true,
			KIND = 'collect',
			LABEL = 'FERRAILLE / TRI SAUVAGE',
			DESCRIPTION = 'Sortir ce qui se revend des tas de gravats. Gants conseillés.',
			ICON = 'tool',

			START = { X = -1602.75, Y = -320.40, Z = 4.20, BUCKET = 0 },

			STEPS = 5,
			ACTION_MS = 6500,
			ANIMATION = 'examine',

			POINTS = {
				{ X = -1614.20, Y = -331.85, Z = 4.15, LABEL = 'Tas de gravats' },
				{ X = -1595.60, Y = -338.30, Z = 4.10, LABEL = 'Tôle froissée' },
				{ X = -1621.95, Y = -312.55, Z = 4.25, LABEL = 'Carcasse de climatiseur' },
				{ X = -1588.10, Y = -305.70, Z = 4.30, LABEL = 'Palettes cassées' },
				{ X = -1630.45, Y = -327.10, Z = 4.05, LABEL = 'Bobine de câble' },
				{ X = -1580.85, Y = -324.60, Z = 4.20, LABEL = 'Bac de chantier' },
			},

			DROPOFF = { X = -1601.30, Y = -318.95, Z = 4.20,
				LABEL = 'Peseuse du ferrailleur', ACTION_MS = 7000, ANIMATION = 'give' },

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 18, MAX = 28 },
				BONUS = { MIN = 60, MAX = 110 },
			},
			ITEMS = {
				{ NAME = 'scrap_metal', COUNT = 2, CHANCE = 80 },
				{ NAME = 'electronics', COUNT = 1, CHANCE = 30 },
			},

			COOLDOWN_MS = 180000,
			MAX_RUNS_PER_DAY = 6,
			MIN_REPUTATION = 2,
			REPUTATION = 2,
		},

		-- livraison ----------------------------------------------------------
		noodles = {
			ENABLED = true,
			KIND = 'courier',
			LABEL = 'LIVRAISON / STAND DE NOUILLES',
			DESCRIPTION = 'Prendre une barquette au stand, la porter chaude, recommencer.',
			ICON = 'location',

			START = { X = -1442.30, Y = 762.85, Z = 22.15, BUCKET = 0 },

			-- Four round trips: the stand, then a customer drawn from POINTS.
			STEPS = 4,
			ACTION_MS = 3000,
			ANIMATION = 'give',

			-- Where each leg starts from. A courier gig needs one.
			PICKUP = { X = -1441.05, Y = 764.20, Z = 22.15,
				LABEL = 'Comptoir du stand', ACTION_MS = 3500, ANIMATION = 'examine' },

			POINTS = {
				{ X = -1456.70, Y = 771.40, Z = 22.30, LABEL = 'Palier du 2e' },
				{ X = -1428.95, Y = 755.10, Z = 22.05, LABEL = 'Loge du parking' },
				{ X = -1463.25, Y = 749.80, Z = 21.95, LABEL = 'Terrasse, table du fond' },
				{ X = -1435.60, Y = 782.35, Z = 22.45, LABEL = "Boutique d'en face" },
				{ X = -1470.15, Y = 766.90, Z = 22.25, LABEL = 'Cabine du gardien' },
				{ X = -1420.40, Y = 773.55, Z = 22.20, LABEL = 'Atelier du coin' },
			},

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 22, MAX = 34 },
				BONUS = { MIN = 50, MAX = 90 },
			},
			ITEMS = {
				{ NAME = 'burrito', COUNT = 1, CHANCE = 50 },
			},

			COOLDOWN_MS = 150000,
			MAX_RUNS_PER_DAY = 8,
			MIN_REPUTATION = 1,
			REPUTATION = 2,
		},

		-- two gigs written and left switched off ------------------------------

		-- No drop-off point: every flyer put up pays on its own.
		flyers = {
			ENABLED = false,
			KIND = 'collect',
			LABEL = 'PROMO / BRAINDANCE',
			DESCRIPTION = 'Coller les affiches là où on les verra. Ne pas se faire prendre.',
			ICON = 'info',

			START = { X = -1520.90, Y = 895.30, Z = 42.10, BUCKET = 0 },

			STEPS = 7,
			ACTION_MS = 3200,
			ANIMATION = 'give',

			POINTS = {
				{ X = -1531.45, Y = 902.70, Z = 42.10, LABEL = 'Pilier ouest' },
				{ X = -1509.20, Y = 888.15, Z = 42.05, LABEL = 'Vitrine condamnée' },
				{ X = -1526.80, Y = 878.90, Z = 42.00, LABEL = 'Abribus' },
				{ X = -1543.35, Y = 893.55, Z = 42.15, LABEL = 'Mur du passage' },
				{ X = -1514.60, Y = 911.20, Z = 42.20, LABEL = "Cage d'escalier" },
				{ X = -1537.05, Y = 915.85, Z = 42.25, LABEL = 'Porte de service' },
				{ X = -1502.75, Y = 901.40, Z = 42.10, LABEL = 'Borne publicitaire' },
				{ X = -1548.90, Y = 880.30, Z = 42.00, LABEL = 'Rideau de fer' },
			},

			DROPOFF = false,

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 14, MAX = 22 },
				BONUS = { MIN = 0, MAX = 0 },
			},
			ITEMS = {},

			COOLDOWN_MS = 120000,
			MAX_RUNS_PER_DAY = 8,
			MIN_REPUTATION = 0,
			REPUTATION = 1,
		},

		-- The only one that asks for reputation: it pays, and it can be walked.
		courier = {
			ENABLED = false,
			KIND = 'courier',
			LABEL = 'COURSIER / PLI SCELLÉ',
			DESCRIPTION = "On ne demande pas ce qu'il y a sur le shard. On le porte.",
			ICON = 'talk',

			START = { X = -1875.40, Y = 236.15, Z = 6.10, BUCKET = 0 },

			STEPS = 2,
			ACTION_MS = 4000,
			ANIMATION = 'give',

			PICKUP = { X = -1876.85, Y = 234.70, Z = 6.10,
				LABEL = 'Casier du vestiaire', ACTION_MS = 5000, ANIMATION = 'examine' },

			POINTS = {
				{ X = -1902.30, Y = 251.45, Z = 6.35, LABEL = 'Parking, niveau -1' },
				{ X = -1849.75, Y = 219.80, Z = 5.95, LABEL = 'Arrière de la laverie' },
				{ X = -1888.10, Y = 208.55, Z = 5.90, LABEL = 'Quai de livraison' },
				{ X = -1861.95, Y = 262.20, Z = 6.40, LABEL = "Toit de l'annexe" },
			},

			PAY = {
				TYPE = 'EDDIES',
				PER_STEP = { MIN = 60, MAX = 95 },
				BONUS = { MIN = 120, MAX = 200 },
			},
			ITEMS = {
				{ NAME = 'shard', COUNT = 1, CHANCE = 20 },
			},

			COOLDOWN_MS = 600000,
			MAX_RUNS_PER_DAY = 3,
			MIN_REPUTATION = 8,
			REPUTATION = 3,
		},
	},
}
