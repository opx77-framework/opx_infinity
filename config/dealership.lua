--- Where vehicles and AVs are sold, what they cost, and where the bought one goes.
-- @author XEROX710
--
-- A dealer is a PLACE, exactly like a garage spot: a marker is drawn where the
-- operator put it, and the server re-derives the player's distance to the
-- DECLARED position before money moves. A dealer captured in game lives in the
-- database and is merged over this table key by key -- `/opx.dealership.add` is
-- what writes it.
--
-- KIND is carried over from the garages vocabulary and means the same two
-- things, because a dealership and a garage are the same two categories of
-- thing: a `garage` dealer sells ground vehicles and stands a player on a
-- cylinder, an `avpad` dealer sells AVs and stands them on a landing ring.
-- What a dealer may sell is therefore decided by its kind AND by the record:
-- an AV record is refused at a `garage` dealer whatever its row says.
--
-- X, Y and Z are validated, and only X and Y are measured against. HEADING is
-- the yaw a vehicle handed over here is created with, which is why `add` asks
-- the operator's own client for a facing exactly as the garages command does --
-- a chat line has no facing of its own.
--
-- The marker vocabulary is the engine's, not this file's: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500.

OPX.Config.MODULES.dealership = {
	enabled = true,

	-- What a price is denominated in. The character contract refuses anything
	-- that is not one of its own money types, and a bad value here is a boot
	-- line rather than a purchase that fails in a way nobody can read.
	CURRENCY = 'EDDIES',

	-- Hand the bought vehicle over AT THE DEALER, so the buyer drives it away,
	-- rather than only filing it in the garage they chose. Either way the row is
	-- registered under that garage's key, so it comes out there afterwards --
	-- a car handed over and abandoned is stored where it was sold and fetched
	-- where it belongs. A hand-over that is refused (no room, the host said no)
	-- does NOT undo the sale: the vehicle is owned and parked, and the refusal
	-- is reported.
	HAND_OVER = true,

	-- Flat metres from the declared X and Y within which a dealer may be used.
	USE_RADIUS = 4.0,

	-- What a dealer's marker looks like, per kind. The engine's own presets.
	MARKER = {
		garage = { shape = 'cylinder', style = 'interaction', RADIUS = 2.5 },
		avpad = { shape = 'ring', style = 'interaction', RADIUS = 3.5 },
	},

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2. A ring left at exact
	-- floor height is co-planar with the floor and draws nothing at all.
	GROUND_OFFSET = 0.06,

	-- Metres above the dealer an AV is handed over, so it does not start
	-- half-buried: an AV record's pivot is the chassis centre.
	AV_LIFT = 1.2,

	-- An AV record starts with one of these, lower-cased. The same rule the
	-- garages module and `open77_avcleanup` use, so a record is in the air
	-- category for every part of the server or for none of it.
	AV_PREFIXES = { 'vehicle.av_', 'vehicle.max_tac_av' },

	-- The marker/scan loop, and how often the client re-asks for its list so a
	-- change of routing bucket is picked up without a rejoin.
	SCAN_MS = 500,
	POLL_MS = 15000,

	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,
	-- How long `add` waits for the client's answer before it says the capture
	-- did not happen.
	CAPTURE_TIMEOUT_MS = 5000,
	-- Floor between two purchases from one connection. Long enough that a
	-- double-tap on a menu row is one purchase and not two.
	COOLDOWN_MS = 3000,

	-- The key that opens the dealership's own list while a player stands on one.
	-- ID is stable, because a player's rebind is stored under it.
	-- THE GARAGES KEY, deliberately: a dealer and a garage spot are the same kind of
	-- thing to a player -- stand on the marker, press E -- and two places that are
	-- the same thing must not be two different keys. `opx.garages.use` is a separate
	-- MAPPING and not a separate key, so a player who rebinds one does not move the
	-- other.
	KEY = { ID = 'opx.dealership.use', NAME = 'dealership.key.use', DEFAULT = 'E' },

	-- THE LIST IS A PANEL, NOT A STRIP. Every other menu in this resource hangs off
	-- an edge and is read in the corner of an eye; a dealership is a shop, and its
	-- stock is read standing still, both hands off the keyboard. So this one opens
	-- centred, at the size of the screen's own middle rather than a column, with
	-- enough rows that a class list does not have to be scrolled to be believed.
	--
	-- The size is SQUARE, and it is a height as well as a width: `WIDTH` and `HEIGHT`
	-- are the same number, so the panel is a square whatever the level holds -- the
	-- root class list is six rows and the garage picker is three, and either of them
	-- would draw a bar if the height were left to the rows. `VISIBLE_ROWS` is then
	-- how much of that square is rows: a row is 37 px and 4 px apart and the frame
	-- adds 44 and the hint 52, so fifteen of them measure 707 and fit in the 708.
	-- The menu module clamps every one of these (240..1200 px, 120..1200 px tall,
	-- 3..24 rows), so a typo here is a wrong size and never a menu that fails to
	-- open. `MAX_HEIGHT_VH` is the last guard: `max-height` beats `height` in CSS,
	-- so on a window shorter than this the panel is clipped rather than drawn off
	-- the screen -- 88 of a screen is 708 at about 805 px of height, and below that a
	-- 708 px square cannot fit at all, so clipping its bottom rows is the honest
	-- failure of the two.
	MENU = {
		ANCHOR = 'center',
		WIDTH = 708,
		HEIGHT = 708,
		MAX_HEIGHT_VH = 88,
		VISIBLE_ROWS = 15,
	},

	-- The three placement commands are ACL-gated, exactly as the garages ones
	-- are: they write a place every player uses. `stock` is a reading of the
	-- catalogue and `buy` acts on the caller alone, so both are open -- a player
	-- who has been granted nothing still has to be able to spend their money.
	COMMANDS = {
		add = 'opx.dealership.add',
		remove = 'opx.dealership.remove',
		list = 'opx.dealership.list',
		stock = 'opx.dealership.stock',
		buy = 'opx.dealership.buy',
	},

	-- WHAT IS FOR SALE, AND FOR HOW MUCH.
	--
	-- KEY is the durable name a purchase names and the name a row is routed by,
	-- so it must be unique and stable. LABEL is what a player reads and is never
	-- translated -- it is a car's name. CLASS groups the list, and is the
	-- operator's own word. RECORD is the exact TweakDB record handed to the
	-- vehicles contract, which is the only thing that decides what is created.
	-- PRICE is in CURRENCY above, and must be a whole number above zero: a free
	-- car is a stock-list mistake, not a giveaway, which is why zero is refused
	-- rather than honoured.
	--
	-- Whether a row is a vehicle or an AV is DERIVED from RECORD, never
	-- declared: one rule decides it (the AV prefixes above) and a row cannot
	-- disagree with itself about which category it is in.
	--
	-- The starter list is the platform's own validated `*_player` records, so a
	-- fresh server sells real cars on the first boot. Replace, extend or empty
	-- it: an empty list is a dealership that sells nothing, which the `stock`
	-- command says out loud.
	STOCK = {
		-- Street
		{ KEY = 'hella', LABEL = 'Archer Hella', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_archer_hella_player', PRICE = 29000 },
		{ KEY = 'bandit', LABEL = 'Archer Bandit', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_archer_bandit_player', PRICE = 31000 },
		{ KEY = 'quartz', LABEL = 'Archer Quartz', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_archer_quartz_player', PRICE = 34000 },
		{ KEY = 'cortes', LABEL = 'Villefort Cortes', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_villefort_cortes_player', PRICE = 36000 },
		{ KEY = 'galena', LABEL = 'Thorton Galena', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_thorton_galena_player', PRICE = 33000 },
		{ KEY = 'maimai', LABEL = 'Makigai MaiMai', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_makigai_maimai_player', PRICE = 21000 },
		{ KEY = 'thrax', LABEL = 'Chevalier Thrax', CLASS = 'Street',
			RECORD = 'Vehicle.v_standard2_chevalier_thrax_player', PRICE = 38000 },

		-- Sport
		{ KEY = 'r7', LABEL = 'Quadra Sport R-7', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_quadra_sport_r7_player', PRICE = 86000 },
		{ KEY = 'turbo', LABEL = 'Quadra Turbo-R', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_quadra_turbo_player', PRICE = 92000 },
		{ KEY = 'type66', LABEL = 'Quadra Type-66', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport2_quadra_type66_player', PRICE = 97000 },
		{ KEY = 'avenger', LABEL = 'Type-66 Avenger', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport2_quadra_type66_avenger_player', PRICE = 118000 },
		{ KEY = 'shion', LABEL = 'Mizutani Shion', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport2_mizutani_shion_player', PRICE = 95000 },
		{ KEY = 'outlaw', LABEL = 'Herrera Outlaw', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_herrera_outlaw_player', PRICE = 104000 },
		{ KEY = 'riptide', LABEL = 'Herrera Riptide', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_herrera_riptide_player', PRICE = 101000 },
		{ KEY = 'caliburn', LABEL = 'Rayfield Caliburn', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_rayfield_caliburn_player', PRICE = 158000 },
		{ KEY = 'aerondight', LABEL = 'Rayfield Aerondight', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport1_rayfield_aerondight_player', PRICE = 172000 },
		{ KEY = 'porsche', LABEL = 'Porsche 911 Turbo', CLASS = 'Sport',
			RECORD = 'Vehicle.v_sport2_porsche_911turbo_player', PRICE = 149000 },

		-- Utility
		{ KEY = 'colby', LABEL = 'Thorton Colby', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard2_thorton_colby_player', PRICE = 27000 },
		{ KEY = 'supron', LABEL = 'Mahir Supron', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard25_mahir_supron_player', PRICE = 24000 },
		{ KEY = 'columbus', LABEL = 'Villefort Columbus', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard25_villefort_columbus_player', PRICE = 42000 },
		{ KEY = 'merrimac', LABEL = 'Thorton Merrimac', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard25_thorton_merrimac_player', PRICE = 52000 },
		{ KEY = 'mackinaw', LABEL = 'Thorton Mackinaw', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard3_thorton_mackinaw_player', PRICE = 61000 },
		{ KEY = 'emperor', LABEL = 'Chevalier Emperor', CLASS = 'Utility',
			RECORD = 'Vehicle.v_standard3_chevalier_emperor_player', PRICE = 44000 },

		-- Bikes
		{ KEY = 'kusanagi', LABEL = 'Yaiba Kusanagi', CLASS = 'Bikes',
			RECORD = 'Vehicle.v_sportbike1_yaiba_kusanagi_player', PRICE = 68000 },
		{ KEY = 'muramasa', LABEL = 'Yaiba Muramasa', CLASS = 'Bikes',
			RECORD = 'Vehicle.v_sportbike1_yaiba_muramasa_player', PRICE = 71000 },
		{ KEY = 'arch', LABEL = 'ARCH Nazare', CLASS = 'Bikes',
			RECORD = 'Vehicle.v_sportbike2_arch_player', PRICE = 79000 },
		{ KEY = 'apollo', LABEL = 'Brennan Apollo', CLASS = 'Bikes',
			RECORD = 'Vehicle.v_sportbike3_brennan_apollo_player', PRICE = 74000 },

		-- Air
		{ KEY = 'manticore', LABEL = 'Militech Manticore', CLASS = 'Air',
			RECORD = 'Vehicle.av_militech_manticore', PRICE = 420000 },
		{ KEY = 'excalibur', LABEL = 'Rayfield Excalibur', CLASS = 'Air',
			RECORD = 'Vehicle.av_rayfield_excalibur', PRICE = 560000 },
		{ KEY = 'atlus', LABEL = 'Zetatech Atlus', CLASS = 'Air',
			RECORD = 'Vehicle.av_zetatech_atlus', PRICE = 640000 },
	},

	-- LABEL is the operator's own words and is never translated. Key is the
	-- durable name a purchase and every command names.
	--
	-- Empty until a dealer is captured in game. `/opx.dealership.add` prints the
	-- line to check in here, which is how a dealer survives a database reset:
	--   dealer_example = { LABEL = "WATSON AUTOS", KIND = 'garage',
	--     X = -1771.79, Y = -77.30, Z = 7.53, HEADING = 90.0, BUCKET = 0 },
	SPOTS = {},
}
