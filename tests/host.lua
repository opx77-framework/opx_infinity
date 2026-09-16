--- A stand-in for the OPEN//77 host, enough to boot the runtime off-platform.
-- @author dop42
--
-- Runs in desktop Lua 5.4, not in the sandbox, so it may use what the sandbox
-- removes. The code under test may not, and `Sandbox` below is what enforces it.

local Host = {}

--- A stand-in for the `MySQL` bridge. `answers` maps a method name to a function
--- of (sql, params); a method that is absent raises, which is what the real
--- bridge does and the whole reason `OPX.Storage` wraps every call.
-- @author dop42
-- @param answers table<string, function>
-- @return table
function Host.Database(answers)
	local bridge = {}
	for _, method in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'transaction' }) do
		bridge[method] = {
			await = function(sql, params)
				local answer = answers[method]
				if answer == nil then error(('no stub for MySQL.%s'):format(method), 0) end
				return answer(sql, params)
			end,
		}
	end
	return bridge
end

--- Builds a fresh environment carrying the globals the platform installs.
-- @author dop42
-- @param side string 'server' or 'client'
-- @param database table|nil the `MySQL` bridge, absent by default
-- @return table env
-- @return table log every line the runtime wrote, by level
function Host.Environment(side, database)
	local log = { debug = {}, info = {}, warn = {}, error = {} }
	local threads = {}
	local handlers = {}
	local commands = {}
	local netEvents = {}
	local clientEvents = {}
	local clock = 0
	-- Forward-declared: the host globals below close over it, and a local declared
	-- after them would leave those closures pointing at a global instead.
	local control

	local Open77 = {
		log = {
			debug = function(line) log.debug[#log.debug + 1] = tostring(line) end,
			info = function(line) log.info[#log.info + 1] = tostring(line) end,
			warn = function(line) log.warn[#log.warn + 1] = tostring(line) end,
			error = function(line) log.error[#log.error + 1] = tostring(line) end,
		},
		time = { monotonic = function() return clock / 1000 end },
		exports = { call = function() return nil, 'no_host' end },

		-- Authoritative state that survives a reload. Answers nothing here, which
		-- is the cold-start case a module has to handle anyway.
		state = { save = function() return true end, load = function() return nil end },

		notifications = { send = function() return true end },

		-- The readiness gate. `hold` answers ONE value -- the session -- or
		-- nil plus a reason, which is the shape the runtime has to handle.
		ready = {
			participate = function() return true end,
			hold = function() return 1 end,
			release = function() return true end,
			status = function() return nil end,
			isReady = function() return false end,
		},

		routingBuckets = {
			setPlayerBucket = function() return true end,
			getPlayerBucket = function() return 0 end,
			setPopulationEnabled = function() return true end,
			setEntityLockdownMode = function() return true end,
		},

		environment = {
			getTime = function() return 0 end,
			setTime = function() return true end,
			setTimeFrozen = function() return true end,
			setWeather = function() return true end,
			setWeatherFrozen = function() return true end,
			isWeatherFrozen = function() return false end,
		},
	}

	Open77.database = database

	local env = {
		Open77 = Open77,
		MySQL = database,

		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		Wait = function() coroutine.yield() end,
		GetGameTimer = function() return clock end,
		GetCurrentResourceName = function() return 'opx-infinity' end,
		GetResourceState = function() return 'stopped' end,

		-- Identity comes from the host and only from the host. `control.Admit`
		-- below is how a test says a slot is occupied.
		GetPlayerIdentifier = function(playerId) return control.accounts[playerId] end,
		GetPlayerName = function(playerId)
			return control.accounts[playerId] and ('player-' .. tostring(playerId)) or nil
		end,

		AddEventHandler = function(name, fn)
			handlers[name] = handlers[name] or {}
			table.insert(handlers[name], fn)
		end,
		TriggerEvent = function(name, ...)
			for _, fn in ipairs(handlers[name] or {}) do fn(...) end
		end,
		RegisterNetEvent = function(name, fn) netEvents[name] = fn end,

		-- A CEF page. `emit` is how a test plays the page: it invokes whatever
		-- the runtime wired to that channel, exactly as the real bridge would.
		WebUI = {
			create = function(spec)
				local page = { spec = spec, sent = {}, handlers = {}, focus = {}, alive = true }
				page.send = function(_, channel, payload)
					page.sent[#page.sent + 1] = { channel = channel, payload = payload }
					return true
				end
				page.on = function(_, channel, handler) page.handlers[channel] = handler end
				page.setFocus = function(_, keyboard, cursor)
					page.focus = { keyboard = keyboard, cursor = cursor }
					return true
				end
				page.hasFocus = function() return page.focus.keyboard or page.focus.cursor end
				page.show = function() page.visible = true; return true end
				page.hide = function() page.visible = false; return true end
				page.destroy = function() page.alive = false; return true end
				control.pages[#control.pages + 1] = page
				return page
			end,
		},
		RegisterCommand = function(name, fn, restricted)
			commands[name] = { run = fn, restricted = restricted == true }
		end,
	}

	if side == 'server' then
		env.TriggerClientEvent = function(name, source, ...)
			clientEvents[#clientEvents + 1] = { name = name, source = source, ... }
		end
	else
		env.TriggerServerEvent = function() end
	end

	env._G = env
	setmetatable(env, { __index = _G })

	-- What the harness hands back to a test.
	control = {
		log = log,
		commands = commands,
		netEvents = netEvents,
		clientEvents = clientEvents,
		handlers = handlers,

		--- Resumes every queued thread up to `rounds` times, so a `while true`
		--- loop in the runtime cannot hang the test.
		Pump = function(rounds)
			for _ = 1, rounds or 40 do
				clock = clock + 100
				local alive = false
				for _, thread in ipairs(threads) do
					if coroutine.status(thread) == 'suspended' then
						alive = true
						local ok, failure = coroutine.resume(thread)
						if not ok then
							log.error[#log.error + 1] = 'thread died: ' .. tostring(failure)
						end
					end
				end
				if not alive then return end
			end
		end,

		-- Slot -> durable account id. Identity comes from the host and only from
		-- the host, so this is the only way a test can make a slot real.
		accounts = {},

		-- Every WebUI page the runtime created, newest last.
		pages = {},

		--- Puts an account on a slot, or clears it when `userId` is nil.
		Admit = function(playerId, userId) control.accounts[playerId] = userId end,

		--- Plays the page: invokes whatever the runtime wired to that channel,
		--- exactly as the real bridge would when the page emits.
		PageEmit = function(page, channel, payload)
			local handler = page and page.handlers[channel]
			if handler then handler(payload) end
		end,

		--- Reports every created page ready. A real page does this once it has
		--- loaded, and nothing can be sent to a surface before it does.
		ReadyPages = function()
			for _, page in ipairs(control.pages) do
				local handler = page.handlers['opx:ready']
				if handler then handler({}) end
			end
		end,

		Fire = function(name, ...)
			for _, fn in ipairs(handlers[name] or {}) do fn(...) end
		end,
	}

	return env, control
end

--- Names the sandbox removes. Loading code that reaches for one is a failure the
--- test should report here rather than on the test server.
Host.Sandbox = { 'io', 'os', 'debug', 'package', 'dofile', 'loadfile', 'require' }

--- Reads the manifest and answers the scripts for one side, in load order.
--- Parsing the real manifest rather than a copy means a file added to the
--- resource and forgotten in the manifest fails here.
-- @author dop42
-- @param path string
-- @param side string 'server' or 'client'
-- @return string[]
function Host.LoadOrder(path, side)
	local wanted = { shared_script = true, [side .. '_script'] = true }
	local files = {}
	for line in io.lines(path) do
		local kind, file = line:match('^%s*([%a_]+)%s+"([^"]+)"')
		if kind and wanted[kind] then files[#files + 1] = file end
	end
	return files
end

return Host
