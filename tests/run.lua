--- Boots the runtime off-platform and checks that the module lifecycle holds.
-- @author dop42
--
--   lua tests/run.lua        from the resource root
--
-- The registry is the one genuinely new piece of machinery in this resource.
-- Everything else is code that already worked somewhere else, so this is where
-- the tests are.

local Host = dofile('tests/host.lua')

local failures, checks = 0, 0

local function check(label, ok, detail)
	checks = checks + 1
	if ok then
		print(('  ok   %s'):format(label))
	else
		failures = failures + 1
		print(('  FAIL %s%s'):format(label, detail and ('  -- ' .. tostring(detail)) or ''))
	end
end

local function section(name) print(('\n== %s'):format(name)) end

--- Loads every manifest script for one side into a fresh environment.
-- @return table env
-- @return table control
-- @return string|nil the file that failed, and why
local function boot(side, database, prelude)
	local env, control = Host.Environment(side, database)
	if prelude then prelude(env) end

	for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do
		local chunk, why = loadfile(file, 't', env)
		if not chunk then return env, control, ('%s: %s'):format(file, why) end
		local ok, failure = pcall(chunk)
		if not ok then return env, control, ('%s: %s'):format(file, failure) end
	end

	-- The host always raises this for a starting resource, and the client half
	-- does all its wiring from it. A helper that skipped it would be testing a
	-- state the platform never produces.
	if side == 'client' then control.Fire('onClientResourceStart', 'opx_infinity') end

	control.Pump(60)

	-- A surface refuses everything until its page has reported ready, so a test
	-- that skipped this would be testing the window before the UI exists.
	control.ReadyPages()
	return env, control
end

-- Everything the runtime itself is allowed to publish on `OPX`. A module that
-- adds a key here has made its internals reachable by every other module, which
-- is the one thing the module boundary exists to prevent -- so this list is the
-- boundary, and adding to it should be a deliberate act.
local CORE_NAMESPACE = {
	VERSION = true, IsServer = true, IsClient = true, Config = true, Now = true,
	Channel = true, Event = true, Host = true,
	Modules = true, Api = true, Schema = true, Scheduler = true,
	Result = true, Table = true, String = true, Math = true, Text = true,
	Validate = true, Hooks = true, Locale = true, CitizenId = true,
	Storage = true, Audit = true, Rpc = true, Surface = true, Keys = true,
	Booted = true, BootError = true,
	Sessions = true, UserIdOf = true, DisplayNameOf = true, EnsureSession = true,
	ForgetSession = true, SessionHolds = true,
	Notify = true, NotifyLocale = true, RefusalKey = true, Refuse = true,
	CommandResult = true, CommandNotice = true, Cooling = true, ForgetCooldowns = true,
	Buckets = true, Gate = true, UI = true, Toast = true, Command = true, Tune = true,
}

-- States a module may legitimately rest in. `absent` means it runs on the other
-- side, `disabled` means the operator turned it off. Only `unavailable` and
-- `failed` mean something went wrong.
local RESTING = { started = true, absent = true, disabled = true }

--- Names a module has hung off `OPX` that do not belong to the runtime.
local function namespaceLeaks(OPX)
	local leaks = {}
	for key in pairs(OPX) do
		if not CORE_NAMESPACE[key] then leaks[#leaks + 1] = key end
	end
	table.sort(leaks)
	return leaks
end

-- ── the sandbox ──────────────────────────────────────────────────────────────
-- Read straight out of the manifest, so the check covers exactly what ships and
-- cannot drift from it.
section('sandbox')
do
	local shipped = {}
	for _, side in ipairs({ 'server', 'client' }) do
		for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do shipped[file] = true end
	end

	local offenders = {}
	for file in pairs(shipped) do
		local handle = io.open(file, 'r')
		if handle then
			local body = handle:read('a')
			handle:close()
			-- Comments mention these names legitimately; only a real reach counts.
			body = body:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
			for _, name in ipairs(Host.Sandbox) do
				if body:find('[^%w_.]' .. name .. '[.(]') then
					offenders[#offenders + 1] = ('%s uses %s'):format(file, name)
				end
			end
		end
	end
	table.sort(offenders)
	check('no shipped file reaches a sandboxed global',
		#offenders == 0, table.concat(offenders, ', '))
end

-- ── server boot ──────────────────────────────────────────────────────────────
section('server boot')
do
	local env, control, why = boot('server')
	check('every manifest script loads', why == nil, why)

	if why == nil then
		check('OPX.Booted is set', env.OPX.Booted == true)
		check('boot reports no database', env.OPX.BootError == 'no database', env.OPX.BootError)
		check('diagnostics started',
			env.OPX.Modules.IsRunning('diagnostics'),
			env.OPX.Modules.Get('diagnostics') and env.OPX.Modules.Record('diagnostics').Reason)
		check('/opx.modules is registered restricted',
			control.commands['opx.modules'] ~= nil and control.commands['opx.modules'].restricted)
		check('no thread died', #control.log.error == 0 or not table.concat(control.log.error)
			:find('thread died'), table.concat(control.log.error, ' | '))

		local leaks = namespaceLeaks(env.OPX)
		check('no module hangs its internals off OPX',
			#leaks == 0, table.concat(leaks, ', '))

		local stalled = {}
		for _, module in ipairs(env.OPX.Modules.Resolve()) do
			-- 'absent' (the module runs on the other side) and 'disabled' (the
			-- operator turned it off) are resting states, not stalls. Only
			-- 'unavailable' and 'failed' mean something went wrong.
			if not RESTING[module.State] then
				stalled[#stalled + 1] = ('%s (%s: %s)')
					:format(module.Id, module.State, module.Reason or '')
			end
		end
		check('every declared module reached a resting state', #stalled == 0, table.concat(stalled, ', '))
	end
end

-- ── the schema, which only runs when there is a database ─────────────────────
-- Without one there are no statements to apply, so the happy path and the
-- failure path are both invisible to the boot test above. This is the section
-- that caught `ApplySchema` answering a Result where boot expected (ok, reason).
section('schema')
do
	local PROBE = 'CREATE TABLE IF NOT EXISTS opx_probe (id INT)'

	-- A database that answers the probe and records what the schema ran.
	local ran = {}
	local working = Host.Database({
		scalar = function() return 1 end,
		update = function(sql) ran[#ran + 1] = sql; return 0 end,
	})
	local env, _, why = boot('server', working)
	check('boot with a database loads', why == nil, why)
	if why == nil then
		check('a database clears the boot error', env.OPX.BootError == nil, env.OPX.BootError)

		env.OPX.Schema.Add({ PROBE })
		local ok = env.OPX.Schema.Apply()
		check('Schema.Apply answers true when the statements run', ok == true)
		-- Modules contribute their own tables during Init, so the probe is not
		-- the only statement and not the first.
		check('the statement reached the bridge',
			(function()
				for index = 1, #ran do if ran[index] == PROBE then return true end end
				return false
			end)(), ('%d statements ran'):format(#ran))
	end

	-- The same path with a bridge that raises, which is what the real one does.
	local broken = Host.Database({
		scalar = function() return 1 end,
		update = function() error('table is broken', 0) end,
	})
	local env2, _, why2 = boot('server', broken)
	check('boot with a broken schema loads', why2 == nil, why2)
	if why2 == nil then
		env2.OPX.Schema.Add({ PROBE })
		local ok, failed = env2.OPX.Schema.Apply()
		-- The first statement to fail names itself, whichever module owns it.
		local named = failed
		-- `ApplySchema` answers a Result, and boot reads a plain pair. Treating
		-- the Result as the boolean makes every failure look like a success,
		-- because a table is truthy.
		check('Schema.Apply answers false, not a Result', ok == false, type(ok))
		check('the failing table is named',
			type(named) == 'string' and named:match('^opx'), tostring(named))
	end
end

-- ── tunables ─────────────────────────────────────────────────────────────────
-- One declaration per resource: a second would replace the first and lose every
-- other module's block. Everything that can go wrong with the panel has to
-- degrade, because none of it is worth a runtime that will not start.
section('tunables')
do
	-- Loaded on its own: boot already published, and `Declare` then correctly
	-- refuses, so driving it through a booted runtime would only prove that.
	local function tuneOnly(strip)
		local env, control = Host.Environment('server')
		if strip then strip(env) end
		for _, file in ipairs({
			'core/shared/main.lua', 'core/shared/channels.lua',
			'lib/shared/math.lua', 'config/shared.lua', 'config/server.lua',
			'core/server/tunables.lua',
		}) do
			assert(loadfile(file, 't', env), file)()
		end
		return env.OPX, control
	end

	do
		local OPX = tuneOnly()
		OPX.Tune.Declare({ PROBE_MS = { value = 5000, type = 'integer', min = 1000 } })
		check('a declared key is known', OPX.Tune.Known('PROBE_MS') == true)
		check('and reads its configured default', OPX.Tune.Number('PROBE_MS', 1) == 5000)
		check('an undeclared key answers the floor', OPX.Tune.Number('NOPE', 42) == 42)

		-- The floor is also the answer for a value that is not a finite number,
		-- so no caller ever compares a deadline against nil.
		OPX.Tune.Declare({ BAD = { value = 0 / 0 } })
		check('a NaN value answers the floor', OPX.Tune.Number('BAD', 7) == 7)
		OPX.Tune.Declare({ HUGE = { value = math.huge } })
		check('an infinity answers the floor too', OPX.Tune.Number('HUGE', 7) == 7)

		local twice = pcall(OPX.Tune.Declare, { PROBE_MS = { value = 1 } })
		check('the same key declared twice is an error, not an overwrite', twice == false)

		check('publishing succeeds against a panel', OPX.Tune.Publish() == true)
		local late = pcall(OPX.Tune.Declare, { LATE = { value = 1 } })
		check('declaring after publish is refused', late == false)
	end

	-- A host with no panel at all. Indexing a nil `Open77.tunables` raises
	-- OUTSIDE a pcall wrapped around the call, which is how this took boot down
	-- the first time.
	do
		local OPX = tuneOnly(function(env) env.Open77.tunables = nil end)
		OPX.Tune.Declare({ PROBE_MS = { value = 5000 } })
		check('no panel does not raise', OPX.Tune.Publish() == false)
		check('and the values still read their configured defaults',
			OPX.Tune.Number('PROBE_MS', 1) == 5000)
	end

	-- A panel that refuses. Losing the panel is not worth losing the runtime, so
	-- the values fall back and the failure is logged loudly instead.
	do
		local OPX, control = tuneOnly(function(env)
			env.Open77.tunables = { declare = function() error('refused', 0) end }
		end)
		OPX.Tune.Declare({ PROBE_MS = { value = 5000 } })
		check('a refused declaration does not raise', OPX.Tune.Publish() == false)
		check('the refusal is logged as an error', #control.log.error > 0,
			table.concat(control.log.error, ' | '))
		check('and the values still read', OPX.Tune.Number('PROBE_MS', 1) == 5000)
	end

	-- A booted runtime must survive a host with no panel, end to end.
	local bare = boot('server', nil, function(e) e.Open77.tunables = nil end)
	check('a runtime with no tunables panel still boots', bare.OPX.Booted == true)
end

-- ── sessions ─────────────────────────────────────────────────────────────────
-- A session is a connected machine; a character is something a module loads onto
-- one. Core owns the first and must never learn about the second.
section('sessions')
do
	local env, control, why = boot('server')
	check('server boots for the session tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX

		check('a slot with no verified account gets no session',
			OPX.EnsureSession(7) == nil)

		control.Admit(7, 'account-a')
		local first = OPX.EnsureSession(7)
		check('a slot with an account gets a session',
			type(first) == 'table' and first.userId == 'account-a')
		check('the same slot answers the same session', OPX.EnsureSession(7) == first)

		-- A player id is recycled. Every read re-checks the account behind the
		-- slot, or the next holder inherits the last one's session.
		control.Admit(7, 'account-b')
		local second = OPX.EnsureSession(7)
		check('a recycled slot evicts and rebuilds',
			second ~= first and second.userId == 'account-b')
		check('SessionHolds is true while the account matches', OPX.SessionHolds(7) == true)

		control.Admit(7, 'account-c')
		check('SessionHolds is false once the account changed', OPX.SessionHolds(7) == false)

		-- The ownership inversion: core announces, it does not call into whatever
		-- owns characters. If this ever becomes a direct call, core knows about
		-- modules and the boundary is gone.
		control.Admit(9, 'account-d')
		OPX.EnsureSession(9)
		local sawDeparting, forgotten = nil, false
		control.handlers[OPX.Event(OPX.Channel.INTERNAL, 'session', 'forgotten')] = {
			function(playerId)
				forgotten = playerId
				local live = OPX.Sessions[playerId]
				sawDeparting = live ~= nil and live.departing == true
			end,
		}
		OPX.ForgetSession(9)
		check('ForgetSession announces on the internal channel', forgotten == 9)
		check('the session is still readable, and marked departing, when it does',
			sawDeparting == true)
		check('the session is gone afterwards', OPX.Sessions[9] == nil)
	end
end

-- ── the entry gate and selection buckets ─────────────────────────────────────
-- Core owns the mechanism, the caller owns the policy. The one guard core keeps
-- is `session.departing`, because core owns sessions.
section('gate and buckets')
do
	local env, control, why = boot('server')
	if why == nil then
		local OPX = env.OPX
		local BASE = OPX.Config.SERVER.ENTRY.BUCKET.BASE
		local WORLD = OPX.Config.SERVER.ENTRY.BUCKET.WORLD

		check('a player-owned bucket is recognised as a selection bucket',
			OPX.Buckets.IsSelection(BASE + 5) == true)
		check('the world bucket is not', OPX.Buckets.IsSelection(WORLD) == false)

		-- A selection bucket belongs to whoever holds that player id NOW, never
		-- to a character. A stored one must never be placed back into.
		check('a stored selection bucket folds to the world',
			OPX.Buckets.PlacementOf(BASE + 5) == WORLD)
		check('a value that is not a bucket id folds to the world',
			OPX.Buckets.PlacementOf('nonsense') == WORLD)
		check('a real stored bucket is honoured', OPX.Buckets.PlacementOf(4200) == 4200)

		control.Admit(11, 'account-e')
		OPX.EnsureSession(11)
		check('a session with an account can be isolated',
			OPX.Buckets.Isolate(11) == true)

		-- A leaving player must not be moved: the slot may already belong to
		-- someone else, who would be dragged into an empty bucket.
		OPX.Sessions[11].departing = true
		check('a departing session is refused', OPX.Buckets.Isolate(11) == false)

		-- The gate seam: `onGiveUp` answering false means "this player is mine
		-- now", and core must NOT release a hold the caller has taken over.
		control.Admit(12, 'account-f')
		OPX.EnsureSession(12)
		OPX.Gate.Hold(12, 'test')
		check('holding records the gate session on the session',
			OPX.Sessions[12].gateSession ~= nil)

		local claimed = false
		OPX.Gate.Watch(12, 1000, function() claimed = true; return false end)
		control.Pump(60)
		check('the watch gives up at the deadline and asks', claimed == true)
		check('and answering false leaves the hold alone',
			OPX.Sessions[12] ~= nil and OPX.Sessions[12].released ~= true)

		check('releasing is idempotent', OPX.Gate.Release(12, 'done') ~= nil
			and OPX.Gate.Release(12, 'done') ~= nil)
		check('releasing a player who never held is safe',
			OPX.Gate.Release(99, 'never') ~= nil)
	end
end

-- ── cooldowns and refusals ───────────────────────────────────────────────────
section('answers')
do
	local env, control, why = boot('server')
	if why == nil then
		local OPX = env.OPX

		check('a first attempt is not cooling', OPX.Cooling(3, 'select', 1000) == false)
		check('an immediate second attempt is', OPX.Cooling(3, 'select', 1000) == true)
		check('a different operation has its own window',
			OPX.Cooling(3, 'create', 1000) == false)
		-- The console is source 0 and is never cooled.
		check('the console is never cooled',
			OPX.Cooling(0, 'select', 1000) == false and OPX.Cooling(0, 'select', 1000) == false)

		OPX.ForgetCooldowns(3)
		check('forgetting clears the window', OPX.Cooling(3, 'select', 1000) == false)

		-- A code the catalogue does not carry must never reach a player raw.
		check('an unknown refusal code becomes error.unavailable',
			OPX.RefusalKey('query-failed') == 'error.unavailable')
		check('a known refusal code is answered as itself',
			OPX.RefusalKey('error.tooFast') == 'error.tooFast')

		local before = #control.clientEvents
		OPX.Refuse(4, 'query-failed', 'selectCharacter')
		local sent = control.clientEvents[#control.clientEvents]
		check('a refusal reaches the client', #control.clientEvents == before + 1)
		check('and carries a renderable code and its operation',
			sent ~= nil and sent[1] ~= nil and sent[1].code == 'error.unavailable'
				and sent[1].operation == 'selectCharacter',
			sent and sent[1] and sent[1].code)
	end
end

-- ── the spawn menu ──────────────────────────────────────────────────────────
-- The one module that decides where a brand new character lands, and the one
-- handshake it has with `character`, which owns placement. Both halves are
-- exercised here: the server side through the real contract it calls into, and the
-- page side through the harness's own page, which plays the CEF.
section('spawn')
do
	local env, control, why = boot('server')
	check('server boots for the spawn tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local spawn = OPX.Modules.Get('spawn')

		check('the spawn module is running', OPX.Modules.IsRunning('spawn'),
			OPX.Modules.Record('spawn').Reason)

		-- THE SEAM `character` WALKS, and it is a CONTRACT LOOKUP rather than a direct
		-- call: `spawn` requires `character`, so `character` cannot require `spawn`
		-- back, and reaches it with `OPX.Api.Get('spawn')` instead. An absent
		-- contract is a legitimate answer, so `character` skips the offer in
		-- silence and places the body itself.
		--
		-- Asserted through the REAL registry on purpose. When this first shipped to
		-- a live server the module declared no `Api` phase at all, so `Get` answered
		-- nil, no new character was ever offered the menu, and every one of them
		-- landed on the default spot -- with nothing in any log. Calling
		-- `spawn.Offer` directly, which is what the other checks here do, passed the
		-- whole suite while that was true. Hence: go through `Api`.
		local contract = OPX.Api.Get('spawn')
		check('the spawn contract is published for `character` to find',
			contract ~= nil, "Api.Get('spawn') answered nil")
		check('and it carries the Offer `character` calls',
			contract ~= nil and type(contract.Offer) == 'function')
		check('and it is wired to this module rather than a stand-in',
			contract ~= nil and contract.Offer == spawn.Offer)

		-- THE GATE, WHICH IS WHERE THIS ACTUALLY BROKE. `PlacePending` used to skip
		-- the offer whenever the row already held a position, so a character that
		-- had ever stood anywhere was never asked again -- and a live server showed
		-- no menu on world enter for exactly that reason, with nothing in any log,
		-- because the skipped path is a legitimate answer rather than an error.
		-- Driven through the REAL `character.PlacePending`: every test that called
		-- `spawn.Offer` directly passed straight through the defect.
		--
		-- `PlayerData.source` is left nil on purpose. If the gate ever comes back,
		-- `PlaceCharacter` answers 'offline' without yielding, so a regression fails
		-- these checks instead of raising its way out of the suite.
		local character = OPX.Modules.Get('character')
		check('the character module is loaded, so the gate is under test',
			character ~= nil and type(character.PlacePending) == 'function')

		if character ~= nil then
			-- A RETURNING character: loaded, and its row already says where it was.
			local returning = 31
			character.Players[returning] = {
				PlayerData = {
					citizenId = 'citizen-returning',
					position = { x = -1771.79, y = -77.30, z = 7.53, heading = 12.0 },
				},
			}
			character.AwaitingPlacement[returning] = 'citizen-returning'
			check('a character that already has a position is offered the menu too',
				character.PlacePending(returning) == true)
			check('and its choice is outstanding', spawn.IsPending(returning) == true)

			-- A BRAND NEW character, with nowhere in its row at all.
			local fresh = 32
			character.Players[fresh] = { PlayerData = { citizenId = 'citizen-fresh' } }
			character.AwaitingPlacement[fresh] = 'citizen-fresh'
			check('and a brand new character is still offered it',
				character.PlacePending(fresh) == true)
			check('with its own choice outstanding', spawn.IsPending(fresh) == true)

			-- Neither of these is a real player; leave the store as it was found.
			character.Players[returning] = nil
			character.Players[fresh] = nil
		end

		-- THE CATALOGUE. Every configured location has to survive normalisation, or a
		-- typo in one entry silently shrinks the menu. Comparing against the
		-- configuration rather than a hardcoded count keeps the check honest when a
		-- spot is added and wrong when one is broken.
		local catalogue = spawn.Catalogue()
		check('every configured location is usable',
			#catalogue == #OPX.Config.MODULES.spawn.LOCATIONS,
			('%d usable of %d configured'):format(#catalogue,
				#OPX.Config.MODULES.spawn.LOCATIONS))
		check('and there is something to choose between', #catalogue > 0)

		local finite = true
		for index = 1, #catalogue do
			local point = catalogue[index]
			if not (OPX.Math.IsFinite(point.x) and OPX.Math.IsFinite(point.y)
				and OPX.Math.IsFinite(point.z) and OPX.Math.IsFinite(point.heading)) then
				finite = false
			end
		end
		check('every position and heading is a finite number', finite)

		-- The lookup the whole wire depends on: the client sends an ID and the server
		-- answers with the coordinates, which is why a location has to be found by the
		-- same string both halves hold.
		check('a location is found by the id the wire carries', spawn.Point('stoop') ~= nil)
		check('and it carries its configured position',
			spawn.Point('stoop') ~= nil and spawn.Point('stoop').x == -410.22,
			tostring(spawn.Point('stoop') and spawn.Point('stoop').x))
		check('an id nobody configured is not found', spawn.Point('nowhere') == nil)

		-- A WORLD WITH ONLY THIS MODULE IN IT, so its own settings can be put in front
		-- of it BEFORE anything builds a catalogue. The catalogue is built once, on
		-- first use, and `M.Start` reads it -- so a deliberately broken one has to be
		-- in place before the phases run, which a `boot()` cannot do.
		--
		-- `character` is a stub: what is under test here is the decision and the
		-- handoff, not the placement.
		-- @param locations table|nil
		-- @param character table|nil the contract the stub provides
		-- @return table env
		-- @return table control
		local function spawnOnly(locations, character)
			local own, ctl = Host.Environment('server')
			for _, file in ipairs({
				'core/shared/main.lua', 'core/shared/channels.lua',
				'core/shared/registry.lua', 'core/shared/lifecycle.lua',
				'lib/shared/math.lua', 'lib/shared/result.lua', 'config/spawn.lua',
				'modules/spawn/module.lua', 'modules/spawn/server/main.lua',
			}) do
				assert(loadfile(file, 't', own), file)()
			end
			own.OPX.Config.MODULES.spawn.LOCATIONS = locations or {}
			-- `Choose` rate-limits through core's own helper and refuses on core's own
			-- channel. Neither is part of what this env tests -- the full-boot section
			-- above covers the refusal -- so both stand in for themselves.
			own.OPX.Cooling = function() return false end
			own.OPX.Refuse = function() end
			local stub = own.OPX.Modules.Declare{ id = 'character' }
			stub.Api = function()
				own.OPX.Api.Provide('character', 1,
					character or { GetPlayer = function() return nil end })
			end
			own.OPX.Modules.Run()
			return own, ctl
		end

		-- ONE BAD ENTRY AMONG GOOD ONES. A duplicate id loses the second (the wire
		-- carries the id ALONE, so the second is unreachable), an id that is not an
		-- identifier at all is dropped, a position that is not a number is dropped,
		-- and a missing heading is north rather than a dropped place.
		do
			local probe = spawnOnly({
				{ id = 'ok', label = 'Fine', district = 'Watson', x = 1, y = 2, z = 3 },
				{ id = 'ok', label = 'Twice', district = 'Watson', x = 4, y = 5, z = 6 },
				{ id = 'bad-id!', label = 'No', district = 'Watson', x = 1, y = 2, z = 3 },
				{ id = 'nan', label = 'No', district = 'Watson', x = 0 / 0, y = 2, z = 3 },
				{ id = 'no-label', x = 1, y = 2, z = 3 },
			})
			check('the module runs with a catalogue of its own',
				probe.OPX.Modules.IsRunning('spawn'), probe.OPX.Modules.Record('spawn').Reason)
			local built = probe.OPX.Modules.Get('spawn').Catalogue()
			check('only the one usable location survives',
				#built == 1 and built[1] ~= nil and built[1].id == 'ok',
				('%d kept'):format(#built))
			check('and a missing heading reads as 0.0, not as a dropped place',
				built[1] ~= nil and built[1].heading == 0.0)
		end

		-- ── a world with nowhere to go ────────────────────────────────────────────
		-- What makes this module stand down and let `character` place directly, which
		-- is the whole behaviour before it existed.
		do
			local bare = spawnOnly({})
			local module = bare.OPX.Modules.Get('spawn')
			check('with nothing configured, there is nothing to choose between',
				module.HasPoints() == false)
			check('and the offer is refused, so the caller places instead',
				module.Offer(4, 'citizen-4') == false)
			check('and nothing is left outstanding', module.IsPending(4) == false)
		end

		-- ── the handoff ───────────────────────────────────────────────────────────
		-- THE SEAM. The point a player picked has to arrive at
		-- `character.PlaceCharacter` with its coordinates intact, for the character
		-- that is actually loaded -- and the call has to happen on a thread, because
		-- placement yields and the routeway it is reached from is a net handler.
		do
			local player = { PlayerData = { citizenId = 'citizen-9' } }
			local called, gotPlayer, gotPoint
			local probe, ctl = spawnOnly(
				{ { id = 'spot', label = 'A Spot', district = 'Watson', x = 11.5, y = 22.5, z = 33.5, heading = 45.0 } },
				{
					GetPlayer = function() return player end,
					PlaceCharacter = function(target, point)
						called, gotPlayer, gotPoint = true, target, point
						return true
					end,
				})
			local module = probe.OPX.Modules.Get('spawn')

			check('a character is offered a choice', module.Offer(3, 'citizen-9') == true)
			probe.source = 3
			ctl.netEvents[module.Event.CHOOSE]({ id = 'spot' })

			-- The placement is its own thread, so it has not run yet: this is the
			-- reason the menu comes down BEFORE the move rather than after it.
			check('nothing has been placed in the tick the click arrived', called ~= true)

			ctl.Pump(4)
			check('the chosen place reaches the placement primitive', called == true)
			check('for the character that is loaded, not for a slot', gotPlayer == player)
			check('carrying the configured coordinates',
				gotPoint ~= nil and gotPoint.x == 11.5 and gotPoint.y == 22.5
					and gotPoint.z == 33.5 and gotPoint.heading == 45.0,
				gotPoint and ('%s,%s,%s'):format(gotPoint.x, gotPoint.y, gotPoint.z))
			check('and the id, so a failure can name the place',
				gotPoint ~= nil and gotPoint.id == 'spot')
		end

		-- ── the offer ────────────────────────────────────────────────────────────
		local src = 7
		control.Admit(src, 'account-spawn')
		OPX.EnsureSession(src)

		local mark = #control.clientEvents
		check('a brand new character is offered a choice', spawn.Offer(src, 'citizen-1') == true)
		check('and the choice is outstanding', spawn.IsPending(src) == true)

		local sent = control.clientEvents[mark + 1]
		check('the offer reaches the client on its own channel',
			sent ~= nil and sent.name == spawn.Event.OFFER, sent and sent.name)
		-- A DURATION, not a deadline: the page counts down to its own clock plus this
		-- number, and the server counts the same number itself.
		check('and carries a positive duration',
			sent ~= nil and sent[1] ~= nil and OPX.Math.IsFinite(sent[1].timeoutMs)
				and sent[1].timeoutMs > 0,
			sent and sent[1] and tostring(sent[1].timeoutMs))
		check('a second offer while the first stands is refused',
			spawn.Offer(src, 'citizen-1') == false)

		-- ── the choice ───────────────────────────────────────────────────────────
		env.source = src
		check('the choose routeway is registered',
			type(control.netEvents[spawn.Event.CHOOSE]) == 'function')

		-- AN ID NOBODY CONFIGURED. Refused, and -- the part that matters -- the menu
		-- stays up: this is a place the server will not place anybody at.
		mark = #control.clientEvents
		control.netEvents[spawn.Event.CHOOSE]({ id = 'nowhere' })
		local refusal = control.clientEvents[mark + 1]
		check('an id nobody configured is refused',
			refusal ~= nil and refusal[1] ~= nil and refusal[1].code == 'spawn.noChoice',
			refusal and refusal[1] and tostring(refusal[1].code))
		check('and the refusal names its operation, so a client can tell it apart',
			refusal ~= nil and refusal[1] ~= nil and refusal[1].operation == spawn.Operation.CHOOSE)
		check('and the choice is still outstanding', spawn.IsPending(src) == true)

		-- A CONFIGURED ONE. A separate player, because the refusal above started this
		-- one's rate-limit window.
		local picker = 8
		control.Admit(picker, 'account-spawn-2')
		OPX.EnsureSession(picker)
		check('a second character is offered its own choice',
			spawn.Offer(picker, 'citizen-2') == true)

		mark = #control.clientEvents
		env.source = picker
		control.netEvents[spawn.Event.CHOOSE]({ id = 'stoop' })
		check('choosing a configured location spends the choice',
			spawn.IsPending(picker) == false)

		local closed = control.clientEvents[#control.clientEvents]
		check('and takes the menu down', closed ~= nil and closed.name == spawn.Event.CLOSE,
			closed and closed.name)
		check('naming the reason and the place',
			closed ~= nil and closed[1] ~= nil and closed[1].reason == 'chosen'
				and closed[1].place == 'King Stoop forecourt',
			closed and closed[1] and tostring(closed[1].place))
		-- The page is told a LABEL. The coordinates are nobody's but the server's.
		check('and never the coordinates',
			closed ~= nil and closed[1] ~= nil and closed[1].x == nil)

		-- ── the deadline ─────────────────────────────────────────────────────────
		-- The only exit a choice nobody makes ever gets. Shortened here, because the
		-- shipped window is 45 seconds and what is under test is the behaviour rather
		-- than the number -- and the five-second floor is itself worth exercising, so
		-- this sets a value BELOW it and expects the floor to win.
		local quitter = 9
		control.Admit(quitter, 'account-spawn-3')
		OPX.EnsureSession(quitter)
		local savedTimeout = OPX.Config.MODULES.spawn.TIMEOUT_SECONDS
		OPX.Config.MODULES.spawn.TIMEOUT_SECONDS = 0
		mark = #control.clientEvents
		check('a character is offered a choice it will not make',
			spawn.Offer(quitter, 'citizen-3') == true)
		check('and it is outstanding', spawn.IsPending(quitter) == true)
		-- A zero would end the choice in the tick it was offered. The floor is what
		-- makes that impossible, and it is visible on the very payload the page
		-- counts down from.
		check('a zero is floored rather than honoured',
			control.clientEvents[mark + 1] ~= nil
				and control.clientEvents[mark + 1][1].timeoutMs == 5000,
			control.clientEvents[mark + 1] and
				tostring(control.clientEvents[mark + 1][1].timeoutMs))

		-- THE WINDOW HAS NOT STARTED, because nothing has the menu on screen.
		-- Pumping past the whole configured window must therefore settle NOTHING:
		-- the menu is deliberately deferred behind the entry module's name form, so
		-- a clock that ran from the offer would be spending the player's time on a
		-- screen they cannot see. This is the defect the live server showed.
		control.Pump(60)
		check('an offer nobody has opened does not spend its window',
			spawn.IsPending(quitter) == true)

		-- The client reports the menu up, over the same routeway it uses, so the
		-- wiring is under test and not just the function.
		env.source = quitter
		control.netEvents[spawn.Event.OPENED]({})

		control.Pump(60)
		check('the deadline settles it anyway', spawn.IsPending(quitter) == false)

		local timedOut
		for index = #control.clientEvents, 1, -1 do
			local event = control.clientEvents[index]
			if event.name == spawn.Event.CLOSE and event.source == quitter then
				timedOut = event
				break
			end
		end
		check('and the menu comes down on its own', timedOut ~= nil)
		check('with a reason of its own, distinct from a choice',
			timedOut ~= nil and timedOut[1] ~= nil and timedOut[1].reason == 'timeout',
			timedOut and timedOut[1] and tostring(timedOut[1].reason))
		check('and no place, because none was chosen',
			timedOut ~= nil and timedOut[1] ~= nil and timedOut[1].place == nil)
		OPX.Config.MODULES.spawn.TIMEOUT_SECONDS = savedTimeout

		-- A SECOND REPORT MUST NOT BUY MORE TIME. The client sends the report once
		-- per offer, but a modified one can send it as often as it likes, and the
		-- only thing that would be is a window nobody can outlast.
		local greedy = 13
		control.Admit(greedy, 'account-spawn-5')
		OPX.EnsureSession(greedy)
		OPX.Config.MODULES.spawn.TIMEOUT_SECONDS = 10
		check('a second character is offered a choice', spawn.Offer(greedy, 'citizen-5') == true)
		env.source = greedy
		control.netEvents[spawn.Event.OPENED]({})
		control.Pump(50)
		control.netEvents[spawn.Event.OPENED]({})
		control.Pump(60)
		check('reporting the menu up twice does not extend the window',
			spawn.IsPending(greedy) == false)
		OPX.Config.MODULES.spawn.TIMEOUT_SECONDS = savedTimeout

		-- A CLIENT THAT NEVER OPENS THE MENU. The player's window is bounded, and
		-- so is the runtime's patience: an offer nobody opens must not leave a
		-- character standing in the pre-game position for the session. This is the
		-- HOLD, and it is the only clock that runs before the report.
		local stuck = 14
		control.Admit(stuck, 'account-spawn-6')
		OPX.EnsureSession(stuck)
		local savedHold = OPX.Config.MODULES.spawn.HOLD_MAX_SECONDS
		-- The floor is sixty seconds, so this cannot be shortened further: a value
		-- below it is floored rather than honoured, which the pump below relies on.
		OPX.Config.MODULES.spawn.HOLD_MAX_SECONDS = 0
		check('a third character is offered a choice it never sees',
			spawn.Offer(stuck, 'citizen-6') == true)
		control.Pump(500)
		check('the hold keeps an unopened offer alive while it lasts',
			spawn.IsPending(stuck) == true)
		control.Pump(200)
		check('and the hold releases it when the menu never appears',
			spawn.IsPending(stuck) == false)
		OPX.Config.MODULES.spawn.HOLD_MAX_SECONDS = savedHold
	end
end

-- ── the spawn menu's page contract ───────────────────────────────────────────
-- The Lua half and the CEF half agreeing by string literal, and the one piece of
-- ordering this module has: the menu stands aside while the entry module is asking
-- the same player something, because two modals on one keyboard is one modal losing
-- its focus.
section('spawn and the page')
do
	local env, control, why = boot('client')
	check('client boots for the spawn tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local spawn = OPX.Modules.Get('spawn')
		local page = control.pages[1]

		check('the spawn module is running', OPX.Modules.IsRunning('spawn'),
			OPX.Modules.Record('spawn').Reason)

		-- The entry module's state, as the entry module raises it.
		local ENTRY = OPX.Event(OPX.Channel.LOCAL, 'entry', 'state')

		local function drew(channel)
			for index = 1, #page.sent do
				if page.sent[index].channel == channel then return page.sent[index] end
			end
			return nil
		end

		control.Fire(ENTRY, { open = true, phase = 'name' })
		control.netEvents[spawn.Event.OFFER]({ timeoutMs = 5000 })
		check('the menu waits while the name form is up', drew('opx:spawn:open') == nil)

		control.Fire(ENTRY, { open = false, phase = 'idle' })
		local opened = drew('opx:spawn:open')
		check('and opens the moment entry is idle', opened ~= nil)

		if opened ~= nil then
			-- The page draws from what it is given, so the places have to be on the
			-- payload: label and district, and no coordinates in either direction.
			local places = opened.payload.locations
			check('with every location on it',
				type(places) == 'table' and #places == #spawn.Catalogue(),
				type(places) == 'table' and #places or -1)
			check('each carrying a label and a district',
				places[1] ~= nil and places[1].label ~= nil and places[1].district ~= nil)
			check('and no coordinates', places[1] ~= nil and places[1].x == nil)
			-- A duration for the display countdown, which is all it is: the server
			-- counts the same window itself.
			check('and a duration to count down',
				opened.payload.timeoutMs == 5000, tostring(opened.payload.timeoutMs))
		end

		-- The page's focus stack, which is what gives the menu the cursor. Acquiring
		-- is announced by the page and mirrored by Lua, and a name that drifts between
		-- the two is a modal nobody can click.
		control.PageEmit(page, 'opx:focus:set', { surface = 'ui', focus = true, owner = 'spawn' })
		check('the menu takes the focus the page hands it', OPX.UI.FocusOwner() == 'spawn')

		-- The click. The page sends an ID and nothing else, and this is the payload the
		-- server has to be able to defend against.
		local toServer
		env.TriggerServerEvent = function(name, payload)
			toServer = { name = name, payload = payload }
		end
		control.PageEmit(page, 'opx:spawn:choose', { id = 'stoop' })
		check('a click goes to the server as a bare id',
			toServer ~= nil and toServer.name == spawn.Event.CHOOSE
				and toServer.payload.id == 'stoop',
			toServer and tostring(toServer.name))

		-- The menu does NOT come down on a click. It comes down when the server says
		-- what happened, because a page that closed itself would show a spawn that
		-- was refused.
		check('and the menu is still up, waiting for the answer',
			drew('opx:spawn:close') == nil)

		control.netEvents[spawn.Event.CLOSE]({ reason = 'chosen', place = 'King Stoop forecourt' })
		check('the answer takes the menu down', drew('opx:spawn:close') ~= nil)
		check('and gives the focus back', OPX.UI.FocusOwner() == nil)
	end
end

-- ── client boot ──────────────────────────────────────────────────────────────
section('client boot')
do
	local env, control, why = boot('client')
	check('every manifest script loads', why == nil, why)

	if why == nil then
		-- `boot` already raised the start event; raising it again is how the
		-- double-Run bug was found, and `Modules.Run` is idempotent now.
		control.Fire('onClientResourceStart', 'opx_infinity')
		control.Pump(60)
		check('diagnostics started', env.OPX.Modules.IsRunning('diagnostics'))
		check('a second resource-start does not re-run the phases',
			env.OPX.Modules.Record('weather').State == 'started',
			env.OPX.Modules.Record('weather').Reason)
		check('the scheduler reports itself', #env.OPX.Scheduler.Report() >= 0)
		check('/opx.client is registered open',
			control.commands['opx.client'] ~= nil and not control.commands['opx.client'].restricted)

		local leaks = namespaceLeaks(env.OPX)
		check('no module hangs its internals off OPX',
			#leaks == 0, table.concat(leaks, ', '))

		local stalled = {}
		for _, module in ipairs(env.OPX.Modules.Resolve()) do
			-- 'absent' (the module runs on the other side) and 'disabled' (the
			-- operator turned it off) are resting states, not stalls. Only
			-- 'unavailable' and 'failed' mean something went wrong.
			if not RESTING[module.State] then
				stalled[#stalled + 1] = ('%s (%s: %s)')
					:format(module.Id, module.State, module.Reason or '')
			end
		end
		check('every declared module reached a resting state', #stalled == 0, table.concat(stalled, ', '))
	end
end

-- ── the registry, against declarations the resource does not ship ────────────
section('ui focus')
do
	local env, control, why = boot('client')
	if why == nil then
		local OPX = env.OPX
		-- ONE page, created at start. It used to be two -- an overlay at start and
		-- an interactive layer on first focus -- and the merge has to hold the line
		-- that mattered in the old shape: the surface is never HIDDEN when focus
		-- drops, because the HUD is on it now.
		check('one page is up at start', #control.pages == 1,
			('%d pages'):format(#control.pages))
		local page = control.pages[1]
		check('it is visible and unfocused',
			page ~= nil and page.spec.visible == true)
		check('overlay and interactive are the same surface',
			OPX.UI.Overlay() ~= nil and OPX.UI.Overlay() == OPX.UI.Interactive())
		check('and asking for them did not build a second page', #control.pages == 1,
			('%d pages'):format(#control.pages))
		-- Only one surface may hold focus, so focus is a single arbitrated
		-- resource. A view opened over another gives it back on release.
		check('nothing holds focus at rest', OPX.UI.FocusOwner() == nil)

		OPX.UI.AcquireFocus('menu', { keyboard = true })
		check('acquiring takes it', OPX.UI.FocusOwner() == 'menu')
		check('and it reaches the page', page ~= nil and page.focus.keyboard == true)

		OPX.UI.AcquireFocus('form', { keyboard = true })
		check('a view opened over it takes it', OPX.UI.FocusOwner() == 'form')

		OPX.UI.ReleaseFocus('form')
		check('releasing gives it back, not away', OPX.UI.FocusOwner() == 'menu')

		-- Acquiring twice must not leave two entries, or one release leaves a
		-- ghost holding focus that nothing can release.
		OPX.UI.AcquireFocus('menu', { keyboard = true })
		OPX.UI.ReleaseFocus('menu')
		check('acquiring twice still releases once', OPX.UI.FocusOwner() == nil)
		check('the page lost focus with it',
			page ~= nil and page.focus.keyboard == false and page.focus.cursor == false)
		-- The regression this merge could introduce, and the reason the check is
		-- here at all: hiding the surface when the stack empties would blank the
		-- HUD every time a menu closed.
		check('but the surface is still shown', page ~= nil and page.visible == true)

		OPX.UI.ReleaseFocus('never-held')
		check('releasing what never held is safe', OPX.UI.FocusOwner() == nil)
	end
end

section('toasts')
do
	local env, control, why = boot('client')
	if why == nil then
		local OPX = env.OPX
		local overlay = control.pages[1]
		local function lastSent()
			return overlay and overlay.sent[#overlay.sent] or nil
		end

		local id = OPX.Toast.Show({ kind = 'success', message = 'saved' })
		check('a toast is raised and addressable', type(id) == 'string', tostring(id))
		local sent = lastSent()
		check('and it reaches the overlay on its own channel',
			sent ~= nil and sent.channel == 'opx:notify:show', sent and sent.channel)
		check('with the kind it was given',
			sent ~= nil and sent.payload.kind == 'success')

		check('an unknown kind falls back to info',
			(function()
				OPX.Toast.Show({ kind = 'catastrophe', message = 'x' })
				return lastSent().payload.kind == 'info'
			end)())

		-- A toast with no text is nothing to show, and raising it would leave an
		-- empty box on screen with no way to read what went wrong.
		check('a toast with no message is refused',
			OPX.Toast.Show({ kind = 'error' }) == nil)

		check('updating one that is up succeeds',
			OPX.Toast.Update(id, { message = 'saved twice' }) == true)
		OPX.Toast.Dismiss(id)
		check('updating one that has gone answers false',
			OPX.Toast.Update(id, { message = 'too late' }) == false)

		-- The server guarantees the code is a catalogue key, so a refusal can be
		-- rendered without leaking an internal storage code to the player.
		local refusal = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
		control.netEvents[refusal]({ kind = 'error', code = 'error.tooFast' })
		check('a refusal from the server is rendered, not shown as its key',
			lastSent().payload.message == env.OPX.Locale.Text('error.tooFast'),
			lastSent().payload.message)

		-- ── the glyph ─────────────────────────────────────────────────────────
		-- The page selects a local path by this name, so the set is closed on both
		-- sides. A caller in this process is REFUSED, because a typo they can still
		-- see a return value for is a bug they will fix; a name off the wire is
		-- dropped, because the sentence it rode in on matters more than the picture.
		check('a toast may carry a glyph from the closed set',
			(function()
				OPX.Toast.Show({ message = 'locked', icon = 'lock' })
				return lastSent().payload.icon == 'lock'
			end)())

		local refused, why = OPX.Toast.Show({ message = 'x', icon = 'vehcile' })
		check('a glyph outside the set is refused, not dropped',
			refused == nil and why == 'invalid_toast_icon', tostring(why))

		local iconed = OPX.Toast.Show({ id = 'glyph', message = 'counting', icon = 'money' })
		check('a patch naming a glyph outside the set is refused too',
			OPX.Toast.Update(iconed, { icon = 'rocket' }) == false)
		check('and an empty name takes the glyph back off',
			OPX.Toast.Update(iconed, { icon = '' }) == true
				and lastSent().payload.icon == '')

		control.netEvents[refusal]({ kind = 'error', code = 'error.tooFast', icon = 'rocket' })
		check('a refusal naming a glyph nobody has loses the glyph, never the words',
			lastSent().payload.icon == nil
				and lastSent().payload.message == env.OPX.Locale.Text('error.tooFast'))

		local answer = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')
		control.netEvents[answer]('/pay', 'success', 'paid', false, 'money')
		check('a command answer carries its glyph the whole way to the page',
			lastSent().payload.icon == 'money', tostring(lastSent().payload.icon))
	end
end

-- ── the Lua/page channel contract ────────────────────────────────────────────
-- Two halves in two languages agreeing by string literal, with no compiler
-- between them. Both live boot-level breaks here were exactly this: Lua wired
-- `opx:ready` while the page emitted `opx:ui:ready`, and Lua sent the catalogue
-- on `opx:config` while the page listened on `opx:locale:set`. Neither raised
-- anything -- a refused send is a `false` nobody reads, and a missing string
-- renders as its own key.
--
-- The rest of the suite could not see either, because the harness plays the page
-- the way Lua expects rather than the way the page behaves. This reads the real
-- built bundle instead.
section('lua <-> page channels')
do
	local built = io.open('web/index.html', 'r')
	if built == nil then
		check('web/index.html is built', false, 'run `npm run build`')
	else
		local page = built:read('a')
		built:close()

		-- The bundle is minified, so the call around a channel name is gone. The
		-- names themselves survive as literals, which is all this needs.
		local speaks = {}
		for name in page:gmatch('"(opx:[%w:_]+)"') do speaks[name] = true end

		-- The two the handshake turns on. Without the first, `surface.ready` is
		-- never set and every send is refused; without the second, every label
		-- renders as its own key.
		check('the page reports ready on the channel the surface wires',
			speaks['opx:ready'] == true)
		check('the page takes the catalogue on the channel Lua sends it on',
			speaks['opx:locale:set'] == true)

		-- Drift detector. A channel the page speaks that no Lua file mentions is
		-- either a feature whose Lua half is not written yet -- which is fine and
		-- expected here -- or a name one side has renamed and the other has not,
		-- which is silent in both directions. Listing them is the point; the
		-- check only fails on the handshake above.
		local lua = {}
		for _, dir in ipairs({ 'core/client', 'lib/client', 'modules' }) do
			-- Both spellings: the full `opx:` name where a module builds one, and
			-- the bare channel where `OPX.Surface` adds the prefix for the caller.
			local pipe = io.popen(('grep -rhoE "opx:[a-z:_]+|\'[a-z][a-z:_]*\'" %s 2>nul')
				:format(dir))
			if pipe then
				for line in pipe:lines() do lua[(line:gsub("'", ''))] = true end
				pipe:close()
			end
		end

		local orphans = {}
		for name in pairs(speaks) do
			local bare = name:gsub('^opx:', '')
			if not lua[name] and not lua[bare] then orphans[#orphans + 1] = bare end
		end
		table.sort(orphans)
		print(('       page channels with no Lua half yet: %s')
			:format(#orphans > 0 and table.concat(orphans, ' ') or 'none'))
	end
end

-- The page is BUILT BEFORE THE MODULES ARE. `core/client/boot.lua` creates the
-- surface first, then walks the modules a frame at a time, because `Start` yields
-- between them to reset the instruction budget. A view emits `opx:<module>:ready`
-- from its mount and the bridge releases all of them in the same tick as
-- `opx:ready`, so a page with warm CEF assets -- every reconnection, and a
-- character switch ends the session -- mounts inside that window.
--
-- `boot()` above cannot see this: it pumps the whole boot out and only then
-- reports the page ready, which is the polite order and not the one that breaks.
-- This section plays the rude one.
section('a page that mounts before the modules have started')
do
	local env, control = Host.Environment('client')
	local broken
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
		local chunk, why = loadfile(file, 't', env)
		if not chunk then broken = ('%s: %s'):format(file, why) break end
		local ok, failure = pcall(chunk)
		if not ok then broken = ('%s: %s'):format(file, failure) break end
	end

	if broken then
		check('the client half loads', false, broken)
	else
		control.Fire('onClientResourceStart', 'opx_infinity')

		-- ONE round. The boot thread creates the surface and then yields inside
		-- the Start phase, so this is the client at its most exposed: a page
		-- exists, and almost nothing has registered on it.
		control.Pump(1)
		local page = control.pages[#control.pages]

		check('the surface exists before the modules do', page ~= nil)

		local hud = env.OPX.Modules.Record('hud')
		check('and the hud has not started yet',
			hud ~= nil and hud.State == 'declared',
			hud and hud.State)

		-- The fix. Wired against the module list at creation, so the channel has
		-- a host listener before the page can emit on it; without this the emit
		-- below reaches nothing at all and cannot even be held.
		check('yet its ready channel is already wired',
			page ~= nil and page.handlers['opx:hud:ready'] ~= nil)

		-- The page, in the order it really speaks: the handshake, then every
		-- `<module>:ready` the mount queued behind it, same tick.
		control.PageEmit(page, 'opx:ready', { surface = 'ui' })
		control.PageEmit(page, 'opx:hud:ready', {})
		control.PageEmit(page, 'opx:inventory:ready', {})

		-- The rest of the boot, where the hud finally registers and is handed
		-- the ready it missed.
		control.Pump(60)

		local drew = {}
		for _, message in ipairs(page and page.sent or {}) do drew[message.channel] = true end

		check('the hud draws anyway, on the ready it was handed late',
			drew['opx:hud:config'] == true)
		check('including the switch that makes the surface show at all',
			drew['opx:hud:show'] == true)

		-- Held for the FIRST handler and then forgotten: a broadcast channel must
		-- not hand the same payload to every module that registers after it.
		local surface = env.OPX.UI.Surface()
		local seen = 0
		env.OPX.Surface.On(surface, 'hud:ready', function() seen = seen + 1 end)
		check('and a handler registering after the replay is not given it again',
			seen == 0, seen)
	end
end

section('module resolution')
do
	local cases = {
		{
			label = 'a missing hard dependency marks the dependant unavailable',
			declare = function(OPX)
				OPX.Modules.Declare{ id = 'alpha', requires = { 'nope' } }
			end,
			expect = function(OPX) return OPX.Modules.Record('alpha').State == 'unavailable' end,
		},
		{
			label = 'unavailability cascades to the next dependant',
			declare = function(OPX)
				OPX.Modules.Declare{ id = 'alpha', requires = { 'nope' } }
				OPX.Modules.Declare{ id = 'beta', requires = { 'alpha' } }
			end,
			expect = function(OPX) return OPX.Modules.Record('beta').State == 'unavailable' end,
		},
		{
			label = 'a missing soft dependency does not stop the dependant',
			declare = function(OPX)
				OPX.Modules.Declare{ id = 'alpha', optional = { 'nope' } }
			end,
			expect = function(OPX) return OPX.Modules.Record('alpha').State == 'started' end,
		},
		{
			label = 'a module disabled in config never runs',
			declare = function(OPX)
				OPX.Config.MODULES.alpha = { enabled = false }
				OPX.Modules.Declare{ id = 'alpha' }
			end,
			expect = function(OPX) return OPX.Modules.Record('alpha').State == 'disabled' end,
		},
		{
			label = 'a raise in Init fails only that module',
			declare = function(OPX)
				local m = OPX.Modules.Declare{ id = 'alpha' }
				m.Init = function() error('deliberate') end
				OPX.Modules.Declare{ id = 'gamma' }
			end,
			expect = function(OPX)
				return OPX.Modules.Record('alpha').State == 'failed'
					and OPX.Modules.Record('gamma').State == 'started'
			end,
		},
		{
			-- The namespace and the lifecycle record used to be one table, so a
			-- module wanting a field called `State` overwrote its own lifecycle
			-- state and never started -- silently, because nothing reads a state
			-- it did not write. `appearance` hit this for real.
			label = 'a module may use a field named after a lifecycle field',
			declare = function(OPX)
				local m = OPX.Modules.Declare{ id = 'alpha' }
				m.State = { anything = true }
				m.Id = 'not-the-module-id'
				m.Reason = 'mine, not the runtime\'s'
			end,
			expect = function(OPX)
				return OPX.Modules.Record('alpha').State == 'started'
					and OPX.Modules.Record('alpha').Id == 'alpha'
					and OPX.Modules.Get('alpha').State.anything == true
			end,
		},
		{
			label = 'a cycle is an error at boot, naming the ring',
			declare = function(OPX)
				OPX.Modules.Declare{ id = 'alpha', requires = { 'beta' } }
				OPX.Modules.Declare{ id = 'beta', requires = { 'alpha' } }
			end,
			raises = 'cycle',
		},
		{
			label = 'dependencies start before their dependants',
			declare = function(OPX, seen)
				local first = OPX.Modules.Declare{ id = 'alpha' }
				local second = OPX.Modules.Declare{ id = 'beta', requires = { 'alpha' } }
				first.Start = function() seen[#seen + 1] = 'alpha' end
				second.Start = function() seen[#seen + 1] = 'beta' end
			end,
			expect = function(_, seen) return seen[1] == 'alpha' and seen[2] == 'beta' end,
		},
		{
			label = 'Stop runs in reverse dependency order',
			declare = function(OPX, seen)
				local first = OPX.Modules.Declare{ id = 'alpha' }
				local second = OPX.Modules.Declare{ id = 'beta', requires = { 'alpha' } }
				first.Stop = function() seen[#seen + 1] = 'alpha' end
				second.Stop = function() seen[#seen + 1] = 'beta' end
			end,
			after = function(OPX) OPX.Modules.Stop() end,
			expect = function(_, seen) return seen[1] == 'beta' and seen[2] == 'alpha' end,
		},
		{
			label = 'a fatal module that fails is reported as fatal',
			declare = function(OPX)
				local m = OPX.Modules.Declare{ id = 'alpha', fatal = true }
				m.Init = function() error('deliberate') end
			end,
			expectRun = function(ok, fatal) return ok == false and fatal == 'alpha' end,
		},
		{
			label = 'two providers of one contract is an error naming both',
			declare = function(OPX)
				local first = OPX.Modules.Declare{ id = 'alpha' }
				local second = OPX.Modules.Declare{ id = 'beta' }
				first.Api = function() OPX.Api.Provide('thing', 1, {}) end
				second.Api = function() OPX.Api.Provide('thing', 1, {}) end
			end,
			expect = function(OPX) return OPX.Modules.Record('beta').State == 'failed' end,
		},
		{
			label = 'Get answers nil below the requested version',
			declare = function(OPX)
				local m = OPX.Modules.Declare{ id = 'alpha' }
				m.Api = function() OPX.Api.Provide('thing', 1, { marker = true }) end
			end,
			expect = function(OPX)
				return OPX.Api.Get('thing', 2) == nil and OPX.Api.Get('thing', 1) ~= nil
			end,
		},
	}

	-- The registry alone, without the rest of the resource. `Resolve` memoises --
	-- correctly, since in production every module declares at load and boot runs
	-- once -- so each case needs its own registry, not a second pass over a used
	-- one.
	local REGISTRY = {
		'core/shared/main.lua', 'core/shared/channels.lua',
		'core/shared/registry.lua', 'core/shared/lifecycle.lua',
	}

	local function registry()
		local env, control = Host.Environment('server')
		for _, file in ipairs(REGISTRY) do
			assert(loadfile(file, 't', env), file)()
		end
		return env.OPX, control
	end

	for _, case in ipairs(cases) do
		local seen = {}
		local OPX, control = registry()

		local declaredOk, declareFailure = pcall(case.declare, OPX, seen)

		if not declaredOk then
			check(case.label, case.raises ~= nil
				and tostring(declareFailure):find(case.raises) ~= nil, declareFailure)
		else
			local ranOk, fatal
			local resolvedOk, runFailure = pcall(function()
				ranOk, fatal = OPX.Modules.Run()
			end)
			control.Pump(10)

			if not resolvedOk then
				check(case.label, case.raises ~= nil
					and tostring(runFailure):find(case.raises) ~= nil, runFailure)
			elseif case.raises then
				check(case.label, false, 'expected a raise mentioning ' .. case.raises)
			elseif case.expectRun then
				check(case.label, case.expectRun(ranOk, fatal) == true, tostring(fatal))
			else
				if case.after then case.after(OPX) end
				local held, detail = pcall(case.expect, OPX, seen)
				check(case.label, held and detail == true,
					held and 'predicate false' or detail)
			end
		end
	end
end

print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
