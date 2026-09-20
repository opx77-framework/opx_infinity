--- Dealerships: stand on a marker, pick a model, pay for it, choose the garage
--- it is delivered to.
-- @author XEROX710
--
-- Three things have to agree before a player owns anything, and they are all
-- decided on the server: the dealer exists and the player is standing on it,
-- the model is one THIS dealer sells, and the money is really there. The client
-- draws the list and sends one request; everything it believes is a hint.
--
-- THE VEHICLE IS NOT CREATED HERE. This module owns no car and no plate: it
-- charges the character, then registers the row through the `vehicles` contract
-- -- which counts the ceiling, draws the plate and writes the row -- and hands
-- the buyer the key of the garage they chose, so what comes out of that marker
-- afterwards is what they just bought. `vehicles` remains the only owner of
-- what a character owns, and of the rules about how much they may own.
--
-- `garages` is optional and only answers one question: which garages may be
-- named as a destination. Without it every purchase is filed under the vehicles
-- module's own default garage, which is a working dealership with one fewer
-- choice, not a broken one.
--
-- `character` is required on both halves: on the server it is the money and the
-- ownership oracle, and on the client it is where the price is read back and
-- where a purchase is announced.
--
-- `prompts` and `menu` are optional too. Without `menu` there is no list to
-- click and `/opx.dealership.buy <key>` still sells a car; without `prompts`
-- the markers still draw and only the strip row is missing.

local M = OPX.Modules.Declare{
	id = 'dealership',
	side = 'both',
	-- Not fatal: a server with no dealership is a server where nobody can buy a
	-- car, and that is a choice an operator may make with `enabled = false`.
	fatal = false,
	requires = { 'character' },
	optional = { 'vehicles', 'garages', 'prompts', 'menu' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection.
	ASK = OPX.Event(NET, 'dealership', 'ask'),
	BUY = OPX.Event(NET, 'dealership', 'buy'),
	CAPTURED = OPX.Event(NET, 'dealership', 'captured'),

	-- Server to client: the dealers this player may see, what is for sale and at
	-- what price, one verdict, and the ask to capture where a player is standing.
	SYNC = OPX.Event(NET, 'dealership', 'sync'),
	STOCK = OPX.Event(NET, 'dealership', 'stock'),
	ANSWER = OPX.Event(NET, 'dealership', 'answer'),
	CAPTURE = OPX.Event(NET, 'dealership', 'capture'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'dealership', 'decision'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: without it a client waiting on one of several requests
-- cannot tell which `error.tooFast` is its own.
M.Operation = { BUY = 'dealershipBuy', CAPTURE = 'dealershipCapture' }

--- The host raises this when a player rebinds or resets a mapping.
M.KEYBINDS_CHANGED = 'onKeybindsChanged'

--- The two kinds a dealer may declare.
-- THE SAME TWO THE GARAGES USE, and deliberately not a third vocabulary: a
-- dealer is a category of place, and the category decides which of the two
-- things it sells. A `garage` dealer sells ground vehicles, an `avpad` dealer
-- sells AVs, and a record that disagrees with the dealer's kind is refused.
M.KIND = { GARAGE = 'garage', AVPAD = 'avpad' }
