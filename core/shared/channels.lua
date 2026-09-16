--- Event name prefixes, and the rule that keeps them apart.
-- @author dop42
--
-- The host dispatcher matches on the name and ignores the network flag, so a
-- local `TriggerEvent` re-enters a `RegisterNetEvent` handler of the same name --
-- a silent, tick-paced loop that logs nothing. Three prefixes make that
-- structurally impossible instead of relying on everyone remembering:
--
--   opx:net:<module>:<verb>   crosses the wire, either direction
--   opx:on:<module>:<verb>    client local bus -- public, what UI and third
--                             parties listen to with a bare AddEventHandler
--   opx:in:<module>:<verb>    inside one VM, between modules -- never public
--
-- `Event` builds them so a typo is a nil index rather than a name nobody raises.

OPX.Channel = { NET = 'net', LOCAL = 'on', INTERNAL = 'in' }

local PREFIXES = { net = true, on = true, ['in'] = true }

--- Builds an event name on one of the three channels.
-- @author dop42
-- @param channel string an OPX.Channel value
-- @param module string
-- @param verb string
-- @return string
function OPX.Event(channel, module, verb)
	if not PREFIXES[channel] then
		error(('unknown event channel %q'):format(tostring(channel)), 2)
	end
	return ('opx:%s:%s:%s'):format(channel, module, verb)
end

--- Host-owned names, listed once so there is a single place to change them.
OPX.Host = {
	PLAYER_CONNECTED = 'onPlayerConnected',
	PLAYER_DISCONNECTED = 'onPlayerDisconnected',
	PLAYER_READY = 'onPlayerReady',
	-- The two runtimes name these differently, and using the client pair on the
	-- server registers a handler nothing ever raises.
	CLIENT_RESOURCE_START = 'onClientResourceStart',
	CLIENT_RESOURCE_STOP = 'onClientResourceStop',
	RESOURCE_START = 'onResourceStart',
	RESOURCE_STOP = 'onResourceStop',
	WORLD_READY = 'open77:worldReady',
	GAMEPLAY_READY = 'open77:session:gameplayReady',
	VEHICLE_REMOVED = 'onVehicleRemoved',
	TUNABLE_CHANGED = 'onTunableChanged',
}
