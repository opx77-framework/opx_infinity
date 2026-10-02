--- What the loading cover says, in both languages.
-- @author dop42
--
-- Three lines and no more, because a cover is looked at for seconds: what is
-- happening, and -- when the platform cannot say how far along it is -- that it
-- is still happening. It never says "done": the cover goes away when the load
-- ends, and that is the only announcement a finished load needs.

local M = OPX.Modules.Get('loading')

local EN = {
	-- The eyebrow over the bar, by the kind the platform names.
	['loading.kind.unknown'] = 'In transit',
	['loading.kind.fastTravel'] = 'Fast travel',
	-- The line under the bar while the platform has no fraction to give.
	['loading.pending'] = 'Streaming the city',
	-- The bar's own caption.
	['loading.title'] = 'Loading',
}

local FR = {
	['loading.kind.unknown'] = 'En transit',
	['loading.kind.fastTravel'] = 'Voyage rapide',
	['loading.pending'] = 'Chargement de la ville',
	['loading.title'] = 'Chargement',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
