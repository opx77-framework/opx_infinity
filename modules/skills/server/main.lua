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

--- The character a connection has loaded, as the character contract sees it.
-- @param source number
-- @return table|nil PlayerData
local function dataOf(source)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, player = pcall(character.GetPlayer, source)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' or type(data.citizenId) ~= 'string' then return nil end
	return data
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
			local data = dataOf(source)
			if data ~= nil and data.citizenId == citizenId then fn(source) end
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

--- The one frame every answer sends: the whole tree as this record stands.
-- Never refused on its own -- a knock from a character with no record is a
-- tree of zeroes -- so the panel can always draw somebody.
-- @param citizenId string
-- @return table
local function frameOf(citizenId)
	local record = records[citizenId]
	local level = record ~= nil and record.level or 1
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
		xp = record ~= nil and record.xp or 0.0,
		need = M.Skill.Need(level),
		points = record ~= nil and record.points or 0,
		depth = M.Skill.Depth(),
		branches = branches,
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

	local cap = math.max(1, math.floor(finite(M.Settings.LEVEL_CAP) or 20))
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

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the index from config. Never yields.
-- @author XEROX710
function M.Init()
	records, dirty = {}, {}
	index = {}

	local problems = {}
	local seen = {}
	for _, branch in ipairs(M.Skill.Branches()) do
		if type(branch.id) ~= 'string' or branch.id == '' then
			problems[#problems + 1] = 'a branch has no id and is ignored'
		else
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
		local data = dataOf(source)
		if data == nil then
			TriggerClientEvent(M.Event.STATE, source, { open = false, reason = 'noCharacter' })
			return
		end
		TriggerClientEvent(M.Event.STATE, source, frameOf(data.citizenId))
	end)

	-- The one intent. Every answer is a fresh frame -- a refusal rides on it as
	-- `refused`, so the panel refreshes and the words come from the one table.
	RegisterNetEvent(M.Event.SPEND, function(nodeId)
		-- The sender is the host's `source` global; `nodeId` is the first
		-- payload, not the second parameter behind a phantom source.
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local data = dataOf(source)
		if data == nil then
			TriggerClientEvent(M.Event.STATE, source, { open = false, reason = 'noCharacter' })
			return
		end
		local claimed, refusal = unlock(data.citizenId, nodeId)
		local frame = frameOf(data.citizenId)
		if not claimed then frame.refused = refusal end
		TriggerClientEvent(M.Event.STATE, source, frame)
	end)

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
