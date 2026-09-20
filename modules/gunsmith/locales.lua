--- What the armouries say, in both languages.
-- @author dop42
--
-- TWO PREFIXES, AND THE SECOND ONE IS NOT A MISTAKE.
--
--   `gunsmith.` is this module's own: the two row labels, and every refusal the
--   CHEST door answers -- which includes the codes `inventory.OpenStash` hands
--   back, because they reach the player through this module's event.
--
--   `crafting.` carries the four refusals the job GATE answers. The crafting
--   module builds the key by prefixing `crafting.` to whatever code a bench's
--   `canUse` returned -- it cannot do otherwise, since it does not know which
--   module a bench belongs to at the moment it draws a greyed row -- so the
--   sentence has to be registered under that prefix, by whoever owns the code.
--   The alternative was teaching crafting to look up a per-consumer namespace,
--   which is a lookup table of module ids inside a module that is meant not to
--   know any.
--
-- The four are the SAME FOUR WORDS the elevators module refuses a floor with,
-- deliberately: one vocabulary for "your job does not get you in", so a player
-- who has read one refusal has read them all.

local M = OPX.Modules.Get('gunsmith')

local EN = {
	['gunsmith.bench'] = 'Workbench',
	['gunsmith.chest'] = 'Armoury stock',

	['gunsmith.no_such_chest'] = 'There is no chest here.',
	['gunsmith.not_for_you'] = 'This armoury is not yours.',
	['gunsmith.job_required'] = 'You do not work here.',
	['gunsmith.grade_too_low'] = 'You are not senior enough for this armoury.',
	['gunsmith.off_duty'] = 'You would have to be on duty.',
	['gunsmith.job_stale'] = 'Your record could not be read. Try again.',
	['gunsmith.no_character'] = 'No character is loaded.',
	['gunsmith.too_far'] = 'You are not standing at the chest.',
	['gunsmith.not_ready'] = 'Your bag is not ready yet.',
	['gunsmith.not_loaded'] = 'Your bag is not loaded.',
	['gunsmith.bad_argument'] = 'That chest is misconfigured.',
	['gunsmith.unavailable'] = 'The armoury cannot be reached right now.',

	['crafting.job_required'] = 'You do not work here.',
	['crafting.grade_too_low'] = 'Your rank does not run to that one.',
	['crafting.off_duty'] = 'You would have to be on duty.',
	['crafting.job_stale'] = 'Your record could not be read. Try again.',
}

local FR = {
	['gunsmith.bench'] = 'Établi',
	['gunsmith.chest'] = "Stock de l'armurerie",

	['gunsmith.no_such_chest'] = "Il n'y a pas de coffre ici.",
	['gunsmith.not_for_you'] = "Cette armurerie n'est pas la vôtre.",
	['gunsmith.job_required'] = 'Vous ne travaillez pas ici.',
	['gunsmith.grade_too_low'] = "Votre rang ne suffit pas pour cette armurerie.",
	['gunsmith.off_duty'] = 'Il faudrait être en service.',
	['gunsmith.job_stale'] = "Votre fiche n'a pas pu être lue. Réessayez.",
	['gunsmith.no_character'] = "Aucun personnage n'est chargé.",
	['gunsmith.too_far'] = "Vous n'êtes pas devant le coffre.",
	['gunsmith.not_ready'] = "Votre sac n'est pas encore prêt.",
	['gunsmith.not_loaded'] = "Votre sac n'est pas chargé.",
	['gunsmith.bad_argument'] = 'Ce coffre est mal configuré.',
	['gunsmith.unavailable'] = "L'armurerie est injoignable pour le moment.",

	['crafting.job_required'] = 'Vous ne travaillez pas ici.',
	['crafting.grade_too_low'] = "Votre rang ne va pas jusque-là.",
	['crafting.off_duty'] = 'Il faudrait être en service.',
	['crafting.job_stale'] = "Votre fiche n'a pas pu être lue. Réessayez.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
