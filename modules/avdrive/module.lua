--- The AV autopilot: a seated pilot's aircraft, flown to the pilot's own map
--- waypoint and handed back at the hover.
-- @author XEROX710
--
-- ONE KEY, ONE FLIGHT, ONE HAND-OVER. A pilot sitting in an AV presses the
-- key; the client reads the map waypoint and says where; the server flies the
-- hull there in three legs -- climb, cruise, descend -- and releases it as a
-- hover above the pin. The same key, a seat left empty, an aircraft taken away
-- or this module stopping all end the run the same way: the freeze comes off,
-- the posing stops, and the platform hands the airframe back to whoever is
-- seated in it. That hand-over is the platform's own rule and not a
-- courtesy -- `modules/ncpd/server/av.lua` says it at length: a seated player
-- in an AV is its pilot as far as `VehicleReplication` is concerned, and two
-- hands on one airframe is a fight, not a ride. The freeze is what makes this
-- a ride: while it holds, the pilot's own motion reports are discarded by the
-- host rather than merged, so the flight this module publishes is the only
-- flight there is, and the release is the moment the pilot's stick means
-- something again.
--
-- WHY OURS AND NOT THE ENGINE'S. `Open77.vehicles.ai` auto-drives ground cars
-- through the engine's own traffic tasks and explicitly does not support AVs.
-- The honest primitive for an aircraft is `setTransform` per tick -- the
-- resource flies the follower -- which is exactly what the MaxTac insertion
-- already does. This module is that pattern aimed at a waypoint instead of a
-- street, and it is deliberately small: the numbers live in
-- `config/avdrive.lua`, the seat and record proofs are the host's own reads,
-- and nothing here creates, owns or removes a vehicle.

local M = OPX.Modules.Declare{
	id = 'avdrive',
	side = 'both',
	fatal = false,
	-- Nothing is required. The aircraft is not this module's: a seat is read
	-- through `Open77.vehicles`, a waypoint is read by the client and handed
	-- over the wire, and a module that wants to know what flew can read the
	-- poses the host already journalled. Requiring `vehicles` would take the
	-- key away from a server whose vehicles are all admin-spawned, and the
	-- autopilot has nothing to do with the ownership roster.
	requires = {},
}

local NET = OPX.Channel.NET

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server: the one key was pressed. The payload is a SUGGESTION of
	-- where to fly -- the client's own map waypoint, or the flag saying the map
	-- could not be read. `source` always comes from the authenticated
	-- connection, and the server re-derives the seat, the hull and the record
	-- from it; the payload only ever names the destination.
	TOGGLE = OPX.Event(NET, 'avdrive', 'toggle'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: there is exactly one ask here, and naming it keeps
-- the refusal ledger's operation field honest.
M.Operation = { ENGAGE = 'avdriveEngage' }
