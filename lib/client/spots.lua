--- The client half of a placed spot: its markers, and the key that uses it.
-- @author dop42
--
-- `lib/shared/spots.lua` is the record -- what a spot is, how it is read off a
-- config or the wire, which one a player stands on. This is what every module
-- that draws spots did with them on the client, written once. `garages`,
-- `dealership`, `clothing` and `teleports` each held a copy of the marker set
-- (create, remove, reconcile, clear), and those four plus the elevator door each
-- held a copy of the key mapping (register, read the answer, the silent press).
-- Five copies of one behaviour drift; the eight-markers-a-pass cap had already
-- reached three of them and not the fourth.
--
-- Hung on `OPX.Spots` rather than a namespace of its own: it is the same subject,
-- and the namespace list in the test suite is the boundary of what the runtime
-- publishes.

OPX.Spots = OPX.Spots or {}

--- Whether another surface holds the keyboard: the chat box, a form, the pause
--- menu. A read that raises answers FREE, where `OPX.Lib.Input.IsCaptured`
--- answers captured -- the spots modules have always read it this way, and a key
--- that went dead because a host read failed would be a key nobody can explain.
-- @author dop42
-- @return boolean
function OPX.Spots.Captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- The player's own ground position, or nil before there is a world to read.
-- `Open77.character.position()` answers numbers, not a table.
-- @author dop42
-- @return number|nil x
-- @return number|nil y
function OPX.Spots.PlayerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- ── the markers ─────────────────────────────────────────────────────────────

--- Markers one set creates in one pass, at most. A marker is an engine call and
--- a pass runs in one resume: the first list, or a change of bucket, used to
--- create every marker in range at once -- the "dozens of engine calls in one
--- resume" shape the platform's per-resume instruction budget ends without a
--- word (`modules/blips` caps its pins for the same reason). The rest come on the
--- next passes; a removal is never deferred.
OPX.Spots.MARKER_CREATES_PER_PASS = 8

OPX.Spots.Markers = {}

--- A set of engine markers kept in line with a spot list.
-- @author dop42
-- @param options table
--   tag          string   the module name, for the one log line a refusal gets
--   look         function (spot) -> { shape, style, radius, lift }
--   maxDistance  function () -> metres; a spot within it has a marker
--   variant      function|nil (spot) -> any; a marker whose variant changed is
--                remade, because a marker's style is fixed when it is created
-- @return table the set: `Reconcile(list, x, y)`, `Clear()`, `Count()`, `Has(key)`
function OPX.Spots.Markers.New(options)
	local tag = tostring(options.tag or 'spots')
	local look, maxDistance, variant = options.look, options.maxDistance, options.variant
	local markers, drawn = {}, {}
	local reported = false
	local set = {}

	-- Creates one marker, or answers why it could not be. Never raises. The draw
	-- distance is the pass's, read once: resolving it again per marker was
	-- another config clamp inside the scan's one resume.
	local function create(spot, limit)
		local api = Open77.markers
		if type(api) ~= 'table' or type(api.create) ~= 'function' then
			return nil, 'world.markers is unavailable'
		end
		local shape = look(spot)
		local read, id, reason = pcall(api.create, {
			-- The spot's declared height plus the look's own lift: a marker left
			-- at floor height is co-planar with the floor and draws nothing.
			position = { x = spot.x, y = spot.y, z = spot.z + (shape.lift or 0) },
			shape = shape.shape,
			style = shape.style,
			radius = shape.radius,
			maxDistance = limit,
		})
		if not read then return nil, tostring(id) end
		if id == nil then return nil, tostring(reason or 'refused') end
		return id, nil
	end

	-- Removes one marker without raising.
	local function remove(id)
		local api = Open77.markers
		if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
		pcall(api.remove, id)
	end

	local function forget(key)
		remove(markers[key])
		markers[key], drawn[key] = nil, nil
	end

	--- Brings the drawn set in line with what is in range: a spot within
	--- `maxDistance()` has a marker, one beyond it does not, and a spot the list
	--- no longer names loses its marker even while in range.
	-- THE POSITION IS HANDED IN, NOT READ HERE: the caller has just read it to
	-- find the nearest spot, and a second read per pass is a second host call
	-- for the same answer. Nil means it could not be read, and draws nothing.
	-- @param list table key -> spot
	-- @param x number|nil
	-- @param y number|nil
	--
	-- THE POSITION IS COERCED ONCE A PASS, and the distance worked out inline:
	-- `FlatDistanceSquared` re-coerced it for every spot on the list, in a scan
	-- that runs inside the scheduler's shared resume -- most of the meter's
	-- 9,200 for `garages:scan` on a twenty-point lot.
	function set.Reconcile(list, x, y)
		local limit = maxDistance()
		local reach = limit * limit
		local creates = 0
		if x ~= nil then x, y = OPX.Spots.Coordinate(x), OPX.Spots.Coordinate(y) end
		local located = x ~= nil and y ~= nil
		local cap = OPX.Spots.MARKER_CREATES_PER_PASS
		for key, spot in pairs(list) do
			local wanted = false
			if located then
				local dx, dy = x - spot.x, y - spot.y
				wanted = dx * dx + dy * dy <= reach
			end
			local have = markers[key]
			if wanted then
				if have ~= nil and variant ~= nil and drawn[key] ~= variant(spot) then
					forget(key)
					have = nil
				end
				if have == nil and creates < cap then
					creates = creates + 1
					local id, failure = create(spot, limit)
					if id == nil then
						if not reported then
							reported = true
							Open77.log.warn(('[%s] no marker is drawn: %s'):format(tag, tostring(failure)))
						end
					else
						markers[key] = id
						if variant ~= nil then drawn[key] = variant(spot) end
					end
				end
			elseif have ~= nil then
				forget(key)
			end
		end
		for key in pairs(markers) do
			if list[key] == nil then forget(key) end
		end
	end

	--- Drops every marker this set drew.
	function set.Clear()
		for key in pairs(markers) do forget(key) end
	end

	--- How many markers are drawn.
	-- @return integer
	function set.Count()
		local count = 0
		for _ in pairs(markers) do count = count + 1 end
		return count
	end

	--- Whether a spot has a marker drawn.
	-- @param key any
	-- @return boolean
	function set.Has(key)
		return markers[key] ~= nil
	end

	--- Forgets whether a refusal was already logged, for a module's Init.
	function set.Reset()
		markers, drawn, reported = {}, {}, false
	end

	return set
end

-- ── the key ─────────────────────────────────────────────────────────────────

OPX.Spots.Key = {}

--- Declares the rebindable key a spot module uses, and answers whether the host
--- took it.
-- @author dop42
--
-- THE SILENT PRESS. E is shared -- garages, dealership, clothing, teleports and
-- the elevator door all declare it -- so a press while another surface holds the
-- keyboard does nothing at all, and the module's own handler decides what a
-- press away from its spots says (each of them: nothing). The handler runs under
-- pcall, so a raise is a log line and not a dead key.
--
-- The mapping's name is translated at registration and its id is stable,
-- because a player's rebind is stored under the id. `DEFAULT = false` declares
-- no key. Two answer shapes are documented for the host call -- the effective
-- key, or `true, key` -- and both are read; reading only the second logged a
-- working mapping as refused.
-- @param options table
--   tag      string   the module name, for the log lines
--   declared table    { ID, NAME, DEFAULT } as the module's KEY block reads
--   onPress  function (origin) called with 'key'
-- @return boolean registered
function OPX.Spots.Key.Register(options)
	local tag = tostring(options.tag or 'spots')
	local declared = options.declared
	if type(declared) ~= 'table' or declared.DEFAULT == false then return false end
	local onPress = options.onPress
	local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
		declared.DEFAULT, function()
			if OPX.Spots.Captured() then return end
			local ran, failure = pcall(onPress, 'key')
			if not ran then
				Open77.log.error(('[%s] key %s: %s'):format(tag, declared.ID, tostring(failure)))
			end
		end)
	local effective = nil
	if called then
		effective = type(ok) == 'string' and ok ~= '' and ok
			or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	end
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[%s] key mapping %s (%s) not registered: %s')
			:format(tag, declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		return false
	end
	return true
end

--- The key a registered mapping is bound to now, or nil when it is not
--- registered: a row with no key to name says nothing.
-- @author dop42
-- @param registered boolean what `Register` answered
-- @param declared table { ID, DEFAULT }
-- @return string|nil
function OPX.Spots.Key.Label(registered, declared)
	if not registered or type(declared) ~= 'table' then return nil end
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end
