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
	Storage = true, Audit = true, Surface = true,
	-- `Lib` is the external library, `opx_lib`, loaded once by
	-- `lib/client/lib.lua` and client-only. It replaced `Rpc` and `Keys`, which
	-- were the two helpers in `lib/client/` that reached nothing this resource
	-- owns; everything under `lib/shared/` stays where it is because the
	-- dedicated-server sandbox has no `require` to load a library with.
	Lib = true,
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
	-- The two sides are kept APART because the runtimes are not the same. A
	-- `shared_script` appears in both lists, and that is exactly what makes the
	-- second check below work: the client-only names are forbidden to anything
	-- the server loads, so a shared file reaching for `require` is caught here
	-- rather than at the first server boot on the test machine.
	local serverSide, clientSide = {}, {}
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do serverSide[file] = true end
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do clientSide[file] = true end

	--- The file's body with comments stripped: they mention these names
	--- legitimately, and only a real reach counts.
	local function body(file)
		local handle = io.open(file, 'r')
		if handle == nil then return nil end
		local text = handle:read('a')
		handle:close()
		return text:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
	end

	local function reaches(file, names)
		local text = body(file)
		if text == nil then return nil end
		for _, name in ipairs(names) do
			if text:find('[^%w_.]' .. name .. '[.(]') then return name end
		end
		return nil
	end

	local offenders = {}
	for file in pairs(clientSide) do
		local name = reaches(file, Host.Sandbox)
		if name then offenders[#offenders + 1] = ('%s uses %s'):format(file, name) end
	end
	for file in pairs(serverSide) do
		local name = reaches(file, Host.Sandbox)
		if name then offenders[#offenders + 1] = ('%s uses %s'):format(file, name) end
	end
	table.sort(offenders)
	check('no shipped file reaches a global neither runtime has',
		#offenders == 0, table.concat(offenders, ', '))

	-- `require` is the only name in this list, and the rule it encodes is the
	-- reason `lib/client/lib.lua` may exist while `lib/shared/result.lua` may
	-- never import anything: the dedicated-server sandbox has no module loader,
	-- so a shared file that imported one would load on the client and fail on
	-- the server, in production, at boot.
	local crossed = {}
	for file in pairs(serverSide) do
		local name = reaches(file, Host.ClientOnly)
		if name then
			crossed[#crossed + 1] = ('%s uses %s, which the server has not'):format(file, name)
		end
	end
	table.sort(crossed)
	check('nothing the server loads reaches a client-only global',
		#crossed == 0, table.concat(crossed, ', '))
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

		-- The repeating work is registered rather than hand-rolled: six modules
		-- used to open their own `while true` loop, one of them with no pcall
		-- around the pass at all.
		local report = table.concat(env.OPX.Scheduler.Report(), '\n')
		local missing = {}
		for _, job in ipairs({ 'vehicles:save', 'needs:autosave', 'downed:scan',
			'weather:schedule', 'admin:travel-sweep', 'admin:tag-sweep', 'admin:door-sweep' }) do
			if not report:find(job, 1, true) then missing[#missing + 1] = job end
		end
		check('every server job is on the scheduler', #missing == 0, table.concat(missing, ', '))

		-- A PILE'S PROP MUST BE A CURATED ALIAS. `Open77.props.create` also takes a
		-- raw depot path, and that is the one form whose failure is invisible: the
		-- renderer matches a prebuilt host per alias, so a `.mesh` draws as a marker
		-- on the client AND returns an id, which stops `World.CreateDrop` falling
		-- back to the crate. An unknown alias is refused with `unknown_alias`, so it
		-- fails loudly and the crate is drawn. This checks the shipped data rather
		-- than the validator, because the validator is what someone would edit.
		local inventory = env.OPX.Modules.Get('inventory')
		local paths = {}
		if inventory and inventory.Catalog then
			for _, name in ipairs(inventory.Catalog.Names()) do
				local entry = inventory.Catalog.Get(name)
				local model = entry and entry.model
				if type(model) == 'string' and (model:find('[\\/]') or model:find('%.mesh$')) then
					paths[#paths + 1] = ('%s -> %s'):format(name, model)
				end
			end
		end
		check('every pile model is a props alias, never a depot path',
			#paths == 0, table.concat(paths, ', '))

		-- A tunable read at registration is frozen for the life of the resource.
		-- The tag sweep passes the read itself, so its line reports what the
		-- tunable says now.
		check('a job may take its cadence from a live tunable',
			report:find('admin:tag%-sweep%s+500ms') ~= nil,
			report:match('admin:tag%-sweep[^\n]*'))

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
		--
		-- `settings` is written in BEFORE the phases run, and for the offer policy
		-- that is not a convenience but the only route: the policy is resolved once
		-- in `Init` -- so a typo is journalled at boot rather than on every join --
		-- and a value set afterwards is a value nothing ever reads.
		-- @param locations table|nil
		-- @param character table|nil the contract the stub provides
		-- @param settings table|nil written over this module's config before boot
		-- @return table env
		-- @return table control
		local function spawnOnly(locations, character, settings)
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
			for key, value in pairs(settings or {}) do
				own.OPX.Config.MODULES.spawn[key] = value
			end
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

		-- ── the offer policy ──────────────────────────────────────────────────────
		-- WHICH WORLD ENTERS ARE ASKED, which is `OFFER_POLICY` and is the operator's
		-- call rather than this module's. Three values and no fourth, and each is
		-- exercised against the same two characters -- one whose row already holds a
		-- position and one that has never been placed -- because `position` is the
		-- whole of what 'first' reads and the whole of what the other two ignore.
		--
		-- Driven through probes rather than the booted server above: the policy is
		-- resolved ONCE, in `Init`, so that a typo is journalled at boot instead of
		-- on every join -- and a value written into the config after the phases have
		-- run is a value nothing will ever read again.
		do
			local SPOT = {
				{ id = 'spot', label = 'A Spot', district = 'Watson',
					x = 1, y = 2, z = 3, heading = 0.0 },
			}

			-- Two slots, two characters. `PlaceCharacter` answers true and is never
			-- the point here: what is under test is whether a menu is offered at
			-- all, which is decided before anything is placed.
			local STOOD, FRESH = 21, 22
			local function roster()
				return {
					GetPlayer = function(source)
						if source == STOOD then
							return { PlayerData = {
								citizenId = 'citizen-stood',
								position = { x = 9.0, y = 9.0, z = 9.0, heading = 0.0 },
							} }
						end
						if source == FRESH then
							return { PlayerData = { citizenId = 'citizen-fresh-2' } }
						end
						return nil
					end,
					PlaceCharacter = function() return true end,
				}
			end

			--- A world with one spot, two characters and the policy under test.
			-- @param policy any
			-- @return table module
			-- @return table control
			local function under(policy)
				local own, ctl = spawnOnly(SPOT, roster(), { OFFER_POLICY = policy })
				return own.OPX.Modules.Get('spawn'), ctl
			end

			-- ALWAYS: what this module did before the setting existed, and still the
			-- shipped default. Both characters are asked.
			do
				local module = under(spawn.Policy.ALWAYS)
				check("'always' is resolved as configured",
					module.OfferPolicy == spawn.Policy.ALWAYS, tostring(module.OfferPolicy))
				check('and a character that has stood somewhere is asked anyway',
					module.Offer(STOOD, 'citizen-stood') == true)
				check('as is one that never has',
					module.Offer(FRESH, 'citizen-fresh-2') == true)
			end

			-- FIRST: asked once per character, ever. The row's own position is the
			-- only thing consulted, so a returning player resumes in silence -- which
			-- is the behaviour the gate used to hard-wire, offered back as a choice.
			do
				local module = under(spawn.Policy.FIRST)
				check("'first' is resolved as configured",
					module.OfferPolicy == spawn.Policy.FIRST, tostring(module.OfferPolicy))
				check('a character that has never stood anywhere is asked',
					module.Offer(FRESH, 'citizen-fresh-2') == true)
				check('and its choice is outstanding', module.IsPending(FRESH) == true)
				check('a character whose row already holds a position is not asked',
					module.Offer(STOOD, 'citizen-stood') == false)
				check('and nothing is left outstanding for it',
					module.IsPending(STOOD) == false)
			end

			-- NEVER: nobody is asked, and -- the part that matters -- NOTHING IS
			-- ARMED. A 'never' that offered a menu and closed it again, or that
			-- recorded a choice nobody would ever make, would hold the character on
			-- a clock for a screen that is never drawn: on the shipped floors that
			-- is sixty seconds of a player standing in the pre-game position, with
			-- no name, waiting for a hold to release a menu that does not exist.
			do
				local module, ctl = under(spawn.Policy.NEVER)
				check("'never' is resolved as configured",
					module.OfferPolicy == spawn.Policy.NEVER, tostring(module.OfferPolicy))

				local mark = #ctl.clientEvents
				check('a brand new character is not asked',
					module.Offer(FRESH, 'citizen-fresh-2') == false)
				check('nor is a returning one',
					module.Offer(STOOD, 'citizen-stood') == false)
				check('and nothing is outstanding for either',
					module.IsPending(FRESH) == false and module.IsPending(STOOD) == false)
				check('and no offer reaches the client', #ctl.clientEvents == mark,
					('%d event(s) sent'):format(#ctl.clientEvents - mark))

				-- Ninety seconds, which is past the sixty-second HOLD floor and far
				-- past any timeout. A hold armed anywhere would settle here and put a
				-- `spawn:close` on the wire; the silence is the assertion.
				ctl.Pump(900)
				check('no hold is armed: nothing settles once the window would have run',
					module.IsPending(FRESH) == false and module.IsPending(STOOD) == false)
				check('and no menu is taken down, because none was ever put up',
					#ctl.clientEvents == mark,
					('%d event(s) sent'):format(#ctl.clientEvents - mark))
			end

			-- AN UNKNOWN VALUE. Refused with a line in the journal and replaced with
			-- the named default -- never honoured, and never silently taken as "off".
			-- A typo that quietly stopped offering the menu is indistinguishable from
			-- the module being broken, which is the failure this check exists for.
			do
				local own, ctl = spawnOnly(SPOT, roster(), { OFFER_POLICY = 'sometimes' })
				local module = own.OPX.Modules.Get('spawn')
				check('an unknown policy is refused rather than honoured',
					module.OfferPolicy == spawn.POLICY_DEFAULT, tostring(module.OfferPolicy))
				check('and it is named in the journal, with what is running instead',
					table.concat(ctl.log.warn, ' | '):find('OFFER_POLICY sometimes') ~= nil,
					table.concat(ctl.log.warn, ' | '))
				check('and the fallback behaves, so a typo costs a log line and no more',
					module.Offer(STOOD, 'citizen-stood') == true)
			end

			-- A POLICY THAT IS NOT A STRING AT ALL. `OFFER_POLICY = true` is the shape
			-- of a mis-edit that turns a named setting into the boolean beside it, and
			-- it must take the same route rather than raising out of `Init`.
			do
				local own = spawnOnly(SPOT, roster(), { OFFER_POLICY = true })
				local module = own.OPX.Modules.Get('spawn')
				check('a policy that is not a string is refused the same way',
					module.OfferPolicy == spawn.POLICY_DEFAULT, tostring(module.OfferPolicy))
			end
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
			-- AND NO WINDOW. The page drew a countdown from this and the countdown
			-- was display only -- it reached zero and did nothing, because the
			-- server counts the same window against its own clock and only that
			-- count ends the choice. Sending it was a deadline put in front of a
			-- one-press decision for no behaviour at all, so the page is not told:
			-- running out still arrives as `spawn:close` with `reason = 'timeout'`.
			check('and no window, because the page no longer counts one',
				opened.payload.timeoutMs == nil, tostring(opened.payload.timeoutMs))
			-- The controls the page is handed are the question and the hint. There
			-- is no confirm label because there is no confirm control: a click on a
			-- card IS the spawn, and a second control for an intent already sent
			-- read as a step the surface deliberately does not have.
			check('and the two sentences it draws, and no confirm label',
				opened.payload.title ~= nil and opened.payload.hint ~= nil
					and opened.payload.confirm == nil and opened.payload.deadline == nil)
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

-- ── deleting a character, and everything it owned ────────────────────────────
-- WHAT A DELETE ACTUALLY REMOVES. Every table keyed on a citizen id carries
-- `ON DELETE CASCADE` onto `opx77_characters` and NOT ONE OF THEM HAS EVER FIRED
-- on a player deleting a character, because the delete is SOFT: `deleted_at` is
-- stamped and the row stays, and a cascade fires for a DELETE and never for an
-- UPDATE. So the foreign keys are all correct and all beside the point, and what
-- does the work is `character:deleted` -- a seam that was raised, listened to by
-- nobody, and left every deleted character's clothes, needs, containers and cars
-- in the database for ever.
section('deleting a character')
do
	local env, control, why = boot('server')
	check('server boots for the delete tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local character = OPX.Modules.Get('character')

		-- THE TWO STAFF DOORS, beside the self-service ones. They do not check
		-- ownership and do not read `SELF_DELETE`; the access list is the check,
		-- and it has happened before either is reached.
		local contract = OPX.Api.Get('character')
		check('the staff listing is published for the admin menu to read',
			contract ~= nil and type(contract.ListCharactersFor) == 'function')
		check('so is the staff rename', contract ~= nil and type(contract.RenameCharacter) == 'function')
		check('and the staff delete', contract ~= nil and type(contract.RemoveCharacter) == 'function')
		check('beside the self-service delete, which is a different door',
			contract ~= nil and type(contract.DeleteCharacter) == 'function'
				and contract.DeleteCharacter ~= contract.RemoveCharacter)

		-- EVERY MODULE THAT OWNS A PER-CHARACTER TABLE ANSWERS THE ANNOUNCEMENT.
		-- Spied rather than driven through the database, which this host has none
		-- of: what is under test is that each module LISTENS and names its own
		-- rows, not that MySQL then deletes them.
		local purged = {}
		local originals = {}
		for _, owner in ipairs({ 'appearance', 'needs', 'inventory', 'vehicles' }) do
			local module = OPX.Modules.Get(owner)
			local storage = module and module.Storage
			if storage ~= nil and type(storage.PurgeCharacter) == 'function' then
				originals[owner] = storage.PurgeCharacter
				storage.PurgeCharacter = function(citizenId)
					purged[owner] = citizenId
					return OPX.Result.Ok(true)
				end
			end
		end
		-- `downed` names its purge `Clear`: it already had the statement, and the
		-- write it queues is the same one a revive writes.
		local downed = OPX.Modules.Get('downed')
		local downedClear = downed and downed.Storage and downed.Storage.Clear
		if downedClear then
			downed.Storage.Clear = function(citizenId) purged.downed = citizenId end
		end

		local before = #control.log.error
		control.Fire(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'), 12, 'citizen-gone')

		for _, owner in ipairs({ 'appearance', 'needs', 'inventory', 'vehicles', 'downed' }) do
			check(('%s removes what it stored for a deleted character'):format(owner),
				purged[owner] == 'citizen-gone', tostring(purged[owner]))
		end
		check('and nothing raised doing it', #control.log.error == before,
			table.concat(control.log.error, ' | '))

		-- A PAYLOAD THAT IS NOT A CITIZEN ID. The announcement is internal and its
		-- handlers still check, because a handler that ran on nil would issue a
		-- delete with an empty parameter -- which is a statement that matches
		-- whatever the column defaults to rather than nothing.
		purged = {}
		control.Fire(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'), 12, nil)
		control.Fire(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'), 12, '')
		local any = false
		for _ in pairs(purged) do any = true end
		check('a delete announcement with no citizen id removes nothing', not any)

		for owner, original in pairs(originals) do
			OPX.Modules.Get(owner).Storage.PurgeCharacter = original
		end
		if downedClear then downed.Storage.Clear = downedClear end

		-- THE ONE TABLE THIS MODULE OWNS ITSELF is purged inline rather than over
		-- the announcement, and the two config hooks are still there for tables
		-- nothing in this runtime owns. Read out of the source, because driving it
		-- needs a database.
		local handle = io.open('modules/character/server/character.lua', 'r')
		local body = handle:read('a')
		handle:close()
		local worker = body:match('local function removeCharacter.-\nend\n')
		check('the delete purges the memberships it owns itself',
			worker ~= nil and worker:find('opx77_character_groups', 1, true) ~= nil)
		check('and still runs the operator cascade list for tables nothing owns',
			worker ~= nil and worker:find('CASCADE_TABLES', 1, true) ~= nil)
		check('and announces the delete so every other module can follow',
			worker ~= nil and worker:find('IN_DELETED', 1, true) ~= nil)
		-- UNDER pcall: the audit is already written and the session still has to be
		-- ended, so a handler that raises must not take either with it.
		check('under a pcall, so one bad listener cannot strand the player',
			worker ~= nil and worker:find('pcall(TriggerEvent, M.Event.IN_DELETED', 1, true) ~= nil)

		-- WHETHER A PLAYER MAY DELETE THEIR OWN. Refused rather than hidden: a
		-- command that silently did nothing would have them trying it again and
		-- then asking staff whether it had worked.
		local saved = OPX.Config.MODULES.character.CHARACTERS.SELF_DELETE
		OPX.Config.MODULES.character.CHARACTERS.SELF_DELETE = false
		local refused = character.DeleteCharacter(77, 'ABC-1234')
		check('with SELF_DELETE off, a player deleting their own is refused',
			refused ~= nil and refused.ok == false, refused and tostring(refused.error))
		check('by a code a player can be shown, not a silent nothing',
			refused ~= nil and refused.error == 'character.deleteNotAllowed',
			refused and tostring(refused.error))
		check('and the code is a catalogue key, so it reads as a sentence',
			OPX.Locale.Exists('character.deleteNotAllowed'))
		OPX.Config.MODULES.character.CHARACTERS.SELF_DELETE = saved
		check('the shipped configuration answers the question either way',
			type(OPX.Config.MODULES.character.CHARACTERS.SELF_DELETE) == 'boolean',
			tostring(OPX.Config.MODULES.character.CHARACTERS.SELF_DELETE))

		-- ── the staff menu's own door ────────────────────────────────────────
		local admin = OPX.Modules.Get('admin')
		check('the three character grants are named in one place, as their own area',
			admin.Command.CHARACTER_LIST == 'opx.admin.character.list'
				and admin.Command.CHARACTER_RENAME == 'opx.admin.character.rename'
				and admin.Command.CHARACTER_DELETE == 'opx.admin.character.delete')
		-- NOT `player.*`, and the distinction is the whole reason for a new area:
		-- that namespace is the session and the puppet, and both die with the
		-- connection. These reach rows that outlive it.
		check('and not under the session namespace, which dies with the connection',
			admin.Command.CHARACTER_DELETE:find('player', 1, true) == nil)

		for _, name in ipairs({ 'opx.admin.character.list', 'opx.admin.character.rename',
			'opx.admin.character.delete' }) do
			local registered = control.commands[name]
			check(('%s is registered'):format(name), registered ~= nil)
			-- RESTRICTED, every one: the host refuses the line before a handler
			-- runs, which is the only permission check this module has.
			check(('%s is restricted, which is the whole check'):format(name),
				registered ~= nil and registered.restricted == true)
		end

		-- A refusal code with no catalogue key behind it reaches a player as the
		-- key itself, and these two are new.
		check('the new refusal codes are sentences in both catalogues',
			OPX.Locale.Exists('admin.error.badName')
				and OPX.Locale.Exists('admin.error.charactersUnavailable'))
	end
end

-- ── taking another character ─────────────────────────────────────────────────
-- WHETHER `opx.select` KICKS, which is `CHARACTERS.SWITCH` and is the operator's
-- call. The two values are not a preference between equals: one takes the other
-- character here in the world, the other ends the session so the next connection
-- arrives on it. `opx.create` is covered by NEITHER and must always disconnect,
-- because a new character needs the game's own creator and that is a join-time
-- screen -- which is a platform fact rather than a decision, so what is asserted
-- here is that no setting can turn it off.
section('taking another character')
do
	--- A world holding only what settles the switch mode.
	-- @param ... string|nil the CHARACTERS.SWITCH to write in, or nothing to keep
	--   what the file ships
	-- @return table module
	-- @return table control
	local function switchOnly(...)
		local own, ctl = Host.Environment('server')
		for _, file in ipairs({
			'core/shared/main.lua', 'core/shared/channels.lua',
			'core/shared/registry.lua', 'core/shared/lifecycle.lua',
			'lib/shared/math.lua', 'lib/shared/result.lua', 'lib/shared/validate.lua',
			'lib/shared/text.lua', 'lib/shared/string.lua', 'lib/shared/table.lua',
			'config/shared.lua', 'config/character.lua', 'modules/character/module.lua',
		}) do
			assert(loadfile(file, 't', own), file)()
		end
		local module = own.OPX.Modules.Get('character')
		if select('#', ...) > 0 then module.Settings.CHARACTERS.SWITCH = (select(1, ...)) end
		return module, ctl
	end

	local vocabulary = switchOnly()
	check('the switch vocabulary is declared in the shared file',
		type(vocabulary.Switch) == 'table' and type(vocabulary.KnownSwitch) == 'function'
			and vocabulary.SWITCH_DEFAULT == vocabulary.Switch.RECONNECT)

	check('both switch modes are recognised',
		vocabulary.KnownSwitch('relog') == 'relog'
			and vocabulary.KnownSwitch('reconnect') == 'reconnect')
	-- A NEAR MISS IS A MISS, and the fallback is the one that disconnects: a typo
	-- that quietly took the safer path costs a player one reconnect, where a typo
	-- that quietly took the newer one costs whatever it turns out to break.
	check('anything else is not a switch mode, whatever its shape',
		vocabulary.KnownSwitch('Relog') == nil and vocabulary.KnownSwitch('soft') == nil
			and vocabulary.KnownSwitch(true) == nil and vocabulary.KnownSwitch(nil) == nil)
	check('the shipped configuration names one of the two',
		vocabulary.KnownSwitch(vocabulary.Settings.CHARACTERS.SWITCH) ~= nil,
		tostring(vocabulary.Settings.CHARACTERS.SWITCH))

	-- RESOLVED ONCE, AT BOOT, and journalled on a bad value -- so a typo is named
	-- in the block an operator reads after editing a config file rather than in
	-- the middle of somebody's switch, where nobody reads it.
	do
		local env, control, why = boot('server')
		check('server boots for the switch tests', why == nil, why)
		if why == nil then
			local character = env.OPX.Modules.Get('character')
			check('the switch mode is settled at boot rather than at the point of use',
				character.KnownSwitch(character.SwitchMode) ~= nil,
				tostring(character.SwitchMode))
			check('and it is the one the file configures',
				character.SwitchMode == env.OPX.Config.MODULES.character.CHARACTERS.SWITCH,
				tostring(character.SwitchMode))
			-- The relog calls `enterCharacter`, which is declared three hundred
			-- lines below `SwitchTo`. Without the forward declaration that call
			-- compiles against a GLOBAL of the same name -- nil -- and raises
			-- inside a command thread, which is exactly where nobody is looking.
			check('the soft path this depends on is published and is a function',
				type(env.OPX.Api.Get('character').SelectCharacter) == 'function')
			check('and the kicking path is still published beside it',
				type(env.OPX.Api.Get('character').SwitchTo) == 'function')
			check('no thread died taking either of them up',
				not table.concat(control.log.error, ' | '):find('thread died'),
				table.concat(control.log.error, ' | '))
		end
	end

	-- AN UNKNOWN VALUE falls back to the disconnect and says so.
	do
		local own, ctl = Host.Environment('server')
		for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do
			assert(loadfile(file, 't', own), file)()
			if file == 'config/character.lua' then
				own.OPX.Config.MODULES.character.CHARACTERS.SWITCH = 'soft'
			end
		end
		ctl.Pump(20)
		local character = own.OPX.Modules.Get('character')
		check('an unknown switch mode is refused rather than honoured',
			character.SwitchMode == character.SWITCH_DEFAULT, tostring(character.SwitchMode))
		check('and it is named in the journal, with what is running instead',
			table.concat(ctl.log.warn, ' | '):find('CHARACTERS.SWITCH soft') ~= nil,
			table.concat(ctl.log.warn, ' | '))
	end

	-- THE ONE THING NO SETTING MAY CHANGE. `opx.create` clears the lock and ends
	-- the session, under either mode, because a new character needs the game's own
	-- creator and resetting the bootstrap mid-session was measured in game and
	-- does not draw one -- it strands the player under the loading cover. Asserted
	-- by reading the function rather than by running it: it needs a session, a
	-- database and a live slot, none of which this host has.
	do
		local handle = io.open('modules/character/server/character.lua', 'r')
		local body = handle:read('a')
		handle:close()
		local newCharacter = body:match('function M%.NewCharacter.-\nend\n')
		check('opx.create still ends the session in its own body',
			newCharacter ~= nil and newCharacter:find('endSession', 1, true) ~= nil)
		check('and never takes the soft path',
			newCharacter ~= nil and newCharacter:find('enterCharacter', 1, true) == nil)
		-- And the switch DOES, which is the whole change: the same read, so the two
		-- cannot drift into agreeing by accident.
		local switchTo = body:match('function M%.SwitchTo.-\nend\n')
		check('while opx.select can take the character here instead',
			switchTo ~= nil and switchTo:find('enterCharacter', 1, true) ~= nil)
		check('and still falls back to ending the session',
			switchTo ~= nil and switchTo:find('endSession', 1, true) ~= nil)
	end
end

-- ── the fitting room, and the join it sits in the middle of ──────────────────
-- WHAT A PLAYER WEARS WHEN THEY ARRIVE, and -- the harder half -- WHEN THEY ARE
-- ASKED. A brand new character answers three questions at one instant: a name, an
-- outfit and a spawn point. Nothing schedules them. What keeps them apart is one
-- rule applied twice -- a view stands aside while the view in front of it reports
-- itself busy -- so the checks below drive the real entry and spawn modules rather
-- than asserting against a plan.
section('the fitting room at join time')
do
	--- A world holding only what settles the fitting-room policy.
	-- The vocabulary and its resolution live in the SHARED file, so they can be put
	-- under test without a client VM full of natives this host does not have.
	-- Called with NO argument it leaves the shipped block alone; called with one
	-- -- `nil` included -- it writes that block in. The two are different cases
	-- and Lua cannot tell them apart from the value, so `select('#', ...)` is what
	-- separates "test the file" from "test a configuration that lost the block".
	-- @param ... table|nil the WARDROBE block to write in
	-- @return table module
	-- @return table control
	local function policyOnly(...)
		local own, ctl = Host.Environment('client')
		for _, file in ipairs({
			'core/shared/main.lua', 'core/shared/channels.lua',
			'core/shared/registry.lua', 'core/shared/lifecycle.lua',
			'lib/shared/math.lua', 'config/appearance.lua',
			'modules/appearance/module.lua',
		}) do
			assert(loadfile(file, 't', own), file)()
		end
		local module = own.OPX.Modules.Get('appearance')
		if select('#', ...) > 0 then module.Settings.WARDROBE = (select(1, ...)) end
		return module, ctl
	end

	local vocabulary = policyOnly(nil)
	check('the fitting-room policy vocabulary is declared in the shared file',
		type(vocabulary.WardrobePolicy) == 'table' and
			type(vocabulary.KnownWardrobePolicy) == 'function')

	-- EACH OF THE THREE, resolved from a configuration rather than from a literal:
	-- the operator types one of these strings and the branch that reads it compares
	-- against the same table, so a value the vocabulary carries and the resolver
	-- refuses cannot happen.
	for _, policy in ipairs({ 'first', 'always', 'never' }) do
		local module = policyOnly({ OFFER_POLICY = policy })
		check(('the fitting-room policy %s is resolved as configured'):format(policy),
			module.ResolveWardrobePolicy() == policy)
	end

	-- AN UNKNOWN VALUE. Refused with a line in the journal and replaced with the
	-- named default -- never honoured, and never silently taken as "off". A typo
	-- that quietly stopped offering the room is indistinguishable from the room
	-- being broken, which is the failure this check exists for.
	do
		local module, ctl = policyOnly({ OFFER_POLICY = 'creation' })
		check('an unknown fitting-room policy is refused rather than honoured',
			module.ResolveWardrobePolicy() == module.WARDROBE_POLICY_DEFAULT,
			tostring(module.ResolveWardrobePolicy()))
		check('and it is named in the journal, with what is running instead',
			table.concat(ctl.log.warn, ' | '):find('OFFER_POLICY creation') ~= nil,
			table.concat(ctl.log.warn, ' | '))
	end

	-- NOT A STRING AT ALL. `OFFER_POLICY = true` is the shape of a mis-edit that
	-- turns a named setting back into the boolean it replaced -- and this setting
	-- did replace one -- so it has to take the same route rather than raising out
	-- of the resolution.
	check('a fitting-room policy that is not a string is refused the same way',
		policyOnly({ OFFER_POLICY = true }).ResolveWardrobePolicy() ==
			vocabulary.WARDROBE_POLICY_DEFAULT)
	check('and so is a configuration with no WARDROBE block at all',
		policyOnly(nil).ResolveWardrobePolicy() == vocabulary.WARDROBE_POLICY_DEFAULT)

	-- A NEAR MISS IS A MISS. The comparison is exact on purpose: a policy matched
	-- case-insensitively would accept 'First' here and be compared against 'first'
	-- at the branch that reads it.
	check('a near miss is not one of the three fitting-room policies',
		vocabulary.KnownWardrobePolicy('First') == nil and
			vocabulary.KnownWardrobePolicy('') == nil and
			vocabulary.KnownWardrobePolicy({}) == nil)

	-- THE SHIPPED CONFIGURATION, read out of the file rather than named here, so
	-- this check is wrong the day somebody edits it to something the module
	-- refuses -- which is the one way an operator would never see the warning.
	do
		local module = policyOnly()
		local block = type(module.Settings.WARDROBE) == 'table' and module.Settings.WARDROBE or {}
		check('the shipped configuration names one of the three',
			module.KnownWardrobePolicy(block.OFFER_POLICY) ~= nil,
			tostring(block.OFFER_POLICY))
		-- The other half of the shipped block, and it has to be a real duration:
		-- a zero here is a room that gives up in the tick it was owed, which is a
		-- join that never draws one and never says why.
		check('and a positive window to wait for the room in',
			(tonumber(block.CREATION_WAIT_MS) or 0) > 0, tostring(block.CREATION_WAIT_MS))
	end

	-- ── the join sequence ────────────────────────────────────────────────────
	-- A WHOLE CLIENT, with the policy written in between the config file that
	-- declares it and the `Init` that settles it: the policy is resolved once, at
	-- boot, so a value set after the phases have run is a value nothing reads.
	--
	-- The natives installed below are the minimum that lets the appearance module
	-- START -- it refuses outright without an appearance, session and character
	-- namespace -- plus an equipment namespace, which is what makes the fitting
	-- room's refusal RETRYABLE rather than final. That distinction is the whole of
	-- what is under test: a room that keeps trying holds the join, and a room that
	-- can never open has to let it go.
	-- @param policy string
	-- @param waitMs integer how long the room is waited for
	-- @param blind boolean|nil switch the two view modules off
	-- @return table env
	-- @return table control
	local function joinClient(policy, waitMs, blind)
		local own, ctl = Host.Environment('client')
		own.Open77.appearance = {
			captureBody = function() return nil, 'no_host' end,
			takeBodyFamilyTransition = function() return nil end,
			finishCommit = function() return true end,
		}
		own.Open77.session = {
			resolveCharacterBootstrap = function() return false, 'no_host' end,
			isCharacterBootstrapPending = function() return false end,
			failCharacterBootstrap = function() return true end,
			hasCharacterBootstrap = function() return false end,
			gameplayReady = function() return true end,
		}
		own.Open77.equipment = {
			apply = function() return true end,
			records = function() return {} end,
			registry = function() return {} end,
			info = function() return nil end,
		}

		for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
			assert(loadfile(file, 't', own), file)()
			if file == 'config/appearance.lua' then
				local block = own.OPX.Config.MODULES.appearance.WARDROBE
				block.OFFER_POLICY = policy
				block.CREATION_WAIT_MS = waitMs
			elseif blind and file == 'config/panel.lua' then
				own.OPX.Config.MODULES.panel.enabled = false
			elseif blind and file == 'config/menu.lua' then
				own.OPX.Config.MODULES.menu.enabled = false
			end
		end

		ctl.Fire('onClientResourceStart', 'opx_infinity')
		ctl.Pump(60)
		ctl.ReadyPages()
		return own, ctl
	end

	--- Every `entry:state` a join raises from here on, as `open/phase`.
	local function watchEntry(env)
		local seen = {}
		env.AddEventHandler(env.OPX.Event(env.OPX.Channel.LOCAL, 'entry', 'state'),
			function(payload)
				seen[#seen + 1] = tostring(payload.open) .. '/' .. tostring(payload.phase)
			end)
		return seen
	end

	--- The first payload sent to the surface on a channel, or nil.
	local function drew(page, channel)
		for index = 1, #page.sent do
			if page.sent[index].channel == channel then return page.sent[index] end
		end
		return nil
	end

	--- How many payloads have been sent to the surface on a channel.
	local function times(page, channel)
		local count = 0
		for index = 1, #page.sent do
			if page.sent[index].channel == channel then count = count + 1 end
		end
		return count
	end

	--- Loads a character over the character module's own bus.
	local function arrive(env, control, citizenId)
		control.Fire(env.OPX.Event(env.OPX.Channel.LOCAL, 'character', 'loaded'),
			{ citizenId = citizenId, charInfo = { gender = 'female' } })
	end

	-- 'first': a brand new character, which is the case this whole seam exists for.
	do
		local env, control = joinClient('first', 400)
		local OPX = env.OPX
		local appearance = OPX.Modules.Get('appearance')
		local spawn = OPX.Modules.Get('spawn')
		local page = control.pages[1]

		check('the client boots with a fitting-room policy under test',
			OPX.Modules.IsRunning('appearance') and OPX.Modules.IsRunning('entry')
				and OPX.Modules.IsRunning('spawn'),
			OPX.Modules.Record('appearance').Reason)
		check('and the policy reached the module through Init, not the point of use',
			appearance.WardrobeOffer == 'first', tostring(appearance.WardrobeOffer))

		arrive(env, control, 'citizen-dress')
		local states = watchEntry(env)
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'created', citizenId = 'citizen-dress' })

		check('a character the creator has just built is owed a fitting room',
			appearance.Wardrobe.Owed() == true)
		-- THE CLAIM IS UP BEFORE THE ROOM IS. Nothing is on screen yet -- this host
		-- has no playable puppet, and a real client has a name form on the keyboard
		-- -- and that gap is exactly when the spawn menu would otherwise open.
		check('and the join reports itself busy, naming the clothes',
			states[#states] == 'true/wardrobe', table.concat(states, ', '))

		control.netEvents[spawn.Event.OFFER]({ timeoutMs = 5000 })
		check('so the spawn menu stands aside while the room is owed',
			drew(page, 'opx:spawn:open') == nil)

		-- THE ROOM NOBODY CAN DRAW. Every try here is refused for a reason that
		-- means 'not yet', so only the window ends it -- and a join held by a room
		-- that will never open is the one failure that costs a player their spawn
		-- choice with nothing going wrong anywhere.
		control.Pump(12)
		check('the wait runs out and the claim is withdrawn',
			appearance.Wardrobe.Owed() == false)
		check('the join reports itself idle again',
			states[#states] == 'false/idle', table.concat(states, ', '))
		check('and the spawn menu opens, late rather than never',
			drew(page, 'opx:spawn:open') ~= nil)
	end

	-- 'never': nobody is handed one, and -- the part that matters -- NOTHING IS
	-- CLAIMED. A 'never' that raised a claim and withdrew it again would hold the
	-- spawn menu shut for a room that was never coming.
	do
		local env, control = joinClient('never', 400)
		local OPX = env.OPX
		local appearance = OPX.Modules.Get('appearance')
		local spawn = OPX.Modules.Get('spawn')
		local page = control.pages[1]

		arrive(env, control, 'citizen-plain')
		local states = watchEntry(env)
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'created', citizenId = 'citizen-plain' })

		check('never owes a brand new character no fitting room',
			appearance.Wardrobe.Owed() == false)
		-- The bus still speaks -- `created` is the entry module's own creator
		-- finishing -- but it never names the clothes, which is what the spawn
		-- menu waits on.
		check('and never names the clothes on the join bus',
			table.concat(states, ', '):find('wardrobe') == nil,
			table.concat(states, ', '))

		control.netEvents[spawn.Event.OFFER]({ timeoutMs = 5000 })
		check('so the spawn menu follows the name form directly, as it always did',
			drew(page, 'opx:spawn:open') ~= nil)
	end

	-- 'always' AND 'first' ON A RETURNING CHARACTER, which raises no `created` at
	-- all. The moment one is offered is the stored clothes going ON: opened before
	-- that, cancelling would put back the pristine puppet's clothes rather than the
	-- ones the player walked in wearing.
	do
		local env, control = joinClient('always', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		arrive(env, control, 'citizen-back')
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'clothingRestored', citizenId = 'citizen-back' })
		check('always offers a returning character one once its clothes are on',
			appearance.Wardrobe.Owed() == true)
	end

	do
		local env, control = joinClient('first', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		arrive(env, control, 'citizen-back-2')
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'clothingRestored', citizenId = 'citizen-back-2' })
		check('and first leaves a returning character alone',
			appearance.Wardrobe.Owed() == false)
	end

	-- THE CHARACTER THAT LEAVES MID-CLAIM. A disconnect is not visible on a client
	-- at all; what the client sees is the character unloading. A claim left
	-- standing for nobody would hold the join open for the rest of the session,
	-- with nothing to draw and nobody to draw it for.
	do
		local env, control = joinClient('first', 60000)
		local OPX = env.OPX
		local appearance = OPX.Modules.Get('appearance')

		arrive(env, control, 'citizen-gone')
		local states = watchEntry(env)
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'created', citizenId = 'citizen-gone' })
		check('a long window holds the claim open while the room is retried',
			appearance.Wardrobe.Owed() == true)

		control.Fire(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'))
		check('the join is released the moment the character goes',
			states[#states] == 'false/idle', table.concat(states, ', '))
		control.Pump(4)
		check('and the claim is withdrawn rather than waiting out the window',
			appearance.Wardrobe.Owed() == false)
	end

	-- ── the view ─────────────────────────────────────────────────────────────
	-- THE SEAM'S OTHER END. `wardrobe.lua` draws nothing and publishes on
	-- `ON_VIEW`; `client/view.lua` is the only file that knows the fitting room is
	-- a `panel` and the appearance panel a `menu`. Driven by publishing on the seam
	-- rather than by opening a real room, because a real room needs a playable
	-- puppet and a clothing catalogue, neither of which is what this tests.
	do
		local env, control = joinClient('never', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		local page = control.pages[1]

		env.TriggerEvent(appearance.Event.ON_VIEW, {
			kind = 'room',
			eyebrow = 'FIRST OUTFIT', title = 'Wardrobe', intro = 'Dress your character.',
			search = 'Search', loading = true,
			labels = { count = '{from}-{to} of {total}', empty = 'Nothing.',
				loading = 'Reading...' },
			actions = { { id = 'cancel', label = 'Skip' },
				{ id = 'save', label = 'Wear this', primary = true } },
			tabs = { { id = 'InnerChest', label = 'Inner chest', marked = false } },
			tab = 'InnerChest',
			selected = { InnerChest = false },
			summary = { label = 'Inner chest', value = 'nothing',
				action = { id = 'remove', label = 'Take off', disabled = true } },
			status = false,
		})

		local opened = drew(page, 'opx:panel:open')
		check('the fitting room is drawn by the panel module', opened ~= nil)
		check('carrying the state half own first frame, verbatim',
			opened ~= nil and opened.payload.eyebrow == 'FIRST OUTFIT'
				and opened.payload.title == 'Wardrobe',
			opened and tostring(opened.payload.title))
		-- The seam's routing field is not part of the panel contract, which refuses
		-- a spec carrying a field it does not know -- WHOLE, so a `kind` left on
		-- would have cost the room rather than the field.
		check('and not the seam own routing field',
			opened ~= nil and opened.payload.kind == nil)

		env.TriggerEvent(appearance.Event.ON_VIEW, {
			kind = 'roomItems', final = true,
			items = { { id = 'Items.Jacket_01', tab = 'InnerChest', label = 'Jacket 01',
				detail = 'Items.Jacket_01' } },
		})
		local batch = drew(page, 'opx:panel:items')
		check('a catalogue batch reaches the page, marked as the last',
			batch ~= nil and batch.payload.done == true
				and batch.payload.items[1].id == 'Items.Jacket_01')

		-- THE CATALOGUE AT THE SIZE IT ACTUALLY ARRIVES AT. The one-item batch
		-- above passed on every build and proved nothing: the fitting room streams
		-- a hundred pieces at a time, and a hundred parsed items is 1207 value
		-- nodes against a host bound of 1024. The host refused every batch,
		-- `WebUI.Page.send` answered false, `panel` never read that answer and
		-- reported the refusal to its caller as a delivery -- so the room sat on
		-- 'Reading the catalogue' for good with no error anywhere. `tests/host.lua`
		-- models the bound now, so this is the check that fails if the split goes.
		local mark, turned = #page.sent, #page.refused
		local bulk = {}
		for index = 1, 100 do
			local record = ('Items.Jacket_%03d_basic_variant'):format(index)
			bulk[index] = { id = record, tab = 'InnerChest',
				label = ('Jacket %03d basic variant'):format(index), detail = record }
		end
		env.TriggerEvent(appearance.Event.ON_VIEW,
			{ kind = 'roomItems', final = true, items = bulk })

		local drawn, sends, dones = 0, 0, 0
		for index = mark + 1, #page.sent do
			local sent = page.sent[index]
			if sent.channel == 'opx:panel:items' then
				sends = sends + 1
				drawn = drawn + #sent.payload.items
				if sent.payload.done == true then dones = dones + 1 end
			end
		end

		-- Counted from `turned` rather than from zero, and NOT because a refusal
		-- before this point is acceptable. `opx:locale:set` is one: the page is
		-- handed the whole string catalogue in a single payload from
		-- `core/client/ui.lua`, which is 2539 nodes here and more on a live server,
		-- so every page that reads a string through `useLocale` renders its keys.
		-- That is a real defect, it is not this one, and chunking a catalogue is
		-- not a change to make inside a fitting-room fix.
		check('the host turns away no catalogue batch',
			#page.refused == turned,
			#page.refused > turned
				and ('%s at %d nodes'):format(page.refused[turned + 1].channel,
					page.refused[turned + 1].nodes) or '')
		check('a hundred-piece batch reaches the page whole', drawn == 100,
			('%d of 100, over %d send(s)'):format(drawn, sends))
		check('over more than one send, because one would not have fitted',
			sends > 1, ('%d send(s)'):format(sends))
		check('and exactly one of them says the catalogue has ended',
			dones == 1, ('%d done flag(s)'):format(dones))

		-- THE CONTRACT'S OWN MAXIMUM HAS TO WORK. `MAX_APPEND` is what a caller is
		-- told it may hand over at once, and it was two hundred while two hundred
		-- was a payload of 2407 -- a bound that refused nothing and delivered
		-- nothing.
		local wide = #page.sent
		local full = {}
		for index = 1, 200 do
			local record = ('Items.Shoe_%03d'):format(index)
			full[index] = { id = record, tab = 'Feet', label = 'Shoe ' .. index, detail = record }
		end
		env.TriggerEvent(appearance.Event.ON_VIEW,
			{ kind = 'roomItems', final = false, items = full })
		local reached = 0
		for index = wide + 1, #page.sent do
			if page.sent[index].channel == 'opx:panel:items' then
				reached = reached + #page.sent[index].payload.items
			end
		end
		check('and a batch at the append bound arrives whole as well',
			reached == 200 and #page.refused == turned, ('%d of 200'):format(reached))

		-- THE STREAM'S LAST WORD IS AN EMPTY BATCH. The catalogue is sorted in
		-- seven piles now and the seventh is free to be empty, so a `final` hung
		-- on the last piece sent would leave the room loading forever for a body
		-- whose last slot has nothing in it.
		local tail = #page.sent
		env.TriggerEvent(appearance.Event.ON_VIEW,
			{ kind = 'roomItems', final = true, items = {} })
		local ended
		for index = tail + 1, #page.sent do
			if page.sent[index].channel == 'opx:panel:items' then ended = page.sent[index] end
		end
		check('an empty final batch still lands, so the room stops reading',
			ended ~= nil and #ended.payload.items == 0 and ended.payload.done == true)

		-- WHAT THE PLAYER DID, coming back through the one function the seam
		-- documents. Everything on it is re-checked there against state this bridge
		-- cannot see: the record against the catalogue that was streamed, the
		-- button against the list that was drawn.
		local seen = {}
		local real = appearance.FromView
		appearance.FromView = function(action, payload)
			seen[#seen + 1] = action
			return real(action, payload)
		end
		local handle = opened.payload.handle
		control.PageEmit(page, 'opx:panel:select', { handle = handle, item = 'Items.Jacket_01' })
		control.PageEmit(page, 'opx:panel:action', { handle = handle, id = 'cancel' })
		check('a click on a piece comes back as a room selection',
			seen[1] == 'room.select', table.concat(seen, ', '))
		check('and a button as a room action', seen[2] == 'room.action',
			table.concat(seen, ', '))

		-- A PAYLOAD FOR A ROOM THAT IS GONE. The handle is the capability, and a
		-- payload naming another one is dropped before this bridge ever sees it --
		-- so a late answer cannot reach the state half.
		control.PageEmit(page, 'opx:panel:select',
			{ handle = handle + 99, item = 'Items.Jacket_01' })
		check('a payload naming another room is dropped', #seen == 2,
			table.concat(seen, ', '))
		appearance.FromView = real

		env.TriggerEvent(appearance.Event.ON_VIEW,
			{ kind = 'roomClosed', reason = 'saved', kept = true })
		check('the state half taking the room down takes the panel down',
			drew(page, 'opx:panel:close') ~= nil)

		-- THE OTHER VIEW. Same seam, a different module, because a tree of rows
		-- carrying values and descriptions is a menu and a searchable grid is not.
		local tree = { kind = 'panel', title = 'Appearance',
			items = { { id = 'looks', label = 'Looks', value = 'none',
				items = { { id = 'wear', label = 'Wear it' } } } } }
		env.TriggerEvent(appearance.Event.ON_VIEW, tree)
		local menu = drew(page, 'opx:menu:open')
		check('the appearance panel is drawn by the menu module',
			menu ~= nil and menu.payload.title == 'Appearance',
			menu and tostring(menu.payload.title))

		-- A REFRESH IS A PATCH. The panel is republished after every decision about
		-- a face, and reopening it would throw a player standing two levels in back
		-- out to the root each time.
		env.TriggerEvent(appearance.Event.ON_VIEW, tree)
		check('and a refresh of it is a patch, not a second open',
			times(page, 'opx:menu:open') == 1,
			('%d open(s)'):format(times(page, 'opx:menu:open')))
	end

	-- A WORLD WITH NEITHER VIEW IN IT. The state machines still run and still
	-- publish; nothing draws. The answer has to come a TICK LATER and not inline,
	-- because the state half publishes `room` from inside the function that goes on
	-- to take the camera and start the catalogue stream -- closing it there would
	-- tear the room down underneath a function still setting it up.
	do
		local env, control = joinClient('never', 400, true)
		local OPX = env.OPX
		local appearance = OPX.Modules.Get('appearance')

		check('a world with the two view modules switched off still runs',
			OPX.Modules.IsRunning('appearance') and not OPX.Modules.IsRunning('panel'),
			OPX.Modules.Record('appearance').Reason)

		local seen = {}
		local real = appearance.FromView
		appearance.FromView = function(action, payload)
			seen[#seen + 1] = action
			return real(action, payload)
		end
		env.TriggerEvent(appearance.Event.ON_VIEW, { kind = 'room', title = 'Wardrobe' })
		check('a room nobody can draw is not answered inside its own publication',
			#seen == 0, table.concat(seen, ', '))
		control.Pump(4)
		check('and is answered on the next pass instead', seen[1] == 'room.close',
			table.concat(seen, ', '))
		appearance.FromView = real
	end

	-- ── the clothes that never go on, and never say so ───────────────────────
	-- THE DEFECT THIS CATCHES IS AN ABSENCE, which is why it was survivable for so
	-- long. Step 1 of the clothing half is a gate -- the face settled, gameplay
	-- announced, no native modal, a puppet a face could go on -- and everything
	-- after it is reached only through a put-on. A gate that never opens therefore
	-- produces no attempt, no read-back, no `diagnose`, no refusal and no decision
	-- on the bus: the module does nothing, and nothing anywhere records that it did
	-- nothing. The fitting room under 'always' waits on `clothingRestored`, so it
	-- waited on a decision that could not be reached; `Report` said 'waiting' to
	-- nobody; and the only lines that existed at all went to `Open77.log`, which on
	-- a client is a file on the PLAYER's machine.
	--
	-- This host has no playable puppet and never announces gameplay, so its gate is
	-- shut exactly the way a stuck client's is. Before the bound, the assertions
	-- below could not be written: there was nothing to assert on.
	do
		local env, control = joinClient('always', 400)
		local appearance = env.OPX.Modules.Get('appearance')

		-- `false` is 'no record stored yet', which is the ordinary case for a new
		-- character and the one that DRESSES: nil is 'the server could not say',
		-- and that one stands down on purpose.
		control.Fire(env.OPX.Event(env.OPX.Channel.LOCAL, 'character', 'loaded'),
			{ citizenId = 'citizen-stuck', charInfo = { gender = 'female' }, clothing = false })

		local decisions = {}
		env.AddEventHandler(appearance.Event.ON_DECISION, function(payload)
			if type(payload) == 'table' and payload.event == 'clothingRestored' then
				decisions[#decisions + 1] = tostring(payload.ok) .. '/' .. tostring(payload.error)
			end
		end)

		check('a character carrying a stored record waits to be dressed',
			appearance.Clothing.Report() == 'waiting', appearance.Clothing.Report())
		-- The clause itself, named. A boolean here is what made every one of these
		-- look identical from outside, and identical to each other.
		check('and the gate that holds it up can be named',
			appearance.Clothing.Shut() ~= nil, tostring(appearance.Clothing.Shut()))

		--- Every diagnostic this client has sent the server, as one string.
		local function toldServer()
			local said = {}
			for index = 1, #control.serverEvents do
				local sent = control.serverEvents[index]
				if sent.name == appearance.Event.DIAGNOSTIC then said[#said + 1] = tostring(sent[1]) end
			end
			return table.concat(said, ' | ')
		end

		-- Past GATE_REPORT_MS and well short of the give-up.
		control.Pump(180)
		check('a gate shut too long is reported to the SERVER, where it can be read',
			toldServer():find('is waiting', 1, true) ~= nil, toldServer())
		check('and the line names the clause rather than saying it is waiting',
			toldServer():find('not_announced', 1, true) ~= nil, toldServer())
		check('the world entry has not given up yet', #decisions == 0,
			table.concat(decisions, ', '))

		-- Past GATE_GIVEUP_MS. The decision has to go out even though the clothes
		-- never went on: the join is BEHIND it.
		control.Pump(300)
		check('a gate that never opens settles the world entry rather than waiting on',
			appearance.Clothing.Report() == 'failed', appearance.Clothing.Report())
		check('and publishes the decision the fitting room is waiting for',
			decisions[1] == 'false/clothing_gate_shut', table.concat(decisions, ', '))
		check('naming it in the journal as well', toldServer():find('was never put on', 1, true) ~= nil,
			toldServer())
	end

	-- ── a catalogue batch the view would not take ────────────────────────────
	-- THE OTHER HALF OF THE SAME SHAPE. `Panel.Append` refuses a batch it cannot
	-- parse and answers so; the bridge logged that answer to the client's log and
	-- told the state half nothing, so a hundred pieces vanished with the room still
	-- saying it was reading and the player with no way to know. The state half
	-- cannot see the loss itself and must not try -- `panel` parses an item by
	-- rules that are its own -- so the answer has to come back over the seam.
	do
		local env, control = joinClient('never', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		local page = control.pages[1]

		env.TriggerEvent(appearance.Event.ON_VIEW, {
			kind = 'room', title = 'Wardrobe', loading = true,
			tabs = { { id = 'InnerChest', label = 'Inner chest', marked = false } },
			tab = 'InnerChest', selected = { InnerChest = false },
			summary = { label = 'Inner chest', value = 'nothing' },
			labels = { loading = 'Reading...' },
		})
		check('a room is up to stream into', drew(page, 'opx:panel:open') ~= nil)

		local answered = {}
		local real = appearance.FromView
		appearance.FromView = function(action, payload)
			if action == 'room.items' then answered[#answered + 1] = payload end
			return real(action, payload)
		end

		-- One unparseable item in a batch of two, which is how this really happens:
		-- `parseItems` refuses the WHOLE batch for any malformed one, so a single
		-- over-long label costs a hundred pieces.
		local mark = #page.sent
		env.TriggerEvent(appearance.Event.ON_VIEW, { kind = 'roomItems', final = false, items = {
			{ id = 'Items.Jacket_01', tab = 'InnerChest', label = 'Jacket 01',
				detail = 'Items.Jacket_01' },
			{ id = 'Items.' .. ('Jacket_02_'):rep(30), tab = 'InnerChest', label = 'Jacket 02',
				detail = 'Items.Jacket_02' },
		} })
		local reached = 0
		for index = mark + 1, #page.sent do
			if page.sent[index].channel == 'opx:panel:items' then reached = reached + 1 end
		end
		check('a batch the panel cannot parse reaches the page as nothing at all',
			reached == 0, ('%d send(s)'):format(reached))

		-- The answer is deferred to the upkeep pass for the same reason the
		-- undrawn-room answer is: this runs inside the state half's own
		-- publication, on the stream's thread.
		control.Pump(4)
		check('and the state half is told, instead of the refusal being swallowed',
			#answered == 1 and answered[1].error ~= nil,
			('%d answer(s), error=%s'):format(#answered,
				answered[1] and tostring(answered[1].error) or '-'))
		check('with nothing counted as drawn for a batch that was not',
			#answered == 1 and answered[1].added == 0,
			answered[1] and tostring(answered[1].added) or '-')

		-- SUMMED ACROSS THE PASS, NOT LAST-ONE-WINS. A catalogue is twenty-odd
		-- batches and the stream yields between them, so a whole room's worth
		-- lands between two upkeep passes; the bridge's other deferral holds ONE
		-- answer, and reusing it here would have reported the size of whichever
		-- batch happened to be last as the size of the catalogue.
		for index = 1, 3 do
			env.TriggerEvent(appearance.Event.ON_VIEW, { kind = 'roomItems', final = false,
				items = { { id = ('Items.Boot_%d'):format(index), tab = 'Feet',
					label = 'Boot ' .. index, detail = 'Items.Boot' } } })
		end
		control.Pump(4)
		check('and three batches in one pass are counted as three, not as one',
			#answered == 2 and answered[2].added == 3,
			answered[2] and tostring(answered[2].added) or '-')
		appearance.FromView = real
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
		-- The external library, loaded for real off the sibling checkout rather
		-- than stubbed: a stub would pass while the two repositories drifted, and
		-- the drift is the only thing worth testing here.
		check('opx_lib loaded, and it is the real one',
			type(env.OPX.Lib) == 'table' and type(env.OPX.Lib.VERSION) == 'string')
		check('the two helpers that moved out are reachable',
			type(env.OPX.Lib.Input) == 'table' and type(env.OPX.Lib.Rpc) == 'table')
		-- What the migration was for: the old names are gone, not aliased.
		check('and the names they replaced are gone',
			env.OPX.Keys == nil and env.OPX.Rpc == nil)
		-- The manifest has to carry every permission the library's wrappers need,
		-- because a permission is checked against THIS resource's manifest.
		local declared = {}
		for line in io.lines('open77.lua') do
			local name = line:match('^%s*"([%w%._]+)",%s*$')
			if name then declared[name] = true end
		end
		-- Only the modules this resource CALLS, found by reading the client
		-- sources. Declaring the library's whole permission set instead would
		-- hand this resource `world.markers` and `ui.vanilla.map` for code it
		-- does not run, and a manifest that asks for more than it uses is the
		-- habit this project does not have.
		--
		-- The useful direction is the other one: start calling `OPX.Lib.Blip`
		-- and this check names the line to add, here, instead of the blip
		-- silently never appearing on somebody's machine.
		local used = {}
		for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
			local handle = io.open(file, 'r')
			if handle then
				local text = handle:read('a')
				handle:close()
				for module in text:gmatch('OPX%.Lib%.(%u%w*)') do used[module] = true end
			end
		end

		local undeclared = {}
		for module in pairs(used) do
			local permission = env.OPX.Lib.NEEDS[module]
			if permission ~= nil and not declared[permission] then
				undeclared[#undeclared + 1] = ('%s needs %s'):format(module, permission)
			end
		end
		table.sort(undeclared)
		check('every permission the library modules in use need is declared',
			#undeclared == 0, table.concat(undeclared, ', '))
		check('and the resource really does call the library',
			next(used) ~= nil)

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

-- ── the one client loop, on its own ──────────────────────────────────────────
-- Loaded alone, against a clock and a `Wait` this section owns. Booting the real
-- client gives thirty-five jobs and a host whose `Wait` discards its argument,
-- which is exactly what hid both of the bugs below: a list that only ever grew,
-- and a loop that slept a flat hundred milliseconds while a 33ms job was due.
section('the client scheduler')
do
	local clock = 0
	local waits = {}
	local thread

	local env = {
		OPX = { Scheduler = {}, Now = function() return clock end },
		Open77 = { log = { error = function() end, warn = function() end, info = function() end } },
		CreateThread = function(fn) thread = coroutine.create(fn) end,
		Wait = function(ms) waits[#waits + 1] = ms; coroutine.yield() end,
		math = math, type = type, tonumber = tonumber, tostring = tostring,
		pcall = pcall, ipairs = ipairs, string = string, table = table,
	}

	local chunk, why = loadfile('core/client/scheduler.lua', 't', env)
	if chunk == nil then
		check('the scheduler loads', false, why)
	else
		chunk()
		local Scheduler = env.OPX.Scheduler

		local runs = { a = 0, b = 0, c = 0 }
		local a = Scheduler.Every('a', 100, function() runs.a = runs.a + 1 end)
		local b = Scheduler.Every('b', 100, function() runs.b = runs.b + 1 end)
		local c = Scheduler.Every('c', 100, function() runs.c = runs.c + 1 end)

		Scheduler.Start()
		local function pass()
			coroutine.resume(thread)
		end

		clock = 1000
		pass()
		check('every registered job runs', runs.a == 1 and runs.b == 1 and runs.c == 1)

		Scheduler.Cancel(b)
		clock = 2000
		pass()
		check('a cancelled job stops running', runs.b == 1)
		check('and is dropped from the list rather than kept as a hole',
			#Scheduler.Report() == 2, tostring(#Scheduler.Report()))

		-- The handle was an index into that list until this pass. Dropping `b`
		-- moved `c` down one, so an index-shaped handle would now cancel `a`.
		Scheduler.Cancel(c)
		clock = 3000
		pass()
		check('a handle still names its own job after the list moved',
			runs.a == 3 and runs.c == 2, ('a=%d c=%d'):format(runs.a, runs.c))

		-- Nothing is due for 100ms, so the loop may sleep the floor.
		check('the loop sleeps the idle floor when nothing is near',
			waits[#waits] == 100, tostring(waits[#waits]))

		Scheduler.Every('fast', 33, function() end)
		clock = 3100
		pass()
		check('and no longer than the nearest deadline when something is',
			waits[#waits] <= 33, tostring(waits[#waits]))

		local raises = 0
		Scheduler.Every('broken', 0, function()
			raises = raises + 1
			error('no')
		end)
		for step = 1, 6 do
			clock = 4000 + step * 100
			pass()
		end
		check('a job that keeps raising is suspended, not left to raise every pass',
			raises == 3, tostring(raises))

		Scheduler.Stop()
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
-- WHAT A FRAME ANSWERS, AND WHY IT HAS TO SAY SO.
--
-- The page reports a CANDIDATE keystroke and goes on drawing it, because it has
-- to: erasing the character and waiting out the round trip is a line that blinks
-- back to its placeholder under every letter, and under the FIRST letter that
-- placeholder is the whole field -- which is the bug this section exists for.
-- The page's binding re-applies Lua's buffer to the element on every frame, so
-- any frame landing inside the round trip writes the buffer from BEFORE the
-- character and takes it off the line.
--
-- So the page has to tell the frame that ANSWERS the character under the caret
-- from a frame built before that character was reported, and a bare frame says
-- nothing about which it is. This is the Lua half of the answer: every edit
-- naming a real field is answered with exactly one frame, the frame carries the
-- sequence of the keystroke it ruled on, and a frame drawn for any other reason
-- carries the older one.
section('the form answers the keystroke it was asked about')
do
	local env, control, why = boot('client')
	check('client boots for the form tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local form = OPX.Api.Get('form')

		-- Two fields, because the name form has two and the second is where a
		-- keystroke can race the caret.
		local opened = form.Open{
			owner = 'entry',
			id = 'entry.name',
			title = 'WHO ARE YOU',
			fields = {
				{ id = 'firstName', label = 'First name', maxLength = 8, required = true },
				{ id = 'lastName', label = 'Last name', maxLength = 8, required = true },
			},
			on = function() end,
		}
		check('a two-field name form opens', opened.ok, opened.error)

		-- The channels are wired on the first open, so the page is only findable
		-- by them afterwards.
		local page
		for _, candidate in ipairs(control.pages) do
			if candidate.handlers['opx:form:edit'] then page = candidate end
		end
		check('and wires the page channels it reads keystrokes on', page ~= nil)

		if opened.ok and page ~= nil then
			local handle = opened.value.handle

			--- The newest thing the page was drawn, open or frame.
			local function latest()
				for index = #page.sent, 1, -1 do
					local sent = page.sent[index]
					if sent.channel == 'opx:form:frame' or sent.channel == 'opx:form:open' then
						return sent
					end
				end
				return nil
			end

			--- One field's row of it.
			local function row(id)
				local sent = latest()
				for _, one in ipairs(sent and sent.payload.rows or {}) do
					if one.id == id then return one end
				end
				return {}
			end

			--- Plays one keystroke and answers how many frames it drew.
			local function typed(id, seq, text)
				local before = #page.sent
				control.PageEmit(page, 'opx:form:edit',
					{ handle = handle, id = id, seq = seq, text = text })
				return #page.sent - before
			end

			check('the open carries no acknowledgement, nothing having been typed',
				row('firstName').ack == nil, tostring(row('firstName').ack))

			-- ONE. The character comes back stamped with its own keystroke. Without
			-- the stamp this frame is indistinguishable from the one carrying the
			-- empty buffer the field had a moment ago, and putting THAT one back is
			-- the empty line under the first letter.
			local frames = typed('firstName', 1, 'J')
			check('a keystroke is answered with exactly one frame', frames == 1, frames)
			check('carrying the buffer Lua kept', row('firstName').text == 'J',
				tostring(row('firstName').text))
			check('and the sequence of the keystroke it answers',
				row('firstName').ack == 1, tostring(row('firstName').ack))

			-- TWO. A refusal is an answer as much as an acceptance is: the page is
			-- holding a character that only this frame takes back off the line.
			frames = typed('firstName', 2, 'Jonathanx')
			check('a refused keystroke is answered too', frames == 1, frames)
			check('with the accepted buffer untouched', row('firstName').text == 'J',
				tostring(row('firstName').text))
			check('and acknowledged, so the line goes back rather than keeping it',
				row('firstName').ack == 2, tostring(row('firstName').ack))
			check('and the refusal is said out loud',
				type(latest().payload.status) == 'string')

			-- THREE. THE SECOND NAME. A keystroke that raced a focus change used to
			-- be discarded with no frame at all, which left a character sitting in a
			-- field Lua never accepted and no answer that would ever take it out.
			frames = typed('lastName', 3, 'S')
			check('a keystroke on the field Lua does not hold is answered as well',
				frames == 1, frames)
			check('that field keeping the buffer it had', row('lastName').text == '',
				tostring(row('lastName').text))
			check('and acknowledged, so the page puts its line back',
				row('lastName').ack == 3, tostring(row('lastName').ack))
			check('while the focused field keeps its own acknowledgement',
				row('firstName').ack == 2, tostring(row('firstName').ack))

			-- FOUR. A frame drawn for something OTHER than a keystroke -- here the
			-- caret moving between the two names -- must not claim to answer one.
			-- This is the frame that lands inside the round trip, and it is the one
			-- the page has to be able to ignore.
			local before = #page.sent
			control.PageEmit(page, 'opx:form:key', { handle = handle, key = 'down' })
			check('moving between the names draws a frame', #page.sent > before)
			check('and it answers no keystroke it was not asked about',
				row('firstName').ack == 2 and row('lastName').ack == 3,
				('%s %s'):format(tostring(row('firstName').ack), tostring(row('lastName').ack)))

			-- FIVE. Two edits crossing on the wire. The older one arriving second
			-- must not un-answer the newer one, or the page waits for an
			-- acknowledgement that has already been and gone and holds its candidate
			-- for the rest of the form.
			typed('lastName', 9, 'Si')
			typed('lastName', 4, 'S')
			check('an acknowledgement never goes backwards',
				row('lastName').ack == 9, tostring(row('lastName').ack))

			-- SIX. A payload naming no field of this form is not a race; it is a
			-- page talking about something else, and answering would tell it that it
			-- was heard.
			before = #page.sent
			control.PageEmit(page, 'opx:form:edit',
				{ handle = handle, id = 'nobody', seq = 20, text = 'x' })
			check('a field this form does not have is not answered at all',
				#page.sent == before, #page.sent - before)
		end
	end
end

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

		-- The theme's pair, and it is the same class of break: a page that never
		-- says ready is never sent a theme, and a theme sent on a name the page
		-- does not listen to is applied by nobody. Both fail as "the accent did
		-- nothing", which is indistinguishable from an accent nobody configured.
		check('the page asks for its theme on the channel the surface wires',
			speaks['opx:theme:ready'] == true)
		check('and takes the theme on the channel Lua sends it on',
			speaks['opx:theme:set'] == true)

		-- Drift detector. A channel the page speaks that no Lua file mentions is
		-- either a feature whose Lua half is not written yet, or a name one side
		-- has renamed and the other has not -- which is silent in both
		-- directions. Listing them is the point; the check only fails on the
		-- handshake above.
		--
		-- A CHANNEL NAME RARELY APPEARS WHOLE IN LUA. The house idiom is a
		-- per-module `send(name, payload)` that builds `'<id>:' .. name`, so the
		-- file holds the verb alone and the prefix is the directory it sits in.
		-- Harvesting per module, off the manifest's own load order, is what
		-- resolves the pair -- without it every module using the idiom is
		-- reported as drift and the one real break is lost in the noise.
		local lua = {}
		for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
			local source = io.open(file, 'r')
			if source then
				local text = source:read('a')
				source:close()

				local module = file:match('^modules/([%a_]+)/')
				for literal in text:gmatch("'([%a][%w:_]*)'") do
					lua[literal] = true
					if module then lua[module .. ':' .. literal] = true end
				end
				for name in text:gmatch('opx:[%a][%w:_]*') do lua[name] = true end
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

		-- ── the three screens that own the display instead ───────────────────
		-- A HUD drawn over the character creator, the spawn menu or the fitting
		-- room is a gauge column standing in front of the one thing the player is
		-- being asked to look at. The mechanism is the one that already exists --
		-- a flag beside the player's own choice, the way `down` is -- and the
		-- three owners are counted rather than collapsed into one boolean,
		-- because they overlap at join and a boolean is whichever finished last.
		local hudApi = env.OPX.Api.Get('hud')

		--- Whether the last `hud:show` the page was sent said to draw.
		local function showing()
			local last
			for _, message in ipairs(page.sent) do
				if message.channel == 'opx:hud:show' then last = message.payload end
			end
			return last ~= nil and last.visible == true
		end

		check('the hud is on screen with nothing else up', showing())

		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'entry', 'state'),
			{ open = true, phase = 'creator' })
		check('the character creator takes the hud off screen', not showing())

		-- OVERLAPPING, WHICH IS WHY THIS IS A SET. The join hands the screen from
		-- the creator to the spawn menu without a gap, and a single flag written
		-- by both would come back on the moment the first one finished.
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'spawn', 'state'),
			{ open = true, phase = 'spawn' })
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'entry', 'state'),
			{ open = false, phase = 'idle' })
		check('and it stays off while the spawn menu still has it', not showing())

		-- A room the player opened themselves, which the join knows nothing about.
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'appearance', 'decision'),
			{ ok = true, event = 'wardrobeOpened' })
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'spawn', 'state'),
			{ open = false, phase = 'idle' })
		check('the fitting room holds it on its own', not showing())

		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'appearance', 'decision'),
			{ ok = true, event = 'wardrobeClosed', reason = 'saved' })
		check('and the last one to close gives it back', showing())

		-- The player's own choice is never touched by any of this: it is recorded
		-- underneath, exactly as it is while they are down.
		hudApi.SetVisible(false)
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'spawn', 'state'),
			{ open = true, phase = 'spawn' })
		env.TriggerEvent(env.OPX.Event(env.OPX.Channel.LOCAL, 'spawn', 'state'),
			{ open = false, phase = 'idle' })
		check('a screen closing does not switch a hud back on that the player switched off',
			not showing())
		local state = hudApi.IsVisible()
		check('and the contract says which of the two is holding it',
			state.ok and state.value.visible == false and state.value.covered == false,
			state.ok and tostring(state.value.covered) or tostring(state.error))
	end
end

-- ── the theme ────────────────────────────────────────────────────────────────
-- An operator's colour is the one piece of configuration in this resource that
-- reaches a stylesheet, and the three ways that goes wrong are all silent: a
-- refused value leaves the shipped red, which is what an unconfigured server
-- looks like; a value out of range leaves a surface nobody can read, on someone
-- else's machine; and a derivation that has drifted from the shipped ladder
-- gives every server a slightly broken version of the house design.
--
-- The first and the last are what this section is mostly about. The default case
-- is checked against the REAL `config/theme.lua` rather than against a table
-- written here, so an owner who uncomments a line in that file to try something
-- and forgets to comment it back fails the suite rather than shipping it.
section('theme')
do
	local env, control, why = boot('server')
	if why ~= nil then
		check('the server half loads', false, why)
	else
		local OPX = env.OPX
		local theme = OPX.Modules.Get('theme')
		local Palette = theme.Palette

		check('the theme module started', OPX.Modules.IsRunning('theme'),
			OPX.Modules.Record('theme') and OPX.Modules.Record('theme').Reason)

		-- ── the hex, which is the only text an operator supplies ────────────
		-- It never becomes CSS -- the page is sent three integers -- but it is
		-- still the value most likely to be typed wrong, and every shape below
		-- that is not exactly six hex digits has to be named rather than read as
		-- something near it.
		local accepted = {
			{ '#ff3b47', { 255, 59, 71 } },
			{ '#FF3B47', { 255, 59, 71 } },
			{ '#000000', { 0, 0, 0 } },
			{ '#ffffff', { 255, 255, 255 } },
		}
		local goodHex = true
		for _, case in ipairs(accepted) do
			local rgb = Palette.Rgb(case[1])
			if rgb == nil or rgb[1] ~= case[2][1] or rgb[2] ~= case[2][2]
				or rgb[3] ~= case[2][3] then
				goodHex = false
			end
		end
		check('#RRGGBB is read, in either case', goodHex)

		local refused = {
			'#fff', '#ff3b4', '#ff3b477', 'ff3b47', '#ff3b4g', 'red',
			'rgb(255,59,71)', '#ff3b47 ', ' #ff3b47', '#ff3b47;',
			-- The shape this would have to have to be an injection, if the wire
			-- carried text at all. It does not, and it is refused here as well.
			'#f00;}html{display:none',
			'', 123, true, {}, nil,
		}
		local leaked = {}
		for _, value in ipairs(refused) do
			if Palette.Rgb(value) ~= nil then leaked[#leaked + 1] = tostring(value) end
		end
		-- `nil` is not reachable through ipairs; checked on its own so the list
		-- above can say what it means.
		if Palette.Rgb(nil) ~= nil then leaked[#leaked + 1] = 'nil' end
		check('everything that is not #RRGGBB is refused', #leaked == 0,
			table.concat(leaked, ' '))

		-- ── the shipped config paints the shipped surface ────────────────────
		-- `config/theme.lua` carries LIVE values rather than commented-out ones,
		-- so the file reads as what it does instead of as an essay about what it
		-- would do. That trade has a price, and this is where it is paid: the
		-- page is now handed a full ladder on every boot, so the ladder it is
		-- handed has to be the one `tokens.css` draws. The check below is the
		-- only thing standing between an edit to `palette.lua` and every server
		-- quietly running a design nobody drew.
		local shipped, shippedNotes = Palette.Resolve(OPX.Config.MODULES.theme)
		check('the shipped config resolves to a full theme, not an empty one',
			not Palette.IsEmpty(shipped), '0 keys')
		check('and to no complaints', #shippedNotes == 0, table.concat(shippedNotes, ' | '))
		-- An absent block still means "change nothing", which is what an operator
		-- who deletes the file gets, and what every other resource gets.
		check('an absent block is still no theme at all', Palette.IsEmpty(Palette.Resolve(nil)))

		-- ── the ladder is the shipped one, restated ──────────────────────────
		-- The factors in `palette.lua` were measured off these seven literals.
		-- If the derivation ever stops reproducing them, every themed server is
		-- running a design nobody drew -- and the surface would still look
		-- plausible, which is why this is a test and not an eyeball.
		local LADDER = {
			accent   = { 255, 59, 71 },   -- #ff3b47
			hi       = { 255, 107, 120 }, -- #ff6b78
			deep     = { 200, 32, 46 },   -- #c8202e
			text     = { 232, 100, 109 }, -- #e8646d
			idle     = { 232, 67, 79 },   -- --op-red-idle's rgb
			alarm    = { 255, 168, 174 }, -- #ffa8ae
			plate    = { 28, 8, 9 },      -- --op-plate's rgb
			plateLit = { 74, 21, 25 },    -- --op-plate-lit's rgb
		}
		local derived = Palette.Ladder({ 255, 59, 71 })
		local worst, worstKey = 0, nil
		for key, want in pairs(LADDER) do
			local got = derived[key]
			for index = 1, 3 do
				local off = math.abs((got and got[index] or -999) - want[index])
				if off > worst then worst, worstKey = off, key end
			end
		end
		-- Four, and the whole of it is on blue: the hand-picked rungs sit within
		-- 1.6 degrees of the accent's hue and the derivation uses one hue for all
		-- of them. Tightening this means changing the shipped literals.
		check('the derived ladder reproduces the shipped one to within 4/255',
			worst <= 4, ('%d off on %s'):format(worst, tostring(worstKey)))
		check('and the accent rung is the operator\'s own hex, exactly',
			derived.accent[1] == 255 and derived.accent[2] == 59 and derived.accent[3] == 71)

		-- A hue nowhere near red, to prove the derivation is not red-shaped.
		local blue = Palette.Ladder({ 0, 128, 255 })
		check('a blue accent produces a blue ladder and a blue-black ground',
			blue.hi[3] > blue.hi[1] and blue.plate[3] > blue.plate[1]
				and blue.plate[3] < 40,
			('hi %d,%d,%d plate %d,%d,%d'):format(blue.hi[1], blue.hi[2], blue.hi[3],
				blue.plate[1], blue.plate[2], blue.plate[3]))

		-- ── the scalars, and their bounds ────────────────────────────────────
		local wide = Palette.Resolve({
			ACCENT = '#00ff00',
			PLATE_OPACITY = 5,
			INTERLACE = 40,
			TILT = 90,
			CUT = 100,
		})
		check('a plate opacity above the ceiling is held there', wide.plateAlpha == 0.98,
			tostring(wide.plateAlpha))
		check('an interlace nobody could read through is held at 0.15',
			wide.interlaceAlpha == 0.15, tostring(wide.interlaceAlpha))
		check('a tilt of 90 degrees is held at 15', wide.tiltDeg == 15, tostring(wide.tiltDeg))
		check('the three cuts are held at their own ceilings',
			wide.cutSm == 24 and wide.cutMd == 48 and wide.cutLg == 80,
			('%s %s %s'):format(tostring(wide.cutSm), tostring(wide.cutMd),
				tostring(wide.cutLg)))

		local narrow = Palette.Resolve({ PLATE_OPACITY = -3, TILT = -20, CUT = 0 })
		check('and at their floors from the other side',
			narrow.plateAlpha == 0.20 and narrow.tiltDeg == 0
				and narrow.cutSm == 1 and narrow.cutLg == 1,
			('%s %s %s %s'):format(tostring(narrow.plateAlpha), tostring(narrow.tiltDeg),
				tostring(narrow.cutSm), tostring(narrow.cutLg)))

		local shipLike = Palette.Resolve({ PLATE_OPACITY = 0.78, INTERLACE = 1, CUT = 1 })
		check('the shipped numbers written out by hand come back unchanged',
			shipLike.plateAlpha == 0.78 and shipLike.plateQuietAlpha == 0.58
				and shipLike.plateLitAlpha == 0.9 and shipLike.interlaceAlpha == 0.05
				and shipLike.cutSm == 6 and shipLike.cutMd == 12 and shipLike.cutLg == 20,
			('%s %s %s %s'):format(tostring(shipLike.plateAlpha),
				tostring(shipLike.plateQuietAlpha), tostring(shipLike.plateLitAlpha),
				tostring(shipLike.interlaceAlpha)))

		-- A word where a number belongs is a MISTAKE, not a magnitude, so it is
		-- dropped and named rather than clamped to a floor the operator never
		-- asked for.
		local wrong, wrongNotes = Palette.Resolve({
			ACCENT = 'crimson', ALARM = '#12', TILT = 'a lot', CUT = {},
		})
		check('a value of the wrong kind is dropped, not repaired',
			Palette.IsEmpty(wrong), OPX.Table.Count(wrong) .. ' key(s)')
		check('and every one of them is named for the journal', #wrongNotes == 4,
			table.concat(wrongNotes, ' | '))

		-- ── what arrives from the wire ───────────────────────────────────────
		-- The same bounds, run over a payload this build did not produce: an
		-- older or newer server, or a key that has since been removed.
		local fromWire = Palette.Sanitise({
			accent = { 300, -5, 71.4 },
			deep = { 1, 2 },
			tiltDeg = 99,
			cutSm = 'six',
			somethingElse = 1,
		})
		check('a channel out of range is clamped to a byte',
			fromWire.accent[1] == 255 and fromWire.accent[2] == 0 and fromWire.accent[3] == 71,
			table.concat(fromWire.accent, ','))
		check('a triple that is not three numbers is dropped', fromWire.deep == nil)
		check('a number out of range is clamped', fromWire.tiltDeg == 15,
			tostring(fromWire.tiltDeg))
		check('a number that is not one is dropped', fromWire.cutSm == nil)
		check('a key this build does not know is dropped', fromWire.somethingElse == nil)

		-- ── the wire itself ──────────────────────────────────────────────────
		local before = #control.clientEvents
		env.source = 7
		control.netEvents[theme.Event.REQUEST]()
		env.source = nil
		local sent = control.clientEvents[#control.clientEvents]
		check('a player who asks is answered, and only that player',
			#control.clientEvents == before + 1 and sent ~= nil
				and sent.name == theme.Event.SET and sent.source == 7,
			sent and tostring(sent.name) or 'nothing sent')
		check('with the resolved theme, which on a stock server is the full ladder',
			sent ~= nil and type(sent[1]) == 'table' and not Palette.IsEmpty(sent[1]))

		-- A second ask inside the window is dropped. Not a security boundary --
		-- the answer is a few hundred bytes -- but anyone can raise the name.
		local held = #control.clientEvents
		env.source = 7
		control.netEvents[theme.Event.REQUEST]()
		env.source = nil
		check('a second ask inside the cooldown is not answered',
			#control.clientEvents == held)

		-- The console has no page and no cooldown bucket; it must not be answered
		-- as if it were player 0.
		local console = #control.clientEvents
		control.netEvents[theme.Event.REQUEST]()
		check('a request with no player behind it is ignored',
			#control.clientEvents == console)

		-- The contract hands out a copy: a caller that edits what it is given
		-- must not be editing what the next player is sent.
		local published = OPX.Api.Get('theme')
		local copy = published and published.Current()
		if copy then copy.accent = { 1, 2, 3 } end
		env.source = 8
		control.netEvents[theme.Event.REQUEST]()
		env.source = nil
		local after = control.clientEvents[#control.clientEvents]
		-- Directly now, rather than through emptiness: the caller wrote 1,2,3
		-- into the table it was handed, and the next player must still be sent
		-- the real accent.
		check('the published theme is a copy, not the live one',
			after ~= nil and type(after[1].accent) == 'table'
				and after[1].accent[1] == 255 and after[1].accent[2] == 59
				and after[1].accent[3] == 71,
			after and after[1] and table.concat(after[1].accent or {}, ','))
	end
end

section('theme: the client half')
do
	local env, control, why = boot('client')
	if why ~= nil then
		check('the client half loads', false, why)
	else
		local theme = env.OPX.Modules.Get('theme')
		local page = control.pages[#control.pages]

		-- `boot` has already reported the page READY, which is the surface-level
		-- handshake. The theme's own `theme:ready` is a separate signal from the
		-- page's boot, and until it arrives there is no root to write onto.
		local wire = { accent = { 0, 128, 255 }, tiltDeg = 3, nonsense = 'x' }
		control.netEvents[theme.Event.SET](wire)

		local function themeSent()
			for _, message in ipairs(page and page.sent or {}) do
				if message.channel == 'opx:theme:set' then return message.payload end
			end
			return nil
		end

		check('a theme that arrives before the page does is held, not dropped',
			themeSent() == nil)

		control.PageEmit(page, 'opx:theme:ready', {})

		local drawn = themeSent()
		check('and is sent the moment the page asks for it', drawn ~= nil)
		check('with the key this build does not know already gone',
			drawn ~= nil and drawn.nonsense == nil and drawn.tiltDeg == 3
				and type(drawn.accent) == 'table' and drawn.accent[3] == 255,
			drawn and tostring(drawn.tiltDeg) or 'nothing')

		-- There is no client-side setter, and that is the whole of the
		-- server-authoritative claim on this side: the only name that reaches the
		-- page is the one the server raises, and the only thing the client sends
		-- is a request with no arguments in it.
		check('the client asks on a name that carries nothing',
			theme.Event.REQUEST == 'opx:net:theme:request')
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

-- ── the staff menu's row vocabulary ─────────────────────────────────────────
-- READ OUT OF THE SOURCE, because the thing that broke is a collision between
-- two fields in one table and neither side is reachable from here: `guarded`
-- and `onRow` are both file-local to a client module.
--
-- The delete row shipped carrying `back = true`, meaning "after the confirmed
-- action, also leave the page it destroyed". But `back` ALREADY means "pressing
-- me pops the screen" -- that is what Cancel is -- and `onRow` tests it before
-- it looks for a confirmation. So the row popped on press and never confirmed
-- and never ran: pressing Delete did nothing, silently, while looking exactly
-- like a row that had been pressed.
section('the staff menu: a guarded row confirms rather than pops')
do
	local handle = io.open('modules/admin/client/menu.lua', 'r')
	local body = handle and handle:read('a') or ''
	if handle then handle:close() end

	local built = body:match('local function guarded%b()(.-)\nend')
	check('guarded() was found in the source', built ~= nil and built ~= '')

	if built then
		-- The whole bug in one assertion.
		check('a guarded row writes no `back` into its row data',
			built:match('item%.data = .-back%s*=') == nil,
			built:match('item%.data = [^\n]*'))
		check('and it does write the confirmation',
			built:match('item%.data = .-confirm%s*=') ~= nil)
	end

	-- The order that makes the collision fatal rather than merely untidy. If a
	-- later edit moves the confirmation test above the pop, this check should be
	-- revisited rather than deleted: the names would still be two meanings.
	local popAt = body:find('if data%.back then return pop%(%) end', 1)
	local confirmAt = body:find("type%(data%.confirm%) == 'table'", 1)
	check('onRow still tests back before confirm, which is why the names must differ',
		popAt ~= nil and confirmAt ~= nil and popAt < confirmAt)
end

-- ── finding somebody who is not connected ────────────────────────────────────
-- THE READ THAT DOES NOT START FROM A SESSION, and the only one in this runtime.
-- Everything else about a character is reached through the account holding it;
-- an offline player has no account to hold it with, so the find goes to the
-- table. That makes it the one query that could return ten thousand rows, and
-- every check below is about a bound on it: the page ceiling, the probe row that
-- says whether there is a next page without a COUNT, the seek that replaces
-- OFFSET, and the floor under a search term.
--
-- NONE OF THIS IS MEASURED. There is no database here and there never will be in
-- this harness; what is under test is which statement runs, what is bound into
-- it and what comes back out. Whether the index is used is a claim about MySQL
-- and is argued in `storage.lua`, not proved here.
section('finding somebody who is not connected')
do
	-- Every statement the find runs, in order, with what was bound into it. The
	-- three SELECTs are otherwise indistinguishable from outside: a first page, a
	-- seek and a search all answer a list of rows.
	local asked = {}
	local answered = {}

	--- `count` rows as the SELECT answers them, numbered from `from`.
	local function rowsFrom(count, from)
		local out = {}
		for index = 1, count do
			local seq = (from or 0) + index
			out[index] = {
				citizen_id = ('CIT-%04d'):format(seq),
				user_id = ('user-%04d'):format(seq),
				cid = 1,
				-- Tables rather than encoded strings: `Storage.Decode` takes either,
				-- because one bridge version answers each.
				char_info = { firstName = 'Vee', lastName = ('Number%d'):format(seq) },
				job = { label = 'Unemployed' },
				gang = { name = 'none' },
				last_logged_out = ('2026-01-%02d 10:00:00'):format(((seq - 1) % 28) + 1),
				created_at = '2025-01-01 00:00:00',
				display_name = ('account-%04d'):format(seq),
			}
		end
		return out
	end

	local database = Host.Database({
		scalar = function() return 1 end,
		update = function() return 0 end,
		single = function() return nil end,
		query = function(sql, params)
			asked[#asked + 1] = { sql = sql, params = params or {} }
			return answered
		end,
	})

	local env, control, why = boot('server', database)
	check('server boots with a database for the find tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local character = OPX.Modules.Get('character')
		local admin = OPX.Modules.Get('admin')
		local storage = character.Storage

		--- The statement the find last ran, and what was bound into it.
		local function last()
			return asked[#asked] or { sql = '', params = {} }
		end

		--- Runs one find with the boot's statements forgotten first.
		local function find(request)
			asked = {}
			return character.FindCharacters(request)
		end

		-- THE CONTRACT. Published beside the other three staff doors, and reached
		-- by `admin` through the contract rather than by touching the module.
		local contract = OPX.Api.Get('character')
		check('the find is published for the staff menu to read',
			contract ~= nil and type(contract.FindCharacters) == 'function')
		check('and it is not the account listing wearing a different name',
			contract ~= nil and contract.FindCharacters ~= contract.ListCharactersFor)

		-- THE CEILING, and it is in the SQL rather than in an argument, so no
		-- caller can raise it. The statement asks for one row more than a page:
		-- that row is the probe and it is what answers `more` without a COUNT.
		check('a find page is 25 rows', storage.FIND_PAGE == 25)
		answered = rowsFrom(1)
		find({ mode = 'recent' })
		check('and the statement asks for exactly one row more than a page',
			tonumber(last().sql:match('LIMIT (%d+)')) == storage.FIND_PAGE + 1,
			last().sql:match('LIMIT %d+'))
		check('the page size is nowhere in the bound parameters, so nobody can raise it',
			last().params.limit == nil)

		-- EMPTY. The whole point of a `more` flag that is false rather than absent:
		-- a client reads a row off it, and nil would read as "not answered yet".
		answered = {}
		local none = find({ mode = 'recent' })
		check('an empty table answers an empty page rather than a failure',
			none.ok == true and #none.value.characters == 0)
		check('and says plainly that there is no next page',
			none.value.more == false and none.value.cursor == nil)

		-- THE BOUNDARY, both sides of it. Exactly a page is the last page; a page
		-- plus the probe is not, and the probe is dropped rather than shown.
		answered = rowsFrom(storage.FIND_PAGE)
		local full = find({ mode = 'recent' })
		check('exactly one page of rows is the last page',
			full.ok and #full.value.characters == storage.FIND_PAGE
				and full.value.more == false,
			tostring(full.ok and #full.value.characters))
		check('so it offers no cursor to seek past', full.value.cursor == nil)

		answered = rowsFrom(storage.FIND_PAGE + 1)
		local over = find({ mode = 'recent' })
		check('a page plus the probe row says there is more',
			over.ok and over.value.more == true)
		check('and the probe itself is dropped rather than drawn',
			#over.value.characters == storage.FIND_PAGE,
			tostring(#over.value.characters))
		check('the cursor is the last row SHOWN, not the probe',
			over.value.cursor == ('CIT-%04d'):format(storage.FIND_PAGE),
			tostring(over.value.cursor))
		check('and a recent page carries the other half of its sort key',
			type(over.value.seenAt) == 'string' and over.value.seenAt ~= '',
			tostring(over.value.seenAt))

		-- THE SEEK. There is no OFFSET anywhere: page two is "what comes after the
		-- row you last saw", which is a different statement from page one because
		-- a TIMESTAMP has no value above every row to start from.
		answered = rowsFrom(2)
		find({ mode = 'recent' })
		check('the first recent page compares against nothing',
			last().sql:find('c.citizen_id) <', 1, true) == nil)
		find({ mode = 'recent', seenAt = '2026-01-10 10:00:00', cursor = 'CIT-0007' })
		check('a page past the first is a seek on the whole sort key',
			last().sql:find('(c.last_logged_out, c.citizen_id) < (@seenAt, @cursor)', 1, true) ~= nil)
		check('and neither statement uses OFFSET',
			last().sql:upper():find('OFFSET', 1, true) == nil)
		check('the seek binds both halves it was handed',
			last().params.seenAt == '2026-01-10 10:00:00' and last().params.cursor == 'CIT-0007')

		-- HALF A CURSOR IS NO CURSOR. A seek needs both halves of the sort key, and
		-- reading page one again beats reading a page nobody asked for.
		find({ mode = 'recent', cursor = 'CIT-0007' })
		check('a cursor with no timestamp falls back to the first page',
			last().sql:find('c.citizen_id) <', 1, true) == nil)

		-- THE FLOOR UNDER A SEARCH, which is half the rate limit: a one-letter term
		-- that matches nothing reads the whole table before it can say so.
		check('the floor is three characters', character.FIND_MIN_TERM == 3)
		asked = {}
		for _, short in ipairs({ '', 'a', 'ab', '  b  ' }) do
			local refused = character.FindCharacters({ mode = 'search', term = short })
			check(('a search for %q is refused'):format(short),
				refused.ok == false and refused.error == 'character.searchShort',
				tostring(refused.error))
		end
		check('and not one of them reached the database', #asked == 0,
			('%d statement(s)'):format(#asked))

		answered = rowsFrom(3)
		local hit = find({ mode = 'search', term = 'vee' })
		check('three characters is enough to run', hit.ok == true, tostring(hit.error))
		check('a search is a seek on the primary key, with no OFFSET',
			last().sql:find('c.citizen_id > @cursor', 1, true) ~= nil
				and last().sql:upper():find('OFFSET', 1, true) == nil)
		check("and its first page starts at the empty string, which is below every id",
			last().params.cursor == '')
		check('a search page carries no timestamp half, because it is not sorted by one',
			hit.value.seenAt == nil)

		-- THE WILDCARDS. A term of `%` that reached LIKE unescaped would match every
		-- row in the table, which is the one query the whole screen exists to avoid.
		find({ mode = 'search', term = '100%_x' })
		check('a per-cent sign in a term is a per-cent sign, not every row',
			last().params.like == '%100\\%\\_x%', tostring(last().params.like))
		find({ mode = 'search', term = 'a\\b' })
		check('and the escape character escapes itself',
			last().params.like == '%a\\\\b%', tostring(last().params.like))
		check('the term is also matched against a citizen id exactly',
			last().params.exact == 'a\\b')

		-- A MODE NOBODY OFFERS. There is deliberately no "everybody" -- staff have
		-- no use for page 187 of ten thousand strangers, and that is the query that
		-- falls over.
		asked = {}
		for _, mode in ipairs({ 'all', '', 'RECENT' }) do
			local refused = character.FindCharacters({ mode = mode })
			check(('a find in mode %q is refused'):format(mode), refused.ok == false)
		end
		check('a find that is not a table at all is refused too',
			character.FindCharacters('recent').ok == false)
		check('and none of those reached the database', #asked == 0)

		-- THE INDEX. It is in the CREATE TABLE and therefore reaches a fresh install
		-- and nothing else; the comment above the schema says so, and this holds
		-- both halves of that together so neither can be edited away alone.
		local schema = table.concat(storage.SCHEMA, '\n')
		check('the find order is indexed in the schema',
			schema:find('idx_opx77_characters_seen (deleted_at, last_logged_out, citizen_id)',
				1, true) ~= nil)
		local handle = io.open('modules/character/server/storage.lua', 'r')
		local source = handle:read('a')
		handle:close()
		check('and the schema says plainly that it will not reach a live database',
			source:find('ALTER TABLE opx77_characters', 1, true) ~= nil)

		-- ── the staff half ───────────────────────────────────────────────────
		-- WHAT THE ADMIN MODULE ADDS: who is connected, and who may ask. It adds no
		-- SQL and no character data, which is the standing rule for the whole module.
		check('the find is its own ACL grant',
			admin.Command.CHARACTER_FIND == 'opx.admin.character.find')
		check('in the `character` area, because what it finds outlives a connection',
			admin.Command.CHARACTER_FIND:find('opx.admin.character.', 1, true) == 1)
		check('and separate from the per-account listing, which has a smaller blast radius',
			admin.Command.CHARACTER_FIND ~= admin.Command.CHARACTER_LIST)
		check('it is registered, and restricted like every other staff command',
			control.commands['opx.admin.character.find'] ~= nil
				and control.commands['opx.admin.character.find'].restricted == true)

		answered = rowsFrom(2)
		local rows, code, page = admin.Offline.Page({ mode = 'recent' })
		check('the staff half answers the rows the contract found',
			rows ~= nil and #rows == 2, tostring(code))
		check('with nobody connected, no row claims to be online',
			rows ~= nil and rows[1].live == nil and rows[1].online == nil)
		check('and it passes the page state through for the menu to page on',
			page ~= nil and page.mode == 'recent' and page.more == false)
		check('a row carries the account, which is what a found row is for',
			rows ~= nil and rows[1].account == 'account-0001')
		check('and carries no money, position or metadata, which were never read',
			rows ~= nil and rows[1].money == nil and rows[1].position == nil
				and rows[1].metadata == nil)

		local refusedRows, refusedCode = admin.Offline.Page({ mode = 'search', term = 'a' })
		check('a term under the floor is refused in the staff half too',
			refusedRows == nil and refusedCode == 'search_short', tostring(refusedCode))

		-- EVERY CODE THIS FILE CAN ANSWER HAS A SENTENCE. `Server.Refuse` falls back
		-- to `failed` for a code it does not know, so a new code with no entry in
		-- `ERRORS` does not raise: it silently answers "that could not be done" and
		-- the operator never learns that their search was two letters long.
		local offlineSource = io.open('modules/admin/server/offline.lua', 'r'):read('a')
		local mainSource = io.open('modules/admin/server/main.lua', 'r'):read('a')
		local mapped = mainSource:match('local ERRORS = %b{}') or ''
		local unmapped = {}
		local function mustMap(code)
			if mapped:find('\n\t' .. code .. ' = ', 1, true) == nil then
				unmapped[#unmapped + 1] = code
			end
		end
		for code in offlineSource:gmatch("refuse%(source, raw, '([%w_]+)'%)") do mustMap(code) end
		for code in offlineSource:gmatch("%] = '([%w_]+)',") do mustMap(code) end
		mustMap('failed')
		mustMap('refused')
		table.sort(unmapped)
		check('every refusal the find can answer maps to a sentence rather than to "failed"',
			#unmapped == 0, table.concat(unmapped, ', '))

		-- THE WIRE. A page of 25 rows crosses in chunks under the host's own limit,
		-- and every chunk carries the tag and the page state -- the tag because a
		-- late answer has to be droppable, the state because the client reads it off
		-- whichever chunk completes the list.
		env.Open77.acl.isAllowed = function() return true end
		env.Open77.players.all = function() return {} end
		answered = rowsFrom(storage.FIND_PAGE + 1)
		local before = #control.clientEvents
		env.source = 5
		control.netEvents[admin.Event.REFRESH]('found', { mode = 'recent' })
		control.Pump(10)
		env.source = nil

		local sent = {}
		for index = before + 1, #control.clientEvents do
			local event = control.clientEvents[index]
			if event.name == admin.Event.FOUND then sent[#sent + 1] = event[1] end
		end
		check('the page reaches the client', #sent > 0, ('%d event(s)'):format(#sent))

		local widest, total = 0, 0
		for _, payload in ipairs(sent) do
			widest = math.max(widest, #payload.rows)
			total = total + #payload.rows
		end
		-- 20 is this module's own chunk, set because the client's JSON decoder
		-- refuses an event past 1,024 value nodes; a found row is about a dozen.
		check('and no single event carries more than 20 rows',
			widest <= 20, ('%d rows in the widest'):format(widest))
		check('the whole page arrives, probe dropped, across those events',
			total == storage.FIND_PAGE, ('%d rows'):format(total))
		check('every chunk is tagged with the question it answers',
			(function()
				for _, payload in ipairs(sent) do
					if payload.tag ~= 'recent||' then return false end
				end
				return #sent > 0
			end)(), sent[1] and tostring(sent[1].tag))
		check('and every chunk carries the page state, not just the last one',
			(function()
				for _, payload in ipairs(sent) do
					if payload.more ~= true or type(payload.cursor) ~= 'string' then return false end
				end
				return true
			end)())
		check('exactly one of them says the list is complete',
			(function()
				local done = 0
				for _, payload in ipairs(sent) do if payload.done then done = done + 1 end end
				return done == 1
			end)())

		-- A REQUEST THAT IS NOT ONE. The argument for this topic is a table, which
		-- is the only topic where it is, so the shape is checked before a thread is
		-- spent on it.
		for _, bad in ipairs({ 'recent', 42, { mode = 'search' },
			{ mode = 'search', term = string.rep('x', 65) } }) do
			local mark = #control.clientEvents
			env.source = 5
			control.netEvents[admin.Event.REFRESH]('found', bad)
			control.Pump(10)
			env.source = nil
			local answeredBack = false
			for index = mark + 1, #control.clientEvents do
				if control.clientEvents[index].name == admin.Event.FOUND then answeredBack = true end
			end
			check(('a malformed find request is dropped rather than run (%s)'):format(type(bad)),
				not answeredBack)
		end
	end
end

-- ── the find screen drops a late answer ──────────────────────────────────────
-- THE ONE SCREEN WITH NO TARGET TO TAG WITH. Every other per-target list on this
-- menu is read FOR a player and tagged with that player's id, so an answer for
-- somebody the operator has moved on from is dropped. The find is read for a
-- QUESTION -- a mode, a term and a cursor -- so the question is the tag, and an
-- answer to a term that has since been retyped has to be dropped exactly as
-- readily.
section('the staff find screen')
do
	local env, control, why = boot('client')
	check('client boots for the find screen', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')

		-- What the screen asked the server for. The host's client half throws
		-- these away; the whole test is about which one was sent and when.
		local asked = {}
		env.TriggerServerEvent = function(name, topic, arg)
			asked[#asked + 1] = { name = name, topic = topic, arg = arg }
		end

		-- THE SPEC AND NOT THE SURFACE. What reaches the CEF page is a rendered
		-- window of labels with the ids and the row data already stripped off, so
		-- the thing worth asserting on is what this module HANDED the menu module.
		-- The contract is wrapped rather than replaced: the real one still runs,
		-- so a spec the menu module would refuse still fails here.
		local specs = {}
		local realMenu = admin.Contracts.menu
		check('the menu contract is there to wrap', type(realMenu) == 'table')
		admin.Contracts.menu = setmetatable({
			Open = function(spec) specs[#specs + 1] = spec; return realMenu.Open(spec) end,
			Update = function(handle, spec)
				specs[#specs + 1] = spec
				return realMenu.Update(handle, spec)
			end,
		}, { __index = realMenu })

		--- Whether the last spec built carries a row with an id.
		local function hasRow(id)
			local spec = specs[#specs]
			for _, item in ipairs(spec and spec.items or {}) do
				if item.id == id then return item end
			end
			return nil
		end

		-- The menu opens against an access map that grants everything, which is
		-- only a drawing hint: the host refuses what it refuses whatever this says.
		control.netEvents[admin.Event.OPEN]({ access = {}, aclKnown = false, inventory = false })
		control.Pump(10)
		check('the staff menu opens', admin.Menu.IsOpen())

		asked = {}
		check('the find screen can be opened', admin.Menu.OpenAt('offlineChars') == true)
		control.Pump(10)
		check('and it lands on the recent list', admin.Menu.Screen() == 'offlineChars')

		local first = nil
		for _, entry in ipairs(asked) do
			if entry.topic == 'found' then first = entry end
		end
		check('opening it asks the server for a page rather than filtering locally',
			first ~= nil and type(first.arg) == 'table' and first.arg.mode == 'recent',
			first and tostring(first.arg))
		check('and it opens on recent, never on the last search somebody typed',
			first ~= nil and first.arg.term == nil)

		--- One page as the server sends it, in a single chunk.
		local function answer(tag, count, more)
			local rows = {}
			for index = 1, count do
				rows[index] = { citizenId = ('CIT-%04d'):format(index),
					firstName = 'Vee', lastName = ('Number%d'):format(index),
					account = ('account-%04d'):format(index),
					lastLoggedOut = '2026-01-01 10:00:00' }
			end
			control.netEvents[admin.Event.FOUND]({ rows = rows, offset = 0, total = count,
				done = true, tag = tag, mode = 'recent', more = more,
				cursor = more and ('CIT-%04d'):format(count) or nil,
				seenAt = more and '2026-01-01 10:00:00' or nil })
			control.Pump(10)
		end

		-- THE LATE ANSWER. A page tagged with a question this screen is not asking
		-- must not be drawn, and the difference between the two calls below is the
		-- tag and nothing else.
		answer('recent|stale-question|', 3, false)
		check('a page answering a question the screen is not asking is dropped',
			hasRow('found_CIT-0001') == nil)
		check('and the screen is still waiting rather than showing another question answer',
			hasRow('empty') ~= nil)

		answer('recent||', 3, false)
		check('a page answering the question it IS asking is drawn',
			hasRow('found_CIT-0001') ~= nil)
		check('the placeholder goes with it', hasRow('empty') == nil)
		check('a row is a way into the SAME character page the roster reaches',
			(function()
				local item = hasRow('found_CIT-0001')
				return item ~= nil and type(item.data) == 'table' and item.data.go == 'character'
					and item.data.arg == 'CIT-0001'
			end)())
		check('and a last page offers nothing to seek past', hasRow('more') == nil)

		-- THE SEEK ROW, which only exists when the server said there is more.
		answer('recent||', 3, true)
		local more = hasRow('more')
		check('a page with more behind it offers a seek', more ~= nil)
		check('and the seek carries the sort key rather than a page number',
			more ~= nil and type(more.data) == 'table' and type(more.data.seek) == 'table'
				and more.data.seek.cursor == 'CIT-0003'
				and more.data.seek.seenAt == '2026-01-01 10:00:00'
				and more.data.seek.p == nil)

		-- THE FLOOR, mirrored on the client so that a term too short is a sentence
		-- rather than a round trip that comes back refused. The server checks it
		-- again and is the authority.
		asked = {}
		admin.Menu.Filter('ab')
		control.Pump(10)
		check('a two-letter search is not sent to the server at all',
			(function()
				for _, entry in ipairs(asked) do
					if entry.topic == 'found' then return false end
				end
				return true
			end)())

		admin.Menu.Filter('silverhand')
		control.Pump(10)
		local searched = nil
		for _, entry in ipairs(asked) do
			if entry.topic == 'found' then searched = entry end
		end
		check('a long enough search goes to the server, because there is no local list',
			searched ~= nil and searched.arg.mode == 'search'
				and searched.arg.term == 'silverhand')
		check('and it starts the seek over rather than carrying the old cursor',
			searched ~= nil and searched.arg.cursor == nil)
		check('the screen shows it is waiting, not the recent rows under a new title',
			hasRow('found_CIT-0001') == nil)

		-- And the answer to the OLD question, arriving now, is dropped -- which is
		-- the whole reason the tag is the question and not a player id.
		answer('recent||', 3, false)
		check('the answer to the previous question, arriving late, is still dropped',
			hasRow('found_CIT-0001') == nil)

		asked = {}
		admin.Menu.Filter(nil)
		control.Pump(10)
		local cleared = nil
		for _, entry in ipairs(asked) do
			if entry.topic == 'found' then cleared = entry end
		end
		check('clearing the box goes back to the recent list',
			cleared ~= nil and cleared.arg.mode == 'recent' and cleared.arg.term == nil)

		-- ── the ONE character page, reached from both lists ──────────────────
		-- `live` IS A PLAYER ID ON ONE LIST AND A BOOLEAN ON THE OTHER, which is
		-- right both times -- under an account's characters the player is the
		-- screen above and there is nothing to name, and on the find there is --
		-- and it is exactly the sort of difference that puts a `true` through a
		-- `%d` and loses the whole screen, because a builder that raises takes the
		-- page with it rather than one row.
		control.netEvents[admin.Event.FOUND]({
			rows = { { citizenId = 'CIT-0009', firstName = 'Vee', lastName = 'Nine',
				account = 'account-nine', live = 7 } },
			offset = 0, total = 1, done = true, tag = 'recent||', mode = 'recent' })
		control.Pump(10)
		check('the find page can be opened on a found row',
			admin.Menu.OpenAt('character', 'CIT-0009') == true)
		control.Pump(10)
		check('and it names the slot holding the character it just found',
			(function()
				local item = hasRow('here')
				return item ~= nil and tostring(item.value):find('[7]', 1, true) ~= nil
			end)(), (function() local i = hasRow('here') return i and tostring(i.value) end)())
		check('it carries the account, which only a found row knows',
			hasRow('account') ~= nil)
		check('and the delete row refreshes the list it actually came from',
			(function()
				local item = hasRow('delete')
				return item ~= nil and type(item.data) == 'table' and item.data.refresh == 'found'
			end)())

		-- The same page for a row off the OTHER list, where `live` is a boolean.
		control.netEvents[admin.Event.CHARACTERS]({
			rows = { { citizenId = 'CIT-0100', firstName = 'Vee', lastName = 'Hundred',
				live = true } },
			offset = 0, total = 1, done = true, target = nil })
		control.Pump(10)
		local built = admin.Menu.OpenAt('character', 'CIT-0100')
		control.Pump(10)
		check('the same page builds for a row off the account list', built == true)
		check('and it draws the name rather than raising on a boolean slot',
			(function()
				local item = hasRow('name')
				return item ~= nil and tostring(item.value):find('Hundred', 1, true) ~= nil
			end)(), (function() local i = hasRow('name') return i and tostring(i.value) end)())
	end
end

-- ── both languages, in step ─────────────────────────────────────────────────
-- A KEY IS ONLY TRANSLATED WHEN IT IS TRANSLATED EVERYWHERE. A missing French
-- key is not a missing sentence: `locale()` answers the key itself, so the
-- player reads `admin.menu.findHint` off the screen. Read out of the SOURCE and
-- not out of a booted catalogue, because half these files need their module
-- declared first and none of that is what is under test.
section('every locale key is in both languages')
do
	local files = { 'locales/en.lua', 'locales/fr.lua' }
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'shared')) do
		if file:match('locales%.lua$') then files[#files + 1] = file end
	end
	check('the locale files were found', #files > 2, ('%d file(s)'):format(#files))

	local keys = { en = {}, fr = {} }
	for _, file in ipairs(files) do
		local handle = io.open(file, 'r')
		if handle then
			local language
			for line in handle:lines() do
				language = line:match("OPX%.Locale%.Register%('(%a%a)'") or language
				local key = line:match("^%s*%['([%w%.%-_]+)'%]%s*=")
				if key and keys[language] then keys[language][key] = file end
			end
			handle:close()
		end
	end

	local gaps = {}
	for key, file in pairs(keys.en) do
		if keys.fr[key] == nil then gaps[#gaps + 1] = ('fr is missing %s (%s)'):format(key, file) end
	end
	for key, file in pairs(keys.fr) do
		if keys.en[key] == nil then gaps[#gaps + 1] = ('en is missing %s (%s)'):format(key, file) end
	end
	table.sort(gaps)

	local counted = 0
	for _ in pairs(keys.en) do counted = counted + 1 end
	check('there are keys to compare', counted > 400, ('%d English keys'):format(counted))
	check('and every one of them is written in both languages',
		#gaps == 0, table.concat(gaps, '; '))
end

print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
