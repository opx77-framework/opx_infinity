--- The last vehicle index part: whatever the earlier parts left.
-- @author dop42
--
-- `FinishVehicles` records a problem when more rows are left than one part
-- should carry, which is the signal to add a `shared/catalog-<n>.lua` line to
-- the manifest. A missing part costs load time, never a vehicle.

OPX.Modules.Get('admin').Catalog.FinishVehicles()
