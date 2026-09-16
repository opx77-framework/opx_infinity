--- Where each HUD block sits, what the gauges read, and the tone thresholds.
-- @author dop42
--
-- The page decides no colour and formats no number: `TONE_WARN` and `TONE_BAD`
-- below are the whole of the gauge palette's logic, and the money separator is
-- the whole of its formatting. Both live here because both are operator
-- decisions, and a page that made either would be a second opinion.
--
-- Every anchor is a closed set on the page, which falls back to its own default
-- for a name it does not know: a typo here is a block in the wrong corner, never
-- a broken layout.

OPX.Config.MODULES.hud = {
	enabled = true,

	-- bottom-left, bottom-right, top-left, top-right, top-center, bottom-center.
	ANCHOR = 'bottom-left',
	INFO_ANCHOR = 'top-right',
	-- Absent, the strip rides in the gauge column's corner.
	STATUS_ANCHOR = 'bottom-left',
	-- Pixels of clearance between the chip strip and the gauges beneath it.
	STATUS_OFFSET = 120,
	VEHICLE_ANCHOR = 'bottom-center',

	-- Gauge column width in pixels on the 1920-wide surface, and how many
	-- segments a gauge and the voice meter are cut into.
	WIDTH = 210,
	SEGMENTS = 10,
	VOICE_SEGMENTS = 8,

	-- Milliseconds between two samples. The vitals stream is the surface's own
	-- 30 fps; the voice and vehicle read-outs move far slower than they are
	-- looked at. Neither sends a frame that changed nothing.
	VITALS_MS = 33,
	WIDGET_MS = 100,

	-- Percent at or under which a gauge takes the warning and the danger tone.
	TONE_WARN = 33,
	TONE_BAD = 15,

	-- The gauges, in drawing order.
	--   SOURCE      health, armor, stamina, or any need name
	--   LABEL       a catalogue key; the page resolves it
	--   ICON        health, armor, stamina, hunger or thirst; anything else
	--               draws no glyph
	--   TONE        the tone above TONE_WARN; omit for the quiet one
	--   ALERT       false leaves the gauge untoned at every value
	--   HIDE_AT_ZERO / HIDE_ABOVE   when the row is not worth the space
	GAUGES = {
		{ ID = 'health', SOURCE = 'health', ICON = 'health',
			LABEL = 'hud.gauge.health', TONE = 'health' },
		-- Untoned on purpose: a low armour is not the alert a low health is.
		{ ID = 'armor', SOURCE = 'armor', ICON = 'armor',
			LABEL = 'hud.gauge.armor', ALERT = false, HIDE_AT_ZERO = true },
		{ ID = 'stamina', SOURCE = 'stamina', ICON = 'stamina',
			LABEL = 'hud.gauge.stamina', HIDE_ABOVE = 99 },
		{ ID = 'hunger', SOURCE = 'hunger', ICON = 'hunger',
			LABEL = 'hud.gauge.hunger' },
		{ ID = 'thirst', SOURCE = 'thirst', ICON = 'thirst',
			LABEL = 'hud.gauge.thirst' },
	},

	-- Money lines, in order. A type held and not listed here is appended after
	-- them, sorted, so a new purse shows up without a config change.
	MONEY = { 'EDDIES', 'BANK' },
	MONEY_SEPARATOR = ' ',

	-- The eyebrow over the read-out, and the two identity lines.
	INFO_EYEBROW = 'hud.info.eyebrow',
	SHOW_JOB = true,
	SHOW_CRED = true,

	-- The microphone block. `OPEN_VOICE` and `DRIVER` are platform resources,
	-- read through their exports and never a dependency: without them the block
	-- still draws what the engine's own voice status says.
	VOICE = {
		OPEN_VOICE = 'open-voice',
		DRIVER = 'open77_voice',
		HIDE_OPEN_VOICE = true,
	},

	-- The speed dial. PASSENGER false draws it for the driver only.
	VEHICLE = {
		PASSENGER = true,
	},

	-- Components of the game's own HUD, which this one replaces. The platform
	-- drops every hide request of a resource when it stops, so nothing is put
	-- back by hand.
	VANILLA = {
		minimap = false,
		compass = false,
		clock = false,
		health = false,
		stamina = false,
		weapon = false,
		speedometer = false,
	},
}
