--- The record reader: the base game's own word on every cyberware record,
--- read through a live client and kept in the database.
-- @author XEROX710
--
-- WHY A CLIENT. The names a patient reads for Night City's chrome live in the
-- game's TweakDB and its localisation, and a dedicated server has neither:
-- `Open77.data.localize` answers `localization_client_only` here. A client is
-- inside the game with both loaded, so the server hands it the record ids
-- (`server/records.lua`) a batch at a time and keeps what its live TweakDB
-- says each one is -- the display name in that player's language, the
-- quality, the equipment area, the item type, the locale key. The table it
-- fills (`opx77_ripperdoc_records`) is what the tray's record rows are
-- checked against: a codename becomes a piece only when the game itself says
-- what the codename is.
--
-- ONE READ AT A TIME, through one client, and bounded: a batch that is not
-- answered in time ends the read (the reader's client may have left or be
-- loading), and every answer is checked against the batch it answers -- a
-- client cannot write a record it was not asked about.

local M = OPX.Modules.Get('ripperdoc')

M.Reader = {}

-- The one read in flight, or nil.
local read = nil
-- The last read's outcome, for `status`.
local last = nil
-- Players already asked to read automatically, so a rejoin does not start a
-- second one, and the players still here.
local autoAsked, present = {}, {}
-- The build the kept records were counted against, and how many there were.
local kept = { build = nil, count = nil }

local BATCH_TIMEOUT_MS = 30000
local MAX_TEXT = 160

--- The reader's policy. Never nil.
-- @return table
local function policy()
	return type(M.Settings.RECORDS) == 'table' and M.Settings.RECORDS or {}
end

--- A short printable string, or ''.
-- @param value any
-- @param limit integer|nil
-- @return string
local function text(value, limit)
	if type(value) ~= 'string' then
		if type(value) == 'number' then value = tostring(value) else return '' end
	end
	value = value:gsub('[%c]', ' ')
	limit = limit or MAX_TEXT
	if #value > limit then value = value:sub(1, limit) end
	return value
end

--- The full record id of one list slot.
-- @param index integer
-- @return string|nil
local function recordAt(index)
	local short = M.Records ~= nil and M.Records.IDS[index] or nil
	return short ~= nil and ('Items.' .. short) or nil
end

--- How many records the list holds.
-- @return integer
function M.Reader.Total()
	return M.Records ~= nil and #M.Records.IDS or 0
end

--- Reads how many records are already kept for this build. Yields.
-- @return integer|nil
function M.Reader.Kept()
	local build = M.Records ~= nil and M.Records.BUILD or ''
	local result = M.Storage.CountRecords(build)
	if type(result) ~= 'table' or result.ok ~= true then return nil end
	local row = type(result.value) == 'table' and result.value[1] or nil
	local count = type(row) == 'table' and tonumber(row.n) or nil
	kept.build, kept.count = build, count
	return count
end

--- Ends the read in flight, saying why.
-- @param why string
local function finish(why)
	if read == nil then return end
	last = {
		player = read.player, why = why, answered = read.answered, kept = read.kept,
		failed = read.failed, missing = read.missing, total = M.Reader.Total(),
		seconds = math.floor((OPX.Now() - read.started) / 1000),
	}
	Open77.log.info(('[ripperdoc] record reader through player %d %s: %d answered, %d kept, ' ..
		'%d unknown to the client, %d not written, %ds'):format(read.player, why, read.answered,
		read.kept, read.missing, read.failed, last.seconds))
	read = nil
end

--- Sends the next batch, or ends the read when the list is walked.
local function sendNext()
	if read == nil then return end
	local total = M.Reader.Total()
	if read.next > total then return finish('finished') end
	local size = math.max(1, math.min(80, math.floor(tonumber(policy().BATCH) or 40)))
	local ids = {}
	for index = read.next, math.min(total, read.next + size - 1) do
		ids[#ids + 1] = recordAt(index)
	end
	read.batch = read.batch + 1
	read.from, read.count = read.next, #ids
	read.asked = {}
	for _, id in ipairs(ids) do read.asked[id] = true end
	read.next = read.next + #ids
	read.sentAt = OPX.Now()
	local sent = pcall(TriggerClientEvent, M.Event.RESOLVE, read.player, read.nonce, read.batch, ids)
	if not sent then return finish('could not reach the client') end
	-- A batch nobody answers ends the read rather than holding it for ever.
	local batch, nonce, sentAt = read.batch, read.nonce, read.sentAt
	CreateThread(function()
		while read ~= nil and read.nonce == nonce and read.batch == batch
			and OPX.Now() - sentAt < BATCH_TIMEOUT_MS do
			Wait(1000)
		end
		if read ~= nil and read.nonce == nonce and read.batch == batch then
			finish(('stopped: batch %d was not answered in %ds'):format(batch,
				BATCH_TIMEOUT_MS // 1000))
		end
	end)
end

--- Starts a read through one player's client.
-- @param player number
-- @return boolean started
-- @return string|nil why not
function M.Reader.Start(player)
	player = tonumber(player)
	if player == nil or player <= 0 then return false, 'name a connected player' end
	if M.Reader.Total() == 0 then return false, 'this build carries no record list' end
	if read ~= nil then
		return false, ('a read is already running through player %d (%d of %d)')
			:format(read.player, read.next - 1, M.Reader.Total())
	end
	read = {
		player = player, nonce = ('%d:%d'):format(OPX.Now(), player), started = OPX.Now(),
		next = 1, batch = 0, answered = 0, kept = 0, failed = 0, missing = 0,
	}
	Open77.log.info(('[ripperdoc] record reader: reading %d base-game cyberware records through ' ..
		'player %d'):format(M.Reader.Total(), player))
	sendNext()
	return true, nil
end

--- One line of how the reader stands.
-- @return string
function M.Reader.Status()
	if read ~= nil then
		return ('reading through player %d: %d of %d asked, %d kept so far')
			:format(read.player, read.next - 1, M.Reader.Total(), read.kept)
	end
	local parts = {}
	if kept.count ~= nil then
		parts[#parts + 1] = ('%d of %d records kept for build %s'):format(kept.count,
			M.Reader.Total(), tostring(kept.build))
	end
	if last ~= nil then
		parts[#parts + 1] = ('last read through player %d %s (%d answered, %d kept, %d unknown)')
			:format(last.player, last.why, last.answered, last.kept, last.missing)
	end
	if #parts == 0 then return 'no read yet' end
	return table.concat(parts, '; ')
end

--- One batch answered. Only the records the batch asked about are kept, and
--- only from the client the read runs through. Yields (the writes).
-- @param player number
-- @param nonce any
-- @param batch any
-- @param rows any
function M.Reader.Answer(player, nonce, batch, rows)
	if read == nil or player ~= read.player or tostring(nonce) ~= read.nonce
		or tonumber(batch) ~= read.batch then return end
	local asked = read.asked
	read.asked = {}
	local build = M.Records.BUILD
	for _, row in ipairs(type(rows) == 'table' and rows or {}) do
		local id = type(row) == 'table' and text(row.record, 128) or ''
		if asked[id] then
			asked[id] = nil
			read.answered = read.answered + 1
			local answer = text(row.answer, 48)
			if answer ~= 'ok' then read.missing = read.missing + 1 end
			local saved = M.Storage.UpsertRecord({
				record = id, name = text(row.name), quality = text(row.quality, 48),
				area = text(row.area, 64), itemType = text(row.itemType, 64),
				localeKey = text(row.localeKey, 48), class = text(row.class, 64),
				answer = answer ~= '' and answer or 'ok', build = build,
			})
			if type(saved) == 'table' and saved.ok == true then
				read.kept = read.kept + 1
			else
				read.failed = read.failed + 1
			end
		end
	end
	-- A read may have been ended while the writes yielded.
	if read == nil or tostring(nonce) ~= read.nonce then return end
	sendNext()
end

--- A player who stays in the city reads the list once, automatically, while
--- the table does not hold every record for this build.
-- @param player number
function M.Reader.Arrived(player)
	local rules = policy()
	present[player] = true
	if rules.AUTO == false or autoAsked[player] then return end
	autoAsked[player] = true
	local arrived = OPX.Now()
	local after = math.max(0, math.floor(tonumber(rules.AUTO_AFTER_MS) or 90000))
	CreateThread(function()
		while present[player] and OPX.Now() - arrived < after do Wait(1000) end
		if read ~= nil or not present[player] then return end
		local count = M.Reader.Kept()
		if count == nil or count >= M.Reader.Total() then return end
		M.Reader.Start(player)
	end)
end

--- A player left: a read through them ends, and they may be asked again.
-- @param player number
function M.Reader.Left(player)
	autoAsked[player], present[player] = nil, nil
	if read ~= nil and read.player == player then finish('stopped: the reader left') end
end

--- Resets the reader (Init).
function M.Reader.Reset()
	read, last, autoAsked, present = nil, nil, {}, {}
	kept.build, kept.count = nil, nil
end
