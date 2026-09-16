--- The rows that carry being down across a disconnect, one per character.
-- @author dop42
--
-- Every statement in the module lives here. No foreign key to the character
-- table: the order tables are created in is not this module's to decide.

local M = OPX.Modules.Get('downed')

M.Storage = {}

--- The create statement `Init` contributes to the schema.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_character_down (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    down_for_ms INT UNSIGNED NOT NULL DEFAULT 0,
    waiting TINYINT(1) NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

local SELECT_ROW = 'SELECT down_for_ms, waiting FROM opx77_character_down WHERE citizen_id = @citizen'

local UPSERT_ROW = [[
INSERT INTO opx77_character_down (citizen_id, down_for_ms, waiting) VALUES (@citizen, @downForMs, @waiting)
ON DUPLICATE KEY UPDATE down_for_ms = @downForMs, waiting = @waiting
]]

local DELETE_ROW = 'DELETE FROM opx77_character_down WHERE citizen_id = @citizen'

-- Writes and deletes waiting for the one worker, oldest first, so that they land
-- in the order they were asked for.
local queue = {}

-- Whether the worker thread is draining the queue.
local draining = false

-- Answers a value shaped like a citizen id that fits the column, or nil. The
-- shape only, not the checksum: the column holds whatever the character module
-- issues.
local function citizenOf(value)
	if type(value) ~= 'string' or #value < 1 or #value > 16 or not value:match('^[%w%-]+$') then
		return nil
	end
	return value
end

--- Whether the down table can be used.
-- @author dop42
--
-- The schema is applied once, before any module starts, and a failure there is
-- what `OPX.BootError` records: nothing is read or written while it is set.
-- @return boolean
function M.Storage.Ready()
	return OPX.BootError == nil
end

--- Reads a character's down row, or nil when it has none.
-- @author dop42
--
-- Yields, so it runs on a thread and never at file scope.
-- @param citizenId string
-- @return table|nil downForMs and waiting
function M.Storage.Read(citizenId)
	local citizen = citizenOf(citizenId)
	if not M.Storage.Ready() or citizen == nil then return nil end

	local read = OPX.Storage.Single(SELECT_ROW, { citizen = citizen })
	if not read.ok then
		Open77.log.error(('cannot read the down row of %s: %s')
			:format(citizen, tostring(read.detail or read.error)))
		return nil
	end

	local row = read.value
	if type(row) ~= 'table' then return nil end
	return {
		downForMs = math.max(0, math.floor(tonumber(row.down_for_ms) or 0)),
		waiting = tonumber(row.waiting) == 1 or row.waiting == true,
	}
end

-- Runs every queued statement in order, from one thread.
local function drain()
	if draining then return end
	draining = true
	CreateThread(function()
		while #queue > 0 do
			local job = table.remove(queue, 1)
			local written = OPX.Storage.Execute(job.sql, job.params)
			if not written.ok then
				Open77.log.error(('cannot %s the down row of %s: %s')
					:format(job.verb, job.params.citizen, tostring(written.detail or written.error)))
			end
		end
		draining = false
	end)
end

--- Queues a write of a character's down row, so that any caller may ask for one.
-- @author dop42
-- @param citizenId string
-- @param downForMs integer
-- @param waiting boolean
function M.Storage.Write(citizenId, downForMs, waiting)
	local citizen = citizenOf(citizenId)
	if not M.Storage.Ready() or citizen == nil then return end
	queue[#queue + 1] = { verb = 'write', sql = UPSERT_ROW, params = {
		citizen = citizen,
		downForMs = math.min(4294967295, math.max(0, math.floor(tonumber(downForMs) or 0))),
		waiting = waiting and 1 or 0,
	} }
	drain()
end

--- Queues a delete of a character's down row.
-- @author dop42
-- @param citizenId string
function M.Storage.Clear(citizenId)
	local citizen = citizenOf(citizenId)
	if not M.Storage.Ready() or citizen == nil then return end
	queue[#queue + 1] = { verb = 'clear', sql = DELETE_ROW, params = { citizen = citizen } }
	drain()
end
