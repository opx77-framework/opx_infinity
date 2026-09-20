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
	-- Forward-declared: the host globals below close over them, and a local
	-- declared after them would leave those closures pointing at a global
	-- instead. The marker, keyboard and ACL stubs close over these four, and so
	-- does `vehicles`: a spawn stub that read a global `vehicles` recorded the
	-- creation and then raised, so every bring-out was answered as a refusal
	-- while the vehicle it created sat in the world.
	local control
	local markers, input, acl, keyMappings, vehicles, vehicleCreates, vehicleRemoves, seats
	local bodies, effects, travels, notices, placement, lifts

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
		-- A LIVE PROXY OF VALUES, which is what the real `declare` answers -- not
		-- the declaration it was handed. Returning the block made `live[key]` a
		-- spec TABLE where `OPX.Tune.Get` expects the number, so every
		-- `OPX.Tune.Number` in the resource found a non-finite value and quietly
		-- returned its floor instead. Whole behaviours read as dead in this harness
		-- for that reason alone: an elevator's REQUESTS_PER_WINDOW came out 0, so
		-- the first floor request any player made was rate-limited before it was
		-- looked at.
		tunables = {
			declare = function(block)
				local proxy = {}
				for key, spec in pairs(block) do
					proxy[key] = type(spec) == 'table' and spec.value or spec
				end
				return proxy
			end,
		},

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
		--
		-- Every creation is recorded, because WHERE a vehicle was created is the
		-- whole point of a garage marker: a test that only saw an id could not
		-- tell a vehicle placed on the marker from one placed beside the player.
		vehicles = {
			create = function(options)
				vehicleCreates[#vehicleCreates + 1] = options
				if vehicles.refuse ~= nil then return nil, tostring(vehicles.refuse) end
				-- A DISTINCT id per creation, the way the engine hands them out. A stub
				-- that answered one constant made every live vehicle the same vehicle
				-- to anything matching by id -- the seat oracle among them -- so a
				-- player sitting in one car could be read as sitting in another.
				vehicles.next = (vehicles.next or 0) + 1
				return ('0x%016x'):format(vehicles.next)
			end,
			-- What a live vehicle projects. Nil is "the host knows nothing about
			-- it", which is one of the two answers a caller has to survive;
			-- `vehicles.snapshot` is the other, and it is where an occupant is set
			-- so the refusal that protects a driver can be exercised.
			get = function() return vehicles.snapshot end,
			-- Recorded, because "the vehicle was put away" and "it is still in the
			-- world with a row that says stored" read identically from a return
			-- value. The comment above has always promised this list.
			remove = function(id)
				vehicleRemoves[#vehicleRemoves + 1] = id
				return true
			end,
			update = function() return true end,
			getDamage = function() return {} end,
			setDamage = function() return true end,
			flags = function() return {} end,
			-- The seat THIS client is in, which is what tells the strip whether the
			-- key is about to take a vehicle out or put one away. Slot 1 is the
			-- local player here, the same convention `state.localPlayer` uses.
			getPlayerSeat = function() return seats[1] end,
		},

		-- Network elevators. A REAL flag store and not an accepting stub, because
		-- the one thing this module's job gate rests on is that an adopted cabin
		-- comes up LOCKED: the platform turns a press of the vanilla in-cabin floor
		-- button into a player request, and `locked` is the only bit that refuses
		-- one. A `setFlags` that answered true without keeping anything would make
		-- the difference between a gated lift and an ungated one invisible here,
		-- which is exactly the bug the tests below exist to catch.
		--
		-- The constants carry the platform's own values -- powered 1, locked 2,
		-- interactionAllowed 4, doorsClosed 8 -- from the `setFlags` card, so a mask
		-- assembled by the runtime is compared against the numbers the engine uses
		-- and not against a private set that would agree with any of them.
		elevators = {
			flags = { powered = 1, locked = 2, interactionAllowed = 4, doorsClosed = 8 },

			-- Engine hashes are opaque 64-bit values and never go through
			-- `tonumber`; the id the host hands back for one is a plain integer, and
			-- the two are different things the runtime must not confuse.
			adopt = function(definition)
				lifts.adopts[#lifts.adopts + 1] = definition
				if lifts.refuse ~= nil then return nil, tostring(lifts.refuse) end
				lifts.next = lifts.next + 1
				local id = lifts.next
				lifts.byId[id] = {
					id = id,
					engineEntity = definition.engineEntity,
					bucket = definition.bucket or 0,
					floorCount = definition.floorCount,
					activeFloor = definition.initialFloor or 0,
					phase = 'idle',
					x = definition.position and definition.position.x,
					y = definition.position and definition.position.y,
					z = definition.position and definition.position.z,
					-- The host's OWN default when the caller names none: powered plus
					-- interaction allowed, per the `adopt` card. A stub that defaulted
					-- to locked would have passed the runtime as it stood before this
					-- change, which is the whole point of writing it out.
					--
					-- `ignoreAdoptFlags` is the build that predates the field and drops
					-- it in silence. That is not a hypothetical: it is the reason the
					-- runtime reads the mask back instead of trusting its own request,
					-- and without it here that read-back could never be exercised.
					flags = (not lifts.ignoreAdoptFlags and definition.flags) or 5,
				}
				return id
			end,

			get = function(id) return lifts.byId[id] end,

			all = function(bucket)
				local rows = {}
				for _, lift in pairs(lifts.byId) do
					if bucket == nil or lift.bucket == bucket then rows[#rows + 1] = lift end
				end
				-- Sorted, because `pairs` order would reshuffle which lift the
				-- runtime's re-claim scan meets first between runs.
				table.sort(rows, function(left, right) return left.id < right.id end)
				return rows
			end,

			-- REPLACES the mask, the way the real one documents itself. Set
			-- `lifts.refuseFlags` to answer false, which is how a cabin owned by
			-- another resource refuses a lock it does not own.
			setFlags = function(id, flags)
				local lift = lifts.byId[id]
				if lift == nil then return false, 'no_such_elevator' end
				if lifts.refuseFlags then return false, 'not_owner' end
				lift.flags = flags
				lifts.flagWrites[#lifts.flagWrites + 1] = { id = id, flags = flags }
				return true
			end,

			goTo = function(id, floor)
				local lift = lifts.byId[id]
				if lift == nil then return false end
				lifts.trips[#lifts.trips + 1] = { id = id, floor = floor }
				lift.targetFloor = floor
				return true
			end,

			remove = function(id)
				lifts.removes[#lifts.removes + 1] = id
				lifts.byId[id] = nil
				return true
			end,

			-- What a client's scan sees. Empty by default: a world with no streamed
			-- lift in it is the honest answer for a harness with no world.
			nearby = function() return lifts.nearby end,
		},

		-- World markers. The stub validates exactly what `client/src/api/Markers.cpp`
		-- validates -- four styles, two shapes, radius 0.1..50, maximumDistance
		-- 1..500 -- so a marker the engine would refuse under `unsupported_style`
		-- fails here rather than silently in a live session. A marker that is never
		-- removed is the other half of the same class of bug, so `list` is real.
		markers = {
			create = function(options)
				if type(options) ~= 'table' or type(options.position) ~= 'table' then
					return nil, 'invalid_argument'
				end
				local styles = { interaction = true, objective = true, spawn = true, danger = true }
				local shapes = { ring = true, cylinder = true }
				if not styles[tostring(options.style)] then return nil, 'unsupported_style' end
				if not shapes[tostring(options.shape)] then return nil, 'unsupported_shape' end
				local radius = tonumber(options.radius)
				if radius == nil or radius < 0.1 or radius > 50.0 then
					return nil, 'invalid_argument'
				end
				local maxDistance = tonumber(options.maxDistance)
				if maxDistance == nil or maxDistance < 1.0 or maxDistance > 500.0 then
					return nil, 'invalid_argument'
				end
				if markers.refuse ~= nil then return nil, tostring(markers.refuse) end
				markers.next = (markers.next or 0) + 1
				local id = 'marker-' .. tostring(markers.next)
				markers.byId[id] = options
				markers.created[#markers.created + 1] = id
				return id
			end,
			update = function(id, patch)
				if markers.byId[id] == nil then return false, 'unknown_marker' end
				if type(patch) == 'table' then
					for key, value in pairs(patch) do markers.byId[id][key] = value end
				end
				return true
			end,
			remove = function(id)
				if markers.byId[id] == nil then return false, 'unknown_marker' end
				markers.byId[id] = nil
				markers.removed[#markers.removed + 1] = id
				return true
			end,
			clear = function()
				for id in pairs(markers.byId) do markers.byId[id] = nil end
				return true
			end,
			list = function()
				local out = {}
				for id in pairs(markers.byId) do out[#out + 1] = id end
				table.sort(out)
				return out
			end,
		},

		-- The keyboard. `isCaptured` answers what the test set, so a player typing
		-- into the chat box is a case a caller can actually be exercised against.
		input = {
			isCaptured = function() return input.captured == true end,
			keyFor = function(id) return input.keys[id] end,
			mappings = function()
				local out = {}
				for id, key in pairs(input.keys) do
					out[#out + 1] = { resource = 'opx_infinity', id = id, key = key }
				end
				return out
			end,
			isDown = function(key) return input.down[key] == true end,
		},

		-- `acl.read` is granted in the manifest, and the capture door asks the same
		-- question the command gate asks. Empty means refused, which is the shape
		-- every caller has to survive; `control.Allow` is how a test grants one.
		acl = {
			isAllowed = function(playerId, permission)
				local granted = acl.granted
				if granted == nil then return false end
				local player = granted[tostring(playerId)]
				return player ~= nil and player[tostring(permission)] == true
			end,
		},

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
			-- The admitted slots, which is what a server-side fan-out walks. An
			-- always-empty list would make "every client in the bucket was told"
			-- untestable, and a capture that told nobody would look the same as one
			-- that told everybody.
			all = function()
				local ids = {}
				for slot in pairs(control.accounts or {}) do
					local id = tonumber(slot)
					if id ~= nil then ids[#ids + 1] = id end
				end
				table.sort(ids)
				return ids
			end,
			name = function(playerId) return control.accounts[playerId] and 'player' or nil end,
			position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end,
			getLifeState = function() return 'alive' end,
			isDead = function() return false end,
			kill = function() return true end,
			respawn = function() return true end,
			revive = function() return true end,
			setArmor = function() return true end,
			-- The seat a connection is sitting in, or nil. The marker key's whole
			-- behaviour turns on this answer -- it is what decides whether the key
			-- puts a vehicle away or brings one out -- so a suite that could not
			-- set it could not exercise half the door. `control.Seat` is the way.
			getVehicleSeat = function(playerId) return seats[tonumber(playerId) or playerId] end,

			-- The one native that hides a body. Recorded rather than accepted: on
			-- the server a veil is a REASON and here it is a boolean, and a test
			-- that could not read the boolean could not tell a body that was
			-- handed back from one that was never hidden. `bodies.refuse` answers
			-- a reason instead, the way a host without the API does.
			setVisible = function(playerId, visible)
				if bodies.refuse ~= nil then return false, bodies.refuse end
				local id = tonumber(playerId) or playerId
				bodies.visible[id] = visible == true
				bodies.writes[#bodies.writes + 1] = { playerId = id, visible = visible == true }
				return true
			end,
			setFrozen = function(playerId, held)
				local id = tonumber(playerId) or playerId
				bodies.frozen[id] = held == true
				return true
			end,
			-- The reader the veil is asked through. nil, not false, when nothing
			-- has ever written it: the module falls back to its own mark on nil.
			isVisible = function(playerId) return bodies.visible[tonumber(playerId) or playerId] end,
			isFrozen = function(playerId) return bodies.frozen[tonumber(playerId) or playerId] end,
			disconnect = function() return true end,
		},

		character = {
			state = function() return { health = 100 } end,
			-- THREE NUMBERS, not a table: `Open77.character.position()` answers
			-- x, y, z, and every client module reads it that way. A stub that
			-- answered a table made every one of those reads nil -- a marker
			-- module drew nothing, with no error to say why.
			position = function() return placement.x, placement.y, placement.z end,
			yaw = function() return 0 end,
		},

		-- The travel natives. Recorded, because the staff half READS BACK what it
		-- set -- `isNoclip` is how the client notices the native was switched off
		-- underneath it, which is the one edge the server cannot see -- and a
		-- no-op stub would make that read always false, a state this client never
		-- produces. `travels.refuse` is a build without the natives.
		travel = {
			setNoclip = function(on)
				if travels.refuse ~= nil then return false, travels.refuse end
				travels.noclip = on == true
				travels.calls[#travels.calls + 1] = { name = 'setNoclip', value = on == true }
				return true
			end,
			isNoclip = function() return travels.noclip end,
			setMapPick = function(on)
				travels.mapPick = on == true
				travels.calls[#travels.calls + 1] = { name = 'setMapPick', value = on == true }
				return true
			end,
			isMapPick = function() return travels.mapPick end,
		},

		-- The effect layer, in the shape the native answers with. `play` RESOLVES
		-- a name against the engine's own catalogue and answers `handle, reason`
		-- -- it never raises -- so a stub that raised would leave the refused
		-- path untested, and one that always answered a handle would hide a
		-- typo'd alias that draws nothing. `effects.refuse` forces the refusal.
		--
		-- The catalogue is a COPY of `kVfxCatalog` in
		-- `client/src/api/Effects.cpp` (51 aliases, counted 2026-09-19). It is
		-- here for one question a suite should be able to ask without the game:
		-- is the effect a config names one the engine actually carries?
		vfx = {
			catalog = function() return effects.catalogue end,
			play = function(effect, options)
				local call = { effect = effect, options = options }
				if effects.refuse ~= nil then
					call.refused = effects.refuse
					effects.calls[#effects.calls + 1] = call
					return nil, effects.refuse
				end
				effects.next = effects.next + 1
				call.id = effects.next
				effects.plays[#effects.plays + 1] = call
				effects.live[effects.next] = effect
				return effects.next
			end,
			-- The move, in the shape the native answers with: `bool, reason`, and
			-- refused outright for a handle this resource does not hold -- which
			-- is what ends the follow loop, so `effects.updates` is also the
			-- evidence that it stopped rather than spun.
			update = function(id, options)
				if effects.live[id] == nil then return false, 'effect_not_found' end
				if options == nil or type(options.position) ~= 'table' then
					return false, 'invalid_position'
				end
				effects.updates[#effects.updates + 1] = { id = id, options = options }
				return true
			end,
			playEntity = function(effect, options)
				effects.entityPlays[#effects.entityPlays + 1] = { effect = effect, options = options }
				effects.next = effects.next + 1
				return effects.next
			end,
			stop = function(id)
				effects.stopped[#effects.stopped + 1] = id
				effects.live[id] = nil
				return true
			end,
			list = function()
				local out = {}
				for id, effect in pairs(effects.live) do
					out[#out + 1] = { id = id, effect = effect }
				end
				return out
			end,
		},

		sfx = {
			play = function(event, options)
				effects.sfx[#effects.sfx + 1] = { event = event, options = options }
				return #effects.sfx
			end,
		},

		-- Player notifications, in the shape the runtime sends them: the toast is
		-- how a staff action explains itself in game, and a stub that swallowed
		-- one would leave "was the operator told?" unanswerable off-platform.
		notifications = {
			send = function(playerId, message)
			local payload = type(message) == 'table' and message or { message = message }
			notices[#notices + 1] = { playerId = tonumber(playerId) or playerId,
				type = payload.type, message = payload.message }
			return true
		end,
		},

		hud = { setVisible = function() return true end },
		resource = { generation = function() return 1 end },
	}

	Open77.database = database

	-- Recorded by the marker and key stubs above, and read by the tests.
	markers = { byId = {}, created = {}, removed = {}, next = 0 }
	input = { captured = false, keys = {}, down = {} }
	acl = { granted = {} }
	-- Set `refuse` to make the engine refuse a creation, the way an unsupported
	-- record or a full world would, and `snapshot` to make `get` answer a live
	-- vehicle's projection -- the occupied case, which is the one a recall has to
	-- refuse.
	vehicles = { refuse = nil, snapshot = nil }
	vehicleCreates = {}
	vehicleRemoves = {}

	-- Adopted elevators, and every mutation in order. `refuse` makes `adopt`
	-- answer nil the way a host with no elevator authority does, and `refuseFlags`
	-- makes `setFlags` answer false the way a cabin another resource owns does --
	-- the two paths on which an adoption must NOT be kept.
	lifts = { byId = {}, next = 0, adopts = {}, flagWrites = {}, trips = {},
		removes = {}, nearby = {}, refuse = nil, refuseFlags = false,
		ignoreAdoptFlags = false }

	-- Who is sitting in what, by player id. Empty is "everybody is on foot",
	-- which is the answer most of the suite wants and one caller has to survive.
	seats = {}

	-- Bodies the server half hid or gave back, keyed by player id, with every
	-- write in order -- a veil applied twice reads differently from one that
	-- moved, which is the difference between a fix and a coincidence.
	bodies = { visible = {}, frozen = {}, writes = {}, refuse = nil }

	-- The travel natives' own state, and every write to them.
	travels = { noclip = false, mapPick = false, calls = {}, refuse = nil }

	-- Notifications the runtime sent, oldest first.
	notices = {}

	-- Where the local operator is standing. Movable, because an effect that is
	-- placed once and left behind and one that follows the operator read
	-- identically unless the suite can move the operator between pumps.
	placement = { x = 0.0, y = 0.0, z = 0.0 }

	-- Effects the client half asked the engine for. `plays` is the world ones,
	-- `calls` every attempt including the refusals, and `live` the handles still
	-- held -- a pop that was never stopped shows up there.
	effects = {
		catalogue = {
			'blood.puddle', 'electric.arc', 'electric.destruction', 'electric.device',
			'electric.emp', 'electric.industrial_arm', 'explosion.frag', 'explosion.fuel',
			'explosion.grenade', 'explosion.nuclear', 'explosion.steam', 'explosion.turret',
			'fire.gas', 'fire.large', 'fire.medium', 'fire.small', 'fire.tiny',
			'glass.shatter', 'impact.concrete', 'impact.default', 'impact.metal',
			'impact.water', 'laser.mine', 'neon.holo_zone', 'neon.loot_drop',
			'race.firework.burst', 'race.flare.smoke', 'smoke.ambient',
			'smoke.column.black', 'smoke.exterior', 'smoke.machine', 'smoke.poison_gas',
			'smoke.steam', 'sparks.burst.large', 'sparks.burst.small', 'sparks.cable',
			'sparks.welding', 'steam.column', 'steam.sewer', 'vehicle.exhaust',
			'vehicle.fire', 'vehicle.police_lights', 'vehicle.skid', 'vehicle.skid.mark',
			'vehicle.skid.smoke', 'water.drip', 'water.hydrant', 'water.sprinkler',
			'weather.dust', 'weather.rain', 'weather.sandstorm',
		},
		plays = {}, calls = {}, entityPlays = {}, stopped = {}, live = {}, sfx = {},
		updates = {},
		next = 0, refuse = nil,
	}

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
		-- RAISES ON A DUPLICATE, because the host does and this stub did not.
		--
		-- The devkit card for build 2.31.13+op77.76 is exact: "Names are 1 to 64
		-- characters ... registering one twice raises `duplicate command`." This
		-- was a silent overwrite, and the cost of that was measured rather than
		-- imagined: the appearance module registered `opx.appearance` twice, the
		-- raise took the rest of its `Start` with it -- including the hook that
		-- loads a character's clothing at login -- and all 1012 checks passed
		-- over it. A stub that accepts what the engine refuses is a stub that
		-- certifies a broken server.
		--
		-- Names are checked too, for the same reason: a name with a space in it
		-- is a command nobody can ever type, and the suite should say so here
		-- rather than let an operator find out.
		RegisterCommand = function(name, fn, restricted)
			if type(name) ~= 'string' or #name < 1 or #name > 64
				or name:match('^[%w_%.:%-]+$') == nil then
				error(('invalid command name %q'):format(tostring(name)), 2)
			end
			-- Case-insensitively, as the host matches them.
			local key = name:lower()
			if commands[key] ~= nil then error('duplicate command', 2) end
			commands[key] = { run = fn, restricted = restricted == true }
		end,

		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Both are produced here, because reading only one of them
		-- is a bug this suite has already caught once.
		RegisterKeyMapping = function(id, name, key, onPressed)
			if keyMappings.refuse then return false, keyMappings.refuse end
			if key == false then return false, 'no_key' end
			local effective = type(key) == 'string' and key ~= '' and key or 'E'
			input.keys[id] = effective
			keyMappings.byId[id] = { name = name, key = effective, pressed = onPressed }
			if keyMappings.secondShape then return true, effective end
			return effective
		end,
	}

	keyMappings = { byId = {}, refuse = false, secondShape = false }

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

		-- World markers the runtime created and removed. `markers.refuse` makes the
		-- next creation fail, which is how "the API is there but said no" is
		-- exercised.
		markers = markers,

		-- The keyboard: `input.captured` is another surface holding it, `input.keys`
		-- is what each mapping answers to after a rebind.
		input = input,

		-- Key mappings the runtime declared, by id.
		keyMappings = keyMappings,

		-- The vehicle stubs themselves: what `get` answers and what the engine
		-- refuses are both set through here.
		vehicles = vehicles,

		-- Every argument list `Open77.vehicles.create` was called with, and every
		-- id `remove` was called with.
		vehicleCreates = vehicleCreates,
		vehicleRemoves = vehicleRemoves,

		-- Every adopted lift, every flag mask written to one, every trip scheduled
		-- and every release -- plus the two refusal switches. A lift's `flags` here
		-- is the engine's own bitmask, so a test asserts on `locked` being set and
		-- not on the runtime having meant to set it.
		lifts = lifts,

		-- Bodies the server half hid, by player id, and every write in order.
		bodies = bodies,

		-- Where the local operator stands; move it to test anything that follows
		-- the operator rather than the spot they were in.
		placement = placement,

		-- Effects the client half asked the engine for, in order, refusals too.
		effects = effects,

		-- Travel native state and every write to it.
		travels = travels,

		-- Notifications the runtime sent, oldest first.
		notices = notices,

		--- Grants one permission to one player, as an ACL entry would.
		Allow = function(playerId, permission)
			local player = acl.granted[tostring(playerId)]
			if player == nil then
				player = {}
				acl.granted[tostring(playerId)] = player
			end
			player[tostring(permission)] = true
		end,

		--- Takes one back off, so a refusal can be exercised after a grant.
		Deny = function(playerId, permission)
			local player = acl.granted[tostring(playerId)]
			if player ~= nil then player[tostring(permission)] = nil end
		end,

		--- Puts an account on a slot, or clears it when `userId` is nil.
		Admit = function(playerId, userId) control.accounts[playerId] = userId end,

		--- Puts a player in a vehicle, or takes them out when it is nil.
		Seat = function(playerId, assignment) seats[tonumber(playerId) or playerId] = assignment end,

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
--- THE PLATFORM'S ORDER, NOT THE MANIFEST'S.
--
-- `SharedScripts.Concat(ServerScripts)` is literally what both loaders execute before
-- any phase runs -- `ServerResourceHost.cs` and `LuaResourceRuntime.cs` in
-- `Open77.Server.Scripting` -- so every SHARED script runs before any script of the
-- side's own, whatever order the manifest lists them in. A harness that reads the
-- manifest top to bottom is a harness that can only ever agree with the platform by
-- accident, and it disagreed about exactly the thing that mattered: a module is
-- declared by a `shared_script` and three configs are `server_script`s, so the suite
-- had the config loaded before the module declared itself while a real server had it
-- the other way round. The module's settings were empty in production and populated
-- here, which is a whole class of fault this file existed to catch and did not.
-- @author XEROX710
-- @param path string
-- @param side string 'server' or 'client'
-- @return string[]
function Host.LoadOrder(path, side)
	local own = side .. '_script'
	local shared, mine = {}, {}
	for line in io.lines(path) do
		local kind, file = line:match('^%s*([%a_]+)%s+"([^"]+)"')
		if kind == 'shared_script' then
			shared[#shared + 1] = file
		elseif kind == own then
			mine[#mine + 1] = file
		end
	end
	for _, file in ipairs(mine) do shared[#shared + 1] = file end
	return shared
end

return Host
