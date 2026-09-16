--- The last weapon index part: whatever is left, then the sorted names.
-- @author dop42
--
-- `Finish` records a problem when more weapons are left than one part should
-- carry, which is the signal to add a `shared/catalog-<n>.lua` line to the
-- manifest. A missing part costs load time, never a weapon.

OPX.Modules.Get('inventory').Catalog.Finish()
