--- Player-facing text for the call card, the live chip, the eye rows and every
--- refusal.
-- @author dop42
--
-- EVERY NAME IN `Model.REASONS` HAS A `calls.error.<name>` LINE HERE, and that
-- is not a convention this file hopes somebody keeps. `OPX.RefusalKey` looks a
-- refusal code up in the catalogue and, when it is not there, downgrades it to
-- `error.unavailable` with a warning written to the server log -- so a refusal
-- with no line is a refusal the player is never actually told, and the only
-- trace is a journal line nobody is reading at the time. The test suite walks
-- `Model.REASONS` against both catalogues and fails on a name missing from
-- either.
--
-- Log lines, the audit trail and the refusal CODES themselves stay in English,
-- like every other module here: they are read by an operator in a journal, not
-- by a player on a screen.

local M = OPX.Modules.Get('calls')

local EN = {
	-- ── the incoming card ────────────────────────────────────────────────────
	['calls.incoming.eyebrow'] = 'NETWATCH RELAY // INBOUND',
	['calls.incoming.title'] = 'INCOMING CALL',
	['calls.incoming.join'] = 'CONFERENCE INVITE',
	['calls.incoming.contact'] = 'CONTACT OFFERED',
	['calls.incoming.from'] = 'FROM',
	['calls.incoming.accept'] = 'ACCEPT',
	['calls.incoming.decline'] = 'DECLINE',
	-- The card says how it is answered rather than assuming the player knows.
	-- The eye is the only way in, and a card that did not say so would be a
	-- screen asking a question with no visible answer.
	['calls.incoming.hint'] = 'Hold ALT on yourself to answer.',
	['calls.incoming.expires'] = 'Expires in {time}',

	-- ── the live chip ────────────────────────────────────────────────────────
	-- The chip used to say "Show the call again", which named a row on the target
	-- eye. That row is gone with the rest of them; the way back is the hologram
	-- key, and the chip does not know which key that is -- a player may rebind it
	-- -- so it says what is TRUE rather than guessing at an instruction.
	['calls.live.waiting'] = 'A call is waiting.',
	['calls.live.title'] = 'CALL',
	['calls.live.elapsed'] = 'ELAPSED',
	['calls.live.with'] = 'WITH',
	['calls.live.others'] = '+{count}',

	-- ── the rows on the eye ──────────────────────────────────────────────────


	-- ── the hologram ─────────────────────────────────────────────────────────
	-- The whole feature's vocabulary now: the eye rows above are gone and these
	-- replaced them. See `config/calls.lua`'s KEY block for why.
	['calls.key.holo'] = 'Holocall',
	['calls.holo.eyebrow'] = 'NETWORK',
	['calls.holo.title'] = 'HOLOCALL',
	['calls.holo.close'] = 'CLOSE',
	['calls.holo.ringing'] = '{name} is calling you.',
	['calls.holo.sharing'] = '{name} wants to give you their contact.',
	['calls.holo.calling'] = 'Calling {name}...',
	['calls.holo.live'] = 'On a call with {names}.',
	['calls.holo.answer'] = 'ANSWER',
	['calls.holo.refuse'] = 'REFUSE',
	-- The share is a question, so its answers are a question's answers and not
	-- a call's. "le share contact devrais etre un input qui propose un yes or no".
	['calls.holo.yes'] = 'YES',
	['calls.holo.no'] = 'NO',
	['calls.holo.hangUp'] = 'HANG UP',
	['calls.holo.call'] = 'CALL',
	['calls.holo.add'] = 'ADD',
	['calls.holo.share'] = 'SHARE',
	['calls.holo.tab.contacts'] = 'CONTACTS',
	['calls.holo.tab.nearby'] = 'AROUND ME',
	['calls.holo.tab.recent'] = 'RECENT',
	['calls.holo.noContacts'] = 'Nobody has given you their contact yet.',
	['calls.holo.noNear'] = 'Nobody close enough to hand a contact to.',
	['calls.holo.noneNear'] = 'Nobody close enough to hand a contact to.',
	['calls.holo.noRecent'] = 'Nothing yet.',
	-- Four outcomes and four sentences, because "they did not pick up" and "you
	-- missed one" are the same event from two sides and a system that said the
	-- same thing to both would be telling one of them a small lie.
	['calls.holo.outcome.missed'] = 'Missed call',
	['calls.holo.outcome.unanswered'] = 'No answer',
	['calls.holo.outcome.declined'] = 'They refused',
	['calls.holo.outcome.refused'] = 'You refused',

	-- ── what happened ────────────────────────────────────────────────────────
	['calls.placed'] = 'Calling {name}...',
	['calls.ringing'] = '{name} is calling you.',
	['calls.answered'] = '{name} answered.',
	['calls.declined'] = '{name} refused the call.',
	['calls.joined'] = '{name} joined the call.',
	['calls.left'] = '{name} hung up.',
	['calls.ended'] = 'The call ended.',
	['calls.expired'] = '{name} did not answer.',
	['calls.contact.offered'] = '{name} offered you their contact.',
	['calls.contact.saved'] = '{name} is in your contacts.',

	-- ── the refusals, one per name in `Model.REASONS` ────────────────────────
	['calls.error.badRequest'] = 'That request made no sense.',
	['calls.error.tooFast'] = 'Slow down.',
	['calls.error.self'] = 'You cannot call yourself.',
	['calls.error.noSuchPlayer'] = 'There is nobody there.',
	['calls.error.notReady'] = 'You are not in the world yet.',
	['calls.error.targetNotReady'] = 'They are not reachable right now.',
	['calls.error.notAlive'] = 'Not while you are down.',
	['calls.error.targetNotAlive'] = 'They cannot take a call right now.',
	['calls.error.alreadyInCall'] = 'You are already on a call.',
	['calls.error.targetInCall'] = 'They are already on a call.',
	['calls.error.alreadyPending'] = 'You already have a call out.',
	['calls.error.targetPending'] = 'Their line is busy.',
	['calls.error.notInCall'] = 'You are not on a call.',
	['calls.error.callFull'] = 'That call is full.',
	['calls.error.alreadyParticipant'] = 'They are already on this call.',
	['calls.error.noSuchInvite'] = 'There is no call waiting for you.',
	['calls.error.expired'] = 'That call already rang out.',
	['calls.error.tooFar'] = 'Stand closer to hand over a contact.',
	['calls.error.unreadable'] = 'The server could not place that call. Try again.',
}

local FR = {
	['calls.incoming.eyebrow'] = 'RELAIS NETWATCH // ENTRANT',
	['calls.incoming.title'] = 'APPEL ENTRANT',
	['calls.incoming.join'] = 'INVITATION CONFÉRENCE',
	['calls.incoming.contact'] = 'CONTACT PROPOSÉ',
	['calls.incoming.from'] = 'DE',
	['calls.incoming.accept'] = 'ACCEPTER',
	['calls.incoming.decline'] = 'REFUSER',
	['calls.incoming.hint'] = 'Maintenez ALT sur vous-même pour répondre.',
	['calls.incoming.expires'] = 'Expire dans {time}',

	['calls.live.title'] = 'APPEL',
	['calls.live.elapsed'] = 'DURÉE',
	['calls.live.with'] = 'AVEC',
	['calls.live.others'] = '+{count}',
	['calls.live.waiting'] = 'Un appel attend.',



	-- ── l'hologramme ─────────────────────────────────────────────────────────
	['calls.key.holo'] = 'Holo-appel',
	['calls.holo.eyebrow'] = 'RESEAU',
	['calls.holo.title'] = 'HOLO-APPEL',
	['calls.holo.close'] = 'FERMER',
	['calls.holo.ringing'] = '{name} vous appelle.',
	['calls.holo.sharing'] = '{name} veut vous donner son contact.',
	['calls.holo.calling'] = 'Appel de {name}...',
	['calls.holo.live'] = 'En appel avec {names}.',
	['calls.holo.answer'] = 'REPONDRE',
	['calls.holo.refuse'] = 'REFUSER',
	['calls.holo.yes'] = 'OUI',
	['calls.holo.no'] = 'NON',
	['calls.holo.hangUp'] = 'RACCROCHER',
	['calls.holo.call'] = 'APPELER',
	['calls.holo.add'] = 'AJOUTER',
	['calls.holo.share'] = 'PARTAGER',
	['calls.holo.tab.contacts'] = 'CONTACTS',
	['calls.holo.tab.nearby'] = 'AUTOUR DE MOI',
	['calls.holo.tab.recent'] = 'RECENTS',
	['calls.holo.noContacts'] = 'Personne ne vous a encore donne son contact.',
	['calls.holo.noNear'] = 'Personne d\'assez proche pour donner un contact.',
	['calls.holo.noneNear'] = 'Personne d\'assez proche pour donner un contact.',
	['calls.holo.noRecent'] = 'Rien pour le moment.',
	['calls.holo.outcome.missed'] = 'Appel manque',
	['calls.holo.outcome.unanswered'] = 'Pas de reponse',
	['calls.holo.outcome.declined'] = 'Il a refuse',
	['calls.holo.outcome.refused'] = 'Vous avez refuse',

	['calls.placed'] = 'Appel de {name}...',
	['calls.ringing'] = '{name} vous appelle.',
	['calls.answered'] = '{name} a répondu.',
	['calls.declined'] = "{name} a refusé l'appel.",
	['calls.joined'] = "{name} a rejoint l'appel.",
	['calls.left'] = '{name} a raccroché.',
	['calls.ended'] = "L'appel est terminé.",
	['calls.expired'] = "{name} n'a pas répondu.",
	['calls.contact.offered'] = '{name} vous propose son contact.',
	['calls.contact.saved'] = '{name} est dans vos contacts.',

	['calls.error.badRequest'] = "Cette requête n'a aucun sens.",
	['calls.error.tooFast'] = 'Doucement.',
	['calls.error.self'] = 'Vous ne pouvez pas vous appeler vous-même.',
	['calls.error.noSuchPlayer'] = "Il n'y a personne.",
	['calls.error.notReady'] = "Vous n'êtes pas encore dans le monde.",
	['calls.error.targetNotReady'] = "Cette personne n'est pas joignable.",
	['calls.error.notAlive'] = 'Pas pendant que vous êtes à terre.',
	['calls.error.targetNotAlive'] = 'Cette personne ne peut pas répondre.',
	['calls.error.alreadyInCall'] = 'Vous êtes déjà en appel.',
	['calls.error.targetInCall'] = 'Cette personne est déjà en appel.',
	['calls.error.alreadyPending'] = 'Vous avez déjà un appel en cours.',
	['calls.error.targetPending'] = 'Sa ligne est occupée.',
	['calls.error.notInCall'] = "Vous n'êtes pas en appel.",
	['calls.error.callFull'] = 'Cet appel est complet.',
	['calls.error.alreadyParticipant'] = 'Cette personne est déjà sur cet appel.',
	['calls.error.noSuchInvite'] = "Aucun appel ne vous attend.",
	['calls.error.expired'] = 'Cet appel a déjà sonné dans le vide.',
	['calls.error.tooFar'] = 'Rapprochez-vous pour transmettre un contact.',
	['calls.error.unreadable'] = "Le serveur n'a pas pu placer cet appel. Réessayez.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
