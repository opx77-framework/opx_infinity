--- How long a call rings, how many may be on it, and what it sounds like.
-- @author dop42
--
-- Shared, like the garages and teleports configs above it and for the same
-- reason: the client half reads the sound names, the participant ceiling and
-- the refusal windows here, and the server re-derives every bound the client
-- thinks it knows. Nothing in this file is a decision -- every one of these
-- values is checked again on the server before it changes anything.

OPX.Config.MODULES.calls = {
	enabled = true,

	-- People on one call. Bounded at three by `Model.MAX_PARTICIPANTS` whatever
	-- is written here: `order` crosses to every participant's screen as a
	-- fixed-size row, and the owner asked for a third, not for a conference.
	MAX_PARTICIPANTS = 3,

	-- Seconds an unanswered invite rings before it gives up. It holds the
	-- caller's one outgoing slot and the target's one incoming slot for the
	-- whole of it, so this is also how long a call nobody picks up locks both
	-- of them out of placing another.
	INVITE_TTL_S = 30,

	-- Floor between two requests of one kind from one player, in milliseconds.
	-- A call is a card on somebody else's screen, so the spam this stops is
	-- aimed at a person rather than at the server.
	REQUEST_MS = 1500,

	-- Metres between two bodies for a CONTACT hand-over, and the only distance
	-- rule in the module. A call reaches across the city -- that is the
	-- feature -- but handing somebody your number is something you do standing
	-- in front of them, and it is the one action the eye offers that a client
	-- could otherwise claim from anywhere.
	CONTACT_RANGE = 6.0,

	-- Contact rows one character may keep. A bounded list, because it is
	-- written to the character's metadata blob and that blob is read on every
	-- load.
	MAX_CONTACTS = 64,

	-- The blue eye-glow lease, in milliseconds.
	--
	-- BOUNDED AND RENEWED, NEVER HELD OPEN. `Open77.players.setHoloCallEyes`
	-- takes `durationMs = 0` to mean "until this resource releases it", and
	-- that is the shape `modules/animations/client/walk.lua` has a whole header
	-- about: a lease is not tied to the thing that justified it, so if a call
	-- ends down a path nobody released on, the player walks around with lit
	-- eyes for the rest of the session with no idea why. A lease that expires
	-- on its own means the worst case is LEASE_MS of glow rather than a
	-- session of it, and the renewal below is what makes a live call keep it.
	EYES = {
		LEASE_MS = 30000,
		RENEW_MS = 10000,
	},

	-- Milliseconds between sweeps: expiring invites, renewing leases, and
	-- checking that everybody on a call is still there.
	SCAN_MS = 2000,

	-- ── the sound ────────────────────────────────────────────────────────────
	--
	-- THE GAME'S OWN, PLAYED BY NAME, WITH NOTHING SHIPPED. These are Wwise
	-- event names out of Cyberpunk's own `ui_phone_01` bank, read from the
	-- devkit's sfx catalogue for game build 2.31 -- not invented, and not an
	-- audio file copied out of the game and redistributed with this resource.
	-- `Open77.sfx.play2d(event)` posts them through `gameGameAudioSystem::Play`
	-- with no entity, which is the same door the vanilla frontend uses for its
	-- own menu sounds. So the incoming call sounds exactly like an incoming
	-- call because it IS the incoming call sound.
	--
	-- The platform refuses a name outside its curated table with
	-- `invalid_sfx_event` rather than forwarding it, so a typo here is a
	-- refusal the client half notes once and not a silent no-op. Every name is
	-- carried as `seed_requires_2.31_runtime_validation` in the catalogue --
	-- the devkit has read them out of the bank but has not played them on this
	-- build -- which is the other reason the client treats a refusal as a
	-- missing sound rather than as a fault.
	--
	-- An empty string switches one off, the way `config/admin.lua`'s noclip
	-- SOUND does. An operator who wants their own ringtone instead wants
	-- `Open77.sound.play` and a file in `web/audio/`, which is a different
	-- door and is not wired here.
	SOUND = {
		-- The ring, on the screen being called.
		INCOMING = 'ui_phone_incoming_call',
		-- Silences the ring: answered, refused, expired or hung up.
		INCOMING_STOP = 'ui_phone_incoming_call_stop',
		ACCEPTED = 'ui_phone_incoming_call_positive',
		DECLINED = 'ui_phone_incoming_call_negative',

		-- The dial tone, on the screen that placed the call.
		OUTGOING = 'ui_phone_initiation_call',
		OUTGOING_STOP = 'ui_phone_initiation_call_stop',

		-- The line closing, on every screen that was on it.
		HANG_UP = 'ui_phone_off',
	},

	-- Seconds the incoming card stays on screen before it takes ITSELF down.
	--
	-- THE OWNER'S HARD REQUIREMENT, AS A NUMBER: "il faut pas que ca gene la
	-- vision du joueur". A card that sits at the edge of the view for the whole
	-- thirty seconds an invite rings is in the player's vision for thirty
	-- seconds, whatever its width -- so it says its piece and gets out of the
	-- way, and the eye's re-pop row brings it back for as long as the call is
	-- still ringing.
	--
	-- THE CALL GOES ON RINGING. This is the card leaving, not the call being
	-- refused: the sound keeps re-arming, ACCEPT and DECLINE stay on the eye,
	-- and the server knows nothing about any of it. Dismissing and declining
	-- being different things is the whole reason the client half holds
	-- `dismissed` locally and never tells the server.
	--
	-- Long enough to read three lines twice, short enough that nobody shoots at
	-- something they could not see.
	CARD_DWELL_S = 8,

	-- Milliseconds between two re-arms of the ring, so an incoming call rings
	-- for as long as the card is up rather than once. `ui_phone_incoming_call`
	-- is a one-shot: there is no loop to start and no handle to stop, which is
	-- why `INCOMING_STOP` exists as a separate event and why this is a clock
	-- rather than a flag.
	RING_EVERY_MS = 3500,
}
