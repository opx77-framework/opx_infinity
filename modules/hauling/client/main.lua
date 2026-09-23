--- Client half: three target rows, three bars, and no loop of its own.
-- @author dop42
--
-- A ROW ONLY EVER ASKS. The server finds the crate again from its own registry
-- and its own reading of where the player is standing; nothing drawn here is
-- believed by anything.
--
-- ============================================================================
-- THERE IS NO PERIODIC JOB IN THIS FILE, AND THAT IS THE DESIGN
-- ============================================================================
--
-- `core/client/scheduler.lua`'s header spells out why it matters. The platform
-- gives Lua 2000 microseconds a frame DIVIDED BY THE NUMBER OF RUNNING
-- RESOURCES, floor 50. This runtime is ONE resource, so all twenty-odd modules
-- share one slice and the scheduler runs at most four jobs per resume. A loop
-- that raises the instruction budget does not crash and does not log -- it
-- unwinds out of the coroutine body and IS NEVER RESUMED AGAIN, for the session.
-- A hauling job that quietly stopped offering rows halfway through an evening is
-- almost always that.
--
-- So the rows are registered ONCE, in `Start`, and never touched again. The three
-- `canInteract` predicates are table lookups against what the server pushed. No
-- sort, no scan, no distance pass -- and in particular not `nearbyDrops`'
-- sort-every-pass from `modules/inventory/client/world.lua:91-102`, which is fine
-- at one player's inventory scale and is not fine at a multi-site job's.
--
-- PROXIMITY IS THE SERVER'S JOB. It is free there -- one read of a position it
-- already holds -- and it is authoritative, which the client's answer could never
-- be. The rows draw; the server decides.
--
-- ============================================================================
-- WHICH ROW THE CRATE IS DRAWN UNDER, AND WHY THIS ONE
-- ============================================================================
--
-- `TARGET_KIND = 'prop'` is the default and what this ships as. The screen ray
-- reports what it hit as `context.target`, and the op77.76 card for
-- `Open77.camera.screenRaycast` says in as many words that `target` distinguishes
-- "canonical playerId, vehicleId, npcId and propId; propId is a decimal string".
-- `canonical` is the platform's own word for a server-owned entity -- the same
-- word its NPC and vehicle pages use -- and a server-owned prop's id IS a decimal
-- string. `modules/target/shared/model.lua:20-21` already lists `prop` as a kind
-- and `:164-165` already validates a `propId` as a decimal string, and
-- `registerProps` has been sitting in `modules/target/client/main.lua:725-734`
-- the whole time. So: ONE row, registered once, `canInteract` a lookup in a table
-- the server keeps up to date. Constant work per pick and no job at all.
--
-- WHAT IS NOT PROVEN is that the engine's physical pick returns a hit on a server
-- prop's collider at all -- that cannot be settled without standing in front of
-- one, and this repository has no way to do that. `TARGET_KIND = 'world'` is the
-- fallback if it turns out not to: one `RegisterWorld` row whose predicate
-- matches the HIT POINT against the crate positions the server pushed. Still one
-- row, still no job, and the player aims at the ground beside the crate rather
-- than at the crate.
--
-- `RegisterSpheres` is the design this deliberately does NOT use. It is a
-- per-pass proximity computation with `MAX_LIST = 32` spheres to a row, so a busy
-- site needs several rows re-registered on every single pickup -- which is
-- exactly the churn the budget above cannot afford.

local M = OPX.Modules.Get('hauling')
local Access, Step, Where = M.Access, M.Step, M.Where

-- The name this module registers its target rows under. The module id, which the
-- target registry reads as an owner that is always live.
local OWNER = 'hauling'

-- Every crate the server has told this client about, by prop id.
local crates = {}

-- Crates arriving in parts, gathered until the part marked `done`.
local incoming = nil

-- The crate this client is holding, as the server last said. NEVER inferred from
-- a successful request: the answer to every request carries it, so a refusal
-- corrects a client that had drifted.
local carrying = nil

-- The seller NPCs, by id as a decimal string. Pushed by the server whole.
local sellers = {}

-- Arrow marker handles, by crate id. A crate has one exactly while it stands free
-- on its point.
local arrows = {}
local arrowCount = 0
local arrowsNoted = false

-- The tokens the target rows were registered under, so `Stop` can take them back.
local tokens = {}

-- The contracts this half uses, read once in `Start`.
local target, progress = nil, nil

-- Whether a bar this module started is up, and what it was for. One at a time,
-- because the server only tracks one step per player.
local bar = nil

--- Whether a value is a decimal-string prop id, which is the only shape the
--- platform ever hands one out in. `tonumber` is never applied to one: they are
--- 64-bit and would not survive it.
local function propId(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^[1-9]%d*$') == nil then return nil end
	return value
end

--- The squared distance between a hit point and a crate's own point.
local function gapSquared(at, crate)
	if type(at) ~= 'table' then return nil end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil then return nil end
	local dx, dy, dz = x - crate.x, y - crate.y, z - crate.z
	return dx * dx + dy * dy + dz * dz
end

--- The crate a pick landed on, in whichever mode this client is running.
--
-- In `prop` mode this is a single table lookup and costs nothing. In `world` mode
-- it walks the crate list ONCE, on a pick -- which is a keypress and not a frame,
-- so it is the one place a scan is affordable.
local function picked(context, wanted)
	if type(context) ~= 'table' then return nil end

	if Access.TARGET_KIND == 'prop' then
		local hit = type(context.target) == 'table' and context.target or nil
		if hit == nil then return nil end
		local id = propId(hit.propId)
		if id == nil then return nil end
		local crate = crates[id]
		if crate == nil or crate.where ~= wanted then return nil end
		return crate
	end

	local at = context.position
	local best, bestGap = nil, Access.REACH_SQ
	for _, crate in pairs(crates) do
		if crate.where == wanted then
			local gap = gapSquared(at, crate)
			if gap ~= nil and gap <= bestGap then best, bestGap = crate, gap end
		end
	end
	return best
end

--- Asks the server to begin a step. It may refuse; the answer says so.
local function ask(step, subject)
	TriggerServerEvent(M.Event.BEGIN, step, subject)
end

--- Whether this client may be offered a pickup on what the ray hit.
local function canPickUp(context)
	if carrying ~= nil then return false end
	return picked(context, Where.GROUND) ~= nil
end

--- The seller NPC the ray hit, as the decimal string the server keyed it by.
local function seller(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return nil end
	local id = math.tointeger(context.target.npcId)
	if id == nil then return nil end
	local key = ('%d'):format(id)
	if sellers[key] == nil then return nil end
	return key
end

--- Whether this client may be offered a sale on what the ray hit.
-- What there is to sell is the server's to count -- the bag and every trunk
-- parked at the drop-off -- so an empty-handed player is offered the row and
-- told `no_crates`, which is the right failure.
local function canSell(context)
	if carrying ~= nil then return false end
	return seller(context) ~= nil
end

--- Whether this client may be offered a load on the vehicle it is looking at.
local function canLoad(context)
	if carrying == nil then return false end
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return false end
	return context.target.vehicleId ~= nil
end

local function onPickUp(context)
	local crate = picked(context, Where.GROUND)
	if crate == nil then return end
	ask(Step.PICKUP, crate.id)
end

local function onSell(context)
	local key = seller(context)
	if key == nil then return end
	ask(Step.DELIVER, key)
end

local function onLoad(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return end
	local vehicleId = context.target.vehicleId
	if vehicleId == nil then return end
	ask(Step.LOAD, vehicleId)
end

--- Registers the rows, once.
--
-- ONE CALL PER SHAPE AND NEVER AGAIN. The id-set changes constantly -- every
-- pickup, every delivery, every refill pass -- and NOT ONE of those changes
-- re-registers anything, because the rows do not name crates: they name a kind,
-- and the predicate reads the table. That is the whole reason this design was
-- worth answering the target-eye question for.
local function registerRows()
	if target == nil then return end

	local crateRows = {
		{
			id = 'hauling.pickup',
			label = locale('hauling.row.pickup'),
			description = locale('hauling.row.pickupHint'),
			icon = 'box',
			distance = Access.REACH,
			canInteract = canPickUp,
			onSelect = onPickUp,
			-- The thing itself: a crate on the floor is what the player walked up to.
			order = 5,
		},
	}

	local rows = Access.TARGET_KIND == 'world'
		and target.RegisterWorld(OWNER, crateRows)
		or target.RegisterProps(OWNER, crateRows)
	if rows.ok and type(rows.value.tokens) == 'table' then
		for _, token in ipairs(rows.value.tokens) do tokens[#tokens + 1] = token end
	else
		OPX.Note('hauling', ('the crate rows were refused: %s')
			:format(tostring(rows.error)))
	end

	local load = target.RegisterVehicles(OWNER, {
		id = 'hauling.load',
		label = locale('hauling.row.load'),
		icon = 'vehicle',
		distance = Access.VEHICLE_REACH,
		canInteract = canLoad,
		onSelect = onLoad,
		order = 4,
	})
	if load.ok then
		tokens[#tokens + 1] = load.value.token
	else
		OPX.Note('hauling', ('the load row was refused: %s'):format(tostring(load.error)))
	end

	local sell = target.RegisterNpcs(OWNER, {
		id = 'hauling.sell',
		label = locale('hauling.row.sell'),
		icon = 'money',
		distance = Access.VEHICLE_REACH,
		canInteract = canSell,
		onSelect = onSell,
		order = 4,
	})
	if sell.ok then
		tokens[#tokens + 1] = sell.value.token
	else
		OPX.Note('hauling', ('the sell row was refused: %s'):format(tostring(sell.error)))
	end
end

-- ── the arrows over free crates ─────────────────────────────────────────────
--
-- The owner: "si ont peux les faire pop au dessus des caisse pour savoir que ces
-- caisse la peuvent etre ramasser". STILL NO LOOP: an arrow is made or taken down
-- by the same crate delta that changes the row's answer, and the platform hides
-- it past MAX_DISTANCE on its own.

--- Says once why no arrow is drawn; a line per crate would be a line per refill.
local function noteArrows(why)
	if arrowsNoted then return end
	arrowsNoted = true
	OPX.Note('hauling', ('no arrow over the crates: %s'):format(tostring(why)))
end

--- Takes a crate's arrow down, if it has one.
local function unmark(id)
	local handle = arrows[id]
	if handle == nil then return end
	arrows[id] = nil
	arrowCount = arrowCount - 1
	local api = Open77.markers
	if type(api) == 'table' and type(api.remove) == 'function' then pcall(api.remove, handle) end
end

--- Puts an arrow over a crate that stands free, and takes it off one that does not.
local function mark(crate)
	if crate.where ~= Where.GROUND then return unmark(crate.id) end
	local look = Access.MARKER
	if look == nil or arrows[crate.id] ~= nil then return end
	if arrowCount >= look.max then return noteArrows('MARKER.MAX reached') end
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return noteArrows('world.markers is unavailable')
	end
	local called, handle, why = pcall(api.create, {
		position = { x = crate.x, y = crate.y, z = crate.z + look.lift },
		shape = look.shape,
		style = look.style,
		color = look.color,
		radius = look.radius,
		height = look.height,
		maxDistance = look.maxDistance,
	})
	if not called or handle == nil then
		local reason = called and why or handle
		-- NOT A FAULT, A MOMENT. The crates arrive with the first hello, which is
		-- before the world exists; every arrow was refused `world_unavailable` and
		-- nothing asked again until a crate changed. The owner: "la fleche ne
		-- aparait que une fois que l'ont as pris puis et reposer". `remarkAll` on
		-- world ready is the second asking.
		if reason ~= 'world_unavailable' then noteArrows(reason) end
		return
	end
	arrows[crate.id] = handle
	arrowCount = arrowCount + 1
end

--- Takes every arrow down.
local function unmarkAll()
	for id in pairs(arrows) do unmark(id) end
	arrows, arrowCount = {}, 0
end

--- Draws every arrow that should be up and is not. For when the world arrives.
local function remarkAll()
	for _, crate in pairs(crates) do mark(crate) end
end

-- ── hands full ──────────────────────────────────────────────────────────────
--
-- The owner: "si ont porte le truc on puisse pas frapper n'y utiliser un item
-- inv". The server holsters the weapon at pickup and the inventory refuses item
-- use; this stops the weapon coming back out. `Attack` (firing) is marked
-- INFERRED by the platform and `Melee` is not blockable at all on 2.31, so a
-- bare-handed swing is the one thing left and nothing here can refuse it.
local HANDS_FULL = { 'Attack', 'WeaponWheel' }
local handsBlocked = false

--- Claims or releases the two actions, only on a change.
local function blockHands(on)
	if handsBlocked == on then return end
	handsBlocked = on
	local input = Open77.input
	if type(input) ~= 'table' or type(input.setActionBlocked) ~= 'function' then return end
	for _, action in ipairs(HANDS_FULL) do
		local called, ok, why = pcall(input.setActionBlocked, action, on)
		if on and (not called or ok ~= true) then
			OPX.Note('hauling', ('%s could not be blocked while carrying: %s')
				:format(action, tostring(called and why or ok)))
		end
	end
end

--- Puts one crate into the local list, or takes it out.
local function keep(row)
	if type(row) ~= 'table' then return end
	local id = propId(row.id)
	if id == nil then return end
	local crate = { id = id, site = tostring(row.site or ''),
		x = tonumber(row.x) or 0.0, y = tonumber(row.y) or 0.0, z = tonumber(row.z) or 0.0,
		bucket = tonumber(row.bucket) or 0, where = tostring(row.where or Where.GROUND) }
	crates[id] = crate
	mark(crate)
end

--- Takes the bar down, whatever is holding it up.
local function dropBar()
	if bar == nil or progress == nil then return end
	bar = nil
	pcall(progress.Stop, OWNER, nil)
end

--- The key actually bound to the drop, as the host answered it.
local dropKey = nil

--- Puts the carried crate down. The server decides; this only asks.
-- The owner: "pendant qu'on carry ont peux faire x pour la drop".
local function onDropKey()
	if carrying == nil then return end
	-- A key typed into a text field is not a key pressed in the world.
	local input = Open77.input
	if type(input) == 'table' and type(input.isCaptured) == 'function' then
		local read, taken = pcall(input.isCaptured)
		if read and taken == true then return end
	end
	-- A load bar under way ends here: the crate is going on the floor instead.
	dropBar()
	local yaw, groundZ = nil, nil
	local character = Open77.character
	if type(character) == 'table' and type(character.yaw) == 'function' then
		local read, value = pcall(character.yaw)
		if read and type(value) == 'number' then yaw = value end
	end
	-- THE FLOOR WHERE IT WILL LAND. The server has no physics and put the crate at
	-- the player's own height, which is not the floor. Cast from just above the
	-- player's head, not from the sky, so a roof or a balcony over them is not the
	-- ground. `Open77.character.position()` answers three numbers.
	if yaw ~= nil and type(character) == 'table' and type(character.position) == 'function'
		and type(Open77.world) == 'table' and type(Open77.world.groundZ) == 'function' then
		local read, x, y, z = pcall(character.position)
		if read and type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
			local radians = math.rad(yaw)
			local dx = x - math.sin(radians) * Access.DROP_DISTANCE
			local dy = y + math.cos(radians) * Access.DROP_DISTANCE
			local cast, ground = pcall(Open77.world.groundZ, dx, dy, z + 1.0)
			if cast and type(ground) == 'number' then groundZ = ground end
		end
	end
	TriggerServerEvent(M.Event.DROP, { yaw = yaw, z = groundZ })
end

--- Binds the drop key, once. A refusal costs the key and nothing else.
local function registerDropKey()
	if type(RegisterKeyMapping) ~= 'function' then
		return OPX.Note('hauling', 'this host has no RegisterKeyMapping: a crate cannot be put down')
	end
	local called, ok, answer = pcall(RegisterKeyMapping, 'hauling_drop',
		locale('hauling.key.drop'), Access.DROP_KEY, onDropKey)
	if not called or (ok ~= true and type(ok) ~= 'string') then
		return OPX.Note('hauling', ('the drop key was refused: %s')
			:format(tostring(called and answer or ok)))
	end
	dropKey = type(ok) == 'string' and ok ~= '' and ok
		or (type(answer) == 'string' and answer ~= '' and answer) or Access.DROP_KEY
end

--- Wires the rows, the wire and the bar. No job is registered here on purpose.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	progress = OPX.Api.Get('progress')

	if target == nil then
		-- The eye IS the entry to this job -- there is no command and no key. Without
		-- it there is nothing to draw and nothing to press, and saying so once is
		-- better than a client that looks like it is working.
		OPX.Note('hauling', 'the target eye is not available, so there is no way into this job')
		return
	end

	registerRows()
	registerDropKey()

	-- The crates can land before the world does; their arrows are asked again here.
	AddEventHandler(OPX.Host.WORLD_READY, remarkAll)
	AddEventHandler(OPX.Host.GAMEPLAY_READY, remarkAll)

	RegisterNetEvent(M.Event.SNAPSHOT, function(part)
		if type(part) ~= 'table' then return end
		if part.first then incoming = {} end
		if incoming == nil then return end
		if type(part.crates) == 'table' then
			for _, row in ipairs(part.crates) do incoming[#incoming + 1] = row end
		end
		if not part.done then return end
		-- SWAPPED WHOLE, and only once the last part has landed. A list rebuilt
		-- part by part is a list that is briefly missing most of its crates, and a
		-- pick during that window would offer nothing on a crate that is right there.
		crates = {}
		unmarkAll()
		for _, row in ipairs(incoming) do keep(row) end
		incoming = nil
	end)

	RegisterNetEvent(M.Event.CRATE, function(row)
		keep(row)
	end)

	RegisterNetEvent(M.Event.SELLERS, function(list)
		if type(list) ~= 'table' then return end
		local fresh = {}
		for _, row in ipairs(list) do
			if type(row) == 'table' and type(row.npc) == 'string' and row.npc:match('^%d+$') then
				fresh[row.npc] = { site = tostring(row.site or ''), dropoff = tostring(row.dropoff or '') }
			end
		end
		sellers = fresh
	end)

	RegisterNetEvent(M.Event.GONE, function(id)
		local key = propId(id)
		if key ~= nil then
			crates[key] = nil
			unmark(key)
		end
	end)

	RegisterNetEvent(M.Event.ANSWER, function(ok, reason, held)
		local was = carrying
		carrying = propId(held) or nil
		blockHands(carrying ~= nil)
		-- Said once per carry, the moment it starts: the key is no use unknown.
		if was == nil and carrying ~= nil and dropKey ~= nil then
			OPX.Toast.Locale('hauling.hint.drop', { key = dropKey }, 'info', 'box')
		end
		if not ok then
			dropBar()
			-- Every verdict goes on the public bus, refusals included: a HUD or a
			-- third party that wants to say something about a refused pickup reads
			-- this and does not have to guess from a toast.
			TriggerEvent(M.Event.ON_DECISION, { ok = false, reason = reason,
				carrying = carrying })
			if type(reason) == 'string' and reason ~= '' then
				-- THE KEY IS CHECKED BEFORE IT IS SHOWN. `locale` answers the KEY
				-- ITSELF for a string nobody wrote, which is the right behaviour for a
				-- log line and is `hauling.refused.invalid_attachment_bone` on a
				-- player's screen. Several refusals here come straight from the host --
				-- the `Open77.props.attach` reason set is eleven codes long and grows
				-- with the platform -- so there will never be a key for all of them.
				local key = 'hauling.refused.' .. reason
				if not OPX.Locale.Exists(key) then key = 'hauling.refused.generic' end
				OPX.Toast.Locale(key, nil, 'error', 'box')
			end
			return
		end
		TriggerEvent(M.Event.ON_DECISION, { ok = true, carrying = carrying })
	end)

	RegisterNetEvent(M.Event.RUN, function(spec)
		if type(spec) ~= 'table' or progress == nil then return end
		local durationMs = tonumber(spec.durationMs)
		if durationMs == nil or durationMs <= 0 then return end
		bar = tostring(spec.step)
		-- THE BAR IS PRESENTATION AND THE SERVER HOLDS THE CLOCK. This client counts
		-- down and then reports; the server refuses a report that arrived sooner
		-- than its own stamp allows, so shortening this bar buys nothing.
		local shown = progress.Start(OWNER, {
			label = locale('hauling.bar.' .. tostring(spec.step)),
			durationMs = durationMs,
			cancelable = true,
		})
		if type(shown) == 'table' and shown.ok ~= true then
			bar = nil
			TriggerServerEvent(M.Event.ABORT, 'no_bar')
			OPX.Note('hauling', ('the bar was refused: %s'):format(tostring(shown.error)))
		end
	end)

	-- The bar's own outcome. Only `finished` means the action happened; every
	-- other ending is the action NOT happening and must reach the server as an
	-- abort, or the claim sits there until the reap pass takes it.
	AddEventHandler(OPX.Modules.Get('progress').Event.ON_DONE, function(outcome)
		if type(outcome) ~= 'table' or outcome.owner ~= OWNER then return end
		if bar == nil then return end
		bar = nil
		if outcome.finished then
			TriggerServerEvent(M.Event.FINISH)
		else
			TriggerServerEvent(M.Event.ABORT, tostring(outcome.ending))
		end
	end)

	-- A character arriving is the moment this client needs the crate list: the
	-- first hello in `Start` is before there is anybody in the world, and a player
	-- who swaps character keeps this VM and would otherwise keep the old list.
	AddEventHandler(OPX.Modules.Get('character').Event.ON_LOADED, function()
		TriggerServerEvent(M.Event.HELLO)
	end)

	TriggerServerEvent(M.Event.HELLO)
end

--- Takes the rows back and drops any bar this module put up.
-- @author dop42
function M.Stop()
	dropBar()
	if target ~= nil then
		for _, token in ipairs(tokens) do pcall(target.Unregister, OWNER, token) end
	end
	tokens = {}
	unmarkAll()
	blockHands(false)
	crates = {}
	sellers = {}
	carrying = nil
end
