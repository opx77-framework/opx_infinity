--- Server-only configuration. Never distributed: credentials, webhooks and
--- anything a client must not read belong here.
-- @author dop42

OPX.Config.SERVER = {
	-- Resources that also place players. Warned about at boot, because server
	-- resources cannot call each other: asking the host whether one is running is
	-- the only way to find out that two things will fight over the same body.
	CONFLICTING_PLACERS = { 'open77_playerstate', 'freeroam', 'pursuit', 'race' },

	-- Numbers an operator may change while people are playing are re-declared as
	-- tunables and read through those, not from here. These are the defaults.
	AUTOSAVE_MS = 300000,
	SAMPLE_MS = 1000,

	-- The readiness gate, and the bucket a player waits in behind it. Every value
	-- below is validated once at load by the file that reads it: a bad one is
	-- named in the log once and the shipped value is used in its place.
	ENTRY = {
		-- Liveness interval declared to the gate. A watchdog on the HOLDER, never
		-- a limit on the player: someone may sit in a creator for an hour as long
		-- as the holder refreshes. Clamped to 1000..600000.
		GATE_MS = 300000,

		-- How long the gate watch waits before giving up on a player and
		-- releasing without them. Held BELOW GATE_MS, so the runtime gives up
		-- first, deliberately, and says why -- rather than the host opening the
		-- gate with the player possibly not incarnated at all.
		WATCH_MS = 240000,

		BUCKET = {
			-- One bucket per player. False moves nobody, and a stored bucket is
			-- honoured exactly as it was.
			ISOLATE = true,

			-- A player's own bucket is BASE plus their id, so the range runs to
			-- BASE + 65535. Bucket ids are uint32.
			BASE = 77000,

			-- The shared world bucket characters are placed in. A WORLD inside the
			-- selection range would break isolation: that is an error line, and
			-- isolation is switched off rather than left broken.
			WORLD = 0,

			-- Ambient population inside a selection bucket.
			POPULATION = false,

			-- inactive, relaxed, strict or full; false leaves the host's own mode
			-- alone.
			LOCKDOWN = 'relaxed',
		},
	},
}
