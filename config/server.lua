--- Server-only configuration. Never distributed: credentials, webhooks and
--- anything a client must not read belong here.
-- @author dop42

OPX.Config.SERVER = {
	-- Numbers an operator may change while people are playing are re-declared as
	-- tunables and read through those, not from here. These are the defaults.
	AUTOSAVE_MS = 300000,
	SAMPLE_MS = 1000,
}
