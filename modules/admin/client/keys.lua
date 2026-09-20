--- The rebindable menu and noclip speed mappings.
-- @author dop42
--
-- Each key is declared to the host with `RegisterKeyMapping`, so the pause menu's
-- shortcuts tab lists it under the localised name given here and a player rebinds
-- it there. The mapping id is namespaced and STABLE: a rebind is stored under it,
-- and renaming one loses every player's rebind.
--
-- A key press sends the same command line the chat box would. None of them
-- authorises anything: a player without the grant presses the key and is refused
-- by the host, exactly as if they had typed it.

local M = OPX.Modules.Get('admin')

M.Keys = {}
local Keys = M.Keys

--- The mapping ids, listed once so a rename is followed here and nowhere else.
Keys.MENU = 'opx.admin.menu'
-- Opens the menu on the Dev screen rather than the root. A SECOND id and not the
-- menu's own: a player rebinds each one separately, and folding them together
-- would take the Dev key away from anyone who moved the menu key.
Keys.DEV = 'opx.admin.dev'
Keys.FASTER = 'opx.admin.noclipFaster'
Keys.SLOWER = 'opx.admin.noclipSlower'

-- Mapping id to the key the host answered with at registration.
local registered = {}

-- Functions run whenever a player rebinds or resets a mapping.
local listeners = {}

--- A configured key name, false for none, else the default.
-- @author dop42
-- @param path string how the warning names it, e.g. KEYS.MENU
-- @param value any
-- @param default string
-- @return string|false
function Keys.Setting(path, value, default)
	if value == false then return false end
	if value == nil then return default end
	if type(value) == 'string' and #value > 0 and #value <= 32 and not value:find('[%s%c]') then
		return value
	end
	Open77.log.warn(('[admin] config: %s must be a key name or false; using %q')
		:format(path, default))
	return default
end

--- Declares one key mapping. A refusal costs one log line and nothing else.
-- Two answer shapes are documented for `RegisterKeyMapping` -- the key guide
-- answers `true, key` and the API reference answers the key alone -- and either
-- is a registration. `false` or nil with a reason is a refusal.
-- @author dop42
-- @param id string
-- @param nameKey string catalogue key of the pause menu name
-- @param key string|false
-- @param onPressed function
-- @param onReleased function|nil makes it a hold mapping
-- @param whileCaptured function|nil answers true when a captured keyboard is
-- not a reason to swallow the press
-- @return boolean
function Keys.Register(id, nameKey, key, onPressed, onReleased, whileCaptured)
	if key == false then return false end
	if type(RegisterKeyMapping) ~= 'function' then
		Open77.log.warn(('[admin] key mapping %s not registered: this client build has no ' ..
			'RegisterKeyMapping'):format(id))
		return false
	end

	local function pressed()
		-- A key pressed while another surface holds the keyboard -- the chat box, a
		-- form, the pause menu -- does nothing, so that typing an F9 into a text
		-- field does not open a menu behind it. The one exception is the menu key
		-- while the player is DOWN: the down screen holds the keyboard for as long
		-- as they are on the floor, and a staff member has to be able to open the
		-- menu that gets them up again.
		if OPX.Lib.Input.IsCaptured() and not (whileCaptured ~= nil and whileCaptured() == true) then
			return
		end
		local ran, failure = pcall(onPressed)
		if not ran then Open77.log.error(('[admin] key %s: %s'):format(id, tostring(failure))) end
	end

	local called, ok, answer
	if onReleased == nil then
		called, ok, answer = pcall(RegisterKeyMapping, id, locale(nameKey), key, pressed)
	else
		local function released()
			local ran, failure = pcall(onReleased)
			if not ran then Open77.log.error(('[admin] key %s: %s'):format(id, tostring(failure))) end
		end
		called, ok, answer = pcall(RegisterKeyMapping, id, locale(nameKey), key, pressed, released)
	end
	local effective = type(ok) == 'string' and ok ~= '' and ok or
		(ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[admin] key mapping %s (%s) not registered: %s')
			:format(id, tostring(key), tostring(called and answer or ok)))
		return false
	end
	registered[id] = effective or key
	return true
end

--- The key a mapping answers to now, rebinds included.
-- @author dop42
-- @param id string
-- @return string|nil
function Keys.Effective(id)
	local known = registered[id]
	if known == nil then return nil end
	return OPX.Lib.Input.KeyFor(id) or known
end

--- Runs a listener whenever a player rebinds or resets a mapping.
-- @author dop42
-- @param listener function
function Keys.OnChanged(listener)
	listeners[#listeners + 1] = listener
end

--- Wires the host's rebind signal, each listener under its own guard.
-- The mappings themselves are declared by the files that own them, which is
-- where the thing the key does lives.
-- @author dop42
function Keys.Start()
	AddEventHandler(M.Host.KEYBINDS_CHANGED, function()
		for index = 1, #listeners do
			local ran, failure = pcall(listeners[index])
			if not ran then Open77.log.error('[admin] keybinds changed: ' .. tostring(failure)) end
		end
	end)
end
