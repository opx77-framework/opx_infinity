--- One authority for the time of day and the sky, published to every client.
-- @author dop42
--
-- This module is the pattern the others follow, so the two rules it demonstrates
-- are worth stating here:
--
-- 1. A module's internals live on the table `Declare` answers, reached with
--    `OPX.Modules.Get('weather')`. They are NOT hung off `OPX.` -- a module that
--    can reach another module's internals will, and then the two are one module
--    with extra steps.
-- 2. What other modules may use is the contract, published in `Api` and read
--    with `OPX.Api.Get('weather')`. A consumer never learns whether the answer
--    came from this module, another one, or an external implementation.
--
-- Without a single authority every client runs its own sky, and two players
-- standing together see different weather.

OPX.Modules.Declare{
	id = 'weather',
	side = 'both',
	fatal = false,
}
