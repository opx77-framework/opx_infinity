--- The target eye: hold a key, point at the world, and be offered what can be done.
-- @author dop42
--
-- This module replaced the platform's own context menu, and its whole job is the
-- registry: anything that wants a row on the eye registers one, and the eye asks
-- the row's owner whether it applies to what the ray actually hit. Nothing here
-- knows what a door, a pile of loot or a staff command is.
--
-- Three properties of the original are load-bearing and are kept by name below
-- and in `shared/model.lua`:
--
--   * `MAX_PER_OWNER` bounds one owner's rows, because a pick pays for every
--     registered row that matches;
--   * the screen ray is cast fresh at the PICK point -- where the right button
--     went down -- never at wherever the cursor has since moved to;
--   * work is sliced. Asking every matching row's owner in one go is what hit the
--     per-resume instruction budget on the resource this came from.
--
-- Client only: the ray, the cursor and the page are all client-side, and the
-- server has no opinion about what is under someone's crosshair. `downed` is
-- optional -- without it the eye simply never learns that the player is on the
-- floor, which is a worse eye and not a broken one.

OPX.Modules.Declare{
	id = 'target',
	side = 'client',
	optional = { 'downed' },
	fatal = false,
}
