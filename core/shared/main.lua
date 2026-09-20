--- The OPX namespace. Every file loaded after this one fills it.
-- @author dop42

OPX = OPX or {}

--- The version this resource's manifest declares.
--
-- ASKED, NOT COPIED, and the reason is that the copy was wrong. This was the
-- literal `'0.1.0'` while `open77.lua` said `0.1.2`, so every boot line, every
-- diagnostics dump and every client report named a version that had not been
-- deployed for two releases -- and the only symptom was somebody reading the
-- wrong number while chasing something else. `opx_lib` carries a test against
-- exactly this failure because it happened there first; here it happened and
-- nothing was watching.
--
-- Both runtimes can answer it and neither needs a permission: the client has
-- `Open77.resource.version()`, and the server reads its own manifest through
-- `Open77.resource.metadata(name, 'version')`. The literal below is the last
-- resort for a host that answers neither. `tests/run.lua` reads this very line
-- out of this file and holds it against the manifest, so even that path cannot
-- drift silently -- and it is read from the SOURCE rather than published on
-- `OPX`, because the suite forbids hanging internals there and is right to.
local DECLARED = '0.1.2'

local function manifestVersion()
	local resource = Open77 ~= nil and Open77.resource or nil
	if type(resource) ~= 'table' then return DECLARED end

	if type(resource.version) == 'function' then
		local read, version = pcall(resource.version)
		if read and type(version) == 'string' and version ~= '' then return version end
	end

	if type(resource.metadata) == 'function' and type(resource.name) == 'function' then
		local named, name = pcall(resource.name)
		if named and type(name) == 'string' and name ~= '' then
			local read, version = pcall(resource.metadata, name, 'version')
			if read and type(version) == 'string' and version ~= '' then return version end
		end
	end

	return DECLARED
end

OPX.VERSION = manifestVersion()

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
