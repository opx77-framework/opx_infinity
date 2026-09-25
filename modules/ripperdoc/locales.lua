--- Player-facing text for the ripperdoc clinic: the tray, the chair, what the
-- ledger says when it moves, and every refusal.
-- @author XEROX710
--
-- Log lines and error codes stay in English: a log is read by an operator, and
-- a code is read by a script. Every string a player can see is here twice.

local EN = {
	['ripperdoc.title'] = 'RIPPERDOC',
	['ripperdoc.key.use'] = 'Ripperdoc chair',
	['ripperdoc.prompt'] = 'Sit / Attend',

	-- The two heads: the tray the patient reads, the desk the operator works.
	['ripperdoc.tray'] = 'TRAY',
	['ripperdoc.desk'] = 'DESK',
	['ripperdoc.chair'] = '{name}',
	['ripperdoc.patient'] = 'PATIENT {name}',
	['ripperdoc.vacant'] = 'NO PATIENT SEATED',
	['ripperdoc.self'] = 'SELF-SERVICE',
	['ripperdoc.attended'] = 'ATTENDED',
	['ripperdoc.invitees'] = 'AT THE CHAIR',
	['ripperdoc.noInvitees'] = 'Nobody is within reach of the chair.',

	-- The tray's content. Every number in a row is one the definition carries.
	['ripperdoc.item.arms'] = 'Gorilla Arms',
	['ripperdoc.item.legs'] = 'Double-Jump Legs',
	['ripperdoc.grade.arms.street'] = 'Street Grade',
	['ripperdoc.grade.arms.elite'] = 'Elite Grade',
	['ripperdoc.grade.legs.training'] = 'Training',
	['ripperdoc.grade.legs.athlete'] = 'Athlete',

	['ripperdoc.slot.arms'] = 'ARMS',
	['ripperdoc.slot.legs'] = 'LEGS',
	['ripperdoc.stat.normalDamage'] = 'STRIKE',
	['ripperdoc.stat.chargedDamage'] = 'CHARGED',
	['ripperdoc.stat.knockbackMeters'] = 'KNOCKBACK',
	['ripperdoc.stat.cooldownMs'] = 'COOLDOWN',
	['ripperdoc.stat.chargeMs'] = 'CHARGE',
	['ripperdoc.stat.jumpStaminaCost'] = 'JUMP COST',
	['ripperdoc.stat.maxAirborneMs'] = 'AIRTIME',
	['ripperdoc.stat.maxFallSpeed'] = 'FALL CAP',

	-- The verbs, with the price spoken in them.
	['ripperdoc.price'] = '€$ {price}',
	['ripperdoc.fit'] = 'FIT {price}',
	['ripperdoc.pull'] = 'PULL {price}',
	['ripperdoc.fitted'] = 'FITTED',
	['ripperdoc.empty'] = 'EMPTY',
	['ripperdoc.removeFirst'] = 'PULL FIRST',
	['ripperdoc.offerSeat'] = 'OFFER SEAT',
	['ripperdoc.leave'] = 'STAND',
	['ripperdoc.stepAway'] = 'STEP AWAY',

	-- The one offer at a time, as both sides read it.
	['ripperdoc.offer'] = 'THE RIPPERDOC OFFERS',
	['ripperdoc.offerSelf'] = 'CONFIRM',
	['ripperdoc.offerFit'] = 'Fit {name} for {price}?',
	['ripperdoc.offerPull'] = 'Pull {name} for {price}?',
	['ripperdoc.accept'] = 'ACCEPT',
	['ripperdoc.decline'] = 'DECLINE',
	['ripperdoc.working'] = 'WORK IN PROGRESS',

	-- The option to sit.
	['ripperdoc.invite'] = '{from} OFFERS YOU THE CHAIR',
	['ripperdoc.offerDeclined'] = 'They declined.',
	['ripperdoc.inviteDeclined'] = 'The offer was declined.',

	-- The ledger, when it moves.
	['ripperdoc.done.fit'] = '{grade} installed.',
	['ripperdoc.done.pull'] = 'The chrome is out.',
	['ripperdoc.done.paid'] = '+{points} PTS',

	-- ONE TABLE, TWO READERS: these are `M.Ripper.Refusal`'s sentences.
	['ripperdoc.noCharacter'] = 'Your record could not be read.',
	['ripperdoc.noSuchChair'] = 'There is no chair there.',
	['ripperdoc.noSuchEntry'] = 'This clinic does not carry that.',
	['ripperdoc.noSuchGrade'] = 'There is no grade {grade} on the tray.',
	['ripperdoc.noSuchTarget'] = 'They are not here.',
	['ripperdoc.tooFar'] = 'Get closer to the chair.',
	['ripperdoc.taken'] = 'The chair is taken.',
	['ripperdoc.seated'] = 'You are already at a chair.',
	['ripperdoc.notRipperdoc'] = 'You are not the operator here.',
	['ripperdoc.noPatient'] = 'Nobody is in the chair.',
	['ripperdoc.busy'] = 'One job at a time.',
	['ripperdoc.slotFilled'] = 'Something is already in the {slot} slot.',
	['ripperdoc.slotEmpty'] = 'There is nothing in the {slot} slot.',
	['ripperdoc.noOffer'] = 'There is no offer waiting.',
	['ripperdoc.noInvite'] = 'Nobody offered you the chair.',
	['ripperdoc.cannotPay'] = 'You cannot cover that.',
	['ripperdoc.notReady'] = 'The record is not ready. Try again.',
	['ripperdoc.hostRefused'] = 'The work was refused: {why}',
	['ripperdoc.noHost'] = 'No chair workspot on this host.',

	-- The placement commands.
	['ripperdoc.help.add'] = 'Capture a ripperdoc chair where you stand.',
	['ripperdoc.help.addKey'] = 'The durable name (generated when omitted).',
	['ripperdoc.help.addLabel'] = "The operator's own words on the chair.",
	['ripperdoc.help.remove'] = 'Remove a captured chair.',
	['ripperdoc.help.removeKey'] = 'The key the chair was captured under.',
	['ripperdoc.help.list'] = 'List every chair and where it comes from.',
	['ripperdoc.captureNoAnswer'] = 'The chair {key} was not saved: the capture was never answered.',
}

local FR = {
	['ripperdoc.title'] = 'RIPPERDOC',
	['ripperdoc.key.use'] = 'Fauteuil de ripperdoc',
	['ripperdoc.prompt'] = "S'asseoir / Servir",

	['ripperdoc.tray'] = 'PLATEAU',
	['ripperdoc.desk'] = 'BUREAU',
	['ripperdoc.chair'] = '{name}',
	['ripperdoc.patient'] = 'PATIENT {name}',
	['ripperdoc.vacant'] = 'AUCUN PATIENT',
	['ripperdoc.self'] = 'LIBRE SERVICE',
	['ripperdoc.attended'] = 'PRIS EN CHARGE',
	['ripperdoc.invitees'] = 'PRÈS DU FAUTEUIL',
	['ripperdoc.noInvitees'] = 'Personne à portée du fauteuil.',

	['ripperdoc.item.arms'] = 'Braces Gorilles',
	['ripperdoc.item.legs'] = 'Jambes Double Saut',
	['ripperdoc.grade.arms.street'] = 'Qualité Rue',
	['ripperdoc.grade.arms.elite'] = 'Qualité Élite',
	['ripperdoc.grade.legs.training'] = 'Entraînement',
	['ripperdoc.grade.legs.athlete'] = 'Athlète',

	['ripperdoc.slot.arms'] = 'BRAS',
	['ripperdoc.slot.legs'] = 'JAMBES',
	['ripperdoc.stat.normalDamage'] = 'COUP',
	['ripperdoc.stat.chargedDamage'] = 'CHARGÉ',
	['ripperdoc.stat.knockbackMeters'] = 'RECUL',
	['ripperdoc.stat.cooldownMs'] = 'RECHARGE',
	['ripperdoc.stat.chargeMs'] = 'CHARGE',
	['ripperdoc.stat.jumpStaminaCost'] = 'COÛT SAUT',
	['ripperdoc.stat.maxAirborneMs'] = 'AIRIEN',
	['ripperdoc.stat.maxFallSpeed'] = 'LIMITE CHUTE',

	['ripperdoc.price'] = '€$ {price}',
	['ripperdoc.fit'] = 'POSER {price}',
	['ripperdoc.pull'] = 'RETIRER {price}',
	['ripperdoc.fitted'] = 'POSÉ',
	['ripperdoc.empty'] = 'VIDE',
	['ripperdoc.removeFirst'] = 'RETIRER D’ABORD',
	['ripperdoc.offerSeat'] = 'PROPOSER LE FAUTEUIL',
	['ripperdoc.leave'] = 'SE LEVER',
	['ripperdoc.stepAway'] = "S'ÉCARTER",

	['ripperdoc.offer'] = 'LE RIPPERDOC PROPOSE',
	['ripperdoc.offerSelf'] = 'CONFIRMER',
	['ripperdoc.offerFit'] = 'Poser {name} pour {price} ?',
	['ripperdoc.offerPull'] = 'Retirer {name} pour {price} ?',
	['ripperdoc.accept'] = 'ACCEPTER',
	['ripperdoc.decline'] = 'REFUSER',
	['ripperdoc.working'] = 'TRAVAIL EN COURS',

	['ripperdoc.invite'] = '{from} VOUS PROPOSE LE FAUTEUIL',
	['ripperdoc.offerDeclined'] = 'Refusé.',
	['ripperdoc.inviteDeclined'] = "L'offre a été refusée.",

	['ripperdoc.done.fit'] = '{grade} installé.',
	['ripperdoc.done.pull'] = 'Le chrome est retiré.',
	['ripperdoc.done.paid'] = '+{points} PTS',

	['ripperdoc.noCharacter'] = 'Votre dossier n’a pas pu être lu.',
	['ripperdoc.noSuchChair'] = 'Aucun fauteuil ici.',
	['ripperdoc.noSuchEntry'] = 'Cette clinique n’a pas ça.',
	['ripperdoc.noSuchGrade'] = 'Aucune qualité {grade} sur le plateau.',
	['ripperdoc.noSuchTarget'] = 'Cette personne n’est pas là.',
	['ripperdoc.tooFar'] = 'Approchez-vous du fauteuil.',
	['ripperdoc.taken'] = 'Le fauteuil est occupé.',
	['ripperdoc.seated'] = 'Vous êtes déjà à un fauteuil.',
	['ripperdoc.notRipperdoc'] = "Vous n'êtes pas l'opérateur ici.",
	['ripperdoc.noPatient'] = 'Personne dans le fauteuil.',
	['ripperdoc.busy'] = 'Une opération à la fois.',
	['ripperdoc.slotFilled'] = 'Le slot {slot} est déjà occupé.',
	['ripperdoc.slotEmpty'] = 'Le slot {slot} est vide.',
	['ripperdoc.noOffer'] = 'Aucune offre en attente.',
	['ripperdoc.noInvite'] = 'Personne ne vous a proposé le fauteuil.',
	['ripperdoc.cannotPay'] = 'Vous ne pouvez pas payer ça.',
	['ripperdoc.notReady'] = 'Le dossier n’est pas prêt. Réessayez.',
	['ripperdoc.hostRefused'] = 'Travail refusé : {why}',
	['ripperdoc.noHost'] = 'Aucun fauteuil sur cet hôte.',

	-- Les commandes de placement.
	['ripperdoc.help.add'] = "Capture un fauteuil de ripperdoc là où vous êtes.",
	['ripperdoc.help.addKey'] = "Le nom durable (généré s'il est omis).",
	['ripperdoc.help.addLabel'] = "Les mots de l'opérateur sur le fauteuil.",
	['ripperdoc.help.remove'] = 'Retire un fauteuil capturé.',
	['ripperdoc.help.removeKey'] = 'La clé sous laquelle le fauteuil a été capturé.',
	['ripperdoc.help.list'] = 'Liste tous les fauteuils et leur origine.',
	['ripperdoc.captureNoAnswer'] = "Le fauteuil {key} n'a pas été enregistré : capture sans réponse.",
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
