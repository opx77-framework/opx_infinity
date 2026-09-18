--- What happens between a connection and a character somebody can play.
-- @author dop42
--
-- There is no selection screen, and that is the whole design. An account is
-- LOCKED on one character and a connection enters on it; the lock is moved by a
-- command (`opx.characters`, `opx.select`, `opx.create`) and a command that moves
-- it disconnects the player. It has to: the body a world loads with is the
-- character bootstrap's answer, and that transaction is spent before the world
-- exists, so the only honest way to play another character is to arrive as one.
--
-- What is left for a client to do is the two things a player still answers for a
-- character the server made empty:
--
-- 1. THE BODY AND THE FACE, which the game's own character creator asks in one
--    flow, in the pre-game menu, while the bootstrap is still open. This module
--    does not draw it and does not choose anything in it: the appearance module
--    says `needsCreation`, this answers by calling `OpenCreator`, and the family
--    the creator confirms is written to the character row by the server.
-- 2. THE NAME, typed once the player is in the world, through the form module.
--    It is asked again as long as it is unanswered -- a cancelled form is not a
--    character that stays nameless -- and the server accepts it exactly once.
--
-- Nothing here is authoritative. The name is re-checked by the server, which
-- refuses a second one whatever a modified client sends.

local M = OPX.Modules.Declare{
	id = 'entry',
	side = 'client',
	-- The character contract: this module reads what is loaded and sends the name
	-- back. Without it there is nothing to be the entry of.
	requires = { 'character' },
	-- The face, and the modal that asks for the name. A character with no face
	-- enters on the default one when the first is absent, which is what the
	-- platform does anyway; with the second absent nothing asks for a name, and
	-- the character keeps the slot it draws as.
	optional = { 'appearance', 'form' },
	fatal = false,
}

local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises.
-- One line on the client's public bus, so anything at all can tell whether the
-- player is still being asked for something. It must stay on the LOCAL channel:
-- the host dispatcher matches on the name alone, and a local raise on a NET name
-- would re-enter that name's network handler.
M.Event = {
	ON_STATE = OPX.Event(LOCAL, 'entry', 'state'),
}

--- Which request a refusal answers.
-- RECOPIED from the character module's own operation names. A module may not read
-- another module's namespace and these arrive as plain strings on the wire, so
-- the two lists are kept in step by hand. A name that drifts costs a refusal this
-- module ignores -- never one it takes for somebody else's.
M.Operation = {
	ENTRY = 'entry',
	NAME = 'name',
}

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
