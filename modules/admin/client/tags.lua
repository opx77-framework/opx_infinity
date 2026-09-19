--- Staff name tags: who is nearby, what they are called, and where the tag sits.
-- @author dop42
--
-- The ACCOUNT list is the one thing a client cannot work out for itself, and the
-- server sends it only to a player the ACL grants `opx.admin.self.tags`. Nothing
-- here asks for it: it arrives, and it stops arriving the moment the grant does.
--
-- THE CHARACTER IS NOT ON THAT LIST, and deliberately not. Who somebody is
-- PLAYING is on their replicated state bag, which this client already holds for
-- everybody in its bucket -- so it is read here rather than sent, and a tag costs
-- the wire nothing it was not already costing. `character`'s own contract is the
-- reader (`GetPlayerIdentity`); this file never touches `Open77.state` itself.
--
-- A tag therefore carries three names and each has a different provenance:
--   `name`       the CHARACTER, off the bag -- what the city calls them
--   `user`       the ACCOUNT, off the staff list -- what a ban is keyed on
--   `citizenId`  the character's public id, off the bag -- what survives both
-- With no character loaded the account moves into `name` and `user` goes empty:
-- a tag over a body has to say something, and the account is what there is.
--
-- The pass is registered with `OPX.Scheduler` and never spawned as a loop of its
-- own: exceeding the per-resume instruction budget unwinds out of a coroutine
-- body and a `while true ... Wait(n)` loop that hits it is never resumed again,
-- silently. It returns at once while the tags are off.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text

M.Tags = {}
local Tags = M.Tags

-- The client store key the switch is remembered under.
local KVP_KEY = 'opx.admin.tags.shown'

-- The client store key the operator's own tag is remembered under. Its own key
-- and not a field of the one above: the two are asked back at different moments
-- -- the switch has to go through the server for the grant, this one never does.
local KVP_OWN_KEY = 'opx.admin.tags.own'

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

-- Whether the operator asked to see their OWN tag. Starts at TAGS.OWN and is
-- theirs to change from the menu after that; it is remembered on this machine.
--
-- IT NEEDS NO SERVER AND NO GRANT, and that is the whole reason it is a flag
-- here rather than a command like the switch above it. It changes what THIS
-- client draws over its own head: the name is the player's own, the body is
-- their own, and nothing about it is knowledge the server would be handing out.
-- The gate is already upstream -- no tags at all without `opx.admin.self.tags`.
local ownShown = false

-- The settings, read once at start.
local tuning = {}

-- The signature of the rows last published, so an unchanged frame is not sent.
local published

-- The scheduler handle, and how many restore attempts are left.
local job, restoresLeft = nil, 0

-- Problems already logged, one line each.
local reported = {}

-- Consecutive passes the operator's own tag has been asked for and not drawn.
-- See the probe at the end of `pass`.
local ownQuiet = 0

local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	Open77.log.warn('[admin] ' .. message)
end

--- Saves the own-tag preference on this machine.
-- Defined up here rather than beside `remember` because `Tags.SetOwnShown` is
-- written above that one, and a `local function` further down the file is a
-- DIFFERENT local: the call above it would reach for a global that is never set.
local function rememberOwn(on)
	local kvp = Open77.kvp
	if type(kvp) ~= 'table' or type(kvp.set) ~= 'function' then
		return warnOnce('kvp', 'Open77.kvp is not on this client: the name tag switch lasts this ' ..
			'session only')
	end
	local called, ok, reason = pcall(kvp.set, KVP_OWN_KEY, on)
	if not called or not ok then
		warnOnce('kvpSetOwn', ('the own-tag preference was not saved: %s')
			:format(tostring(called and reason or ok)))
	end
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

--- Whether the operator asked to see their own tag, for the menu row.
-- @author dop42
-- @return boolean
function Tags.IsOwnShown()
	return ownShown
end

--- Turns the operator's own tag on or off and redraws at the next pass.
--
-- `published` is cleared rather than the pass being run here: the pass is on the
-- scheduler at `UPDATE_MS` and running it inline would be a second one in the
-- same frame. Clearing the signature is what makes the next one redraw instead
-- of deciding nothing changed.
--
-- IT IS STILL THIRD PERSON ONLY, and that is not this switch's business to
-- override. `pass` draws the local body's tag only when the view is `tps`,
-- because in first person the tag would sit in the middle of the screen with no
-- head under it. Asking for your own tag asks for it where there is somewhere to
-- put it.
-- @author dop42
-- @param on boolean
function Tags.SetOwnShown(on)
	on = on == true
	if ownShown == on then return end
	ownShown = on
	published = nil
	rememberOwn(on)
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

-- Answered for anybody there is nothing to say about, so a caller may index it.
local EMPTY_IDENTITY = {}

-- Who a player is playing, off the replicated bag through `character`'s contract.
-- A runtime with no character module, a host that does not replicate bags, and a
-- slot that has loaded nobody all answer the same empty table.
local function identityOf(playerId)
	local character = Client.Contract('character')
	if type(character) ~= 'table' or type(character.GetPlayerIdentity) ~= 'function' then
		return EMPTY_IDENTITY
	end
	local read, identity = pcall(character.GetPlayerIdentity, playerId)
	if not read or type(identity) ~= 'table' then return EMPTY_IDENTITY end
	return identity
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
		showUser = tuning.username,
		showCitizen = tuning.citizen,
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
	-- Why the operator's own tag was left out, for the one line below. Nil means
	-- it was drawn, or was never asked for.
	local ownMissing = nil
	if not down and not (tuning.hideFirstPerson and third == false) then
		local read, entries, why = pcall(players.nearby, tuning.distance + CULL_MARGIN,
			{ includeSelf = ownShown, limit = tuning.max })
		if ownShown then
			ownMissing = ('the local body is not in players.nearby (%d entries, %s)')
				:format(type(entries) == 'table' and #entries or -1,
					read and tostring(why or 'no reason given') or tostring(entries))
		end
		for _, entry in ipairs(read and type(entries) == 'table' and entries or {}) do
			local id = type(entry) == 'table' and tonumber(entry.playerId) or nil
			local row = id and known[id] or nil
			local distance = row and Text.Finite(entry.distance) or nil
			if ownShown and entry.isLocal == true then
				ownMissing = row == nil and 'the server has not sent this operator\'s own name'
					or entry.entity == nil and 'the local body has no entity'
					or distance == nil and 'the local body has no distance'
					or nil
			end
			-- THE CHECKBOX IS THE ANSWER, and it did not used to be. This read
			-- `entry.isLocal ~= true or third == true`: the operator's own tag was
			-- drawn in THIRD PERSON ONLY, because in first person the head is at
			-- the camera and the tag "would sit in the middle of the screen".
			--
			-- The fear is real and the guard was the wrong place for it. It made a
			-- ticked box do nothing in the view most players are in, with nothing
			-- anywhere saying why -- and it was a guess besides: `thirdPerson()`
			-- answers nil on a build that cannot read the perspective, and nil is
			-- not `true`, so the tag was withheld from anyone whose client could
			-- not be asked.
			--
			-- The middle-of-the-screen case is now refused on EVIDENCE instead, one
			-- layer down: the anchor projects the head every frame and carries the
			-- depth in front of the camera with it, and `TagsRoot.vue` draws no tag
			-- closer than half a metre. A head at the camera fails that test by
			-- construction, in any view, on any build -- and a tag that the page
			-- can actually put over a head is drawn, which is what the box says.
			if distance and entry.entity ~= nil and (entry.isLocal ~= true or ownShown) then
				-- One bag read per body per pass, and the contract caches it: see
				-- `modules/character/client/state.lua`.
				local identity = identityOf(id)
				rows[#rows + 1] = {
					playerId = id,
					entity = entry.entity,
					-- THE LOCAL BODY IS NOT AN ANCHORABLE ENTITY. `players.nearby`
					-- answers entity `0` for your own body -- the reserved id every
					-- Open77 entity API reads as "the local player" -- and the anchor
					-- backend refuses it by name: `invalid_entity`. The view follows
					-- this row by POSITION instead, and this is the flag that tells
					-- it which one. The position itself is deliberately NOT carried
					-- here: it moves every frame, and the row signature below is what
					-- stops this module republishing a frame that has not changed.
					own = entry.isLocal == true,
					-- THE CHARACTER TAKES THE MAIN SLOT and the account falls back into
					-- it, which is why `user` is nil rather than repeated whenever that
					-- fallback is what happened. The page then never has to work out
					-- which of two names it is looking at.
					name = identity.name or row.name,
					user = identity.name and row.name or nil,
					citizenId = identity.citizenId,
					staff = row.staff == true,
					offsetZ = headOffset(entry.entity, entry.position),
					alpha = alphaFor(distance),
				}
			end
		end
	end

	-- ONE LINE, ONCE, when the box is ticked and the tag still is not there. The
	-- option is the sort that is either on screen or unexplained, and "it does not
	-- work" is not something anyone can act on. A tag that IS published and then
	-- culled by the page's depth test is the first-person case and says so there.
	-- NOT ON THE FIRST PASS. The pass runs at `UPDATE_MS` and the first few after a
	-- reconnect are genuinely empty: the switch is restored from the store before
	-- the body is streamed and before the server's first name list lands, so a
	-- probe that latched on pass one reported the boot and then never looked
	-- again. It has to be wrong for a couple of seconds together before it is news.
	ownQuiet = ownMissing ~= nil and ownQuiet + 1 or 0
	if ownQuiet == math.max(2, math.floor(2000 / tuning.updateMs)) and not reported.own then
		reported.own = true
		M.Client.Journal(('the own name tag is on but not drawn: %s'):format(ownMissing))
	end

	table.sort(rows, function(left, right) return left.playerId < right.playerId end)

	local parts = {}
	for index, row in ipairs(rows) do
		-- Every field the view draws, so a frame that changed only the account or
		-- the citizen id is republished rather than decided unchanged.
		parts[index] = ('%d\t%s\t%s\t%s\t%s\t%d\t%.2f\t%.1f'):format(row.playerId,
			tostring(row.entity), row.name, row.user or '', row.citizenId or '',
			row.staff and 1 or 0, row.offsetZ, row.alpha)
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
		hideFirstPerson = settings.HIDE_IN_FIRST_PERSON == true,
		technical = settings.TECHNICAL ~= false,
		username = settings.USERNAME ~= false,
		citizen = settings.CITIZEN ~= false,
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

	-- The own-tag preference: `TAGS.OWN` is the DEFAULT, not the value. It is what
	-- a machine that has never been asked starts at, and the store wins after
	-- that, because from then on it is the operator's own answer. Read before the
	-- switch below, which may return early.
	local readOwn, savedOwn = pcall(kvp.get, KVP_OWN_KEY, settings.OWN == true)
	ownShown = readOwn and savedOwn == true or (not readOwn and settings.OWN == true)

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
