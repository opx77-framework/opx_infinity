--- Reports what the runtime actually brought up.
-- @author dop42
--
-- The platform's eighth gamemode convention is that a mode ships a diagnostic
-- command. With modules that can be disabled, unavailable or failed, "it is not
-- working" has several distinct answers, and this is what tells them apart.

local M = OPX.Modules.Declare{
	id = 'diagnostics',
	side = 'both',
	fatal = false,
}

--- The page's own failures, forwarded from the client to the server log.
--
-- WHY THIS EXISTS. When a view throws, `ModuleHost.vue` takes that module off the
-- page for the rest of the session -- deliberately, so one broken view cannot
-- blank the HUD -- and reports the throw on `opx:diag`. `lib/client/surface.lua`
-- writes that to `Open77.log`, which is the CLIENT log: a file on the player's
-- machine, in a folder they have to go and find, on a PC that is often not the
-- one the operator is working from.
--
-- So the one artefact that says which view died, and why, was the one artefact
-- nobody could read. A view that vanishes silently and a view that was never
-- written look identical from the server, and both look like "it does not work"
-- from the player. This carries the line to the journal instead.
M.PAGE = OPX.Event(OPX.Channel.NET, 'diagnostics', 'page')
