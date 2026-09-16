--- The item catalogue: one definition per stored item name.
-- @author dop42
--
-- Data, and nothing else: `shared/catalog.lua` normalises every row once at load
-- and a malformed row becomes a boot warning rather than an error in the middle
-- of a request. MODEL is optional and draws a pile made for that item -- an
-- `Open77.props` alias, or a raw `base\...\name.mesh` path.

local M = OPX.Modules.Get('inventory')

M.Data = M.Data or {}

M.Data.ITEMS = {
	water = {
		WEIGHT = 500, CATEGORY = 'drink', MODEL = 'food.drink_packaged',
		USE = { STATUS = { thirst = 35 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	nicola = {
		WEIGHT = 330, CATEGORY = 'drink', MODEL = 'food.soda_can',
		USE = { STATUS = { thirst = 25 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	coffee = {
		WEIGHT = 300, CATEGORY = 'drink', MODEL = 'food.drink_packaged',
		USE = { STATUS = { thirst = 15 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	-- Open77 ships no eating profile: food plays the drink profile's first hand-to-mouth clip.
	burrito = {
		WEIGHT = 350, CATEGORY = 'food', MODEL = 'food.street_food',
		USE = { STATUS = { hunger = 35 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},
	chips = {
		WEIGHT = 150, CATEGORY = 'food', MODEL = 'food.snack',
		USE = { STATUS = { hunger = 12 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},
	kibble = {
		WEIGHT = 250, CATEGORY = 'food', MODEL = 'food.snack',
		USE = { STATUS = { hunger = 20 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},

	bandage = { WEIGHT = 60, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },
	bounce_back = { WEIGHT = 120, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },
	maxdoc = { WEIGHT = 200, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },

	scrap_metal = { WEIGHT = 400, CATEGORY = 'material' },
	electronics = { WEIGHT = 150, CATEGORY = 'material' },
	lockpick = { WEIGHT = 50, CATEGORY = 'tool', MODEL = 'container.toolbox' },

	phone = { WEIGHT = 180, STACK = false },
	id_card = { WEIGHT = 10, STACK = false },
	shard = { WEIGHT = 20 },
}
