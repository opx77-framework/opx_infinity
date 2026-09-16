--- English player-facing text and refusal codes.
-- @author dop42
--
-- Almost every key here is a refusal code: it reaches locale() through a
-- variable, never as a literal, so a rename breaks nothing at load and
-- everything at the moment a player is refused.

OPX.Locale.Register('en', {
	['error.unavailable'] = 'That is not available right now.',
	['error.badRequest'] = 'That request could not be read.',
	['error.tooFast'] = 'Slow down.',
	['error.noPermission'] = 'You may not do that.',
})
