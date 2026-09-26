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
-- `hq_key` is the durable name a captured station is referred to by, and it is
-- the primary key because a station captured twice is one station moved, not
-- two -- which is also what the merge in `modules/headquarters/module.lua`
-- does with a captured key that shadows a config row.

local M = OPX.Modules.Get('headquarters')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_headquarters (
    hq_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    bucket INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

--- Every captured station, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT hq_key, label, x, y, z, bucket
  FROM opx77_headquarters
 ORDER BY created_at
  ]])
end

--- Inserts a captured station, or moves the one already under that key.
-- One statement rather than a select and a branch: two captures in the same tick
-- would both pass the select, and the primary key is the only thing that can
-- settle a key.
-- @author XEROX710
-- @param spot table a normalised spot (`M.Access.FromDefinition`'s shape)
-- @return Result
function M.Storage.Upsert(spot)
	return Storage.Execute([[
INSERT INTO opx77_headquarters (hq_key, label, x, y, z, bucket)
VALUES (@key, @label, @x, @y, @z, @bucket)
ON DUPLICATE KEY UPDATE label = @label, x = @x, y = @y, z = @z, bucket = @bucket
  ]], {
		key = spot.key,
		label = spot.label,
		x = spot.x,
		y = spot.y,
		z = spot.z,
		bucket = spot.bucket,
	})
end

--- Deletes a captured station by its key.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.Delete(key)
	return Storage.Execute('DELETE FROM opx77_headquarters WHERE hq_key = @key', { key = key })
end
