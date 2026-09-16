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
	['character.badName'] = 'That name cannot be used.',
	['character.badOrigin'] = 'That is not a valid lifepath.',
	['character.badBirthdate'] = 'That birth date cannot be used.',
	['character.created'] = 'Character created. Your citizen ID is {citizenId}.',
	['character.deleted'] = 'Character deleted.',
	['character.inUse'] = 'That character is already in the world.',

	['entry.failed'] = 'Could not bring you into Night City. Try reconnecting.',
	['entry.noIdentity'] = 'Your identity could not be verified.',
	['entry.timedOut'] = 'You took too long to choose a character.',

	['money.insufficient'] = 'You do not have enough {type}.',
	['money.badType'] = 'That is not a currency on this server.',
	['money.badAmount'] = 'That amount is not valid.',
	['money.negative'] = 'That balance cannot go negative.',
	['money.vetoed'] = 'That transaction was blocked.',
	['money.offline'] = 'That character is not in the world.',
	['money.paycheck'] = 'You received {amount} {type} for {job}.',

	['job.notFound'] = 'No such job.',
	['job.gradeNotFound'] = 'That job has no such grade.',
	['job.onDuty'] = 'You are on duty.',
	['job.offDuty'] = 'You are off duty.',
	['job.noDuty'] = 'That job has no shifts to clock into.',
	['job.notMember'] = 'You do not work that job.',

	['gang.notFound'] = 'No such gang.',
	['gang.gradeNotFound'] = 'That gang has no such grade.',
	['gang.notMember'] = 'You are not in that gang.',

	['error.notLoggedIn'] = 'You are not in the world yet.',

	['command.inGameOnly'] = 'That command has to be run in game.',
	['command.usage.select'] = 'usage: /opx.select <citizenId>',
	['command.usage.create'] =
		'usage: /opx.create <firstName> <lastName> [nomad|streetkid|corpo] [female|male]',
	['command.usage.delete'] = 'usage: /opx.delete <citizenId>',
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
	['command.entered'] = 'You are in the world as {citizenId}.',
	['command.characterCount'] = '{count} character(s):',

	['command.help.players'] = 'List who is in the world.',
	['command.help.where'] = 'Show what the server holds on a player.',
	['command.help.here'] = 'Print where you stand as a DEFAULT_SPAWN block.',
	['command.help.characters'] = 'List your characters.',
	['command.help.select'] = 'Enter the world as one of your characters.',
	['command.help.create'] = 'Create a character.',
	['command.help.delete'] = 'Delete one of your characters.',
	['command.help.duty'] = 'Clock in or out of your job.',
	['command.help.money'] = 'Give a character money, or take it.',
	['command.help.job'] = "Set a character's job and grade.",
	['command.help.gang'] = "Set a character's gang and grade.",
	['command.help.group'] = 'List the members of a job or a gang.',
	['command.help.save'] = 'Save every loaded character now.',
})

OPX.Locale.Register('fr', {
	['character.limit'] = 'Vous avez deja {max} personnages.',
	['character.rowLimit'] = "Ce compte a cree autant de personnages qu'il le peut.",
	['character.notFound'] = 'Aucun personnage ne porte cet identifiant citoyen.',
	['character.badName'] = 'Ce nom ne peut pas etre utilise.',
	['character.badOrigin'] = "Ce parcours de vie n'existe pas.",
	['character.badBirthdate'] = 'Cette date de naissance ne peut pas etre utilisee.',
	['character.created'] = 'Personnage cree. Votre identifiant citoyen est {citizenId}.',
	['character.deleted'] = 'Personnage supprime.',
	['character.inUse'] = 'Ce personnage est deja en jeu.',

	['entry.failed'] = 'Impossible de vous faire entrer dans Night City. Reconnectez-vous.',
	['entry.noIdentity'] = "Votre identite n'a pas pu etre verifiee.",
	['entry.timedOut'] = 'Vous avez mis trop de temps a choisir un personnage.',

	['money.insufficient'] = "Vous n'avez pas assez de {type}.",
	['money.badType'] = "Ce n'est pas une devise sur ce serveur.",
	['money.badAmount'] = "Ce montant n'est pas valide.",
	['money.negative'] = 'Ce solde ne peut pas devenir negatif.',
	['money.vetoed'] = 'Cette transaction a ete bloquee.',
	['money.offline'] = "Ce personnage n'est pas en jeu.",
	['money.paycheck'] = 'Vous avez recu {amount} {type} pour {job}.',

	['job.notFound'] = "Ce metier n'existe pas.",
	['job.gradeNotFound'] = "Ce metier n'a pas ce grade.",
	['job.onDuty'] = 'Vous etes en service.',
	['job.offDuty'] = "Vous n'etes plus en service.",
	['job.noDuty'] = "Ce metier n'a pas de service a prendre.",
	['job.notMember'] = "Vous n'exercez pas ce metier.",

	['gang.notFound'] = "Ce gang n'existe pas.",
	['gang.gradeNotFound'] = "Ce gang n'a pas ce grade.",
	['gang.notMember'] = "Vous n'etes pas dans ce gang.",

	['error.notLoggedIn'] = "Vous n'etes pas encore en jeu.",

	['command.inGameOnly'] = 'Cette commande doit etre lancee en jeu.',
	['command.usage.select'] = 'usage : /opx.select <identifiantCitoyen>',
	['command.usage.create'] =
		'usage : /opx.create <prenom> <nom> [nomad|streetkid|corpo] [female|male]',
	['command.usage.delete'] = 'usage : /opx.delete <identifiantCitoyen>',
	['command.usage.money'] =
		'usage : /opx.money <numeroJoueur|identifiantCitoyen> <TYPE> <montant> (negatif pour retirer)',
	['command.usage.job'] = 'usage : /opx.job <numeroJoueur|identifiantCitoyen> <metier> [grade]',
	['command.usage.gang'] = 'usage : /opx.gang <numeroJoueur|identifiantCitoyen> <gang> [grade]',
	['command.usage.group'] = 'usage : /opx.group <job|gang> <nom>',
	['command.noSession'] = "Le joueur {id} n'a pas de session.",
	['command.positionUnreadable'] = 'Votre position est illisible pour le moment.',
	['command.moneySet'] = '{citizenId} detient maintenant {amount}.',
	['command.jobSet'] = '{citizenId} est maintenant {grade} chez {job}.',
	['command.gangSet'] = '{citizenId} est maintenant {grade} chez {gang}.',
	['command.saved'] = '{saved} personnage(s) sur {total} sauvegarde(s).',
	['command.entered'] = 'Vous etes en jeu avec {citizenId}.',
	['command.characterCount'] = '{count} personnage(s) :',

	['command.help.players'] = 'Liste qui est en jeu.',
	['command.help.where'] = "Montre ce que le serveur sait d'un joueur.",
	['command.help.here'] = 'Affiche votre position au format DEFAULT_SPAWN.',
	['command.help.characters'] = 'Liste vos personnages.',
	['command.help.select'] = 'Entrer en jeu avec un de vos personnages.',
	['command.help.create'] = 'Creer un personnage.',
	['command.help.delete'] = 'Supprimer un de vos personnages.',
	['command.help.duty'] = 'Prendre ou quitter votre service.',
	['command.help.money'] = "Donner de l'argent a un personnage, ou lui en retirer.",
	['command.help.job'] = "Definir le metier et le grade d'un personnage.",
	['command.help.gang'] = "Definir le gang et le grade d'un personnage.",
	['command.help.group'] = "Liste les membres d'un metier ou d'un gang.",
	['command.help.save'] = 'Sauvegarder tous les personnages en jeu.',
})
