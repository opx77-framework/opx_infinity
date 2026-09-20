--- Clothing stores: stand on the marker, press the key, and the fitting room
--- opens with the game's own clothing catalogue in it.
-- @author XEROX710
--
-- The client draws one marker per configured store in the player's own routing
-- bucket, posts a prompt row while the player stands on one, and asks the
-- `appearance` contract to put the fitting room up when the key is pressed. The
-- server owns the list -- which stores exist, and which bucket each is in -- and
-- nothing else: no vehicle is created here, no money moves, and no row is
-- written except by a placement command.
--
-- THE FITTING ROOM IS NOT REIMPLEMENTED HERE. `appearance` streams the body's
-- whole catalogue for its family (`Open77.equipment.records`, `restricted =
-- false`, limit 2000, every slot), owns the puppet while a player browses, and
-- saves what survives; this module knows one thing about it -- how to ask for it
-- -- and refuses out loud when that contract is absent rather than drawing a
-- store that does nothing.
--
-- `appearance` is therefore OPTIONAL and not required. On a server running the
-- platform's own `open77_appearance` package the module stands down, and its
-- contract is exactly as absent as it is on a cut-down host: the markers must
-- still draw, the row must still post, and the key must say why it cannot open
-- anything instead of failing silently.
--
-- The strip is optional too: without `prompts` the markers still draw and the
-- key still works, and only the row is missing.

local M = OPX.Modules.Declare{
	id = 'clothing',
	side = 'both',
	-- Not fatal: a server with no clothing store is a server where a player
	-- dresses in the menu, and that is a choice an operator may make with
	-- `enabled = false`.
	fatal = false,
	optional = { 'appearance', 'prompts' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server: `source` always comes from the authenticated connection,
	-- and the payload carries nothing at all -- a list is asked for, never
	-- claimed.
	ASK = OPX.Event(NET, 'clothing', 'ask'),

	-- Server to client: the stores of this player's own routing bucket.
	SYNC = OPX.Event(NET, 'clothing', 'sync'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'clothing', 'decision'),
}

--- The host raises this when a player rebinds or resets a mapping.
M.KEYBINDS_CHANGED = 'onKeybindsChanged'

--- The name this module calls itself when it borrows the fitting room.
-- The appearance module lends the room to a NAMED caller and refuses to take it
-- back from anyone else, so the name is the whole of the ownership handshake --
-- it is declared here, once, rather than spelled out at the open call and the
-- test that reads it back.
M.WARDROBE_OWNER = 'clothing'
