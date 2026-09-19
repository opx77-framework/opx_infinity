--- The one table this module reads or writes: one row of needs per character.
-- @author dop42
--
-- Every statement in the module lives here. No foreign key to the character
-- table: this module would then refuse to install until the character module had
-- migrated, and the order tables are created in is not this module's to decide.

local M = OPX.Modules.Get('needs')
local Bounds = M.Bounds

M.Storage = {}

--- The create statement `Init` contributes to the schema.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_character_status (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    needs JSON NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

local SELECT_NEEDS = 'SELECT needs FROM opx77_character_status WHERE citizen_id = @citizen'

local DELETE_NEEDS = 'DELETE FROM opx77_character_status WHERE citizen_id = @citizen'

local UPSERT_NEEDS = [[
INSERT INTO opx77_character_status (citizen_id, needs) VALUES (@citizen, @needs)
ON DUPLICATE KEY UPDATE needs = @needs
]]

--- Reads a character's stored needs, or the defaults when it has no row.
-- @author dop42
--
-- Yields, so it runs on a thread and never at file scope.
-- @param citizenId string
-- @return table|nil the bounded values, nil when the row could not be read
-- @return string|nil why
function M.Storage.Load(citizenId)
	local read = OPX.Storage.Single(SELECT_NEEDS, { citizen = citizenId })
	if not read.ok then return nil, tostring(read.detail or read.error) end

	local row = read.value
	if type(row) ~= 'table' or row.needs == nil then return Bounds.Defaults() end
	-- A column that will not decode reads as absent: the row loads at the
	-- defaults rather than refusing the character its needs.
	return (Bounds.Read(OPX.Storage.Decode(row.needs, nil)))
end

--- Writes one character's needs, logging a failure.
-- @author dop42
--
-- Yields, so it runs on a thread and never at file scope.
-- @param citizenId string
-- @param values table
-- @return boolean
function M.Storage.Save(citizenId, values)
	-- Guarded: a table that will not encode raises, and this runs inside a
	-- thread where a raise is silent.
	local encoded, payload = pcall(json.encode, values)
	if not encoded then
		Open77.log.warn(('%s not saved: %s'):format(OPX.Audit.Safe(citizenId), tostring(payload)))
		return false
	end

	local written = OPX.Storage.Update(UPSERT_NEEDS, { citizen = citizenId, needs = payload })
	if not written.ok then
		Open77.log.warn(('%s not saved: %s')
			:format(OPX.Audit.Safe(citizenId), tostring(written.detail or written.error)))
		return false
	end
	return true
end

--- Removes the needs of a character that has been deleted.
-- @author dop42
--
-- NOTHING ELSE WOULD. The header above explains why this table carries no
-- foreign key onto `opx77_characters`, and that reasoning still holds -- but it
-- left the row with nothing at all to remove it, and a foreign key would not
-- have removed it either: a character delete is a SOFT delete, `deleted_at` on a
-- row that stays, and no cascade fires for an UPDATE. So this is called from the
-- character module's own delete announcement instead, which is the seam that
-- exists for exactly this and had nobody listening to it.
--
-- Yields, so it runs on a thread and never at file scope.
-- @param citizenId string
-- @return boolean
function M.Storage.PurgeCharacter(citizenId)
	local removed = OPX.Storage.Update(DELETE_NEEDS, { citizen = citizenId })
	if not removed.ok then
		Open77.log.warn(('%s: needs not removed on delete: %s')
			:format(OPX.Audit.Safe(citizenId), tostring(removed.detail or removed.error)))
		return false
	end
	return true
end
