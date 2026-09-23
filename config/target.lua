--- The key, the reach of the ray, and the pace of the target eye.
-- @author dop42
--
-- The three timings at the bottom are the ones that were measured rather than
-- chosen. `BATCH` is the important one: resolving a pick asks every matching row
-- whether it applies, and a row whose answer lives on another resource is a host
-- call. Doing all of them in one coroutine body is what exceeded the per-resume
-- instruction budget on the resource this module was ported from, and a body that
-- exceeds it is unwound and never resumed -- silently. Five rows per slice, one
-- slice per scheduler pass, is the bound that fixed it.
--
-- `WATCH_MS` and `RESOLVE_MS` are floors, not periods: `OPX.Scheduler` sleeps
-- `IDLE_MS` (100) whenever no job is due, so anything below that runs at roughly
-- 100ms unless another job is keeping the loop busy. They are written as the pace
-- this module would like, not the pace it gets.

OPX.Config.MODULES.target = {
	enabled = true,

	-- Rebindable in the pause menu; this is only the default.
	KEY = 'ALT',

	-- Keep the native weapon wheel off the key for as long as this module runs.
	BLOCK_WEAPON_WHEEL = true,

	-- Metres the ray reaches from the camera. Each row also checks its own
	-- `distance`, which is the one a player actually feels.
	RAY_DISTANCE = 12.0,

	-- Rows listed at once. Past this the list stops being read and starts being
	-- scrolled.
	MAX_OPTIONS = 32,

	-- ── WHERE A ROW SITS ─────────────────────────────────────────────────────
	--
	-- Not a setting: the bands every module's `order` is written in, kept here
	-- because it is the one file about the eye that every module's author reads
	-- and because no module may read another module's namespace to find them.
	--
	--     0-9    THE THING ITSELF. Opening a door, taking a pile off the floor.
	--            What the player walked up to it for.
	--    10-19   ITS STATE. Locking it, turning it on.
	--    20-39   WHAT IT HOLDS. A boot, a glovebox, a stash.
	--    40-59   WORK. Gigs, jobs, anything a player took on.
	--    60-89   LEAVING. Abandoning a run, getting out.
	--   100-999  STAFF. Always last, always under a folder of its own.
	--
	-- A GROUP IS SORTED WHOLE, at the lowest order any of its rows carries, so
	-- these numbers place a FOLDER as much as they place a row -- and two rows of
	-- one folder can never be split by a row from another. Rows with no group are
	-- the group `''` and are placed the same way.

	-- Milliseconds between two looks under the cursor while nothing is picked.
	HOVER_MS = 90,

	-- Milliseconds between two checks that the key, the focus and the target are
	-- still there.
	WATCH_MS = 50,

	-- Milliseconds between two slices of a pick's resolution.
	RESOLVE_MS = 25,

	-- Milliseconds between two sweeps of the registry while the eye is down.
	SWEEP_MS = 2000,

	-- Milliseconds between two checks that the picked target is still there.
	REVALIDATE_MS = 200,

	-- Milliseconds every canInteract and checked of one pick may take together.
	LOOKUP_BUDGET_MS = 1500,

	-- Rows one slice resolves. See the header.
	BATCH = 5,

	-- ── WHO IS THIS ──────────────────────────────────────────────────────────
	--
	-- THE OWNER: "en gors avec alt sur un joeuru tu peux recup c'est identifiant
	-- donc id serveur est id perso c'est tous".
	--
	-- One row on another player that answers with their two identifiers and puts
	-- them on the clipboard. Two, because they are different things and both get
	-- asked for: the SERVER id is the number in the journal and in every staff
	-- command, and it is only that player's until they disconnect; the CHARACTER
	-- id is durable and identifies a person for as long as the character exists.
	--
	-- IT IS THE EYE'S OWN ROW AND NOT THE CHARACTER MODULE'S, and that is forced
	-- rather than chosen: `character` cannot depend on `target`, because `target`
	-- optionally depends on `downed` and `downed` REQUIRES `character` -- a cycle,
	-- which the module graph refuses by name and which would take the boot down.
	-- The eye already starts after the character module for the same reason, so it
	-- can read the contract with no ordering of its own.
	--
	-- NOTHING PRIVATE CROSSES ANYTHING. Both values are already on this client:
	-- the character id is replicated on the player's own state bag, which is what
	-- draws their nameplate. This row reads what is already here and copies it.
	IDENTIFY = {
		-- Whether the row is offered at all.
		ENABLED = true,
		-- Metres it reaches. The eye's own default is 3.0; this is a thing you do
		-- to somebody you are looking at across a room.
		DISTANCE = 12.0,
	},

	-- A GLOW ON WHAT THE EYE PICKED, for as long as its rows are up. The owner,
	-- 2026-09-24: "fait egalement la lumiere sur l'object qu'on target".
	--
	-- A LOCAL light: `Open77.props.create` on the CLIENT is never replicated, so
	-- only the player aiming sees it. Placed LIFT metres over the point the ray
	-- hit. There is no outline native that follows the cursor --
	-- `Open77.inspector.outline` outlines what the RETICLE is on, and the eye
	-- picks with the cursor while the camera is held still.
	--
	-- COLOR is linear 0..1 with x/y/z keys, as every platform light takes it.
	GLOW = {
		ENABLED = true,
		COLOR = { x = 1.0, y = 0.08, z = 0.08 },
		INTENSITY = 15.0,
		RADIUS = 2.0,
		LIFT = 0.4,
	},
}
