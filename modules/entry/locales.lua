--- Every string the first screen draws, in the two languages the runtime ships.
-- @author dop42
--
-- The page holds no English. Lua resolves every key here and sends the sentence,
-- including the ones a field refuses with: a validation message is a key on this
-- side of the bridge and a rendered string on the other.
--
-- The refusal CODES the server answers -- `character.*`, `entry.*`, `error.*` --
-- are not repeated here. They belong to the modules that raise them, every
-- catalogue merges into one, and `OPX.Locale.Exists` finds them from here.

local M = OPX.Modules.Get('entry')

local EN = {
	['entry.eyebrow.roster'] = 'NIGHT CITY // WHO ARE YOU',
	['entry.eyebrow.create'] = 'NIGHT CITY // NEW IDENTITY',
	['entry.title'] = 'Choose your character',
	['entry.create.title'] = 'Build your character',
	['entry.create.warning'] = 'None of this can be changed later.',
	['entry.slots'] = '{used}/{slots} SLOTS',

	['entry.card.id'] = 'ID {citizenId}',
	['entry.card.lastSeen'] = 'Last seen {when}',
	['entry.card.never'] = 'never',
	['entry.card.unemployed'] = 'Unemployed',

	['entry.slot.number'] = 'Slot {index}',
	['entry.slot.empty'] = 'Empty slot',
	['entry.slot.note'] = 'Nobody lives here yet.',

	['entry.create.card'] = 'New character',
	['entry.create.note'] = 'Build somebody new. {used} of {slots} slots used.',
	['entry.create.full'] = 'Every slot on this account is taken.',

	['entry.body.female'] = 'Female',
	['entry.body.male'] = 'Male',

	['entry.notice.waiting'] = 'Waiting for your characters...',
	['entry.notice.entering'] = 'Entering Night City...',
	['entry.notice.registering'] = 'Writing you into the city...',
	['entry.notice.created'] = '{name} is ready.',
	['entry.notice.timedOut'] = 'Nothing answered. Try again.',
	['entry.notice.noLifepath'] = 'No lifepath has arrived yet. Try again in a moment.',
	['entry.refusal.unknown'] = 'That was refused ({code}).',

	['entry.step.identity'] = 'Identity',
	['entry.step.birth'] = 'Born',
	['entry.step.lifepath'] = 'Lifepath',
	['entry.step.body'] = 'Body',
	['entry.step.review'] = 'Review',
	['entry.step.count'] = 'Step {step} of {steps}',

	['entry.field.firstName'] = 'First name',
	['entry.field.lastName'] = 'Last name',
	['entry.field.birthDate'] = 'Date of birth',
	['entry.field.origin'] = 'Lifepath',
	['entry.field.gender'] = 'Body',

	['entry.about.identity'] = 'The name on your papers. It is written once.',
	['entry.about.birth'] = 'Written as YYYY-MM-DD.',
	['entry.about.lifepath'] = 'Where you come from.',
	['entry.about.body'] = 'The body your character is built on. The one already ' ..
		'loaded comes first; the other reloads the world.',
	['entry.about.review'] = 'Read it back. Nothing below can be changed later.',

	['entry.hint.firstName'] = 'V',
	['entry.hint.lastName'] = 'Vector',
	['entry.hint.birthDate'] = '2050-01-01',

	['entry.refusal.required'] = 'This one is needed.',
	['entry.refusal.tooShort'] = 'At least {min} characters.',
	['entry.refusal.tooLong'] = 'At most {max} characters.',
	['entry.refusal.badName'] =
		'Letters, spaces, apostrophes and hyphens, starting with a letter.',
	['entry.refusal.notText'] = 'That text cannot be read.',
	['entry.refusal.badDate'] = 'Write it as YYYY-MM-DD.',
	['entry.refusal.noSuchDate'] = 'That day never happened. Pick a real date, in the past.',
	['entry.refusal.badChoice'] = 'Choose one of the options.',

	['entry.action.next'] = 'Continue',
	['entry.action.back'] = 'Back',
	['entry.action.submit'] = 'Create character',
	['entry.action.cancel'] = 'Cancel',

	['entry.key.move'] = 'Move',
	['entry.key.choose'] = 'Choose',
	['entry.key.back'] = 'Back',
	['entry.key.confirm'] = 'Confirm',
}

local FR = {
	['entry.eyebrow.roster'] = 'NIGHT CITY // QUI ÊTES-VOUS',
	['entry.eyebrow.create'] = 'NIGHT CITY // NOUVELLE IDENTITÉ',
	['entry.title'] = 'Choisissez votre personnage',
	['entry.create.title'] = 'Construisez votre personnage',
	['entry.create.warning'] = 'Rien de tout ceci ne pourra être modifié.',
	['entry.slots'] = '{used}/{slots} EMPLACEMENTS',

	['entry.card.id'] = 'ID {citizenId}',
	['entry.card.lastSeen'] = 'Vu pour la dernière fois {when}',
	['entry.card.never'] = 'jamais',
	['entry.card.unemployed'] = 'Sans emploi',

	['entry.slot.number'] = 'Emplacement {index}',
	['entry.slot.empty'] = 'Emplacement libre',
	['entry.slot.note'] = "Personne n'habite encore ici.",

	['entry.create.card'] = 'Nouveau personnage',
	['entry.create.note'] = 'Construisez quelqu\'un. {used} emplacements sur {slots} utilisés.',
	['entry.create.full'] = 'Tous les emplacements de ce compte sont pris.',

	['entry.body.female'] = 'Féminin',
	['entry.body.male'] = 'Masculin',

	['entry.notice.waiting'] = 'En attente de vos personnages...',
	['entry.notice.entering'] = 'Entrée dans Night City...',
	['entry.notice.registering'] = 'Inscription dans la ville...',
	['entry.notice.created'] = '{name} est prêt.',
	['entry.notice.timedOut'] = "Rien n'a répondu. Réessayez.",
	['entry.notice.noLifepath'] = "Aucun parcours de vie n'est encore arrivé. Réessayez.",
	['entry.refusal.unknown'] = 'Refusé ({code}).',

	['entry.step.identity'] = 'Identité',
	['entry.step.birth'] = 'Naissance',
	['entry.step.lifepath'] = 'Parcours',
	['entry.step.body'] = 'Corps',
	['entry.step.review'] = 'Relecture',
	['entry.step.count'] = 'Étape {step} sur {steps}',

	['entry.field.firstName'] = 'Prénom',
	['entry.field.lastName'] = 'Nom',
	['entry.field.birthDate'] = 'Date de naissance',
	['entry.field.origin'] = 'Parcours de vie',
	['entry.field.gender'] = 'Corps',

	['entry.about.identity'] = "Le nom qui figure sur vos papiers. Il ne s'écrit qu'une fois.",
	['entry.about.birth'] = 'Au format AAAA-MM-JJ.',
	['entry.about.lifepath'] = "D'où vous venez.",
	['entry.about.body'] = 'Le corps sur lequel votre personnage est construit. ' ..
		'Celui déjà chargé vient en premier ; l\'autre recharge le monde.',
	['entry.about.review'] = 'Relisez. Rien de ce qui suit ne pourra être modifié.',

	['entry.hint.firstName'] = 'V',
	['entry.hint.lastName'] = 'Vector',
	['entry.hint.birthDate'] = '2050-01-01',

	['entry.refusal.required'] = 'Celui-ci est obligatoire.',
	['entry.refusal.tooShort'] = 'Au moins {min} caractères.',
	['entry.refusal.tooLong'] = 'Au plus {max} caractères.',
	['entry.refusal.badName'] =
		'Lettres, espaces, apostrophes et traits d\'union, en commençant par une lettre.',
	['entry.refusal.notText'] = 'Ce texte ne peut pas être lu.',
	['entry.refusal.badDate'] = 'Écrivez-la au format AAAA-MM-JJ.',
	['entry.refusal.noSuchDate'] =
		"Ce jour n'a jamais existé. Choisissez une vraie date, dans le passé.",
	['entry.refusal.badChoice'] = 'Choisissez une des options.',

	['entry.action.next'] = 'Continuer',
	['entry.action.back'] = 'Retour',
	['entry.action.submit'] = 'Créer le personnage',
	['entry.action.cancel'] = 'Annuler',

	['entry.key.move'] = 'Naviguer',
	['entry.key.choose'] = 'Choisir',
	['entry.key.back'] = 'Retour',
	['entry.key.confirm'] = 'Confirmer',
}

-- Kept on the module table as well as registered: the two are compared at start,
-- so a key present in one language and missing from the other is named once
-- rather than rendered as its own key on somebody's screen.
M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
