--- One part of the ped index, PART rows long.
-- @author dop42
--
-- A file of its own because the host checks a script's load time every 10,000 VM
-- instructions and cancels the whole resource set when a check falls past its
-- deadline. Splitting the index across files is what keeps every one of them
-- under a check.

local Peds = OPX.Modules.Get('admin').Peds

Peds.IndexPeds(Peds.PART)
