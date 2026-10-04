--- This module's player-facing text, in every language it ships.
-- @author dop42
--
-- Almost every key here is a refusal code: it reaches `locale()` through a
-- variable and never as a literal, so a rename breaks nothing at load and
-- everything at the moment a player is refused. `OPX.RefusalKey` is what guarantees
-- a code answered to a player exists here at all.
--
-- Server logs stay in English whatever the locale.

OPX.Locale.Register('en', {
	['character.limit'] = 'You already have {max} characters.',
	['character.rowLimit'] = 'This account has created as many characters as it may.',
	['character.notFound'] = 'No character carries that citizen ID.',
	['character.badName'] = 'Use letters only (spaces, hyphens and apostrophes allowed).',
	['character.searchShort'] = 'Search for at least three characters.',
	['character.badBody'] = 'That is not a body this game has.',
	['character.bodySet'] = 'This character is already built on a body.',
	['character.nameSet'] = 'This character already has a name.',
	['character.named'] = '{name}. Welcome to Night City.',
	['character.unnamed'] = 'no name yet',
	['character.created'] = 'Character created. Your citizen ID is {citizenId}.',
	['character.deleted'] = 'Character deleted.',
	['character.deleteConfirm'] = 'This deletes {citizenId} with its clothes, items and vehicles, for good. Run /opx.delete {citizenId} confirm to go ahead.',
	['character.deleteNotAllowed'] = 'Deleting your own character is turned off on this server. Ask a member of staff.',
	['character.inUse'] = 'That character is already in the world.',
	['character.alreadyPlaying'] = 'You are playing that character right now.',

	['entry.failed'] = 'Could not bring you into Night City. Try reconnecting.',
	['entry.noIdentity'] = 'Your identity could not be verified.',

	['session.switching'] = 'Switching character. Reconnect to play them.',
	['session.newCharacter'] = 'Building a new character. Reconnect to make them.',
	['session.characterDeleted'] = 'That character is gone. Reconnect to play another.',

	['money.insufficient'] = 'You do not have enough money.',
	['money.badType'] = 'That is not a currency on this server.',
	['money.badAmount'] = 'That amount is not valid.',
	['money.negative'] = 'That balance cannot go negative.',
	['money.vetoed'] = 'That transaction was blocked.',
	['money.offline'] = 'That character is not in the world.',
	['money.paycheck'] = 'Paycheck from {job}: {amount}.',

	['job.notFound'] = 'No such job.',
	['job.gradeNotFound'] = 'That job has no such grade.',
	['job.onDuty'] = 'You are on duty.',
	['job.offDuty'] = 'You are off duty.',
	['job.noDuty'] = 'That job has no shifts to clock into.',
	['job.notMember'] = 'You do not work that job.',
	['job.vetoed'] = 'That job change was blocked.',

	['gang.notFound'] = 'No such gang.',
	['gang.gradeNotFound'] = 'That gang has no such grade.',
	['gang.notMember'] = 'You are not in that gang.',
	['gang.vetoed'] = 'That gang change was blocked.',

	['error.notLoggedIn'] = 'You are not in the world yet.',

	['command.inGameOnly'] = 'That command has to be run in game.',
	['command.usage.select'] = 'usage: /opx.select <citizenId>',
	['command.usage.create'] = 'usage: /opx.create (no arguments; it disconnects you)',
	['command.usage.delete'] = 'usage: /opx.delete <citizenId> confirm',
	['command.usage.money'] =
		'usage: /opx.money <playerId|citizenId> <TYPE> <amount> (negative removes)',
	['command.usage.job'] = 'usage: /opx.job <playerId|citizenId> <job> [grade]',
	['command.usage.gang'] = 'usage: /opx.gang <playerId|citizenId> <gang> [grade]',
	['command.usage.group'] = 'usage: /opx.group <job|gang> <name>',
	['command.noSession'] = 'Player {id} has no session.',
	['command.positionUnreadable'] = 'Your position is not readable right now.',
	['command.moneySet'] = '{citizenId} now holds {amount}.',
	['command.jobSet'] = '{citizenId} is now {grade} at {job}.',
	['command.gangSet'] = '{citizenId} is now {grade} in {gang}.',
	['command.saved'] = 'Saved {saved} of {total} character(s).',
	['command.characterCount'] = '{count} character(s), {slots} slot(s). The one marked > is ' ..
		'the one you enter on:',
	['command.characterHint'] = 'opx.select <ID> takes another one, opx.create builds a new ' ..
		'one. Both disconnect you; the character is entered when you reconnect.',
	-- The same two sentences under CHARACTERS.SWITCH = 'relog', where only the
	-- second one still disconnects: a new body is built in the game's own menu,
	-- which there is no way back to without a new connection.
	['command.characterHintRelog'] = 'opx.select <ID> takes another one here and now. ' ..
		'opx.create builds a new one and disconnects you, because a new body is built ' ..
		'in the game menu.',
	['command.locked'] = 'Locked on {name}. Reconnect to play them.',
	['command.switched'] = 'You are now playing {name}.',
	['command.buildingNew'] = 'Your next connection builds a new character.',

	['command.help.players'] = 'List who is in the world.',
	['command.help.where'] = 'Show what the server holds on a player.',
	['command.help.here'] = 'Print where you stand as a DEFAULT_SPAWN block.',
	['command.help.characters'] = 'List your characters.',
	['command.help.select'] = 'Play another of your characters.',
	['command.help.create'] = 'Build a new character. Disconnects you.',
	['command.help.delete'] = 'Delete one of your characters.',
	['command.help.duty'] = 'Clock in or out of your job.',
	['command.help.money'] = 'Give a character money, or take it.',
	['command.help.job'] = "Set a character's job and grade.",
	['command.help.gang'] = "Set a character's gang and grade.",
	['command.help.group'] = 'List the members of a job or a gang.',
	['command.help.save'] = 'Save every loaded character now.',
})

OPX.Locale.Register('fr', {
	['character.limit'] = 'Vous avez déjà {max} personnages.',
	['character.rowLimit'] = 'Ce compte a atteint le nombre maximal de personnages.',
	['character.notFound'] = 'Aucun personnage ne porte cet identifiant citoyen.',
	['character.badName'] = 'Utilisez uniquement des lettres (espaces, tirets et apostrophes acceptés).',
	['character.searchShort'] = 'Cherchez avec au moins trois caractères.',
	['character.badBody'] = "Ce corps n'existe pas dans ce jeu.",
	['character.bodySet'] = 'Ce personnage est déjà construit sur un corps.',
	['character.nameSet'] = 'Ce personnage a déjà un nom.',
	['character.named'] = '{name}. Bienvenue à Night City.',
	['character.unnamed'] = 'sans nom',
	['character.created'] = 'Personnage créé. Votre identifiant citoyen est {citizenId}.',
	['character.deleted'] = 'Personnage supprimé.',
	['character.deleteConfirm'] = 'Cela supprime {citizenId} avec ses vêtements, objets et véhicules, définitivement. Tapez /opx.delete {citizenId} confirm pour continuer.',
	['character.deleteNotAllowed'] = "La suppression de votre propre personnage est désactivée sur ce serveur. Demandez à un membre de l'équipe.",
	['character.inUse'] = 'Ce personnage est déjà en jeu.',
	['character.alreadyPlaying'] = 'Vous jouez déjà ce personnage.',

	['entry.failed'] = 'Impossible de vous faire entrer dans Night City. Reconnectez-vous.',
	['entry.noIdentity'] = "Votre identité n'a pas pu être vérifiée.",
	['session.switching'] = 'Changement de personnage. Reconnectez-vous pour le jouer.',
	['session.newCharacter'] = 'Nouveau personnage. Reconnectez-vous pour le construire.',
	['session.characterDeleted'] = 'Ce personnage est supprimé. Reconnectez-vous.',

	['money.insufficient'] = "Vous n'avez pas assez d'argent.",
	['money.badType'] = "Ce n'est pas une devise sur ce serveur.",
	['money.badAmount'] = "Ce montant n'est pas valide.",
	['money.negative'] = 'Ce solde ne peut pas devenir négatif.',
	['money.vetoed'] = 'Cette transaction a été bloquée.',
	['money.offline'] = "Ce personnage n'est pas en jeu.",
	['money.paycheck'] = 'Salaire de {job} : {amount}.',

	['job.notFound'] = "Ce métier n'existe pas.",
	['job.gradeNotFound'] = "Ce métier n'a pas ce grade.",
	['job.onDuty'] = 'Vous êtes en service.',
	['job.offDuty'] = "Vous n'êtes plus en service.",
	['job.noDuty'] = "Ce métier n'a pas de service à prendre.",
	['job.notMember'] = "Vous n'exercez pas ce métier.",
	['job.vetoed'] = 'Ce changement de métier a été bloqué.',

	['gang.notFound'] = "Ce gang n'existe pas.",
	['gang.gradeNotFound'] = "Ce gang n'a pas ce grade.",
	['gang.notMember'] = "Vous n'êtes pas dans ce gang.",
	['gang.vetoed'] = 'Ce changement de gang a été bloqué.',

	['error.notLoggedIn'] = "Vous n'êtes pas encore en jeu.",

	['command.inGameOnly'] = 'Cette commande doit être lancée en jeu.',
	['command.usage.select'] = 'usage : /opx.select <identifiantCitoyen>',
	['command.usage.create'] = 'usage : /opx.create (sans argument ; vous serez déconnecté)',
	['command.usage.delete'] = 'utilisation : /opx.delete <identifiantCitoyen> confirm',
	['command.usage.money'] =
		'usage : /opx.money <numéroJoueur|identifiantCitoyen> <TYPE> <montant> (négatif pour retirer)',
	['command.usage.job'] = 'usage : /opx.job <numéroJoueur|identifiantCitoyen> <métier> [grade]',
	['command.usage.gang'] = 'usage : /opx.gang <numéroJoueur|identifiantCitoyen> <gang> [grade]',
	['command.usage.group'] = 'usage : /opx.group <job|gang> <nom>',
	['command.noSession'] = "Le joueur {id} n'a pas de session.",
	['command.positionUnreadable'] = 'Votre position est illisible pour le moment.',
	['command.moneySet'] = '{citizenId} détient maintenant {amount}.',
	['command.jobSet'] = '{citizenId} est maintenant {grade} chez {job}.',
	['command.gangSet'] = '{citizenId} est maintenant {grade} chez {gang}.',
	['command.saved'] = '{saved} personnage(s) sur {total} sauvegardé(s).',
	['command.characterCount'] = '{count} personnage(s), {slots} emplacement(s). Celui marqué ' ..
		'> est celui avec lequel vous entrez :',
	['command.characterHint'] = 'opx.select <ID> pour en prendre un autre, opx.create pour en ' ..
		'construire un. Les deux vous déconnectent ; le personnage est chargé à la reconnexion.',
	['command.characterHintRelog'] = 'opx.select <ID> pour en prendre un autre tout de suite. ' ..
		'opx.create en construit un nouveau et vous déconnecte, car un nouveau corps se ' ..
		'construit dans le menu du jeu.',
	['command.locked'] = 'Verrouillé sur {name}. Reconnectez-vous pour le jouer.',
	['command.switched'] = 'Vous jouez maintenant {name}.',
	['command.buildingNew'] = 'Votre prochaine connexion construira un nouveau personnage.',

	['command.help.players'] = 'Liste qui est en jeu.',
	['command.help.where'] = "Montre ce que le serveur sait d'un joueur.",
	['command.help.here'] = 'Affiche votre position au format DEFAULT_SPAWN.',
	['command.help.characters'] = 'Liste vos personnages.',
	['command.help.select'] = 'Jouer un autre de vos personnages.',
	['command.help.create'] = 'Construire un nouveau personnage. Vous déconnecte.',
	['command.help.delete'] = 'Supprimer un de vos personnages.',
	['command.help.duty'] = 'Prendre ou quitter votre service.',
	['command.help.money'] = "Donner de l'argent à un personnage, ou lui en retirer.",
	['command.help.job'] = "Définir le métier et le grade d'un personnage.",
	['command.help.gang'] = "Définir le gang et le grade d'un personnage.",
	['command.help.group'] = "Liste les membres d'un métier ou d'un gang.",
	['command.help.save'] = 'Sauvegarder tous les personnages en jeu.',
})
