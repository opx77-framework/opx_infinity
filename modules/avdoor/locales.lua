--- Player-facing text for the AV door.
-- @author XEROX710

local EN = {
	['avdoor.title'] = 'AIRCRAFT',
	['avdoor.key.board'] = 'Board the aircraft',
	['avdoor.prompt.pilot'] = 'Board',
	['avdoor.prompt.passenger'] = 'Ride along',
	['avdoor.help.why'] = 'Why the aircraft nearest to you does or does not open its door to you',

	['avdoor.refused.noCharacter'] = 'Load a character first.',
	['avdoor.refused.noAircraft'] = 'There is no aircraft here.',
	['avdoor.refused.wrecked'] = 'That aircraft is wrecked.',
	['avdoor.refused.seated'] = 'You are already in a vehicle.',
	['avdoor.refused.down'] = 'You cannot board while down.',
	['avdoor.refused.noPosition'] = 'Your position could not be read.',
	['avdoor.refused.tooFar'] = 'Walk up to the aircraft\u{2019}s door.',
	['avdoor.refused.moving'] = 'The aircraft is still moving.',
	['avdoor.refused.notYours'] = 'That aircraft is not yours to fly.',
	['avdoor.refused.notCrew'] = 'Only its crew on duty may board that aircraft.',
	['avdoor.refused.noSeat'] = 'Every seat is taken.',
	['avdoor.refused.busy'] = 'One moment.',
	['avdoor.refused.failed'] = 'You could not get in: {reason}',
}

local FR = {
	['avdoor.title'] = 'AÉRONEF',
	['avdoor.key.board'] = 'Monter dans l\u{2019}aéronef',
	['avdoor.prompt.pilot'] = 'Monter',
	['avdoor.prompt.passenger'] = 'Monter en passager',
	['avdoor.help.why'] = 'Pourquoi l\u{2019}aéronef le plus proche vous ouvre ou non sa porte',

	['avdoor.refused.noCharacter'] = 'Chargez d\u{2019}abord un personnage.',
	['avdoor.refused.noAircraft'] = 'Il n\u{2019}y a pas d\u{2019}aéronef ici.',
	['avdoor.refused.wrecked'] = 'Cet aéronef est détruit.',
	['avdoor.refused.seated'] = 'Vous êtes déjà dans un véhicule.',
	['avdoor.refused.down'] = 'Impossible de monter à terre.',
	['avdoor.refused.noPosition'] = 'Votre position est illisible.',
	['avdoor.refused.tooFar'] = 'Approchez-vous de la porte de l\u{2019}aéronef.',
	['avdoor.refused.moving'] = 'L\u{2019}aéronef est encore en mouvement.',
	['avdoor.refused.notYours'] = 'Cet aéronef n\u{2019}est pas le vôtre.',
	['avdoor.refused.notCrew'] = 'Seul son équipage en service peut y monter.',
	['avdoor.refused.noSeat'] = 'Toutes les places sont prises.',
	['avdoor.refused.busy'] = 'Un instant.',
	['avdoor.refused.failed'] = 'Impossible de monter : {reason}',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
