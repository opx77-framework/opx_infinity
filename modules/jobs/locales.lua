--- Player-facing text for the strip row, every refusal, the menus and the help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A board's LABEL is the operator's own words and lives in config, not
-- here, and so do job and grade names -- those are the character catalogue's.
--
-- EVERY REFUSAL THE SERVER CAN ANSWER WITH HAS A LINE HERE, which is what makes
-- `jobs.byInvitation` worth having as its own key: MaxTac does not take
-- walk-ins, and the menu says THAT rather than leaving a dead row or a bare no.

local EN = {
	['jobs.title'] = 'EMPLOYMENT',

	['jobs.key.use'] = 'Read the board or manage the roster',
	['jobs.prompt.signup'] = 'Read the work on offer',
	['jobs.prompt.boss'] = 'Manage the roster',

	-- ── the menu ────────────────────────────────────────────────────────────
	['jobs.menu.jobs'] = 'WORK ON OFFER',
	['jobs.menu.job'] = '{job}',
	['jobs.menu.desk'] = '{job} ROSTER',
	['jobs.menu.member'] = '{name}',
	['jobs.menu.hire'] = 'HIRE AT {job}',

	['jobs.row.close'] = 'Close',
	['jobs.row.back'] = 'Back',
	['jobs.row.join'] = 'Sign up',
	-- A job held beside the worked one: this row makes it the worked one.
	['jobs.row.work'] = 'Work this job',
	['jobs.row.leave'] = 'Hand in your notice',
	['jobs.row.hire'] = 'Hire somebody standing here',
	['jobs.row.fire'] = 'Dismiss',
	['jobs.row.promote'] = 'Promote',
	['jobs.row.demote'] = 'Demote',
	['jobs.row.entry'] = 'entry rank',
	['jobs.row.noMembers'] = 'Nobody holds this job yet.',
	['jobs.row.noCandidates'] = 'Nobody is standing close enough to hire.',

	-- A row's right-hand column: what the player's own standing is.
	['jobs.status.open'] = 'Open',
	['jobs.status.approval'] = 'By invitation only',
	['jobs.status.closed'] = 'Not on offer',
	['jobs.status.you'] = 'You',
	['jobs.status.boss'] = 'Boss',
	['jobs.status.top'] = 'Top rank',
	-- The time banked towards the next rank. It never moves the rank: the boss
	-- does, at the desk.
	-- A row's value is cut at 48 characters, grade name and all: keep it short.
	['jobs.status.progress'] = '{points} / {required} to {next}',
	-- Held beside the worked job: it banks no time and opens nothing.
	['jobs.status.idle'] = 'Held, not worked',
	['jobs.status.roster'] = '{count} member(s)  |  ladder {top} level(s)',
	['jobs.noList'] = 'The list could not be opened.',

	-- ── what the server says back ───────────────────────────────────────────
	['jobs.joined'] = 'You are on the books for {job}.',
	['jobs.joinedBeside'] =
		'You are on the books for {job}, beside the job you work. Choose "Work this job" ' ..
		'on its row to work it.',
	['jobs.working'] = 'You now work {job}.',
	['jobs.left'] = 'You have left {job}.',
	['jobs.hired'] = 'You have been taken on by {job}.',
	['jobs.hiredBeside'] =
		'You have been taken on by {job}, beside the job you work. Choose "Work this job" ' ..
		'on its row at the employment board to work it.',
	['jobs.fired'] = 'You have been dismissed from {job}.',
	-- {job} is the catalogue's own name for the job and {grade} the rank's.
	['jobs.promoted'] = 'You have been promoted to {grade} in {job}.',
	['jobs.demoted'] = 'You have been demoted to {grade} in {job}.',
	['jobs.deskDone'] = '{action} done.',

	-- ── a job offer: nobody is hired without saying yes ─────────────────────
	-- {boss} is the boss's character name, {name} the candidate's, {seconds}
	-- how long the offer stands.
	['jobs.menu.offer'] = 'JOB OFFER: {job}',
	['jobs.offer.text'] = '{boss} offers you a place in {job} as {grade}.',
	['jobs.offer.wait'] = 'Answer within {seconds} s',
	['jobs.row.accept'] = 'Accept',
	['jobs.row.refuse'] = 'Refuse',
	['jobs.offer.received'] = '{boss} offers you a place in {job}. Accept or refuse within {seconds} s.',
	['jobs.offer.sent'] = 'Offer sent to {name}. Waiting for their answer ({seconds} s).',
	['jobs.offer.accepted'] = '{name} accepted: they are on the books for {job}.',
	['jobs.offer.refused'] = '{name} turned down the place in {job}.',
	['jobs.offer.youRefused'] = 'You turned down the place in {job}.',
	['jobs.offer.expired'] = '{name} did not answer in time: the offer of {job} lapsed.',
	['jobs.offer.expiredYou'] = 'The offer of a place in {job} lapsed.',
	['jobs.offer.none'] = 'That offer is no longer open.',
	['jobs.offer.pending'] = 'That person is already answering another offer.',
	['jobs.candidateNotNear'] = 'That person has to be standing near you to be offered the job.',
	['jobs.refused'] = 'That could not be done.',

	['jobs.noCharacter'] = 'Your record could not be read.',
	['jobs.noPosition'] = 'Your position could not be read.',
	['jobs.wrongBucket'] = 'That marker is not the one in front of you.',
	['jobs.tooFar'] = 'You are too far from the marker. Stand on it and try again.',
	['jobs.noSuchBoard'] = 'There is no board here.',
	['jobs.noSuchJob'] = 'There is no such job here.',
	['jobs.alreadyMember'] = 'You already work that job.',
	['jobs.notMember'] = 'That person does not work this job.',
	['jobs.notYours'] = 'You do not hold that job.',
	['jobs.alreadyWorking'] = 'That is already the job you work.',
	['jobs.notOpen'] = 'That job is not on offer.',
	['jobs.byInvitation'] = 'That job is by invitation: somebody holding its boss rank has to take you on.',
	['jobs.needsJob'] = 'You do not work the job this one requires.',
	['jobs.needsGrade'] = 'Your rank is not high enough for this one.',
	['jobs.needsRight'] = 'You do not hold the clearance this one requires.',
	-- The same two refusals with the requirement named, which is what the board
	-- shows: the server says which job and which rank the terms ask for.
	['jobs.needsRank'] = 'Needs {need} {rank} or above',
	['jobs.needsJobNamed'] = 'Needs {need}',
	['jobs.lastBoss'] = 'That would leave the job with nobody in charge of it.',
	['jobs.notBoss'] = 'You do not hold the boss rank of that job.',
	['jobs.topRank'] = 'They already hold the top rank.',
	['jobs.bottomRank'] = 'They already hold the entry rank.',
	['jobs.candidateAway'] = 'That person is not standing close enough to the desk.',
	['jobs.rosterFailed'] = 'The roster could not be read.',
	['jobs.captureFailed'] = 'That board could not be saved.',
	['jobs.captureNoAnswer'] =
		'Your client did not answer the capture, so {key} was NOT saved. Stand where ' ..
		'you want it and run the command again.',

	-- ── the capture commands ────────────────────────────────────────────────
	['jobs.help.add'] = 'Put a jobs board where you are standing.',
	['jobs.help.addKind'] = "either 'signup' for the office or 'boss' for a division's desk",
	['jobs.help.addKey'] = 'durable name for the board, e.g. jobs_city',
	['jobs.help.addJob'] = 'the job the board is drawn for, e.g. ncpd',
	['jobs.help.remove'] = 'Delete a captured board. A board from config is not removable here.',
	['jobs.help.removeKey'] = 'the name the board was captured under',
	['jobs.help.list'] = 'Show every board: kind, job, position and where it comes from.',

	-- ── the desk commands ───────────────────────────────────────────────────
	['jobs.help.roster'] = 'List who holds a job, at which grade and with how much time served.',
	['jobs.help.rosterJob'] = 'the job, e.g. ncpd',
	['jobs.help.rank'] = 'Show a job ladder and where somebody stands on it.',
	['jobs.help.rankCitizen'] = 'a citizen id; you when omitted',
	['jobs.help.join'] = 'Put YOURSELF on a job at its entry rank.',
	['jobs.help.leave'] = 'Take YOURSELF off a job.',
	['jobs.help.promote'] = 'Move somebody one rank up. Needs the boss rank of that job.',
	['jobs.help.demote'] = 'Move somebody one rank down. Needs the boss rank of that job.',
	['jobs.help.fire'] = 'Dismiss somebody. Needs the boss rank of that job.',
	['jobs.help.hire'] = 'Offer somebody near you a place; they accept or refuse. Needs the boss rank of that job.',
	['jobs.help.hirePlayerId'] = 'the connection number of somebody standing near you',
}

local FR = {
	['jobs.title'] = 'EMPLOI',

	['jobs.key.use'] = 'Lire le tableau ou gérer l’effectif',
	['jobs.prompt.signup'] = 'Lire les emplois proposés',
	['jobs.prompt.boss'] = 'Gérer l’effectif',

	['jobs.menu.jobs'] = 'EMPLOIS PROPOSÉS',
	['jobs.menu.job'] = '{job}',
	['jobs.menu.desk'] = 'EFFECTIF {job}',
	['jobs.menu.member'] = '{name}',
	['jobs.menu.hire'] = 'EMBAUCHER CHEZ {job}',

	['jobs.row.close'] = 'Fermer',
	['jobs.row.back'] = 'Retour',
	['jobs.row.join'] = 'S’inscrire',
	['jobs.row.work'] = 'Exercer ce métier',
	['jobs.row.leave'] = 'Démissionner',
	['jobs.row.hire'] = 'Embaucher quelqu’un présent ici',
	['jobs.row.fire'] = 'Licencier',
	['jobs.row.promote'] = 'Promouvoir',
	['jobs.row.demote'] = 'Rétrograder',
	['jobs.row.entry'] = 'échelon d’entrée',
	['jobs.row.noMembers'] = 'Personne n’occupe encore cet emploi.',
	['jobs.row.noCandidates'] = 'Personne n’est assez proche pour être embauché.',

	['jobs.status.open'] = 'Ouvert',
	['jobs.status.approval'] = 'Sur invitation',
	['jobs.status.closed'] = 'Non proposé',
	['jobs.status.you'] = 'Vous',
	['jobs.status.boss'] = 'Chef',
	['jobs.status.top'] = 'Échelon le plus élevé',
	['jobs.status.progress'] = '{points} / {required} pour {next}',
	-- Court : la colonne est coupée à 48 caractères, grade compris.
	['jobs.status.idle'] = 'Non exercé',
	['jobs.status.roster'] = '{count} membre(s)  |  échelle {top} niveau(x)',
	['jobs.noList'] = 'La liste n’a pas pu s’ouvrir.',

	['jobs.joined'] = 'Vous êtes inscrit pour {job}.',
	['jobs.joinedBeside'] =
		'Vous êtes inscrit pour {job}, à côté du métier que vous exercez. Choisissez ' ..
		'« Exercer ce métier » sur sa ligne pour l’exercer.',
	['jobs.working'] = 'Vous exercez désormais {job}.',
	['jobs.left'] = 'Vous avez quitté {job}.',
	['jobs.hired'] = 'Vous avez été embauché par {job}.',
	['jobs.hiredBeside'] =
		'Vous avez été embauché par {job}, à côté du métier que vous exercez. Choisissez ' ..
		'« Exercer ce métier » sur sa ligne au bureau d’emploi pour l’exercer.',
	['jobs.fired'] = 'Vous avez été licencié de {job}.',
	['jobs.promoted'] = 'Vous avez été promu au grade {grade} dans {job}.',
	['jobs.demoted'] = 'Vous avez été rétrogradé au grade {grade} dans {job}.',
	['jobs.deskDone'] = '{action} effectué.',

	['jobs.menu.offer'] = 'OFFRE D’EMPLOI : {job}',
	['jobs.offer.text'] = '{boss} vous propose une place dans {job} au grade {grade}.',
	['jobs.offer.wait'] = 'Répondez sous {seconds} s',
	['jobs.row.accept'] = 'Accepter',
	['jobs.row.refuse'] = 'Refuser',
	['jobs.offer.received'] = '{boss} vous propose une place dans {job}. Acceptez ou refusez sous {seconds} s.',
	['jobs.offer.sent'] = 'Offre envoyée à {name}. En attente de sa réponse ({seconds} s).',
	['jobs.offer.accepted'] = '{name} a accepté : la personne est inscrite pour {job}.',
	['jobs.offer.refused'] = '{name} a refusé la place dans {job}.',
	['jobs.offer.youRefused'] = 'Vous avez refusé la place dans {job}.',
	['jobs.offer.expired'] = '{name} n’a pas répondu à temps : l’offre pour {job} a expiré.',
	['jobs.offer.expiredYou'] = 'L’offre d’une place dans {job} a expiré.',
	['jobs.offer.none'] = 'Cette offre n’est plus valable.',
	['jobs.offer.pending'] = 'Cette personne répond déjà à une autre offre.',
	['jobs.candidateNotNear'] = 'La personne doit se tenir près de vous pour recevoir l’offre.',
	['jobs.refused'] = 'Cela n’a pas pu être fait.',

	['jobs.noCharacter'] = 'Votre fiche n’a pas pu être lue.',
	['jobs.noPosition'] = 'Votre position n’a pas pu être lue.',
	['jobs.wrongBucket'] = 'Ce marqueur n’est pas celui devant vous.',
	['jobs.tooFar'] = 'Vous êtes trop loin du marqueur. Placez-vous dessus et réessayez.',
	['jobs.noSuchBoard'] = 'Il n’y a pas de tableau ici.',
	['jobs.noSuchJob'] = 'Cet emploi n’existe pas ici.',
	['jobs.alreadyMember'] = 'Vous occupez déjà cet emploi.',
	['jobs.notMember'] = 'Cette personne n’occupe pas cet emploi.',
	['jobs.notYours'] = 'Vous n’occupez pas cet emploi.',
	['jobs.alreadyWorking'] = 'C’est déjà le métier que vous exercez.',
	['jobs.notOpen'] = 'Cet emploi n’est pas proposé.',
	['jobs.byInvitation'] =
		'Cet emploi se fait sur invitation : quelqu’un détenant le grade de chef doit vous engager.',
	['jobs.needsJob'] = 'Vous n’occupez pas l’emploi exigé par celui-ci.',
	['jobs.needsGrade'] = 'Votre grade est trop bas pour celui-ci.',
	['jobs.needsRight'] = 'Vous n’avez pas l’habilitation exigée.',
	['jobs.needsRank'] = 'Exige le grade {rank} ({need}) ou supérieur',
	['jobs.needsJobNamed'] = 'Exige l’emploi {need}',
	['jobs.lastBoss'] = 'Cela laisserait l’emploi sans personne à sa tête.',
	['jobs.notBoss'] = 'Vous ne détenez pas le grade de chef de cet emploi.',
	['jobs.topRank'] = 'Cette personne détient déjà le grade le plus élevé.',
	['jobs.bottomRank'] = 'Cette personne détient déjà le grade d’entrée.',
	['jobs.candidateAway'] = 'Cette personne n’est pas assez proche du bureau.',
	['jobs.rosterFailed'] = 'L’effectif n’a pas pu être lu.',
	['jobs.captureFailed'] = 'Ce tableau n’a pas pu être enregistré.',
	['jobs.captureNoAnswer'] =
		'Votre client n’a pas répondu à la capture : {key} n’a PAS été enregistré. ' ..
		'Placez-vous où vous le voulez et relancez la commande.',

	['jobs.help.add'] = 'Place un tableau d’emplois là où vous êtes.',
	['jobs.help.addKind'] = "soit 'signup' pour le bureau, soit 'boss' pour le bureau d'une division",
	['jobs.help.addKey'] = 'nom durable du tableau, ex. jobs_city',
	['jobs.help.addJob'] = "l'emploi pour lequel le tableau est dessiné, ex. ncpd",
	['jobs.help.remove'] = 'Supprime un tableau capturé. Un tableau de config ne l’est pas ici.',
	['jobs.help.removeKey'] = 'le nom sous lequel le tableau a été capturé',
	['jobs.help.list'] = 'Affiche chaque tableau : type, emploi, position et origine.',

	['jobs.help.roster'] = 'Liste qui occupe un emploi, à quel grade et avec quelle ancienneté.',
	['jobs.help.rosterJob'] = "l'emploi, ex. ncpd",
	['jobs.help.rank'] = 'Affiche l’échelle d’un emploi et où en est quelqu’un.',
	['jobs.help.rankCitizen'] = 'un identifiant de citoyen ; vous si omis',
	['jobs.help.join'] = 'Vous inscrit à un emploi à son échelon d’entrée.',
	['jobs.help.leave'] = 'Vous retire d’un emploi.',
	['jobs.help.promote'] = 'Monte quelqu’un d’un grade. Exige le grade de chef de cet emploi.',
	['jobs.help.demote'] = 'Descend quelqu’un d’un grade. Exige le grade de chef de cet emploi.',
	['jobs.help.fire'] = 'Licencie quelqu’un. Exige le grade de chef de cet emploi.',
	['jobs.help.hire'] = 'Propose une place à quelqu’un près de vous ; la personne accepte ou refuse. Exige le grade de chef de cet emploi.',
	['jobs.help.hirePlayerId'] = 'le numéro de connexion de quelqu’un debout près de vous',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
