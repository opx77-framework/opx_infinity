--- Player-facing text for the down screen and its refusals.
-- @author dop42
--
-- The keys keep the `medic.` prefix they were written under, so a view already
-- drawing them needs no rewriting. The catalogues are also kept on the module
-- table: the server compares them at start and names a key present in one and
-- missing from the other.

local M = OPX.Modules.Get('downed')

local EN = {
	['medic.screen.eyebrow'] = 'BIOMONITOR // NEURAL LINK DEGRADED',
	['medic.screen.title'] = 'FLATLINE',
	['medic.screen.subtitle'] = 'Critical vitals. You are down.',
	['medic.screen.vitals'] = 'VITALS',
	['medic.screen.bpm'] = 'BPM',
	['medic.screen.down'] = 'DOWN FOR',
	['medic.screen.signal'] = 'DISTRESS SIGNAL',
	['medic.screen.signalOff'] = 'NOT SENT',
	['medic.screen.signalOn'] = 'BROADCASTING',

	['medic.wait.label'] = 'WAIT FOR HELP',
	['medic.wait.hint'] = 'Broadcast a distress signal and hold on.',
	['medic.wait.active'] = 'SIGNAL SENT',
	['medic.wait.activeHint'] = 'Help has been called. Stay with us.',

	['medic.giveUp.label'] = 'GIVE UP',
	['medic.giveUp.hint'] = 'Hold to wake up at the nearest medical center.',
	['medic.giveUp.locked'] = 'Available in {time}',
	['medic.giveUp.holding'] = 'KEEP HOLDING',

	['medic.refused.too_soon'] = 'Not yet. Hold on a little longer.',
	['medic.refused.no_hospital'] = 'No medical center is configured.',
	['medic.refused.respawn_refused'] = 'The medical center could not take you. Try again.',
	['medic.refused.not_incarnated'] = 'Your body is not in the world yet.',
	['medic.refused.gate_closed'] = 'Still joining; try again in a moment.',
	['medic.refused.gate_unreadable'] = 'The server cannot move you right now.',
	['medic.refused.failed'] = 'That could not be done.',
}

local FR = {
	['medic.screen.eyebrow'] = 'BIOMONITEUR // LIAISON NEURALE DÉGRADÉE',
	['medic.screen.title'] = 'FLATLINE',
	['medic.screen.subtitle'] = 'Signes vitaux critiques. Vous êtes à terre.',
	['medic.screen.vitals'] = 'SIGNES VITAUX',
	['medic.screen.bpm'] = 'BPM',
	['medic.screen.down'] = 'À TERRE DEPUIS',
	['medic.screen.signal'] = 'SIGNAL DE DÉTRESSE',
	['medic.screen.signalOff'] = 'NON ÉMIS',
	['medic.screen.signalOn'] = 'EN ÉMISSION',

	['medic.wait.label'] = 'ATTENDRE LES SECOURS',
	['medic.wait.hint'] = 'Émettre un signal de détresse et tenir bon.',
	['medic.wait.active'] = 'SIGNAL ÉMIS',
	['medic.wait.activeHint'] = 'Les secours sont appelés. Restez avec nous.',

	['medic.giveUp.label'] = 'ABANDONNER',
	['medic.giveUp.hint'] = 'Maintenir pour vous réveiller au centre médical le plus proche.',
	['medic.giveUp.locked'] = 'Disponible dans {time}',
	['medic.giveUp.holding'] = 'CONTINUEZ DE MAINTENIR',

	['medic.refused.too_soon'] = 'Pas encore. Tenez encore un peu.',
	['medic.refused.no_hospital'] = "Aucun centre médical n'est configuré.",
	['medic.refused.respawn_refused'] = "Le centre médical n'a pas pu vous prendre. Réessayez.",
	['medic.refused.not_incarnated'] = "Votre corps n'est pas encore dans le monde.",
	['medic.refused.gate_closed'] = 'Connexion en cours ; réessayez dans un instant.',
	['medic.refused.gate_unreadable'] = "Le serveur ne peut pas vous déplacer pour l'instant.",
	['medic.refused.failed'] = "Cette action n'a pas abouti.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
