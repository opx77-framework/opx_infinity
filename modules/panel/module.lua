--- The mouse-driven drawer: tabs, a searchable list, buttons and a confirm step.
-- @author dop42
--
-- This is the view the handle pattern was taken from, and the pattern is the
-- whole reason five systems can share one surface: Lua opens with a spec and
-- keeps the handle, every payload in either direction carries it, and a message
-- whose handle is not the open one is dropped rather than applied. Without that
-- rule a late reply from a panel that has already closed lands in the panel that
-- replaced it.
--
-- Three things the page decides for itself, and only these three, because none
-- of them is a fact about the world: the search filter over items Lua has
-- already sent, the page of that filtered list, and whether the confirm dialog
-- is on screen. Everything else is Lua's answer, applied verbatim. The page does
-- not select an item because it was clicked; it says it was clicked and waits
-- for `selected` to come back.

local M = OPX.Modules.Declare{
	id = 'panel',
	side = 'client',
	fatal = false,
	-- Not a requirement. With it, a panel does not open over a player who is
	-- down; without it the module never hears about it and opens.
	optional = { 'downed' },
}

M.Event = {
	-- Raised beside the caller's own callback for every action on every panel,
	-- for anything that wants to watch the surface rather than own it. It must
	-- stay on the LOCAL channel: the host dispatcher matches on the name alone,
	-- so a local raise on a NET name would re-enter the wire handlers.
	ACTION = OPX.Event(OPX.Channel.LOCAL, 'panel', 'action'),
}

--- Names the host owns. Escape is swallowed by the plugin before any surface
--- sees it and arrives as this instead, so it cannot be renamed here.
M.Host = {
	PAUSE_KEY = 'open77:pauseKey',
}
