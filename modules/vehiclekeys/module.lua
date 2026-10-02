--- Vehicle keys: one inventory item per vehicle, and the lock it works.
-- @author dop42
--
-- THE OWNER: "faire les clé de voiture en item, quand même les véhicules admin,
-- avant le menu ou alt on peut se donner la clé du véhicule précis".
--
-- A KEY IS AN ITEM AND ITS VEHICLE IS ITS METADATA. `vehicle_key` is one entry
-- in `modules/inventory/data/items.lua`; what it opens is
-- `{ plate = '<PLATE>', label = '<model> · <PLATE>' }` on the unit, written by
-- this module and never by a client. Two keys to two cars are two stacks, and
-- the screen draws each under its own label.
--
-- THE PLATE IS THE IDENTITY, the same rule `vehicles` lives by: a runtime id
-- belongs to one spawn and is recycled, a plate is the row. A vehicle `vehicles`
-- never spawned -- a staff spawn, a showroom car, anything another resource made
-- -- has no plate, so this module MINTS one for it the first time a key is cut:
-- `TMP-` and six characters. The dash is the point. A real plate is drawn from
-- `PLATE_FORMAT`, letters and digits into an `ascii_bin` column, so no minted
-- plate can ever be a real one and no temporary key can ever open an owned car.
-- A minted plate lives exactly as long as its vehicle: when the host removes
-- it the plate is forgotten, and a key to it opens nothing ever again -- which
-- is the honest reading of a key to a car that no longer exists.
--
-- WHAT A KEY DOES IS THE HOST'S LOCK. `Open77.vehicles.setLocked` and
-- `isLocked` (devkit cards `server:Open77.vehicles.setLocked`, since op77.45,
-- `world.vehicles`) move one durable, replicated bit that the engine itself
-- enforces: a locked car offers no mount choice and refuses a seat claim. This
-- module only decides WHO may flip it -- somebody holding a key whose plate is
-- that vehicle's, standing beside it or sitting in it -- and a locked vehicle's
-- trunk is shut by `World.TrunkLocked` in the inventory module.
--
-- EVERY CONTRACT IS OPTIONAL. Without `inventory` there is nowhere to keep a key
-- and every door says so; without `vehicles` every vehicle is plateless and gets
-- a minted plate; without `target` there is no row and the key item still works
-- from the bag. Nothing here is worth failing the resource over.

local M = OPX.Modules.Declare{
	id = 'vehiclekeys',
	side = 'both',
	fatal = false,
	-- `target` is client-only and rests `absent` on the server, which is why it
	-- is optional and not required -- the argument `modules/hauling/module.lua`
	-- makes at length.
	optional = { 'vehicles', 'inventory', 'target' },
}

local NET = OPX.Channel.NET

M.Event = {
	-- Client to server: "lock or unlock the vehicle I am pointing at". The payload
	-- names the vehicle and NOTHING ELSE the server believes: a plate in it is
	-- ignored, the key is looked for in the server's copy of the bag, and the
	-- vehicle's plate is the server's own answer.
	TOGGLE = OPX.Event(NET, 'vehiclekeys', 'toggle'),
}

--- Which request a refusal answers. See `M.Operation` in `modules/vehicles`.
M.Operation = {
	TOGGLE = 'vehicleKeyToggle',
}

--- The catalogue name of a key. Written once: the item file, the use handler, the
--- count and the client's row all spell it through this.
M.ITEM = 'vehicle_key'

--- The prefix of a plate minted for a vehicle `vehicles` never registered. See the
--- header for why the dash makes it impossible to collide with a real plate.
M.MINTED_PREFIX = 'TMP-'

--- Metres from a vehicle's centre a key works at, on the row and on the server.
-- A key fob from a few steps away, not across a car park: the row is offered
-- inside this, and the server measures it again from its own positions.
M.REACH = 6.0
