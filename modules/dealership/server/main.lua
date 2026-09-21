--- Server half: the dealers, what each one sells, and the purchase itself.
-- @author XEROX710
--
-- Everything the client believes is re-derived here before money moves: a
-- request is a hint, and the mask is these checks. The distance is measured
-- across the ground against the DECLARED position, exactly as the client
-- measures it, the bucket must agree, the model must be one THIS dealer sells,
-- and the money must really be there.
--
-- THE ORDER OF THE TWO WRITES IS NOT FREE. A purchase moves money and creates a
-- vehicle, and only one of those can be undone: the character contract can give
-- money back, and the vehicles contract creates a row and offers no way to
-- remove one. So the charge goes first and the registration second, and a
-- registration that is refused -- the ceiling, a refused insertion, a plate that
-- could not be drawn -- is answered with a refund of exactly what was taken. The
-- reverse order would hand out a free car every time a row could not be written.
--
-- This module owns no vehicle and no plate. What a character owns, and every
-- rule about how much of it they may own, stays in one place: the vehicles
-- contract.
--
-- A dealer captured in game lives in the database and is merged OVER the config
-- by key, so a dealer checked in at `config/dealership.lua` can be moved in game
-- and the checked-in value is what a database reset falls back to.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('dealership')
local Access = M.Access

local Result = OPX.Result
local Store = M.Storage

-- The dealers an operator checked in, and the ones captured in game.
local configSpots = {}
local captured = {}

-- Config overlaid by captured: the one list every read below uses.
local spots = {}

-- Per-player rate-limit windows for requests that are not rate-limited by
-- `OPX.Cooling`.
local windows = {}

-- The capture request each connection has not answered yet: `{ at = ms }`, by
-- player id. `add` cannot know a facing, so it asks the client for one, and an
-- answer that never comes has to settle itself rather than leaving the operator
-- believing a dealer was placed.
local pending = {}

-- The contracts, resolved in `Start`. `character` and `vehicles` nil means
-- nothing can be charged or owned and every purchase is refused; `garages` nil
-- costs one choice -- which garage the vehicle is filed under -- and nothing
-- else, because the vehicles module has a default of its own.
local character, vehicles, garages

-- The currency a price is denominated in, settled in `Start`, and nil when the
-- character contract does not know it. Nil refuses every purchase.
local currency

-- What is for sale, as the client reads it: `{ garage = {...}, avpad = {...} }`.
-- Built once in `Start`, because the formatted price needs the character
-- contract, and a client that formatted its own would be a second answer to the
-- same question.
local stockFor = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }

-- Whether the loop that sweeps rate-limit windows is running.
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

-- One capture request's identity, so a watcher cannot expire a request that
-- replaced it. `at` is monotonic and taken once.
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
			('[dealership] player %d did not answer the capture of %s within %d ms; ' ..
				'nothing was saved'):format(player, safe(key), Access.CAPTURE_TIMEOUT_MS))
		OPX.NotifyLocale(player, 'dealership.captureNoAnswer', { key = safe(key) }, 'error')
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

--- The dealers of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the dealers of their own bucket and what is for sale.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
	TriggerClientEvent(M.Event.STOCK, player, { kinds = stockFor })
end

--- Sends every connected player their own list. Guarded: a capture must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[dealership] sync failed: ' .. tostring(failure))
		end
	end
end

--- Answers a destination garage a purchase named, or nil when it may not be used.
-- The rules are all here and none of them are the client's: the named place has
-- to exist, be a place of the SAME category as the dealer (a car is not filed to
-- an AV pad) and be in the player's own routing bucket.
-- @author XEROX710
-- @param key any
-- @param kind string
-- @param bucket integer
-- @return table|nil
local function destination(key, kind, bucket)
	if garages == nil or type(key) ~= 'string' or key == '' then return nil end
	local listed = garages.Spots()
	local spot = type(listed) == 'table' and Access.Spot(listed, key) or nil
	if spot == nil or spot.kind ~= kind or spot.bucket ~= bucket then return nil end
	return spot
end

--- Buys one model from the dealer the connection is standing on.
-- @author XEROX710
-- @param source Source
-- @param dealerKey string|nil the dealer's name; the nearest one when omitted
-- @param entryKey string the stock row being bought
-- @param destKey string|nil the garage the vehicle is filed under
-- @return Result
function M.Buy(source, dealerKey, entryKey, destKey)
	if vehicles == nil then return Result.Err('dealership.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('dealership.noCharacter')
	end
	local at = pointOf(source)
	if at == nil then return Result.Err('dealership.noPosition') end

	local dealer = nil
	if dealerKey == nil or dealerKey == '' then
		dealer = Access.Nearest(spots, at.x, at.y)
	else
		dealer = Access.Spot(spots, dealerKey)
	end
	if dealer == nil then return Result.Err('dealership.noSuchSpot') end
	if dealer.bucket ~= at.bucket then return Result.Err('dealership.wrongBucket') end

	local flat = Access.FlatDistanceSquared(dealer, at.x, at.y)
	if flat == nil or flat > Access.USE_RADIUS_SQ then
		return Result.Err('dealership.tooFar', dealer.key)
	end

	local entry = Access.Entry(entryKey)
	if entry == nil then return Result.Err('dealership.noSuchEntry') end
	-- WHAT THIS DEALER SELLS, and it is the dealer's category that decides: a
	-- garage sells ground vehicles, a pad sells AVs. A row is refused rather
	-- than quietly redirected to the dealer that does stock it.
	if not Access.SoldHere(dealer.kind, entry) then
		return Result.Err('dealership.notSold', entry.key)
	end
	if currency == nil then return Result.Err('dealership.noCurrency') end

	-- Read before anything is charged, so the common refusal costs the player
	-- nothing at all: the money is still re-checked by the removal itself, which
	-- is the only check that counts -- this one is the courtesy.
	local balance = character.GetMoney(source, currency)
	if type(balance) ~= 'number' or balance < entry.price then
		return Result.Err('dealership.cannotAfford', entry.key)
	end

	local dest = nil
	if type(destKey) == 'string' and destKey ~= '' then
		dest = destination(destKey, dealer.kind, at.bucket)
		if dest == nil then return Result.Err('dealership.noSuchGarage', destKey) end
	end

	-- ── the purchase ─────────────────────────────────────────────────────
	local paid, refusal = character.RemoveMoney(source, currency, entry.price,
		'dealership:' .. entry.key)
	if not paid then
		-- The character contract answers a catalogue key of its own
		-- (`money.insufficient`, `money.offline`), which is a code the player
		-- can be shown; anything that is not a string is a fault of ours.
		return Result.Err(type(refusal) == 'string' and refusal or 'dealership.paymentFailed')
	end

	-- GUARDED, BECAUSE OF WHAT IS ON THE OTHER SIDE OF IT. The row is written by
	-- another module, and a throw inside it unwinds THIS frame -- past the refund
	-- below and out of the caller -- so the player is charged and owns nothing,
	-- with no line anywhere that says how much. That is not hypothetical: a
	-- setting `vehicles` never received made `Register` compare a nil, the money
	-- went out twice and not one row was written. A throw is a refusal like any
	-- other, and the message is kept for the log so the next one is diagnosable.
	local answered, made = pcall(vehicles.Register, data.citizenId, entry.record, {
		garage = dest ~= nil and dest.key or nil,
	})
	if not answered then
		Open77.log.error(('[dealership] %s: vehicles.Register threw for %s: %s')
			:format(tostring(data.citizenId), entry.key, tostring(made)))
		made = Result.Err('dealership.registerFailed')
	elseif type(made) ~= 'table' then
		-- THE OTHER WAY THE SAME MONEY GETS LOST. The pcall above guards a THROW;
		-- this guards a RETURN that is not a Result. `made.ok` on a nil raises
		-- here, three lines after `RemoveMoney` and before the refund that the
		-- comment above exists to protect -- so the throw the pcall was added to
		-- survive would simply move down the function. A contract that answers
		-- the wrong shape is a refusal like any other.
		Open77.log.error(('[dealership] %s: vehicles.Register answered a %s for %s')
			:format(tostring(data.citizenId), type(made), entry.key))
		made = Result.Err('dealership.registerFailed')
	end
	if not made.ok then
		-- THE HALF THAT CAN BE UNDONE. Nothing was owned, so the money goes
		-- back; a refund that itself fails is the one outcome that costs a
		-- player money, and it is said in the log with everything needed to
		-- settle it by hand.
		local back, why = character.AddMoney(source, currency, entry.price,
			'dealership:refund:' .. entry.key)
		if not back then
			Open77.log.error(
				('[dealership] %s was charged %d %s for %s and the vehicle was refused (%s); ' ..
					'the refund ALSO failed (%s) -- settle this by hand')
					:format(tostring(data.citizenId), entry.price, currency, entry.key,
						tostring(made.error), tostring(why)))
		else
			Open77.log.warn(
				('[dealership] %s refused %s after payment (%s); %d %s refunded')
					:format(tostring(data.citizenId), entry.key, tostring(made.error),
						entry.price, currency))
		end
		return made
	end

	local plate = made.value and made.value.plate or nil
	local handOver = M.Settings.HAND_OVER ~= false
	local spawned = false

	if handOver and plate ~= nil then
		-- AT THE DEALER, turned to the dealer's own heading, so a bought car
		-- appears where it was bought rather than a car's width to one side.
		-- An AV is lifted clear of the ground it is sold on.
		local z = dealer.z
		if entry.av then z = z + Access.AvLift() end
		local handed = vehicles.Spawn(source, plate, {
			x = dealer.x, y = dealer.y, z = z,
			yaw = dealer.heading,
			bucket = dealer.bucket,
		})
		spawned = handed.ok == true
		if not spawned then
			-- NOT A FAILED SALE. The vehicle is owned and it is filed under the
			-- garage the player chose, so it comes out there; the hand-over is
			-- the convenience, and its refusal is reported rather than undone.
			Open77.log.warn(('[dealership] %s owns %s but the hand-over at %s was refused: %s')
				:format(tostring(data.citizenId), tostring(plate), safe(dealer.key),
					tostring(handed.error)))
		end
	end

	local player = character.GetPlayer(source)
	if player ~= nil then
		OPX.Audit.Player(player, 'dealership.buy', tostring(plate), {
			entry = entry.key,
			dealer = dealer.key,
			garage = dest ~= nil and dest.key or '',
			price = tostring(entry.price),
			currency = currency,
		})
	end
	Open77.log.info(('[dealership] %s bought %s (%s) at %s for %d %s%s'):format(
		tostring(data.citizenId), safe(entry.key), safe(entry.record), safe(dealer.key),
		entry.price, currency, dest ~= nil and (' -> ' .. safe(dest.key)) or ''))

	return Result.Ok({
		plate = plate,
		entry = entry.key,
		model = entry.label,
		dealer = dealer.key,
		label = dealer.label,
		garage = dest ~= nil and dest.key or nil,
		price = entry.price,
		currency = currency,
		spawned = spawned,
	})
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- One purchase off the wire. Rate-limited, then answered either way.
local function onRequested(dealerKey, entryKey, destKey)
	local src = tonumber(source)
	if src == nil then return end
	if dealerKey ~= nil and type(dealerKey) ~= 'string' then dealerKey = nil end
	if destKey ~= nil and type(destKey) ~= 'string' then destKey = nil end
	if type(entryKey) ~= 'string' or entryKey == '' then
		return OPX.Refuse(src, 'error.badRequest', M.Operation.BUY)
	end

	-- The floor between two purchases. Long enough that a double-tap on a menu
	-- row is one car: the menu closes on the first press and a second is a
	-- request the player did not mean to make.
	if Access.COOLDOWN_MS > 0 and OPX.Cooling(src, 'dealership.buy', Access.COOLDOWN_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.BUY)
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.BUY)
	end

	CreateThread(function()
		local bought = M.Buy(src, dealerKey, entryKey, destKey)
		if not bought.ok then
			-- The refusal AND a toast of the same code: without the toast the
			-- player would not know why nothing happened.
			OPX.Refuse(src, bought.error, M.Operation.BUY)
			OPX.NotifyLocale(src, bought.error, nil, 'error')
			TriggerClientEvent(M.Event.ANSWER, src, false, bought.error, entryKey)
			Open77.log.info(('[dealership] player %d refused %s: %s'):format(src,
				safe(entryKey), tostring(bought.error)))
			return
		end
		local value = bought.value
		OPX.NotifyLocale(src, 'dealership.bought',
			{ model = value.model, plate = value.plate }, 'success')
		TriggerClientEvent(M.Event.ANSWER, src, true, nil, entryKey, value)
		Open77.log.info(('[dealership] player %d bought %s'):format(src, safe(value.plate)))
	end)
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Whether the ACL lets this player run a placement command.
-- The host resolves `command.<name>` before a COMMAND handler runs, and a net
-- event has no such gate of its own -- so the capture door asks the same
-- question here. An unreadable ACL answers no.
local function aclAllows(player, name)
	if type(name) ~= 'string' or name == '' then return false end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

--- Prints the stock the way the catalogue reads: class, model, price and which
--- kind of dealer sells it.
local function reportStock(source)
	local entries = {}
	for kind in pairs(Access.KINDS) do
		local listed = Access.For(kind)
		for index = 1, #listed do
			local entry = listed[index]
			entries[#entries + 1] = ('%s %s %s %s %s'):format(
				kind, entry.class, entry.key, entry.label,
				currency ~= nil and character ~= nil
					and character.FormatMoney(entry.price, currency)
					or tostring(entry.price))
		end
	end
	table.sort(entries)
	if #entries == 0 then
		return OPX.CommandResult(source, true, 'the stock list is empty: nothing is for sale')
	end
	entries[#entries + 1] = ('%d row(s); %d garage, %d avpad'):format(#entries,
		#Access.For(M.KIND.GARAGE), #Access.For(M.KIND.AVPAD))
	OPX.CommandResult(source, true, table.concat(entries, '\n'))
end

--- Prints every dealer: kind, position and whether it came from config or the
--- database.
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
	lines[#lines + 1] = ('%d dealer(s): %d from config, %d captured')
		:format(#keys, #keys - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Saves one captured dealer: the position from the server, the heading from the
--- client that asked. Runs on a thread: the write yields.
local function capture(player, kind, key, label, yaw, citizenId)
	local at = pointOf(player)
	if at == nil then
		return OPX.NotifyLocale(player, 'dealership.noPosition', nil, 'error')
	end
	local read, position = pcall(Open77.players.position, player)
	local z = read and type(position) == 'table' and coordinate(position.z) or nil
	if z == nil then
		return OPX.NotifyLocale(player, 'dealership.noPosition', nil, 'error')
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
		Open77.log.warn(('[dealership] player %d capture of %s refused: %s')
			:format(player, safe(key), safe(why)))
		OPX.NotifyLocale(player, 'dealership.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = Store.Upsert(spot, citizenId)
	if not saved.ok then
		Open77.log.warn(('[dealership] player %d could not save the capture of %s: %s')
			:format(player, safe(key), safe(saved.detail)))
		OPX.NotifyLocale(player, 'dealership.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, 'could not save; the reason is in the server log')
	end
	captured[key] = spot
	rebuild()
	-- The operator first and directly: they are looking at the marker they just
	-- placed, and a fan-out that cannot read the roster would otherwise leave
	-- the one person who cares without it.
	sync(player)
	syncAll()
	Open77.log.info(('[dealership] %s captured as %s at %.2f,%.2f,%.2f yaw=%.1f by %d')
		:format(key, kind, spot.x, spot.y, spot.z, spot.heading, player))
	OPX.CommandResult(player, true, ('%s saved; check it in to survive a database reset:\n  %s = ' ..
		'{ LABEL = %q, KIND = %q, X = %.2f, Y = %.2f, Z = %.2f, HEADING = %.1f, BUCKET = %d },')
		:format(key, key, spot.label, spot.kind, spot.x, spot.y, spot.z, spot.heading,
			spot.bucket))
end

--- Registers the placement, listing and purchase commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'dealership.help.add',
		params = {
			{ name = 'kind', optional = true, help = locale('dealership.help.addKind') },
			{ name = 'key', optional = true, help = locale('dealership.help.addKey') },
			{ name = 'label', optional = true, help = locale('dealership.help.addLabel') },
		},
	}, function(source, args)
		-- THE KIND AND THE KEY ARE BOTH OPTIONAL, exactly as the garages
		-- command they are modelled on: one rule decides the slots, and the
		-- first word names the KIND when it is one and is the KEY otherwise.
		local kind = type(args[1]) == 'string' and args[1]:lower() or ''
		local first = 1
		if Access.KINDS[kind] then
			first = 2
		else
			kind = M.KIND.GARAGE
		end
		local key = type(args[first]) == 'string' and args[first] or ''
		if #key > Access.MAX_KEY then
			Open77.log.warn(('[dealership] player %d add refused: the key is %d characters, over %d')
				:format(source, #key, Access.MAX_KEY))
			return OPX.CommandResult(source, false,
				('usage: add [garage|avpad] [key] [label] -- a key is 1 to %d characters'):format(
					Access.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a dealer whose key the operator never
			-- learned could not be used or removed afterwards.
			local index = 0
			repeat index = index + 1 until spots[kind .. index] == nil
			key = kind .. index
		end
		local label = ''
		for index = first + 1, #args do
			label = label .. (index > first + 1 and ' ' or '') .. tostring(args[index])
		end
		if #label > 64 then label = label:sub(1, 64) end

		-- The position is read when the client answers; the HEADING is the
		-- operator's own facing, and a chat command has none. Recorded before
		-- the ask, so an answer that arrives immediately cannot be mistaken for
		-- one that arrived before it was ever requested.
		local at = OPX.Now()
		pending[source] = { at = at }
		TriggerClientEvent(M.Event.CAPTURE, source, kind, key, label)
		Open77.log.info(('[dealership] asked player %d for the facing of %s %s')
			:format(source, kind, key))
		watchCapture(source, at, key)
		OPX.CommandResult(source, true, 'capturing where you are standing; look the way a ' ..
			'vehicle sold here should point')
	end)

	register(names.remove, {
		restricted = true,
		help = 'dealership.help.remove',
		params = { { name = 'key', help = locale('dealership.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captured[key] == nil then
			return OPX.CommandResult(source, false, configSpots[key] ~= nil
				and 'that dealer comes from config; edit config/dealership.lua to remove it'
				or 'no captured dealer named ' .. key)
		end
		CreateThread(function()
			local gone = Store.Delete(key)
			if not gone.ok then
				return OPX.CommandResult(source, false, 'could not delete; the reason is in the server log')
			end
			captured[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[dealership] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'dealership.help.list' }, function(source)
		report(source)
	end)

	register(names.stock, { restricted = false, help = 'dealership.help.stock' }, function(source)
		reportStock(source)
	end)

	register(names.buy, {
		restricted = false,
		help = 'dealership.help.buy',
		params = {
			{ name = 'key', help = locale('dealership.help.buyKey') },
			{ name = 'garage', optional = true, help = locale('dealership.help.buyGarage') },
		},
		cooldownMs = Access.COOLDOWN_MS,
	}, function(source, args)
		local entryKey = type(args[1]) == 'string' and args[1] or ''
		if #entryKey == 0 then
			return OPX.CommandResult(source, false, 'usage: buy <key> [garage] -- stand on a ' ..
				'dealership marker; /' .. tostring(names.stock or '') .. ' lists what is for sale')
		end
		local destKey = type(args[2]) == 'string' and args[2] or nil
		CreateThread(function()
			local bought = M.Buy(source, nil, entryKey, destKey)
			if not bought.ok then
				OPX.NotifyLocale(source, bought.error, nil, 'error')
				return OPX.CommandResult(source, false, tostring(bought.error))
			end
			local value = bought.value
			OPX.NotifyLocale(source, 'dealership.bought',
				{ model = value.model, plate = value.plate }, 'success')
			OPX.CommandResult(source, true, ('%s bought: %s%s'):format(value.model,
				tostring(value.plate),
				value.garage ~= nil and (' delivered to ' .. tostring(value.garage)) or ''))
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
	currency = nil
	stockFor = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the dealership contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('dealership', 1, {
		Buy = M.Buy,
		Spots = function() return spots end,
		Stock = function()
			local listed = {}
			for key, entry in pairs(Access.STOCK) do
				listed[key] = { label = entry.label, class = entry.class,
					price = entry.price, av = entry.av }
			end
			return Result.Ok({ currency = currency, stock = listed })
		end,
		State = function()
			local dealers = {}
			for key, spot in pairs(spots) do
				dealers[key] = { kind = spot.kind, label = spot.label,
					captured = captured[key] ~= nil }
			end
			local total = OPX.Table.Count(Access.STOCK)
			return Result.Ok({ dealers = dealers, stock = total, currency = currency })
		end,
	})
end

--- Resolves the contracts, reads the captured dealers and wires the doors.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	vehicles = OPX.Api.Get('vehicles')
	garages = OPX.Api.Get('garages')

	if character == nil then
		Open77.log.warn('[dealership] no character contract: nothing can be charged or proved ' ..
			'owned, so every purchase is refused')
	end
	if vehicles == nil then
		Open77.log.error('[dealership] no vehicles contract: nothing can be sold, and every ' ..
			'purchase is refused')
	end
	-- Said once, at start, because the difference is one choice and not a
	-- broken dealership: without it the vehicles module's own default garage is
	-- where a bought vehicle is filed.
	if garages == nil then
		Open77.log.info('[dealership] no garages contract: a purchase is filed under the ' ..
			'vehicles module\'s default garage, and no destination can be chosen')
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[dealership] config: ' .. line)
	end

	-- THE CURRENCY IS CHECKED ONCE, HERE. A price denominated in something the
	-- character contract does not know would refuse every purchase with
	-- `money.badType` in the middle of a player's evening; said at boot it is a
	-- line an operator reads after editing the config, and every purchase
	-- afterwards refuses with one code that names the configuration.
	currency = type(M.Settings.CURRENCY) == 'string' and M.Settings.CURRENCY or nil
	if character ~= nil and currency ~= nil and not character.IsMoneyType(currency) then
		Open77.log.error(('[dealership] CURRENCY %s is not a money type on this server: ' ..
			'nothing can be sold until it is fixed'):format(tostring(currency)))
		currency = nil
	end

	-- The stock as a client reads it, with the price formatted by the contract
	-- that owns the currency table. Built once: a payload rebuilt per ask would
	-- format the whole catalogue on every poll of every player.
	for kind in pairs(Access.KINDS) do
		local rows = {}
		local listed = Access.For(kind)
		for index = 1, #listed do
			local entry = listed[index]
			local text = currency ~= nil and character ~= nil
				and character.FormatMoney(entry.price, currency)
				or tostring(entry.price)
			rows[index] = Access.Wire(entry, text)
		end
		stockFor[kind] = rows
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

	RegisterNetEvent(M.Event.BUY, onRequested)

	-- The capture door, gated exactly as the command that opens it: a net event
	-- has no host-side ACL check, so the same question is asked here.
	RegisterNetEvent(M.Event.CAPTURED, function(kind, key, label, yaw)
		local player = tonumber(source)
		if player == nil then return end

		-- Settled by the arrival itself, accepted or not: an answer is an
		-- answer, and a "did not answer" warning after one has landed would be
		-- a lie.
		pending[player] = nil

		local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
		if not aclAllows(player, names.add) then
			Open77.log.warn(('[dealership] player %d tried to capture a dealer without %s')
				:format(player, tostring(names.add)))
			return OPX.Refuse(player, 'error.noPermission', M.Operation.CAPTURE)
		end
		if not within(player, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
			Open77.log.warn(('[dealership] player %d answered a capture too fast; refused')
				:format(player))
			return OPX.Refuse(player, 'error.tooFast', M.Operation.CAPTURE)
		end

		kind = type(kind) == 'string' and kind:lower() or ''
		key = type(key) == 'string' and key or ''
		label = type(label) == 'string' and label or ''
		if #label > 64 then label = label:sub(1, 64) end
		if not Access.KINDS[kind] or #key == 0 or #key > Access.MAX_KEY then
			Open77.log.warn(('[dealership] player %d answered a capture for an unusable dealer')
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
		if player ~= nil then
			windows[player] = nil
			pending[player] = nil
		end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[dealership] captured dealers could not be read: ' ..
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
				Open77.log.warn('[dealership] captured row refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				captured[spot.key] = spot
			end
		end
		rebuild()
		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
		local inConfig = OPX.Table.Count(configSpots)
		Open77.log.info(('[dealership] ready: %d config, %d captured, %d refused; ' ..
			'%d garage row(s) and %d avpad row(s) for sale in %s'):format(
			inConfig, accepted, refused, #Access.For(M.KIND.GARAGE), #Access.For(M.KIND.AVPAD),
			tostring(currency or 'no currency')))
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

--- Stops the sweep. The dealers are already durable, so there is nothing to write.
-- @author XEROX710
function M.Stop()
	running = false
	windows = {}
	pending = {}
end
