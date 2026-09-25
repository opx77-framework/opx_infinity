--- Config reads, board normalisation and the decisions both halves share.
-- @author XEROX710
--
-- Two input shapes arrive here and they are deliberately not the same function,
-- exactly as they are not in `garages`. A DEFINITION is what an operator writes
-- in `config/jobs.lua` and what a captured row holds in the database:
-- upper-case fields, the same spelling the garages and elevators configs use. A
-- WIRE board is what the server sends a client: already normalised and
-- lower-case. Each is validated on its own terms, and both end in the one
-- `build` below -- so there is one place that decides what a board is and one
-- place that decides whether one is usable.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a ladder with a hole in it reads as a warning at boot
-- rather than a raise inside a scan or a network handler. Only X and Y are ever
-- measured against; Z is validated and then carried to the create call.
--
-- THE ONE CROSS-MODULE CHECK lives here too, as a function that takes the job
-- catalogue as an argument rather than reaching for it: `Problems` asks a
-- resolver -- the character contract's own `GetJob` -- whether each job this
-- file offers exists, and whether every level of each ladder is a grade that job
-- really has. A ladder naming a grade nobody defined would promote somebody into
-- a rank with no name and no pay, and a board for a job nobody defined would
-- offer work that does not exist.

local M = OPX.Modules.Get('jobs')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- Box every accepted coordinate fits in.
local BOUND = 1000000

-- Coerces a world coordinate: finite and inside BOUND.
local function coordinate(value)
	local parsed = finiteNumber(value)
	if parsed == nil or parsed > BOUND or parsed < -BOUND then return nil end
	return parsed
end
Access.Coordinate = coordinate

-- Coerces a whole number inside BOUND.
local function integer(value)
	local parsed = coordinate(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	return math.floor(parsed)
end
Access.Integer = integer

--- The two kinds of board, and the engine's own marker vocabulary.
local KINDS = { [M.KIND.SIGNUP] = true, [M.KIND.BOSS] = true }
Access.KINDS = KINDS

local SHAPES = { ring = true, cylinder = true }
local STYLES = { interaction = true, objective = true, spawn = true, danger = true }

--- The largest allowed board key, which is also the column width.
Access.MAX_KEY = 48

--- One marker preset, with the shipped default for anything the config left out.
--
-- Every value is clamped to what `Open77.markers` accepts rather than passed on
-- to be refused: a RADIUS outside 0.1..50 would draw no marker at all, and a
-- board that exists in the config and not in the world is the one failure a
-- player cannot tell from a board nobody placed.
-- @param kind string
-- @return table `{ shape, style, radius, lift }`
function Access.Marker(kind)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
	local preset = type(declared) == 'table' and declared or {}
	local shape = type(preset.shape) == 'string' and preset.shape:lower() or nil
	local style = type(preset.style) == 'string' and preset.style:lower() or nil
	local radius = finiteNumber(preset.RADIUS)
	local lift = finiteNumber(Config.GROUND_OFFSET)
	return {
		shape = SHAPES[shape] and shape or (kind == M.KIND.BOSS and 'cylinder' or 'cylinder'),
		style = STYLES[style] and style
			or (kind == M.KIND.BOSS and 'objective' or 'interaction'),
		radius = radius ~= nil and math.max(0.1, math.min(50.0, radius)) or 2.5,
		lift = lift ~= nil and math.max(0.0, math.min(2.0, lift)) or 0.06,
	}
end

--- Metres at which a marker stops being drawn, inside the engine's 1..500.
-- @return number
function Access.MaxDistance()
	local declared = finiteNumber(Config.MAX_DISTANCE)
	if declared == nil then return 150.0 end
	return math.max(1.0, math.min(500.0, declared))
end

--- Flat metres within which a board may be used.
-- @return number
function Access.UseRadius()
	local declared = finiteNumber(Config.USE_RADIUS)
	if declared == nil then return 4.0 end
	return math.max(0.5, declared)
end

--- The scan cadence, or zero when the config got it wrong.
-- Zero is read by the client as a boot error rather than as every pass.
-- @return number
function Access.ScanMs()
	local declared = finiteNumber(Config.SCAN_MS)
	if declared == nil or declared % 1 ~= 0 then return 0 end
	return declared
end

--- How often the client re-asks for its boards.
-- @return number
function Access.PollMs()
	local declared = finiteNumber(Config.POLL_MS)
	if declared == nil or declared % 1 ~= 0 or declared < 0 then return 15000 end
	return declared
end

--- How long the capture round-trip waits for a client's answer before it says
--- the capture did not happen. Four figures or fewer read as a mistake, so the
--- shipped five seconds stands in: a bound that short would time out on a
--- healthy client and refuse a spot that was about to be saved.
-- @return number
function Access.CaptureTimeoutMs()
	local declared = finiteNumber(Config.CAPTURE_TIMEOUT_MS)
	if declared == nil or declared < 1000 then return 5000 end
	return math.floor(declared)
end

--- How many requests one connection may make inside Access.RequestWindowMs.
-- A board is a place a player stands on, so this ceiling is about a stuck key
-- and not about fairness.
-- @return number
function Access.RequestsPerWindow()
	local declared = finiteNumber(Config.REQUESTS_PER_WINDOW)
	if declared == nil or declared < 1 then return 8 end
	return math.floor(declared)
end

--- The window those requests are counted in.
-- @return number
function Access.RequestWindowMs()
	local declared = finiteNumber(Config.REQUEST_WINDOW_MS)
	if declared == nil or declared < 1000 then return 10000 end
	return math.floor(declared)
end

--- The floor between two desk commands from one connection.
-- @return number
function Access.PromotionCooldown()
	local declared = finiteNumber(Config.COOLDOWN_MS)
	if declared == nil or declared < 0 then return 2000 end
	return math.floor(declared)
end

--- Metres from a desk a candidate has to be standing to be hired.
-- @return number
function Access.HireRadius()
	local declared = finiteNumber(Config.HIRE_RADIUS)
	if declared == nil then return 8.0 end
	return math.max(0.5, declared)
end

--- The most members one roster payload carries.
-- @return number
function Access.RosterLimit()
	local declared = finiteNumber(Config.ROSTER_LIMIT)
	if declared == nil or declared < 1 then return 200 end
	return math.floor(declared)
end

-- ── the platform's window ───────────────────────────────────────────────────

-- HOW BIG ONE NETWORK EVENT MAY BE, in the client's own numbers.
--
-- The client decodes every inbound event with `DecodeArgumentArray`
-- (scripting/src/ResourceHost.cpp), which refuses the WHOLE payload -- root,
-- array or object, every value -- past 1024 value nodes or 8 levels of
-- nesting, and drops it with one line on the host's own `network` category:
-- "dropped malformed network event payload". The server's encoder is more
-- permissive (4096 nodes, 16 levels) and throws rather than trimming, so a
-- payload between the two windows is sent by a happy server and refused by
-- every client with no error on either side that names the payload.
--
-- That is how the job markers went missing in game on 2026-09-22: the sync
-- carried every board AND its whole state tree, `state.offers[].grades[]`
-- alone is nine levels deep, so `TriggerClientEvent` returned true, the node
-- logged the boards as sent, and the client held none of them. Every payload
-- this module raises is now measured against these two numbers before it is
-- sent, and says its own cost out loud.
--
-- The values are the host's constants and must move with them.
Access.CEILING = { VALUES = 1024, DEPTH = 8 }

--- What one event would cost the client to decode, in the host's own accounting.
--
-- Mirrors `JsonReader::Value`: the argument array is the root at depth zero,
-- every value in it counts once (object KEYS do not), and a table's members sit
-- one level deeper than the table. Measuring the arguments rather than the
-- payload table is deliberate -- it is what the client measures.
-- @param ... any the arguments the event would be raised with
-- @return number values, number depth
function Access.Cost(...)
	local values, deepest = 1, 0
	local function walk(value, depth)
		values = values + 1
		if depth > deepest then deepest = depth end
		if type(value) ~= 'table' then return end
		for _, member in pairs(value) do walk(member, depth + 1) end
	end
	for index = 1, select('#', ...) do walk(select(index, ...), 1) end
	return values, deepest
end

--- Whether the client would accept an event, and what it costs either way.
-- @param ... any the arguments the event would be raised with
-- @return boolean, number values, number depth
function Access.Fits(...)
	local values, depth = Access.Cost(...)
	return values <= Access.CEILING.VALUES and depth <= Access.CEILING.DEPTH, values, depth
end

--- The key declaration, with the shipped value as the fallback so a config that
--- lost its KEY block still names a key.
-- @return table
function Access.Key()
	local declared = type(Config.KEY) == 'table' and Config.KEY or nil
	return declared or { ID = 'opx.jobs.use', NAME = 'jobs.key.use', DEFAULT = 'E' }
end

-- ── the boards ──────────────────────────────────────────────────────────────

--- Builds one validated board, or answers why it was refused.
-- @param key string
-- @param kind any
-- @param job any
-- @param label any
-- @param x any
-- @param y any
-- @param z any
-- @param heading any
-- @param bucket any
-- @param by any the citizen who captured it, or nil for a declared board
-- @return table|nil
-- @return string|nil
local function build(key, kind, job, label, x, y, z, heading, bucket, by)
	if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
		return nil, 'key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters'
	end
	if type(kind) ~= 'string' or not KINDS[kind:lower()] then
		return nil, ('%s: KIND must be one of signup, boss'):format(key)
	end
	if type(job) ~= 'string' or job == '' then
		return nil, ('%s: JOB must name a job in the character catalogue'):format(key)
	end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	if x == nil or y == nil or z == nil then
		return nil, ('%s: X, Y and Z must be finite numbers inside %d'):format(key, BOUND)
	end
	local headingNumber = heading == nil and 0.0 or finiteNumber(heading)
	if headingNumber == nil then
		return nil, ('%s: HEADING must be a finite number'):format(key)
	end
	local bucketNumber = bucket == nil and 0 or integer(bucket)
	if bucketNumber == nil or bucketNumber < 0 then
		return nil, ('%s: BUCKET must be a whole number, 0 or more'):format(key)
	end
	if label ~= nil and type(label) ~= 'string' then
		return nil, ('%s: LABEL must be a string'):format(key)
	end
	-- The job key is lower-cased, because the character catalogue keys are and
	-- an operator who typed `NCPD` has named the same job.
	return {
		key = key,
		label = (type(label) == 'string' and label ~= '') and label or key,
		kind = kind:lower(),
		job = job:lower(),
		x = x, y = y, z = z,
		heading = headingNumber,
		bucket = bucketNumber,
		-- WHO CAPTURED IT, when a database row says so. A declared board has
		-- nobody and this is nil. It is deliberately NOT on the wire: the server
		-- decides which boards a player is sent, so this is an input to that
		-- decision and not something a client is asked to filter by.
		by = (type(by) == 'string' and by ~= '') and by or nil,
	}
end

--- Normalises one config or database row, in the operator's upper-case spelling.
-- @param key string
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromDefinition(key, raw)
	if type(raw) ~= 'table' then return nil, tostring(key) .. ': every board must be a table' end
	return build(key, raw.KIND, raw.JOB, raw.LABEL, raw.X, raw.Y, raw.Z, raw.HEADING,
		raw.BUCKET, raw.BY)
end

--- Normalises one board off the wire, in the shape `Access.WireRow` writes.
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	if type(raw) ~= 'table' then return nil, 'every board must be a table' end
	return build(raw.key, raw.kind, raw.job, raw.label, raw.x, raw.y, raw.z, raw.heading, raw.bucket)
end

--- The fields of one board as the SYNC event carries them: WHERE THE MARKER IS,
--- and nothing else. (`Access.Marker` above is the marker's LOOK; this is the
--- row that says where to put it.)
--
-- NINE FLAT VALUES PER BOARD, which is the whole point. What a player may DO at
-- a board -- the jobs it offers, their own grade, what the next rank costs, the
-- roster, who is standing close enough to hire -- is the server's verdict and
-- travels on the `state` event, for the one board they are standing on. A board
-- list that carried each board's verdict instead cost nine LEVELS of nesting and
-- several hundred values, past the client's decode window, so the client dropped
-- the whole payload in silence and drew no marker at all (see Access.CEILING).
-- @param board table
-- @return table
function Access.WireRow(board)
	return {
		key = board.key, label = board.label, kind = board.kind, job = board.job,
		x = board.x, y = board.y, z = board.z,
		heading = board.heading, bucket = board.bucket,
	}
end

--- Builds a key -> board table from a list of definitions.
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	local boards = {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'BOARDS must be a table of key -> definition'
		end
		return boards
	end
	for key, raw in pairs(definitions) do
		local board, why = Access.FromDefinition(key, raw)
		if board == nil then
			if problems ~= nil then problems[#problems + 1] = why end
		else
			boards[key] = board
		end
	end
	return boards
end

--- Flat distance squared from a board's declared position, or nil.
-- @param board table
-- @param x number
-- @param y number
-- @return number|nil
function Access.FlatDistanceSquared(board, x, y)
	if type(board) ~= 'table' then return nil end
	local dx, dy = board.x - x, board.y - y
	return dx * dx + dy * dy
end

--- Whether a position is close enough to use a board.
-- @param board table
-- @param x number
-- @param y number
-- @param radius number|nil defaults to USE_RADIUS
-- @return boolean
function Access.Within(board, x, y, radius)
	local flat = Access.FlatDistanceSquared(board, x, y)
	if flat == nil then return false end
	local reach = radius or Access.UseRadius()
	return flat <= reach * reach
end

--- The board a position is standing on, or nil.
--
-- The NEAREST within reach, and not the first one met: two boards a metre apart
-- would otherwise be chosen between by the order `pairs` happened to walk, which
-- is the difference between a player pressing the key at the sign-up board and
-- pressing it at the desk beside it.
-- @param boards table key -> board
-- @param x number
-- @param y number
-- @param radius number|nil
-- @return table|nil
function Access.Nearest(boards, x, y, radius)
	local reach = radius or Access.UseRadius()
	local limit = reach * reach
	local best, bestFlat = nil, nil
	for _, board in pairs(boards) do
		local flat = Access.FlatDistanceSquared(board, x, y)
		if flat ~= nil and flat <= limit and (bestFlat == nil or flat < bestFlat) then
			best, bestFlat = board, flat
		end
	end
	return best
end

-- ── the terms of employment ─────────────────────────────────────────────────

--- The rules for one job, coerced, or nil when a board does not offer it.
--
-- Answers a LADDER that is always a table, so a caller never indexes nil: a job
-- declared with no ladder is a job whose ranks never move on their own, which is
-- a real configuration and not a missing one.
-- @param name string|nil
-- @return table|nil `{ open, approval, requires, ladder, top }`
function Access.Terms(name)
	local declared = type(Config.JOBS) == 'table' and type(name) == 'string'
		and Config.JOBS[name:lower()] or nil
	if type(declared) ~= 'table' then return nil end

	local requires = nil
	local raw = declared.REQUIRES
	if type(raw) == 'table' then
		requires = {
			job = type(raw.JOB) == 'string' and raw.JOB:lower() or nil,
			grade = integer(raw.GRADE),
			acl = type(raw.ACL) == 'string' and raw.ACL or nil,
		}
		if requires.grade ~= nil and requires.grade < 0 then requires.grade = nil end
	end

	local ladder = {}
	if type(declared.LADDER) == 'table' then
		for level, points in pairs(declared.LADDER) do
			local index = integer(level)
			local wanted = finiteNumber(points)
			if index ~= nil and index >= 1 and wanted ~= nil and wanted >= 0 then
				ladder[index] = wanted
			end
		end
	end

	return {
		-- A job a board names is offered unless it says otherwise, which is what
		-- makes `JOBS = { police = { LADDER = {...} } }` a complete entry.
		open = declared.OPEN ~= false,
		approval = declared.APPROVAL == true,
		requires = requires,
		ladder = ladder,
		top = M.Seniority.Top(ladder),
	}
end

--- Every job a board offers, and its terms.
-- @return table name -> terms
function Access.TermsAll()
	local all = {}
	for name in pairs(type(Config.JOBS) == 'table' and Config.JOBS or {}) do
		local terms = Access.Terms(name)
		if terms ~= nil then all[name] = terms end
	end
	return all
end

--- Whether one character satisfies one job's terms, and what is missing when
--- they do not.
--
-- Pure by construction: the three questions it asks about a character arrive as
-- CALLBACKS rather than as a contract, because `shared/` is loaded on both
-- halves and a client holds a copy of its own job that is minutes old. The
-- server passes the roster's own answers; the client passes the same answers read
-- from its replicated copy, so the refusal a player reads on the board and the
-- refusal the server would give have one implementation.
-- @param terms table from Access.Terms
-- @param character table|nil `{ job, grade, jobs, allowed }`
--   `grade(citizenJob)` answers the grade held, `allowed(right)` answers the ACL
-- @return boolean
-- @return string|nil a locale key under `jobs.`
function Access.MeetsRequirements(terms, character)
	if type(terms) ~= 'table' then return false, 'jobs.noSuchJob' end

	local gradeOf = type(character) == 'table' and character.grade or nil
	local allowed = type(character) == 'table' and character.allowed or nil

	local requires = terms.requires
	if type(requires) == 'table' then
		if requires.acl ~= nil then
			if type(allowed) ~= 'function' or allowed(requires.acl) ~= true then
				return false, 'jobs.needsRight'
			end
		end
		if requires.job ~= nil then
			local held = type(gradeOf) == 'function' and gradeOf(requires.job) or nil
			if type(held) ~= 'number' then return false, 'jobs.needsJob' end
			if requires.grade ~= nil and held < requires.grade then return false, 'jobs.needsGrade' end
		end
	end

	return true, nil
end

--- Whether one character satisfies one job's terms, and what is missing when
--- they do not.
--
-- The terms a SIGN-UP asks about: the requirements above plus whether the job is
-- offered at all, and whether it takes walk-ins. A job with `APPROVAL = true` is
-- refused here by name -- `jobs.byInvitation` -- rather than as a bare no, which
-- is what the board then shows: MaxTac does not take walk-ins, and the menu says
-- so instead of leaving a dead row.
-- @param terms table from Access.Terms
-- @param character table|nil `{ grade(citizenJob), allowed(right) }`
-- @return boolean
-- @return string|nil a locale key under `jobs.`
function Access.MeetsTerms(terms, character)
	if type(terms) ~= 'table' then return false, 'jobs.noSuchJob' end
	if terms.open ~= true then return false, 'jobs.notOpen' end
	if terms.approval == true then return false, 'jobs.byInvitation' end
	return Access.MeetsRequirements(terms, character)
end

-- ── the cross-module check ──────────────────────────────────────────────────

--- Every configuration problem this module can name before a player meets one.
--
-- `resolveJob` is the character contract's own `GetJob`, handed in rather than
-- reached for: this file is loaded on both halves and knows nothing about
-- modules. A resolver that answers nothing at all -- a character module that is
-- absent -- is not a fault of this config, so the check is skipped rather than
-- reported as a hundred missing jobs.
-- @param resolveJob function|nil name -> definition|nil
-- @param problems table|nil collector, appended to
-- @return table
function Access.Problems(resolveJob, problems)
	problems = problems or {}

	if type(Config.JOBS) ~= 'table' then
		problems[#problems + 1] = 'JOBS must be a table of name -> rules'
		return problems
	end

	for name, terms in pairs(Access.TermsAll()) do
		local definition = type(resolveJob) == 'function' and resolveJob(name) or nil
		if type(definition) ~= 'table' then
			-- Said and kept: a board for a job the catalogue does not define can
			-- never be signed at, and a warning that skipped the entry would
			-- leave it on the sign looking joinable.
			problems[#problems + 1] = ('JOBS.%s: the character catalogue has no such job'):format(name)
		else
			local grades = type(definition.grades) == 'table' and definition.grades or {}
			for level in pairs(terms.ladder) do
				if grades[level] == nil then
					problems[#problems + 1] = ('JOBS.%s.LADDER[%d]: grade %d is not a grade of %s'):format(
						name, level, level, name)
				end
			end
			-- A boss board for a job with nobody able to be boss is a desk
			-- nobody can ever sit behind, and that is worth one line.
			local hasBoss = false
			for _, grade in pairs(grades) do
				if type(grade) == 'table' and grade.isBoss == true then hasBoss = true end
			end
			if not hasBoss then
				for _, board in pairs(Access.Coerce(type(Config.BOARDS) == 'table' and Config.BOARDS or {})) do
					if board.job == name and board.kind == M.KIND.BOSS then
						problems[#problems + 1] =
							('BOARDS.%s: %s has no grade marked isBoss, so nobody may work this desk')
								:format(board.key, name)
					end
				end
			end
		end
	end

	return problems
end
