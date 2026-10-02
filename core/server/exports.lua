--- The creator surface, server half: what another Open77 resource may call.
-- @author dop42
--
-- LAST IN THE SERVER MANIFEST. Everything it wraps is a contract another file
-- publishes during the module phases, and an export registered at file scope is
-- supported -- so this file only has to exist after the modules, and it reads
-- every contract at the moment of the call rather than holding one.
--
-- WHY THIS EXISTS. Inside `opx_infinity` modules talk through `OPX.Api.Get`, and
-- that table lives in this VM: no other resource can reach it, and the old
-- `opx77_*` exports went away with the split into modules. A creator writing a
-- job, a shop or a heist as a resource of their own had nothing to call. The
-- devkit cards for `server:exports` (op77.45) and `GetInvokingResource` are the
-- platform's answer, and this is the curated set built on them.
--
-- THE ANSWER IS ALWAYS ONE PLAIN TABLE, the old opx77 export contract:
--
--   { ok = true, value = <answer> }          the value may be nil
--   { ok = false, error = <code> }           a stable code, branchable
--
-- one value and not `ok, code`, because a synchronous `exports.opx_infinity:X()`
-- and an awaited `Open77.exports.call` must read the same, and `local r = ...`
-- of a two-value answer silently keeps the boolean and drops the reason. An
-- export never raises: a body that does is logged and answered
-- `error.unavailable`.
--
-- EVERY CALL PASSES THREE GATES BEFORE ITS BODY:
--   1. the caller -- the name the HOST reports, never an argument;
--   2. the scope  -- `SERVER.EXPORTS.READ` for a question, `.WRITERS` for a
--                    change, both in `config/server.lua`;
--   3. the boot   -- nothing answers before the boot thread has settled.
-- and every argument is then checked again by the export AND by the contract
-- under it. The server stays the authority: a player id is a connection the
-- host knows, a citizen id is parsed, an amount is a whole positive number.
--
-- A WRITE IS AUDITED WITH ITS CALLER, `event=export.<Name>`, beside whatever the
-- module itself writes; money additionally carries `ext:<resource>:` in front
-- of its reason, so the money ledger line names who paid too.
--
-- CALL A WRITE WITH `Open77.exports.call(...)` AND AWAIT IT. A write, and any
-- read of a character who is not online, can reach the database, and the
-- synchronous form fails a callee that yields with `export_yielded`. Those
-- exports (AddMoneyOffline, the stash and key exports, SetVehicleState, and an
-- item export naming a citizen id) take one tick before touching anything, so
-- a synchronous call fails there with nothing begun, and then run on a thread
-- of this resource that a cancelled caller cannot leave half-done. The reads
-- of a loaded player (GetPlayerData, GetMoney, HasJob, GetJob, GetGang,
-- IsStaff) answer from memory and are safe either way.

local Result = OPX.Result

-- The version of THIS surface. Bumped on any breaking change to an export's
-- arguments or answer; a name is never reused for something else.
local SURFACE = 1

-- A resource name as the manifest grammar allows one, bounded.
local CALLER_PATTERN = '^[%w_%-%.]+$'

-- A money reason a caller may give, in characters.
local MAX_REASON = 64

-- Job, gang and stash names: what the configs use.
local NAME_PATTERN = '^[%w_%-%.]+$'

-- Callers already told how to be admitted, by `caller \1 export`, so a
-- resource retrying in a loop writes one hint and not one per tick.
local hinted = {}

local function refuse(code)
	return { ok = false, error = code }
end

local function ok(value)
	return { ok = true, value = value }
end

--- A contract Result as the plain answer the surface promises.
local function answered(result)
	if type(result) ~= 'table' then return refuse('error.unavailable') end
	if result.ok == true then return ok(result.value) end
	return refuse(type(result.error) == 'string' and result.error or 'error.unavailable')
end

local function settings()
	local server = OPX.Config.SERVER or {}
	return type(server.EXPORTS) == 'table' and server.EXPORTS or {}
end

--- Whether an allowlist admits a caller: '*', a set, or an array of names.
local function admits(list, caller)
	if list == '*' then return true end
	if type(list) ~= 'table' then return false end
	if list[caller] == true then return true end
	for _, name in ipairs(list) do
		if name == caller then return true end
	end
	return false
end

-- ── the arguments ────────────────────────────────────────────────────────────

--- A player id the host knows a connection for, or nil.
local function playerOf(value)
	local id = math.tointeger(tonumber(value))
	if type(value) ~= 'number' or id == nil or id < 1 or id > 2147483647 then return nil end
	if OPX.UserIdOf(id) == nil then return nil end
	return id
end

--- A citizen id in its canonical form, or nil.
local function citizenOf(value)
	if type(value) ~= 'string' then return nil end
	local parsed = OPX.CitizenId.Parse(value)
	return parsed.ok and parsed.value or nil
end

--- What an inventory call may name: a connected player id, or a citizen id.
local function targetOf(value)
	if type(value) == 'number' then return playerOf(value) end
	return citizenOf(value)
end

--- A bounded name, or nil.
local function nameOf(value, maximum)
	if type(value) ~= 'string' or #value < 1 or #value > (maximum or 48) then return nil end
	if not value:match(NAME_PATTERN) then return nil end
	return value
end

--- A whole number in bounds, or nil. `nil` in is answered as `fallback`.
local function countOf(value, low, high, fallback)
	if value == nil then return fallback end
	local n = math.tointeger(tonumber(value))
	if type(value) ~= 'number' or n == nil or n < low or n > high then return nil end
	return n
end

--- A money type this server has, or nil.
local function moneyTypeOf(value)
	local character = OPX.Api.Get('character')
	if type(value) ~= 'string' or character == nil or not character.IsMoneyType(value) then
		return nil
	end
	return value
end

--- A caller's reason, cleaned, bounded and named after its caller.
local function reasonOf(caller, value)
	local text = '-'
	if value ~= nil then
		if type(value) ~= 'string' then return nil end
		text = OPX.Text.Clean(value, MAX_REASON, '...') or '-'
	end
	return ('ext:%s:%s'):format(caller, text)
end

--- Metadata a caller may hand an inventory call: nil, or a plain table.
local function metadataOf(value)
	if value == nil then return true, nil end
	if type(value) ~= 'table' then return false, nil end
	return true, value
end

-- ── the gate ─────────────────────────────────────────────────────────────────

--- Whether a call of an export may yield, from its raw arguments.
local function mayYield(yields, args)
	if yields == true then return true end
	if type(yields) == 'function' then return yields(table.unpack(args, 1, args.n)) == true end
	return false
end

--- Runs a body that may yield on a thread of THIS resource, and waits for it.
--
-- A BODY THAT YIELDS MUST NOT BE ABANDONED HALF-WAY, and the host abandons an
-- export coroutine in two documented cases (devkit, server-exports): a
-- synchronous caller -- the callee "must not yield", the call fails with
-- `export_yielded` and nothing resumes it -- and an asynchronous caller that
-- times out, stops or reloads, which "cancels the target's scheduled task. This
-- stops future continuation; it cannot undo writes already performed". A body
-- abandoned there keeps whatever it held: the offline money ledger busy (every
-- login of that character refused until the stale guard, a minute later), an
-- inventory `loading` marker every later load of that stash or bag waits 35 s
-- on and then fails, and a statement already submitted whose caller was told
-- the call failed -- and retries it.
--
-- So two things, in this order. A PROBE: one `Wait(0)` before anything is
-- touched. A synchronous caller fails right there with nothing begun; an
-- asynchronous one loses a tick. Then the body runs on a thread THIS resource
-- owns, which no caller's lifetime can cancel, and the export coroutine only
-- waits on it: if that coroutine is abandoned, the body still finishes and
-- lets go of what it held.
-- @return boolean ran, any answer -- `pcall`'s shape
local function detached(body, caller, args)
	if not pcall(Wait, 0) then return true, refuse('export.mustAwait') end
	local box = { done = false }
	CreateThread(function()
		box.ran, box.answer = pcall(body, caller, table.unpack(args, 1, args.n))
		box.done = true
	end)
	while not box.done do Wait(0) end
	return box.ran, box.answer
end

--- Publishes one export behind the three gates.
-- @param name string the export name
-- @param scope string `read` or `write`
-- @param body fun(caller: string, ...): table the plain answer
-- @param yields boolean|fun(...): boolean|nil whether a call can yield -- reach
--   the database or wait -- given its raw arguments. Such a call is run
--   `detached`, above.
local function publish(name, scope, body, yields)
	if type(exports) ~= 'function' then return end
	exports(name, function(...)
		local caller = GetInvokingResource ~= nil and GetInvokingResource() or nil
		if type(caller) ~= 'string' or #caller < 1 or #caller > 64
			or not caller:match(CALLER_PATTERN) then
			return refuse('export.callerDenied')
		end

		local config = settings()
		local list = scope == 'write' and config.WRITERS or config.READ
		if not admits(list, caller) then
			OPX.Audit.Security('export.denied', ('%s called %s'):format(caller, name),
				{ caller = caller, export = name, scope = scope })
			local key = caller .. '\1' .. name
			if not hinted[key] then
				hinted[key] = true
				Open77.log.warn(('[exports] %s was refused %s; to admit it, add `%s = true` to ' ..
					'EXPORTS.%s in config/server.lua'):format(caller, name, caller,
					scope == 'write' and 'WRITERS' or 'READ'))
			end
			return refuse('export.callerDenied')
		end

		if not OPX.Booted then return refuse('export.booting') end

		local args = table.pack(...)
		local ran, answer
		if mayYield(yields, args) then
			ran, answer = detached(body, caller, args)
		else
			ran, answer = pcall(body, caller, table.unpack(args, 1, args.n))
		end
		if not ran then
			Open77.log.error(('[exports] %s raised for %s: %s')
				:format(name, caller, tostring(answer)))
			answer = refuse('error.unavailable')
		elseif type(answer) ~= 'table' then
			answer = refuse('error.unavailable')
		end

		if scope == 'write' then
			args.n = nil
			OPX.Audit.Log({
				event = 'export.' .. name,
				severity = answer.ok and 'info' or 'warn',
				message = caller,
				data = { caller = caller, args = args, error = answer.error },
			})
		end
		return answer
	end)
end

--- The loaded character at a player id, or nil and the refusal.
local function loaded(value)
	local character = OPX.Api.Get('character')
	if character == nil then return nil, refuse('error.unavailable') end
	local id = playerOf(value)
	if id == nil then return nil, refuse('export.badArgument') end
	local player = character.GetPlayer(id)
	if player == nil then return nil, refuse('error.notLoggedIn') end
	return player, nil, character
end

-- ── who a player is ──────────────────────────────────────────────────────────

publish('GetVersion', 'read', function()
	return ok({ version = OPX.VERSION, exports = SURFACE })
end)

publish('GetPlayerData', 'read', function(_, source)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	return ok(character.PublicView(player))
end)

publish('GetPlayerByCitizenId', 'read', function(_, citizenId)
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	local id = citizenOf(citizenId)
	if id == nil then return refuse('export.badArgument') end
	local player = character.GetPlayerByCitizenId(id)
	if player == nil then return refuse('error.notLoggedIn') end
	return ok(character.PublicView(player))
end)

publish('IsStaff', 'read', function(_, source)
	local id = playerOf(source)
	if id == nil then return refuse('export.badArgument') end
	local right = settings().STAFF_PERMISSION
	if type(right) ~= 'string' or right == '' then right = 'command.opx.admin' end
	-- The index is inside the pcall: a host without `acl.read` installs no
	-- `Open77.acl` at all, and that is "not staff", not a raise.
	local read, allowed = pcall(function() return Open77.acl.isAllowed(id, right) end)
	return ok(read and allowed == true)
end)

-- ── money ────────────────────────────────────────────────────────────────────

publish('GetMoney', 'read', function(_, source, moneyType)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if moneyType == nil then return ok(OPX.Table.DeepCopy(character.GetMoney(player))) end
	if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
	return ok(character.GetMoney(player, moneyType))
end)

--- The two loaded-character money doors share everything but the verb.
local function moneyDoor(verb)
	return function(caller, source, moneyType, amount, reason)
		local player, refused, character = loaded(source)
		if player == nil then return refused end
		if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
		local value = countOf(amount, 1, 9999999999, nil)
		if value == nil then return refuse('money.badAmount') end
		local why = reasonOf(caller, reason)
		if why == nil then return refuse('export.badArgument') end
		local done, code = character[verb](player, moneyType, value, why)
		if not done then return refuse(code or 'error.unavailable') end
		return ok(character.GetMoney(player, moneyType))
	end
end

publish('AddMoney', 'write', moneyDoor('AddMoney'))
publish('RemoveMoney', 'write', moneyDoor('RemoveMoney'))

publish('AddMoneyOffline', 'write', function(caller, citizenId, moneyType, amount, reason)
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	local id = citizenOf(citizenId)
	if id == nil then return refuse('export.badArgument') end
	if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
	local value = countOf(amount, 1, 9999999999, nil)
	if value == nil then return refuse('money.badAmount') end
	local why = reasonOf(caller, reason)
	if why == nil then return refuse('export.badArgument') end
	return answered(character.AddMoneyOffline(id, moneyType, value, why))
end, true)

-- ── jobs and gangs ───────────────────────────────────────────────────────────

publish('HasJob', 'read', function(_, source, name, onDuty, minGrade)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if nameOf(name) == nil then return refuse('export.badArgument') end
	if onDuty ~= nil and type(onDuty) ~= 'boolean' then return refuse('export.badArgument') end
	local grade = countOf(minGrade, 0, 255, false)
	if grade == nil then return refuse('export.badArgument') end
	return ok(character.HasJob(player, name, onDuty == true, grade or nil))
end)

publish('HasGang', 'read', function(_, source, name, minGrade)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if nameOf(name) == nil then return refuse('export.badArgument') end
	local grade = countOf(minGrade, 0, 255, false)
	if grade == nil then return refuse('export.badArgument') end
	return ok(character.HasGang(player, name, grade or nil))
end)

publish('GetJob', 'read', function(_, source)
	local player, refused = loaded(source)
	if player == nil then return refused end
	return ok(OPX.Table.DeepCopy(player.PlayerData.job))
end)

publish('GetGang', 'read', function(_, source)
	local player, refused = loaded(source)
	if player == nil then return refused end
	return ok(OPX.Table.DeepCopy(player.PlayerData.gang))
end)

-- ── items ────────────────────────────────────────────────────────────────────

--- The inventory contract, or nil.
local function inventory()
	return OPX.Api.Get('inventory')
end

--- Whether an item call names a citizen id, which loads an offline bag and
--- yields; a player id answers from the bag already loaded.
local function byCitizen(target)
	return type(target) == 'string'
end

--- The checked arguments every item export takes, or the refusal.
local function itemArgs(target, name, count, metadata, countRequired)
	local who = targetOf(target)
	if who == nil then return nil, refuse('export.badArgument') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then
		return nil, refuse('export.badArgument')
	end
	local units = countOf(count, 1, 1000000, countRequired and nil or 1)
	if units == nil then return nil, refuse('export.badArgument') end
	local fits, meta = metadataOf(metadata)
	if not fits then return nil, refuse('export.badArgument') end
	return { target = who, name = name, count = units, metadata = meta }, nil
end

publish('HasItem', 'read', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	local counted = api.GetItemCount(args.target, args.name, args.metadata)
	if not counted.ok then return answered(counted) end
	return ok(counted.value >= args.count)
end, byCitizen)

publish('CountItem', 'read', function(_, target, name, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, nil, metadata, false)
	if args == nil then return refused end
	return answered(api.GetItemCount(args.target, args.name, args.metadata))
end, byCitizen)

publish('AddItem', 'write', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	return answered(api.AddItem(args.target, args.name, args.count, args.metadata))
end, byCitizen)

publish('RemoveItem', 'write', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	return answered(api.RemoveItem(args.target, args.name, args.count, args.metadata))
end, byCitizen)

-- ── stashes ──────────────────────────────────────────────────────────────────

--- The checked arguments every stash export takes, or the refusal.
local function stashArgs(stash, item, count, metadata)
	if nameOf(stash) == nil then return nil, refuse('export.badArgument') end
	if type(item) ~= 'string' or #item < 1 or #item > 64 then
		return nil, refuse('export.badArgument')
	end
	local units = countOf(count, 1, 1000000, 1)
	if units == nil then return nil, refuse('export.badArgument') end
	local fits, meta = metadataOf(metadata)
	if not fits then return nil, refuse('export.badArgument') end
	return { stash = stash, item = item, count = units, metadata = meta }, nil
end

publish('CountInStash', 'read', function(_, stash, item, metadata)
	local api = inventory()
	if api == nil or api.CountInStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, nil, metadata)
	if args == nil then return refused end
	return answered(api.CountInStash(args.stash, args.item, args.metadata))
end, true)

publish('AddToStash', 'write', function(_, stash, item, count, metadata)
	local api = inventory()
	if api == nil or api.AddToStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, count, metadata)
	if args == nil then return refused end
	return answered(api.AddToStash(args.stash, args.item, args.count, args.metadata))
end, true)

publish('RemoveFromStash', 'write', function(_, stash, item, count, metadata)
	local api = inventory()
	if api == nil or api.RemoveFromStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, count, metadata)
	if args == nil then return refused end
	return answered(api.RemoveFromStash(args.stash, args.item, args.count, args.metadata))
end, true)

-- ── chat ─────────────────────────────────────────────────────────────────────

publish('SendChat', 'write', function(_, target, message)
	local chat = OPX.Api.Get('chat')
	if chat == nil or chat.Send == nil then return refuse('error.unavailable') end
	return answered(chat.Send(target, message))
end)

publish('BroadcastChat', 'write', function(_, message, options)
	local chat = OPX.Api.Get('chat')
	if chat == nil or chat.Broadcast == nil then return refuse('error.unavailable') end
	if options ~= nil and type(options) ~= 'table' then return refuse('export.badArgument') end
	return answered(chat.Broadcast(message, options))
end)

-- ── vehicles and keys ────────────────────────────────────────────────────────

publish('RevokeKeys', 'write', function(_, target, plate)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.Revoke == nil then return refuse('error.unavailable') end
	local who = targetOf(target)
	if who == nil or type(plate) ~= 'string' then return refuse('export.badArgument') end
	return answered(keys.Revoke(who, plate))
end, true)

publish('RevokeAllKeys', 'write', function(_, plate)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.RevokeAll == nil then return refuse('error.unavailable') end
	if type(plate) ~= 'string' then return refuse('export.badArgument') end
	return answered(keys.RevokeAll(plate))
end, true)

publish('SetVehicleState', 'write', function(_, plate, state, garage)
	local vehicles = OPX.Api.Get('vehicles')
	if vehicles == nil or vehicles.SetState == nil then return refuse('error.unavailable') end
	if type(plate) ~= 'string' or type(state) ~= 'string' then
		return refuse('export.badArgument')
	end
	if garage ~= nil and nameOf(garage) == nil then return refuse('export.badArgument') end
	return answered(vehicles.SetState(plate, state, garage))
end, true)

if type(exports) ~= 'function' then
	Open77.log.warn('[exports] this host has no `exports`: the creator surface is not published')
end
