--- Client-only configuration. Not authoritative: a modified client can change
--- every value here, and the server re-derives anything that matters.
-- @author dop42

OPX.Config.CLIENT = {
	SURFACE = {
		-- Two surfaces, not one per feature. The platform allows eight per
		-- resource, only one surface may hold focus at a time, and an exception
		-- on the interactive layer must not be able to blank the overlay.
		OVERLAY = { zIndex = 700, fps = 30 },
		INTERACTIVE = { zIndex = 740, fps = 60 },
	},
}
