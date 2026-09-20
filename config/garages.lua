--- Where an owned vehicle may be brought out, and the glowing marker that says so.
-- @author XEROX710
--
-- A spot is a PLACE and not a menu: the marker is drawn where the operator put
-- it, and the server re-derives the player's distance to the DECLARED position
-- before anything is created. A spot captured in game lives in the database and
-- is merged over this table key by key -- `/opx.garages.add` is what writes it.
--
-- KIND decides what may come out of a spot and nothing else about it: a `garage`
-- brings out a ground vehicle, an `avpad` brings out an AV record. A vehicle
-- whose own `garage` column names a spot is preferred at THAT spot; when none
-- does -- every vehicle registers under DEFAULT_GARAGE -- any eligible one is
-- brought out, so a fresh world is not a world where nothing can be spawned.
--
-- X, Y and Z are validated, and only X and Y are measured against: a pad on a
-- roof is used by someone standing on the roof, and someone on the street below
-- it is not near it. HEADING is the yaw the vehicle is created with.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`, which is
-- why both presets below glow with a stock style rather than a custom one.

OPX.Config.MODULES.garages = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a spot may be used.
	USE_RADIUS = 4.0,

	-- What a marker looks like, per kind. Both are engine presets, both glow: the
	-- garage is the standing cylinder, the pad is the landing ring.
	MARKER = {
		garage = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
		avpad = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
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
	-- z-fighting. Both kinds share the one value.
	GROUND_OFFSET = 0.06,

	-- Metres above the pad an AV is created, so it does not start half-buried.
	-- An AV record's pivot is the chassis centre, the same reason freeroam lifts
	-- its own AV spawns.
	AV_LIFT = 1.2,

	-- An AV record starts with one of these, lower-cased. The same rule
	-- `open77_avcleanup` sweeps the world by.
	AV_PREFIXES = { 'vehicle.av_', 'vehicle.max_tac_av' },

	-- The marker/scan loop. SCAN_MS also decides how long a marker stays up
	-- after a read fails.
	SCAN_MS = 500,
	-- How often the client re-asks for the list, so a change of routing bucket
	-- is picked up without a rejoin.
	POLL_MS = 15000,

	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,
	-- How long `add` waits for the client's answer before it says the capture did
	-- not happen. A chat command has no facing of its own, so the client is asked
	-- for one -- and a client that never answers used to leave the operator
	-- believing a spot had been placed where there was none.
	CAPTURE_TIMEOUT_MS = 5000,
	-- Floor between two bring-outs from one connection.
	COOLDOWN_MS = 3000,

	-- The key that brings a vehicle out at the spot the player is standing on.
	-- ID is stable, because a player's rebind is stored under it; NAME is the
	-- catalogue key of the pause-menu label.
	KEY = { ID = 'opx.garages.use', NAME = 'garages.key.use', DEFAULT = 'E' },

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	COMMANDS = {
		add = 'opx.garages.add',
		remove = 'opx.garages.remove',
		list = 'opx.garages.list',
		bring = 'opx.garages.bring',
	},

	-- LABEL is the operator's own words and is never translated. Key is the
	-- durable name: a vehicle's `garage` column and every command name it.
	--
	-- Empty until a spot is captured in game. `/opx.garages.add` prints the line
	-- to check in here, which is how a spot survives a database reset:
	--   garage_example = { LABEL = "V'S GARAGE", KIND = 'garage',
	--     X = -1771.79, Y = -77.30, Z = 7.53, HEADING = 90.0, BUCKET = 0 },
	SPOTS = {},
}
