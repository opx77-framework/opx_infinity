--- One part of the weapon index, PART weapons long.
-- @author dop42
--
-- A file of its own because the host checks a script's load time every 10,000 VM
-- instructions and cancels the whole resource set when a check falls past its
-- deadline. A weapon costs roughly 160 instructions, so splitting the index
-- across files is what keeps every one of them under a check.

local Catalog = OPX.Modules.Get('inventory').Catalog

Catalog.IndexWeapons(Catalog.PART)
