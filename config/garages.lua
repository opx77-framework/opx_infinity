--- Where an owned vehicle may be brought out, and the glowing markers that say so.
-- @author XEROX710
--
-- A GARAGE IS A NAME, AND A NAME MAY BE IN SEVERAL PLACES. That is the whole of
-- the rework, in the owner's own words: "change les system de garage". Before
-- it, a garage WAS a point -- one marker, one key, one car out where the marker
-- stood -- so a player who stored a car in Watson could only ever fetch it in
-- Watson, and an operator who wanted the same garage on two sides of a building
-- had to make two garages and file the cars under one of them.
--
-- So a garage is a KEY with a list of LOCATIONS, and each location is three
-- different kinds of point:
--
--   MENU   where the list opens. It shows EVERY vehicle filed under this
--          garage's key, whichever location it was stored at -- that is what
--          makes storing in Watson and fetching in Japantown one garage rather
--          than two.
--   ENTRY  the ONE point a vehicle is taken in at. One, deliberately: driving in
--          is a thing you do at a door, and two doors to one garage is two
--          places a player has to guess between.
--   EXITS  the points a vehicle comes OUT at, tried IN THE ORDER WRITTEN. The
--          first one with nothing parked on it wins. When every one of them is
--          occupied the bring-out is REFUSED and the player is told so, which is
--          the owner's own choice over the two alternatives -- queueing behind a
--          car nobody may move, or spawning on top of it.
--
-- THE KEY IS WHAT A VEHICLE'S `garage` COLUMN HOLDS, and it is the same key the
-- points used to be named by, which is why no row anywhere had to be rewritten
-- for this: `garage1` was a spot and is now a garage, and every car filed under
-- `garage1` still comes out of it.
--
-- THE COMMANDS THAT PLACED A SPOT ARE GONE. `/opx.garages.add` and
-- `/opx.garages.remove` wrote into `opx77_garages`, so the shape of the world
-- lived in a table nobody had a copy of. A garage is written here now. The
-- module still READS that table at boot and adopts anything in it that this file
-- does not name -- see `modules/garages/server/main.lua`, "the legacy adoption"
-- -- and prints each one as the block to paste in here, so nothing an operator
-- ever placed is lost by the commands going away.
--
-- KIND decides what may come out: a `garage` brings out a ground vehicle, an
-- `avpad` brings out an AV record. It belongs to the GARAGE and not to a point,
-- because a garage that took cars in at one location and AVs at another would be
-- a garage whose own list means two things.
--
-- X, Y and Z are validated, and only X and Y are measured against: a pad on a
-- roof is used by someone standing on the roof, and someone on the street below
-- it is not near it. HEADING is the yaw a vehicle is created with, so it is a
-- field of ENTRY and of an EXIT and NOT of MENU -- nothing is created at a menu
-- point, and a heading on a record nothing turns is a field a later author wires
-- up by mistake.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`, which is
-- why every preset below glows with a stock style rather than a custom one.

OPX.Config.MODULES.garages = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a point may be used.
	USE_RADIUS = 4.0,

	-- HOW MUCH ROOM AN EXIT NEEDS TO COUNT AS FREE, in flat metres. Every
	-- server vehicle in the location's routing bucket is measured against every
	-- exit in turn, and an exit with one inside this radius is skipped.
	--
	-- 3.0 rather than a car's own length: the measure is between two PIVOTS, and
	-- a pivot is the chassis centre, so two vehicles three metres apart are two
	-- vehicles touching. Larger refuses a bay that would have fitted; smaller
	-- drops a car through the roof of the one already parked there.
	--
	-- The vehicle being fetched is never counted against its own exit: a car
	-- left standing on the only exit of its own garage would otherwise be a car
	-- that can never be recalled.
	EXIT_CLEARANCE = 3.0,

	-- What a marker looks like, per KIND for the menu point and per ROLE for the
	-- door. All three are engine presets and all three glow.
	--
	-- `entry` is its own look on purpose: the menu point and the door are two
	-- different promises -- one opens a list, one takes the car you are sitting
	-- in -- and a player who cannot tell them apart drives into the wrong one.
	MARKER = {
		garage = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
		avpad = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
		entry = { shape = 'ring', style = 'interaction', RADIUS = 3.0 },
	},

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2.
	--
	-- Not decoration. A ring is the marker mesh flattened to 0.04 m, so one
	-- placed at exact floor height is co-planar with the floor and draws NOTHING:
	-- the entity spawns, the marker is listed, and the pad looks empty. The
	-- platform's own POI path lifts its markers by the same 0.06 m for exactly
	-- this reason, and the research notes recommend the small lift against
	-- z-fighting. Every kind shares the one value.
	GROUND_OFFSET = 0.06,

	-- Metres above the pad an AV is created, so it does not start half-buried.
	-- An AV record's pivot is the chassis centre, the same reason freeroam lifts
	-- its own AV spawns.
	AV_LIFT = 1.2,

	-- WHICH RECORDS ARE AVs IS NOT A GARAGE SETTING. It is one list,
	-- `AV_PREFIXES` in `config/shared.lua`, read by one helper: this module, the
	-- dealership and the admin catalogue each used to carry their own, and a
	-- record that flies at a dealer and not in a garage is a car you can buy at a
	-- pad you cannot recall it at.

	-- The marker/scan loop. SCAN_MS also decides how long a marker stays up
	-- after a read fails.
	SCAN_MS = 500,
	-- How often the client re-asks for the list, so a change of routing bucket
	-- is picked up without a rejoin.
	POLL_MS = 15000,

	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,
	-- Floor between two bring-outs from one connection.
	COOLDOWN_MS = 3000,

	-- The key that opens the list at a menu point, and puts a vehicle away at a
	-- door. ID is stable, because a player's rebind is stored under it; NAME is
	-- the catalogue key of the pause-menu label.
	KEY = { ID = 'opx.garages.use', NAME = 'garages.key.use', DEFAULT = 'E' },

	-- THE LIST IS A PANEL, NOT A STRIP, for the reason the dealership's own
	-- MENU block spells out: a garage list is read standing still. The menu
	-- module clamps every one of these (240..1200 px, 120..1200 px tall, 3..24
	-- rows), so a typo here is a wrong size and never a menu that fails to open.
	MENU = {
		ANCHOR = 'center',
		WIDTH = 560,
		HEIGHT = 560,
		MAX_HEIGHT_VH = 88,
		VISIBLE_ROWS = 12,
	},

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	--
	-- `add` and `remove` ARE GONE, and this is the whole of what is left. They
	-- wrote a place every player uses into a table that only existed on one
	-- host; a garage is a line in this file now. See the header.
	COMMANDS = {
		list = 'opx.garages.list',
		bring = 'opx.garages.bring',
	},

	-- EVERY GARAGE ON THE SERVER.
	--
	-- LABEL is the operator's own words and is never translated. The key is the
	-- durable name: a vehicle's `garage` column holds it and every command names
	-- it, so keys are added freely and NEVER renamed -- renaming one orphans
	-- every car filed under it.
	--
	-- The two below were captured in game when a garage was still a single
	-- point, and were checked in on 2026-09-21 off the boot log. They are
	-- written here as one location each whose menu, door and only exit are that
	-- one captured point, which is exactly what they did before -- stand on the
	-- marker, press the key, the car appears where you are standing. Give either
	-- of them a second location, or a second exit, and it becomes the thing the
	-- rework is for.
	GARAGES = {
		garage1 = {
			LABEL = 'garage1',
			KIND = 'garage',
			LOCATIONS = {
				{
					BUCKET = 0,
					MENU = { X = -1527.21, Y = -218.56, Z = 7.86 },
					ENTRY = { X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
					EXITS = {
						{ X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
					},
				},
			},
		},

		garage2 = {
			LABEL = 'garage2',
			KIND = 'garage',
			LOCATIONS = {
				{
					BUCKET = 0,
					MENU = { X = 89.67, Y = -569.73, Z = 7.56 },
					ENTRY = { X = 89.67, Y = -569.73, Z = 7.56, HEADING = 242.1 },
					EXITS = {
						{ X = 89.67, Y = -569.73, Z = 7.56, HEADING = 242.1 },
					},
				},
			},
		},
	},
}
