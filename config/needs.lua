--- Where the effect strip sits, and every need with its bounds.
-- @author dop42
--
-- `NEEDS` is the whole vocabulary: a key absent from here is refused by every
-- call and never stored, and a key added to it is served at its `DEFAULT` to
-- characters whose stored row predates it. `MIN` and `MAX` bound it on both
-- halves, and `DECAY_PER_MINUTE` is optional -- a need without one only moves
-- when something moves it.

OPX.Config.MODULES.needs = {
	enabled = true,

	-- The corner a view places the strip in, and the pixels it sits above that
	-- corner, clear of the gauges. Both travel in the published strip.
	ANCHOR = 'bottom-left',
	OFFSET = 120,

	-- Chips published at once; the rest are counted in `hidden`.
	MAX_VISIBLE = 6,

	NEEDS = {
		hunger = { MIN = 0, MAX = 100, DEFAULT = 100, DECAY_PER_MINUTE = 0.20 },
		thirst = { MIN = 0, MAX = 100, DEFAULT = 100, DECAY_PER_MINUTE = 0.28 },
		stamina = { MIN = 0, MAX = 100, DEFAULT = 100 },
		streetCred = { MIN = 0, MAX = 100000, DEFAULT = 0 },
	},

	-- Milliseconds between two decay charges, and between two throttled pushes.
	DECAY_MS = 60000,
	PUSH_MS = 120000,

	-- A move this large on any need pushes at once instead of waiting.
	PUSH_DELTA = 5,

	-- Milliseconds between two server writes of the pushes it holds.
	AUTOSAVE_MS = 300000,
}
