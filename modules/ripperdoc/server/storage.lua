--- Every SQL statement this module runs, and the two tables it owns.
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
-- `chair_key` is the durable name a captured chair is referred to by, and it is
-- the primary key because a chair captured twice is one chair moved, not two --
-- which is also what the merge in `modules/ripperdoc/module.lua` does with a
-- captured id that shadows a config row.

local M = OPX.Modules.Get('ripperdoc')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc (
    chair_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    yaw DOUBLE NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc_chrome (
    citizen_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    entry_id VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    grade_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    condition_points INT NOT NULL DEFAULT 100,
    broken TINYINT(1) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizen_id, entry_id)
) ENGINE=InnoDB
]],
	-- THE SEAT, beside the chair and not inside it: a chair captured on a
	-- base-game ripperdoc chair remembers what it snapped to and how the
	-- patient sits in it. A NEW table rather than new columns, because this
	-- runtime has no migration step -- a column added to a table an operator
	-- already has would be a column their server never gets.
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc_seat (
    chair_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    seat_forward DOUBLE NOT NULL DEFAULT 0,
    seat_right DOUBLE NOT NULL DEFAULT 0,
    seat_up DOUBLE NOT NULL DEFAULT 0,
    seat_yaw DOUBLE NOT NULL DEFAULT 0,
    forward_x DOUBLE NULL,
    forward_y DOUBLE NULL,
    vanilla_class VARCHAR(96) NOT NULL DEFAULT '',
    vanilla_name VARCHAR(96) NOT NULL DEFAULT '',
    vanilla_engine VARCHAR(32) NOT NULL DEFAULT '',
    bucket INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
	-- A REFUND THAT HAD NOBODY TO LAND ON. The money rule compensates a failed
	-- operation, and the character contract cannot credit a character who is
	-- not loaded (`money.offline`). The refund waits here, keyed by the
	-- character, and is paid the next time that character loads.
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc_refund (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizen_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    money_type VARCHAR(16) NOT NULL,
    amount INT NOT NULL,
    reason VARCHAR(96) NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_citizen (citizen_id)
) ENGINE=InnoDB
]],
	-- THE BASE GAME'S OWN WORD ON EACH CYBERWARE RECORD, read through a live
	-- client by the record reader (`server/reader.lua`). `name` is in the
	-- reading client's language; `build` is the catalogue build it was read
	-- against, so a new game build reads the list again.
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc_records (
    record_id VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    display_name VARCHAR(160) NOT NULL DEFAULT '',
    quality VARCHAR(48) NOT NULL DEFAULT '',
    equip_area VARCHAR(64) NOT NULL DEFAULT '',
    item_type VARCHAR(64) NOT NULL DEFAULT '',
    locale_key VARCHAR(48) NOT NULL DEFAULT '',
    record_class VARCHAR(64) NOT NULL DEFAULT '',
    answer VARCHAR(48) NOT NULL DEFAULT '',
    build VARCHAR(16) NOT NULL DEFAULT '',
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

--- Every captured chair, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT chair_key, label, x, y, z, yaw
  FROM opx77_ripperdoc
 ORDER BY created_at
  ]])
end

--- Inserts a captured chair, or moves the one already under that key.
-- One statement rather than a select and a branch: two captures in the same tick
-- would both pass the select, and the primary key is the only thing that can
-- settle a key.
-- @author XEROX710
-- @param chair table normalised chair fields (`M.Ripper.Row`'s shape)
-- @return Result
function M.Storage.Upsert(chair)
	return Storage.Execute([[
INSERT INTO opx77_ripperdoc (chair_key, label, x, y, z, yaw)
VALUES (@key, @label, @x, @y, @z, @yaw)
ON DUPLICATE KEY UPDATE label = @label, x = @x, y = @y, z = @z, yaw = @yaw
  ]], {
		key = chair.id,
		label = chair.NAME,
		x = chair.X,
		y = chair.Y,
		z = chair.Z,
		yaw = chair.YAW,
	})
end

--- Deletes a captured chair by its key.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.Delete(key)
	return Storage.Execute('DELETE FROM opx77_ripperdoc WHERE chair_key = @key', { key = key })
end

--- Every chrome condition row of one patient, oldest first.
-- @author XEROX710
-- @param citizenId string
-- @return Result carrying an array of rows
function M.Storage.FetchChrome(citizenId)
	return Storage.Query([[
SELECT entry_id, grade_key, condition_points, broken
  FROM opx77_ripperdoc_chrome
 WHERE citizen_id = @citizen
 ORDER BY created_at
  ]], { citizen = citizenId })
end

--- Records one piece's condition, creating the row on first wear. One
-- statement rather than a select and a branch, for the same reason the chair
-- upsert is one.
-- @author XEROX710
-- @param citizenId string
-- @param entryId string
-- @param gradeKey string the grade the patient wears (or wore)
-- @param conditionPoints integer 0..100
-- @param broken boolean
-- @return Result
function M.Storage.UpsertChrome(citizenId, entryId, gradeKey, conditionPoints, broken)
	return Storage.Execute([[
INSERT INTO opx77_ripperdoc_chrome (citizen_id, entry_id, grade_key, condition_points, broken)
VALUES (@citizen, @entry, @grade, @points, @broken)
ON DUPLICATE KEY UPDATE grade_key = @grade, condition_points = @points, broken = @broken
  ]], {
		citizen = citizenId,
		entry = entryId,
		grade = gradeKey,
		points = conditionPoints,
		broken = broken and 1 or 0,
	})
end

--- Forgets one patient's piece entirely -- the pull of a movement kit, where
-- there is no platform record left behind.
-- @author XEROX710
-- @param citizenId string
-- @param entryId string
-- @return Result
function M.Storage.DeleteChrome(citizenId, entryId)
	return Storage.Execute([[
DELETE FROM opx77_ripperdoc_chrome
 WHERE citizen_id = @citizen AND entry_id = @entry
  ]], { citizen = citizenId, entry = entryId })
end

--- Every seat row, keyed by chair.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchSeats()
	return Storage.Query([[
SELECT chair_key, seat_forward, seat_right, seat_up, seat_yaw, forward_x, forward_y,
       vanilla_class, vanilla_name, vanilla_engine, bucket
  FROM opx77_ripperdoc_seat
  ]])
end

--- Writes one chair's seat: the offsets, the facing it snapped to and what it
--- snapped to.
-- @author XEROX710
-- @param key string
-- @param seat table { FORWARD, RIGHT, UP, YAW, FX, FY, CLASS, NAME, ENGINE, BUCKET }
-- @return Result
function M.Storage.UpsertSeat(key, seat)
	return Storage.Execute([[
INSERT INTO opx77_ripperdoc_seat (chair_key, seat_forward, seat_right, seat_up, seat_yaw,
    forward_x, forward_y, vanilla_class, vanilla_name, vanilla_engine, bucket)
VALUES (@key, @forward, @right, @up, @yaw, IF(@facing = 1, @fx, NULL), IF(@facing = 1, @fy, NULL),
    @class, @name, @engine, @bucket)
ON DUPLICATE KEY UPDATE seat_forward = @forward, seat_right = @right, seat_up = @up,
    seat_yaw = @yaw, forward_x = IF(@facing = 1, @fx, NULL), forward_y = IF(@facing = 1, @fy, NULL),
    vanilla_class = @class, vanilla_name = @name, vanilla_engine = @engine, bucket = @bucket
  ]], {
		-- EVERY PARAMETER IS BOUND: the bridge drops a nil one and the driver
		-- then refuses the statement, so a chair with no engine facing sends a
		-- flag and two zeros rather than two nils.
		key = key,
		forward = seat.FORWARD or 0,
		right = seat.RIGHT or 0,
		up = seat.UP or 0,
		yaw = seat.YAW or 0,
		facing = (seat.FX ~= nil and seat.FY ~= nil) and 1 or 0,
		fx = seat.FX or 0,
		fy = seat.FY or 0,
		class = seat.CLASS or '',
		name = seat.NAME or '',
		engine = seat.ENGINE or '',
		bucket = seat.BUCKET or 0,
	})
end

--- Deletes one chair's seat row.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.DeleteSeat(key)
	return Storage.Execute('DELETE FROM opx77_ripperdoc_seat WHERE chair_key = @key', { key = key })
end

--- Queues a refund for a character who is not here to take it.
-- @author XEROX710
-- @param citizenId string
-- @param moneyType string
-- @param amount integer
-- @param reason string
-- @return Result
function M.Storage.QueueRefund(citizenId, moneyType, amount, reason)
	return Storage.Execute([[
INSERT INTO opx77_ripperdoc_refund (citizen_id, money_type, amount, reason)
VALUES (@citizen, @money, @amount, @reason)
  ]], { citizen = citizenId, money = moneyType, amount = amount, reason = reason })
end

--- Every refund waiting for one character.
-- @author XEROX710
-- @param citizenId string
-- @return Result carrying an array of rows
function M.Storage.FetchRefunds(citizenId)
	return Storage.Query([[
SELECT id, money_type, amount, reason
  FROM opx77_ripperdoc_refund
 WHERE citizen_id = @citizen
 ORDER BY id
  ]], { citizen = citizenId })
end

--- Deletes one paid refund. Deleted by id AND character, so a row can only be
--- consumed by the character it was queued for.
-- @author XEROX710
-- @param id integer
-- @param citizenId string
-- @return Result
function M.Storage.DeleteRefund(id, citizenId)
	-- `Update`, not `Execute`: the rows affected is the answer, and a refund is
	-- paid only when THIS delete is the one that removed its row.
	return Storage.Update([[
DELETE FROM opx77_ripperdoc_refund WHERE id = @id AND citizen_id = @citizen
  ]], { id = id, citizen = citizenId })
end

--- How many records the reader has kept for one catalogue build.
-- @author XEROX710
-- @param build string
-- @return Result carrying an array with one row { n }
function M.Storage.CountRecords(build)
	return Storage.Query([[
SELECT COUNT(*) AS n
  FROM opx77_ripperdoc_records
 WHERE build = @build
  ]], { build = build })
end

--- Keeps what a live client said one record is. One statement per record,
--- replaced whole: a later read is the newer truth.
-- @author XEROX710
-- @param row table { record, name, quality, area, itemType, localeKey, class, answer, build }
-- @return Result
function M.Storage.UpsertRecord(row)
	return Storage.Execute([[
INSERT INTO opx77_ripperdoc_records (record_id, display_name, quality, equip_area, item_type,
    locale_key, record_class, answer, build)
VALUES (@record, @name, @quality, @area, @itype, @loc, @class, @answer, @build)
ON DUPLICATE KEY UPDATE display_name = @name, quality = @quality, equip_area = @area,
    item_type = @itype, locale_key = @loc, record_class = @class, answer = @answer, build = @build
  ]], {
		record = row.record,
		name = row.name,
		quality = row.quality,
		area = row.area,
		itype = row.itemType,
		loc = row.localeKey,
		class = row.class,
		answer = row.answer,
		build = row.build,
	})
end
