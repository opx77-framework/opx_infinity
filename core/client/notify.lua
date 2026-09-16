--- Toasts, drawn on the overlay.
-- @author dop42
--
-- This used to be a resource of its own that everything else reached through an
-- export, which is why twelve resources carried a copy of the three-level export
-- call just to raise a notice. In one runtime it is a call.
--
-- The page owns the timing: a toast carries its lifetime and the page animates
-- it down and asks to be told when it has gone. Lua keeps only what it needs to
-- address a toast that is still up.

OPX.Toast = OPX.Toast or {}

local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
local ANSWER = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')

local KINDS = { info = true, success = true, warning = true, error = true }
local DEFAULT_MS = 5000

local live = {}
local nextId = 0

--- Raises a toast and answers its id. `id` may be supplied to replace a toast
--- already on screen rather than stacking another under it -- a player who runs
--- the same command twice should see one answer, not a pile.
-- @author dop42
-- @param definition table kind, title, message, durationMs, id
-- @return string|nil
function OPX.Toast.Show(definition)
	if type(definition) ~= 'table' then return nil end

	local message = definition.message
	if type(message) ~= 'string' or message == '' then return nil end

	local id = definition.id
	if type(id) ~= 'string' or id == '' then
		nextId = nextId + 1
		id = ('t%d'):format(nextId)
	end

	local toast = {
		id = id,
		kind = KINDS[definition.kind] and definition.kind or 'info',
		title = definition.title,
		message = message,
		durationMs = tonumber(definition.durationMs) or DEFAULT_MS,
	}

	live[id] = toast
	if not OPX.UI.Send('overlay', 'notify:show', toast) then
		live[id] = nil
		return nil
	end
	return id
end

--- Raises a toast whose text comes from the catalogue. Every refusal code in
--- this runtime is a catalogue key, so this is the path a refusal takes.
-- @author dop42
-- @param key string
-- @param params table|nil
-- @param kind string|nil
-- @return string|nil
function OPX.Toast.Locale(key, params, kind)
	return OPX.Toast.Show({ kind = kind, message = locale(key, params) })
end

--- Takes a toast off screen early.
-- @author dop42
-- @param id string
function OPX.Toast.Dismiss(id)
	if live[id] == nil then return end
	live[id] = nil
	OPX.UI.Send('overlay', 'notify:dismiss', { id = id })
end

--- Rewrites a toast that is still up. Answers false for one that has gone, so a
--- caller updating a progress line stops rather than raising a fresh toast.
-- @author dop42
-- @param id string
-- @param patch table
-- @return boolean
function OPX.Toast.Update(id, patch)
	local toast = live[id]
	if toast == nil or type(patch) ~= 'table' then return false end

	for key, value in pairs(patch) do
		if key ~= 'id' then toast[key] = value end
	end
	return OPX.UI.Send('overlay', 'notify:update', toast)
end

--- Clears everything on screen.
-- @author dop42
function OPX.Toast.Clear()
	live = {}
	OPX.UI.Send('overlay', 'notify:clear', {})
end

--- Wires the server's two answer channels and the page's own expiry report.
-- @author dop42
function OPX.Toast.Attach()
	-- The page tells us when a toast finished its own countdown, so Lua's table
	-- does not grow for the session with toasts that are long gone.
	OPX.UI.On('overlay', 'notify:gone', function(payload)
		if type(payload.id) == 'string' then live[payload.id] = nil end
	end)

	RegisterNetEvent(NOTIFY, function(payload)
		if type(payload) ~= 'table' then return end
		-- The code is always a catalogue key: the server guarantees it through
		-- RefusalKey, so rendering it raw is never a leak of an internal code.
		local code = payload.code
		if type(code) ~= 'string' then return end
		OPX.Toast.Show({ kind = payload.kind or 'error', message = locale(code) })
	end)

	RegisterNetEvent(ANSWER, function(_, kind, message, toasted)
		-- `toasted` means the action already raised this toast itself. Without
		-- the flag a command that notifies on success would answer twice.
		if toasted == true then return end
		if type(message) ~= 'string' or message == '' then return end
		OPX.Toast.Show({ kind = kind, message = message, id = 'opx.command' })
	end)
end
