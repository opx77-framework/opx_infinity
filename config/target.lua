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
}
