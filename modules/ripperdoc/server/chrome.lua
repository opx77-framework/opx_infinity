--- The chrome that wears out, and the chrome the platform holds as a grant:
-- one condition number per patient per piece, every way it goes down, and the
-- shelves the movement kit and the decks are defined on.
-- @author XEROX710
--
-- WHY A LEDGER BESIDE THE PLATFORM'S. The platform's durable record says WHAT
-- implant is in which of its slots; it has no opinion on how worn it is, and
-- it holds nothing at all for chrome it has no adapter for. So this ledger is
-- two things. For every piece it is the CONDITION (100 fresh, 0 broken). For
-- the pieces the platform does not hold -- the movement grants, the stat
-- chrome, the roleplay chrome -- it is also the INSTALLATION: a row with a
-- grade is a piece that is fitted.
--
-- EVERY PIECE HAS A LIFE IN REAL DAYS (`M.Ripper.Lifecycle`):
--   time    `LIFESPAN_DAYS` of calendar time from its fitting or its last
--           repair to broken, online or not: every tick wears each loaded
--           patient's chrome by the time since it was last worn, and the time
--           a patient spent away is caught up the next time their ledger loads
--   use     the host's own action events -- the punch, the jump, the dash, the
--           overdrive, the slam, the upload -- only on the piece that did it
--   damage  a body that takes a hit wears the chrome plating it
--   death   flatlining is hard on everything
-- The last three are EXTRA life off, in minutes of it, and together never
-- more than `WEAR_DAYS` of one life (`M.Chrome.WearFor`): the hardest use
-- there is brings the break forward by that much and no more. The level of
-- the character stretches the life (`M.Ripper.LevelFactor`). Crossing into
-- WORN, FAILING or BROKEN is told to the patient once, in their own words. A
-- broken piece stops paying for itself (`server/effects.lua` reads the band);
-- a broken implant is pulled through the same remove staging every sale uses
-- (`M.Event.ON_BROKEN`, answered in `server/main.lua`); a broken grant has its
-- grant dropped.
--
-- THE LEDGER IS TWO TABLES. `opx77_ripperdoc_chrome` holds what it always did
-- (the grade, the whole-number condition, broken); `opx77_ripperdoc_life` --
-- NEW, because this runtime has no migration step -- holds the life: the
-- precise points, the extra wear used, when the calendar last wore it and when
-- the life began. A chrome row with no life row predates real-day durability,
-- and is the owner's ONE-TIME RESET: back to fresh, once, journalled.
--
-- THE MOVEMENT KIT IS GRANTS, NOT RECORDS. `dash`, `reflex` and `ability`
-- pieces live in the platform's movement modules: the clinic defines one
-- immutable definition per grade at Start and arms the fitted one on the
-- patient. A grant is a session thing (the platform drops it when the player
-- leaves), so a player who is READY picks their fitted pieces back up.

local M = OPX.Modules.Get('ripperdoc')

local CreateThread, Wait = CreateThread, Wait

M.Chrome = {}

-- citizen id -> entry id -> { points, broken, grade, use, wornAt, startedAt,
-- dirty, refit }: `use` is the extra wear taken so far (points), `wornAt` when
-- the calendar last wore it and `startedAt` when its life began (unix seconds),
-- and `refit` a broken implant made whole again while out of the body, waiting
-- to be fitted back (`{ points, why, tries }`).
local ledger = {}
-- "citizen|entry" -> what the chrome table holds for that piece (the whole
-- condition, broken, the grade), as last read or written: it is written again
-- only when that moves.
local stored = {}
-- citizen ids whose fetch has been asked for (one read per patient, ever)
local asked = {}
-- player key -> entry id -> definition id, the grants armed right now
local armed = {}
-- player key -> entry id -> true: grants armed while the player sat in a chair,
-- which their own client never kept (see `M.Chrome.Reproject`)
local stale = {}
-- player key -> entry id -> true: grants HELD BACK -- revoked on purpose and
-- never re-armed by anything until they are given back (`M.Chrome.HoldBack`:
-- a Sandevistan whose boost outlasts the platform's, until its cooldown ends)
local heldBack = {}
-- definition id -> true, the definitions the platform accepted at Start
local shelf = {}
-- citizen id -> the player it was last seen on, for the tick's notifications
local holders = {}
-- Per player: the re-arm refusals already said, and the last death revision
-- read (the life bus may deliver out of order).
local ensureWarned = {}
local deathRevision = {}
-- Whether a failing read has been said out loud already (once per boot, the
-- way every other module reports a storage it cannot read).
local warnedRead = false
-- the character contract, resolved on first use (an optional dependency may
-- publish after this module has run)
local character = nil
-- The tick's run flag, so Stop ends it.
local ticking = false
-- Whether the wall clock is settled: false while the database's clock is being
-- read at Start on a host with no clock of its own (a ledger read meanwhile
-- would stamp lives with the wrong clock).
local clockSettled = true
-- How many times a broken implant made whole is tried back into the body in
-- one session before it waits for the next.
local REFIT_TRIES = 3

--- The character contract, fetched once and kept.
local function contracts()
	if character == nil then character = OPX.Api.Get('character') end
end

--- One patient's durable name, or nil when there is none to read. The same
--- contract read `server/main.lua` settles every charge with.
-- @param player number
-- @return string|nil
local function citizenOf(player)
	contracts()
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local ran, record = pcall(character.GetPlayer, player)
	if not ran or type(record) ~= 'table' then return nil end
	local data = type(record.PlayerData) == 'table' and record.PlayerData or record
	local citizenId = data.citizenId
	return type(citizenId) == 'string' and citizenId or nil
end
M.Chrome.CitizenOf = citizenOf

--- The player one citizen is on, or nil: the one last seen wearing it, else
--- the one the character contract names.
-- @param citizenId string
-- @return number|nil
local function playerOf(citizenId)
	if holders[citizenId] ~= nil then return holders[citizenId] end
	contracts()
	if character == nil or type(character.GetPlayerByCitizenId) ~= 'function' then return nil end
	local ran, found = pcall(character.GetPlayerByCitizenId, citizenId)
	if not ran or found == nil then return nil end
	if type(found) == 'table' then
		local data = type(found.PlayerData) == 'table' and found.PlayerData or found
		found = data.source
	end
	return tonumber(found)
end

--- One citizen's life numbers for a pass: the lifecycle, the character's
--- level and cap, the extra-wear cap in points and the clock -- read once.
-- @param citizenId string|nil
-- @return table
local function lifeOf(citizenId)
	local life = M.Ripper.Lifecycle()
	life.level, life.cap = M.Ripper.LevelOf(citizenId)
	life.now = M.Ripper.UnixNow()
	life.capPoints = M.Ripper.WearCapPoints(life)
	return life
end

--- Real seconds one piece lasts for this citizen, fresh to broken.
-- @param entry table
-- @param life table `lifeOf`
-- @return number
local function lifeSeconds(entry, life)
	return M.Ripper.LifeSeconds(entry, life.level, life.cap, life)
end

--- The condition `seconds` of one piece's life are worth.
-- @param entry table
-- @param seconds number
-- @param life table `lifeOf`
-- @return number points
local function pointsFor(entry, seconds, life)
	local total = lifeSeconds(entry, life)
	if total <= 0 or seconds <= 0 then return 0 end
	return 100 * seconds / total
end

--- Whether two stamps come from the same kind of clock: a wall-clock stamp
--- is never read against a monotonic one (a host without a wall clock ages
--- chrome only while it runs, and never invents a gap between two boots).
-- @param a number
-- @param b number
-- @return boolean
local function sameClock(a, b)
	return M.Ripper.WallClock(a) == M.Ripper.WallClock(b)
end

--- A fresh life for one piece: its condition, no extra wear, and the calendar
--- starting now.
-- @param grade string|nil
-- @param points number|nil 100 unless given
-- @param now number unix seconds
-- @return table a ledger row
local function freshRow(grade, points, now)
	return {
		points = math.max(0, math.min(100, tonumber(points) or 100)), broken = false,
		grade = tostring(grade or ''), use = 0, wornAt = now, startedAt = now, dirty = true,
	}
end

--- What the chrome table holds for a row, as one comparable string.
-- @param points number
-- @param broken boolean
-- @param grade string
-- @return string
local function shownAs(points, broken, grade)
	return ('%d|%d|%s'):format(math.floor(tonumber(points) or 100), broken and 1 or 0, tostring(grade or ''))
end

-- Defined below, used by Load.
local breakPiece, wearRow

--- The calendar's wear on one citizen's chrome since each piece was last worn
--- by it -- the tick, and the catch-up at a load. A piece whose stamp comes from
--- another kind of clock (or from the future) is stamped again, never worn.
--- Answers what moved.
-- @param player number|nil
-- @param citizenId string
-- @param life table `lifeOf`
-- @return table array of { id, before, after, broke, seconds }
local function age(player, citizenId, life)
	local rows = ledger[citizenId]
	local moved = {}
	if rows == nil then return moved end
	-- Collected first: breaking a piece raises events, and the rows table is
	-- not walked while that happens.
	local targets = {}
	for entryId, row in pairs(rows) do
		if row.broken ~= true and tostring(row.grade or '') ~= '' then
			local entry = M.Ripper.Entry(entryId)
			local since = tonumber(row.wornAt)
			if entry ~= nil then
				if since == nil or since > life.now or not sameClock(since, life.now) then
					row.wornAt, row.dirty = life.now, true
				elseif life.now > since then
					targets[#targets + 1] = { entry = entry, row = row, seconds = life.now - since }
				end
			end
		end
	end
	table.sort(targets, function(a, b) return a.entry.id < b.entry.id end)
	for _, target in ipairs(targets) do
		local before = tonumber(target.row.points) or 100
		target.row.wornAt = life.now
		local broke = wearRow(player, citizenId, target.entry, pointsFor(target.entry, target.seconds, life),
			('its life ran out (%.1f h worn by the calendar)'):format(target.seconds / 3600))
		moved[#moved + 1] = { id = target.entry.id, before = before,
			after = tonumber(target.row.points) or 0, broke = broke, seconds = target.seconds }
	end
	return moved
end

--- One player's ledger, loaded on first need, the time it spent away caught
--- up, and -- for a row that predates real-day durability -- the one-time reset.
--- Yields; call from a thread.
-- @param citizenId string|nil
-- @return table the citizen's rows, never nil
function M.Chrome.Load(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then return {} end
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	if asked[citizenId] then return ledger[citizenId] end
	asked[citizenId] = true
	-- A life is stamped with the clock: on a host whose only wall clock is the
	-- database's, the read at Start is waited for (a few seconds at most).
	for _ = 1, 50 do
		if clockSettled then break end
		Wait(100)
	end
	local rows = M.Storage.FetchChrome(citizenId)
	local lives = (type(rows) == 'table' and rows.ok == true) and M.Storage.FetchLife(citizenId) or nil
	if type(rows) ~= 'table' or rows.ok ~= true or type(lives) ~= 'table' or lives.ok ~= true then
		-- A ledger that could not be read is not a ledger that silently says
		-- "fresh": the read is asked for again and every answer keeps 100
		-- until a write lands. SAID ONCE, though: a database that is down is
		-- one incident, not one per patient per minute. And a life table that
		-- cannot be read is NOT a ledger with no lives: that would reset every
		-- piece the patient wears.
		asked[citizenId] = nil
		if not warnedRead then
			warnedRead = true
			local failed = (type(rows) ~= 'table' or rows.ok ~= true) and rows or lives
			Open77.log.warn('[ripperdoc] chrome condition could not be read: '
				.. tostring(type(failed) == 'table' and failed.detail or 'no answer'))
		end
		return ledger[citizenId]
	end
	local lived = {}
	for _, row in ipairs(type(lives.value) == 'table' and lives.value or {}) do
		if type(row) == 'table' and type(row.entry_id) == 'string' then lived[row.entry_id] = row end
	end
	local life = lifeOf(citizenId)
	local player = playerOf(citizenId)
	local mine = ledger[citizenId]
	local reset = {}
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		local entryId = type(row) == 'table' and row.entry_id or nil
		local entry = type(entryId) == 'string' and M.Ripper.Entry(entryId) or nil
		-- A row written by THIS session while the read was in flight is newer
		-- than the read: the read never overwrites it.
		if entry ~= nil and mine[entryId] == nil then
			local grade = tostring(row.grade_key or '')
			local broken = tonumber(row.broken) == 1
			local points = math.max(0, math.min(100, tonumber(row.condition_points) or 100))
			stored[citizenId .. '|' .. entryId] = shownAs(points, broken, grade)
			local kept = lived[entryId]
			if kept ~= nil then
				mine[entryId] = {
					points = broken and 0 or math.max(0, math.min(100, tonumber(kept.points) or points)),
					broken = broken, grade = grade,
					use = math.max(0, tonumber(kept.use_wear) or 0),
					wornAt = tonumber(kept.worn_at), startedAt = tonumber(kept.started_at),
				}
			elseif broken and grade ~= '' and M.Ripper.IsPlatform(entry) then
				-- THE ONE-TIME RESET, for an implant the break pulled out of the
				-- body: it cannot be whole in the ledger while the platform's
				-- record says its slot is empty, so it is fitted back for free
				-- (`M.Ripper.Refit`, on the arrival and every tick) and its fresh
				-- life starts when that lands. Nothing is written until then: a
				-- restart before it simply resets it again.
				mine[entryId] = { points = 0, broken = true, grade = grade, use = 0,
					wornAt = life.now, startedAt = life.now,
					refit = { points = 100, why = 'reset', tries = 0 } }
				reset[#reset + 1] = { id = entryId, grade = grade, was = 'broken, out of the body',
					refit = true }
			else
				-- THE ONE-TIME RESET: this row predates real-day durability. Back
				-- to fresh, a new life starting now -- written at once below, so
				-- it happens once.
				mine[entryId] = freshRow(grade, 100, life.now)
				reset[#reset + 1] = { id = entryId, grade = grade,
					was = broken and 'broken' or ('%d%%'):format(math.floor(points)) }
			end
		end
	end
	for _, piece in ipairs(reset) do
		Open77.log.info(('[ripperdoc] %s: the one-time chrome reset (real-day durability): %s (%s) was %s -- %s')
			:format(citizenId, piece.id, piece.grade ~= '' and piece.grade or 'no grade', piece.was,
				piece.refit and 'whole again, and fitted back into the body for free as soon as its record reads'
					or ('back to 100%%, a new %.2f-day life from now'):format(
						lifeSeconds(M.Ripper.Entry(piece.id), life) / M.Ripper.DAY_SECONDS)))
	end
	-- THE TIME AWAY, caught up at the level the character has now -- only
	-- against a wall clock: a monotonic timer restarts with the server, and two
	-- boots' readings compared would invent (or hide) a gap. Without one, the
	-- lives start counting again from now.
	if not M.Ripper.WallClock(life.now) then
		for _, row in pairs(mine) do
			if row.broken ~= true then row.wornAt = life.now end
		end
	end
	local moved = age(player, citizenId, life)
	local longest = 0
	for _, piece in ipairs(moved) do longest = math.max(longest, piece.seconds) end
	if #moved > 0 and longest >= 60 then
		local parts = {}
		for _, piece in ipairs(moved) do
			parts[#parts + 1] = ('%s %.1f -> %.1f%s'):format(piece.id, piece.before, piece.after,
				piece.broke and ' (BROKE)' or '')
		end
		Open77.log.info(('[ripperdoc] %s: chrome caught up over %.1f h since it was last worn (level %d of %d): %s')
			:format(citizenId, longest / 3600, math.floor(life.level), math.floor(life.cap),
				table.concat(parts, ', ')))
	end
	M.Chrome.Changed(citizenId)
	M.Chrome.Flush(citizenId)
	return ledger[citizenId]
end

--- Whether a citizen's ledger has been read (so its silence means "nothing").
-- @param citizenId string|nil
-- @return boolean
function M.Chrome.Loaded(citizenId)
	return type(citizenId) == 'string' and asked[citizenId] == true
end

--- One piece's condition. Never nil: an unread piece is a fresh piece.
-- @param citizenId string|nil
-- @param entryId string
-- @return table { points, broken, grade }
function M.Chrome.Row(citizenId, entryId)
	local rows = type(citizenId) == 'string' and ledger[citizenId] or nil
	local row = rows ~= nil and rows[entryId] or nil
	if row == nil then return { points = 100, broken = false, grade = '' } end
	return row
end

--- Every row a citizen has, entry id -> row. Never nil.
-- @param citizenId string|nil
-- @return table
function M.Chrome.Rows(citizenId)
	return type(citizenId) == 'string' and ledger[citizenId] or {}
end

--- Whether the piece is broken (and therefore paying nobody).
-- @param citizenId string|nil
-- @param entryId string
-- @return boolean
function M.Chrome.Broken(citizenId, entryId)
	return M.Chrome.Row(citizenId, entryId).broken == true
end

--- Raises the change for one citizen, so the stat composer and any open tray
--- see it. Cheap; called on every write.
-- @param citizenId string|nil
function M.Chrome.Changed(citizenId)
	if type(citizenId) ~= 'string' then return end
	TriggerEvent(M.Event.ON_CHANGED, { citizen = citizenId })
end

--- Writes one piece's condition and its life through to the database. Yields;
--- call from a thread. The chrome table's points are written as the whole
--- number BELOW them, so a reconnect can only ever find the chrome a little
--- more worn, never mended -- and only when that number, the break or the grade
--- moved; the life (the precise points, the extra wear, when the calendar last
--- wore it) is written every time. A broken implant waiting to be fitted back
--- by the one-time reset is not written at all: until it is back in the body a
--- restart resets it again.
-- @param citizenId string
-- @param entryId string
local function writeRow(citizenId, entryId, row)
	row.dirty = nil
	if row.refit ~= nil and row.refit.why == 'reset' then return true end
	local now = M.Ripper.UnixNow()
	local key = citizenId .. '|' .. tostring(entryId)
	local shown = shownAs(row.points, row.broken == true, row.grade)
	if stored[key] ~= shown then
		local saved = M.Storage.UpsertChrome(citizenId, entryId, tostring(row.grade or ''),
			math.floor(tonumber(row.points) or 100), row.broken == true)
		if type(saved) ~= 'table' or saved.ok ~= true then
			row.dirty = true
			Open77.log.warn(('[ripperdoc] the condition of %s could not be saved: %s')
				:format(tostring(entryId),
					tostring(type(saved) == 'table' and saved.detail or 'no answer')))
			return false
		end
		stored[key] = shown
	end
	local lived = M.Storage.UpsertLife(citizenId, entryId, tonumber(row.points) or 100,
		tonumber(row.use) or 0, math.floor(tonumber(row.wornAt) or now),
		math.floor(tonumber(row.startedAt) or now))
	if type(lived) ~= 'table' or lived.ok ~= true then
		row.dirty = true
		Open77.log.warn(('[ripperdoc] the life of %s could not be saved: %s')
			:format(tostring(entryId), tostring(type(lived) == 'table' and lived.detail or 'no answer')))
		return false
	end
	return true
end

-- "citizen|entry" -> true while a write (or a pull's delete) of that piece is
-- out, and -> true in `again` when another was asked for meanwhile.
local writing, again = {}, {}

--- ONE WRITE PER PIECE AT A TIME. A write yields, and two statements for the
--- same row in flight may land in either order -- the older last, and a
--- repaired piece read back worn. So a write asked for while one is out only
--- says so, and the one out goes again with what the row holds by then: the
--- last to land is always the newest.
-- @param citizenId string
-- @param entryId string
local function save(citizenId, entryId)
	local key = citizenId .. '|' .. tostring(entryId)
	local rows = ledger[citizenId]
	local row = rows ~= nil and rows[entryId] or nil
	-- A piece pulled since the write was asked for has nothing left to write.
	if row == nil then return end
	if writing[key] then
		row.dirty, again[key] = true, true
		return
	end
	writing[key] = true
	for _ = 1, 4 do
		again[key] = nil
		rows = ledger[citizenId]
		row = rows ~= nil and rows[entryId] or nil
		if row == nil then break end
		-- A raise must not leave the piece marked as being written: every
		-- later write of it would only say so, and none would go out.
		local ran, wrote = pcall(writeRow, citizenId, entryId, row)
		if not ran then
			row.dirty = true
			Open77.log.warn(('[ripperdoc] the write of %s raised: %s'):format(tostring(entryId), tostring(wrote)))
		end
		if not ran or not wrote or not again[key] then break end
	end
	writing[key], again[key] = nil, nil
end

--- Writes every row that changed since the last write. Yields.
-- @param citizenId string|nil only this citizen's, or everyone's when nil
function M.Chrome.Flush(citizenId)
	local targets = {}
	if type(citizenId) == 'string' then
		targets[citizenId] = ledger[citizenId]
	else
		targets = ledger
	end
	for citizen, rows in pairs(targets) do
		for entryId, row in pairs(rows or {}) do
			if row.dirty then save(citizen, entryId) end
		end
	end
end

--- Puts a fresh life on one piece, replacing its row, and writes it.
-- @param citizenId string
-- @param entryId string
-- @param gradeId string|nil
-- @param points number|nil 100 unless given
-- @param write boolean|nil false leaves the write to the next flush
local function renew(citizenId, entryId, gradeId, points, write)
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	local row = freshRow(gradeId, points, M.Ripper.UnixNow())
	ledger[citizenId][entryId] = row
	if write ~= false then CreateThread(function() save(citizenId, entryId) end) end
	M.Chrome.Changed(citizenId)
	return row
end

--- Records a fitted piece at full condition -- the completion of an install,
--- and of an upgrade (new chrome is new chrome): a fresh life, starting now.
-- @param citizenId string|nil
-- @param entryId string
-- @param gradeId string|nil
-- @param points number|nil the condition it starts at, 100 unless given (an
-- implant an admin set, fitted back into the body)
function M.Chrome.Fit(citizenId, entryId, gradeId, points)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	renew(citizenId, entryId, gradeId, points)
end

--- Forgets a pulled piece entirely: its condition and its life.
-- @param citizenId string|nil
-- @param entryId string
function M.Chrome.Pull(citizenId, entryId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if ledger[citizenId] ~= nil then ledger[citizenId][entryId] = nil end
	CreateThread(function()
		-- After any write of the piece still out (it would land after the
		-- delete and bring the pulled piece back) -- ten seconds at most -- and
		-- holding the piece while it deletes.
		local key = citizenId .. '|' .. tostring(entryId)
		for _ = 1, 200 do
			if not writing[key] then break end
			Wait(50)
		end
		writing[key] = true
		local gone = M.Storage.DeleteChrome(citizenId, entryId)
		if type(gone) ~= 'table' or gone.ok ~= true then
			Open77.log.warn(('[ripperdoc] the condition row of %s could not be deleted: %s')
				:format(tostring(entryId),
					tostring(type(gone) == 'table' and gone.detail or 'no answer')))
		end
		local ended = M.Storage.DeleteLife(citizenId, entryId)
		if type(ended) ~= 'table' or ended.ok ~= true then
			Open77.log.warn(('[ripperdoc] the life row of %s could not be deleted: %s')
				:format(tostring(entryId),
					tostring(type(ended) == 'table' and ended.detail or 'no answer')))
		end
		writing[key], again[key], stored[key] = nil, nil, nil
		-- Fitted again while the delete was out: written now, after it.
		local rows = ledger[citizenId]
		if rows ~= nil and rows[entryId] ~= nil and rows[entryId].dirty then save(citizenId, entryId) end
	end)
	M.Chrome.Changed(citizenId)
end

--- Buys the wear back: a repaired piece is fresh again -- a new life from
--- now -- and remembers its grade so a pull-then-repair knows what to fit back.
-- @param citizenId string|nil
-- @param entryId string
function M.Chrome.Repair(citizenId, entryId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	renew(citizenId, entryId, M.Chrome.Row(citizenId, entryId).grade)
end

--- Makes sure a platform implant the record holds has a row -- an implant
--- fitted before the ledger existed, or by another resource, starts a fresh
--- life here rather than being invisible to the lifecycle.
-- @param citizenId string|nil
-- @param entryId string
-- @param gradeId string
function M.Chrome.Adopt(citizenId, entryId, gradeId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	local row = ledger[citizenId][entryId]
	if row ~= nil and tostring(row.grade or '') == tostring(gradeId or '') then return end
	if row ~= nil and row.broken then return end
	-- Written with the next flush, as it always was.
	renew(citizenId, entryId, gradeId, 100, false)
end

--- A piece made whole where it is, without the chair: the one-time reset or an
--- admin, on a piece that is still in the body (or held in the ledger). Its
--- life starts again at `points`, with no extra wear, and it is written now.
-- @param citizenId string
-- @param entryId string
-- @param points number|nil 100 unless given
function M.Chrome.Mend(citizenId, entryId, points)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	local row = ledger[citizenId] ~= nil and ledger[citizenId][entryId] or nil
	if row == nil then return end
	renew(citizenId, entryId, row.grade, points)
end

--- The broken implants of one citizen that the one-time reset or an admin
--- made whole while they were out of the body, still to be fitted back
--- (`M.Ripper.Refit` in `server/main.lua` stages it) -- and not yet tried as
--- often as a session tries one.
-- @param citizenId string|nil
-- @return table array of { entry, row }
function M.Chrome.Refits(citizenId)
	local out = {}
	for entryId, row in pairs(type(citizenId) == 'string' and ledger[citizenId] or {}) do
		local entry = row.refit ~= nil and M.Ripper.Entry(entryId) or nil
		if entry ~= nil and row.broken == true and (row.refit.tries or 0) < REFIT_TRIES then
			out[#out + 1] = { entry = entry, row = row }
		end
	end
	table.sort(out, function(a, b) return a.entry.id < b.entry.id end)
	return out
end

--- The broken implants of one citizen that are not waiting to be fitted back
--- -- the ones a break should have pulled out of the body. A break the
--- calendar caught up at a load (the piece ran out while its owner was away)
--- often comes before the patient's record reads, so the pull is asked for
--- again by the arrival and the tick until the record says the slot is free.
-- @param citizenId string|nil
-- @return table array of entries
function M.Chrome.BrokenImplants(citizenId)
	local out = {}
	for entryId, row in pairs(type(citizenId) == 'string' and ledger[citizenId] or {}) do
		local entry = row.broken == true and row.refit == nil and tostring(row.grade or '') ~= ''
			and M.Ripper.Entry(entryId) or nil
		if entry ~= nil and M.Ripper.IsPlatform(entry) then out[#out + 1] = entry end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

--- A broken implant that cannot go back in the body: its slot holds another
--- piece now. It stays broken -- repairable at a chair once the slot is free --
--- and, for the one-time reset, that is the reset done (written, so it is not
--- tried again at every load).
-- @param citizenId string
-- @param entryId string
-- @param why string for the journal
function M.Chrome.RefitRefused(citizenId, entryId, why)
	local row = ledger[citizenId] ~= nil and ledger[citizenId][entryId] or nil
	if row == nil or row.refit == nil then return end
	local reset = row.refit.why == 'reset'
	row.refit = nil
	row.dirty = true
	Open77.log.info(('[ripperdoc] %s: %s stays broken and out of the body -- %s%s'):format(citizenId,
		entryId, tostring(why), reset and ' (the one-time reset leaves it repairable at a chair)' or ''))
	CreateThread(function() save(citizenId, entryId) end)
	M.Chrome.Changed(citizenId)
end

--- The definition the platform accepted at Start.
-- @param definitionId string
-- @return boolean
function M.Chrome.Shelf(definitionId)
	return shelf[definitionId] == true
end

--- Whether the grant for this piece is armed on the player right now.
-- @param player number
-- @param entryId string
-- @return boolean
function M.Chrome.Armed(player, entryId)
	local key = M.Ripper.KeyOf(player)
	return armed[key] ~= nil and armed[key][entryId] ~= nil
end

--- Arms the piece's grant on the player, or says why not. A grant is a
--- session thing and this is the only place that hands one out.
-- @param player number
-- @param entry table
-- @param grade table
-- @return boolean granted
-- @return string|nil why not
local function arm(player, entry, grade)
	local definitionId = M.Ripper.DefinitionFor(entry, grade)
	if not M.Chrome.Shelf(definitionId) then
		return false, 'the definition ' .. tostring(definitionId) .. ' is not on the shelf'
	end
	local module = M.Ripper.GrantModule(entry)
	if module == nil or type(module.grant) ~= 'function' then
		return false, 'no grant door on this host'
	end
	local key = M.Ripper.KeyOf(player)
	local ran, result, why = pcall(module.grant, player, definitionId)
	-- THE ANSWER IS A TABLE -- the movement modules return `{ok=true}` or
	-- `nil, reason` (`wiki/dash.md`), exactly like their `define`. Comparing
	-- the table to `true` calls every granted piece a refusal and swallows
	-- the reason with it. Read what is actually returned.
	local accepted = ran and (result == true
		or (type(result) == 'table' and result.ok == true))
	if not accepted then
		return false, tostring((not ran and result)
			or (type(result) == 'table' and (result.reason or result.error))
			or why or 'refused')
	end
	if armed[key] == nil then armed[key] = {} end
	-- ONE GRANT PER MODULE: the platform holds one dash, one overdrive and one
	-- ability per resource per player, so arming a second piece of the same
	-- kind replaced the first on the host. The bookkeeping says so too.
	local kind = M.Ripper.GrantKind(entry)
	for otherId in pairs(armed[key]) do
		local other = M.Ripper.Entry(otherId)
		if otherId ~= entry.id and other ~= nil and M.Ripper.GrantKind(other) == kind then
			armed[key][otherId] = nil
		end
	end
	armed[key][entry.id] = definitionId
	-- ARMED IN THE CHAIR IS NOT ARMED. The patient sits in a workspot, and the
	-- movement clients refuse a body in one: `open77_reflex` takes the
	-- projection, acks it -- so the server reads `ready` -- then finds no
	-- usable body on its next frame and drops it for good, because only a NEW
	-- revision ever rebuilds it. That was "the Apogee is fitted and does
	-- nothing": the key was dead until the next session. So a grant armed on a
	-- seated player is marked, and projected again once they are up
	-- (`M.Chrome.Reproject`, from the stand in `server/main.lua`).
	if type(M.Ripper.Seated) == 'function' and M.Ripper.Seated(player) then
		stale[key] = stale[key] or {}
		stale[key][entry.id] = true
	end
	M.Chrome.PushKit(player)
	return true, nil
end

--- Drops the piece's grant, if it is armed.
-- @param player number
-- @param entry table
local function disarm(player, entry)
	local key = M.Ripper.KeyOf(player)
	if stale[key] ~= nil then stale[key][entry.id] = nil end
	local definitionId = armed[key] ~= nil and armed[key][entry.id] or nil
	if definitionId == nil then return end
	armed[key][entry.id] = nil
	local module = M.Ripper.GrantModule(entry)
	if module ~= nil and type(module.revoke) == 'function' then
		pcall(module.revoke, player, definitionId)
	end
	M.Chrome.PushKit(player)
end

--- The piece whose grant of one power kind is armed on a player, or nil.
-- @param player number
-- @param kind string `dash`, `reflex` or `ability`
-- @return table|nil entry
function M.Chrome.ArmedEntry(player, kind)
	for entryId in pairs(armed[M.Ripper.KeyOf(player)] or {}) do
		local entry = M.Ripper.Entry(entryId)
		if entry ~= nil and M.Ripper.GrantKind(entry) == kind then return entry end
	end
	return nil
end

--- The definition id a piece's grant is armed under on a player, or nil.
-- @param player number
-- @param entryId string
-- @return string|nil
function M.Chrome.ArmedDefinition(player, entryId)
	local held = armed[M.Ripper.KeyOf(player)]
	return held ~= nil and held[entryId] or nil
end

--- Whether a player holds a grant that was armed while they sat in a chair --
--- any, or the one piece named.
-- @param player number
-- @param entryId string|nil
-- @return boolean
function M.Chrome.Stale(player, entryId)
	local marks = stale[M.Ripper.KeyOf(player)]
	if marks == nil then return false end
	if entryId ~= nil then return marks[entryId] == true end
	return next(marks) ~= nil
end

--- What one player holds, as their own machine needs it: every movement power
--- armed on them, the default key it answers to and the look it wears -- and
--- a power HELD BACK until its cooldown ends (`held = true`), which their
--- machine still holds as theirs (its real item stays on, and nothing asks for
--- it to be projected again) while nothing can engage it.
-- @param player number
-- @return table kind -> { entry, name, key, look, held }
function M.Chrome.Kit(player)
	local grants = {}
	local key = M.Ripper.KeyOf(player)
	for entryId in pairs(armed[key] or {}) do
		local entry = M.Ripper.Entry(entryId)
		local kind = entry ~= nil and M.Ripper.GrantKind(entry) or nil
		if kind == 'dash' or kind == 'reflex' or kind == 'ability' then
			local _, look = M.Ripper.SandyLook(entry)
			grants[kind] = { entry = entryId, name = entry.NAME, key = M.Ripper.PowerKey(entry),
				look = look }
		end
	end
	local citizenId = heldBack[key] ~= nil and citizenOf(player) or nil
	for entryId in pairs(heldBack[key] or {}) do
		local entry = M.Ripper.Entry(entryId)
		local kind = entry ~= nil and M.Ripper.GrantKind(entry) or nil
		local row = M.Chrome.Row(citizenId, entryId)
		if (kind == 'dash' or kind == 'reflex' or kind == 'ability') and grants[kind] == nil
			and row.broken ~= true and tostring(row.grade or '') ~= '' then
			local _, look = M.Ripper.SandyLook(entry)
			grants[kind] = { entry = entryId, name = entry.NAME, key = M.Ripper.PowerKey(entry),
				look = look, held = true }
		end
	end
	return grants
end

--- Tells a player's own machine what it holds (`M.Event.KIT`), with anything
--- `extra` adds: `announce` (a piece just became usable) or `reproject` (a
--- one-use token to ask for the chair's grants again once standing).
-- @param player number
-- @param extra table|nil
-- @return boolean sent
function M.Chrome.PushKit(player, extra)
	local target = tonumber(player)
	if target == nil or target <= 0 then return false end
	local payload = { grants = M.Chrome.Kit(target) }
	-- A token not yet handed back rides every kit, so a request the server
	-- could not take (the patient sat down again first) is simply sent again.
	if type(M.Ripper.PendingReproject) == 'function' then
		payload.reproject = M.Ripper.PendingReproject(target)
	end
	for field, value in pairs(type(extra) == 'table' and extra or {}) do payload[field] = value end
	local sent = pcall(TriggerClientEvent, M.Event.KIT, target, payload)
	return sent
end

--- Gives a player's own client a FRESH projection of the powers the server
--- holds on them: each one revoked and granted again, so the platform sends a
--- new revision and the client builds it against the body it has NOW. `only`
--- narrows it: `'stale'` is what was armed while they sat in a chair, a power
--- kind (`'reflex'`) is that power alone, nil is everything.
-- @param player number
-- @param only string|nil
-- @return integer how many were projected again
function M.Chrome.Reproject(player, only)
	local key = M.Ripper.KeyOf(player)
	local held = armed[key]
	if held == nil then return 0 end
	local citizenId = citizenOf(player)
	local targets = {}
	for entryId in pairs(held) do
		local entry = M.Ripper.Entry(entryId)
		-- A power held back is never projected again here: only its own
		-- release gives it back (`M.Chrome.GiveBack`).
		if entry ~= nil and M.Ripper.IsGrant(entry) and not M.Chrome.HeldBack(player, entryId)
			and (only == nil
			or (only == 'stale' and stale[key] ~= nil and stale[key][entryId] == true)
			or only == M.Ripper.GrantKind(entry)) then
			targets[#targets + 1] = entry
		end
	end
	local done, missed = 0, 0
	for _, entry in ipairs(targets) do
		local grade = M.Ripper.Grade(entry, M.Chrome.Row(citizenId, entry.id).grade)
		if grade ~= nil then
			disarm(player, entry)
			local granted, why = arm(player, entry, grade)
			if granted then
				done = done + 1
			else
				missed = missed + 1
				Open77.log.warn(('[ripperdoc] %s could not be projected again on player %s: %s (retrying)')
					:format(entry.id, tostring(player), tostring(why)))
			end
		end
	end
	-- A grant the platform turned away straight after its own revoke is asked
	-- for again in a moment rather than at the next wear tick, a minute away.
	if missed > 0 then
		CreateThread(function()
			for _ = 1, 3 do
				Wait(2000)
				if M.Chrome.Ensure(player) == 0 then return end
			end
		end)
	end
	return done
end

--- Arms every fitted, unbroken grant the patient owns and does not hold yet --
--- except one HELD BACK (`M.Chrome.HoldBack`), which waits for its release.
--- Safe to call often: it only ever acts on what is missing.
-- @param player number
function M.Chrome.Ensure(player)
	local citizenId = citizenOf(player)
	if citizenId == nil then return 0 end
	local rows = ledger[citizenId]
	if rows == nil then return 0 end
	local missing = 0
	local key = M.Ripper.KeyOf(player)
	for entryId, row in pairs(rows) do
		local entry = M.Ripper.Entry(entryId)
		if entry ~= nil and M.Ripper.IsGrant(entry) and row.broken ~= true
			and tostring(row.grade or '') ~= '' and not M.Chrome.HeldBack(player, entryId) then
			local grade = M.Ripper.Grade(entry, row.grade)
			if grade ~= nil and not M.Chrome.Armed(player, entryId) then
				local granted, why = arm(player, entry, grade)
				if not granted then
					missing = missing + 1
					-- Retried until it lands (a grant wants a bound, living body,
					-- and a fresh session has neither for a few seconds), and SAID
					-- once per reason rather than once per retry.
					local said = ensureWarned[key] or {}
					ensureWarned[key] = said
					if said[entryId] ~= tostring(why) then
						said[entryId] = tostring(why)
						Open77.log.warn(('[ripperdoc] could not re-arm %s on player %s: %s (retrying)')
							:format(entryId, tostring(player), tostring(why)))
					end
				elseif ensureWarned[key] ~= nil then
					ensureWarned[key][entryId] = nil
				end
			end
		end
	end
	return missing
end

--- Asks `server/main.lua` to fit back the broken implants the one-time reset
--- or an admin made whole while they were out of the body. Answers how many
--- still wait.
-- @param player number
-- @return integer
local function refit(player)
	if type(M.Ripper.Refit) ~= 'function' then return 0 end
	local ran, waiting = pcall(M.Ripper.Refit, player)
	if not ran then
		Open77.log.warn('[ripperdoc] fitting an implant back raised: ' .. tostring(waiting))
		return 0
	end
	return tonumber(waiting) or 0
end

--- Loads one character's ledger and arms what it names, retrying the grants
--- while the platform is still binding the body -- and fits back what the
--- one-time reset made whole while it was out of the body, once the record
--- reads. Yields; call from a thread.
-- @param player number
function M.Chrome.Arrive(player)
	local citizenId = citizenOf(player)
	if citizenId == nil then return end
	holders[citizenId] = player
	M.Chrome.Load(citizenId)
	for _ = 1, 8 do
		if citizenOf(player) ~= citizenId then return end
		local missing = M.Chrome.Ensure(player)
		local waiting = refit(player)
		if missing == 0 and waiting == 0 then return end
		Wait(5000)
	end
end

--- Fits a movement kit piece on the patient: the grant IS the installation.
-- @param player number
-- @param entry table
-- @param grade table
-- @return boolean
-- @return string|nil
function M.Chrome.FitGrant(player, entry, grade)
	-- New chrome is new chrome: whatever held the old grant back does not
	-- hold this one.
	local marks = heldBack[M.Ripper.KeyOf(player)]
	if marks ~= nil then marks[entry.id] = nil end
	local granted, why = arm(player, entry, grade)
	if not granted then return false, why end
	M.Chrome.Fit(citizenOf(player), entry.id, grade.id)
	return true, nil
end

--- Pulls a movement kit piece: the grant goes and the row goes with it.
-- @param player number
-- @param entry table
function M.Chrome.PullGrant(player, entry)
	local marks = heldBack[M.Ripper.KeyOf(player)]
	if marks ~= nil then marks[entry.id] = nil end
	disarm(player, entry)
	M.Chrome.Pull(citizenOf(player), entry.id)
end

-- ── a grant held back ─────────────────────────────────────────────────────
--
-- A SANDEVISTAN'S BOOST CAN OUTLAST THE PLATFORM'S (`server/sandevistan.lua`:
-- the ripperdoc runs the look and the slowed world for the level-scaled time,
-- the platform's overdrive stops at its own 15 s ceiling). The platform starts
-- its cooldown when ITS overdrive ends, so the only way to have no new boost
-- start before the ripperdoc's own ends and its cooldown has passed is to hold
-- the grant: revoked when the platform's overdrive completes, and never armed
-- again -- not by Ensure, not by a re-projection, not by an arrival -- until
-- `GiveBack`. A disconnect or a character put down clears it.

--- Whether a grant is held back on a player -- the one piece named, or any.
-- @param player number
-- @param entryId string|nil
-- @return boolean
function M.Chrome.HeldBack(player, entryId)
	local marks = heldBack[M.Ripper.KeyOf(player)]
	if marks == nil then return false end
	if entryId ~= nil then return marks[entryId] == true end
	return next(marks) ~= nil
end

--- Holds a grant back: revoked on the platform, marked so nothing arms it
--- again, and the player's machine told it is held (not gone).
-- @param player number
-- @param entry table
-- @return boolean whether it was armed
function M.Chrome.HoldBack(player, entry)
	local key = M.Ripper.KeyOf(player)
	heldBack[key] = heldBack[key] or {}
	heldBack[key][entry.id] = true
	local was = M.Chrome.Armed(player, entry.id)
	if was then disarm(player, entry) else M.Chrome.PushKit(player) end
	return was
end

--- Gives a held grant back: the mark goes and the grant is armed again the
--- ordinary way (a piece that broke or was pulled meanwhile stays off).
-- @param player number
-- @param entryId string
-- @return boolean whether it is armed now
function M.Chrome.GiveBack(player, entryId)
	local key = M.Ripper.KeyOf(player)
	local marks = heldBack[key]
	if marks ~= nil then
		marks[entryId] = nil
		if next(marks) == nil then heldBack[key] = nil end
	end
	M.Chrome.Ensure(player)
	local back = M.Chrome.Armed(player, entryId)
	if back then return true end
	-- Not armed: the kit says so (the held power is gone from it), and a
	-- platform that turned the grant away is asked again in a moment rather
	-- than at the next tick.
	M.Chrome.PushKit(player)
	CreateThread(function()
		for _ = 1, 3 do
			Wait(2000)
			if M.Chrome.HeldBack(player, entryId) or M.Chrome.Ensure(player) == 0 then return end
		end
	end)
	return false
end

--- Tells the patient their chrome just crossed into a worse band. Said once
--- per crossing, in the server's language, with the piece named in it.
-- @param player number|nil
-- @param entry table
-- @param band string
local function announce(player, entry, band)
	if player == nil or band == 'optimal' then return end
	local key = 'ripperdoc.wear.' .. band
	pcall(OPX.NotifyLocale, player, key, { name = locale(entry.NAME) },
		band == 'worn' and 'info' or 'error')
end

--- THE BREAK, with exactly the consequences wear has: the piece at zero and
--- broken, its grant dropped, the patient told, the row written, the journal,
--- and `ON_BROKEN` -- on which `server/main.lua` pulls a broken implant.
-- @param player number|nil the body wearing it
-- @param citizenId string
-- @param entry table
-- @param row table its ledger row
-- @param cause string for the journal
breakPiece = function(player, citizenId, entry, row, cause)
	row.points, row.broken, row.dirty, row.refit = 0, true, true, nil
	if M.Ripper.IsGrant(entry) and player ~= nil then disarm(player, entry) end
	announce(player, entry, 'broken')
	Open77.log.info(('[ripperdoc] %s%s: %s (%s) broke -- %s'):format(citizenId,
		player ~= nil and (' on player ' .. tostring(player)) or '', entry.id,
		tostring(row.grade or ''), tostring(cause or 'worn to zero')))
	CreateThread(function() save(citizenId, entry.id) end)
	TriggerEvent(M.Event.ON_BROKEN, {
		player = player, citizen = citizenId,
		entry = entry.id, grade = tostring(row.grade or ''),
	})
	M.Chrome.Changed(citizenId)
end

--- Takes points off one fitted piece, breaking it at zero and saying so when
--- it crosses into a worse band. The write is deferred to the tick's flush:
--- a piece worn every second must not be a row written every second.
-- @param player number|nil
-- @param citizenId string
-- @param entry table
-- @param points number
-- @param cause string|nil for the journal, should it break
-- @return boolean whether it broke
wearRow = function(player, citizenId, entry, points, cause)
	if type(citizenId) ~= 'string' or type(entry) ~= 'table' then return false end
	points = tonumber(points) or 0
	if points <= 0 or points ~= points then return false end
	local rows = ledger[citizenId]
	local row = rows ~= nil and rows[entry.id] or nil
	if row == nil or row.broken == true or tostring(row.grade or '') == '' then
		-- Nothing fitted here: a piece is only worn while the patient wears it.
		return false
	end
	local before = M.Ripper.ConditionState(row.points, false)
	row.points = math.max(0, (tonumber(row.points) or 100) - points)
	row.dirty = true
	if row.points <= 0 then
		breakPiece(player, citizenId, entry, row, cause)
		return true
	end
	local after = M.Ripper.ConditionState(row.points, false)
	if after ~= before then
		announce(player, entry, after)
		-- A band crossing changes what the piece is worth, so the numbers are
		-- recomposed now rather than at the next reconcile.
		M.Chrome.Changed(citizenId)
	end
	return false
end

--- THE RAW PRIMITIVE: takes `points` of condition off one fitted piece, as
--- they are -- no cap, no clock. Every wear path ends here; the tests force
--- bands and breaks with it.
-- @param player number|nil the body wearing it, for the notice and the break
-- @param citizenId string
-- @param entry table
-- @param points number
-- @param cause string|nil for the journal, should it break
-- @return boolean whether it broke
function M.Chrome.WearPiece(player, citizenId, entry, points, cause)
	return wearRow(player, citizenId, entry, points, cause)
end

--- EXTRA WEAR, CAPPED: `minutes` of one piece's life taken off by use, damage
--- or a death -- never more, over one life, than `WEAR_DAYS` of it (the cap is
--- `M.Ripper.WearCapPoints`, and what was taken so far is the row's `use`).
--- Once the cap is spent, the calendar alone decides when it breaks.
-- @param player number|nil
-- @param citizenId string
-- @param entry table
-- @param minutes number
-- @param cause string for the journal, should it break
-- @param life table|nil `lifeOf`, read when absent
-- @return boolean whether it broke
function M.Chrome.WearFor(player, citizenId, entry, minutes, cause, life)
	minutes = tonumber(minutes) or 0
	if minutes <= 0 or minutes ~= minutes or type(entry) ~= 'table' then return false end
	local rows = type(citizenId) == 'string' and ledger[citizenId] or nil
	local row = rows ~= nil and rows[entry.id] or nil
	if row == nil or row.broken == true or tostring(row.grade or '') == '' then return false end
	life = life or lifeOf(citizenId)
	local used = math.max(0, tonumber(row.use) or 0)
	local points = math.min(pointsFor(entry, minutes * 60, life), math.max(0, life.capPoints - used))
	if points <= 0 then return false end
	row.use = used + points
	return wearRow(player, citizenId, entry, points, cause)
end

--- Wears every fitted piece a predicate accepts by the same minutes of life,
--- through the capped path.
-- @param player number
-- @param citizenId string
-- @param accept function(entry, row): boolean
-- @param minutes number|function(entry): number
-- @param cause string
local function wearWhere(player, citizenId, accept, minutes, cause)
	local rows = ledger[citizenId]
	if rows == nil then return end
	-- Collected first: breaking a piece raises events, and the rows table is
	-- not walked while that happens.
	local targets = {}
	for entryId, row in pairs(rows) do
		if row.broken ~= true and tostring(row.grade or '') ~= '' then
			local entry = M.Ripper.Entry(entryId)
			if entry ~= nil and accept(entry, row) then targets[#targets + 1] = entry end
		end
	end
	local life = #targets > 0 and lifeOf(citizenId) or nil
	for _, entry in ipairs(targets) do
		local amount = type(minutes) == 'function' and minutes(entry, life) or minutes
		M.Chrome.WearFor(player, citizenId, entry, amount, cause, life)
	end
end

--- Applies one use-wear event to the pieces it belongs to: `USE_MINUTES` of
--- life times each piece's own weight.
-- @param player number
-- @param eventName string a key of `DURABILITY.WEAR_BY`
function M.Chrome.Wear(player, eventName)
	local selector = M.Ripper.WearSelector(eventName)
	if selector == nil then return end
	player = tonumber(player)
	if player == nil then return end
	local citizenId = citizenOf(player)
	if citizenId == nil then return end
	holders[citizenId] = player
	CreateThread(function()
		M.Chrome.Load(citizenId)
		wearWhere(player, citizenId, function(entry)
			return M.Ripper.WearMatches(selector, entry)
		end, function(entry, life)
			return life.USE_MINUTES * M.Ripper.WearWeight(entry)
		end, 'worn out by use (' .. tostring(eventName) .. ')')
	end)
end

--- The damage a body took wears the plating it wears: every fitted piece
--- whose grade carries armor loses `DAMAGE_MINUTES` of life per 100 damage.
-- @param player number
-- @param amount number health points the hit was worth
function M.Chrome.WearDamage(player, amount)
	local life = M.Ripper.Lifecycle()
	amount = tonumber(amount) or 0
	if amount <= 0 or life.DAMAGE_MINUTES <= 0 then return end
	local citizenId = citizenOf(player)
	if citizenId == nil or ledger[citizenId] == nil then return end
	holders[citizenId] = player
	wearWhere(player, citizenId, function(entry, row)
		local grade = M.Ripper.Grade(entry, row.grade)
		local effects = type(grade) == 'table' and grade.EFFECTS or nil
		return type(effects) == 'table' and (tonumber(effects.armor) or 0) > 0
	end, life.DAMAGE_MINUTES * amount / 100, 'worn out by damage')
end

--- A death wears everything the body was wearing: `DEATH_MINUTES` of life.
-- @param player number
function M.Chrome.WearDeath(player)
	local life = M.Ripper.Lifecycle()
	if life.DEATH_MINUTES <= 0 then return end
	local citizenId = citizenOf(player)
	if citizenId == nil or ledger[citizenId] == nil then return end
	holders[citizenId] = player
	wearWhere(player, citizenId, function() return true end, life.DEATH_MINUTES, 'worn out by a death')
end

--- The calendar's wear on one citizen's chrome up to now (the tick's own
--- step, public for the tests and the admin). Answers what moved.
-- @param player number|nil
-- @param citizenId string
-- @return table array of { id, before, after, broke, seconds }
function M.Chrome.Age(player, citizenId)
	if type(citizenId) ~= 'string' or ledger[citizenId] == nil then return {} end
	return age(player, citizenId, lifeOf(citizenId))
end

--- How long one fitted piece has left, as the tray shows it: the condition
--- now (the calendar's wear since the last tick counted in), the seconds to
--- broken at the current rate -- the calendar alone, at the character's level
--- -- and the extra wear used and its cap, in seconds of that life. nil
--- `left` when nothing is fitted, the piece is broken or durability is off.
-- @param citizenId string|nil
-- @param entryId string
-- @param life table|nil `lifeOf`, read when absent
-- @return table { points, left, wear, wearCap, life }
function M.Chrome.Life(citizenId, entryId, life)
	local row = M.Chrome.Row(citizenId, entryId)
	local entry = M.Ripper.Entry(entryId)
	local points = row.broken == true and 0 or math.max(0, math.min(100, tonumber(row.points) or 100))
	if entry == nil or row.broken == true or tostring(row.grade or '') == '' then
		return { points = points }
	end
	life = life or lifeOf(citizenId)
	local total = lifeSeconds(entry, life)
	if total <= 0 then return { points = points } end
	local since = tonumber(row.wornAt)
	if since ~= nil and since <= life.now and sameClock(since, life.now) then
		points = math.max(0, points - 100 * (life.now - since) / total)
	end
	return {
		points = points,
		left = math.floor(points * total / 100),
		wear = math.floor(math.max(0, tonumber(row.use) or 0) * total / 100),
		wearCap = math.floor(life.capPoints * total / 100),
		life = math.floor(total),
	}
end

--- THE ADMIN'S OVERRIDE (`/opx.clinic.chrome`): every piece fitted on one
--- character set at once. A condition above 0 is a new life at that condition
--- -- the calendar's wear already `100 - value`, no extra wear, so the time
--- left matches it -- on a piece un-broken, re-armed (a grant) or fitted back
--- into the body (a broken implant, through `M.Ripper.Refit`); `100` is a
--- fresh life. 0 breaks every piece with exactly the consequences wear has.
--- Answers one row per piece, sorted by id.
-- @param player number the character's player
-- @param citizenId string
-- @param value number 0..100
-- @return table array of { id, grade, before, after, broken, refit }
function M.Chrome.SetAll(player, citizenId, value)
	local rows = type(citizenId) == 'string' and ledger[citizenId] or nil
	if rows == nil then return {} end
	value = math.max(0, math.min(100, tonumber(value) or 100))
	holders[citizenId] = player
	local ids = {}
	for entryId, row in pairs(rows) do
		if tostring(row.grade or '') ~= '' and M.Ripper.Entry(entryId) ~= nil then ids[#ids + 1] = entryId end
	end
	table.sort(ids)
	local out = {}
	for _, entryId in ipairs(ids) do
		local entry = M.Ripper.Entry(entryId)
		local row = rows[entryId]
		local before = row.broken == true and 0 or (tonumber(row.points) or 100)
		local line = { id = entryId, grade = row.grade, before = before, after = value }
		if value <= 0 then
			if row.broken ~= true then breakPiece(player, citizenId, entry, row, 'set to 0 by an admin') end
			line.after, line.broken = 0, true
		elseif row.broken == true and M.Ripper.IsPlatform(entry) then
			-- Pulled when it broke (or still in the body where the pull never
			-- came): `M.Ripper.Refit` reads the record and fits it back, or
			-- mends it where it is, at this condition.
			row.refit = { points = value, why = 'admin', tries = 0 }
			line.refit = true
		else
			renew(citizenId, entryId, row.grade, value)
		end
		out[#out + 1] = line
	end
	if value > 0 then
		M.Chrome.Ensure(player)
		refit(player)
	end
	M.Chrome.Changed(citizenId)
	return out
end

--- One tick of the clock: every loaded, connected patient's chrome -- dead or
--- alive, the calendar does not care -- worn by the time since it was last
--- worn, a grant the platform refused asked for again, an implant waiting to
--- go back in the body tried again, and every row that changed written once.
function M.Chrome.Tick()
	local read, ids = pcall(Open77.players.all)
	for _, raw in ipairs(read and type(ids) == 'table' and ids or {}) do
		local player = tonumber(raw)
		local citizenId = player ~= nil and citizenOf(player) or nil
		if citizenId ~= nil and ledger[citizenId] ~= nil then
			holders[citizenId] = player
			age(player, citizenId, lifeOf(citizenId))
			-- A grant the platform refused at arrival is asked for again every
			-- tick until it lands, and so is an implant that has to go back into
			-- the body -- or out of it, broken.
			M.Chrome.Ensure(player)
			if #M.Chrome.Refits(citizenId) > 0 or #M.Chrome.BrokenImplants(citizenId) > 0 then refit(player) end
		end
	end
	M.Chrome.Flush(nil)
end

--- Forgets one citizen's rows after writing what changed -- a character that
--- is put down must not keep wearing, and a slot reused by somebody else must
--- not inherit their chrome. Yields.
-- @param citizenId string|nil
function M.Chrome.Forget(citizenId)
	if type(citizenId) ~= 'string' then return end
	M.Chrome.Flush(citizenId)
	for entryId in pairs(ledger[citizenId] or {}) do stored[citizenId .. '|' .. tostring(entryId)] = nil end
	ledger[citizenId], asked[citizenId], holders[citizenId] = nil, nil, nil
end

--- The JSON decoder the wear events arrive through, or nil when the host has
--- none. The same tolerant shape `server/main.lua` reads completions with.
-- @param encoded any
-- @return table|nil
local function decode(encoded)
	if type(json) == 'table' and type(json.decode) == 'function' then
		local ran, result = pcall(json.decode, tostring(encoded or ''))
		if ran and type(result) == 'table' then return result end
	end
	return nil
end

--- One wear door per host event. Each reads its own result and only counts
--- the wear the platform says actually happened.
local function onMeleeHit(victim, attacker, encoded)
	local result = decode(encoded)
	if result ~= nil and result.ok == false then return end
	M.Chrome.Wear(attacker, 'hit')
end

local function onJump(player, encoded)
	local result = decode(encoded)
	if result ~= nil and result.ok == false then return end
	M.Chrome.Wear(player, 'jump')
end

local function onDash(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'accepted' then return end
	M.Chrome.Wear(player, 'dash')
end

local function onReflex(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'active' then return end
	M.Chrome.Wear(player, 'overdrive')
end

local function onAbility(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.ok == false then return end
	M.Chrome.Wear(player, 'slam')
end

--- The hacking transition names its actor inside the JSON (`wiki/hacking.md`:
--- "records correlate actionId, both participants"), and the first argument
--- the host passes is not a promise about which participant it is. Read the
--- actor from the record, and fall back to the argument.
local function onHacking(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'upload_started'
		and payload.phase ~= 'uploading' then
		return
	end
	local actor = payload ~= nil and (payload.actor or payload.attacker or payload.player) or nil
	M.Chrome.Wear(tonumber(actor) or player, 'upload')
end

--- One definition on one of the platform's shelves, said once either way.
-- @param shelfName string for the log line
-- @param define function the platform's `define`
-- @param definition table
local function put(shelfName, define, definition)
	local ran, result, why = pcall(define, definition)
	local accepted = ran and type(result) == 'table' and result.ok == true
	if accepted then
		shelf[definition.id] = true
		Open77.log.info(('[ripperdoc] the %s %s is on the shelf'):format(shelfName, definition.id))
	else
		local reason = (not ran and result)
			or (type(result) == 'table' and (result.reason or result.error)) or why
		Open77.log.warn(('[ripperdoc] the %s %s was refused: %s')
			:format(shelfName, definition.id, tostring(reason)))
	end
end

--- Defines every movement piece, deck hack and Self-ICE on the platform's own
--- shelves, and arms the wear table. Called from `server/main.lua` at Start.
function M.Chrome.Start()
	local hacking = type(Open77) == 'table' and type(Open77.hacking) == 'table'
		and Open77.hacking or nil
	-- THE MOVEMENT KIT: one definition per distinct config, within what the
	-- platform takes per module (`M.Ripper.GrantPlan`).
	local grantPlan = M.Ripper.GrantPlan()
	local counts = {}
	for _, def in ipairs(grantPlan.defs) do
		local module = M.Ripper.GrantModule({ POWER = { GRANT = def.kind } })
		if module ~= nil and type(module.define) == 'function' then
			put(def.kind, module.define, { id = def.id, version = 1, profile = def.profile,
				config = def.config })
			counts[def.kind] = (counts[def.kind] or 0) + 1
		end
	end
	for kind, count in pairs(counts) do
		Open77.log.info(('[ripperdoc] %d %s definition(s) serve every %s grade on the tray')
			:format(count, kind, kind))
	end
	for _, entry in ipairs(M.Ripper.Catalog()) do
		local kind = M.Ripper.GrantKind(entry)
		if kind == 'hacking' and hacking ~= nil and type(hacking.define) == 'function' then
			-- THE HACK IS THE IMPLANT'S TWIN (`wiki/hacking.md`): one
			-- definition, the implant's own id and version, and every grade
			-- the implant has -- the balance living on each grade row with
			-- its `kind`. A per-grade id was a deck the hacking service had
			-- never heard of.
			local grades = {}
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local row = { id = grade.id }
				for field, value in pairs(type(grade.HACK) == 'table' and grade.HACK or {}) do
					row[field] = value
				end
				if row.kind == nil then row.kind = 'short_circuit' end
				-- The fields the service requires and a hand-written config
				-- may not name (bounds per `wiki/hacking.md`).
				if row.staminaCost == nil then row.staminaCost = 15 end
				if row.statusMs == nil then row.statusMs = 750 end
				if row.recoveryMs == nil then row.recoveryMs = math.max(4000, row.statusMs + 500) end
				if row.lockHacking == nil then row.lockHacking = false end
				if row.nonlethal == nil then row.nonlethal = false end
				grades[#grades + 1] = row
			end
			put('hack', hacking.define, { id = M.Ripper.DefinitionFor(entry, nil), version = 1,
				grades = grades })
		elseif M.Ripper.KindOf(entry) == 'ice' and hacking ~= nil
			and type(hacking.defineIce) == 'function' then
			local grades = {}
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local ice = type(grade.ICE) == 'table' and grade.ICE or {}
				grades[#grades + 1] = { id = grade.id,
					charges = tonumber(ice.charges) or 1,
					rechargeMs = tonumber(ice.rechargeMs) or 30000 }
			end
			put('ice', hacking.defineIce, { id = M.Ripper.DefinitionFor(entry, nil), version = 1,
				grades = grades })
		end
	end

	AddEventHandler('onCyberwareMeleeHit', onMeleeHit)
	AddEventHandler('onCyberwareJump', onJump)
	AddEventHandler('onDashChanged', onDash)
	AddEventHandler('onReflexChanged', onReflex)
	AddEventHandler('onAbilityActivation', onAbility)
	AddEventHandler('onHackingTransition', onHacking)

	-- THE BODY'S OWN WEAR. Arguments are scalar strings on this transport
	-- (docs/combat.md), so every id and amount is read through `tonumber`.
	AddEventHandler('open77:playerDamaged', function(victim, _, amount)
		local player = tonumber(victim)
		if player ~= nil then M.Chrome.WearDamage(player, tonumber(amount)) end
	end)
	-- A DEATH, NOT A MOVE: the platform's join spawn, every placement and
	-- every staff move is a scripted kill and a respawn, and none of them is
	-- the body going down (`wiki/server-api.md`, "Deaths that are not deaths").
	AddEventHandler('onPlayerLifeStateChanged', function(playerId, revision, phase)
		if tostring(phase) ~= 'dead' then return end
		local player = tonumber(playerId)
		if player == nil then return end
		local number = tonumber(revision)
		if number ~= nil then
			if deathRevision[player] ~= nil and number <= deathRevision[player] then return end
			deathRevision[player] = number
		end
		local players = Open77.players
		if type(players.getLifeState) == 'function' then
			local read, life = pcall(players.getLifeState, player)
			if read and type(life) == 'table' and life.cause == 'script' then return end
		end
		M.Chrome.WearDeath(player)
	end)

	-- The host drops session grants with the session; only our bookkeeping
	-- needs sweeping after them -- and the rows, written first. The HOST'S
	-- name for a departure is `onPlayerDisconnected` with the id as its
	-- argument (`OPX.Host`); the FiveM `playerDropped` this used to listen to
	-- is raised by nothing here, so a dropped patient's grants stayed "armed"
	-- in this table and the slot's next holder inherited them.
	local function release(player)
		if player == nil then return end
		armed[M.Ripper.KeyOf(player)] = nil
		stale[M.Ripper.KeyOf(player)] = nil
		-- A grant held back goes with the session: the next one starts clean.
		heldBack[M.Ripper.KeyOf(player)] = nil
		ensureWarned[M.Ripper.KeyOf(player)] = nil
		deathRevision[player] = nil
		for citizenId, holder in pairs(holders) do
			if holder == player then
				CreateThread(function() M.Chrome.Forget(citizenId) end)
			end
		end
	end
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		release(tonumber(playerId))
	end)
	-- A character put down on a connection that stays (the relog switch) is a
	-- departure for THAT character's chrome: its grants go and its rows are
	-- written and forgotten, so the next character starts from its own.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(player, data)
		player = tonumber(player)
		if player == nil then return end
		local key = M.Ripper.KeyOf(player)
		for entryId in pairs(armed[key] or {}) do
			local entry = M.Ripper.Entry(entryId)
			if entry ~= nil then disarm(player, entry) end
		end
		armed[key] = nil
		stale[key] = nil
		heldBack[key] = nil
		local citizenId = type(data) == 'table' and data.citizenId or nil
		if type(citizenId) == 'string' then
			CreateThread(function() M.Chrome.Forget(citizenId) end)
		end
	end)

	-- THE KIT COMES BACK WITH THE SESSION. A grant dies with the session and
	-- a patient outlives sessions, so a player who is READY -- every hold
	-- cleared, a body to put their character on -- reads their ledger once
	-- and picks up every fitted, unbroken piece it names.
	AddEventHandler(OPX.Host.PLAYER_READY, function(rawPlayerId)
		local player = tonumber(rawPlayerId)
		if player == nil then return end
		CreateThread(function() M.Chrome.Arrive(player) end)
	end)
	-- AND WITH EVERY CHARACTER. A relog puts a new character on the same
	-- connection without a new ready: its ledger is read and its kit armed
	-- the moment it loads, not the next time it sits in a clinic chair.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(rawPlayerId)
		local player = tonumber(rawPlayerId)
		if player == nil then return end
		CreateThread(function() M.Chrome.Arrive(player) end)
	end)

	-- THE WALL CLOCK a life is stamped with. A host with a clock of its own
	-- needs nothing more; one without has the database's read once, here, and
	-- advanced by the server's timer (`M.Ripper.UnixNow`). Said once either way.
	if M.Ripper.PlatformUnix() ~= nil then
		clockSettled = true
		Open77.log.info('[ripperdoc] chrome ages by the platform\'s wall clock: a life runs online or not')
	else
		clockSettled = false
		CreateThread(function()
			local read = M.Storage.UnixNow()
			local rows = type(read) == 'table' and read.ok == true and type(read.value) == 'table'
				and read.value or {}
			local first = type(rows[1]) == 'table' and rows[1] or {}
			local taken = M.Ripper.AnchorUnix(first.now, OPX.Now())
			clockSettled = true
			if M.Ripper.PlatformUnix() ~= nil then return end
			if taken then
				Open77.log.info('[ripperdoc] chrome ages by the database\'s clock (UNIX_TIMESTAMP at start, ' ..
					'advanced by the server\'s timer): a life runs online or not')
			else
				Open77.log.warn('[ripperdoc] no wall clock on this host and none from the database (' ..
					tostring(type(read) == 'table' and (read.detail or read.error) or 'no answer') ..
					'): chrome ages only while this server runs, and time away is not caught up')
			end
		end)
	end

	-- THE CLOCK. One thread for everybody, at the lifecycle's own tick.
	ticking = true
	CreateThread(function()
		while ticking do
			Wait(math.floor(M.Ripper.Lifecycle().TICK_SECONDS * 1000))
			if not ticking then return end
			local ran, failure = pcall(M.Chrome.Tick)
			if not ran then
				Open77.log.warn('[ripperdoc] the wear tick raised: ' .. tostring(failure))
			end
		end
	end)
end

--- Ends the clock. The rows are written by `Stop` in `server/main.lua`, one
--- thread per row, because a shutdown does not resume a yielded loop.
function M.Chrome.Stop()
	ticking = false
end

--- Every dirty row, for the shutdown write.
-- @return table array of { citizen, entry }
function M.Chrome.Dirty()
	local out = {}
	for citizen, rows in pairs(ledger) do
		for entryId, row in pairs(rows) do
			if row.dirty then out[#out + 1] = { citizen = citizen, entry = entryId } end
		end
	end
	return out
end

--- Writes one row now (the shutdown's per-row thread). Yields.
-- @param citizenId string
-- @param entryId string
function M.Chrome.Save(citizenId, entryId)
	save(citizenId, entryId)
end

--- The citizens the ledger holds rows for right now, with the player last
--- seen wearing them.
-- @return table citizen -> player|nil
function M.Chrome.Holders()
	local out = {}
	for citizen in pairs(ledger) do out[citizen] = holders[citizen] end
	return out
end

--- Records which player a citizen is on (the tray and the composer know it
--- first).
-- @param citizenId string
-- @param player number
function M.Chrome.Hold(citizenId, player)
	if type(citizenId) == 'string' and player ~= nil then holders[citizenId] = player end
end

--- Resets the ledger and the grants (a reload starts clean).
function M.Chrome.Init()
	ledger, asked, armed, shelf, holders = {}, {}, {}, {}, {}
	stale, heldBack, stored, writing, again = {}, {}, {}, {}, {}
	ensureWarned, deathRevision = {}, {}
	warnedRead = false
	ticking = false
	clockSettled = true
end
