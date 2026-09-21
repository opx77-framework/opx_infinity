--- Where vehicles and AVs are sold, what they cost, and where the bought one goes.
-- @author XEROX710
--
-- A dealer is a PLACE: a marker is drawn where the operator put it, and the
-- server re-derives the player's distance to the DECLARED position before money
-- moves. A dealer is written in SPOTS at the bottom of this file and nowhere
-- else -- `/opx.dealership.add` and `.remove` are gone, for the reason
-- `config/garages.lua` gives at the same place. Any dealer still living only in
-- `opx77_dealerships` is adopted at boot and printed as the line that checks it
-- in, so nothing an operator placed is lost by the commands going away.
--
-- THREE THINGS HAPPEN AT A DEALER NOW. A player stands on the marker and buys
-- from the list, as before. An operator dresses the floor with PREVIEW POINTS --
-- locked showroom cars, written in `PREVIEW.POINTS` below. And anyone
-- inside the dealership ZONE grows a "sell a vehicle" row on every other player,
-- so a salesperson sells to a customer face to face: the customer's own client
-- confirms, the price is paid into the company bank of the seller's job or gang,
-- and a configured percentage of it is paid to the seller.
--
-- KIND is carried over from the garages vocabulary and means the same two
-- things, because a dealership and a garage are the same two categories of
-- thing: a `garage` dealer sells ground vehicles and stands a player on a
-- cylinder, an `avpad` dealer sells AVs and stands them on a landing ring.
-- What a dealer may sell is therefore decided by its kind AND by the record:
-- an AV record is refused at a `garage` dealer whatever its row says.
--
-- X, Y and Z are validated, and only X and Y are measured against. HEADING is
-- the yaw a vehicle handed over here is created with, and the yaw a showroom car
-- stands at, so it is never decoration: a dealer at zero degrees hands cars out
-- facing whichever way the map was built.
--
-- HOW TO CAPTURE ONE. Stand where the thing goes, FACE THE WAY IT SHOULD FACE,
-- and run `/opx.admin.self.pos` -- Self -> Position on the staff menu, or the
-- row on the target eye. It copies
-- `{ NAME = "here", LABEL = "Here", X = ..., Y = ..., Z = ..., HEADING = ... }`
-- to your operating system clipboard, with the facing you are really standing
-- at, and you paste the numbers into a row below. That is the whole capture
-- path. It replaced a menu, not a survey: `/opx.dealership.add` wrote the same
-- numbers straight into a database, which is what made them impossible to read
-- back.
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

	-- WHICH RECORDS ARE AVs IS NOT A DEALERSHIP SETTING. It is one list,
	-- `AV_PREFIXES` in `config/shared.lua`, read by one helper, which is what
	-- puts a record in the air category for every part of the server or for none
	-- of it. This key used to claim that and be a second copy of it.

	-- The marker/scan loop, and how often the client re-asks for its list so a
	-- change of routing bucket is picked up without a rejoin.
	SCAN_MS = 500,
	POLL_MS = 15000,

	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,
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

	-- `list` is a reading of what is placed and stays ACL-gated; `stock` is a
	-- reading of the catalogue and `buy` acts on the caller alone, so both are
	-- open -- a player who has been granted nothing still has to be able to spend
	-- their money.
	--
	-- `add` and `remove` ARE GONE. They placed a dealer from a chat line into a
	-- table only one host had. A dealer is written in SPOTS below, and so is a
	-- preview point, in PREVIEW.POINTS -- the staff menu's Dev screen used to
	-- place those and the owner deleted it on 2026-09-21: "il y a pas de config
	-- live c'est tous par les fichier config donc degage moi ce menu est pass
	-- moi tous dans les config". NOTHING ON THIS SERVER IS PLACED FROM A MENU.
	COMMANDS = {
		list = 'opx.dealership.list',
		stock = 'opx.dealership.stock',
		buy = 'opx.dealership.buy',
	},

	-- ── the showroom floor ──────────────────────────────────────────────────

	-- WHAT A PREVIEW POINT IS. A place on the showroom floor with one model of
	-- the stock list standing on it, so a player walks around what they are about
	-- to buy instead of reading its name off a row. A dealer has as many as the
	-- operator places.
	--
	-- THE PREVIEW IS LOCKED, and that is not decoration: an unlocked showroom car
	-- is a free car with an audience. The lock is the engine's own `locked` flag,
	-- set at creation and read back -- a flag that was asked for and refused is a
	-- line in the journal rather than a car driving out of the window.
	--
	-- LIMIT is per dealer and exists because every preview is a network vehicle
	-- that never despawns: a showroom of two hundred is a showroom that costs
	-- every client in the district its frame budget.
	PREVIEW = {
		ENABLED = true,
		LIMIT = 12,
		LOCKED = true,
		-- Metres a preview is lifted off the declared Z. Smaller than AV_LIFT,
		-- because this is the gap that stops a chassis resting in the floor
		-- rather than the clearance an AV needs to materialise.
		LIFT = 0.1,

		-- ── THE SHOWROOM ITSELF ──────────────────────────────────────────
		--
		-- ONE ROW PER CAR ON THE FLOOR, keyed by a durable name of your own.
		-- Empty out of the box: a fresh server's dealers are counters, and a
		-- sample point would stand a car in the middle of somebody's road.
		--
		-- A point reads:
		--   show_hella_1 = { X = -1536.1, Y = -205.9, Z = 7.86, HEADING = 52.0,
		--     BUCKET = 0, DEALER = 'garage1', ENTRY = 'hella' },
		--
		--   X, Y, Z    where the car stands. LIFT above is added to Z, so give
		--              the floor and not the roof of the wheel.
		--   HEADING    the yaw it faces, 0..360. This is the field a menu used
		--              to fill in from the operator's own facing and the field
		--              `/opx.admin.self.pos` now copies with the rest, so stand
		--              the way the car should stand before you run it.
		--   BUCKET     the routing bucket, 0 for the ordinary world.
		--   DEALER     a key in SPOTS at the bottom of this file. A point
		--              naming a dealer that does not exist is KEPT and simply
		--              not created, with a line in the journal per car -- the
		--              dealer may come back on the next edit of this file, and
		--              deleting the car for the operator would be worse.
		--   ENTRY      a KEY in STOCK. Which model stands there, and what the
		--              player walks around before they buy it. A name that is
		--              not in STOCK is refused at boot with a line naming it:
		--              the stock list is entirely config, so a point that names
		--              nothing in it can never stand a car up on any start.
		--
		-- THE KEY IS YOURS AND IT IS DURABLE. It is what the journal names when
		-- a car refuses, and what a row adopted out of `opx77_dealership_previews`
		-- is matched against -- a key written here SHADOWS the database row of
		-- the same name, because this file is the copy somebody has.
		--
		-- MORE THAN `LIMIT` POINTS ON ONE DEALER is reported at boot and the
		-- ones over the line are not created. The limit is a frame budget:
		-- every preview is a network vehicle that never despawns.
		--
		-- MIGRATING A SHOWROOM PLACED BEFORE 2026-09-21: the server prints
		-- every preview that exists only in `opx77_dealership_previews` at
		-- every start, as the exact config line that recreates it, followed by
		-- a warning counting them. Paste them in here and they stop depending
		-- on that table. The table is read-only now -- nothing writes to it --
		-- so nothing is lost while you get round to it.
		POINTS = {
		},
	},

	-- THE RIGHT THAT PLACED ONE IS GONE, AND SO IS WHAT IT GATED. `PLACEMENT_RIGHT
	-- = 'opx.dealership.place'` stood here, guarding `M.PlacePreview` and
	-- `M.RemovePreview` through the dealership contract.
	--
	-- The owner removed the staff Dev screen that was their only caller, and then
	-- ("retire cela aussi") the path itself. What it was doing in the meantime is
	-- worth writing down, because it is a shape worth recognising: a wire verb
	-- nothing sent, on a write path nothing read, guarded by an ACL right granted
	-- to a real account. A live entry point nobody exercises is worse than either
	-- having the feature or not having it -- nobody watches a door nobody uses.
	--
	-- The showroom is `PREVIEW.POINTS` above, and the table that held the old
	-- rows is still read, still adopted and still printed back as config.

	-- ── selling to somebody standing in front of you ────────────────────────

	-- Flat metres from a dealer within which the eye grows a "sell a vehicle"
	-- row on every other player. Wider than USE_RADIUS on purpose: USE_RADIUS is
	-- standing ON the marker, and a showroom is a room -- a salesperson walks a
	-- customer around it and must not lose the row for doing so.
	ZONE_RADIUS = 30.0,

	-- THE BUYER'S OWN CLIENT CONFIRMS, and there is no setting to turn that off.
	-- The owner chose it over debiting the buyer the moment a salesperson presses
	-- a row: money that leaves an account because somebody else clicked something
	-- is a support ticket whatever the salesperson meant by it.
	--
	-- This is how long they have to answer. An offer that expires is refused and
	-- both sides are told, rather than sitting in a table until one of them
	-- disconnects.
	OFFER_TIMEOUT_MS = 30000,

	-- WHERE THE MONEY GOES. The price is paid into the COMPANY BANK of the
	-- seller's own group, and this percentage of it is paid to the seller
	-- instead. 0 is a company that pays commission to nobody, 100 is one that
	-- keeps nothing; both are legal and neither is the default.
	--
	-- Rounded DOWN to a whole unit, and the company gets the remainder: a
	-- rounding that favoured the seller would mint money on every odd price.
	SELLER_CUT_PERCENT = 10,

	-- WHICH GROUPS HAVE A COMPANY BANK. The owner chose both: "jobs AND gangs".
	-- A seller's company is their JOB when jobs are banked and the job is not in
	-- EXCLUDED below, and their GANG otherwise -- a gang member with a day job
	-- sells for the day job, which is the one a customer is buying from.
	--
	-- EXCLUDED names the jobs that are the absence of a job. `unemployed` is an
	-- entry in `config/character.lua` rather than a nil, precisely so nothing has
	-- to handle nil, and a bank account for it would be one account every player
	-- on the server can pay into and its bosses -- there are none -- withdraw
	-- from.
	COMPANY = {
		JOBS = true,
		GANGS = true,
		EXCLUDED = { unemployed = true, none = true },
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
	-- A dealer reads:
	--   dealer_example = { LABEL = "WATSON AUTOS", KIND = 'garage',
	--     X = -1771.79, Y = -77.30, Z = 7.53, HEADING = 90.0, BUCKET = 0 },
	--
	-- THE ONE BELOW WAS CAPTURED IN GAME AND LIVED ONLY IN `opx77_dealerships`.
	-- Checked in on 2026-09-21 off the boot log, for the reason written at the
	-- same place in `config/garages.lua`: the rework removes the command that
	-- made it, and a dealer that exists only in a table nobody has a copy of is
	-- one dropped database away from gone. A row of the same key is now SHADOWED
	-- by this file rather than overlaying it -- there is no command to move a
	-- dealer with any more, so the file has to be the one thing that decides.
	--
	-- The key really is `garage1` -- the capture generates a key per KIND, and a
	-- dealer selling garage-class cars gets that one. It is unrelated to the
	-- `garage1` in `config/garages.lua`: the two live in different tables and
	-- name different things.
	SPOTS = {
		garage1 = { LABEL = 'garage1', KIND = 'garage',
			X = -1536.42, Y = -207.43, Z = 7.86, HEADING = 142.2, BUCKET = 0 },
	},
}
