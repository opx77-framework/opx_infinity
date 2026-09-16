--- Reports what the runtime actually brought up.
-- @author dop42
--
-- The platform's eighth gamemode convention is that a mode ships a diagnostic
-- command. With modules that can be disabled, unavailable or failed, "it is not
-- working" has several distinct answers, and this is what tells them apart.

OPX.Modules.Declare{
	id = 'diagnostics',
	side = 'both',
	fatal = false,
}
