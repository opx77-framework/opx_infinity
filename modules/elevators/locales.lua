--- Player-facing text for the panel and every refusal.
-- @author dop42
--
-- Log lines, the diagnostic report and the error codes themselves stay in
-- English. A floor's LABEL and REASON are the operator's own words and live in
-- config, not here.

local EN = {
	['elevators.title'] = 'ELEVATORS',
	['elevators.locked'] = 'Locked',
	['elevators.refused'] = 'That floor is not available.',

	['elevators.noElevatorNearby'] = 'You are not standing at an elevator.',
	['elevators.noSuchElevator'] = 'No such elevator.',
	['elevators.noSuchFloor'] = 'This elevator has no such floor.',
	['elevators.notAdopted'] = 'This elevator is not ready yet. Try again in a moment.',
	['elevators.floorOutOfRange'] = 'That floor is outside this elevator.',
	['elevators.moveRejected'] = 'The cabin would not move.',
	['elevators.notSent'] = 'That request could not be sent.',
	['elevators.rateLimited'] = 'Slow down and try again in a moment.',

	['elevators.noCharacter'] = 'Your record could not be read.',
	['elevators.jobStale'] = 'Your record is out of date. Try again in a moment.',
	['elevators.jobRequired'] = 'You do not hold the job this floor asks for.',
	['elevators.gradeTooLow'] = 'Your grade is too low for this floor.',
	['elevators.offDuty'] = 'You must be on duty for this floor.',

	['elevators.noPosition'] = 'Your position could not be read.',
	['elevators.wrongBucket'] = 'This elevator is not the one in front of you.',
	['elevators.tooFar'] = 'You are too far from the elevator.',

	['elevators.help.where'] = 'Show every elevator: its position, floors and adoption.',
	['elevators.help.whereKey'] = 'one of {keys}; every elevator when omitted',
}

local FR = {
	['elevators.title'] = 'ASCENSEURS',
	['elevators.locked'] = 'Verrouillé',
	['elevators.refused'] = "Cet étage n'est pas accessible.",

	['elevators.noElevatorNearby'] = "Vous n'êtes pas devant un ascenseur.",
	['elevators.noSuchElevator'] = "Cet ascenseur n'existe pas.",
	['elevators.noSuchFloor'] = "Cet ascenseur n'a pas cet étage.",
	['elevators.notAdopted'] = "Cet ascenseur n'est pas encore prêt. Patientez un instant.",
	['elevators.floorOutOfRange'] = 'Cet étage est hors de cet ascenseur.',
	['elevators.moveRejected'] = "La cabine n'a pas voulu bouger.",
	['elevators.notSent'] = "Cette demande n'a pas pu être envoyée.",
	['elevators.rateLimited'] = 'Ralentissez et réessayez dans un instant.',

	['elevators.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['elevators.jobStale'] = "Votre fiche n'est plus à jour. Réessayez dans un instant.",
	['elevators.jobRequired'] = "Vous n'exercez pas le métier demandé pour cet étage.",
	['elevators.gradeTooLow'] = 'Votre grade est trop bas pour cet étage.',
	['elevators.offDuty'] = 'Vous devez être en service pour cet étage.',

	['elevators.noPosition'] = "Votre position n'a pas pu être lue.",
	['elevators.wrongBucket'] = "Cet ascenseur n'est pas celui devant vous.",
	['elevators.tooFar'] = "Vous êtes trop loin de l'ascenseur.",

	['elevators.help.where'] = 'Affiche chaque ascenseur : position, étages et adoption.',
	['elevators.help.whereKey'] = 'parmi {keys} ; tous les ascenseurs si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
