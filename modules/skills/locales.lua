--- Player-facing text for the skill tree: the trunks, the fifteen nodes, what
-- the ledger says when it moves, and every refusal.
-- @author XEROX710
--
-- Log lines and error codes stay in English: a log is read by an operator, and
-- a code is read by a script. Every string a player can see is here twice.

local EN = {
	['skills.title'] = 'SKILL TREE',
	['skills.key.tree'] = 'Skill tree',

	-- The header's readouts. Every one of them states a number the surface was
	-- given (rule 8), which is why there is no decorative filler beside them.
	['skills.level'] = 'LVL {level}',
	['skills.xp'] = '{xp}/{need} XP',
	['skills.points'] = '{points} PTS',
	['skills.trunkRank'] = 'RANK {rank}/{depth}',
	['skills.branchXp'] = '{xp}/{need} INTO THIS TRUNK',
	['skills.claimed'] = 'NODES {have}/{of}',

	['skills.branch.ncpd'] = 'NCPD',
	['skills.branch.maxtac'] = 'MAXTAC',
	['skills.branch.street'] = 'STREET',

	-- The three trunks' fifteen nodes. A NAME is what the node IS; a DESC is
	-- what it does, with the perk's own value spoken as the content it is.
	['skills.node.ncpd1'] = 'Beat Instinct',
	['skills.desc.ncpd1'] = 'Read a street before it turns. Vest rating +{value}.',
	['skills.node.ncpd2'] = 'Quick Hands',
	['skills.desc.ncpd2'] = 'Reload drills until they are reflex. Reload +{value}%.',
	['skills.node.ncpd3'] = 'Soft Step',
	['skills.desc.ncpd3'] = 'Move like the sirens are somebody else\\u{2019}s. Stealth +{value}%.',
	['skills.node.ncpd4'] = 'Command Voice',
	['skills.desc.ncpd4'] = 'A scene listens when you arrive. Presence +{value}%.',
	['skills.node.ncpd5'] = 'Night City Legend',
	['skills.desc.ncpd5'] = 'The badge outlives the shift. All ratings +{value}%.',

	['skills.node.maxtac1'] = 'Iron Stomach',
	['skills.desc.maxtac1'] = 'Ride the drop without losing it. G-tolerance +{value}%.',
	['skills.node.maxtac2'] = 'Rope Discipline',
	['skills.desc.maxtac2'] = 'Board a moving hull like it is a doorway. Boarding +{value}%.',
	['skills.node.maxtac3'] = 'Terminal Velocity',
	['skills.desc.maxtac3'] = 'Own the last hundred metres. Drop accuracy +{value}%.',
	['skills.node.maxtac4'] = 'Laser Discipline',
	['skills.desc.maxtac4'] = 'The warning lines land where you mean them. Targeting +{value}%.',
	['skills.node.maxtac5'] = 'Reaper',
	['skills.desc.maxtac5'] = 'They name you before they run. All ratings +{value}%.',

	['skills.node.street1'] = 'Silver Tongue',
	['skills.desc.street1'] = 'Every price is an opening bid. Haggle +{value}%.',
	['skills.node.street2'] = 'Fleet Feet',
	['skills.desc.street2'] = 'Outrun the consequences. Sprint +{value}%.',
	['skills.node.street3'] = 'Crafted Touch',
	['skills.desc.street3'] = 'Work with your hands and mean it. Craft +{value}%.',
	['skills.node.street4'] = 'Scavenger\\u{2019}s Eye',
	['skills.desc.street4'] = 'Value where others see junk. Salvage +{value}%.',
	['skills.node.street5'] = 'Fixer',
	['skills.desc.street5'] = 'You know a person. Everything +{value}%.',

	-- The detail strip and its one control.
	['skills.detail'] = 'SELECT A NODE',
	['skills.spend'] = 'UNLOCK · {cost} PT',
	['skills.stow'] = 'CLOSE [{key}]',

	-- What the ledger says when it moves. The work line is the feed's row; the
	-- level line is a second sentence because a level is a different event.
	['skills.gain.work'] = '+{xp} XP',
	['skills.gain.level'] = 'LEVEL {level} · +{points} PT',
	['skills.gain.node'] = 'NODE UNLOCKED · {cost} PT',

	-- Refusals. Same words the panel would use; `M.Skill.Refusal` is the map.
	['skills.noCharacter'] = 'Your record could not be read.',
	['skills.noNode'] = 'There is no such node.',
	['skills.noPoints'] = 'Not enough points.',
	['skills.prereq'] = 'The node above it is still locked.',
	['skills.rank'] = 'This trunk has not earned that node yet.',
	['skills.unlocked'] = 'That node is already yours.',
	['skills.failed'] = 'That could not be done.',
	['skills.menuOpen'] = 'Close the menu first.',
}

local FR = {
	['skills.title'] = 'ARBRE DE COMP\\u{2019}TENCES',
	['skills.key.tree'] = 'Arbre de comp\\u{2019}tences',

	['skills.level'] = 'NIV. {level}',
	['skills.xp'] = '{xp}/{need} XP',
	['skills.points'] = '{points} PTS',
	['skills.trunkRank'] = 'RANG {rank}/{depth}',
	['skills.branchXp'] = '{xp}/{need} DANS CETTE BRANCHE',
	['skills.claimed'] = 'NOEUDS {have}/{of}',

	['skills.branch.ncpd'] = 'NCPD',
	['skills.branch.maxtac'] = 'MAXTAC',
	['skills.branch.street'] = 'RUE',

	['skills.node.ncpd1'] = 'Instinct de patrouille',
	['skills.desc.ncpd1'] = 'Lire une rue avant qu\\u{2019}elle ne tourne. Gilet +{value}.',
	['skills.node.ncpd2'] = 'Mains vives',
	['skills.desc.ncpd2'] = 'Des drills jusqu\\u{2019}au r\\u{2019}flexe. Rechargement +{value} %.',
	['skills.node.ncpd3'] = 'Pas l\\u{2019}ger',
	['skills.desc.ncpd3'] = 'Avancer comme si les sir\\u{2019}nes \\u{2019}taient celles des autres. Discr\\u{2019}tion +{value} %.',
	['skills.node.ncpd4'] = 'Voix de commandement',
	['skills.desc.ncpd4'] = 'La sc\\u{2019}ne \\u{2019}coute d\\u{2019}s votre arrivee. Presence +{value} %.',
	['skills.node.ncpd5'] = 'Legende de Night City',
	['skills.desc.ncpd5'] = 'Le badge survit au service. Toutes notes +{value} %.',

	['skills.node.maxtac1'] = 'Estomac de fer',
	['skills.desc.maxtac1'] = 'Tenir la chute sans c\\u{2019}der. G-tolerance +{value} %.',
	['skills.node.maxtac2'] = 'Discipline de corde',
	['skills.desc.maxtac2'] = 'Monter une carlingue en mouvement comme une porte. Embarquement +{value} %.',
	['skills.node.maxtac3'] = 'Vitesse terminale',
	['skills.desc.maxtac3'] = 'Poss\\u{2019}der les cent derniers metres. Precision en chute +{value} %.',
	['skills.node.maxtac4'] = 'Discipline laser',
	['skills.desc.maxtac4'] = 'Les lignes tombent o\\u{2019} vous les voulez. Vis\\u{2019}e +{value} %.',
	['skills.node.maxtac5'] = 'Faucheur',
	['skills.desc.maxtac5'] = 'On vous nomme avant de fuir. Toutes notes +{value} %.',

	['skills.node.street1'] = 'Langue d\\u{2019}argent',
	['skills.desc.street1'] = 'Chaque prix est une offre de d\\u{2019}part. Marchandage +{value} %.',
	['skills.node.street2'] = 'Pieds l\\u{2019}gers',
	['skills.desc.street2'] = 'Fuir les cons\\u{2019}quences. Sprint +{value} %.',
	['skills.node.street3'] = 'Main d\\u{2019}\\u{2019}uvre',
	['skills.desc.street3'] = 'Travailler de ses mains et le signer. Artisanat +{value} %.',
	['skills.node.street4'] = '\\u{2019}il du fouineur',
	['skills.desc.street4'] = 'De la valeur l\\u{2019} o\\u{2019} d\\u{2019}autres voient du rebut. R\\u{2019}cup\\u{2019}ration +{value} %.',
	['skills.node.street5'] = 'Fixeur',
	['skills.desc.street5'] = 'Vous connaissez quelqu\\u{2019}un. Tout +{value} %.',

	['skills.detail'] = 'CHOISISSEZ UN \\u{2019}UD',
	['skills.spend'] = 'D\\u{2019}BLOQUER \\u{2019} {cost} PT',
	['skills.stow'] = 'FERMER [{key}]',

	['skills.gain.work'] = '+{xp} XP',
	['skills.gain.level'] = 'NIVEAU {level} \\u{2019} +{points} PT',
	['skills.gain.node'] = '\\u{2019}UD D\\u{2019}BLOQU\\u{2019} · {cost} PT',

	['skills.noCharacter'] = 'Votre dossier n\\u{2019}a pas pu \\u{2019}tre lu.',
	['skills.noNode'] = 'Cet n\\u{2019}ud n\\u{2019}existe pas.',
	['skills.noPoints'] = 'Pas assez de points.',
	['skills.prereq'] = 'Le n\\u{2019}ud pr\\u{2019}c\\u{2019}dent est encore verrouill\\u{2019}.',
	['skills.rank'] = 'Cette branche n\\u{2019}a pas encore m\\u{2019}rit\\u{2019} ce n\\u{2019}ud.',
	['skills.unlocked'] = 'Ce n\\u{2019}ud est d\\u{2019}j\\u{2019} \\u{2019} vous.',
	['skills.failed'] = 'Cela n\\u{2019}a pas pu \\u{2019}tre fait.',
	['skills.menuOpen'] = 'Fermez d\\u{2019}abord le menu.',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
