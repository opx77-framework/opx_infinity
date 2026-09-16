--- Global PvP as the server last announced it, for the World switch and the eye.
-- @author dop42
--
-- This client is told, never asked. The host holds the real switch and the server
-- broadcasts what it accepted; the only outbound message here is the one request
-- a client makes when it started after the last broadcast.

local M = OPX.Modules.Get('admin')

M.Combat = {}
local Combat = M.Combat

-- Whether the server last said damage between players is on.
local pvp = false

--- Whether the server last said damage between players is on.
-- @author dop42
-- @return boolean
function Combat.IsPvp()
	return pvp
end

--- Wires the state event and asks once for the state.
-- @author dop42
function Combat.Start()
	RegisterNetEvent(M.Event.PVP, function(on)
		pvp = on == true
		M.Menu.Refresh()
	end)
	TriggerServerEvent(M.Event.PVP_REQUEST)
end
