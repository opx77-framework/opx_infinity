--- A stand-in for the OPEN//77 host, enough to boot the runtime off-platform.
-- @author dop42
--
-- Runs in desktop Lua 5.4, not in the sandbox, so it may use what the sandbox
-- removes. The code under test may not, and `Sandbox` below is what enforces it.

local Host = {}

--- Builds a fresh environment carrying the globals the platform installs.
-- @author dop42
-- @param side string 'server' or 'client'
-- @return table env
-- @return table log every line the runtime wrote, by level
function Host.Environment(side)
	local log = { debug = {}, info = {}, warn = {}, error = {} }
	local threads = {}
	local handlers = {}
	local commands = {}
	local netEvents = {}
	local clientEvents = {}
	local clock = 0

	local Open77 = {
		log = {
			debug = function(line) log.debug[#log.debug + 1] = tostring(line) end,
			info = function(line) log.info[#log.info + 1] = tostring(line) end,
			warn = function(line) log.warn[#log.warn + 1] = tostring(line) end,
			error = function(line) log.error[#log.error + 1] = tostring(line) end,
		},
		time = { monotonic = function() return clock / 1000 end },
		exports = { call = function() return nil, 'no_host' end },
	}

	local env = {
		Open77 = Open77,

		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		Wait = function() coroutine.yield() end,
		GetGameTimer = function() return clock end,
		GetCurrentResourceName = function() return 'opx-infinity' end,
		GetResourceState = function() return 'stopped' end,

		AddEventHandler = function(name, fn)
			handlers[name] = handlers[name] or {}
			table.insert(handlers[name], fn)
		end,
		TriggerEvent = function(name, ...)
			for _, fn in ipairs(handlers[name] or {}) do fn(...) end
		end,
		RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
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
	local control = {
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
