--- Calls another client resource's exports, checked at every level.
-- @author dop42
--
-- `Open77.exports.call` is the only way in: this platform installs no
-- `exports.<resource>:<name>()` proxy. A call is a dispatch that answers a
-- promise, and a promise that answers a table.
--
-- A call fails at three separate levels, and a caller that checks only the
-- first turns a remote error into a silent nil:
--
--   1. dispatch    the resource is not running, or `call` raised, so `promise`
--                  is nil -- nothing was ever asked
--   2. resolution  the promise answered `callError` -- it was asked and never
--                  answered
--   3. the answer  `result.ok ~= true` -- the remote answered, and refused
--
-- `answered` tells level 3 from levels 1 and 2: false means the remote was
-- unreachable and its state is unknown, true means it spoke and said no. Only
-- a caller that knows the difference may drop cached state on a failure.

OPX.Rpc = {}

--- Whether a resource is running right now.
-- @author dop42
-- @param resource string
-- @return boolean
function OPX.Rpc.IsRunning(resource)
	-- Guarded: a soft-dependency check must never take its caller down over a
	-- name the host does not recognise.
	local read, state = pcall(GetResourceState, resource)
	return read and state == 'running'
end

--- Calls one client export on another resource and reads its answer.
-- Yields on the promise, so it only runs inside a `CreateThread`.
-- The `await` sits outside every pcall on purpose: a yield is not safe across
-- a pcall boundary in this runtime, so only the dispatch is pcall'd.
-- @author dop42
-- @param resource string
-- @param name string
-- @param ... any
-- @return table|nil the whole answer, nil at any of the three levels
-- @return string|nil the failure code
-- @return boolean answered, true only when the remote itself refused
function OPX.Rpc.Call(resource, name, ...)
	local exports = Open77.exports
	-- Absent when the manifest granted this resource no export access at all.
	if type(exports) ~= 'table' or type(exports.call) ~= 'function' then
		return nil, 'no_exports', false
	end
	if not OPX.Rpc.IsRunning(resource) then return nil, 'not_running', false end

	local dispatched, promise, reason = pcall(exports.call, resource, name, ...)
	if not dispatched then return nil, tostring(promise), false end
	if not promise then return nil, tostring(reason or 'not_dispatched'), false end

	local result, callError = promise:await()
	if callError then return nil, tostring(callError), false end
	if type(result) ~= 'table' then return nil, 'malformed_answer', true end
	if result.ok ~= true then return nil, tostring(result.error or 'refused'), true end
	return result, nil, true
end
