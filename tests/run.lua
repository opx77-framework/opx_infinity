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
