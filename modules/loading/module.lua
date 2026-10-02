--- The game's own loading screen, read: the views step aside and the cover goes up.
-- @author dop42
--
-- WHAT THIS ANSWERS. A teleport, a lift ride between floors and a respawn all
-- put the game's native loading screen up for a second or several, and this
-- resource went on drawing straight over it: the gauges, the key strip that
-- had just said "E Take the lift", the eye, the toasts. A player watching a
-- loading screen was shown a HUD for a street they were no longer standing in.
--
-- THE PLATFORM SAYS WHEN, AND NOTHING HERE GUESSES. `Open77.screen.loadingState`
-- is the native lifecycle as the client sees it -- `active` from the moment the
-- screen starts opening until it has finished closing -- with a `revision`
-- that moves whenever any of it does. This module reads it, and that is all it
-- does with the platform: it never forces a load, never shortens one and never
-- decides that one is over. `active` going false is the only end there is.
--
-- IT HIDES BY ASKING THE PAGE, NOT BY SWITCHING ANYBODY OFF. Each view on the
-- surface has its own reasons to be on screen or not -- the HUD the player's
-- choice and the down state, the key strip whatever the player stands on, the
-- tags a staff toggle. Writing `false` into any of them and `true` back after
-- would turn every one of those reasons into "on", which is a closed view
-- reopening itself after a lift ride. So the page takes the views registered
-- as HUD-like off screen while this says a load is up, without touching what
-- they hold, and puts them back exactly as they were. `hud` also listens on
-- `ON_STATE` and counts a load as one more screen in front of it, which is
-- what stops it sampling vitals nobody can see.
--
-- THE COVER IS FOR LOADS IN PLAY, NEVER THE JOIN. The connection screen is the
-- platform's and `web/loading.html` already dresses it; a second OPX screen on
-- top of that one would be two loading screens. A cycle the platform names
-- `initial` or `splash` never gets one, and neither does the cycle that was
-- already running when this module first looked -- that is the join, whatever
-- it was called at the time.
--
-- OLDER CLIENTS. The reader is newer than the devkit's op77.78 and is looked up
-- before every use. A client without it gets one line in its own log, no cover,
-- and a surface that behaves exactly as it did before this module existed.

local M = OPX.Modules.Declare{
	id = 'loading',
	-- The loading screen is the player's own; the server has nothing to say
	-- about it, so there is no server half and no wire.
	side = 'client',
	-- A cover is presentation. A resource that refused to boot because it could
	-- not dress a loading screen has made the screen the least of its problems.
	fatal = false,
}

local LOCAL = OPX.Channel.LOCAL

M.Event = {
	-- Client-local and public. `{ active, cover, kind, id }`, raised when a load
	-- starts or ends or the cover comes or goes -- never for a progress tick.
	-- `active` is the platform's own flag; anything that steps aside for a load
	-- reads it, and `cover` says whether OPX is drawing over the native screen.
	ON_STATE = OPX.Event(LOCAL, 'loading', 'state'),
}

--- The kinds the platform names. Anything else is read as `unknown`, which is
--- what the platform itself answers before it knows.
M.Kinds = { unknown = true, splash = true, initial = true, fastTravel = true }

--- The kinds that are the connection rather than play. The cover stands aside
--- for both: the join screen is the platform's.
M.Connection = { splash = true, initial = true }

--- The permission the reader is gated on. Named once, for the refusal test.
M.PERMISSION = 'screen.read'
