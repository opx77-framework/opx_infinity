--- Every SQL statement this module runs, and the one table it owns.
-- @author XEROX710
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: `server/main.lua` decides.
--
-- Statements bind named parameters (`@key`), never `?`, and every one of them
-- yields and answers a `Result`, so every one has to be reached from a
-- `CreateThread`.
--
-- THE TABLE HOLDS THE ONE FACT NOBODY ELSE STORES. The jobs bank is per job
-- and per character and measures employment; this is the CHARACTER's own
-- ledger -- how far they have come and what they bought with it -- and it is
-- per character alone. The unlocked set is the row's own bounded column (the
-- node ids, comma separated) rather than a second table: fifteen nodes across
-- three trunks is a value this row can hold whole, and one row per character
-- is one read per knock.
--
-- No foreign key, for the same reason the jobs banks have none: a citizen id
-- here that no character row matches is a character who was deleted, and it is
-- read as a ledger with nobody to pay rather than as a fault.

local M = OPX.Modules.Get('skills')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS for the table this module owns. The citizen
-- is the primary key because a character has exactly one tree.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_skills (
    citizen_id VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    xp DOUBLE NOT NULL DEFAULT 0,
    level INT NOT NULL DEFAULT 1,
    points INT NOT NULL DEFAULT 0,
    nodes VARCHAR(512) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    branches VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (citizen_id)
) ENGINE=InnoDB
]],
}

--- Every tree on the server, oldest row first. Read once at boot: the running
-- set is what the funnel pays into, and a row for a character who never
-- connects again keeps its progress without being loaded.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT citizen_id, xp, level, points, nodes, branches
  FROM opx77_skills
 ORDER BY updated_at
  ]])
end

--- Writes one character's tree, or moves the one already under that id.
-- One statement rather than a select and a branch: two credits landing in the
-- same moment would both pass the select, and the primary key is the only thing
-- that can settle it.
-- @author XEROX710
-- @param citizenId string
-- @param record table the live record to persist
-- @param nodes string the unlocked ids, comma separated and bounded
-- @param branches string what each trunk was fed, `id:xp` pairs bounded
-- @return Result
function M.Storage.Upsert(citizenId, record, nodes, branches)
	return Storage.Execute([[
INSERT INTO opx77_skills (citizen_id, xp, level, points, nodes, branches)
VALUES (@citizen, @xp, @level, @points, @nodes, @branches)
ON DUPLICATE KEY UPDATE
    xp = @xp, level = @level, points = @points, nodes = @nodes, branches = @branches
  ]], {
		citizen = citizenId,
		xp = record.xp,
		level = record.level,
		points = record.points,
		nodes = nodes,
		branches = branches,
	})
end
