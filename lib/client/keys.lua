--- The host keyboard, read so that a failed read is never a raise.
-- @author dop42
--
-- `Open77.input` is only installed when the manifest grants `input.actions`,
-- and a reader that is present can still raise on a build that does not
-- support it. Every read below is therefore guarded twice: the function is
-- checked before it is called, and the call is pcall'd.
--
-- A guarded read answers the safe value rather than the optimistic one. For
-- capture that means captured: a key that fires while another surface owns the
-- keyboard types into someone else's text box, which is worse than a key that
-- does nothing.

OPX.Keys = {}

--- The input table, or nil when this client has none.
-- @return table|nil
local function input()
	local bridge = Open77.input
	if type(bridge) ~= 'table' then return nil end
	return bridge
end

--- Whether another surface holds the keyboard right now.
-- No input bridge at all means nothing can be capturing, so that answers
-- false; a reader that raises answers true, the safe value.
-- @author dop42
-- @return boolean
function OPX.Keys.IsCaptured()
	local bridge = input()
	if bridge == nil or type(bridge.isCaptured) ~= 'function' then return false end
	local read, captured = pcall(bridge.isCaptured)
	if not read then return true end
	return captured == true
end

--- The mouse cursor, or nil when it cannot be read.
-- @author dop42
-- @return table|nil with at least `inBounds` and `captured`
function OPX.Keys.Cursor()
	local bridge = input()
	if bridge == nil or type(bridge.cursor) ~= 'function' then return nil end
	local read, cursor = pcall(bridge.cursor)
	if not read or type(cursor) ~= 'table' then return nil end
	return cursor
end

--- The key a registered mapping answers to now, rebinds included.
-- @author dop42
-- @param action string the mapping id it was registered under
-- @return string|nil nil when the key is unknown
function OPX.Keys.KeyFor(action)
	local bridge = input()
	if bridge == nil or type(bridge.keyFor) ~= 'function' then return nil end
	local read, key = pcall(bridge.keyFor, action)
	if not read or type(key) ~= 'string' or key == '' then return nil end
	return key
end

--- Every key mapping the host knows, across all resources.
-- A failed read answers nil rather than an empty list: an empty list is a
-- truthful `nobody registered anything`, and a caller that cached the last
-- good copy would wipe it over a read that simply did not happen.
-- @author dop42
-- @return table|nil list of { resource, id, key }
-- @return string|nil the failure
function OPX.Keys.Mappings()
	local bridge = input()
	if bridge == nil or type(bridge.mappings) ~= 'function' then return nil, 'no_input' end
	local read, list = pcall(bridge.mappings)
	if not read then return nil, tostring(list) end
	if type(list) ~= 'table' then return nil, 'malformed_answer' end
	return list, nil
end

--- Whether a key is held down now.
-- @author dop42
-- @param key string
-- @return boolean
function OPX.Keys.IsDown(key)
	local bridge = input()
	if bridge == nil or type(bridge.isDown) ~= 'function' then return false end
	-- The reader answers the state and, on a second return, a refusal: a key
	-- name it does not poll answers (nil, reason) rather than raising.
	local read, down, refusal = pcall(bridge.isDown, key)
	if not read or refusal ~= nil then return false end
	return down == true
end

--- Keeps a native action off its key, or gives it back.
-- @author dop42
-- @param action string
-- @param blocked boolean
-- @return boolean
-- @return string|nil the failure
function OPX.Keys.BlockNativeAction(action, blocked)
	local bridge = input()
	if bridge == nil or type(bridge.setNativeActionBlocked) ~= 'function' then
		return false, 'native_action_unavailable'
	end
	local called, ok, reason = pcall(bridge.setNativeActionBlocked, action, blocked == true)
	if not called then return false, tostring(ok) end
	if ok ~= true then return false, tostring(reason or 'refused') end
	return true, nil
end
