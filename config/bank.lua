--- Bank branches: stand on the marker, press the key, and move money between
--- the account a paycheck lands in and the eddies in your pocket.
-- @author XEROX710
--
-- THE OWNER, 2026-09-29: "add bank paycheck and ways to withdraw from bank
-- with set banking marker and menu". A paycheck is paid into `BANK`
-- (`config/character.lua`, `PAYCHECK_TYPE`), and until this module there was
-- no way to turn a single eddie of it into cash: the only door out of the
-- account was a staff command. A BRANCH IS A PLACE, exactly as a clothing store
-- and a garage spot are -- the marker is drawn where an operator put it with
-- `/opx.bank.add`, the row goes up when a player stands on it, and the key
-- opens the branch's menu: both balances, quick amounts, "all of it", and any
-- other amount typed into a form.
--
-- THE SERVER MOVES THE MONEY AND DECIDES EVERYTHING ABOUT IT. The menu is
-- drawn from the balances the server sent; the press names a direction and an
-- amount, and the server measures the distance to the branch again, reads the
-- balance again and moves the money in two audited steps (out of one account,
-- into the other), putting it back if the second step is refused. A client
-- cannot name a branch, a balance or a player.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500.

OPX.Config.MODULES.bank = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a branch may be used.
	-- The server measures it again on every transaction.
	USE_RADIUS = 2.5,

	-- The branch's marker: the standing cylinder in the "walk up and press
	-- something" style, like a clothing store's, and smaller -- a counter or an
	-- ATM, not a shop floor.
	MARKER = { shape = 'cylinder', style = 'interaction', RADIUS = 1.2 },

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 120.0,

	-- Metres the marker is lifted off the declared Z, 0..2 (a marker at exact
	-- floor height is co-planar with the floor and draws nothing).
	GROUND_OFFSET = 0.06,

	-- The marker/scan loop, and how often the client re-asks for the list so a
	-- change of routing bucket is picked up without a rejoin.
	SCAN_MS = 500,
	POLL_MS = 15000,

	-- The key that opens the branch a player is standing on. E, like every
	-- other place you stand on and press something; a separate MAPPING, so a
	-- player who rebinds one does not move the others.
	KEY = { ID = 'opx.bank.use', NAME = 'bank.key.use', DEFAULT = 'E' },

	-- The two sides of every transaction: the account a paycheck is paid into
	-- and the cash in hand. Both must be money types of this server
	-- (`config/shared.lua`, `MONEY.TYPES`).
	ACCOUNT = 'BANK',
	CASH = 'EDDIES',

	-- The quick amounts the menu offers for each direction, in eddies. A row
	-- the balance cannot cover is drawn dimmed rather than left out, so the
	-- menu keeps its shape.
	AMOUNTS = { 100, 500, 1000, 5000, 10000 },

	-- The most one transaction may move, and the longest amount the "other
	-- amount" form accepts (digits).
	MAX_TRANSFER = 10000000,

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	COMMANDS = {
		add = 'opx.bank.add',
		remove = 'opx.bank.remove',
		list = 'opx.bank.list',
	},

	-- LABEL is the operator's own words and is never translated. Empty until a
	-- branch is captured in game: `/opx.bank.add [key] [label]` where you stand
	-- saves one to the database and prints the line to check in here, which is
	-- how a branch survives a database reset:
	--   bank_example = { LABEL = "ARASAKA BANK", X = -1400.0, Y = 120.0, Z = 12.0,
	--     BUCKET = 0 },
	SPOTS = {},
}
