--- Named extension points a gameplay file can veto through.
-- @author dop42

OPX.Hooks = {}

-- Each list is kept sorted by priority at insertion, so trigger never sorts.
local registry = {}
local nextId = 0

--- Adds a hook, lower priority first, and answers its id.
-- @author dop42
-- @param name string
-- @param fn fun(payload: HookPayload): boolean|nil
-- @param priority number|nil
-- @return integer
function OPX.Hooks.Register(name, fn, priority)
	if type(name) ~= 'string' or type(fn) ~= 'function' then
		error('OPX.Hooks.Register expects (name: string, fn: function)', 2)
	end

	nextId = nextId + 1
	local entry = { id = nextId, fn = fn, priority = tonumber(priority) or 0 }

	local list = registry[name]
	if not list then
		list = {}
		registry[name] = list
	end

	-- Insert before the first strictly greater priority, never before an equal
	-- one, so hooks sharing a priority keep their registration order.
	local at = #list + 1
	for i = 1, #list do
		if list[i].priority > entry.priority then
			at = i
			break
		end
	end
	table.insert(list, at, entry)

	return entry.id
end

--- @author dop42
-- @param id integer
-- @return boolean
function OPX.Hooks.Remove(id)
	for _, list in pairs(registry) do
		for i = 1, #list do
			if list[i].id == id then
				table.remove(list, i)
				return true
			end
		end
	end
	return false
end

--- Runs every hook at a name, stopping at the first veto.
-- @author dop42
-- @param name string
-- @param payload HookPayload
-- @return boolean
function OPX.Hooks.Trigger(name, payload)
	local list = registry[name]
	if not list then return true end

	for i = 1, #list do
		-- pcall so a third-party hook that raises is logged and skipped rather
		-- than aborting the caller; only an explicit false is a veto, which
		-- keeps a hook that merely returns nothing from blocking the action.
		local ok, verdict = pcall(list[i].fn, payload)
		if not ok then
			Open77.log.error(('[hooks] %s (#%d) raised: %s')
				:format(name, list[i].id, tostring(verdict)))
		elseif verdict == false then
			return false
		end
	end
	return true
end

-- `Has(name)` was here and had no caller. Asking whether a hook has listeners
-- before running it is the shape that goes stale between the question and the
-- answer; `Run` over an empty list is already the cheap no-op that makes the
-- question unnecessary.
