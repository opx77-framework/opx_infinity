--- Server half: the boards, the seniority bank, and every decision about a job.
-- @author XEROX710
--
-- EVERY ANSWER A PLAYER READS IS DECIDED HERE. The menu a client draws is a
-- picture of what this half already said: which boards stand in the player's
-- bucket, whether the job is already theirs, which grade they hold, how far the
-- next rank is and what is missing from the terms. Nothing a client sends is
-- trusted -- a join names a BOARD and never a job, a grade or a citizen, and the
-- board's own row decides what joining it means.
--
-- A RANK IS WRITTEN IN ONE PLACE. `applyGrade` is the only function here that
-- moves somebody's grade, and it goes through the `character` contract, so a
-- rank gained at a desk is the same rank `/opx.job` grants: it arrives on the
-- same client event, pays the same, and is read by every gate that already reads
-- a job. The subtle half of that is why the function exists at all -- a
-- character's PRIMARY job carries a COPY of its grade (name, payment, `isBoss`)
-- inside `PlayerData.job`, and changing the membership row alone would leave a
-- promoted captain being paid as a cadet and refused by every gate that reads
-- `job.isBoss`. So the primary job goes through `SetJob`, which rebuilds that
-- copy, and every other membership through `AddPlayerToJob`, which does not
-- touch it.
--
-- THE ROSTER IS NOT STORED HERE EITHER. `GetGroupMembers` answers who holds a
-- job and at which grade, offline members included, and this module's bank is
-- joined onto it. A second members table here would be a second answer to "who
-- works here", and the first one to be wrong would be the one a menu drew.
--
-- THE BANK IS THE ONE THING THIS MODULE OWNS. It starts at nothing when somebody
-- joins, is paid by one tick while they are on duty in the job they are working,
-- buys nobody anything (a rank is held, not bought), is written back on a
-- cadence and after every change of rank, and is deleted when they are fired: a
-- rehire starts at the bottom rather than walking back in at the rank they left.
--
-- TWO KINDS OF READ, AND THE DIFFERENCE MATTERS. The live read (`ResolvePlayer`,
-- memory only) answers for a character who is connected, and is what the sync
-- path uses -- a payload is built on the host's own thread and may not yield.
-- The ROSTER read is a database query and yields, so it is reached only from a
-- thread: the commands, the desk actions and the tick. Every function below says
-- which it is.

local M = OPX.Modules.Get('jobs')

local Access = M.Access
local Seniority = M.Seniority
local Store = M.Storage

local Result = OPX.Result

-- ── state ───────────────────────────────────────────────────────────────────

--- The character contract, resolved at Start. Nil is answered and not raised:
--- nothing here can decide anything without it, and every door says so by name.
local character = nil

--- The config's boards, normalised once, and the captured ones merged over them.
local configBoards, captured = {}, {}

--- Every board by key, and the same set indexed by routing bucket, so a sync
--- walks only what its player could see.
local boards, byBucket = {}, {}

--- Seniority banks: citizenId -> job -> points, and which of them changed since
--- the last write-back.
local banks, dirty = {}, {}

--- The capture round-trip: player -> `{ at = ms }`, and the request windows.
local pending, windows = {}, {}

--- What each connection was last sent, so the sync's own line is said on a
--- change rather than on every ask. `EMPTY` and a count of 0 are different
--- answers and the two read differently in a log: one is "no character yet",
--- the other "nothing where you are standing".
local sent = {}
local EMPTY = 'no-character'

--- What each payload's cost was last said as, so the line is said once per
--- shape rather than on every ask -- and an over-budget shape is an error said
--- once, because the platform drops it in silence and a repeat adds nothing.
local costed = {}
local OVER = 'over'

--- When each character was last promoted, so one tick cannot walk somebody up
--- two ranks because a ladder's levels sit close together.
local promotedAt = {}

--- Phase flag, so the loops stop when the module is asked to.
local running = false

--- Longest wire value a log line carries, in characters. A newline in a key
--- would otherwise forge a whole log line.
local MAX_LOGGED = 64

-- ── small helpers ───────────────────────────────────────────────────────────

--- Cleans and caps a value for a log line.
-- @param value any
-- @return string
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

--- The live Player for a connection, or nil. Memory only; never yields.
-- @param source number
-- @return table|nil
local function playerOf(source)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(character.GetPlayer, source)
	if not read or type(loaded) ~= 'table' then return nil end
	return loaded
end

--- The character fields every decision here reads, or nil before a character is
--- loaded. Never the identity of a client: a connection that has not chosen a
--- character has no job, no grade and nothing to sign.
-- @param source number
-- @return table|nil `{ citizenId, source, player, job, jobName, jobs }`
local function characterOf(source)
	local loaded = playerOf(source)
	if loaded == nil then return nil end
	local data = type(loaded.PlayerData) == 'table' and loaded.PlayerData or nil
	if data == nil or type(data.citizenId) ~= 'string' or data.citizenId == '' then return nil end
	local job = type(data.job) == 'table' and data.job or nil
	return {
		citizenId = data.citizenId,
		source = tonumber(data.source) or source,
		player = loaded,
		job = job,
		jobName = type(job) == 'table' and job.name or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or {},
		name = type(data.name) == 'string' and data.name or nil,
	}
end

--- Walks every connection that has a character loaded, in memory only.
--
-- THE HOST LISTS THE CONNECTIONS AND THE CONTRACT RESOLVES THE CHARACTER, which
-- is the walk `garages`, `dealership`, `clothing`, `downed` and `appearance`
-- all use. It is NOT `character.GetPlayers`: that walk is documented as -- and
-- is -- the one that EVICTS a slot whose account id no longer matches its
-- session, so a periodic pass over it unloads characters as a side effect of
-- reading a list. The character module avoids it in its own 1 Hz pass for that
-- reason, and this module pays the same attention: a tick that reads a roster
-- once a minute may not be a tick that drops players.
-- @param fn function(source, who) called for each loaded character
-- @return integer how many were visited
local function eachPlayer(fn)
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return 0 end
	local seen = 0
	for index = 1, #ids do
		local who = characterOf(tonumber(ids[index]))
		if who ~= nil then
			seen = seen + 1
			fn(who.source, who)
		end
	end
	return seen
end

--- A player's position, or nil. The one host read this module makes, and it is
--- always measured against the DECLARED board position rather than trusted from
--- a client.
-- @param source number
-- @return table|nil `{ x, y, z, bucket }`
local function positionOf(source)
	local read, position = pcall(Open77.players.position, source)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = tonumber(position.bucket) or 0 }
end

--- Whether a player holds a right. An unreadable ACL answers no: a door that
--- cannot be checked is not one to leave open.
-- @param source number
-- @param right string
-- @return boolean
local function allowed(source, right)
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, answer = pcall(acl.isAllowed, source, right)
	return read and answer == true
end

--- The grade a CONNECTED character holds in one job, read from memory. Never
--- yields, which is what makes it usable while a payload is being built.
-- @param citizenId string
-- @param name string
-- @return number|nil
local function liveGrade(citizenId, name)
	if character == nil or type(character.ResolvePlayer) ~= 'function' then return nil end
	local read, live = pcall(character.ResolvePlayer, citizenId)
	if not read or type(live) ~= 'table' then return nil end
	local data = type(live.PlayerData) == 'table' and live.PlayerData or nil
	local jobs = data ~= nil and data.jobs or nil
	if type(jobs) ~= 'table' then return nil end
	return tonumber(jobs[name])
end

--- One job's whole roster as a citizenId -> grade map, or nil when it could not
--- be read. YIELDS: the roster is a database query.
-- @param name string
-- @return table|nil
local function rosterGrades(name)
	if character == nil or type(character.GetGroupMembers) ~= 'function' then return nil end
	local read, listed = pcall(character.GetGroupMembers, 'job', name)
	if not read or type(listed) ~= 'table' or listed.ok ~= true then return nil end
	local members = type(listed.value) == 'table' and listed.value or {}
	local map = {}
	for index = 1, #members do
		local member = members[index]
		if type(member.citizenId) == 'string' then
			map[member.citizenId] = tonumber(member.grade) or 0
		end
	end
	return map
end

--- The grade a character holds, live first and roster second.
-- @param citizenId string
-- @param name string
-- @param map table|nil a roster map already fetched by the caller
-- @return number|nil
local function gradeHeld(citizenId, name, map)
	local held = liveGrade(citizenId, name)
	if held ~= nil then return held end
	return type(map) == 'table' and map[citizenId] or nil
end

--- The grade a job marks as its boss grade, or nil when it has none.
--
-- Read from the character catalogue's own `isBoss` flag rather than from a
-- second list here: a rank that is a boss rank is a boss rank everywhere, and a
-- job with no such grade can never be managed by anybody. `Access.Problems` says
-- so at boot when a desk stands for one.
-- @param name string
-- @return integer|nil
local function bossGradeOf(name)
	if character == nil or type(character.GetJob) ~= 'function' then return nil end
	local read, definition = pcall(character.GetJob, name)
	if not read or type(definition) ~= 'table' or type(definition.grades) ~= 'table' then
		return nil
	end
	local boss = nil
	for level, grade in pairs(definition.grades) do
		local index = tonumber(level)
		if index ~= nil and type(grade) == 'table' and grade.isBoss == true then
			if boss == nil or index > boss then boss = index end
		end
	end
	return boss
end

--- Whether a character holds a job at its boss grade. Memory first, so a boss
--- standing at their own desk is answered without a query.
-- @param citizenId string
-- @param name string
-- @param map table|nil a roster map already fetched by the caller
-- @return boolean
local function isBossOf(citizenId, name, map)
	local boss = bossGradeOf(name)
	if boss == nil then return false end
	local held = gradeHeld(citizenId, name, map)
	return held ~= nil and held >= boss
end

--- The grades a job actually has, ascending.
--
-- A promotion is clamped to this and never to what a ladder names: a ladder that
-- mentions a level the catalogue has no grade for is refused at boot, and a
-- build that somehow still holds one must not promote anybody into it --
-- `AddPlayerToJob` would answer `job.gradeNotFound` and the rank would be lost
-- inside a refusal the player never saw.
-- @param name string
-- @return table sorted array
local function gradesOf(name)
	local out = {}
	if character == nil or type(character.GetJob) ~= 'function' then return out end
	local read, definition = pcall(character.GetJob, name)
	if not read or type(definition) ~= 'table' or type(definition.grades) ~= 'table' then return out end
	for level in pairs(definition.grades) do
		local index = tonumber(level)
		if index ~= nil then out[#out + 1] = index end
	end
	table.sort(out)
	return out
end

--- One job's grade definition, or nil.
-- @param name string
-- @param grade number
-- @return table|nil
local function rankOf(name, grade)
	if character == nil or type(character.GetJob) ~= 'function' then return nil end
	local read, definition = pcall(character.GetJob, name)
	if not read or type(definition) ~= 'table' or type(definition.grades) ~= 'table' then return nil end
	local rank = definition.grades[grade]
	return type(rank) == 'table' and rank or nil
end

--- A character's default job, read from the character module's own config.
--
-- This is the one value this module needs and does not own, and it is read
-- rather than copied: joining the default job as the primary one is what makes a
-- job a job, and a second spelling of 'unemployed' here would be a copy to keep
-- in step.
-- @return string|nil
local function defaultJob()
	local config = OPX.Config.MODULES['character']
	local player = type(config) == 'table' and config.PLAYER or nil
	local name = type(player) == 'table' and player.DEFAULT_JOB or nil
	return type(name) == 'string' and name ~= '' and name or nil
end

--- One job's seniority bank, or zero.
-- @param citizenId string
-- @param name string
-- @return number
local function bankOf(citizenId, name)
	local held = banks[citizenId]
	local points = type(held) == 'table' and held[name] or nil
	return Seniority.Finite(points) or 0.0
end

--- Writes one bank and remembers that it has to be saved.
-- @param citizenId string
-- @param name string
-- @param points number
local function setBank(citizenId, name, points)
	local held = banks[citizenId]
	if held == nil then
		held = {}
		banks[citizenId] = held
	end
	held[name] = points
	local marked = dirty[citizenId]
	if marked == nil then
		marked = {}
		dirty[citizenId] = marked
	end
	marked[name] = true
end

--- Drops one bank, in memory and in the database. Yields: the delete is a query.
-- @param citizenId string
-- @param name string
-- @return boolean whether it is gone
local function dropBank(citizenId, name)
	local removed = Store.Delete(citizenId, name)
	if not removed.ok then
		Open77.log.warn(('[jobs] %s: the bank of %s was not deleted: %s')
			:format(safe(citizenId), safe(name), safe(removed.detail)))
		return false
	end
	local held = banks[citizenId]
	if held ~= nil then held[name] = nil end
	if dirty[citizenId] ~= nil then dirty[citizenId][name] = nil end
	return true
end

--- Adds to a bank, under the configured ceiling.
-- @param citizenId string
-- @param name string
-- @param points number
-- @return number the new value
local function pay(citizenId, name, points)
	local settings = type(M.Settings.SENIORITY) == 'table' and M.Settings.SENIORITY or {}
	local before = bankOf(citizenId, name)
	local next_ = Seniority.Clamp(before + (Seniority.Finite(points) or 0.0),
		settings.MAX_POINTS)
	setBank(citizenId, name, next_)
	-- What this credit ACTUALLY moved leaves the funnel on one local event:
	-- the clamp's truth, not the caller's ask. This is the whole of the
	-- `modules/skills` integration -- one line at the single place every job's
	-- work is ever credited.
	TriggerEvent(M.Event.PAID, citizenId, name, next_ - before)
	return next_
end

--- Writes one character's dirty banks out. Yields.
-- @param citizenId string
-- @return integer how many rows were written
local function flush(citizenId)
	local marked = dirty[citizenId]
	if marked == nil then return 0 end
	local written = 0
	for name in pairs(marked) do
		local saved = Store.Upsert(citizenId, name, bankOf(citizenId, name))
		if saved.ok then
			written = written + 1
		else
			Open77.log.warn(('[jobs] %s: the seniority of %s could not be written: %s')
				:format(safe(citizenId), safe(name), safe(saved.detail)))
		end
	end
	dirty[citizenId] = nil
	return written
end

--- Fires a write-back for one character on a thread of its own, so a change of
--- rank survives a restart without the caller waiting on the disk.
-- @param citizenId string
local function flushSoon(citizenId)
	if dirty[citizenId] == nil then return end
	CreateThread(function() flush(citizenId) end)
end

-- ── the boards ──────────────────────────────────────────────────────────────

--- Merges the config's boards with the captured ones, newest key winning, and
--- re-indexes them by routing bucket.
local function rebuild()
	boards, byBucket = {}, {}
	for key, board in pairs(configBoards) do boards[key] = board end
	for key, board in pairs(captured) do boards[key] = board end
	for _, board in pairs(boards) do
		local bucket = byBucket[board.bucket]
		if bucket == nil then
			bucket = {}
			byBucket[board.bucket] = bucket
		end
		bucket[#bucket + 1] = board
	end
end

--- The boards a player in this bucket may be shown at all.
--
-- A sign-up board is everybody's. A DESK IS ONLY ITS BOSS'S: showing one to a
-- player who cannot use it would draw a marker that refuses every press, and the
-- roster behind it is not theirs to read.
--
-- AND A BOARD IS ITS CAPTURER'S, which is the third rule and the one a live
-- server needed: an operator placed two desks, read `saved`, and saw nothing at
-- all, because a desk whose division has no boss yet is a marker drawn for
-- nobody -- and there was no way to tell that from a capture that had failed.
-- The capturer sees where they put it. That is a placement aid and NOT a
-- promotion: every desk action still re-derives `isBossOf` on the server
-- (`M.Boss`), and the roster is attached only when `state.isBoss`, so a capturer
-- who is not the boss gets a marker that refuses the roster -- which is what
-- the capture answer now says out loud.
-- @param bucket number
-- @param citizenId string|nil
-- @return table[] sorted by key, so a payload is stable between asks
local function boardsFor(bucket, citizenId)
	local listed = byBucket[bucket] or {}
	local out = {}
	for index = 1, #listed do
		local board = listed[index]
		if board.kind == M.KIND.SIGNUP then
			out[#out + 1] = board
		elseif citizenId ~= nil
			and (isBossOf(citizenId, board.job) or board.by == citizenId) then
			out[#out + 1] = board
		end
	end
	table.sort(out, function(left, right) return left.key < right.key end)
	return out
end

--- What the server says about one JOB FOR ONE PLAYER: the terms, the grade they
--- hold, the next rank and how far off it is.
--
-- Decided here and carried on the payload rather than derived on the client, so
-- the menu a player reads and the answer the server would give are one
-- implementation. A client re-deriving it from its replicated job would be a
-- second copy of the rules, minutes stale. Memory only: this runs while a
-- payload is being built.
-- @param name string the job
-- @param who table from `characterOf`
-- @return table
local function jobState(name, who)
	local terms = Access.Terms(name)
	local held = tonumber(who.jobs[name])
	local ladder = terms ~= nil and terms.ladder or {}

	local state = {
		job = name,
		open = terms ~= nil and terms.open == true,
		approval = terms ~= nil and terms.approval == true,
		held = held,
		isBoss = isBossOf(who.citizenId, name),
		top = terms ~= nil and terms.top or 0,
	}

	-- The job's own name, so a row reads as what the catalogue calls the work
	-- rather than as its config key.
	local read, definition = nil, nil
	if character ~= nil and type(character.GetJob) == 'function' then
		read, definition = pcall(character.GetJob, name)
	end
	if read and type(definition) == 'table' then
		state.label = type(definition.label) == 'string' and definition.label or name
	end

	-- The ladder AS THE CATALOGUE DEFINES IT, so a job's own screen can draw its
	-- ranks without a request per row. Read from the catalogue and not from the
	-- seniority config: a grade exists because the job has it, and a level the
	-- ladder prices that the job has no grade for is refused at boot.
	local defined = gradesOf(name)
	local listed = {}
	for index = 1, #defined do
		local level = defined[index]
		local rank = rankOf(name, level)
		listed[index] = {
			level = level,
			name = rank ~= nil and rank.name or nil,
			payment = rank ~= nil and tonumber(rank.payment) or nil,
			isBoss = rank ~= nil and rank.isBoss == true,
			required = Seniority.Required(terms ~= nil and terms.ladder or nil, level),
		}
	end
	state.grades = listed

	if held ~= nil then
		local rank = rankOf(name, held)
		state.grade = rank ~= nil and rank.name or nil
		state.payment = rank ~= nil and tonumber(rank.payment) or nil
		local progress = Seniority.Progress(ladder, held, bankOf(who.citizenId, name))
		if progress ~= nil then
			local nextRank = rankOf(name, progress.level)
			state.next = progress.level
			state.nextGrade = nextRank ~= nil and nextRank.name or nil
			state.progress = progress.fraction
			state.points = progress.points
			state.required = progress.to
			state.shortfall = progress.to - progress.points
		end
	elseif terms ~= nil then
		-- Not a member: whether they could become one, and what is missing. The
		-- same predicate the server applies to the join itself, so the row the
		-- menu draws and the refusal a press would get cannot disagree.
		local met, missing = Access.MeetsTerms(terms, {
			grade = function(other) return who.jobs[other] end,
			allowed = function(right) return allowed(who.source, right) end,
		})
		state.canJoin = met
		state.missing = missing
	end

	return state
end

--- What the server says about one board FOR ONE PLAYER.
--
-- A SIGN-UP BOARD SPEAKS FOR THE WHOLE CATALOGUE and a desk speaks for its own
-- job. That asymmetry is the point of the two kinds: an employment office is one
-- place a player walks up to and reads every job on offer, while a roster belongs
-- to the division it is drawn for. So the sign-up payload carries one state per
-- offered job, in the config's own order, and the desk carries the one it is the
-- desk of.
-- @param board table
-- @param who table from `characterOf`
-- @return table
local function stateOf(board, who, source)
	local state = jobState(board.job, who)
	state.kind = board.kind

	if board.kind == M.KIND.BOSS and state.isBoss then
		-- WHO IS STANDING CLOSE ENOUGH TO HIRE. A position read per player, so it
		-- is asked for only where a hire can be pressed, and re-measured on the
		-- other side when it is: this list is what the menu OFFERS.
		state.candidates = M.Candidates(board, source)
	end

	if board.kind == M.KIND.SIGNUP then
		local offers = {}
		for name in pairs(Access.TermsAll()) do offers[#offers + 1] = name end
		table.sort(offers)
		local rows = {}
		for index = 1, #offers do rows[index] = jobState(offers[index], who) end
		state.offers = rows
	end

	return state
end

--- Says what one payload costs the client, once per shape, and SHOUTS when it
--- would be refused.
--
-- The client's decoder refuses the whole payload past `Access.CEILING` (1024
-- values, 8 levels) and drops it with a line on the host's `network` category --
-- the server's own encoder is wider (4096, 16) and throws rather than trimming,
-- so a payload in between is sent happily and read by nobody. The job markers
-- went missing in game exactly that way, so every event this module raises now
-- names its own cost against the window it has to fit, and a shape that no
-- longer fits is an error rather than a silence.
-- @param label string what is being sent, for the line
-- @param ... any the arguments the event is raised with
local function noteCost(label, ...)
	local fits, values, depth = Access.Fits(...)
	if fits then
		if costed[label] == nil then
			costed[label] = true
			Open77.log.info(('[jobs] %s costs %d of the platform\'s %d value(s) and depth %d of %d')
				:format(label, values, Access.CEILING.VALUES, depth, Access.CEILING.DEPTH))
		end
		return
	end
	if costed[label] == OVER then return end
	costed[label] = OVER
	Open77.log.error(('[jobs] %s is over the platform\'s window: %d of %d value(s), depth %d of %d. ' ..
		'The client will drop it whole and in silence.')
		:format(label, values, Access.CEILING.VALUES, depth, Access.CEILING.DEPTH))
end

--- Sends one player the boards they may see, and the verdict for the one they
--- are standing on.
--
-- AND SAYS WHAT IT SENT, once per change. This is the server half of the line
-- the client draws its side with, and it exists for the same reason: a marker
-- that is not there is decided by two halves that were both silent, so `0
-- board(s) held` on the client was indistinguishable from a payload that was
-- never sent, and from one that was sent empty because the player's routing
-- bucket holds no boards at all. One line on each side names which half decided.
-- @param source number
local function sync(source)
	local who = characterOf(source)
	if who == nil then
		-- A client that asked before its character loaded is told an empty world
		-- rather than nothing at all: the two read differently in a log, and the
		-- client asks again on its own cadence.
		if sent[source] ~= EMPTY then
			sent[source] = EMPTY
			Open77.log.info(('[jobs] no character for %d yet; an empty board list was sent')
				:format(source))
		end
		TriggerClientEvent(M.Event.SYNC, source, { boards = {} })
		return
	end

	local at = positionOf(source)
	local bucket = at ~= nil and at.bucket or 0
	local listed = boardsFor(bucket, who.citizenId)
	local payload, count = {}, 0
	local standing, desks = {}, {}
	for index = 1, #listed do
		local board = listed[index]
		count = count + 1
		payload[count] = Access.WireRow(board)
		-- WHAT THE PLAYER IS STANDING ON, and only that, gets a verdict. The
		-- radius is the same one the client uses to pick the board its key opens
		-- (Access.UseRadius), so a board the client can act at always has its
		-- state, and a board across the district, which the client can only
		-- draw, costs nine values instead of a tree of them.
		if at ~= nil and Access.Within(board, at.x, at.y) then
			standing[#standing + 1] = board
		end
	end

	local budget = { boards = payload, bucket = bucket }
	TriggerClientEvent(M.Event.SYNC, source, budget)
	noteCost('the board list', budget)

	for index = 1, #standing do
		local board = standing[index]
		local state = stateOf(board, who, source)
		-- The verdict is its own event: one board, and the client keeps it under
		-- the key it names rather than inside the board.
		TriggerClientEvent(M.Event.STATE, source, board.key, state)
		noteCost('a board verdict (' .. tostring(board.key) .. ')', board.key, state)
		-- A DESK THE PLAYER IS STANDING ON and may manage gets its roster, but
		-- not on this call: a roster is a database query, and the sync itself is
		-- reached from a net handler that may not yield. The jobs are noted here
		-- and the rows are sent on a thread of their own, as their own event.
		if board.kind == M.KIND.BOSS and state.isBoss then
			desks[#desks + 1] = board.job
		end
	end

	if sent[source] ~= count then
		sent[source] = count
		Open77.log.info(('[jobs] %d of the %d board(s) in bucket %d sent to %d')
			:format(count, OPX.Table.Count(byBucket[bucket] or {}), bucket, source))
	end

	if #desks > 0 then
		CreateThread(function()
			for index = 1, #desks do
				local roster = M.Roster(desks[index])
				if roster.ok then
					TriggerClientEvent(M.Event.ROSTER, source, desks[index], roster.value.members,
						roster.value.top)
					noteCost(('the roster of %s'):format(tostring(desks[index])), desks[index],
						roster.value.members, roster.value.top)
				end
			end
		end)
	end
end

--- Sends every connected player their own list. Guarded: one connection that
--- cannot be read must not stop a capture from being saved.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local source = tonumber(ids[index])
		if source ~= nil then
			local sent, failure = pcall(sync, source)
			if not sent then
				Open77.log.warn('[jobs] sync failed: ' .. tostring(failure))
			end
		end
	end
end

-- ── the one place a rank moves ──────────────────────────────────────────────

--- Writes a grade onto a character, through the character contract.
--
-- A PRIMARY JOB CARRIES A COPY OF ITS GRADE inside `PlayerData.job`, and only
-- `SetJob` rebuilds it. So when the job being changed is the one they are
-- actually working, the rank goes through `SetJob`; every other membership goes
-- through `AddPlayerToJob`, which leaves the primary job alone. Neither call is
-- this module's to spell out: both are `character`'s, and both re-derive the
-- grade from the catalogue before writing it.
-- @param citizenId string
-- @param name string
-- @param grade integer
-- @param primaryName string|nil the character's current primary job
-- @return Result
local function applyGrade(citizenId, name, grade, primaryName)
	if character == nil then return Result.Err('jobs.noCharacter') end
	if primaryName == name then return character.SetJob(citizenId, name, grade) end
	return character.AddPlayerToJob(citizenId, name, grade)
end

-- ── the roster ──────────────────────────────────────────────────────────────

--- One job's members, with their grades and their seniority.
--
-- The members come from the character module and the bank from this one, joined
-- here rather than stored together: the roster is that module's answer, and a
-- copy would be stale the moment an operator granted a rank with `/opx.job`.
-- YIELDS: the member list is a query.
-- @author XEROX710
-- @param name string
-- @param listed table|nil members already fetched by the caller, to avoid a
--   second query in the same operation
-- @return Result carrying `{ job, members, count, top }`
function M.Roster(name, listed)
	if character == nil or type(character.GetGroupMembers) ~= 'function' then
		return Result.Err('jobs.noCharacter')
	end
	local terms = Access.Terms(name)
	if terms == nil then return Result.Err('jobs.noSuchJob', tostring(name)) end

	if type(listed) ~= 'table' then
		local read, answer = pcall(character.GetGroupMembers, 'job', name)
		if not read or type(answer) ~= 'table' or answer.ok ~= true then
			return Result.Err('jobs.rosterFailed', tostring(name))
		end
		listed = type(answer.value) == 'table' and answer.value or {}
	end

	local boss = bossGradeOf(name)
	local rows, limit = {}, Access.RosterLimit()
	for index = 1, #listed do
		if #rows >= limit then break end
		local member = listed[index]
		local grade = tonumber(member.grade) or 0
		local bank = bankOf(member.citizenId, name)
		local progress = Seniority.Progress(terms.ladder, grade, bank)
		local rank = rankOf(name, grade)
		rows[#rows + 1] = {
			citizenId = tostring(member.citizenId),
			name = tostring(member.name or member.citizenId),
			grade = grade,
			gradeName = rank ~= nil and tostring(rank.name) or ('grade ' .. tostring(grade)),
			payment = rank ~= nil and tonumber(rank.payment) or nil,
			isBoss = boss ~= nil and grade >= boss,
			points = bank,
			next = progress ~= nil and progress.level or nil,
			progress = progress ~= nil and progress.fraction or nil,
			shortfall = progress ~= nil and (progress.to - progress.points) or nil,
		}
		-- ROWS ARE ADDED WHILE THE PAYLOAD STILL FITS THE CLIENT'S WINDOW, and
		-- the first one that would not ends the list. A configured limit is a
		-- wish, not a measurement: ROSTER_LIMIT says 200 members and 200 members
		-- cost about 2 200 values against a window of 1 024, so a division that
		-- grew to its configured size had its whole roster dropped on arrival --
		-- in silence, the same way the markers were. Measured here instead, and
		-- said out loud below.
		if not Access.Fits(name, rows, terms.top) then
			rows[#rows] = nil
			break
		end
	end
	if #rows < #listed then
		Open77.log.warn(('[jobs] the roster of %s carries %d of its %d member(s): more would not ' ..
			'fit the platform\'s %d-value window, and a payload over it is dropped whole')
			:format(tostring(name), #rows, #listed, Access.CEILING.VALUES))
	end
	return Result.Ok({ job = name, members = rows, count = #rows, top = terms.top, total = #listed })
end

--- Everybody standing near a desk, for a boss to hire from.
--
-- Hiring somebody across the map is not a scene anybody can see, so a candidate
-- has to be within HIRE_RADIUS of the desk -- re-derived here from the host's
-- own positions and never sent by the boss's client. Yields (positions are host
-- reads).
-- @param board table a boss board
-- @param source number the boss, excluded from their own candidate list
-- @return table[] `{ source, citizenId, name, distance }` nearest first
function M.Candidates(board, source)
	local out = {}
	local radius = Access.HireRadius()
	eachPlayer(function(id, who)
		if id == source then return end
		local at = positionOf(id)
		if at == nil or at.bucket ~= board.bucket then return end
		local flat = Access.FlatDistanceSquared(board, at.x, at.y)
		if flat == nil or flat > radius * radius then return end
		out[#out + 1] = {
			source = id,
			citizenId = who.citizenId,
			name = who.name or who.citizenId,
			distance = math.sqrt(flat),
		}
	end)
	table.sort(out, function(left, right) return left.distance < right.distance end)
	return out
end

-- ── joining and leaving ─────────────────────────────────────────────────────

--- The board a player is standing on, or why they are not.
-- @param source number
-- @param key string
-- @param kind string expected board kind
-- @return table|nil board
-- @return string|nil refusal
-- @return table|nil who
local function boardAt(source, key, kind)
	local who = characterOf(source)
	if who == nil then return nil, 'jobs.noCharacter', nil end
	local board = boards[key]
	if type(board) ~= 'table' or board.kind ~= kind then return nil, 'jobs.noSuchBoard', who end
	local at = positionOf(source)
	if at == nil then return nil, 'jobs.noPosition', who end
	if at.bucket ~= board.bucket then return nil, 'jobs.wrongBucket', who end
	if not Access.Within(board, at.x, at.y) then return nil, 'jobs.tooFar', who end
	return board, nil, who
end

--- The whole of a join, once, for a board and a command alike.
--
-- The grade is the bottom of the ladder by definition, and the terms are
-- re-derived from the live roster rather than read off the menu the player
-- pressed. A command that could put somebody in a job a board would refuse is a
-- second rule wearing one name, so there is one of these and not two. Yields.
-- @param source number
-- @param who table from `characterOf`
-- @param name string the job
-- @return Result carrying `{ job, grade }`
local function joinCore(source, who, name)
	local terms = Access.Terms(name)
	if terms == nil then return Result.Err('jobs.noSuchJob', tostring(name)) end
	if who.jobs[name] ~= nil then return Result.Err('jobs.alreadyMember', name) end

	local met, missing = Access.MeetsTerms(terms, {
		grade = function(held) return who.jobs[held] end,
		allowed = function(right) return allowed(source, right) end,
	})
	if not met then return Result.Err(missing or 'jobs.notOpen', name) end

	-- A BRAND NEW CHARACTER IS UNEMPLOYED, and a job nobody is actually working
	-- pays nothing and gates nothing. Only the default job is taken over this
	-- way; a character with a career keeps it and holds this one alongside.
	local unemployed = who.jobName == nil or who.jobName == defaultJob()
	local joined = unemployed and character.SetJob(who.citizenId, name, 0)
		or character.AddPlayerToJob(who.citizenId, name, 0)
	if not joined.ok then return joined end

	setBank(who.citizenId, name, 0)
	flushSoon(who.citizenId)
	OPX.Audit.Player(who.player, 'jobs.join', name)
	Open77.log.info(('[jobs] %s joined %s'):format(safe(who.citizenId), safe(name)))
	return Result.Ok({ job = name, grade = 0 })
end

--- Joins the player at a sign-up board.
--
-- The board is the place and the job is the work: every job the config offers
-- may be taken at any sign-up board, which is what makes the board one office
-- instead of one queue per job. Naming a job is not a privilege -- the terms are
-- re-derived here either way -- and naming one the config does not offer is
-- refused by name. Yields.
-- @author XEROX710
-- @param source number
-- @param key string the board's own key
-- @param name string|nil the job; the board's own job when omitted
-- @return Result carrying `{ job, grade }`
function M.Join(source, key, name)
	local board, refusal, who = boardAt(source, key, M.KIND.SIGNUP)
	if board == nil then return Result.Err(refusal) end

	local wanted = board.job
	if type(name) == 'string' and name ~= '' then wanted = name:lower() end
	return joinCore(source, who, wanted)
end

--- Joins a player to a job by name, for an operator command. Yields.
-- @param source number
-- @param name string
-- @return Result
function M.JoinJob(source, name)
	local who = characterOf(source)
	if who == nil then return Result.Err('jobs.noCharacter') end
	return joinCore(source, who, tostring(name):lower())
end

--- Whether this character is the only boss their job has.
--
-- Answered from the roster and not from a count kept anywhere: the last boss is
-- a fact about the roster at this moment, and a counter would be a second answer
-- that drifts the first time an operator grants or revokes a rank with
-- `/opx.job`. Yields.
-- @author XEROX710
-- @param citizenId string
-- @param name string
-- @param map table|nil a roster map already fetched by the caller
-- @return boolean
function M.LastBoss(citizenId, name, map)
	local boss = bossGradeOf(name)
	if boss == nil then return false end

	local mine = gradeHeld(citizenId, name, map)
	if mine == nil or mine < boss then return false end

	if map == nil then
		map = rosterGrades(name)
		if map == nil then
			-- The roster could not be read. Said as "not the last boss" and not
			-- the other way round: refusing a resignation because a query failed
			-- is a player locked out of their own career by the database, which
			-- is worse than one desk being emptied and refilled by an operator.
			Open77.log.warn(('[jobs] the roster of %s could not be read while counting its bosses')
				:format(safe(name)))
			return false
		end
	end

	local bosses = 0
	for _, grade in pairs(map) do
		if type(grade) == 'number' and grade >= boss then bosses = bosses + 1 end
	end
	return bosses <= 1
end

--- Takes the player out of the job a board stands for.
--
-- THE LAST BOSS MAY NOT WALK OUT, and neither may they be fired or demoted: a
-- desk with nobody able to sit behind it is a roster nobody can ever change
-- again, which is a worse outcome than refusing one resignation. Yields.
-- @author XEROX710
-- @param source number
-- @param key string
-- @return Result
function M.Leave(source, key)
	local board, refusal, who = boardAt(source, key, M.KIND.SIGNUP)
	if board == nil then return Result.Err(refusal) end
	if Access.Terms(board.job) == nil then return Result.Err('jobs.noSuchJob', board.job) end
	if who.jobs[board.job] == nil then return Result.Err('jobs.notMember', board.job) end
	if M.LastBoss(who.citizenId, board.job) then return Result.Err('jobs.lastBoss', board.job) end

	local left = character.RemovePlayerFromJob(who.citizenId, board.job)
	if not left.ok then return left end
	dropBank(who.citizenId, board.job)

	OPX.Audit.Player(who.player, 'jobs.leave', board.job)
	Open77.log.info(('[jobs] %s left %s'):format(safe(who.citizenId), safe(board.job)))
	return Result.Ok({ job = board.job })
end

-- ── the desk ────────────────────────────────────────────────────────────────

--- One action a boss takes at their desk, on a board already resolved.
--
-- Every action is re-derived on this side: the caller's own boss grade, whether
-- the target is really a member (or, for a hire, really standing here), and what
-- the job's own grades allow. A payload from a client is a REQUEST, and the four
-- actions below are the only four outcomes there are. Yields.
-- @param source number
-- @param board table a boss board
-- @param action string from `M.ACTION`
-- @param target any a citizen id, or a connection for a hire
-- @param who table from `characterOf`
-- @param requireDesk boolean whether a HIRE must name somebody standing at the
--   board. True for the marker, false for the command: a command is already a
--   deliberate act by somebody the host has identified, and a desk with nobody
--   standing at it is the case a command exists for.
-- @return Result carrying what changed
local function bossAct(source, board, action, target, who, requireDesk)
	local name = board.job
	if not isBossOf(who.citizenId, name) then return Result.Err('jobs.notBoss', name) end

	local terms = Access.Terms(name)
	if terms == nil then return Result.Err('jobs.noSuchJob', name) end
	local grades = gradesOf(name)
	if #grades == 0 then return Result.Err('jobs.noSuchJob', name) end
	local bottom, top = grades[1], grades[#grades]

	if action == M.ACTION.HIRE then
		local candidate = tonumber(target)
		if candidate == nil then return Result.Err('error.badRequest') end
		local their = characterOf(candidate)
		if their == nil then return Result.Err('jobs.noCharacter') end
		if their.jobs[name] ~= nil then return Result.Err('jobs.alreadyMember', name) end

		-- Standing at the desk, re-derived here rather than trusted from the
		-- boss's client: hiring somebody across the map is not a scene.
		if requireDesk == true then
			local at = positionOf(candidate)
			local radius = Access.HireRadius()
			local flat = at ~= nil and at.bucket == board.bucket
				and Access.FlatDistanceSquared(board, at.x, at.y) or nil
			if flat == nil or flat > radius * radius then
				return Result.Err('jobs.candidateAway', name)
			end
		end

		local met, missing = Access.MeetsRequirements(terms, {
			grade = function(held) return their.jobs[held] end,
			allowed = function(right) return allowed(candidate, right) end,
		})
		if not met then return Result.Err(missing or 'jobs.notOpen', name) end

		local joined = their.jobName == nil or their.jobName == defaultJob()
		local written = joined and character.SetJob(their.citizenId, name, bottom)
			or character.AddPlayerToJob(their.citizenId, name, bottom)
		if not written.ok then return written end

		setBank(their.citizenId, name, 0)
		flushSoon(their.citizenId)
		OPX.NotifyLocale(candidate, 'jobs.hired', { job = name })
		OPX.Audit.Player(who.player, 'jobs.hire',
			('%s as %s grade %d'):format(safe(their.citizenId), safe(name), bottom))
		Open77.log.info(('[jobs] %s hired %s into %s at grade %d')
			:format(safe(who.citizenId), safe(their.citizenId), safe(name), bottom))
		return Result.Ok({ job = name, citizenId = their.citizenId, grade = bottom })
	end

	-- The other three act on somebody who already holds the job, and the roster
	-- is read once and used for both the target's grade and the last-boss count.
	local citizenId = type(target) == 'string' and target or nil
	if citizenId == nil or citizenId == '' then return Result.Err('error.badRequest') end
	local map = rosterGrades(name)
	if map == nil then return Result.Err('jobs.rosterFailed', name) end

	local held = gradeHeld(citizenId, name, map)
	if held == nil then return Result.Err('jobs.notMember', name) end

	if action == M.ACTION.FIRE then
		if M.LastBoss(citizenId, name, map) then return Result.Err('jobs.lastBoss', name) end
		local left = character.RemovePlayerFromJob(citizenId, name)
		if not left.ok then return left end

		dropBank(citizenId, name)
		local live = character.ResolvePlayer ~= nil and character.ResolvePlayer(citizenId) or nil
		local targetSource = type(live) == 'table' and tonumber(live.PlayerData.source) or nil
		if targetSource ~= nil then OPX.NotifyLocale(targetSource, 'jobs.fired', { job = name }) end

		OPX.Audit.Player(who.player, 'jobs.fire',
			('%s from %s'):format(safe(citizenId), safe(name)))
		Open77.log.info(('[jobs] %s fired %s from %s')
			:format(safe(who.citizenId), safe(citizenId), safe(name)))
		return Result.Ok({ job = name, citizenId = citizenId, fired = true })
	end

	-- Promote and demote are one move on the ladder with two directions, and
	-- both are clamped to the grades the catalogue really defines: a ladder that
	-- names a grade nobody wrote must not promote anybody into it.
	local step = action == M.ACTION.PROMOTE and 1 or (action == M.ACTION.DEMOTE and -1 or 0)
	if step == 0 then return Result.Err('error.badRequest') end

	local wanted = nil
	for index = 1, #grades do
		local grade = grades[index]
		if step > 0 and grade > held and (wanted == nil or grade < wanted) then wanted = grade end
		if step < 0 and grade < held and (wanted == nil or grade > wanted) then wanted = grade end
	end
	if wanted == nil then return Result.Err(step > 0 and 'jobs.topRank' or 'jobs.bottomRank', name) end

	-- A demotion out of the boss grade is a firing's problem and obeys a
	-- firing's rule: the last boss stays a boss wherever they are on the ladder.
	local boss = bossGradeOf(name)
	if step < 0 and boss ~= nil and wanted < boss and held >= boss
		and M.LastBoss(citizenId, name, map) then
		return Result.Err('jobs.lastBoss', name)
	end

	local live = type(character.ResolvePlayer) == 'function'
		and character.ResolvePlayer(citizenId) or nil
	local primaryName = type(live) == 'table' and type(live.PlayerData) == 'table'
		and type(live.PlayerData.job) == 'table' and live.PlayerData.job.name or nil

	local moved = applyGrade(citizenId, name, wanted, primaryName)
	if not moved.ok then return moved end

	local targetSource = type(live) == 'table' and tonumber(live.PlayerData.source) or nil
	if targetSource ~= nil then
		OPX.NotifyLocale(targetSource, step > 0 and 'jobs.promoted' or 'jobs.demoted',
			{ job = name, grade = tostring(wanted) })
	end
	OPX.Audit.Player(who.player, step > 0 and 'jobs.promote' or 'jobs.demote',
		('%s in %s to grade %d'):format(safe(citizenId), safe(name), wanted))
	Open77.log.info(('[jobs] %s %s %s in %s to grade %d'):format(safe(who.citizenId),
		step > 0 and 'promoted' or 'demoted', safe(citizenId), safe(name), wanted))
	return Result.Ok({ job = name, citizenId = citizenId, grade = wanted })
end

--- One action a boss takes at the desk they are standing on. Yields.
-- @author XEROX710
-- @param source number
-- @param key string the desk's own key
-- @param action string from `M.ACTION`
-- @param target any a citizen id, or a connection for a hire
-- @return Result
function M.Boss(source, key, action, target)
	local board, refusal, who = boardAt(source, key, M.KIND.BOSS)
	if board == nil then return Result.Err(refusal) end
	return bossAct(source, board, action, target, who, true)
end

--- The same action, reached by job name instead of by standing at the desk.
--
-- What an operator command needs: the rule is the desk's rule -- the caller has
-- to hold the job's boss grade and every action is re-derived -- but the caller
-- is not required to be standing at a marker, because a command is already a
-- deliberate act by somebody the host has identified. Yields.
-- @author XEROX710
-- @param source number
-- @param name string
-- @param action string from `M.ACTION`
-- @param target any
-- @return Result
function M.BossByJob(source, name, action, target)
	local who = characterOf(source)
	if who == nil then return Result.Err('jobs.noCharacter') end
	if Access.Terms(name) == nil then return Result.Err('jobs.noSuchJob', tostring(name)) end

	local board = nil
	for _, candidate in pairs(boards) do
		if board == nil and candidate.kind == M.KIND.BOSS and candidate.job == name then
			board = candidate
		end
	end
	if board == nil then
		-- NO DESK STANDS FOR THIS JOB, and the command still works: a command is
		-- the door for a job whose desk an operator has not placed yet, and the
		-- only thing the desk's position is used for is measuring a HIRE. The
		-- caller's own bucket stands in for the missing desk's, which is the
		-- bucket any candidate of theirs is in by construction.
		board = { key = name, job = name, kind = M.KIND.BOSS, label = name,
			x = 0, y = 0, z = 0, heading = 0, bucket = 0 }
	end
	return bossAct(source, board, action, target, who, false)
end

-- ── the seniority tick ──────────────────────────────────────────────────────

--- Pays every on-duty holder of a job that has a ladder, and moves the rank of
--- anybody whose bank has reached the next one.
--
-- WHO TICKS: a character whose PRIMARY job is this one and who is on duty. Duty
-- is the character module's own field and not a second one -- a job with
-- `defaultDuty = true` is always on duty, so a freelancer banks while they play
-- and a police officer banks while they are clocked in. A membership that is not
-- the job they are working banks nothing, because there is no shift to work.
--
-- WHO MOVES A RANK: with `AUTO_PROMOTE` on, the bank's own level does it, and
-- the promotion goes through the same `applyGrade` every other promotion does.
-- A job with `APPROVAL = true` never moves on a clock -- its ranks are granted
-- at a desk -- so its holders keep banking and the rank waits for a person.
-- Yields: the promotion writes rows.
local function tick()
	local settings = type(M.Settings.SENIORITY) == 'table' and M.Settings.SENIORITY or {}
	if settings.enabled == false then return end

	local perTick = Seniority.Finite(settings.POINTS_PER_TICK)
	if perTick == nil or perTick <= 0.0 then return end
	local auto = settings.AUTO_PROMOTE ~= false
	local cooldown = Seniority.Finite(settings.PROMOTION_COOLDOWN_MS) or 5000
	local now = OPX.Now()

	eachPlayer(function(source, who)
		local job = who.job
		if type(job) ~= 'table' or job.onDuty ~= true then return end
		local name = job.name
		if type(name) ~= 'string' then return end

		local terms = Access.Terms(name)
		if terms == nil or terms.top <= 0 or terms.approval == true then return end

		-- The bank is paid BEFORE the rank is considered, and every holder of the
		-- job is paid whether or not their rank can move: a job whose ranks are
		-- granted at a desk still banks the time that buys them.
		local points = pay(who.citizenId, name, perTick)
		if not auto then return end

		local earned = Seniority.GradeFor(terms.ladder, points)
		local held = tonumber(job.grade and job.grade.level) or 0
		-- Clamped to what the catalogue defines and never to what the ladder
		-- names: a build holding a level nobody wrote must not promote anybody
		-- into it, because the write would come back `job.gradeNotFound`.
		local ceiling = gradesOf(name)
		local highest = #ceiling > 0 and ceiling[#ceiling] or held
		local wanted = math.min(earned, highest)
		if wanted <= held then return end
		if promotedAt[who.citizenId] ~= nil and now - promotedAt[who.citizenId] < cooldown then return end

		local moved = applyGrade(who.citizenId, name, wanted, name)
		if not moved.ok then return end
		promotedAt[who.citizenId] = now

		OPX.NotifyLocale(source, 'jobs.promotedAuto', { job = name, grade = tostring(wanted) })
		OPX.Audit.Player(who.player, 'jobs.promote',
			('%s to grade %d by seniority'):format(safe(name), wanted))
		Open77.log.info(('[jobs] %s promoted to %s grade %d on seniority (%.1f point(s))')
			:format(safe(who.citizenId), safe(name), wanted, points))
		-- The board a player is standing on says which rank they hold; a
		-- promotion under their feet would otherwise leave the menu lying.
		sync(source)
	end)
end

--- Writes every dirty bank out. Yields; a job of its own.
-- @return integer rows written
local function flushAll()
	local written = 0
	for citizenId in pairs(dirty) do written = written + flush(citizenId) end
	return written
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
-- @param name string|nil
-- @param opts table
-- @param handler function
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Who will actually be shown a board, in words, so an operator placing one is
--- told rather than left to guess.
---
--- THIS IS THE ANSWER THAT WAS MISSING. A capture used to report `saved` and
--- nothing else, and the two states that matter most are both silent: a desk is
--- drawn only for the holder of its job's boss grade, so a division with no boss
--- yet is a marker drawn for nobody; and the operator who placed it, read
--- `saved`, walked around and saw nothing had no way to tell a board nobody can
--- see from a capture that never happened. Memory only: both reads are the live
--- ones and neither yields.
-- @param board table
-- @param citizenId string|nil the capturer
-- @return string
local function audienceOf(board, citizenId)
	if board.kind == M.KIND.SIGNUP then
		return ('shown to every player within %d m of it')
			:format(math.floor(Access.MaxDistance()))
	end

	local boss = bossGradeOf(board.job)
	local who = boss ~= nil
		and ('the holder of %s grade %d'):format(board.job, boss)
		or ('the holder of whatever grade %s marks as its boss'):format(board.job)
	if citizenId == nil or board.by ~= citizenId then
		return ('a desk is shown to ' .. who .. ' and to whoever captured it')
	end

	local held = gradeHeld(citizenId, board.job)
	if boss ~= nil and held ~= nil and held >= boss then
		return ('a desk is shown to ' .. who .. ', which you hold, so it stands for you')
	end
	return ('a desk is shown to ' .. who .. '. You hold ' ..
		(held ~= nil and ('grade %d of %s'):format(held, board.job) or ('no %s grade'):format(board.job)) ..
		', so you see the marker as the one who captured it, and the roster will refuse you ' ..
		'until you hold that grade (the admin menu can put you in it, or it is earned at a desk)')
end

--- Saves one captured board: the position from the server, the heading from the
--- client that asked. Yields.
-- @param player number
-- @param kind string
-- @param job string
-- @param key string
-- @param label string
-- @param yaw any the client's own facing, or nil
-- @param citizenId string|nil who wrote it
local function capture(player, kind, job, key, label, yaw, citizenId)
	local at = positionOf(player)
	if at == nil then
		OPX.NotifyLocale(player, 'jobs.noPosition', nil, 'error')
		return OPX.CommandResult(player, false, 'your position could not be read; nothing was saved')
	end

	local heading = Access.FiniteNumber(yaw)
	if heading == nil then heading = 0.0 end
	heading = heading % 360.0

	-- `BY` IS THE CAPTURER, carried into the board and not just into the row: a
	-- desk is shown to its job's boss and to whoever captured it, so a board
	-- built here without it would be invisible to the operator who placed it
	-- until the next boot, which is the very symptom this fixes.
	local board, why = Access.FromDefinition(key, {
		KIND = kind, JOB = job, LABEL = label,
		X = at.x, Y = at.y, Z = at.z, HEADING = heading, BUCKET = at.bucket,
		BY = citizenId,
	})
	if board == nil then
		Open77.log.warn(('[jobs] player %d capture of %s refused: %s')
			:format(player, safe(key), safe(why)))
		OPX.NotifyLocale(player, 'jobs.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = Store.UpsertBoard(board, citizenId)
	if not saved.ok then
		Open77.log.warn(('[jobs] player %d could not save the capture of %s: %s')
			:format(player, safe(key), safe(saved.detail)))
		OPX.NotifyLocale(player, 'jobs.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, 'could not save: ' .. tostring(saved.detail))
	end

	captured[key] = board
	rebuild()
	syncAll()
	local audience = audienceOf(board, citizenId)
	Open77.log.info(
		('[jobs] %s captured as a %s board for %s at %.2f,%.2f,%.2f yaw=%.1f by %d; %s')
			:format(safe(key), safe(kind), safe(job), board.x, board.y, board.z, board.heading,
				player, audience))
	OPX.CommandResult(player, true, ('%s saved -- %s. Check it in to survive a database ' ..
		'reset:\n  %s = ' ..
		'{ LABEL = %q, KIND = %q, JOB = %q, X = %.2f, Y = %.2f, Z = %.2f, HEADING = %.1f, BUCKET = %d },')
		:format(key, audience, key, board.label, board.kind, board.job, board.x, board.y, board.z,
			board.heading, board.bucket))
end

--- Watches one capture ask and says so when the client never answered: a board
--- that was never captured used to read exactly like one captured elsewhere.
-- @param player number
-- @param askedAt number
-- @param key string
local function watchCapture(player, askedAt, key)
	CreateThread(function()
		local timeout = Access.CaptureTimeoutMs()
		Wait(timeout)
		local still = pending[player]
		if still ~= nil and still.at == askedAt then
			pending[player] = nil
			Open77.log.warn(('[jobs] player %d did not answer the capture of %s within %d ms; ' ..
				'nothing was saved'):format(player, safe(key), timeout))
			OPX.NotifyLocale(player, 'jobs.captureNoAnswer', { key = key }, 'error')
		end
	end)
end

--- Prints every board: kind, job, position and where it comes from.
-- @param source number
local function report(source)
	local keys, capturedCount = {}, 0
	for key in pairs(boards) do keys[#keys + 1] = key end
	table.sort(keys)

	local lines = {}
	for index = 1, #keys do
		local board = boards[keys[index]]
		local fromDatabase = captured[board.key] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s %s job=%s pos=%.2f,%.2f,%.2f yaw=%.1f bucket=%d %s'):format(
			board.key, board.kind, board.label, board.job, board.x, board.y, board.z,
			board.heading, board.bucket, fromDatabase and 'captured' or 'config')
	end
	local offered = 0
	for _, terms in pairs(Access.TermsAll()) do
		if terms.open then offered = offered + 1 end
	end
	lines[#lines + 1] = ('%d board(s): %d from config, %d captured; %d job(s) offered')
		:format(#keys, #keys - capturedCount, capturedCount, offered)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Prints one job's ladder and where a character stands on it.
-- @param source number
-- @param name string
-- @param who string|nil a citizen id; the caller's own when omitted
local function reportRank(source, name, who)
	local terms = Access.Terms(name)
	if terms == nil then
		return OPX.CommandResult(source, false, 'no job named ' .. tostring(name))
	end

	local lines = {}
	for _, grade in ipairs(gradesOf(name)) do
		local rank = rankOf(name, grade)
		local wanted = Seniority.Required(terms.ladder, grade)
		lines[#lines + 1] = ('  %d %s pay=%s needs=%s%s'):format(grade,
			rank ~= nil and tostring(rank.name) or '?',
			rank ~= nil and tostring(rank.payment) or '?',
			wanted ~= nil and ('%.0f point(s)'):format(wanted) or 'nothing (entry)',
			rank ~= nil and rank.isBoss == true and '  (boss)' or '')
	end
	lines[#lines + 1] = ('  ladder: %d level(s); %s'):format(terms.top,
		terms.open and 'open to sign-up' or 'not offered at a board')
	if terms.approval then
		lines[#lines + 1] = '  ranks are granted at a desk, not by a clock'
	end
	if terms.requires ~= nil then
		if terms.requires.job ~= nil then
			lines[#lines + 1] = ('  requires %s at grade %d'):format(terms.requires.job,
				terms.requires.grade or 0)
		end
		if terms.requires.acl ~= nil then
			lines[#lines + 1] = ('  requires the right %s'):format(terms.requires.acl)
		end
	end

	local citizenId = who
	if citizenId == nil then
		local self = characterOf(source)
		citizenId = self ~= nil and self.citizenId or nil
	end
	if citizenId ~= nil then
		local held = liveGrade(citizenId, name)
		if held == nil then
			lines[#lines + 1] = ('  %s does not hold %s'):format(citizenId, name)
		else
			local points = bankOf(citizenId, name)
			local progress = Seniority.Progress(terms.ladder, held, points)
			lines[#lines + 1] = ('  %s holds grade %d with %.1f point(s)%s'):format(citizenId, held,
				points, progress ~= nil and (', %.0f to go'):format(progress.to - points) or '')
		end
	end
	OPX.CommandResult(source, true, ('%s\n%s'):format(name, table.concat(lines, '\n')))
end

--- One boss command: a job and a citizen, answered by the desk's own rule.
-- Declared before `registerCommands` and assigned below, because the handler is
-- built while it is still nil.
local bossCommand

--- Registers the placement, listing and desk commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'jobs.help.add',
		params = {
			{ name = 'kind', optional = true, help = 'jobs.help.addKind' },
			{ name = 'key', optional = true, help = 'jobs.help.addKey' },
			{ name = 'job', help = 'jobs.help.addJob' },
		},
	}, function(source, args)
		local first, kind = 1, M.KIND.SIGNUP
		if type(args[1]) == 'string' and Access.KINDS[args[1]:lower()] then
			kind = args[1]:lower()
			first = 2
		end

		local key = type(args[first]) == 'string' and args[first] or ''
		local job = type(args[first + 1]) == 'string' and args[first + 1]:lower() or ''

		if #job == 0 then
			return OPX.CommandResult(source, false,
				'usage: add [signup|boss] [key] <job> -- the job must be named, e.g. ncpd')
		end
		if Access.Terms(job) == nil then
			return OPX.CommandResult(source, false,
				('no job named %s is offered at a board; config/jobs.lua JOBS lists the ones ' ..
					'that are'):format(job))
		end
		if #key > Access.MAX_KEY then
			return OPX.CommandResult(source, false,
				('a board key is 1 to %d characters'):format(Access.MAX_KEY))
		end
		if #key == 0 then
			local index = 0
			repeat index = index + 1 until boards[kind .. index] == nil
			key = kind .. index
		end

		local at = OPX.Now()
		pending[source] = { at = at }
		TriggerClientEvent(M.Event.CAPTURE, source, kind, job, key, '')
		Open77.log.info(('[jobs] asked player %d for the facing of a %s board for %s as %s')
			:format(source, kind, job, safe(key)))
		watchCapture(source, at, key)
		OPX.CommandResult(source, true,
			('capturing a %s board for %s where you are standing; look the way it should face')
				:format(kind, job))
	end)

	register(names.remove, {
		restricted = true,
		help = 'jobs.help.remove',
		params = { { name = 'key', help = 'jobs.help.removeKey' } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captured[key] == nil then
			return OPX.CommandResult(source, false, configBoards[key] ~= nil
				and 'that board comes from config; edit config/jobs.lua to remove it'
				or 'no captured board named ' .. key)
		end
		CreateThread(function()
			local gone = Store.DeleteBoard(key)
			if gone ~= nil and gone.ok == false then
				return OPX.CommandResult(source, false, 'could not delete: ' .. tostring(gone.detail))
			end
			captured[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[jobs] %s removed by %d'):format(safe(key), source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'jobs.help.list' }, function(source)
		report(source)
	end)

	register(names.roster, {
		restricted = true,
		help = 'jobs.help.roster',
		params = { { name = 'job', help = 'jobs.help.rosterJob' } },
	}, function(source, args)
		local name = type(args[1]) == 'string' and args[1]:lower() or ''
		if #name == 0 then return OPX.CommandResult(source, false, 'usage: roster <job>') end
		CreateThread(function()
			local listed = M.Roster(name)
			if not listed.ok then
				return OPX.CommandResult(source, false, tostring(listed.error))
			end
			local lines = {}
			for _, member in ipairs(listed.value.members) do
				lines[#lines + 1] = ('  %s %s (%s) grade %d, %.1f point(s)%s'):format(
					member.citizenId, member.name, member.gradeName, member.grade, member.points,
					member.isBoss and ' [boss]' or '')
			end
			lines[#lines + 1] = ('%d member(s); the ladder is %d level(s)')
				:format(listed.value.count, listed.value.top)
			OPX.CommandResult(source, true, table.concat(lines, '\n'))
		end)
	end)

	register(names.rank, {
		restricted = true,
		help = 'jobs.help.rank',
		params = {
			{ name = 'job', help = 'jobs.help.rosterJob' },
			{ name = 'citizenId', optional = true, help = 'jobs.help.rankCitizen' },
		},
	}, function(source, args)
		local name = type(args[1]) == 'string' and args[1]:lower() or ''
		if #name == 0 then
			return OPX.CommandResult(source, false, 'usage: rank <job> [citizenId]')
		end
		CreateThread(function()
			reportRank(source, name, type(args[2]) == 'string' and args[2] or nil)
		end)
	end)

	register(names.join, {
		restricted = true,
		help = 'jobs.help.join',
		params = { { name = 'job', help = 'jobs.help.rosterJob' } },
	}, function(source, args)
		local name = type(args[1]) == 'string' and args[1]:lower() or ''
		if #name == 0 then return OPX.CommandResult(source, false, 'usage: join <job>') end
		CreateThread(function()
			local joined = M.JoinJob(source, name)
			if not joined.ok then
				return OPX.CommandResult(source, false, tostring(joined.error))
			end
			sync(source)
			OPX.CommandResult(source, true, ('joined %s at grade 0'):format(name))
		end)
	end)

	register(names.leave, {
		restricted = true,
		help = 'jobs.help.leave',
		params = { { name = 'job', help = 'jobs.help.rosterJob' } },
	}, function(source, args)
		local name = type(args[1]) == 'string' and args[1]:lower() or ''
		if #name == 0 then return OPX.CommandResult(source, false, 'usage: leave <job>') end
		CreateThread(function()
			local who = characterOf(source)
			if who == nil then
				return OPX.CommandResult(source, false, 'your record could not be read')
			end
			if who.jobs[name] == nil then
				return OPX.CommandResult(source, false, ('you do not hold %s'):format(name))
			end
			if M.LastBoss(who.citizenId, name) then
				return OPX.CommandResult(source, false,
					('you are the last boss of %s; hand the desk over before leaving'):format(name))
			end
			local left = character.RemovePlayerFromJob(who.citizenId, name)
			if not left.ok then
				return OPX.CommandResult(source, false, tostring(left.error))
			end
			dropBank(who.citizenId, name)
			sync(source)
			OPX.CommandResult(source, true, ('left %s'):format(name))
		end)
	end)

	for _, action in ipairs({ M.ACTION.PROMOTE, M.ACTION.DEMOTE, M.ACTION.FIRE }) do
		register(names[action], {
			-- NOT restricted to an operator: a boss is granted a desk by their
			-- grade and not by an ACL entry, and the server checks that grade
			-- itself. `restricted = false` here means the host asks nothing --
			-- `bossAct` asks everything that matters.
			restricted = false,
			help = 'jobs.help.' .. action,
			params = {
				{ name = 'job', help = 'jobs.help.rosterJob' },
				{ name = 'citizenId', help = 'jobs.help.rankCitizen' },
			},
			cooldownMs = Access.PromotionCooldown(),
		}, function(source, args)
			bossCommand(source, args, action)
		end)
	end

	-- HIRE IS THE ONE DESK ACTION WHOSE TARGET IS A CONNECTION AND NOT A CITIZEN
	-- ID, which is why it is not in the loop above: `bossAct` reads a hire's
	-- target as a connection -- the candidate has to be standing at the desk, and
	-- somebody who is not in the session cannot be -- so the shared reader, which
	-- hands over a string, would give it a value it can only refuse. Registered
	-- separately with the connection named as one.
	register(names.hire, {
		restricted = false,
		help = 'jobs.help.hire',
		params = {
			{ name = 'job', help = 'jobs.help.rosterJob' },
			{ name = 'playerId', help = 'jobs.help.hirePlayerId' },
		},
		cooldownMs = Access.PromotionCooldown(),
	}, function(source, args)
		local name = type(args[1]) == 'string' and args[1]:lower() or ''
		local candidate = tonumber(args[2])
		if #name == 0 or candidate == nil then
			return OPX.CommandResult(source, false,
				'usage: opx.jobs.hire <job> <playerId> -- the boss grade of the job is what permits it')
		end
		CreateThread(function()
			local done = M.BossByJob(source, name, M.ACTION.HIRE, candidate)
			if not done.ok then
				return OPX.CommandResult(source, false, tostring(done.error))
			end
			syncAll()
			OPX.CommandResult(source, true, ('hired into %s at grade %s'):format(name,
				tostring(done.value.grade)))
		end)
	end)
end

--- A boss action typed instead of pressed. Yields.
-- @param source number
-- @param args table
-- @param action string
bossCommand = function(source, args, action)
	local name = type(args[1]) == 'string' and args[1]:lower() or ''
	local citizenId = type(args[2]) == 'string' and args[2] or ''
	if #name == 0 or #citizenId == 0 then
		return OPX.CommandResult(source, false,
			('usage: %s <job> <citizenId> -- the boss grade of the job is what permits it')
				:format(action))
	end
	CreateThread(function()
		local done = M.BossByJob(source, name, action, citizenId)
		if not done.ok then
			return OPX.CommandResult(source, false, tostring(done.error))
		end
		syncAll()
		OPX.CommandResult(source, true, ('%s: %s %s -> grade %s'):format(action, name, citizenId,
			tostring(done.value.grade or 'gone')))
	end)
end

-- ── the rate limits ─────────────────────────────────────────────────────────

--- Whether a connection is inside its request budget.
-- @param player number
-- @return boolean
local function within(player)
	local limit = Access.RequestsPerWindow()
	local span = Access.RequestWindowMs()
	if limit <= 0 or span <= 0 then return true end

	local now = OPX.Now()
	local window = windows[player]
	if window == nil or now - window.started > span then
		windows[player] = { started = now, used = 1 }
		return true
	end
	if window.used >= limit then return false end
	window.used = window.used + 1
	return true
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config. Never yields.
-- @author XEROX710
function M.Init()
	local problems = {}
	configBoards = Access.Coerce(type(M.Settings.BOARDS) == 'table' and M.Settings.BOARDS or {},
		problems)
	for _, line in ipairs(problems) do Open77.log.warn('[jobs] config: ' .. line) end

	captured = {}
	rebuild()
	banks, dirty = {}, {}
	pending, windows, promotedAt = {}, {}, {}
	running = false

	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the jobs contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('jobs', 1, {
		-- The bank, for a resource that wants to pay for an arrest or a delivery
		-- instead of, or as well as, worked time. It goes through the same clamp,
		-- the same ladder and the same write-back as the tick.
		Award = function(citizenId, name, points)
			if type(citizenId) ~= 'string' or Access.Terms(name) == nil then
				return Result.Err('jobs.noSuchJob', tostring(name))
			end
			local total = pay(citizenId, name, points)
			return Result.Ok({
				job = name,
				points = total,
				grade = Seniority.GradeFor(Access.Terms(name).ladder, total),
			})
		end,
		Bank = function(citizenId, name)
			if type(citizenId) ~= 'string' then return 0 end
			return bankOf(citizenId, name)
		end,
		Roster = M.Roster,
		LastBoss = function(citizenId, name) return M.LastBoss(citizenId, name) end,
		State = function()
			local offered = {}
			for name, terms in pairs(Access.TermsAll()) do
				offered[name] = { open = terms.open, approval = terms.approval, top = terms.top }
			end
			return Result.Ok({
				boards = OPX.Table.Count(boards),
				captured = OPX.Table.Count(captured),
				banks = OPX.Table.Count(banks),
				jobs = offered,
			})
		end,
	})
end

--- Resolves the contract, reads the boards and the banks, and starts the tick.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.error('[jobs] no character contract: no board can be read, nobody can be ' ..
			'signed, and every request is refused')
	end

	local problems = {}
	Access.Problems(type(character) == 'table' and type(character.GetJob) == 'function'
		and character.GetJob or nil, problems)
	for _, line in ipairs(problems) do Open77.log.warn('[jobs] config: ' .. line) end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player ~= nil then sync(player) end
	end)

	-- THE VERDICT FOR ONE BOARD, asked for by key.
	--
	-- A client walking up to a board needs its state NOW rather than on the next
	-- poll (15 s away), and the state is too big a tree to ride on the board list
	-- without taking the whole list over the client's decode window. So it is
	-- asked for by key and answered for one board -- the one the player is
	-- STANDING ON, checked here against the host's own position rather than taken
	-- from the ask, and only if the list they may see contains it, so this door
	-- cannot hand out a desk its boss is not entitled to.
	RegisterNetEvent(M.Event.DETAIL, function(key)
		local player = tonumber(source)
		if player == nil or type(key) ~= 'string' then return end
		if not within(player) then return end
		local who = characterOf(player)
		local at = positionOf(player)
		if who == nil or at == nil then return end
		local listed = boardsFor(at.bucket, who.citizenId)
		for index = 1, #listed do
			local board = listed[index]
			if board.key == key and Access.Within(board, at.x, at.y) then
				local state = stateOf(board, who, player)
				TriggerClientEvent(M.Event.STATE, player, key, state)
				noteCost('a board verdict (' .. tostring(key) .. ')', key, state)
				return
			end
		end
	end)

	RegisterNetEvent(M.Event.JOIN, function(key, job)
		local player = tonumber(source)
		if player == nil then return end
		if not within(player) then
			return OPX.Refuse(player, 'error.tooFast', M.Operation.JOIN)
		end
		CreateThread(function()
			local joined = M.Join(player, type(key) == 'string' and key or '',
				type(job) == 'string' and job or nil)
			if not joined.ok then
				OPX.Refuse(player, joined.error, M.Operation.JOIN)
				OPX.NotifyLocale(player, joined.error, { job = joined.detail }, 'error')
				return TriggerClientEvent(M.Event.ANSWER, player, false, joined.error, key)
			end
			sync(player)
			OPX.NotifyLocale(player, 'jobs.joined', { job = joined.value.job }, 'success')
			TriggerClientEvent(M.Event.ANSWER, player, true, nil, key, joined.value.job)
		end)
	end)

	RegisterNetEvent(M.Event.LEAVE, function(key)
		local player = tonumber(source)
		if player == nil then return end
		if not within(player) then
			return OPX.Refuse(player, 'error.tooFast', M.Operation.LEAVE)
		end
		CreateThread(function()
			local left = M.Leave(player, type(key) == 'string' and key or '')
			if not left.ok then
				OPX.Refuse(player, left.error, M.Operation.LEAVE)
				OPX.NotifyLocale(player, left.error, { job = left.detail }, 'error')
				return TriggerClientEvent(M.Event.ANSWER, player, false, left.error, key)
			end
			sync(player)
			OPX.NotifyLocale(player, 'jobs.left', { job = left.value.job }, 'success')
			TriggerClientEvent(M.Event.ANSWER, player, true, nil, key, left.value.job)
		end)
	end)

	RegisterNetEvent(M.Event.BOSS, function(key, action, target, origin)
		local player = tonumber(source)
		if player == nil then return end
		if not within(player) then
			return OPX.Refuse(player, 'error.tooFast', M.Operation.BOSS)
		end
		CreateThread(function()
			local done = M.Boss(player, type(key) == 'string' and key or '',
				type(action) == 'string' and action:lower() or '', target)
			if not done.ok then
				OPX.Refuse(player, done.error, M.Operation.BOSS)
				OPX.NotifyLocale(player, done.error, { job = done.detail }, 'error')
				return TriggerClientEvent(M.Event.ANSWER, player, false, done.error, origin)
			end
			syncAll()
			OPX.NotifyLocale(player, 'jobs.deskDone',
				{ action = tostring(action), job = tostring(done.value.job) }, 'success')
			TriggerClientEvent(M.Event.ANSWER, player, true, nil, origin, done.value.job)
		end)
	end)

	-- The capture door, gated exactly as the command that opens it: a net event
	-- has no host-side ACL check, so the same question is asked here. A client
	-- that sends this unprompted is either the operator or nobody.
	RegisterNetEvent(M.Event.CAPTURED, function(kind, job, key, label, yaw)
		local player = tonumber(source)
		if player == nil then return end
		pending[player] = nil

		local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
		if not allowed(player, 'command.' .. tostring(names.add)) then
			Open77.log.warn(('[jobs] player %d tried to capture a board without %s')
				:format(player, safe(names.add)))
			return OPX.Refuse(player, 'error.noPermission', M.Operation.CAPTURE)
		end
		if not within(player) then
			return OPX.Refuse(player, 'error.tooFast', M.Operation.CAPTURE)
		end

		kind = type(kind) == 'string' and kind:lower() or ''
		job = type(job) == 'string' and job:lower() or ''
		key = type(key) == 'string' and key or ''
		label = type(label) == 'string' and label or ''
		if not Access.KINDS[kind] or #key == 0 or #key > Access.MAX_KEY
			or Access.Terms(job) == nil then
			Open77.log.warn(('[jobs] player %d answered a capture for an unusable board')
				:format(player))
			return OPX.Refuse(player, 'error.badRequest', M.Operation.CAPTURE)
		end

		local who = characterOf(player)
		CreateThread(function()
			capture(player, kind, job, key, label, yaw, who ~= nil and who.citizenId or nil)
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then
		windows[player] = nil
		pending[player] = nil
		sent[player] = nil
	end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[jobs] seniority could not be read: ' .. safe(rows.detail))
		else
			local loaded = type(rows.value) == 'table' and rows.value or {}
			local skipped = 0
			for index = 1, #loaded do
				local row = loaded[index]
				local citizenId = tostring(row.citizen_id or '')
				local name = tostring(row.job or '')
				local points = Seniority.Finite(row.points)
				if citizenId ~= '' and name ~= '' and points ~= nil and points >= 0 then
					local held = banks[citizenId]
					if held == nil then
						held = {}
						banks[citizenId] = held
					end
					held[name] = points
				else
					skipped = skipped + 1
					Open77.log.warn('[jobs] a seniority row was refused: ' ..
						safe(row.citizen_id))
				end
			end
			if skipped > 0 then
				Open77.log.warn(('[jobs] %d seniority row(s) could not be read'):format(skipped))
			end
		end

		-- The captured boards, merged over the config by key: a board captured in
		-- game is the one that stands, and the checked-in value is what a
		-- database reset falls back to.
		local stored = Store.FetchBoards()
		if not stored.ok then
			Open77.log.error('[jobs] captured boards could not be read: ' .. safe(stored.detail))
		else
			local rows = type(stored.value) == 'table' and stored.value or {}
			for index = 1, #rows do
				local raw = rows[index]
				-- `board_key`, WHICH IS THE NAME THE QUERY SELECTS. This read `raw.key`
			-- and the two never met: every captured board came back under a field
			-- nobody read, so it was refused at boot with `key must be a string of 1
			-- to 48 characters` and an operator's placed marker vanished on every
			-- restart while the write had succeeded. Seen on a live server
			-- (2026-09-22) twice, once per captured board.
				--
				-- The suite could not see it because its database stub stored the
				-- INSERT's own parameters -- `key`, `label` -- and handed them straight
				-- back, so the loader was given the field it was asking for. It stores
				-- by column now, which is what the bridge answers with.
				local board, why = Access.FromDefinition(tostring(raw.board_key or ''), {
					KIND = raw.kind, JOB = raw.job, LABEL = raw.label,
					X = raw.x, Y = raw.y, Z = raw.z, HEADING = raw.heading, BUCKET = raw.bucket,
					BY = raw.created_by,
				})
				if board == nil then
					Open77.log.warn(('[jobs] a captured board was refused: %s'):format(safe(why)))
				else
					captured[board.key] = board
				end
			end
			rebuild()
		end

		local offered = 0
		for _, terms in pairs(Access.TermsAll()) do
			if terms.open then offered = offered + 1 end
		end
		Open77.log.info(('[jobs] ready: %d board(s) (%d captured), %d job(s) offered, %d bank(s)')
			:format(OPX.Table.Count(boards), OPX.Table.Count(captured), offered,
				OPX.Table.Count(banks)))
		syncAll()
	end)

	local settings = type(M.Settings.SENIORITY) == 'table' and M.Settings.SENIORITY or {}
	local tickMs = Seniority.Finite(settings.TICK_MS)
	if settings.enabled == false then
		Open77.log.info('[jobs] seniority is off; no rank will be earned from worked time')
	elseif tickMs == nil or tickMs < 1000 then
		Open77.log.error('[jobs] SENIORITY.TICK_MS is not at least a second; no rank will be ' ..
			'earned until it is fixed')
	else
		CreateThread(function()
			while running do
				Wait(tickMs)
				tick()
			end
		end)
	end

	local saveMs = Seniority.Finite(settings.SAVE_MS) or 60000
	if saveMs >= 1000 then
		CreateThread(function()
			while running do
				Wait(saveMs)
				local written = flushAll()
				if written > 0 then
					Open77.log.info(('[jobs] wrote %d seniority row(s)'):format(written))
				end
			end
		end)
	end

	-- The rate-limit windows, so a long session does not keep one per player that
	-- ever pressed a key.
	CreateThread(function()
		while running do
			Wait(60000)
			local now, span = OPX.Now(), Access.RequestWindowMs() * 6
			for player, window in pairs(windows) do
				if now - (window.started or now) > span then windows[player] = nil end
			end
		end
	end)
end

--- Stops the loops and writes every bank out one last time.
--
-- The write is done in a job of its own rather than here, because `Stop` is
-- called from the shutdown path where yielding is not guaranteed -- and losing
-- the bank of everybody online because the process was asked to stop is exactly
-- the failure a periodic write is there to make cheap.
-- @author XEROX710
function M.Stop()
	running = false
	local held = dirty
	dirty = {}
	local pendingCount = OPX.Table.Count(held)
	if pendingCount > 0 then
		CreateThread(function()
			local written = 0
			for citizenId, marked in pairs(held) do
				for name in pairs(marked) do
					local saved = Store.Upsert(citizenId, name, bankOf(citizenId, name))
					if saved.ok then written = written + 1 end
				end
			end
			Open77.log.info(('[jobs] wrote %d seniority row(s) on shutdown'):format(written))
		end)
	end
	windows, pending = {}, {}
end
