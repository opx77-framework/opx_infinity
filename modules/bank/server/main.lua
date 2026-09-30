--- Server half: the branches, their buckets, the three placement commands, and
--- every eddie that moves at a counter.
-- @author XEROX710
--
-- A TRANSACTION IS JUDGED HERE FROM SCRATCH. The press names a direction and
-- an amount (or "all of it"); everything else is read on this side: the
-- character loaded on the connection, the branch the body is standing on
-- (measured from the host's own position, in the body's own bucket), and the
-- balance at this moment. The money then moves in TWO audited steps through
-- the character contract -- out of one account, into the other -- and a
-- second step the contract refuses puts the first one back, so a transaction
-- either moves the whole amount or nothing. There is no step a client can
-- skip, no balance it can claim and no branch it can name.

local M = OPX.Modules.Get('bank')
local Access = M.Access
local Store = M.Storage
local Result = OPX.Result

-- The branches from config and the ones read back from the database, merged
-- into `spots` on every change.
local configSpots, captured = {}, {}
local spots = {}

-- The character contract, resolved in `Start`.
local character = nil

local MAX_LOGGED = 64

local coordinate = Access.Coordinate

local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

--- A connection's position and bucket, or nil.
-- @param source Source
-- @return table|nil x, y, z, bucket
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local at = type(position.position) == 'table' and position.position or position
	local x, y, z = coordinate(at.x), coordinate(at.y), coordinate(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = Access.Integer(position.bucket) or 0 }
end

local function rebuild()
	spots = {}
	for key, branch in pairs(configSpots) do spots[key] = branch end
	for key, branch in pairs(captured) do spots[key] = branch end
end

local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the branches of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then Open77.log.warn('[bank] sync failed: ' .. tostring(failure)) end
	end
end

--- The branch a connection is standing on, or nil.
-- @param player number
-- @return table|nil branch
function M.BranchOf(player)
	local at = pointOf(player)
	if at == nil then return nil end
	return Access.Nearest(Access.InBucket(spots, at.bucket), at.x, at.y)
end

--- Both balances of the character on a connection, or nil.
-- @param player number
-- @return table|nil `{ account, cash }`
local function balancesOf(player)
	if character == nil or type(character.GetMoney) ~= 'function' then return nil end
	local read, account = pcall(character.GetMoney, player, Access.ACCOUNT)
	local readCash, cash = pcall(character.GetMoney, player, Access.CASH)
	if not read or not readCash or tonumber(account) == nil or tonumber(cash) == nil then return nil end
	return { account = math.floor(tonumber(account)), cash = math.floor(tonumber(cash)) }
end

--- What the menu is drawn from: the branch and both balances, or the refusal.
-- @param player number
-- @return table a `Result`: `{ branch = { key, label }, account, cash, amounts }`
function M.State(player)
	player = tonumber(player)
	if player == nil or player <= 0 then return Result.Err('no_character') end
	local balances = balancesOf(player)
	if balances == nil then return Result.Err('no_character') end
	local branch = M.BranchOf(player)
	if branch == nil then return Result.Err('not_at_branch') end
	return Result.Ok({
		branch = { key = branch.key, label = branch.label },
		account = balances.account,
		cash = balances.cash,
		amounts = Access.AMOUNTS,
		max = Access.MAX_TRANSFER,
	})
end

--- Moves money between the account and the cash in hand, at a branch.
-- @param player number
-- @param kind string `withdraw` or `deposit`
-- @param amount any a whole number of eddies, or nil with `all`
-- @param all boolean move the whole balance of the side money leaves
-- @return table a `Result`: `{ kind, amount, account, cash, branch }`
function M.Move(player, kind, amount, all)
	player = tonumber(player)
	if player == nil or player <= 0 then return Result.Err('no_character') end
	if not M.KINDS[kind] then return Result.Err('bad_kind') end
	local balances = balancesOf(player)
	if balances == nil then return Result.Err('no_character') end
	local branch = M.BranchOf(player)
	if branch == nil then return Result.Err('not_at_branch') end

	local from, into = Access.ACCOUNT, Access.CASH
	local available = balances.account
	if kind == 'deposit' then
		from, into = Access.CASH, Access.ACCOUNT
		available = balances.cash
	end

	local value
	if all == true then
		if available <= 0 then return Result.Err('nothing') end
		value = math.min(available, Access.MAX_TRANSFER)
	else
		local number = tonumber(amount)
		if number ~= nil and number > Access.MAX_TRANSFER and number % 1 == 0 then
			return Result.Err('too_much', tostring(Access.MAX_TRANSFER))
		end
		value = M.Amount(amount, Access.MAX_TRANSFER)
		if value == nil then return Result.Err('bad_amount') end
		if value > available then return Result.Err('insufficient') end
	end

	local reason = ('bank:%s:%s'):format(kind, branch.key)
	local ranOut, out, outWhy = pcall(character.RemoveMoney, player, from, value, reason)
	if not ranOut or out ~= true then
		local why = ranOut and tostring(outWhy or 'refused') or tostring(out)
		Open77.log.warn(('[bank] player %d: %s of %d refused taking it out of %s: %s')
			:format(player, kind, value, from, why))
		return Result.Err(why == 'money.insufficient' and 'insufficient' or 'failed', why)
	end
	local ranIn, put, putWhy = pcall(character.AddMoney, player, into, value, reason)
	if not ranIn or put ~= true then
		-- THE FIRST STEP IS UNDONE, so the money is where it was: a transaction
		-- that took the money out and could not put it in is not allowed to
		-- stand as a loss.
		local back = select(2, pcall(character.AddMoney, player, from, value, 'bank:refund:' .. branch.key))
		Open77.log.error(('[bank] player %d: %s of %d could not be paid into %s (%s); %s')
			:format(player, kind, value, into, tostring(ranIn and putWhy or put),
				back == true and 'the money went back' or 'AND THE REFUND WAS REFUSED'))
		return Result.Err('failed', tostring(ranIn and putWhy or put))
	end

	local after = balancesOf(player) or balances
	Open77.log.info(('[bank] player %d at %s: %s %d (%s %d, %s %d)')
		:format(player, branch.key, kind, value, Access.ACCOUNT, after.account, Access.CASH, after.cash))
	return Result.Ok({
		kind = kind,
		amount = value,
		account = after.account,
		cash = after.cash,
		branch = { key = branch.key, label = branch.label },
	})
end

-- ── the commands ────────────────────────────────────────────────────────────

local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

local function report(source)
	local lines, keys, capturedCount = {}, {}, 0
	for key in pairs(spots) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local branch = spots[keys[index]]
		local fromDatabase = captured[branch.key] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s pos=%.2f,%.2f,%.2f bucket=%d %s'):format(
			branch.key, branch.label, branch.x, branch.y, branch.z, branch.bucket,
			fromDatabase and 'captured' or 'config')
	end
	lines[#lines + 1] = ('%d branch(es): %d from config, %d captured')
		:format(#keys, #keys - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Saves one captured branch at the position this half read for itself.
local function capture(player, key, label)
	local at = pointOf(player)
	if at == nil then return OPX.NotifyLocale(player, 'bank.noPosition', nil, 'error') end
	local branch, why = Access.FromDefinition(key, {
		LABEL = label, X = at.x, Y = at.y, Z = at.z, BUCKET = at.bucket,
	})
	if branch == nil then
		Open77.log.warn(('[bank] player %d capture of %s refused: %s'):format(player, safe(key), safe(why)))
		OPX.NotifyLocale(player, 'bank.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, tostring(why))
	end
	local saved = Store.Upsert(branch)
	if not saved.ok then
		Open77.log.warn(('[bank] player %d could not save the capture of %s: %s')
			:format(player, safe(key), safe(saved.detail)))
		OPX.NotifyLocale(player, 'bank.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, 'could not save; the reason is in the server log')
	end
	captured[key] = branch
	rebuild()
	sync(player)
	syncAll()
	Open77.log.info(('[bank] %s captured at %.2f,%.2f,%.2f bucket=%d by %d')
		:format(key, branch.x, branch.y, branch.z, branch.bucket, player))
	OPX.CommandResult(player, true, ('%s saved; check it in to survive a database reset:\n  %s = ' ..
		'{ LABEL = %q, X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d },')
		:format(key, key, branch.label, branch.x, branch.y, branch.z, branch.bucket))
end

local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'bank.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('bank.help.addKey') },
			{ name = 'label', optional = true, help = locale('bank.help.addLabel') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > Access.MAX_KEY then
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(Access.MAX_KEY))
		end
		if #key == 0 then
			local index = 0
			repeat index = index + 1 until spots['bank' .. index] == nil
			key = 'bank' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end
		if #label > 64 then label = label:sub(1, 64) end
		CreateThread(function() capture(source, key, label) end)
	end)

	register(names.remove, {
		restricted = true,
		help = 'bank.help.remove',
		params = { { name = 'key', help = locale('bank.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captured[key] == nil then
			return OPX.CommandResult(source, false, configSpots[key] ~= nil
				and 'that branch comes from config; edit config/bank.lua to remove it'
				or 'no captured branch named ' .. key)
		end
		CreateThread(function()
			local gone = Store.Delete(key)
			if not gone.ok then
				return OPX.CommandResult(source, false, 'could not delete; the reason is in the server log')
			end
			captured[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[bank] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'bank.help.list' }, function(source)
		report(source)
	end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

function M.Init()
	configSpots = Access.SPOTS
	captured = {}
	rebuild()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

function M.Api()
	OPX.Api.Provide('bank', 1, {
		Spots = function() return spots end,
		State = function(player) return M.State(player) end,
		Move = function(player, kind, amount, all) return M.Move(player, kind, amount, all) end,
	})
end

function M.Start()
	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[bank] config: ' .. line)
	end
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('[bank] no character contract: every branch will refuse')
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.OPEN, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		if OPX.Cooling(player, 'bank.open', 500) then return end
		local state = M.State(player)
		TriggerClientEvent(M.Event.STATE, player, state.ok and {
			ok = true,
			branch = state.value.branch,
			account = state.value.account,
			cash = state.value.cash,
			amounts = state.value.amounts,
			max = state.value.max,
		} or { ok = false, reason = tostring(state.error) })
	end)

	RegisterNetEvent(M.Event.MOVE, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 or type(payload) ~= 'table' then return end
		if OPX.Cooling(player, 'bank.move', 400) then
			return TriggerClientEvent(M.Event.RESULT, player, { ok = false, reason = 'busy' })
		end
		local moved = M.Move(player, payload.kind, payload.amount, payload.all == true)
		TriggerClientEvent(M.Event.RESULT, player, moved.ok and {
			ok = true,
			kind = moved.value.kind,
			amount = moved.value.amount,
			account = moved.value.account,
			cash = moved.value.cash,
			branch = moved.value.branch,
		} or { ok = false, kind = tostring(payload.kind), reason = tostring(moved.error),
			detail = moved.detail })
	end)

	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[bank] captured branches could not be read: ' .. tostring(rows.detail))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted, refused = 0, 0
		for index = 1, #loaded do
			local row = loaded[index]
			local branch, why = Access.FromDefinition(row.spot_key, {
				LABEL = row.label, X = row.x, Y = row.y, Z = row.z, BUCKET = row.bucket,
			})
			if branch == nil then
				refused = refused + 1
				Open77.log.warn('[bank] captured row refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				captured[branch.key] = branch
			end
		end
		rebuild()
		syncAll()
		Open77.log.info(('[bank] ready: %d config, %d captured, %d refused; %s <-> %s')
			:format(OPX.Table.Count(configSpots), accepted, refused, Access.ACCOUNT, Access.CASH))
	end)
end
