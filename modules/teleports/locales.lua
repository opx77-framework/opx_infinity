--- Player-facing text for the strip row, every refusal and the command help.
-- @author dop42
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English: they are read by an operator in a journal, not by a player on a
-- screen.
--
-- A TELEPORT'S LABELS AND ITS REASON ARE THE OPERATOR'S OWN WORDS and are NOT
-- here. They live in `config/teleports.lua`, they travel on the wire as written,
-- and they are interpolated into `{place}` and `{reason}` below untranslated --
-- exactly as `config/elevators.lua`'s REASON and LABEL are. A server that runs
-- in French names its rooftops in French by writing them that way.

local EN = {
	['teleports.title'] = 'TELEPORT',

	['teleports.key.use'] = 'Use teleport',
	['teleports.prompt'] = 'Go to {place}',
	['teleports.prompt.locked'] = '{place} (locked)',

	['teleports.arrived'] = 'You arrived at {place}.',

	['teleports.refused'] = 'That trip was refused: {reason}',
	['teleports.locked'] = 'This teleport is not yours to use.',
	-- The operator's own sentence, shown instead of the line above whenever they
	-- wrote one. It is what makes a locked teleport say why.
	['teleports.lockedReason'] = '{reason}',

	['teleports.noSuchTeleport'] = 'There is no teleport here.',
	['teleports.tooFar'] = 'You are not standing on the teleport.',
	['teleports.noPosition'] = 'Your position could not be read.',
	['teleports.inFlight'] = 'You are already on your way.',
	['teleports.busy'] = 'Finish what you are doing first.',
	['teleports.downed'] = 'Not while you are down.',
	['teleports.inVehicle'] = 'Step out of the vehicle first.',
	['teleports.notAlive'] = 'Not while you are dead.',
	['teleports.notReady'] = 'You are not in the world yet.',
	['teleports.badDestination'] = 'That destination is not a place. Tell an admin.',
	['teleports.neverArrived'] = 'You did not arrive. Nothing was moved; tell an admin.',
	['teleports.unavailable'] = 'Teleports are unavailable on this server.',

	['teleports.help.where'] = 'Show every teleport: both ends, its gate and how its trips ' ..
		'have gone.',
	['teleports.help.whereKey'] = 'one teleport to show; all of them when omitted ({keys})',
}

local FR = {
	['teleports.title'] = 'TELEPORTATION',

	['teleports.key.use'] = 'Utiliser la teleportation',
	['teleports.prompt'] = 'Aller a {place}',
	['teleports.prompt.locked'] = '{place} (verrouille)',

	['teleports.arrived'] = 'Vous etes arrive a {place}.',

	['teleports.refused'] = 'Ce trajet a ete refuse : {reason}',
	['teleports.locked'] = "Cette teleportation ne vous est pas ouverte.",
	['teleports.lockedReason'] = '{reason}',

	['teleports.noSuchTeleport'] = "Il n'y a pas de teleportation ici.",
	['teleports.tooFar'] = "Vous n'etes pas sur la teleportation.",
	['teleports.noPosition'] = "Votre position n'a pas pu etre lue.",
	['teleports.inFlight'] = 'Vous etes deja en route.',
	['teleports.busy'] = "Terminez d'abord ce que vous faites.",
	['teleports.downed'] = 'Pas pendant que vous etes a terre.',
	['teleports.inVehicle'] = "Sortez d'abord du vehicule.",
	['teleports.notAlive'] = 'Pas pendant que vous etes mort.',
	['teleports.notReady'] = "Vous n'etes pas encore dans le monde.",
	['teleports.badDestination'] = "Cette destination n'est pas un lieu. Prevenez un admin.",
	['teleports.neverArrived'] = "Vous n'etes pas arrive. Rien n'a bouge ; prevenez un admin.",
	['teleports.unavailable'] = 'Les teleportations sont indisponibles sur ce serveur.',

	['teleports.help.where'] = 'Affiche chaque teleportation : ses deux extremites, son acces ' ..
		'et ses trajets.',
	['teleports.help.whereKey'] = 'une teleportation a afficher ; toutes si omis ({keys})',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
