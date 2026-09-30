--- Player-facing text for the bank branches.
-- @author XEROX710

local EN = {
	['bank.title'] = 'BANK',
	['bank.key.use'] = 'Use a bank branch',
	['bank.prompt'] = 'Bank',

	['bank.menu.title'] = 'BANK \u{2014} {branch}',
	['bank.menu.account'] = 'Account balance',
	['bank.menu.cash'] = 'Cash in hand',
	['bank.menu.withdraw'] = 'WITHDRAW',
	['bank.menu.deposit'] = 'DEPOSIT',
	['bank.menu.withdrawAmount'] = 'Withdraw {amount}',
	['bank.menu.depositAmount'] = 'Deposit {amount}',
	['bank.menu.withdrawAll'] = 'Withdraw everything',
	['bank.menu.depositAll'] = 'Deposit all your cash',
	['bank.menu.other'] = 'Another amount\u{2026}',
	['bank.menu.otherHint'] = 'Type the amount in eddies',
	['bank.menu.close'] = 'Close',

	['bank.form.withdraw'] = 'WITHDRAW',
	['bank.form.deposit'] = 'DEPOSIT',
	['bank.form.amount'] = 'Amount',
	['bank.form.hint'] = 'Eddies, up to {max} at a time',

	['bank.done.withdraw'] = 'Withdrew {amount}. Account {account}, cash {cash}.',
	['bank.done.deposit'] = 'Deposited {amount}. Account {account}, cash {cash}.',

	['bank.refused.noCharacter'] = 'Load a character first.',
	['bank.refused.notAtBranch'] = 'Stand at a bank branch to do that.',
	['bank.refused.badAmount'] = 'That is not an amount the bank can move.',
	['bank.refused.tooMuch'] = 'That is more than one transaction can move.',
	['bank.refused.insufficient'] = 'Not enough money for that.',
	['bank.refused.nothing'] = 'There is nothing to move.',
	['bank.refused.busy'] = 'One moment.',
	['bank.refused.failed'] = 'The bank refused the transaction: {reason}',
	['bank.noMenu'] = 'The bank screen is not available right now.',

	['bank.noPosition'] = 'Your position could not be read.',
	['bank.captureFailed'] = 'The branch could not be saved.',
	['bank.help.add'] = 'Place a bank branch where you stand',
	['bank.help.addKey'] = 'The branch key (optional)',
	['bank.help.addLabel'] = 'The name shown on the menu (optional)',
	['bank.help.remove'] = 'Remove a captured bank branch',
	['bank.help.removeKey'] = 'The branch key',
	['bank.help.list'] = 'List every bank branch',
}

local FR = {
	['bank.title'] = 'BANQUE',
	['bank.key.use'] = 'Utiliser une agence bancaire',
	['bank.prompt'] = 'Banque',

	['bank.menu.title'] = 'BANQUE \u{2014} {branch}',
	['bank.menu.account'] = 'Solde du compte',
	['bank.menu.cash'] = 'Liquide en poche',
	['bank.menu.withdraw'] = 'RETIRER',
	['bank.menu.deposit'] = 'D\u{C9}POSER',
	['bank.menu.withdrawAmount'] = 'Retirer {amount}',
	['bank.menu.depositAmount'] = 'D\u{E9}poser {amount}',
	['bank.menu.withdrawAll'] = 'Tout retirer',
	['bank.menu.depositAll'] = 'D\u{E9}poser tout le liquide',
	['bank.menu.other'] = 'Autre montant\u{2026}',
	['bank.menu.otherHint'] = 'Saisissez le montant en eddies',
	['bank.menu.close'] = 'Fermer',

	['bank.form.withdraw'] = 'RETRAIT',
	['bank.form.deposit'] = 'D\u{C9}P\u{D4}T',
	['bank.form.amount'] = 'Montant',
	['bank.form.hint'] = 'Eddies, jusqu\u{2019}\u{E0} {max} par op\u{E9}ration',

	['bank.done.withdraw'] = 'Retrait de {amount}. Compte {account}, liquide {cash}.',
	['bank.done.deposit'] = 'D\u{E9}p\u{F4}t de {amount}. Compte {account}, liquide {cash}.',

	['bank.refused.noCharacter'] = 'Chargez d\u{2019}abord un personnage.',
	['bank.refused.notAtBranch'] = 'Placez-vous \u{E0} une agence bancaire.',
	['bank.refused.badAmount'] = 'Ce montant est invalide.',
	['bank.refused.tooMuch'] = 'C\u{2019}est plus qu\u{2019}une op\u{E9}ration ne peut en d\u{E9}placer.',
	['bank.refused.insufficient'] = 'Fonds insuffisants.',
	['bank.refused.nothing'] = 'Il n\u{2019}y a rien \u{E0} d\u{E9}placer.',
	['bank.refused.busy'] = 'Un instant.',
	['bank.refused.failed'] = 'La banque a refus\u{E9} l\u{2019}op\u{E9}ration : {reason}',
	['bank.noMenu'] = 'L\u{2019}\u{E9}cran de la banque est indisponible.',

	['bank.noPosition'] = 'Votre position est illisible.',
	['bank.captureFailed'] = 'L\u{2019}agence n\u{2019}a pas pu \u{EA}tre enregistr\u{E9}e.',
	['bank.help.add'] = 'Placer une agence bancaire ici',
	['bank.help.addKey'] = 'La cl\u{E9} de l\u{2019}agence (facultatif)',
	['bank.help.addLabel'] = 'Le nom affich\u{E9} dans le menu (facultatif)',
	['bank.help.remove'] = 'Supprimer une agence enregistr\u{E9}e',
	['bank.help.removeKey'] = 'La cl\u{E9} de l\u{2019}agence',
	['bank.help.list'] = 'Lister les agences bancaires',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
