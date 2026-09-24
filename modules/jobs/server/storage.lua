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
-- THE TABLE HOLDS THE ONE FACT THE CHARACTER MODULE DOES NOT. Who works where,
-- at which grade, on duty or not is `opx77_character_groups` and `PlayerData`,
-- and nothing here duplicates it: this is a BANK of worked time, keyed by the
-- character and the job, and it exists only because seniority is the one thing
-- about a job nobody was already storing.
--
-- No foreign key, for the same reason the garage spots have none: a citizen id
-- here that no character row matches is a character who was deleted, and it is
-- read as a bank with nobody to pay rather than as a fault.

local M = OPX.Modules.Get('jobs')

local Storage = OPX.Storage

-- Longest label a captured board may carry. The column is the bound.
local MAX_LABEL = 64

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
-- The pair is the primary key because a character holds one bank per job: a
-- second row for the same pair would be two answers to "how long have they
-- worked here", and the key is the only thing that can settle it.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_job_boards (
    board_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    label VARCHAR(64) NOT NULL DEFAULT '',
    kind VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    job VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    x DOUBLE NOT NULL DEFAULT 0,
    y DOUBLE NOT NULL DEFAULT 0,
    z DOUBLE NOT NULL DEFAULT 0,
    heading DOUBLE NOT NULL DEFAULT 0,
    bucket INT NOT NULL DEFAULT 0,
    created_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (board_key)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_job_seniority (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    job VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    points DOUBLE NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizen_id, job)
) ENGINE=InnoDB
]],
}

--- Every board captured in game.
-- Read once at boot and merged OVER the config by key: a board captured in game
-- is the one that stands, and the checked-in value is what a database reset
-- falls back to. Oldest first, so a rebuild that kept the last row per key would
-- keep the one that was captured most recently.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchBoards()
	return Storage.Query([[
SELECT board_key, label, kind, job, x, y, z, heading, bucket, created_by
  FROM opx77_job_boards
 ORDER BY updated_at
  ]])
end

--- Writes one captured board, or moves the one already under that key.
-- One statement rather than a select and a branch: two operators capturing under
-- the same key at the same moment would both pass the select, and the primary
-- key is the only thing that can settle it.
-- @author XEROX710
-- @param board table a normalised board from Access
-- @param citizenId string|nil who captured it
-- @return Result
function M.Storage.UpsertBoard(board, citizenId)
	local label = type(board.label) == 'string' and board.label or board.key
	if #label > MAX_LABEL then label = label:sub(1, MAX_LABEL) end
	return Storage.Execute([[
INSERT INTO opx77_job_boards
    (board_key, label, kind, job, x, y, z, heading, bucket, created_by)
VALUES (@key, @label, @kind, @job, @x, @y, @z, @heading, @bucket, @by)
ON DUPLICATE KEY UPDATE
    label = @label, kind = @kind, job = @job,
    x = @x, y = @y, z = @z, heading = @heading, bucket = @bucket, created_by = @by
  ]], {
		key = board.key,
		label = label,
		kind = board.kind,
		job = board.job,
		x = board.x,
		y = board.y,
		z = board.z,
		heading = board.heading,
		bucket = board.bucket,
		by = type(citizenId) == 'string' and citizenId or nil,
	})
end

--- Deletes one captured board.
-- A board that came from the config is not removable here: the command that
-- calls this says so rather than deleting a row that does not exist.
-- @author XEROX710
-- @param key string
-- @return Result
function M.Storage.DeleteBoard(key)
	return Storage.Execute('DELETE FROM opx77_job_boards WHERE board_key = @key', { key = key })
end

--- Every bank on the server, oldest row first.
-- Read once at boot: the running set is what the tick pays, and a row for a
-- character who never connects again keeps its points without being loaded.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT citizen_id, job, points
  FROM opx77_job_seniority
 ORDER BY updated_at
  ]])
end

--- The banks of one character.
-- @author XEROX710
-- @param citizenId string
-- @return Result carrying an array of rows
function M.Storage.FetchFor(citizenId)
	return Storage.Query([[
SELECT citizen_id, job, points
  FROM opx77_job_seniority
 WHERE citizen_id = @citizen
  ]], { citizen = citizenId })
end

--- Writes one bank, or moves the one already under that pair.
-- One statement rather than a select and a branch: two ticks landing in the same
-- moment would both pass the select, and the primary key is the only thing that
-- can settle a pair.
-- @author XEROX710
-- @param citizenId string
-- @param job string
-- @param points number
-- @return Result
function M.Storage.Upsert(citizenId, job, points)
	return Storage.Execute([[
INSERT INTO opx77_job_seniority (citizen_id, job, points)
VALUES (@citizen, @job, @points)
ON DUPLICATE KEY UPDATE points = @points
  ]], {
		citizen = citizenId,
		job = job,
		points = points,
	})
end

--- Deletes one bank. Used when a character is fired: the time worked is not
--- theirs once the job is not, and a rehire starts at the bottom rather than
--- walking back in at the rank they left.
-- @author XEROX710
-- @param citizenId string
-- @param job string
-- @return Result
function M.Storage.Delete(citizenId, job)
	return Storage.Execute(
		'DELETE FROM opx77_job_seniority WHERE citizen_id = @citizen AND job = @job',
		{ citizen = citizenId, job = job })
end
