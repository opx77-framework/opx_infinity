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
	['spawn.about'] = 'Pick where you start, or pick nothing to keep your last position.',
	['spawn.hint'] = 'Click a location to spawn there.',
	['spawn.confirm'] = 'SPAWN',
	['spawn.deadline'] = 'Auto-spawn in',
	['spawn.placed'] = 'Spawned at {place}.',
	['spawn.timeout'] = 'No choice was made: the server placed you.',

	['spawn.noChoice'] = 'That spawn choice is no longer open.',
}

local FR = {
	['spawn.title'] = 'CHOISIR UN POINT D APPARTION',
	['spawn.about'] = 'Choisissez ou vous commencez, ou ne choisissez rien pour garder votre position.',
	['spawn.hint'] = 'Cliquez sur un lieu pour y apparaitre.',
	['spawn.confirm'] = 'APPARAITRE',
	['spawn.deadline'] = 'Apparition automatique dans',
	['spawn.placed'] = 'Apparition a {place}.',
	['spawn.timeout'] = 'Aucun choix : le serveur vous a place.',

	['spawn.noChoice'] = "Ce choix d'apparition n'est plus ouvert.",
}

-- Kept on the module table as well as registered: the two are compared at start,
-- so a key present in one language and missing from the other is named once
-- rather than rendered as its own key on somebody's screen.
M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
