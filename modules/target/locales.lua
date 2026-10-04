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
	['target.identify.row'] = 'Show ID',
	['target.identify.title'] = 'IDENTIFIERS',
	['target.identify.copied'] = 'Server {server} / Character {citizen} — copied',
	['target.identify.shown'] = 'Server {server} / Character {citizen}',
	['target.key'] = 'Target (hold)',
	['target.looking'] = 'Looking…',
	['target.unavailable'] = 'Action unavailable',
	['target.confirm'] = 'Confirm: {label}',
}

local FR = {
	['target.identify.row'] = 'Voir les identifiants',
	['target.identify.title'] = 'IDENTIFIANTS',
	['target.identify.copied'] = 'Serveur {server} / Personnage {citizen} — copié',
	['target.identify.shown'] = 'Serveur {server} / Personnage {citizen}',
	['target.key'] = 'Cibler (maintenir)',
	['target.looking'] = 'Recherche…',
	['target.unavailable'] = 'Action indisponible',
	['target.confirm'] = 'Confirmer : {label}',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
