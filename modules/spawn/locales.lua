--- Every string this module puts on screen, in the two languages the runtime ships.
-- @author dop42
--
-- The view is drawn from these and from nothing else: Lua resolves every key and
-- hands the page a sentence, so the page holds no English of its own. The refusal
-- code below is a catalogue key like any other -- `OPX.Refuse` looks it up on its
-- way out, so a code missing here would reach a player as `error.unavailable`.

local M = OPX.Modules.Get('spawn')

local EN = {
	['spawn.title'] = 'CHOOSE A SPAWN',
	['spawn.eyebrow'] = 'SPAWN',
	['spawn.about'] = 'Pick where you start.',
	['spawn.hint'] = 'Click a location to spawn there.',
	['spawn.placed'] = 'Spawned at {place}.',
	['spawn.timeout'] = 'No choice was made: the server placed you.',
	['spawn.resume'] = 'Where I left off',
	['spawn.resumeHint'] = 'Your last position',
	['spawn.resumed'] = 'Back where you left off.',
	['spawn.placeFailed'] = 'You could not be moved there. You are still where you were.',

	['spawn.noChoice'] = 'That spawn choice is no longer open.',
}

local FR = {
	['spawn.title'] = 'CHOISISSEZ OÙ APPARAÎTRE',
	['spawn.eyebrow'] = 'APPARITION',
	['spawn.about'] = 'Choisissez où vous commencez.',
	['spawn.hint'] = 'Cliquez sur un lieu pour y apparaître.',
	['spawn.placed'] = 'Apparition à {place}.',
	['spawn.timeout'] = 'Aucun choix : le serveur vous a placé.',
	['spawn.resume'] = "Là où j'étais",
	['spawn.resumeHint'] = 'Votre dernière position',
	['spawn.resumed'] = 'Retour là où vous étiez.',
	['spawn.placeFailed'] = "Le déplacement n'a pas pu se faire : vous n'avez pas bougé.",

	['spawn.noChoice'] = "Ce choix d'apparition n'est plus ouvert.",
}

-- Kept on the module table as well as registered: the two are compared at start,
-- so a key present in one language and missing from the other is named once
-- rather than rendered as its own key on somebody's screen.
M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
