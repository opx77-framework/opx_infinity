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
-- No foreign key, and nothing durable about a purchase lives here: a dealer is a
-- place in the world and belongs to no character. What a player BOUGHT is a
-- vehicle, and that row is the vehicles module's -- this module creates none.

local M = OPX.Modules.Get('dealership')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
-- `spot_key` is the durable name a captured dealer is referred to by, and it is
-- the primary key because a dealer captured twice is one dealer moved, not two.
-- The shape is the garages table's, on purpose: a dealer and a garage spot are
-- the same kind of thing and an operator moving between the two should not have
-- to learn a second set of column names.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_dealerships (
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

--- Every captured dealer, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT spot_key, label, kind, x, y, z, heading, bucket, captured_by
  FROM opx77_dealerships
 ORDER BY created_at
  ]])
end

--- Inserts a captured dealer, or moves the one already under that key.
-- One statement rather than a select and a branch: two captures in the same tick
-- would both pass the select, and the primary key is the only thing that can
-- settle a key.
-- @author XEROX710
-- @param spot table normalised spot fields
-- @param citizenId string|nil who captured it
-- @return Result
function M.Storage.Upsert(spot, citizenId)
	return Storage.Execute([[
INSERT INTO opx77_dealerships (spot_key, label, kind, x, y, z, heading, bucket, captured_by)
VALUES (@key, @label, @kind, @x, @y, @z, @heading, @bucket, NULLIF(@citizen, ''))
ON DUPLICATE KEY UPDATE label = @label, kind = @kind, x = @x, y = @y, z = @z,
                        heading = @heading, bucket = @bucket
  ]], {
		key = spot.key,
		label = spot.label,
		kind = spot.kind,
		x = spot.x,
		y = spot.y,
		z = spot.z,
		heading = spot.heading,
		bucket = spot.bucket,
		citizen = citizenId ~= nil and tostring(citizenId) or '',
	})
end

--- Deletes a captured dealer by its key.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.Delete(key)
	return Storage.Execute('DELETE FROM opx77_dealerships WHERE spot_key = @key', { key = key })
end
