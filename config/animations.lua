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

	-- Catalogue names never offered to anybody.
	DISABLED = {},

	LOOP_BY_DEFAULT = true,
	ONE_SHOT_MS = 10000,
	MAX_DURATION_MS = 600000,

	-- Play requests per player per window; stops get twice as many.
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

	-- NAME = false registers no command. `e` is deliberately short and not
	-- prefixed: /e dance is the emote everyone already types.
	COMMANDS = {
		ANIM = { NAME = 'opx.anim', RESTRICTED = false },
		EMOTE = { NAME = 'e', RESTRICTED = false },
		STOP = { NAME = 'opx.anim.stop', RESTRICTED = false },
		LIST = { NAME = 'opx.anim.list', RESTRICTED = false },
	},
}
