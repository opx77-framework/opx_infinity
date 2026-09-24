--- The employment office: a sign-up board, a seniority ladder, and a boss's desk.
-- @author XEROX710
--
-- A JOB IS NOT INVENTED HERE. `config/character.lua` defines every job, its
-- grades and what each grade pays and is called; the character module stores a
-- character's memberships, replicates them, gates elevators, armouries and
-- teleports with them and already answers `/opx.job`, `/opx.duty` and
-- `/opx.group`. This module decides the three things that catalogue has no field
-- for:
--
--   * WHERE a job is joined -- a sign-up board a player stands on, press the
--     key, read the work and take it;
--   * WHO may join it -- the terms in `JOBS` (`OPEN`, `APPROVAL`, `REQUIRES`),
--     re-derived on the server at the moment of joining and never trusted from
--     the menu a client drew;
--   * HOW LONG the next rank takes -- a seniority ladder, banked while on duty.
--
-- THE RANK ITSELF IS THE CHARACTER MODULE'S. Every promotion here goes through
-- the `character` contract (`SetJob`/`AddPlayerToJob`), so a rank gained at a
-- board is the same rank an operator grants with `/opx.job`, arrives on the same
-- client event, and is read by every gate that already reads a job. Nothing in
-- this module writes `PlayerData` and nothing keeps a second copy of who works
-- where: the roster comes from `GetGroupMembers`, the boss question from the
-- grade's own `isBoss` flag in the catalogue.
--
-- THE SENIORITY BANK IS THE ONE THING THIS MODULE OWNS, because it is the only
-- thing about a job that is not already stored: how long somebody has worked it.
-- It lives in its own table, is written back on a cadence and on shutdown, and
-- is fed by one tick that pays every eligible holder -- see
-- `modules/jobs/server/main.lua`.
--
-- `character` is REQUIRED on both halves. On the server it is the only thing
-- that can answer who holds what; on the client it is where the player's own job
-- is read from, and a client without it draws a board that cannot say whether
-- the player already works there.
--
-- `prompts` is optional: without it the boards still draw and the key still
-- works, and only the strip row is missing.

local M = OPX.Modules.Declare{
	id = 'jobs',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'prompts', 'menu' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection:
	-- a join is always FOR the player who asked, never for a citizen id a client
	-- names.
	ASK = OPX.Event(NET, 'jobs', 'ask'),
	DETAIL = OPX.Event(NET, 'jobs', 'detail'),
	JOIN = OPX.Event(NET, 'jobs', 'join'),
	LEAVE = OPX.Event(NET, 'jobs', 'leave'),
	BOSS = OPX.Event(NET, 'jobs', 'boss'),
	CAPTURED = OPX.Event(NET, 'jobs', 'captured'),

	-- Server to client: the boards this player may see, the verdict for ONE board
	-- they are standing on, the roster of a desk (its own event, because the
	-- roster is a query and the sync may not yield), and the ask to capture where
	-- a player is standing.
	--
	-- `state` is its own event because the client's decode window is small: a
	-- marker is nine flat values, a board's verdict is a tree of them, and a
	-- payload over the window is dropped whole and in silence (Access.CEILING).
	STATE = OPX.Event(NET, 'jobs', 'state'),
	SYNC = OPX.Event(NET, 'jobs', 'sync'),
	ANSWER = OPX.Event(NET, 'jobs', 'answer'),
	ROSTER = OPX.Event(NET, 'jobs', 'roster'),
	CAPTURE = OPX.Event(NET, 'jobs', 'capture'),

	-- Server-local, and the module's one door outward: every point `pay`
	-- ACTUALLY credits -- tick wages and `Award` arrests alike -- leaves on it,
	-- with the citizen, the job and the credited delta. The skill tree listens
	-- here rather than re-measuring work or reaching into the ladder.
	PAID = OPX.Event(LOCAL, 'jobs', 'paid'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included, so a HUD or a job resource can hear one without asking. Public:
	-- a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'jobs', 'decision'),
}

--- Which request a refusal answers. Passed to `OPX.Refuse`: without it a client
--- waiting on one of several requests cannot tell which `error.tooFast` is its
--- own.
M.Operation = {
	JOIN = 'jobsJoin',
	LEAVE = 'jobsLeave',
	BOSS = 'jobsBoss',
	CAPTURE = 'jobsCapture',
}

--- The host raises this when a player rebinds or resets a mapping.
M.KEYBINDS_CHANGED = 'onKeybindsChanged'

--- The two kinds of board. A sign-up board offers work, a desk manages it.
M.KIND = { SIGNUP = 'signup', BOSS = 'boss' }

--- What a boss may do to one member. The vocabulary is shared with the client
--- so a menu row and the server handler cannot disagree about a spelling.
M.ACTION = { PROMOTE = 'promote', DEMOTE = 'demote', FIRE = 'fire', HIRE = 'hire' }

--- The three job actions a desk offers per member, in the order a member's own
--- screen lists them. `HIRE` is not in it: hiring acts on somebody who does not
--- hold the job yet, so it is the desk's own row rather than a member's.
M.DESK_ORDER = { M.ACTION.PROMOTE, M.ACTION.DEMOTE, M.ACTION.FIRE }
