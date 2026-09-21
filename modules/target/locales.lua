--- Player-facing text of the target eye and its list.
-- @author dop42
--
-- `target.key` is the label the pause menu shows beside the rebindable key, so it
-- is read once at start and never re-read: the host keeps the name it was given
-- when the mapping was registered.

local M = OPX.Modules.Get('target')

local EN = {
	-- The eye's own row: who is this. Two identifiers, named, because they are
	-- different things with different lifetimes.
	['target.identify.row'] = 'Identifiers',
	['target.identify.title'] = 'IDENTIFIERS',
	['target.identify.copied'] = 'Server {server} / Character {citizen} — copied',
	['target.identify.shown'] = 'Server {server} / Character {citizen}',
	['target.key'] = 'Target (hold)',
	['target.hint'] = 'Right-click a target',
	['target.looking'] = 'Looking…',
	['target.back'] = 'Back',
	['target.unavailable'] = 'Action unavailable',
}

local FR = {
	['target.identify.row'] = 'Identifiants',
	['target.identify.title'] = 'IDENTIFIANTS',
	['target.identify.copied'] = 'Serveur {server} / Perso {citizen} — copié',
	['target.identify.shown'] = 'Serveur {server} / Perso {citizen}',
	['target.key'] = 'Cibler (maintenir)',
	['target.hint'] = 'Clic droit sur une cible',
	['target.looking'] = 'Recherche…',
	['target.back'] = 'Retour',
	['target.unavailable'] = 'Action indisponible',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
