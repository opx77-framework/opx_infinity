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
				-- Marked dead as well as unlinked: a `Trigger` already walking a
				-- copy of this list would otherwise still call a hook whose owner
				-- has withdrawn it -- a module that has just been stopped, or a
				-- one-shot that has already fired.
				list[i].fn = nil
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

	-- THE LIST IS WALKED AS IT WAS AT THE START, NOT AS IT BECOMES. This
	-- iterated the live table with a bound fixed at entry, while `Register` and
	-- `Remove` insert into and remove from that same table -- and a hook is
	-- entitled to do either, including from inside this loop. `Trigger` also
	-- yields: `character:loading` runs hooks that read the database, so another
	-- thread can reach `Remove` between two hooks of one trigger.
	--
	-- Three things that cost a veto, all of them reachable:
	--   * a one-shot hook that removes itself shifts the tail down, so the
	--     hook after it is skipped;
	--   * a `Remove` from elsewhere during a yield leaves `list[i]` nil at the
	--     old bound, and `list[i].fn` is the evaluation of an ARGUMENT to
	--     `pcall`, so that index is not protected by it -- the raise leaves
	--     `Trigger` entirely and the hooks after it never vote;
	--   * a hook that registers a lower priority inserts before the cursor and
	--     the hook at the cursor runs a second time while the last is skipped.
	--
	-- A skipped hook here is a skipped VETO, so the action it would have
	-- refused goes through. A shallow copy costs one table per trigger and
	-- makes the walk say what the loop always claimed it said. `Remove` marks
	-- the entry dead as well as unlinking it, so a copy taken before the
	-- removal does not call a hook its owner has already withdrawn.
	local walking, count = {}, #list
	for i = 1, count do walking[i] = list[i] end

	for i = 1, count do
		local entry = walking[i]
		-- pcall so a third-party hook that raises is logged and skipped rather
		-- than aborting the caller; only an explicit false is a veto, which
		-- keeps a hook that merely returns nothing from blocking the action.
		if entry ~= nil and entry.fn ~= nil then
			local ok, verdict = pcall(entry.fn, payload)
			if not ok then
				Open77.log.error(('[hooks] %s (#%d) raised: %s')
					:format(name, entry.id, tostring(verdict)))
			elseif verdict == false then
				return false
			end
		end
	end
	return true
end

-- `Has(name)` was here and had no caller. Asking whether a hook has listeners
-- before running it is the shape that goes stale between the question and the
-- answer; `Run` over an empty list is already the cheap no-op that makes the
-- question unnecessary.
