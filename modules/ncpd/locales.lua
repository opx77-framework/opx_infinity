--- Player-facing text for the wanted line, the command help and every refusal.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English: a log is read by an operator, and a code is read by a script.
-- `shared/law.lua`'s warning list is operator text too, and stays as it is.

local EN = {
	['ncpd.title'] = 'NCPD',
	['ncpd.refused'] = 'That could not be done.',

	-- The one line a wanted player sees. The division is the config's own label,
	-- so a server that renames MaxTac renames it here as well.
	['ncpd.wanted'] = 'Wanted: {division} responding ({stage}/6)',
	['ncpd.cleared'] = 'The city has lost interest.',

	-- Said when the engine's heat actually moved, which is the only moment the
	-- worth saying anything about: the stars are the engine's own HUD.
	['ncpd.heatRaised'] = '{division} is answering: heat {stage}/5.',
	['ncpd.maxtacInbound'] = 'MaxTac is inbound.',
	['ncpd.seamUnavailable'] = 'This client cannot raise a wanted level.',

	['ncpd.noCharacter'] = 'Your record could not be read.',
	['ncpd.noPosition'] = 'Your position could not be read.',
	['ncpd.noCitizen'] = 'That player has no loaded character to charge.',
	['ncpd.unknownLaw'] = 'No such offence.',
	['ncpd.unknownStage'] = 'That is not a heat stage.',
	['ncpd.offline'] = 'That player is not connected.',

	['ncpd.help.status'] = 'where the city stands on you, or on a named player',
	['ncpd.help.report'] = 'charge somebody with an offence from the law book',
	['ncpd.help.heat'] = 'put somebody straight onto a heat stage, for a job or a test',
	['ncpd.help.av'] = 'call the MaxTac AV for somebody, subject to the engine spacing',
	['ncpd.help.clear'] = 'forget everything the city holds against somebody',
	['ncpd.help.laws'] = 'every offence this server scores, and what it costs',
	['ncpd.help.law'] = 'a law id from the book (`/opx.ncpd.laws`)',
	['ncpd.help.stage'] = 'a heat stage, 0 to 5',
	['ncpd.help.player'] = 'a player id ; you, when omitted',
}

local FR = {
	['ncpd.title'] = 'NCPD',
	['ncpd.refused'] = 'Action impossible.',
	['ncpd.wanted'] = 'Recherché : {division} engagée ({stage}/6)',
	['ncpd.cleared'] = 'La ville ne s\u{2019}intéresse plus à vous.',
	['ncpd.heatRaised'] = '{division} répond : chaleur {stage}/5.',
	['ncpd.maxtacInbound'] = 'MaxTac arrive.',
	['ncpd.seamUnavailable'] = 'Ce client ne peut pas lever de niveau de recherche.',
	['ncpd.noCharacter'] = 'Votre fiche est illisible.',
	['ncpd.noPosition'] = 'Votre position est illisible.',
	['ncpd.noCitizen'] = 'Ce joueur n\u{2019}a pas de personnage chargé.',
	['ncpd.unknownLaw'] = 'Infraction inconnue.',
	['ncpd.unknownStage'] = 'Ce n\u{2019}est pas un palier de chaleur.',
	['ncpd.offline'] = 'Ce joueur n\u{2019}est pas connecté.',
	['ncpd.help.status'] = 'où en est la ville avec vous, ou avec un joueur nommé',
	['ncpd.help.report'] = 'inculper quelqu\u{2019}un d\u{2019}une infraction du code',
	['ncpd.help.heat'] = 'placer quelqu\u{2019}un sur un palier de chaleur, pour un job ou un test',
	['ncpd.help.av'] = 'appeler l\u{2019}AV MaxTac pour quelqu\u{2019}un, selon l\u{2019}espacement du moteur',
	['ncpd.help.clear'] = 'effacer tout ce que la ville reproche à quelqu\u{2019}un',
	['ncpd.help.laws'] = 'chaque infraction notée par ce serveur, et son coût',
	['ncpd.help.law'] = 'un identifiant du code (`/opx.ncpd.laws`)',
	['ncpd.help.stage'] = 'un palier de chaleur, 0 à 5',
	['ncpd.help.player'] = 'un identifiant de joueur ; vous, si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
