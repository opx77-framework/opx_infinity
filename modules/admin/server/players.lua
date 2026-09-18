--- Commands acting on a body or on a session: self, players, moderation.
-- @author dop42
--
-- Every mover here goes through `Server.Place`, which is a kill and a respawn:
-- there is no transform write anywhere in this module, because a transform
-- written on a client that is not incarnated is exactly what the readiness gate
-- exists to stop.
--
-- Kick and ban are the two that do NOT check the gate: a player who never
-- finished joining is precisely the one somebody may need to remove.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit, tell = Server.Answer, Server.Refuse, Server.Audit, Server.Tell
local count = Server.Count

M.Players = {}
local Players = M.Players

-- What a staff kill is attributed to.
local RESOURCE = GetCurrentResourceName()

-- Command that switched noclip and map travel on, per player, so the sweep knows
-- which grant to re-check. Speed is kept so switching noclip back on keeps it.
local noclip, mapPick, speedChosen = {}, {}, {}

-- Players this module hid or froze, so a stop gives the body back, and so a host
-- that cannot answer `isVisible`/`isFrozen` still has an answer.
local hidden, frozen = {}, {}

-- Milliseconds between two sweeps of the travel modes against the ACL.
local SWEEP_MS = 2000

-- Longest disconnect reason the platform accepts, in UTF-8 bytes.
local KICK_REASON_BYTES = 127

-- Seconds per ban duration unit, and the longest timed ban: ten years.
local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }
local MAX_BAN_SECONDS = 3650 * 86400

-- Answers a refused native mutator and keeps its reason in the audit.
local function nativeRefused(source, raw, event, playerId, reason)
	refuse(source, raw, 'refused', { reason = tostring(reason) })
	audit(source, event, false, playerId, 'refused: ' .. tostring(reason))
	return false
end

-- The three typed words as a point within a million, or nil.
local function pointOf(x, y, z)
	x, y, z = Text.Finite(x), Text.Finite(y), Text.Finite(z)
	if x == nil or y == nil or z == nil then return nil end
	if math.abs(x) > 1e6 or math.abs(y) > 1e6 or math.abs(z) > 1e6 then return nil end
	return { x = x, y = y, z = z }
end

-- A player's maximum health in absolute points, and the raw reading.
local function healthOf(playerId)
	local read, health = pcall(Open77.players.getHealth, playerId)
	if not read or type(health) ~= 'table' then return 100.0, nil end
	local maximum = Text.Finite(health.maxHealth)
	if maximum == nil or maximum <= 0 then maximum = 100.0 end
	return maximum, health
end

-- One of the host's boolean player readers, nil when it cannot say.
local function readFlag(reader, playerId)
	local read, value = pcall(Open77.players[reader], playerId)
	if not read or type(value) ~= 'boolean' then return nil end
	return value
end

-- Sends one travel instruction to a player's client half.
local function travel(playerId, action, value)
	TriggerClientEvent(M.Event.TRAVEL, playerId, action, value)
end

-- The configured starting noclip speed, inside the native's 0.1..500.
local function defaultSpeed()
	return M.Bounded('NOCLIP.SPEED', M.Section('NOCLIP').SPEED, 0.1, 500, 40.0)
end

-- Switches a player's noclip, sending the starting speed the first time.
local function setNoclip(playerId, on, grant)
	noclip[playerId] = on and grant or nil
	travel(playerId, 'noclip', on == true)
	if on and speedChosen[playerId] == nil then travel(playerId, 'speed', defaultSpeed()) end
end

--- Whether this module has noclip on for a player, for the eye's checkbox.
-- @author dop42
-- @param playerId Source
-- @return boolean
function Players.IsNoclip(playerId)
	return noclip[playerId] ~= nil
end

--- Sends one staff client the body states behind its checkboxes: whether its own
--- body is hidden, the ids of the players held still, and the ped each player
--- wearing one is wearing.
-- The host readers come first and this module's own marks are the fallback, so a
-- build that cannot answer `isFrozen` still draws the right box.
--
-- `frozen` and `worn` are both LISTS rather than maps keyed by player id: an
-- empty table may not survive the trip, and a map of integer keys is not the
-- shape the wire keeps. None reads as nobody held and nobody wearing, which is
-- the truthful answer either way.
-- @author dop42
-- @param playerId Source
-- @param departed Source|nil a player leaving right now, left off the lists
function Players.PushBodies(playerId, departed)
	if playerId <= 0 then return end
	local visible = readFlag('isVisible', playerId)
	local held, worn = {}, {}
	for _, id in ipairs(Server.PlayerIds()) do
		if id ~= departed then
			local still = readFlag('isFrozen', id)
			if still == nil then still = frozen[id] == true end
			if still then held[#held + 1] = id end
			local ped = M.Models.Worn(id)
			if ped ~= nil then worn[#worn + 1] = { id = id, ped = ped } end
		end
	end
	local invisible
	if visible == nil then invisible = hidden[playerId] == true else invisible = not visible end
	-- The operator's own ped travels beside the list rather than inside it: the
	-- menu draws a row for it before the roster has named this client to itself.
	TriggerClientEvent(M.Event.BODIES, playerId, { invisible = invisible, frozen = held,
		worn = worn, wornSelf = M.Models.Worn(playerId), models = M.Models.Available() })
end

-- Sends the body states to every client the ACL grants one of the commands the
-- states are drawn for.
local function pushBodiesToStaff(departed)
	for _, id in ipairs(Server.PlayerIds()) do
		if id ~= departed and (Server.Permitted(id, Command.PLAYER_FREEZE) == true
			or Server.Permitted(id, Command.PLAYER_MODEL) == true) then
			Players.PushBodies(id, departed)
		end
	end
end

--- Sends the body states to every staff client. The seam `server/models.lua`
--- redraws the checkboxes through after a ped goes on or comes off.
-- @author dop42
-- @param departed Source|nil a player leaving right now, left off the lists
function Players.PushToStaff(departed)
	pushBodiesToStaff(departed)
end

-- Heals a player to their maximum health, audited and answered.
local function heal(source, raw, playerId, event)
	if not Server.Admitted(source, raw, playerId, event) then return end
	local maximum = healthOf(playerId)
	local ok, reason = Open77.players.setHealth(playerId, maximum)
	if not ok then return nativeRefused(source, raw, event, playerId, reason) end
	audit(source, event, true, playerId, ('%.0f'):format(maximum))
	if playerId ~= source then tell(playerId, 'admin.toast.healed', nil, 'success') end
	answer(source, raw, true, 'admin.done.healed',
		{ id = playerId, name = Server.LabelOf(playerId) or '?' })
end

-- Revives a player where they lie, through `downed` when it is running so that
-- its own screen closes with them, and through the host otherwise.
local function revive(source, raw, playerId, event)
	if not Server.Admitted(source, raw, playerId, event) then return end
	local ok, reason

	local downed = Server.Contract('downed')
	if downed ~= nil then
		local result = downed.Revive(playerId, M.OWNER)
		ok = result.ok
		reason = result.error
		-- `not_down` is not a refusal here: a player who is already up is the
		-- answer the operator wanted, and the host revive below is a no-op.
		if not ok and reason ~= 'not_down' then
			return nativeRefused(source, raw, event, playerId, reason)
		end
		ok = true
	else
		ok, reason = Open77.players.revive(playerId, Server.Recovery())
		if not ok then return nativeRefused(source, raw, event, playerId, reason) end
	end

	audit(source, event, true, playerId)
	if playerId ~= source then tell(playerId, 'admin.toast.revived', nil, 'success') end
	answer(source, raw, true, 'admin.done.revived',
		{ id = playerId, name = Server.LabelOf(playerId) or '?' })
end

-- Switches a player's god mode, toggling when no word is typed.
local function god(source, raw, playerId, word, event)
	local wanted, invalid = Text.Switch(word)
	if invalid then return refuse(source, raw, 'bad_switch') end
	if not Server.Admitted(source, raw, playerId, event) then return end
	if wanted == nil then
		local _, health = healthOf(playerId)
		wanted = not (health ~= nil and health.godMode == true)
	end
	local ok, reason = Open77.players.setGodMode(playerId, wanted)
	if not ok then return nativeRefused(source, raw, event, playerId, reason) end
	audit(source, event, true, playerId, wanted and 'on' or 'off')
	if playerId ~= source then
		tell(playerId, wanted and 'admin.toast.godOn' or 'admin.toast.godOff')
	end
	answer(source, raw, true, wanted and 'admin.done.godOn' or 'admin.done.godOff',
		{ id = playerId, name = Server.LabelOf(playerId) or '?' })
end

-- Where to land beside a player, and the bucket they are in.
local function beside(playerId)
	local position = Server.PositionOf(playerId)
	if position == nil then return nil, nil end
	local offset = M.Section('PLACEMENT').BESIDE or {}
	return {
		x = position.x + Server.Setting(offset.X, 1.5),
		y = position.y + Server.Setting(offset.Y, 0.0),
		z = position.z + Server.Setting(offset.Z, 0.0),
	}, position.bucket
end

-- A typed ban duration in seconds, false for permanent, nil for anything else.
local function duration(token)
	if type(token) ~= 'string' then return nil end
	local word = token:lower()
	if word == 'perm' or word == 'permanent' then return false end
	local amount, unit = word:match('^(%d+)([smhd])$')
	if amount == nil then return nil end
	local seconds = tonumber(amount) * UNITS[unit]
	if seconds <= 0 or seconds > MAX_BAN_SECONDS then return nil end
	return seconds
end

--- Registers every command of this file, and the passes behind the travel modes.
-- @author dop42
function Players.Register()
	Server.Command(Command.SELF_NOCLIP, {
		help = 'admin.help.noclip',
		params = { { name = 'on|off', help = 'admin.help.toggle', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			local wanted, invalid = Text.Switch(args[1])
			if invalid then return refuse(source, raw, 'bad_switch') end
			if wanted == nil then wanted = noclip[source] == nil end
			setNoclip(source, wanted, Command.SELF_NOCLIP)
			audit(source, 'admin.self.noclip', true, nil, wanted and 'on' or 'off')
			answer(source, raw, true, wanted and 'admin.done.noclipOn' or 'admin.done.noclipOff')
		end,
	})

	Server.Command(Command.SELF_SPEED, {
		help = 'admin.help.speed', params = { { name = 'm/s', help = 'admin.help.speedValue' } },
		inGame = true,
		handler = function(source, args, raw)
			local speed = Text.Finite(args[1])
			if count(args) ~= 1 or speed == nil or speed < 0.1 or speed > 500 then
				return answer(source, raw, false, 'admin.usage.speed')
			end
			speedChosen[source] = speed
			travel(source, 'speed', speed)
			audit(source, 'admin.self.speed', true, nil, ('%.1f'):format(speed))
			answer(source, raw, true, 'admin.done.speed', { speed = ('%.1f'):format(speed) })
		end,
	})

	Server.Command(Command.SELF_MAPTRAVEL, {
		help = 'admin.help.maptravel',
		params = { { name = 'on|off|x', help = 'admin.help.maptravelValue', optional = true },
			{ name = 'y', help = 'admin.help.maptravelPoint', optional = true },
			{ name = 'z', help = 'admin.help.maptravelPoint', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			if count(args) == 3 then
				local point = pointOf(args[1], args[2], args[3])
				if point == nil then return refuse(source, raw, 'bad_coordinates') end
				local placed, code, reason = Server.Place(source, point, 0.0, nil, 'maptravel')
				audit(source, 'admin.self.maptravel', placed, source,
					('%.0f %.0f %.0f %s'):format(point.x, point.y, point.z, code or ''))
				if not placed then return refuse(source, raw, code, { reason = reason }) end
				return answer(source, raw, true, 'admin.done.moved',
					{ x = ('%.1f'):format(point.x), y = ('%.1f'):format(point.y),
						z = ('%.1f'):format(point.z) })
			end
			local wanted, invalid = Text.Switch(args[1])
			if invalid or count(args) > 1 then
				return answer(source, raw, false, 'admin.usage.maptravel')
			end
			if wanted == nil then wanted = mapPick[source] == nil end
			mapPick[source] = wanted and Command.SELF_MAPTRAVEL or nil
			travel(source, 'mapPick', wanted)
			audit(source, 'admin.self.maptravel', true, nil, wanted and 'on' or 'off')
			answer(source, raw, true, wanted and 'admin.done.mapOn' or 'admin.done.mapOff')
		end,
	})

	Server.Command(Command.SELF_HEAL, {
		help = 'admin.help.selfHeal', inGame = true,
		handler = function(source, _, raw) heal(source, raw, source, 'admin.self.heal') end,
	})

	Server.Command(Command.SELF_REVIVE, {
		help = 'admin.help.selfRevive', inGame = true,
		handler = function(source, _, raw) revive(source, raw, source, 'admin.self.revive') end,
	})

	Server.Command(Command.SELF_GOD, {
		help = 'admin.help.selfGod',
		params = { { name = 'on|off', help = 'admin.help.toggle', optional = true } },
		inGame = true,
		handler = function(source, args, raw) god(source, raw, source, args[1], 'admin.self.god') end,
	})

	Server.Command(Command.SELF_INVISIBLE, {
		help = 'admin.help.invisible',
		params = { { name = 'on|off', help = 'admin.help.toggle', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			local wanted, invalid = Text.Switch(args[1])
			if invalid then return refuse(source, raw, 'bad_switch') end
			if wanted == nil then
				local visible = readFlag('isVisible', source)
				if visible == nil then visible = hidden[source] == nil end
				wanted = visible
			end
			local ok, reason = Open77.players.setVisible(source, not wanted)
			if not ok then return nativeRefused(source, raw, 'admin.self.invisible', source, reason) end
			hidden[source] = wanted or nil
			Players.PushBodies(source)
			audit(source, 'admin.self.invisible', true, nil, wanted and 'on' or 'off')
			answer(source, raw, true, wanted and 'admin.done.invisibleOn' or 'admin.done.invisibleOff')
		end,
	})

	Server.Command(Command.PLAYER_FREEZE, {
		help = 'admin.help.freeze',
		params = { { name = 'playerId', help = 'admin.help.playerId' },
			{ name = 'on|off', help = 'admin.help.toggle', optional = true } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			local wanted, invalid = Text.Switch(args[2])
			if invalid then return refuse(source, raw, 'bad_switch') end
			if not Server.Admitted(source, raw, playerId, 'admin.player.freeze') then return end
			if wanted == nil then
				local held = readFlag('isFrozen', playerId)
				if held == nil then held = frozen[playerId] == true end
				wanted = not held
			end
			local ok, reason = Open77.players.setFrozen(playerId, wanted)
			if not ok then return nativeRefused(source, raw, 'admin.player.freeze', playerId, reason) end
			frozen[playerId] = wanted or nil
			pushBodiesToStaff()
			audit(source, 'admin.player.freeze', true, playerId, wanted and 'on' or 'off')
			if playerId ~= source then
				tell(playerId, wanted and 'admin.toast.frozen' or 'admin.toast.unfrozen', nil, 'warning')
			end
			answer(source, raw, true, wanted and 'admin.done.frozen' or 'admin.done.unfrozen',
				{ id = playerId, name = Server.LabelOf(playerId) or '?' })
		end,
	})

	Server.Command(Command.SELF_POS, {
		help = 'admin.help.pos', inGame = true, read = true,
		handler = function(source, _, raw)
			local position = Server.PositionOf(source)
			if position == nil then return refuse(source, raw, 'no_position') end
			local row = ('{ NAME = "here", LABEL = "Here", X = %.2f, Y = %.2f, Z = %.2f, HEADING = 0.0 },')
				:format(position.x, position.y, position.z)
			travel(source, 'copy', row)
			answer(source, raw, true, 'admin.done.pos', { row = row, bucket = position.bucket })
		end,
	})

	Server.Command(Command.PLAYER_GOTO, {
		help = 'admin.help.goto', params = { { name = 'playerId', help = 'admin.help.playerId' } },
		inGame = true,
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if playerId == source then return refuse(source, raw, 'self_target') end
			if not Server.Admitted(source, raw, playerId, 'admin.player.goto') then return end
			local point, bucket = beside(playerId)
			if point == nil then return refuse(source, raw, 'no_position') end
			local placed, code, reason = Server.Place(source, point, 0.0, bucket, 'goto')
			audit(source, 'admin.player.goto', placed, playerId, code)
			if not placed then return refuse(source, raw, code, { reason = reason }) end
			answer(source, raw, true, 'admin.done.goto',
				{ id = playerId, name = Server.LabelOf(playerId) or '?', bucket = bucket })
		end,
	})

	Server.Command(Command.PLAYER_BRING, {
		help = 'admin.help.bring', params = { { name = 'playerId', help = 'admin.help.playerId' } },
		inGame = true,
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if playerId == source then return refuse(source, raw, 'self_target') end
			local point, bucket = beside(source)
			if point == nil then return refuse(source, raw, 'no_position') end
			local placed, code, reason = Server.Place(playerId, point, 0.0, bucket, 'bring')
			audit(source, 'admin.player.bring', placed, playerId, code)
			if not placed then return refuse(source, raw, code, { reason = reason, id = playerId }) end
			tell(playerId, 'admin.toast.brought')
			answer(source, raw, true, 'admin.done.bring',
				{ id = playerId, name = Server.LabelOf(playerId) or '?' })
		end,
	})

	Server.Command(Command.PLAYER_TP, {
		help = 'admin.help.tp',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'x', help = 'admin.help.coordinate' },
			{ name = 'y', help = 'admin.help.coordinate' },
			{ name = 'z', help = 'admin.help.coordinate' },
			{ name = 'heading', help = 'admin.help.heading', optional = true } },
		handler = function(source, args, raw)
			local given = count(args)
			if given < 4 or given > 5 then return answer(source, raw, false, 'admin.usage.tp') end
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			local point = pointOf(args[2], args[3], args[4])
			local heading = 0.0
			if given == 5 then heading = Text.Finite(args[5]) end
			if point == nil or heading == nil then return refuse(source, raw, 'bad_coordinates') end
			local placed, code, reason = Server.Place(playerId, point, heading, nil, 'tp')
			audit(source, 'admin.player.tp', placed, playerId,
				('%.0f %.0f %.0f %s'):format(point.x, point.y, point.z, code or ''))
			if not placed then return refuse(source, raw, code, { reason = reason, id = playerId }) end
			if playerId ~= source then tell(playerId, 'admin.toast.moved') end
			answer(source, raw, true, 'admin.done.moved',
				{ x = ('%.1f'):format(point.x), y = ('%.1f'):format(point.y),
					z = ('%.1f'):format(point.z) })
		end,
	})

	Server.Command(Command.PLAYER_OBSERVE, {
		help = 'admin.help.observe', params = { { name = 'playerId', help = 'admin.help.playerId' } },
		inGame = true,
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if playerId == source then return refuse(source, raw, 'self_target') end
			if not Server.Admitted(source, raw, playerId, 'admin.player.observe') then return end
			local position = Server.PositionOf(playerId)
			if position == nil then return refuse(source, raw, 'no_position') end
			local height = Server.Setting(M.Section('PLACEMENT').OBSERVE_HEIGHT, 2.0)
			local placed, code, reason = Server.Place(source,
				{ x = position.x, y = position.y, z = position.z + height }, 0.0, position.bucket,
				'observe')
			audit(source, 'admin.player.observe', placed, playerId, code)
			if not placed then return refuse(source, raw, code, { reason = reason }) end
			setNoclip(source, true, Command.PLAYER_OBSERVE)
			answer(source, raw, true, 'admin.done.observe',
				{ id = playerId, name = Server.LabelOf(playerId) or '?' })
		end,
	})

	Server.Command(Command.PLAYER_HEAL, {
		help = 'admin.help.heal', params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId then heal(source, raw, playerId, 'admin.player.heal') end
		end,
	})

	Server.Command(Command.PLAYER_REVIVE, {
		help = 'admin.help.revive',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId then revive(source, raw, playerId, 'admin.player.revive') end
		end,
	})

	Server.Command(Command.PLAYER_GOD, {
		help = 'admin.help.god',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'on|off', help = 'admin.help.toggle', optional = true } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId then god(source, raw, playerId, args[2], 'admin.player.god') end
		end,
	})

	Server.Command(Command.PLAYER_KILL, {
		help = 'admin.help.kill', params = { { name = 'playerId', help = 'admin.help.playerId' } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if not Server.Admitted(source, raw, playerId, 'admin.player.kill') then return end
			local ok, reason = Open77.players.kill(playerId, {
				killer = source > 0 and source or nil,
				cause = 'script',
				weapon = RESOURCE .. ':kill',
			})
			if not ok then return nativeRefused(source, raw, 'admin.player.kill', playerId, reason) end
			audit(source, 'admin.player.kill', true, playerId)
			tell(playerId, 'admin.toast.killed', nil, 'warning')
			answer(source, raw, true, 'admin.done.killed',
				{ id = playerId, name = Server.LabelOf(playerId) or '?' })
		end,
	})

	Server.Command(Command.PLAYER_HEALTH, {
		help = 'admin.help.health',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'points', help = 'admin.help.healthPoints' } },
		handler = function(source, args, raw)
			local value = Text.Finite(args[2])
			if count(args) ~= 2 or value == nil or value < 0 then
				return answer(source, raw, false, 'admin.usage.health')
			end
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if not Server.Admitted(source, raw, playerId, 'admin.player.health') then return end
			local maximum = healthOf(playerId)
			value = math.min(value, maximum)
			local ok, reason = Open77.players.setHealth(playerId, value)
			if not ok then return nativeRefused(source, raw, 'admin.player.health', playerId, reason) end
			audit(source, 'admin.player.health', true, playerId, ('%.0f/%.0f'):format(value, maximum))
			answer(source, raw, true, 'admin.done.health',
				{ id = playerId, value = ('%.0f'):format(value), maximum = ('%.0f'):format(maximum) })
		end,
	})

	Server.Command(Command.PLAYER_ARMOR, {
		help = 'admin.help.armor',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'points', help = 'admin.help.armorPoints' } },
		handler = function(source, args, raw)
			local value = Text.Finite(args[2])
			if count(args) ~= 2 or value == nil or value < 0 or value > 10000 then
				return answer(source, raw, false, 'admin.usage.armor')
			end
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			if not Server.Admitted(source, raw, playerId, 'admin.player.armor') then return end
			local ok, reason = Open77.players.setArmor(playerId, value)
			if not ok then return nativeRefused(source, raw, 'admin.player.armor', playerId, reason) end
			audit(source, 'admin.player.armor', true, playerId, ('%.0f'):format(value))
			answer(source, raw, true, 'admin.done.armor',
				{ id = playerId, value = ('%.0f'):format(value) })
		end,
	})

	Server.Command(Command.MODERATE_KICK, {
		help = 'admin.help.kick',
		params = { { name = 'playerId', help = 'admin.help.playerId' },
			{ name = 'reason', help = 'admin.help.reason', optional = true } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			local reason = M.Trimmed(Text.Rest(args, 2), 200) or locale('admin.kick.defaultReason')
			-- Cut in bytes, not characters: the platform's limit is on the wire.
			reason = Text.Bytes(reason, KICK_REASON_BYTES)
			local name = Server.LabelOf(playerId) or '?'
			local ok, failure = Open77.players.kick(playerId, reason)
			if not ok then return nativeRefused(source, raw, 'admin.moderate.kick', playerId, failure) end
			audit(source, 'admin.moderate.kick', true, playerId, ('%s: %s'):format(name, reason))
			answer(source, raw, true, 'admin.done.kicked', { id = playerId, name = name, reason = reason })
		end,
	})

	Server.Command(Command.MODERATE_BAN, {
		help = 'admin.help.ban',
		params = { { name = 'playerId', help = 'admin.help.playerId' },
			{ name = 'duration', help = 'admin.help.banDuration', optional = true },
			{ name = 'reason', help = 'admin.help.reason', optional = true } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end

			local seconds, reasonFrom = nil, 2
			local parsed = duration(args[2])
			if parsed == false then
				reasonFrom = 3
			elseif parsed ~= nil then
				seconds, reasonFrom = parsed, 3
			elseif type(args[2]) == 'string' and args[2]:lower():match('^%-?%d+[smhd]$') then
				-- It looks like a duration and is out of range, so it is not the
				-- first word of a reason.
				return refuse(source, raw, 'bad_duration')
			end

			local access = Open77.access
			if type(access) ~= 'table' or type(access.ban) ~= 'function' then
				return refuse(source, raw, 'refused', { reason = 'access_unavailable' })
			end
			-- The ban is on the ACCOUNT, not the slot: a player id is recycled.
			local identifier = Server.UserOf(playerId)
			if identifier == nil then return refuse(source, raw, 'refused', { reason = 'no_identity' }) end

			local reason = M.Trimmed(Text.Rest(args, reasonFrom), 200)
				or locale('admin.ban.defaultReason')
			local name = Server.LabelOf(playerId) or '?'
			local ok, failure = access.ban(identifier, reason, seconds, name)
			if not ok then return nativeRefused(source, raw, 'admin.moderate.ban', playerId, failure) end
			audit(source, 'admin.moderate.ban', true, playerId,
				('%s %s: %s'):format(name, seconds and (seconds .. 's') or 'permanent', reason))
			answer(source, raw, true, seconds and 'admin.done.banned' or 'admin.done.bannedForever',
				{ id = playerId, name = name, reason = reason,
					hours = seconds and ('%.1f'):format(seconds / 3600) or '' })
		end,
	})

	-- A travel mode is not a command, so nothing re-resolves its grant on its
	-- own: a staff member whose grant is taken away mid-session would keep
	-- flying. `OPX.Scheduler` is the client's loop; the server VM has none, so
	-- this keeps its own thread and each pass is guarded.
	CreateThread(function()
		while true do
			Wait(SWEEP_MS)
			local swept, failure = pcall(function()
				for playerId, grant in pairs(noclip) do
					if Server.Permitted(playerId, grant) == false then
						setNoclip(playerId, false)
						Open77.log.info(('[admin] noclip off for player %d: %s is no longer granted')
							:format(playerId, grant))
					end
				end
				for playerId, grant in pairs(mapPick) do
					if Server.Permitted(playerId, grant) == false then
						mapPick[playerId] = nil
						travel(playerId, 'mapPick', false)
					end
				end
			end)
			if not swept then Open77.log.warn('[admin] travel sweep failed: ' .. tostring(failure)) end
		end
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId) or 0
		noclip[player], mapPick[player], speedChosen[player] = nil, nil, nil
		local wasFrozen = frozen[player] ~= nil
		local wasWorn = M.Models.Worn(player) ~= nil
		hidden[player], frozen[player] = nil, nil
		M.Models.Forget(player)
		-- A departing player must come off every staff member's checkbox, and the
		-- list is built without them: their slot may already belong to somebody.
		if wasFrozen or wasWorn then pushBodiesToStaff(player) end
	end)
end

--- Switches off every travel mode this module armed, and gives back every body
--- it hid or held. Best effort: a stop is not a place to refuse.
-- @author dop42
function Players.Release()
	for playerId in pairs(noclip) do travel(playerId, 'noclip', false) end
	for playerId in pairs(mapPick) do travel(playerId, 'mapPick', false) end
	for playerId in pairs(hidden) do pcall(Open77.players.setVisible, playerId, true) end
	for playerId in pairs(frozen) do pcall(Open77.players.setFrozen, playerId, false) end
	noclip, mapPick, speedChosen, hidden, frozen = {}, {}, {}, {}, {}
end
