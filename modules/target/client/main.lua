--- The eye: the held key, the screen ray under the cursor, the row list and the pick.
-- @author dop42
--
-- WHERE THE WORK IS BOUNDED, because this is the module that proved it matters.
--
-- Holding the key and pressing the RIGHT button asks every row that matches what
-- the ray hit whether it applies. A row whose owner is another resource answers
-- over a host call, and the original did all of them inside one coroutine body.
-- That body exceeded the per-resume instruction budget, which unwinds straight out
-- of the coroutine and never resumes it -- no crash, no repeat, nothing logged.
-- Three things keep that from coming back and none of them is optional:
--
--   1. a pick is resolved in SLICES of `BATCH` rows, one slice per scheduler pass,
--      each on its own one-shot thread that ends when the slice does;
--   2. an owner's liveness is cached for `ALIVE_CACHE_MS` and the registry sweeps
--      ONCE per batch, not once per row;
--   3. `MAX_PER_OWNER` bounds how much any one owner can add to the walk.
--
-- The scheduler is the other half of it: there is no `CreateThread` loop here at
-- all. `OPX.Scheduler.Every` runs the two repeating jobs, and the only threads
-- this file spawns are one-shot bodies for work that has to yield on a promise.

local M = OPX.Modules.Get('target')
local Model = M.Model
local Result = OPX.Result

-- The key mapping id the pause menu lists.
local KEY_ID = 'opx.target.activate'

-- The surface the page draws on, and this module's name on its focus stack.
local SURFACE = 'interactive'
local FOCUS = 'target'

-- The public client bus: what another resource listens to with a bare
-- AddEventHandler. It must stay on the LOCAL channel -- the host dispatcher
-- matches on the name alone, so a local raise on a NET name would re-enter a
-- network handler of the same name.
local EVENT_OPENED = OPX.Event(OPX.Channel.LOCAL, 'target', 'opened')
local EVENT_CLOSED = OPX.Event(OPX.Channel.LOCAL, 'target', 'closed')
local EVENT_SELECTED = OPX.Event(OPX.Channel.LOCAL, 'target', 'selected')

-- What `downed` raises when the player goes down or gets back up.
local EVENT_DOWNED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Milliseconds two picks must be apart.
local PICK_GAP_MS = 150

-- Milliseconds an owner's running answer is reused. A start or a stop forgets it
-- at once, so this only ever delays noticing a reload.
local ALIVE_CACHE_MS = 500

-- What a module id is stamped with in place of a generation. A module lives in
-- this VM: it has no resource generation, so it is never swept for a reload it
-- cannot have had. Only stopping takes its rows away.
local IN_PROCESS = 'module'

-- Settings, read in Init so a config change does not need a code change.
local KEY, BLOCK_WEAPON_WHEEL, RAY_DISTANCE, MAX_OPTIONS = 'ALT', true, 12.0, 32
local HOVER_MS, WATCH_MS, RESOLVE_MS, SWEEP_MS = 90, 50, 25, 2000
local REVALIDATE_MS, LOOKUP_BUDGET_MS, BATCH = 200, 1500, 5

-- Whether the key is held and the eye is up.
local opened = false

-- Whether a pick or a select is being worked out.
local busy = false

-- The handle the page echoes on every message. One per open; a message carrying
-- any other handle is a message from a session that has gone.
local handle = nil
local sequence = 0

-- Bumped on every open, pick, select and close, so a late answer is dropped. The
-- page never sees it: the handle is the page's guard, this is Lua's.
local request = 0

-- What the listed rows were built for.
local selection

-- Tokens of the rows on screen, the only ones a select may name.
local listed = {}

-- Whether the key was released since the last open. The host reports a captured
-- key as up, so this is what keeps one press from reopening the eye forever.
local armed = true

-- Milliseconds of the last pick and the last hover look, and of the next check
-- that the picked target is still there.
local lastPick, lastHover, nextCheck = -math.huge, -math.huge, 0

-- Owners that switched targeting off, to the generation that did.
local disabledBy = {}

-- Whether `downed` says the player is on the floor.
local down = false

-- Owner to its generation and when that was read.
local liveness = {}

-- The pick being resolved, or nil: request, context, queue, at, rows, listed,
-- budget and whether a slice's thread is running.
local pending = nil

-- Scheduler handles, so Stop takes the jobs down with the module.
local jobs = {}

-- Reads the generation an owner is on, or nil when it is not running. A module in
-- this VM answers the sentinel; a separate resource answers the host's number, so
-- a reload leaves its rows behind.
local function readGeneration(owner)
	if OPX.Modules.IsRunning(owner) then return IN_PROCESS end
	local record = OPX.Modules.Record(owner)
	-- `started` is only stamped once EVERY module's Start has run, so a module
	-- registering its rows from its own Start is still `declared` here. Without
	-- this it would be refused by nothing but the boot order.
	if record ~= nil then return record.State == 'declared' and IN_PROCESS or nil end
	local read, state = pcall(GetResourceState, owner)
	if not read or state ~= 'running' then return nil end
	local resource = Open77.resource
	if type(resource) ~= 'table' or type(resource.generation) ~= 'function' then return IN_PROCESS end
	local got, current = pcall(resource.generation, owner)
	if not got or current == nil then return IN_PROCESS end
	return current
end

-- The generation an owner is on now, read at most twice a second.
local function generationOf(owner)
	if type(owner) ~= 'string' or owner == '' then return nil end
	local at = OPX.Now()
	local known = liveness[owner]
	if known == nil or at - known.at > ALIVE_CACHE_MS then
		known = { at = at, generation = readGeneration(owner) }
		liveness[owner] = known
	end
	return known.generation
end

-- Whether an owner still runs the generation that registered.
local function alive(owner, generation)
	local current = generationOf(owner)
	return current ~= nil and current == generation
end

--- Every row every owner registered.
M.Registry = Model.New(alive)
local Registry = M.Registry

-- Writes one message to the page. False means there is no surface, or the page
-- has not reported ready, which is a refusal and not a retry.
local function send(channel, payload)
	return OPX.UI.Send(SURFACE, channel, payload)
end

-- The key the player bound, or the configured one.
local function key()
	return OPX.Lib.Input.KeyFor(KEY_ID) or KEY
end

-- Whether the target key is down.
local function held()
	return OPX.Lib.Input.IsDown(key())
end

-- The character state when it stands in the world alive, or nil.
local function living()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
	local read, state = pcall(character.state)
	if not read or type(state) ~= 'table' or not state.attached or not state.alive then return nil end
	if type(state.health) ~= 'number' or state.health <= 0 or type(state.position) ~= 'table' then return nil end
	return state
end

-- Whether this client can pick at all. Without a screen ray there is no eye, and
-- the registry is the only half of the module that still works.
local function canPick()
	local camera = Open77.camera
	local input = Open77.input
	return type(camera) == 'table' and type(camera.screenRaycast) == 'function'
		and type(input) == 'table' and type(input.cursor) == 'function'
end

-- Holds or hands back aim, shooting, interaction and the camera. Every one of
-- these needs `players.controls`; without the permission the eye refuses to open
-- rather than opening over live controls.
local function controls(hold)
	local players = Open77.players
	if type(players) ~= 'table' then return false end
	if not hold then
		if type(players.resetControls) == 'function' then pcall(players.resetControls) end
		return true
	end
	local taken = pcall(function()
		assert(players.allowAim(false) and players.allowShoot(false)
			and players.allowInteraction(false) and players.freezeRotation(true))
	end)
	return taken
end

--- Takes the eye down and hands the cursor, camera and weapons back.
-- @author dop42
-- @param reason string
local function close(reason)
	request = request + 1
	local was = opened
	opened, busy, selection, listed, pending = false, false, nil, {}, nil
	if handle ~= nil then send('target:close', { handle = handle }) end
	handle = nil
	OPX.UI.ReleaseFocus(FOCUS)
	if not was then return end
	controls(false)
	TriggerEvent(EVENT_CLOSED, reason or 'closed')
end

-- Whether no running owner has switched targeting off.
local function targetingEnabled()
	for owner, generation in pairs(disabledBy) do
		if not alive(owner, generation) then disabledBy[owner] = nil end
	end
	return next(disabledBy) == nil
end

-- Casts the screen ray at a point and describes what it hit.
local function contextAt(x, y)
	local state = living()
	if state == nil then return nil end
	local camera = Open77.camera
	if type(camera) ~= 'table' or type(camera.screenRaycast) ~= 'function' then return nil end
	local called, hit = pcall(camera.screenRaycast, x, y, RAY_DISTANCE, { self = true })
	if not called or type(hit) ~= 'table' then return nil end
	hit.screen = { x = x, y = y }
	if not hit.hit then
		hit.target = { kind = 'sky', networked = false }
		hit.kind = 'sky'
		hit.playerDistance = nil
		return hit
	end
	if not hit.entityLookupAvailable then return nil end
	local at, here = hit.position, state.position
	if type(at) ~= 'table' then return nil end
	hit.playerDistance = math.sqrt((at.x - here.x) ^ 2 + (at.y - here.y) ^ 2 + (at.z - here.z) ^ 2)
	hit.target = type(hit.target) == 'table' and hit.target or { kind = 'world', networked = false }
	hit.kind = hit.target.isLocalPlayer and 'self' or hit.target.kind
	return hit
end

-- Whether two contexts hit the same thing.
local function sameTarget(left, right)
	if left == nil or right == nil or left.kind ~= right.kind then return false end
	if left.kind == 'sky' then
		local p, q = left.direction, right.direction
		return type(p) == 'table' and type(q) == 'table' and p.x * q.x + p.y * q.y + p.z * q.z > 0.9998
	end
	if left.target.engineEntity or right.target.engineEntity then
		return left.target.engineEntity == right.target.engineEntity
	end
	local p, q = left.position, right.position
	if type(p) ~= 'table' or type(q) ~= 'table' then return false end
	return (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2 < 0.04
end

-- Whether a request is still the current one, the surface still holds focus and
-- the player still holds the key.
local function stillHeld(at)
	if not opened or at ~= request then return false end
	return OPX.UI.FocusOwner() == FOCUS and held()
end

-- Reads a page point in 0..1, or nil.
local function point(payload)
	local x, y = payload.x, payload.y
	if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then
		return nil
	end
	return x, y
end

-- Asks one row's owner a question about what the ray hit.
--
-- A FUNCTION is called here, in this VM: no promise, no host call, no yield, and
-- it is the reason a module's rows cost the budget almost nothing. A
-- `{ resource, export }` pair is a genuinely separate resource and goes over
-- `OPX.Lib.Rpc.Call`, which yields on the promise -- which is why every caller of
-- this runs on a one-shot thread and never on a scheduler job.
local function ask(row, callback, context)
	local observation = {}
	for field, value in pairs(context) do observation[field] = value end
	observation.option = { id = row.id, owner = row.owner, token = row.token, data = row.data }
	if type(callback) == 'function' then
		local ran, answer = pcall(callback, observation)
		if not ran then return nil, tostring(answer) end
		return answer
	end
	if type(callback) ~= 'table' then return nil, 'no_callback' end
	-- `answer.value` is the remote's whole reply table; its payload is the
	-- `value` inside that, which is why this reads twice.
	local answer = OPX.Lib.Rpc.Call(callback.resource, callback.export, observation)
	if not answer.ok then return nil, answer.error end
	return answer.value.value
end

-- Draws the resolved list, or nothing at all.
local function finish()
	local job = pending
	pending = nil
	if job == nil or not stillHeld(job.request) then return end
	busy = false
	if #job.rows == 0 then
		-- Nothing to offer: the eye goes back to hovering as if the press never
		-- happened. Not an empty panel, and not a line saying there is nothing here.
		listed = {}
		send('target:empty', { handle = handle })
		return
	end
	selection, listed = job.context, job.listed
	send('target:menu', {
		handle = handle,
		x = job.context.screen.x,
		y = job.context.screen.y,
		options = job.rows,
	})
end

-- One slice of a pick: at most BATCH rows, then the body ends. Runs on its own
-- one-shot thread because `ask` may yield.
local function slice()
	local job = pending
	if job == nil then return end
	local last = math.min(job.at + BATCH - 1, #job.queue)
	while job.at <= last do
		if not stillHeld(job.request) then
			pending = nil
			return
		end
		if OPX.Now() >= job.budget then
			-- A spent budget never dispatches a call whose answer would be dropped.
			job.at = #job.queue + 1
			break
		end
		local row = job.queue[job.at]
		job.at = job.at + 1
		local allowed = row.canInteract == nil or ask(row, row.canInteract, job.context) == true
		local mark
		if allowed and row.checked ~= nil then
			local answer = ask(row, row.checked, job.context)
			-- Only a boolean draws a box; nil, an error or a refusal leaves the row
			-- without one.
			if answer == true or answer == false then mark = answer end
		end
		if not stillHeld(job.request) then
			pending = nil
			return
		end
		if allowed and Registry.Get(row.token) == row and Registry.Matches(row, job.context) then
			job.rows[#job.rows + 1] = {
				token = row.token, label = row.label, description = row.description,
				group = row.group, icon = row.icon, danger = row.danger, checked = mark,
			}
			job.listed[row.token] = true
			if #job.rows >= MAX_OPTIONS then
				job.at = #job.queue + 1
				break
			end
		end
	end
	if job.at > #job.queue then return finish() end
	job.inFlight = false
end

-- Starts the next slice, if the last one has finished. The scheduler job, and the
-- only thing that paces the resolution.
local function resolve()
	local job = pending
	if job == nil or job.inFlight then return end
	if not stillHeld(job.request) then
		pending = nil
		return
	end
	job.inFlight = true
	-- One thread per slice, and the slice is bounded. The instruction budget
	-- unwinds out of a coroutine body and never resumes it; a body that handles
	-- five rows and then ends cannot become the loop that silently stopped,
	-- because the next slice gets a thread of its own either way.
	CreateThread(slice)
end

-- Lights the eye when the cursor is over something with rows, predicates aside.
local function hover(payload)
	if not opened or busy or selection ~= nil or payload.handle ~= handle then return end
	if OPX.Now() - lastHover < HOVER_MS * 0.5 then return end
	lastHover = OPX.Now()
	local x, y = point(payload)
	if x == nil then return end
	local context = contextAt(x, y)
	-- `Any` deliberately does not sweep: this runs while the pointer moves, and a
	-- sweep here would be a host read per owner per frame.
	send('target:hover', { handle = handle, available = context ~= nil and Registry.Any(context) })
end

-- Lists the rows for what is under a pick -- the point of the right-button press.
local function pick(payload)
	if not opened or busy or payload.handle ~= handle then return end
	if OPX.Now() - lastPick < PICK_GAP_MS then return end
	lastPick = OPX.Now()
	local cursor = OPX.Lib.Input.Cursor()
	if cursor == nil or not cursor.inBounds then return end
	-- The PRESS's point, not the cursor's later one: between the press and this
	-- handler the pointer has already moved, and the ray below is cast fresh at the
	-- point the player actually pressed.
	local x, y = point(payload)
	if x == nil then return end

	request = request + 1
	selection, listed, busy = nil, {}, true
	if not send('target:loading', { handle = handle, x = x, y = y }) then
		return close('no_surface')
	end
	local context = contextAt(x, y)
	if context == nil then
		busy = false
		send('target:empty', { handle = handle })
		return
	end
	pending = {
		request = request,
		context = context,
		-- One sweep for the whole pick, inside Candidates.
		queue = Registry.Candidates(context),
		at = 1,
		rows = {},
		listed = {},
		budget = OPX.Now() + LOOKUP_BUDGET_MS,
		inFlight = false,
	}
end

-- Runs a listed row's onSelect once its target and its predicate still hold. On
-- its own one-shot thread: every step here may yield on a promise.
local function commit(row, at)
	local current = contextAt(selection.screen.x, selection.screen.y)
	if not sameTarget(selection, current) or not Registry.Matches(row, current) then
		return close('target_changed')
	end
	local allowed = row.canInteract == nil or ask(row, row.canInteract, current) == true
	if not stillHeld(at) then return end
	-- Checked again AFTER a predicate that may have yielded, not only before it.
	local fresh = contextAt(selection.screen.x, selection.screen.y)
	if not allowed or Registry.Get(row.token) ~= row or not sameTarget(current, fresh)
		or not Registry.Matches(row, fresh) then
		busy = false
		send('target:error', { handle = handle })
		return
	end
	fresh.option = { id = row.id, owner = row.owner, token = row.token, data = row.data }
	-- Input goes back before the owner opens its own screen.
	close('selected')
	TriggerEvent(EVENT_SELECTED, fresh)
	-- The callback comes from the REGISTERED ROW, never from the page. The page
	-- said which row was clicked and nothing else; this is the re-resolution.
	local answer, failure = ask(row, row.onSelect, fresh)
	if answer == false or failure ~= nil then
		Open77.log.warn(('%s/%s refused the pick: %s'):format(row.owner, row.id,
			tostring(failure or 'rejected')))
	end
end

-- The page reports which row was clicked; everything about it is re-derived here.
local function choose(payload)
	if not opened or busy or payload.handle ~= handle then return end
	if type(payload.token) ~= 'string' or not listed[payload.token] then return end
	local row = Registry.Get(payload.token)
	if row == nil or selection == nil then return close('option_unavailable') end
	request = request + 1
	local at = request
	busy = true
	send('target:busy', { handle = handle, token = payload.token })
	CreateThread(function() commit(row, at) end)
end

-- Puts the eye up while the key is held. The key mapping's own callback, so it
-- runs on a press and never on a loop.
local function open()
	if not armed or not held() then return end
	-- Never again until a real release, even after a pick or Escape.
	armed = false
	if opened or down or not targetingEnabled() or not canPick() then return end
	-- A key that fires while another surface owns the keyboard types into someone
	-- else's text box. `OPX.Lib.Input.IsCaptured` answers CAPTURED when the read itself
	-- raises, which is the safe answer, so this is a refusal and not a warning.
	if OPX.Lib.Input.IsCaptured() then return end
	if living() == nil then return end
	local cursor = OPX.Lib.Input.Cursor()
	if cursor == nil or cursor.captured then return end

	request = request + 1
	sequence = sequence + 1
	handle = ('t%d'):format(sequence)
	opened, selection, listed, busy, pending = true, nil, {}, false, nil
	OPX.UI.AcquireFocus(FOCUS, { keyboard = true, cursor = true })
	if not controls(true) then return close('controls_unavailable') end
	local drawn = send('target:open', {
		handle = handle,
		hoverMs = HOVER_MS,
		labels = {
			hint = locale('target.hint'),
			looking = locale('target.looking'),
			unavailable = locale('target.unavailable'),
			back = locale('target.back'),
		},
	})
	if not drawn then return close('no_surface') end
	TriggerEvent(EVENT_OPENED, { handle = handle })
end

-- Records whether the player is down, taking the eye with it.
local function setDown(value)
	down = value == true
	if down and opened then close('player_down') end
end

-- Closes the eye once the key, the focus or the target is gone.
local function watch()
	if not held() then armed = true end
	if not opened then return end
	if OPX.UI.FocusOwner() ~= FOCUS or not held() or down or living() == nil then
		return close('input_released')
	end
	if selection ~= nil and not busy and OPX.Now() >= nextCheck then
		nextCheck = OPX.Now() + REVALIDATE_MS
		-- The menu names one thing. When that thing is gone the menu is a list of
		-- actions against nothing, so it closes rather than going stale.
		if not sameTarget(selection, contextAt(selection.screen.x, selection.screen.y)) then
			close('target_changed')
		end
	end
end

-- Forgets the rows of owners that have gone, while the eye is down. A pick sweeps
-- for itself; this is what keeps the table from holding a stopped module's rows
-- for a session in which nobody ever targets anything.
local function sweep()
	if opened then return end
	for owner, generation in pairs(disabledBy) do
		if not alive(owner, generation) then disabledBy[owner] = nil end
	end
	Registry.Sweep()
end

-- ── the contract ─────────────────────────────────────────────────────────────
-- Every entry takes the caller's own name as `owner`. There is no
-- `GetInvokingResource` for an in-process call, so the name is given rather than
-- read, exactly as `downed.Suspend` does: a switch, not a boundary.

-- Registers one definition or a batch for an owner, each forced through a filter.
local function stored(owner, definitions, filter)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	if type(definitions) ~= 'table' then return Result.Err('invalid_options') end
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end

	local single = definitions.id ~= nil
	local batch = {}
	for index, definition in pairs(single and { definitions } or definitions) do
		if type(definition) ~= 'table' then return Result.Err('invalid_option') end
		local row = {}
		for field, value in pairs(definition) do row[field] = value end
		for field, value in pairs(filter) do row[field] = value end
		batch[index] = row
	end

	local tokens, reason = Registry.RegisterMany(owner, generation, batch)
	if tokens == nil then return Result.Err(reason) end
	if single then return Result.Ok({ token = tokens[1] }) end
	return Result.Ok({ tokens = tokens })
end

--- Registers one row, or a batch whole or not at all.
-- @author dop42
-- @param owner string
-- @param definitions table one definition, or a list of them
-- @return Result
local function register(owner, definitions)
	return stored(owner, definitions, {})
end

--- Registers rows shown on other players.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerPlayers(owner, definitions)
	return stored(owner, definitions, { types = { 'player' } })
end

--- Registers rows shown on the player's own body.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerSelf(owner, definitions)
	return stored(owner, definitions, { types = { 'player' }, allowSelf = true, selfOnly = true })
end

--- Registers rows shown on vehicles.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerVehicles(owner, definitions)
	return stored(owner, definitions, { types = { 'vehicle' } })
end

--- Registers rows shown on npcs.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerNpcs(owner, definitions)
	return stored(owner, definitions, { types = { 'npc' } })
end

--- Registers rows shown on props.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerProps(owner, definitions)
	return stored(owner, definitions, { types = { 'prop' } })
end

--- Registers rows shown on doors.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerDoors(owner, definitions)
	return stored(owner, definitions, { types = { 'door' } })
end

--- Registers rows shown on any bare surface.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerWorld(owner, definitions)
	return stored(owner, definitions, { types = { 'world' } })
end

--- Registers rows shown on empty space; the context carries a direction, not a point.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerSky(owner, definitions)
	return stored(owner, definitions, { types = { 'sky' } })
end

--- Registers rows shown on entities of the given records.
-- @author dop42
-- @param owner string
-- @param records string[]
-- @param definitions table
-- @return Result
local function registerModels(owner, records, definitions)
	if records == nil then return Result.Err('invalid_records') end
	return stored(owner, definitions, { records = records })
end

--- Registers rows shown on the given entities only.
-- @author dop42
-- @param owner string
-- @param entities table[] each names one of playerId, vehicleId, npcId, engineEntity or propId
-- @param definitions table
-- @return Result
local function registerEntities(owner, entities, definitions)
	if entities == nil then return Result.Err('invalid_entities') end
	return stored(owner, definitions, { entities = entities })
end

--- Registers rows shown when the ray lands within one of the given spheres,
--- whatever it hit.
-- @author dop42
-- @param owner string
-- @param spheres table[] each is x, y, z and radius in metres, 0.1..10
-- @param definitions table
-- @return Result
local function registerSpheres(owner, spheres, definitions)
	if spheres == nil then return Result.Err('invalid_spheres') end
	return stored(owner, definitions, { spheres = spheres })
end

--- Changes some fields of one of the owner's rows; the answer carries its new token.
-- @author dop42
-- @param owner string
-- @param token string
-- @param patch table
-- @return Result
local function update(owner, token, patch)
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end
	local fresh, reason = Registry.Update(owner, generation, token, patch)
	if fresh == nil then return Result.Err(reason) end
	return Result.Ok({ token = fresh })
end

--- A copy of one of the owner's definitions.
-- @author dop42
-- @param owner string
-- @param token string
-- @return Result
local function get(owner, token)
	local definition, reason = Registry.Describe(owner, token)
	if definition == nil then return Result.Err(reason) end
	return Result.Ok({ token = token, definition = definition })
end

--- Removes one of the owner's rows.
-- @author dop42
-- @param owner string
-- @param token string
-- @return Result
local function unregister(owner, token)
	local ok, reason = Registry.Unregister(owner, token)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- Removes several of the owner's rows, all or none.
-- @author dop42
-- @param owner string
-- @param tokens string[]
-- @return Result
local function unregisterMany(owner, tokens)
	local ok, reason = Registry.UnregisterMany(owner, tokens)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- Removes every row of one owner.
-- @author dop42
-- @param owner string
-- @return Result
local function clear(owner)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	Registry.RemoveOwner(owner)
	return Result.Ok(true)
end

--- Switches one of the owner's rows on or off.
-- @author dop42
-- @param owner string
-- @param token string
-- @param value boolean
-- @return Result
local function setEnabled(owner, token, value)
	local ok, reason = Registry.SetEnabled(owner, token, value)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- The owner's rows, short form.
-- @author dop42
-- @param owner string
-- @return Result
local function list(owner)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	return Result.Ok({ options = Registry.List(owner) })
end

--- Switches the eye off for as long as the caller runs, or back on.
-- @author dop42
-- @param owner string
-- @param value boolean
-- @return Result
local function setTargetingEnabled(owner, value)
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end
	if type(value) ~= 'boolean' then return Result.Err('expected_boolean') end
	disabledBy[owner] = not value and generation or nil
	if not value and opened then close('provider_disabled') end
	return Result.Ok(true)
end

--- Takes the eye down.
-- @author dop42
-- @return Result
local function closeEye()
	close('provider_closed')
	return Result.Ok(true)
end

--- Whether the eye can be drawn and is up, and what the open list was built for.
-- @author dop42
-- @return Result
local function state()
	local total, owners = Registry.Size()
	return Result.Ok({
		ready = canPick(),
		open = opened,
		enabled = targetingEnabled(),
		handle = handle,
		target = selection and selection.target or nil,
		context = selection,
		rows = total,
		owners = owners,
	})
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- A setting, clamped, or the fallback when it is missing or not a number.
local function tuned(name, fallback, low, high)
	local value = tonumber(M.Settings[name])
	if value == nil or value ~= value then return fallback end
	if low ~= nil and value < low then return low end
	if high ~= nil and value > high then return high end
	return value
end

--- Reads the settings and clears every piece of held state.
-- @author dop42
function M.Init()
	local settings = M.Settings
	KEY = type(settings.KEY) == 'string' and settings.KEY ~= '' and settings.KEY or 'ALT'
	BLOCK_WEAPON_WHEEL = settings.BLOCK_WEAPON_WHEEL ~= false
	RAY_DISTANCE = tuned('RAY_DISTANCE', 12.0, 1.0, 100.0)
	MAX_OPTIONS = math.floor(tuned('MAX_OPTIONS', 32, 1, Model.MAX_TOTAL))
	HOVER_MS = math.floor(tuned('HOVER_MS', 90, 30, 1000))
	WATCH_MS = math.floor(tuned('WATCH_MS', 50, 10, 1000))
	RESOLVE_MS = math.floor(tuned('RESOLVE_MS', 25, 0, 1000))
	SWEEP_MS = math.floor(tuned('SWEEP_MS', 2000, 250, 60000))
	REVALIDATE_MS = math.floor(tuned('REVALIDATE_MS', 200, 50, 5000))
	LOOKUP_BUDGET_MS = math.floor(tuned('LOOKUP_BUDGET_MS', 1500, 100, 10000))
	-- The bound the budget lesson is written into. One is legal and slow; a large
	-- one is the failure this module was ported to keep out.
	BATCH = math.floor(tuned('BATCH', 5, 1, 16))

	opened, busy, handle, sequence, request = false, false, nil, 0, 0
	selection, listed, pending = nil, {}, nil
	armed, down = true, false
	lastPick, lastHover, nextCheck = -math.huge, -math.huge, 0
	disabledBy, liveness, jobs = {}, {}, {}
end

--- Publishes the registry and the eye's switches.
-- @author dop42
function M.Api()
	OPX.Api.Provide('target', 1, {
		Register = register,
		RegisterPlayers = registerPlayers,
		RegisterSelf = registerSelf,
		RegisterVehicles = registerVehicles,
		RegisterNpcs = registerNpcs,
		RegisterProps = registerProps,
		RegisterDoors = registerDoors,
		RegisterWorld = registerWorld,
		RegisterSky = registerSky,
		RegisterModels = registerModels,
		RegisterEntities = registerEntities,
		RegisterSpheres = registerSpheres,
		Update = update,
		Get = get,
		Unregister = unregister,
		UnregisterMany = unregisterMany,
		Clear = clear,
		SetEnabled = setEnabled,
		List = list,
		SetTargetingEnabled = setTargetingEnabled,
		Close = closeEye,
		State = state,
	})
end

--- Wires the page, claims the key and starts the two jobs.
-- @author dop42
function M.Start()
	-- The sweep runs whether or not this client can draw an eye: the registry is
	-- the half of this module that still works without a screen ray, and a stopped
	-- owner's rows must not outlive it either way.
	jobs[#jobs + 1] = OPX.Scheduler.Every('target:sweep', SWEEP_MS, sweep)

	if not canPick() then
		Open77.log.warn('this client has no screen picking: the target eye is off')
		return
	end

	-- The surface is created here rather than on the first press. It is lazy by
	-- default for a reason -- a second CEF page is not free -- but this one is
	-- reached by a key a player holds within seconds of spawning, and a first press
	-- that did nothing while the page loaded would read as a broken key.
	if OPX.UI.Interactive() == nil then
		Open77.log.error('no interactive surface: the target eye cannot be drawn')
		return
	end

	OPX.UI.On(SURFACE, 'target:hover', hover)
	OPX.UI.On(SURFACE, 'target:pick', pick)
	OPX.UI.On(SURFACE, 'target:select', choose)
	OPX.UI.On(SURFACE, 'target:cancel', function(payload)
		if opened and payload.handle == handle then close('cancelled') end
	end)

	if BLOCK_WEAPON_WHEEL then
		local blocked = OPX.Lib.Input.Block('WeaponWheel', true)
		if not blocked.ok then
			Open77.log.warn('the weapon wheel stays on the key: ' .. tostring(blocked.detail))
		end
	end

	local mapper = rawget(_G, 'RegisterKeyMapping')
	if type(mapper) == 'function' then
		local mapped, failure = pcall(mapper, KEY_ID, locale('target.key'), KEY, open)
		if not mapped then Open77.log.error('the target key was not mapped: ' .. tostring(failure)) end
	end

	AddEventHandler(EVENT_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		setDown(payload.down == true)
	end)

	-- `downed` may have raised its state before this module wired the handler, so
	-- the contract is read once. Absent, the eye simply never learns about it.
	local downed = OPX.Api.Get('downed', 1)
	if downed ~= nil and type(downed.IsDown) == 'function' then
		local read, answer = pcall(downed.IsDown)
		if read and type(answer) == 'table' and answer.ok and type(answer.value) == 'table' then
			setDown(answer.value.down == true)
		end
	end

	jobs[#jobs + 1] = OPX.Scheduler.Every('target:watch', WATCH_MS, watch)
	jobs[#jobs + 1] = OPX.Scheduler.Every('target:resolve', RESOLVE_MS, resolve)
end

--- Takes the eye down and gives the key and the controls back.
-- @author dop42
function M.Stop()
	close('module_stopped')
	for _, handleId in ipairs(jobs) do OPX.Scheduler.Cancel(handleId) end
	jobs = {}
	if BLOCK_WEAPON_WHEEL then OPX.Lib.Input.Block('WeaponWheel', false) end
end
