--- What the bar says, in both languages.
-- @author dop42
--
-- A bar's LABEL is the caller's -- "Eating", "Picking the lock" -- and is passed
-- in rather than looked up here, because this module does not know what anybody
-- is doing. What is here is the one line the bar draws for itself -- the hint
-- naming the key that cancels it, on the bars that allow it -- and the name of
-- that key in the pause menu's bindings.

local M = OPX.Modules.Get('progress')

local EN = {
	['progress.cancel'] = '{key} to cancel',
	['progress.key.cancel'] = 'Cancel the current action',
}

local FR = {
	['progress.cancel'] = '{key} pour annuler',
	['progress.key.cancel'] = "Annuler l'action en cours",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
