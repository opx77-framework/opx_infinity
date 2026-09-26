--- Client half: the one key, the waypoint it reads, and nothing else.
-- @author XEROX710
--
-- THE KEY IS THE WHOLE SURFACE. There is no row, no marker and no menu: a
-- pilot presses the binding, this file reads the pilot's own map waypoint and
-- hands the destination to the server, and every word the pilot reads after
-- that is a toast the server chose. The server re-derives the seat, the hull
-- and the record from the connection, so nothing here is a claim -- the
-- payload is the destination and the honest flag saying the map could not be
-- read, and nothing more.
--
-- `nil` AND `nil, reason` ARE DIFFERENT ANSWERS, and the wiki says so in as
-- many words: the first is "no waypoint is set" and the second is "the
-- question could not be asked". A pilot who dropped no pin is told to drop
-- one; a host whose map read is broken is told it is broken. Collapsing them
-- would send a player to the map to fix a server.
--
-- NO MENU GATE, unlike the crew door's key. A key pressed with the map open is
-- the NORMAL case here -- the pin was just placed -- and the platform's own
-- flight input is separately gated on menus and consoles.

local M = OPX.Modules.Get('avdrive')

--- Reads the pilot's map waypoint through the platform's own blip read.
-- @return table|nil `{ x, y, z }`
-- @return boolean whether the read itself failed, rather than no pin being set
local function waypoint()
	local api = type(Open77) == 'table' and Open77.blips or nil
	if type(api) ~= 'table' or type(api.waypoint) ~= 'function' then
		return nil, true
	end
	local read, point, reason = pcall(api.waypoint)
	if not read then return nil, true end
	if type(point) ~= 'table' then
		-- A bare nil is no waypoint; a nil WITH a reason is a question the
		-- host could not answer. They name two different toasts.
		return nil, reason ~= nil
	end
	local x, y, z = tonumber(point.x), tonumber(point.y), tonumber(point.z)
	if x == nil or y == nil or z == nil then return nil, true end
	return { x = x, y = y, z = z }, false
end

--- The one press: read the pin, hand it over. The OFF half of the toggle needs
--- no destination at all -- a payload with no position still reaches the
--- server, and a run in flight is cancelled by the press whatever the payload
--- says.
local function toggle()
	local position, unreadable = waypoint()
	TriggerServerEvent(M.Event.TOGGLE, {
		position = position,
		unreadable = unreadable == true,
	})
end

--- Declares the binding. The name is translated at registration and the id is
--- stable, because a player's rebind is stored under the id.
-- @author XEROX710
function M.Start()
	local declared = type(M.Settings) == 'table' and M.Settings.KEY or nil
	if type(declared) ~= 'table' or declared.DEFAULT == false then return end
	if type(RegisterKeyMapping) ~= 'function' then
		Open77.log.warn('[avdrive] this host has no RegisterKeyMapping: the autopilot has no key')
		return
	end
	if type(declared.ID) ~= 'string' or type(declared.NAME) ~= 'string'
		or type(declared.DEFAULT) ~= 'string' then
		Open77.log.warn('[avdrive] KEY is not a table of ID, NAME and DEFAULT: the autopilot has no key')
		return
	end

	local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
		declared.DEFAULT, function()
			local ran, failure = pcall(toggle)
			if not ran then
				Open77.log.error(('[avdrive] key %s: %s'):format(declared.ID, tostring(failure)))
			end
		end)
	-- Two answer shapes are documented for `RegisterKeyMapping`: the effective
	-- key, or `true, key`. Reading only the second logged a working mapping as
	-- refused.
	local effective = nil
	if called then
		effective = type(ok) == 'string' and ok ~= '' and ok
			or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	end
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[avdrive] key mapping %s (%s) not registered: %s')
			:format(declared.ID, tostring(declared.DEFAULT),
				tostring(called and answer or ok)))
	end
end
