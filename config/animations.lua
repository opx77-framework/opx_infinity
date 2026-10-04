--- Animations: the picker, the two keys and the four commands.
-- @author dop42
--
-- This ships to every client in the signed resource set, so nothing secret and
-- no ACL decision belongs here. `RESTRICTED` gates `command.<NAME>` in the host
-- ACL; every command acts on its caller alone, so they are all open by default.
--
-- The rate limit and the two durations are also declared as tunables by the
-- server half, so an operator can move them while people are playing. The values
-- below are what they fall back to.

OPX.Config.MODULES.animations = {
	enabled = true,

	-- auto leaves the bodies to open77_animations while it runs; always and
	-- never force it. Two presenters on one body restart each other's clip.
	PRESENTER = 'auto',

	-- false answers refusals as chat lines instead of toasts.
	NOTIFY = true,
	TOAST_MS = 4000,

	-- Show the stop key in the prompt strip while your animation plays.
	PROMPTS = true,

	-- Catalogue names never offered to anybody. A platform profile id works
	-- here too (`'carry'`, `'camera_point'`...): those are matched once the
	-- platform's catalogue has been read, and one matching nothing is a line in
	-- the boot log.
	DISABLED = {},

	-- Offer every profile of the platform's own catalogue (open77_animations,
	-- read at runtime with `Open77.animations.list`) beside the entries written
	-- in modules/animations/shared/catalogue.lua, so a profile a new build adds
	-- appears without a release. false offers only the written ones.
	PLATFORM = true,

	-- EMOTES WITH A NEARBY PLAYER, through the platform's two-player
	-- coordinator (`Open77.playerInteractions`, kind `custom`). The requester
	-- picks one, the nearest player within RANGE is invited, and nothing plays
	-- until they accept. The server measures the distance, never a client.
	--
	-- `ACTOR` and `TARGET` are platform profile ids and must be stationary
	-- (workspot) ones: the coordinator plays nothing that walks. A pair naming a
	-- profile the build lacks, or one in DISABLED, is not offered.
	SHARED = {
		ENABLED = true,
		-- Metres between the two bodies, 0.25 to 10.
		RANGE = 3.0,
		-- How long an invitation waits for its answer.
		INVITE_MS = 15000,
		PAIRS = {
			{ ID = 'dance', ACTOR = 'dance', TARGET = 'dance', DURATION_MS = 30000 },
			{ ID = 'give', ACTOR = 'give', TARGET = 'give', DURATION_MS = 5000 },
			{ ID = 'checkup', ACTOR = 'examine', TARGET = 'wounded', DURATION_MS = 12000 },
			{ ID = 'cheer', ACTOR = 'cheer', TARGET = 'cheer', DURATION_MS = 10000 },
			{ ID = 'taichi', ACTOR = 'taichi', TARGET = 'taichi', DURATION_MS = 30000 },
			{ ID = 'talk', ACTOR = 'preach', TARGET = 'armscrossed', DURATION_MS = 20000 },
		},
	},

	LOOP_BY_DEFAULT = true,
	ONE_SHOT_MS = 10000,
	MAX_DURATION_MS = 600000,

	-- Play requests per player per window; stops get twice as many. An
	-- invitation to a nearby player counts as a play.
	RATE_LIMIT = { WINDOW_MS = 10000, REQUESTS = 6 },

	PICKER = {
		CLOSE_ON_SELECT = true,
		-- Engine clip words beside Variant n; never translated.
		SHOW_VARIANT_WORDS = true,
	},

	-- Defaults a player rebinds in the pause menu; false registers none.
	KEYS = {
		PICKER = 'F3',
		STOP = 'X',
	},

	-- THE PACES A PLAYER CYCLES, and what they are NOT.
	--
	-- There are no walk STYLES on this platform. `SetPedMovementClipset` -- the
	-- FiveM native that gives a body a swagger or a limp -- has no Open77
	-- equivalent at all: the devkit's alias table has no row for it, and the
	-- whole of `Open77.movement` is `setWalkMode`, `getWalkMode`, `lock` and
	-- `unlock`. What exists is a bounded SPEED, so these are paces and they are
	-- named as paces rather than pretending to be gaits.
	--
	-- `SPEED` is metres per second and the platform accepts 0.5 to 2.5; anything
	-- outside is refused by `Walk.Request` before the native ever sees it. The
	-- first entry is the one a fresh session starts on, and cycling past the
	-- last releases the lease and gives the body its ordinary movement back.
	WALK_PACES = {
		{ ID = 'stroll', SPEED = 0.8 },
		{ ID = 'walk', SPEED = 1.2 },
		{ ID = 'brisk', SPEED = 1.8 },
	},

	-- NAME = false registers no command. `e` is deliberately short and not
	-- prefixed: /e dance is the emote everyone already types.
	COMMANDS = {
		ANIM = { NAME = 'opx.anim', RESTRICTED = false },
		EMOTE = { NAME = 'e', RESTRICTED = false },
		STOP = { NAME = 'opx.anim.stop', RESTRICTED = false },
		LIST = { NAME = 'opx.anim.list', RESTRICTED = false },
	},
}
