--- Staff commands, their answers and chat suggestions.
-- @author dop42
--
-- Every mutation is a restricted command resolved by the host before the handler
-- runs; no handler checks a permission itself, and no network event mutates the
-- state. Answers travel to this module's client half rather than through
-- `open77:command:result`, which does not print an accepted answer.

local M = OPX.Modules.Get('weather')
local Clock = M.Clock

M.Commands = {}

-- Server to client answer to a staff command.
local EVENT_NOTICE = OPX.Event(OPX.Channel.NET, 'weather', 'notice')

-- Chat suggestion text and parameter help keys per command entry. The
-- `weather.help.*` keys are read through a variable, never as a literal.
local HELP = {
	STATUS = { text = 'weather.help.status', params = {} },
	PRESETS = { text = 'weather.help.presets', params = {} },
	SET = { text = 'weather.help.set', params = {
		{ name = 'preset', help = 'weather.help.set.preset' },
		{ name = 'seconds', help = 'weather.help.set.seconds', optional = true },
	} },
	NEXT = { text = 'weather.help.next', params = {} },
	FREEZE = { text = 'weather.help.freeze', params = {
		{ name = 'on|off', help = 'weather.help.onOff' },
	} },
	TIME = { text = 'weather.help.time', params = {
		{ name = 'HH:MM[:SS]', help = 'weather.help.time.value' },
	} },
	TIME_FREEZE = { text = 'weather.help.timeFreeze', params = {
		{ name = 'on|off', help = 'weather.help.onOff' },
	} },
	DAY_LENGTH = { text = 'weather.help.dayLength', params = {
		{ name = 'minutes', help = 'weather.help.dayLength.minutes' },
	} },
}

-- Catalogue key a player reads for each refusal code. The codes stay codes on
-- the wire and in the log; only the player reads the catalogue.
local ERROR_KEYS = {
	invalid_time = 'weather.error.invalidTime',
	invalid_day_length = 'weather.error.invalidDayLength',
	day_too_short = 'weather.error.dayTooShort',
	unknown_preset = 'weather.error.unknownPreset',
	invalid_transition = 'weather.error.invalidTransition',
	no_presets = 'weather.error.noPresets',
}

-- Commands actually registered, for suggestions and the boot line.
local registered = {}

-- Answers a player through the client half, the console through the log.
local function notice(source, raw, kind, message)
	local player = tonumber(source) or 0
	if player > 0 then
		TriggerClientEvent(EVENT_NOTICE, player, raw or '', kind, message)
		return
	end
	if kind == 'success' or kind == 'report' then
		Open77.log.info(message)
	else
		Open77.log.warn(message)
	end
end

-- Answers a report someone asked to read, as a chat line.
local function answer(source, raw, message)
	notice(source, raw, 'report', message)
end

-- Whether the answer goes to a player rather than the log.
local function toPlayer(source)
	return (tonumber(source) or 0) > 0
end

-- Composes the status line a player reads, from the catalogue.
local function statusLine()
	local status = M.Authority.Status()
	local parts = {
		locale('weather.status', {
			time = ('%02d:%02d:%02d'):format(status.hour, status.minute, status.second),
			minutes = math.floor(status.dayLengthMinutes + 0.5),
			weather = status.weather,
		}),
	}
	if status.timeFrozen then parts[#parts + 1] = locale('weather.status.clockHeld') end
	if status.weatherFrozen then
		parts[#parts + 1] = locale('weather.status.scheduleHeld')
	else
		parts[#parts + 1] = locale('weather.status.nextRoll',
			{ seconds = status.nextRollInSeconds or 0 })
	end
	parts[#parts + 1] = locale('weather.status.revision', { revision = status.revision })
	if not M.Authority.ready then parts[#parts + 1] = locale('weather.status.degraded') end
	return table.concat(parts, ' ')
end

-- Answers a successful action with the new status.
local function accept(source, raw)
	notice(source, raw, 'success',
		toPlayer(source) and statusLine() or M.Authority.StatusText())
end

-- Answers a refusal: catalogue text to a player, English to the log.
local function refuse(source, raw, key, params, console, kind)
	notice(source, raw, kind or 'warning', toPlayer(source) and locale(key, params) or console)
end

-- Refuses with the code a mutator answered; an unknown code reads as unknown.
local function refuseCode(source, raw, code)
	local key = ERROR_KEYS[code]
	local kind = (key == nil or code == 'no_presets') and 'error' or 'warning'
	refuse(source, raw, key or 'weather.error.unknown', nil, tostring(code), kind)
end

-- Counts the typed arguments, trusting a finite whole n: `#args` reads 1 for a
-- single nil, and a NaN n would pass every bound test below.
-- Kept over `OPX.Text.Integer`, which accepts a negative count.
local function count(args)
	if type(args) ~= 'table' then return 0 end
	local given = tonumber(args.n)
	if not Clock.Whole(given, 0) then return #args end
	return given
end

-- Reads on or off and their synonyms, nil for anything else. Kept over
-- `OPX.Text.Switch`, which also accepts yes and no and lowercases first.
local function onOff(value)
	if value == 'on' or value == 'true' or value == '1' then return true end
	if value == 'off' or value == 'false' or value == '0' then return false end
	return nil
end

-- Last run per player and command, for the two-second cooldown. A nested table
-- rather than a built "<player>:<command>" key: Lua 5.4 separates 12 from 12.0,
-- so a float id left a string key that no cleanup pattern ever matched, while
-- in a nested table both reach the same slot and forgetting a player is one
-- assignment. The console is never limited.
local lastCommandMs = {}

-- Whether a player's command falls inside the two-second cooldown.
local function cooled(source, key)
	local player = math.floor(tonumber(source) or 0)
	if player <= 0 then return false end
	local slots = lastCommandMs[player]
	if slots == nil then
		slots = {}
		lastCommandMs[player] = slots
	end
	local atMs = OPX.Now()
	local previous = slots[key]
	if previous ~= nil and atMs - previous < 2000 then return true end
	slots[key] = atMs
	return false
end

-- Registers one configured command, or logs why it does not exist.
-- `floor` is true for a mutation: `RESTRICTED ~= false` on purpose, so that a
-- flag that is absent, misspelled or quoted cannot open a mutation, and an open
-- mutation is reported at boot. Two entries under one name would bind a single
-- ACL key and the second entry's flag with it, so the second is refused.
local function register(key, handler, floor)
	local entry = M.Settings.COMMANDS and M.Settings.COMMANDS[key] or nil
	local name = type(entry) == 'table' and entry.NAME or nil
	if type(name) ~= 'string' or name == '' then
		Open77.log.info(('command %s is off (COMMANDS.%s.NAME)'):format(key, key))
		return
	end

	local restricted
	if floor then
		restricted = entry.RESTRICTED ~= false
		if not restricted then
			Open77.log.warn(('command %s is OPEN to every player (COMMANDS.%s.RESTRICTED = false)')
				:format(name, key))
		end
	else
		restricted = entry.RESTRICTED == true
	end

	for position = 1, #registered do
		local existing = registered[position]
		if existing.name == name then
			Open77.log.error(('command %s is declared twice (COMMANDS.%s and COMMANDS.%s); ' ..
				'%s is NOT registered'):format(name, existing.key, key, key))
			return
		end
	end

	RegisterCommand(name, handler, restricted)
	registered[#registered + 1] = { key = key, name = name, restricted = restricted }
end

-- Reports the synchronized time and weather to the caller.
local function onStatus(source, _, raw)
	if cooled(source, 'status') then return end
	answer(source, raw, toPlayer(source) and statusLine() or M.Authority.StatusText())
end

-- Reports the configured weather presets to the caller. WEIGHT and
-- TRANSITION_SECONDS print with %g: the loader does not round them, and %d
-- raises on a number with no integer form.
local function onPresets(source, _, raw)
	if cooled(source, 'presets') then return end
	local player = toPlayer(source)
	local lines = { player and locale('weather.presets.header')
		or 'weather presets (name / engine preset / weight / seconds):' }
	local presets = M.Authority.Presets()
	for position = 1, #presets do
		local definition = presets[position]
		local row = {
			name = ('%-12s'):format(definition.NAME),
			preset = ('%-26s'):format(definition.PRESET),
			weight = ('%-3s'):format(('%g'):format(definition.WEIGHT)),
			min = definition.MIN_SECONDS,
			max = definition.MAX_SECONDS,
			transition = ('%g'):format(definition.TRANSITION_SECONDS),
		}
		lines[#lines + 1] = player and locale('weather.presets.row', row)
			or ('  %s %s w=%s %d..%ds  transition %ss'):format(
				row.name, row.preset, row.weight, row.min, row.max, row.transition)
	end
	answer(source, raw, table.concat(lines, '\n'))
end

-- Crosses to a preset, with an optional transition length.
local function onSet(source, args, raw)
	local given = count(args)
	if given < 1 or given > 2 then
		return refuse(source, raw, 'weather.usage.set', nil,
			'usage: <preset> [transitionSeconds]')
	end
	local result = M.Authority.SetWeather(args[1], args[2], 'command_set')
	if not result.ok then
		local presets = M.Settings.COMMANDS and (M.Settings.COMMANDS.PRESETS or {}).NAME or nil
		if result.error == 'unknown_preset' and type(presets) == 'string' and presets ~= '' then
			return refuse(source, raw, 'weather.error.presetHint', { command = presets },
				('unknown_preset -- run %s'):format(presets))
		end
		return refuseCode(source, raw, result.error)
	end
	accept(source, raw)
end

-- Rolls the weighted weather table now.
local function onNext(source, args, raw)
	if count(args) ~= 0 then
		return refuse(source, raw, 'weather.usage.next', nil, 'usage: no arguments')
	end
	local result = M.Authority.Roll('command_next')
	if not result.ok then return refuseCode(source, raw, result.error) end
	accept(source, raw)
end

-- Holds or releases the weather roll schedule.
local function onFreeze(source, args, raw)
	local wanted = onOff(args and args[1])
	if count(args) ~= 1 or wanted == nil then
		return refuse(source, raw, 'weather.usage.freeze', nil, 'usage: <on|off>')
	end
	M.Authority.SetWeatherFrozen(wanted, 'command_freeze')
	accept(source, raw)
end

-- Sets the authoritative time of day.
local function onTime(source, args, raw)
	if count(args) ~= 1 then
		return refuse(source, raw, 'weather.usage.time', nil, 'usage: <HH:MM[:SS]>')
	end
	local seconds = Clock.Parse(args[1])
	if seconds == nil then return refuseCode(source, raw, 'invalid_time') end
	M.Authority.SetTime(seconds, 'command_time')
	accept(source, raw)
end

-- Holds or releases the authoritative clock.
local function onTimeFreeze(source, args, raw)
	local wanted = onOff(args and args[1])
	if count(args) ~= 1 or wanted == nil then
		return refuse(source, raw, 'weather.usage.timeFreeze', nil, 'usage: <on|off>')
	end
	M.Authority.SetTimeFrozen(wanted, 'command_time_freeze')
	accept(source, raw)
end

-- Sets how many real minutes a game day takes.
local function onDayLength(source, args, raw)
	if count(args) ~= 1 then
		return refuse(source, raw, 'weather.usage.dayLength', nil, 'usage: <realMinutes>')
	end
	local result = M.Authority.SetDayLength(args[1], 'command_day_length')
	if not result.ok then return refuseCode(source, raw, result.error) end
	accept(source, raw)
end

-- Sends the registered commands to the player as chat suggestions. The preset
-- names come from configuration rather than from a catalogue that would have to
-- repeat them.
local function onChatReady()
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if cooled(player, 'chat_suggestions') then return end

	local presets = M.Authority.Presets()
	local presetNames = {}
	for position = 1, #presets do presetNames[position] = presets[position].NAME end
	local values = { names = #presetNames > 0 and table.concat(presetNames, ', ') or '-' }

	local suggestions = {}
	for position = 1, #registered do
		local command = registered[position]
		local help = HELP[command.key]
		local parameters = {}
		for slot = 1, help and #help.params or 0 do
			local parameter = help.params[slot]
			parameters[slot] = {
				name = parameter.name,
				help = parameter.help and locale(parameter.help, values) or nil,
				optional = parameter.optional == true or nil,
			}
		end
		suggestions[position] = {
			command = '/' .. command.name,
			help = help and locale(help.text) or '',
			parameters = parameters,
		}
	end
	TriggerClientEvent('chat:addSuggestions', player, suggestions)
end

--- Registers every configured command and the chat suggestion handler.
-- Called from the module's `Start` phase, after the authority has adopted its
-- carried state: a command may run the moment it is registered.
-- @author dop42
function M.Commands.Register()
	register('STATUS', onStatus)
	register('PRESETS', onPresets)
	register('SET', onSet, true)
	register('NEXT', onNext, true)
	register('FREEZE', onFreeze, true)
	register('TIME', onTime, true)
	register('TIME_FREEZE', onTimeFreeze, true)
	register('DAY_LENGTH', onDayLength, true)

	RegisterNetEvent('chat:ready', onChatReady)

	-- A departing player's cooldowns. `onPlayerDisconnected` is an admitted
	-- player leaving; a connection refused at the door raises
	-- `onPlayerRejected`, which this module has no reason to hear.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		lastCommandMs[math.floor(tonumber(playerId) or 0)] = nil
	end)

	local names = {}
	for position = 1, #registered do
		local command = registered[position]
		names[position] = command.name .. (command.restricted and ' [acl]' or ' [open]')
	end
	Open77.log.info(('weather commands: %s')
		:format(#names > 0 and table.concat(names, ', ') or 'none'))
end
