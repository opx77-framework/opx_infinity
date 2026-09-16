--- The first screen: the character roster and the creation flow, on one stage.
-- @author dop42
--
-- Two resources used to share this one screen. `opx77_charselector` held the
-- roster and owned the camera; `opx77_charcreator` drew the form and BORROWED
-- the camera through a hold-and-release pair of exports, because a camera handed
-- between two resources is a camera that jumps. Selection and creation are one
-- flow with one stage, so they are one module, and the hand-over that made the
-- seam awkward is gone with the seam.
--
-- Three ideas run through the whole module.
--
-- 1. THE SCREEN IS DRAWN IN THE GAMEPLAY WORLD AND NOWHERE ELSE. The platform
--    raises `open77:worldReady` for the pre-game menu world too, and a screen
--    drawn there sits under the loading cover with the player's controls locked
--    behind it. Only `Open77.session.characterBootstrap().phase == 'ready'` tells
--    the two apart, and even that is not enough on its own: just after the
--    bootstrap resolves, the menu's puppet still answers attached and alive.
-- 2. A REFUSAL IS BRANCHED ON THE OPERATION IT ANSWERS, NEVER ON ITS CODE.
--    `error.tooFast` is raised by every request the server rate limits, and a
--    screen that read the code alone would take a vehicle exit's refusal for its
--    own.
-- 3. THE PAGE SENDS INTENTS. It reports which card was chosen; this module calls
--    the character contract and waits for the event. Nothing the page computes
--    is a fact, including the validation it never does: every rule is here, and
--    every rule here is the server's, repeated.

local M = OPX.Modules.Declare{
	id = 'entry',
	side = 'client',
	-- The roster, the selection and the registration are all the character
	-- contract's; there is no screen to draw without it.
	requires = { 'character' },
	-- The face editor. A character with no face enters on the default one when it
	-- is absent, which is what the platform does anyway.
	optional = { 'appearance' },
	fatal = false,
}

local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises.
-- One line on the client's public bus, so that anything at all can tell whether
-- the player is still choosing. It must stay on the LOCAL channel: the host
-- dispatcher matches on the name alone, and a local raise on a NET name would
-- re-enter that name's network handler.
M.Event = {
	ON_STATE = OPX.Event(LOCAL, 'entry', 'state'),
}

--- Host-owned names this module listens to.
-- `open77:worldReady` is in `OPX.Host`; this one belongs to the session service
-- and is listed here so a typo is a nil index rather than a handler nobody
-- raises. It says the gameplay puppet has been rebuilt: that is the world the
-- roster belongs in.
M.HostEvent = {
	RESET_COMPLETE = 'open77:playerReset:complete',
}

--- Which request a refusal answers.
-- RECOPIED from the character module's own operation names. A module may not read
-- another module's namespace, and these arrive as plain strings on the wire, so
-- the two lists are kept in step by hand. A name that drifts costs a refusal this
-- screen ignores -- never a refusal it takes for somebody else's.
M.Operation = {
	ENTRY = 'entry',
	ROSTER = 'roster',
	SELECT = 'select',
	CREATE = 'create',
}

--- The pattern each half of a character name must match.
-- RECOPIED from the character module for the same reason as the operations. A
-- letter is a byte range rather than `%a`, which is ASCII only and would refuse
-- "Eloise" spelled properly; four-byte lead bytes are left out, because that is
-- where the emoji live.
local LETTER = '%a\194-\239\128-\191'
M.NAME_PATTERN = ("^[%s][%s '%%-]*$"):format(LETTER, LETTER)

--- The shape of a birth date, and the bounds the server checks it against.
M.BIRTH_PATTERN = '^%d%d%d%d%-%d%d%-%d%d$'
M.BIRTH_MIN = 8
M.BIRTH_MAX = 10

--- Days per month, February at its leap-year length.
-- A date is written once for the life of a character, so the year is not worth
-- resolving for one day. The server counts them the same way.
M.MONTH_DAYS = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- The two body families the server stores on `charInfo.gender`.
M.FAMILIES = { 'female', 'male' }

--- Reads a configured number with a floor.
-- The floor is also the answer for a setting that is missing or not finite, so no
-- caller ever compares a number against nil. The test is finiteness and not a NaN
-- test: an infinity passes `value ~= value` and would freeze an interval.
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

--- Whether a configured deadline is armed, and for how long.
-- A value that is not a positive finite number turns its deadline off rather than
-- expiring everything at once, which is what an infinity or a NaN would do.
-- @author dop42
-- @param value any
-- @return number|nil
function M.Deadline(value)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) or value <= 0 then return nil end
	return math.floor(value)
end
