--- The clinic's client half: the marker at the chair, the press, and the state
-- behind the page. It decides nothing -- every frame it draws was decided
-- server-side.
-- @author XEROX710
--
-- NO KEY OPENS THE MENU. The one binding is the interaction key (press E at the
-- chair, the convention `modules/garages`, `modules/dealership` and
-- `modules/clothing` all share), and the menu itself appears the moment the
-- server says the patient is seated -- an auto-open, which is what the request
-- asked for.
--
-- The markers draw from config and gate themselves: `maxDistance` is the
-- native's own, so there is no scan loop deciding visibility and no poll cost
-- beside it. The prompt row DOES poll, at half a second, because it states
-- where the player stands -- one position read every 500 ms, the same budget
-- `modules/clothing/client/main.lua` settled on.

local M = OPX.Modules.Get('ripperdoc')
local Event = M.Event

-- What the prompts contract records as this module's own.
local OWNER = 'ripperdoc'
local GROUP = 'clinic'

-- The markers drawn for the chairs, and the chair the player is standing on.
local markers = {}
local nearest, shown = nil, false

-- Whether the key mapping answered.
local keyRegistered = false

-- Whether each failure was already logged: a marker that cannot be drawn and a
-- row that cannot be posted are different problems.
local reportedMarkers, reportedStrip = false, false

-- The scan thread's run flag, so Stop can end it.
local running = false

--- The key declaration, with the shipped value as the fallback so a config that
-- lost its KEY block still names a key.
-- @return table
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or M.Ripper.KEY
end

--- The player's own position, or nil before there is a world to read. THREE
-- NUMBERS, not a table -- `Open77.character.position()`'s own shape.
-- @return number|nil, number|nil, number|nil
local function playerXYZ()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil, nil
	end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number'
		or x ~= x or y ~= y then
		return nil, nil, nil
	end
	return x, y, z
end

--- The player's own facing in degrees, or nil. Read only when a capture is
--- asked for, because that is the only time it is used.
-- @return number|nil
local function playerYaw()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.yaw) ~= 'function' then return nil end
	local read, yaw = pcall(character.yaw)
	if not read or type(yaw) ~= 'number' or yaw ~= yaw then return nil end
	return yaw
end

--- Whether another surface holds the keyboard (the same guard `modules/clothing`
-- uses: a press while typing belongs to whatever is being typed into).
-- @return boolean
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- The key the player's own binding answers to, or nil when it is off.
-- @return string|nil
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	local lib = OPX.Lib
	if type(lib) == 'table' and type(lib.Input) == 'table' and type(lib.Input.KeyFor) == 'function' then
		local read, bound = pcall(lib.Input.KeyFor, declared.ID)
		if read and type(bound) == 'string' and bound ~= '' then return bound end
	end
	return declared.DEFAULT
end

--- Creates one marker, or answers why it could not. Never raises.
-- @param chair table
-- @return any|nil marker id
-- @return string|nil why
local function createMarker(chair)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = M.Ripper.Marker()
	local read, id, reason = pcall(api.create, {
		-- The chair's own height plus the look's lift: a marker left at floor
		-- height is co-planar with the floor and draws nothing at all.
		position = { x = chair.X, y = chair.Y, z = (chair.Z or 0) + (look.LIFT or 0) },
		shape = look.shape,
		style = look.style,
		radius = look.RADIUS,
		maxDistance = M.Ripper.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

--- Removes one marker without raising.
-- @param id any
local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

--- Brings the drawn set in line with what is in range: a chair within
--- MAX_DISTANCE has a marker, one beyond it does not. Touches nothing when the
--- set would not change -- the shape `modules/clothing/client/main.lua` keeps,
--- and for its reason too: `markers.list()` is read as the set that SHOULD
--- exist, so a chair across the city must not sit in it. `maxDistance` hides a
--- marker from players; only this bookkeeping keeps it out of the list.
-- @param inRange table chair id -> true
local function syncMarkers(inRange)
	for chairId, id in pairs(markers) do
		if not inRange[chairId] then
			removeMarker(id)
			markers[chairId] = nil
		end
	end
	for chairId in pairs(inRange) do
		if markers[chairId] == nil then
			local id, why = createMarker(M.Ripper.Chair(chairId))
			if id ~= nil then
				markers[chairId] = id
			elseif not reportedMarkers then
				reportedMarkers = true
				Open77.log.warn('[ripperdoc] the chair marker could not be drawn: ' .. tostring(why))
			end
		end
	end
end

--- The chair the player is standing on, if any -- and where the prompt row is.
local function scan()
	local x, y, z = playerXYZ()
	if x == nil then
		nearest = nil
		syncMarkers({})
		return
	end
	local reach = M.Ripper.Reach()
	local maxDistance = M.Ripper.MaxDistance()
	local best, bestAt = nil, reach * reach
	local inRange = {}
	for _, chair in ipairs(M.Ripper.Chairs()) do
		local dx = x - (chair.X or 0)
		local dy = y - (chair.Y or 0)
		local dz = (z or 0) - (chair.Z or 0)
		local at = dx * dx + dy * dy + dz * dz
		if at <= bestAt then
			best, bestAt = chair, at
		end
		if at <= maxDistance * maxDistance then
			inRange[chair.id] = true
		end
	end
	nearest = best
	syncMarkers(inRange)
end

--- Brings the prompt row in line with where the player is standing.
local function syncPrompt()
	local want = nearest ~= nil and keyLabel() ~= nil and not captured()
	if want == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the clinic, and this
		-- is said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[ripperdoc] no prompts contract; the strip row is not shown')
		end
		shown = false
		return
	end

	shown = want
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line.
			label = locale('ripperdoc.prompt'),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	if not ran then
		shown = false
		Open77.log.warn('[ripperdoc] the strip row did not post: ' .. tostring(answer))
	end
end

--- The press. The server routes it (sit or attend) -- this half only says WHICH
-- chair was pressed.
local function press()
	if captured() then return end
	scan()
	if nearest == nil then return end
	TriggerServerEvent(M.Event.USE, nearest.id)
end

--- Turns the page's five intents into server events. The page decides nothing:
-- an offer names its entry and grade, an answer names what it answers, and the
-- server re-derives all of it.
-- @param verb string
-- @param payload table
function M.Ripper.FromView(verb, payload)
	payload = type(payload) == 'table' and payload or {}
	if verb == 'offer' then
		TriggerServerEvent(M.Event.OFFER,
			tostring(payload.entry or ''), tostring(payload.grade or ''), tostring(payload.mode or 'install'))
	elseif verb == 'answer' then
		-- The offer's own id rides with the answer, so an answer to an offer
		-- that has since been replaced buys nothing.
		TriggerServerEvent(M.Event.ANSWER, tostring(payload.what or ''), payload.accept == true,
			tonumber(payload.offer))
	elseif verb == 'browse' then
		-- Local: which system or piece the page shows is the page's business,
		-- redrawn from the shared tray and the last frame, never a round trip.
		M.RipperView.Browse(payload.system, payload.piece)
	elseif verb == 'invite' then
		TriggerServerEvent(M.Event.INVITE, tonumber(payload.player) or payload.player)
	elseif verb == 'stand' then
		TriggerServerEvent(M.Event.STAND)
	elseif verb == 'close' then
		TriggerServerEvent(M.Event.CLOSE)
	end
end

-- ── the base-game chair ──────────────────────────────────────────────────
--
-- `/opx.clinic.add` asks THIS client to find the chair the operator is at,
-- because only a client has a world to look in. Two looks, best first: what
-- the crosshair is on (the engine's own look-at target), and every object
-- around the operator, scored by whether its class or name reads as a chair.
-- The winner's own position and facing come from the engine
-- (`world.entityGeometry`), so the patient is posed exactly in the chair the
-- city placed. Every candidate is written to the log -- a capture that picked
-- the wrong object is fixed by reading what else it saw.

--- The seat policy.
-- @return table
local function seatPolicy()
	return type(M.Settings.SEAT) == 'table' and M.Settings.SEAT or {}
end

--- Whether a row out of the world can never be a chair: a body, a car, a
--- door, a weapon or a loose item.
-- @param row table
-- @return boolean
local function neverAChair(row)
	local family = tostring(row.family or row.kind or '')
	return row.playerId ~= nil or row.npcId ~= nil or row.vehicleId ~= nil
		or family == 'player' or family == 'npc' or family == 'puppet' or family == 'vehicle'
		or family == 'populationNpc' or family == 'trafficVehicle' or family == 'door'
		or family == 'weapon' or family == 'item'
end

--- The chair words, lowered once per search rather than once per row.
-- @return table
local function chairWords()
	local out = {}
	local words = seatPolicy().WORDS
	for _, word in ipairs(type(words) == 'table' and words or {}) do
		if type(word) == 'string' and word ~= '' then out[#out + 1] = word:lower() end
	end
	return out
end

--- How much a candidate reads as a chair: one point per chair word in its
--- class or name.
-- @param row table
-- @param words table lowered words
-- @return integer
local function chairScore(row, words)
	local text = (tostring(row.className or row.class or '') .. ' ' .. tostring(row.name or '')):lower()
	local score = 0
	for index = 1, #words do
		if text:find(words[index], 1, true) then score = score + 1 end
	end
	return score
end

--- A number that is finite, or nil (the shared coercer).
local finiteNumber = OPX.Math.Finite

--- Everything a capture might mean, with where it came from. With `yielding`
--- the scan gives the resume back every few rows (call from a thread).
-- @param yielding boolean|nil
-- @return table candidates
local function chairCandidates(yielding)
	local out, seen = {}, {}
	local words = chairWords()
	local aimReach = finiteNumber(seatPolicy().AIM_RADIUS) or 3.0
	local function add(row, source)
		if type(row) ~= 'table' then return end
		local engine = row.engineEntity or row.engineId or row.entity
		local key = engine ~= nil and tostring(engine) or nil
		if key ~= nil and seen[key] ~= nil then
			-- Seen twice (aimed at AND around): the name the inspector lends
			-- and the aim both count for the one row.
			local known = seen[key]
			if known.name == '' and type(row.name) == 'string' then known.name = row.name end
			if source == 'aim' then known.source = 'aim' end
			known.words = chairScore({ className = known.class, name = known.name }, words)
			return
		end
		if neverAChair(row) then return end
		local candidate = {
			engine = engine, class = tostring(row.className or row.class or ''),
			name = tostring(row.name or ''), kind = tostring(row.kind or ''),
			family = tostring(row.family or ''), distance = finiteNumber(row.distance) or 99,
			position = type(row.position) == 'table' and row.position or nil, source = source,
		}
		candidate.words = chairScore(candidate, words)
		if key ~= nil then seen[key] = candidate end
		out[#out + 1] = candidate
	end
	local character = Open77.character
	if type(character) == 'table' and type(character.aimedEntity) == 'function' then
		local ran, aimed = pcall(character.aimedEntity)
		if ran and type(aimed) == 'table' then add(aimed, 'aim') end
	end
	local inspector = Open77.inspector
	if type(inspector) == 'table' and type(inspector.target) == 'function' then
		local ran, target = pcall(inspector.target)
		if ran and type(target) == 'table' and target.valid == true then
			add({ engineEntity = target.engineId, className = target.class, name = target.name,
				kind = target.kind, family = target.kind, position = target.position,
				distance = target.distance }, 'aim')
		end
	end
	local world = Open77.world
	if type(world) == 'table' and type(world.nearby) == 'function' then
		if yielding then Wait(0) end
		local radius = finiteNumber(seatPolicy().SCAN_RADIUS) or 4
		local ran, rows = pcall(world.nearby, radius)
		if ran and type(rows) == 'table' then
			for index = 1, math.min(#rows, 24) do
				if yielding and index % 6 == 0 then Wait(0) end
				add(rows[index], 'near')
			end
		end
	end
	-- WHAT COUNTS: anything whose class or name reads as a chair, and the
	-- one object the operator aims at from right beside it -- the city's
	-- ripperdoc chair does not have to call itself one, but the operator
	-- has to be at it. A door across the room is neither.
	for _, row in ipairs(out) do
		row.eligible = row.words > 0 or (row.source == 'aim' and row.distance <= aimReach)
		row.score = row.words * 10 + (row.source == 'aim' and 5 or 0)
	end
	return out
end

--- Where a candidate stands and which way it faces, from the engine.
-- @param candidate table
-- @return table|nil { x, y, z, fx, fy }
local function geometryOf(candidate)
	local world = Open77.world
	local geometry = nil
	if candidate.engine ~= nil and type(world) == 'table'
		and type(world.entityGeometry) == 'function' then
		local ran, answer = pcall(world.entityGeometry, candidate.engine)
		if ran and type(answer) == 'table' then geometry = answer end
	end
	local position = geometry ~= nil and geometry.position or candidate.position
	local forward = geometry ~= nil and geometry.forward or nil
	if forward == nil and candidate.engine ~= nil and type(Open77.character) == 'table'
		and type(Open77.character.frame) == 'function' then
		local ran, frame = pcall(Open77.character.frame, { engineEntity = candidate.engine, radius = 8 })
		if ran and type(frame) == 'table' then
			forward = frame.forward
			position = position or frame.position
		end
	end
	if type(position) ~= 'table' then return nil end
	local x, y, z = finiteNumber(position.x or position[1]), finiteNumber(position.y or position[2]),
		finiteNumber(position.z or position[3])
	if x == nil or y == nil or z == nil then return nil end
	-- A chair's origin is its floor, which is where the posture wants its
	-- device; a mesh that reports its bounds says so exactly.
	local bounds = geometry ~= nil and type(geometry.bounds) == 'table' and geometry.bounds or nil
	if bounds ~= nil and type(bounds.min) == 'table' and finiteNumber(bounds.min.z) ~= nil then
		z = math.min(z, finiteNumber(bounds.min.z))
	end
	local fx, fy = nil, nil
	if type(forward) == 'table' then
		fx, fy = finiteNumber(forward.x or forward[1]), finiteNumber(forward.y or forward[2])
	end
	return { x = x, y = y, z = z, fx = fx, fy = fy }
end

--- The chair a capture should snap to, or nil; every candidate is logged
--- either way. With `yielding`, gives the resume back as it goes (from a
--- thread only).
-- @param yielding boolean|nil
-- @return table|nil snap
-- @return table candidates
function M.Ripper.FindChair(yielding)
	local candidates = chairCandidates(yielding)
	table.sort(candidates, function(a, b)
		if a.eligible ~= b.eligible then return a.eligible end
		if a.score ~= b.score then return a.score > b.score end
		return a.distance < b.distance
	end)
	for index, row in ipairs(candidates) do
		if index > 8 then break end
		Open77.log.info(('[ripperdoc] chair candidate %d: %s %q kind=%s family=%s %.2f m via %s words=%d%s engine=%s')
			:format(index, row.class, row.name, row.kind, row.family, row.distance, row.source,
				row.words, row.eligible and '' or ' (not a chair)', tostring(row.engine)))
	end
	local best = candidates[1]
	if best == nil or not best.eligible then return nil, candidates end
	if yielding then Wait(0) end
	local geometry = geometryOf(best)
	if geometry == nil then return nil, candidates end
	local yaw = nil
	if geometry.fx ~= nil and geometry.fy ~= nil and (geometry.fx ~= 0 or geometry.fy ~= 0) then
		-- REDengine's yaw: 0 faces +y and a positive yaw turns toward -x, so
		-- a forward (fx, fy) is the yaw atan2(-fx, fy).
		yaw = math.deg(math.atan(-geometry.fx, geometry.fy)) % 360.0
	else
		-- No facing from the engine: say so, and let the server decide
		-- rather than borrowing the operator's own.
		geometry.fx, geometry.fy = nil, nil
	end
	return {
		x = geometry.x, y = geometry.y, z = geometry.z, yaw = yaw,
		fx = geometry.fx, fy = geometry.fy,
		class = best.class, name = best.name, engine = tostring(best.engine or ''),
		source = best.source, distance = best.distance,
	}, candidates
end

--- Clears every marker and the row (Init and Stop both land here).
local function clear()
	for chairId, id in pairs(markers) do
		removeMarker(id)
		markers[chairId] = nil
	end
	nearest, shown = nil, false
end

--- Resets the surface (Init and a reload both start clean).
function M.Init()
	running = false
	keyRegistered = false
	reportedMarkers, reportedStrip = false, false
	markers = {}
	nearest, shown = nil, false
end

--- Draws the chairs, declares the key, and wires the frame door.
function M.Start()
	-- The markers come from the scan below, which draws only chairs in range
	-- (see `syncMarkers`).

	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				local ran, failure = pcall(press)
				if not ran then
					Open77.log.error(('[ripperdoc] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective
		-- key, or `true, key`.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		keyRegistered = called and (ok == true or effective ~= nil)
		if not keyRegistered then
			Open77.log.warn('[ripperdoc] the key mapping was refused; the chair answers the press only')
		end
	end

	-- The frame door, before anything can arrive on it.
	RegisterNetEvent(M.Event.FRAME, function(payload)
		if type(payload) ~= 'table' then return end
		TriggerEvent(M.Event.VIEW, payload)
	end)

	-- THE CAPTURE ROUND-TRIP. A command on the server cannot know a facing, so
	-- it asks this client for one: the answer carries the heading and nothing
	-- else this half decides.
	-- The search runs on its own thread and gives the resume back as it goes:
	-- two dozen objects scored against the chair words is most of one resume.
	RegisterNetEvent(M.Event.CAPTURE, function(key, label)
		CreateThread(function()
			local yaw = playerYaw()
			local ran, snap = pcall(M.Ripper.FindChair, true)
			if not ran then
				Open77.log.warn('[ripperdoc] the chair search raised: ' .. tostring(snap))
				snap = nil
			end
			-- An empty table and not nil when nothing was found, so the server
			-- can tell "looked and found none" from a client that never looked.
			local accepted, reason = TriggerServerEvent(M.Event.CAPTURED, key, label, yaw, snap or {})
			if not accepted then
				Open77.log.warn(('[ripperdoc] the capture of %s was not answered: %s')
					:format(tostring(key), tostring(reason)))
				return
			end
			Open77.log.info(('[ripperdoc] answered the capture of %s yaw=%s snap=%s')
				:format(tostring(key), tostring(yaw),
					snap ~= nil and (snap.class .. ' ' .. snap.name) or 'none'))
		end)
	end)

	-- THE CLIENT HALF OF A DIAGNOSIS: what `open77_cyberware` on this machine
	-- reports about its own projection. An export call is a promise, so it is
	-- awaited on its own thread and answered with whatever came back.
	RegisterNetEvent(M.Event.PROBE, function(nonce)
		CreateThread(function()
			local report = {}
			local exports = Open77.exports
			if type(exports) ~= 'table' or type(exports.call) ~= 'function' then
				report.error = 'no_exports'
			else
				local ran, pending, why = pcall(exports.call, 'open77_cyberware', 'capabilities')
				if not ran or pending == nil then
					report.error = tostring((ran and why) or pending or 'no_answer')
				elseif type(pending) == 'table' and type(pending.await) == 'function' then
					local done, value, failure = pcall(pending.await, pending)
					if done and type(value) == 'table' then
						report.local_ = value.localProjection
						report.legs = value.legsProjection
						report.slam = value.slamProjection
						report.side = value.side
					else
						report.error = tostring((done and failure) or value or 'await_failed')
					end
				elseif type(pending) == 'table' then
					report.local_ = pending.localProjection
					report.legs = pending.legsProjection
				end
			end
			TriggerServerEvent(M.Event.PROBED, nonce, report)
		end)
	end)

	-- THE RECORD READER'S CLIENT HALF. The server names a batch of TweakDB
	-- record ids; this machine's live TweakDB says what each one is -- the
	-- display name in this player's language, its quality, its equipment
	-- area -- and the answer goes back for the database. Static game data:
	-- nothing about this player is read or sent.
	RegisterNetEvent(M.Event.RESOLVE, function(nonce, batch, ids)
		CreateThread(function()
			local api = type(Open77) == 'table' and Open77.data or nil
			local rows = {}
			for index, id in ipairs(type(ids) == 'table' and ids or {}) do
				if index > 80 then break end
				if type(id) == 'string' and #id <= 128 then
					local row = { record = id }
					if type(api) ~= 'table' then
						row.answer = 'no_data_api'
					else
						local value, why = nil, nil
						for _, reader in ipairs({ api.item, api.weapon }) do
							if value == nil and type(reader) == 'function' then
								local ran, answer, reason = pcall(reader, id)
								if ran and type(answer) == 'table' then value = answer
								elseif why == nil or why == 'record_wrong_kind' then
									why = ran and tostring(reason or 'record_unknown') or 'raised'
								end
							end
						end
						if value ~= nil then
							row.answer = 'ok'
							row.name, row.quality = value.displayName, value.quality
							row.area, row.itemType = value.equipArea, value.itemType
							row.localeKey, row.class = value.localeKey, value.recordClass
							if (type(row.name) ~= 'string' or row.name == '') and value.localeKey ~= nil
								and type(api.localize) == 'function' then
								local ran, text = pcall(api.localize, value.localeKey)
								if ran and type(text) == 'string' then row.name = text end
							end
						else
							row.answer = why or 'record_unknown'
						end
					end
					rows[#rows + 1] = row
				end
				-- A native read per id: a handful per resume.
				if index % 6 == 0 then Wait(0) end
			end
			TriggerServerEvent(M.Event.RESOLVED, nonce, batch, rows)
		end)
	end)

	-- The recorder's switch, from `/opx.clinic.record`.
	RegisterNetEvent(M.Event.RECORD, function(mode)
		if M.Recorder ~= nil then M.Recorder.Command(tostring(mode or 'on')) end
	end)

	-- The captured chairs, merged into the list the scan draws from. Asked for
	-- once at start so the first scan has them, and re-sent by the server after
	-- every capture or removal.
	-- Applied on a thread, a few rows per resume: every captured chair is
	-- checked again here, and a clinic-heavy server's list is more than one
	-- resume's work. A newer list supersedes one still being applied.
	local chairsGeneration = 0
	RegisterNetEvent(M.Event.CHAIRS, function(rows)
		chairsGeneration = chairsGeneration + 1
		local mine = chairsGeneration
		CreateThread(function()
			local checked = {}
			for index, row in ipairs(type(rows) == 'table' and rows or {}) do
				checked[index] = row
			end
			local accepted = M.Ripper.CheckCaptured(checked, 6)
			if mine ~= chairsGeneration then return end
			M.Ripper.Captured = accepted
			Open77.log.info(('[ripperdoc] %d captured chair(s) received'):format(#accepted))
			Wait(0)
			scan()
		end)
	end)
	TriggerServerEvent(M.Event.ASK)

	-- THE TRAY IS BUILT BEFORE IT IS NEEDED, a few rows per resume: the page
	-- is laid out from it, and building a hundred-odd pieces in the resume
	-- that draws the first frame would be the resume that dies doing it.
	CreateThread(function() M.Ripper.WarmCatalog(3) end)

	-- The page's intents come through the view seam into `FromView`.
	M.RipperView.Start()
	if M.Recorder ~= nil then M.Recorder.Start() end

	-- The scan: one position read per pass, at clothing's own half-second.
	running = true
	CreateThread(function()
		while running do
			local ran, failure = pcall(function()
				scan()
				syncPrompt()
			end)
			if not ran then
				Open77.log.warn('[ripperdoc] the scan raised: ' .. tostring(failure))
			end
			Wait(500)
		end
	end)
end

--- Takes the surface down with the module.
function M.Stop()
	running = false
	if M.Recorder ~= nil then M.Recorder.Stop() end
	M.RipperView.Stop()
	local api = OPX.Api.Get('prompts')
	if api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	clear()
end
