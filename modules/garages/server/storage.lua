--- Every SQL statement this module runs, and the one table it owns.
-- @author XEROX710
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: `server/main.lua` decides.
--
-- Statements bind named parameters (`@key`), never `?`: the bridge rewrites `?`
-- by walking the query text, and no comment may appear inside a SQL string for
-- the same reason. Every statement yields and answers a `Result`, so every one
-- of them has to be reached from a `CreateThread`.
--
-- No foreign key: a spot is a place in the world and belongs to no character,
-- which is also why deleting a character does not delete a garage.
--
-- THIS TABLE IS READ-ONLY NOW, and that is the migration rather than an
-- oversight. `/opx.garages.add` and `.remove` wrote it, and both are gone: a
-- garage is written in `config/garages.lua`. The `Upsert` and `Delete` that
-- stood here went with them, because a writer with no caller is a writer the
-- next reader wires a new command up to.
--
-- `FetchAll` and the CREATE stay, and they are the whole reason nothing is lost:
-- the server adopts every row in here that config does not name, and prints the
-- block that would check it in. Dropping the table would destroy the one copy of
-- every spot an operator ever placed in game, so nothing here drops it -- an
-- operator who has not yet checked their spots in can still roll back.
--
-- `opx77_avpads` BELOW IS THE TABLE THAT DOES HAVE WRITERS: the AV pad capture
-- (`/opx.avgarages.add`) writes it and `/opx.avgarages.remove` deletes from it,
-- both callers from the day it shipped. It is a table of its own and not this
-- one revived, because the two lists mean different things: a row here is a
-- legacy spot config has not adopted yet and must never be written again, and a
-- row there is a capture an operator made on purpose.

local M = OPX.Modules.Get('garages')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
-- `spot_key` is the durable name a captured spot is referred to by, and it is
-- the primary key because a spot captured twice is one spot moved, not two.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_garages (
    spot_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    kind VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    captured_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

--- Every captured spot, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT spot_key, label, kind, x, y, z, heading, bucket, captured_by
  FROM opx77_garages
 ORDER BY created_at
  ]])
end

-- The pad capture's own table, joined onto the one schema list above:
-- `pad_key` is the durable name a captured pad is referred to by, and it is
-- the primary key because a pad captured twice is one pad moved, not two.
table.insert(M.Storage.SCHEMA, [[
CREATE TABLE IF NOT EXISTS opx77_avpads (
    pad_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    captured_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]])

--- Every captured AV pad, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchPads()
	return Storage.Query([[
SELECT pad_key, label, x, y, z, heading, bucket, captured_by
  FROM opx77_avpads
 ORDER BY created_at
  ]])
end

--- Inserts a captured pad, or moves the one already under that key.
-- One statement rather than a select and a branch: two captures in the same tick
-- would both pass the select, and the primary key is the only thing that can
-- settle a key.
-- @author XEROX710
-- @param pad table { key, label, x, y, z, heading, bucket, capturedBy }
-- @return Result
function M.Storage.UpsertPad(pad)
	return Storage.Execute([[
INSERT INTO opx77_avpads (pad_key, label, x, y, z, heading, bucket, captured_by)
VALUES (@key, @label, @x, @y, @z, @heading, @bucket, @capturedBy)
ON DUPLICATE KEY UPDATE label = @label, x = @x, y = @y, z = @z,
    heading = @heading, bucket = @bucket, captured_by = @capturedBy
  ]], {
		key = pad.key,
		label = pad.label,
		x = pad.x,
		y = pad.y,
		z = pad.z,
		heading = pad.heading,
		bucket = pad.bucket,
		capturedBy = pad.capturedBy,
	})
end

--- Deletes a captured pad by its key. A config pad is not this statement's to
-- take: the remove command checks `captures` before it ever gets here.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.DeletePad(key)
	return Storage.Execute('DELETE FROM opx77_avpads WHERE pad_key = @key', { key = key })
end
