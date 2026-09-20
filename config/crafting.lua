--- Crafting: the bounds every bench is held to, whoever registered it.
-- @author dop42
--
-- THERE ARE NO RECIPES HERE, AND THAT IS THE POINT. A recipe belongs to the
-- module that owns the place it is made in -- the gunsmith's armouries are in
-- `config/gunsmith.lua`, a ripperdoc's clinics would be in its own -- because a
-- recipe is a fact about a trade and this module knows nothing about trades. It
-- knows how to take materials, hold an order for a while and hand the output
-- back, and everything below is a ceiling on how far a consumer may push that.
--
-- Shared: both halves read this. The client needs the key and the refusal
-- windows it draws with; the server needs all of it, and re-derives every limit
-- the client thinks it knows.

OPX.Config.MODULES.crafting = {
	enabled = true,

	-- Metres a bench with a declared position serves from, measured on the
	-- SERVER against the player's own position and never taken from a payload.
	-- A bench may name its own; this is the ceiling and the fallback.
	REACH = 3.0,
	MAX_REACH = 25.0,

	-- Orders one character may have cooking at one bench at a time. A bench may
	-- ask for fewer; it may not ask for more.
	--
	-- THE QUEUE IS SEQUENTIAL, which is what the word means and what a workshop
	-- is: the second order starts when the first one finishes, so ordering three
	-- at once buys the time of three and not the time of one. Without that a
	-- queue is only a way of multiplying throughput by the queue length.
	QUEUE = 3,
	MAX_QUEUE = 10,

	-- SECONDS AND NOT MILLISECONDS, unlike every other duration in this runtime,
	-- because the deadline is stored in a DATETIME column whose resolution is one
	-- second. A figure in milliseconds would promise a precision the storage
	-- cannot keep, and the difference would show up as an order that reads as
	-- ready a fraction before the database agrees.
	MIN_SECONDS = 5,
	MAX_SECONDS = 86400,

	-- Units one order may yield, and materials one recipe may name. Both are
	-- bounds on what a consumer may write rather than on what a player may do:
	-- a recipe past either is a boot warning and is left out of the bench.
	MAX_YIELD = 1000,
	MAX_INPUTS = 8,

	-- Recipes one bench may carry. The screen is a menu and a menu is a list
	-- somebody scrolls; past this the list is the problem rather than the recipes.
	MAX_RECIPES = 40,

	-- Requests one player may send per window, counted per player and not per
	-- bench. A refused request is still ANSWERED, so the screen settles on a
	-- refusal instead of waiting for its own timeout.
	RATE_LIMIT = { WINDOW_MS = 10000, REQUESTS = 20 },

	-- The one place `modules/progress/` belongs in a craft: the second or so of
	-- HANDING THE MATERIALS OVER. The bar takes `Movement` and `Attack` away
	-- while it is up, which is right for a handover and would be absurd for the
	-- twenty minutes afterwards -- so it covers the request and nothing else, and
	-- the order goes on cooking long after it has gone. 0 turns it off; a runtime
	-- with no `progress` module never had one.
	HANDOVER_MS = 1200,

	-- How long the screen holds a view before it asks for a fresh one. The
	-- remaining time on a cooking order is drawn from a number the server sent,
	-- so this is how often that number is corrected and not how often the screen
	-- redraws.
	REFRESH_MS = 5000,
}
