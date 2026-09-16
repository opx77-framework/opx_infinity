--- The OPX namespace. Every file loaded after this one fills it.
-- @author dop42

OPX = OPX or {}

OPX.VERSION = '0.1.0'

-- Both globals are installed by the bootstrap before the first script, and each
-- exists in exactly one runtime. `Open77.database` cannot be used for this: it is
-- only installed with the `database.access` permission.
OPX.IsServer = rawget(_G, 'TriggerClientEvent') ~= nil
OPX.IsClient = rawget(_G, 'TriggerServerEvent') ~= nil

--- Configuration roots, filled by `config/`. `SERVER` is nil on a client and
--- `CLIENT` is nil on the server, so reading the wrong one fails loudly.
OPX.Config = OPX.Config or { SHARED = {}, MODULES = {} }

local resolvedTimer

--- Monotonic milliseconds since process start.
-- @author dop42
-- @return integer
function OPX.Now()
	-- Resolved on first use, not at load: during boot the global may not be
	-- installed yet, and a fallback captured now would be captured forever.
	if resolvedTimer == nil then
		resolvedTimer = rawget(_G, 'GetGameTimer') or false
	end
	if resolvedTimer then return resolvedTimer() end
	return math.floor(Open77.time.monotonic() * 1000)
end
