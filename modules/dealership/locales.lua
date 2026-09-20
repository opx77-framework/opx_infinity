--- Player-facing text for the strip row, the buy list, every refusal and the
--- command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A dealer's LABEL and a car's name are the operator's own words and
-- live in config, not here -- which is why the price arrives already formatted
-- and no currency is named in these strings.

local EN = {
	['dealership.title'] = 'DEALERSHIP',
	['dealership.refused'] = 'That could not be done.',

	['dealership.key.use'] = 'Open the dealership',
	['dealership.prompt.garage'] = 'Browse vehicles',
	['dealership.prompt.avpad'] = 'Browse AVs',

	['dealership.close'] = 'Close',
	['dealership.back'] = 'Back',
	['dealership.deliverHere'] = 'Deliver here',

	['dealership.bought'] = 'You bought {model}. Plate {plate}.',

	['dealership.noSuchSpot'] = 'There is no dealership here.',
	['dealership.noSuchEntry'] = 'That is not something this dealership sells.',
	['dealership.notSold'] = 'This dealership does not sell that.',
	['dealership.noSuchGarage'] = 'That is not a garage of yours you can deliver to.',
	['dealership.nothingForSale'] = 'This dealership has nothing in stock.',
	['dealership.noList'] = 'The list could not be opened. Use the buy command instead.',
	['dealership.noCharacter'] = 'Your record could not be read.',
	['dealership.noPosition'] = 'Your position could not be read.',
	['dealership.wrongBucket'] = 'That marker is not the one in front of you.',
	['dealership.tooFar'] = 'You are too far from the dealer. Stand on the marker and try again.',
	['dealership.cannotAfford'] = 'You cannot afford that.',
	['dealership.noCurrency'] = 'Prices on this server are in a currency that does not exist here. ' ..
		'Tell an operator.',
	['dealership.paymentFailed'] = 'The payment was refused.',
	['dealership.registerFailed'] = 'That vehicle could not be stored, so it was not sold.',
	['dealership.noVehicles'] = 'Vehicles are unavailable on this server.',
	['dealership.captureFailed'] = 'That dealership could not be saved.',
	['dealership.captureNoAnswer'] =
		'Your client did not answer the capture, so {key} was NOT saved. Stand where ' ..
		'you want it and run the command again.',

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Deliver the {model}',
	['dealership.menu.pay'] = 'You pay {price}',
	['dealership.dest.none'] = 'Your default garage',

	['dealership.help.add'] = 'Put a dealership marker where you are standing.',
	['dealership.help.addKind'] = "either 'garage' (sells vehicles) or 'avpad' (sells AVs)",
	['dealership.help.addKey'] = 'durable name for the dealer, e.g. dealer_watson',
	['dealership.help.addLabel'] = 'what players read; the name itself when omitted',
	['dealership.help.remove'] = 'Delete a captured dealership. One from config is not removable here.',
	['dealership.help.removeKey'] = 'the name the dealership was captured under',
	['dealership.help.list'] = 'Show every dealership: kind, position and where it comes from.',
	['dealership.help.stock'] = 'Show what is for sale, and which kind of dealer sells it.',
	['dealership.help.buy'] = 'Buy a model while standing on a dealership marker.',
	['dealership.help.buyKey'] = 'the stock key, as the stock command lists it',
	['dealership.help.buyGarage'] = 'the garage to deliver it to; your default when omitted',
}

local FR = {
	['dealership.title'] = 'CONCESSION',
	['dealership.refused'] = "Cela n'a pas pu être fait.",

	['dealership.key.use'] = 'Ouvrir la concession',
	['dealership.prompt.garage'] = 'Voir les véhicules',
	['dealership.prompt.avpad'] = 'Voir les AV',

	['dealership.close'] = 'Fermer',
	['dealership.back'] = 'Retour',
	['dealership.deliverHere'] = 'Livrer ici',

	['dealership.bought'] = 'Vous avez acheté : {model}. Plaque {plate}.',

	['dealership.noSuchSpot'] = "Il n'y a pas de concession ici.",
	['dealership.noSuchEntry'] = "Cette concession ne vend pas cela.",
	['dealership.notSold'] = 'Cette concession ne vend pas cela.',
	['dealership.noSuchGarage'] = "Ce n'est pas un de vos garages où livrer.",
	['dealership.nothingForSale'] = "Cette concession n'a rien en stock.",
	['dealership.noList'] = "La liste n'a pas pu être ouverte. Utilisez la commande d'achat.",
	['dealership.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['dealership.noPosition'] = "Votre position n'a pas pu être lue.",
	['dealership.wrongBucket'] = "Ce marqueur n'est pas celui devant vous.",
	['dealership.tooFar'] = 'Vous êtes trop loin du concessionnaire. Mettez-vous sur le marqueur.',
	['dealership.cannotAfford'] = 'Vous ne pouvez pas vous le permettre.',
	['dealership.noCurrency'] = "Les prix de ce serveur sont dans une monnaie qui n'existe pas ici. " ..
		'Prévenez un opérateur.',
	['dealership.paymentFailed'] = 'Le paiement a été refusé.',
	['dealership.registerFailed'] = "Ce véhicule n'a pas pu être enregistré, il ne vous a donc pas été vendu.",
	['dealership.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',
	['dealership.captureFailed'] = "Cette concession n'a pas pu être enregistrée.",
	['dealership.captureNoAnswer'] =
		'Votre client n’a pas répondu à la capture : {key} n’a PAS été enregistré. '
		.. 'Placez-vous où vous le voulez et relancez la commande.',

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Livrer la {model}',
	['dealership.menu.pay'] = 'Vous payez {price}',
	['dealership.dest.none'] = 'Votre garage par défaut',

	['dealership.help.add'] = 'Place un marqueur de concession là où vous êtes.',
	['dealership.help.addKind'] = "soit 'garage' (véhicules), soit 'avpad' (AV)",
	['dealership.help.addKey'] = 'nom durable de la concession, ex. dealer_watson',
	['dealership.help.addLabel'] = 'ce que lisent les joueurs ; le nom si omis',
	['dealership.help.remove'] = "Supprime une concession capturée. Une concession de config ne l'est pas ici.",
	['dealership.help.removeKey'] = 'le nom sous lequel la concession a été capturée',
	['dealership.help.list'] = 'Affiche chaque concession : type, position et origine.',
	['dealership.help.stock'] = 'Affiche ce qui est en vente et quel type de concessionnaire le vend.',
	['dealership.help.buy'] = 'Achète un modèle en étant sur un marqueur de concession.',
	['dealership.help.buyKey'] = 'la clé du stock, telle que la commande stock la liste',
	['dealership.help.buyGarage'] = 'le garage où livrer ; votre garage par défaut si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
