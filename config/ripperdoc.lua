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

	-- HOW LONG THE CHROME LASTS. Every fitted piece carries one CONDITION
	-- (100 = fresh, 0 = broken) and four things take it down:
	--   use     the host's own action events, on the piece that did the work
	--           (`WEAR_BY` below, `WEAR` points a use unless a piece names its own)
	--   time    `LIFESPAN_HOURS` of play from fresh to broken by wear alone,
	--           checked every `TICK_SECONDS`; an iconic piece lasts
	--           `ICONIC_LIFESPAN` times longer
	--   damage  `DAMAGE_WEAR` points per 100 damage the body takes, on every
	--           piece that carries armor plating
	--   death   `DEATH_WEAR` points off everything
	-- Below `WORN_AT` a piece reads WORN; below `FAILING_AT` it is FAILING and
	-- gives only `FAILING_EFFECT` of what it is worth; at 0 it BREAKS and gives
	-- nothing (a broken implant is pulled) until a ripperdoc repairs it. A
	-- repair costs `REPAIR_FRACTION` of the grade's price for the share that
	-- is missing, and never less than `REPAIR_MIN`.
	--
	-- `WEAR_BY` maps each host wear event to what it wears: a piece id (and so
	-- its family -- `arms` wears whichever Gorilla Arms are fitted), or
	-- `slot:<platform slot>`, `grant:<dash|reflex|ability>`, `system:<system>`.
	DURABILITY = {
		enabled = true,
		PRICE_PER_POINT = 2,
		WEAR = 1,
		LIFESPAN_HOURS = 24,
		ICONIC_LIFESPAN = 1.5,
		TICK_SECONDS = 60,
		DAMAGE_WEAR = 1.5,
		DEATH_WEAR = 4,
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
