--- Player-facing text for the rows, the bars and every refusal.
-- @author dop42
--
-- Log lines, the diagnostic and the refusal CODES themselves stay in English. A
-- site's LABEL and its TARGET wording are the operator's own words and live in
-- `config/hauling.lua`, not here.
--
-- `hauling.refused.generic` is load-bearing and not a filler. Several refusals a
-- player can see come straight off the host -- `Open77.props.attach` alone
-- answers eleven different reasons and the set grows with the platform -- so
-- there will never be a key for every one. The client checks `OPX.Locale.Exists`
-- and falls back here, because `locale` answers the KEY ITSELF for a string
-- nobody wrote and `hauling.refused.invalid_attachment_bone` on a player's screen
-- is worse than a sentence.

local EN = {
	['hauling.row.pickup'] = 'Pick up the crate',
	['hauling.row.pickupHint'] = 'Heavy. Get it into a vehicle.',
	['hauling.row.load'] = 'Load the crate',
	['hauling.row.deliver'] = 'Hand the crate over',

	['hauling.bar.pickup'] = 'Lifting the crate',
	['hauling.bar.load'] = 'Loading the crate',
	['hauling.bar.deliver'] = 'Handing the crate over',

	['hauling.paid'] = 'Delivered to {dropoff}. Paid {amount}.',

	['hauling.refused.generic'] = 'That did not work.',
	['hauling.refused.no_such_crate'] = 'That crate is not there any more.',
	['hauling.refused.already_claimed'] = 'Somebody got to it first.',
	['hauling.refused.already_carrying'] = 'Your hands are full.',
	['hauling.refused.stale_revision'] = 'That crate moved. Try it again.',
	['hauling.refused.claim_expired'] = 'You took too long, so the crate went back.',
	['hauling.refused.carry_dropped'] = 'You cannot get in with that. Load it into the bed.',
	['hauling.refused.too_soon'] = 'That was too quick to be real.',
	['hauling.refused.too_far'] = 'You are too far away.',
	['hauling.refused.wrong_bucket'] = 'That crate is not the one in front of you.',
	['hauling.refused.no_position'] = 'Your position could not be read.',
	['hauling.refused.not_carrying'] = 'You are not carrying anything.',
	['hauling.refused.not_loaded'] = 'That crate is not in a vehicle.',
	['hauling.refused.no_such_vehicle'] = 'That vehicle is not there.',
	['hauling.refused.no_bed_slot'] = 'There is nowhere in that vehicle to put it.',
	['hauling.refused.not_at_dropoff'] = 'The vehicle is not at a drop-off.',
	['hauling.refused.not_paid'] = 'The delivery could not be paid. Nothing was taken.',
	['hauling.refused.nothing_running'] = 'You were not doing anything.',
	['hauling.refused.rate_limited'] = 'Slow down and try again in a moment.',
	['hauling.refused.no_character'] = 'Your record could not be read.',
	['hauling.refused.job_required'] = 'You do not hold the job this site asks for.',
	['hauling.refused.grade_too_low'] = 'Your grade is too low for this site.',
	['hauling.refused.no_such_site'] = 'No such site.',
	['hauling.refused.no_carry_config'] = 'This server has not said how a crate is carried.',
}

local FR = {
	['hauling.row.pickup'] = 'Ramasser la caisse',
	['hauling.row.pickupHint'] = 'Lourde. À mettre dans un véhicule.',
	['hauling.row.load'] = 'Charger la caisse',
	['hauling.row.deliver'] = 'Livrer la caisse',

	['hauling.bar.pickup'] = 'Soulèvement de la caisse',
	['hauling.bar.load'] = 'Chargement de la caisse',
	['hauling.bar.deliver'] = 'Livraison de la caisse',

	['hauling.paid'] = 'Livrée à {dropoff}. Payé {amount}.',

	['hauling.refused.generic'] = "Cela n'a pas fonctionné.",
	['hauling.refused.no_such_crate'] = "Cette caisse n'est plus là.",
	['hauling.refused.already_claimed'] = "Quelqu'un vous a devancé.",
	['hauling.refused.already_carrying'] = 'Vous avez déjà les mains prises.',
	['hauling.refused.stale_revision'] = 'Cette caisse a bougé. Réessayez.',
	['hauling.refused.claim_expired'] = 'Vous avez trop attendu : la caisse est repartie.',
	['hauling.refused.carry_dropped'] = 'Impossible de monter avec. Chargez-la dans la benne.',
	['hauling.refused.too_soon'] = "C'était trop rapide pour être vrai.",
	['hauling.refused.too_far'] = 'Vous êtes trop loin.',
	['hauling.refused.wrong_bucket'] = "Cette caisse n'est pas celle devant vous.",
	['hauling.refused.no_position'] = "Votre position n'a pas pu être lue.",
	['hauling.refused.not_carrying'] = 'Vous ne portez rien.',
	['hauling.refused.not_loaded'] = "Cette caisse n'est pas dans un véhicule.",
	['hauling.refused.no_such_vehicle'] = "Ce véhicule n'existe pas.",
	['hauling.refused.no_bed_slot'] = 'Il n’y a pas de place pour elle dans ce véhicule.',
	['hauling.refused.not_at_dropoff'] = "Le véhicule n'est pas à un point de livraison.",
	['hauling.refused.not_paid'] = "La livraison n'a pas pu être payée. Rien n'a été pris.",
	['hauling.refused.nothing_running'] = 'Vous ne faisiez rien.',
	['hauling.refused.rate_limited'] = 'Ralentissez et réessayez dans un instant.',
	['hauling.refused.no_character'] = "Votre fiche n'a pas pu être lue.",
	['hauling.refused.job_required'] = "Vous n'exercez pas le métier demandé sur ce site.",
	['hauling.refused.grade_too_low'] = 'Votre grade est trop bas pour ce site.',
	['hauling.refused.no_such_site'] = "Ce site n'existe pas.",
	['hauling.refused.no_carry_config'] = "Ce serveur n'a pas dit comment une caisse se porte.",
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
