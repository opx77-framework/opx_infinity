--- The bag, the containers in the world, the keys and who may run the commands.
-- @author dop42
--
-- Shared: both halves read this. The client needs the keys, the tabs and the
-- reach it draws prompts at; the server needs everything, and re-derives every
-- limit the client thinks it knows.
--
-- Nothing here is trusted as written. `modules/inventory/shared/common.lua`
-- reads it once at load and resolves every value a calculation or a lookup is
-- made on, so a mistyped entry is a warning in the boot log and a fallback,
-- never an error raised in the middle of a request.

OPX.Config.MODULES.inventory = {
	enabled = true,

	-- A new character's bag. An existing bag keeps the size it was created with:
	-- the size only ever reaches the database through the row that creates it.
	BAG = { SLOTS = 40, MAX_WEIGHT = 30000 },

	-- Grams per unit for a stored item the catalogue no longer carries. A stack
	-- of something that has been removed from data/ still weighs something, or a
	-- deleted item would be a free way to carry anything.
	DEFAULT_ITEM_WEIGHT = 100,

	-- Most units one slot holds of a stackable item, and the ceiling on one
	-- stack's encoded metadata.
	MAX_STACK = 1000000,
	MAX_METADATA_BYTES = 1024,

	-- Metres, measured server-side and only server-side.
	REACH = {
		-- To a stash, a pile, or another player.
		DISTANCE = 3.0,
		-- From a vehicle's centre to its trunk, which is not its centre.
		VEHICLE = 4.5,
	},

	-- Bag slots a key uses straight, without opening the screen.
	HOTBAR = { ENABLED = true, SLOTS = 5 },

	-- Defaults a player rebinds in the pause menu. `false` registers no mapping
	-- at all, which is how an operator turns a key off.
	KEYS = {
		OPEN = 'I',
		HOTBAR = { '4', '5', '6', '7', '8' },
	},

	-- Least time between two uses by one player, and how long a use handler has
	-- to answer before the use is refused.
	USE_COOLDOWN_MS = 750,
	USE_HANDLER_MS = 5000,

	-- Screen requests one player may send per window. A refused request is still
	-- answered, so the page settles what it is waiting on instead of hanging
	-- until its own timeout.
	RATE_LIMIT = { WINDOW_MS = 1000, REQUESTS = 20 },

	-- Deferred writes. A container is written DELAY_MS after its last change,
	-- BATCH containers to a transaction, looked for every SWEEP_MS.
	SAVE = { DELAY_MS = 2000, SWEEP_MS = 1000, BATCH = 16 },

	-- Piles on the ground. They are memory-only containers: nothing about a pile
	-- survives a restart, which is why LIFETIME_MINUTES is short.
	DROPS = {
		ENABLED = true,
		SLOTS = 25,
		LIFETIME_MINUTES = 30,
		MAX = 200,
		MAX_PER_CHARACTER = 10,
		COOLDOWN_MS = 1000,
		-- A drop this close to an existing pile joins it instead of making one.
		DISTANCE = 1.5,
		-- A curated Open77.props alias, drawn for a pile whose item has no MODEL.
		MODEL = 'crate.small',
		-- Metres within which a pile registers a target sphere.
		PROMPT_RADIUS = 20.0,
	},

	-- Vehicle storage. SLOTS at 0 gives that vehicle no storage at all.
	TRUNK = { SLOTS = 30, MAX_WEIGHT = 80000 },
	GLOVEBOX = { SLOTS = 10, MAX_WEIGHT = 10000 },

	-- A record carrying one of these fragments is a two-wheeler: no glovebox,
	-- and a trunk divided by TRUNK_DIVISOR.
	BIKES = { PATTERNS = { 'sportbike', '_bike_' }, TRUNK_DIVISOR = 3 },

	-- Fixed stashes. NAME is the storage key and must never be reused for
	-- somewhere else: it is what the row is keyed on.
	STASHES = {},

	-- Weapons drawn from the bag. SLOT is the game weapon slot an inventory
	-- weapon occupies; REMOVE_UNBACKED takes off any weapon no bag item backs.
	WEAPONS = {
		ENABLED = true,
		SLOT = 1,
		REMOVE_UNBACKED = true,
		SCAN_MS = 5000,
		AMMO_SYNC_MS = 2000,
	},

	-- Players the screen offers to hand something to, and how often that list is
	-- refreshed while the screen is open.
	NEARBY = { MAX = 4, SCAN_MS = 1000 },

	-- Category tabs over the grid, in order. REST takes every category no other
	-- tab names, so nothing can be carried and be unreachable.
	TABS = {
		{ KEY = 'all' },
		{ KEY = 'weapons', CATEGORIES = { 'weapon', 'ammo' } },
		{ KEY = 'food', CATEGORIES = { 'food', 'drink' } },
		{ KEY = 'medical', CATEGORIES = { 'medical' } },
		{ KEY = 'materials', CATEGORIES = { 'material', 'tool' } },
		{ KEY = 'misc', REST = true },
	},

	-- Largest count one staff command accepts.
	MAX_COMMAND_COUNT = 10000,
}
