--- Every SQL statement this module runs, and the one table it owns.
-- @author XEROX710
--
-- This is the only file in the module allowed to carry SQL. Statements bind
-- named parameters (`@key`), never `?`, and every one yields and answers a
-- `Result`, so every one of them has to be reached from a `CreateThread`.
--
-- The table holds PLACES, not money: a branch is a point in the world and
-- belongs to nobody. Balances live on the character (`PlayerData.money`) and
-- are written by the character module.

local M = OPX.Modules.Get('bank')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns. `spot_key` is
--- the durable name a captured branch is referred to by: a branch captured
--- twice is one branch moved, not two.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_bank (
    spot_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

--- Every captured branch, oldest first.
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT spot_key, label, x, y, z, bucket
  FROM opx77_bank
 ORDER BY created_at
  ]])
end

--- Inserts a captured branch, or moves the one already under that key.
-- @param spot table normalised branch fields
-- @return Result
function M.Storage.Upsert(spot)
	return Storage.Execute([[
INSERT INTO opx77_bank (spot_key, label, x, y, z, bucket)
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

--- Deletes a captured branch by its key.
-- @param key string
-- @return Result
function M.Storage.Delete(key)
	return Storage.Execute('DELETE FROM opx77_bank WHERE spot_key = @key', { key = key })
end
