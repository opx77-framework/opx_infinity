--- The server half: the ledger, the curve, and the funnel the jobs bank pours
-- into. Every number a player reads is decided here.
-- @author XEROX710
--
-- ONE FUNNEL IN, ONE ANSWER OUT. Work arrives on `jobs.Event.PAID` -- the jobs
-- bank's own `pay` says so on every credit it actually makes -- and leaves as a
-- `GAIN` line and a fresh `STATE` frame. The net handlers answer the knock and
-- the one intent (a spend), and both answers are full frames: the panel is a
-- picture of this file and never a second copy of it.
--
-- THE CLAMP IS THE LEDGER'S, NOT THE BANK'S. The bank stops paying at its
-- ceiling; a character at the top of the ladder is still doing work, so the XP
-- is what was credited by the bank (its own truth) and the level cap is this
-- module's own (`LEVEL_CAP`). Two ceilings, each owning its own fact.
--
-- ONE LEVER BESIDE THE FUNNEL, AND IT IS STAFF'S. `opx.skills.level` puts a
-- character at the cap, at a level, or back at the start, for testing or for
-- fun. It moves the same record the funnel does, writes it back the same way,
-- and tells the player's client to re-ask -- an OPEN tree redraws, a closed one
-- stays closed. `max` also asks the player's own machine to max the base
-- game's levels (the preload in `DEVELOP`), which nothing on a server can
-- reach any other way; the client reports what it answered and it is
-- journalled here.

local M = OPX.Modules.Get('skills')
local Result = OPX.Result
local Store = M.Storage

--- The character contract, resolved at Start. Nil is answered and not raised.
local character = nil

--- citizenId -> { xp, level, points, nodes = { [id] = true } }.
-- `xp` is XP INTO the current level, not a lifetime total: the header reads
-- `xp/need`, and a total would need recomputing what is owed at every draw.
local records = {}

--- Which records changed since the last write-back.
local dirty = {}

--- node id -> { branch = id, rank = integer, node = node }, rebuilt at Init.
local index = {}

--- connection -> { nonce, at, citizenId }: a base-game develop request that
-- has gone out and not been answered. A report that matches none is ignored.
local developing = {}
local developCount = 0

--- How long a develop request waits for its report before it is stale.
local DEVELOP_TTL_MS = 60000

--- Whether a malformed `ripperdoc.ChromeLevel` answer has been named already:
-- the frame is drawn on every knock, and one line says it.
local chromeNamed = false

-- ── the small things ────────────────────────────────────────────────────────

--- A finite number or nil: NaN and infinities are refusals everywhere here,
-- because a NaN written once is a record no level can ever be computed from.
-- @param value any
-- @return number|nil
local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return number
end

--- Text bounded for a journal line: a client's words never reach the log raw.
-- @param value any
-- @return string
local function safe(value)
	if type(OPX.Audit) == 'table' and type(OPX.Audit.Safe) == 'function' then
		return OPX.Audit.Safe(tostring(value), 96)
	end
	return (tostring(value):sub(1, 96):gsub('[%c]', ' '))
end

--- The citizen id as the ledger keys it: the row's text, whatever the host's
-- database typed the column as. A bridge that answers a numeric-looking id as a
-- number must still find the same record the load keyed.
-- @param data table PlayerData
-- @return string|nil
local function citizenOf(data)
	local citizenId = data.citizenId
	if type(citizenId) == 'string' and citizenId ~= '' then return citizenId end
	if type(citizenId) == 'number' then return tostring(citizenId) end
	return nil
end

--- The character a connection has loaded, as the character contract sees it,
-- and -- when there is none to read -- why. The contract is re-read on every
-- look, the way the ripperdoc's reader does it: captured once at Start, a nil
-- answer there would refuse every knock for the life of the VM.
-- @param source number
-- @return table|nil PlayerData
-- @return string|nil citizenId as the ledger keys it
-- @return string|nil why, when there is nothing to read
local function dataOf(source)
	if character == nil then character = OPX.Api.Get('character') end
	if character == nil or type(character.GetPlayer) ~= 'function' then
		return nil, nil, 'no character contract'
	end
	local read, player = pcall(character.GetPlayer, source)
	if not read then return nil, nil, 'the roster raised: ' .. tostring(player) end
	if type(player) ~= 'table' then return nil, nil, 'no character is loaded' end
	-- The contract answers the PLAYER object and the facts live on its
	-- PlayerData -- but a reader that accepts the facts bare costs nothing.
	local data = type(player.PlayerData) == 'table' and player.PlayerData or player
	local citizenId = citizenOf(data)
	if citizenId == nil then
		return nil, nil, 'its citizen id reads as ' .. type(data.citizenId)
	end
	return data, citizenId
end

--- Runs fn for every connection currently holding this character.
-- The ledger is keyed by citizen and the wire is keyed by connection; this is
-- the only place the two meet.
-- @param citizenId string
-- @param fn function(source)
local function eachHolder(citizenId, fn)
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index_ = 1, #ids do
		local source = tonumber(ids[index_])
		if source ~= nil and source > 0 then
			local data, held = dataOf(source)
			if data ~= nil and held == citizenId then fn(source) end
		end
	end
end

--- One character's record, created empty on first touch.
-- @param citizenId string
-- @return table
local function recordOf(citizenId)
	local record = records[citizenId]
	if record == nil then
		record = { xp = 0.0, level = 1, points = 0, nodes = {} }
		records[citizenId] = record
	end
	return record
end

--- What one trunk has been fed. Created on the record the first time work
-- arrives for it.
-- @param record table
-- @param branchId string
-- @return number XP fed to this trunk
local function branchXp(record, branchId)
	local fed = record.branches
	if fed == nil then
		fed = {}
		record.branches = fed
	end
	return finite(fed[branchId]) or 0.0
end

--- The unlocked nodes as the bounded column the row holds.
-- Sorted so one set writes one value however it was built.
-- @param record table
-- @return string
local function nodesColumn(record)
	local ids = {}
	for id in pairs(record.nodes) do ids[#ids + 1] = id end
	table.sort(ids)
	local column = table.concat(ids, ',')
	if #column > 500 then return column:sub(1, 500) end
	return column
end

--- What each trunk was fed, as the bounded column the row holds. Sorted so one
-- record writes one value however it was built.
-- @param record table
-- @return string `id:xp` pairs joined by `;`
local function branchesColumn(record)
	local pairs_ = {}
	for id in pairs(record.branches or {}) do pairs_[#pairs_ + 1] = id end
	table.sort(pairs_)
	local column = {}
	for _, id in ipairs(pairs_) do
		column[#column + 1] = ('%s:%s'):format(id, tostring(record.branches[id]))
	end
	local joined = table.concat(column, ';')
	if #joined > 240 then return joined:sub(1, 240) end
	return joined
end

--- Marks a record for write-back and schedules one on a thread of its own, so
-- progress survives a restart without the caller waiting on the disk.
-- @param citizenId string
local function flushSoon(citizenId)
	if not dirty[citizenId] then return end
	CreateThread(function()
		if not dirty[citizenId] then return end
		dirty[citizenId] = nil
		local record = records[citizenId]
		if record == nil then return end
		local saved = Store.Upsert(citizenId, record, nodesColumn(record), branchesColumn(record))
		if not saved.ok then
			dirty[citizenId] = true
			Open77.log.warn(('[skills] %s: the tree could not be written: %s')
				:format(tostring(citizenId), tostring(saved.detail)))
		end
	end)
end

--- Tells the player's own client that the ledger moved. One line of news: the
-- work credited, and -- on its `level` field -- how many levels it crossed.
-- @param citizenId string
-- @param line table
local function pushGain(citizenId, line)
	eachHolder(citizenId, function(source)
		local sent, failure = pcall(TriggerClientEvent, M.Event.GAIN, source, line)
		if not sent then
			Open77.log.warn('[skills] gain line refused: ' .. tostring(failure))
		end
	end)
end

-- ── the tree ────────────────────────────────────────────────────────────────

--- What one node's state is, seen from one record: `unlocked`, `available`
-- (rank reached, the node above it claimed, and the points in hand) or
-- `locked` -- and `locked` says WHY, because the panel's detail strip answers
-- the question the greyed node asks.
-- @param record table
-- @param branchId string
-- @param rank integer the trunk's current rank
-- @param rankOf integer this node's rank in the chain
-- @param node table
-- @return string state
-- @return string|nil why, for a locked node
local function nodeState(record, branchId, rankOf, rank, node)
	if record.nodes[node.id] == true then return 'unlocked' end
	if rank < rankOf then return 'locked', M.Skill.Refusal.rank end
	if rankOf > 1 then
		local branch = nil
		for _, candidate in ipairs(M.Skill.Branches()) do
			if candidate.id == branchId then branch = candidate break end
		end
		local before = branch ~= nil and type(branch.NODES) == 'table' and branch.NODES[rankOf - 1] or nil
		if before == nil or record.nodes[before.id] ~= true then
			return 'locked', M.Skill.Refusal.prereq
		end
	end
	if (finite(record.points) or 0) < (finite(node.COST) or 1) then
		return 'locked', M.Skill.Refusal.noPoints
	end
	return 'available'
end

--- A trunk's emblem, if it names one the shared glyph set can draw. A name the
-- set does not hold is left off the wire rather than sent to a page that would
-- draw nothing for it (it was named at Init).
-- @param branch table
-- @return string|nil
local function iconOf(branch)
	local icon = branch.ICON
	if type(icon) ~= 'string' or type(OPX.Glyphs) ~= 'table' or not OPX.Glyphs[icon] then return nil end
	return icon
end

--- What the character level does for fitted chrome, as the ripperdoc answers
-- it -- or nil, which draws no band. Asked lazily on every frame: the
-- ripperdoc is optional and may start after this module, and a server without
-- one simply has a tree with no band. The answer is kept only when it is
-- exactly the page's contract (`M.Skill.ChromeShape`); a wrong one is named
-- once and left off.
-- @param level integer
-- @param cap integer
-- @return table|nil
local function chromeFor(level, cap)
	local ripperdoc = OPX.Api.Get('ripperdoc')
	if type(ripperdoc) ~= 'table' or type(ripperdoc.ChromeLevel) ~= 'function' then return nil end
	local ran, answer = pcall(ripperdoc.ChromeLevel, level, cap)
	if ran and answer == nil then return nil end
	local block, why = nil, nil
	if ran then
		block, why = M.Skill.ChromeShape(answer)
	else
		why = 'it raised: ' .. tostring(answer)
	end
	if block == nil and not chromeNamed then
		chromeNamed = true
		Open77.log.warn('[skills] ripperdoc.ChromeLevel answered something the panel does not draw, '
			.. 'so the tree shows no chrome band: ' .. tostring(why))
	end
	return block
end

--- The one frame every answer sends: the whole tree as this record stands.
-- Never refused on its own -- a knock from a character with no record is a
-- tree of zeroes -- so the panel can always draw somebody.
-- @param citizenId string
-- @return table
local function frameOf(citizenId)
	local record = records[citizenId]
	local level = record ~= nil and record.level or 1
	local cap = M.Skill.Cap()
	local branches = {}
	for _, branch in ipairs(M.Skill.Branches()) do
		local earned = record ~= nil and branchXp(record, branch.id) or 0.0
		local rank = M.Skill.Rank(earned)
		local nodes = {}
		local list = type(branch.NODES) == 'table' and branch.NODES or {}
		for rankOf = 1, #list do
			local node = list[rankOf]
			local state, why = nodeState(record or { nodes = {} }, branch.id, rankOf, rank, node)
			nodes[#nodes + 1] = {
				id = node.id,
				name = node.NAME,
				desc = node.DESC,
				perk = node.PERK,
				value = finite(node.VALUE) or 0,
				cost = finite(node.COST) or 1,
				state = state,
				why = why,
			}
		end
		branches[#branches + 1] = {
			id = branch.id,
			name = branch.NAME,
			-- What the page draws the trunk with: its emblem, and the line that
			-- says which work feeds it. Both optional on the wire.
			icon = iconOf(branch),
			feed = type(branch.FEED) == 'string' and branch.FEED ~= '' and branch.FEED or nil,
			rank = math.min(rank, math.max(#list, 1)),
			xp = earned % (tonumber(M.Settings.BRANCH_STEP) or 100),
			-- The step itself, so the panel's trunk gauge states a real
			-- `xp/need` instead of a percentage of a number it was never given.
			need = tonumber(M.Settings.BRANCH_STEP) or 100,
			nodes = nodes,
		}
	end
	return {
		open = true,
		level = level,
		-- The cap, so the panel states the level against it and draws the
		-- level track 1..cap.
		cap = cap,
		xp = record ~= nil and record.xp or 0.0,
		need = M.Skill.Need(level),
		points = record ~= nil and record.points or 0,
		depth = M.Skill.Depth(),
		branches = branches,
		chrome = chromeFor(level, cap),
	}
end

--- Folds credited job work into one character's tree: XP into the trunk the job
-- feeds, levels from the character's whole career, and one line of news.
-- @param citizenId string
-- @param jobName string|nil
-- @param credited number|nil what the bank actually credited
local function earn(citizenId, jobName, credited)
	local points = finite(credited) or 0.0
	if points <= 0 then return end
	local branchId = M.Skill.BranchOf(jobName)
	local xp = points * (finite(M.Settings.XP_PER_POINT) or 10)
	if branchId == nil or xp <= 0 then return end

	local record = recordOf(citizenId)
	record.branches = record.branches or {}
	record.branches[branchId] = branchXp(record, branchId) + xp

	local cap = M.Skill.Cap()
	local perLevel = math.max(1, math.floor(finite(M.Settings.POINTS_PER_LEVEL) or 1))
	local leveled = 0
	local banked = 0
	if record.level >= cap then
		record.xp = math.min(record.xp + xp, M.Skill.Need(cap))
	else
		record.xp = record.xp + xp
		while record.level < cap and record.xp >= M.Skill.Need(record.level) do
			record.xp = record.xp - M.Skill.Need(record.level)
			record.level = record.level + 1
			record.points = record.points + perLevel
			leveled = leveled + 1
			banked = banked + perLevel
		end
		if record.level >= cap then record.xp = math.min(record.xp, M.Skill.Need(cap)) end
	end

	dirty[citizenId] = true
	flushSoon(citizenId)
	-- `level` is the level NOW if this credit raised one, and 0 if it did not:
	-- the toast says "LEVEL {level}", so the field is the number it speaks.
	pushGain(citizenId, {
		key = 'skills.gain.work',
		args = { xp = xp },
		level = leveled > 0 and record.level or 0,
		points = banked,
	})
end

--- Spends one point-pair on a node: the tree's one intent, decided whole here.
-- @param citizenId string
-- @param nodeId any
-- @return boolean claimed
-- @return string|nil the refusal, in `M.Skill.Refusal`'s own codes
local function unlock(citizenId, nodeId)
	if type(nodeId) ~= 'string' or nodeId == '' then return false, 'noNode' end
	local entry = index[nodeId]
	if entry == nil then return false, 'noNode' end

	local record = recordOf(citizenId)
	if record.nodes[nodeId] == true then return false, 'unlocked' end

	local rank = M.Skill.Rank(branchXp(record, entry.branch))
	local state, why = nodeState(record, entry.branch, entry.rankOf, rank, entry.node)
	if state ~= 'available' then
		return false, why == M.Skill.Refusal.rank and 'rank'
			or why == M.Skill.Refusal.prereq and 'prereq' or 'noPoints'
	end

	record.points = record.points - (finite(entry.node.COST) or 1)
	record.nodes[nodeId] = true
	dirty[citizenId] = true
	flushSoon(citizenId)
	pushGain(citizenId, {
		key = 'skills.gain.node',
		args = { cost = finite(entry.node.COST) or 1 },
		level = 0,
		points = 0,
	})
	return true
end

-- ── the staff lever ─────────────────────────────────────────────────────────

--- What the declared nodes cost, split by whether this record holds them:
-- the points already spent, and the points every node still locked would take.
-- Nodes the config no longer declares are neither -- an unlock left behind by
-- a removed node is not a point anybody spent on this tree.
-- @param record table
-- @return number spent
-- @return number missing
local function nodeCosts(record)
	local spent, missing = 0, 0
	for _, branch in ipairs(M.Skill.Branches()) do
		for _, node in ipairs(type(branch.NODES) == 'table' and branch.NODES or {}) do
			local cost = finite(node.COST) or 1
			if record.nodes[node.id] == true then spent = spent + cost else missing = missing + cost end
		end
	end
	return spent, missing
end

--- The lever's arithmetic on one record. No wire and no disk: the caller does
--- both, so this is the part a test can read whole.
---   max    the cap, a full XP bar, every trunk fed to its full depth, and the
---          points to buy every node still locked (never fewer than it held)
---   set    that level, no XP into it, and the points that level banks minus
---          what the claimed nodes cost -- never below zero; trunks untouched
---   reset  level 1, nothing fed, nothing claimed, nothing banked
-- @param record table
-- @param mode string `max`, `set` or `reset`
-- @param level integer|nil for `set`
function M.Skill.ApplyLevel(record, mode, level)
	local cap = M.Skill.Cap()
	if mode == 'reset' then
		record.level, record.xp, record.points = 1, 0.0, 0
		record.nodes, record.branches = {}, {}
		return
	end
	if mode == 'max' then
		local step = math.max(0, tonumber(M.Settings.BRANCH_STEP) or 100)
		record.level = cap
		record.xp = M.Skill.Need(cap)
		record.branches = record.branches or {}
		for _, branch in ipairs(M.Skill.Branches()) do
			local depth = type(branch.NODES) == 'table' and #branch.NODES or 0
			local full = math.max(0, depth - 1) * step
			record.branches[branch.id] = math.max(branchXp(record, branch.id), full)
		end
		local _, missing = nodeCosts(record)
		record.points = math.max(math.floor(finite(record.points) or 0), missing)
		return
	end
	local target = math.max(1, math.min(math.floor(tonumber(level) or 1), cap))
	local spent = nodeCosts(record)
	record.level = target
	record.xp = 0.0
	record.points = math.max(0, M.Skill.Banked(target) - spent)
end

--- Asks one player's machine to max the base game's own levels, through the
--- preload `DEVELOP` names. What it answers comes back on `DEVELOPED` and is
--- journalled there; this only sends the request and remembers it.
-- @param target number the connection
-- @param citizenId string
-- @return boolean asked
-- @return string|nil why not
local function askDevelop(target, citizenId)
	if M.Skill.DevelopSettings() == nil then return false, 'DEVELOP is off in config/skills.lua' end
	developCount = developCount + 1
	local nonce = ('%d:%d'):format(OPX.Now(), developCount)
	developing[target] = { nonce = nonce, at = OPX.Now(), citizenId = citizenId }
	local sent, failure = pcall(TriggerClientEvent, M.Event.DEVELOP, target, nonce)
	if not sent then
		developing[target] = nil
		return false, 'the request could not be sent: ' .. tostring(failure)
	end
	return true
end

--- `/opx.skills.level <max|reset|1..cap> [playerId]`.
-- @param source number|nil the caller; 0 or nil is the console
-- @param args string[]
local function levelCommand(source, args)
	local caller = tonumber(source) or 0
	local cap = M.Skill.Cap()
	local name = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS.level or 'opx.skills.level'
	local usage = ('usage: %s <max|reset|1..%d> [playerId]'):format(tostring(name), cap)

	local verb = type(args[1]) == 'string' and args[1]:lower() or ''
	local mode, level = nil, nil
	if verb == 'max' or verb == 'reset' then
		mode = verb
	else
		local asked = tonumber(verb)
		if asked ~= nil and asked == math.floor(asked) and asked >= 1 and asked <= cap then
			mode, level = 'set', math.floor(asked)
		end
	end
	if mode == nil then return OPX.CommandResult(source, false, usage) end

	local target = caller
	if args[2] ~= nil and args[2] ~= '' then
		target = tonumber(args[2])
		if target == nil or target <= 0 or target ~= math.floor(target) then
			return OPX.CommandResult(source, false, usage)
		end
	elseif caller <= 0 then
		return OPX.CommandResult(source, false, usage .. ' -- the console has no character, so it must name a player')
	end

	local data, citizenId, why = dataOf(target)
	if data == nil then
		return OPX.CommandResult(source, false,
			('player %d has no character to level: %s'):format(target, tostring(why)))
	end

	local record = recordOf(citizenId)
	M.Skill.ApplyLevel(record, mode, level)
	dirty[citizenId] = true
	flushSoon(citizenId)

	local actor = caller > 0 and ('player ' .. caller) or 'the console'
	local line = ('[skills] %s set player %d (%s) to %s: level %d/%d, %d point(s) to spend')
		:format(actor, target, citizenId, verb, record.level, cap, record.points)
	Open77.log.info(line)
	OPX.Audit.Log({
		event = 'skills.level',
		message = line,
		source = caller > 0 and caller or nil,
		data = { target = target, citizenId = citizenId, mode = mode, level = record.level,
			cap = cap, points = record.points },
	})

	-- The player is told in their own language, and an OPEN tree redraws: the
	-- client re-asks only when its panel is up, so a closed one stays closed.
	local notice = {
		key = 'skills.admin.' .. mode,
		args = { level = record.level, cap = cap, points = record.points },
	}
	eachHolder(citizenId, function(holder)
		local sent, failure = pcall(TriggerClientEvent, M.Event.REFRESH, holder, notice)
		if not sent then Open77.log.warn('[skills] refresh refused: ' .. tostring(failure)) end
	end)

	local extra = ''
	if mode == 'max' then
		local asked, notAsked = askDevelop(target, citizenId)
		extra = asked and '; the base game\'s levels were asked of their client (see the journal)'
			or ('; the base game\'s levels were NOT asked: ' .. tostring(notAsked))
		if not asked then
			Open77.log.warn(('[skills] player %d: base-game development not asked: %s')
				:format(target, tostring(notAsked)))
		end
	end
	OPX.CommandResult(source, true, ('player %d (%s): %s -> level %d/%d, %d point(s) to spend%s')
		:format(target, citizenId, verb, record.level, cap, record.points, extra))
end

--- Takes a develop report from the machine it was asked of. A report nobody
--- asked for -- no request out, the wrong nonce, or one gone stale -- is named
--- and dropped: this door only ever writes a journal line, and it writes the
--- line for the request that is actually out.
-- @param source number
-- @param nonce any
-- @param ok any
-- @param why any
local function developed(source, nonce, ok, why)
	local pending = developing[source]
	if pending == nil or pending.nonce ~= nonce or OPX.Now() - pending.at > DEVELOP_TTL_MS then
		Open77.log.warn(('[skills] player %d: a base-game development report nobody asked for was ignored')
			:format(source))
		return
	end
	developing[source] = nil
	local line
	if ok == true then
		line = ('[skills] player %d: base-game development maxed on their client'):format(source)
		Open77.log.info(line)
	else
		line = ('[skills] player %d: base-game development refused on their client: %s')
			:format(source, safe(why ~= nil and why or 'refused'))
		Open77.log.warn(line)
	end
	OPX.Audit.Log({
		event = 'skills.develop',
		severity = ok == true and 'info' or 'warn',
		message = line,
		source = source,
		data = { citizenId = pending.citizenId },
	})
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the index from config. Never yields.
-- @author XEROX710
function M.Init()
	records, dirty = {}, {}
	index = {}
	developing, developCount = {}, 0
	chromeNamed = false

	local problems = {}
	local seen = {}
	local trunks = {}
	for _, branch in ipairs(M.Skill.Branches()) do
		if type(branch.id) ~= 'string' or branch.id == '' then
			problems[#problems + 1] = 'a branch has no id and is ignored'
		else
			if trunks[branch.id] then
				problems[#problems + 1] = ('branch %q is declared twice'):format(branch.id)
			end
			trunks[branch.id] = true
			if branch.ICON ~= nil and iconOf(branch) == nil then
				problems[#problems + 1] = ('branch %q names ICON %q, which the shared glyph set does not draw')
					:format(branch.id, tostring(branch.ICON))
			end
			local list = type(branch.NODES) == 'table' and branch.NODES or {}
			if #list == 0 then
				problems[#problems + 1] = ('branch %q declares no nodes'):format(branch.id)
			end
			for rankOf = 1, #list do
				local node = list[rankOf]
				if type(node.id) ~= 'string' or node.id == '' then
					problems[#problems + 1] = ('branch %q node %d has no id'):format(branch.id, rankOf)
				elseif seen[node.id] then
					problems[#problems + 1] = ('node %q is declared twice'):format(node.id)
				else
					seen[node.id] = true
					index[node.id] = { branch = branch.id, rankOf = rankOf, node = node }
				end
			end
		end
	end
	if M.Skill.BranchOf('a-job-no-trunk-named') == nil then
		problems[#problems + 1] = 'no trunk declares itself the catch-all, so unnamed jobs earn nothing'
	end
	for _, line in ipairs(problems) do Open77.log.warn('[skills] config: ' .. line) end

	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the skills contract.
-- The perks are DATA and this is the seam that reads them: a gameplay system
-- that wants a rating asks here, and the answer is the sum of what the
-- character's unlocked nodes actually declare.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('skills', 1, {
		--- Credits job work to a character by hand (a bonus a system invented).
		-- @param citizenId string
		-- @param jobName string
		-- @param points number
		Award = function(citizenId, jobName, points)
			if type(citizenId) ~= 'string' or citizenId == '' then
				return Result.Err('skills.noCharacter', tostring(citizenId))
			end
			local credited = finite(points) or 0.0
			if credited <= 0 then return Result.Err('skills.failed', tostring(points)) end
			earn(citizenId, jobName, credited)
			local record = recordOf(citizenId)
			return Result.Ok({ level = record.level, xp = record.xp, points = record.points })
		end,

		--- One perk's rating as this character holds it: zero until a node that
		-- declares it is claimed.
		-- @param citizenId string
		-- @param perkId string
		Perk = function(citizenId, perkId)
			local record = type(citizenId) == 'string' and records[citizenId] or nil
			if record == nil or type(perkId) ~= 'string' then return 0 end
			local total = 0
			for id in pairs(record.nodes) do
				local entry = index[id]
				if entry ~= nil and entry.node.PERK == perkId then
					total = total + (finite(entry.node.VALUE) or 0)
				end
			end
			return total
		end,

		--- A character's level and the cap it climbs to, as two whole numbers:
		-- what the ripperdoc scales chrome by. A citizen with no ledger is a
		-- level-1 character -- the same answer the knock gives.
		-- @param citizenId string
		-- @return integer level
		-- @return integer cap
		Level = function(citizenId)
			local cap = M.Skill.Cap()
			local record = type(citizenId) == 'string' and records[citizenId] or nil
			if record == nil then return 1, cap end
			return math.max(1, math.min(math.floor(finite(record.level) or 1), cap)), cap
		end,

		--- The whole tree, as `frameOf` draws it.
		-- @param citizenId string
		State = function(citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then
				return Result.Err('skills.noCharacter', tostring(citizenId))
			end
			return Result.Ok(frameOf(citizenId))
		end,

		--- XP owed between one character level and the next.
		XpFor = function(level) return M.Skill.Need(level) end,
	})
end

--- Wires the funnel and the two doors, and loads what the database holds.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')

	-- THE HOOK. The jobs bank's `pay` is the one funnel every credit passes
	-- through, and it says what it actually credited; this is the whole of the
	-- integration, deliberately one subscription rather than a reach inside
	-- jobs' ladder, clamp or write-back.
	local jobs = OPX.Modules.Get('jobs')
	if jobs ~= nil and type(jobs.Event) == 'table' and jobs.Event.PAID ~= nil then
		AddEventHandler(jobs.Event.PAID, function(citizenId, jobName, credited)
			local ran, failure = pcall(earn, tostring(citizenId or ''), jobName, credited)
			if not ran then
				Open77.log.error('[skills] the funnel broke: ' .. tostring(failure))
			end
		end)
	else
		Open77.log.warn('[skills] no jobs funnel is listening; the tree can only be fed by hand')
	end

	-- The knock: the whole tree, or the one sentence saying why not.
	RegisterNetEvent(M.Event.ASK, function()
		-- The sender is the host's `source` global; a `source` parameter
		-- here shadowed it with the empty payload (the scanner's own bug).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local data, citizenId, why = dataOf(source)
		if data == nil then
			Open77.log.warn(('[skills] %s knocked and could not be read: %s')
				:format(tostring(source), tostring(why)))
			TriggerClientEvent(M.Event.STATE, source, { open = false, reason = 'noCharacter' })
			return
		end
		TriggerClientEvent(M.Event.STATE, source, frameOf(citizenId))
	end)

	-- The one intent. Every answer is a fresh frame -- a refusal rides on it as
	-- `refused`, so the panel refreshes and the words come from the one table.
	RegisterNetEvent(M.Event.SPEND, function(nodeId)
		-- The sender is the host's `source` global; `nodeId` is the first
		-- payload, not the second parameter behind a phantom source.
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local data, citizenId, why = dataOf(source)
		if data == nil then
			Open77.log.warn(('[skills] %s spent and could not be read: %s')
				:format(tostring(source), tostring(why)))
			TriggerClientEvent(M.Event.STATE, source, { open = false, reason = 'noCharacter' })
			return
		end
		local claimed, refusal = unlock(citizenId, nodeId)
		local frame = frameOf(citizenId)
		if not claimed then frame.refused = refusal end
		TriggerClientEvent(M.Event.STATE, source, frame)
	end)

	-- What the player's machine did with a base-game develop request.
	RegisterNetEvent(M.Event.DEVELOPED, function(nonce, ok, why)
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		developed(source, nonce, ok, why)
	end)

	-- The staff lever. Restricted: the host asks the ACL for `command.<name>`
	-- before the handler runs. Unnamed in config is unregistered.
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
	if type(names.level) == 'string' and names.level ~= '' then
		OPX.Command.Register(names.level, {
			restricted = true,
			help = 'skills.help.level',
			params = {
				{ name = 'level', help = 'skills.help.levelValue' },
				{ name = 'playerId', optional = true, help = 'skills.help.levelPlayer' },
			},
		}, levelCommand)
	end

	-- What the database already holds. The knock needs no record to answer, so
	-- this load may land late without a player ever noticing.
	CreateThread(function()
		local read, result = pcall(Store.FetchAll)
		if not read or type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table' then
			Open77.log.warn('[skills] the stored trees could not be read')
			return
		end
		for _, row in ipairs(result.value) do
			local citizenId = row.citizen_id
			if type(citizenId) == 'string' and citizenId ~= '' then
				local nodes = {}
				for id in string.gmatch(type(row.nodes) == 'string' and row.nodes or '', '[^,]+') do
					if index[id] ~= nil then nodes[id] = true end
				end
				local fed = {}
				for pair in string.gmatch(type(row.branches) == 'string' and row.branches or '', '[^;]+') do
					local id, earned = pair:match('^([^:]+):(.+)$')
					local amount = finite(earned)
					if type(id) == 'string' and id ~= '' and amount ~= nil then fed[id] = amount end
				end
				records[citizenId] = {
					xp = finite(row.xp) or 0.0,
					level = math.max(1, math.floor(finite(row.level) or 1)),
					points = math.max(0, math.floor(finite(row.points) or 0)),
					nodes = nodes,
					branches = fed,
				}
			end
		end
	end)
end

--- Takes the module down: whatever changed is written before the lights go.
-- @author XEROX710
function M.Stop()
	local pending = {}
	for citizenId in pairs(dirty) do pending[#pending + 1] = citizenId end
	CreateThread(function()
		for _, citizenId in ipairs(pending) do
			local record = records[citizenId]
			if record ~= nil then
				dirty[citizenId] = nil
				Store.Upsert(citizenId, record, nodesColumn(record), branchesColumn(record))
			end
		end
	end)
end
