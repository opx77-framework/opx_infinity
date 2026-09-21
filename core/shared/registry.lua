--- The module registry and the contract registry.
-- @author dop42
--
-- Files still load in manifest order, because the platform has no module system:
-- a file that is both listed in the manifest and reached by `require` executes
-- twice, and `require` is client-only -- the dedicated server has no module
-- loader at all, so it can never order a shared registry. What this file adds is
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

--- One module's settings, as the config stands AT THIS MOMENT.
--
-- RESOLVED WHEN IT IS READ, NEVER CAPTURED, and that is not a style preference.
-- A module is declared by `modules/<id>/module.lua`, which is a `shared_script`, and
-- the platform's loaders run `SharedScripts.Concat(ServerScripts)` -- EVERY shared
-- script before ANY server script. So a table captured at declare time is the empty
-- fallback for every module whose config is a SERVER script, and it stays empty for
-- the life of the resource: the config assigns its table afterwards, and the module
-- is still holding the `{}` it was handed.
--
-- Three configs are server scripts (`config/server.lua`, `config/vehicles.lua`,
-- `config/theme.lua`). The cost was not theoretical. `vehicles` reads
-- `M.Settings.PER_CHARACTER`, which arrived as nil, and `Register` threw on
-- `nil > 0` -- inside a dealership purchase, after the money had been taken and
-- before any row was written. So a player was charged and owned nothing, and every
-- garage then answered, correctly, "you own nothing that comes out here".
--
-- The offline suite could not see it: it loaded the manifest in FILE order, where
-- every config sits above every module. That is fixed beside this in `tests/host.lua`.
--
-- THIS FILE IS A `shared_script`, SO IT RUNS IN BOTH SANDBOXES, and the two do not
-- offer the same globals: the client's `OpenSandbox` (scripting/src/ResourceHost.cpp)
-- removes `setmetatable` and `getmetatable` outright, while the server's
-- (`LuaResourceRuntime.Sandbox`) keeps them. Nothing here may therefore use either,
-- or a metatable that works on the server refuses the whole resource on the client --
-- the session ends with `resource_activation_failed` before a single module starts.
-- `OPX.Modules.Rebind` is what answers the same question without one.
-- @author XEROX710
-- @param id string
-- @return table the module's settings, never nil
function OPX.Modules.Settings(id)
	return OPX.Config.MODULES[id] or {}
end

--- Re-points every declared module's `Settings` at its live config.
--
-- Call it ONCE, from `OPX.Modules.Resolve`, which is the moment every script has run
-- and no phase has: the only point at which a module whose config is a
-- `server_script` can be told what that config says. `Declare` has already handed out
-- the table that existed then, and a module never assigns this field itself, so the
-- re-point is the whole of the fix and no read can be left holding the old one.
-- @author XEROX710
function OPX.Modules.Rebind()
	for _, record in ipairs(OPX.Modules.All()) do
		record.Module.Settings = OPX.Modules.Settings(record.Id)
	end
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
	-- AFTER `Resolve` IS TOO LATE, AND IT USED TO BE SILENT. `Resolve` memoises
	-- its order, so a module declared once it has run sits at `declared` for
	-- ever: no phase touches it, `Report` never lists it -- it walks the
	-- resolved order -- and `IsRunning` answers false with the reason recorded
	-- nowhere. Every `Declare` today is in a `module.lua` loaded before the
	-- phases begin, so this is a trap being shut rather than a bug being fixed;
	-- it is shut because the failure it produces is invisible.
	if type(OPX.Modules.Resolved) == 'function' and OPX.Modules.Resolved() then
		error(('module %q is declared after the modules were resolved; nothing would run it')
			:format(id), 2)
	end

	local side = spec.side or 'both'
	if not SIDES[side] then
		error(('module %q declares an unknown side %q'):format(id, tostring(side)), 2)
	end

	local settings = OPX.Modules.Settings(id)

	-- What the module's own files write into. `Settings` and the four phase
	-- functions are the only names the runtime ever looks for here.
	--
	-- `Settings` here is the config as it stands AT DECLARE TIME, which for the three
	-- `server_script` configs is the empty fallback: the platform runs every shared
	-- script before any server script, so `config/vehicles.lua` has not run yet when
	-- `modules/vehicles/module.lua` declares itself. `OPX.Modules.Rebind` re-points
	-- this field once everything has run, which is why a module may read `M.Settings`
	-- freely in its own phases and must NOT capture it into a file-scope local.
	--
	-- A `__index` metatable would answer the same question, and is not available:
	-- the client sandbox has no `setmetatable`. See `OPX.Modules.Settings` above.
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

	-- THE FAST PATH. At declare time the answer is only knowable for a config that
	-- has already run, which is every `shared_script` config and neither of the two
	-- MODULES-shaped server scripts. `OPX.Modules.Resolve` answers for the rest, once
	-- every script has run and before any phase does.
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

--- Withdraws every contract a module published. Called by the lifecycle when
--- that module is halted.
---
--- A PUBLISHED CONTRACT OUTLIVED THE MODULE THAT PUBLISHED IT. `Provide` is
--- called from inside `Api`, and `Api` is a function that can raise three lines
--- after publishing: the module was marked `failed` and the contract stayed in
--- this table for the life of the resource, pointing at an implementation whose
--- constructor never finished and whose `Start` will never run. `settle` only
--- walks `Requires`, not `Optional`, so a module that lists it as optional was
--- not dropped -- it started, called `OPX.Api.Get`, got the half-built table,
--- and discovered the problem wherever it happened to look.
-- @author dop42
-- @param owner string the module id
-- @return string[] the names withdrawn
function OPX.Api.Withdraw(owner)
	local withdrawn = {}
	for name, held in pairs(contracts) do
		if held.owner == owner then withdrawn[#withdrawn + 1] = name end
	end
	for index = 1, #withdrawn do contracts[withdrawn[index]] = nil end
	return withdrawn
end
