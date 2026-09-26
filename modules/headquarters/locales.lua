--- Player-facing text for the name row and the command help.
-- @author XEROX710
--
-- A headquarters' LABEL is the operator's own words and lives in
-- `config/headquarters.lua`, not here: it is never translated. What lives here
-- is the one word the row puts beside it and the help lines.

local EN = {
	['headquarters.title'] = 'HEADQUARTERS',
	['headquarters.prompt.value'] = 'Headquarters',
	['headquarters.key.use'] = 'Read the station',
	['headquarters.help.add'] = 'Capture where you stand as a headquarters: saved, set and printed for the config.',
	['headquarters.help.addKey'] = 'The durable key (hq1, hq2, ... when empty).',
	['headquarters.help.addLabel'] = 'What the name row shows (the key when empty).',
	['headquarters.help.remove'] = 'Remove a captured headquarters.',
	['headquarters.help.removeKey'] = 'The key the capture was saved under.',
	['headquarters.help.list'] = 'Show every configured headquarters: label, position and bucket.',
	['headquarters.none'] = 'No headquarters is configured in config/headquarters.lua.',
}

local FR = {
	['headquarters.title'] = 'QUARTIER GÉNÉRAL',
	['headquarters.prompt.value'] = 'Quartier général',
	['headquarters.key.use'] = 'Lire le lieu',
	['headquarters.help.add'] = 'Capture votre position comme quartier général : enregistré, posé et imprimé pour la config.',
	['headquarters.help.addKey'] = 'La clé durable (hq1, hq2, ... si vide).',
	['headquarters.help.addLabel'] = 'Ce que la ligne de nom affiche (la clé si vide).',
	['headquarters.help.remove'] = 'Retire un quartier général capturé.',
	['headquarters.help.removeKey'] = 'La clé sous laquelle la capture a été enregistrée.',
	['headquarters.help.list'] = 'Affiche chaque quartier général : nom, position et bucket.',
	['headquarters.none'] = 'Aucun quartier général n’est configuré dans config/headquarters.lua.',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
