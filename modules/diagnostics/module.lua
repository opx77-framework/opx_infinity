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
--
-- WHY THIS DID NOT CONVERGE ON `OPX.Note`, when the module-fault half of this same
-- file did. A note is a DECISION, budgeted at sixty per session, because the trail
-- it carries is finite and you want all of it. A page report is a THROW, and a
-- throwing render loop is unbounded by nature -- which is why this one is
-- three-floored (twenty per page load, twenty per client session, twenty per
-- minute on the server) and why its server ceiling is a RENEWABLE window rather
-- than a session budget. Those are two different bargains, and merging them costs
-- both: one broken view would eat the note budget in its first minute and blind
-- every decision note from every other module for the rest of the session, and the
-- view fault itself would stop being reported at sixty where today it keeps
-- reporting twenty a minute for as long as it keeps throwing. An intermittent
-- render fault is found by watching it recur.
M.PAGE = OPX.Event(OPX.Channel.NET, 'diagnostics', 'page')

--- The answer to a diagnostic command, server to client, one line per entry.
-- Declared here with `PAGE` rather than built in each half, which is how every
-- other module keeps its wires: a rename then happens once, and the two halves
-- cannot drift into two different names without the file saying so.
M.LINES = OPX.Event(OPX.Channel.NET, 'diagnostics', 'lines')
