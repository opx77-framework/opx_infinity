--- The panel's default words, which a caller's spec overrides field by field.
-- @author dop42
--
-- `panel.count` keeps its placeholders: the page fills them itself, because the
-- page is the only side that knows how many rows fit and which of them are
-- drawn. It is handed the template, never a rendered line.

OPX.Locale.Register('en', {
	['panel.count'] = '{from}-{to} of {total}',
	['panel.empty'] = 'Nothing to show here.',
	['panel.loading'] = 'Loading...',
	['panel.search'] = 'Search',
	['panel.confirmYes'] = 'Confirm',
	['panel.confirmNo'] = 'Back',
})

OPX.Locale.Register('fr', {
	['panel.count'] = '{from}-{to} sur {total}',
	['panel.empty'] = 'Rien à afficher ici.',
	['panel.loading'] = 'Chargement...',
	['panel.search'] = 'Rechercher',
	['panel.confirmYes'] = 'Confirmer',
	['panel.confirmNo'] = 'Retour',
})
