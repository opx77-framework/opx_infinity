--- The skill tree: a character levels up from working jobs, and the points buy
-- a path down the trunk that work fed.
-- @author XEROX710
--
-- WHAT THIS IS FOR. Jobs measure work (the seniority bank), the engine measures
-- heat, and nothing measured the CHARACTER -- how far this body has come from
-- the day it arrived in Night City. This module is that ledger, drawn as a
-- tree: seven trunks (the NCPD, MaxTac, the corps, the nomads, the street, the
-- ripperdocs and -- at the top -- the fixers), five nodes up each, every node a
-- claim the work has to reach before a point may buy it. The trunks are
-- config (`config/skills.lua` BRANCHES): nothing in the module counts them.
--
-- THE FUNNEL IS THE JOBS BANK'S OWN. `modules/jobs/server/main.lua`'s `pay` is
-- the single place a job's work is ever credited -- the tick's wages and
-- `jobs.Award`'s arrests and deliveries both pass through it -- and it says so
-- on `jobs.Event.PAID` with what was ACTUALLY credited after the bank's own
-- clamp. This module never re-measures work and never reaches inside jobs: it
-- listens at the funnel and keeps its own book. The tick and the award are the
-- same source on purpose: a shift is work, an arrest is work, and a tree that
-- only counted one of them would be a picture of half a career.
--
-- TWO HALVES, ONE ANSWER EACH (the README's own shape). The server owns every
-- number: how much XP a credit bought, which level that crossed, which nodes a
-- point may unlock. The client holds no arithmetic at all -- it asks, it draws
-- the frame the server answered with, and a press is an INTENT the server
-- either honours or refuses in a fresh frame. A page that computed its own
-- tree would be a second authority over one fact, and the two would drift the
-- first time a clamp moved.
--
-- THE PERKS ARE DATA. `M.Skill.Perk` sums what the unlocked nodes declare; no
-- gameplay system in this repo reads it yet, and that is the seam, not a gap
-- papered over: a system that wants the value asks for it, and until one does,
-- the tree still fills, ranks and persists truthfully.

local M = OPX.Modules.Declare{
	id = 'skills',
	side = 'both',
	-- The hook is onto `jobs`, and a server without jobs simply has no funnel
	-- to listen at: the tree exists, the API awards, and nothing credits it.
	fatal = false,
	optional = { 'jobs' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Client to server: the knock, and the one intent the tree has.
	ASK = OPX.Event(NET, 'skills', 'ask'),
	SPEND = OPX.Event(NET, 'skills', 'spend'),

	-- Server to client, one player at a time: the whole truth in one frame, and
	-- a line of news when the ledger moves.
	STATE = OPX.Event(NET, 'skills', 'state'),
	GAIN = OPX.Event(NET, 'skills', 'gain'),

	-- Server to client: somebody else moved this character's ledger (an admin
	-- level change). It carries the sentence to toast, and an OPEN tree
	-- re-asks for its frame -- a closed one stays closed.
	REFRESH = OPX.Event(NET, 'skills', 'refresh'),

	-- The base game's own levels, maxed on the player's machine: the server
	-- asks (`develop`, with a nonce), the client runs the preload's export and
	-- reports what it answered (`developed`), and the server journals it.
	DEVELOP = OPX.Event(NET, 'skills', 'develop'),
	DEVELOPED = OPX.Event(NET, 'skills', 'developed'),

	-- Client-local: what the state half says the page should draw.
	SKILL_VIEW = OPX.Event(LOCAL, 'skills', 'view'),
}

-- The two namespaces the module's own files fill. Created here, beside each
-- other, so no file has to index a table that does not exist yet (the namespace
-- is owned in one place).
M.Skill = {}
M.SkillView = {}

-- The key, in the same shape as the scanner's and the crew door's: the id is
-- stable because a player's rebind is stored under it. THE SHIPPED DEFAULT,
-- and nothing more -- `KEY` in `config/skills.lua` is the operator's answer
-- and wins whenever it is a usable block.
M.Skill.KEY = { ID = 'opx.skills.tree', NAME = 'skills.key.tree', DEFAULT = 'F4' }

--- The key declaration the operator configured, or the shipped one.
--
-- Read on every ask rather than captured once, the same reason `M.Skill.Branches`
-- resolves on every read: config is live, and a block an operator fixed must
-- take effect without a code change. A `KEY` block that is not one -- no ID or
-- no NAME, or a DEFAULT that is neither a key name nor `false` -- falls back to
-- the declaration above rather than leaving the tree unreachable.
-- @return table `{ ID, NAME, DEFAULT }`
function M.Skill.KeySettings()
	local declared = type(M.Settings) == 'table' and type(M.Settings.KEY) == 'table'
		and M.Settings.KEY or nil
	if declared ~= nil
		and type(declared.ID) == 'string' and declared.ID ~= ''
		and type(declared.NAME) == 'string' and declared.NAME ~= '' then
		local default = declared.DEFAULT
		if default == false or (type(default) == 'string' and default ~= '') then
			return { ID = declared.ID, NAME = declared.NAME, DEFAULT = default }
		end
	end
	return M.Skill.KEY
end

-- ONE TABLE, TWO READERS, exactly as `M.Radio.Refusal` is: the server refuses
-- with a code, a player reads a sentence, and the map between them lives here
-- so the toast and the panel say the same thing in the same words. A code this
-- table has not heard of names itself rather than going blank.
M.Skill.Refusal = {
	noCharacter = 'skills.noCharacter',
	noNode = 'skills.noNode',
	noPoints = 'skills.noPoints',
	prereq = 'skills.prereq',
	rank = 'skills.rank',
	unlocked = 'skills.unlocked',
	failed = 'skills.failed',
}

--- The tree as the config declares it.
-- Resolved when it is read and never captured (see `OPX.Modules.Settings`).
-- @return table the BRANCHES array, never nil
function M.Skill.Branches()
	return type(M.Settings.BRANCHES) == 'table' and M.Settings.BRANCHES or {}
end

--- The trunk a job's work feeds: the trunk that names the job, or the trunk
-- that names none (the street's catch-all). Nil only when no catch-all exists.
-- @param jobName string|nil
-- @return string|nil branch id
function M.Skill.BranchOf(jobName)
	local catchAll = nil
	for _, branch in ipairs(M.Skill.Branches()) do
		local jobs = branch.JOBS
		if type(jobs) == 'table' then
			if jobs[jobName] == true then return branch.id end
		elseif catchAll == nil then
			catchAll = branch.id
		end
	end
	return catchAll
end

--- How much XP stands between one character level and the next.
-- @param level integer
-- @return number
function M.Skill.Need(level)
	local step = tonumber(M.Settings.LEVEL_STEP) or 100
	return step * math.max(1, tonumber(level) or 1)
end

--- The rank a trunk's chain stands at, given what has been fed into it.
-- Rank 1 is the first node and needs nothing; each rank after it is one
-- `BRANCH_STEP` of that trunk's own work deeper.
-- @param earned number XP fed to this trunk
-- @return integer rank, at least 1
function M.Skill.Rank(earned)
	local step = tonumber(M.Settings.BRANCH_STEP) or 100
	if step <= 0 then return 1 end
	return 1 + math.floor(math.max(0, tonumber(earned) or 0) / step)
end

--- The deepest rank any trunk declares, so the rank readouts can be cut.
-- @return integer
function M.Skill.Depth()
	local deepest = 0
	for _, branch in ipairs(M.Skill.Branches()) do
		local nodes = type(branch.NODES) == 'table' and #branch.NODES or 0
		if nodes > deepest then deepest = nodes end
	end
	return deepest
end

--- The character level cap: a whole number, at least 1. One reader, so the
--- ledger, the frame, the admin lever and the API all stop at the same top.
-- @return integer
function M.Skill.Cap()
	local cap = OPX.Math.Finite(M.Settings.LEVEL_CAP)
	if cap == nil then return 20 end
	return math.max(1, math.floor(cap))
end

--- The points a character has banked by reaching `level`: one grant per level
--- crossed, so level 1 has banked nothing.
-- @param level integer
-- @return integer
function M.Skill.Banked(level)
	local per = math.max(1, math.floor(tonumber(M.Settings.POINTS_PER_LEVEL) or 1))
	return math.max(0, math.floor(tonumber(level) or 1) - 1) * per
end

--- The base game's develop request as the config sets it, or nil when it is
--- turned off (`DEVELOP.RESOURCE = false`) or not a block at all.
-- @return table|nil `{ RESOURCE, EXPORT, CODE }`
function M.Skill.DevelopSettings()
	local block = type(M.Settings.DEVELOP) == 'table' and M.Settings.DEVELOP or nil
	if block == nil or type(block.RESOURCE) ~= 'string' or block.RESOURCE == '' then return nil end
	local export = type(block.EXPORT) == 'string' and block.EXPORT ~= '' and block.EXPORT or 'develop'
	local code = OPX.Math.Finite(block.CODE) or 10
	return { RESOURCE = block.RESOURCE, EXPORT = export, CODE = math.floor(code) }
end

--- What the panel's chrome band draws, and nothing else: four finite numbers
--- and three pairs of them (the page's contract, `ui/src/modules/skills`). A
--- NUMBER, and only one: the contract is numbers, so a numeric string is
--- refused here rather than coerced the way `OPX.Math.Finite` would.
-- @param value any
-- @return number|nil
local function finiteNumber(value)
	if type(value) ~= 'number' then return nil end
	return OPX.Math.Finite(value)
end

--- `ripperdoc.ChromeLevel`'s answer, kept only when it is EXACTLY the shape the
--- panel draws. Anything else answers nil and why: a band drawn from a
--- half-understood table would state numbers nobody sent. The copy carries the
--- seven contract fields and nothing more, so what reaches the wire is the
--- contract whatever else the answer held.
-- @param value any
-- @return table|nil a fresh copy
-- @return string|nil why not
function M.Skill.ChromeShape(value)
	if type(value) ~= 'table' then return nil, 'not a table' end
	local out = {}
	for _, field in ipairs({ 'lifeDays', 'lifeBaseDays', 'lifeMaxDays', 'wearDays' }) do
		local number = finiteNumber(value[field])
		if number == nil then return nil, field .. ' is not a finite number' end
		out[field] = number
	end
	for _, field in ipairs({ 'activeSeconds', 'activeBaseSeconds', 'activeMaxSeconds' }) do
		local pair = value[field]
		if type(pair) ~= 'table' or #pair ~= 2 then return nil, field .. ' is not a pair' end
		local lo, hi = finiteNumber(pair[1]), finiteNumber(pair[2])
		if lo == nil or hi == nil then return nil, field .. ' is not a pair of finite numbers' end
		out[field] = { lo, hi }
	end
	return out
end
