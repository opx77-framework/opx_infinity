--- Death and revive: who is down, and the two ways back up.
-- @author dop42
--
-- The server decides who is down. A player is down from the moment their life
-- phase is `dead`; a placement -- a kill and a respawn in one tick, the way a
-- character is moved -- goes straight to `respawnpending` and never opens the
-- screen. Every player's life state is read again each second, so a death that
-- happened while this module was stopped is caught, and a revive done by
-- anything at all closes it.
--
-- Nothing else in the runtime respawns a dead player: the platform leaves a body
-- dead until something revives or respawns it.
--
-- A player who is down gets one full-screen view with two choices -- wait for
-- help, which broadcasts a distress signal, or give up, which unlocks after a
-- delay and wakes them at the nearest medical center. Every rule behind give up
-- is checked on the server and never on the view.
--
-- The view itself is not here. The client half owns the state machine and hands
-- it to whatever draws it, over the seam marked in `client/main.lua`.

OPX.Modules.Declare{
	id = 'downed',
	side = 'both',
	fatal = false,
	-- Every stored row is keyed on the citizen id, and only the character module
	-- knows which character a player has loaded.
	requires = { 'character' },
}
