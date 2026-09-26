--- Where the NCPD and MaxTac headquarters are, and the marker that says so.
-- @author XEROX710
--
-- A HEADQUARTERS IS A NAME AND A PLACE, and that is the whole of this file. The
-- marker it draws is how a player finds the station; the label it shows while
-- they stand on it is how they know they are at it. Everything else a
-- headquarters holds -- the MaxTac AV pads, the garages, the stores that go
-- around it -- is configured in its own file beside this one: `config/avgarages.lua`
-- for the AV recall pads, `config/garages.lua` for the garages. This file
-- designates, and the others place.
--
-- HOW TO CAPTURE ONE: ONE COMMAND, CAPTURE AND SET. Stand where the marker
-- should be and run `/opx.headquarters.add [key] [label]` -- it reads where you
-- stand, saves the station, draws it for everyone at once, and answers with the
-- line to check into the file below. No key names one (`hq1`, `hq2`, ...) and
-- no label names the key. `/opx.headquarters.remove <key>` takes a captured one
-- back; `/opx.headquarters.list` reads the whole map out loud.
--
-- THE FILE IS STILL THE RECORD. A capture is saved to the database and drawn
-- immediately, but the answer's config line is what survives a database reset
-- -- paste it below and the station is permanent. This is a COMMAND and not a
-- menu on purpose: the owner deleted the staff menu's Dev screen on 2026-09-21
-- -- "il y a pas de config live c'est tous par les fichier config donc degage
-- moi ce menu est pass moi tous dans les config" -- because a screen that
-- places things teaches an operator to set a server up somewhere nobody can
-- read afterwards. One command that ends in a line to paste into this file is
-- the opposite of that.
--
-- There is no HEADING here and there will not be one: nothing is created at a
-- headquarters, so there is no facing for one to have -- a heading on a record
-- nothing turns is a field a later author wires up by mistake. BUCKET comes
-- from the world (the bucket you were standing in) and is editable in the line
-- it prints.
--
-- THE MAP PIN IS EACH STATION'S OWN CHOICE. A station is pinned on the map
-- when its own row declares `BLIP`; without the block there is no pin, which
-- is what makes the pin optional per station. The block is the pin's whole
-- look, and every field of it is optional:
--
--   BLIP = true                                          -- the category defaults
--   BLIP = { SPRITE = 'objective', COLOR = '#FFCC00' }   -- its own look
--   BLIP = { ICON = { ASSET = 'assets/blips/hq.svg', SIZE = 56 } }
--
-- SPRITE is a stable alias, a 2.31 variant name or a number -- the vocabulary
-- `config/blips.lua` documents in full. ICON is a custom .svg compiled under
-- the real mappin widget: a resource-relative path, or a table carrying its
-- own SIZE (16..128). COLOR is exactly `#RRGGBB` or `#RRGGBBAA`. The pin's
-- title is the station's LABEL, and a bad field is dropped with a boot warning
-- naming the row rather than costing the whole pin. An ICON needs its .svg
-- declared in `open77.lua` (`files { "assets/blips/*.svg" }`) or the engine
-- answers `asset_not_declared`; the sprite and the colour need no manifest
-- change. A captured station is pinned the moment its answer's line -- with
-- the `BLIP` block written in -- is checked in below: the map's look lives in
-- this file and nowhere else.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`, which is
-- why the preset below glows with a stock style rather than a custom one.

OPX.Config.MODULES.headquarters = {
	enabled = true,

	-- Flat metres from the declared X and Y within which the strip names the
	-- place. Stand on the marker and it speaks; step off and it stops.
	USE_RADIUS = 4.0,

	-- What the marker looks like. One look, because a station is a station: a
	-- ring, glowing, wide enough to park an AV in -- the same look an AV pad
	-- wears, which is deliberate, because a headquarters is where the pads are.
	MARKER = {
		hq = { shape = 'ring', style = 'objective', RADIUS = 3.0 },
	},

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2. Not decoration: a
	-- ring is the marker mesh flattened to 0.04 m, so one placed at exact floor
	-- height is co-planar with the floor and draws NOTHING. The platform's own
	-- POI path lifts its markers by the same 0.06 m for exactly this reason.
	GROUND_OFFSET = 0.06,

	-- THE KEY THE NAME ROW WEARS. The strip is a prompts row and the prompts
	-- contract draws no row without a key cap at all -- a row of pure text is
	-- refused `prompts.keysRequired` -- and a cap that names no real key is a
	-- key the player presses to nothing, which is what the old literal `!`
	-- was. So the cap names a REAL keybind now: the same `ID`/`NAME`/`DEFAULT`
	-- block every other surface declares, registered with the host and
	-- rebindable in the player's own key settings, and the press answers with
	-- the station's own name -- a designation says what it is when touched,
	-- and does nothing else.
	--
	-- F8 because the rest of the keyboard is spoken for: E opens the shops,
	-- the pads, the desks and the teleports, F boards the MaxTac AV, H/Y/X
	-- are the phone, F6 flies and F7 dresses. F8 is the free one beside the
	-- two panels that claim its neighbours. `DEFAULT = false` turns the press
	-- AND the row off together, because a row with no cap is not drawn.
	KEY = { ID = 'opx.headquarters.use', NAME = 'headquarters.key.use', DEFAULT = 'F8' },

	-- The marker/scan loop. SCAN_MS also decides how long a marker stays up
	-- after a read fails. POLL_MS is how often the client re-asks for the list,
	-- so a change of routing bucket is picked up without a rejoin.
	SCAN_MS = 500,
	POLL_MS = 15000,

	-- ACL-gated; refused unless the player holds `command.<name>`.
	-- `add` captures where you stand AND sets it -- one command, no routeway,
	-- because a headquarters has no facing a chat command could not carry.
	COMMANDS = {
		add = 'opx.headquarters.add',
		remove = 'opx.headquarters.remove',
		list = 'opx.headquarters.list',
	},

	-- EVERY HEADQUARTERS ON THE SERVER.
	--
	-- LABEL is what the strip shows while a player stands on the marker. It is
	-- the operator's own words and is never translated. The key is the durable
	-- name every command and log line uses, so keys are added freely and NEVER
	-- renamed.
	--
	-- BUCKET is the routing bucket the marker exists in -- 0 is the open city.
	--
	-- NOTHING IS SHIPPED HERE, on purpose: a marker at a coordinate nobody ever
	-- stood at is a marker that lies. Stand at your station, run
	-- `/opx.headquarters.add`, and check in the block its answer prints -- the
	-- shape is exactly the one commented out below.
	HEADQUARTERS = {
		-- ncpd_hq = {
		-- 	LABEL = 'NCPD HQ',
		-- 	X = -1527.21, Y = -218.56, Z = 7.86, BUCKET = 0,
		-- 	BLIP = { SPRITE = 'objective', COLOR = '#3B82F6' },
		-- },
		-- maxtac_hq = {
		-- 	LABEL = 'MaxTac HQ',
		-- 	X = 89.67, Y = -569.73, Z = 7.56, BUCKET = 0,
		-- },
	},
}
