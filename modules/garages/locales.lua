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
	['garages.prompt.driveIn'] = 'Take out your vehicle',

	-- The two things a row in the list can be. A garage is in several places
	-- now, so "the car you left here" and "the car you left at the other end of
	-- the city, which will be fetched to here" are different facts about it.
	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Parked here',
	['garages.list.away'] = 'Elsewhere',

	['garages.broughtOut'] = 'Brought out {plate}.',
	['garages.storedAway'] = 'Put away {plate}.',

	['garages.noSuchSpot'] = 'There is no garage here.',
	['garages.noCharacter'] = 'Your character is not loaded yet. Try again in a moment.',
	['garages.noPosition'] = 'Your position could not be read.',
	['garages.wrongBucket'] = 'You are not at this marker. Step onto it and try again.',
	['garages.tooFar'] = 'You are too far from the marker. Stand on it and try again.',
	['garages.nothingHere'] = 'You have no vehicle for this garage.',
	-- EVERY EXIT IS TAKEN. The owner chose a refusal over a queue and over
	-- creating the vehicle inside the car already parked there, so this says what
	-- is wrong and what to do about it rather than apologising.
	['garages.noFreeExit'] =
		'Every exit at {garage} is blocked. Move what is parked there and try again.',
	['garages.passengers'] = 'Your passengers have to get out before the car goes into {garage}.',
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
	['garages.prompt.driveIn'] = 'Sortir votre véhicule',

	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Garé ici',
	['garages.list.away'] = 'Ailleurs',

	['garages.broughtOut'] = 'Véhicule sorti : {plate}.',
	['garages.storedAway'] = 'Véhicule rangé : {plate}.',

	['garages.noSuchSpot'] = 'Il n’y a pas de garage ici.',
	['garages.noCharacter'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['garages.noPosition'] = "Votre position n'a pas pu être lue.",
	['garages.wrongBucket'] = "Vous n'êtes pas sur ce marqueur. Placez-vous dessus et réessayez.",
	['garages.tooFar'] = 'Vous êtes trop loin du marqueur. Mettez-vous dessus.',
	['garages.nothingHere'] = "Vous n'avez aucun véhicule pour ce garage.",
	['garages.noFreeExit'] =
		'Toutes les sorties de {garage} sont bloquées. Dégagez-en une et réessayez.',
	['garages.passengers'] = 'Vos passagers doivent descendre avant de ranger le véhicule dans {garage}.',
	['garages.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['garages.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',

	['garages.help.list'] = 'Affiche chaque garage : type, emplacements et origine.',
	['garages.help.bring'] = 'Sort votre propre véhicule à un garage où vous êtes.',
	['garages.help.bringKey'] = 'le nom du garage ; le point le plus proche si omis',
	['garages.help.bringPlate'] = 'une plaque à vous ; la première éligible si omise',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
