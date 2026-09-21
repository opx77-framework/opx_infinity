--- Player-facing text for the strip row, every refusal and the command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A spot's LABEL is the operator's own words and lives in config, not
-- here.

local EN = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = 'That could not be done.',

	['garages.key.use'] = 'Bring out or put away a vehicle',
	['garages.prompt.garage'] = 'Bring out a vehicle',
	['garages.prompt.avpad'] = 'Bring out an AV',
	-- Said instead of the two above while the player is sitting in one of their
	-- own vehicles, because that is what the same key does then.
	['garages.prompt.putAway'] = 'Put your vehicle away',

	['garages.broughtOut'] = 'Brought out {plate}.',
	['garages.storedAway'] = 'Put away {plate}.',

	['garages.noSuchSpot'] = 'There is no garage here.',
	['garages.noCharacter'] = 'Your record could not be read.',
	['garages.noPosition'] = 'Your position could not be read.',
	['garages.wrongBucket'] = 'That marker is not the one in front of you.',
	['garages.tooFar'] = 'You are too far from the marker. Stand on it and try again.',
	['garages.nothingHere'] = 'You own nothing that comes out here.',
	['garages.notYours'] = 'That vehicle of yours does not come out here.',
	['garages.rateLimited'] = 'Slow down and try again in a moment.',
	['garages.noVehicles'] = 'Vehicles are unavailable on this server.',
	['garages.captureFailed'] = 'That spot could not be saved.',
	['garages.captureNoAnswer'] =
		'Your client did not answer the capture, so {key} was NOT saved. Stand where ' ..
		'you want it and run the command again.',

	['garages.help.add'] = 'Put a garage or AV pad marker where you are standing.',
	['garages.help.addKind'] = "either 'garage' or 'avpad'",
	['garages.help.addKey'] = 'durable name for the spot, e.g. garage_watson',
	['garages.help.addLabel'] = 'what players read; the name itself when omitted',
	['garages.help.remove'] = 'Delete a captured spot. A spot from config is not removable here.',
	['garages.help.removeKey'] = 'the name the spot was captured under',
	['garages.help.list'] = 'Show every garage and AV pad: kind, position and where it comes from.',
	['garages.help.bring'] = 'Bring your own vehicle out at a spot you are standing on.',
	['garages.help.bringKey'] = 'the spot name; the nearest one when omitted',
	['garages.help.bringPlate'] = 'a plate you own; the first eligible one when omitted',
}

local FR = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = "Cela n'a pas pu être fait.",

	['garages.key.use'] = 'Sortir ou ranger un véhicule',
	['garages.prompt.garage'] = 'Sortir un véhicule',
	['garages.prompt.avpad'] = 'Sortir un AV',
	['garages.prompt.putAway'] = 'Ranger votre véhicule',

	['garages.broughtOut'] = 'Sorti : {plate}.',
	['garages.storedAway'] = 'Rangé : {plate}.',

	['garages.noSuchSpot'] = 'Il n’y a pas de garage ici.',
	['garages.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['garages.noPosition'] = "Votre position n'a pas pu être lue.",
	['garages.wrongBucket'] = "Ce marqueur n'est pas celui devant vous.",
	['garages.tooFar'] = 'Vous êtes trop loin du marqueur. Mettez-vous dessus.',
	['garages.nothingHere'] = 'Vous ne possédez rien qui sorte ici.',
	['garages.notYours'] = "Ce véhicule ne sort pas ici.",
	['garages.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['garages.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',
	['garages.captureFailed'] = "Ce point n'a pas pu être enregistré.",
	['garages.captureNoAnswer'] =
		'Votre client n’a pas répondu à la capture : {key} n’a PAS été enregistré. '
		.. 'Placez-vous où vous le voulez et relancez la commande.',

	['garages.help.add'] = 'Place un marqueur de garage ou de pad AV là où vous êtes.',
	['garages.help.addKind'] = "soit 'garage', soit 'avpad'",
	['garages.help.addKey'] = 'nom durable du point, ex. garage_watson',
	['garages.help.addLabel'] = 'ce que lisent les joueurs ; le nom si omis',
	['garages.help.remove'] = "Supprime un point capturé. Un point de config ne l'est pas ici.",
	['garages.help.removeKey'] = 'le nom sous lequel le point a été capturé',
	['garages.help.list'] = 'Affiche chaque garage et pad AV : type, position et origine.',
	['garages.help.bring'] = 'Sort votre propre véhicule à un point où vous êtes.',
	['garages.help.bringKey'] = 'le nom du point ; le plus proche si omis',
	['garages.help.bringPlate'] = 'une plaque à vous ; la première éligible si omise',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
