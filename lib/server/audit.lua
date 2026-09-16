--- The player audit log, written as greppable platform log lines.
-- @author dop42
--
-- `Open77.log` says what the code does; this says what an operator will have to
-- account for later. The platform log is its only medium: every entry is one line
-- of the same shape, `[audit] event=... severity=... citizen=... user=...
-- player=... message="..." data=...`, so that a `grep` finds it again.
--
-- Everything here may have come from a client. A newline in client-chosen text
-- forges a whole log line, attributed to whatever resource the attacker names, so
-- every message and every data text is stripped of its control characters and
-- bounded. The cut falls between two characters rather than between two bytes:
-- cutting by bytes could split a multi-byte character and leave invalid UTF-8 in
-- the line.

OPX.Audit = {}
local Audit = OPX.Audit

-- The severities an entry may carry; anything else reads info.
local SEVERITIES = { debug = true, info = true, warn = true, error = true }

-- Longest message or data text one entry carries, in characters.
local MAX_MESSAGE = 200

-- Window in which repeated identical entries are collapsed, so that a client
-- looping on a refusal costs one line and a count instead of a screenful.
local DEDUPE_MS = 10000

-- How long a closed window is kept, so that the next entry can report its count.
local RETAIN_MS = DEDUPE_MS * 6

-- Recent entries by key, with their time, count and owner. The owner is stored
-- beside the key rather than parsed back out of it, because a key ends either
-- with the source or with the citizen id.
local recent = {}

-- Event prefixes whose info entries are never collapsed: six purchases in eight
-- seconds are six answers, and collapsing them would destroy the record. A
-- refusal under these prefixes is collapsed anyway, by its severity.
local LEDGER_PREFIXES = { 'money.', 'character.' }

--- Byte length of the first characters, bounded at four bytes each.
local function span(text, maximum)
	local size = math.min(#text, maximum * 4)
	local characters = 0
	for index = 1, size do
		-- A byte outside the 0x80..0xBF continuation range starts a character.
		local byte = text:byte(index)
		if byte < 0x80 or byte > 0xBF then
			if characters >= maximum then return index - 1 end
			characters = characters + 1
		end
	end
	return size
end

--- Turns a value into text without control characters, truncated.
local function bounded(value, maximum)
	local text = tostring(value or '')
	text = text:gsub('[%c]', ' ')
	local cut = span(text, maximum)
	if cut < #text then text = text:sub(1, cut) .. '...' end
	return text
end

--- Truncates a value and strips its control characters for logging.
-- @author dop42
--
-- Published because any text a caller puts in a log line may have been chosen by
-- a client, and a newline in it forges a whole line.
-- @param value any
-- @param maximum integer|nil characters to keep, 64 by default
-- @return string
function OPX.Audit.Safe(value, maximum)
	return bounded(value, maximum or 64)
end

--- Formats an entry as one key=value audit line.
local function toLine(entry)
	local parts = {
		('event=%s'):format(entry.event),
		('severity=%s'):format(entry.severity),
	}
	if entry.citizenId then parts[#parts + 1] = ('citizen=%s'):format(entry.citizenId) end
	if entry.userId then parts[#parts + 1] = ('user=%s'):format(entry.userId) end
	if entry.source then parts[#parts + 1] = ('player=%d'):format(entry.source) end
	if entry.message and entry.message ~= '' then
		parts[#parts + 1] = ('message=%q'):format(entry.message)
	end
	if entry.data then
		parts[#parts + 1] = ('data=%s'):format(bounded(json.encode(entry.data), MAX_MESSAGE))
	end
	return table.concat(parts, ' ')
end

--- Answers whether an entry must be written every time.
local function isLedger(entry)
	if entry.severity ~= 'info' and entry.severity ~= 'debug' then return false end
	for i = 1, #LEDGER_PREFIXES do
		local prefix = LEDGER_PREFIXES[i]
		if entry.event:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- When the recent entries may next be swept.
local nextSweepAt = 0

--- Drops recent entries past their retention, at most once a window.
local function sweep(now)
	-- Sweeping on every entry would be a full walk per line. This, not `forget`,
	-- is what bounds the table. It only removes keys `pairs` has already yielded,
	-- which Lua defines; adding during the walk is not defined.
	if now < nextSweepAt then return end
	nextSweepAt = now + DEDUPE_MS
	for key, seen in pairs(recent) do
		if now - seen.at >= RETAIN_MS then recent[key] = nil end
	end
end

--- Counts an entry and answers whether its window is still open.
local function repeated(key, owner)
	local now = OPX.Now()
	sweep(now)
	local seen = recent[key]
	if seen and now - seen.at < DEDUPE_MS then
		seen.count = seen.count + 1
		return true, seen.count
	end
	local carried = seen and seen.count or 0
	recent[key] = { at = now, count = 0, owner = owner }
	return false, carried
end

--- Forgets the dedupe windows a departing player or character owns.
-- @author dop42
--
-- A caller that knows the citizen id passes it: an entry logged without a source
-- is keyed by citizen id, which a departing source does not name.
-- @param source Source
-- @param citizenId CitizenId|nil
function OPX.Audit.Forget(source, citizenId)
	local bySource = tostring(source)
	local byCitizen = citizenId ~= nil and tostring(citizenId) or nil
	for key, seen in pairs(recent) do
		if seen.owner == bySource or (byCitizen and seen.owner == byCitizen) then
			recent[key] = nil
		end
	end
end

--- Writes one audit entry, collapsing repeats outside the ledger.
-- @author dop42
--
-- The first entry written after a closed window carries `[+N suppressed]`.
-- @param entry table event, severity, message, data, source, citizenId, userId
function OPX.Audit.Log(entry)
	if type(entry) ~= 'table' or type(entry.event) ~= 'string' then return end
	entry.severity = SEVERITIES[entry.severity] and entry.severity or 'info'
	entry.message = entry.message ~= nil and bounded(entry.message, MAX_MESSAGE) or nil

	if not isLedger(entry) then
		local owner = tostring(entry.source or entry.citizenId or '-')
		local again, carried = repeated(entry.event .. '\1' .. owner, owner)
		if again then return end
		if carried > 0 then
			entry.message = ('%s [+%d suppressed]'):format(entry.message or '', carried)
		end
	end

	Open77.log[entry.severity](('[audit] %s'):format(toLine(entry)))
end

--- Writes an audit entry attributed to a loaded character.
-- @author dop42
--
-- Covers the most common shape: the source, citizen and account of a `Player`.
-- @param player Player|nil
-- @param event string
-- @param message string|nil
-- @param data table|nil
function OPX.Audit.Player(player, event, message, data)
	local playerData = player and player.PlayerData
	Audit.Log({
		event = event,
		message = message,
		data = data,
		source = playerData and playerData.source,
		citizenId = playerData and playerData.citizenId,
		userId = playerData and playerData.userId,
	})
end

--- Writes a warn audit entry for a refused or suspicious request.
-- @author dop42
--
-- Always pass the source: without it the window is keyed by event alone, and one
-- player looping on a refusal swallows the refusals of everybody else.
-- @param event string
-- @param message string|nil
-- @param data table|nil
-- @param source Source|nil who caused it, keying the dedupe window
function OPX.Audit.Security(event, message, data, source)
	Audit.Log({ event = event, severity = 'warn', message = message, data = data,
		source = source })
end
