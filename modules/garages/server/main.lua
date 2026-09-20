--- Server half: the spots, what may come out of each, and the capture commands.
-- @author XEROX710
--
-- Everything the client believes is re-derived here before a vehicle exists: an
-- ask is a hint, and the mask is these checks. The distance is measured across
-- the ground against the DECLARED position, exactly as the client measures it,
-- and the bucket must agree -- a marker drawn for another routing bucket is not
-- one a player can use.
--
-- This module creates no vehicle of its own: it hands the plate to the
-- `vehicles` contract, which re-proves the ownership from the character roster
-- before it moves anything. Two owners of the same question would be one too
-- many, and the plate is the one this half does not own.
--
-- A spot captured in game lives in the database and is merged OVER the config by
-- key, so a spot checked in at `config/garages.lua` can be moved in game and the
-- checked-in value is what a database reset falls back to.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('garages')
local Access = M.Access

local Result = OPX.Result
local Store = M.Storage

-- The spots an operator checked in, and the ones captured in game.
local configSpots = {}
local captured = {}

-- Config overlaid by captured: the one list every read below uses.
local spots = {}

-- Per-player rate-limit windows for requests that are not rate-limited by
-- `OPX.Cooling`.
local windows = {}

-- The capture request each connection has not answered yet: `{ at = ms }`, by
-- player id. `add` cannot know a facing, so it asks the client for one, and an
-- answer that never comes used to be indistinguishable from one that arrived --
-- the operator was told to look the way the vehicle should point and then heard
-- nothing at all, for ever. A request now has a lifetime and settles itself.
local pending = {}

-- The contracts, resolved in `Start`. Nil means nothing can be proved and every
-- request is refused.
local vehicles, character

-- Whether the capture commands are worth registering, and whether the database
-- answered. Set in `Start`.
local running = false

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- How long a rate-limit window lives past a player's last request.
local WINDOW_GC_MS = 60000

local coordinate, integer = Access.Coordinate, Access.Integer

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(player, limit, spanMs)
	if limit <= 0 or spanMs <= 0 then return true end
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

-- One request's identity, so a watcher cannot expire a request that replaced
-- it. `at` is monotonic and taken once.
local function watchCapture(player, at, key)
	if Access.CAPTURE_TIMEOUT_MS <= 0 then return end
	CreateThread(function()
		while true do
			local entry = pending[player]
			if entry == nil or entry.at ~= at then return end
			if OPX.Now() - at >= Access.CAPTURE_TIMEOUT_MS then break end
			Wait(100)
		end
		-- Still this request and still unanswered: say so, once.
		local entry = pending[player]
		if entry == nil or entry.at ~= at then return end
		pending[player] = nil
		Open77.log.warn(
			('[garages] player %d did not answer the capture of %s within %d ms; ' ..
				'nothing was saved'):format(player, safe(key), Access.CAPTURE_TIMEOUT_MS))
		OPX.NotifyLocale(player, 'garages.captureNoAnswer', { key = safe(key) }, 'error')
	end)
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Reads a connection's ground position and bucket, or nil.
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local x, y = coordinate(position.x), coordinate(position.y)
	if x == nil or y == nil then return nil end
	local bucket = integer(position.bucket)
	return { x = x, y = y, bucket = bucket or 0 }
end

--- Rebuilds the merged list. Called once at load and after every capture.
local function rebuild()
	spots = {}
	for key, spot in pairs(configSpots) do spots[key] = spot end
	for key, spot in pairs(captured) do spots[key] = spot end
end

--- The spots of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the spots of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

--- Sends every connected player their own list. Guarded: a capture must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[garages] sync failed: ' .. tostring(failure))
		end
	end
end

--- Whether a stored row may come out at a spot.
-- The kind is the only thing decided here, and it is the whole rule: a ground
-- marker takes a ground vehicle and a pad takes an AV. Whether a row may come out
-- at all is the vehicles contract's question, not this module's -- a vehicle that
-- is already out is answered there with the id it has, and the state a row was
-- stored under belongs to the module that wrote it.
local function eligible(row, spot)
	if type(row) ~= 'table' or type(row.plate) ~= 'string' then return false end
	local av = Access.IsAv(row.record)
	if spot.kind == M.KIND.AVPAD then return av end
	return not av
end

--- Picks what comes out: a named plate when one was named, otherwise the
--- player's own vehicle stored at THIS spot, and failing that any eligible one.
-- Ties are broken by plate so the same request always answers the same vehicle
-- rather than whichever row `pairs` met first.
local function choose(rows, spot, wanted)
	local ranked = {}
	for index = 1, #rows do
		local row = rows[index]
		if eligible(row, spot) then
			ranked[#ranked + 1] = {
				row = row,
				rank = (row.garage == spot.key) and 0 or 1,
			}
		end
	end
	table.sort(ranked, function(left, right)
		if left.rank ~= right.rank then return left.rank < right.rank end
		return left.row.plate < right.row.plate
	end)

	if type(wanted) ~= 'string' or wanted == '' then
		return ranked[1] and ranked[1].row or nil
	end
	for index = 1, #ranked do
		if ranked[index].row.plate == wanted then return ranked[index].row end
	end
	return nil, 'vehicle.notFound'
end

--- The spot a request names, resolved against where the connection is standing.
-- THE ONE RESOLVER. The spot underfoot, the routing bucket and the reach are the
-- same three questions whether the key is about to take a vehicle out or put one
-- away, and a second copy for the second job would be a second answer to them.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the spot name; the nearest one when omitted
-- @return spot|nil
-- @return Result|nil the refusal, when there is one
local function resolve(source, key)
	local at = pointOf(source)
	if at == nil then return nil, Result.Err('garages.noPosition') end

	local spot = nil
	if key == nil or key == '' then
		spot = Access.Nearest(spots, at.x, at.y)
	else
		spot = Access.Spot(spots, key)
	end
	if spot == nil then return nil, Result.Err('garages.noSuchSpot') end
	if spot.bucket ~= at.bucket then return nil, Result.Err('garages.wrongBucket') end

	local flat = Access.FlatDistanceSquared(spot, at.x, at.y)
	if flat == nil or flat > Access.USE_RADIUS_SQ then
		return nil, Result.Err('garages.tooFar', spot.key)
	end
	return spot, nil
end

--- Brings one of the connection's own vehicles out at a spot it stands on.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the spot name; the nearest one when omitted
-- @param wanted string|nil a plate the caller claims
-- @return Result
function M.Bring(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end
	local spot, refusal = resolve(source, key)
	if spot == nil then return refusal end

	local owned = vehicles.List(data.citizenId)
	if not owned.ok then return owned end
	local rows = type(owned.value) == 'table' and owned.value or {}
	local pick, refusal = choose(rows, spot, wanted)
	if pick == nil then return Result.Err(refusal or 'garages.nothingHere', spot.key) end

	-- The spot itself, never the player's side: that is the whole point of a
	-- marker. An AV is lifted clear of the pad it materialises on.
	local z = spot.z
	if Access.IsAv(pick.record) then z = z + Access.AvLift() end

	-- Flat, the shape the vehicles contract reads a named place in: a nested
	-- position would be read as no place at all and the car would land beside the
	-- player, a car's width off the marker.
	local spawned = vehicles.Spawn(source, pick.plate, {
		x = spot.x, y = spot.y, z = z,
		yaw = spot.heading,
		bucket = spot.bucket,
	})
	if not spawned.ok then return spawned end

	return Result.Ok({
		spot = spot.key,
		label = spot.label,
		plate = pick.plate,
		id = spawned.value and spawned.value.id or nil,
		-- Forwarded, not decided here: whether the vehicle had to be moved is
		-- the vehicles contract's answer, and this half only repeats it.
		recalled = spawned.value and spawned.value.recalled or nil,
	})
end

--- The marker's one door: PUT AWAY when the connection is sitting in its own
--- vehicle, and BRING OUT otherwise.
-- ONE DECISION, MADE HERE. The player presses one key on one marker, and which
-- of the two things that key does is not something the client may claim: it is
-- read from the seat the host reports and the plate this module's own table
-- holds, both through the vehicles contract. A client that said "I am in my car"
-- would be a client deciding what gets stored.
--
-- Putting away is filed UNDER THE SPOT the player is standing on, because that is
-- what makes it come out there next time: `choose` prefers a row whose garage is
-- the spot it is standing on, and a car put away at a marker that then treated it
-- as a stranger would be a marker that forgets where you left it.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the spot name; the nearest one when omitted
-- @param wanted string|nil a plate the caller claims, for the bring-out half
-- @return Result
function M.Use(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end

	-- Read without trusting it: a contract too old to answer is "on foot", which
	-- is the bring-out half -- the behaviour every marker had before this.
	local seated = type(vehicles.Occupied) == 'function' and vehicles.Occupied(source) or nil
	if seated ~= nil and seated.ok and seated.value ~= nil then
		local spot, refusal = resolve(source, key)
		if spot == nil then return refusal end
		local put = vehicles.Store(seated.value.plate, spot.key)
		if not put.ok then return put end
		return Result.Ok({
			spot = spot.key,
			label = spot.label,
			plate = seated.value.plate,
			stored = true,
		})
	end

	return M.Bring(source, key, wanted)
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- One request off the wire. Rate-limited, then answered either way.
local function onRequested(key, plate)
	local src = tonumber(source)
	if src == nil then return end
	if key ~= nil and type(key) ~= 'string' then key = nil end
	if plate ~= nil and type(plate) ~= 'string' then plate = nil end

	-- THE DECLARED COOLDOWN, WHICH WAS DECLARED AND NOT ENFORCED. `COOLDOWN_MS`
	-- is written in `config/garages.lua`, read into `Access.COOLDOWN_MS` and
	-- validated at boot -- and then nothing anywhere applied it. Only the
	-- six-per-ten-seconds window ran, so six bring-outs could land in one tick.
	--
	-- That is not merely untidy. `Store.FetchOne` YIELDS before the already-out
	-- guard in `modules/vehicles/server/main.lua`, so two `M.Bring` threads for
	-- the same plate both pass it and both reach `vehicles.create` -- two cars
	-- from one row. The race lives in `vehicles` and wants fixing there; this is
	-- the caller that can drive it, and the floor its own config already asked
	-- for is what stops it being driven.
	--
	-- Same shape and same reason as the dealership's, which did apply its own.
	if Access.COOLDOWN_MS > 0 and OPX.Cooling(src, 'garages.bring', Access.COOLDOWN_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, key, false, 'garages.rateLimited')
		return
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, key, false, 'garages.rateLimited')
		return
	end

	CreateThread(function()
		local used = M.Use(src, key, plate)
		if not used.ok then
			-- The refusal AND a toast of the same code: without the toast the
			-- player would not know why nothing happened.
			OPX.Refuse(src, used.error, M.Operation.BRING)
			OPX.NotifyLocale(src, used.error, nil, 'error')
			TriggerClientEvent(M.Event.ANSWER, src, key, false, used.error)
			Open77.log.info(('[garages] player %d refused %s: %s'):format(src, safe(key),
				tostring(used.error)))
			return
		end
		-- The action travels with the answer and into the line, because the three
		-- outcomes read the same from the outside and do not mean the same thing:
		-- a car that came from the roster, one that had to be moved to this
		-- marker first, and one the player just handed over.
		local value = used.value
		local action = value.stored and 'stored' or (value.recalled and 'recalled' or 'brought')
		if value.stored then
			OPX.NotifyLocale(src, 'garages.storedAway', { plate = value.plate }, 'success')
		else
			OPX.NotifyLocale(src, 'garages.broughtOut', { plate = value.plate }, 'success')
		end
		TriggerClientEvent(M.Event.ANSWER, src, key, true, nil, value.plate, action)
		Open77.log.info(('[garages] player %d %s %s at %s'):format(src,
			action == 'stored' and 'put away' or (action == 'recalled' and 'moved' or 'brought out'),
			safe(value.plate), safe(value.spot)))
	end)
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Whether the ACL lets this player run a capture command.
-- The host resolves `command.<name>` before a COMMAND handler runs, and a net
-- event has no such gate of its own -- so the capture door asks the same
-- question here. An unreadable ACL answers no: a door that cannot be checked is
-- not one to leave open.
local function aclAllows(player, name)
	if type(name) ~= 'string' or name == '' then return false end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

-- Prints every spot: kind, position, and whether it came from config or the
-- database.
local function report(source)
	local lines = {}
	local keys, capturedCount = {}, 0
	for key in pairs(spots) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local spot = spots[keys[index]]
		local fromDatabase = captured[spot.key] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s %s pos=%.2f,%.2f,%.2f yaw=%.1f bucket=%d %s'):format(
			spot.key, spot.kind, spot.label, spot.x, spot.y, spot.z, spot.heading,
			spot.bucket, fromDatabase and 'captured' or 'config')
	end
	lines[#lines + 1] = ('%d spot(s): %d from config, %d captured')
		:format(#keys, #keys - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Saves one captured spot: the position from the server, the heading from the
--- client that asked.
-- The position is read HERE and never off the wire, so the yaw is the one field a
-- client contributes -- and it only turns a vehicle. Runs on a thread: the write
-- yields.
local function capture(player, kind, key, label, yaw, citizenId)
	local at = pointOf(player)
	if at == nil then
		return OPX.NotifyLocale(player, 'garages.noPosition', nil, 'error')
	end
	local read, position = pcall(Open77.players.position, player)
	local z = read and type(position) == 'table' and coordinate(position.z) or nil
	if z == nil then
		return OPX.NotifyLocale(player, 'garages.noPosition', nil, 'error')
	end

	local heading = Access.FiniteNumber(yaw)
	if heading == nil then heading = 0.0 end
	heading = heading % 360.0

	local spot, why = Access.FromDefinition(key, {
		KIND = kind, LABEL = label, X = at.x, Y = at.y, Z = z,
		HEADING = heading, BUCKET = at.bucket,
	})
	if spot == nil then
		-- Said in the node's log as well as to the player: a refusal only the
		-- player can see leaves whoever reads the log unable to tell a capture
		-- that was turned down from one that never arrived.
		Open77.log.warn(('[garages] player %d capture of %s refused: %s')
			:format(player, safe(key), safe(why)))
		OPX.NotifyLocale(player, 'garages.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = Store.Upsert(spot, citizenId)
	if not saved.ok then
		Open77.log.warn(('[garages] player %d could not save the capture of %s: %s')
			:format(player, safe(key), safe(saved.detail)))
		OPX.NotifyLocale(player, 'garages.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, 'could not save: ' .. tostring(saved.detail))
	end
	captured[key] = spot
	rebuild()
	-- The operator first and directly: they are looking at the marker they just
	-- placed, and a fan-out that cannot read the roster would otherwise leave the
	-- one person who cares without it.
	sync(player)
	syncAll()
	Open77.log.info(('[garages] %s captured as %s at %.2f,%.2f,%.2f yaw=%.1f by %d')
		:format(key, kind, spot.x, spot.y, spot.z, spot.heading, player))
	OPX.CommandResult(player, true, ('%s saved; check it in to survive a database reset:\n  %s = ' ..
		'{ LABEL = %q, KIND = %q, X = %.2f, Y = %.2f, Z = %.2f, HEADING = %.1f, BUCKET = %d },')
		:format(key, key, spot.label, spot.kind, spot.x, spot.y, spot.z, spot.heading,
			spot.bucket))
end

--- Registers the capture and diagnostic commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'garages.help.add',
		params = {
			{ name = 'kind', optional = true, help = locale('garages.help.addKind') },
			{ name = 'key', optional = true, help = locale('garages.help.addKey') },
			{ name = 'label', optional = true, help = locale('garages.help.addLabel') },
		},
	}, function(source, args)
		-- THE KIND AND THE KEY ARE BOTH OPTIONAL. The config file has always
		-- advertised the bare form -- "`/opx.garages.add` prints the line to check
		-- in here" -- but the handler demanded two positionals and answered the
		-- bare command with a string no player ever saw and no line in the server
		-- log, so the command read as dead. It is not dead: it captures a garage
		-- where the operator stands, under a key it names back to them.
		--
		-- One rule decides the slots: the first word names the KIND when it is one
		-- and is the KEY otherwise, in which case the kind is the garage the bare
		-- form means.
		local kind = type(args[1]) == 'string' and args[1]:lower() or ''
		local first = 1
		if Access.KINDS[kind] then
			first = 2
		else
			kind = M.KIND.GARAGE
		end
		local key = type(args[first]) == 'string' and args[first] or ''
		if #key > Access.MAX_KEY then
			Open77.log.warn(('[garages] player %d add refused: the key is %d characters, over %d')
				:format(source, #key, Access.MAX_KEY))
			return OPX.CommandResult(source, false,
				('usage: add [garage|avpad] [key] [label] -- a key is 1 to %d characters')
					:format(Access.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a spot whose key the operator never learned
			-- could not be brought out or removed afterwards.
			local index = 0
			repeat index = index + 1 until spots[kind .. index] == nil
			key = kind .. index
		end
		local label = ''
		for index = first + 1, #args do
			label = label .. (index > first + 1 and ' ' or '') .. tostring(args[index])
		end
		if #label > 64 then label = label:sub(1, 64) end

		-- The position is read below when the client answers; the HEADING is the
		-- operator's own facing, and a chat command has none. So the client is
		-- asked for it -- the one field a client contributes, and it only turns a
		-- vehicle -- exactly as a dropped pile is turned by the same answer.
		-- Recorded before the ask, so an answer that arrives immediately cannot be
		-- mistaken for one that arrived before it was ever requested.
		local at = OPX.Now()
		pending[source] = { at = at }
		TriggerClientEvent(M.Event.CAPTURE, source, kind, key, label)
		Open77.log.info(('[garages] asked player %d for the facing of %s %s')
			:format(source, kind, key))
		watchCapture(source, at, key)
		OPX.CommandResult(source, true, 'capturing where you are standing; look the way the ' ..
			'vehicle should point')
	end)

	register(names.remove, {
		restricted = true,
		help = 'garages.help.remove',
		params = { { name = 'key', help = locale('garages.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captured[key] == nil then
			return OPX.CommandResult(source, false, configSpots[key] ~= nil
				and 'that spot comes from config; edit config/garages.lua to remove it'
				or 'no captured spot named ' .. key)
		end
		CreateThread(function()
			local gone = Store.Delete(key)
			if not gone.ok then
				return OPX.CommandResult(source, false, 'could not delete: ' .. tostring(gone.detail))
			end
			captured[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[garages] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'garages.help.list' }, function(source)
		report(source)
	end)

	register(names.bring, {
		restricted = true,
		help = 'garages.help.bring',
		params = {
			{ name = 'key', optional = true, help = locale('garages.help.bringKey') },
			{ name = 'plate', optional = true, help = locale('garages.help.bringPlate') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or nil
		local plate = type(args[2]) == 'string' and args[2] or nil
		CreateThread(function()
			local brought = M.Bring(source, key, plate)
			if not brought.ok then
				OPX.NotifyLocale(source, brought.error, nil, 'error')
				return OPX.CommandResult(source, false, tostring(brought.error))
			end
			OPX.NotifyLocale(source, 'garages.broughtOut', { plate = brought.value.plate }, 'success')
			OPX.CommandResult(source, true, ('%s out at %s'):format(brought.value.plate,
				brought.value.label))
		end)
	end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and contributes this module's table. Never yields.
-- @author XEROX710
function M.Init()
	configSpots = Access.SPOTS
	captured = {}
	rebuild()
	windows = {}
	pending = {}
	running = false
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the garages contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('garages', 1, {
		Bring = M.Bring,
		Use = M.Use,
		Spots = function() return spots end,
		State = function()
			local listed = {}
			for key, spot in pairs(spots) do
				listed[key] = { kind = spot.kind, label = spot.label,
					captured = captured[key] ~= nil }
			end
			return Result.Ok({ spots = listed })
		end,
	})
end

--- Resolves the contracts, loads the captured spots and wires the two doors.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	vehicles = OPX.Api.Get('vehicles')
	if character == nil then
		Open77.log.warn('[garages] no character contract: nothing can be proved owned, so ' ..
			'every request is refused')
	end
	if vehicles == nil then
		Open77.log.error('[garages] no vehicles contract: no marker can bring anything out')
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[garages] config: ' .. line)
	end

	-- Both doors are registered whatever the database answered: an operator has
	-- to be able to read back what the configuration says, and `add` is how a
	-- database that answered nothing gets filled.
	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.REQUEST, onRequested)

	-- The capture door, gated exactly as the command that opens it: a net event
	-- has no host-side ACL check, so the same question is asked here. A client
	-- that sends this unprompted is either the operator or nobody.
	RegisterNetEvent(M.Event.CAPTURED, function(kind, key, label, yaw)
		local player = tonumber(source)
		if player == nil then return end

		-- Settled by the arrival itself, accepted or not: an answer is an answer,
		-- and a "did not answer" warning after one has landed would be a lie.
		pending[player] = nil

		local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
		if not aclAllows(player, names.add) then
			Open77.log.warn(('[garages] player %d tried to capture a spot without %s')
				:format(player, tostring(names.add)))
			return OPX.Refuse(player, 'error.noPermission', M.Operation.CAPTURE)
		end
		if not within(player, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
			Open77.log.warn(('[garages] player %d answered a capture too fast; refused')
				:format(player))
			return OPX.Refuse(player, 'error.tooFast', M.Operation.CAPTURE)
		end

		kind = type(kind) == 'string' and kind:lower() or ''
		key = type(key) == 'string' and key or ''
		label = type(label) == 'string' and label or ''
		if #label > 64 then label = label:sub(1, 64) end
		if not Access.KINDS[kind] or #key == 0 or #key > Access.MAX_KEY then
			Open77.log.warn(('[garages] player %d answered a capture for an unusable spot')
				:format(player))
			return OPX.Refuse(player, 'error.badRequest', M.Operation.CAPTURE)
		end

		local data = characterOf(player)
		CreateThread(function()
			capture(player, kind, key, label, yaw, data and data.citizenId or nil)
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then windows[player] = nil end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[garages] captured spots could not be read: ' ..
				tostring(rows.detail))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted, refused = 0, 0
		for index = 1, #loaded do
			local row = loaded[index]
			local spot, why = Access.FromDefinition(row.spot_key, {
				KIND = row.kind, LABEL = row.label,
				X = row.x, Y = row.y, Z = row.z, HEADING = row.heading, BUCKET = row.bucket,
			})
			if spot == nil then
				refused = refused + 1
				Open77.log.warn('[garages] captured row refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				captured[spot.key] = spot
			end
		end
		rebuild()
		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
		Open77.log.info(('[garages] ready: %d config, %d captured, %d refused'):format(
			(function()
				local count = 0
				for _ in pairs(configSpots) do count = count + 1 end
				return count
			end)(), accepted, refused))
	end)

	-- A sweep for the rate-limit windows, so a long session does not accumulate
	-- one per player that ever asked.
	CreateThread(function()
		while running do
			Wait(WINDOW_GC_MS)
			local at = OPX.Now()
			for player, window in pairs(windows) do
				if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
			end
		end
	end)
end

--- Stops the sweep. The spots are already durable, so there is nothing to write.
-- @author XEROX710
function M.Stop()
	running = false
	windows = {}
	pending = {}
end
