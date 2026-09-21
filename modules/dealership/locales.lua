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

	-- The showroom floor, placed from the staff menu's Dev screen.
	['dealership.previewsOff'] = 'Showroom cars are switched off on this server.',
	['dealership.previewPlaced'] = 'A {model} is standing here now.',
	['dealership.previewRemoved'] = 'That showroom car is gone.',
	['dealership.previewLimit'] = 'This showroom is already full ({key} cars).',
	['dealership.noSuchPreview'] = 'There is no showroom car by that name.',
	['dealership.placeFailed'] = 'That showroom car could not be placed.',

	-- Selling face to face, and the two ends of it: the salesperson who offers
	-- and the buyer who answers.
	['dealership.target.sell'] = 'Sell a vehicle',
	['dealership.offerSent'] = 'Offer sent. They have to accept it themselves.',
	['dealership.offerAccept'] = 'Buy it',
	['dealership.offerDecline'] = 'No thanks',
	['dealership.offerDeclined'] = 'They turned the offer down.',
	['dealership.offerExpired'] = 'The offer was not answered in time.',
	['dealership.noOffer'] = 'There is no offer waiting for you.',
	['dealership.noCompany'] =
		'You have no job or gang to sell for, so there is nowhere to pay the money in.',
	['dealership.noSuchBuyer'] = 'That is not somebody you can sell to.',
	['dealership.notInZone'] = 'You have to be inside a dealership to do that.',
	['dealership.buyerNotInZone'] = 'They are not inside the dealership.',
	['dealership.buyerCannotAfford'] = 'They cannot afford that.',
	['dealership.buyerGone'] = 'They are no longer here.',
	['dealership.sellerGone'] = 'The seller is no longer here.',
	['dealership.commission'] = 'You earned {amount} on the {model}.',

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Deliver the {model}',
	['dealership.menu.pay'] = 'You pay {price}',
	['dealership.menu.sell'] = 'Sell to {player}',
	['dealership.menu.sellHint'] = 'They have to accept the offer themselves.',
	['dealership.menu.offer'] = 'Buy the {model}?',
	['dealership.menu.offerHint'] = '{seller} is offering it to you for {price}',
	['dealership.dest.none'] = 'Your default garage',

	['dealership.help.list'] = 'Show every dealership and showroom car: kind, position and origin.',
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

	['dealership.previewsOff'] = "Les véhicules d'exposition sont désactivés sur ce serveur.",
	['dealership.previewPlaced'] = 'Une {model} est exposée ici.',
	['dealership.previewRemoved'] = "Ce véhicule d'exposition a été retiré.",
	['dealership.previewLimit'] = 'Ce hall est déjà plein ({key} véhicules).',
	['dealership.noSuchPreview'] = "Aucun véhicule d'exposition ne porte ce nom.",
	['dealership.placeFailed'] = "Ce véhicule d'exposition n'a pas pu être placé.",

	['dealership.target.sell'] = 'Vendre un véhicule',
	['dealership.offerSent'] = "Offre envoyée. La personne doit l'accepter elle-même.",
	['dealership.offerAccept'] = 'Acheter',
	['dealership.offerDecline'] = 'Non merci',
	['dealership.offerDeclined'] = "L'offre a été refusée.",
	['dealership.offerExpired'] = "L'offre n'a pas eu de réponse à temps.",
	['dealership.noOffer'] = "Aucune offre ne vous attend.",
	['dealership.noCompany'] =
		"Vous n'avez ni emploi ni gang pour vendre : l'argent n'aurait nulle part où aller.",
	['dealership.noSuchBuyer'] = "Ce n'est pas quelqu'un à qui vous pouvez vendre.",
	['dealership.notInZone'] = 'Vous devez être dans une concession pour faire cela.',
	['dealership.buyerNotInZone'] = "Cette personne n'est pas dans la concession.",
	['dealership.buyerCannotAfford'] = 'Cette personne ne peut pas se le permettre.',
	['dealership.buyerGone'] = "Cette personne n'est plus là.",
	['dealership.sellerGone'] = "Le vendeur n'est plus là.",
	['dealership.commission'] = 'Vous avez gagné {amount} sur la {model}.',

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Livrer la {model}',
	['dealership.menu.pay'] = 'Vous payez {price}',
	['dealership.menu.sell'] = 'Vendre à {player}',
	['dealership.menu.sellHint'] = "La personne doit accepter l'offre elle-même.",
	['dealership.menu.offer'] = 'Acheter la {model} ?',
	['dealership.menu.offerHint'] = '{seller} vous la propose pour {price}',
	['dealership.dest.none'] = 'Votre garage par défaut',

	['dealership.help.list'] = "Affiche chaque concession et véhicule d'exposition : type, position et origine.",
	['dealership.help.stock'] = 'Affiche ce qui est en vente et quel type de concessionnaire le vend.',
	['dealership.help.buy'] = 'Achète un modèle en étant sur un marqueur de concession.',
	['dealership.help.buyKey'] = 'la clé du stock, telle que la commande stock la liste',
	['dealership.help.buyGarage'] = 'le garage où livrer ; votre garage par défaut si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
