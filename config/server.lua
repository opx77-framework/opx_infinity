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

	-- Short spellings, so `opx.admin.self.noclip` can also be typed `noclip`.
	--
	-- THE LONG NAME IS THE COMMAND AND NOTHING HERE RENAMES IT. Every key below
	-- keeps working exactly as it always has: it is what `acl.jsonc` grants, what
	-- `config/admin.lua`'s LINKS block names, and what the staff menu and the eye
	-- run. The value is a convenience that lives alongside it, and an operator who
	-- empties this table loses nothing but the typing.
	--
	-- A VALUE THE HOST WILL NOT GIVE US IS SKIPPED, NOT FATAL. This session also
	-- runs open77_shell, open77_pause, open77_voice, open-voice, open77_weapons,
	-- open77_interactions and open77_props, and a bare word is a far likelier
	-- collision than a prefixed one -- `open77_weather` ships a plain `weather`
	-- command, which is the shape of the thing. If one of these is already taken,
	-- `core/server/commands.lua` logs the name and the reason and moves on.
	--
	-- WHAT IS DELIBERATELY ABSENT, because symmetry is the wrong goal here:
	--   * `opx.admin` itself. It is the grant that makes somebody staff, `admin`
	--     is the single likeliest bare name for another resource to own, and the
	--     menu is already on F9.
	--   * everything irreversible: `...moderate.ban`, `...moderate.kick`,
	--     `...player.kill`, `...character.delete`, `opx.delete`. A bare `ban` or
	--     `kill` is a word you can type by accident, and none of them can be
	--     taken back. Typing the long name is friction that matches the
	--     consequence.
	--   * the generic nouns -- `save`, `give`, `list`, `add`, `open`, `set`,
	--     `money`, `status`, `time`, `weather`. Claiming one of those out of the
	--     session-wide namespace is asking for the collision, and half of them
	--     say nothing about which of eight commands they mean.
	COMMAND_ALIASES = {
		-- Players.
		['opx.characters'] = 'chars',
		['opx.duty'] = 'duty',
		['opx.withdraw'] = 'withdraw',

		-- Staff, on themselves.
		['opx.admin.self.noclip'] = 'noclip',
		['opx.admin.self.god'] = 'god',
		['opx.admin.self.invisible'] = 'invis',
		['opx.admin.self.heal'] = 'heal',
		['opx.admin.self.revive'] = 'revive',
		['opx.admin.self.speed'] = 'speed',
		['opx.admin.self.pos'] = 'pos',

		-- Staff, on somebody else. The bare verbs above are the self ones because
		-- those are the ones typed without stopping to think; these keep a word
		-- that says a target is coming.
		['opx.admin.player.goto'] = 'goto',
		['opx.admin.player.bring'] = 'bring',
		['opx.admin.player.tp'] = 'tp',
		['opx.admin.player.freeze'] = 'freeze',
		['opx.admin.player.observe'] = 'spectate',

		-- Weapons and vehicles.
		['opx.admin.weapon.give'] = 'addweapon',
		['opx.admin.weapon.giveammo'] = 'addammo',
		['opx.admin.weapon.remove'] = 'delweapon',
		['opx.admin.vehicle.spawn'] = 'car',
		['opx.admin.vehicle.repair'] = 'fix',
		['opx.admin.vehicle.remove'] = 'dv',

		['opx.admin.world.announce'] = 'announce',
	},

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
