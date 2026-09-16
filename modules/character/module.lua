--- Users, characters, groups, money and the roster: everything that outlives a
--- session.
-- @author dop42
--
-- Fatal, because nothing else has a state to read without it: a job board, an
-- inventory and a vehicle all name a character, and there is no character here
-- to name.
--
-- Two ideas run through the whole module and are worth having before reading it.
--
-- 1. A SESSION is a connected machine and a PLAYER is a loaded character. Someone
--    at the selection screen has a session and no player. Every caller that
--    confuses the two either refuses a legitimate connection or trusts a
--    character that was never loaded. Sessions belong to core; the roster of
--    loaded characters belongs here.
-- 2. THERE IS NO EXISTENCE ORACLE. Somebody else's character answers exactly the
--    same code as a character that does not exist (`character.notFound`).
--    Answering "not yours" would tell an attacker the id is real. The attempt is
--    written to the audit log instead.

local M = OPX.Modules.Declare{
	id = 'character',
	side = 'both',
	fatal = true,
}

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (see core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` would
-- otherwise re-enter the `RegisterNetEvent` handler of the same name. A verb may
-- therefore repeat across channels -- NET `loaded` and LOCAL `loaded` are two
-- different names -- but never within one.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL
local INTERNAL = OPX.Channel.INTERNAL

M.Event = {
	-- Server to client. A listener holds `network.events` and uses RegisterNetEvent.
	LOADED = OPX.Event(NET, 'character', 'loaded'),
	UNLOADED = OPX.Event(NET, 'character', 'unloaded'),
	DATA = OPX.Event(NET, 'character', 'data'),
	MONEY = OPX.Event(NET, 'character', 'money'),
	JOB = OPX.Event(NET, 'character', 'job'),
	GANG = OPX.Event(NET, 'character', 'gang'),
	ROSTER = OPX.Event(NET, 'character', 'roster'),

	-- Client to server. Every payload is attacker-controlled; only `source` is not.
	ANNOUNCE = OPX.Event(NET, 'character', 'announce'),
	SELECT = OPX.Event(NET, 'character', 'select'),
	CREATE = OPX.Event(NET, 'character', 'create'),
	DELETE = OPX.Event(NET, 'character', 'delete'),
	HEADING = OPX.Event(NET, 'character', 'heading'),

	-- The client's own bus, raised after the mirror is updated so that a handler
	-- reading the contract sees the change. Public: a bare AddEventHandler.
	ON_LOADED = OPX.Event(LOCAL, 'character', 'loaded'),
	ON_UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded'),
	ON_CHANGED = OPX.Event(LOCAL, 'character', 'changed'),
	ON_MONEY = OPX.Event(LOCAL, 'character', 'money'),
	ON_JOB = OPX.Event(LOCAL, 'character', 'job'),
	ON_GANG = OPX.Event(LOCAL, 'character', 'gang'),
	ON_ROSTER = OPX.Event(LOCAL, 'character', 'roster'),

	-- Between modules inside one VM. Never crosses the wire.
	IN_LOADED = OPX.Event(INTERNAL, 'character', 'loaded'),
	IN_UNLOADED = OPX.Event(INTERNAL, 'character', 'unloaded'),
	IN_MONEY = OPX.Event(INTERNAL, 'character', 'money'),
	IN_JOB = OPX.Event(INTERNAL, 'character', 'job'),
	IN_GANG = OPX.Event(INTERNAL, 'character', 'gang'),
	IN_DELETED = OPX.Event(INTERNAL, 'character', 'deleted'),
	IN_PAYCHECK = OPX.Event(INTERNAL, 'character', 'paycheck'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`, whose channel is core's: without it a client waiting on
-- one of several requests cannot tell which `error.tooFast` is its own.
M.Operation = {
	ENTRY = 'entry',
	ROSTER = 'roster',
	SELECT = 'select',
	CREATE = 'create',
	DELETE = 'delete',
}

-- The three helpers below are here rather than in one half because both halves
-- need the same answer from them: a name the client accepts and the server
-- refuses is a form that fails after the player has filled it in.

--- The pattern each half of a character name must match.
-- A letter is described by a byte range rather than `%a`, which is ASCII only and
-- would refuse "Eloise" spelled properly. Four-byte lead bytes are excluded:
-- that is where the emoji live.
local LETTER = '%a\194-\239\128-\191'
M.NAME_PATTERN = ("^[%s][%s '%%-]*$"):format(LETTER, LETTER)

--- Validates one half of a character name against the configured bounds.
-- @author dop42
-- @param value any
-- @return Result
function M.ValidateName(value)
	local bounds = M.Settings.CHARACTERS.NAME
	return OPX.Validate.Text(value, {
		min = bounds.MIN,
		max = bounds.MAX,
		pattern = M.NAME_PATTERN,
	})
end

--- Reads a configured number with a floor.
-- The floor is also the answer for a setting that is missing or not a finite
-- number, so that no caller ever compares a number against nil. The test is
-- finiteness and not `value ~= value`: an infinity passes a NaN test and would
-- freeze an interval. This is where a live tunables service plugs in.
-- @author dop42
-- @param value any
-- @param floor number
-- @return number
function M.Number(value, floor)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return floor end
	if floor and value < floor then return floor end
	return value
end
