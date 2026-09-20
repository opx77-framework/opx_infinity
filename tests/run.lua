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

--- Pumps until `ready()` answers true, or `rounds` are spent.
-- The client scheduler runs at most four jobs per pass and rotates between
-- them, so "one scan later" is not a fixed number of rounds -- a test that
-- hard-codes one is asserting how many other modules happened to register a job
-- on the same loop, which changes every time a module is added. This answers
-- whether it settled, so the assertion after it keeps its teeth.
-- @param control table the booted environment's control handle
-- @param ready function
-- @param rounds integer|nil
-- @return boolean
local function settle(control, ready, rounds)
	for _ = 1, rounds or 40 do
		if ready() then return true end
		control.Pump(1)
	end
	return ready()
end

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

		-- A MODULE MUST SEE THE CONFIG THE MANIFEST LOADED. `module.lua` is a
		-- shared script and this suite now loads in the platform's order -- every
		-- shared script before any server script -- so a module whose config is
		-- one of the three server-only ones asks for its settings after that
		-- config has run. It used to ask before, and hold the empty fallback for
		-- the life of the resource: `vehicles` compared a nil ceiling inside
		-- `Register`, so a dealership purchase took the money and wrote no row.
		-- The VALUES are checked rather than the mechanism, because the values
		-- are what a module compares.
		local vehiclesModule = env.OPX.Modules.Get('vehicles')
		local vehicleSettings = env.OPX.Config.MODULES.vehicles
		check('a module reads its own config even when that config is a server script',
			vehiclesModule ~= nil and type(vehicleSettings) == 'table'
				and vehiclesModule.Settings.PER_CHARACTER == vehicleSettings.PER_CHARACTER
				and vehiclesModule.Settings.SPAWN_OFFSET == vehicleSettings.SPAWN_OFFSET
				and vehiclesModule.Settings.PER_CHARACTER ~= nil,
			vehiclesModule and ('%s / %s'):format(tostring(vehiclesModule.Settings.PER_CHARACTER),
				tostring(vehicleSettings and vehicleSettings.PER_CHARACTER)))

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
	-- @param natives table|nil more fields for the appearance namespace. The three
	-- above are all the JOINS below need; a section that opens a panel needs the
	-- one question a panel asks before it opens -- whether a native appearance
	-- modal is on screen -- and the default namespace does not answer it, which
	-- this module reads as 'up' on purpose.
	-- @return table env
	-- @return table control
	local function joinClient(policy, waitMs, blind, natives)
		local own, ctl = Host.Environment('client')
		own.Open77.appearance = {
			captureBody = function() return nil, 'no_host' end,
			takeBodyFamilyTransition = function() return nil end,
			finishCommit = function() return true end,
		}
		for field, value in pairs(natives or {}) do own.Open77.appearance[field] = value end
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

	-- ── the catalogue pass ───────────────────────────────────────────────────
	-- WHAT THE CLIENT LOG SHOWED, on the machine of the player who reported it:
	--
	--     wardrobe.lua:624: Open77 script execution budget exceeded
	--
	-- The pass formatted 256 records between two yields -- about 750us, seven times
	-- the host's share of the frame budget -- so the raise ended the thread inside
	-- the first stride and the room read a catalogue that could never arrive. The
	-- room still LOOKED alive, which is why this needs a driven pass rather than a
	-- screenshot: nothing about a dead thread is visible on screen.
	--
	-- Driven through `Stream` with a stubbed list, because a real room needs a
	-- playable puppet and this is a property of the pass, not of the puppet.
	do
		local env, control = joinClient('never', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		local Wardrobe = appearance.Wardrobe

		-- A FULL CATALOGUE, in the shape the engine returns it: every slot the room
		-- dresses, one nonvisual record, one record of a slot the room does not draw,
		-- and one entry that is not a record at all -- neither of the last two may
		-- reach the view.
		local slots = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }
		local records = {}
		local hidden = 0
		for index = 1, 2000 do
			local nonvisual = index % 97 == 0
			if nonvisual then hidden = hidden + 1 end
			records[index] = { record = ('Items.Piece_%02d_of_%d'):format(index % 40, index),
				slot = slots[(index % #slots) + 1], nonvisual = nonvisual }
		end
		records[#records + 1] = { record = 'Items.NotASlot_01', slot = 'Thermal' }
		records[#records + 1] = 'Items.NotEvenARecord'

		-- THE PAUSE IS THE RESUME BOUNDARY. The host spends a budget per resume, so
		-- the assertion is about records per SUSPENSION, not per batch -- and a stride
		-- that grows again fails here rather than on a player's screen.
		local resumes = 0
		local sizes, items, finals, lastFinal = {}, 0, 0, nil
		local firstItem = nil
		local done = Wardrobe.Stream(records,
			function() resumes = resumes + 1 end,
			function() return true end,
			function(part, final)
				sizes[#sizes + 1] = #part
				items = items + #part
				if firstItem == nil then firstItem = part[1] end
				if final then finals = finals + 1 end
				lastFinal = final
			end)

		check('a two-thousand record catalogue streams to the end', done == true)
		check('and every wearable record reaches the room, minus the hidden ones',
			items == 2000 - hidden and hidden > 0,
			('%d shown of %d, %d hidden'):format(items, #records, hidden))
		-- The four fields the panel contract draws, and the record twice over: `detail`
		-- is the row's second line, and `id` is what a selection comes back as.
		check('each row carries the record, its tab, its label and the line under it',
			firstItem ~= nil and firstItem.id == firstItem.detail
				and type(firstItem.label) == 'string' and firstItem.label ~= ''
				and type(firstItem.tab) == 'string',
			firstItem and tostring(firstItem.id))
		check('one yield at least every stride of records, which is what the budget needs',
			resumes >= math.ceil(#records / 8),
			('%d resume(s) for %d records'):format(resumes, #records))
		check('and each part is the size an event carries',
			sizes[#sizes] ~= nil and sizes[#sizes] <= 32)
		check('the last part is the only one marked final',
			finals == 1 and lastFinal == true, ('%d final(s)'):format(finals))

		-- AND THE ROWS THE SORT RUNS ON ARE PLAIN STRINGS, which is the property that
		-- makes that sort C's. Sorting entries through a comparator measured 825us of
		-- Lua calls for two thousand rows -- 44,000 of them -- against a share of the
		-- frame budget around 100-125us, so a comparator is the same silent death the
		-- stride was. Pinned by SHAPE, because until a thread dies there is no other
		-- difference to observe: the rows order identically either way.
		local rows = Wardrobe.Catalogue(records, function() end, function() return true end)
		check('and the rows handed to the sort are packed strings, so C does the sorting',
			type(rows) == 'table' and #rows == items and type(rows[1]) == 'string'
				and rows[1]:find('\0', 1, true) ~= nil,
			rows and ('%s, %d row(s)'):format(type(rows[1]), #rows))

		-- THE ORDER IS THE DOCUMENTED ONE, and not whatever the bytes happen to do:
		-- a label's digits are read as numbers, so 2 comes before 10. The sort is C's
		-- now, which is the only reason two thousand rows can be ordered at all.
		local pair = {}
		Wardrobe.Stream(
			{ { record = 'Items.Shirt_10', slot = 'InnerChest' },
				{ record = 'Items.Shirt_2', slot = 'InnerChest' } },
			function() end, function() return true end,
			function(part)
				for index = 1, #part do pair[#pair + 1] = part[index].label end
			end)
		check('the catalogue is ordered by label, digits as numbers',
			pair[1] == 'Shirt 2' and pair[2] == 'Shirt 10', table.concat(pair, ' | '))

		-- A ROOM THAT HAS GONE TAKES THE PASS WITH IT: the `alive` check is what stops
		-- one character's catalogue landing in another's room.
		local parts, stopped = 0, nil
		stopped = Wardrobe.Stream(records, function() end,
			function() return parts < 40 end,
			function() parts = parts + 1 end)
		check('a catalogue for a room that has gone stops where it stood',
			stopped == false and parts == 40, ('%s after %d part(s)'):format(tostring(stopped), parts))
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

	-- ── the doors into both views ────────────────────────────────────────────
	-- THE HOLE THIS EXISTS FOR. The module owns two state machines and draws
	-- neither: `client/view.lua` hands the panel to `menu` and the fitting room
	-- to `panel`, and the contract that opens them is exported on the API. Until
	-- the key and the two commands were added, NOTHING CALLED IT -- and the only
	-- symptom was a screen that never appeared, on the machine of every player
	-- who was not mid-creation, because the policy offers the room to a character
	-- the creator has just built and to nobody else.
	do
		-- `isOpen` answers false, which is what a client with no modal on screen
		-- says. The default namespace does not answer it at all, and this module
		-- reads a raise as 'a modal IS up' -- so without this the panel under test
		-- could never open on this host for a reason that is not the code's.
		local env, control = joinClient('never', 400, false, {
			isOpen = function() return false end,
		})
		local OPX = env.OPX
		local appearance = OPX.Modules.Get('appearance')

		check('the client boots with the appearance module running',
			OPX.Modules.IsRunning('appearance'), OPX.Modules.Record('appearance').Reason)

		-- ── the key ──────────────────────────────────────────────────────
		local declared = appearance.Settings.KEY
		local mapping = type(declared) == 'table' and control.keyMappings.byId[declared.ID] or nil
		check('the panel key is declared to the host, so a player can rebind it',
			mapping ~= nil, tostring(declared and declared.ID))
		check('and defaults to the key the configuration ships',
			mapping ~= nil and mapping.key == declared.DEFAULT, mapping and tostring(mapping.key))
		check('and the pause menu is given a name for it, not the key itself',
			mapping ~= nil and type(mapping.name) == 'string' and mapping.name ~= ''
				and mapping.name ~= declared.DEFAULT
				-- Neither the key NOR the catalogue key: the label is rendered, so a
				-- translation nobody registered shows up here as the key it was for.
				and mapping.name ~= declared.NAME,
			mapping and tostring(mapping.name))

		-- NO CHARACTER YET. The panel has nothing to show, and the point of the
		-- check is the second half: a key that does nothing and says nothing is
		-- indistinguishable from a key that is not wired up at all.
		local idle = #control.log.warn
		mapping.pressed()
		check('the key with no character loaded opens nothing', not appearance.Panel.IsOpen())
		check('and names the reason in the journal rather than going quiet',
			#control.log.warn == idle + 1
				and tostring(control.log.warn[#control.log.warn]):find('no_character', 1, true) ~= nil,
			control.log.warn[#control.log.warn])

		-- A CHARACTER, AND THEN THE SAME KEY. Both halves matter: `OpenPanel` for
		-- a caller who already owns the open panel refreshes it rather than
		-- refusing, so a key wired straight to it could raise the panel and never
		-- take it down.
		-- A RETURNING character, which is the player the whole hole was about: it
		-- has a stored face, so nothing asks for the game's own creator -- the one
		-- state in which the panel is legitimately busy -- and the key has to work.
		control.Fire(OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded'), {
			citizenId = 'citizen-door',
			charInfo = { gender = 'female' },
			appearance = { gameBuild = '2.31' },
		})
		local arrived = #control.log.warn
		mapping.pressed()
		check('the key puts the panel up for a character that has one',
			appearance.Panel.IsOpen() and appearance.Panel.Owner() == 'appearance',
			('%s / %s'):format(tostring(appearance.Panel.Owner()),
				#control.log.warn > arrived and control.log.warn[#control.log.warn]
					or 'no refusal was logged'))
		mapping.pressed()
		check('and the same key takes it down again', not appearance.Panel.IsOpen())

		-- A KEY PRESSED INTO A SURFACE HOLDING THE KEYBOARD. It must neither raise
		-- the panel nor close the one already up, or typing F7 into a text field
		-- would toggle a surface the player is not looking at.
		mapping.pressed()
		check('the panel is up again', appearance.Panel.IsOpen())
		control.input.captured = true
		mapping.pressed()
		check('a key pressed into a surface holding the keyboard is ignored',
			appearance.Panel.IsOpen())
		control.input.captured = false
		mapping.pressed()
		check('and works again once that surface lets go', not appearance.Panel.IsOpen())

		-- ── what the two commands reach ──────────────────────────────────
		control.netEvents[appearance.Event.SHOW]('panel')
		check('the command puts the panel up on the client it was run for',
			appearance.Panel.IsOpen())
		control.netEvents[appearance.Event.SHOW]('panel')
		check('and a second run takes the same panel down',
			not appearance.Panel.IsOpen())

		-- A payload the server would never send names no view, so it opens none --
		-- and it is the CLIENT that decides that, not the server that sent it.
		control.netEvents[appearance.Event.SHOW]('everything')
		check('a view the server never names opens nothing',
			not appearance.Panel.IsOpen() and not appearance.Wardrobe.IsOpen())

		-- THE FITTING ROOM, which is the view the whole hole was about. This host
		-- has no playable puppet, so the state half refuses -- and the assertion
		-- is that the command's outcome is never SILENT: it is either open or it
		-- is named in the journal, which is the line a player or an operator reads
		-- instead of "I ran it and nothing happened".
		local asked = #control.log.warn
		control.netEvents[appearance.Event.SHOW]('wardrobe')
		control.Pump(8)
		check('the fitting room opens, or is refused by the state half itself',
			appearance.Wardrobe.IsOpen() or (#control.log.warn > asked
				and tostring(control.log.warn[#control.log.warn])
					:find('the fitting room was not put up: player_unavailable', 1, true) ~= nil),
			appearance.Wardrobe.IsOpen() and 'opened'
				or tostring(control.log.warn[#control.log.warn]))
	end

	-- ── the two commands, on the server ──────────────────────────────────────
	do
		local env, control, why = boot('server')
		check('the server boots with the appearance module', why == nil, why)

		local appearance = env.OPX.Modules.Get('appearance')
		local panel = control.commands['opx.appearance']
		local room = control.commands['opx.appearance.wardrobe']

		-- UNRESTRICTED, and that is a decision rather than an omission: both act on
		-- the caller alone, so there is nothing for the ACL to protect -- and a
		-- player who has never been granted anything still has to be able to reach
		-- their own clothes.
		check('the panel command is registered and open to every player',
			panel ~= nil and not panel.restricted)
		check('and so is the fitting room command', room ~= nil and not room.restricted)

		-- The help line is a CATALOGUE KEY the chat box renders at send time, so a
		-- typo in it is a suggestion reading `appearance.command.panel`.
		for _, key in ipairs({ 'appearance.command.panel', 'appearance.command.wardrobe' }) do
			check(('the help for %s is translated'):format(key),
				env.OPX.Locale.Text(key) ~= key, env.OPX.Locale.Text(key))
		end

		if panel ~= nil and room ~= nil then
			local src = 7
			panel.run(src, {})
			local sent = control.clientEvents[#control.clientEvents]
			check('running it names the panel to the caller\'s own client',
				sent ~= nil and sent.name == appearance.Event.SHOW and sent.source == src
					and sent[1] == 'panel', sent and tostring(sent[1]))

			room.run(src, {})
			local late = control.clientEvents[#control.clientEvents]
			check('and the other names the fitting room, to the same client',
				late ~= nil and late.name == appearance.Event.SHOW and late.source == src
					and late[1] == 'wardrobe', late and tostring(late[1]))
		end
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
-- ── garages and AV pads ─────────────────────────────────────────────────────
-- What is under test is a PLACE and not a menu: a marker stands where an operator
-- put it, the vehicle is created ON it rather than beside the player, and every
-- claim a client makes is re-derived on the server. So these checks drive the
-- real net events and the real vehicles contract, and read the marker options and
-- the created vehicle's position back out of the host -- a test that only saw an
-- id could not tell a vehicle placed on the marker from one placed beside the
-- player, which is the whole feature.
section('garages')
do
	-- The vehicle roster the bridge answers with. The SQL is the real storage
	-- module's; this is only the bridge half.
	local function bridge(rows, wrote)
		return Host.Database({
			scalar = function() return 1 end,
			update = function(sql)
				-- Only the INSERT: the schema runs `CREATE TABLE IF NOT EXISTS`
				-- through the same bridge method, and counting that would make
				-- "nothing was written" true of a boot rather than of a refusal.
				if wrote ~= nil and sql:find('INSERT INTO opx77_garages', 1, true) then
					wrote[#wrote + 1] = sql
				end
				return 0
			end,
			query = function(sql, params)
				-- Filtered by the citizen the statement binds, exactly as the real
				-- storage does: a stub that answered every row to every caller would
				-- make a character who owns nothing look like an owner, which is one
				-- of the refusals under test.
				if sql:find('opx77_vehicles', 1, true) then
					local citizen = type(params) == 'table' and params.citizen or nil
					local mine = {}
					for index = 1, #rows do
						if citizen == nil or rows[index].citizen_id == citizen then
							mine[#mine + 1] = rows[index]
						end
					end
					return mine
				end
				return {}
			end,
			-- One vehicle by its plate, and the count behind the ceiling. Both are
			-- read through `single`; answering nil to the first is a refusal the
			-- vehicles module reports as `vehicle.notFound`, which is how a bring-out
			-- check can pass while no vehicle is ever created.
			single = function(sql, params)
				if sql:find('COUNT(%*)') ~= nil then return { total = #rows } end
				local plate = type(params) == 'table' and params.plate or nil
				if plate ~= nil then
					for index = 1, #rows do
						if rows[index].plate == plate then return rows[index] end
					end
				end
				return nil
			end,
		})
	end

	local function row(plate, record)
		return {
			plate = plate, citizen_id = 'citizen-garage', record = record,
			appearance = nil, garage = 'impound', state = 1, health = 1.0,
			body = nil, paint = nil, metadata = '{}',
		}
	end

	local wrote = {}
	local env, control, why = boot('server', bridge({ row('AA111AA', 'Vehicle.v_standard2_archer_hella_player'),
		row('AA222AA', 'Vehicle.av_militech_manticore') }, wrote))
	check('the server boots with the garages module', why == nil, why)

	-- The last client event with one name, or nil. Every verdict below is asserted
	-- off the wire rather than off a return value, because the wire is what the
	-- player's client actually reads.
	local function lastEvent(name)
		for index = #control.clientEvents, 1, -1 do
			if control.clientEvents[index].name == name then return control.clientEvents[index] end
		end
		return nil
	end

	if why == nil then
		local OPX = env.OPX
		local garages = OPX.Modules.Get('garages')
		local Access = garages.Access
		local contract = OPX.Api.Get('garages')

		check('the garages module is running', OPX.Modules.IsRunning('garages'),
			OPX.Modules.Record('garages').Reason)
		check('and publishes its half of the contract',
			contract ~= nil and type(contract.Bring) == 'function' and type(contract.Spots) == 'function')
		check('the shipped config reports no problems', #Access.Problems() == 0,
			table.concat(Access.Problems(), ' | '))

		-- ── the AV rule, which decides what a pad will take ────────────────
		check('an AV record is an AV', Access.IsAv('Vehicle.av_militech_manticore') == true)
		check('a max-tac AV record is an AV', Access.IsAv('Vehicle.max_tac_av') == true)
		check('a ground car is not', Access.IsAv('Vehicle.v_standard2_archer_hella_player') == false)
		check('and neither is nothing at all', Access.IsAv(nil) == false)
		check('case is not the caller\'s problem', Access.IsAv('VEHICLE.AV_RAYFIELD_EXCALIBUR') == true)

		-- ── the marker vocabulary ─────────────────────────────────────────
		-- Both markers GLOW, which is the request: the engine's four styles are
		-- the only glowing looks there are, and a resource-declared style is not
		-- something this build can mount.
		local garageLook = Access.Marker('garage')
		check('a garage marker is the glowing spawn cylinder',
			garageLook.shape == 'cylinder' and garageLook.style == 'spawn' and garageLook.radius == 2.5,
			('%s/%s/%s'):format(tostring(garageLook.shape), tostring(garageLook.style),
				tostring(garageLook.radius)))
		local padLook = Access.Marker('avpad')
		check('a pad marker is the glowing objective ring',
			padLook.shape == 'ring' and padLook.style == 'objective' and padLook.radius == 3.5,
			('%s/%s/%s'):format(tostring(padLook.shape), tostring(padLook.style),
				tostring(padLook.radius)))

		-- ── the lift, which is the difference between a glow and an empty pad
		-- A ring is the marker mesh flattened to 0.04 m: left on the floor it is
		-- co-planar with it and draws nothing at all. Both kinds are lifted, and
		-- the lift travels with the look so no call site can forget it.
		check('both markers are lifted off the floor',
			garageLook.lift == 0.06 and padLook.lift == 0.06,
			('%s/%s'):format(tostring(garageLook.lift), tostring(padLook.lift)))

		local shippedOffset = OPX.Config.MODULES.garages.GROUND_OFFSET
		OPX.Config.MODULES.garages.GROUND_OFFSET = 0.0
		check('a lift of zero is a choice and not a mistake',
			Access.Marker('avpad').lift == 0.0)
		OPX.Config.MODULES.garages.GROUND_OFFSET = 9000.0
		check('an unbounded lift is clamped to the default, not carried to the engine',
			Access.Marker('avpad').lift == 0.06)
		check('and a lift the config got wrong is reported at boot',
			#Access.Problems() == 1, table.concat(Access.Problems(), ' | '))
		OPX.Config.MODULES.garages.GROUND_OFFSET = shippedOffset

		local MARKER = OPX.Config.MODULES.garages.MARKER
		local shippedStyle = MARKER.garage.style
		MARKER.garage.style = 'glow'
		check('a style the engine does not have falls back rather than being sent',
			Access.Marker('garage').style == 'spawn')
		MARKER.garage.style = shippedStyle

		local shippedDistance = OPX.Config.MODULES.garages.MAX_DISTANCE
		OPX.Config.MODULES.garages.MAX_DISTANCE = 9000.0
		check('a draw distance the engine would refuse is clamped to its ceiling',
			Access.MaxDistance() == 150.0)
		OPX.Config.MODULES.garages.MAX_DISTANCE = shippedDistance

		-- ── what a spot has to be ─────────────────────────────────────────
		local good = Access.FromWire({ key = 'x', kind = 'garage', x = 0.0, y = 0.0, z = 0.0 })
		check('a spot off the wire is accepted', good ~= nil and good.heading == 0.0 and good.bucket == 0)
		check('and takes its key as its label when it has none', good ~= nil and good.label == 'x')
		check('an unknown kind is refused',
			Access.FromWire({ key = 'x', kind = 'garage2', x = 0.0, y = 0.0, z = 0.0 }) == nil)
		check('a NaN coordinate is refused, not carried to the engine',
			Access.FromWire({ key = 'x', kind = 'garage', x = 0 / 0, y = 0.0, z = 0.0 }) == nil)
		check('an over-long key is refused',
			Access.FromWire({ key = string.rep('k', 200), kind = 'garage', x = 0.0, y = 0.0, z = 0.0 }) == nil)

		-- ── distance, and the tie ─────────────────────────────────────────
		local spots = {
			left = Access.FromDefinition('left', { KIND = 'garage', X = 3.0, Y = 0.0, Z = 0.0 }),
			right = Access.FromDefinition('right', { KIND = 'garage', X = -3.0, Y = 0.0, Z = 0.0 }),
			far = Access.FromDefinition('far', { KIND = 'garage', X = 100.0, Y = 0.0, Z = 0.0 }),
		}
		local nearest = Access.Nearest(spots, 0.0, 0.0)
		check('two markers a metre apart are decided by name, not by pairs order',
			nearest ~= nil and nearest.key == 'left', nearest and nearest.key)
		check('a radius the caller names is what is measured against',
			select(1, Access.Nearest(spots, 0.0, 0.0, 4.0)) == nil)
		check('a spot beyond the radius is not offered',
			select(1, Access.Nearest({ far = spots.far }, 0.0, 0.0)) == nil)

		-- ── the capture round-trip ─────────────────────────────────────────
		-- A character that owns the two rows above, on a slot the host admitted.
		local function load(id, citizenId)
			control.Admit(id, 'account-' .. tostring(id))
			OPX.EnsureSession(id)
			local character = OPX.Modules.Get('character')
			character.Players[id] = { PlayerData = { citizenId = citizenId } }
			return character
		end

		local src = 41
		load(src, 'citizen-garage')

		check('the capture command is registered and ACL-gated',
			control.commands['opx.garages.add'] ~= nil
				and control.commands['opx.garages.add'].restricted == true)
		check('and its routeway to the client exists',
			type(control.netEvents[garages.Event.CAPTURED]) == 'function')

		-- The command asks the CLIENT where it is looking, because a chat command
		-- has no facing of its own.
		local mark = #control.clientEvents
		control.commands['opx.garages.add'].run(src, { 'garage', 'garage_dock' })
		local asked = lastEvent(garages.Event.CAPTURE)
		check('the add command asks the client for its facing',
			asked ~= nil and #control.clientEvents > mark and asked.source == src)
		check('naming the kind and the key it was given',
			asked ~= nil and asked[1] == 'garage' and asked[2] == 'garage_dock')

		-- ── the bare form the config file advertises ─────────────────────
		-- `config/garages.lua` has always said `/opx.garages.add` prints the line to
		-- check in, while the handler demanded two positionals and answered the
		-- bare command with a string no player saw and no line in the server log.
		-- A command the documentation advertises and the handler refuses is a door
		-- with no handle, so the kind and the key are now both optional.
		control.commands['opx.garages.add'].run(src, {})
		local bare = lastEvent(garages.Event.CAPTURE)
		check('the bare add command asks the client too, as a garage',
			bare ~= nil and bare[1] == 'garage', bare and tostring(bare[1]))
		check('under a key it generated, so the spot can be named again afterwards',
			bare ~= nil and bare[2] == 'garage1', bare and tostring(bare[2]))

		-- The generated key steps past what is already placed, so a second bare
		-- capture cannot land on the first one's name.
		control.commands['opx.garages.add'].run(src, { 'avpad' })
		local pad = lastEvent(garages.Event.CAPTURE)
		check('a bare AV pad add is an avpad with its own generated key',
			pad ~= nil and pad[1] == 'avpad' and pad[2] == 'avpad1',
			pad and ('%s/%s'):format(tostring(pad[1]), tostring(pad[2])))

		-- A first word that is not a kind is the KEY, which is what somebody
		-- typing `add watson` means; the label still travels as the label.
		control.commands['opx.garages.add'].run(src, { 'watson', 'THE DOCKS' })
		local named = lastEvent(garages.Event.CAPTURE)
		check('and a first word that is not a kind is the key',
			named ~= nil and named[1] == 'garage' and named[2] == 'watson'
				and named[3] == 'THE DOCKS',
			named and ('%s/%s/%s'):format(tostring(named[1]), tostring(named[2]),
				tostring(named[3])))

		-- A CLIENT THAT FIRES THE ROUTEWAY ITSELF. The net event has no host-side
		-- ACL check -- that gate runs for commands only -- so the module asks the
		-- same question here. Without this, anybody could place markers.
		env.source = src
		local before = #control.clientEvents
		control.netEvents[garages.Event.CAPTURED]('garage', 'sneaky', 'SNEAKY', 0.0)
		local denied = control.clientEvents[#control.clientEvents]
		check('a capture from someone without the permission is refused',
			#control.clientEvents > before and denied ~= nil and denied[1] ~= nil
				and denied[1].code == 'error.noPermission',
			denied and denied[1] and tostring(denied[1].code))
		check('and the refusal names the operation, so a client can tell it apart',
			denied ~= nil and denied[1] ~= nil and denied[1].operation == garages.Operation.CAPTURE)
		check('and nothing was placed', contract.Spots()['sneaky'] == nil)
		check('and nothing was written', #wrote == 0, #wrote)

		-- With the permission, the same routeway lands a spot.
		control.Allow(src, 'command.opx.garages.add')
		control.netEvents[garages.Event.CAPTURED]('garage', 'garage_dock', 'THE DOCK', 90.0)
		control.Pump(8)
		local held = contract.Spots()
		check('a permitted capture lands', held['garage_dock'] ~= nil)
		check('at the position the SERVER read and the heading the client gave',
			held['garage_dock'] ~= nil and held['garage_dock'].x == 0.0
				and held['garage_dock'].y == 0.0 and held['garage_dock'].z == 0.0
				and held['garage_dock'].heading == 90.0,
			held['garage_dock'] and ('%s,%s,%s yaw %s'):format(held['garage_dock'].x,
				held['garage_dock'].y, held['garage_dock'].z, tostring(held['garage_dock'].heading)))
		check('and its label is the operator\'s own words', held['garage_dock'].label == 'THE DOCK')
		check('and the row was written through the bridge', #wrote == 1, #wrote)
		local synced = lastEvent(garages.Event.SYNC)
		check('and the client was told what is there now',
			synced ~= nil and type(synced[1]) == 'table' and type(synced[1].spots) == 'table'
				and #synced[1].spots == 1)

		-- ── bringing out what the character owns ──────────────────────────
		local created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		local options = control.vehicleCreates[#control.vehicleCreates]
		check('the request creates one vehicle', #control.vehicleCreates == created + 1)
		check('ON the marker, never a car\'s width to one side',
			options ~= nil and type(options.position) == 'table' and options.position.x == 0.0
				and options.position.y == 0.0 and options.position.z == 0.0,
			options and options.position and ('%s,%s,%s'):format(options.position.x,
				options.position.y, options.position.z))
		check('facing the heading the spot was captured with',
			options ~= nil and options.yaw == 90.0, options and tostring(options.yaw))
		-- The wire is (key, ok, failure, plate): the failure slot is nil on a
		-- success, so the plate is the FOURTH argument and not the third. Read
		-- positionally, the same shape the client's own handler reads.
		local answer = lastEvent(garages.Event.ANSWER)
		check('and the player is told which of their own vehicles came out',
			answer ~= nil and answer[1] == 'garage_dock' and answer[2] == true
				and answer[4] == 'AA111AA',
			answer and tostring(answer[4]))
		check('a ground car is what a ground marker takes',
			options ~= nil and options.record == 'Vehicle.v_standard2_archer_hella_player')

		-- ── the AV pad ────────────────────────────────────────────────────
		-- Added through the table the server itself holds, so the validation
		-- under test is the real one rather than a fixture's copy.
		held['pad_dock'] = Access.FromDefinition('pad_dock', {
			KIND = 'avpad', LABEL = 'THE PAD', X = 0.0, Y = 0.0, Z = 2.0, HEADING = 0.0, BUCKET = 0,
		})
		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('pad_dock')
		control.Pump(8)
		options = control.vehicleCreates[#control.vehicleCreates]
		check('a pad takes the AV and not the car',
			#control.vehicleCreates == created + 1 and options ~= nil
				and options.record == 'Vehicle.av_militech_manticore',
			options and tostring(options.record))
		check('and it is lifted clear of the pad it materialises on',
			options ~= nil and options.position.z == 2.0 + 1.2, options and tostring(options.position.z))
		check('the pad\'s own answer names the AV',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[4] == 'AA222AA',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[4]))

		-- ── what is refused, and why ──────────────────────────────────────
		local walker = 42
		load(walker, 'citizen-garage')
		env.source = walker

		local far = 40.0
		held['far_dock'] = Access.FromDefinition('far_dock', {
			KIND = 'garage', LABEL = 'FAR', X = far, Y = 0.0, Z = 0.0, HEADING = 0.0, BUCKET = 0,
		})
		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('far_dock')
		control.Pump(8)
		check('standing 40 metres from a marker creates nothing',
			#control.vehicleCreates == created)
		check('and says it was the distance',
			lastEvent(garages.Event.ANSWER) ~= nil and lastEvent(garages.Event.ANSWER)[3] == 'garages.tooFar',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[3]))

		held['other_bucket'] = Access.FromDefinition('other_bucket', {
			KIND = 'garage', LABEL = 'ELSEWHERE', X = 0.0, Y = 0.0, Z = 0.0, BUCKET = 7,
		})
		control.netEvents[garages.Event.REQUEST]('other_bucket')
		control.Pump(8)
		check('a marker in another routing bucket is refused',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'garages.wrongBucket')

		control.netEvents[garages.Event.REQUEST]('no_such_marker')
		control.Pump(8)
		check('a marker that does not exist is refused',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'garages.noSuchSpot')

		-- A character who owns nothing: the roster answers no rows for them.
		local pauper = 44
		load(pauper, 'citizen-penniless')
		env.source = pauper
		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('standing on a marker owning nothing creates nothing',
			#control.vehicleCreates == created)
		check('and says so rather than handing out a car',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'garages.nothingHere',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[3]))

		-- ── the window ────────────────────────────────────────────────────
		local spammer = 43
		load(spammer, 'citizen-garage')
		env.source = spammer
		local limit = OPX.Config.MODULES.garages.REQUESTS_PER_WINDOW
		for _ = 1, limit do
			control.netEvents[garages.Event.REQUEST]('garage_dock')
			control.Pump(6)
		end
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(6)
		check(('the request after %d in one window is rate-limited'):format(limit),
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'garages.rateLimited',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[3]))

		-- ── a capture the client never answers ────────────────────────────
		-- The one failure that used to be silent at both ends: the command asks
		-- for a facing, no answer ever comes, and neither half says anything -- so
		-- the operator walks away believing a spot was placed where there is none.
		-- Last in this section because it leaves a spot behind and moves `source`.
		local function asksFor(player)
			local asked = 0
			for index = 1, #control.clientEvents do
				local event = control.clientEvents[index]
				if event.name == garages.Event.CAPTURE and event.source == player then
					asked = asked + 1
				end
			end
			return asked
		end

		local quiet = 42
		load(quiet, 'citizen-garage-quiet')
		control.Allow(quiet, 'command.opx.garages.add')
		local warnsBefore, noticesBefore = #control.log.warn, #control.notices
		local logsBefore = #control.log.info
		local previousSource = env.source
		control.commands['opx.garages.add'].run(quiet, { 'garage', 'garage_never' })
		check('an unanswered capture is asked for exactly once', asksFor(quiet) == 1,
			asksFor(quiet))
		check('and the request is logged when it goes out',
			#control.log.info > logsBefore
				and control.log.info[#control.log.info]:find('garage_never', 1, true) ~= nil,
			control.log.info[#control.log.info])

		-- Young: the answer may still be on its way, so nothing is said yet.
		control.Pump(10)
		check('nothing is said while the answer may still come',
			#control.log.warn == warnsBefore and #control.notices == noticesBefore)

		-- Past its lifetime it settles itself, once -- not once per pump.
		control.Pump(80)
		control.Pump(80)
		check('a capture that is never answered is reported, once',
			#control.log.warn == warnsBefore + 1, #control.log.warn - warnsBefore)
		check('naming the spot and saying nothing was saved',
			control.log.warn[#control.log.warn] ~= nil
				and control.log.warn[#control.log.warn]:find('garage_never', 1, true) ~= nil
				and control.log.warn[#control.log.warn]:find('nothing was saved', 1, true) ~= nil,
			control.log.warn[#control.log.warn])
		local told = control.notices[#control.notices]
		check('and the operator is told in game, not only in the log',
			#control.notices == noticesBefore + 1 and told ~= nil and told.playerId == quiet
				and told.type == 'error',
			told and ('%s: %s'):format(tostring(told.type), tostring(told.message)))
		check('and no spot was placed by it', contract.Spots()['garage_never'] == nil)

		-- A late answer is still an answer. The request is gone, so the ordinary
		-- path runs and the spot lands: slowness is not a refusal, and a client
		-- that was still loading must not need the command run again.
		local lateWarns = #control.log.warn
		env.source = quiet
		control.netEvents[garages.Event.CAPTURED]('garage', 'garage_never', 'LATE', 12.0)
		control.Pump(8)
		control.Pump(40)
		check('an answer that arrives after the warning still lands',
			contract.Spots()['garage_never'] ~= nil)
		check('and it raises no second "did not answer"',
			#control.log.warn == lateWarns, #control.log.warn - lateWarns)

		-- An answer that is unusable is a different failure with its own line:
		-- the client DID answer, so "did not answer" would be a lie.
		local badWarns = #control.log.warn
		control.netEvents[garages.Event.CAPTURED]('not-a-kind', 'garage_bad', 'X', 0.0)
		check('an unusable answer is reported as one',
			#control.log.warn == badWarns + 1
				and control.log.warn[#control.log.warn]:find('unusable spot', 1, true) ~= nil,
			control.log.warn[#control.log.warn])
		env.source = previousSource
	end
end

-- ── the client half of the markers ───────────────────────────────────────────
-- The spots come from the server and never from the config, so everything below
-- arrives over `SYNC`. What is asserted is what the ENGINE was asked for: the
-- shape, the style, the radius and the distance, read back out of the host's
-- marker stub, which validates them the way `Markers.cpp` does.
section('garages, client side')
do
	local cenv, cctl, cwhy = boot('client')
	check('the client boots with the garages module', cwhy == nil, cwhy)

	if cwhy == nil then
		local OPX = cenv.OPX
		local garages = OPX.Modules.Get('garages')
		local Runtime = garages.Runtime
		local prompts = OPX.Api.Get('prompts')

		check('the client half is running, not just loaded', OPX.Modules.IsRunning('garages'),
			OPX.Modules.Record('garages').Reason)

		-- ── the key ───────────────────────────────────────────────────────
		local mapping = cctl.keyMappings.byId['opx.garages.use']
		check('the key is declared to the host, so a player can rebind it', mapping ~= nil)
		check('and defaults to E', mapping ~= nil and mapping.key == 'E',
			mapping and tostring(mapping.key))
		check('and the pause menu is given a name for it, not a key',
			mapping ~= nil and type(mapping.name) == 'string' and mapping.name ~= ''
				and mapping.name:find('key', 1, true) == nil, mapping and tostring(mapping.name))

		-- The list is asked for on start, so a marker already in range does not
		-- wait for the poll.
		local asked = false
		for index = 1, #cctl.clientToServer do
			if cctl.clientToServer[index].name == garages.Event.ASK then asked = true end
		end
		check('the client asks for its spots on start', asked)

		-- ── the markers ───────────────────────────────────────────────────
		cctl.netEvents[garages.Event.SYNC]({ spots = {
			{ key = 'garage_dock', label = 'THE DOCK', kind = 'garage',
				x = 0.0, y = 0.0, z = 0.0, heading = 90.0, bucket = 0 },
			{ key = 'pad_dock', label = 'THE PAD', kind = 'avpad',
				x = 6.0, y = 0.0, z = 2.0, heading = 0.0, bucket = 0 },
		} })
		cctl.Pump(6)

		local drawn = cenv.Open77.markers.list()
		check('one marker is drawn per spot in range', #drawn == 2, #drawn)

		local looks = {}
		for index = 1, #drawn do
			local options = cctl.markers.byId[drawn[index]]
			looks[options.position.x] = options
		end
		local garageMarker = looks[0.0]
		local padMarker = looks[6.0]
		check('the garage marker is the glowing cylinder on its spot',
			garageMarker ~= nil and garageMarker.shape == 'cylinder'
				and garageMarker.style == 'spawn' and garageMarker.radius == 2.5,
			garageMarker and ('%s/%s/%s'):format(tostring(garageMarker.shape),
				tostring(garageMarker.style), tostring(garageMarker.radius)))
		check('the pad marker is the glowing ring on its own spot',
			padMarker ~= nil and padMarker.shape == 'ring' and padMarker.style == 'objective'
				and padMarker.radius == 3.5,
			padMarker and ('%s/%s/%s'):format(tostring(padMarker.shape),
				tostring(padMarker.style), tostring(padMarker.radius)))
		-- The spot's OWN height, not the player's, and lifted by the look's own
		-- offset: a pad on a roof at 2.0 is drawn at 2.06, and one that was not
		-- lifted would be co-planar with that roof and invisible.
		local padLift = garages.Access.Marker('avpad').lift
		check('and its own height, not the player\'s, lifted clear of the surface',
			padMarker ~= nil and math.abs(padMarker.position.z - (2.0 + padLift)) < 1e-9,
			padMarker and tostring(padMarker.position.z))
		check('and the ground marker is lifted off the floor it stands on',
			garageMarker ~= nil
				and math.abs(garageMarker.position.z - garages.Access.Marker('garage').lift) < 1e-9,
			garageMarker and tostring(garageMarker.position.z))

		-- ── the strip row ─────────────────────────────────────────────────
		check('standing on a marker posts its row', Runtime.Report().nearest == 'garage_dock',
			Runtime.Report().nearest)
		local listed = prompts ~= nil and prompts.List('garages') or nil
		check('and the strip holds exactly one row for it',
			listed ~= nil and listed.ok == true and listed.value.count == 1
				and listed.value.prompts[1] == 'spot',
			listed and listed.ok and tostring(listed.value.count))
		check('and names the key it is bound to', Runtime.Report().key == 'E',
			Runtime.Report().key)

		-- ── the key sends the request ─────────────────────────────────────
		local before = #cctl.clientToServer
		mapping.pressed()
		local sent = cctl.clientToServer[#cctl.clientToServer]
		check('the key sends a request for the marker underfoot',
			#cctl.clientToServer == before + 1 and sent ~= nil
				and sent.name == garages.Event.REQUEST and sent[1] == 'garage_dock',
			sent and tostring(sent[1]))

		-- A keyboard held elsewhere is not a key: a row that stayed up while
		-- somebody typed would fire as they typed.
		cctl.input.captured = true
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('garages') or nil
			return row ~= nil and row.ok == true and row.value.count == 0
		end)
		listed = prompts ~= nil and prompts.List('garages') or nil
		check('the row steps aside while another surface holds the keyboard',
			listed ~= nil and listed.ok == true and listed.value.count == 0,
			listed and listed.ok and tostring(listed.value.count))
		local mark = #cctl.clientToServer
		mapping.pressed()
		check('and the key does nothing while it does', #cctl.clientToServer == mark)
		cctl.input.captured = false
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('garages') or nil
			return row ~= nil and row.ok == true and row.value.count == 1
		end)

		-- ── the capture round-trip ────────────────────────────────────────
		mark = #cctl.clientToServer
		local infoMark = #cctl.log.info
		cctl.netEvents[garages.Event.CAPTURE]('avpad', 'pad_dock', 'THE PAD')
		local answered = cctl.clientToServer[#cctl.clientToServer]
		check('the client answers a capture ask', #cctl.clientToServer > mark)
		check('with the operator\'s own facing, which only this half can read',
			answered ~= nil and answered.name == garages.Event.CAPTURED
				and answered[1] == 'avpad' and answered[2] == 'pad_dock')
		-- Both ends of the round trip say their half, so a capture that dies in
		-- the middle is a hole in a log rather than silence from everywhere.
		check('and names the spot it answered, so the round trip reads from here',
			#cctl.log.info > infoMark
				and cctl.log.info[#cctl.log.info]:find('pad_dock', 1, true) ~= nil,
			cctl.log.info[#cctl.log.info])

		-- ── taking them down ──────────────────────────────────────────────
		cctl.netEvents[garages.Event.SYNC]({ spots = {} })
		cctl.Pump(6)
		check('a list the server clears takes every marker with it',
			#cenv.Open77.markers.list() == 0, #cenv.Open77.markers.list())
		listed = prompts ~= nil and prompts.List('garages') or nil
		check('and the row comes down with it',
			listed ~= nil and listed.ok == true and listed.value.count == 0)

		-- A MARKER THE ENGINE REFUSES. It must be one logged line and no marker,
		-- rather than a raise inside the scan or a marker nobody can see.
		local warned = #cctl.log.warn
		cctl.markers.refuse = 'unsupported_style'
		cctl.netEvents[garages.Event.SYNC]({ spots = {
			{ key = 'garage_dock', label = 'THE DOCK', kind = 'garage',
				x = 0.0, y = 0.0, z = 0.0, heading = 0.0, bucket = 0 },
		} })
		cctl.Pump(6)
		check('a refused marker is not drawn', #cenv.Open77.markers.list() == 0)
		check('and it is said once, in the log', #cctl.log.warn > warned
			and table.concat(cctl.log.warn, ' | '):find('no marker is drawn', 1, true) ~= nil,
			table.concat(cctl.log.warn, ' | '))
		cctl.markers.refuse = nil

		-- A SPOT THE CLIENT CANNOT READ is dropped and named, never taken as a
		-- marker at 0,0,0 -- which is the failure a NaN or a bad kind would give.
		cctl.netEvents[garages.Event.SYNC]({ spots = {
			{ key = 'broken', label = 'BROKEN', kind = 'garage', x = 0 / 0, y = 0.0, z = 0.0 },
		} })
		cctl.Pump(6)
		check('a spot the client cannot read is dropped, not placed at the origin',
			#cenv.Open77.markers.list() == 0 and Runtime.Report().spots == 0,
			('%d drawn, %d held'):format(#cenv.Open77.markers.list(), Runtime.Report().spots))

		-- ── the local refusal ─────────────────────────────────────────────
		-- No marker underfoot: refused locally, and nothing leaves the client.
		local decisions = {}
		cenv.AddEventHandler(garages.Event.ON_DECISION, function(payload)
			decisions[#decisions + 1] = payload
		end)
		mark = #cctl.clientToServer
		local answer = Runtime.Use('test')
		check('using a marker nobody is standing on answers no spot',
			answer.ok == false and answer.error == 'garages.noSuchSpot')
		check('and nothing is sent', #cctl.clientToServer == mark)
		check('and the verdict is published on the local bus',
			#decisions == 1 and decisions[1].error == 'garages.noSuchSpot')
	end
end

section('dealerships')
do
	-- The bridge both real storage modules run against: the vehicle rows that
	-- already exist, every dealership row written, and every vehicle row a
	-- purchase creates. The SQL is the shipped storage's -- only the answers are
	-- a fixture's.
	local function bridge(rows, vehiclesWritten, dealersWritten)
		return Host.Database({
			scalar = function() return 1 end,
			update = function(sql, params)
				if sql:find('INSERT INTO opx77_vehicles', 1, true) then
					vehiclesWritten[#vehiclesWritten + 1] = params
					-- The row that was just written, in the column shape the
					-- storage reads back, so the hand-over can fetch it by plate.
					rows[#rows + 1] = {
						plate = params.plate, citizen_id = params.citizen,
						record = params.record, appearance = params.appearance,
						garage = params.garage, state = params.state,
						health = params.health, body = params.body,
						paint = params.paint, metadata = params.metadata or '{}',
					}
				elseif sql:find('opx77_dealerships', 1, true) then
					dealersWritten[#dealersWritten + 1] = params
				end
				return 0
			end,
			query = function(sql, params)
				if sql:find('opx77_vehicles', 1, true) then
					local citizen = type(params) == 'table' and params.citizen or nil
					local mine = {}
					for index = 1, #rows do
						if citizen == nil or rows[index].citizen_id == citizen then
							mine[#mine + 1] = rows[index]
						end
					end
					return mine
				end
				return {}
			end,
			-- The two `single` reads a purchase makes: the ceiling behind the
			-- registration, and the one row a hand-over fetches by plate. The
			-- COUNT is matched PLAINLY: `(%*)` is a Lua capture around a literal
			-- `*`, which matches "COUNT*" and never "COUNT(*)", so the ceiling
			-- would answer zero for every character.
			single = function(sql, params)
				if sql:find('COUNT(*)', 1, true) ~= nil then return { total = #rows } end
				local plate = type(params) == 'table' and params.plate or nil
				if plate ~= nil then
					for index = 1, #rows do
						if rows[index].plate == plate then return rows[index] end
					end
				end
				return nil
			end,
		})
	end

	local rows, vehiclesWritten, dealersWritten = {}, {}, {}
	local env, control, why = boot('server', bridge(rows, vehiclesWritten, dealersWritten))
	check('the server boots with the dealership module', why == nil, why)

	-- The last client event with one name, or nil. Every verdict below is read
	-- off the wire, because the wire is what the player's client actually reads.
	local function lastEvent(name)
		for index = #control.clientEvents, 1, -1 do
			if control.clientEvents[index].name == name then return control.clientEvents[index] end
		end
		return nil
	end

	-- The last COMMAND answer whose text carries a needle, or nil. A command
	-- answers through `OPX.CommandResult`, which is a client event; the author
	-- field is what tells it apart from a toast about the same words.
	local function lastAnswer(needle)
		for index = #control.clientEvents, 1, -1 do
			local payload = control.clientEvents[index][1]
			if type(payload) == 'table' and payload.author ~= nil
				and type(payload.text) == 'string'
				and payload.text:find(needle, 1, true) ~= nil then
				return payload
			end
		end
		return nil
	end

	-- Whether any line in a list of strings carries a needle.
	local function names(lines, needle)
		for index = 1, #lines do
			if tostring(lines[index]):find(needle, 1, true) ~= nil then return true end
		end
		return false
	end

	if why == nil then
		local OPX = env.OPX
		local dealership = OPX.Modules.Get('dealership')
		local Access = dealership.Access
		local contract = OPX.Api.Get('dealership')
		local vehicles = OPX.Api.Get('vehicles')
		-- The vehicles module's own settings: where a row with no named garage
		-- goes, and how many one character may own. Read through the config it
		-- was declared in, which is the same table the module reads.
		local vehicleConfig = OPX.Config.MODULES.vehicles
		local garages = OPX.Api.Get('garages')
		local garageAccess = OPX.Modules.Get('garages').Access
		local character = OPX.Modules.Get('character')
		local Config = OPX.Config.MODULES.dealership

		check('the dealership module is running', OPX.Modules.IsRunning('dealership'),
			OPX.Modules.Record('dealership').Reason)
		check('and publishes its half of the contract',
			contract ~= nil and type(contract.Buy) == 'function'
				and type(contract.Spots) == 'function' and type(contract.Stock) == 'function'
				and type(contract.State) == 'function')
		check('the shipped config reports no problems', #Access.Problems() == 0,
			table.concat(Access.Problems(), ' | '))

		-- ── the catalogue ──────────────────────────────────────────────────
		-- WHAT A KINDS OF DEALER SELLS is one rule and it is derived: a ground
		-- dealer sells every row whose record is not an AV, a pad sells every row
		-- whose record is, and no row is for sale twice.
		local ground, air = Access.For(dealership.KIND.GARAGE), Access.For(dealership.KIND.AVPAD)
		check('the stock list is not empty at either kind of dealer',
			#ground > 0 and #air > 0, ('%d and %d'):format(#ground, #air))

		local onlyGround, onlyAir = true, true
		for index = 1, #ground do
			if ground[index].av then onlyGround = false end
		end
		for index = 1, #air do
			if not air[index].av then onlyAir = false end
		end
		check('a garage dealer sells only ground vehicles', onlyGround)
		check('and a pad sells only AVs', onlyAir)

		local total = 0
		for _ in pairs(Access.STOCK) do total = total + 1 end
		check('every row is for sale at exactly one kind of dealer', #ground + #air == total,
			('%d + %d vs %d rows'):format(#ground, #air, total))

		check('an AV record is an AV', Access.IsAv('Vehicle.av_militech_manticore') == true)
		check('a max-tac AV record is an AV', Access.IsAv('Vehicle.max_tac_av') == true)
		check('a ground car is not', Access.IsAv('Vehicle.v_standard2_archer_hella_player') == false)
		check('and neither is nothing at all', Access.IsAv(nil) == false)
		check('case is not the caller\'s problem', Access.IsAv('VEHICLE.AV_RAYFIELD_EXCALIBUR') == true)

		-- A ROW IS REFUSED WHOLE, never repaired: the catalogue is read once, so
		-- a row the operator priced at nothing is a row nobody sells rather than
		-- a car given away.
		local shippedStock = Config.STOCK
		Config.STOCK = {
			{ KEY = 'free', LABEL = 'FREE CAR', CLASS = 'Street',
				RECORD = 'Vehicle.v_standard2_archer_hella_player', PRICE = 0 },
			{ KEY = 'twice', LABEL = 'ONE', CLASS = 'Street', RECORD = 'Vehicle.a', PRICE = 10 },
			{ KEY = 'twice', LABEL = 'TWO', CLASS = 'Street', RECORD = 'Vehicle.b', PRICE = 10 },
			{ KEY = 'nameless', LABEL = '', CLASS = 'Street', RECORD = 'Vehicle.c', PRICE = 10 },
			{ KEY = 'recordless', LABEL = 'NO RECORD', CLASS = 'Street', RECORD = '', PRICE = 10 },
		}
		local problems = Access.Problems()
		check('a row priced at nothing is refused, not honoured',
			names(problems, 'PRICE must be a whole number above zero'))
		check('a key declared twice is refused', names(problems, 'is declared twice'))
		check('a row with no label is refused', names(problems, 'LABEL must be a string'))
		check('a row with no TweakDB record is refused',
			names(problems, 'RECORD must be a TweakDB record name'))
		check('and the catalogue that is sold is the shipped one, untouched',
			Access.Entry('free') == nil and Access.Entry('hella') ~= nil)
		Config.STOCK = shippedStock
		check('putting the shipped list back clears every one of them', #Access.Problems() == 0,
			table.concat(Access.Problems(), ' | '))

		-- ── the marker vocabulary ──────────────────────────────────────────
		local garageLook = Access.Marker('garage')
		check('a dealer marker is the glowing cylinder',
			garageLook.shape == 'cylinder' and garageLook.style == 'interaction'
				and garageLook.radius == 2.5,
			('%s/%s/%s'):format(tostring(garageLook.shape), tostring(garageLook.style),
				tostring(garageLook.radius)))
		local padLook = Access.Marker('avpad')
		check('a pad marker is the glowing ring',
			padLook.shape == 'ring' and padLook.style == 'interaction' and padLook.radius == 3.5,
			('%s/%s/%s'):format(tostring(padLook.shape), tostring(padLook.style),
				tostring(padLook.radius)))
		-- A ring is the marker mesh flattened to 0.04 m: left on the floor it is
		-- co-planar with it and draws nothing at all.
		check('both markers are lifted off the floor', garageLook.lift == 0.06 and padLook.lift == 0.06,
			('%s/%s'):format(tostring(garageLook.lift), tostring(padLook.lift)))

		local shippedOffset = Config.GROUND_OFFSET
		Config.GROUND_OFFSET = 0.0
		check('a lift of zero is a choice and not a mistake', Access.Marker('avpad').lift == 0.0)
		Config.GROUND_OFFSET = 9000.0
		check('an unbounded lift is clamped to the default, not carried to the engine',
			Access.Marker('avpad').lift == 0.06)
		check('and a lift the config got wrong is reported at boot',
			names(Access.Problems(), 'GROUND_OFFSET must be a finite number'))
		Config.GROUND_OFFSET = shippedOffset

		local shippedStyle = Config.MARKER.garage.style
		Config.MARKER.garage.style = 'glow'
		check('a style the engine does not have falls back rather than being sent',
			Access.Marker('garage').style == 'spawn')
		Config.MARKER.garage.style = shippedStyle

		local shippedDistance = Config.MAX_DISTANCE
		Config.MAX_DISTANCE = 9000.0
		check('a draw distance the engine would refuse is clamped to its ceiling',
			Access.MaxDistance() == 150.0)
		Config.MAX_DISTANCE = shippedDistance

		-- ── what a dealer has to be ────────────────────────────────────────
		local good = Access.FromWire({ key = 'x', kind = 'garage', x = 0.0, y = 0.0, z = 0.0 })
		check('a dealer off the wire is accepted',
			good ~= nil and good.heading == 0.0 and good.bucket == 0)
		check('and takes its key as its label when it has none', good ~= nil and good.label == 'x')
		check('an unknown kind is refused',
			Access.FromWire({ key = 'x', kind = 'garage2', x = 0.0, y = 0.0, z = 0.0 }) == nil)
		check('a NaN coordinate is refused, not carried to the engine',
			Access.FromWire({ key = 'x', kind = 'garage', x = 0 / 0, y = 0.0, z = 0.0 }) == nil)
		check('an over-long key is refused',
			Access.FromWire({ key = string.rep('k', 200), kind = 'garage', x = 0.0, y = 0.0, z = 0.0 })
				== nil)

		local spots = {
			left = Access.FromDefinition('left', { KIND = 'garage', X = 3.0, Y = 0.0, Z = 0.0 }),
			right = Access.FromDefinition('right', { KIND = 'garage', X = -3.0, Y = 0.0, Z = 0.0 }),
			far = Access.FromDefinition('far', { KIND = 'garage', X = 100.0, Y = 0.0, Z = 0.0 }),
		}
		local nearest = Access.Nearest(spots, 0.0, 0.0)
		check('two dealers a metre apart are decided by name, not by pairs order',
			nearest ~= nil and nearest.key == 'left', nearest and nearest.key)
		check('a radius the caller names is what is measured against',
			select(1, Access.Nearest(spots, 0.0, 0.0, 4.0)) == nil)
		check('a dealer beyond the radius is not offered',
			select(1, Access.Nearest({ far = spots.far }, 0.0, 0.0)) == nil)

		-- ── the doors ─────────────────────────────────────────────────────
		check('the placement commands are registered and ACL-gated',
			control.commands[Config.COMMANDS.add] ~= nil
				and control.commands[Config.COMMANDS.add].restricted == true
				and control.commands[Config.COMMANDS.remove].restricted == true
				and control.commands[Config.COMMANDS.list].restricted == true)
		check('and buying and reading the stock are open, because they act on the caller',
			control.commands[Config.COMMANDS.buy] ~= nil
				and control.commands[Config.COMMANDS.buy].restricted == false
				and control.commands[Config.COMMANDS.stock] ~= nil
				and control.commands[Config.COMMANDS.stock].restricted == false)
		check('and the capture routeway exists for the ask to come back on',
			type(control.netEvents[dealership.Event.CAPTURED]) == 'function'
				and type(control.netEvents[dealership.Event.BUY]) == 'function')

		-- ── the fixture's dealers ──────────────────────────────────────────
		-- `Access.SPOTS` IS the list the server half reads as its configuration
		-- (`M.Init` takes that table, not a copy), so writing here is what an
		-- operator checking a dealer in does. A capture below re-merges config
		-- with captured, which is what puts them in the world.
		Access.SPOTS['yard'] = Access.FromDefinition('yard', {
			KIND = 'garage', LABEL = 'UPTOWN YARD', X = 1.0, Y = 1.0, Z = 5.0,
			HEADING = 90.0, BUCKET = 0,
		})
		Access.SPOTS['pad'] = Access.FromDefinition('pad', {
			KIND = 'avpad', LABEL = 'UPTOWN PAD', X = 1.0, Y = 1.0, Z = 5.0,
			HEADING = 0.0, BUCKET = 0,
		})
		Access.SPOTS['far_yard'] = Access.FromDefinition('far_yard', {
			KIND = 'garage', LABEL = 'FAR YARD', X = 100.0, Y = 0.0, Z = 0.0,
			HEADING = 0.0, BUCKET = 0,
		})
		Access.SPOTS['other_yard'] = Access.FromDefinition('other_yard', {
			KIND = 'garage', LABEL = 'OTHER YARD', X = 1.0, Y = 1.0, Z = 0.0,
			HEADING = 0.0, BUCKET = 3,
		})

		-- ── the capture round-trip ─────────────────────────────────────────
		-- A loaded Player, in the shape the character contract reads: the data it
		-- owns, and the method it calls on every balance change.
		local function load(id, citizenId, eddies)
			control.Admit(id, 'account-' .. tostring(id))
			OPX.EnsureSession(id)
			character.Players[id] = {
				PlayerData = { citizenId = citizenId, source = id,
					money = { EDDIES = eddies or 0 } },
				Functions = { UpdatePlayerData = function() end },
			}
			return character.Players[id]
		end

		local src = 71
		load(src, 'citizen-dealer', 2000000)

		-- A command asks the CLIENT where it is looking, because a chat command
		-- has no facing of its own -- and the heading only turns a vehicle that
		-- is handed over where it was bought.
		local mark = #control.clientEvents
		control.commands[Config.COMMANDS.add].run(src, { 'garage', 'dealer_dock' })
		local asked = lastEvent(dealership.Event.CAPTURE)
		check('the add command asks the client for its facing',
			asked ~= nil and #control.clientEvents > mark and asked.source == src)
		check('naming the kind and the key it was given',
			asked ~= nil and asked[1] == 'garage' and asked[2] == 'dealer_dock',
			asked and ('%s/%s'):format(tostring(asked[1]), tostring(asked[2])))

		-- The bare form the config file advertises, with the key and the kind
		-- both optional -- and the first word is the KIND when it is one.
		control.commands[Config.COMMANDS.add].run(src, {})
		local bare = lastEvent(dealership.Event.CAPTURE)
		check('the bare add command asks as a garage, under a key it generated',
			bare ~= nil and bare[1] == 'garage' and bare[2] == 'garage1',
			bare and ('%s/%s'):format(tostring(bare[1]), tostring(bare[2])))
		control.commands[Config.COMMANDS.add].run(src, { 'avpad' })
		local padAsk = lastEvent(dealership.Event.CAPTURE)
		check('and a bare AV pad add is an avpad with its own generated key',
			padAsk ~= nil and padAsk[1] == 'avpad' and padAsk[2] == 'avpad1',
			padAsk and ('%s/%s'):format(tostring(padAsk[1]), tostring(padAsk[2])))
		control.commands[Config.COMMANDS.add].run(src, { 'watson', 'WATSON AUTOS' })
		local named = lastEvent(dealership.Event.CAPTURE)
		check('and a first word that is not a kind is the key itself',
			named ~= nil and named[1] == 'garage' and named[2] == 'watson'
				and named[3] == 'WATSON AUTOS',
			named and ('%s/%s/%s'):format(tostring(named[1]), tostring(named[2]),
				tostring(named[3])))

		-- A key longer than the column is refused BEFORE the client is asked: a
		-- capture that could never be saved must not move the operator's marker.
		local lastAsk = lastEvent(dealership.Event.CAPTURE)
		control.commands[Config.COMMANDS.add].run(src, { 'garage', string.rep('k', Access.MAX_KEY + 1) })
		check('a key longer than the column is refused before the client is asked',
			lastEvent(dealership.Event.CAPTURE) == lastAsk)
		check('and the refusal says what a key may be', lastAnswer('a key is 1 to') ~= nil)

		-- A CLIENT THAT FIRES THE ROUTEWAY ITSELF. The net event has no host-side
		-- ACL check -- that gate runs for commands only -- so the module asks the
		-- same question here. Without it, anybody could place dealers.
		env.source = src
		local before = #control.clientEvents
		control.netEvents[dealership.Event.CAPTURED]('garage', 'sneaky', 'SNEAKY', 0.0)
		local denied = control.clientEvents[#control.clientEvents]
		check('a capture from someone without the permission is refused',
			#control.clientEvents > before and denied ~= nil and denied[1] ~= nil
				and denied[1].code == 'error.noPermission',
			denied and denied[1] and tostring(denied[1].code))
		check('and the refusal names the operation, so a client can tell it apart',
			denied ~= nil and denied[1] ~= nil
				and denied[1].operation == dealership.Operation.CAPTURE)
		check('and nothing was placed', contract.Spots()['sneaky'] == nil)
		check('and nothing was written', #dealersWritten == 0)

		-- With the permission, the same routeway lands a dealer -- at the
		-- position the SERVER read and the heading the client gave.
		control.Allow(src, 'command.' .. Config.COMMANDS.add)
		control.netEvents[dealership.Event.CAPTURED]('garage', 'dealer_dock', 'THE DOCKS', 90.0)
		control.Pump(8)
		local held = contract.Spots()
		check('a permitted capture lands', held['dealer_dock'] ~= nil)
		check('at the position the SERVER read and the heading the client gave',
			held['dealer_dock'] ~= nil and held['dealer_dock'].x == 0.0
				and held['dealer_dock'].y == 0.0 and held['dealer_dock'].z == 0.0
				and held['dealer_dock'].heading == 90.0,
			held['dealer_dock'] and ('%s,%s,%s yaw %s'):format(held['dealer_dock'].x,
				held['dealer_dock'].y, held['dealer_dock'].z, tostring(held['dealer_dock'].heading)))
		check('and its label is the operator\'s own words', held['dealer_dock'].label == 'THE DOCKS')
		check('and the row was written through the bridge', #dealersWritten == 1, #dealersWritten)
		check('and the fixture\'s checked-in dealers are in the merged list too',
			held['yard'] ~= nil and held['pad'] ~= nil and held['far_yard'] ~= nil)
		-- Told what is there NOW, and only what is in the player's own routing
		-- bucket: the dealer parked on bucket 3 is not in a bucket-0 client's list.
		local synced = lastEvent(dealership.Event.SYNC)
		local found, inBucket = {}, true
		for index = 1, type(synced) == 'table' and #synced[1].spots or 0 do
			found[synced[1].spots[index].key] = true
		end
		for index = 1, type(synced) == 'table' and #synced[1].spots or 0 do
			if synced[1].spots[index].bucket ~= 0 then inBucket = false end
		end
		check('and the client was told what is there now',
			synced ~= nil and type(synced[1]) == 'table' and type(synced[1].spots) == 'table'
				and found['dealer_dock'] == true and found['yard'] == true,
			synced and synced[1] and tostring(#synced[1].spots))
		check('and only what is in the player\'s own routing bucket',
			found['other_yard'] == nil and inBucket,
			('%d spot(s), other bucket present: %s'):format(
				type(synced) == 'table' and #synced[1].spots or 0,
				tostring(found['other_yard'] ~= nil)))

		-- ── what the server will not sell ─────────────────────────────────
		local function refused(dealerKey, entryKey, destKey)
			local answer = contract.Buy(src, dealerKey, entryKey, destKey)
			return answer.ok == false and answer.error or ('sold:' .. tostring(answer.ok))
		end

		check('a model nobody sells is refused',
			refused('yard', 'flying_carpet') == 'dealership.noSuchEntry', refused('yard', 'flying_carpet'))
		check('a dealer that does not exist is refused',
			refused('ghost_yard', 'hella') == 'dealership.noSuchSpot')
		check('a dealer out of reach is refused',
			refused('far_yard', 'hella') == 'dealership.tooFar')
		check('a dealer in another routing bucket is refused',
			refused('other_yard', 'hella') == 'dealership.wrongBucket')
		check('a ground car is refused at an AV pad',
			refused('pad', 'hella') == 'dealership.notSold')
		check('and an AV is refused at a garage dealer',
			refused('yard', 'manticore') == 'dealership.notSold')
		check('a destination that is not a garage is refused',
			refused('yard', 'hella', 'pad') == 'dealership.noSuchGarage')
		check('a connection with no character cannot buy',
			contract.Buy(999, 'yard', 'hella', nil).error == 'dealership.noCharacter')
		local written = #vehiclesWritten
		character.Players[src].PlayerData.money.EDDIES = 10
		check('a purchase beyond the balance is refused before anything is charged',
			refused('yard', 'hella') == 'dealership.cannotAfford')
		check('and nothing was registered for any of those refusals',
			#vehiclesWritten == written, #vehiclesWritten)

		-- ── the purchase ───────────────────────────────────────────────────
		local hella = Access.Entry('hella')
		character.Players[src].PlayerData.money.EDDIES = 2000000
		local balance = character.Players[src].PlayerData.money.EDDIES
		local bought = contract.Buy(src, 'yard', 'hella', nil)
		check('a purchase the server can prove goes through', bought.ok == true,
			bought and tostring(bought.error))
		check('and the price is charged, to the unit',
			character.Players[src].PlayerData.money.EDDIES == balance - hella.price,
			('%s then %s'):format(tostring(balance), tostring(hella.price)))
		check('and one row is registered through the vehicles contract',
			#vehiclesWritten == written + 1)
		check('under the model that was bought',
			vehiclesWritten[#vehiclesWritten].record == hella.record)
		check('and filed in the garage the vehicles module defaults to when nobody chose one',
			vehiclesWritten[#vehiclesWritten].garage == vehicleConfig.DEFAULT_GARAGE,
			vehiclesWritten[#vehiclesWritten].garage)
		check('and the buyer is told the plate it was given',
			bought.value ~= nil and type(bought.value.plate) == 'string'
				and bought.value.plate ~= '')

		-- ON the marker at its own height: `yard` is at 1,1,5 and the player is
		-- at 0,0,0, so a hand-over that followed the player instead of the dealer
		-- would read 0,0 here.
		local handOver = control.vehicleCreates[#control.vehicleCreates]
		check('the vehicle is handed over ON the dealer, not beside the player',
			handOver ~= nil and handOver.position.x == 1.0 and handOver.position.y == 1.0
				and handOver.position.z == 5.0,
			handOver and ('%s,%s,%s'):format(handOver.position.x, handOver.position.y,
				handOver.position.z))
		check('facing the heading the dealer carries',
			handOver ~= nil and handOver.yaw == 90.0, handOver and tostring(handOver.yaw))

		-- ── the destination the buyer chose ────────────────────────────────
		-- Read from the GARAGES contract, which is the only owner of where a
		-- garage is: nothing here keeps a copy.
		local listed = garages.Spots()
		listed['garage_dock'] = garageAccess.FromDefinition('garage_dock', {
			KIND = 'garage', LABEL = 'THE DOCK', X = 1.0, Y = 1.0, Z = 5.0,
			HEADING = 0.0, BUCKET = 0,
		})
		listed['pad_dock'] = garageAccess.FromDefinition('pad_dock', {
			KIND = 'avpad', LABEL = 'THE PAD', X = 1.0, Y = 1.0, Z = 5.0,
			HEADING = 0.0, BUCKET = 0,
		})

		local delivered = contract.Buy(src, 'yard', 'quartz', 'garage_dock')
		check('a purchase may name the garage it is delivered to',
			delivered.ok == true and delivered.value.garage == 'garage_dock',
			delivered and tostring(delivered.error))
		check('and the row is filed under that garage',
			vehiclesWritten[#vehiclesWritten].garage == 'garage_dock',
			vehiclesWritten[#vehiclesWritten].garage)
		check('and a destination of the wrong category is refused rather than redirected',
			refused('yard', 'hella', 'pad_dock') == 'dealership.noSuchGarage')

		-- ── an AV, which is lifted off the pad it stands on ────────────────
		local manticore = Access.Entry('manticore')
		character.Players[src].PlayerData.money.EDDIES = 2000000
		local avBuy = contract.Buy(src, 'pad', 'manticore', nil)
		check('an AV is sold at a pad', avBuy.ok == true, avBuy and tostring(avBuy.error))
		handOver = control.vehicleCreates[#control.vehicleCreates]
		check('and it is handed over LIFTED clear of the pad\'s own floor',
			handOver ~= nil and handOver.position.z == 5.0 + Access.AvLift(),
			handOver and tostring(handOver.position.z))
		check('and the AV\'s price is the AV row\'s, not a car\'s',
			character.Players[src].PlayerData.money.EDDIES == 2000000 - manticore.price)

		-- ── the half that can be undone ────────────────────────────────────
		-- A registration the ownership half refuses AFTER the money moved. The
		-- ceiling is the same refusal a real server produces, with the row count
		-- already at it.
		local shippedCeiling = vehicleConfig.PER_CHARACTER
		-- Three rows are already owned, so a ceiling of one is the refusal a real
		-- ceiling produces.
		vehicleConfig.PER_CHARACTER = 1
		local warnMark = #control.log.warn
		balance = 500000
		character.Players[src].PlayerData.money.EDDIES = balance
		written = #vehiclesWritten
		local unpaid = contract.Buy(src, 'yard', 'hella', nil)
		check('a registration the ownership half refuses is refused to the buyer',
			unpaid.ok == false and unpaid.error == 'vehicle.limit', tostring(unpaid.error))
		check('and the money does not stay taken',
			character.Players[src].PlayerData.money.EDDIES == balance,
			tostring(character.Players[src].PlayerData.money.EDDIES))
		check('and nothing was written for it', #vehiclesWritten == written)
		check('and the refund is said out loud, with what was bought and refused',
			#control.log.warn > warnMark and names(control.log.warn, 'refunded'),
			table.concat(control.log.warn, ' | '))
		vehicleConfig.PER_CHARACTER = shippedCeiling

		-- ── a throw is a refusal, not a disappearance ──────────────────────
		-- The row is written by another module, and a throw in there used to
		-- unwind the purchase past its own refund -- which is how a player was
		-- charged twice and owned nothing. The call is guarded now, so a throw
		-- takes the same path as any other refusal: nothing written, the money
		-- back, and the message kept. The contract table is the very one the
		-- module holds, so this is the real call site being exercised.
		local vehiclesApi = env.OPX.Api.Get('vehicles')
		local realRegister = vehiclesApi ~= nil and vehiclesApi.Register or nil
		if vehiclesApi ~= nil then
			vehiclesApi.Register = function() error('the store threw') end
		end
		local throwMark = #control.log.error
		balance = 500000
		character.Players[src].PlayerData.money.EDDIES = balance
		written = #vehiclesWritten
		local blewUp = contract.Buy(src, 'yard', 'hella', nil)
		check('a throw inside the vehicle store is refused to the buyer',
			blewUp.ok == false and blewUp.error == 'dealership.registerFailed',
			blewUp and tostring(blewUp.error))
		check('and the money goes back rather than nowhere',
			character.Players[src].PlayerData.money.EDDIES == balance,
			tostring(character.Players[src].PlayerData.money.EDDIES))
		check('and nothing was written for it', #vehiclesWritten == written)
		check('and the throw is in the log, with the module and the reason',
			#control.log.error > throwMark and names(control.log.error, 'threw')
				and names(control.log.error, 'the store threw'),
			table.concat(control.log.error, ' | '):sub(-200))
		if vehiclesApi ~= nil then vehiclesApi.Register = realRegister end

		-- ── the wire ───────────────────────────────────────────────────────
		local wireBalance = character.Players[src].PlayerData.money.EDDIES
		mark = #control.clientEvents
		control.netEvents[dealership.Event.BUY]('yard', 'hella', nil)
		control.Pump(8)
		local answer = lastEvent(dealership.Event.ANSWER)
		check('a purchase asked for over the wire is answered either way',
			answer ~= nil and #control.clientEvents > mark and answer.source == src)
		-- The wire is (ok, failure, entry, value): the failure slot is nil on a
		-- success, so the value is the FOURTH argument.
		check('and the answer carries the plate the buyer gets',
			answer ~= nil and answer[1] == true and answer[3] == 'hella'
				and type(answer[4]) == 'table' and answer[4].plate ~= nil,
			answer and ('%s/%s'):format(tostring(answer[1]), tostring(answer[3])))

		before = #control.clientEvents
		control.netEvents[dealership.Event.BUY]('yard', 'hella', nil)
		local cooling = control.clientEvents[#control.clientEvents]
		check('a second purchase in the same breath is refused as too fast',
			#control.clientEvents > before and cooling ~= nil and cooling[1] ~= nil
				and cooling[1].code == 'error.tooFast',
			cooling and cooling[1] and tostring(cooling[1].code))
		check('and nothing was charged for it',
			character.Players[src].PlayerData.money.EDDIES == wireBalance - hella.price,
			tostring(character.Players[src].PlayerData.money.EDDIES))

		-- ── the commands an operator reads ─────────────────────────────────
		control.commands[Config.COMMANDS.stock].run(src, {})
		local stockAnswer = lastAnswer('row(s)')		check('the stock command lists what is for sale and which dealer sells it',
			stockAnswer ~= nil and stockAnswer.text:find('hella', 1, true) ~= nil
				and stockAnswer.text:find('avpad', 1, true) ~= nil,
			stockAnswer and stockAnswer.text:sub(1, 60))

		-- A dealer that comes from the config file: `list` says which is which,
		-- and `remove` will not take it out of the world.
		control.commands[Config.COMMANDS.list].run(src, {})
		local listAnswer = lastAnswer('dealer(s)')
		check('the list command names every dealer and where it comes from',
			listAnswer ~= nil and listAnswer.text:find('dealer_dock', 1, true) ~= nil
				and listAnswer.text:find('yard', 1, true) ~= nil
				and listAnswer.text:find('captured', 1, true) ~= nil
				and listAnswer.text:find('config', 1, true) ~= nil,
			listAnswer and listAnswer.text:sub(1, 60))

		control.commands[Config.COMMANDS.remove].run(src, { 'yard' })
		check('a configured dealer is refused removal, and says where it lives',
			lastAnswer('config/dealership.lua') ~= nil)
		check('and it is still standing', contract.Spots()['yard'] ~= nil)

		control.commands[Config.COMMANDS.remove].run(src, { 'ghost' })
		check('removing a dealer nobody placed says there was none',
			lastAnswer('no captured dealer named ghost') ~= nil)

		local dealerMark = #dealersWritten
		control.commands[Config.COMMANDS.remove].run(src, { 'dealer_dock' })
		control.Pump(8)
		check('a captured dealer can be removed', #dealersWritten > dealerMark
			and contract.Spots()['dealer_dock'] == nil)
		synced = lastEvent(dealership.Event.SYNC)
		found = {}
		for index = 1, type(synced) == 'table' and #synced[1].spots or 0 do
			found[synced[1].spots[index].key] = true
		end
		check('and every client is told what is left',
			synced ~= nil and found['dealer_dock'] == nil and found['yard'] == true,
			synced and ('%d spot(s)'):format(#synced[1].spots))

		-- A PURCHASE FROM A DEALER THAT IS GONE is refused rather than answered
		-- from a stale list.
		check('and buying at the removed dealer is refused',
			refused('dealer_dock', 'hella') == 'dealership.noSuchSpot')
	end
end

section('dealership, client side')
do
	local cenv, cctl, cwhy = boot('client')
	check('the client boots with the dealership module', cwhy == nil, cwhy)

	if cwhy == nil then
		local OPX = cenv.OPX
		local dealership = OPX.Modules.Get('dealership')
		local garages = OPX.Modules.Get('garages')
		local Runtime = dealership.Runtime
		local Access = dealership.Access
		local prompts = OPX.Api.Get('prompts')
		local page = cctl.pages[1]

		-- The last payload a channel was sent, or nil.
		local function lastDrawn(channel)
			for index = #page.sent, 1, -1 do
				if page.sent[index].channel == channel then return page.sent[index] end
			end
			return nil
		end

		-- The last toast whose message carries a needle, or nil. The menu raises a
		-- caller's status as a toast rather than a line under the list, and the
		-- price is what a buyer is told when the delivery screen opens.
		local function lastToast(needle)
			for index = #page.sent, 1, -1 do
				local sent = page.sent[index]
				if sent.channel == 'opx:notify:show' and type(sent.payload) == 'table'
					and type(sent.payload.message) == 'string'
					and sent.payload.message:find(needle, 1, true) ~= nil then
					return sent.payload
				end
			end
			return nil
		end

		check('the client half is running, not just loaded',
			OPX.Modules.IsRunning('dealership'), OPX.Modules.Record('dealership').Reason)

		-- ── the key ────────────────────────────────────────────────────────
		local mapping = cctl.keyMappings.byId['opx.dealership.use']
		check('the key is declared to the host, so a player can rebind it', mapping ~= nil)
		-- THE GARAGES KEY. A dealer and a garage spot are the same gesture to a
		-- player, so they are the same key; two mappings, one key name.
		check('and defaults to the garages key, E', mapping ~= nil and mapping.key == 'E',
			mapping and tostring(mapping.key))
		check('and the pause menu is given a name for it, not a key',
			mapping ~= nil and type(mapping.name) == 'string' and mapping.name ~= ''
				and mapping.name:find('key', 1, true) == nil, mapping and tostring(mapping.name))

		-- The list is asked for on start, so a dealer already in range does not
		-- wait for the poll.
		local asked = false
		for index = 1, #cctl.clientToServer do
			if cctl.clientToServer[index].name == dealership.Event.ASK then asked = true end
		end
		check('the client asks for its dealers on start', asked)

		-- ── the markers ────────────────────────────────────────────────────
		cctl.netEvents[dealership.Event.STOCK]({ kinds = {
			garage = { { key = 'hella', label = 'Archer Hella', class = 'Street',
				price = 29000, text = '29,000 $' } },
			avpad = { { key = 'manticore', label = 'Militech Manticore', class = 'Air',
				price = 420000, text = '420,000 $' } },
		} })
		cctl.netEvents[dealership.Event.SYNC]({ spots = {
			{ key = 'yard', label = 'UPTOWN YARD', kind = 'garage',
				x = 1.0, y = 1.0, z = 5.0, heading = 90.0, bucket = 0 },
			{ key = 'pad', label = 'UPTOWN PAD', kind = 'avpad',
				x = 4.0, y = 1.0, z = 2.0, heading = 0.0, bucket = 0 },
		} })
		cctl.Pump(6)

		local drawn = cenv.Open77.markers.list()
		check('one marker is drawn per dealer in range', #drawn == 2, #drawn)

		local looks = {}
		for index = 1, #drawn do
			local options = cctl.markers.byId[drawn[index]]
			looks[options.position.x] = options
		end
		local yardMarker, padMarker = looks[1.0], looks[4.0]
		check('the garage dealer is the cylinder on its own spot',
			yardMarker ~= nil and yardMarker.shape == 'cylinder'
				and yardMarker.style == 'interaction' and yardMarker.radius == 2.5,
			yardMarker and ('%s/%s/%s'):format(tostring(yardMarker.shape),
				tostring(yardMarker.style), tostring(yardMarker.radius)))
		check('the pad is the ring on its own spot',
			padMarker ~= nil and padMarker.shape == 'ring' and padMarker.style == 'interaction'
				and padMarker.radius == 3.5,
			padMarker and ('%s/%s/%s'):format(tostring(padMarker.shape),
				tostring(padMarker.style), tostring(padMarker.radius)))
		-- The spot's OWN height plus the look's own lift: a ring on a roof at 2.0
		-- is drawn at 2.06, and one that was not lifted would be co-planar with
		-- that roof and invisible.
		check('and its own height, not the player\'s, lifted clear of the surface',
			padMarker ~= nil and math.abs(padMarker.position.z - (2.0 + Access.Marker('avpad').lift)) < 1e-9,
			padMarker and tostring(padMarker.position.z))
		check('and the engine is given the clamped draw distance, not the raw config',
			yardMarker ~= nil and yardMarker.maxDistance == Access.MaxDistance(),
			yardMarker and tostring(yardMarker.maxDistance))

		-- ── the strip row ──────────────────────────────────────────────────
		check('standing on a dealer posts its row', Runtime.Report().nearest == 'yard',
			Runtime.Report().nearest)
		local listed = prompts ~= nil and prompts.List('dealership') or nil
		check('and the strip holds exactly one row for it',
			listed ~= nil and listed.ok == true and listed.value.count == 1
				and listed.value.prompts[1] == 'dealer',
			listed and listed.ok and tostring(listed.value.count))
		check('and names the key it is bound to', Runtime.Report().key == 'E',
			Runtime.Report().key)
		check('and it knows what the dealer sells', Runtime.Report().listed == 1,
			tostring(Runtime.Report().listed))

		-- ── the list ───────────────────────────────────────────────────────
		mapping.pressed()
		check('the key opens the list for the dealer underfoot',
			Runtime.Report().open == true and Runtime.Report().screen == 'root',
			('%s/%s'):format(tostring(Runtime.Report().open), tostring(Runtime.Report().screen)))
		local opened = lastDrawn('opx:menu:open')
		check('drawn by the menu module, titled with the dealer\'s own name',
			opened ~= nil and opened.payload.title == 'UPTOWN YARD',
			opened and tostring(opened.payload.title))

		-- ── the panel it is drawn as ───────────────────────────────────────
		-- THE GEOMETRY IS THE CALLER'S. Every other menu hangs off an edge at the
		-- module's own size; a dealership is read standing still, so it asks for a
		-- large centred panel and the module draws what it was handed. This is the
		-- whole of the change on the wire, asserted on the payload the page reads.
		local menu = dealership.Settings and dealership.Settings.MENU or nil
		check('the dealership asks for a centred panel',
			opened ~= nil and opened.payload.anchor == 'center',
			opened and tostring(opened.payload.anchor))
		check('at its own size, and with its own window of rows',
			menu ~= nil and opened ~= nil and opened.payload.width == menu.WIDTH
				and opened.payload.height == menu.HEIGHT
				and opened.payload.maxHeight == menu.MAX_HEIGHT_VH
				-- The frame is the window, not the list: the caller's size, or the whole
				-- list when there is less of it than the window holds.
				and #opened.payload.rows == math.min(menu.VISIBLE_ROWS, opened.payload.total),
			menu and opened and ('%sx%s/%svh/%d of %s'):format(tostring(opened.payload.width),
				tostring(opened.payload.height), tostring(opened.payload.maxHeight),
				#opened.payload.rows, tostring(opened.payload.total)))
		-- A SQUARE, and the square is a height and a width that are the same number --
		-- NOT a row count that happens to measure right: this screen's own list is six
		-- classes, and a panel whose height followed its rows would draw a bar on the
		-- screen the player sees first. Pinned here because the number is what makes it
		-- square, and because a caller that names no height must still get no height --
		-- every strip in the pack depends on that half of it.
		check('and it is a SQUARE one: a height and a width that are one number',
			menu ~= nil and menu.WIDTH == 708 and menu.HEIGHT == menu.WIDTH,
			menu and ('%sx%s'):format(tostring(menu.WIDTH), tostring(menu.HEIGHT)))

		-- The frame the page draws: the visible window of rows, the class the list
		-- is grouped under, and the price the SERVER formatted.
		local row, index = nil, nil
		if opened ~= nil then
			for position = 1, #opened.payload.rows do
				local drawnRow = opened.payload.rows[position]
				if drawnRow.label == 'Archer Hella' then
					row = drawnRow
					index = opened.payload.first + position - 1
				end
			end
		end
		check('and the row a player picks carries the price the SERVER formatted',
			row ~= nil and row.value == '29,000 $' and row.arrow == true,
			row and tostring(row.value))
		check('grouped under the class its row belongs to',
			opened ~= nil and opened.payload.rows[1] ~= nil
				and opened.payload.rows[1].rule == true
				and opened.payload.rows[1].label == 'Street',
			opened and tostring(opened.payload.rows[1] and opened.payload.rows[1].label))

		-- ── the destination, which is the garages module's answer ──────────
		-- Seeded through the garages module's own event, because which garages
		-- exist is that module's answer and this one keeps no copy.
		cctl.netEvents[garages.Event.SYNC]({ spots = {
			{ key = 'garage_dock', label = 'THE DOCK', kind = 'garage',
				x = 1.0, y = 1.0, z = 5.0, heading = 0.0, bucket = 0 },
			{ key = 'pad_dock', label = 'THE PAD', kind = 'avpad',
				x = 1.0, y = 1.0, z = 5.0, heading = 0.0, bucket = 0 },
		} })
		cctl.Pump(6)

		cctl.PageEmit(page, 'opx:menu:choose',
			{ handle = opened ~= nil and opened.payload.handle or 0, index = index or 0 })
		local deliver = lastDrawn('opx:menu:open')
		check('picking a model opens the delivery screen',
			Runtime.Report().screen == 'deliver', tostring(Runtime.Report().screen))
		check('and titled with the model, not the dealer',
			deliver ~= nil and deliver.payload.title == 'Deliver the Archer Hella',
			deliver and tostring(deliver.payload.title))

		local destination, otherKind = nil, 0
		if deliver ~= nil then
			for position = 1, #deliver.payload.rows do
				local drawnRow = deliver.payload.rows[position]
				if drawnRow.label == 'THE DOCK' then destination = drawnRow end
				if drawnRow.label == 'THE PAD' then otherKind = otherKind + 1 end
			end
		end
		check('offering the garages of the SAME category, and only those',
			destination ~= nil and otherKind == 0,
			('dock %s, other-kind rows %d'):format(tostring(destination ~= nil), otherKind))
		check('and the price is said where the player sees it as the screen opens',
			lastToast('You pay 29,000 $') ~= nil)

		-- The destination row IS the confirmation: choosing it sends the
		-- purchase, and the client stops believing it has bought anything until
		-- the server says so.
		local before = #cctl.clientToServer
		local chosen = nil
		if deliver ~= nil then
			for position = 1, #deliver.payload.rows do
				if deliver.payload.rows[position].label == 'THE DOCK' then
					chosen = deliver.payload.first + position - 1
				end
			end
		end
		cctl.PageEmit(page, 'opx:menu:choose',
			{ handle = deliver ~= nil and deliver.payload.handle or 0, index = chosen or 0 })
		-- Searched for rather than taken as the last: other modules talk to the
		-- server on their own cadence, and the last event on the wire is not
		-- necessarily this one's.
		local sent = nil
		for position = #cctl.clientToServer, 1, -1 do
			if cctl.clientToServer[position].name == dealership.Event.BUY then
				sent = cctl.clientToServer[position]
				break
			end
		end
		check('picking the destination sends the purchase',
			sent ~= nil and #cctl.clientToServer > before
				and sent[1] == 'yard' and sent[2] == 'hella' and sent[3] == 'garage_dock',
			sent and ('%s/%s/%s'):format(tostring(sent[1]), tostring(sent[2]), tostring(sent[3])))
		check('and the list comes down before the request goes out, so the answer is not behind it',
			Runtime.Report().open == false)

		-- ── the verdicts ───────────────────────────────────────────────────
		local verdicts = {}
		cenv.AddEventHandler(dealership.Event.ON_DECISION, function(payload)
			verdicts[#verdicts + 1] = payload
		end)

		cctl.netEvents[dealership.Event.ANSWER](false, 'dealership.cannotAfford', 'hella')
		check('a refusal from the server is published on the local bus',
			#verdicts == 1 and verdicts[1].ok == false
				and verdicts[1].error == 'dealership.cannotAfford',
			verdicts[1] and tostring(verdicts[1].error))
		check('and named to the player, not left silent',
			lastDrawn('opx:notify:show') ~= nil)

		cctl.netEvents[dealership.Event.ANSWER](true, nil, 'hella', {
			plate = 'AA111AA', model = 'Archer Hella', dealer = 'yard',
			garage = 'garage_dock', price = 29000,
		})
		check('a purchase the server confirms is published with the plate',
			verdicts[2] ~= nil and verdicts[2].ok == true and verdicts[2].plate == 'AA111AA'
				and verdicts[2].garage == 'garage_dock',
			verdicts[2] and tostring(verdicts[2].plate))

		-- ── the heading, which only this half can read ─────────────────────
		before = #cctl.clientToServer
		local infoMark = #cctl.log.info
		cctl.netEvents[dealership.Event.CAPTURE]('garage', 'dealer_dock', 'THE DOCKS')
		local answered = cctl.clientToServer[#cctl.clientToServer]
		check('the client answers a capture ask', #cctl.clientToServer > before)
		check('with the operator\'s own facing, which the server cannot read',
			answered ~= nil and answered.name == dealership.Event.CAPTURED
				and answered[1] == 'garage' and answered[2] == 'dealer_dock',
			answered and tostring(answered[2]))
		-- Both ends of the round trip say their half, so a capture that dies in
		-- the middle is a hole in a log rather than silence from everywhere.
		check('and names the dealer it answered, so the round trip reads from here',
			#cctl.log.info > infoMark
				and cctl.log.info[#cctl.log.info]:find('dealer_dock', 1, true) ~= nil,
			cctl.log.info[#cctl.log.info])

		-- ── a keyboard held elsewhere is not a key ─────────────────────────
		cctl.input.captured = true
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('dealership') or nil
			return row ~= nil and row.ok == true and row.value.count == 0
		end)
		listed = prompts ~= nil and prompts.List('dealership') or nil
		check('the row steps aside while another surface holds the keyboard',
			listed ~= nil and listed.ok == true and listed.value.count == 0,
			listed and listed.ok and tostring(listed.value.count))
		before = #cctl.clientToServer
		mapping.pressed()
		check('and the key opens nothing while it does', Runtime.Report().open == false)
		cctl.input.captured = false
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('dealership') or nil
			return row ~= nil and row.ok == true and row.value.count == 1
		end)

		-- ── a dealer with nothing to sell ──────────────────────────────────
		cctl.netEvents[dealership.Event.STOCK]({ kinds = { garage = {}, avpad = {} } })
		cctl.Pump(4)
		local refusedOpen = Runtime.Open()
		check('a dealer with no stock refuses the list rather than opening an empty one',
			refusedOpen.ok == false and refusedOpen.error == 'dealership.nothingForSale',
			tostring(refusedOpen.error))
		check('and says so to the player', Runtime.Report().open == false)
		cctl.netEvents[dealership.Event.STOCK]({ kinds = {
			garage = { { key = 'hella', label = 'Archer Hella', class = 'Street',
				price = 29000, text = '29,000 $' } },
			avpad = {},
		} })
		cctl.Pump(4)

		-- The garages module draws a marker for each of ITS spots on the same
		-- engine list, so its two come down before the dealership's own set is
		-- counted -- otherwise every count below is off by two and says nothing.
		cctl.netEvents[garages.Event.SYNC]({ spots = {} })
		cctl.Pump(6)
		check('and the garages module\'s own markers are not this module\'s bookkeeping',
			#cenv.Open77.markers.list() == 2, #cenv.Open77.markers.list())

		-- ── a dealer the client cannot read ────────────────────────────────
		local warned = #cctl.log.warn
		cctl.netEvents[dealership.Event.SYNC]({ spots = {
			{ key = 'broken', label = 'BROKEN', kind = 'garage', x = 0 / 0, y = 0.0, z = 0.0 },
		} })
		cctl.Pump(6)
		check('a dealer the client cannot read is dropped, not placed at the origin',
			#cenv.Open77.markers.list() == 0 and Runtime.Report().spots == 0,
			('%d drawn, %d held'):format(#cenv.Open77.markers.list(), Runtime.Report().spots))
		check('and it is said once, in the log', #cctl.log.warn > warned
			and table.concat(cctl.log.warn, ' | '):find('was refused', 1, true) ~= nil,
			table.concat(cctl.log.warn, ' | '))

		-- ── taking them down ───────────────────────────────────────────────
		cctl.netEvents[dealership.Event.SYNC]({ spots = {
			{ key = 'yard', label = 'UPTOWN YARD', kind = 'garage',
				x = 1.0, y = 1.0, z = 5.0, heading = 0.0, bucket = 0 },
		} })
		cctl.Pump(6)
		check('a list the server re-sends is drawn again', #cenv.Open77.markers.list() == 1,
			#cenv.Open77.markers.list())
		cctl.netEvents[dealership.Event.SYNC]({ spots = {} })
		cctl.Pump(6)
		check('and a list the server clears takes every marker with it',
			#cenv.Open77.markers.list() == 0, #cenv.Open77.markers.list())
		listed = prompts ~= nil and prompts.List('dealership') or nil
		check('and the row comes down with it',
			listed ~= nil and listed.ok == true and listed.value.count == 0)
	end
end

-- ── clothing stores ────────────────────────────────────────────────────────
-- What is under test is a PLACE and not a shop: a store draws a marker, the
-- marker's key asks the appearance module to put ITS fitting room up, and no
-- catalogue is reimplemented here. So these checks drive the real commands and
-- the real net events, and read the written row and the merged list back out of
-- the host -- a test that only saw a key could not tell a store placed where the
-- operator stands from one placed anywhere else.
section('clothing stores')
do
	-- The bridge the storage module runs against: only the bridge half, so the
	-- SQL and the row it answers are the real ones.
	local function bridge(rows, wrote)
		return Host.Database({
			scalar = function() return 1 end,
			update = function(sql)
				-- Only the INSERT: the schema runs `CREATE TABLE IF NOT EXISTS`
				-- through the same bridge method, and counting that would make
				-- "nothing was written" true of a boot rather than of a refusal.
				if wrote ~= nil and sql:find('INSERT INTO opx77_clothing', 1, true) then
					wrote[#wrote + 1] = sql
				end
				return 0
			end,
			query = function(sql)
				if sql:find('opx77_clothing', 1, true) then return rows end
				return {}
			end,
			single = function() return nil end,
		})
	end

	local wrote = {}
	local env, control, why = boot('server', bridge({
		{ spot_key = 'store_row', label = 'A STORED STORE', x = 10.0, y = 20.0, z = 1.5, bucket = 0 },
	}, wrote))
	check('the server boots with the clothing module', why == nil, why)

	-- The last client event with one name, or nil. Every list below is asserted
	-- off the wire rather than off a return value, because the wire is what the
	-- player's client actually reads.
	local function lastEvent(name)
		for index = #control.clientEvents, 1, -1 do
			if control.clientEvents[index].name == name then return control.clientEvents[index] end
		end
		return nil
	end

	if why == nil then
		local OPX = env.OPX
		local clothing = OPX.Modules.Get('clothing')
		local Access = clothing.Access
		local contract = OPX.Api.Get('clothing')

		check('the clothing module is running', OPX.Modules.IsRunning('clothing'),
			OPX.Modules.Record('clothing').Reason)
		check('and publishes its half of the contract',
			contract ~= nil and type(contract.Spots) == 'function'
				and type(contract.State) == 'function')
		check('the shipped config reports no problems', #Access.Problems() == 0,
			table.concat(Access.Problems(), ' | '))

		-- ── a store is a place, and a place has no facing ─────────────────
		local dock = Access.FromDefinition('dock', { LABEL = 'DOCK', X = 1.0, Y = 2.0, Z = 3.0 })
		check('a definition is validated into a place',
			dock ~= nil and dock.x == 1.0 and dock.z == 3.0 and dock.label == 'DOCK')
		check('with no kind and no heading, because a store has neither',
			dock ~= nil and dock.kind == nil and dock.heading == nil)
		check('and a bucket of zero when the operator names none',
			dock ~= nil and dock.bucket == 0)
		check('a store with no label is named by its key',
			Access.FromDefinition('plain', { X = 0.0, Y = 0.0, Z = 0.0 }).label == 'plain')

		check('a coordinate that is not a number is refused',
			Access.FromDefinition('bad', { X = 'here', Y = 0.0, Z = 0.0 }) == nil)
		check('and a NaN is refused',
			Access.FromDefinition('nan', { X = 0 / 0, Y = 0.0, Z = 0.0 }) == nil)
		check('and a key over the column width is refused',
			Access.FromDefinition(string.rep('k', Access.MAX_KEY + 1), { X = 0.0, Y = 0.0, Z = 0.0 }) == nil)
		check('and an empty key is refused',
			Access.FromDefinition('', { X = 0.0, Y = 0.0, Z = 0.0 }) == nil)
		check('and a bucket that is not a whole number is refused',
			Access.FromDefinition('frac', { X = 0.0, Y = 0.0, Z = 0.0, BUCKET = 1.5 }) == nil)
		check('and a negative bucket is refused',
			Access.FromDefinition('neg', { X = 0.0, Y = 0.0, Z = 0.0, BUCKET = -1 }) == nil)

		-- ── the marker ───────────────────────────────────────────────────
		local look = Access.Marker()
		check('the marker is the engine interaction cylinder',
			look.shape == 'cylinder' and look.style == 'interaction' and look.radius == 2.5,
			('%s/%s/%s'):format(look.shape, look.style, tostring(look.radius)))
		check('lifted off the floor it stands on', look.lift == 0.06, look.lift)

		local shippedMarker = OPX.Config.MODULES.clothing.MARKER
		OPX.Config.MODULES.clothing.MARKER = { shape = 'blob', style = 'glow', RADIUS = 900 }
		look = Access.Marker()
		check('a look the engine does not know falls back per field, not as a block',
			look.shape == 'cylinder' and look.style == 'interaction' and look.radius == 2.5,
			('%s/%s/%s'):format(look.shape, look.style, tostring(look.radius)))
		OPX.Config.MODULES.clothing.MARKER = shippedMarker

		local shippedOffset = OPX.Config.MODULES.clothing.GROUND_OFFSET
		OPX.Config.MODULES.clothing.GROUND_OFFSET = 9000.0
		check('a lift the engine would refuse falls back to the shipped one',
			Access.Marker().lift == 0.06, Access.Marker().lift)
		OPX.Config.MODULES.clothing.GROUND_OFFSET = shippedOffset

		local shippedDistance = OPX.Config.MODULES.clothing.MAX_DISTANCE
		OPX.Config.MODULES.clothing.MAX_DISTANCE = 9000.0
		check('and a draw distance past the engine\'s ceiling is clamped',
			Access.MaxDistance() == 150.0, Access.MaxDistance())
		OPX.Config.MODULES.clothing.MAX_DISTANCE = shippedDistance

		-- ── the bucket is the filter ──────────────────────────────────────
		local mixed = {}
		mixed['two'] = Access.FromDefinition('two', { X = 0.0, Y = 0.0, Z = 0.0, BUCKET = 1 })
		mixed['one'] = Access.FromDefinition('one', { X = 0.0, Y = 0.0, Z = 0.0, BUCKET = 0 })
		mixed['another'] = Access.FromDefinition('another', { X = 0.0, Y = 0.0, Z = 0.0, BUCKET = 0 })
		local inBucket = Access.InBucket(mixed, 0)
		check('a bucket holds only its own stores', #inBucket == 2, #inBucket)
		check('and they are sorted, so a listing cannot reshuffle between runs',
			inBucket[1].key == 'another' and inBucket[2].key == 'one',
			('%s,%s'):format(inBucket[1].key, inBucket[2].key))

		-- ── the commands ─────────────────────────────────────────────────
		local src = 41
		check('the add command is registered and ACL-gated',
			control.commands['opx.clothing.add'] ~= nil
				and control.commands['opx.clothing.add'].restricted == true)
		check('and so are remove and list, which write nothing between them but name every store',
			control.commands['opx.clothing.remove'] ~= nil
				and control.commands['opx.clothing.remove'].restricted == true
				and control.commands['opx.clothing.list'] ~= nil
				and control.commands['opx.clothing.list'].restricted == true)

		-- ── the bare capture, and what does NOT cross the wire ───────────
		-- THE GARAGES ASK THEIR OWN CLIENT BACK for a facing, because a chat line
		-- has none and a vehicle needs one. A store has no facing, so the position
		-- the server can read for itself is the whole of what `add` needs -- and a
		-- capture round-trip, its deadline and its "did not answer" warning are
		-- machinery this module does not have at all.
		check('the module declares no capture ask to send', clothing.Event.CAPTURE == nil)
		local before = #control.clientEvents
		control.commands['opx.clothing.add'].run(src, {})
		control.Pump(8)
		local held = contract.Spots()
		check('the bare add command captures where the operator stands', held['store1'] ~= nil)
		check('at the position the SERVER read, and only that',
			held['store1'] ~= nil and held['store1'].x == 0.0
				and held['store1'].y == 0.0 and held['store1'].z == 0.0,
			held['store1'] and ('%s,%s,%s'):format(held['store1'].x, held['store1'].y,
				held['store1'].z))
		check('under a key it generated and named back', held['store1'].label == 'store1')
		check('the row was written through the bridge', #wrote == 1, #wrote)
		check('binding the key by name rather than splicing it into the statement',
			#wrote == 1 and wrote[1]:find('@key', 1, true) ~= nil)
		check('and the client is TOLD the new list rather than asked for anything',
			#control.clientEvents > before and lastEvent(clothing.Event.SYNC) ~= nil,
			#control.clientEvents - before)

		-- A name and a label, the way an operator actually places one.
		control.commands['opx.clothing.add'].run(src, { 'jinguji', 'JINGUJI' })
		control.Pump(8)
		held = contract.Spots()
		check('an add with a key and a label keeps both',
			held['jinguji'] ~= nil and held['jinguji'].label == 'JINGUJI',
			held['jinguji'] and tostring(held['jinguji'].label))
		check('and writes a row of its own', #wrote == 2, #wrote)

		-- A key the column cannot hold is refused BEFORE anything is written, so a
		-- typo cannot leave half a store behind.
		local wroteBefore = #wrote
		control.commands['opx.clothing.add'].run(src, { string.rep('k', Access.MAX_KEY + 1) })
		control.Pump(4)
		check('a key past the column width is refused, and nothing is written',
			#wrote == wroteBefore)
		check('and no store was filed under it',
			contract.Spots()[string.rep('k', Access.MAX_KEY + 1)] == nil)

		-- ── what came back from the database ──────────────────────────────
		check('a store read back from the database is one of ours',
			held['store_row'] ~= nil and held['store_row'].label == 'A STORED STORE',
			held['store_row'] and tostring(held['store_row'].label))
		check('and it is held at the position the row names, not at the origin',
			held['store_row'].x == 10.0 and held['store_row'].y == 20.0
				and held['store_row'].z == 1.5)
		local state = contract.State()
		check('and the state says it came from there, not from the config file',
			state.ok == true and state.value.stores['store_row'] ~= nil
				and state.value.stores['store_row'].captured == true)

		-- ── one bucket is sent one list ──────────────────────────────────
		env.source = src
		local mark = #control.clientEvents
		control.netEvents[clothing.Event.ASK]()
		local synced = lastEvent(clothing.Event.SYNC)
		check('a client that asks is sent its own bucket\'s list',
			#control.clientEvents > mark and synced ~= nil
				and type(synced[1]) == 'table' and type(synced[1].spots) == 'table',
			synced and tostring(type(synced[1])))
		-- Named, not counted: the three that exist at this point are the one read
		-- back from the database, the generated one and the named one, and a
		-- payload that carried a fourth would be carrying something nobody placed.
		local sent = {}
		if synced ~= nil then
			for index = 1, #synced[1].spots do sent[synced[1].spots[index].key] = true end
		end
		check('carrying exactly the stores of that bucket',
			sent['store_row'] == true and sent['store1'] == true and sent['jinguji'] == true
				and sent['from_config'] == nil,
			table.concat((function()
				local keys = {}
				for key in pairs(sent) do keys[#keys + 1] = key end
				table.sort(keys)
				return keys
			end)(), ','))
		check('and none of the fields a store does not own',
			synced ~= nil and synced[1].spots[1].heading == nil
				and synced[1].spots[1].kind == nil)

		local readPosition = env.Open77.players.position
		env.Open77.players.position = function() return { x = 0, y = 0, z = 0, bucket = 3 } end
		mark = #control.clientEvents
		control.netEvents[clothing.Event.ASK]()
		synced = lastEvent(clothing.Event.SYNC)
		check('a client in another bucket is sent an empty list, not everybody\'s stores',
			synced ~= nil and #synced[1].spots == 0, synced and #synced[1].spots)
		env.Open77.players.position = readPosition

		-- ── removing ────────────────────────────────────────────────────
		local wroteBeforeRemove = #wrote
		control.commands['opx.clothing.remove'].run(src, { 'store_row' })
		control.Pump(8)
		held = contract.Spots()
		check('a stored store is removable by its key', held['store_row'] == nil)
		check('and the row was deleted through the bridge', #wrote == wroteBeforeRemove)
		control.commands['opx.clothing.remove'].run(src, { 'nobody_placed_this' })
		control.Pump(4)
		check('a key nobody has is refused and changes nothing',
			contract.Spots()['nobody_placed_this'] == nil and #wrote == wroteBeforeRemove)

		-- A store that comes from the CONFIG file is not this command's to delete:
		-- inserted into the table the module itself holds, so the branch under test
		-- is the real one, and the merge that puts it in the list is the real one
		-- too -- an `add` afterwards rebuilds.
		Access.SPOTS['from_config'] = Access.FromDefinition('from_config',
			{ LABEL = 'FROM CONFIG', X = 5.0, Y = 5.0, Z = 1.0 })
		control.commands['opx.clothing.add'].run(src, { 'after_config' })
		control.Pump(8)
		check('a store from the config file is in the list with the captured ones',
			contract.Spots()['from_config'] ~= nil)
		local wroteBeforeConfig = #wrote
		control.commands['opx.clothing.remove'].run(src, { 'from_config' })
		control.Pump(4)
		check('but a command cannot delete it: it is edited in the config file',
			contract.Spots()['from_config'] ~= nil and #wrote == wroteBeforeConfig)
	end
end

section('clothing, client side')
do
	local cenv, cctl, cwhy = boot('client')
	check('the client boots with the clothing module', cwhy == nil, cwhy)

	if cwhy == nil then
		local OPX = cenv.OPX
		local clothing = OPX.Modules.Get('clothing')
		local Runtime = clothing.Runtime
		local prompts = OPX.Api.Get('prompts')

		check('the client half is running, not just loaded', OPX.Modules.IsRunning('clothing'),
			OPX.Modules.Record('clothing').Reason)

		-- The garages and the dealership draw markers on the SAME engine list, so
		-- their spots come down before anything here is counted: otherwise every
		-- count below is off by however many they had placed.
		cctl.netEvents[OPX.Modules.Get('garages').Event.SYNC]({ spots = {} })
		cctl.netEvents[OPX.Modules.Get('dealership').Event.SYNC]({ spots = {} })
		cctl.Pump(6)

		-- ── the key ───────────────────────────────────────────────────────
		local mapping = cctl.keyMappings.byId['opx.clothing.use']
		check('the key is declared to the host, so a player can rebind it', mapping ~= nil)
		check('and defaults to E, the same gesture as a garage or a dealer',
			mapping ~= nil and mapping.key == 'E', mapping and tostring(mapping.key))
		check('and the pause menu is given a name for it, not a key',
			mapping ~= nil and type(mapping.name) == 'string' and mapping.name ~= ''
				and mapping.name:find('key', 1, true) == nil, mapping and tostring(mapping.name))

		local asked = false
		for index = 1, #cctl.clientToServer do
			if cctl.clientToServer[index].name == clothing.Event.ASK then asked = true end
		end
		check('the client asks for its stores on start', asked)

		-- ── the markers ───────────────────────────────────────────────────
		local jinguji = { key = 'jinguji', label = 'JINGUJI', x = 0.0, y = 0.0, z = 0.0, bucket = 0 }
		cctl.netEvents[clothing.Event.SYNC]({ spots = {
			jinguji,
			{ key = 'unreachable', label = 'UNREACHABLE', x = 200.0, y = 0.0, z = 0.0, bucket = 0 },
		} })
		settle(cctl, function() return #cenv.Open77.markers.list() == 1 end)

		local drawn = cenv.Open77.markers.list()
		check('one marker is drawn per store in range', #drawn == 1, #drawn)
		local options = cctl.markers.byId[drawn[1]]
		check('the marker is the engine interaction cylinder',
			options ~= nil and options.shape == 'cylinder' and options.style == 'interaction'
				and options.radius == 2.5,
			options and ('%s/%s/%s'):format(tostring(options.shape), tostring(options.style),
				tostring(options.radius)))
		local lift = clothing.Access.Marker().lift
		check('and it is drawn at the store\'s own height, lifted clear of the surface',
			options ~= nil and math.abs(options.position.z - (0.0 + lift)) < 1e-9,
			options and tostring(options.position.z))
		check('a store past MAX_DISTANCE has no marker at all',
			Runtime.Report().spots == 2 and Runtime.Report().markers == 1,
			('%d held, %d drawn'):format(Runtime.Report().spots, Runtime.Report().markers))

		-- ── the strip row ─────────────────────────────────────────────────
		check('standing on a store posts its row', Runtime.Report().nearest == 'jinguji',
			Runtime.Report().nearest)
		local listed = prompts ~= nil and prompts.List('clothing') or nil
		check('and the strip holds exactly one row for it',
			listed ~= nil and listed.ok == true and listed.value.count == 1
				and listed.value.prompts[1] == 'store',
			listed and listed.ok and tostring(listed.value.count))
		check('and names the key it is bound to', Runtime.Report().key == 'E', Runtime.Report().key)

		-- ── the key opens the fitting room ────────────────────────────────
		-- The room belongs to `appearance`, so what this half owes it is the ASK:
		-- the contract, called once, under this module's own name -- which is what
		-- the room lends itself to and takes itself back from.
		local appearance = OPX.Api.Get('appearance')
		local realOpen = appearance ~= nil and appearance.OpenWardrobe or nil
		check('the fitting room this module opens is a contract it can actually reach',
			type(realOpen) == 'function')

		local decisions = {}
		cenv.AddEventHandler(clothing.Event.ON_DECISION, function(payload)
			decisions[#decisions + 1] = payload
		end)
		local calls = {}
		if appearance ~= nil then
			appearance.OpenWardrobe = function(owner)
				calls[#calls + 1] = owner
				return { ok = true, value = { citizenId = 'citizen-clothing' } }
			end
		end

		mapping.pressed()
		check('the key opens the fitting room', #calls == 1, #calls)
		check('under this module\'s own name, so the room knows whose it is',
			calls[1] == clothing.WARDROBE_OWNER, calls[1])
		check('and the verdict is published on the local bus',
			#decisions == 1 and decisions[1].ok == true and decisions[1].store == 'jinguji',
			decisions[1] and tostring(decisions[1].error))

		-- A room that refuses is a refusal here, carrying the room's OWN reason:
		-- `player_down`, `no_character` and `appearance_busy` are all states a
		-- player can be in, and none of them is a fault in this module.
		if appearance ~= nil then
			appearance.OpenWardrobe = function() return { ok = false, error = 'player_down' } end
		end
		decisions = {}
		local verdict = Runtime.Open('test')
		check('a room that refuses answers a store that could not be opened',
			verdict.ok == false and verdict.error == 'clothing.wardrobeRefused'
				and verdict.reason == 'player_down',
			('%s/%s'):format(tostring(verdict.error), tostring(verdict.reason)))
		check('and the player is told the room\'s own reason, not a generic one',
			OPX.Locale.Text('clothing.wardrobeRefused', { reason = 'player_down' }):find('player_down', 1, true) ~= nil,
			OPX.Locale.Text('clothing.wardrobeRefused', { reason = 'player_down' }))
		check('and the refusal is on the local bus too',
			#decisions == 1 and decisions[1].ok == false)

		-- A room that raises is a refused open and never a broken key.
		if appearance ~= nil then
			appearance.OpenWardrobe = function() error('boom') end
		end
		verdict = Runtime.Open('test')
		check('a room that raises is a refused open, never a key that throws',
			verdict.ok == false and verdict.error == 'clothing.wardrobeRefused'
				and verdict.reason == 'call_failed',
			('%s/%s'):format(tostring(verdict.error), tostring(verdict.reason)))

		-- With no room at all -- the platform's own appearance package running,
		-- or a host that never loaded the module -- the door says so instead of
		-- doing nothing, because the marker drew and the row posted.
		if appearance ~= nil then appearance.OpenWardrobe = nil end
		verdict = Runtime.Open('test')
		check('with no fitting room at all the open is refused by name',
			verdict.ok == false and verdict.error == 'clothing.noWardrobe',
			tostring(verdict.error))
		check('and there are words for it, so the player is told something',
			OPX.Locale.Text('clothing.noWardrobe'):find('fitting room', 1, true) ~= nil,
			OPX.Locale.Text('clothing.noWardrobe'))
		if appearance ~= nil then appearance.OpenWardrobe = realOpen end

		-- ── a keyboard held elsewhere is not a key ────────────────────────
		cctl.input.captured = true
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('clothing') or nil
			return row ~= nil and row.ok == true and row.value.count == 0
		end)
		listed = prompts ~= nil and prompts.List('clothing') or nil
		check('the row steps aside while another surface holds the keyboard',
			listed ~= nil and listed.ok == true and listed.value.count == 0,
			listed and listed.ok and tostring(listed.value.count))
		calls = {}
		mapping.pressed()
		check('and the key opens nothing while it does', #calls == 0, #calls)
		cctl.input.captured = false
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('clothing') or nil
			return row ~= nil and row.ok == true and row.value.count == 1
		end)

		-- ── a store nobody is standing on ─────────────────────────────────
		cctl.netEvents[clothing.Event.SYNC]({ spots = {} })
		settle(cctl, function() return Runtime.Report().nearest == nil end)
		calls = {}
		verdict = Runtime.Open('test')
		check('a store nobody is standing on cannot be opened',
			verdict.ok == false and verdict.error == 'clothing.noSuchStore')
		check('and nothing was asked of the fitting room', #calls == 0)

		-- ── a store the client cannot read ────────────────────────────────
		local warned = #cctl.log.warn
		cctl.netEvents[clothing.Event.SYNC]({ spots = {
			{ key = 'broken', label = 'BROKEN', x = 0 / 0, y = 0.0, z = 0.0 },
		} })
		cctl.Pump(6)
		check('a store the client cannot read is dropped, not placed at the origin',
			#cenv.Open77.markers.list() == 0 and Runtime.Report().spots == 0,
			('%d drawn, %d held'):format(#cenv.Open77.markers.list(), Runtime.Report().spots))
		check('and it is said once, in the log', #cctl.log.warn > warned
			and table.concat(cctl.log.warn, ' | '):find('was refused', 1, true) ~= nil,
			table.concat(cctl.log.warn, ' | '))

		-- A MARKER THE ENGINE REFUSES. It must be one logged line and no marker,
		-- rather than a raise inside the scan or a marker nobody can see.
		local warnedMarkers = #cctl.log.warn
		cctl.markers.refuse = 'unsupported_style'
		cctl.netEvents[clothing.Event.SYNC]({ spots = { jinguji } })
		cctl.Pump(6)
		check('a marker the engine refuses is not drawn', #cenv.Open77.markers.list() == 0)
		check('and it is said once, in the log', #cctl.log.warn > warnedMarkers
			and table.concat(cctl.log.warn, ' | '):find('no marker is drawn', 1, true) ~= nil,
			table.concat(cctl.log.warn, ' | '))
		cctl.markers.refuse = nil

		-- ── taking them down ──────────────────────────────────────────────
		cctl.netEvents[clothing.Event.SYNC]({ spots = { jinguji } })
		settle(cctl, function() return #cenv.Open77.markers.list() == 1 end)
		check('a list the server re-sends is drawn again', #cenv.Open77.markers.list() == 1,
			#cenv.Open77.markers.list())
		cctl.netEvents[clothing.Event.SYNC]({ spots = {} })
		settle(cctl, function() return #cenv.Open77.markers.list() == 0 end)
		check('and a list the server clears takes every marker with it',
			#cenv.Open77.markers.list() == 0, #cenv.Open77.markers.list())
		listed = prompts ~= nil and prompts.List('clothing') or nil
		check('and the row comes down with it',
			listed ~= nil and listed.ok == true and listed.value.count == 0)
	end
end

section('permissions the code needs')
do
	-- A permission a resource does not declare is answered `nil, permission_denied:<name>`
	-- by the native, and NOTHING ELSE HAPPENS: no refusal the platform journals, no
	-- error the caller must handle, no line anywhere. The feature simply does
	-- nothing, silently, until somebody reads the reason off the return value --
	-- which is how the noclip pop was dead on arrival (`Open77.vfx.play` with no
	-- `world.effects` in the manifest). This is the cheapest net for that: the call
	-- sites are in the files the manifest lists, and the permission names are the
	-- native handlers' own strings, in `scripting/src/ResourceHost.cpp`.
	-- The namespaces, not the calls: a module that binds `local markers = Open77.markers`
	-- at the top and calls through the local would slip past a call-site search,
	-- and a false positive here only ever demands a permission a file already
	-- mentions -- which for the three the resource declares is no demand at all.
	local GATED = {
		{ 'Open77.vfx', 'world.effects', 'every world effect' },
		{ 'Open77.sfx', 'world.effects', 'every sound' },
		{ 'Open77.markers', 'world.markers', 'the glowing garage and pad markers' },
		{ 'Open77.props', 'world.props', 'world props' },
		{ 'Open77.clipboard.setText', 'clipboard.write', 'writing the clipboard' },
		{ 'Open77.players.setVisible', 'players.life.visibility', 'hiding a body' },
		{ 'Open77.players.setFrozen', 'players.life.freeze', 'holding a player still' },
		{ 'Open77.doors', 'world.doors', 'the staff door switch' },
	}

	local handle = io.open('open77.lua', 'r')
	local manifest = handle and handle:read('a') or ''
	if handle then handle:close() end
	check('the manifest is readable', #manifest > 0)

	-- Every quoted lowercase name in the file, which is how a permission is
	-- written and nothing else in the manifest is.
	local declared = {}
	for name in manifest:gmatch('"([a-z][a-z0-9._]*)"') do declared[name] = true end

	local seen, files = {}, {}
	for _, side in ipairs({ 'shared', 'server', 'client' }) do
		for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do
			if not seen[file] then
				seen[file] = true
				files[#files + 1] = file
			end
		end
	end
	check('the manifest lists the files to scan', #files > 0, #files)

	for index = 1, #GATED do
		local call, permission, what = GATED[index][1], GATED[index][2], GATED[index][3]
		local used
		for position = 1, #files do
			local input = io.open(files[position], 'r')
			if input then
				local body = input:read('a')
				input:close()
				if body:find(call, 1, true) then
					used = files[position]
					break
				end
			end
		end
		if used == nil then
			-- Nothing calls it, so nothing needs the grant: an unread permission
			-- is not a failure, and this line says which ones are unread.
			check(('%s is not needed yet (%s)'):format(permission, what), true)
		else
			check(('%s is declared, because %s calls it (%s)'):format(permission, used, what),
				declared[permission] == true, 'not declared in open77.lua')
		end
	end
end

section('noclip, server side')
do
	local env, control, why = boot('server')
	check('the server boots with the admin module', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local Players = admin.Players
		local src = 12

		control.Admit(src, 'account-noclip')
		OPX.EnsureSession(src)
		control.Allow(src, 'command.' .. admin.Command.SELF_NOCLIP)
		control.Allow(src, 'command.' .. admin.Command.SELF_INVISIBLE)

		-- The newest travel instruction sent to a client, or nil. Filtered by the
		-- mode, because arming noclip also sends the starting speed and the last
		-- message on the wire is therefore not the one under test.
		local function lastTravel(action)
			for index = #control.clientEvents, 1, -1 do
				local event = control.clientEvents[index]
				if event.name == admin.Event.TRAVEL and (action == nil or event[1] == action) then
					return event
				end
			end
			return nil
		end

		check('nothing has touched the body yet', control.bodies.visible[src] == nil,
			tostring(control.bodies.visible[src]))

		-- ── the way up ────────────────────────────────────────────────────
		control.commands[admin.Command.SELF_NOCLIP].run(src, {})
		control.Pump(4)
		local on = lastTravel('noclip')
		check('noclip on is sent to the operator',
			on ~= nil and on[2] == true,
			on and ('%s=%s'):format(tostring(on[1]), tostring(on[2])))
		check('and the body goes with it -- this is the despawn the pop accompanies',
			control.bodies.visible[src] == false, tostring(control.bodies.visible[src]))
		check('and noclip is recorded as on, for the checkbox', Players.IsNoclip(src) == true)
		local writes = #control.bodies.writes
		check('and the hide is the only body write so far', writes == 1, writes)

		-- ── the way down, as the CLIENT sees it ───────────────────────────
		-- The native being switched off underneath the server. This event is the
		-- only thing that can say so, and without it the body stays hidden for
		-- the rest of the session.
		env.source = src
		control.netEvents[admin.Event.NOCLIP_BODY](false)
		control.Pump(4)
		check('the native going off underneath the server is honoured',
			Players.IsNoclip(src) == false)
		check('and the body is given back', control.bodies.visible[src] == true,
			tostring(control.bodies.visible[src]))

		-- ── and the direction a client must NOT be able to claim ──────────
		control.commands[admin.Command.SELF_NOCLIP].run(src, {})
		control.Pump(4)
		env.source = src
		env.source = src
		control.netEvents[admin.Event.NOCLIP_BODY](true)
		control.Pump(4)
		check('a client claiming noclip is ON cannot drive its own body',
			Players.IsNoclip(src) == true and control.bodies.visible[src] == false,
			('%s/%s'):format(tostring(Players.IsNoclip(src)),
				tostring(control.bodies.visible[src])))

		-- ── two reasons, one body ─────────────────────────────────────────
		-- The Invisible switch and the flying are separate reasons, and whichever
		-- is switched off first must not hand back a body the other still hides.
		control.commands[admin.Command.SELF_INVISIBLE].run(src, { 'on' })
		control.Pump(4)
		check('the Invisible switch hides the body too', control.bodies.visible[src] == false)
		control.commands[admin.Command.SELF_NOCLIP].run(src, { 'off' })
		control.Pump(4)
		check('noclip off does not give back a body the switch still hides',
			control.bodies.visible[src] == false, tostring(control.bodies.visible[src]))
		check('and the travel instruction says off', (function()
			local off = lastTravel('noclip')
			return off ~= nil and off[2] == false
		end)())
		control.commands[admin.Command.SELF_INVISIBLE].run(src, { 'off' })
		control.Pump(4)
		check('and the switch off is what gives it back',
			control.bodies.visible[src] == true, tostring(control.bodies.visible[src]))

		-- A host that cannot hide a body says so instead of pretending. The flight
		-- still takes -- the native is the operator's -- so the operator is told
		-- the body did not follow, with the reason, rather than left to wonder.
		control.bodies.refuse = 'no_such_native'
		control.commands[admin.Command.SELF_NOCLIP].run(src, {})
		control.Pump(4)
		local toast = control.notices[#control.notices]
		check('a host that cannot hide the body tells the operator why',
			toast ~= nil and toast.playerId == src and toast.type == 'warning'
				and tostring(toast.message):find('no_such_native', 1, true) ~= nil,
			toast and ('%s: %s'):format(tostring(toast.type), tostring(toast.message)))
		check('and the flight still took, so the answer is not a lie about noclip',
			Players.IsNoclip(src) == true)
		control.bodies.refuse = nil
	end
end

section('noclip, the pop')
do
	local cenv, cctl, cwhy = boot('client')
	check('the client boots with the admin module', cwhy == nil, cwhy)

	if cwhy == nil then
		local OPX = cenv.OPX
		local admin = OPX.Modules.Get('admin')
		local Noclip = admin.Noclip
		local travel = admin.Event.TRAVEL

		-- The advertised effect catalogue, in the shape a config can check against.
		local carried = {}
		for _, alias in ipairs(cenv.Open77.vfx.catalog()) do carried[alias] = true end

		check('the pop owns one transition point and nothing else',
			type(Noclip.Changed) == 'function' and type(Noclip.Pop) == 'function')
		local report = Noclip.Report()
		check('it starts with the effect the config names, and no handle',
			report.handle == nil and report.effect == OPX.Config.MODULES.admin.NOCLIP.EFFECT,
			report.effect)
		-- The one failure a suite can catch without the game: an alias the engine
		-- does not carry is answered `nil, invalid_argument` and draws NOTHING, so
		-- a typo here would be a noclip that pops only in the log.
		check('and that effect is one the engine actually carries',
			carried[report.effect] == true, report.effect)
		check('and its duration is inside the engine\'s own ceiling',
			report.seconds >= 0.0 and report.seconds <= 600.0, tostring(report.seconds))

		-- ── the way up ────────────────────────────────────────────────────
		local mark = #cctl.clientToServer
		cctl.netEvents[travel]('noclip', true)
		cctl.Pump(4)
		check('the way up plays the pop exactly once', #cctl.effects.plays == 1,
			#cctl.effects.plays)
		local first = cctl.effects.plays[1]
		check('with the configured effect and duration',
			first ~= nil and first.effect == report.effect
				and first.options.duration == report.seconds,
			first and ('%s/%s'):format(tostring(first.effect), tostring(first.options.duration)))
		check('where the operator is standing, because a depot alias is resolved in the world',
			first ~= nil and type(first.options.position) == 'table'
				and first.options.position.x == 0.0 and first.options.position.y == 0.0
				and first.options.position.z == 0.0)
		check('and it is NOT sent to the entity-bound call, which would resolve it as a CName',
			#cctl.effects.entityPlays == 0, #cctl.effects.entityPlays)
		check('and the noclip native was really switched on', cctl.travels.noclip == true)
		check('and the body is NOT reported on the way up -- the server already knew',
			#cctl.clientToServer == mark)

		-- ── and it RIDES the operator ─────────────────────────────────────
		-- A world effect is placed once and then stays where it was put. An
		-- operator noclips at 40 m/s, so a pop left at the spot the toggle
		-- happened in is behind them before it has drawn a frame -- drawn
		-- correctly, and visible to nobody, which is exactly what "the pop does
		-- not show" looks like from inside the game. The effect is therefore
		-- re-placed at the operator while it lives, and this is the check that
		-- the suite can move the operator and watch it follow.
		local riding = Noclip.Report().handle
		check('the drawn pop was taken as a handle to move', riding ~= nil, tostring(riding))
		cctl.placement.x, cctl.placement.y, cctl.placement.z = 12.5, -4.0, 2.25
		cctl.Pump(3)
		local moved = cctl.effects.updates[#cctl.effects.updates]
		check('and it is re-placed where the operator IS, not where they were',
			moved ~= nil and moved.id == riding and moved.options.position.x == 12.5
				and moved.options.position.y == -4.0 and moved.options.position.z == 2.25,
			moved and ('handle %s at (%s, %s, %s)'):format(tostring(moved.id),
				tostring(moved.options.position.x), tostring(moved.options.position.y),
				tostring(moved.options.position.z)) or 'never moved')
		check('and it moved more than once, so this is a follow and not one nudge',
			#cctl.effects.updates >= 2, #cctl.effects.updates)
		check('and it is still never the entity-bound call', #cctl.effects.entityPlays == 0,
			#cctl.effects.entityPlays)

		-- Bounded by the effect's own life: past it the loop ends instead of
		-- moving a dead handle for the rest of the session.
		cctl.Pump(30)
		local settled = #cctl.effects.updates
		cctl.Pump(10)
		check('and it stops when the effect expires instead of spinning a dead handle',
			#cctl.effects.updates == settled,
			('%d -> %d'):format(settled, #cctl.effects.updates))
		cctl.placement.x, cctl.placement.y, cctl.placement.z = 0.0, 0.0, 0.0

		-- A repeated `on` is not a transition, so it must not pop again.
		cctl.netEvents[travel]('noclip', true)
		cctl.Pump(4)
		check('a repeated on does not pop again', #cctl.effects.plays == 1, #cctl.effects.plays)

		-- ── the way down ──────────────────────────────────────────────────
		cctl.netEvents[travel]('noclip', false)
		cctl.Pump(4)
		check('the way down plays the pop again', #cctl.effects.plays == 2, #cctl.effects.plays)
		check('and this is the edge the server is told about',
			#cctl.clientToServer > mark
				and cctl.clientToServer[#cctl.clientToServer].name == admin.Event.NOCLIP_BODY
				and cctl.clientToServer[#cctl.clientToServer][1] == false,
			cctl.clientToServer[#cctl.clientToServer][1] == nil and 'nothing sent'
				or tostring(cctl.clientToServer[#cctl.clientToServer][1]))

		-- ── a pop the engine turns down ───────────────────────────────────
		-- The native answers `nil, reason` here rather than raising, and a name the
		-- catalogue does not carry arrives exactly this way.
		local drawn = #cctl.effects.plays
		local heldThen = Noclip.Report().handle
		cctl.effects.refuse = 'invalid_argument'
		cctl.netEvents[travel]('noclip', true)
		cctl.Pump(4)
		cctl.netEvents[travel]('noclip', false)
		cctl.Pump(4)
		local function popWarnings()
			local found = {}
			for _, line in ipairs(cctl.log.warn) do
				if tostring(line):find('the noclip pop', 1, true) then found[#found + 1] = line end
			end
			return found
		end
		local warned = popWarnings()
		check('a refused pop is reported once with the engine\'s own reason',
			#warned == 1 and tostring(warned[1]):find('invalid_argument', 1, true) ~= nil,
			#warned .. ': ' .. table.concat(warned, ' | '))
		check('and nothing was drawn, so no handle was taken',
			#cctl.effects.plays == drawn and #cctl.effects.calls == 2
				and Noclip.Report().handle == heldThen,
			('%d/%d'):format(#cctl.effects.plays, #cctl.effects.calls))
		cctl.effects.refuse = nil

		-- ── the handle is owned, not leaked ───────────────────────────────
		cctl.netEvents[travel]('noclip', true)
		cctl.Pump(4)
		local held = Noclip.Report().handle
		check('and the next drawn pop takes a fresh handle', held ~= nil and held ~= heldThen,
			tostring(held))
		check('a pop that was drawn is held', held ~= nil, tostring(held))
		Noclip.Stop()
		check('and stopping the module takes it down',
			#cctl.effects.stopped >= 1
				and cctl.effects.stopped[#cctl.effects.stopped] == held
				and Noclip.Report().handle == nil,
			table.concat(cctl.effects.stopped, ','))

		-- ── a client with no effect layer at all ──────────────────────────
		-- The half must still work: the state moves, the body is still reported,
		-- and the missing layer is named once rather than every toggle.
		local mark2 = #cctl.clientToServer
		cenv.Open77.vfx = nil
		cctl.netEvents[travel]('noclip', false)
		cctl.Pump(4)
		cctl.netEvents[travel]('noclip', true)
		cctl.Pump(4)
		local missing = 0
		for _, line in ipairs(cctl.log.info) do
			if tostring(line):find('no Open77.vfx', 1, true) then missing = missing + 1 end
		end
		check('a client without the effect layer says so once, not once per toggle',
			missing == 1, missing)
		check('and the half keeps working: the native still moves and the edge is still reported',
			cctl.travels.noclip == true and #cctl.clientToServer > mark2)
	end
end

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

-- ── the staff spawn menu: Air, the AV lift, and a descend ───────────────────
-- THREE THINGS, ALL OF THEM OBSERVED RATHER THAN READ. The class the spawn menu
-- did not have; that a record's category comes from the record and an AV is
-- lifted where a car is not; and that descending into a screen UPDATES the open
-- menu instead of replacing it -- one handle, one frame, no close. The reopen was
-- one per keystroke, and it is what the page blanked for, what re-ran the
-- nine-row arrival walk for a screen that had not arrived, and what dropped a
-- click that landed inside it (the handle is the capability every intent names).
section('the staff spawn menu: Air, the AV lift, and a descend that updates')
do
	local env, control, why = boot('client')
	check('client boots for the staff menu tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local Catalog = admin.Catalog
		local classes = Catalog.Classes()

		-- THE CLASS THE MENU WAS MISSING, and first, because it is the one an
		-- operator opens this screen looking for by name.
		local air = classes[1]
		check('the spawn menu opens with an Air class',
			air ~= nil and air.key == 'air', air and air.key)

		local members = air and air.members or {}
		check('holding the six AVs', #members == 6, #members)

		-- DERIVED, NEVER DECLARED: every Air row's record matches the configured
		-- prefixes, and every row the rule calls air carries the flag.
		local prefixes = admin.Section('VEHICLES').AV_PREFIXES or {}
		local function isAir(record)
			local lowered = tostring(record):lower()
			for _, prefix in ipairs(prefixes) do
				if lowered:sub(1, #prefix) == prefix then return true end
			end
			return false
		end
		local wrong = {}
		for _, entry in ipairs(members) do
			if entry.av ~= true or not isAir(entry.record) then wrong[#wrong + 1] = entry.name end
		end
		check('every one of them an AV by its record', #wrong == 0, table.concat(wrong, ' '))

		-- AND NOT ONE OUTSIDE IT. A ground class holding an air record would mean
		-- the flag and the record had drifted apart, which is the whole reason no
		-- row declares its own category.
		local strays = {}
		for _, class in ipairs(classes) do
			if class.key ~= 'air' then
				for _, entry in ipairs(class.members) do
					if entry.av == true or isAir(entry.record) then
						strays[#strays + 1] = entry.name
					end
				end
			end
		end
		check('and not one in any ground class', #strays == 0, table.concat(strays, ' '))

		local manticore = Catalog.Vehicle('av_manticore')
		check('an AV answers to the name staff type and to its own record',
			manticore ~= nil and manticore.record == 'Vehicle.av_militech_manticore'
				and Catalog.Vehicle('vehicle.av_militech_manticore') == manticore,
			manticore and manticore.record)

		-- The index is in parts for its size, and a part carrying more than one
		-- part's worth is a problem the module logs at boot.
		local burden = {}
		for _, line in ipairs(admin.Problems or {}) do
			if tostring(line):find('vehicles.lua', 1, true) ~= nil then burden[#burden + 1] = line end
		end
		check('and the catalogue reports no problem row', #burden == 0, table.concat(burden, ' | '))

		-- ── descending, played the way the panel descends ────────────────
		control.netEvents[admin.Event.OPEN]({ access = {}, aclKnown = false, inventory = false })

		-- The page the staff menu opened on, found by what was sent to it rather
		-- than by assuming which surface sits first in the list.
		local OPEN_CHANNEL, FRAME_CHANNEL, CLOSE_CHANNEL =
			'opx:menu:open', 'opx:menu:frame', 'opx:menu:close'
		local page
		for _, candidate in ipairs(control.pages) do
			for _, sent in ipairs(candidate.sent) do
				if sent.channel == OPEN_CHANNEL then page = candidate end
			end
		end
		check('the staff menu opens on a page', page ~= nil)

		if page ~= nil then
			local function times(channel)
				local count = 0
				for _, sent in ipairs(page.sent) do
					if sent.channel == channel then count = count + 1 end
				end
				return count
			end
			local function last(channel)
				for index = #page.sent, 1, -1 do
					if page.sent[index].channel == channel then return page.sent[index] end
				end
				return nil
			end

			local handle = last(OPEN_CHANNEL).payload.handle
			check('and is given a handle', handle ~= nil)

			-- THE OTHER HALF OF THE SQUARE, and the half every menu in the pack rests
			-- on: this caller named no height, so the page is handed none and draws the
			-- strip its rows make. A height that leaked here would make every existing
			-- menu a panel.
			check('and a caller that named no height is given none',
				last(OPEN_CHANNEL).payload.height == nil,
				tostring(last(OPEN_CHANNEL).payload.height))

			local opens, frames = times(OPEN_CHANNEL), times(FRAME_CHANNEL)

			-- THE DESCEND ITSELF, through the module's own door, into the screen the
			-- Air class lives on.
			check('the panel can put a screen up over the root',
				admin.Menu.OpenAt('vehicleClasses', 'me') == true)
			check('a descend does NOT reopen the menu', times(OPEN_CHANNEL) == opens,
				('%d opens'):format(times(OPEN_CHANNEL)))
			check('and is drawn as one frame, on the same handle',
				times(FRAME_CHANNEL) == frames + 1
					and last(FRAME_CHANNEL).payload.handle == handle)
			check('and the surface is never closed and reopened under the player',
				times(CLOSE_CHANNEL) == 0)

			-- WHERE IT LANDS. A rebuild keeps the player's position, which is right
			-- for a redraw and meaningless for a screen that has just replaced the
			-- last one, so the caller pins the landing -- the first row under the
			-- filter block, which is the first class.
			local state = OPX.Api.Get('menu').State()
			check('and the cursor lands under the filter block, on the first class',
				state.ok and state.value.itemId == 'class_air',
				state.ok and tostring(state.value.itemId))

			-- A REDRAW KEEPS THE ROW: the other half of the same rule.
			control.PageEmit(page, 'opx:menu:key', { handle = handle, key = 'down' })
			local moved = OPX.Api.Get('menu').State()
			check('down moves the cursor', moved.ok and moved.value.itemId ~= 'class_air',
				moved.ok and tostring(moved.value.itemId))
			admin.Menu.Refresh()
			local kept = OPX.Api.Get('menu').State()
			check('and a redraw leaves the player on the row they were on',
				kept.ok and kept.value.itemId == moved.value.itemId,
				kept.ok and tostring(kept.value.itemId))
		end
	end
end

-- ── the AV lift, server side ─────────────────────────────────────────────────
section('an AV is lifted clear of the ground where a car is not')
do
	local env, control, why = boot('server')
	check('the server boots with the admin module for the spawn tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local settings = admin.Section('VEHICLES')
		local src = 21

		control.Admit(src, 'account-admin-air')
		OPX.EnsureSession(src)
		control.Allow(src, 'command.' .. admin.Command.VEHICLE_SPAWN)

		-- THE READINESS GATE, opened here because a spawn acts on a BODY. The stub's
		-- own life state is not a table and its gate is shut, which is a deliberate
		-- default -- nothing may teleport or spawn a player before they are in the
		-- world -- and therefore something this section has to say out loud rather
		-- than spawn around.
		env.Open77.players.getLifeState = function() return { state = 'alive' } end
		env.Open77.ready = { isReady = function() return true end, status = function() return nil end }

		-- Read out of the config, so this checks the arithmetic rather than
		-- repeating the numbers it is meant to be checking.
		local offset = settings.SPAWN_OFFSET
		local lift = settings.AV_LIFT

		control.commands[admin.Command.VEHICLE_SPAWN].run(src, { 'av_manticore' })
		control.Pump(4)
		local av = control.vehicleCreates[#control.vehicleCreates]
		check('an AV is created through the seam a car uses',
			av ~= nil and av.record == 'Vehicle.av_militech_manticore',
			av and tostring(av.record))
		check('and it is lifted clear of the ground a car sits on',
			av ~= nil and math.abs(av.position.z - (offset.Z + lift)) < 1e-9,
			av and tostring(av.position.z))

		control.commands[admin.Command.VEHICLE_SPAWN].run(src, { 'hella' })
		control.Pump(4)
		local car = control.vehicleCreates[#control.vehicleCreates]
		check('while a ground car is left at the offset',
			car ~= nil and car.position.z == offset.Z, car and tostring(car.position.z))
		check('and both came through the same seam, one record apart',
			#control.vehicleCreates == 2, #control.vehicleCreates)
	end
end

-- ── recovery: money to a character ────────────────────────────────────────
-- THE STAFF DOOR ONTO A PURSE, OBSERVED RATHER THAN READ. The money moves; `me`
-- pays the CONNECTION and never an argument; giving to somebody else lands on
-- their balance and not the operator's; an amount has a ceiling and a fraction,
-- a zero and a currency this server does not have are refused before anything
-- moves; the console has no purse to pay; and a hook that vetoes the transaction
-- is reported as a veto rather than a command that quietly did nothing.
section('recovery: money to a character')
do
	local env, control, why = boot('server')
	check('the server boots for the recovery tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local character = OPX.Modules.Get('character')
		local contract = OPX.Api.Get('character')
		local Command = admin.Command

		-- The last answer the command sent, read off the wire: the wire is what the
		-- operator's client actually reads.
		local function answer()
			for index = #control.clientEvents, 1, -1 do
				if control.clientEvents[index].name == admin.Event.ANSWER then
					return control.clientEvents[index]
				end
			end
			return nil
		end

		-- A loaded Player in the shape the contract reads: the data it owns and the
		-- method it calls on every balance change.
		local function load(id, citizenId, eddies)
			control.Admit(id, 'account-' .. tostring(id))
			OPX.EnsureSession(id)
			character.Players[id] = {
				PlayerData = { citizenId = citizenId, source = id,
					money = { EDDIES = eddies or 0 } },
				Functions = { UpdatePlayerData = function() end },
			}
			return character.Players[id]
		end

		local operator, other = 61, 62
		load(operator, 'citizen-recovery-op', 100)
		load(other, 'citizen-recovery-other', 250)

		local function balance(id)
			return character.Players[id].PlayerData.money.EDDIES
		end

		local function run(source, tokens)
			control.commands[Command.RECOVERY_MONEY].run(source, tokens)
		end

		check('the recovery command is registered and ACL-gated',
			control.commands[Command.RECOVERY_MONEY] ~= nil
				and control.commands[Command.RECOVERY_MONEY].restricted == true,
			tostring(Command.RECOVERY_MONEY))

		-- The map the menu greys its rows by is built from this list, so a command
		-- missing from it is a category whose rows never go grey.
		local listed = false
		for _, entry in ipairs(admin.Server.Commands()) do
			if entry.name == Command.RECOVERY_MONEY then listed = true end
		end
		check('and the command list the access map is built from carries it', listed)

		-- ── the operator's own purse ────────────────────────────────────────
		-- A LOWER-CASE CURRENCY ON PURPOSE: the server's own money command upper-
		-- cases what it is given and so does this one, so a row typed into the form
		-- is not a refusal for its case.
		run(operator, { 'me', 'eddies', '5000' })
		check('`me` pays the CALLER, resolved from the connection and not the line',
			balance(operator) == 5100, tostring(balance(operator)))
		-- The needle is the contract's own formatter, so this says the answer carries
		-- the number the character holds without restating how money is printed.
		check('and the answer names the balance the character holds now',
			answer() ~= nil and answer()[2] == true
				and tostring(answer()[3]):find(contract.FormatMoney(5100, 'EDDIES'), 1, true) ~= nil,
			answer() and tostring(answer()[3]))

		-- ── somebody else's ──────────────────────────────────────────────────
		run(operator, { tostring(other), 'EDDIES', '1000' })
		check('a player id pays THAT character, not the operator',
			balance(other) == 1250 and balance(operator) == 5100,
			('%s/%s'):format(tostring(balance(other)), tostring(balance(operator))))

		-- ── the same door takes it back ─────────────────────────────────────
		run(operator, { tostring(other), 'EDDIES', '-250' })
		check('a negative amount takes money back',
			balance(other) == 1000, tostring(balance(other)))

		-- ── any amount, and where any stops ─────────────────────────────────
		-- The ceiling is the number the amount field itself accepts: ten digits.
		local before = balance(other)
		run(operator, { tostring(other), 'EDDIES', '9999999999' })
		check('an amount up to the ceiling is carried',
			balance(other) == before + 9999999999, tostring(balance(other)))

		before = balance(other)
		run(operator, { tostring(other), 'EDDIES', '10000000000' })
		check('and one digit past it is refused before any money moves',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))

		run(operator, { tostring(other), 'EDDIES', '12.5' })
		check('a fraction is not an amount',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))

		run(operator, { tostring(other), 'EDDIES', '0' })
		check('and neither is zero',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))

		run(operator, { tostring(other), 'GOLD', '10' })
		check('a currency this server does not have is refused',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))

		run(operator, { 'nobody', 'EDDIES', '10' })
		check('and a token that is neither a player id nor me is refused',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))

		-- ── who `me` is ─────────────────────────────────────────────────────
		-- Read from the source, which cannot be forged, so nothing an operator can
		-- type moves the target of the row that says "give myself". A source with no
		-- loaded character is what a connection in the lobby looks like: the target
		-- resolves to them and the contract refuses, because there is no purse to
		-- pay yet -- and the operator's own balance is where it was.
		before = balance(operator)
		run(99, { 'me', 'EDDIES', '10' })
		check('and a connection with no loaded character is refused, not paid',
			balance(operator) == before and answer()[2] == false,
			tostring(balance(operator)))

		-- ── a hook that says no ─────────────────────────────────────────────
		-- The mutator's veto reaches the operator as a refusal, and the balance is
		-- where it was: a transaction a gameplay file blocked must never look like a
		-- transaction that happened.
		local veto = OPX.Hooks.Register('money:beforeAdd', function() return false end, 0)
		before = balance(other)
		run(operator, { tostring(other), 'EDDIES', '500' })
		check('a vetoed transaction is reported as a veto, with no money moved',
			balance(other) == before and answer()[2] == false, tostring(balance(other)))
		OPX.Hooks.Remove(veto)

		-- And with the veto gone the same line pays, so the check above is the hook
		-- and not an unrelated refusal.
		run(operator, { tostring(other), 'EDDIES', '500' })
		check('and the same line pays once the hook is gone',
			balance(other) == before + 500 and answer()[2] == true,
			tostring(balance(other)))
	end
end

-- ── the staff menu: the Recovery category ──────────────────────────────────
-- TWO ROWS AND THE SCREEN THEY LIVE ON, observed through the page the panel is
-- drawn on: the category is offered on the root, its first row is the operator's
-- own purse, pressing that row opens the money form, and the second row leads to
-- the player picker. The greying is checked both ways -- a row the access map
-- grants is open, and the same row without the grant is greyed -- because that
-- map is the only thing telling an operator what their grants are.
section('the staff menu: the Recovery category')
do
	local env, control, why = boot('client')
	check('client boots for the recovery menu tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local locale = env.locale
		local Command = admin.Command

		local OPEN_CHANNEL, FRAME_CHANNEL = 'opx:menu:open', 'opx:menu:frame'

		-- The access map is what an operator's grants look like from here, and it
		-- arrives on its own event: the opener TOGGLES, so asking twice would close
		-- the panel rather than re-read it.
		control.netEvents[admin.Event.OPEN]({ access = { [Command.RECOVERY_MONEY] = true },
			aclKnown = true, inventory = false })

		local page
		for _, candidate in ipairs(control.pages) do
			for _, sent in ipairs(candidate.sent) do
				if sent.channel == OPEN_CHANNEL then page = candidate end
			end
		end
		check('the staff menu opens on a page', page ~= nil)

		if page ~= nil then
			-- The newest rows the page was sent, on either channel: the OPEN
			-- carries the first frame, and a descend carries the next one.
			local function newest()
				for index = #page.sent, 1, -1 do
					local sent = page.sent[index]
					if sent.channel == FRAME_CHANNEL or sent.channel == OPEN_CHANNEL then
						return sent
					end
				end
				return nil
			end

			-- A handle current enough to name a row: every descend updates in place,
			-- but coming back from a form reopens the menu and mints a new one.
			local function handleNow()
				local sent = newest()
				return sent and sent.payload.handle
			end

			local function drawn()
				local sent = newest()
				local out = {}
				for _, row in ipairs(sent and sent.payload.rows or {}) do
					out[#out + 1] = tostring(row.label)
				end
				return out
			end
			local function has(list, wanted)
				for _, value in ipairs(list) do
					if value == wanted then return true end
				end
				return false
			end
			local function isGreyed(label)
				local sent = newest()
				for _, row in ipairs(sent and sent.payload.rows or {}) do
					if tostring(row.label) == label then return row.off == true end
				end
				return nil
			end

			-- ── the category on the root ────────────────────────────────────
			check('the root offers a Recovery category',
				has(drawn(), locale('admin.menu.recovery')), table.concat(drawn(), ' / '))
			check('and its row is open when the access map grants the command',
				isGreyed(locale('admin.menu.recovery')) == false,
				tostring(isGreyed(locale('admin.menu.recovery'))))

			-- The same row with the map saying no: an operator without the grant reads
			-- it as refused rather than pressing it and being refused.
			control.netEvents[admin.Event.ACCESS]({ access = {}, aclKnown = true })
			check('and greyed when the map does not',
				isGreyed(locale('admin.menu.recovery')) == true,
				tostring(isGreyed(locale('admin.menu.recovery'))))

			control.netEvents[admin.Event.ACCESS]({
				access = { [Command.RECOVERY_MONEY] = true }, aclKnown = true })
			check('and open again once the map carries the grant',
				isGreyed(locale('admin.menu.recovery')) == false)

			-- ── the screen it opens ─────────────────────────────────────────
			check('the category opens', admin.Menu.OpenAt('recovery') == true)
			check('on a screen whose first row is the operator\'s own purse',
				admin.Menu.Screen() == 'recovery'
					and OPX.Api.Get('menu').State().value.itemId == 'recoverySelf',
				tostring(admin.Menu.Screen()))
			check('and it is drawn as a row over a picker row',
				has(drawn(), locale('admin.menu.recoverySelf'))
					and has(drawn(), locale('admin.menu.recoveryPlayer')),
				table.concat(drawn(), ' / '))

			-- ── the picker ──────────────────────────────────────────────────
			-- THE ROW UNDER THE PURSE IS THE WHOLE OF "give it to somebody else".
			-- Walked before any form is opened, because opening one suspends the
			-- surface -- a behaviour of its own, and one this category does not
			-- depend on. The roster is pushed the way the server pushes one: in
			-- chunks, the last of which says it is the last, which is when the client
			-- swaps it in.
			control.netEvents[admin.Event.ROSTER]({ offset = 0, done = true,
				rows = { { id = 7, name = 'Matthew', state = 'up', bucket = 0 } } })

			control.PageEmit(page, 'opx:menu:key', { handle = handleNow(), key = 'down' })
			control.PageEmit(page, 'opx:menu:key', { handle = handleNow(), key = 'enter' })
			check('the row under the purse leads to the player picker',
				admin.Menu.Screen() == 'recoveryPlayers', tostring(admin.Menu.Screen()))
			check('which draws a row per player, named for them',
				has(drawn(), '[7] Matthew'), table.concat(drawn(), ' / '))

			-- ── and pressing a player ───────────────────────────────────────
			-- The only difference between the two rows of this category is the target
			-- they carry, and this is where the picked one is carried: the form that
			-- opens is the recovery money form, whose submit is the line
			-- `opx.admin.recovery.money <picked> <account> <amount>`.
			control.PageEmit(page, 'opx:menu:key', { handle = handleNow(), key = 'enter' })
			check('pressing a player opens the money form', admin.Forms.IsOpen() == true)
			local form = OPX.Api.Get('form').State()
			check('and the form is the recovery money form, owned by the panel',
				form.ok and form.value.open == true
					and form.value.form == 'admin.recoveryMoney'
					and form.value.owner == admin.OWNER,
				form.ok and tostring(form.value.form))
			admin.Forms.Close()
		end
	end
end

-- ── a world announcement, and the clips around it ───────────────────────────
-- THE SENTENCE GOES OUT AS THIS MODULE'S OWN EVENT, not through the platform's
-- notification package, and that is what makes the stingers possible at all: only
-- the page that owns a toast's clock can hold a message back until the first clip
-- has played. The wire carries the sentence and its lifetime, and NOTHING about
-- the presentation -- which clips play is each receiving client's own config -- so
-- the last check here is that no clip name is sent to clients at all. A server
-- that started naming files would be handing a path to machines it does not own.
section('a world announcement reaches every client')
do
	local env, control, why = boot('server')
	check('the server boots for the announcement tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local Command = admin.Command

		local ids = { 71, 72, 73 }
		for _, id in ipairs(ids) do
			control.Admit(id, 'account-' .. tostring(id))
			OPX.EnsureSession(id)
		end

		local command = control.commands[Command.WORLD_ANNOUNCE]
		check('the announce command is registered and ACL-gated',
			command ~= nil and command.restricted == true, tostring(Command.WORLD_ANNOUNCE))

		-- Everything the server sent after this point, on any channel, in order.
		local from = #control.clientEvents
		command.run(ids[1], { 'the', 'city', 'is', 'on' })

		-- The chat line goes out on core's own result channel, named here with the
		-- same constructor core names it with rather than as a literal.
		local CHAT = OPX.Event(OPX.Channel.NET, 'runtime', 'commandResult')
		local announced, chatted, answered
		for index = from + 1, #control.clientEvents do
			local event = control.clientEvents[index]
			if event.name == admin.Event.ANNOUNCE then
				announced = announced or {}
				announced[event.source] = event[1]
			elseif event.name == CHAT then
				chatted = (chatted or 0) + 1
			elseif event.name == admin.Event.ANSWER then
				answered = event
			end
		end

		local reached = 0
		local carried = true
		for _, id in ipairs(ids) do
			local payload = announced and announced[id] or nil
			if payload ~= nil then
				reached = reached + 1
				-- The text is what the operator typed, joined with one space by the
				-- rest-of-the-line rule, and the lifetime is the tunable.
				if payload.text ~= 'the city is on' or type(payload.durationMs) ~= 'number' then
					carried = false
				end
				-- PRESENTATION STAYS HOME. A stinger on this payload would be a clip
				-- name chosen by the server for a client it does not own.
				if payload.stinger ~= nil then carried = false end
			end
		end
		check('every player is sent the announcement, the sender included', reached == #ids,
			tostring(reached))
		check('carrying the sentence and a lifetime, and no clip of its own', carried)

		check('each of them also gets the chat line, as before', chatted == #ids,
			tostring(chatted))
		check('and the operator is told how many received it',
			answered ~= nil and answered[2] == true and tostring(answered[3]):find('3', 1, true) ~= nil,
			answered and tostring(answered[3]))

		local newest = admin.Server.Recent(1)[1]
		check('and the line is in the audit trail with what was said',
			newest ~= nil and newest.event == 'admin.world.announce'
				and tostring(newest.detail):find('the city is on', 1, true) ~= nil,
			newest and tostring(newest.event))

		-- An empty line is refused rather than sent to everybody.
		from = #control.clientEvents
		command.run(ids[1], { '   ' })
		local sent = 0
		for index = from + 1, #control.clientEvents do
			if control.clientEvents[index].name == admin.Event.ANNOUNCE then sent = sent + 1 end
		end
		check('an announcement with no words reaches nobody', sent == 0, tostring(sent))
	end
end

-- ── the stinger a client plays around an announcement ───────────────────────
-- THE CLIENT HALF READS THE CLIPS FROM ITS OWN CONFIG and hands them to the toast,
-- and `core/client/notify.lua` is the one place that decides what a toast may
-- carry. The rule that matters here is the one a served config depends on: a clip
-- name is a BARE FILE NAME resolved under the page's own `audio/`, because the
-- page belongs to someone else's machine and a name able to climb out of that
-- directory would be a name able to make every client in the city fetch from
-- wherever a config pointed. A name that does not fit is DROPPED -- the clip, not
-- the message -- and the last checks here are that the pack really ships the two
-- files the shipped config names.
section('the stinger a client plays around an announcement')
do
	local env, control, why = boot('client')
	check('client boots for the stinger tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local locale = env.locale

		-- The newest toast the runtime sent to the page, on any page: the overlay is
		-- one surface, and a test that assumed which one would be fragile.
		local function lastToast()
			local found
			for _, page in ipairs(control.pages) do
				for index = 1, #page.sent do
					if page.sent[index].channel == 'opx:notify:show' then
						found = page.sent[index].payload
					end
				end
			end
			return found
		end

		check('the announcement channel is wired on this client',
			control.netEvents[admin.Event.ANNOUNCE] ~= nil)

		control.netEvents[admin.Event.ANNOUNCE]({ text = 'the city is on', durationMs = 12000 })
		local toast = lastToast()
		check('an announcement raises a toast', toast ~= nil)
		check('carrying the operator\'s sentence',
			toast ~= nil and toast.message == 'the city is on',
			toast and tostring(toast.message))
		check('under the announcement title, in this client\'s own language',
			toast ~= nil and toast.title == locale('admin.announce.title'),
			toast and tostring(toast.title))
		check('for as long as the server said', toast ~= nil and toast.durationMs == 12000,
			toast and tostring(toast.durationMs))
		check('on one fixed id, so a second replaces the first',
			toast ~= nil and toast.id == 'opx.admin.announce', toast and tostring(toast.id))
		check('as the kind that does not look like a "saved" toast',
			toast ~= nil and toast.kind == 'warning', toast and tostring(toast.kind))
		check('and the two clips this client configured',
			toast ~= nil and type(toast.stinger) == 'table'
				and toast.stinger.open == 'announce-open.mp3'
				and toast.stinger.close == 'announce-close.mp3',
			toast and toast.stinger and tostring(toast.stinger.open))
		check('at the configured volume',
			toast ~= nil and toast.stinger ~= nil and toast.stinger.volume == 0.8,
			toast and toast.stinger and tostring(toast.stinger.volume))

		-- ── a name that could leave the page ────────────────────────────────
		-- The config is served, so this is the case a hostile or careless server
		-- settings file produces. Both halves are checked: the clip is dropped, and
		-- the sentence it wrapped still arrives.
		local settings = admin.Settings.ANNOUNCE
		local kept = settings.STINGER
		settings.STINGER = { OPEN = '../../secrets.mp3', CLOSE = 'announce-close.mp3', VOLUME = 4 }

		control.netEvents[admin.Event.ANNOUNCE]({ text = 'still delivered', durationMs = 5000 })
		local second = lastToast()
		check('a clip name that could leave the page is dropped, not obeyed',
			second ~= nil and second.stinger ~= nil and second.stinger.open == '',
			second and second.stinger and tostring(second.stinger.open))
		check('and the message it was wrapping is still delivered',
			second ~= nil and second.message == 'still delivered',
			second and tostring(second.message))
		check('while a volume above full is clamped rather than obeyed',
			second ~= nil and second.stinger ~= nil and second.stinger.volume == 1,
			second and second.stinger and tostring(second.stinger.volume))
		settings.STINGER = kept

		-- ── the files a client actually downloads ───────────────────────────
		-- `web/` is what the resource ships, so a name in the config that is not in
		-- it is a stinger that silently never plays for anybody.
		local shipped = admin.Section('ANNOUNCE').STINGER
		for _, name in ipairs({ shipped.OPEN, shipped.CLOSE }) do
			local file = io.open('web/audio/' .. tostring(name), 'rb')
			check(('the pack ships the clip %s'):format(tostring(name)), file ~= nil)
			if file ~= nil then file:close() end
		end
	end
end

print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
