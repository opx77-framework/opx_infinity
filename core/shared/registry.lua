--- The module registry and the contract registry.
-- @author dop42
--
-- Files still load in manifest order, because the platform has no module system:
-- a file that is both listed in the manifest and reached by `require` executes
-- twice, and `require` cannot leave the resource anyway. What this file adds is
-- ordering *between* modules, so that a module never depends on another module
-- having happened to run a particular file first.
--
--   modules/<id>/module.lua        OPX.Modules.Declare{...}   -- pure data
--   modules/<id>/server/main.lua   M.Init / M.Api / M.Start / M.Stop
--
-- No metatables anywhere: none of the 37 shipped platform resources uses one,
-- and the client sandbox does not install `getmetatable`.

OPX.Modules = OPX.Modules or {}
OPX.Api = OPX.Api or {}

-- Two tables on purpose. `records` is the runtime's bookkeeping -- id, side,
-- dependencies, state, reason -- and `namespaces` is what a module's own files
-- write into. They used to be one table, and a module that happened to want a
-- field called `State` silently overwrote its own lifecycle state and never
-- started, with nothing logged. The only names the runtime reads off a namespace
-- now are the four phases; everything else there belongs to the module.
local records = {}
local namespaces = {}
local order = {}
local contracts = {}

local SIDES = { server = true, client = true, both = true }

--- Whether this VM runs the given side.
local function runsHere(side)
	if side == 'both' then return true end
	if side == 'server' then return OPX.IsServer end
	return OPX.IsClient
end

--- Declares a module and returns its table. Call once, from `module.lua`, before
--- any of the module's own files. The returned table is where those files hang
--- `Init`, `Api`, `Start` and `Stop`.
-- @author dop42
-- @param spec table id, side, requires, optional, fatal
-- @return table the module table
function OPX.Modules.Declare(spec)
	local id = spec and spec.id
	if type(id) ~= 'string' or id == '' then
		error('a module must declare a string id', 2)
	end
	if records[id] then
		error(('module %q is declared twice'):format(id), 2)
	end

	local side = spec.side or 'both'
	if not SIDES[side] then
		error(('module %q declares an unknown side %q'):format(id, tostring(side)), 2)
	end

	local settings = OPX.Config.MODULES[id] or {}

	-- What the module's own files write into. `Settings` and the four phase
	-- functions are the only names the runtime ever looks for here.
	local namespace = { Settings = settings }

	local record = {
		Id = id,
		Side = side,
		Requires = spec.requires or {},
		Optional = spec.optional or {},
		Fatal = spec.fatal == true,
		Provides = spec.provides,
		Module = namespace,
		State = 'declared',
		Reason = nil,
	}

	if settings.enabled == false then
		record.State = 'disabled'
		record.Reason = 'disabled in config'
	elseif not runsHere(side) then
		record.State = 'absent'
		record.Reason = 'runs on the ' .. side
	end

	records[id] = record
	namespaces[id] = namespace
	order[#order + 1] = id
	return namespace
end

--- The module's own namespace -- what its files write into and read from.
-- @author dop42
-- @param id string
-- @return table|nil
function OPX.Modules.Get(id)
	return namespaces[id]
end

--- The runtime's bookkeeping for a module: id, side, dependencies, state and
--- reason. Separate from the namespace so that a module writing a field of its
--- own can never overwrite its own lifecycle state.
-- @author dop42
-- @param id string
-- @return table|nil
function OPX.Modules.Record(id)
	return records[id]
end

--- Every declared module, in declaration order.
-- @author dop42
-- @return table[]
function OPX.Modules.All()
	local list = {}
	for index = 1, #order do list[index] = records[order[index]] end
	return list
end

--- Whether a module reached `started` in this VM.
-- @author dop42
-- @param id string
-- @return boolean
function OPX.Modules.IsRunning(id)
	local record = records[id]
	return record ~= nil and record.State == 'started'
end

--- Publishes a contract. Called from a module's `Api` phase; after that phase no
--- provider may appear, so a consumer's `Require` either resolves or is a fault.
-- @author dop42
-- @param name string
-- @param version integer
-- @param implementation table
function OPX.Api.Provide(name, version, implementation)
	if type(name) ~= 'string' or type(version) ~= 'number' or type(implementation) ~= 'table' then
		error('Provide(name, version, implementation)', 2)
	end
	local held = contracts[name]
	if held then
		-- Two providers silently resolving to one is how a framework loses a
		-- ledger. Name both and stop.
		error(('contract %q is provided by both %q and %q')
			:format(name, held.owner, OPX.Api.Owner or '?'), 2)
	end
	contracts[name] = { version = version, implementation = implementation, owner = OPX.Api.Owner or '?' }
end

--- The implementation of a contract, or nil when nobody provides it at or above
--- `minimum`. A caller that cannot continue without it uses `Require`.
-- @author dop42
-- @param name string
-- @param minimum? integer
-- @return table|nil
-- @return integer|nil version
function OPX.Api.Get(name, minimum)
	local held = contracts[name]
	if not held then return nil end
	if minimum ~= nil and held.version < minimum then return nil end
	return held.implementation, held.version
end

--- Like `Get`, but raises rather than returning nil. For a module that declared
--- the contract in `requires` and therefore cannot have started without it.
-- @author dop42
-- @param name string
-- @param minimum? integer
-- @return table
function OPX.Api.Require(name, minimum)
	local implementation = OPX.Api.Get(name, minimum)
	if not implementation then
		error(('contract %q is not available'):format(name), 2)
	end
	return implementation
end

--- Every published contract, as name -> version.
-- @author dop42
-- @return table<string, integer>
function OPX.Api.Versions()
	local list = {}
	for name, held in pairs(contracts) do list[name] = held.version end
	return list
end
