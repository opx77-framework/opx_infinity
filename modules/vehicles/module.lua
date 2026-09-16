--- Owned vehicles: registering one, bringing it out, putting it away, and
--- keeping its condition across a restart.
-- @author dop42
--
-- The plate is the identity, never the runtime id: a runtime id belongs to one
-- spawn and is recycled, a plate is the row. Ownership is proved against the
-- character the connection has loaded, and never against what the client claims.
--
-- `live` -- plate to runtime id and owner -- is what is out NOW, and it is
-- rebuilt empty on every reload: the host removes the vehicles this resource
-- created when it stops, so a carried table would name vehicles that are gone.
--
-- Only vehicles this module spawned have a row. One created by anything else
-- answers no plate at all, and nothing durable may be attached to it.

local M = OPX.Modules.Declare{
	id = 'vehicles',
	side = 'server',
	fatal = false,
	-- Every row is keyed on the citizen id, and only the character module knows
	-- which character a connection has loaded.
	requires = { 'character' },
}

-- The three prefixes are disjoint by construction (see core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` on a
-- NET name would re-enter the handler registered for the wire.
local NET = OPX.Channel.NET

M.Event = {
	-- Client to server. Every payload is attacker-controlled; only `source` is
	-- not, and both handlers re-derive the character and the ownership from it.
	SPAWN = OPX.Event(NET, 'vehicles', 'spawn'),
	STORE = OPX.Event(NET, 'vehicles', 'store'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: without it a client waiting on one of several requests
-- cannot tell which `error.tooFast` is its own.
M.Operation = {
	SPAWN = 'vehicleSpawn',
	STORE = 'vehicleStore',
}
