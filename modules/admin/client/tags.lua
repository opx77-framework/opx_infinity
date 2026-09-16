--- Staff name tags: who is nearby, what they are called, and where the tag sits.
-- @author dop42
--
-- The name list is the one thing a client cannot work out for itself, and the
-- server sends it only to a player the ACL grants `opx.admin.self.tags`. Nothing
-- here asks for it: it arrives, and it stops arriving the moment the grant does.
--
-- The pass is registered with `OPX.Scheduler` and never spawned as a loop of its
-- own: exceeding the per-resume instruction budget unwinds out of a coroutine
-- body and a `while true ... Wait(n)` loop that hits it is never resumed again,
-- silently. It returns at once while the tags are off.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

M.Tags = {}
local Tags = M.Tags

-- The client store key the switch is remembered under.
local KVP_KEY = 'opx.admin.tags.shown'

-- Anchors the platform allows one resource, which bounds how many tags a view
-- can be asked to draw at once.
local ANCHOR_LIMIT = 32

-- Metres past the configured distance a player is looked at early, so a tag is
-- ready the moment they come into range rather than a pass later.
local CULL_MARGIN = 1.5

-- Times a saved switch is asked back, and the wait before each ask. The server
-- half may not be listening the instant this client starts.
local RESTORE_TRIES, RESTORE_DELAY_MS = 3, 5000

-- Whether the server last said this operator's tags are on, and whether it has
-- said anything at all since this module started.
local shown, answered = false, false

-- Names by player id from the server, and a list still arriving.
local known, incoming = {}, {}

-- Whether the player is down, in which case no tag is drawn.
local down = false

-- The settings, read once at start.
local tuning = {}

-- The signature of the rows last published, so an unchanged frame is not sent.
local published

-- The scheduler handle, and how many restore attempts are left.
local job, restoresLeft = nil, 0

-- Problems already logged, one line each.
local reported = {}

local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	Open77.log.warn('[admin] ' .. message)
end

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state machine and nothing else: no surface is created
-- here, and there is no tags module under `ui/src/modules/` yet. Everything it
-- has to say to whatever draws the tags leaves on `M.Event.ON_TAGS`, and a view
-- module attaches by listening to it with a bare `AddEventHandler`.
--
-- A view for this belongs on the OVERLAY surface (`OPX.UI.Send('overlay', ...)`)
-- and must never take focus: a name tag that captured the keyboard would stop the
-- player moving. It draws each row against a world anchor -- `Open77.anchors`,
-- with the overlay surface as the anchor's page -- and nothing else.
--
-- Three kinds go out:
--   'config'  once, and again on every switch-on: the colours, whether the id
--             square is drawn, and the word a staff badge carries
--   'rows'    the tags to draw now: one row per player, with the entity to
--             follow, the metres above its origin, and the fade
--   'hide'    every tag comes down

--- Tells the view something.
-- @author dop42
-- @param kind string 'config', 'rows' or 'hide'
-- @param payload table|nil
local function publish(kind, payload)
	payload = payload or {}
	payload.kind = kind
	TriggerEvent(M.Event.ON_TAGS, payload)
end

-- ── the state ───────────────────────────────────────────────────────────────

--- Whether this operator's name tags are on, for the menu row and the eye.
-- @author dop42
-- @return boolean
function Tags.IsShown()
	return shown
end

-- A configured number inside its range, or the fallback.
local function setting(value, fallback, low, high)
	local number = Text.Finite(value)
	if number == nil or number < low or number > high then return fallback end
	return number
end

-- A configured #RRGGBB colour, or the fallback.
local function colour(value, fallback)
	if type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') then return value:upper() end
	return fallback
end

-- Fades a tag over the far part of the distance, in tenths, so the view is not
-- asked to redraw for a hundredth of an alpha.
local function alphaFor(distance)
	local start = tuning.distance * tuning.fadeStart
	local alpha = 1.0
	if distance > start and tuning.distance > start then
		alpha = math.max(0.0, 1.0 - (distance - start) / (tuning.distance - start))
	end
	return math.floor(alpha * 10 + 0.5) / 10
end

-- Metres from a body's origin to just above its head slot.
local function headOffset(entity, position)
	local character = Open77.character
	if type(character) ~= 'table' or type(character.bonePosition) ~= 'function'
		or type(position) ~= 'table' then
		return tuning.headOffset
	end
	local read, head, reason = pcall(character.bonePosition, entity, 'head')
	if not read or type(head) ~= 'table' then
		-- A body that is not attached yet, and a build with no head bone, are both
		-- ordinary; anything else is worth one line.
		if read and reason ~= 'unknown_bone' and reason ~= 'entity_not_attached' then
			warnOnce('head', ('name tags cannot read the head slot (%s): using TAGS.HEAD_OFFSET_Z')
				:format(tostring(reason)))
		end
		return tuning.headOffset
	end
	local headZ, bodyZ = Text.Finite(head.z), Text.Finite(position.z)
	if headZ == nil or bodyZ == nil then return tuning.headOffset end
	local offset = headZ - bodyZ + tuning.headLift
	if offset < 0.5 or offset > 3.0 then return tuning.headOffset end
	return offset
end

-- Whether the view in force is third person, nil when it cannot be read.
local function thirdPerson()
	local perspective = Open77.perspective
	if type(perspective) ~= 'table' or type(perspective.get) ~= 'function' then return nil end
	local read, mode = pcall(perspective.get)
	if not read or type(mode) ~= 'string' then return nil end
	return mode == 'tps'
end

-- Sends the view the configuration it draws with.
local function publishConfig()
	publish('config', {
		distance = tuning.distance,
		fadeStart = tuning.fadeStart,
		technical = tuning.technical,
		staffLabel = locale('admin.tags.staff'),
		colors = { text = tuning.text, accent = tuning.accent, staff = tuning.staff,
			background = tuning.background },
	})
end

-- One pass: works out the tags to draw and publishes them when they changed.
local function pass()
	if not shown then return end
	local players = Open77.players
	if type(players) ~= 'table' or type(players.nearby) ~= 'function' then
		return warnOnce('nearby', 'Open77.players.nearby is not on this client: name tags cannot ' ..
			'be drawn')
	end

	local third = thirdPerson()
	local rows = {}
	if not down and not (tuning.hideFirstPerson and third == false) then
		local read, entries = pcall(players.nearby, tuning.distance + CULL_MARGIN,
			{ includeSelf = tuning.own, limit = tuning.max })
		for _, entry in ipairs(read and type(entries) == 'table' and entries or {}) do
			local id = type(entry) == 'table' and tonumber(entry.playerId) or nil
			local row = id and known[id] or nil
			local distance = row and Text.Finite(entry.distance) or nil
			-- The local player's own tag is only drawn in third person: in first
			-- person it would sit in the middle of the screen.
			if distance and entry.entity ~= nil and (entry.isLocal ~= true or third == true) then
				rows[#rows + 1] = {
					playerId = id,
					entity = entry.entity,
					name = row.name,
					staff = row.staff == true,
					offsetZ = headOffset(entry.entity, entry.position),
					alpha = alphaFor(distance),
				}
			end
		end
	end
	table.sort(rows, function(left, right) return left.playerId < right.playerId end)

	local parts = {}
	for index, row in ipairs(rows) do
		parts[index] = ('%d\t%s\t%s\t%d\t%.2f\t%.1f'):format(row.playerId, tostring(row.entity),
			row.name, row.staff and 1 or 0, row.offsetZ, row.alpha)
	end
	local signature = table.concat(parts, '\n')
	if signature == published then return end
	published = signature
	publish('rows', { rows = rows })
end

-- Saves the switch on this machine for this server.
local function remember(on)
	local kvp = Open77.kvp
	if type(kvp) ~= 'table' or type(kvp.set) ~= 'function' then
		return warnOnce('kvp', 'Open77.kvp is not on this client: the name tag switch lasts this ' ..
			'session only')
	end
	local called, ok, reason = pcall(kvp.set, KVP_KEY, on)
	if not called or not ok then
		warnOnce('kvpSet', ('the name tag switch was not saved: %s')
			:format(tostring(called and reason or ok)))
	end
end

-- Asks the server to turn the tags back on, a few times, and gives up quietly.
-- The grant is re-checked there: the stored preference is this client's word.
local function restorePass()
	if answered or restoresLeft <= 0 then return end
	restoresLeft = restoresLeft - 1
	TriggerServerEvent(M.Event.TAGS_RESTORE)
end

--- Reads the settings, wires the two events and registers the pass.
-- @author dop42
function Tags.Start()
	local settings = M.Section('TAGS')
	local colors = type(settings.COLORS) == 'table' and settings.COLORS or {}
	tuning = {
		distance = setting(settings.DISTANCE, 25.0, 1.0, 100.0),
		fadeStart = setting(settings.FADE_START, 0.55, 0.0, 1.0),
		headLift = setting(settings.HEAD_LIFT, 0.35, 0.0, 2.0),
		headOffset = setting(settings.HEAD_OFFSET_Z, 2.05, 0.5, 3.0),
		updateMs = math.floor(setting(settings.UPDATE_MS, 250, 50, 2000)),
		max = math.floor(setting(settings.MAX, ANCHOR_LIMIT, 1, ANCHOR_LIMIT)),
		own = settings.OWN == true,
		hideFirstPerson = settings.HIDE_IN_FIRST_PERSON == true,
		technical = settings.TECHNICAL ~= false,
		text = colour(colors.TEXT, '#F2F6F8'),
		accent = colour(colors.ACCENT, '#FCEE0A'),
		staff = colour(colors.STAFF, '#22D8E2'),
		background = colour(colors.BACKGROUND, '#0A1220'),
	}

	RegisterNetEvent(M.Event.TAGS_STATE, function(on, persist)
		answered = true
		shown = on == true
		if persist == true then remember(shown) end
		if shown then
			published = nil
			publishConfig()
		else
			known, incoming, published = {}, {}, nil
			publish('hide')
		end
		M.Menu.Refresh()
	end)

	RegisterNetEvent(M.Event.TAG_ROWS, function(payload)
		if not shown or type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then incoming = {} end
		for _, entry in ipairs(payload.rows) do
			local id = tonumber(type(entry) == 'table' and entry.id or nil)
			if id and type(entry.name) == 'string' then
				incoming[id] = { name = Text.Bytes(entry.name, 192), staff = entry.staff == true }
			end
		end
		-- Swapped whole, never merged: a list that arrived in pieces and was
		-- applied in pieces would tag a player who has just left.
		if payload.done ~= true then return end
		known, incoming = incoming, {}
	end)

	AddEventHandler(M.Event.ON_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		down = payload.down == true
	end)

	job = OPX.Scheduler.Every('admin.tags', tuning.updateMs, pass)

	local kvp = Open77.kvp
	if type(kvp) ~= 'table' or type(kvp.get) ~= 'function' then return end
	local read, saved = pcall(kvp.get, KVP_KEY, false)
	if not read or saved ~= true then return end
	restoresLeft = RESTORE_TRIES
	OPX.Scheduler.Every('admin.tags.restore', RESTORE_DELAY_MS, restorePass)
end

--- Takes every tag down and forgets the list.
-- @author dop42
function Tags.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	shown = false
	known, incoming, published = {}, {}, nil
	publish('hide')
end
