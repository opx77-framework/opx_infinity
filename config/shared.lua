--- Configuration every client receives. Nothing secret belongs here: it ships to
--- each player in the signed resource set.
-- @author dop42

OPX.Config.SHARED = {
	LOCALE = 'en',

	MONEY = {
		DEFAULT = 'EDDIES',
		TYPES = { EDDIES = 'EDDIES', BANK = 'BANK' },
		ALLOW_NEGATIVE = {},
	},
}

--- Per-module settings. A module reads its own table as `module.Settings`, and
--- the two keys the runtime itself reads are `enabled` and `provider`:
---   enabled  = false   the module declares and stops there
---   provider = '<id>'  another module answers this one's contract instead
OPX.Config.MODULES = {
	-- example = { enabled = true },
}
