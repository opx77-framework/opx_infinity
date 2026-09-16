--- Player-facing text of the target eye and its list.
-- @author dop42
--
-- `target.key` is the label the pause menu shows beside the rebindable key, so it
-- is read once at start and never re-read: the host keeps the name it was given
-- when the mapping was registered.

local M = OPX.Modules.Get('target')

local EN = {
	['target.key'] = 'Target (hold)',
	['target.hint'] = 'Click a target',
	['target.looking'] = 'Looking…',
	['target.back'] = 'Back',
	['target.unavailable'] = 'Action unavailable',
}

local FR = {
	['target.key'] = 'Cibler (maintenir)',
	['target.hint'] = 'Cliquez sur une cible',
	['target.looking'] = 'Recherche…',
	['target.back'] = 'Retour',
	['target.unavailable'] = 'Action indisponible',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
