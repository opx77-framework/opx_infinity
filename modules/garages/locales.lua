--- Player-facing text for the strip row, the list, every refusal and the
--- command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A garage's LABEL is the operator's own words and lives in config, not
-- here.

local EN = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = 'That could not be done.',
	['garages.close'] = 'Close',

	['garages.key.use'] = 'Open a garage, or put a vehicle away',
	['garages.prompt.garage'] = 'Open your garage',
	['garages.prompt.avpad'] = 'Open your hangar',
	-- Said at a DOOR rather than at a menu point: one takes a vehicle in and the
	-- other opens a list, and a player who cannot tell them apart drives into the
	-- wrong one.
	['garages.prompt.putAway'] = 'Put your vehicle away',
	['garages.prompt.driveIn'] = 'Drive in to store a vehicle',

	-- The two things a row in the list can be. A garage is in several places
	-- now, so "the car you left here" and "the car you left at the other end of
	-- the city, which will be fetched to here" are different facts about it.
	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Parked here',
	['garages.list.away'] = 'Elsewhere',

	['garages.broughtOut'] = 'Brought out {plate}.',
	['garages.storedAway'] = 'Put away {plate}.',

	['garages.noSuchSpot'] = 'There is no garage here.',
	['garages.noCharacter'] = 'Your record could not be read.',
	['garages.noPosition'] = 'Your position could not be read.',
	['garages.wrongBucket'] = 'That marker is not the one in front of you.',
	['garages.tooFar'] = 'You are too far from the marker. Stand on it and try again.',
	['garages.nothingHere'] = 'You own nothing that comes out here.',
	['garages.notYours'] = 'That vehicle of yours does not come out here.',
	-- EVERY EXIT IS TAKEN. The owner chose a refusal over a queue and over
	-- creating the vehicle inside the car already parked there, so this says what
	-- is wrong and what to do about it rather than apologising.
	['garages.noFreeExit'] =
		'Every exit at {garage} is blocked. Move what is parked there and try again.',
	['garages.rateLimited'] = 'Slow down and try again in a moment.',
	['garages.noVehicles'] = 'Vehicles are unavailable on this server.',

	['garages.help.list'] = 'Show every garage: kind, locations and where it comes from.',
	['garages.help.bring'] = 'Bring your own vehicle out at a garage you are standing at.',
	['garages.help.bringKey'] = 'the garage name; the nearest point when omitted',
	['garages.help.bringPlate'] = 'a plate you own; the first eligible one when omitted',
}

local FR = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = "Cela n'a pas pu être fait.",
	['garages.close'] = 'Fermer',

	['garages.key.use'] = 'Ouvrir un garage ou ranger un véhicule',
	['garages.prompt.garage'] = 'Ouvrir votre garage',
	['garages.prompt.avpad'] = 'Ouvrir votre hangar',
	['garages.prompt.putAway'] = 'Ranger votre véhicule',
	['garages.prompt.driveIn'] = 'Entrez pour ranger un véhicule',

	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Garé ici',
	['garages.list.away'] = 'Ailleurs',

	['garages.broughtOut'] = 'Sorti : {plate}.',
	['garages.storedAway'] = 'Rangé : {plate}.',

	['garages.noSuchSpot'] = 'Il n’y a pas de garage ici.',
	['garages.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['garages.noPosition'] = "Votre position n'a pas pu être lue.",
	['garages.wrongBucket'] = "Ce marqueur n'est pas celui devant vous.",
	['garages.tooFar'] = 'Vous êtes trop loin du marqueur. Mettez-vous dessus.',
	['garages.nothingHere'] = 'Vous ne possédez rien qui sorte ici.',
	['garages.notYours'] = "Ce véhicule ne sort pas ici.",
	['garages.noFreeExit'] =
		'Toutes les sorties de {garage} sont bloquées. Dégagez-en une et réessayez.',
	['garages.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['garages.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',

	['garages.help.list'] = 'Affiche chaque garage : type, emplacements et origine.',
	['garages.help.bring'] = 'Sort votre propre véhicule à un garage où vous êtes.',
	['garages.help.bringKey'] = 'le nom du garage ; le point le plus proche si omis',
	['garages.help.bringPlate'] = 'une plaque à vous ; la première éligible si omise',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
