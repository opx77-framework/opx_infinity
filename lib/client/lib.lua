--- `opx_lib`, loaded once for the whole client half.
-- @author dop42
--
--   OPX.Lib.Input.IsCaptured()
--   OPX.Lib.Rpc.Call('open77_notifications', 'show', { message = 'Saved' })
--
-- WHY THE LIBRARY IS REACHED THROUGH `OPX` AND NOT IMPORTED PER FILE. `require`
-- caches by resolved file per caller generation, so twenty `require('@opx_lib')`
-- calls cost one load -- the repetition would be harmless, not wasteful. It is
-- a convention rather than an optimisation: every other shared thing in this
-- resource is `OPX.<something>`, and one import line at the top of twenty files
-- is twenty places to forget it.
--
-- WHY IT IS CLIENT-ONLY, AND CANNOT BE OTHERWISE. The dedicated-server sandbox
-- has no `require` at all. `OPX.Result`, `OPX.Math`, `OPX.Text` and the rest of
-- `lib/shared/` therefore stay where they are and are NOT the library's copies,
-- even where the code is equivalent: the server has no way to load them. That
-- asymmetry is the reason only the two client-only helpers moved out --
-- `OPX.Keys` became `OPX.Lib.Input`, `OPX.Rpc` became `OPX.Lib.Rpc` -- and the
-- reason nothing else will follow them until the platform grows a server
-- loader.
--
-- THE DEPENDENCY IS DECLARED IN THE MANIFEST, so the platform will not start
-- this resource until `opx_lib` is running. A failure here therefore means the
-- manifest and this file disagree, which is worth stopping for: the alternative
-- is `attempt to index a nil value` in whichever module happens to read
-- `OPX.Lib` first, twenty files from the cause.

local lib, reason = require('@opx_lib')

if type(lib) ~= 'table' then
	error(('opx_infinity requires opx_lib, and require answered %q. Check that '
		.. 'open77.lua carries `dependency "opx_lib"` and that the resource is '
		.. 'installed and running.'):format(tostring(reason)), 0)
end

OPX.Lib = lib
