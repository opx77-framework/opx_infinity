--- Where a player may open the fitting room: a store is a marker you stand on.
-- @author XEROX710
--
-- A STORE IS A PLACE, exactly as a garage spot and a dealer are: the marker is
-- drawn where the operator put it. A store captured in game lives in the
-- database and is merged over this table key by key -- `/opx.clothing.add` is
-- what writes it.
--
-- WHICH ROOM OPENS IS A CLIENT DECISION; WHAT MAY BE SAVED OUT OF IT IS NOT.
-- The key still calls the appearance contract locally, because every reason a
-- room may not go up -- the puppet down, another surface holding the keyboard,
-- a save in flight -- is knowable on that client and nowhere else. `sync()`
-- still filters the LIST by routing bucket only.
--
-- What changed is the half that matters. This note used to end "until then this
-- comment says what the code does", the then being the day the room acquired a
-- price: `modules/shops` charges per changed slot, and a fitting room opened
-- from the wrong place stopped being a cosmetic lie the moment a save came out
-- of it. The key now also raises `clothing:open` on the server, which measures
-- the distance to the store ITSELF -- the shape `modules/shops/server/main.lua`
-- uses in `shopAt` -- and only then tells `appearance` that a clothing write is
-- expected from this player. A client that fires it from the other side of the
-- city draws itself a room and cannot save a stitch of it.
--
-- WHAT IS BEHIND THE KEY IS THE FITTING ROOM, not a shop of our own. The
-- `appearance` module already streams this body's whole clothing catalogue
-- (`Open77.equipment.records`, unrestricted, every slot) into a room the player
-- may browse, try on and save from, and it owns the puppet, the save and the
-- rules about who is offered the room at all. This module owns the PLACE and
-- nothing else: it draws a marker, and the key asks that contract to open the
-- room. A store that drew its own list would be a second catalogue with its own
-- idea of what a body may wear.
--
-- THERE IS NO KIND HERE. A garage spot and a dealer are each one of two
-- categories and the category decides what comes out of them; a store is one
-- category of thing, and carries no HEADING either, because nothing is created
-- at a store and nothing is turned by an operator's facing. That is also why
-- `/opx.clothing.add` does not ask the client for anything: the one field a
-- client used to contribute was a vehicle's yaw.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`.

OPX.Config.MODULES.clothing = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a store may be used.
	USE_RADIUS = 4.0,

	-- What a store's marker looks like: the standing cylinder, in the one style
	-- that says "walk up to this and press something" rather than "something
	-- happens here" (`spawn`, which the garages use) or "this is a target"
	-- (`objective`, which the AV pads use).
	MARKER = { shape = 'cylinder', style = 'interaction', RADIUS = 2.5 },

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2.
	--
	-- Not decoration. A ring is the marker mesh flattened to 0.04 m, so one
	-- placed at exact floor height is co-planar with the floor and draws NOTHING:
	-- the entity spawns, the marker is listed, and the store looks empty. The
	-- platform's own POI path lifts its markers by the same 0.06 m for exactly
	-- this reason.
	GROUND_OFFSET = 0.06,

	-- The marker/scan loop. SCAN_MS also decides how long a marker stays up
	-- after a read fails.
	SCAN_MS = 500,
	-- How often the client re-asks for the list, so a change of routing bucket
	-- is picked up without a rejoin.
	POLL_MS = 15000,

	-- The key that opens the fitting room at the store a player is standing on.
	-- ID is stable, because a player's rebind is stored under it; NAME is the
	-- catalogue key of the pause-menu label.
	--
	-- E, like the garages and the dealership, because it is the same gesture in
	-- all three places -- stand on the marker, press the key. It is a separate
	-- MAPPING and not the same key, so a player who rebinds one does not move
	-- the others.
	KEY = { ID = 'opx.clothing.use', NAME = 'clothing.key.use', DEFAULT = 'E' },

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	-- `list` writes nothing but names every store on the server, so it is gated
	-- with the other two exactly as the garages gate theirs.
	COMMANDS = {
		add = 'opx.clothing.add',
		remove = 'opx.clothing.remove',
		list = 'opx.clothing.list',
	},

	-- LABEL is the operator's own words and is never translated. Key is the
	-- durable name a capture and every command names.
	--
	-- Empty until a store is captured in game. `/opx.clothing.add` prints the
	-- line to check in here, which is how a store survives a database reset:
	--   store_example = { LABEL = "JINGUJI", X = -1771.79, Y = -77.30, Z = 7.53,
	--     BUCKET = 0 },
	SPOTS = {},
}
