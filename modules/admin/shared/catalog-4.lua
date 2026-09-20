--- The fourth part of the vehicle index, PART rows long.
-- @author dop42
--
-- This was the last part until the Air class was added to `data/vehicles.lua`:
-- with the AV rows the catalogue no longer fits in four parts, and a last part
-- that carried two parts' worth would report a problem at boot rather than
-- silently loading slowly. `shared/catalog-5.lua` finishes the index now.

local Catalog = OPX.Modules.Get('admin').Catalog

Catalog.IndexVehicles(Catalog.PART)
