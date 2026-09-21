--- Configuration every client receives. Nothing secret belongs here: it ships to
--- each player in the signed resource set.
-- @author dop42

OPX.Config.SHARED = {
	LOCALE = 'en',

	SERVER_NAME = 'OPEN//77',
	-- Where a toast is drawn. Advisory: a client that cannot honour it warns
	-- rather than dropping the toast.
	NOTIFY_POSITION = 'top-right',

	MONEY = {
		DEFAULT = 'EDDIES',
		TYPES = { EDDIES = 'EDDIES', BANK = 'BANK' },
		ALLOW_NEGATIVE = {},
	},

	-- A TweakDB vehicle record naming an AV starts with one of these, compared
	-- lower-cased because the database column and the wire disagree about case.
	-- The rule `open77_avcleanup` sweeps the world by.
	--
	-- IT LIVES HERE AND NOT UNDER A MODULE because whether a record flies is a
	-- fact about the record, not about who is looking at it. It was three lists
	-- under `garages`, `dealership` and `admin.VEHICLES`, and the day one of them
	-- was edited the staff catalogue and the dealer disagreed about the same car.
	-- `OPX.Text.IsAvRecord` is the only reader; an empty list falls back to this
	-- pair rather than meaning "nothing flies".
	AV_PREFIXES = { 'vehicle.av_', 'vehicle.max_tac_av' },
}

--- Per-module settings. A module reads its own table as `module.Settings`, and
--- the two keys the runtime itself reads are `enabled` and `provider`:
---   enabled  = false   the module declares and stops there
---   provider = '<id>'  another module answers this one's contract instead
OPX.Config.MODULES = {
	-- example = { enabled = true },
}
