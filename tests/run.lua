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
	-- The one glyph vocabulary, in `core/shared/glyphs.lua`. It is on `OPX`
	-- rather than inside the toast because `target` and `menu` validate
	-- against it too, and the three copies that preceded it -- 47 names, 45
	-- and 14 -- are what a shared name is for.
	Glyphs = true,
	Modules = true, Api = true, Schema = true, Scheduler = true,
	-- The one job gate, in `lib/shared/jobgate.lua`. On `OPX` and not inside a
	-- module for the same reason `Glyphs` is: `elevators` and `teleports` both
	-- decide who may pass, on both halves, and the copy that drifted would be
	-- the one saying somebody may.
	JobGate = true,
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
	-- CLIENT ONLY, and deliberately: `Note` is a client saying something to the
	-- operator's journal, and the server already has one. The server half of it
	-- is a net handler, which hangs off nothing.
	Note = true,
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

		-- THE OTHER HALF OF THE FITTING-ROOM POLICY, and until it existed there
		-- was no other half. `OFFER_POLICY` decides which world enters are HANDED
		-- a room; the contract has carried `OpenPanel` and `OpenWardrobe` since
		-- they were written and NOTHING IN THIS RUNTIME CALLED EITHER, so under
		-- 'first' or 'never' a player who closed the room could not reach it
		-- again for the life of the character. Unrestricted, because it opens
		-- nothing but the asking player's own clothes.
		check('/opx.appearance is registered, and open to everybody',
			control.commands['opx.appearance'] ~= nil
				and not control.commands['opx.appearance'].restricted,
			control.commands['opx.appearance'] == nil and 'not registered' or 'restricted')
		check('no thread died', #control.log.error == 0 or not table.concat(control.log.error)
			:find('thread died'), table.concat(control.log.error, ' | '))

		-- WHAT A CHARACTER MAY BE SAID TO BE WEARING. There is no catalogue on a
		-- server, so the canonical form is a SHAPE check and can never be a
		-- lookup -- the equipment natives are client-only and asking the client
		-- would be trusting the thing this distrusts. But the shape was
		-- `[%w_%.%-]+`, which is every TweakDB id there is: a client could report
		-- its outer chest as `Character.Judy` and the server would store it.
		-- Every clothing record is in the `Items` namespace, so the anchor is one
		-- pattern and a whole family of nonsense stops passing.
		local clothing = env.OPX.Modules.Get('appearance').Clothing
		local function canonical(record)
			return clothing.Canonical({ schemaVersion = clothing.VERSION,
				equipment = { OuterChest = record }, wardrobe = {} })
		end
		check('a clothing record outside the Items namespace is refused',
			canonical('Character.Judy') == nil and canonical('Vehicle.Cthulhu') == nil)
		check('and one inside it still is not', canonical('Items.Jacket_01') ~= nil)
		check('the namespace has to be the whole prefix, not a substring',
			canonical('NotItems.Jacket_01') == nil and canonical('Items') == nil)

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
		--
		-- 2000ms IS `ADMIN_TAGS_REFRESH_MS`, and this used to expect 500 -- which
		-- is the FLOOR that `server/tags.lua` passes to `OPX.Tune.Number` for the
		-- case where the key cannot be read. The tunables stub in `host.lua`
		-- answered the declaration instead of a live proxy, so every tunable in
		-- the suite read as its caller's floor and this check was asserting that
		-- the harness was broken. See the note on the stub.
		-- The old assertion passed whether the tunable worked or not, which is
		-- the one thing it existed to tell apart.
		check('a job may take its cadence from a live tunable',
			report:find('admin:tag%-sweep%s+2000ms') ~= nil,
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
-- ── a source that arrives as a string ────────────────────────────────────────
-- Four functions in `core/server/answer.lua` open with `source = tonumber(source)`
-- and two did not: `CommandResult` and `CommandNotice` went straight to
-- `source > 0`, so a source handed over as a string -- which is how a console and
-- some host paths do it -- raised `attempt to compare string with number` instead
-- of answering. The two that raised are the two a COMMAND answers through.
section('a source that arrives as a string')
do
	local env, _, why = boot('server')
	check('the server boots', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		check('CommandResult takes a string source without raising',
			(pcall(OPX.CommandResult, '1', true, 'hello')))
		check('CommandNotice takes one too',
			(pcall(OPX.CommandNotice, '1', 'test', 'success', 'done', false)))
		check('and the console path still works on a nil source',
			(pcall(OPX.CommandResult, nil, true, 'console')))
	end
end

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
		control.Pump(20)
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
			actions = { { id = 'cancel', label = 'Skip' },
				{ id = 'save', label = 'Wear this', primary = true } },
			sliders = {
				{ id = 'InnerChest', label = 'Inner chest', count = 270, index = 0,
					value = 'nothing' },
				{ id = 'OuterChest', label = 'Outer chest', count = 677, index = 4,
					value = 'Jacket 04' },
			},
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

		-- SEVEN INTEGERS, NOT 1968 ROWS, and the first frame is the finished one.
		-- The room used to publish `loading = true` and then stream its catalogue
		-- over some twenty-six batches; every one of them was a payload, a parse
		-- and an append, and the run died part way through with nothing said.
		check('the room first frame carries its sliders, counts and all',
			opened ~= nil and #opened.payload.sliders == 2
				and opened.payload.sliders[2].count == 677
				and opened.payload.sliders[2].index == 4,
			opened and tostring(#opened.payload.sliders))
		check('and says nothing about loading, because there is nothing to wait for',
			opened ~= nil and opened.payload.loading ~= true)
		check('and asks for no search plate over rows it no longer sends',
			opened ~= nil and opened.payload.search == false,
			opened and tostring(opened.payload.search))
		check('THE STREAM IS GONE: the room appends no items at all',
			times(page, 'opx:panel:items') == 0,
			('%d batch(es)'):format(times(page, 'opx:panel:items')))

		-- A SLIDER OUT OF STEP WITH ITS OWN TRACK IS REFUSED WHOLE, the way every
		-- other field of this contract is: a thumb past the end of the range is a
		-- caller that has lost its list, and drawing it would leave the page's
		-- idea of the position and the caller's permanently apart.
		local Panel = env.OPX.Api.Get('panel')
		local handle = opened.payload.handle
		local badThumb = Panel.Update(handle,
			{ sliders = { { id = 'Legs', label = 'Legs', count = 3, index = 9, value = 'x' } } })
		check('a thumb outside its own track is refused',
			not badThumb.ok and badThumb.error == 'invalid_sliders', tostring(badThumb.error))
		local badCount = Panel.Update(handle,
			{ sliders = { { id = 'Legs', label = 'Legs', count = -1, index = 0, value = 'x' } } })
		check('and so is a range of less than nothing',
			not badCount.ok and badCount.error == 'invalid_sliders', tostring(badCount.error))

		-- THE APPEND PATH STILL HAS TO WORK, and it is tested against the contract
		-- rather than through the fitting room now, because the fitting room no
		-- longer uses it. The defect it guards is the panel module's own: a
		-- hundred parsed items is 1207 value nodes against a host bound of 1024,
		-- the host refused every batch, `WebUI.Page.send` answered false and this
		-- module reported the refusal to its caller as a delivery.
		local mark, turned = #page.sent, #page.refused
		local bulk = {}
		for index = 1, 200 do
			local record = ('Items.Jacket_%03d_basic_variant'):format(index)
			bulk[index] = { id = record, tab = 'InnerChest',
				label = ('Jacket %03d basic variant'):format(index), detail = record }
		end
		local appended = Panel.Append(handle, bulk, true)
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
		-- That is a real defect and it is not this one.
		check('a batch at the append bound is taken', appended.ok, tostring(appended.error))
		check('the host turns away no catalogue batch',
			#page.refused == turned,
			#page.refused > turned
				and ('%s at %d nodes'):format(page.refused[turned + 1].channel,
					page.refused[turned + 1].nodes) or '')
		check('and it reaches the page whole', drawn == 200,
			('%d of 200, over %d send(s)'):format(drawn, sends))
		check('over more than one send, because one would not have fitted',
			sends > 1, ('%d send(s)'):format(sends))
		check('and exactly one of them says the batch has ended',
			dones == 1, ('%d done flag(s)'):format(dones))

		-- WHAT THE PLAYER DID, coming back through the one function the seam
		-- documents. Everything on it is re-checked there against state this bridge
		-- cannot see: the index against the track that was drawn, the button
		-- against the list that was drawn.
		local seen, carried = {}, {}
		local real = appearance.FromView
		appearance.FromView = function(action, payload)
			seen[#seen + 1] = action
			carried[#carried + 1] = payload
			return real(action, payload)
		end
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'OuterChest', index = 12, commit = true })
		control.PageEmit(page, 'opx:panel:action', { handle = handle, id = 'cancel' })
		check('a slider let go comes back as a room slide',
			seen[1] == 'room.slide', table.concat(seen, ', '))
		check('carrying the slot, the index and that it was committed',
			carried[1] ~= nil and carried[1].slot == 'OuterChest'
				and carried[1].index == 12 and carried[1].commit == true,
			carried[1] and tostring(carried[1].slot) .. '/' .. tostring(carried[1].index))
		check('and a button as a room action', seen[2] == 'room.action',
			table.concat(seen, ', '))

		-- NEITHER END TRUSTS THE INDEX. `panel` checks it against the track it
		-- drew, which is what stops a modified page naming a position the caller's
		-- own list does not have.
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'OuterChest', index = 4000, commit = true })
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Nonesuch', index = 1, commit = true })
		check('an index past the end of the track never reaches the state half',
			#seen == 2, table.concat(seen, ', '))

		-- A PAYLOAD FOR A ROOM THAT IS GONE. The handle is the capability, and a
		-- payload naming another one is dropped before this bridge ever sees it --
		-- so a late answer cannot reach the state half.
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle + 99, id = 'OuterChest', index = 1, commit = true })
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
		control.Pump(20)
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

		--- Every note this client has sent the server, as one string.
		--- On the CORE event now, and filed under this module's id: the module's own
		--- relay converged on `OPX.Note`, so a note is `(module, text)`.
		local function toldServer()
			local note = env.OPX.Event(env.OPX.Channel.NET, 'runtime', 'note')
			local said = {}
			for index = 1, #control.serverEvents do
				local sent = control.serverEvents[index]
				if sent.name == note and sent[1] == 'appearance' then
					said[#said + 1] = tostring(sent[2])
				end
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
		-- THE ANNOUNCEMENT'S OWN SILENCE. `not_announced` above is this module's
		-- answer to the clothing half and says nothing about why; every `return
		-- false` in `Announce` used to be silent, so the chain ended at the word
		-- and three diagnoses were argued from it.
		check('and the announcement that is holding it names its own clause',
			toldServer():find('gameplay-ready is held by no_gameplay_world', 1, true) ~= nil,
			toldServer())
	end

	--- Every note a client has sent the server under this module's id, as one
	--- string. The block above has its own copy, scoped to itself; this is the one
	--- the blocks below share.
	local function notesOf(env, control)
		local note = env.OPX.Event(env.OPX.Channel.NET, 'runtime', 'note')
		local said = {}
		for index = 1, #control.serverEvents do
			local sent = control.serverEvents[index]
			if sent.name == note and sent[1] == 'appearance' then said[#said + 1] = tostring(sent[2]) end
		end
		return table.concat(said, ' | ')
	end

	-- ── the forty seconds that were somebody building a face ─────────────────
	-- THE CLOTHING GIVE-UP MEASURED THE WRONG THING. Its clock started when the
	-- character arrived, and on a join-time creation the character arrives BEFORE
	-- the creator opens: the player then stands in the game's own screen for as
	-- long as they like -- which this module has no deadline for anywhere, on
	-- purpose -- while forty seconds of budget meant for "a gate nothing is doing
	-- anything about" run out underneath them. Measured on the live server on
	-- 2026-09-20: creator up at 14:46:47, face stored at 14:47:57, this gate gave
	-- up at 14:47:27.
	do
		local env, control = joinClient('always', 400)
		local appearance = env.OPX.Modules.Get('appearance')

		control.Fire(env.OPX.Event(env.OPX.Channel.LOCAL, 'character', 'loaded'),
			{ citizenId = 'citizen-creating', charInfo = { gender = 'female' }, clothing = false })

		local decisions = {}
		env.AddEventHandler(appearance.Event.ON_DECISION, function(payload)
			if type(payload) == 'table' and payload.event == 'clothingRestored' then
				decisions[#decisions + 1] = tostring(payload.ok) .. '/' .. tostring(payload.error)
			end
		end)

		-- The creator on screen, which is the whole of the difference.
		appearance.Face.creating = true
		check('a creation names itself, rather than the announcement it is holding up',
			appearance.Clothing.Shut() == 'creating', tostring(appearance.Clothing.Shut()))

		-- Well past GATE_GIVEUP_MS: 48 seconds against a budget of 40.
		control.Pump(480)
		check('and a creation longer than the give-up window does not spend it',
			appearance.Clothing.Report() == 'waiting', appearance.Clothing.Report())
		check('so nothing is published saying the clothes can never go on',
			#decisions == 0, table.concat(decisions, ', '))
		check('the operator is told what is holding it, once',
			select(2, notesOf(env, control):gsub('waits on creating', '')) == 1,
			notesOf(env, control))

		-- THE NET IS AIMED, NOT REMOVED. The moment the screen comes down the full
		-- window is available again -- and it still runs out.
		appearance.Face.creating = false
		control.Pump(480)
		check('and the give-up still fires once the screen the player was in comes down',
			appearance.Clothing.Report() == 'failed', appearance.Clothing.Report())
		check('naming the clause that is left rather than the creation that ended',
			notesOf(env, control):find('was never put on: not_announced', 1, true) ~= nil,
			notesOf(env, control))
	end

	-- ── an expiry is not a policy refusal ────────────────────────────────────
	-- THE TWO OUTCOMES THE JOURNAL COULD NOT TELL APART. Under 'first' the offer
	-- test is one boolean -- was this a creation -- and `clothingRestored` carries
	-- `creation = false` because it is the stored record going on. So a creation
	-- whose room ran out of its window and came round again on the clothes was
	-- answered "the policy is first and this is not a creation": a sentence about
	-- the operator's choice, describing a clock. Only one of those two is
	-- anybody's decision.
	do
		local env, control = joinClient('first', 400)
		local appearance = env.OPX.Modules.Get('appearance')

		arrive(env, control, 'citizen-expired')
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'created', citizenId = 'citizen-expired' })
		check('a creation is owed its room', appearance.Wardrobe.Owed() == true)

		control.Pump(12)
		check('the window runs out with no room ever drawn',
			appearance.Wardrobe.Owed() == false)
		check('and the journal calls that an expiry, not a refusal',
			notesOf(env, control):find('expired after', 1, true) ~= nil, notesOf(env, control))

		-- A world entry with nothing owed clears the once-per-entry guard, exactly
		-- as it is meant to -- which is what puts the expired offer back in front
		-- of the policy test at all. Without this the guard hides the defect
		-- rather than fixing it, and the check below would pass on a module that
		-- still cannot tell the two outcomes apart.
		control.Fire(env.OPX.Host.WORLD_READY)

		-- The clothes finally go on, seconds later, exactly as they did on the
		-- server: same character, same join, same creation.
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'clothingRestored', citizenId = 'citizen-expired' })
		check('THE EXPIRY IS NOT RE-DECIDED AS A POLICY REFUSAL',
			notesOf(env, control):find('is not a creation', 1, true) == nil,
			notesOf(env, control))
		check('it is resumed as the creation offer it always was',
			appearance.Wardrobe.Owed() == true, notesOf(env, control))

		-- And once only: a resumed offer that expires again is reported and left
		-- alone, or a world entry could offer the same room for ever.
		control.Pump(12)
		check('a second expiry withdraws the claim again',
			appearance.Wardrobe.Owed() == false)
		control.Fire(env.OPX.Host.WORLD_READY)
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'clothingRestored', citizenId = 'citizen-expired' })
		check('and is not resumed a second time',
			appearance.Wardrobe.Owed() == false,
			notesOf(env, control))
		check('still without ever calling it a policy refusal',
			notesOf(env, control):find('is not a creation', 1, true) == nil,
			notesOf(env, control))
	end

	-- ── the world a creation's own bootstrap answer loads ────────────────────
	-- THE OTHER HALF, AND IT IS STRUCTURAL RATHER THAN A RACE. The game's creator
	-- is the pre-game menu's screen: `FinishCreation` spends the character
	-- bootstrap on the body it built, and the world that comes up afterwards
	-- raises `worldReady`. Every creation therefore reaches that handler seconds
	-- after `created`, with its offer live -- and the handler used to clear
	-- `roomOffered` unconditionally, which threw away the offer this join was in
	-- the middle of and let `clothingRestored` walk through the guard that exists
	-- to stop precisely that.
	do
		local env, control = joinClient('first', 60000)
		local appearance = env.OPX.Modules.Get('appearance')

		arrive(env, control, 'citizen-bootstrapped')
		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'created', citizenId = 'citizen-bootstrapped' })
		check('the creation is owed a room with a long window to open in',
			appearance.Wardrobe.Owed() == true)

		control.Fire(env.OPX.Host.WORLD_READY)
		check('the world the creation itself loaded does not withdraw the claim',
			appearance.Wardrobe.Owed() == true, notesOf(env, control))

		env.TriggerEvent(appearance.Event.ON_DECISION,
			{ ok = true, event = 'clothingRestored', citizenId = 'citizen-bootstrapped' })
		check('and the clothes going on do not re-decide the live offer by policy',
			notesOf(env, control):find('is not a creation', 1, true) == nil,
			notesOf(env, control))
		check('the offer that is still running is the one that stands',
			select(2, notesOf(env, control):gsub('a fitting room is owed', '')) == 1,
			notesOf(env, control))
	end

	-- ── the catalogue, read per slot, standing behind seven sliders ──────────
	-- A REAL ROOM, OPENED. The blocks above drive the seam by hand, which proves
	-- the bridge and proves nothing about the read: the defect that cost this room
	-- its catalogue lived entirely in the state half, between the one unfiltered
	-- `records` call and the page. So this one puts a puppet under it -- a
	-- playable character, an equipment namespace answering per slot, and a
	-- clothing half that lends the body -- and opens the room for real.
	--
	-- The lend is stubbed and the rest is not. `Clothing.BeginPreview` is step
	-- four of a state machine that wants a stored record, a completed save and an
	-- open gate; this host never announces gameplay so its gate never opens, which
	-- the block above tests on purpose. Standing in for the two preview calls is
	-- what lets everything AFTER them be the real thing.
	-- ── where the camera is told to stand ────────────────────────────────────
	-- THE ARITHMETIC ON ITS OWN, because the arithmetic is what was wrong. The
	-- room's whole framing used to be `Open77.camera.orbit`, a yaw INSIDE the
	-- third-person rig which the platform says in as many words "cannot move the
	-- view off the player" -- so the character stayed pinned off the centreline
	-- and the reported defect ("le perso est a droite") could not be fixed by
	-- turning anything. `Framing` is the offset that replaces it, and a camera
	-- offset is the one part of a camera a test without a screen can hold.
	do
		local env = boot('client')
		local appearance = env.OPX.Modules.Get('appearance')
		local Framing = appearance.Wardrobe.Framing
		local SHOT = { CAMERA_OFFSET = { X = 0.0, Y = 2.6, Z = 1.1 } }

		-- A room facing the front stands the camera where the operator said: in
		-- front, at chest height, and -- the fix -- on the centreline.
		local x, y, z = Framing(SHOT, 180)
		check('the front view stands the camera on the body\'s centreline',
			x == 0.0, tostring(x))
		check('and in front of it, at the height it was given',
			y == 2.6 and z == 1.1, ('y=%s z=%s'):format(tostring(y), tostring(z)))

		-- Turning walks the camera AROUND the puppet, because with the camera off
		-- the body there is no rig left for a yaw to yaw. Back is the front offset
		-- negated; the height never changes, because walking round somebody does
		-- not change how tall you are.
		local bx, by, bz = Framing(SHOT, 0)
		check('the back view is the same distance on the other side',
			math.abs(bx) < 1e-9 and math.abs(by + 2.6) < 1e-9 and bz == 1.1,
			('x=%.4f y=%.4f z=%s'):format(bx, by, tostring(bz)))

		-- A QUARTER TURN SWAPS THE AXES AND KEEPS THE DISTANCE. This is the check
		-- that would catch the rotation being written with a sign or a pair of
		-- terms the wrong way round -- the two mistakes that look right at 0 and
		-- 180 degrees and are wrong everywhere else.
		local sx, sy = Framing(SHOT, 90)
		check('a quarter turn stands the camera off to the side, same distance out',
			math.abs(math.abs(sx) - 2.6) < 1e-9 and math.abs(sy) < 1e-9,
			('x=%.4f y=%.4f'):format(sx, sy))

		-- ── what is refused, and why each one has to be ──
		check('no offset at all leaves the camera on the body',
			Framing({}, 180) == nil)
		check('and so does a half-written one: two axes are not a request',
			Framing({ CAMERA_OFFSET = { X = 0.0, Y = 2.6 } }, 180) == nil)
		-- A camera standing inside the puppet is the bug with extra steps, and a
		-- stray zero in a config would otherwise render the inside of a chest --
		-- which looks exactly like the room failing to open.
		check('an offset of nothing is not a shot',
			Framing({ CAMERA_OFFSET = { X = 0.0, Y = 0.0, Z = 0.0 } }, 180) == nil)
		-- The platform will happily put the view in the next district. A typo
		-- there is a black frame with a working menu on it.
		check('and an offset past any clothing shot is a typo, not a wish',
			Framing({ CAMERA_OFFSET = { X = 0.0, Y = 400.0, Z = 1.1 } }, 180) == nil)
	end

	do
		local env, control = joinClient('never', 400)
		local appearance = env.OPX.Modules.Get('appearance')
		local page = control.pages[1]

		-- How many pieces each slot answers. Uneven on purpose: the buckets the old
		-- stream sorted were assumed to be "roughly a seventh each" and the live
		-- catalogue is 677 in one slot against 38 in another, which is what made
		-- the one unyieldable sort the heaviest thing in the room.
		local COUNTS = { Head = 3, Face = 0, InnerChest = 2, OuterChest = 5, Legs = 1,
			Feet = 4, Outfit = 0 }
		local asked = {}
		env.Open77.equipment.records = function(options)
			if type(options) ~= 'table' or type(options.slot) ~= 'string' then
				return nil, 'invalid_options'
			end
			asked[#asked + 1] = options.slot
			local out = {}
			for index = 1, (COUNTS[options.slot] or 0) do
				-- Answered out of order, so the sort has something to do, and with
				-- one non-visual entry the room must drop rather than count.
				out[index] = { record = ('Items.%s_%02d'):format(options.slot,
					(COUNTS[options.slot] + 1) - index) }
			end
			out[#out + 1] = { record = ('Items.%s_hidden'):format(options.slot), nonvisual = true }
			return out
		end

		local worn = {}
		env.Open77.equipment.apply = function(slots)
			for slot, item in pairs(slots) do worn[slot] = item end
			return true
		end
		env.Open77.character.state = function()
			return { health = 100, alive = true, attached = true }
		end

		local lent, gaveBack = nil, nil
		appearance.Clothing.BeginPreview = function(owner)
			lent = owner
			return { equipment = { OuterChest = 'Items.OuterChest_02' } }
		end
		appearance.Clothing.EndPreview = function(owner, keep)
			gaveBack = tostring(owner) .. '/' .. tostring(keep)
			return true
		end

		-- THE CAMERA, WHICH THE BASE HOST DOES NOT INSTALL. Without it every
		-- camera call in the room takes its native-absent path, which is a real
		-- case but the one that proves nothing: the defect being fixed here is
		-- that the room never moved the camera off the player at all, and only a
		-- host that HAS `detach` can show that it now does.
		local shots, fovs = {}, {}
		env.Open77.camera = {
			detach = function(x, y, z)
				shots[#shots + 1] = { x = x, y = y, z = z }
				return true
			end,
			view = function() return { fov = 68.0 } end,
			setFov = function(degrees) fovs[#fovs + 1] = degrees return true end,
			orbit = function() return true end,
			clearOrbit = function() return true end,
		}

		local opened, reason = appearance.Wardrobe.Open('appearance')
		check('the fitting room is asked for', opened, tostring(reason))
		control.Pump(30)
		check('and the puppet was borrowed for it', lent == 'appearance', tostring(lent))
		check('the room is open', appearance.Wardrobe.IsOpen())

		-- ── the camera stands off the body, centred ──────────────────────────
		-- THE REPORTED DEFECT, PINNED. "la camera n'est pas centrer sur le perso,
		-- le perso est a droite" -- the third-person rig is pinned over the
		-- player's shoulder and `camera.orbit` is a yaw INSIDE that rig, so no
		-- amount of orbiting centres anything. What must be true now is that the
		-- room CALLS `detach`, and that the lateral offset it detaches to is zero
		-- -- zero across is the body's own centreline, and the centreline is the
		-- middle of the frame.
		check('the room took the camera off the body', #shots == 1,
			('%d detach call(s)'):format(#shots))
		check('and stood it on the puppet\'s centreline, in front and at chest height',
			#shots == 1 and shots[1].x == 0.0 and shots[1].y > 0 and shots[1].z > 0,
			#shots == 1 and ('x=%s y=%s z=%s'):format(shots[1].x, shots[1].y, shots[1].z) or 'none')

		-- AND THE LENS IS LEFT ALONE. Widening was the previous attempt at this
		-- and it made the framing worse rather than better -- a wider lens on a
		-- rig that is still pinned off-centre pushes the subject further towards
		-- the edge. A camera that really stood back must not also widen, or the
		-- fix and the defect ship together.
		check('and did not widen the lens on top of it', #fovs == 0,
			table.concat(fovs, ', '))

		-- The turn buttons walk the camera AROUND the puppet now, because with the
		-- camera off the body there is no rig left for a yaw to yaw. Back is 180
		-- degrees from the front, so the offset in front becomes the same distance
		-- behind -- and the height does not change, because walking round somebody
		-- does not change how tall you are.
		appearance.FromView('room.action', { value = 'back' })
		local front, behind = shots[1], shots[#shots]
		check('turning the room round walks the camera round the puppet',
			#shots == 2 and math.abs(behind.y + front.y) < 0.001
			and math.abs(behind.z - front.z) < 0.001,
			('%d shot(s)'):format(#shots))
		appearance.FromView('room.action', { value = 'front' })

		-- ONE QUERY PER SLOT is the whole of the fix, so it is the first thing
		-- asserted: the old room asked once, unfiltered, for up to two thousand
		-- records and did the slotting itself.
		check('the catalogue is read one slot at a time, each slot named',
			table.concat(asked, ',') == 'Head,Face,InnerChest,OuterChest,Legs,Feet,Outfit',
			('%d read(s): %s'):format(#asked, table.concat(asked, ', ')))

		local frame = drew(page, 'opx:panel:open')
		check('the room drew its first frame', frame ~= nil)
		check('and no catalogue batch was ever appended to it',
			times(page, 'opx:panel:items') == 0,
			('%d batch(es)'):format(times(page, 'opx:panel:items')))

		--- The slider drawn for one slot, out of the last frame or patch.
		local function slider(slot)
			local latest
			for index = 1, #page.sent do
				local sent = page.sent[index]
				if sent.payload.sliders ~= nil then
					for _, entry in ipairs(sent.payload.sliders) do
						if entry.id == slot then latest = entry end
					end
				end
			end
			return latest
		end

		check('one slider per visible slot, and seven of them',
			frame ~= nil and #frame.payload.sliders == 7,
			frame and tostring(#frame.payload.sliders))
		-- THE COUNT IS THE SLOT'S OWN, which is the thing seven queries buy: the
		-- room holds seven lists and the page is told seven lengths.
		check('each slider counts that slot pieces, and only that slot',
			slider('OuterChest').count == 5 and slider('Head').count == 3
				and slider('Legs').count == 1,
			('OuterChest=%d Head=%d Legs=%d'):format(slider('OuterChest').count,
				slider('Head').count, slider('Legs').count))
		-- A record the room will not show is not a position on the track either.
		check('a non-visual record is not a position anybody can stand on',
			slider('Feet').count == 4, tostring(slider('Feet').count))
		-- A SLOT WITH NOTHING IN IT IS STILL A SLIDER. The old room hid an empty
		-- slot behind a tab that said 'Nothing here for this slot'; a track of
		-- length nought says the same thing without a tab to find it behind.
		check('an empty slot is a track with one position on it',
			slider('Face').count == 0 and slider('Face').index == 0)

		-- INDEX 0 IS 'NOTHING', everywhere: it is where an empty slot starts, it
		-- is what a slot the body is not wearing reports, and it is what taking a
		-- piece off means now that there is no 'Take off' button.
		check('a slot the puppet is not wearing starts on nothing',
			slider('InnerChest').index == 0 and slider('InnerChest').value == 'nothing',
			tostring(slider('InnerChest').value))
		-- Sorted, so `Items.OuterChest_02` is the second position although the
		-- catalogue answered it fourth.
		check('and a slot the puppet IS wearing starts on that piece',
			slider('OuterChest').index == 2 and slider('OuterChest').value == 'Outer Chest 02',
			('%d/%s'):format(slider('OuterChest').index, tostring(slider('OuterChest').value)))

		-- THE SLIDER SELECTS BY INDEX, and the index is all the page ever sends:
		-- turning one into a record name is the state half's job, because it is
		-- the only side holding the list.
		local handle = frame.payload.handle
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Head', index = 3, commit = true })
		check('a committed index puts that position piece on the puppet',
			worn.Head == 'Items.Head_03', tostring(worn.Head))
		check('and the slider follows it, with the one label the page is told',
			slider('Head').index == 3 and slider('Head').value == 'Head 03',
			('%d/%s'):format(slider('Head').index, tostring(slider('Head').value)))

		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Head', index = 0, commit = true })
		check('index 0 takes the piece off rather than naming one',
			worn.Head == false and slider('Head').index == 0
				and slider('Head').value == 'nothing',
			tostring(worn.Head))

		-- An uncommitted move is a fitting, not a choice: the body wears it and
		-- the save would not keep it.
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Legs', index = 1, commit = false })
		check('an uncommitted move still dresses the puppet',
			worn.Legs == 'Items.Legs_01', tostring(worn.Legs))

		-- TWO SLOTS PREVIEWING 'NOTHING' ARE TWO PREVIEWS, and the fitting is keyed
		-- on the slot as well as the record to say so: `false` is a legitimate
		-- thing to try on, so a record on its own cannot tell one empty slot from
		-- another and the second preview would be skipped as a repeat of the
		-- first -- leaving the first slot's piece off the body for good.
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Feet', index = 2, commit = true })
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'Feet', index = 0, commit = false })
		control.PageEmit(page, 'opx:panel:slide',
			{ handle = handle, id = 'InnerChest', index = 0, commit = false })
		check('previewing nothing on one slot does not leave another undressed',
			worn.Feet == 'Items.Feet_02', tostring(worn.Feet))

		-- ── the category strip, and what gates each row ──────────────────────
		-- WIRED, NOT BUILT. Saved outfits, share codes and the job gate all
		-- already existed in `modules/shops` -- the table, the codes, `looksFor`
		-- -- and not one client in this resource ever sent `SAVE`, `LIST`, `LOAD`,
		-- `DELETE`, `SHARE` or `REDEEM`. What is asserted here is the door: the
		-- strip reaches the page, and which rows are on it.
		--- The category row the page was last sent.
		local function groups()
			local latest
			for index = 1, #page.sent do
				if page.sent[index].payload.groups ~= nil then
					latest = page.sent[index].payload.groups
				end
			end
			return latest
		end

		--- Whether the strip carries a button whose id ends in `name`.
		local function hasGroup(name)
			for _, row in ipairs(groups() or {}) do
				if row.id == 'shops:' .. name then return true end
			end
			return false
		end

		check('the fitting room carries a category strip', groups() ~= nil,
			'no groups ever reached the page')
		local ids = {}
		for _, row in ipairs(groups() or {}) do ids[#ids + 1] = row.id end
		check('and saved outfits, saving and codes are all reachable from it',
			hasGroup('outfits') and hasGroup('save') and hasGroup('code'),
			('strip: [%s]'):format(table.concat(ids, ', ')))

		-- THE GATE IS WHICH BUTTONS EXIST. This room was opened from the
		-- appearance panel and not from a shop counter, so there is no shop being
		-- served -- and a Uniforms category with nothing behind it is a button
		-- that can only ever refuse. The server applies the job gate before it
		-- sends the list; this is the same rule one screen further out.
		check('but a room opened away from a counter offers no uniforms',
			not hasGroup('looks'))

		-- Even once a look list arrives: without a shop being served there is
		-- still nothing this player could be sold.
		local shopsModule = env.OPX.Modules.Get('shops')
		control.netEvents[shopsModule.Event.LOOKS]({ shop = 'jinguji',
			looks = { { id = 'corpo', label = 'Corpo suit', cost = 0 } } })
		check('and a look list alone does not conjure the category',
			not hasGroup('looks'))

		-- ── a shared code, all the way onto the sliders ──────────────────────
		-- THE ROUND TRIP THAT WAS BROKEN. A redeemed code comes back as `PUT_ON`,
		-- and `shops.putOn` borrows the puppet through `BeginClothingPreview` --
		-- which, with this very room open, is refused, because the puppet is
		-- already lent to it. So redeeming a code inside the clothing screen used
		-- to do nothing at all: no clothes, no toast, no log line. It goes through
		-- the room's draft now, which means the SLIDER MOVES -- and the slider
		-- moving is the only thing the player can actually see.
		local wasFeet = slider('Feet')
		control.netEvents[shopsModule.Event.PUT_ON]({ look = 'shared',
			wear = { Feet = 'Items.Feet_03' } })
		local nowFeet = slider('Feet')
		check('a code redeemed inside the room moves the room\'s own slider',
			nowFeet ~= nil and nowFeet.value == 'Feet 03',
			nowFeet and tostring(nowFeet.value) or 'no Feet slider')
		check('and it is a different position from the one it stood on',
			wasFeet ~= nil and nowFeet ~= nil and wasFeet.index ~= nowFeet.index)
		check('and the puppet is actually wearing it',
			worn.Feet == 'Items.Feet_03', tostring(worn.Feet))

		-- A GARMENT THIS BODY HAS NO RECORD FOR IS SKIPPED, NOT OBEYED. A code is
		-- read out by another player whose character may be a different build, so
		-- half its records may be ones this catalogue never offered. Dressing in
		-- as much of the look as fits beats refusing the whole outfit over one
		-- jacket -- and putting a record the room cannot place under a thumb would
		-- leave the slider lying about what is on the body.
		control.netEvents[shopsModule.Event.PUT_ON]({ look = 'foreign',
			wear = { Feet = 'Items.NotInThisCatalogue' } })
		check('a record this body has no catalogue entry for is skipped',
			slider('Feet').value == 'Feet 03', tostring(slider('Feet').value))

		local before = #shots
		appearance.Wardrobe.Close('caller')
		check('closing the room gives the puppet back unkept',
			gaveBack == 'appearance/false', tostring(gaveBack))

		-- THE CAMERA IS GIVEN BACK, and this is the check that matters most of the
		-- three: a stuck camera is, in the platform's own words, indistinguishable
		-- from a crash. A zero offset is the body's own position, so `detach` with
		-- three zeroes IS "put it back" -- and it is the same permission-free call
		-- that took it, rather than `camera.attach()`, which is gated on
		-- `camera.script` and would mean needing a permission in order to LET GO.
		local last = shots[#shots]
		check('and puts the camera back on the body on the way out',
			#shots == before + 1 and last.x == 0.0 and last.y == 0.0 and last.z == 0.0,
			last and ('x=%s y=%s z=%s'):format(last.x, last.y, last.z) or 'no release')
	end

	-- ── the one bound still in play ──────────────────────────────────────────
	-- `Open77.equipment.records` caps `limit` at 2000 and the live catalogue was
	-- at 98.4% of it when it was read whole. Per slot the largest is a third of
	-- that, so this cannot fire today -- which is exactly why it is written down
	-- and tested: a silent truncation is the shape of the whole episode.
	do
		local env, control = joinClient('never', 400)
		local appearance = env.OPX.Modules.Get('appearance')

		env.Open77.equipment.records = function(options)
			local out = {}
			if options.slot == 'OuterChest' then
				for index = 1, 2000 do out[index] = { record = ('Items.Coat_%04d'):format(index) } end
			end
			return out
		end
		env.Open77.equipment.apply = function() return true end
		env.Open77.character.state = function()
			return { health = 100, alive = true, attached = true }
		end
		appearance.Clothing.BeginPreview = function() return { equipment = {} } end
		appearance.Clothing.EndPreview = function() return true end

		--- Every note this client has sent the server, as one string.
		local function toldServer()
			local note = env.OPX.Event(env.OPX.Channel.NET, 'runtime', 'note')
			local said = {}
			for index = 1, #control.serverEvents do
				local sent = control.serverEvents[index]
				if sent.name == note and sent[1] == 'appearance' then
					said[#said + 1] = tostring(sent[2])
				end
			end
			return table.concat(said, ' | ')
		end

		appearance.Wardrobe.Open('appearance')

		-- THE READ MUST BREATHE, and this is the check that says so. The defect
		-- this whole section now guards was not a wrong answer: it was the right
		-- answer computed in ONE resume, which exceeded the client's per-resume
		-- instruction budget and unwound the coroutine with nothing logged
		-- anywhere the operator could see. Desktop Lua has no such budget, so no
		-- assertion about the RESULT can ever catch it -- only an assertion about
		-- the shape of the work.
		--
		-- Forty frames is comfortably past the twenty-one a per-slot yield
		-- needs -- three breaths a slot, seven slots -- and comfortably short of
		-- the eighty-odd a chunked 2000-record read costs. The first number was
		-- twenty and did NOT discriminate: the mutation passed. So: still reading here means it is chunking; already open
		-- means somebody took the chunking out.
		-- Asked of the OPENED note rather than of `IsOpen`, which answers
		-- `phase ~= 'closed'` and is therefore true throughout the read.
		control.Pump(40)
		check('a 2000-record slot has not finished opening after 40 frames, so the '
			.. 'read is chunked rather than done in one resume',
			toldServer():find('the fitting room opened', 1, true) == nil, toldServer())

		-- ONE FRAME PER `CATALOGUE_CHUNK` ENTRIES, which is why this is not 30 any
		-- more. `readCatalogue` used to yield once per slot and blew the client's
		-- per-resume instruction budget doing a whole slot in one go -- the defect
		-- that made the fitting room silently not exist. It now breathes every 64
		-- entries, so this 2000-record slot alone costs about sixty-five frames
		-- and the whole read about eighty. Sized with headroom rather than to the
		-- measurement, because the chunk is a tuning value and this test is about
		-- the truncation line, not about how many frames the read takes.
		control.Pump(200)
		check('an answer that reaches the limit is reported, not swallowed',
			toldServer():find('being truncated', 1, true) ~= nil, toldServer())
		check('and the line names the slot and both numbers',
			toldServer():find('OuterChest catalogue answered 2000 record(s) against a limit of 2000',
				1, true) ~= nil, toldServer())
		appearance.Wardrobe.Close('caller')
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

		-- ── the two answer shapes, and the bug that lives between them ───────
		--
		-- The library splits its answers on purpose: a WRITER answers a Result
		-- so a caller can branch on a real failure, a READER on a hot path
		-- answers the plain value because a table per tick is garbage the
		-- collector did not need. Both are right, and mixing them up is silent:
		-- a Result is a TABLE, so `if not writer() then` is never true and the
		-- branch behind it can never be taken again.
		--
		-- That is not hypothetical. `Input.Block` answers a Result where the
		-- native it replaced answered `(boolean, reason)`, and the warning behind
		-- `if not blocked then` was dead from the day it was migrated. The two
		-- checks below pin the shapes the client half now depends on, so the next
		-- migration is told rather than discovering it in somebody's game.
		local Lib = env.OPX.Lib

		-- Readers. The host installs no `Open77.input`, which is exactly the case
		-- a reader has to answer safely rather than crash on.
		check('a library reader answers a plain value, never a Result',
			Lib.Input.IsDown('UP') == false and Lib.Input.IsCaptured() == false)

		-- Writers. No `Open77.kvp` on this host either, so `Set` takes the
		-- native-absent path -- the one `modules/admin/client/tags.lua` relies on
		-- to warn once instead of raising.
		local wrote = Lib.Store.Set('opx.tests.shape', true)
		check('a library writer answers a Result, refusal and all',
			type(wrote) == 'table' and wrote.ok == false and type(wrote.error) == 'string')

		-- And the reader half of the same module takes a fallback rather than
		-- making the caller unwrap. `tags.lua` reads its own-tag default through
		-- this: before the migration an absent store returned out of `Start`
		-- early and the configured `TAGS.OWN` was silently dropped.
		check('and its reader answers the fallback when the store is not there',
			Lib.Store.Get('opx.tests.shape', 'fallback') == 'fallback')

		-- `Native.Reach` is the capability probe the client hand-rolled as a
		-- two-level `type()` dance in five places. It answers the function or
		-- nil, and it must not raise on a namespace that is wholly absent.
		--
		-- IT IS PROBED AGAINST THE ENVIRONMENT THE RESOURCE RUNS IN, which is
		-- what `Host.RequireFor` made possible: the library is loaded INTO `env`
		-- now, so `rawget(_G, 'Open77')` inside it reads the same stub every
		-- other client file reads. Before that it was loaded with a bare
		-- `loadfile` and ran in the real global table, so every wrapper took its
		-- absent-native path for the whole suite and only refusals were covered.
		local stub = env.Open77
		local found = Lib.Native.Reach('players.all')
		local missingLeaf = Lib.Native.Reach('players.nope')
		local missingRoot = Lib.Native.Reach('nosuch.thing')
		env.Open77 = nil
		local withoutPlatform = Lib.Native.Reach('players.all')
		env.Open77 = stub

		check('Native.Reach answers a function off the live stub',
			type(found) == 'function', type(found))
		check('and nil for a missing leaf and a missing namespace alike',
			missingLeaf == nil and missingRoot == nil)
		check('and nil, rather than raising, when there is no Open77 at all',
			withoutPlatform == nil)

		-- The structural half: nobody may put a Result straight into a boolean
		-- position. Line-scoped, which is enough because every such call in this
		-- resource is written on one line, and allowlisted by the readers the
		-- library documents as answering plain values.
		local plain = {
			['Input.IsDown'] = true, ['Input.IsCaptured'] = true,
			['Input.Cursor'] = true, ['Input.KeyFor'] = true,
			['Input.Mappings'] = true, ['Store.Get'] = true, ['Store.Has'] = true,
			['Native.Reach'] = true, ['Rpc.IsRunning'] = true,
			['Timer.After'] = true, ['Timer.Cancel'] = true, ['Timer.Until'] = true,
			['Timer.Debounce'] = true, ['Timer.Throttle'] = true,
			['Camera.Why'] = true,
		}
		local unwrapped = {}
		for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
			local handle = io.open(file, 'r')
			if handle then
				local number = 0
				for line in handle:lines() do
					number = number + 1
					-- Only a call standing alone as the condition. A comment is not
					-- a branch, and neither is a call whose answer is compared or
					-- unwrapped further along the line.
					local module, fn = line:match('^%s*if%s+n?o?t?%s*OPX%.Lib%.(%u%w*)%.(%u%w*)%(')
					if module and not plain[module .. '.' .. fn]
						and not line:find('%.ok') and not line:find('[=~<>]=') then
						unwrapped[#unwrapped + 1] = ('%s:%d %s.%s'):format(file, number, module, fn)
					end
				end
				handle:close()
			end
		end
		table.sort(unwrapped)
		check('no client file branches on a library Result as though it were a boolean',
			#unwrapped == 0, table.concat(unwrapped, ', '))

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
		-- The refusals below call it, and a scheduler that cannot raise would
		-- pass the interval checks by accident.
		error = error,
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

		-- A BAD INTERVAL IS REFUSED RATHER THAN RUN EVERY PASS.
		-- `math.max(0, math.floor(tonumber(intervalMs) or 0))` used to turn a
		-- nil, a string or a function into 0, and 0 on this scheduler means
		-- every single pass. On a client with a per-resume instruction budget
		-- that is a typo quietly eating the budget until something unrelated is
		-- cut off mid-coroutine with nothing in the log.
		--
		-- A FUNCTION IS THE CASE WORTH ITS OWN LINE. The SERVER'S `Every` takes
		-- `integer|function` and re-reads it every pass, which is how a job
		-- follows a live tunable. The two share a name and a signature on paper
		-- and cannot share this, because `OPX.Tune` is server-only; so it is
		-- refused here instead of silently becoming frame-rate.
		local noop = function() end
		check('a function interval is refused, not turned into every frame',
			select(1, pcall(Scheduler.Every, 'fn', function() return 250 end, noop)) == false)
		check('so is a nil interval',
			select(1, pcall(Scheduler.Every, 'nope', nil, noop)) == false)
		check('so is a string that is not a number',
			select(1, pcall(Scheduler.Every, 'str', 'soon', noop)) == false)
		check('and so is a negative one',
			select(1, pcall(Scheduler.Every, 'neg', -1, noop)) == false)
		check('zero stays legal, because a caller may mean every pass',
			select(1, pcall(Scheduler.Every, 'zero', 0, noop)) == true)

		Scheduler.Stop()
	end
end

-- ── the ACL read that raised outside the pcall written to catch it ───────────
-- `permitted` decides whether a restricted command is SUGGESTED, and its comment
-- says a read that raises counts as a refusal -- suggested to nobody rather than
-- to everybody. It did not do that. `pcall(Open77.acl.isAllowed, ...)` resolves
-- the field BEFORE pcall runs, so a host without `Open77.acl` -- no `acl.read`
-- grant, or an older build -- raised on the index, outside the protection.
--
-- Loaded into an env of its own rather than through `boot`, because the whole
-- point is a host that does NOT install the table, and the harness always does.
section('suggestions when the ACL is not installed')
do
	local env = {
		OPX = { Command = {}, Refuse = function() end, Cooling = function() return false end },
		Open77 = { log = { error = function() end, warn = function() end } },
		RegisterCommand = function() end,
		type = type, tonumber = tonumber, tostring = tostring, pcall = pcall,
		ipairs = ipairs, pairs = pairs, error = error, table = table, string = string,
	}

	local chunk, why = loadfile('core/server/commands.lua', 't', env)
	check('commands loads without an ACL table', chunk ~= nil, why)

	if chunk ~= nil then
		local ok = pcall(chunk)
		check('and runs', ok)

		env.OPX.Command.Register('staffonly', { restricted = true }, function() end)
		env.OPX.Command.Register('anyone', {}, function() end)

		-- The raise used to happen here, on the index, and took the whole
		-- suggestion list with it.
		local listed, suggestions = pcall(env.OPX.Command.Suggestions, 1)
		check('asking for suggestions does not raise with no ACL installed',
			listed, not listed and tostring(suggestions) or nil)

		if listed then
			local names = {}
			for _, row in ipairs(suggestions or {}) do names[tostring(row.name)] = true end
			check('the open command is still suggested', names.anyone == true)
			check('and the restricted one is suggested to nobody',
				names.staffonly ~= true)
		end

		-- A DUPLICATE IS REFUSED HERE, NAMED, AND LEAVES NOTHING BEHIND.
		-- `RegisterCommand` raises on a name it already has, so a duplicate was
		-- always fatal -- it happened to `opx.appearance` and took the
		-- clothing-load hook down with it -- but the raise came out of the host
		-- with no idea which two callers collided. Worse, the suggestion row was
		-- written BEFORE the host was asked, so the loser's help text stayed in
		-- the list for a command the host had just refused it.
		local again, why = pcall(env.OPX.Command.Register, 'anyone', { help = 'second' },
			function() end)
		check('registering a name twice is refused', again == false)
		check('and the refusal names the command',
			again == false and tostring(why):find('anyone', 1, true) ~= nil,
			tostring(why))

		local kept
		for _, row in ipairs(env.OPX.Command.Suggestions(1) or {}) do
			if row.name == 'anyone' then kept = row end
		end
		check('and the first registration is what stayed in the list',
			kept ~= nil and kept.help ~= 'second', kept and tostring(kept.help))

		-- A COOLDOWN THAT IS NOT A NUMBER TOOK THE RATE LIMIT AWAY.
		-- `tonumber(opts.cooldownMs) or 0` met a gate of `if cooldownMs > 0`, so
		-- a misspelt config value did not fail loudly -- it removed the limit
		-- from a command that had explicitly asked for one, which is the one
		-- direction a typo must never be allowed to go on its own.
		check('a cooldown that is not a number is refused',
			select(1, pcall(env.OPX.Command.Register, 'slowish',
				{ cooldownMs = 'later' }, function() end)) == false)
		check('no cooldown at all is still fine',
			select(1, pcall(env.OPX.Command.Register, 'free', {}, function() end)) == true)
		check('and a real one is too',
			select(1, pcall(env.OPX.Command.Register, 'paced',
				{ cooldownMs = 5000 }, function() end)) == true)
	end
end

-- ── showing a page must never hide it ────────────────────────────────────────
-- `OPX.Surface.Visible` read `pcall(visible and page.show or page.hide, page)`,
-- which is the and/or trap doing something worse than raising. Ask it to SHOW a
-- page whose host has no `show` -- an older build, a surface kind without it --
-- and the first half answers nil, the `or` takes over, and the page is hidden.
-- A missing method has to fail the call, not perform its opposite.
--
-- Loaded into an env of its own: the point is a page missing a method, and no
-- real surface in the harness is missing one.
section('showing a page never hides it')
do
	local env = {
		OPX = { Surface = {} },
		Open77 = { log = { error = function() end, warn = function() end } },
		type = type, tostring = tostring, pcall = pcall, pairs = pairs,
		ipairs = ipairs, error = error, table = table, string = string,
		tonumber = tonumber, math = math,
	}

	local chunk, why = loadfile('lib/client/surface.lua', 't', env)
	check('the surface helper loads', chunk ~= nil, why)

	if chunk ~= nil and pcall(chunk) then
		local Surface = env.OPX.Surface
		local calls = {}

		local lame = { page = { hide = function() calls[#calls + 1] = 'hide' end } }
		check('showing a page whose host has no show answers false',
			Surface.Visible(lame, true) == false)
		check('and did NOT hide it instead', #calls == 0,
			table.concat(calls, ', '))

		check('hiding that same page still works', Surface.Visible(lame, false) == true)
		check('and hid it exactly once', #calls == 1, table.concat(calls, ', '))

		local whole = {
			page = {
				show = function() calls[#calls + 1] = 'show' end,
				hide = function() calls[#calls + 1] = 'hide' end,
			},
		}
		check('a page with both is shown when asked to show',
			Surface.Visible(whole, true) == true and calls[#calls] == 'show')
		check('and hidden when asked to hide',
			Surface.Visible(whole, false) == true and calls[#calls] == 'hide')
	end
end

-- ── what the client pays for every second it is doing nothing ────────────────
-- A pass that recomputes an answer that did not change is the whole subject. The
-- three checks below are the three shapes it took, and each of them is a
-- REGRESSION GUARD rather than a feature: nothing a player can see changes if
-- one of them fails, which is exactly why they have to be here.
--
-- The counters are on the HOST BRIDGES, not on the Lua. A host read is the unit
-- that costs on the platform, and counting it is the only figure that survives
-- the difference between this machine and a game.
section('the standing cost')
do
	local pressed = false
	local keyCallbacks = {}
	local reads = { isDown = 0, keyFor = 0 }
	local pools = { health = 100, armor = 0, stamina = 100 }

	--- Everything the client half reaches for that the plain harness has no stub
	--- for. Without the camera and the cursor `canPick` refuses and the target
	--- module registers its sweep and nothing else, so the two jobs under test
	--- would never exist to be counted.
	local function prelude(env)
		local O = env.Open77
		O.input = {
			isDown = function() reads.isDown = reads.isDown + 1 return pressed end,
			keyFor = function() reads.keyFor = reads.keyFor + 1 return 'ALT' end,
			cursor = function() return { inBounds = true, captured = false } end,
			isCaptured = function() return false end,
			block = function() return true end,
		}
		O.camera = { screenRaycast = function() return { hit = false } end }
		O.stats = {
			get = function()
				return {
					health = { value = pools.health, maximum = 100 },
					armor = pools.armor,
					stamina = { value = pools.stamina, maximum = 100 },
				}
			end,
		}
		-- The body wins over the canonical pool for damage the server never hears
		-- of, so this is the reading the gauge column actually draws.
		O.character.state = function()
			return {
				health = pools.health, attached = true, alive = true,
				position = { x = 0, y = 0, z = 0 },
			}
		end
		-- Keyed by id: half the client registers a mapping, and the last one to do
		-- so would otherwise be the only one a test could press.
		env.RegisterKeyMapping = function(id, _, _, callback) keyCallbacks[id] = callback end
	end

	local env, control, why = boot('client', nil, prelude)
	if why ~= nil then
		check('the client half loads', false, why)
	else
		local OPX = env.OPX

		local function registered(name)
			for _, line in ipairs(OPX.Scheduler.Report()) do
				if line:match('^' .. name .. '%s') then return true end
			end
			return false
		end

		-- ── the job that only exists while there is something to do ───────────
		-- `target:resolve` slices a pick at 25ms, the fastest interval in the
		-- resource. The one client loop sleeps the nearest deadline, so a job at
		-- that interval sets the floor on how often the loop wakes AT ALL --
		-- registered for the session it woke it forty times a second to read a
		-- nil and return. It is registered by the pick and cancelled by the last
		-- slice.
		check('the eye is up and its standing jobs with it', registered('target:watch'))
		check('but the slicer is not standing: nothing is being sliced',
			not registered('target:resolve'))

		-- ── the key read that decides a boolean that was already decided ──────
		-- `armed` is a latch: the press drops it, the release raises it. Reading
		-- the key to raise one that is already up is two host reads, twenty times
		-- a second, for the whole session.
		reads.isDown, reads.keyFor = 0, 0
		control.Pump(20)
		check('an eye at rest reads the key not at all',
			reads.isDown == 0 and reads.keyFor == 0,
			('isDown=%d keyFor=%d'):format(reads.isDown, reads.keyFor))

		-- AND IT STILL RE-ARMS, which is the half that matters: a gate that never
		-- opens is not an optimisation, it is a key that works once.
		local keyCallback = keyCallbacks['opx.target.activate']
		if keyCallback == nil then
			check('the target key was mapped', false, 'no RegisterKeyMapping callback')
		else
			pressed = true
			keyCallback()
			pressed = false
			reads.isDown, reads.keyFor = 0, 0
			control.Pump(20)
			check('a press puts the latch down and the read comes back',
				reads.isDown > 0, reads.isDown)

			-- Released and observed: the latch is up again and the reads stop.
			reads.isDown, reads.keyFor = 0, 0
			control.Pump(20)
			check('and stops again once the release has been seen',
				reads.isDown == 0, reads.isDown)
		end

		-- ── the payload built thirty times a second to be thrown away ─────────
		-- `hud:vitals` is change-gated on a signature, and building that
		-- signature was the cost: a row table, five `tostring`s and a concat per
		-- gauge and one more over the lot, at 30 Hz, discarded whenever the pools
		-- had not moved.
		local page
		for _, candidate in ipairs(control.pages) do
			if candidate.handlers['opx:hud:ready'] ~= nil then page = candidate end
		end
		if page == nil then
			check('the overlay page exists', false)
		else
			local function vitals()
				local count = 0
				for _, message in ipairs(page.sent) do
					if message.channel == 'opx:hud:vitals' then count = count + 1 end
				end
				return count
			end

			-- COUNTING SENDS IS NOT ENOUGH, and the reason is the whole point of
			-- the change: the push was ALREADY gated on a signature, so a pass
			-- that rebuilt the column and compared it equal sent nothing either
			-- way. The cost was the rebuild, and the only way to see it from out
			-- here is to watch the configuration the rebuild reads. Each gauge
			-- row is proxied so that reading its `SOURCE` -- which `gauges()`
			-- does once per row per call and nothing else does at all -- counts.
			local builds = 0
			do
				local settings = OPX.Modules.Get('hud').Settings
				local configured = settings.GAUGES
				local proxied = {}
				for index = 1, #configured do
					local row = configured[index]
					proxied[index] = setmetatable({}, {
						__index = function(_, field)
							if field == 'SOURCE' then builds = builds + 1 end
							return row[field]
						end,
					})
				end
				settings.GAUGES = proxied
			end

			-- The join screens own the display until they say otherwise, and a
			-- covered HUD samples nothing at all.
			env.TriggerEvent(OPX.Event(OPX.Channel.LOCAL, 'entry', 'state'), { open = false })
			env.TriggerEvent(OPX.Event(OPX.Channel.LOCAL, 'spawn', 'state'), { open = false })
			control.PageEmit(page, 'opx:hud:ready', {})
			control.Pump(10)

			local settled = vitals()
			check('the gauge column reaches the page', settled > 0, settled)

			builds = 0
			control.Pump(40)
			check('and a pool that did not move draws nothing further',
				vitals() == settled, ('%d -> %d'):format(settled, vitals()))
			check('nor builds the column it would have thrown away',
				builds == 0, builds)

			-- THE HALF THE GATE COULD BREAK. A gate that never lets go is a
			-- health bar frozen at whatever it said when the player spawned.
			pools.health = 41
			control.Pump(10)
			check('a pool that moved is drawn', vitals() > settled,
				('%d -> %d'):format(settled, vitals()))
			check('and the column was built to draw it', builds > 0, builds)

			-- A fraction of a percent is not a percent. The gauges draw whole
			-- numbers, so a pool jittering below the rounding is not a change,
			-- and a gate that compared the raw pool would fire on every pass.
			local drawnAt41 = vitals()
			pools.health = 41.4
			builds = 0
			control.Pump(20)
			check('a move too small to round to a different percent is not',
				vitals() == drawnAt41 and builds == 0,
				('sent %d -> %d, built %d'):format(drawnAt41, vitals(), builds))
		end
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
	local function bridge(rows, wrote, vehicleWrites)
		return Host.Database({
			scalar = function() return 1 end,
			update = function(sql, params)
				-- Only the INSERT: the schema runs `CREATE TABLE IF NOT EXISTS`
				-- through the same bridge method, and counting that would make
				-- "nothing was written" true of a boot rather than of a refusal.
				if wrote ~= nil and sql:find('INSERT INTO opx77_garages', 1, true) then
					wrote[#wrote + 1] = sql
				end
				-- Every write to a vehicle row, with its parameters. Which marker a
				-- put-away files the vehicle UNDER is only observable here: the
				-- roster this bridge answers from is never touched by an UPDATE.
				if vehicleWrites ~= nil and sql:find('UPDATE opx77_vehicles', 1, true) then
					vehicleWrites[#vehicleWrites + 1] = type(params) == 'table' and params or {}
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

	local wrote, vehicleWrites = {}, {}
	local env, control, why = boot('server', bridge({ row('AA111AA', 'Vehicle.v_standard2_archer_hella_player'),
		row('AA222AA', 'Vehicle.av_militech_manticore') }, wrote, vehicleWrites))
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
		-- The vehicles half, read the way any other module reads it: the plate a
		-- player is sitting in is proved through this contract and nothing else.
		local vehicleApi = OPX.Api.Get('vehicles')

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
		--
		-- THE INDEX AS WELL AS THE ROSTER. `character.RegisterPlayer` fills both,
		-- and the difference is not cosmetic: "is this character still loaded?"
		-- is answered from `Registry.byCitizenId`, and the vehicles module asks it
		-- before saving a live vehicle in place. A roster entry with no index
		-- entry reads as an owner who left, so the save pass put every car away --
		-- which meant no vehicle in this file was ever still out one pump later,
		-- and "a vehicle that is already out" could not be tested at all.
		local function load(id, citizenId)
			control.Admit(id, 'account-' .. tostring(id))
			OPX.EnsureSession(id)
			local character = OPX.Modules.Get('character')
			local userId = 'account-' .. tostring(id)
			character.Players[id] = { PlayerData = { citizenId = citizenId, source = id,
				userId = userId } }
			character.Registry.byCitizenId[citizenId] = id
			character.Registry.byUserId[userId] = id
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

		-- THE COOLDOWN IS SWITCHED OFF FOR THE CASES THAT ARE NOT ABOUT IT, and
		-- turned back on for the one that is, below. `COOLDOWN_MS` is a real
		-- floor between two bring-outs -- three seconds, which is thirty pumps --
		-- and every check from here to the rate-limit block fires a second
		-- request immediately to test something else entirely: which vehicle a
		-- pad takes, that another bucket is refused, that an unknown marker is.
		-- Making each of them wait would be thirty pumps of nothing, three times,
		-- to assert something already asserted once.
		local cooldown = Access.COOLDOWN_MS
		Access.COOLDOWN_MS = 0

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

		-- ── a vehicle that is already out is BROUGHT TO THE MARKER ───────
		-- The bug this pins: the door answered `Ok` with the id the vehicle
		-- already had, wherever it was, so the player was told "brought out",
		-- stood on an empty marker and pressed the key again -- six times in one
		-- recorded session. The vehicle is put away and created again AT the
		-- spot now, which is what the marker promised in the first place.
		created = #control.vehicleCreates
		local removals = #control.vehicleRemoves
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('a vehicle that is already out is removed and created again',
			#control.vehicleCreates == created + 1 and #control.vehicleRemoves == removals + 1,
			('%d created, %d removed'):format(#control.vehicleCreates - created,
				#control.vehicleRemoves - removals))
		options = control.vehicleCreates[#control.vehicleCreates]
		check('and the second creation is ON the marker, not beside the player',
			options ~= nil and options.position.x == 0.0 and options.position.y == 0.0,
			options and ('%s,%s'):format(tostring(options.position.x), tostring(options.position.y)))
		answer = lastEvent(garages.Event.ANSWER)
		check('and the answer says it was moved rather than brought from the roster',
			answer ~= nil and answer[2] == true and answer[5] == 'recalled',
			answer and tostring(answer[5]))

		-- SOMEBODY IS SITTING IN IT. The occupant is not necessarily the player
		-- who pressed the key -- a marker is a public place -- so the vehicle is
		-- refused rather than taken out of a driver's hands.
		control.vehicles.snapshot = { occupants = { { playerId = 99 } } }
		created = #control.vehicleCreates
		removals = #control.vehicleRemoves
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('a vehicle somebody is sitting in is neither moved nor removed',
			#control.vehicleCreates == created and #control.vehicleRemoves == removals,
			('%d created, %d removed'):format(#control.vehicleCreates - created,
				#control.vehicleRemoves - removals))
		check('and the refusal names the occupant',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'vehicle.occupied',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[3]))
		control.vehicles.snapshot = nil

		-- ── the same key, seated: PUT IT AWAY ────────────────────────────
		-- The id is read the way any caller reads it -- the seat assignment names a
		-- runtime id and this contract is what says which plate owns it -- and the
		-- plate is the roster fixture the bring-out above just produced.
		local outPlate = 'AA111AA'
		local live = vehicleApi.Get(outPlate)
		check('the plate out at the marker answers its runtime id',
			live.ok == true and live.value.spawned == true and live.value.id ~= nil,
			live.ok and tostring(live.value.id) or tostring(live.detail))
		control.Seat(src, { vehicleId = live.value.id, seat = 'driver' })

		created = #control.vehicleCreates
		removals = #control.vehicleRemoves
		local wroteVehicles = #vehicleWrites
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('seated on a marker, the key puts the vehicle away and creates nothing',
			#control.vehicleCreates == created and #control.vehicleRemoves == removals + 1,
			('%d created, %d removed'):format(#control.vehicleCreates - created,
				#control.vehicleRemoves - removals))
		check('and it is filed UNDER the marker the player is standing on',
			#vehicleWrites > wroteVehicles
				and vehicleWrites[#vehicleWrites].garage == 'garage_dock'
				and tonumber(vehicleWrites[#vehicleWrites].state) == 1,
			#vehicleWrites > wroteVehicles and ('garage=%s state=%s'):format(
				tostring(vehicleWrites[#vehicleWrites].garage),
				tostring(vehicleWrites[#vehicleWrites].state)) or 'nothing was written')
		answer = lastEvent(garages.Event.ANSWER)
		check('and the answer says STORED, which is not the same thing as brought out',
			answer ~= nil and answer[2] == true and answer[5] == 'stored',
			answer and tostring(answer[5]))
		check('and the character is on foot again as far as the contract is concerned',
			vehicleApi.Occupied(src).value == nil)

		-- On foot, the same key brings it back -- out of the roster, at the spot
		-- it was just filed under. Both halves of one key, one marker.
		--
		-- THE MARKER'S OWN WINDOW HAS TO EXPIRE FIRST, and deliberately rather
		-- than by widening it: this section has now asked it as many times as one
		-- window allows, and the refusal that follows is the subject of the test
		-- at the end of the file. Clock ticks are 100 ms in this harness.
		control.Pump(math.ceil(OPX.Config.MODULES.garages.REQUEST_WINDOW_MS / 100) + 2)
		control.Seat(src, nil)
		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		answer = lastEvent(garages.Event.ANSWER)
		check('and on foot the same key brings it back out at that marker',
			#control.vehicleCreates == created + 1 and answer ~= nil
				and answer[2] == true and answer[5] == 'brought',
			('%d created, answer ok=%s action=%s error=%s'):format(
				#control.vehicleCreates - created,
				answer and tostring(answer[2]) or 'none',
				answer and tostring(answer[5]) or 'none',
				answer and tostring(answer[3]) or 'none'))

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

		-- ── the floor between two bring-outs ──────────────────────────────
		-- DECLARED IN CONFIG, VALIDATED AT BOOT, AND FOR A WHILE NOT APPLIED.
		-- `COOLDOWN_MS` was read into `Access.COOLDOWN_MS` and nothing anywhere
		-- used it, so only the six-per-ten-seconds window ran and six bring-outs
		-- could land in the same tick. That matters past tidiness: `FetchOne`
		-- yields before the already-out guard in `modules/vehicles`, so two
		-- threads for one plate both pass it and both create a vehicle.
		local hasty = 45
		load(hasty, 'citizen-garage')
		env.source = hasty
		Access.COOLDOWN_MS = cooldown > 0 and cooldown or 3000

		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('the first bring-out of a pair is served',
			#control.vehicleCreates == created + 1)

		created = #control.vehicleCreates
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('and a second inside the floor creates nothing',
			#control.vehicleCreates == created)
		check('and is refused rather than dropped',
			lastEvent(garages.Event.ANSWER) ~= nil
				and lastEvent(garages.Event.ANSWER)[3] == 'garages.rateLimited',
			lastEvent(garages.Event.ANSWER) and tostring(lastEvent(garages.Event.ANSWER)[3]))

		-- Past the floor -- thirty pumps is three seconds -- it is served again.
		created = #control.vehicleCreates
		control.Pump(31)
		control.netEvents[garages.Event.REQUEST]('garage_dock')
		control.Pump(8)
		check('and once the floor has passed it is served again',
			#control.vehicleCreates == created + 1)

		Access.COOLDOWN_MS = 0

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
		for index = 1, #cctl.serverEvents do
			if cctl.serverEvents[index].name == garages.Event.ASK then asked = true end
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

		-- ONE KEY, TWO JOBS, so the row has to name the job it is about to do:
		-- a row that still read "bring out a vehicle" while the player sat in one
		-- would be labelling the key with the wrong half of what it does.
		check('on foot, the row names the bring-out',
			Runtime.Report().label == 'garages.prompt.garage', Runtime.Report().label)
		cctl.Seat(1, { seat = 'driver' })
		settle(cctl, function() return Runtime.Report().label == 'garages.prompt.putAway' end)
		check('seated in a vehicle, the same row says put away',
			Runtime.Report().label == 'garages.prompt.putAway', Runtime.Report().label)
		cctl.Seat(1, nil)
		settle(cctl, function() return Runtime.Report().label == 'garages.prompt.garage' end)
		check('and it goes back to the bring-out once the player is out of it',
			Runtime.Report().label == 'garages.prompt.garage', Runtime.Report().label)

		-- ── the key sends the request ─────────────────────────────────────
		local before = #cctl.serverEvents
		mapping.pressed()
		local sent = cctl.serverEvents[#cctl.serverEvents]
		check('the key sends a request for the marker underfoot',
			#cctl.serverEvents == before + 1 and sent ~= nil
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
		local mark = #cctl.serverEvents
		mapping.pressed()
		check('and the key does nothing while it does', #cctl.serverEvents == mark)
		cctl.input.captured = false
		settle(cctl, function()
			local row = prompts ~= nil and prompts.List('garages') or nil
			return row ~= nil and row.ok == true and row.value.count == 1
		end)

		-- ── the capture round-trip ────────────────────────────────────────
		mark = #cctl.serverEvents
		local infoMark = #cctl.log.info
		cctl.netEvents[garages.Event.CAPTURE]('avpad', 'pad_dock', 'THE PAD')
		local answered = cctl.serverEvents[#cctl.serverEvents]
		check('the client answers a capture ask', #cctl.serverEvents > mark)
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
		mark = #cctl.serverEvents
		local answer = Runtime.Use('test')
		check('using a marker nobody is standing on answers no spot',
			answer.ok == false and answer.error == 'garages.noSuchSpot')
		check('and nothing is sent', #cctl.serverEvents == mark)
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
			local userId = 'account-' .. tostring(id)
			character.Players[id] = {
				PlayerData = { citizenId = citizenId, source = id, userId = userId,
					money = { EDDIES = eddies or 0 } },
				Functions = { UpdatePlayerData = function() end },
			}
			-- The roster AND the index, the way `character.RegisterPlayer` fills
			-- them: the vehicles module asks the index whether an owner is still
			-- loaded before it saves a live vehicle in place, and a hand-loaded
			-- roster without it reads as an owner who left.
			character.Registry.byCitizenId[citizenId] = id
			character.Registry.byUserId[userId] = id
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
		for index = 1, #cctl.serverEvents do
			if cctl.serverEvents[index].name == dealership.Event.ASK then asked = true end
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
		local before = #cctl.serverEvents
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
		for position = #cctl.serverEvents, 1, -1 do
			if cctl.serverEvents[position].name == dealership.Event.BUY then
				sent = cctl.serverEvents[position]
				break
			end
		end
		check('picking the destination sends the purchase',
			sent ~= nil and #cctl.serverEvents > before
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
		before = #cctl.serverEvents
		local infoMark = #cctl.log.info
		cctl.netEvents[dealership.Event.CAPTURE]('garage', 'dealer_dock', 'THE DOCKS')
		local answered = cctl.serverEvents[#cctl.serverEvents]
		check('the client answers a capture ask', #cctl.serverEvents > before)
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
		before = #cctl.serverEvents
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
		for index = 1, #cctl.serverEvents do
			if cctl.serverEvents[index].name == clothing.Event.ASK then asked = true end
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
		local mark = #cctl.serverEvents
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
			#cctl.serverEvents == mark)

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
			#cctl.serverEvents > mark
				and cctl.serverEvents[#cctl.serverEvents].name == admin.Event.NOCLIP_BODY
				and cctl.serverEvents[#cctl.serverEvents][1] == false,
			cctl.serverEvents[#cctl.serverEvents][1] == nil and 'nothing sent'
				or tostring(cctl.serverEvents[#cctl.serverEvents][1]))

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
		local mark2 = #cctl.serverEvents
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
			cctl.travels.noclip == true and #cctl.serverEvents > mark2)
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

-- ── what the screen does once the server has answered ────────────────────────
-- The owner's report was "deleting a character takes seconds to leave the
-- screen". The cause was a fixed 1200ms sleep standing in for an answer the
-- client was already being sent, so these hold the causal chain rather than a
-- duration: the command goes out and NOTHING is asked for until the answer
-- lands, a refusal asks for nothing at all, and a confirmation both drops the
-- row and refetches. A timer cannot be asserted on; a cause can.
section('the staff menu answers the server, not a clock')
do
	local env, control, why = boot('client')
	check('the client boots for the menu feedback tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')

		local asked = {}
		env.TriggerServerEvent = function(name, topic, arg)
			asked[#asked + 1] = { name = name, topic = topic, arg = arg }
			-- The host answers whether the line left, and `Client.Execute` refuses to
			-- believe a nil: a stub that forgot this aborts every command silently.
			return true
		end

		-- The spec and not the surface, for the reason the find screen's wrapper
		-- gives: what reaches the page has the ids and the row data stripped off.
		local specs = {}
		local realMenu = admin.Contracts.menu
		admin.Contracts.menu = setmetatable({
			Open = function(spec) specs[#specs + 1] = spec; return realMenu.Open(spec) end,
			Update = function(handle, spec)
				specs[#specs + 1] = spec
				return realMenu.Update(handle, spec)
			end,
		}, { __index = realMenu })

		local function rowOf(id)
			for _, item in ipairs((specs[#specs] or {}).items or {}) do
				if item.id == id then return item end
			end
			return nil
		end
		local function act(itemId, extra)
			local item = rowOf(itemId)
			if item == nil then return false end
			local payload = { action = 'select', itemId = itemId, handle = 1, data = item.data }
			for key, value in pairs(extra or {}) do payload[key] = value end
			local on
			for index = #specs, 1, -1 do
				if specs[index].on then on = specs[index].on break end
			end
			if on == nil then return false end
			on(payload)
			return true
		end
		local function refreshes(topic)
			local seen = 0
			for _, entry in ipairs(asked) do
				if entry.name == admin.Event.REFRESH and entry.topic == topic then seen = seen + 1 end
			end
			return seen
		end

		control.netEvents[admin.Event.OPEN]({ access = {}, aclKnown = true, inventory = false })
		control.Pump(10)

		--- Opens an account's character list holding two rows and lands on the
		--- confirmation screen for deleting the second.
		local function armDelete()
			admin.Menu.OpenAt('playerCharacters', 2)
			control.Pump(10)
			control.netEvents[admin.Event.CHARACTERS]({ rows = {
				{ citizenId = 'CIT-0001', firstName = 'V', lastName = 'One' },
				{ citizenId = 'CIT-0002', firstName = 'V', lastName = 'Two' },
			}, offset = 0, total = 2, done = true, target = '2' })
			control.Pump(10)
			act('char_CIT-0002')
			control.Pump(10)
			act('delete')
			control.Pump(10)
			asked = {}
			act('confirm')
			control.Pump(6)
		end

		armDelete()
		check('a confirmed delete sends the command line', (function()
			for _, entry in ipairs(asked) do
				if entry.name == OPX.Modules.Get('admin').Host.COMMAND_EXECUTE then return true end
			end
			return false
		end)())
		-- THE POINT OF THE WHOLE CHANGE. Six pumps is well past the 1200ms the old
		-- code slept for, and the list must still not have been asked for: until
		-- the server has answered there is nothing to ask it about.
		check('and asks for no list at all until the server has answered',
			refreshes('characters') == 0, ('%d asked'):format(refreshes('characters')))
		check('so the row is still drawn, because nothing has confirmed it is gone',
			rowOf('char_CIT-0002') ~= nil)

		control.netEvents['open77:command:result'](
			'/opx.admin.character.delete CIT-0002', true, 'deleted')
		control.Pump(4)
		check('the answer is what asks for the list again',
			refreshes('characters') == 1, ('%d asked'):format(refreshes('characters')))
		check('and the row goes on the confirmation rather than on the refetch',
			rowOf('char_CIT-0002') == nil)

		-- A REFUSED DELETE IS THE CASE THAT MATTERS. Nothing was deleted, so the row
		-- stays and no list is read: a UI that removed it and quietly put it back is
		-- how somebody deletes the wrong character twice.
		asked = {}
		armDelete()
		control.netEvents['open77:command:result'](
			'/opx.admin.character.delete CIT-0002', false, 'permission_denied: refused')
		control.Pump(4)
		check('a REFUSED delete leaves the row exactly where it was',
			rowOf('char_CIT-0002') ~= nil)
		check('and spends no list read on a command the server turned down',
			refreshes('characters') == 0, ('%d asked'):format(refreshes('characters')))

		-- THE GREYED ROW. `tagsOwn` is only meaningful while the name tags are on,
		-- and the switch above it is a server round trip -- so the row is greyed
		-- until `TAGS_STATE` lands. What must never come back is the version where
		-- nothing asked for a rebuild and the row stayed greyed until the operator
		-- moved the cursor: this asserts the rebuild, not the delay.
		admin.Menu.OpenAt('self')
		control.Pump(10)
		check('the own-tag row is greyed while the name tags are off',
			(function()
				local item = rowOf('tagsOwn')
				return item ~= nil and item.disabled == true
			end)())
		local before = #specs
		control.netEvents[admin.Event.TAGS_STATE](true, false)
		control.Pump(4)
		check('the name tags arriving rebuilds the screen by itself',
			#specs > before, ('%d rebuilds'):format(#specs - before))
		check('and the own-tag row is a live checkbox in the rebuilt screen',
			(function()
				local item = rowOf('tagsOwn')
				return item ~= nil and not item.disabled and type(item.toggle) == 'boolean'
			end)(), (function()
				local item = rowOf('tagsOwn')
				return item and ('disabled=%s toggle=%s')
					:format(tostring(item.disabled), tostring(item.toggle))
			end)())
	end
end

-- ── one press, one outcome ───────────────────────────────────────────────────
-- The owner's report was "des fois aussi je recois des message du style slow
-- down dans le menu admin mais cela marche quand meme": a Slow down toast on a
-- staff action that went through anyway. It went through because the refusal was
-- never about the action -- the menu's own navigation asked the server for the
-- SAME list three times in a third of a second, the 750ms refresh floor turned
-- the repeats away, and each one raised `error.tooFast` at the operator.
--
-- The two halves are held apart here on purpose. The client must stop asking
-- three times for one list, and the server must stop telling a player off for a
-- background read they never asked for. Either one alone leaves the report half
-- true, and only the pair of them gives one press one outcome.
section('the staff menu never says slow down about a press that worked')
do
	-- ── the server half ──────────────────────────────────────────────────────
	local env, control, why = boot('server')
	check('the server boots for the refresh floor', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local admin = OPX.Modules.Get('admin')
		local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')

		-- READ FIRST, because a floor of 0 would make every check below pass
		-- without the guard ever running. This is also the check that holds the
		-- tunables stub honest: it answered the declaration rather than a live
		-- proxy, every `OPX.Tune.Number` in the suite read as its caller's floor,
		-- and that is why a menu that trips its own rate limit on ordinary
		-- navigation shipped with a green suite behind it.
		check('the refresh floor is the configured 750ms, not the 0 of a tunable ' ..
			'that cannot be read',
			OPX.Tune.Number('ADMIN_RATE_REFRESH_MS', 0) == 750,
			tostring(OPX.Tune.Number('ADMIN_RATE_REFRESH_MS', 0)))

		--- Everything sent to one player since a mark, split into the lists that
		--- were served and the refusals that were raised.
		local function since(mark)
			local served, refused = 0, {}
			for index = mark + 1, #control.clientEvents do
				local entry = control.clientEvents[index]
				if entry.name == NOTIFY then
					local payload = entry[1]
					refused[#refused + 1] = type(payload) == 'table'
						and ('%s/%s'):format(tostring(payload.code), tostring(payload.operation))
						or tostring(payload)
				elseif entry.name == admin.Event.ROSTER then
					served = served + 1
				end
			end
			return served, refused
		end

		-- The refresh event re-checks the opener grant on every ask, so without
		-- this the roster is never served and the checks below would pass on a
		-- refusal rather than on a list.
		control.Allow(7, 'command.' .. admin.OPENER)

		local mark = #control.clientEvents
		env.source = 7
		control.netEvents[admin.Event.REFRESH]('roster')
		control.netEvents[admin.Event.REFRESH]('roster')
		env.source = nil
		local served, refused = since(mark)

		-- THE GUARD STILL GUARDS. Two asks, one answer: the floor is doing its
		-- job, and the fix is not the guard going away.
		check('a repeated list request inside the floor is served once',
			served == 1, ('%d served'):format(served))
		-- AND THE WHOLE BUG. The operator asked for nothing here -- this is the
		-- menu re-reading a list -- so being turned away must cost them no words.
		check('and the one that was turned away says nothing to the operator',
			#refused == 0, table.concat(refused, ', '))

		-- Past the floor it is a new request and is served, so the silence above
		-- is a dropped repeat and not a gate that closed for good.
		control.Pump(10)
		local later = #control.clientEvents
		env.source = 7
		control.netEvents[admin.Event.REFRESH]('roster')
		env.source = nil
		local again, stillQuiet = since(later)
		check('a request past the floor is served again',
			again == 1, ('%d served'):format(again))
		check('and it too is served without a word of refusal',
			#stillQuiet == 0, table.concat(stillQuiet, ', '))
	end

	-- ── the client half ──────────────────────────────────────────────────────
	-- The cadence, which is the other half: three deliberate keypresses used to
	-- put three identical roster requests on the wire inside 300ms, and the two
	-- the server dropped are the two that toasted.
	local cenv, cctl, cwhy = boot('client')
	check('the client boots for the menu cadence', cwhy == nil, cwhy)

	if cwhy == nil then
		local admin = cenv.OPX.Modules.Get('admin')

		local asked = {}
		cenv.TriggerServerEvent = function(name, topic, arg)
			asked[#asked + 1] = { name = name, topic = topic, arg = arg }
			-- The host answers whether the line left, and `Client.Execute` refuses
			-- to believe a nil.
			return true
		end

		local specs = {}
		local realMenu = admin.Contracts.menu
		admin.Contracts.menu = setmetatable({
			Open = function(spec) specs[#specs + 1] = spec; return realMenu.Open(spec) end,
			Update = function(handle, spec)
				specs[#specs + 1] = spec
				return realMenu.Update(handle, spec)
			end,
		}, { __index = realMenu })

		local function rowOf(id)
			for _, item in ipairs((specs[#specs] or {}).items or {}) do
				if item.id == id then return item end
			end
			return nil
		end
		local function act(itemId)
			local item = rowOf(itemId)
			if item == nil then return false end
			local on
			for index = #specs, 1, -1 do
				if specs[index].on then on = specs[index].on break end
			end
			if on == nil then return false end
			on({ action = 'select', itemId = itemId, handle = 1, data = item.data })
			return true
		end
		local function refreshes(topic)
			local seen = 0
			for _, entry in ipairs(asked) do
				if entry.name == admin.Event.REFRESH and entry.topic == topic then seen = seen + 1 end
			end
			return seen
		end

		cctl.netEvents[admin.Event.OPEN]({ access = {}, aclKnown = true, inventory = false })
		cctl.Pump(10)
		cctl.netEvents[admin.Event.ROSTER]({ rows = {
			{ id = 3, name = 'Vee One', state = 'up', bucket = 0 },
			{ id = 4, name = 'Vee Two', state = 'up', bucket = 0 },
		}, offset = 0, total = 2, done = true })
		cctl.Pump(10)
		check('the staff menu is open on the root', admin.Menu.Screen() == 'root')

		-- ONE PUMP BETWEEN PRESSES, which is 100ms of host clock: this is somebody
		-- walking into a player's health screen at a normal pace, well inside the
		-- 750ms floor. A test that pumped ten rounds between presses would be
		-- asserting nothing -- it would have waited the floor out.
		asked = {}
		local walked = act('players')
		cctl.Pump(1)
		walked = walked and act('player_3')
		cctl.Pump(1)
		walked = walked and act('health')
		cctl.Pump(1)
		check('the operator walks root -> Players -> a player -> Health', walked
			and admin.Menu.Screen() == 'playerHealth', tostring(admin.Menu.Screen()))
		check('and the three screens ask for the roster ONCE between them',
			refreshes('roster') == 1, ('%d asked'):format(refreshes('roster')))

		-- Past the floor the same screen asks again: the list is re-read, it is
		-- simply not re-read three times a second. Without this the fix could be
		-- "never ask twice", which is a menu that goes stale.
		cctl.Pump(10)
		asked = {}
		admin.Menu.OpenAt('player', 4)
		cctl.Pump(1)
		check('stepping onto a player screen past the floor asks for the roster again',
			refreshes('roster') == 1, ('%d asked'):format(refreshes('roster')))
	end
end

-- ── the name tags say what the pass decided ──────────────────────────────────
-- The tags stopped drawing after the `opx_lib` migration and produced not one
-- diagnosable line, because every line the pass can write went to a file on the
-- player's machine. These hold the evidence open: a pass that draws nothing has
-- to say WHY through `OPX.Note`, and the four ways it can draw nothing have to
-- be four different sentences.
section('the name tag pass reports what it decided')
do
	-- What the stubbed native answers: a list, or a reason string for a refusal.
	local answer = {}

	local env, control = Host.Environment('client')
	local notes = {}
	env.TriggerServerEvent = function(name, module, text)
		if tostring(name):find('runtime:note', 1, true) then notes[#notes + 1] = tostring(text) end
		return true
	end
	-- The host stubs no `players.nearby` and no `kvp`, which is right for every
	-- other test and is exactly what this one is about.
	env.Open77.players.nearby = function()
		if type(answer) == 'string' then return nil, answer end
		return answer
	end
	env.Open77.kvp = { get = function(_, fallback) return fallback end,
		set = function() return true end }

	local why
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
		local chunk, failure = loadfile(file, 't', env)
		if not chunk then why = failure break end
		local ok, raised = pcall(chunk)
		if not ok then why = raised break end
	end
	check('the client boots for the tag pass tests', why == nil, why)

	if why == nil then
		control.Fire('onClientResourceStart', 'opx_infinity')
		control.Pump(60)
		control.ReadyPages()

		local admin = env.OPX.Modules.Get('admin')

		local function said(fragment)
			for _, note in ipairs(notes) do
				if note:find(fragment, 1, true) then return note end
			end
			return nil
		end

		check('starting says the pass was registered, and on what settings',
			said('pass registered at') ~= nil, table.concat(notes, ' | '))
		-- THE SILENCE THAT COST TWO DIAGNOSES. A switch that never came on and a
		-- pass that computed nothing were the same empty journal.
		check('and a switch that is off says so rather than saying nothing',
			said('the switch is off') ~= nil, table.concat(notes, ' | '))

		notes = {}
		control.netEvents[admin.Event.TAGS_STATE](true, false)
		control.Pump(20)
		check('the switch coming on is reported, so the grant can be ruled out',
			said('the switch is on') ~= nil, table.concat(notes, ' | '))
		check('and an empty world names the call it made and the answer it got',
			said('radius=') ~= nil and said('0 near') ~= nil, table.concat(notes, ' | '))

		-- TWENTY PUMPS AND NOT FOUR, here and at every wait in this section, and
		-- the reason is the scheduler rather than the pass. `OPX.Scheduler` runs
		-- at most `MAX_PER_TICK` jobs per resume and rotates so none starves --
		-- so the more modules a boot registers, the longer any one job waits for
		-- its turn. Four pumps was enough when this was written and stopped being
		-- enough the moment garages, dealerships and clothing stores each brought
		-- their own job. Nothing about the pass changed; the queue in front of it
		-- did.
		--
		-- BODIES BUT NO NAMES is the server's list failing, not a native, and the
		-- line has to be able to say which: they want opposite fixes.
		notes = {}
		answer = {
			{ playerId = 2, entity = 20, distance = 5.0, position = { x = 0, y = 0, z = 0 } },
		}
		control.Pump(20)
		check('bodies with no name list are counted as a naming fault, not a native one',
			said('no name 1') ~= nil, table.concat(notes, ' | '))

		notes = {}
		control.netEvents[admin.Event.TAG_ROWS]({
			rows = { { id = 2, name = 'vee' } }, offset = 0, done = true })
		control.Pump(20)
		check('and once the names arrive the pass reports a row drawn',
			said('1 drawn') ~= nil, table.concat(notes, ' | '))

		-- A REFUSAL FROM THE NATIVE reads as an empty list at the call site, so the
		-- reason has to be carried out or it is indistinguishable from "nobody near".
		notes = {}
		answer = 'no_local_position'
		control.Pump(20)
		check('a refusal from the native carries its reason into the journal',
			said('no_local_position') ~= nil, table.concat(notes, ' | '))

		-- An absent native and an unreachable NAMESPACE are a build fault and a
		-- library fault. The code that tells them apart was being thrown away.
		notes = {}
		env.Open77.players.nearby = nil
		control.Pump(20)
		check('and an unreachable native says which of the two kinds it is',
			said('native_not_found') ~= nil, table.concat(notes, ' | '))
	end
end

-- ── the note door ────────────────────────────────────────────────────────────
-- `OPX.Note` and `core/server/note.lua`. THE ONE THING THIS RUNTIME HAS THAT AN
-- OPERATOR CAN READ about what a client decided, so the suite holds both ends of
-- it: that an honest note arrives, that a hostile one does not, and -- the reason
-- the feature exists at all -- that a door which has closed SAYS SO. A budget
-- that ran out quietly would put an operator back in front of exactly the absence
-- that caused three failed diagnoses of the fitting room in one day.
section('the note door: the client half')
do
	local env, control, why = boot('client')
	check('the client boots for the note tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')

		--- Every note this client put on the wire, newest last.
		local function notes()
			local out = {}
			for index = 1, #control.serverEvents do
				local sent = control.serverEvents[index]
				if sent.name == NOTE then out[#out + 1] = { sent[1], sent[2] } end
			end
			return out
		end

		check('`Note` is on the namespace and is a function',
			type(OPX.Note) == 'function', type(OPX.Note))

		-- NOT ZERO AT BOOT, and that is the converged door working: this harness
		-- brings up a client where most modules are unavailable, and
		-- `modules/diagnostics` now files each of those faults as a note. A real
		-- client that came up clean sends none.
		local base = #notes()
		check('a degraded boot files its module faults as notes', base > 0, base)

		local crossed = OPX.Note('appearance', 'a fitting room is owed')
		local said = notes()
		check('a note crosses the wire, and says so',
			crossed == true and #said == base + 1, #said - base)
		check('carrying the module it was filed under and the words',
			said[#said][1] == 'appearance' and said[#said][2] == 'a fitting room is owed',
			tostring(said[#said][1]) .. '/' .. tostring(said[#said][2]))

		-- The local copy is not the point of the feature, but it is the complete
		-- trail for whoever DOES have the player's machine.
		local lastLocal = control.log.info[#control.log.info]
		check('and it is written to the client log as well',
			type(lastLocal) == 'string' and
				lastLocal:find('[note] appearance: a fitting room is owed', 1, true) ~= nil,
			tostring(lastLocal))

		local before = #notes()
		check('a note with no words does not cross', OPX.Note('appearance', '') == false)
		check('nor does one whose text is not text', OPX.Note('appearance', { 1 }) == false)
		check('nor does one whose text is missing entirely', OPX.Note('appearance') == false)
		check('and none of the three reached the wire', #notes() == before, #notes() - before)

		-- FORGIVING IN ONE DIRECTION ONLY. A caller who passed the wrong module
		-- still gets their evidence into the journal; the server is what decides
		-- whether the id is one it will print.
		OPX.Note(nil, 'the module id was lost')
		said = notes()
		check('a note with no module id still crosses, under a placeholder',
			said[#said][1] == 'unnamed', tostring(said[#said][1]))

		-- The client cut is a courtesy to the wire; the server enforces its own.
		OPX.Note('appearance', ('x'):rep(900))
		said = notes()
		check('an over-long note is cut before it is sent',
			#said[#said][2] == 403, #said[#said][2])

		OPX.Note('appearance', 'first\n[2026-01-01] [info] player was banned')
		said = notes()
		check('a newline is gone before the text leaves the client',
			said[#said][2]:find('\n') == nil, said[#said][2])

		-- A DIAGNOSTIC THAT CAN BREAK THE THING IT IS DIAGNOSING IS WORSE THAN
		-- NONE. The whole body is under a `pcall`, so a wire that raises is a
		-- `false` and not a stack trace out of whatever was already going wrong.
		local realSend = env.TriggerServerEvent
		env.TriggerServerEvent = function() error('the wire is down', 0) end
		local raised = not pcall(OPX.Note, 'appearance', 'sent while the wire is down')
		env.TriggerServerEvent = realSend
		check('a wire that raises does not raise out of `Note`', raised == false)
	end
end

section('the note door: the client budget announces itself')
do
	-- A FRESH CLIENT, because the budget is per session and the tests above have
	-- already spent some of it.
	local env, control, why = boot('client')
	if why == nil then
		local OPX = env.OPX
		local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')

		for index = 1, 200 do OPX.Note('appearance', ('decision %d'):format(index)) end

		local crossed, suppression, lastModule = 0, {}, nil
		for index = 1, #control.serverEvents do
			local sent = control.serverEvents[index]
			if sent.name == NOTE then
				crossed = crossed + 1
				lastModule = sent[1]
				if type(sent[2]) == 'string' and sent[2]:find('budget', 1, true) then
					suppression[#suppression + 1] = sent[2]
				end
			end
		end

		check('two hundred notes cost exactly the budget on the wire', crossed == 60, crossed)
		check('and the budget spends its LAST slot saying that it is spent',
			#suppression == 1, #suppression)
		check('exactly once, and not once per dropped note',
			suppression[1] ~= nil and
				suppression[1]:find('budget of 60 is spent', 1, true) ~= nil,
			tostring(suppression[1]))
		check('filed under the runtime, not under whichever module was last',
			lastModule == 'runtime', tostring(lastModule))

		-- The client log keeps everything. It is the JOURNAL that has the hole,
		-- and the point of the line above is that the hole is labelled.
		local kept = 0
		for index = 1, #control.log.info do
			if control.log.info[index]:find('[note] appearance:', 1, true) then kept = kept + 1 end
		end
		check('while the client log still has all two hundred', kept == 200, kept)
	end
end

section('the note door: the server half')
do
	-- A CLOCK THE TEST OWNS. `Pump` only advances time while a thread is still
	-- suspended, and both ceilings under test are measured in milliseconds.
	local at = 0
	local env, control, why = boot('server', nil, function(sandbox)
		sandbox.GetGameTimer = function() return at end
	end)
	check('the server boots for the note tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')

		--- One note arriving from a player, exactly as the host would deliver it.
		local function say(player, module, text)
			env.source = player
			control.netEvents[NOTE](module, text)
			env.source = nil
		end

		--- Journal lines this door has written, at one level.
		local function journal(level)
			local out = {}
			local lines = control.log[level]
			for index = 1, #lines do
				if lines[index]:find('[note]', 1, true) then out[#out + 1] = lines[index] end
			end
			return out
		end

		local function count(level) return #journal(level) end

		check('the door is registered on the net channel',
			type(control.netEvents[NOTE]) == 'function')

		say(3, 'appearance', 'a fitting room is owed to citizen-7')
		local written = journal('info')
		check('an honest note reaches the journal', #written == 1, #written)
		check('attributed to the player and the module it came from',
			written[1] ~= nil and
				written[1]:find('[note] appearance from player 3:', 1, true) ~= nil,
			tostring(written[1]))

		-- ── what the door refuses ────────────────────────────────────────────
		local was = count('info')

		-- Only `source` is not chosen by the client, and the console is not a
		-- client: a note attributed to nobody is a line an operator would read as
		-- if the server itself had written it.
		say(0, 'appearance', 'from nobody')
		check('a note from no player is refused', count('info') == was)

		say(3, 'appearance', 42)
		say(3, 42, 'the module id is a number')
		say(3, nil, nil)
		say(3, { 'appearance' }, 'the module id is a table')
		check('a payload of the wrong types is refused', count('info') == was, count('info') - was)

		say(3, 'Appearance', 'a capital')
		say(3, 'appearance two', 'a space')
		say(3, '../../etc', 'a path')
		say(3, '[audit] event=ban', 'a module id dressed as a log line')
		say(3, ('a'):rep(40), 'a module id past the ceiling')
		say(3, '', 'no module id at all')
		check('a module id that is not a module id is refused',
			count('info') == was, count('info') - was)

		-- REFUSED WHOLE, not truncated: cleaning a payload a client made large on
		-- purpose is the work the attacker wanted done.
		say(3, 'appearance', ('x'):rep(4000))
		check('a note past the byte ceiling is refused whole', count('info') == was)

		-- `pure/string.lua` makes this argument at length: a newline in text that
		-- reaches a format string writes a second line indistinguishable from one
		-- the runtime wrote.
		say(3, 'appearance', 'harmless\n[2026-01-01] [info] player 3 was granted admin\r\tmore')
		written = journal('info')
		local forged = written[#written]
		check('a control character cannot forge a second journal line',
			forged ~= nil and forged:find('\n') == nil and forged:find('\r') == nil and
				forged:find('\t') == nil, (forged or ''):gsub('%c', '?'))
		check('and the words themselves still arrive',
			forged ~= nil and forged:find('granted admin', 1, true) ~= nil, tostring(forged))

		-- Cut to the same figure the client cuts to, so text that got under the
		-- byte ceiling still cannot own the line.
		say(3, 'appearance', ('y'):rep(900))
		written = journal('info')
		check('an over-long note that fits the byte ceiling is truncated',
			#written[#written] < 500, #written[#written])

		-- ── the window ───────────────────────────────────────────────────────
		local burst = 21
		was = count('info')
		for index = 1, 30 do say(burst, 'appearance', ('burst %d'):format(index)) end
		check('a burst is cut off at the window allowance', count('info') - was == 12,
			count('info') - was)

		at = at + 10000
		say(burst, 'appearance', 'the window came round')
		check('and the window is RENEWABLE, not a second budget',
			count('info') - was == 13, count('info') - was)

		-- ── the budget, and the line that says it went ───────────────────────
		local talker = 22
		was = count('info')
		local wasWarn = count('warn')

		--- One note per window, so the window never bites and only the budget can.
		local function paced(text)
			at = at + 10000
			say(talker, 'appearance', text)
		end

		for index = 1, 100 do paced(('decision %d'):format(index)) end
		check('a hundred notes cost exactly the budget in the journal',
			count('info') - was == 60, count('info') - was)

		local warned = journal('warn')
		local announcements = 0
		for index = 1, #warned do
			if warned[index]:find('spent their budget', 1, true) then
				announcements = announcements + 1
			end
		end
		check('AN EXHAUSTED BUDGET IS VISIBLE, not silence', announcements == 1, announcements)
		check('and it names the player and the figure',
			warned[#warned] ~= nil and
				warned[#warned]:find('player 22 has spent their budget of 60', 1, true) ~= nil,
			tostring(warned[#warned]))
		check('one alarm only, however long the flood runs',
			count('warn') - wasWarn == 1, count('warn') - wasWarn)

		-- The alarm says the budget went; the tally says how much went with it,
		-- which is the difference between a trail with a known hole and a trail
		-- nobody can size.
		wasWarn = count('warn')
		control.Fire(OPX.Host.PLAYER_DISCONNECTED, talker)
		warned = journal('warn')
		check('a departure reports how many notes were lost',
			warned[#warned] ~= nil and
				warned[#warned]:find('player 22: 40 further notes suppressed', 1, true) ~= nil,
			tostring(warned[#warned]))
		check('exactly one tally line', count('warn') - wasWarn == 1, count('warn') - wasWarn)

		-- A player id is recycled, and a spent budget left behind would silence
		-- the next holder of the slot before they had said anything.
		was = count('info')
		at = at + 10000
		say(talker, 'appearance', 'the slot has a new holder')
		check('and the slot starts clean for whoever holds it next',
			count('info') - was == 1, count('info') - was)

		-- Nothing dropped, nothing said: the ordinary departure costs no line.
		wasWarn = count('warn')
		control.Fire(OPX.Host.PLAYER_DISCONNECTED, 3)
		check('a departure that lost nothing says nothing', count('warn') == wasWarn)
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


-- ── clothing shops: the half that is pure ───────────────────────────────────
-- THE PRICE MODEL IS TESTED AND THE WORLD IS NOT, which is the split this
-- module was written for. Whether a player is standing at a counter needs a
-- server, a body and a position; what their change COSTS needs none of those,
-- so it lives in `module.lua` as plain functions over plain tables and is held
-- to account here.
section('shops')
do
	local env, _, why = boot('client')
	check('the client boots with the shops module', why == nil, why)

	local shops = why == nil and env.OPX.Modules.Get('shops') or nil
	check('the module declared itself', type(shops) == 'table')

	if type(shops) == 'table' then
		-- THE COPY THAT MUST NOT DRIFT. `shops.SLOTS` is a hand-written mirror of
		-- `appearance`'s list, because a shared file cannot reach a client-only
		-- table and a module may not read another's settings. The comment on it
		-- promises this test exists; here it is.
		local appearance = env.OPX.Modules.Get('appearance')
		local theirs = type(appearance) == 'table' and type(appearance.Clothing) == 'table'
			and appearance.Clothing.SLOTS or nil
		check('the slot list is the same one appearance uses',
			type(theirs) == 'table' and #theirs == #shops.SLOTS
			and table.concat(theirs, ',') == table.concat(shops.SLOTS, ','),
			type(theirs) == 'table' and table.concat(theirs, ',') or 'appearance has no SLOTS')

		check('a slot name is recognised', shops.IsSlot('Legs') == true)
		check('and anything else is not',
			shops.IsSlot('Trousers') == false and shops.IsSlot(nil) == false)

		-- ── what changed ──
		check('an untouched look owes nothing',
			#shops.Changed({ Legs = 'Items.A' }, { Legs = 'Items.A' }) == 0)
		check('a swapped garment is one slot',
			table.concat(shops.Changed({ Legs = 'Items.A' }, { Legs = 'Items.B' }), ',') == 'Legs')

		-- TAKING SOMETHING OFF IS A CHANGE. It is the case a naive diff misses,
		-- and a shop that did not bill it would let anybody re-dress for free by
		-- emptying a slot and filling it on a second visit.
		check('emptying a slot is a change',
			table.concat(shops.Changed({ Head = 'Items.Hat' }, { Head = false }), ',') == 'Head')

		-- ...AND nil IS NOT. An absent key and an explicitly empty slot are the
		-- same state wearing two spellings; charging for the difference between
		-- them would bill a player for how the record happened to be encoded.
		check('nil and false are the same emptiness',
			#shops.Changed({ Head = nil }, { Head = false }) == 0)

		check('the answer is in the canonical order, not the table order',
			table.concat(shops.Changed({}, { Feet = 'Items.B', Head = 'Items.A' }), ',')
				== 'Head,Feet')

		-- ── what it costs ──
		local prices = shops.Prices({ Legs = 450, Feet = 300, Head = 250 }, { Legs = 140 })
		check('a shop overrides one price and inherits the rest',
			prices.Legs == 140 and prices.Feet == 300 and prices.Head == 250)
		check('a key that is not a slot never becomes a price',
			shops.Prices({ Trousers = 900 }, nil).Trousers == nil)

		check('the bill is the sum of the slots that moved',
			shops.Bill(prices, { 'Legs', 'Feet' }) == 440)
		check('a slot with no price is free rather than an error',
			shops.Bill(prices, { 'Outfit' }) == 0)
		check('changing nothing costs nothing', shops.Bill(prices, {}) == 0)

		-- ── codes ──
		local length = 8
		check('a code survives being read out badly',
			shops.CleanCode('  abcd-2345 ', length) == 'ABCD2345')
		check('a code of the wrong length is refused',
			shops.CleanCode('ABCD234', length) == nil)

		-- NOTHING IS GUESSED, and this is the check that holds that decision.
		-- Crockford's base32 reads a typed `I` as `1`; this alphabet contains
		-- neither, so there is no correct target and a guess would hand somebody
		-- a different look than the one they were read out.
		check('a character the alphabet excludes is refused, not remapped',
			shops.CleanCode('ABCD2I45', length) == nil
			and shops.CleanCode('ABCD2O45', length) == nil)

		local step = 0
		local minted = shops.MintCode(length, function(_, high)
			step = step + 1
			return ((step - 1) % high) + 1
		end)
		check('a minted code is the length asked for', #minted == length)
		local clean = true
		for index = 1, #minted do
			if not shops.CODE_ALPHABET:find(minted:sub(index, index), 1, true) then clean = false end
		end
		check('and every character of it is in the alphabet', clean, minted)
		check('and a minted code reads back as itself',
			shops.CleanCode(minted, length) == minted)
	end
end

-- ── walking through an emote ────────────────────────────────────────────────
-- THE LEASE IS THE RISK, not the feature. `Open77.movement.setWalkMode` is a
-- request held on the PLAYER, not a property of the animation: if an emote ends
-- and nothing releases, that player walks for the rest of their session with
-- nothing on screen to explain it and no way to undo it. So what is tested here
-- is almost entirely the giving back.
section('animations: walking through an emote')
do
	local env, _, why = boot('client')
	check('the client boots with the walk half', why == nil, why)

	local animations = why == nil and env.OPX.Modules.Get('animations') or nil
	local Walk = type(animations) == 'table' and animations.Walk or nil
	check('the walk half declared itself', type(Walk) == 'table')

	if type(Walk) == 'table' then
		-- A recorder in place of the native, so every ask and every release is
		-- counted rather than inferred.
		local asked = {}
		env.Open77.movement = {
			setWalkMode = function(enabled, speed)
				asked[#asked + 1] = { enabled = enabled, speed = speed }
				return true
			end,
		}

		local Catalogue = animations.Catalogue

		-- ── the catalogue rule ──
		-- EVERY WALKABLE EMOTE IS A STANDING ONE, asserted across the whole
		-- catalogue rather than on one row. `sit`, `examine` and `wounded` are
		-- authored against the ground: walking out of one does not produce a
		-- player strolling while seated, it produces a body sliding across the
		-- pavement in a pose that stopped meaning anything.
		local entries = Catalogue.Entries()
		local offenders = {}
		local walkable = 0
		for index = 1, #entries do
			local entry = entries[index]
			if entry.walk ~= nil then
				walkable = walkable + 1
				if entry.placement ~= 'standing' then
					offenders[#offenders + 1] = entry.name
				end
				if entry.walk < 0.5 or entry.walk > 2.5 then
					offenders[#offenders + 1] = entry.name .. '(speed)'
				end
			end
		end
		check('some emotes are walkable at all', walkable > 0, tostring(walkable))
		check('and every one of them is a standing pose within the speed bounds',
			#offenders == 0, table.concat(offenders, ','))

		-- ── taking and giving back ──
		check('nothing is held before an emote plays', Walk.Held() == nil)

		Walk.Follow(true, 'smoke')
		check('a walkable emote takes the lease at its own speed', Walk.Held() == 1.3,
			tostring(Walk.Held()))
		check('and it asked the platform exactly once',
			#asked == 1 and asked[1].enabled == true and asked[1].speed == 1.3)

		-- ASKED ONCE, NOT ONCE A FRAME. The state funnel fires on every change and
		-- a re-ask at the same speed would be a native call per event for nothing.
		Walk.Follow(true, 'smoke')
		check('holding it again at the same speed asks nothing more', #asked == 1)

		Walk.Follow(true, 'drink')
		check('a different emote moves the lease rather than stacking one',
			Walk.Held() == 1.2 and #asked == 2 and asked[2].speed == 1.2)

		Walk.Follow(true, 'dance')
		check('an emote that does not walk gives the lease back',
			Walk.Held() == nil and asked[#asked].enabled == false)

		Walk.Follow(true, 'smoke')
		Walk.Follow(false, nil)
		check('and so does the emote ending', Walk.Held() == nil
			and asked[#asked].enabled == false)

		Walk.Follow(true, 'no_such_emote')
		check('an emote this client does not know holds nothing', Walk.Held() == nil)

		-- ── the watchdog ──
		-- The reason it exists: the release above is a promise about every exit
		-- path, and a promise about every path is the kind that is kept until
		-- somebody adds a path. This is what makes it survive that.
		animations.Presenter.State = function() return { active = false } end
		Walk.Follow(true, 'smoke')
		check('the lease is held before the sweep', Walk.Held() == 1.3)
		Walk.Check()
		check('a lease with no emote under it is swept', Walk.Held() == nil)

		animations.Presenter.State = function()
			return { active = true, animation = 'smoke' }
		end
		Walk.Follow(true, 'smoke')
		Walk.Check()
		check('and a lease that still has one is left alone', Walk.Held() == 1.3)

		-- ── a host that cannot do it ──
		-- op77.75 is recent. A client older than that is not broken; it simply
		-- cannot walk through an emote, and must not raise trying.
		Walk.Release()
		env.Open77.movement = nil
		check('a build without the native reports it', Walk.Available() == false)
		local safe = pcall(Walk.Follow, true, 'smoke')
		check('and asking for a walk on one neither holds nor raises',
			safe and Walk.Held() == nil)
	end
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


-- ── the magazine, and whether the gun is actually in hand ───────────────────
-- TWO DEFECTS THE OWNER FOUND BY PLAYING, and both are the same mistake in
-- different clothes: a number read from the wrong place, and a state read from
-- the wrong place.
section('weapons: the magazine and the hand')
do
	local env, _, why = boot('server')
	check('the server boots', why == nil, why)

	local inventory = why == nil and env.OPX.Modules.Get('inventory') or nil
	check('the inventory module is there', type(inventory) == 'table')

	if type(inventory) == 'table' then
		local Catalog = inventory.Catalog

		-- ── the magazine ──
		-- `AMMO.MAX` is how many rounds fit in a BOX. The weapon half read it as
		-- how many fit in the GUN, so a pistol took the whole crate and never
		-- reloaded. These two numbers must not be the same one.
		local pistol = Catalog.Get('weapon_chao')
		check('a weapon carries a magazine', pistol ~= nil
			and type(pistol.weapon) == 'table' and pistol.weapon.magazine ~= nil,
			pistol and tostring(pistol.weapon and pistol.weapon.magazine))

		local box = Catalog.Get('ammo_handgun')
		check('and it is NOT the ammunition box its class loads',
			pistol ~= nil and box ~= nil
				and pistol.weapon.magazine ~= box.ammo.max,
			box and ('magazine %s vs box %s'):format(
				tostring(pistol and pistol.weapon.magazine), tostring(box.ammo.max)))

		check('and it is a handful of rounds rather than a crateful',
			pistol ~= nil and pistol.weapon.magazine > 0 and pistol.weapon.magazine <= 50,
			pistol and tostring(pistol.weapon.magazine))

		-- Every class that loads ammunition states one, checked across the whole
		-- catalogue: one missing is one weapon that silently loads nothing.
		local missing = {}
		local armed = 0
		for _, name in ipairs(Catalog.Names()) do
			local item = Catalog.Get(name)
			if type(item) == 'table' and type(item.weapon) == 'table'
				and item.weapon.ammo ~= nil then
				armed = armed + 1
				if item.weapon.magazine == nil then missing[#missing + 1] = name end
			end
		end
		check('some weapons load ammunition at all', armed > 0, tostring(armed))
		check('and every one of them states a magazine', #missing == 0,
			table.concat(missing, ',', 1, math.min(#missing, 6)))

		-- ── the hand ──
		-- `armed[source]` is OUR record of what we last put there. The game
		-- holsters on its own -- a vehicle, a knockdown -- and then Use, which
		-- reads as a toggle, put away something already away.
		local Weapons = inventory.Weapons
		check('the in-hand question is askable', type(Weapons.InHand) == 'function')

		if type(Weapons.InHand) == 'function' then
			local answer = nil
			env.Open77.weapons = env.Open77.weapons or {}
			env.Open77.weapons.get = function() return answer end

			answer = { drawn = true, fresh = true }
			check('a fresh answer saying drawn is believed', Weapons.InHand(1) == true)

			answer = { drawn = false, fresh = true }
			check('and a fresh answer saying holstered is believed too',
				Weapons.InHand(1) == false)

			-- DO-NOT-KNOW KEEPS THE OLD BEHAVIOUR, and these three are why the
			-- default is `true` rather than `false`. The platform calls this a
			-- cache and says to read it to decide, never to assert: a stale
			-- reading, a player the host has heard nothing from, and a build
			-- without the call are all "cannot say". Answering "not in hand" to
			-- any of them would trade a rare wrong holster for a constant wrong
			-- draw.
			answer = { drawn = false, fresh = false }
			check('a STALE answer is not taken as holstered', Weapons.InHand(1) == true)

			answer = nil
			check('and neither is a refusal', Weapons.InHand(1) == true)

			env.Open77.weapons.get = nil
			check('nor a build that cannot be asked', Weapons.InHand(1) == true)

			env.Open77.weapons.get = function() error('boom') end
			check('and a reader that raises does not take the caller with it',
				Weapons.InHand(1) == true)
			env.Open77.weapons.get = nil
		end
	end
end

-- ── the rounds a drawn weapon comes out with ────────────────────────────────
-- THE OWNER DREW A WEAPON HOLDING ZERO ROUNDS AND IT CAME OUT SHOOTING. The
-- cause is one missing field rather than a wrong sum: `setAmmo` changes only
-- what it is TOLD about, and the fallback split named the reserve and said
-- nothing of the magazine -- so the engine kept the full one it loaded when the
-- weapon was assigned. Every case below therefore asserts that BOTH halves are
-- stated, not only that they add up.
section('weapons: the rounds a draw comes out with')
do
	local env, _, why = boot('server')
	check('the server boots', why == nil, why)

	local inventory = why == nil and env.OPX.Modules.Get('inventory') or nil
	local Weapons = type(inventory) == 'table' and inventory.Weapons or nil
	check('the split is askable on its own', type(Weapons) == 'table'
		and type(Weapons.Amounts) == 'function')

	if type(Weapons) == 'table' and type(Weapons.Amounts) == 'function' then
		-- THE BUG, AS A CHECK. No capacity reading, no rounds on the item: the
		-- weapon must be stated empty rather than left as the engine loaded it.
		local empty = Weapons.Amounts(0, nil, nil, false)
		check('an empty item states an empty magazine rather than staying silent',
			empty.magazine == 0, tostring(empty.magazine))
		check('and an empty reserve with it', empty.reserve == 0, tostring(empty.reserve))

		-- Every other shape has to state both as well, or the same hole reopens
		-- somewhere else.
		local known = Weapons.Amounts(0, 30, nil, false)
		check('an empty item with a known capacity is empty too',
			known.magazine == 0 and known.reserve == 0)

		local full = Weapons.Amounts(50, 30, nil, false)
		check('a known capacity fills the magazine and reserves the rest',
			full.magazine == 30 and full.reserve == 20,
			('%s / %s'):format(tostring(full.magazine), tostring(full.reserve)))

		local under = Weapons.Amounts(12, 30, nil, false)
		check('fewer rounds than the magazine holds all go in it',
			under.magazine == 12 and under.reserve == 0)

		-- UNKNOWN CAPACITY IS NOT UNKNOWN MAGAZINE. Zero is the one value that is
		-- always safe to state -- no capacity is below it -- so the rounds go to
		-- the reserve and the player chambers them. Stating nothing was what let
		-- the engine answer instead.
		local blind = Weapons.Amounts(40, nil, nil, false)
		check('with no capacity reading the rounds go to the reserve',
			blind.magazine == 0 and blind.reserve == 40,
			('%s / %s'):format(tostring(blind.magazine), tostring(blind.reserve)))

		-- A reload keeps what is already chambered: the split is taken from the
		-- reading rather than guessed, which is why the snapshot is asked first.
		local reload = Weapons.Amounts(40, 30, 7, true)
		check('a reload keeps what is chambered and reserves the rest',
			reload.magazine == 7 and reload.reserve == 33)

		local overdrawn = Weapons.Amounts(3, 30, 7, true)
		check('and never chambers more rounds than the item actually holds',
			overdrawn.magazine == 3 and overdrawn.reserve == 0,
			('%s / %s'):format(tostring(overdrawn.magazine), tostring(overdrawn.reserve)))

		-- Whatever the branch, the two halves are the item's rounds and no more.
		-- This is the invariant the whole function exists to hold: the engine is
		-- never handed a round the item did not have.
		local shapes = {
			{ 0, nil, nil, false }, { 0, 30, nil, false }, { 50, 30, nil, false },
			{ 12, 30, nil, false }, { 40, nil, nil, false }, { 40, 30, 7, true },
			{ 3, 30, 7, true },
		}
		local kept = true
		for index = 1, #shapes do
			local s = shapes[index]
			local out = Weapons.Amounts(s[1], s[2], s[3], s[4])
			if out.magazine == nil or out.reserve == nil
				or out.magazine + out.reserve ~= s[1] then kept = false end
		end
		check('every split states both halves and invents no rounds', kept)
	end
end

-- ── the version is one number, in three places ──────────────────────────────
-- THE SERVER REPORTED 0.1.0 WHILE THE MANIFEST SAID 0.1.2, for two releases,
-- and the only symptom was the owner reading the wrong number off a boot line
-- while chasing something else. `core/shared/main.lua` now ASKS the platform --
-- `Open77.resource.version()` on the client, `resource.metadata` on the server,
-- neither needing a permission -- so on a real host nothing can drift.
--
-- The literal in that file is the last resort for a host that answers neither,
-- and this is what stops the last resort from being the next stale number. Read
-- out of the SOURCE, because the suite rightly forbids publishing it on `OPX`
-- just so a test can see it. `opx_lib` carries the same check for the same
-- reason; there it was written after the drift, and here after it happened
-- again in the other repository.
section('the version')
do
	local function grab(path, pattern)
		local handle = io.open(path, 'r')
		local body = handle and handle:read('a') or ''
		if handle then handle:close() end
		return body:match(pattern)
	end

	local literal = grab('core/shared/main.lua', "local DECLARED = '([%d%.]+)'")
	local manifest = grab('open77.lua', '\nversion "([%d%.]+)"')

	check('core states a fallback version', literal ~= nil, tostring(literal))
	check('the manifest states one', manifest ~= nil, tostring(manifest))
	check('and they are the same number', literal == manifest,
		('core %s vs manifest %s'):format(tostring(literal), tostring(manifest)))
end

-- ── one glyph vocabulary, and the page can draw every name in it ────────────
-- WRITTEN AFTER COUNTING THREE COPIES THAT DISAGREED. `Model.ICONS`,
-- `menu.M.ICONS` and `OPX.Toast.ICONS` were three hand-kept lists, each under a
-- comment telling the next author to change all of them in the same change. On
-- disk they held 47 names, 45 and 14. Nothing had broken, because no caller
-- passes a toast an icon -- it was a trap, not a fault, and the only reason it
-- was ever found is that somebody read the three tables side by side.
--
-- So the set now lives once, in `core/shared/glyphs.lua`, and two things are
-- checked here. First that the three names really are THE SAME TABLE and not
-- three fresh copies again: identity, not equality, because a copy made today
-- would pass an equality check and drift tomorrow. Second that every name in it
-- has a path in `ui/src/modules/target/glyphs.ts` and every path has a name --
-- the one seam a shared Lua file cannot close, since a `.ts` file is not
-- loadable from Lua, and the seam the two dropped names (`inside`, `named`)
-- came through. Lua promising a glyph the page has no path for is a row that
-- validates, reaches the DOM and draws the fallback.
-- ── a payload the host refused is not a toast that went up ───────────────────
-- `OPX.Surface.Send` answers `(sent, refused)`. The second is true when the host
-- TOOK the call and rejected the payload as too large or not serialisable -- a
-- pcall cannot see that, and `notify.lua` read only the first value. `live[id]`
-- then held a toast the page had never drawn, and every later `Update` and
-- `Dismiss` addressed something that was not there. `modules/panel` found this
-- the expensive way: a refused batch of clothes was reported to the fitting room
-- as delivered and the room sat on "Reading the catalogue" for good.
section('a refused payload is not a toast')
do
	local env, _, why = boot('client')
	check('the client boots', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local real = OPX.UI.Send

		-- Delivered, then refused, then delivered again: the middle one is the
		-- case, and the two around it prove the gate is not simply shut.
		local raised = OPX.Toast.Show({ id = 'ok', message = 'first' })
		check('a toast the host accepts goes up', raised == 'ok', tostring(raised))

		OPX.UI.Send = function() return true, true end
		local refusedId, reason = OPX.Toast.Show({ id = 'big', message = 'second' })
		check('a toast whose payload the host refused does NOT go up',
			refusedId == nil, tostring(refusedId))
		check('and says why', reason == 'payload_refused', tostring(reason))

		OPX.UI.Send = real
		check('and Lua is not holding it: an update finds nothing to patch',
			OPX.Toast.Update('big', { message = 'third' }) == false)
		check('while the one that did go up is still addressable',
			OPX.Toast.Update('ok', { message = 'third' }) == true)

		-- The other door into the same payload.
		OPX.UI.Send = function() return true, true end
		local patched, patchWhy = OPX.Toast.Update('ok', { message = 'fourth' })
		check('a refused UPDATE answers false rather than true', patched == false)
		check('and says why too', patchWhy == 'payload_refused', tostring(patchWhy))
		OPX.UI.Send = real
	end
end

-- ── the page does not outlive the resource ───────────────────────────────────
-- `OPX.UI.Teardown` says in its own docstring that this is the stop path. The
-- stop path -- `onClientResourceStop` in `core/client/boot.lua` -- called
-- `Scheduler.Stop` and `Modules.Stop` and never called it, so the CEF page the
-- resource built was left alive behind it.
section('the page goes down with the resource')
do
	local env, control, why = boot('client')
	check('the client boots', why == nil, why)

	if why == nil then
		local before = 0
		for _, page in ipairs(control.pages) do
			if page.alive ~= false then before = before + 1 end
		end
		check('a page was built', before > 0, before)

		control.Fire('onClientResourceStop', 'opx_infinity')

		local after = 0
		for _, page in ipairs(control.pages) do
			if page.alive ~= false then after = after + 1 end
		end
		check('and none is left alive after the resource stops', after == 0, after)
	end
end

-- ── the hotbar peek ─────────────────────────────────────────────────────────
-- The hotbar keys work with the bag SHUT, which is the point of them and also
-- the problem: nothing on screen says what they are bound to until you open the
-- bag and look, by which time you did not need the key. One key shows the row
-- for a few seconds.
--
-- WHAT IS ACTUALLY CHECKED HERE is that it costs nothing it should not. The
-- client already holds the whole bag -- `Screen.Own()` is the mirror the server
-- pushes on every change -- so a peek must be a read of a table this runtime
-- already has and NOT a round trip; and Lua must keep no timer, because a
-- `Wait` loop for a thing on screen four seconds at a time is a cost every
-- client pays forever. Both of those are invisible from the screen, which is
-- why they are asserted rather than eyeballed.
section('the hotbar peek')
do
	local env, control, why = boot('client')
	check('the client boots', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local inventory = OPX.Modules.Get('inventory')
		local Slotbar = inventory.Slotbar
		local page = control.pages[1]

		check('the peek module is loaded', type(Slotbar) == 'table')

		check('the peek key is registered',
			control.keyMappings.byId['opx.inventory.peek'] ~= nil)
		check('and it is not one of the hotbar keys it would shadow',
			control.keyMappings.byId['opx.inventory.peek'] ~= nil
				and control.keyMappings.byId['opx.inventory.peek'].key
					~= control.keyMappings.byId['opx.inventory.hotbar1'].key)

		local function drew()
			local found
			for index = 1, #page.sent do
				if page.sent[index].channel == 'opx:inventory:slotbar' then found = page.sent[index] end
			end
			return found
		end

		-- NO BAG IS A REFUSAL, not an empty row. A player who has not loaded a
		-- character has no hotbar to look at.
		local before = 0
		for _, sent in ipairs(control.serverEvents) do
			if sent.name == inventory.Event.HELLO then before = before + 1 end
		end

		local ok, reason = Slotbar.Peek()
		check('a peek with no bag is refused', ok == false and reason == 'no_bag', tostring(reason))
		check('and nothing was drawn', drew() == nil)

		-- IT ASKS RATHER THAN JUST REFUSING. The mirror is filled by
		-- `M.Event.OWN`, pushed from `Containers.Publish` at the HELLO handshake
		-- through `Players.Attach`. A player whose attach answered `not_loaded`
		-- because the character was not up yet holds nil until their first
		-- pickup -- and the peek is exactly the gesture such a player makes
		-- first. This is the check the shipped version did not have: it asserted
		-- the refusal and stopped there, so a key that did nothing for a whole
		-- class of player passed.
		-- COUNTED ACROSS THE PRESS, not searched for. The client half already
		-- sends one HELLO from `Start`, so a check that merely looked for one
		-- passed whether the peek asked or not -- it stayed green under the
		-- mutant that removed the ask, which makes it not a check.
		local function hellos()
			local n = 0
			for _, sent in ipairs(control.serverEvents) do
				if sent.name == inventory.Event.HELLO then n = n + 1 end
			end
			return n
		end
		check('and the client asks the server for its bag instead of giving up',
			hellos() > before, ('%d hello(s), was %d'):format(hellos(), before))

		-- AND IT SAYS SO WHERE THE OPERATOR CAN READ IT. `Open77.log` on a client
		-- writes to the PLAYER'S machine; `OPX.Note` is the bounded relay that
		-- reaches the server journal. A refusal nobody can see is how this bug
		-- survived a deploy.
		local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')
		local told = false
		for _, sent in ipairs(control.serverEvents) do
			if sent.name == NOTE and tostring(sent[2]):find('no_bag', 1, true) then told = true end
		end
		check('and the refusal reaches the operator, not just the player', told)

		-- The bag, pushed the way the server pushes it.
		control.netEvents[inventory.Event.OWN]({
			id = 1, kind = 'player', slots = 50, maxWeight = 100000, weight = 500,
			items = {
				{ slot = 1, name = 'bandage', count = 3, metadata = {} },
				{ slot = 3, name = 'water', count = 1, metadata = {} },
			},
		})

		check('a peek with a bag goes up', Slotbar.Peek() == true)

		local shown = drew()
		check('and something was drawn', shown ~= nil)

		if shown ~= nil then
			local slots = shown.payload and shown.payload.slots or {}
			check('one row per hotbar slot, gaps included',
				#slots == inventory.Options.HOTBAR_SLOTS,
				('%d vs %d'):format(#slots, inventory.Options.HOTBAR_SLOTS))

			-- EVERY SLOT IS DRAWN, EMPTY OR NOT. Closing the gap would renumber
			-- the row the player is trying to memorise.
			check('slot 2 is drawn even though it holds nothing',
				slots[2] ~= nil and slots[2].slot == 2 and slots[2].name == nil)

			check('a filled slot carries its name and count',
				slots[1] ~= nil and slots[1].name == 'bandage' and slots[1].count == 3,
				slots[1] and tostring(slots[1].name))
			check('and a label the overlay can draw without a catalogue',
				slots[1] ~= nil and type(slots[1].label) == 'string' and slots[1].label ~= '')
			check('the sparse payload is read by SLOT and not by position',
				slots[3] ~= nil and slots[3].name == 'water',
				slots[3] and tostring(slots[3].name))

			check('every row carries the key that uses it',
				slots[1] ~= nil and slots[1].key ==
					control.keyMappings.byId['opx.inventory.hotbar1'].key,
				slots[1] and tostring(slots[1].key))

			check('the page is told how long to hold it, and times itself',
				tonumber(shown.payload and shown.payload.holdMs) == inventory.Options.HOTBAR_PEEK_MS,
				shown.payload and tostring(shown.payload.holdMs))
		end

		-- LUA KEEPS NO TIMER. If it did, a job would be registered for it, and
		-- the scheduler report is where one would show up.
		local ticking = false
		for _, line in ipairs(OPX.Scheduler.Report()) do
			if tostring(line):find('slotbar', 1, true) or tostring(line):find('peek', 1, true) then
				ticking = true
			end
		end
		check('and no scheduler job was registered to take it down', not ticking)

		-- A REFRESH KEEPS THE COUNTDOWN. A bag that changes twice a second while
		-- the row is up would otherwise hold it there for as long as the player
		-- keeps picking things up.
		--
		-- `Pump` is the clock: one round is 100ms.
		control.Pump(10)
		Slotbar.Refresh()
		local again = drew()
		check('a refresh while the row is up redraws it',
			again ~= nil and again.payload ~= nil)
		check('and does NOT restart the hold',
			again ~= nil and tonumber(again.payload.holdMs) < inventory.Options.HOTBAR_PEEK_MS,
			again and tostring(again.payload.holdMs))

		-- Counted rather than compared against `#page.sent`: pumping the clock
		-- runs every other module's jobs too, and one of them drawing something
		-- unrelated would fail a check about this row.
		local function slotbarSends()
			local count = 0
			for index = 1, #page.sent do
				if page.sent[index].channel == 'opx:inventory:slotbar' then count = count + 1 end
			end
			return count
		end

		-- Once it has fallen, a refresh is silent rather than a fresh row.
		control.Pump(math.ceil(inventory.Options.HOTBAR_PEEK_MS / 100) + 1)
		check('the row is down once its hold has run out', Slotbar.IsUp() == false)
		local before = slotbarSends()
		Slotbar.Refresh()
		check('and refreshing a row that has gone draws nothing',
			slotbarSends() == before, ('%d vs %d'):format(slotbarSends(), before))

		-- WIRED, and not merely written. `Refresh` and `Hide` above were called
		-- by hand; these two check that the module actually subscribes to the
		-- local events `client/main.lua` raises, which is the difference between
		-- a feature and a pair of functions nobody calls.
		check('a fresh peek goes up again', Slotbar.Peek() == true)
		local mark = slotbarSends()
		control.Fire(inventory.Event.ON_CHANGED, { inventory = {}, changes = {} })
		check('a bag change under a live row redraws it', slotbarSends() > mark)

		control.Fire(inventory.Event.ON_OPENED)
		check('and opening the bag takes the row down rather than doubling it',
			Slotbar.IsUp() == false)
	end
end

section('the glyph vocabulary')
do
	local env, _, why = boot('client')
	check('the client boots', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local glyphs = OPX.Glyphs
		check('core declares one glyph set', type(glyphs) == 'table')

		local names = {}
		for name in pairs(glyphs or {}) do names[#names + 1] = name end
		table.sort(names)
		check('and it is not empty', #names > 0, #names)

		check('the toast draws from it, not from a copy',
			OPX.Toast.ICONS == glyphs)

		local target = OPX.Modules.Get('target')
		check('target validates against it, not against a copy',
			target ~= nil and target.Model ~= nil and target.Model.ICONS == glyphs)

		local menu = OPX.Modules.Get('menu')
		check('the menu validates against it, not against a copy',
			menu ~= nil and menu.ICONS == glyphs)

		-- The page's own keys, read out of the source. Two spaces of indent and
		-- a colon is how a key of `GLYPHS` is written and nothing else in that
		-- object is; the paths themselves are quoted and bracketed.
		local handle = io.open('ui/src/modules/target/glyphs.ts', 'r')
		local body = handle and handle:read('a') or ''
		if handle then handle:close() end
		check('the page glyph table is readable', #body > 0)

		local LF = string.char(10)
		local drawn = {}
		local object = body:match('export const GLYPHS[^\n]*\n(.-)\n}')
		-- The leading newline is put back because `object` begins one character
		-- past it, and without it the FIRST key -- `interact` -- has no separator
		-- in front of it and is missed. The check went red on that alone the
		-- first time it ran, which is the check working.
		for name in (LF .. (object or '')):gmatch('\n  ([%a][%w]*):') do
			drawn[name] = true
		end

		local drawnCount = 0
		for _ in pairs(drawn) do drawnCount = drawnCount + 1 end
		check('and it names some glyphs', drawnCount > 0, drawnCount)

		local missing = {}
		for index = 1, #names do
			local name = names[index]
			if not drawn[name] then missing[#missing + 1] = name end
		end
		check('every name Lua accepts has a path on the page',
			#missing == 0, table.concat(missing, ', '))

		local extra = {}
		for name in pairs(drawn) do
			if not glyphs[name] then extra[#extra + 1] = name end
		end
		table.sort(extra)
		check('and every path on the page has a name Lua accepts',
			#extra == 0, table.concat(extra, ', '))
	end
end

-- ── every item picture the catalogue names is actually shipped ──────────────
-- WRITTEN AFTER LOSING TWO OF THEM. A `git add -A` on a working tree that had
-- been through three branch switches staged a deletion nobody asked for: the
-- two icons went out of the tree while `data/weapons.lua` kept naming them, and
-- the suite passed, and the deploy went out. The page falls back to a monogram
-- on a broken image, so nothing crashed and nothing said anything either.
--
-- That is the hole. A missing picture is invisible from Lua, invisible from the
-- tests and invisible in the log; the only reporter is somebody looking at the
-- slot. So the catalogue's own claim is checked against the filesystem: every
-- `IMAGE` it names must exist in the SOURCE tree the build copies from.
section('every item picture the catalogue names is shipped')
do
	local env, _, why = boot('server')
	check('the server boots', why == nil, why)

	local inventory = why == nil and env.OPX.Modules.Get('inventory') or nil
	check('the inventory module is there', type(inventory) == 'table')

	if type(inventory) == 'table' then
		local Catalog = inventory.Catalog

		-- CHECKED IN THE SOURCE, NOT IN THE BUILD, and the first version of this
		-- test got that wrong and let the same file go missing twice.
		-- `ui/public/images` is what a picture IS; `web/images` is where the vite
		-- build copies it, and a file dropped into `web` alone survives exactly
		-- until the next `npm run build` rewrites that tree. Asserting on the
		-- output is asserting on a cache.
		local function shipped(file)
			local source = io.open('ui/public/images/' .. file, 'rb')
			if source == nil then return false end
			source:close()
			return true
		end

		local named, missing = 0, {}
		for _, name in ipairs(Catalog.Names()) do
			local item = Catalog.Get(name)
			-- Only what the catalogue explicitly NAMES. An item with no `IMAGE`
			-- and no `<name>.png` is a deliberate monogram, and there are enough
			-- of those that asserting on them would be asserting a wish.
			local file = type(item) == 'table' and item.image or nil
			if type(file) == 'string' and file ~= '' then
				named = named + 1
				if not shipped(file) then missing[#missing + 1] = name .. ' -> ' .. file end
			end
		end

		check('some items name a picture of their own', named > 0, tostring(named))
		check('and every one of those files is in ui/public/images', #missing == 0,
			table.concat(missing, ', '))
	end
end

-- ── the timed-action bar ────────────────────────────────────────────────────
-- THE RISK IS NOT THE BAR, IT IS THE LOCK. A bar that fails to draw is a
-- missing picture; a lock that is not released is a player who cannot move for
-- the rest of their session and has nothing on screen to explain it. So almost
-- every check here is about the release, and about the fact that there is
-- exactly one function that performs it.
section('the timed-action bar')
do
	local env, control, why = boot('client')
	check('the client boots with the progress module', why == nil, why)

	local progress = why == nil and env.OPX.Modules.Get('progress') or nil
	check('the module declared itself', type(progress) == 'table')

	local contract = why == nil and env.OPX.Api.Get('progress') or nil
	check('and published its contract', type(contract) == 'table'
		and type(contract.Start) == 'function')

	if type(contract) == 'table' then
		-- Every block and release the module asks the host for, in order.
		local claims = {}
		env.Open77.input = env.Open77.input or {}
		env.Open77.input.setActionBlocked = function(action, blocked)
			claims[#claims + 1] = { action = action, blocked = blocked }
			return true
		end

		local function held()
			local out = {}
			for index = 1, #claims do
				local claim = claims[index]
				if claim.blocked then out[claim.action] = true else out[claim.action] = nil end
			end
			return out
		end

		-- ── the refusals ──
		check('a bar needs an owner', contract.Start('', { label = 'x', durationMs = 1000 })
			.ok == false)
		check('and something to say',
			contract.Start('t', { durationMs = 1000 }).error == 'invalid_label')
		check('and a duration inside the configured bounds',
			contract.Start('t', { label = 'x', durationMs = 10 }).error == 'invalid_duration'
			and contract.Start('t', { label = 'x', durationMs = 999999 }).error
				== 'invalid_duration')

		-- ── up ──
		claims = {}
		local started = contract.Start('eat', { label = 'Eating', durationMs = 3000 })
		check('a well-formed bar goes up', started.ok == true, started.error)
		check('and the state says whose it is',
			contract.State().value.open == true and contract.State().value.owner == 'eat')

		-- ONLY THE PLATFORM'S OWN VOCABULARY. Five words are blockable on this
		-- build and anything else answers `unknown_action`; the first draft of
		-- `M.LOCKED` named eight, seven of which would have been refused, and the
		-- bar would have held nobody at all.
		local now = held()
		check('the player is held by Movement and Attack', now.Movement and now.Attack)
		local stray = {}
		for index = 1, #claims do
			local action = claims[index].action
			if action ~= 'Movement' and action ~= 'Attack' then stray[#stray + 1] = action end
		end
		check('and by nothing the platform would refuse', #stray == 0,
			table.concat(stray, ','))

		-- ── one at a time ──
		local second = contract.Start('other', { label = 'Other', durationMs = 1000 })
		check('a second bar is refused rather than stacked',
			second.ok == false and second.error == 'progress_busy', second.error)
		check('and the first is still up', contract.State().value.owner == 'eat')

		-- ── only its owner ──
		check('somebody else may not take it down',
			contract.Stop('other').error == 'not_owner')

		-- ── down, and the lock with it ──
		local done = nil
		env.AddEventHandler(progress.Event.ON_DONE, function(payload) done = payload end)

		claims = {}
		check('its own owner may', contract.Stop('eat').ok == true)
		check('the bar is down', contract.State().value.open == false)
		check('EVERY action it took is given back',
			held().Movement == nil and held().Attack == nil,
			tostring(#claims) .. ' claim(s)')
		check('and the outcome says it did not finish',
			done ~= nil and done.ending == progress.Ending.STOPPED and done.finished == false,
			done and tostring(done.ending))

		-- ── the clock ──
		-- THE ONLY ENDING THAT MEANS THE ACTION HAPPENED. Every other value is the
		-- action NOT happening, and a caller reading `ending ~= nil` as success is
		-- the bug the vocabulary exists to make hard to write.
		done = nil
		claims = {}
		contract.Start('eat', { label = 'Eating', durationMs = 300 })
		control.Pump(20)
		check('a bar whose clock runs out finishes',
			done ~= nil and done.ending == progress.Ending.FINISHED and done.finished == true,
			done and tostring(done.ending))
		check('and gives the lock back on that path too',
			held().Movement == nil and held().Attack == nil)

		-- ── the character leaving ──
		-- The path that would otherwise leave a lock on somebody who is no longer
		-- the person who took it.
		done = nil
		claims = {}
		contract.Start('eat', { label = 'Eating', durationMs = 30000 })
		check('a long bar is up', contract.State().value.open == true)
		control.Fire(env.OPX.Event(env.OPX.Channel.LOCAL, 'character', 'unloaded'))
		check('a character leaving takes the bar', contract.State().value.open == false)
		check('and the lock with it',
			held().Movement == nil and held().Attack == nil)
		check('reported as an interruption, not a finish',
			done ~= nil and done.ending == progress.Ending.INTERRUPTED
			and done.finished == false, done and tostring(done.ending))

		-- ── a host that cannot block ──
		-- The bar still draws. The player can walk out of it, which is worse than
		-- being held and far better than no bar at all.
		env.Open77.input.setActionBlocked = nil
		local blind = contract.Start('eat', { label = 'Eating', durationMs = 1000 })
		check('a build that cannot block still shows the bar', blind.ok == true, blind.error)
		check('and taking it down does not raise', pcall(contract.Stop, 'eat'))
	end
end
-- ── one staff action, one message ───────────────────────────────────────────
-- THREE NOTIFICATIONS FOR ONE GIVE, reported by the owner: giving themselves an
-- item as staff put the same sentence on screen twice -- once titled STAFF and
-- once bare -- and then told them a staff member had put something in their bag.
--
-- The two halves are separate faults and are held apart here.
--
-- SERVER: the inbound notice is the one the TARGET reads, and a staff member
-- acting on themselves is not a target. That comparison used to be written out
-- at every call site; it is `Server.Inform` now, so it is one thing to get right
-- and one thing to break.
--
-- CLIENT: `modules/menu` reroutes `SetStatus` to a toast, so writing the menu
-- status and raising the module's own toast are the same lane. `onAnswer` did
-- both. It now raises its own only when the status did not land -- the menu shut
-- -- or when the answer spans lines the single status line cannot hold, which is
-- the rule `onCommandResult` beside it already kept.
section('one staff action, one message')
do
	local env, control, why = boot('server')
	check('the server boots for the staff give', why == nil, why)

	local inventory = why == nil and env.OPX.Modules.Get('inventory') or nil
	local admin = why == nil and env.OPX.Modules.Get('admin') or nil

	if type(inventory) == 'table' and type(admin) == 'table' then
		local OPX = env.OPX

		-- The bag comes from memory rather than a column: what is under test is
		-- who gets told, not how a row is read.
		local nextId = 100
		inventory.Storage.Read = function(kind, owner, slots, maxWeight)
			nextId = nextId + 1
			return { id = nextId, kind = kind, owner = tostring(owner), slots = slots,
				maxWeight = maxWeight, items = {} }
		end
		inventory.Storage.Write = function() return true end

		local function playerOf(source, citizenId)
			return { PlayerData = { citizenId = citizenId, source = source } }
		end
		local people = { [1] = playerOf(1, 'CIT-0001'), [2] = playerOf(2, 'CIT-0002') }
		local character = {
			GetPlayer = function(source) return people[source] end,
			GetPlayerByCitizenId = function(citizenId)
				for _, person in pairs(people) do
					if person.PlayerData.citizenId == citizenId then return person end
				end
				return nil
			end,
			GetCharacter = function() return OPX.Result.Err('character.notFound') end,
		}
		inventory.Contracts.character = character
		admin.Contracts.character = character

		env.CreateThread(function() inventory.Players.Attach(1) end)
		env.CreateThread(function() inventory.Players.Attach(2) end)
		control.Pump(30)
		control.Admit(1, 'user-1')
		control.Admit(2, 'user-2')
		check('both staff and player hold a character',
			inventory.Players.Citizen(1) ~= nil and inventory.Players.Citizen(2) ~= nil)

		-- Everything either of them could be told, counted per player: the answer
		-- to the command rides this module's own event, the inbound notice rides
		-- the platform's notification package, and a fault in either half shows up
		-- as a number that is not one.
		local told = {}
		local function countFor(playerId)
			return (told[playerId] or {}).answers or 0, (told[playerId] or {}).notices or 0
		end
		local function bump(playerId, field)
			playerId = tonumber(playerId) or 0
			told[playerId] = told[playerId] or { answers = 0, notices = 0 }
			told[playerId][field] = told[playerId][field] + 1
		end

		local realTrigger = env.TriggerClientEvent
		env.TriggerClientEvent = function(name, source, ...)
			if name == admin.Event.ANSWER then bump(source, 'answers') end
			return realTrigger(name, source, ...)
		end
		local realNotify = OPX.Notify
		OPX.Notify = function(source, message, kind, durationMs)
			bump(source, 'notices')
			return realNotify(source, message, kind, durationMs)
		end

		local give = control.commands['opx.admin.inventory.give']
		check('the staff give command is registered', type(give) == 'table')

		local function run(source, target)
			told = {}
			local ran, failure = pcall(give.run, source,
				{ target, 'bandage', '1' },
				('opx.admin.inventory.give %s bandage 1'):format(tostring(target)))
			control.Pump(30)
			return ran, failure
		end

		if type(give) == 'table' then
			-- ── to somebody else ──
			local ran, failure = run(1, '2')
			check('a staff give to another player runs', ran, failure)
			local staffAnswers, staffNotices = countFor(1)
			local heldAnswers, heldNotices = countFor(2)
			check('the giver is answered exactly once', staffAnswers == 1,
				('%d answers'):format(staffAnswers))
			check('and is not also told somebody gave them something',
				staffNotices == 0, ('%d notices'):format(staffNotices))
			check('the player is told exactly once', heldNotices == 1,
				('%d notices'):format(heldNotices))
			check('and is not sent the command answer as well', heldAnswers == 0,
				('%d answers'):format(heldAnswers))

			-- ── to themselves ──
			-- One message in total. The `me` spelling, their own player id and
			-- their own citizen id are three doors into the same place, and the
			-- guard has to hold on all three.
			for _, spelling in ipairs({ 'me', '1', 'CIT-0001' }) do
				local selfRan, selfFailure = run(1, spelling)
				check(('a staff give to self by %q runs'):format(spelling), selfRan, selfFailure)
				local answers, notices = countFor(1)
				check(('and produces exactly one message in total, not two'):format(spelling),
					answers + notices == 1, ('%d answers, %d notices'):format(answers, notices))
				check('the one message being the command answer', answers == 1,
					('%d answers'):format(answers))
			end

			-- A SOURCE THAT ARRIVES AS A STRING is how a console and some host
			-- paths hand one over -- see the section of that name above, and the
			-- two functions in `core/server/answer.lua` it was written for.
			local stringRan, stringFailure = run('1', 'me')
			check('a staff give whose source arrived as a string runs', stringRan, stringFailure)
			local answers, notices = countFor(1)
			check('and still says one thing, not two', answers + notices == 1,
				('%d answers, %d notices'):format(answers, notices))
		end

		-- THE SEAM ITSELF, asked directly, because no command can reach it with a
		-- string today: `Server.Command` normalises the source before a handler
		-- sees one, so the whole-command check above cannot tell a comparison that
		-- normalises from one that does not. `'1'` is not `1` in Lua, and the day a
		-- caller arrives that is not a command -- a net handler, the console -- an
		-- un-normalised comparison sends the inbound notice to the very player it
		-- exists to spare.
		told = {}
		check('an inbound notice is dropped when the target IS the actor',
			admin.Server.Inform(1, 1, 'admin.toast.healed') == false)
		check('and when the actor arrived as a string spelling of the same player',
			admin.Server.Inform('1', 1, 'admin.toast.healed') == false)
		check('and when the target did, too',
			admin.Server.Inform(1, '1', 'admin.toast.healed') == false)
		check('nothing was sent on any of the three', select(2, countFor(1)) == 0,
			('%d notices'):format(select(2, countFor(1))))
		check('while a real target is told', admin.Server.Inform(1, 2, 'admin.toast.healed') == true)
		check('and nobody at all is not', admin.Server.Inform(1, nil, 'admin.toast.healed') == false)

		env.TriggerClientEvent = realTrigger
		OPX.Notify = realNotify
	end
end

-- The client half of the same action: how many toasts one answer comes to.
section('one staff answer, one toast')
do
	local env, control, why = boot('client')
	check('the client boots for the staff answer', why == nil, why)

	if why == nil then
		local admin = env.OPX.Modules.Get('admin')
		local overlay = control.pages[1]
		env.TriggerServerEvent = function() return true end

		control.netEvents[admin.Event.OPEN]({ access = {}, aclKnown = true, inventory = true })
		control.Pump(10)

		--- Runs the give the way the menu does and answers the toasts it drew.
		local function toastsFor(menuOpen, message)
			if menuOpen then admin.Menu.OpenAt('self') else admin.Menu.Close() end
			control.Pump(10)
			local mark = #overlay.sent
			admin.Client.Execute({ 'opx.admin.inventory.give', 'me', 'bandage', '1' })
			control.Pump(2)
			control.netEvents[admin.Event.ANSWER]('opx.admin.inventory.give me bandage 1', true,
				message, 'success')
			control.Pump(6)
			local drawn = {}
			for index = mark + 1, #overlay.sent do
				local sent = overlay.sent[index]
				if sent.channel == 'opx:notify:show' then drawn[#drawn + 1] = sent.payload end
			end
			return drawn
		end

		local ANSWER_LINE = 'Put 1x Bandage in the bag of me [1].'

		local open = toastsFor(true, ANSWER_LINE)
		check('a staff give answered with the menu open raises ONE toast',
			#open == 1, ('%d toasts'):format(#open))
		check('and it carries the whole sentence',
			open[1] ~= nil and open[1].message == ANSWER_LINE, open[1] and open[1].message)

		-- The keybinds and the map pick both run commands with the menu shut, and
		-- the status line only queues for a screen that is not there: dropping the
		-- module's toast on this path would lose the answer altogether.
		local shut = toastsFor(false, ANSWER_LINE)
		check('with the menu shut the module still raises its own',
			#shut == 1, ('%d toasts'):format(#shut))
		check('titled, because nothing else says who is talking',
			shut[1] ~= nil and shut[1].title == env.OPX.Locale.Text('admin.toast.title'),
			shut[1] and tostring(shut[1].title))

		-- The status lane is one truncated line. An answer that spans several is
		-- unreadable there, which is why `onCommandResult` has always excepted it.
		local long = toastsFor(true, 'line one\nline two')
		local full = false
		for _, payload in ipairs(long) do
			if payload.message == 'line one\nline two' then full = true end
		end
		check('a multi-line answer is still raised in full', full,
			('%d toasts'):format(#long))
	end
end

section('elevators: an adopted cabin is locked before anyone can ride it')
do
	-- The job gate rests entirely on the host's `locked` flag. Open77 intercepts a
	-- press of the vanilla in-cabin floor button and converts it into a player
	-- request BEFORE the game's own local movement runs, and `locked` is the only
	-- bit that refuses one. So a cabin this module has adopted and not locked is a
	-- cabin anybody rides to any floor by pressing the button Cyberpunk already
	-- draws, with the panel's greyed rows and the server's `Access.Evaluate` never
	-- consulted. That is what these checks are about; the panel is not.
	local WHERE = { x = -1521.40, y = 892.75, z = 42.10 }
	local LIFT = '0x00000000000000ab'

	local env, control, why = boot('server', nil, function(sandbox)
		-- The reporting player has to stand at the shaft, in the elevator's own
		-- bucket, or `onSighted` drops the report before adoption is reached. The
		-- stub's fixed origin is nowhere near any configured elevator.
		sandbox.Open77.players.position = function()
			return { x = WHERE.x, y = WHERE.y, z = WHERE.z, bucket = 0 }
		end
	end)
	check('the server boots for the elevator tests', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local M = OPX.Modules.Get('elevators')
		local lifts = control.lifts
		local SIGHTED = M.Event.SIGHTED
		local REQUEST = M.Event.REQUEST

		--- One client reporting a streamed native lift, as the host delivers it.
		local function sight(player, entity)
			env.source = player
			control.netEvents[SIGHTED](entity, WHERE.x, WHERE.y, WHERE.z, 12, 0)
			env.source = nil
		end

		check('the sighting door is on the net channel',
			type(control.netEvents[SIGHTED]) == 'function')

		sight(4, LIFT)

		check('a lift reported at a configured shaft is adopted', #lifts.adopts == 1,
			#lifts.adopts)

		-- THE MASK GOES IN WITH THE ADOPTION. Asserted on the adopt call itself and
		-- not on the lift afterwards: a `setFlags` a moment later leaves the same
		-- end state and still leaves the window this closes.
		local asked = lifts.adopts[1]
		check('the adoption itself asks for the locked bit',
			asked ~= nil and type(asked.flags) == 'number' and (asked.flags & 2) ~= 0,
			asked and tostring(asked.flags))
		check('and keeps the cabin powered, so the server can still move it',
			asked ~= nil and type(asked.flags) == 'number' and (asked.flags & 1) ~= 0,
			asked and tostring(asked.flags))
		check('and does not invite the request it would then refuse',
			asked ~= nil and type(asked.flags) == 'number' and (asked.flags & 4) == 0,
			asked and tostring(asked.flags))

		local adopted = nil
		for _, lift in pairs(lifts.byId) do adopted = lift end
		check('the lift the host holds is locked', adopted ~= nil and (adopted.flags & 2) ~= 0,
			adopted and tostring(adopted.flags))

		--- Every client event of one name, in order. `clientEvents` is one flat
		--- list of every send, so a test that wants one channel filters it.
		local function sentTo(recorder, name)
			local out = {}
			for index = 1, #recorder do
				if recorder[index].name == name then out[#out + 1] = recorder[index] end
			end
			return out
		end

		-- The client is only handed an id once the cabin is gated; a BOUND carrying
		-- an id for an unlocked lift is the panel opening over a free ride.
		local bound = sentTo(control.clientEvents, M.Event.BOUND)
		check('and only then is the client told its id', #bound == 1, #bound)

		-- ── a host that drops the flags field ────────────────────────────────
		-- `flags` is an argument to `adopt`, and an older build ignores a field it
		-- does not know rather than refusing the call. This is why the mask is read
		-- back afterwards instead of assumed from the request, and why a lock that
		-- will not take is now a rollback where it used to be a warning: an adopted
		-- cabin nobody locked is a shaft wearing this module's job-gated panel that
		-- rides anywhere off the vanilla button.
		local env2, control2, why2 = boot('server', nil, function(sandbox)
			sandbox.Open77.players.position = function()
				return { x = WHERE.x, y = WHERE.y, z = WHERE.z, bucket = 0 }
			end
		end)
		check('the server boots again for the dropped-flags case', why2 == nil, why2)

		if why2 == nil then
			local M2 = env2.OPX.Modules.Get('elevators')
			control2.lifts.ignoreAdoptFlags = true
			control2.lifts.refuseFlags = true
			env2.source = 5
			control2.netEvents[M2.Event.SIGHTED](LIFT, WHERE.x, WHERE.y, WHERE.z, 12, 0)
			env2.source = nil

			check('the adoption was attempted', #control2.lifts.adopts == 1,
				#control2.lifts.adopts)
			check('a cabin that came up unlocked is released, not kept',
				next(control2.lifts.byId) == nil)
			check('the host was actually asked to take it back',
				#control2.lifts.removes == 1, #control2.lifts.removes)
			check('and no client was handed an id for it',
				#sentTo(control2.clientEvents, M2.Event.BOUND) == 0)

			-- The proof that the release is real and not only a log line: a floor
			-- request for that shaft has nothing left to move.
			env2.source = 5
			control2.netEvents[M2.Event.REQUEST]('arasaka_tower', 0)
			env2.source = nil
			local answers = sentTo(control2.clientEvents, M2.Event.ANSWER)
			local last = answers[#answers]
			check('so a floor request for it is refused not_adopted',
				last ~= nil and last[4] == 'not_adopted', last and tostring(last[4]))
		end

		-- ── a cabin another resource already owns ────────────────────────────
		-- `all(bucket)` reports every adopted lift in the bucket and not only this
		-- module's, so the cabin met on the re-claim path may belong to
		-- `open77_elevators` -- the conflict the module header names -- and
		-- `setFlags` on another owner's lift is refused. It must not be bound, and
		-- it must NOT be removed either: it is not this module's to take away.
		local env4, control4, why4 = boot('server', nil, function(sandbox)
			sandbox.Open77.players.position = function()
				return { x = WHERE.x, y = WHERE.y, z = WHERE.z, bucket = 0 }
			end
		end)
		check('the server boots for the foreign-owner case', why4 == nil, why4)

		if why4 == nil then
			local M4 = env4.OPX.Modules.Get('elevators')
			-- The other owner's cabin, as `all(0)` would report it: powered and
			-- accepting requests, and not locked.
			control4.lifts.byId[77] = { id = 77, engineEntity = LIFT, bucket = 0,
				floorCount = 12, activeFloor = 0, phase = 'idle',
				x = WHERE.x, y = WHERE.y, z = WHERE.z, flags = 5 }
			control4.lifts.refuseFlags = true

			env4.source = 7
			control4.netEvents[M4.Event.SIGHTED](LIFT, WHERE.x, WHERE.y, WHERE.z, 12, 0)
			env4.source = nil

			check('a foreign cabin is not re-adopted', #control4.lifts.adopts == 0,
				#control4.lifts.adopts)
			check('nor bound to a client', #sentTo(control4.clientEvents, M4.Event.BOUND) == 0)
			check('and it is left standing, not removed', #control4.lifts.removes == 0,
				#control4.lifts.removes)
			check('the other owner still has it',
				control4.lifts.byId[77] ~= nil and control4.lifts.byId[77].flags == 5)
		end

		-- ── a build with no flag constants ───────────────────────────────────
		-- `Open77.elevators.flags` is documented by the op77.76 guide but a constant
		-- table is not a native, so the devkit catalogue cannot confirm it: it is
		-- unverified rather than known absent. Indexing it blind used to raise
		-- inside this very handler, which took the handler down AFTER the adopt had
		-- already succeeded -- the one outcome worse than not adopting at all.
		local env3, control3, why3 = boot('server', nil, function(sandbox)
			sandbox.Open77.players.position = function()
				return { x = WHERE.x, y = WHERE.y, z = WHERE.z, bucket = 0 }
			end
			sandbox.Open77.elevators.flags = nil
		end)
		check('the server boots for the missing-constants case', why3 == nil, why3)

		if why3 == nil then
			local M3 = env3.OPX.Modules.Get('elevators')
			env3.source = 6
			local survived = pcall(control3.netEvents[M3.Event.SIGHTED],
				LIFT, WHERE.x, WHERE.y, WHERE.z, 12, 0)
			env3.source = nil
			check('a host with no flag constants does not take the handler down', survived)
			check('and nothing is adopted that could not have been gated',
				#control3.lifts.adopts == 0, #control3.lifts.adopts)
		end

		-- ── the gate itself ──────────────────────────────────────────────────
		-- `Access.Evaluate` is the one decision both halves make, and the server
		-- re-derives it from its own roster before it moves a cabin. Checked
		-- directly: it is a pure function of a floor and a job snapshot.
		local Access = M.Access
		local now = 1000000
		local function snap(name, level, onDuty, jobs)
			return { job = name and { name = name, grade = { level = level },
				onDuty = onDuty } or nil, jobs = jobs, atMs = now }
		end
		local public = { INDEX = 0, LABEL = 'Plaza' }
		local gated = { INDEX = 8, LABEL = 'Counterintel', JOBS = { arasaka = 2 } }
		local duty = { INDEX = 11, LABEL = 'Executive', JOBS = { arasaka = 3 }, ON_DUTY = true }

		check('a public floor is open to nobody at all',
			(Access.Evaluate(public, nil, now)) == true)
		local ok, refusal = Access.Evaluate(gated, nil, now)
		check('a gated floor is shut to a character that never read', ok == false and
			refusal == 'no_character', tostring(refusal))
		ok, refusal = Access.Evaluate(gated, snap('arasaka', 1), now)
		check('and to the right job at too low a grade', ok == false and
			refusal == 'grade_too_low', tostring(refusal))
		ok, refusal = Access.Evaluate(gated, snap('militech', 9), now)
		check('and to the wrong job at any grade', ok == false and
			refusal == 'job_required', tostring(refusal))
		check('and open at the grade it asks for',
			(Access.Evaluate(gated, snap('arasaka', 2), now)) == true)
		ok, refusal = Access.Evaluate(duty, snap('arasaka', 3, false), now)
		check('an ON_DUTY floor is shut to the same rank off duty', ok == false and
			refusal == 'off_duty', tostring(refusal))
		check('and open on duty',
			(Access.Evaluate(duty, snap('arasaka', 3, true), now)) == true)

		-- A SNAPSHOT THAT AGED OUT CLOSES THE GATED FLOOR AND NOT THE LOBBY. A
		-- broken character read must not lock someone out of a public floor.
		local stale = now + Access.JOB_MAX_AGE_MS + 1
		ok, refusal = Access.Evaluate(gated, snap('arasaka', 3), stale)
		check('a stale job snapshot shuts a gated floor', ok == false and
			refusal == 'job_stale', tostring(refusal))
		check('and leaves a public floor open',
			(Access.Evaluate(public, snap('arasaka', 3), stale)) == true)

		-- MEMBERSHIP is `primary` in the shipped config: a job merely held, with no
		-- clock behind it, is not the job being worked.
		ok = Access.Evaluate(gated, snap('militech', 9, false, { arasaka = 5 }), now)
		check('a membership is not the worked job under MEMBERSHIP = primary',
			ok == false)
	end
end

-- ── eddies as an item ───────────────────────────────────────────────────────
-- ONE PROPERTY, ASSERTED OVER EVERY PATH: total money before == total money
-- after. A player's total is their EDDIES balance plus every note they are
-- carrying, and no operation -- a withdraw, a deposit, a hand-over, or any of
-- those REFUSED halfway -- may change the sum across everybody involved.
--
-- The reason it is stated that way rather than as "the withdraw works" is that
-- the failure this bridge exists to avoid is not a broken withdraw. It is a
-- withdraw that works and a mint that does not, or a credit that lands and a
-- removal that does not: both halves individually correct, the pair minting or
-- destroying money. So every check below reads the TOTAL, and the interesting
-- ones are the failures.
section('eddies: the balance and the notes always add up to the same number')
do
	local env, control, why = boot('server')
	check('the server boots', why == nil, why)

	local OPX = why == nil and env.OPX or nil
	local inventory = OPX and OPX.Modules.Get('inventory') or nil
	local character = OPX and OPX.Modules.Get('character') or nil
	check('the inventory and character modules are both there',
		type(inventory) == 'table' and type(character) == 'table')

	if type(inventory) == 'table' and type(character) == 'table' then
		local Currency = inventory.Currency
		local Containers = inventory.Containers
		local Players = inventory.Players
		local Actions = inventory.Actions
		local Catalog = inventory.Catalog
		local Options = inventory.Options
		local KIND = inventory.KIND

		-- The gate answers false and the life reader answers a STRING in the bare
		-- harness, and `Players.MayAct` reads both. Without these two every
		-- conversion below would refuse before it reached any money, and the
		-- section would pass by never doing anything.
		env.Open77.ready.isReady = function() return true end
		env.Open77.players.getLifeState = function() return {} end

		local wired, item, moneyType = Currency.Wired()
		check('the money-to-item bridge wired itself at start', wired == true)
		check('and it names the eddies item and the EDDIES balance',
			item == 'eddies' and moneyType == 'EDDIES',
			('%s / %s'):format(tostring(item), tostring(moneyType)))

		local eddies = Catalog.Get('eddies')
		check('the item is in the catalogue and stacks', eddies ~= nil
			and eddies.stackable == true)

		-- WEIGHTLESS ON PURPOSE. Weight is the one limit that can refuse HALF a
		-- move, and half a move of money is the bug this whole file is about.
		check('and it weighs nothing, so no transfer can be refused part-way',
			eddies ~= nil and eddies.weight == 0, eddies and tostring(eddies.weight))

		-- A loaded character in the shape the character contract reads, with a
		-- MEMORY-ONLY bag registered under the same identity its own loader would
		-- use -- so `Players.Bag` finds it in the cache and the suite needs no
		-- database to move real stacks through the real code.
		local function load(id, citizenId, balance)
			local userId = 'account-' .. tostring(id)
			character.Players[id] = {
				PlayerData = { citizenId = citizenId, source = id, userId = userId,
					money = { EDDIES = balance, BANK = 0 } },
				Functions = { UpdatePlayerData = function() end },
			}
			character.Registry.byCitizenId[citizenId] = id
			character.Registry.byUserId[userId] = id
			local bag = Containers.Transient(KIND.CHARACTER, citizenId,
				Options.BAG_SLOTS, Options.BAG_MAX_WEIGHT)
			Players.Attach(id)
			return bag
		end

		local ALICE, BOB = 401, 402
		local aliceBag = load(ALICE, 'citizen-eddies-a', 1000)
		local bobBag = load(BOB, 'citizen-eddies-b', 0)
		check('both bags are held for their characters',
			Players.Bag(ALICE) == aliceBag and Players.Bag(BOB) == bobBag)

		--- What one player is worth: the balance plus every note they carry.
		local function worth(source, bag)
			local balance = character.GetMoney(source, 'EDDIES')
			return (type(balance) == 'number' and balance or 0) + Currency.CountIn(bag)
		end
		local function total()
			return worth(ALICE, aliceBag) + worth(BOB, bobBag)
		end

		local START = 1000
		check('the economy starts at a known size', total() == START, tostring(total()))

		-- ── the mint ──────────────────────────────────────────────────────────
		local drew, refusal = Currency.Withdraw(ALICE, 300)
		check('a withdraw inside the balance is accepted', drew == true, tostring(refusal))
		check('and it moved the money out of the balance',
			character.GetMoney(ALICE, 'EDDIES') == 700,
			tostring(character.GetMoney(ALICE, 'EDDIES')))
		check('and into notes in the bag', Currency.CountIn(aliceBag) == 300,
			tostring(Currency.CountIn(aliceBag)))
		check('and the total is what it was', total() == START, tostring(total()))

		-- ── the refusals, which must cost nothing ─────────────────────────────
		local over
		over, refusal = Currency.Withdraw(ALICE, 5000)
		check('a withdraw past the balance is refused', over == false)
		-- Refused by the courtesy read of the balance, BEFORE anything is
		-- charged -- the same shape the dealership uses. `RemoveMoney` would
		-- refuse it too; this one just means the common mistake never reaches a
		-- mutator at all.
		check('and refused before a single unit of it was charged',
			refusal == 'not_enough_money', tostring(refusal))
		check('and the total is unchanged by the refusal', total() == START, tostring(total()))

		check('a withdraw of nothing is refused',
			(Currency.Withdraw(ALICE, 0)) == false)
		check('and so is a fractional one, which would round into free money',
			(Currency.Withdraw(ALICE, 1.5)) == false)
		check('and so is a NaN, which passes every comparison it is put through',
			(Currency.Withdraw(ALICE, 0 / 0)) == false)
		check('and none of them moved anything', total() == START
			and character.GetMoney(ALICE, 'EDDIES') == 700, tostring(total()))

		-- ── handing it over, which is the whole point ─────────────────────────
		local slot = nil
		for index, stack in pairs(aliceBag.items) do
			if stack.name == 'eddies' then slot = index end
		end
		check('the notes are in a slot that can be handed over', slot ~= nil)

		local gave, giveWhy = Actions.Give(ALICE, BOB, slot, 120)
		check('a stack of eddies hands over like any other item', gave == true,
			tostring(giveWhy))
		check('the giver is down the notes', Currency.CountIn(aliceBag) == 180,
			tostring(Currency.CountIn(aliceBag)))
		check('the taker has them', Currency.CountIn(bobBag) == 120,
			tostring(Currency.CountIn(bobBag)))

		-- THE CHECK THE OWNER ASKED FOR, and the reason the item exists: handing
		-- somebody the item has handed them the money, and no balance moved to do
		-- it. Neither player can spend a note until they bank it, so nothing here
		-- is spendable twice.
		check('handing over eddies moved the money without touching a balance',
			character.GetMoney(ALICE, 'EDDIES') == 700
				and character.GetMoney(BOB, 'EDDIES') == 0)
		check('and the economy is still the same size', total() == START, tostring(total()))

		-- ── the burn ──────────────────────────────────────────────────────────
		local bobSlot = nil
		for index, stack in pairs(bobBag.items) do
			if stack.name == 'eddies' then bobSlot = index end
		end
		local banked, bankWhy = Currency.Deposit(BOB, bobSlot, nil)
		check('using the stack banks it', banked == true, tostring(bankWhy))
		check('the notes are gone', Currency.CountIn(bobBag) == 0,
			tostring(Currency.CountIn(bobBag)))
		check('and the balance carries them instead',
			character.GetMoney(BOB, 'EDDIES') == 120,
			tostring(character.GetMoney(BOB, 'EDDIES')))
		check('and the economy is STILL the same size', total() == START, tostring(total()))

		-- A deposit of somebody else's slot number, of an empty slot, or of a slot
		-- holding something that is not money: each is money credited for nothing
		-- if it is not refused.
		check('depositing an empty slot is refused',
			(Currency.Deposit(BOB, 39, nil)) == false)
		Containers.Add(bobBag, 'bandage', 2)
		local bandageSlot = nil
		for index, stack in pairs(bobBag.items) do
			if stack.name == 'bandage' then bandageSlot = index end
		end
		local notMoney, notMoneyWhy = Currency.Deposit(BOB, bandageSlot, nil)
		check('and depositing a slot that is not money is refused, not credited',
			notMoney == false and notMoneyWhy == 'empty_slot', tostring(notMoneyWhy))
		check('and the economy is untouched by either', total() == START, tostring(total()))

		-- ── the ground ────────────────────────────────────────────────────────
		-- A pile is memory-only: swept after DROPS.LIFETIME_MINUTES and gone at the
		-- next restart. Dropping a note is therefore not losing an item, it is
		-- deleting a balance, so the server refuses it whatever the screen offers.
		local pile, dropWhy = Actions.Drop(ALICE, slot, 10, 0.0)
		check('eddies cannot be left on the ground', pile == nil and dropWhy == 'no_drop',
			tostring(dropWhy))
		check('and the refused drop left the notes where they were',
			Currency.CountIn(aliceBag) == 180 and total() == START, tostring(total()))

		-- ...and the refusal is about THIS item, not about drops being off.
		Containers.Add(aliceBag, 'bandage', 1)
		local aliceBandage = nil
		for index, stack in pairs(aliceBag.items) do
			if stack.name == 'bandage' then aliceBandage = index end
		end
		check('while an ordinary item still drops',
			(Actions.Drop(ALICE, aliceBandage, 1, 0.0)) ~= nil)

		-- ── the half that fails, which is the whole reason for the ordering ───
		-- THE MINT REFUSES AFTER THE DEBIT HAS LANDED. This is the case the
		-- refund exists for, and the only way to reach it is to make the second
		-- half fail on purpose: every ordinary cause is already refused by the
		-- `CanCarry` read that runs before the debit.
		local realAdd = Containers.Add
		Containers.Add = function() return false, 'no_room' end
		local minted, mintWhy = Currency.Withdraw(ALICE, 250)
		Containers.Add = realAdd
		check('a withdraw whose mint fails is refused', minted == false, tostring(mintWhy))
		check('and the debit was given back rather than pocketed',
			character.GetMoney(ALICE, 'EDDIES') == 700,
			tostring(character.GetMoney(ALICE, 'EDDIES')))
		check('so the economy did not shrink', total() == START, tostring(total()))

		-- ...AND IT THREW rather than answering. A raise out of the mint would
		-- unwind past the refund and out of the caller, leaving a player charged
		-- for notes they never got.
		Containers.Add = function() error('the mint blew up') end
		local threw = Currency.Withdraw(ALICE, 250)
		Containers.Add = realAdd
		check('a withdraw whose mint RAISES is refused rather than taken', threw == false)
		check('and that debit came back too',
			character.GetMoney(ALICE, 'EDDIES') == 700 and total() == START,
			tostring(total()))

		-- THE CREDIT REFUSES AFTER THE NOTES ARE GONE, which is the mirror of it.
		-- A `money:beforeAdd` veto is how a real module refuses a credit, so it is
		-- what the failure is made of here rather than a patched function.
		local veto = OPX.Hooks.Register('money:beforeAdd', function() return false end)
		local aliceSlot = nil
		for index, stack in pairs(aliceBag.items) do
			if stack.name == 'eddies' then aliceSlot = index end
		end
		local vetoed, vetoWhy = Currency.Deposit(ALICE, aliceSlot, 50)
		OPX.Hooks.Remove(veto)
		check('a deposit whose credit is vetoed is refused', vetoed == false,
			tostring(vetoWhy))
		check('and the notes were put back rather than burnt',
			Currency.CountIn(aliceBag) == 180, tostring(Currency.CountIn(aliceBag)))
		check('so the economy did not shrink there either', total() == START,
			tostring(total()))

		-- ── the door the client actually knocks on ────────────────────────────
		-- `Actions.Use` is what the Use row calls, and the whole reason the
		-- deposit does its own removal is what happens on this path: the catalogue
		-- consume runs AFTER the handler, so a handler that answered a consume
		-- would have credited the balance before the units were gone.
		local usedSlot = nil
		for index, stack in pairs(aliceBag.items) do
			if stack.name == 'eddies' then usedSlot = index end
		end
		-- On a thread, because `Actions.Use` runs a use handler on a thread of its
		-- own and waits on its deadline -- it yields, and the platform only ever
		-- reaches it from a coroutine.
		local used, useWhy
		env.CreateThread(function() used, useWhy = Actions.Use(ALICE, usedSlot) end)
		check('the use settles', settle(control, function() return used ~= nil end, 60))
		check('using the stack from the bag deposits it', used == true, tostring(useWhy))
		check('the notes are gone and the balance has them',
			Currency.CountIn(aliceBag) == 0
				and character.GetMoney(ALICE, 'EDDIES') == 880,
			('%d notes / %s balance'):format(Currency.CountIn(aliceBag),
				tostring(character.GetMoney(ALICE, 'EDDIES'))))
		check('and after every one of these, the economy is the size it started',
			total() == START, tostring(total()))
	end
end


-- ── teleports ────────────────────────────────────────────────────────────────
-- A TELEPORT IS A DOOR THAT DOES NOT CHECK ITSELF, so every check below is
-- about the thing that does. The client sends a key and a leg; the server looks
-- the destination up in its own catalogue, re-derives the job gate, re-reads the
-- position and only then asks the platform to move a body. What is asserted is
-- therefore always two things at once: that the wire answer said no, AND that
-- `control.trips.calls` is still empty -- a refusal that had already moved the
-- player is not a refusal.
section('teleports: the destination and the gate are the server\'s, and pure')
do
	-- WHERE THE PLAYER IS STANDING, movable between requests. The stub's fixed
	-- origin is nowhere near any of the points below, so a test that could not
	-- move the body could only ever exercise `too_far`.
	local WHERE = { x = 100.0, y = 200.0, z = 10.0, bucket = 0 }

	local env, control, why = boot('server', nil, function(sandbox)
		sandbox.Open77.players.position = function()
			return { x = WHERE.x, y = WHERE.y, z = WHERE.z, bucket = WHERE.bucket }
		end
	end)
	check('the server boots with the teleports module', why == nil, why)

	if why == nil then
		local OPX = env.OPX
		local M = OPX.Modules.Get('teleports')
		local Access = M.Access
		local contract = OPX.Api.Get('teleports')

		check('the teleports module is running', OPX.Modules.IsRunning('teleports'),
			OPX.Modules.Record('teleports').Reason)
		check('and publishes its half of the contract',
			contract ~= nil and type(contract.IsAllowed) == 'function'
				and type(contract.Entrances) == 'function'
				and type(contract.State) == 'function')
		check('the shipped config reports no problems', #Access.Problems() == 0,
			table.concat(Access.Problems(), ' | '))
		check('and ships no teleport switched on, because every coordinate in it ' ..
			'is an example', OPX.Table.Count(Access.POINTS) == 0,
			OPX.Table.Count(Access.POINTS))

		-- ── the catalogue the rest of this section runs against ──────────────
		-- INSTALLED INTO THE LIVE TABLE, and that is not a trick: `M.Init` binds
		-- the server half's `points` to `Access.POINTS` itself, so writing into it
		-- is exactly what loading a config with these rows would have done. It has
		-- to be done here because the shipped config deliberately enables nothing
		-- -- the check directly above is the one that keeps it that way -- and a
		-- suite that needed a real point would otherwise be an argument for
		-- shipping a fake one.
		local FIXTURES = {
			-- A two-way with no gate: the plain case the owner asked for.
			roof = { LABEL = 'ROOF', BUCKET = 0, RETURN = true,
				ENTRY = { LABEL = 'Street', X = 100.0, Y = 200.0, Z = 10.0, HEADING = 0.0 },
				EXIT = { LABEL = 'Rooftop', X = 100.0, Y = 205.0, Z = 40.0, HEADING = 180.0 } },
			-- A one-way: you drop through it and walk out.
			hatch = { LABEL = 'HATCH', BUCKET = 0,
				ENTRY = { LABEL = 'Hatch', X = 300.0, Y = 400.0, Z = 5.0 },
				EXIT = { LABEL = 'Sublevel', X = 300.0, Y = 400.0, Z = -8.0 } },
			-- A locked two-way, with the operator's own words on the refusal.
			vault = { LABEL = 'VAULT', BUCKET = 0, RETURN = true,
				JOBS = { arasaka = 2 }, ON_DUTY = true, REASON = 'Arasaka Counterintel',
				ENTRY = { LABEL = 'Lobby', X = 500.0, Y = 600.0, Z = 2.0 },
				EXIT = { LABEL = 'Vault', X = 505.0, Y = 600.0, Z = 2.0 } },
			-- Switched off by the operator.
			shelved = { enabled = false, LABEL = 'SHELVED', BUCKET = 0,
				ENTRY = { X = 700.0, Y = 800.0, Z = 1.0 },
				EXIT = { X = 701.0, Y = 800.0, Z = 1.0 } },
			-- In another routing bucket entirely.
			elsewhere = { LABEL = 'ELSEWHERE', BUCKET = 7,
				ENTRY = { X = 100.0, Y = 200.0, Z = 10.0 },
				EXIT = { X = 900.0, Y = 900.0, Z = 9.0 } },
		}
		local installed = Access.Coerce(FIXTURES, nil)
		for key, point in pairs(installed) do Access.POINTS[key] = point end

		check('a point switched off is dropped from the catalogue, not merely hidden',
			Access.POINTS.shelved == nil)
		check('and the four live ones are installed', OPX.Table.Count(Access.POINTS) == 4,
			OPX.Table.Count(Access.POINTS))

		-- ── destination validation, as a pure function ───────────────────────
		-- `Access.Lookup` is the whole of "may this client name this place". It
		-- takes the two strings a client is allowed to send and nothing else, and
		-- every way of getting it wrong ends at nil.
		local points = Access.POINTS
		check('a configured teleport resolves on its outbound leg',
			Access.Lookup(points, 'roof', 'out') ~= nil)
		check('a key nobody configured resolves to nothing',
			Access.Lookup(points, 'no_such_key', 'out') == nil)
		check('and so does a point the operator switched off',
			Access.Lookup(points, 'shelved', 'out') == nil)
		check('a leg that is not one of the two resolves to nothing',
			Access.Lookup(points, 'roof', 'sideways') == nil)
		check('and a leg that is not a string at all',
			Access.Lookup(points, 'roof', { leg = 'out' }) == nil)
		check('and a key that is not a string at all',
			Access.Lookup(points, { key = 'roof' }, 'out') == nil)

		-- ONE-WAY MEANS ONE WAY. Without this the `RETURN` flag is decoration: a
		-- client naming `back` on the hatch would be lifted out of the sublevel
		-- the operator meant them to walk out of.
		check('the back leg of a one-way teleport does not exist',
			Access.Lookup(points, 'hatch', 'back') == nil)
		check('and the back leg of a two-way does, reversed',
			(function()
				local back = Access.Lookup(points, 'roof', 'back')
				return back ~= nil and back.x == 100.0 and back.z == 40.0
					and back.to.x == 100.0 and back.to.z == 10.0
			end)())
		check('a row names where it is GOING and not where it stands',
			Access.Lookup(points, 'roof', 'out').label == 'Rooftop' and
			Access.Lookup(points, 'roof', 'back').label == 'Street')
		check('and carries the destination heading the operator wrote',
			Access.Lookup(points, 'roof', 'out').to.heading == 180.0)

		-- ── the definitions themselves ───────────────────────────────────────
		check('a teleport with no ENTRY is refused',
			Access.FromDefinition('x', { EXIT = { X = 0.0, Y = 0.0, Z = 0.0 } }) == nil)
		check('and one with no EXIT',
			Access.FromDefinition('x', { ENTRY = { X = 0.0, Y = 0.0, Z = 0.0 } }) == nil)
		check('a coordinate that is not a number is refused',
			Access.FromDefinition('x', { ENTRY = { X = 'there', Y = 0.0, Z = 0.0 },
				EXIT = { X = 0.0, Y = 0.0, Z = 0.0 } }) == nil)
		check('and a NaN is refused, because it passes every comparison',
			Access.FromDefinition('x', { ENTRY = { X = 0 / 0, Y = 0.0, Z = 0.0 },
				EXIT = { X = 0.0, Y = 0.0, Z = 0.0 } }) == nil)
		check('a key over the column width is refused',
			Access.FromDefinition(string.rep('k', Access.MAX_KEY + 1),
				{ ENTRY = { X = 0.0, Y = 0.0, Z = 0.0 },
					EXIT = { X = 0.0, Y = 0.0, Z = 0.0 } }) == nil)
		check('RETURN is two-way only when it is written as true, never coerced',
			(function()
				local loose = Access.FromDefinition('loose', { RETURN = 'yes',
					ENTRY = { X = 0.0, Y = 0.0, Z = 0.0 }, EXIT = { X = 1.0, Y = 0.0, Z = 0.0 } })
				return loose ~= nil and loose.twoWay == false
			end)())
		check('a heading is wrapped rather than refused, because 370 is a bearing',
			Access.FromDefinition('turn', { ENTRY = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 370.0 },
				EXIT = { X = 1.0, Y = 0.0, Z = 0.0 } }).entry.heading == 10.0)

		-- ── job eligibility, as a pure function ──────────────────────────────
		-- The rule is `lib/shared/jobgate.lua`, shared with the elevators module;
		-- these drive it through THIS module's own adapter, because the adapter is
		-- what decides which leg carries a gate.
		local now = 1000000
		local function snap(name, level, onDuty, jobs)
			return { job = name and { name = name, grade = { level = level },
				onDuty = onDuty } or nil, jobs = jobs, atMs = now }
		end
		local open = Access.Lookup(points, 'roof', 'out')
		local gated = Access.Lookup(points, 'vault', 'out')
		local homeward = Access.Lookup(points, 'vault', 'back')

		check('an ungated teleport is open to a character that could not be read',
			(Access.Evaluate(open, nil, now)) == true)
		local ok, refusal = Access.Evaluate(gated, nil, now)
		check('a gated one is shut to the same character', ok == false and
			refusal == 'no_character', tostring(refusal))
		ok, refusal = Access.Evaluate(gated, snap('arasaka', 1, true), now)
		check('and to the right job at too low a grade', ok == false and
			refusal == 'grade_too_low', tostring(refusal))
		ok, refusal = Access.Evaluate(gated, snap('militech', 9, true), now)
		check('and to the wrong job at any grade', ok == false and
			refusal == 'job_required', tostring(refusal))
		ok, refusal = Access.Evaluate(gated, snap('arasaka', 3, false), now)
		check('and to the right rank off duty, because ON_DUTY was written',
			ok == false and refusal == 'off_duty', tostring(refusal))
		check('and open at the grade it asks for, on duty',
			(Access.Evaluate(gated, snap('arasaka', 2, true), now)) == true)

		local stale = now + Access.JOB_MAX_AGE_MS + 1
		ok, refusal = Access.Evaluate(gated, snap('arasaka', 3, true), stale)
		check('a stale snapshot shuts a gated teleport', ok == false and
			refusal == 'job_stale', tostring(refusal))
		check('and leaves an ungated one open, because a broken read must not ' ..
			'wall off a shortcut', (Access.Evaluate(open, snap('arasaka', 3, true), stale)) == true)

		-- THE WAY BACK IS NEVER GATED, and this is the check that keeps somebody
		-- from being stranded on the far side of their own revoked job -- in a
		-- place that, by this module's whole premise, has no walkable way out.
		check('the way back out of a locked teleport is open to nobody at all',
			(Access.Evaluate(homeward, nil, now)) == true)
		check('and carries no gate to be read', homeward.jobs == nil and
			homeward.onDuty == false)
		check('while the way in still carries the operator\'s own reason',
			gated.reason == 'Arasaka Counterintel')

		-- ── standing on it, as a pure function ───────────────────────────────
		local at = Access.Lookup(points, 'roof', 'out')
		check('a body on the mark is standing on the entrance',
			(Access.AtEntrance(at, 100.0, 200.0, 10.0, 0)) == true)
		check('a body across the street is not',
			select(2, Access.AtEntrance(at, 140.0, 200.0, 10.0, 0)) == 'too_far')
		check('nor is one in another routing bucket standing in the same spot',
			select(2, Access.AtEntrance(at, 100.0, 200.0, 10.0, 7)) == 'wrong_bucket')
		-- THE VERTICAL BAND, which is the measurement the elevators deliberately
		-- do not have. A lift is called from every floor of its shaft; a pad is a
		-- disc. The case this really guards is a body FALLING through the marker's
		-- column, which passes a flat-only test for the whole of the fall.
		check('a body on the walkway overhead is not standing on the pad below it',
			select(2, Access.AtEntrance(at, 100.0, 200.0, 10.0 + Access.USE_HEIGHT + 0.5, 0))
				== 'too_far')
		check('and neither is one falling past it from underneath',
			select(2, Access.AtEntrance(at, 100.0, 200.0, 10.0 - Access.USE_HEIGHT - 0.5, 0))
				== 'too_far')
		check('a position that is not a number is no position',
			select(2, Access.AtEntrance(at, 'here', 200.0, 10.0, 0)) == 'no_position')

		-- ── the wire: every refusal is the server\'s, and nothing moves ───────
		local USE = M.Event.USE
		check('the request door is on the net channel', type(control.netEvents[USE]) == 'function')

		--- One client pressing the key, and the thread the trip runs on.
		local function use(player, key, leg)
			env.source = player
			control.netEvents[USE](key, leg)
			env.source = nil
			-- The handler hands the trip to a `CreateThread`, because `:await()`
			-- needs a managed coroutine; without the pump nothing would have run.
			control.Pump(8)
		end

		--- The last ANSWER put on the wire: key, leg, ok, code, reason.
		local function answer()
			for index = #control.clientEvents, 1, -1 do
				if control.clientEvents[index].name == M.Event.ANSWER then
					return control.clientEvents[index]
				end
			end
			return nil
		end

		local trips = control.trips
		local function moved() return #trips.calls end

		-- A PLAYER ID PER CASE, and not one player pressing the key eight times.
		-- The request window is four in ten seconds and the pump advances the
		-- clock a tenth of a second a round, so a suite that reused one slot would
		-- start answering `rate_limited` halfway down -- which is the limiter
		-- working and every check below it testing nothing.
		WHERE.x, WHERE.y, WHERE.z, WHERE.bucket = 100.0, 200.0, 10.0, 0

		-- A key nobody configured.
		use(11, 'no_such_key', 'out')
		local last = answer()
		check('a teleport nobody configured is refused', last ~= nil and last[3] == false and
			last[4] == 'no_such_teleport', last and tostring(last[4]))
		check('and no body was asked to move', moved() == 0, moved())

		-- The back leg of a one-way, standing at its exit.
		WHERE.x, WHERE.y, WHERE.z = 300.0, 400.0, -8.0
		use(12, 'hatch', 'back')
		last = answer()
		check('the back leg of a one-way is refused by the server, not by the page',
			last ~= nil and last[3] == false and last[4] == 'no_such_teleport',
			last and tostring(last[4]))
		check('and still nothing moved', moved() == 0, moved())

		-- A gated teleport with no character loaded.
		WHERE.x, WHERE.y, WHERE.z = 500.0, 600.0, 2.0
		use(13, 'vault', 'out')
		last = answer()
		check('a locked teleport is refused to a character the server cannot read',
			last ~= nil and last[3] == false and last[4] == 'no_character',
			last and tostring(last[4]))
		check('and the refusal carries the operator\'s own words, so it says why',
			last ~= nil and last[5] == 'Arasaka Counterintel', last and tostring(last[5]))
		check('and nothing moved', moved() == 0, moved())

		-- Standing nowhere near it.
		WHERE.x, WHERE.y, WHERE.z = 100.0, 200.0, 10.0
		use(14, 'hatch', 'out')
		last = answer()
		check('a teleport asked for from across the map is refused too_far',
			last ~= nil and last[3] == false and last[4] == 'too_far',
			last and tostring(last[4]))
		check('and nothing moved', moved() == 0, moved())

		-- Standing directly above it: the mid-fall case, on the wire.
		WHERE.x, WHERE.y, WHERE.z = 100.0, 200.0, 10.0 + Access.USE_HEIGHT + 5.0
		use(15, 'roof', 'out')
		last = answer()
		check('a body falling past the marker is refused, not carried',
			last ~= nil and last[3] == false and last[4] == 'too_far',
			last and tostring(last[4]))
		check('and nothing moved', moved() == 0, moved())

		-- ── a trip that is allowed ───────────────────────────────────────────
		WHERE.x, WHERE.y, WHERE.z, WHERE.bucket = 100.0, 200.0, 10.0, 0
		use(16, 'roof', 'out')
		last = answer()
		check('a player standing on an ungated entrance is carried',
			last ~= nil and last[3] == true, last and tostring(last[4]))
		check('and exactly one body was asked to move', moved() == 1, moved())
		local call = trips.calls[1]
		check('to the EXIT the operator wrote, and never to anything off the wire',
			call ~= nil and call.position.x == 100.0 and call.position.y == 205.0
				and call.position.z == 40.0)
		check('facing the way the operator wrote',
			call ~= nil and call.options.heading == 180.0, call and tostring(call.options.heading))
		check('in the teleport\'s own routing bucket',
			call ~= nil and call.options.bucket == 0)
		check('with the arrival watch given the configured budget',
			call ~= nil and call.options.timeoutMs == M.Settings.SETTLE_MS,
			call and tostring(call.options.timeoutMs))
		-- A PLAYER IN A VEHICLE IS REFUSED AND NOT EJECTED, by default: `dismount`
		-- accepts LOSING the car, which leaves it parked across the pad.
		check('and dismount off, so a driver is refused rather than losing their car',
			call ~= nil and call.options.dismount == false,
			call and tostring(call.options.dismount))

		-- ── the arrival is checked, not assumed ──────────────────────────────
		-- The platform's watch rejects `settle_timeout` when the body never stood
		-- at the mark. A module that took the promise and walked away would report
		-- that trip as a success, and the player would be inside a hillside being
		-- told they had arrived.
		trips.reject = 'settle_timeout'
		use(17, 'roof', 'out')
		last = answer()
		check('a trip whose body never arrived is reported as a failure',
			last ~= nil and last[3] == false and last[4] == 'settle_timeout',
			last and tostring(last[4]))
		check('and the destination is named in the journal, because a timeout ' ..
			'means there is no floor there',
			(function()
				for _, line in ipairs(control.log.warn) do
					if tostring(line):find('roof', 1, true) and
						tostring(line):find('never arrived', 1, true) then return true end
				end
				return false
			end)())
		trips.reject = nil

		-- A refusal from the native itself, before anything moved.
		trips.refuse = 'player_in_vehicle'
		use(18, 'roof', 'out')
		last = answer()
		check('the platform\'s own refusal reaches the player in its own words',
			last ~= nil and last[3] == false and last[4] == 'player_in_vehicle',
			last and tostring(last[4]))
		trips.refuse = nil

		-- ── the gate, re-derived at the moment of the press ──────────────────
		-- The contract table is the one the server half reaches through
		-- `OPX.Api.Get`, so replacing its reader is exactly what a loaded
		-- character would change and nothing else.
		local character = OPX.Api.Get('character')
		local heldJob = { name = 'arasaka', grade = { level = 3 }, onDuty = true }
		local realGetPlayer = character.GetPlayer
		character.GetPlayer = function()
			return { PlayerData = { job = heldJob, jobs = {} } }
		end

		WHERE.x, WHERE.y, WHERE.z = 500.0, 600.0, 2.0
		use(19, 'vault', 'out')
		last = answer()
		check('the right job at the right grade, on duty, is carried through the lock',
			last ~= nil and last[3] == true, last and tostring(last[4]))

		heldJob = { name = 'arasaka', grade = { level = 3 }, onDuty = false }
		use(19, 'vault', 'out')
		last = answer()
		check('and the same rank off duty is refused at the moment of the press',
			last ~= nil and last[3] == false and last[4] == 'off_duty',
			last and tostring(last[4]))

		-- AND THE WAY BACK IS STILL OPEN TO THEM. This is the stranding case end
		-- to end: their duty ended while they were inside.
		WHERE.x, WHERE.y, WHERE.z = 505.0, 600.0, 2.0
		use(19, 'vault', 'back')
		last = answer()
		check('but the way back out is not, so nobody is stranded by a duty toggle',
			last ~= nil and last[3] == true, last and tostring(last[4]))

		-- ── the list a client draws from ─────────────────────────────────────
		heldJob = { name = 'militech', grade = { level = 9 }, onDuty = true }
		WHERE.x, WHERE.y, WHERE.z, WHERE.bucket = 100.0, 200.0, 10.0, 0
		env.source = 15
		control.netEvents[M.Event.ASK]()
		env.source = nil
		local sync = nil
		for index = #control.clientEvents, 1, -1 do
			if control.clientEvents[index].name == M.Event.SYNC then
				sync = control.clientEvents[index][1]
				break
			end
		end
		check('a client is sent the entrances of its own bucket', type(sync) == 'table' and
			type(sync.entrances) == 'table')

		local byId = {}
		if type(sync) == 'table' and type(sync.entrances) == 'table' then
			for _, row in ipairs(sync.entrances) do byId[row.key .. ':' .. row.leg] = row end
		end
		check('a two-way teleport is sent as two entrances',
			byId['roof:out'] ~= nil and byId['roof:back'] ~= nil)
		check('and a one-way as one', byId['hatch:out'] ~= nil and byId['hatch:back'] == nil)
		check('a teleport in another bucket is not sent at all', byId['elsewhere:out'] == nil)

		-- WHAT IS *NOT* ON THE WIRE is the point of this pair. A client that never
		-- learns where a teleport goes cannot name the place it wants to go to,
		-- which is why the request carries a key and a leg and nothing else.
		check('an entrance carries the position of the mark it is standing on',
			byId['roof:out'] ~= nil and byId['roof:out'].x == 100.0
				and byId['roof:out'].z == 10.0)
		check('and never the coordinates of where it leads',
			(function()
				for _, row in ipairs(sync.entrances) do
					for _, field in ipairs({ 'to', 'exit', 'destination', 'heading' }) do
						if row[field] ~= nil then return false end
					end
				end
				return true
			end)())

		check('a locked entrance is marked refused for the client to colour',
			byId['vault:out'] ~= nil and byId['vault:out'].allowed == false)
		check('and carries the operator\'s reason, so the marker can say why',
			byId['vault:out'] ~= nil and byId['vault:out'].reason == 'Arasaka Counterintel')
		check('while its way back out is marked open',
			byId['vault:back'] ~= nil and byId['vault:back'].allowed == true)
		check('and an ungated one is open to the same character',
			byId['roof:out'] ~= nil and byId['roof:out'].allowed == true)

		-- ── the request window ───────────────────────────────────────────────
		-- The limit governs the CABIN, not the answer: a request past it is still
		-- answered, so a player sees why nothing happened.
		local allowance = M.Settings.REQUESTS_PER_WINDOW
		local before = moved()
		for _ = 1, allowance + 2 do use(21, 'roof', 'out') end
		last = answer()
		check('a player past their request window is refused rather than carried',
			last ~= nil and last[3] == false and last[4] == 'rate_limited',
			last and tostring(last[4]))
		check('and no more bodies moved than the window allowed',
			moved() - before <= allowance, moved() - before)

		character.GetPlayer = realGetPlayer
	end
end

section('teleports, client side')
do
	local cenv, cctl, cwhy = boot('client')
	check('the client boots with the teleports module', cwhy == nil, cwhy)

	if cwhy == nil then
		local OPX = cenv.OPX
		local teleports = OPX.Modules.Get('teleports')
		local Runtime = teleports.Runtime
		local Access = teleports.Access

		check('the client half is running, not just loaded',
			OPX.Modules.IsRunning('teleports'), OPX.Modules.Record('teleports').Reason)
		check('and publishes its half of the contract',
			(function()
				local api = OPX.Api.Get('teleports')
				return api ~= nil and type(api.Use) == 'function'
					and type(api.Nearest) == 'function' and type(api.State) == 'function'
			end)())

		-- Every other marker module draws on the SAME engine list, so their spots
		-- come down before anything here is counted: otherwise every count below
		-- is off by however many they had placed.
		cctl.netEvents[OPX.Modules.Get('garages').Event.SYNC]({ spots = {} })
		cctl.netEvents[OPX.Modules.Get('dealership').Event.SYNC]({ spots = {} })
		cctl.netEvents[OPX.Modules.Get('clothing').Event.SYNC]({ spots = {} })
		cctl.Pump(6)

		local mapping = cctl.keyMappings.byId['opx.teleports.use']
		check('the key is declared to the host, so a player can rebind it', mapping ~= nil)
		check('and defaults to E, the same gesture as a garage, a dealer or a store',
			mapping ~= nil and mapping.key == 'E', mapping and tostring(mapping.key))

		local asked = false
		for index = 1, #cctl.serverEvents do
			if cctl.serverEvents[index].name == teleports.Event.ASK then asked = true end
		end
		check('the client asks the server for its entrances on start', asked)

		-- ── the markers ───────────────────────────────────────────────────────
		-- The client stands at the origin (`placement` in the host), so the open
		-- entrance is underfoot and the locked one is a few metres away.
		local function sync(rows)
			cctl.netEvents[teleports.Event.SYNC]({ entrances = rows })
			cctl.Pump(6)
		end

		sync({
			{ key = 'roof', leg = 'out', label = 'Rooftop', x = 0.0, y = 0.0, z = 0.0,
				allowed = true },
			{ key = 'vault', leg = 'out', label = 'Vault', x = 8.0, y = 0.0, z = 0.0,
				allowed = false, error = 'off_duty', reason = 'Arasaka Counterintel' },
			{ key = 'far', leg = 'out', label = 'Far', x = 5000.0, y = 0.0, z = 0.0,
				allowed = true },
		})
		settle(cctl, function() return Runtime.Report().markers == 2 end)

		check('one marker is drawn per entrance in range',
			Runtime.Report().entrances == 3 and Runtime.Report().markers == 2,
			('%d held, %d drawn'):format(Runtime.Report().entrances, Runtime.Report().markers))

		local styles = {}
		for _, id in ipairs(cenv.Open77.markers.list()) do
			local options = cctl.markers.byId[id]
			if options ~= nil then styles[#styles + 1] = options.style end
		end
		table.sort(styles)
		-- A LOCKED SHORTCUT IS VISIBLY LOCKED FROM ACROSS THE STREET, which is the
		-- whole reason `allowed` is on the wire at all. It decides a colour and
		-- nothing else -- the server refuses the trip either way.
		check('a refused entrance is drawn in the locked style and an open one is not',
			#styles == 2 and styles[1] == 'danger' and styles[2] == 'interaction',
			table.concat(styles, '/'))

		-- A PROMOTION ARRIVING ON THE POLL REMAKES THE MARKER. The style is fixed
		-- when a marker is created, so a client that left it alone would keep
		-- drawing a red ring on a shortcut the player may now take -- which reads
		-- as the server refusing them, and is the opposite of the truth.
		sync({
			{ key = 'roof', leg = 'out', label = 'Rooftop', x = 0.0, y = 0.0, z = 0.0,
				allowed = true },
			{ key = 'vault', leg = 'out', label = 'Vault', x = 8.0, y = 0.0, z = 0.0,
				allowed = true },
			{ key = 'far', leg = 'out', label = 'Far', x = 5000.0, y = 0.0, z = 0.0,
				allowed = true },
		})
		settle(cctl, function()
			for _, id in ipairs(cenv.Open77.markers.list()) do
				local options = cctl.markers.byId[id]
				if options ~= nil and options.style == 'danger' then return false end
			end
			return true
		end)
		local stillLocked = false
		for _, id in ipairs(cenv.Open77.markers.list()) do
			local options = cctl.markers.byId[id]
			if options ~= nil and options.style == 'danger' then stillLocked = true end
		end
		check('an entrance that was unlocked underneath the player is redrawn open',
			not stillLocked)

		-- ── a malformed payload is dropped, not drawn ─────────────────────────
		check('an entrance with no usable key is refused off the wire',
			Access.FromWire({ leg = 'out', x = 0.0, y = 0.0, z = 0.0 }) == nil)
		check('and one naming a leg that does not exist',
			Access.FromWire({ key = 'k', leg = 'sideways', x = 0.0, y = 0.0, z = 0.0 }) == nil)
		check('and one whose position is a NaN, which would poison every distance',
			Access.FromWire({ key = 'k', leg = 'out', x = 0 / 0, y = 0.0, z = 0.0 }) == nil)

		-- ── the key sends two strings and nothing else ────────────────────────
		local before = #cctl.serverEvents
		local pressed = Runtime.Use('test')
		check('the key press is accepted while standing on an entrance',
			pressed.ok == true, tostring(pressed.error))

		local sent = nil
		for index = before + 1, #cctl.serverEvents do
			if cctl.serverEvents[index].name == teleports.Event.USE then
				sent = cctl.serverEvents[index]
			end
		end
		check('and it reaches the server as a key and a leg', sent ~= nil and
			sent[1] == 'roof' and sent[2] == 'out',
			sent and ('%s/%s'):format(tostring(sent[1]), tostring(sent[2])))
		-- THE REQUEST CARRIES NO COORDINATE, and this is the one check that makes
		-- "the server decides" true rather than merely intended: a client that
		-- could name a position could name any position.
		check('and carries nothing else at all -- no position for the server to trust',
			sent ~= nil and sent[3] == nil, sent and tostring(sent[3]))

		-- A SECOND PRESS WHILE THE FIRST IS UNANSWERED IS HELD BACK. The server
		-- keeps the real lock; this only stops a held key filling the request
		-- window with duplicates of a trip already under way.
		local again = Runtime.Use('test')
		check('a second press before the answer arrives is held back locally',
			again.ok ~= true and again.error == 'teleports.inFlight', tostring(again.error))

		cctl.netEvents[teleports.Event.ANSWER]('roof', 'out', true, nil, 'Rooftop')
		cctl.Pump(2)
		check('and the answer releases it', Runtime.Report().asking == false)

		-- ── standing on nothing ───────────────────────────────────────────────
		sync({})
		settle(cctl, function() return Runtime.Report().markers == 0 end)
		check('a list that was cleared takes its markers down with it',
			Runtime.Report().markers == 0, Runtime.Report().markers)
		local nowhere = Runtime.Use('test')
		check('and the key on empty ground refuses locally rather than asking',
			nowhere.ok ~= true and nowhere.error == 'teleports.noSuchTeleport',
			tostring(nowhere.error))
	end
end
print(('\n%d checks, %d failed'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
