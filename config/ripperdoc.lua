--- The ripperdoc clinic: the chairs, the tray, and what each piece of chrome costs.
-- @author XEROX710
--
-- THE TRAY IS THE WHOLE BASE GAME. Every piece Night City's ripperdocs sell
-- is on it, filed under the body system the base game files it under
-- (`modules/ripperdoc/shared/cyberware.lua`), with the base game's slot counts
-- and a capacity limit. What a piece DOES is the platform's decision: the
-- Gorilla Arms family, Reinforced Tendons, the decks and Self-ICE are durable
-- platform implants (`Open77.cyberware`); Kerenzikov, the Sandevistans and the
-- Berserks are platform grants (dash, reflex overdrive, ground slam); the
-- plating, the circulatory pieces and the rest carry stat EFFECTS the server
-- really applies (armor plating, max health, regeneration, stamina, no fall
-- damage, capacity); and the chrome the platform has no adapter for is sold as
-- roleplay chrome, and says so. Every piece wears out (DURABILITY below).
--
-- THE CATALOG BELOW is the operator's own hand-tuned pieces, and wins over a
-- base-game piece of the same id. Its grade fields are the platform's shared
-- schema, and the values are the .87 wiki's own example grades: the training
-- legs are literally the wiki's (`jumpStaminaCost = 15`, `cooldownMs = 800`)
-- and the athlete its stated counterpart (8 stamina, 500 ms). The prices beside
-- them are POLICY and edited here without touching the module.
--
-- CHAIRS ARE PLACES WITH A CHAIR ON THEM. A row is one ripperdoc chair in the
-- world: the patient is seated on it with the platform's own portable `chair`
-- workspot (`Open77.animations.playAt` puts the pose and its invisible device
-- under them). PLACE ONE IN GAME with `/opx.clinic.add` at the base game's own
-- ripperdoc chair -- aim at it -- and the capture takes THAT chair's position
-- and facing, so the patient sits in the chair the city already placed and no
-- prop is spawned. Away from a base-game chair, `/opx.clinic.add` captures where
-- the operator stands, and `CHAIR_PROP` below spawns a visible chair there.
-- `/opx.clinic.tune` nudges the seat inside the chair; every capture prints
-- the line to check in here.
--
-- The marker vocabulary is fixed by the engine: styles are `interaction`,
-- `objective`, `spawn` and `danger`, shapes are `ring` and `cylinder`, RADIUS
-- is 0.1..50 and MAX_DISTANCE is 1..500 -- the same words `config/clothing.lua`
-- documents, because the same native answers both.

OPX.Config.MODULES.ripperdoc = {
	enabled = true,

	-- What the clinic charges in -- one of `OPX.Config.SHARED.MONEY.TYPES`.
	MONEY = 'EDDIES',

	-- Metres. How close to the chair the press must be, and how close a patient
	-- must be to be offered the seat.
	REACH = 2.5,

	-- Jobs bank points a finished installation pays the operator. The jobs
	-- funnel turns them into grade seniority and skill-tree XP like every other
	-- credited work; self-service pays nobody.
	POINTS = 5,

	-- What a clinic's marker looks like: the standing cylinder in the one style
	-- that says "press here", lifted the platform's own 0.06 m off the floor
	-- (the POI path lifts its markers the same way).
	MARKER = { shape = 'cylinder', style = 'interaction', RADIUS = 1.2, LIFT = 0.06 },

	-- Metres a marker draws from at all.
	MAX_DISTANCE = 150.0,

	-- The interaction key. The id is stable because a player's rebind is stored
	-- under it; the menu itself needs no key -- it opens the moment the patient
	-- is seated.
	KEY = { ID = 'opx.ripperdoc.use', NAME = 'ripperdoc.key.use', DEFAULT = 'E' },

	-- THE CHAIR THE PATIENT CAN SEE. The seat itself is the platform's portable
	-- workspot (a real prop rendered through the session body), but a patient
	-- looking at nothing needs a chair to look AT: every configured chair gets
	-- one physical prop spawned on its place and the patient sits on it.
	-- `MODEL` is a generated prop alias like the poi's (`furniture.chair.metal`,
	-- `office.chair`), placed as `open77_prop_furniture_chair_metal` and so on;
	-- `OFFSET` nudges the chair under the pose and `YAW_OFFSET` turns it so its
	-- front faces the patient (the pose faces the captured YAW; if your chair
	-- sits backwards in game, add 180 here). Where no host prop API exists the
	-- module says so once at boot and the seats work as the invisible workspots
	-- they always were.
	CHAIR_PROP = {
		enabled = true,
		MODEL = 'furniture.chair.metal',
		OFFSET = { X = 0.0, Y = 0.0, Z = 0.0 },
		YAW_OFFSET = 0.0,
		STREAMING_RADIUS = 150.0,
	},

	-- What the placement commands answer to. `add` captures a chair where the
	-- operator stands, `remove` takes a captured one away, `list` prints them
	-- all -- the same three every other station module ships.
	COMMANDS = {
		add = 'opx.clinic.add',
		remove = 'opx.clinic.remove',
		list = 'opx.clinic.list',
		-- Nudges a chair's seat inside the chair: forward, right and up in
		-- metres along the CHAIR's own axes, and a turn in degrees.
		tune = 'opx.clinic.tune',
		-- What a patient's chrome record, binding, body and client projection
		-- say -- the first thing to run when the tray answers "not ready".
		diag = 'opx.clinic.diag',
		-- The base-game menu recorder, switched on one player's client (see
		-- RECORDER below): `on`, `off`, `snap` (one snapshot now), `dump`.
		record = 'opx.clinic.record',
		-- The record reader (see RECORDS below): `/opx.clinic.records` reads
		-- every base-game cyberware record through your own client,
		-- `/opx.clinic.records status` says how far it got.
		records = 'opx.clinic.records',
		-- THE SANDEVISTAN KEY, per player and unrestricted (it touches the
		-- caller's own machine and nothing else): `/opx.sandy.key` says which
		-- key engages the overdrive, `/opx.sandy.key v` rebinds it, and
		-- `/opx.sandy.key reset` gives it back to POWER_KEYS.reflex below. The
		-- same rebind is in Pause > Settings > KEY BINDINGS as "Overdrive:
		-- engage the reflex boost", and either one follows the player to every
		-- server.
		key = 'opx.sandy.key',
		-- A whole Sandevistan on the caller WITHOUT the overdrive -- the look,
		-- the layers, the slowed world and the screen, through the same code --
		-- for testing the presentation on its own: `/opx.sandy.test [seconds]`
		-- (1 to 44: as long as the longest level-scaled boost). Restricted: it
		-- slows every player near the caller.
		test = 'opx.sandy.test',
		-- THE ADMIN'S OVERRIDE, on the caller's own body: `/opx.clinic.chrome
		-- full` puts a fresh life on every piece fitted on you (repaired,
		-- re-armed, a broken implant fitted back), `/opx.clinic.chrome 40` sets
		-- them all to 40% (the time left matching it), `/opx.clinic.chrome 0`
		-- breaks them all exactly the way wear does. Restricted.
		chrome = 'opx.clinic.chrome',
	},

	-- WHO WORKS THE CHAIR. A ripperdoc presses the chair and gets the desk;
	-- with REQUIRE_DUTY (the shipped value) only while clocked in, so an
	-- off-duty ripperdoc sits in the chair like any other patient.
	ATTEND = { REQUIRE_DUTY = true },

	-- THE SEAT. `PROFILE` is the platform workspot the patient is posed in
	-- (the portable `chair`, which renders nothing -- the chair they see is
	-- the one under them). `/opx.clinic.add` looks for the base-game chair
	-- the operator is at -- the object under the crosshair, or the nearest
	-- chair-like object within `SCAN_RADIUS` -- and takes ITS position and
	-- facing when it is within `SNAP_RADIUS` of the operator; a chair
	-- captured that way spawns no prop. `VANILLA` is the seat offset a new
	-- snapped chair starts with (forward/right/up in metres along the chair's
	-- own axes, YAW in degrees); fix one chair with `/opx.clinic.tune`.
	SEAT = {
		PROFILE = 'chair',
		SCAN_RADIUS = 4.0,
		SNAP_RADIUS = 6.0,
		-- The object under the crosshair counts as the chair from this close
		-- even when nothing in its class or name says "chair" (the city's own
		-- ripperdoc chair need not). Further off, only a chair-worded object
		-- does -- and a body, a car, a door or a weapon never.
		AIM_RADIUS = 3.0,
		VANILLA = { FORWARD = 0.0, RIGHT = 0.0, UP = 0.0, YAW = 0.0 },
		-- Words that make an object a chair when the client scores what is
		-- around it (class names and display names, case-insensitive).
		WORDS = { 'ripper', 'chair', 'seat', 'medic', 'surg', 'operat', 'dentist',
			'recliner', 'armchair', 'stool', 'clinic', 'doctor' },
	},

	-- THE BASE GAME'S CHROME. Every piece Night City's ripperdocs sell
	-- (`modules/ripperdoc/shared/cyberware.lua`), priced here: one price per
	-- tier, an iconic piece at `ICONIC_MULTIPLIER` of it, and chrome with no
	-- mechanical effect on this server (`rp` kind) at `RP_MULTIPLIER`. Pull a
	-- piece off the tray by listing its id in EXCLUDE; set `enabled = false`
	-- to sell only the CATALOG below.
	VANILLA = {
		enabled = true,
		PRICE_BY_TIER = { 120, 350, 800, 1600, 3000 },
		ICONIC_MULTIPLIER = 1.6,
		RP_MULTIPLIER = 0.6,
		REMOVE_FRACTION = 0.1,
		REMOVE_MIN = 25,
		EXCLUDE = {},
		-- Chrome with no multiplayer adapter on this build (the `rp` kind:
		-- Mantis Blades, the Monowire, the Projectile Launcher, the Kiroshi
		-- optics...) is OFF THE SHELF: nothing can put it on the body, so
		-- nobody is sold it. A patient who already wears one keeps it and can
		-- still have it pulled or mended. `true` sells it again as roleplay
		-- chrome that costs capacity and does nothing mechanical.
		SELL_RP = false,
	},

	-- A PLATFORM IMPLANT WHOSE NATIVE FITTING FAILED (the arms, the legs, a
	-- deck: `native_projection_failed` from the patient's own client) is
	-- tried again before the patient is refunded -- the platform's own tests
	-- record the native step timing out once and succeeding on the next try.
	-- NATIVE is how many more tries, WAIT_MS how long after the failure.
	RETRY = { NATIVE = 1, WAIT_MS = 4000 },

	-- THE RECORD READER. A dedicated server has no copy of the game, so the
	-- base game's own names for its cyberware are read through a connected
	-- client: the server hands it the TweakDB record ids in batches, its live
	-- TweakDB answers what each one is, and the answers are kept in the
	-- `opx77_ripperdoc_records` table. AUTO reads them once through the first
	-- player who stays AUTO_AFTER_MS in the city, and never again while the
	-- table holds every record. BATCH ids per round trip.
	RECORDS = { AUTO = true, AUTO_AFTER_MS = 90000, BATCH = 40 },

	-- THE BODY'S LIMIT, the base game's: every fitted piece costs capacity,
	-- and a piece that would not fit is refused. A Chrome Compressor adds to
	-- it. `enabled = false` turns the rule off.
	CAPACITY = { enabled = true, BASE = 100 },

	-- How many pieces each body system takes, over the base game's (frontal
	-- cortex 3, operating system 1, arms 1, skeleton 2, nervous system 3,
	-- integumentary 3, face 1, hands 1, circulatory 3, legs 1). The operating
	-- system holds ONE of a deck, a Sandevistan, a Berserk or the compressor --
	-- raise it to let a patient wear them together.
	SYSTEMS = {},

	-- AN UPGRADE trades the fitted grade in for this fraction of its price.
	UPGRADE = { TRADE_IN = 0.5 },

	-- THE KEYS THE POWERS ANSWER TO, by power class: every Sandevistan engages
	-- on `reflex`, Kerenzikov dashes on `dash` and a Berserk slams on
	-- `ability`. This is the DEFAULT the platform registers the action under on
	-- the player's machine (`inputKey`); a player's own rebind wins over it and
	-- is never overwritten by a change here. The platform's vocabulary: one
	-- letter or digit, f1..f12, or space, enter, tab, shift, ctrl, alt,
	-- capslock, backspace, insert, delete, home, end, pageup, pagedown, up,
	-- down, left, right. Anything else falls back to the piece's own key.
	POWER_KEYS = { reflex = 'x', dash = 'z', ability = 'l' },

	-- THE SANDEVISTAN. The platform's overdrive is a speed buff on the owner's
	-- own body; everything else a Sandevistan is -- the world slowing, the look
	-- on the body, the screen -- is drawn here, for a piece named in LOOK (its
	-- definition is registered with `presentation = 'none'`, so the platform's
	-- blue glow is off). A piece not named keeps the platform's own.
	--
	-- A look, field by field:
	--   BLINK          one cooked `.effect` at the body's feet as the boost is
	--                  accepted (START) and as it ends (END), left where it
	--                  went off for `seconds`: Adam Smasher's own
	--                  `fx_sandevistan_start` / `fx_sandevistan_end`
	--   LAYERS         cooked `.effect` files bound to the boosted body by
	--                  EVERY client that has it streamed, the owner's own
	--                  included, for the whole boost: `slots` is the first body
	--                  slot the body has (a player's own body names them
	--                  `hips`, `left_foot`...; everybody else's `Hips`,
	--                  `LeftFoot`...), `every` restarts a one-shot effect so it
	--                  lasts the boost, `once` plays it once as the boost
	--                  starts, `who` = 'self' / 'others' limits it to the
	--                  owner's own body or to everybody else's, and `self` =
	--                  'fpp' / 'tps' limits it on the OWNER'S OWN body to first
	--                  or third person (their own hands are posed for first
	--                  person; a trail on their head would be in their eyes).
	--                  In third person the owner's model is the platform's
	--                  self-view body, drawn exactly where their own body is:
	--                  what is bound to their body's hips, feet, chest and head
	--                  is what their third-person model wears. `body` = true
	--                  marks a layer that stands down on the owner's own body
	--                  where the world ships VIEW (Smasher's start pair and the
	--                  loop file of his fx_sandevistan_loop): up to
	--                  opx_sandy_view 1.4.3 the model played them itself by
	--                  the names its template authors; since 1.4.4 it lights
	--                  only eye_glow_gold -- the NPC echoes smeared copies of
	--                  the screen around the body
	--   START          effects the BODY authors, played by name once as the
	--                  boost is accepted -- on everybody else's body only
	--   LOOP           effects the body authors, held by name for the boost
	--                  on everybody else's body only (the owner's own body
	--                  authors none of them; their third-person model does,
	--                  and VIEW's REDscript lights its eye_glow_gold)
	--   TIME           SELF_SCALE is how fast the world runs for the OWNER
	--                  while their body does not slow (the Apogee's own 0.15):
	--                  the owner's clock is claimed by VIEW's resource and its
	--                  REDscript exempts their body, exactly the base game's
	--                  asymmetry; on a build with the platform's dilation lease
	--                  (`Open77.dilation`) the lease does it instead. Where
	--                  neither can, the owner's whole view runs at
	--                  SELF_FALLBACK_SCALE (body included); 1 turns that off.
	--                  NEARBY_SCALE is how fast every player within RADIUS
	--                  metres runs for the boost -- world and body -- on any
	--                  build, which is also what makes THEM move in slow motion
	--                  on the owner's screen; a player who walks into the radius
	--                  mid-boost is slowed too, one who leaves it (RADIUS x 1.25)
	--                  is let go. RADIUS 0 slows nobody else. EASE_MS eases.
	--   SCREEN         the owner's screen when the base game's own one cannot
	--                  be had: a platform screen alias (`Open77.vfx.screen`,
	--                  STRENGTH picks its tier) held for the boost, with START a
	--                  one-shot alias as it engages. The base game's Sandevistan
	--                  screen is the camera's time-dilation curve `Sandevistan`
	--                  over a slowed clock, which only REDscript can set; VIEW
	--                  below ships that REDscript, and while it runs the owner
	--                  gets the real screen and this stand-in stays off
	--   SOUND          one positioned sound at activation, heard on the body
	--   SELF           false keeps the look's layers and blinks off the
	--                  owner's own body (their screen and clock are unaffected)
	--   PLATE          the nameplate while boosted -- past ~20 m it is the only
	--                  cue anybody can read (the platform's own marker cannot
	--                  run here: this resource owns the plates)
	--
	-- THE `smasher` LOOK IS ADAM SMASHER'S OWN SANDEVISTAN, read out of his
	-- 2.31 entity (`base\characters\entities\boss\adam_smasher.ent`, the
	-- `fx_sandevistan` and `fx_animalboss` effect spawners) and put on a player:
	--   fx_sandevistan_start/_end   -> ch_adam_smasher_sandevistan_teleport_start/_end (Root)  = BLINK
	--   sandevistan_trails_smasher  -> ch_npc_sandevistan_trail on wrists, heels, spine, arms  = the trail LAYERS
	--   fx_sandevistan_loop         -> ch_oda_sandevistan_loop (Trajectory, Hips)              = a LAYER
	--   sandevistan_loop            -> ch_npc_ability_kerenzikov_center_loop (Root)            = a LAYER
	--   fx_sandevistan_left/_right  -> ch_npc_sandevistan_left/_right (Hips), with the dash sound = START
	--   fx_sandevistan_center       -> ch_npc_sandevistan_center (Trajectory), a flash       = a LAYER, once
	-- HIS GHOST TRAIL -- the afterimages he leaves when he dashes -- is drawn
	-- by VIEW on the player's own model: its archive gives every player body
	-- twelve layers of a copy of ITS OWN body, arms and head in his armour look
	-- (switched off), and its REDscript places them every frame where the body
	-- was 0.045, 0.09 ... 0.54 s before (opx_sandy_view 1.4.9; 1.4.7 confirmed
	-- in game; his own `sandevistan_multilayer.mt` copies, switched on by his
	-- `ch_smasher_sandevistan_*.effect`, never showed on a player body --
	-- `docs/sandevistan.md` has every build). It is lit by the LOOP trigger
	-- `opx_sandy_ghost_on` below (everybody else's copy of the owner, on every
	-- machine the owner is streamed to) and by VIEW's REDscript on the owner's
	-- own third-person model.
	-- A trail effect is 2 s long, so it is restarted every 1.8 s; each is a
	-- real-time effect on a body that runs in real time.
	SANDEVISTAN = {
		enabled = true,
		LOOK = { apogee_sandevistan = 'smasher' },
		LOOKS = {
			smasher = {
				BLINK = {
					START = { effect = 'base\\fx\\characters\\boss_adam_shasher\\ch_adam_smasher_sandevistan_teleport_start.effect',
						seconds = 15 },
					END = { effect = 'base\\fx\\characters\\boss_adam_shasher\\ch_adam_smasher_sandevistan_teleport_end.effect',
						seconds = 15 },
				},
				LAYERS = {
					-- `sandevistan_trails_smasher`: his afterimage trail on the
					-- wrists, heels, chest and head.
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'LeftHand' }, every = 1.8, self = 'fpp' },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'RightHand' }, every = 1.8, self = 'fpp' },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'LeftFoot', 'left_foot' }, every = 1.8 },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'RightFoot', 'right_foot' }, every = 1.8 },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'Chest' }, every = 1.8 },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail.effect',
						slots = { 'Head' }, every = 1.8, self = 'tps' },
					-- `fx_sandevistan_trails_left/_right`: the same trails with the
					-- chromatic aberration and the blurred afterimage left behind.
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail_left.effect',
						slots = { 'Hips', 'hips', 'Legs' }, every = 1.8 },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_trail_right.effect',
						slots = { 'Chest' }, every = 1.8 },
					-- `fx_sandevistan_left/_right` on the owner's own body, once as
					-- it engages (everybody else's body plays them by name, START).
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_left.effect',
						slots = { 'Hips', 'hips', 'Legs' }, once = true, who = 'self', body = true },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_right.effect',
						slots = { 'Hips', 'hips', 'Legs' }, once = true, who = 'self', body = true },
					-- `fx_sandevistan_loop` (off on the owner's own body where
					-- VIEW ships: `body = true`).
					{ effect = 'base\\fx\\characters\\boss_cyberninja\\sandevistan\\ch_oda_sandevistan_loop.effect',
						slots = { 'Hips', 'hips', 'Legs' }, body = true },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_ability_kerenzikov_center_loop.effect',
						slots = { 'Hips', 'hips', 'Legs' } },
					{ effect = 'base\\fx\\characters\\npc\\abilities\\ch_npc_sandevistan_center.effect',
						slots = { 'Hips', 'hips', 'Legs' }, once = true },
				},
				START = { 'fx_sandevistan_left', 'fx_sandevistan_right' },
				START_SECONDS = 3,
				-- `opx_sandy_ghost_on` is HIS GHOST TRAIL: the trigger VIEW's
				-- archive gives every player body, answered by VIEW's REDscript
				-- on the body that plays it (its twelve afterimages lit and placed
				-- every frame; undone when the look stops it).
				LOOP = { 'eye_glow_gold', 'opx_sandy_ghost_on' },
				TIME = { SELF_SCALE = 0.15, SELF_FALLBACK_SCALE = 0.5, NEARBY_SCALE = 0.15, RADIUS = 30,
					EASE_MS = 250 },
				SCREEN = { ALIAS = 'drugged', STRENGTH = 0.5, START = 'damage.emp' },
				SOUND = 'nme_ability_sandevistan_dash_long',
				-- The owner's own ears: the base game's Sandevistan enter and
				-- exit, on their own body.
				SELF_SOUND = { ENTER = 'time_dilation_sandevistan_enter', EXIT = 'time_dilation_sandevistan_exit' },
				SELF = true,
				PLATE = { SUFFIX = ' // SANDEVISTAN', COLOR = '#FF2D55' },
			},
		},
		-- The action a Sandevistan is engaged through on the player's machine
		-- (what `/opx.sandy.key` rebinds). The platform's own; change it only
		-- if the platform renames it.
		MAPPING = { RESOURCE = 'open77_reflex', ID = 'reflex_overdrive' },
		-- THE COOLDOWN, one for every Sandevistan the ripperdoc sells: after a
		-- boost ENDS the power is back this many ms later (the platform starts
		-- the cooldown when the boost is over). It replaces each grade's own
		-- `cooldownMs` and `chargeRegenMs` when the tray is built, and the
		-- platform's own boost never outlasts it. nil keeps every grade's own.
		-- A boost the character's level lengthened (LEVEL_SECONDS) outlasts the
		-- platform's: its cooldown still runs from ITS end -- the grant is held
		-- back from the moment the platform's overdrive completes until the
		-- boost is over and this cooldown has passed.
		COOLDOWN_MS = 20000,
		-- THE BOOST GROWS WITH THE CHARACTER'S LEVEL (the skill tree): at level
		-- 1 a Sandevistan's boost is its grade's own `durationMs` (6 to 9 s on
		-- this tray); at the level cap it is LEVEL_SECONDS -- the first number
		-- for a tier-1 grade, the second for tier 5, linear between (30, 32.5,
		-- 35, 37.5, 40 s) -- and linear in the level in between. The
		-- platform's overdrive (the speed) is capped at 15 s by its own client
		-- and its definitions are shared by grade, so they never change with a
		-- level: what grows is the boost the ripperdoc draws -- the look, the
		-- owner's slowed world, the players slowed around them, the screen.
		-- So it applies to a Sandevistan with a LOOK above; one the platform
		-- draws keeps the platform's boost. Each number at most 44 (the clients
		-- hold a boost for 45 s at most). nil keeps every grade's own at every
		-- level.
		LEVEL_SECONDS = { 30, 40 },
		-- THE REAL ITEM. A piece named here is also the base game's own item in
		-- the Operating System slot, fitted by VIEW's REDscript with the base
		-- game's equipment system (the inventory, the paperdoll and every stat
		-- read of the slot see it), taken off and out of the inventory when the
		-- ripperdoc takes the piece out. The number is the code VIEW's REDscript
		-- knows: 1 = Items.AdvancedSandevistanApogee. While it is fitted the
		-- base game's own Sandevistan activation is off: the key and the
		-- slowdown stay the ripperdoc's.
		WEAR = { apogee_sandevistan = 1 },
		-- THE BASE GAME'S OWN SANDEVISTAN SCREEN. `SandevistanEvents.OnEnter`
		-- sets the camera's time-dilation curve `Sandevistan` and slows the
		-- world under the reason `sandevistan` with V exempt; the curve is what
		-- the screen looks like, and only REDscript can set it. The resource
		-- named here (`extras/opx_sandy_view` in this repo) ships that REDscript
		-- to every player as a preload; while it is running on the server the
		-- owner's screen is the base game's own and SCREEN's stand-in is off.
		-- Its preload is executable content, so it only starts on a server with
		-- `requiredMods.unsecured = true`. false turns it off.
		VIEW = { RESOURCE = 'opx_sandy_view' },
		-- A PLAYER WHOSE OWN CLIENT LOST THE POWER while the server still holds
		-- it asks for it again. `open77_reflex` drops the overdrive the first
		-- frame its body is in ANY workspot -- the clinic chair, a sit or lean
		-- emote -- or on a new body after a respawn, and only a new projection
		-- brings it back. The server re-projects it at most once per AFTER_MS,
		-- and never inside the power's own boost and cooldown from its last use.
		RECOVER = { AFTER_MS = 15000 },
	},

	-- THE POWERS' DEFINITIONS. The platform holds at most DEFINITION_LIMIT
	-- dash, overdrive and ground-slam definitions per resource (8 on the
	-- builds this was measured on: the ninth answers `definition_limit`).
	-- Grades that configure a power identically share one definition; past
	-- the limit, the remaining grades are served by the nearest one that fits.
	GRANTS = { DEFINITION_LIMIT = 8 },

	-- THE PLATFORM RESOURCES the chrome is delivered through. A piece whose
	-- resource is not running is refused at the chair (nobody pays for chrome
	-- that cannot reach the body), and the boot says which are missing. Each
	-- must be in the server's resources.load: open77_cyberware (arms, legs,
	-- ground slam), open77_dash, open77_reflex (it needs open77_effects) and
	-- open77_hacking (it needs open77_effects and open77_notifications).
	-- Rename one here, or set it to false to stop checking it.
	SERVICES = {},

	-- WHAT THE CHROME IS WORTH ON THE BODY (`server/effects.lua`). The caps
	-- bound the sum of every fitted piece; armor is PLATING that recharges
	-- toward its rating once the body has gone `ARMOR_DELAY_MS` unhurt, at
	-- `ARMOR_RECHARGE` of the rating per second.
	EFFECTS = {
		ARMOR_CAP = 80,
		HEALTH_MAX_CAP = 150,
		HEALTH_REGEN_CAP = 8,
		STAMINA_MAX_CAP = 80,
		STAMINA_REGEN_CAP = 20,
		CAPACITY_CAP = 100,
		ARMOR_DELAY_MS = 6000,
		ARMOR_RECHARGE = 0.25,
		RECONCILE_MS = 1000,
	},

	-- "NOT READY", DIAGNOSED. How often one patient's diagnosis is written to
	-- the journal, and how long a bound character may project nothing before
	-- it is bound again (the platform parks a timed-out restore as failed).
	DIAGNOSTICS = { LOG_EVERY_MS = 15000, REBIND_AFTER_MS = 20000 },

	-- THE BASE-GAME MENU RECORDER (`client/recorder.lua`). With AUTO on, a
	-- client records every base-game menu whose scenario name matches one of
	-- SCENARIOS on its own -- the ripperdoc's vendor screen among them -- and
	-- sends the snapshots to the server journal as `[ripperdoc:rec]` lines.
	-- `/opx.clinic.record on` records EVERY base-game menu on one client.
	-- Switch AUTO off once you have what you need: every vendor a player
	-- opens writes a few journal lines while it is on.
	RECORDER = {
		AUTO = true,
		SCENARIOS = { 'vendor', 'ripper', 'cyber' },
		NEARBY_RADIUS = 12.0,
		MAX_NEARBY = 12,
	},

	CHAIRS = {
		-- A first chair, at the ripperdoc chair pose the wiki's own example
		-- names. Move it with `/opx.clinic.add` output like everything else here.
		{ id = 'clinic_watson', NAME = 'Watson Clinic',
			X = -1441.2, Y = 129.6, Z = 18.05, YAW = 90.0 },
	},

	-- HOW LONG THE CHROME LASTS: REAL DAYS. Every fitted piece carries one
	-- CONDITION (100 = fresh, 0 = broken) and a LIFE:
	--   time    `LIFESPAN_DAYS` (6) real calendar days from its fitting or its
	--           last repair to broken, whether its owner is online or not --
	--           worn every `TICK_SECONDS` while they play, and the time they
	--           were away caught up when they come back
	--   use     the host's own action events, on the piece that did the work
	--           (`WEAR_BY` below): `USE_MINUTES` of its life per use, times the
	--           piece's own `WEAR` weight (`WEAR` here when it names none)
	--   damage  `DAMAGE_MINUTES` of life per 100 damage the body takes, on
	--           every piece that carries armor plating
	--   death   `DEATH_MINUTES` of life off everything
	-- Use, damage and deaths together never take more than `WEAR_DAYS` (1) of
	-- one life: a piece worked as hard as a piece can be still lasts 5 days,
	-- and one that is barely used lasts 6 -- never sooner, never forever.
	--
	-- THE EXTRA WEAR, PRICED. 30 s of life a use, 4 min per 100 damage, an hour
	-- a death, against 24 h of allowance: a hard 4-hour evening -- ~600 punches
	-- on the arms (5 h), ~400 double jumps on the legs (3.3 h), ~30 Sandevistan
	-- boosts at weight 2 (0.5 h), ~5000 damage soaked by the plating (3.3 h),
	-- five deaths (5 h on everything) -- spends roughly 5 to 10 hours of a
	-- piece's allowance: a fair part of the day, not all of it. Two or three
	-- such evenings in one life spend it whole, and then only the calendar
	-- decides.
	--
	-- THE LEVEL (the skill tree) STRETCHES THE WHOLE LIFE: `LEVEL_LIFESPAN`
	-- (1.5) times as long at the level cap -- 6 days become 9, and the
	-- allowance 1 day becomes 1.5 -- linear from level 1. An iconic piece's
	-- whole life is `ICONIC_LIFESPAN` times as long (1: every piece lasts the
	-- same 5 to 6 days, as the owner asked).
	--
	-- Below `WORN_AT` a piece reads WORN; below `FAILING_AT` it is FAILING and
	-- gives only `FAILING_EFFECT` of what it is worth; at 0 it BREAKS and gives
	-- nothing (a broken implant is pulled) until a ripperdoc repairs it -- a new
	-- life from that day. A repair costs `REPAIR_FRACTION` of the grade's price
	-- for the share that is missing, and never less than `REPAIR_MIN`. The
	-- tray shows how long each piece has left. `/opx.clinic.chrome` sets the
	-- condition of everything fitted on an admin. `LIFESPAN_DAYS = 0` (or
	-- `enabled = false`) switches wear off entirely.
	--
	-- WHEN THIS FIRST RUNS, every piece already fitted goes back to fresh --
	-- once (a piece with no life yet predates real days), broken ones working
	-- again: a broken implant is fitted back into the body for free.
	--
	-- `WEAR_BY` maps each host wear event to what it wears: a piece id (and so
	-- its family -- `arms` wears whichever Gorilla Arms are fitted), or
	-- `slot:<platform slot>`, `grant:<dash|reflex|ability>`, `system:<system>`.
	DURABILITY = {
		enabled = true,
		PRICE_PER_POINT = 2,
		LIFESPAN_DAYS = 6,
		WEAR_DAYS = 1,
		USE_MINUTES = 0.5,
		DAMAGE_MINUTES = 4,
		DEATH_MINUTES = 60,
		WEAR = 1,
		LEVEL_LIFESPAN = 1.5,
		ICONIC_LIFESPAN = 1,
		TICK_SECONDS = 60,
		WORN_AT = 60,
		FAILING_AT = 25,
		FAILING_EFFECT = 0.5,
		REPAIR_FRACTION = 0.35,
		REPAIR_MIN = 10,
		WEAR_BY = {
			hit = 'slot:arms',          -- onCyberwareMeleeHit, on the attacker
			jump = 'slot:legs',         -- onCyberwareJump
			dash = 'grant:dash',        -- onDashChanged, on an accepted dash
			overdrive = 'grant:reflex', -- onReflexChanged, when it goes active
			slam = 'grant:ability',     -- onAbilityActivation
			upload = 'slot:operating_system', -- onHackingTransition, on uploads
		},
	},

	CATALOG = {
		{
			-- Gorilla Arms: the platform's own implant (`arms`/`gorilla_arms`).
			id = 'arms',
			DEFINITION = 'opx.ripperdoc.arms',
			NAME = 'ripperdoc.item.arms',
			SYSTEM = 'arms', KIND = 'implant', CAPACITY = 8,
			SLOT = 'arms',
			PROFILE = 'gorilla_arms',
			REMOVE = 50,
			GRADES = {
				{ id = 'street', NAME = 'ripperdoc.grade.arms.street', PRICE = 100,
					VALUE = { normalDamage = 15, chargedDamage = 35, knockbackMeters = 2,
						cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
				{ id = 'elite', NAME = 'ripperdoc.grade.arms.elite', PRICE = 250,
					VALUE = { normalDamage = 25, chargedDamage = 60, knockbackMeters = 4,
						cooldownMs = 600, chargeMs = 500, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
				{ id = 'maxtac', NAME = 'ripperdoc.grade.arms.maxtac', PRICE = 450,
					VALUE = { normalDamage = 35, chargedDamage = 85, knockbackMeters = 5,
						cooldownMs = 500, chargeMs = 450, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
			},
		},
		{
			-- Reinforced Tendons: the platform's double jump (`legs`/`double_jump`).
			id = 'legs',
			DEFINITION = 'opx.ripperdoc.legs',
			NAME = 'ripperdoc.item.legs',
			SYSTEM = 'legs', KIND = 'implant', CAPACITY = 8,
			SLOT = 'legs',
			PROFILE = 'double_jump',
			REMOVE = 25,
			GRADES = {
				-- The .87 wiki's own example grades, verbatim.
				{ id = 'training', NAME = 'ripperdoc.grade.legs.training', PRICE = 100,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 15,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
				{ id = 'athlete', NAME = 'ripperdoc.grade.legs.athlete', PRICE = 250,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 500, chargeMs = 650, jumpStaminaCost = 8,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
				{ id = 'apex', NAME = 'ripperdoc.grade.legs.apex', PRICE = 400,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 350, chargeMs = 650, jumpStaminaCost = 4,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
			},
		},
		{
			-- THE MOVEMENT KIT. Where a piece is a POWER it is not a durable
			-- implant but a platform grant: the definition lives in the movement
			-- modules (`Open77.dash`, `Open77.reflex`, `Open77.abilities`) and the
			-- clinic holds the appointment that unlocks it. `POWER.KEY` is the
			-- free key the piece is re-armed under, `POWER.GRANT` the class
			-- (`dash`/`reflex`/`ability`) the grant goes through, and every grade's
			-- `VALUE` is that module's own config verbatim (`inputKey` comes from
			-- `POWER.KEY`; bounds per `wiki/dash.md`, `wiki/reflex-overdrive.md`,
			-- `wiki/ground-slam.md` -- a value outside them is refused, not trimmed).
			id = 'dash',
			DEFINITION = 'opx.ripperdoc.dash',
			NAME = 'ripperdoc.item.dash',
			SYSTEM = 'nervous_system', KIND = 'grant', CAPACITY = 12,
			SLOT = 'nervous_system',
			PROFILE = 'dash_legs',
			REMOVE = 25,
			WEAR = 1,
			POWER = { GRANT = 'dash', KEY = 'z' },
			GRADES = {
				{ id = 'street', NAME = 'ripperdoc.grade.dash.street', PRICE = 150,
					VALUE = { requireDoubleJump = false, allowGround = true, allowAir = false,
						movementProfile = 'native', presentation = 'native',
						staminaCost = 15, cooldownMs = 900, maxCharges = 1,
						chargeRegenMs = 2500, landingRearmMs = 150,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
				{ id = 'air', NAME = 'ripperdoc.grade.dash.air', PRICE = 300,
					VALUE = { requireDoubleJump = true, allowGround = false, allowAir = true,
						movementProfile = 'native', presentation = 'native',
						staminaCost = 10, cooldownMs = 700, maxCharges = 1,
						chargeRegenMs = 2500, landingRearmMs = 150,
						maxAirborneMs = 10000, maxFallSpeed = 30 } },
			},
		},
		{
			-- The Dynalar Sandevistan: in the base game an OPERATING SYSTEM
			-- piece, so it shares that one slot with the decks and Berserks.
			id = 'reflex',
			DEFINITION = 'opx.ripperdoc.reflex',
			NAME = 'ripperdoc.item.reflex',
			SYSTEM = 'operating_system', KIND = 'grant', CAPACITY = 18,
			SLOT = 'frontal_cortex',
			PROFILE = 'reflex_overdrive',
			REMOVE = 25,
			WEAR = 2,
			POWER = { GRANT = 'reflex', KEY = 'x' },
			GRADES = {
				{ id = 'sandevistan', NAME = 'ripperdoc.grade.reflex.sandevistan', PRICE = 350,
					VALUE = { tier = 'reflex', durationMs = 6000, cooldownMs = 30000,
						maxCharges = 1, chargeRegenMs = 30000, staminaCost = 25,
						heatCost = 0, presentation = 'native' } },
				{ id = 'apex', NAME = 'ripperdoc.grade.reflex.apex', PRICE = 550,
					VALUE = { tier = 'reflex_heavy', durationMs = 8000, cooldownMs = 24000,
						maxCharges = 1, chargeRegenMs = 30000, staminaCost = 25,
						heatCost = 0, presentation = 'native' } },
			},
		},
		{
			-- The Moore Tech Berserk and its ground slam: an operating system
			-- piece too.
			id = 'slam',
			DEFINITION = 'opx.ripperdoc.slam',
			NAME = 'ripperdoc.item.slam',
			SYSTEM = 'operating_system', KIND = 'grant', CAPACITY = 12,
			SLOT = 'skeleton',
			PROFILE = 'ground_slam',
			REMOVE = 25,
			WEAR = 3,
			POWER = { GRANT = 'ability', KEY = 'l' },
			GRADES = {
				{ id = 'training', NAME = 'ripperdoc.grade.slam.training', PRICE = 150,
					VALUE = { damage = 0, knockbackMeters = 2.5, radius = 2.5,
						innerRadius = 1, staminaCost = 20, cooldownMs = 12000,
						cosmetic = false, nonlethal = true, reaction = 'knockdown' } },
				{ id = 'combat', NAME = 'ripperdoc.grade.slam.combat', PRICE = 350,
					VALUE = { damage = 60, knockbackMeters = 3, radius = 3,
						innerRadius = 1, staminaCost = 30, cooldownMs = 10000,
						cosmetic = false, nonlethal = false, reaction = 'knockdown' } },
			},
		},
		{
			-- The Arasaka deck: a durable implant like the arms (the platform's
			-- own `operating_system`/`cyberdeck` pair) and, beside it, ONE hack
			-- definition with the implant's own id and every grade
			-- (`wiki/hacking.md`). `HACK` is each grade's row verbatim --
			-- `kind`, range, upload, cooldown, damage; the fields the service
			-- also requires (stamina, status, recovery) default in
			-- `server/chrome.lua`. `VALUE` stays the audited cyberware schema.
			id = 'deck',
			DEFINITION = 'opx.ripperdoc.deck',
			NAME = 'ripperdoc.item.deck',
			SYSTEM = 'operating_system', KIND = 'implant', CAPACITY = 14,
			SLOT = 'operating_system',
			PROFILE = 'cyberdeck',
			REMOVE = 25,
			WEAR = 2,
			POWER = { GRANT = 'hacking' },
			GRADES = {
				{ id = 'training', NAME = 'ripperdoc.grade.deck.training', PRICE = 150,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 },
					HACK = { kind = 'short_circuit', damage = 15, uploadMs = 800,
						range = 8, cooldownMs = 4000 } },
				{ id = 'street', NAME = 'ripperdoc.grade.deck.street', PRICE = 300,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 },
					HACK = { kind = 'overheat', damage = 25, uploadMs = 700,
						range = 10, cooldownMs = 4000 } },
				{ id = 'military', NAME = 'ripperdoc.grade.deck.military', PRICE = 500,
					VALUE = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
						cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 0,
						maxAirborneMs = 10000, maxFallSpeed = 30 },
					HACK = { kind = 'malfunction', damage = 40, uploadMs = 500,
						range = 12, cooldownMs = 4000 } },
			},
		},
	},
}
