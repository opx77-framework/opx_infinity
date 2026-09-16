--- Values an operator may change from the Warden panel while people are playing.
-- @author dop42
--
-- Modules contribute their block during `Init`; the runtime declares the whole
-- set once, before anything starts. One declaration per resource is all the host
-- offers, so collecting is not a convenience -- a second `declare` would replace
-- the first and every other module's values would vanish from the panel.
--
-- Read through `Number` at the moment of use, never captured into a local at file
-- scope: a captured tunable is frozen for the life of the resource, which is the
-- one thing a live value must not be.

OPX.Tune = OPX.Tune or {}

local declaration = {}
local defaults = {}
local live
local declared = false

local CHANGED = OPX.Event(OPX.Channel.INTERNAL, 'tune', 'changed')

--- Adds a module's tunables. Call from `Init`. A key already declared is an
--- error rather than a silent overwrite: two modules fighting over one panel
--- entry is a bug in one of them, and the panel would show only the winner.
-- @author dop42
-- @param block table<string, table>
function OPX.Tune.Declare(block)
	if declared then
		error('tunables are declared once, before any module starts', 2)
	end
	for key, spec in pairs(block) do
		if declaration[key] ~= nil then
			error(('tunable %q is declared twice'):format(key), 2)
		end
		declaration[key] = spec
		defaults[key] = spec.value
	end
end

--- Declares everything collected. Called once by boot, between `api` and `start`.
--- A refused declaration used to be fatal, on the reasoning that running on a
--- value the panel cannot adjust is worse than not starting. That is still true
--- of one value, but not of a whole runtime: here one module's bad block would
--- take down four working ones, so the values fall back to their configured
--- defaults and the failure is said loudly instead.
-- @author dop42
-- @return boolean whether the panel is live
function OPX.Tune.Publish()
	if declared then return live ~= nil end
	declared = true

	-- Resolved before the pcall can help: indexing a nil `Open77.tunables` raises
	-- outside it, so a host that does not install the panel would take boot down
	-- rather than degrade. The same reason `lib/server/storage.lua` reaches the
	-- MySQL bridge through rawget.
	local panel = Open77.tunables
	if type(panel) ~= 'table' or type(panel.declare) ~= 'function' then
		Open77.log.warn('[tune] no tunables panel on this host; configured defaults are used')
		return false
	end

	local ok, answer = pcall(panel.declare, declaration)
	if not ok or answer == nil then
		Open77.log.error(('[tune] the panel refused the declaration: %s')
			:format(tostring(answer)))
		Open77.log.error('  every tunable now reads its configured default and cannot be ' ..
			'changed while the server runs.')
		return false
	end

	live = answer
	return true
end

--- The current value of a tunable, or its configured default.
-- @author dop42
-- @param key string
-- @return any
function OPX.Tune.Get(key)
	if live ~= nil then
		local value = live[key]
		if value ~= nil then return value end
	end
	return defaults[key]
end

--- A tunable read as a finite number, never below a floor. The floor is also the
--- answer for an undeclared key and for a value that is not a finite number, so
--- no caller ever compares a deadline against nil.
-- @author dop42
-- @param key string
-- @param floor number
-- @return number
function OPX.Tune.Number(key, floor)
	local value = OPX.Tune.Get(key)
	-- Tested with IsFinite rather than `value ~= value`: an infinity passes a NaN
	-- test and would freeze an interval.
	if not OPX.Math.IsFinite(value) then return floor end
	if floor and value < floor then return floor end
	return value
end

--- Whether a key was declared by anybody.
-- @author dop42
-- @param key string
-- @return boolean
function OPX.Tune.Known(key)
	return declaration[key] ~= nil
end

-- The host names the key that moved. Re-raised internally so a module can react
-- without every module registering its own host handler.
AddEventHandler(OPX.Host.TUNABLE_CHANGED, function(key)
	TriggerEvent(CHANGED, key)
end)
