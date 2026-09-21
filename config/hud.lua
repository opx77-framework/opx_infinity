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

	-- Components of the game's own HUD, which this one replaces. `false` hides
	-- one; `true` leaves it to the game. The platform drops every hide request of
	-- a resource when it stops, so nothing is put back by hand, and a hide is a
	-- CLAIM rather than an override -- releasing ours does not reveal a component
	-- another resource is still hiding.
	--
	-- ALL THIRTEEN ARE LISTED, and that is the change. Seven were named and six
	-- were simply absent, which reads as "we decided to show them" and meant "we
	-- did not think about them". Every one now carries a value and a reason, so
	-- the next person is disagreeing with a decision rather than filling a gap.
	--
	-- `Open77.hud.components()` is the authority on the set; the client half
	-- reads it and applies only the names this build knows, so a name added or
	-- renamed upstream costs nothing here.
	VANILLA = {
		-- ====================================================================
		-- THE MINIMAP, AND THE ONE ENTRY IN THIS LIST THAT WAS NOT PAID FOR
		-- ====================================================================
		--
		-- `true` since the blips work, and it is a REVERSAL. It was `false`, under
		-- the heading "replaced outright by this HUD", alongside health, stamina,
		-- the clock and the rest.
		--
		-- IT WAS NOT REPLACED. Every other hide in this block is paid for by
		-- something this runtime draws instead: `core/client/notify.lua` for the
		-- notifications, our own gauges for health and stamina, our own clock. The
		-- minimap was the one entry where we hid the game's version and drew
		-- NOTHING. `grep -rin "minimap|radar" ui/ web/` finds a single CSS comment
		-- in `MenuView.vue` positioning something "below the minimap" and no
		-- component anywhere. So the player lost their map and got an empty corner.
		--
		-- THAT IS THE OWNER'S COMPLAINT, VERBATIM AND REPEATED: "ce serais cool de
		-- voir des blips sur la minimap". There were no blips at all until
		-- `modules/blips` -- that, and not this flag, is what the map was missing,
		-- and `config/blips.lua` carries the measurement. But this flag decides
		-- WHERE they land, because the platform's component table
		-- (`open77_guide hud-visibility#components`) gives `minimap` as: "Map
		-- panel, geometry, player marker, MAPPINS, GPS lines, frame and location
		-- label". Hiding it hides the pins ON THE MINIMAP.
		--
		-- THE FULLSCREEN MAP IS NOT AFFECTED EITHER WAY. It is not one of the
		-- thirteen components `Open77.hud` governs; there is no switch here that
		-- reaches it. So:
		--
		--   true   pins on the minimap AND the fullscreen map. A vanilla panel in
		--          the corner of a screen the rest of which is ours.
		--   false  pins on the fullscreen map only. A clean corner, and a player
		--          who has to open the big map to navigate.
		--
		-- Set it back to `false` if the clean screen is worth more than the map.
		-- Nothing breaks: `modules/blips` reads this component's effective state
		-- at boot and says which of the two is in force in its `OPX.Note`, so the
		-- answer is in the server journal rather than in somebody's memory.
		minimap = true,

		-- Replaced outright by this HUD.
		compass = false,
		clock = false,
		health = false,
		stamina = false,
		weapon = false,
		speedometer = false,

		-- DEAD CHROME ON THIS SERVER. There are no quests, so the tracker draws
		-- single-player objectives over a multiplayer world.
		questTracker = false,

		-- WE OWN NOTIFICATIONS. `core/client/notify.lua` and the overlay draw
		-- every message this runtime sends; the vanilla stack would be a second,
		-- differently-styled one saying things nobody here raises.
		vanillaNotifications = false,

		-- THE VANILLA INVENTORY AND CHARACTER SCREENS. This runtime has its own
		-- for both, and two inventories over one body is the double-surface
		-- problem every other seam in this tree is shaped to avoid: the vanilla
		-- one shows the engine's equipment, ours shows the bag, and they disagree.
		hubMenu = false,

		-- LEFT TO THE GAME, DELIBERATELY, and each for its own reason.
		--
		-- `crosshair` is how a player aims. Hiding it is not a style choice, it
		-- is taking away the weapon's usability.
		crosshair = true,
		-- `scanner` is real gameplay and we replace nothing it does.
		scanner = true,
		-- `phone` is the one genuinely open question. It is the vanilla contacts
		-- list, which is single-player content -- but it is also a screen players
		-- reach for, and nothing here replaces it yet. Shown until something does.
		phone = true,
	},
}
