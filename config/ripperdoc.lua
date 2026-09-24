--- The ripperdoc clinic: the chairs, the tray, and what each piece of chrome costs.
-- @author XEROX710
--
-- THE TRAY IS THE PLATFORM'S OWN. Every entry registers a definition with
-- `Open77.cyberware.define`, and every definition selects one of the two
-- audited slot/profile pairs the runtime implements natively -- `arms` with
-- `gorilla_arms`, and `legs` with `double_jump`. Nothing here fakes an implant:
-- the staged ticket, the durable record and the read-back belong to the
-- platform, and this file is the shop standing in front of them.
--
-- THE GRADE FIELDS ARE THE PLATFORM'S SHARED SCHEMA, and the values are the
-- .87 wiki's own example grades: the training legs are literally the wiki's
-- (`jumpStaminaCost = 15`, `cooldownMs = 800`) and the athlete its stated
-- counterpart (8 stamina, 500 ms). The prices beside them are POLICY -- the
-- wiki's example clinic charged 100 and 250 with a 25-credit legs pull, and
-- those are the numbers shipped here, in eddies. Prices belong to the economy
-- and are edited here without touching the module.
--
-- CHAIRS ARE PLACES, NOT PROPS. A row is one ripperdoc chair in the world: the
-- patient is seated on it with the platform's own portable `chair` workspot
-- (`Open77.animations.playAt` puts the pose and its invisible device under
-- them), so a chair needs no mesh of its own. PLACE ONE IN GAME with
-- `/opx.clinic.add` -- stand at the chair, look the way the patient should
-- face, run it. It saves the chair and prints the line to check in here.
-- `opx.here` prints a row exactly like these for wherever you are standing.
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

	-- What the placement commands answer to. `add` captures a chair where the
	-- operator stands, `remove` takes a captured one away, `list` prints them
	-- all -- the same three every other station module ships.
	COMMANDS = {
		add = 'opx.clinic.add',
		remove = 'opx.clinic.remove',
		list = 'opx.clinic.list',
	},

	CHAIRS = {
		-- A first chair, at the ripperdoc chair pose the wiki's own example
		-- names. Move it with `/opx.clinic.add` output like everything else here.
		{ id = 'clinic_watson', NAME = 'ripperdoc.chair.watson',
			X = -1441.2, Y = 129.6, Z = 18.05, YAW = 90.0 },
	},

	CATALOG = {
		{
			id = 'arms',
			DEFINITION = 'opx.ripperdoc.arms',
			NAME = 'ripperdoc.item.arms',
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
			},
		},
		{
			id = 'legs',
			DEFINITION = 'opx.ripperdoc.legs',
			NAME = 'ripperdoc.item.legs',
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
			},
		},
	},
}
