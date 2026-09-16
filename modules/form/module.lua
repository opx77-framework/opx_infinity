--- The modal that asks for values: text, choice and slider, answered together.
-- @author dop42
--
-- Like the menu it is a renderer with the model behind it, and the division of
-- labour is the one rule that makes a typed line work at all: Lua holds the
-- authoritative buffer, runs `maxLength`, `charset`, `pattern` and `required`,
-- and answers every keystroke with the buffer it ACCEPTED. What the page reports
-- is a CANDIDATE. A refused keystroke is not merely hidden -- the accepted
-- buffer stays as it was and the page is told to put it back, because a field
-- that kept its own text would be showing a value that has already been refused.
--
-- The page keeps the keyboard throughout and forwards five keys; every other
-- key belongs to the focused input. LEFT and RIGHT are the exception that makes
-- a typed line and an arrow-stepped list share one surface: they belong to the
-- caret unless the frame said the focused row spins.
--
-- The surface is shared, so every payload in either direction carries the handle
-- this module minted and a payload naming another one is discarded.

local M = OPX.Modules.Declare{
	id = 'form',
	side = 'client',
	fatal = false,
	-- Not a requirement. With it, a form does not open over a player who is
	-- down; without it the module never hears about it and opens.
	optional = { 'downed' },
}

M.Event = {
	-- Raised beside the caller's own callback for every answer, for anything
	-- that wants to watch the surface rather than own it. It must stay on the
	-- LOCAL channel: the host dispatcher matches on the name alone, so a local
	-- raise on a NET name would re-enter the wire handlers.
	ANSWER = OPX.Event(OPX.Channel.LOCAL, 'form', 'answer'),
}

--- Names the host owns. Escape is swallowed by the plugin before any surface
--- sees it and arrives as this instead, so it cannot be renamed here.
M.Host = {
	PAUSE_KEY = 'open77:pauseKey',
}
