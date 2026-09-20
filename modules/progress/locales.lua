--- What the bar says, in both languages.
-- @author dop42
--
-- A bar's LABEL is the caller's -- "Eating", "Picking the lock" -- and is passed
-- in rather than looked up here, because this module does not know what anybody
-- is doing. What is here is the one word the bar draws for itself: the hint that
-- it can be cancelled, on the bars that allow it.

local M = OPX.Modules.Get('progress')

local EN = {
	['progress.cancel'] = 'Hold to cancel',
}

local FR = {
	['progress.cancel'] = 'Maintenir pour annuler',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
