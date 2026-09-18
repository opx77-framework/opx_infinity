--- Player-facing text for the board, the legs, the payouts and every refusal.
-- @author dop42
--
-- Log lines and the error codes themselves stay in English. A gig's LABEL and
-- DESCRIPTION, and a point's LABEL, are the operator's own words and live in
-- `config/gigs.lua`, not here.

local EN = {
	['gigs.title'] = 'ODD JOBS',

	['gigs.board.take'] = 'Take the job: {gig}',

	['gigs.row.pick'] = 'Pick it up',
	['gigs.row.drop'] = 'Hand it in',
	['gigs.row.progress'] = 'Stop {index} of {total}',
	['gigs.row.abandon'] = 'Give up this job',

	['gigs.acting.pick'] = 'Working on it...',
	['gigs.acting.drop'] = 'Handing it over...',

	['gigs.leg.pick'] = 'Next stop ({index}/{total}): {place}',
	['gigs.leg.drop'] = 'Hand it in ({index}/{total}): {place}',

	['gigs.done.paid'] = 'Job done. {total} eddies, bonus included ({bonus}). Reputation: {reputation}.',
	['gigs.done.expired'] = 'The job went stale. You keep the {total} eddies you earned.',
	['gigs.done.abandoned'] = 'Job dropped. You keep the {total} eddies you earned.',
	['gigs.done.stopped'] = 'The job ended. You keep the {total} eddies you earned.',

	['gigs.refuse.generic'] = 'That did not work.',
	['gigs.refuse.noSuchGig'] = 'There is no such job here.',
	['gigs.refuse.notRunning'] = 'The job board is not taking anyone right now.',
	['gigs.refuse.alreadyWorking'] = 'You are already on a job. Finish it or give it up.',
	['gigs.refuse.notWorking'] = 'You are not on a job.',
	['gigs.refuse.staleRun'] = 'That job is over.',
	['gigs.refuse.staleLeg'] = 'That stop has already been done.',
	['gigs.refuse.rateLimited'] = 'Slow down and try again in a moment.',
	['gigs.refuse.noPosition'] = 'Your position could not be read.',
	['gigs.refuse.wrongBucket'] = 'That job is not the one in front of you.',
	['gigs.refuse.tooFar'] = 'You are too far from the spot.',
	['gigs.refuse.tooSoon'] = 'Not so fast. Do the work.',
	['gigs.refuse.notTrusted'] = 'Nobody hands that one to a stranger yet.',
	['gigs.refuse.dayFull'] = 'That is all the work there is today.',
	['gigs.refuse.cooling'] = 'Come back in {seconds} seconds.',
	['gigs.refuse.playerDown'] = 'Not from down there.',
	['gigs.refuse.noCharacter'] = 'Your record could not be read.',
	['gigs.refuse.notSent'] = 'That request could not be sent.',
	['gigs.refuse.internalError'] = 'Something went wrong. Try again.',

	['gigs.command.none'] = 'No job is on the board.',
	['gigs.command.reputation'] = 'Your reputation: {value}',
	['gigs.command.working'] = 'On the job {gig}: stop {index}/{total}, {earned} eddies so far.',

	['gigs.help.list'] = 'List every odd job, what it pays and where you stand with it.',
	['gigs.help.cancel'] = 'Give up the odd job you are on.',
}

local FR = {
	['gigs.title'] = 'PETITS BOULOTS',

	['gigs.board.take'] = 'Prendre le boulot : {gig}',

	['gigs.row.pick'] = 'Ramasser',
	['gigs.row.drop'] = 'Déposer',
	['gigs.row.progress'] = 'Arrêt {index} sur {total}',
	['gigs.row.abandon'] = 'Abandonner le boulot',

	['gigs.acting.pick'] = 'En cours...',
	['gigs.acting.drop'] = 'Remise en cours...',

	['gigs.leg.pick'] = 'Arrêt suivant ({index}/{total}) : {place}',
	['gigs.leg.drop'] = 'À déposer ({index}/{total}) : {place}',

	['gigs.done.paid'] = 'Boulot terminé. {total} eddies, prime comprise ({bonus}). Réputation : {reputation}.',
	['gigs.done.expired'] = 'Le boulot a traîné. Vous gardez les {total} eddies gagnés.',
	['gigs.done.abandoned'] = 'Boulot abandonné. Vous gardez les {total} eddies gagnés.',
	['gigs.done.stopped'] = 'Le boulot est terminé. Vous gardez les {total} eddies gagnés.',

	['gigs.refuse.generic'] = "Ça n'a pas marché.",
	['gigs.refuse.noSuchGig'] = "Il n'y a pas de boulot ici.",
	['gigs.refuse.notRunning'] = "Le tableau n'embauche personne pour le moment.",
	['gigs.refuse.alreadyWorking'] = 'Vous êtes déjà sur un boulot. Finissez-le ou abandonnez-le.',
	['gigs.refuse.notWorking'] = "Vous n'êtes sur aucun boulot.",
	['gigs.refuse.staleRun'] = 'Ce boulot est terminé.',
	['gigs.refuse.staleLeg'] = 'Cet arrêt est déjà fait.',
	['gigs.refuse.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['gigs.refuse.noPosition'] = "Votre position n'a pas pu être lue.",
	['gigs.refuse.wrongBucket'] = "Ce boulot n'est pas celui devant vous.",
	['gigs.refuse.tooFar'] = 'Vous êtes trop loin du point.',
	['gigs.refuse.tooSoon'] = 'Pas si vite. Faites le travail.',
	['gigs.refuse.notTrusted'] = 'Personne ne confie encore ça à un inconnu.',
	['gigs.refuse.dayFull'] = "C'est tout le travail qu'il y a aujourd'hui.",
	['gigs.refuse.cooling'] = 'Revenez dans {seconds} secondes.',
	['gigs.refuse.playerDown'] = "Pas depuis le sol.",
	['gigs.refuse.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['gigs.refuse.notSent'] = "Cette demande n'a pas pu être envoyée.",
	['gigs.refuse.internalError'] = "Quelque chose s'est mal passé. Réessayez.",

	['gigs.command.none'] = "Aucun boulot n'est affiché.",
	['gigs.command.reputation'] = 'Votre réputation : {value}',
	['gigs.command.working'] = 'Sur le boulot {gig} : arrêt {index}/{total}, {earned} eddies pour le moment.',

	['gigs.help.list'] = 'Affiche chaque petit boulot, ce qu\'il paie et où vous en êtes.',
	['gigs.help.cancel'] = 'Abandonne le petit boulot en cours.',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
