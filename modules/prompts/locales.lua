--- The key cap names and the hold tag.
-- @author dop42
--
-- These keys are never written literally anywhere in the code: a cap's name is
-- composed as `prompts.key.<NAME>` from the key the host reports, upper-cased,
-- and tested with `OPX.Locale.Exists` before it is resolved. Every entry below
-- is therefore live, and a key with no entry is drawn as the host spells it.
--
-- A caller's own labels are not here. They belong to the module that posted the
-- row, which is where they are translated.

OPX.Locale.Register('en', {
	['prompts.hold'] = 'HOLD',

	['prompts.key.SPACE'] = 'SPACE',
	['prompts.key.ENTER'] = 'ENTER',
	['prompts.key.RETURN'] = 'ENTER',
	['prompts.key.ESC'] = 'ESC',
	['prompts.key.ESCAPE'] = 'ESC',
	['prompts.key.BACKSPACE'] = 'BKSP',
	['prompts.key.DELETE'] = 'DEL',
	['prompts.key.INSERT'] = 'INS',
	['prompts.key.HOME'] = 'HOME',
	['prompts.key.END'] = 'END',
	['prompts.key.PAGEUP'] = 'PG UP',
	['prompts.key.PAGEDOWN'] = 'PG DN',
	['prompts.key.CAPSLOCK'] = 'CAPS',
	['prompts.key.TAB'] = 'TAB',
	['prompts.key.SHIFT'] = 'SHIFT',
	['prompts.key.CTRL'] = 'CTRL',
	['prompts.key.CONTROL'] = 'CTRL',
	['prompts.key.ALT'] = 'ALT',
	['prompts.key.MOUSE'] = 'MOUSE',
	['prompts.key.LMB'] = 'LMB',
	['prompts.key.RMB'] = 'RMB',
	['prompts.key.MMB'] = 'MMB',
	['prompts.key.SCROLL'] = 'SCROLL',
})

OPX.Locale.Register('fr', {
	['prompts.hold'] = 'MAINTENIR',

	['prompts.key.SPACE'] = 'ESPACE',
	['prompts.key.ENTER'] = 'ENTREE',
	['prompts.key.RETURN'] = 'ENTREE',
	['prompts.key.ESC'] = 'ECHAP',
	['prompts.key.ESCAPE'] = 'ECHAP',
	['prompts.key.BACKSPACE'] = 'RET ARR',
	['prompts.key.DELETE'] = 'SUPPR',
	['prompts.key.INSERT'] = 'INSER',
	['prompts.key.HOME'] = 'ORIGINE',
	['prompts.key.END'] = 'FIN',
	['prompts.key.PAGEUP'] = 'PG PREC',
	['prompts.key.PAGEDOWN'] = 'PG SUIV',
	['prompts.key.CAPSLOCK'] = 'MAJ',
	['prompts.key.TAB'] = 'TAB',
	['prompts.key.SHIFT'] = 'MAJ',
	['prompts.key.CTRL'] = 'CTRL',
	['prompts.key.CONTROL'] = 'CTRL',
	['prompts.key.ALT'] = 'ALT',
	['prompts.key.MOUSE'] = 'SOURIS',
	['prompts.key.LMB'] = 'CLIC G',
	['prompts.key.RMB'] = 'CLIC D',
	['prompts.key.MMB'] = 'CLIC M',
	['prompts.key.SCROLL'] = 'MOLETTE',
})
