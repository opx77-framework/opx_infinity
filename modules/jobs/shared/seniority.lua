--- The ladder arithmetic: what a bank of seniority is worth, and what is next.
-- @author XEROX710
--
-- PURE, AND DELIBERATELY SO. No clock of its own, no config read, no module
-- namespace, no world: a ladder and a number go in, a grade and a fraction come
-- out. That is what lets the suite drive every branch of a promotion -- a bank
-- one point under a rank, one over it, a ladder with a gap in it, a grade at the
-- top of a career -- without a server, a database or a player.
--
-- A LADDER IS CONTIGUOUS AND LEVEL 0 IS FREE. `LADDER = { [1] = 90, [2] = 360 }`
-- means rank 1 is held from 90 points of worked time and rank 2 from 360, and
-- the grade a character starts at costs nothing. A ladder with a hole in it --
-- `{ [1] = 90, [3] = 900 }` -- is not "a rank nobody can reach", it is a
-- configuration that would promote somebody into a grade number the job may not
-- even define, so it is refused where it is read (`Access.Problems`) rather than
-- here, and every function below answers for the levels it was given.
--
-- THE BANK IS A NUMBER OF POINTS AND NOT A TIME. Who pays them, and how often,
-- is the server's own business: the shipped tick pays one a minute while on
-- duty. Keeping that out of here means a job can be made to pay for arrests, for
-- deliveries or for a shift's length without touching the arithmetic that turns
-- a bank into a rank.

local M = OPX.Modules.Get('jobs')

M.Seniority = {}
local Seniority = M.Seniority

--- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
--- `OPX.Text.Finite`, which also caps at 2^53: this measures a bank of minutes
--- and a fraction of a rank.
-- @param value any
-- @return number|nil
Seniority.Finite = OPX.Math.Finite

--- The highest level a ladder defines.
-- A ladder with a hole is walked to the first missing level, so a caller that
-- somehow holds one still gets the ranks it really has rather than a raise.
-- @param ladder table|nil
-- @return integer zero when the ladder is empty or not a table
function Seniority.Top(ladder)
	if type(ladder) ~= 'table' then return 0 end
	local top = 0
	while Seniority.Finite(ladder[top + 1]) ~= nil do top = top + 1 end
	return top
end

--- The points one level wants, or nil for a level the ladder does not define.
-- @param ladder table|nil
-- @param level any
-- @return number|nil
function Seniority.Required(ladder, level)
	local index = tonumber(level)
	if index == nil or index % 1 ~= 0 or index < 1 then return nil end
	if type(ladder) ~= 'table' then return nil end
	local wanted = Seniority.Finite(ladder[index])
	if wanted == nil or wanted < 0 then return nil end
	return wanted
end

--- The ceiling a bank is held under, so a ladder that never ends cannot run away
--- with the number. Nil when the config names no ceiling, which reads as "no
--- ceiling" rather than as zero.
-- @param bank any
-- @param ceiling any
-- @return number not below zero
function Seniority.Clamp(bank, ceiling)
	local points = Seniority.Finite(bank) or 0.0
	if points < 0.0 then points = 0.0 end
	local limit = Seniority.Finite(ceiling)
	if limit ~= nil and limit > 0.0 and points > limit then points = limit end
	return points
end

--- The grade a bank has earned on a ladder.
--
-- Walked from level 1 upwards and stopped at the first level the bank does not
-- reach, so a grade is always a rank the ladder and the catalogue both define --
-- never a number derived from a division.
-- @param ladder table|nil
-- @param bank any
-- @return integer
function Seniority.GradeFor(ladder, bank)
	local points = Seniority.Clamp(bank, nil)
	local grade = 0
	local top = Seniority.Top(ladder)
	while grade < top do
		local wanted = Seniority.Required(ladder, grade + 1)
		if wanted == nil or points < wanted then break end
		grade = grade + 1
	end
	return grade
end

--- The level after this one, or nil at the top of the ladder.
-- @param ladder table|nil
-- @param grade any
-- @return integer|nil
function Seniority.NextLevel(ladder, grade)
	local current = tonumber(grade) or 0
	if current % 1 ~= 0 or current < 0 then return nil end
	local candidate = current + 1
	if Seniority.Required(ladder, candidate) == nil then return nil end
	return candidate
end

--- How far a bank has come towards the next rank.
--
-- Answers nil for a character already at the top of a ladder, which is not the
-- same as zero progress and is why it is nil and not a table of zeroes: a
-- finished career has no next rank to be six per cent of the way to.
-- @param ladder table|nil
-- @param grade any the grade currently held
-- @param bank any
-- @return table|nil `{ from, to, points, fraction }`
function Seniority.Progress(ladder, grade, bank)
	local current = tonumber(grade) or 0
	local nextLevel = Seniority.NextLevel(ladder, current)
	if nextLevel == nil then return nil end

	local from = Seniority.Required(ladder, current) or 0.0
	local to = Seniority.Required(ladder, nextLevel)
	if to == nil or to <= from then return nil end

	local points = Seniority.Clamp(bank, nil)
	local fraction = (points - from) / (to - from)
	if fraction < 0.0 then fraction = 0.0 end
	if fraction > 1.0 then fraction = 1.0 end
	return { from = from, to = to, level = nextLevel, points = points, fraction = fraction }
end

--- The points a bank needs for one level, counting what is already in it.
-- Used by the roster, where "how much longer" is the only useful form of the
-- number: a member reading 240/360 wants to know the difference, not the total.
-- @param ladder table|nil
-- @param level any
-- @param bank any
-- @return number the shortfall, never below zero; nil when the level is not one
function Seniority.Shortfall(ladder, level, bank)
	local wanted = Seniority.Required(ladder, level)
	if wanted == nil then return nil end
	local remaining = wanted - Seniority.Clamp(bank, nil)
	if remaining < 0.0 then remaining = 0.0 end
	return remaining
end
