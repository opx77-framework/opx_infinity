--- What the shops say, in both languages.
-- @author dop42
--
-- Every refusal a player can be shown has a sentence here. A code that reaches
-- `OPX.NotifyLocale` without one becomes `error.unavailable` with the real code
-- logged -- which is a safety net and not a plan, so the net is left unused.

local M = OPX.Modules.Get('shops')

local EN = {
	['shops.row'] = 'Try clothes on',

	-- Refusals. `no_such_shop`, `too_far`, `position_unknown` and `not_for_you`
	-- are the four `shopAt` can answer and are prefixed with `shops.` by the
	-- caller, so their keys read oddly on purpose -- they are machine names.
	['shops.no_such_shop'] = 'There is no shop here.',
	['shops.too_far'] = 'You are not close enough to the counter.',
	['shops.position_unknown'] = 'The server cannot tell where you are standing.',
	['shops.not_for_you'] = 'This shop does not serve you.',

	['shops.unavailable'] = 'The fitting room is not available right now.',
	['shops.cannotDress'] = 'Those clothes would not go on.',
	['shops.cannotPay'] = 'You cannot afford that: {total} needed.',
	['shops.paid'] = '{total} at {shop}.',

	['shops.noSuchLook'] = 'That look is not on offer.',
	['shops.notForYou'] = 'Your job does not entitle you to that.',
	['shops.notHere'] = 'That look is not carried here.',

	['shops.noCharacter'] = 'No character is loaded.',
	['shops.nameNeeded'] = 'Give the outfit a name.',
	['shops.tooMany'] = 'You already keep {max} outfits. Delete one first.',
	['shops.nothingWorn'] = 'There is nothing saved to write down yet.',
	['shops.saved'] = 'Saved as {name}.',
	['shops.saveFailed'] = 'That could not be written down.',
	['shops.listFailed'] = 'Your outfits could not be read.',
	['shops.noSuchOutfit'] = 'That outfit is not yours.',
	['shops.outfitUnreadable'] = 'That outfit cannot be read back.',

	['shops.sharingOff'] = 'Sharing is turned off on this server.',
	['shops.badCode'] = 'That is not a code.',
	['shops.noSuchCode'] = 'No outfit answers that code.',
	['shops.codeFailed'] = 'A code could not be minted. Try again.',
}

local FR = {
	['shops.row'] = 'Essayer des vêtements',

	['shops.no_such_shop'] = "Il n'y a pas de boutique ici.",
	['shops.too_far'] = 'Vous êtes trop loin du comptoir.',
	['shops.position_unknown'] = 'Le serveur ne sait pas où vous vous tenez.',
	['shops.not_for_you'] = 'Cette boutique ne vous sert pas.',

	['shops.unavailable'] = "La cabine d'essayage n'est pas disponible.",
	['shops.cannotDress'] = 'Ces vêtements ne se sont pas mis.',
	['shops.cannotPay'] = 'Vous ne pouvez pas payer : {total} nécessaires.',
	['shops.paid'] = '{total} chez {shop}.',

	['shops.noSuchLook'] = "Cette tenue n'est pas proposée.",
	['shops.notForYou'] = 'Votre métier ne vous y donne pas droit.',
	['shops.notHere'] = "Cette tenue n'est pas vendue ici.",

	['shops.noCharacter'] = "Aucun personnage n'est chargé.",
	['shops.nameNeeded'] = 'Donnez un nom à la tenue.',
	['shops.tooMany'] = 'Vous gardez déjà {max} tenues. Supprimez-en une.',
	['shops.nothingWorn'] = "Il n'y a rien d'enregistré à noter pour l'instant.",
	['shops.saved'] = 'Enregistrée sous {name}.',
	['shops.saveFailed'] = "Cela n'a pas pu être enregistré.",
	['shops.listFailed'] = "Vos tenues n'ont pas pu être lues.",
	['shops.noSuchOutfit'] = "Cette tenue n'est pas la vôtre.",
	['shops.outfitUnreadable'] = 'Cette tenue est illisible.',

	['shops.sharingOff'] = 'Le partage est désactivé sur ce serveur.',
	['shops.badCode'] = "Ce n'est pas un code.",
	['shops.noSuchCode'] = 'Aucune tenue ne répond à ce code.',
	['shops.codeFailed'] = "Un code n'a pas pu être généré. Réessayez.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
