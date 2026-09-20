--- Garages and AV pads: a glowing marker you stand on to bring your own vehicle out.
-- @author XEROX710
--
-- The client draws one marker per configured spot in the player's own routing
-- bucket, posts a prompt row while the player stands on one, and sends a
-- request when the key is pressed. The server re-derives everything it can
-- prove -- the spot exists, the player is within USE_RADIUS of the DECLARED
-- position, the bucket agrees, the character is loaded and the vehicle is
-- theirs -- and only then asks the `vehicles` contract to create it, AT the
-- spot and facing the spot's HEADING, never beside the player.
--
-- THE ONE KEY DOES TWO THINGS, AND ONLY THE SERVER DECIDES WHICH. Standing on a
-- marker, the key brings one of the character's own vehicles out AT the spot.
-- Sitting in one of them, the same key puts it AWAY, filed under the spot the
-- player is standing on so that is where it comes out next time. The seated
-- question is answered by the host's own seat assignment and the plate the
-- `vehicles` contract holds, never by the client; the client only chooses which
-- of the two texts the row names.
--
-- A VEHICLE OF THEIRS THAT IS ALREADY OUT IS MOVED, NOT IGNORED. It used to be
-- answered with the id it already had -- `Ok`, "brought out", and an empty spot
-- in front of the player, because the car was on the other side of the map. The
-- `vehicles` contract recalls it to the named place instead, and refuses when
-- somebody is sitting in it.
--
-- What comes out is what the character already owns: this module spawns no new
-- vehicle and creates no row. A spot with nothing eligible answers a refusal
-- that says so, rather than handing out a car the player does not have.
--
-- The marker is the engine's own (`world.markers`), so there is no geometry of
-- our own to keep in step with a screen: the four styles and two shapes are the
-- ones the host accepts, and `config/garages.lua` picks one per kind.
--
-- `character` is required on both halves: on the server it is the only proof
-- of ownership, and on the client it is where the player's own position and
-- facing are read from.
--
-- `vehicles` is OPTIONAL and not required, because it is a server-only module:
-- requiring it took the whole client half down with it -- no marker, no row, no
-- key -- the moment the server half was the only half that existed. The server
-- asks for the contract in `Start` and refuses every request without it, which
-- is the same answer with a line that says why.
--
-- The strip is optional too: without `prompts` the markers still draw and the
-- command still works, and only the key row is missing.

local M = OPX.Modules.Declare{
	id = 'garages',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'vehicles', 'prompts', 'downed' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection.
	ASK = OPX.Event(NET, 'garages', 'ask'),
	REQUEST = OPX.Event(NET, 'garages', 'request'),
	CAPTURED = OPX.Event(NET, 'garages', 'captured'),

	-- Server to client: the spots this player may see, one verdict, and the ask
	-- to capture where a player is standing (a command has no heading of its own).
	SYNC = OPX.Event(NET, 'garages', 'sync'),
	ANSWER = OPX.Event(NET, 'garages', 'answer'),
	CAPTURE = OPX.Event(NET, 'garages', 'capture'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'garages', 'decision'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: without it a client waiting on one of several requests
-- cannot tell which `error.tooFast` is its own.
M.Operation = { BRING = 'garageBring', CAPTURE = 'garageCapture' }

--- The host raises this when a player rebinds or resets a mapping.
M.KEYBINDS_CHANGED = 'onKeybindsChanged'

--- The two kinds a spot may declare. A garage is a ground vehicle, a pad is an AV.
M.KIND = { GARAGE = 'garage', AVPAD = 'avpad' }
