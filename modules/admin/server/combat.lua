--- Global player-versus-player damage: on at start from COMBAT.PVP, switched by
--- staff.
-- @author dop42
--
-- The host holds the real switch and this module holds only what it last
-- accepted, which is what the menu row and the eye's checkbox read. A client is
-- never asked what the state is: it is told.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit

M.Combat = {}
local Combat = M.Combat

-- Whether the host last accepted PvP on.
local pvp = false

-- Switches global PvP on the host and tells every client the result.
local function apply(on)
	local combat = Open77.combat
	if type(combat) ~= 'table' or type(combat.setFriendlyFire) ~= 'function' then
		return false, 'combat_unavailable'
	end
	local called, ok, reason = pcall(combat.setFriendlyFire, on == true)
	if not called then return false, tostring(ok) end
	if ok ~= true then return false, tostring(reason or 'refused') end
	pvp = on == true
	TriggerClientEvent(M.Event.PVP, -1, pvp)
	return true
end

--- Registers the switch command and applies the configured state at start.
-- @author dop42
function Combat.Register()
	Server.Command(Command.WORLD_PVP, {
		help = 'admin.help.pvp',
		params = { { name = 'on|off', help = 'admin.help.toggle', optional = true } },
		handler = function(source, args, raw)
			local wanted, invalid = Text.Switch(args[1])
			if invalid then return refuse(source, raw, 'bad_switch') end
			if wanted == nil then wanted = not pvp end
			local ok, reason = apply(wanted)
			if not ok then
				audit(source, 'admin.world.pvp', false, nil, tostring(reason))
				return refuse(source, raw, reason == 'combat_unavailable' and 'combat_unavailable'
					or 'refused', { reason = reason })
			end
			audit(source, 'admin.world.pvp', true, nil, wanted and 'on' or 'off')
			answer(source, raw, true, wanted and 'admin.done.pvpOn' or 'admin.done.pvpOff')
		end,
	})

	-- A client that started after the broadcast asks once for the state.
	RegisterNetEvent(M.Event.PVP_REQUEST, function()
		local playerId = tonumber(source) or 0
		if playerId <= 0 or Server.Cooled(playerId, 'pvp:request', 1000) then return end
		TriggerClientEvent(M.Event.PVP, playerId, pvp)
	end)

	-- On a thread: the host bindings may not be installed at the moment the
	-- module starts, and this must not be what stops it coming up.
	CreateThread(function()
		local wanted = M.Section('COMBAT').PVP ~= false
		local ok, reason = apply(wanted)
		if not ok then
			Open77.log.error(('[admin] PvP could not be switched %s at start: %s')
				:format(wanted and 'on' or 'off', tostring(reason)))
			return
		end
		Open77.log.info(('[admin] PvP %s at start (COMBAT.PVP)'):format(wanted and 'on' or 'off'))
	end)
end
