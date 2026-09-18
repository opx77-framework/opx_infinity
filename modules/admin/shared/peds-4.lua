--- The last ped index part: whatever the earlier parts left.
-- @author dop42
--
-- `FinishPeds` records a problem when more rows are left than one part should
-- carry, which is the signal to add a `shared/peds-<n>.lua` line to the
-- manifest. A missing part costs load time, never a ped.

OPX.Modules.Get('admin').Peds.FinishPeds()
