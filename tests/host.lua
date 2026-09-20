--- A stand-in for the OPEN//77 host, enough to boot the runtime off-platform.
-- @author dop42
--
-- Runs in desktop Lua 5.4, not in the sandbox, so it may use what the sandbox
-- removes. The code under test may not, and `Sandbox` below is what enforces it.

local Host = {}

--- The sandbox installs a `json` global, and every JSON column binding goes
--- through it. A stub that only pretended to encode would let a round-trip bug
--- pass, so this one really encodes and really decodes its own output.
--
-- An empty Lua table encodes as `{}`, not `[]` -- the same asymmetry the pages
-- have to guard against, and the reason the runtime's decoders never trust `#`.
local json = {}

local function encodeValue(value, out)
	local kind = type(value)
	if value == nil then
		out[#out + 1] = 'null'
	elseif kind == 'boolean' then
		out[#out + 1] = tostring(value)
	elseif kind == 'number' then
		-- NaN and the infinities are not JSON. They arrive from clients and the
		-- runtime is expected to reject them before they reach a column.
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = 'null'
		else
			out[#out + 1] = (value % 1 == 0) and ('%d'):format(value) or ('%.14g'):format(value)
		end
	elseif kind == 'string' then
		out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(char)
			local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
				['\t'] = '\\t' }
			return escapes[char] or ('\\u%04x'):format(char:byte())
		end) .. '"'
	elseif kind == 'table' then
		local count = 0
		for _ in pairs(value) do count = count + 1 end
		if count > 0 and count == #value then
			out[#out + 1] = '['
			for index = 1, count do
				if index > 1 then out[#out + 1] = ',' end
				encodeValue(value[index], out)
			end
			out[#out + 1] = ']'
		else
			-- Keys sorted: two encodings of the same table must compare equal,
			-- which is what lets a caller skip a write when nothing changed.
			local keys = {}
			for key in pairs(value) do keys[#keys + 1] = tostring(key) end
			table.sort(keys)
			out[#out + 1] = '{'
			for index = 1, #keys do
				if index > 1 then out[#out + 1] = ',' end
				encodeValue(keys[index], out)
				out[#out + 1] = ':'
				encodeValue(value[keys[index]] or value[tonumber(keys[index])], out)
			end
			out[#out + 1] = '}'
		end
	else
		out[#out + 1] = 'null'
	end
end

function json.encode(value)
	local out = {}
	encodeValue(value, out)
	return table.concat(out)
end

local decodeValue

local function skip(text, at)
	return text:find('[^ \t\r\n]', at) or #text + 1
end

function decodeValue(text, at)
	at = skip(text, at)
	local char = text:sub(at, at)

	if char == '{' or char == '[' then
		local isArray = char == '['
		local closer = isArray and ']' or '}'
		local out, index = {}, 0
		at = skip(text, at + 1)
		if text:sub(at, at) == closer then return out, at + 1 end
		while true do
			local key
			if isArray then
				index = index + 1
				key = index
			else
				key, at = decodeValue(text, at)
				at = skip(text, at)
				if text:sub(at, at) ~= ':' then return nil, at end
				at = at + 1
			end
			out[key], at = decodeValue(text, at)
			at = skip(text, at)
			local next = text:sub(at, at)
			if next == closer then return out, at + 1 end
			if next ~= ',' then return nil, at end
			at = skip(text, at + 1)
		end
	elseif char == '"' then
		local out, index = {}, at + 1
		while index <= #text do
			local byte = text:sub(index, index)
			if byte == '"' then return table.concat(out), index + 1 end
			if byte == '\\' then
				local escaped = text:sub(index + 1, index + 1)
				local plain = { n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\' }
				if plain[escaped] then
					out[#out + 1] = plain[escaped]
					index = index + 2
				elseif escaped == 'u' then
					out[#out + 1] = string.char(tonumber(text:sub(index + 2, index + 5), 16) % 256)
					index = index + 6
				else
					index = index + 2
				end
			else
				out[#out + 1] = byte
				index = index + 1
			end
		end
		return nil, index
	end

	local literal = text:match('^[%-%d%.eE%+]+', at)
	if literal then return tonumber(literal), at + #literal end
	for word, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = nil }) do
		if text:sub(at, at + #word - 1) == word then return value, at + #word end
	end
	if text:sub(at, at + 3) == 'null' then return nil, at + 4 end
	return nil, at
end

function json.decode(text)
	if type(text) ~= 'string' then return nil end
	local ok, value = pcall(decodeValue, text, 1)
	return ok and value or nil
end

Host.json = json

-- Value nodes the host accepts in one WebUI payload, and the rule it counts by:
-- the value itself, and both halves of every pair under a table. `modules/menu`
-- and `modules/panel` both count against this, and this file is the third copy
-- on purpose -- a stub that shared the runtime's counter could not catch the
-- runtime's counter being wrong.
Host.MAX_PAYLOAD_NODES = 1024

--- The nodes one payload comes to.
-- @author dop42
-- @param value any
-- @return integer
function Host.PayloadNodes(value)
	local nodes = 1
	if type(value) ~= 'table' then return nodes end
	for key, nested in pairs(value) do
		nodes = nodes + Host.PayloadNodes(key) + Host.PayloadNodes(nested)
	end
	return nodes
end

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
	local serverEvents = {}
	local clock = 0
	-- Forward-declared: the host globals below close over it, and a local declared
	-- after them would leave those closures pointing at a global instead.
	local control

	-- Replicated state bags, by `<kind>:<id>`. A REAL store and not an accepting
	-- stub: the runtime skips a write whose value has not moved, and a `set` that
	-- always answered true without keeping anything would make that skip -- and
	-- every read after it -- untestable.
	local bags = {}

	-- One bag handle. The five method names shadow the keys of the same name, which
	-- is the platform's own rule and the one thing a caller can get wrong here.
	local function bagFor(kind, id)
		local slot = ('%s:%s'):format(kind, tostring(id))
		bags[slot] = bags[slot] or {}
		local methods = {
			set = function(_, key, value) bags[slot][key] = value; return true end,
			clear = function(_, key)
				if key == nil then bags[slot] = {}; return true end
				if bags[slot][key] == nil then return false, 'unknown_bag' end
				bags[slot][key] = nil
				return true
			end,
			get = function(_, key) return bags[slot][key] end,
			all = function()
				local out = {}
				for key, value in pairs(bags[slot]) do out[key] = value end
				return out
			end,
			revision = function() return 1 end,
			selector = function() return { kind = kind, id = tostring(id) } end,
		}
		return setmetatable({}, {
			__index = function(_, key) return methods[key] or bags[slot][key] end,
		})
	end

	local Open77 = {
		log = {
			debug = function(line) log.debug[#log.debug + 1] = tostring(line) end,
			info = function(line) log.info[#log.info + 1] = tostring(line) end,
			warn = function(line) log.warn[#log.warn + 1] = tostring(line) end,
			error = function(line) log.error[#log.error + 1] = tostring(line) end,
		},
		time = { monotonic = function() return clock / 1000 end },
		exports = { call = function() return nil, 'no_host' end },

		-- `Open77.state` holds two unrelated things and the platform says so: the
		-- resource-private blob that survives a reload, and the replicated bags.
		-- `save`/`load` answer nothing, which is the cold-start case a module has to
		-- handle anyway.
		state = {
			save = function() return true end,
			load = function() return nil end,
			clear = function() return true end,

			global = bagFor('global', 0),
			player = function(id) return bagFor('player', id) end,
			entity = function(kind, id) return bagFor(kind, id) end,
			localPlayer = function() return bagFor('player', 1) end,

			-- No delta ever fires here: a change handler is only reached from a
			-- write on the OTHER side of the wire, and there is no wire.
			onChange = function() return 1 end,
			offChange = function() return true end,
		},

		notifications = { send = function() return true end },

		-- One declaration per resource, answering a live table the runtime reads
		-- through. A host that does not install this at all is the other case the
		-- runtime has to survive, so tests can clear it.
		tunables = { declare = function(block) return block end },

		-- The readiness gate. `hold` answers ONE value -- the session -- or
		-- nil plus a reason, which is the shape the runtime has to handle.
		ready = {
			participate = function() return true end,
			hold = function() return 1 end,
			release = function() return true end,
			status = function() return nil end,
			isReady = function() return false end,
		},

		-- Spawned vehicles. `create` answers an opaque engine id, which is stored
		-- as-is and never put through `tonumber`: these are 64-bit and would not
		-- survive it.
		vehicles = {
			create = function() return '0x0000000000000001' end,
			get = function() return nil end,
			remove = function() return true end,
			update = function() return true end,
			getDamage = function() return {} end,
			setDamage = function() return true end,
			flags = function() return {} end,
		},

		acl = { isAllowed = function() return false end },

		routingBuckets = {
			setPlayer = function() return true end,
			getPlayer = function() return 0 end,
			setPopulationEnabled = function() return true end,
			setLockdownMode = function() return true end,
		},

		environment = {
			getTime = function() return 0 end,
			setTime = function() return true end,
			setTimeFrozen = function() return true end,
			setWeather = function() return true end,
			setWeatherFrozen = function() return true end,
			isWeatherFrozen = function() return false end,
		},

		players = {
			all = function() return {} end,
			name = function(playerId) return control.accounts[playerId] and 'player' or nil end,
			position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end,
			getLifeState = function() return 'alive' end,
			isDead = function() return false end,
			kill = function() return true end,
			respawn = function() return true end,
			revive = function() return true end,
			setArmor = function() return true end,
			disconnect = function() return true end,
		},

		character = {
			state = function() return { health = 100 } end,
			position = function() return { x = 0, y = 0, z = 0 } end,
			yaw = function() return 0 end,
		},

		hud = { setVisible = function() return true end },
		resource = { generation = function() return 1 end },
	}

	Open77.database = database

	local env = {
		Open77 = Open77,
		json = json,
		MySQL = database,

		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		Wait = function() coroutine.yield() end,
		GetGameTimer = function() return clock end,
		GetCurrentResourceName = function() return 'opx_infinity' end,
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
				-- `visible` starts from the spec, not from a later `show`. The runtime creates
				-- the surface visible on purpose, and a stub that ignores the flag would
				-- make a never-painting page look identical to a working one.
				local page = {
					spec = spec,
					sent = {},
					-- Every send the host turned away, newest last.
					refused = {},
					handlers = {},
					focus = {},
					visible = spec.visible == true,
					alive = true,
				}
				page.send = function(_, channel, payload)
					-- THE HOST BOUNDS A WebUI PAYLOAD AND REFUSES AN OVERSIZED ONE
					-- WHOLE. This stub used to answer true to everything, which is
					-- why the fitting room's catalogue could be lost on the wire for
					-- a release with a green suite behind it: every batch it sent was
					-- past the bound, `WebUI.Page.send` answered false on the real
					-- host, and nothing here ever said so. Modelled rather than
					-- asserted per test, so the whole suite is the check.
					local nodes = Host.PayloadNodes(payload)
					if nodes > Host.MAX_PAYLOAD_NODES then
						page.refused[#page.refused + 1] =
							{ channel = channel, nodes = nodes }
						return false
					end
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
		-- RECORDED, NOT SWALLOWED. This used to be an empty function, which made
		-- the one channel a client half has to the operator the one channel the
		-- suite could not see: `modules/appearance` reports every clothing and
		-- fitting-room decision over it, precisely because `Open77.log` on a
		-- client writes to a file on the player's machine. A test that cannot read
		-- this cannot tell a module that decided nothing from one that decided and
		-- said so, which is the distinction two diagnoses of the fitting room both
		-- got wrong.
		env.TriggerServerEvent = function(name, ...)
			serverEvents[#serverEvents + 1] = { name = name, ... }
			return true
		end
	end

	-- `require` exists in the CLIENT VM and nowhere else: the dedicated-server
	-- sandbox has no module loader at all. Installing it on the client side only
	-- is what lets a shared_script that reached for it fail here, which is the
	-- one place that mistake is cheap to find.
	--
	-- It resolves `@opx_lib/...` against the sibling checkout, so these tests
	-- exercise the REAL library rather than a stand-in -- a stub would pass while
	-- the two repositories drifted apart, which is the failure this is meant to
	-- catch.
	if side == 'client' then env.require = Host.RequireFor(env) end

	env._G = env
	setmetatable(env, { __index = _G })

	-- What the harness hands back to a test.
	control = {
		log = log,
		commands = commands,
		netEvents = netEvents,
		clientEvents = clientEvents,
		serverEvents = serverEvents,
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

--- Names the sandbox removes on BOTH runtimes. Loading code that reaches for one
--- is a failure the test should report here rather than on the test server.
Host.Sandbox = { 'io', 'os', 'debug', 'package', 'dofile', 'loadfile' }

--- Names the CLIENT VM has and the dedicated server does not.
---
--- `require` is the whole list, and it is separated from `Host.Sandbox` rather
--- than dropped from it because the distinction is real and load-bearing: a
--- `client_script` may import a library, and a `shared_script` that did the same
--- would break the moment the server loaded it. Merging the two lists would
--- either forbid a legal import or permit an illegal one.
Host.ClientOnly = { 'require' }

--- Where a published dependency library lives.
---
--- A sibling checkout by default, which is how they sit on a workstation.
--- `OPX_LIB_PATH` overrides it, and CI needs that: `actions/checkout` refuses a
--- path outside the workspace, so the runner clones the library INTO the
--- workspace and points this at it. Without the override, CI cannot see the
--- sibling at all and every client boot dies on the first `require`.
---
--- The suite loads the REAL library rather than a stub on purpose -- a stub
--- would pass while the two repositories drifted apart -- so a missing checkout
--- has to be loud rather than skipped.
Host.Providers = { opx_lib = os.getenv('OPX_LIB_PATH') or '../opx_lib' }

--- Builds the client VM's `require` for ONE environment.
---
--- A FACTORY rather than a plain function, and the environment is the whole
--- reason. `loadfile(path)` runs a module in the REAL global table -- which is
--- not where the harness's stubbed `Open77` lives; that is in the sandbox
--- `env`. So every library wrapper resolved its natives against a table that
--- was never there, took its absent-native path for the entire suite, and the
--- SUCCESS paths of `Input`, `Rpc`, `Store` and `Players` went untested while
--- their refusals were covered. The suite loads the real library precisely so
--- the two repositories cannot drift; loading it blind to the stub gave up
--- most of that.
---
--- The cache moves inside for the same reason. It was module-level and shared
--- across every environment the suite builds, where the platform caches per
--- caller generation -- two consumers get two copies. Per environment is both
--- the faithful shape and what lets the stub differ between tests.
-- @author dop42
-- @param env table the sandbox the importing resource runs in
-- @return function
function Host.RequireFor(env)
	local imported = {}

	local function resolve(name)
	if type(name) ~= 'string' then return nil, 'invalid_module_name' end

	local provider, module = name:match('^@([%w_]+)/?(.*)$')
	if provider == nil then
		-- A bare name resolves inside the CALLING resource on the platform. This
		-- resource ships no importable modules, so reaching for one is a mistake
		-- rather than something to support.
		return nil, ('unqualified require(%q)'):format(name)
	end

	local root = Host.Providers[provider]
	if root == nil then return nil, 'module_dependency_not_declared' end
	if module == '' then module = 'init' end

	local path = ('%s/%s.lua'):format(root, (module:gsub('%.', '/')))
	if imported[path] ~= nil then return imported[path] end

	-- IN `env`, which is the point of the factory: the module resolves its
	-- natives against the stub the test installed, not against the real global
	-- table where there is no platform at all.
	local chunk, why = loadfile(path, 't', env)
	if chunk == nil then
		-- The sibling is genuinely absent, rather than the import being wrong.
		return nil, ('module_dependency_not_running: %s'):format(tostring(why))
	end

	-- The library imports its own siblings through the caller's `require`,
	-- which in a running client is this same resolver. It already IS
	-- `env.require` and the module runs in `env`, so the lookup finds it with
	-- no global swap -- the swap this replaced was only ever needed because the
	-- module was running somewhere `env` could not be seen from.
	local value = chunk()

	if value == nil then value = true end
	imported[path] = value
	return value
	end

	return resolve
end

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
