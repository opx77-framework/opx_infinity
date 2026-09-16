--- The ceiling per character, the plate shape, the default garage and the
--- cadence the condition of everything out is written at.
-- @author dop42
--
-- Server-only: nothing a client draws reads any of it.

OPX.Config.MODULES.vehicles = {
	enabled = true,

	-- Most vehicles one character may own; 0 for no ceiling.
	PER_CHARACTER = 8,

	-- 1 draws a digit, A a letter, . either, and anything else is copied
	-- through. Drawn in ASCII capitals, because the column is `ascii_bin`.
	PLATE_FORMAT = '11AAA111',

	-- Where a vehicle registered with no garage belongs.
	DEFAULT_GARAGE = 'impound',

	-- Metres to the side of the player a vehicle appears.
	SPAWN_OFFSET = 3.0,

	-- How often the condition of every vehicle out is written. This loop, and
	-- not the stop handler, is what guarantees damage survives a crash.
	SAVE_SECONDS = 120,
}
