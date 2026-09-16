--- The two views this module owns -- the appearance panel and the fitting room --
--- and the one seam a view module attaches to.
-- @author dop42
--
-- Neither of these drew itself: the panel was a list drawn by a menu resource and
-- the fitting room a page drawn by a panel resource, and neither exists in this
-- runtime yet. The state machines are here; the drawing is not, and must not be.

local M = OPX.Modules.Get('appearance')

local Snapshot = M.Snapshot
local State = M.Face
local Runtime = M.Runtime
local Clothing = M.Clothing

M.Panel = {}
M.Wardrobe = {}
local Panel = M.Panel
local Wardrobe = M.Wardrobe

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state, the rules and the puppet; it creates no surface.
-- Everything it has to say to whatever draws these two views leaves on
-- `M.Event.ON_VIEW` with a `kind`, and everything a view has to say comes back
-- through the one function `M.FromView`. A view module attaches by listening to
-- the first and calling the second.
--
--   out  kind = 'config'      every string a view draws, sent when it reports ready
--        kind = 'panel'       the panel's rows; draw or redraw it
--        kind = 'panelClosed' take the panel down, with a `reason`
--        kind = 'status'      a transient line under the open panel
--        kind = 'room'        the fitting room's first frame; draw it
--        kind = 'roomItems'   another batch of catalogue entries, `final` on the last
--        kind = 'roomState'   the room's tabs, choices and summary changed
--        kind = 'roomClosed'  take the room down, with a `reason`
--        kind = 'confirm'     ask the player a yes/no question
--
--   in   'ready'              the view can be drawn on; answers config and state
--        'panel.select'       a panel row was chosen: `payload.item`
--        'panel.close'        the player took the panel down: `payload.reason`
--        'room.hover'         a piece is pointed at: `payload.item`, `payload.tab`
--        'room.leave'         nothing is pointed at any more
--        'room.select'        a piece was chosen: `payload.item`, `payload.tab`
--        'room.tab'           another slot's tab was opened: `payload.tab`
--        'room.action'        a button was pressed: `payload.value`
--        'room.dismiss'       the player asked to leave the room
--        'room.confirm'       an answer to a confirm: `payload.item`, `payload.value`
--        'room.close'         the view took the room down: `payload.reason`
--        'diag'               a view-side failure, for the client log

--- Tells whatever draws these views something.
local function publish(kind, payload)
	payload = payload or {}
	payload.kind = kind
	TriggerEvent(M.Event.ON_VIEW, payload)
end

-- Every string a view draws, read from the active catalogue when it reports ready.
local TEXT_KEYS = {
	'appearance.panel.title', 'appearance.panel.looks', 'appearance.panel.body',
	'appearance.panel.outfits', 'appearance.panel.soon', 'appearance.panel.bodyType',
	'appearance.panel.savedLook', 'appearance.panel.worn', 'appearance.panel.stored',
	'appearance.panel.none', 'appearance.panel.otherBuild', 'appearance.panel.noLook',
	'appearance.panel.oneLook', 'appearance.panel.wear', 'appearance.panel.editFace',
	'appearance.panel.editHair', 'appearance.panel.editNote', 'appearance.panel.bodyNote',
	'appearance.panel.outfitsNote', 'appearance.panel.wearing', 'appearance.panel.wornNow',
	'appearance.panel.alreadyWorn', 'appearance.panel.busy',
	'wardrobe.title', 'wardrobe.ui.heading', 'wardrobe.ui.eyebrow',
	'wardrobe.ui.eyebrowCreation', 'wardrobe.ui.intro', 'wardrobe.ui.introCreation',
	'wardrobe.ui.female', 'wardrobe.ui.male', 'wardrobe.ui.nothing', 'wardrobe.ui.remove',
	'wardrobe.ui.search', 'wardrobe.ui.count', 'wardrobe.ui.empty', 'wardrobe.ui.loading',
	'wardrobe.ui.save', 'wardrobe.ui.saveCreation', 'wardrobe.ui.cancel', 'wardrobe.ui.skip',
	'wardrobe.ui.front', 'wardrobe.ui.back', 'wardrobe.ui.confirmTitle',
	'wardrobe.ui.confirmText', 'wardrobe.ui.confirmTitleCreation',
	'wardrobe.ui.confirmTextCreation', 'wardrobe.ui.confirmYes', 'wardrobe.ui.confirmNo',
}

-- ── the appearance panel ────────────────────────────────────────────────────
-- The frame around the face, not the face: there is no face editor here and there
-- cannot be one. An option is an opaque 64-bit catalogue hash with no human label
-- anywhere on the platform, so the engine's own mirror is the only editor there
-- is and this panel's job is to open it.

-- The module or resource the open panel belongs to, and the panel session, moved
-- on by every open and every close so a stale thread stops.
local panelOwner = nil
local panelSession = 0

--- Whether a panel is up for any caller.
-- @author dop42
-- @return boolean
function M.Panel.IsOpen()
	return panelOwner ~= nil
end

--- The caller the open panel belongs to.
-- @author dop42
-- @return string|nil
function M.Panel.Owner()
	return panelOwner
end

--- Whether a native modal is on screen, an unreadable answer counting as one.
local function nativeUp()
	return State.editing or State.creating or Runtime.ModalOnScreen()
end
M.Panel.NativeUp = nativeUp

--- The player-facing condition of the stored face.
local function storedText()
	if type(State.canonical) ~= 'table' then return locale('appearance.panel.none') end
	if State.Wearing() then return locale('appearance.panel.worn') end
	return locale('appearance.panel.stored')
end

--- The player-facing body family of the character.
local function familyText()
	return State.family ~= nil and Runtime.FamilyText(State.family) or '-'
end

--- The saved-look rows and the two ways into the native editor.
-- A row that cannot be used carries the reason as its value rather than being
-- greyed out with nothing beside it.
local function looksItems()
	local stored = type(State.canonical) == 'table' and State.canonical or nil
	local fits = stored ~= nil and M.BuildAccepted(stored.gameBuild)
	local busy = State.commit ~= nil or nativeUp()

	local blocked
	if stored == nil then
		blocked = locale('appearance.panel.none')
	elseif not fits then
		blocked = locale('appearance.panel.otherBuild')
	elseif State.Wearing() then
		blocked = locale('appearance.panel.worn')
	elseif busy then
		blocked = locale('appearance.panel.busy')
	end

	return {
		{ separator = true, label = locale('appearance.panel.oneLook') },
		{ id = 'saved', label = locale('appearance.panel.savedLook'), value = storedText(),
			disabled = true },
		{ id = 'wear', label = locale('appearance.panel.wear'), value = blocked,
			disabled = blocked ~= nil },
		{ separator = true },
		{ id = 'editFace', label = locale('appearance.panel.editFace'),
			description = locale('appearance.panel.editNote'),
			value = busy and locale('appearance.panel.busy') or nil, disabled = busy },
		{ id = 'editHair', label = locale('appearance.panel.editHair'),
			value = busy and locale('appearance.panel.busy') or nil, disabled = busy },
	}
end

--- The panel's whole content: the three levels and their rows.
local function panelSpec()
	local roomBusy = Wardrobe.IsOpen() or not Clothing.Ready()
	return {
		title = locale('appearance.panel.title'),
		items = {
			{ id = 'looks', label = locale('appearance.panel.looks'), value = storedText(),
				items = looksItems() },
			{ id = 'body', label = locale('appearance.panel.body'), value = familyText(),
				items = {
					-- Stated and not offered: the body family belongs to the character.
					{ separator = true, label = locale('appearance.panel.bodyNote') },
					{ id = 'family', label = locale('appearance.panel.bodyType'), value = familyText(),
						disabled = true },
				} },
			{ id = 'outfits', label = locale('appearance.panel.outfits'),
				items = {
					{ id = 'wardrobe', label = locale('appearance.panel.outfitsNote'),
						value = roomBusy and locale('appearance.panel.busy') or nil,
						disabled = roomBusy },
				} },
		},
	}
end

--- Redraws the open panel where the player stands in it.
-- @author dop42
function M.Panel.Refresh()
	if panelOwner == nil then return end
	publish('panel', panelSpec())
end

--- Shows a transient status line under the open panel.
local function status(text, ok)
	if panelOwner == nil then return end
	publish('status', { text = text, ok = ok == true })
end

--- Takes the panel down for a reason of this module's own.
-- @author dop42
-- @param reason string
function M.Panel.Close(reason)
	if panelOwner == nil then return end
	panelSession = panelSession + 1
	panelOwner = nil
	publish('panelClosed', { reason = reason })
	Runtime.Publish({ ok = true, event = 'panelClosed', citizenId = State.citizenId,
		reason = reason })
end

--- Puts the panel up for a caller, or redraws it.
-- @author dop42
--
-- One panel at a time, keyed on the caller's own name: a second caller is refused
-- and the owner asking again redraws its own.
-- @param owner string the caller's own name
-- @return boolean
-- @return string|nil the refusal
function M.Panel.Open(owner)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	if Runtime.IsDown() then return false, 'player_down' end
	if State.citizenId == nil then return false, 'no_character' end
	if nativeUp() then return false, 'appearance_busy' end
	if panelOwner ~= nil and panelOwner ~= owner then return false, 'panel_busy' end

	if panelOwner == owner then
		Panel.Refresh()
		return true
	end

	panelSession = panelSession + 1
	panelOwner = owner
	publish('panel', panelSpec())
	Runtime.Publish({ ok = true, event = 'panelOpened', citizenId = State.citizenId })
	return true
end

--- Puts the stored face back on the puppet from the panel.
local function wearStored()
	if type(State.canonical) ~= 'table' then
		return status(locale('appearance.panel.noLook'), false)
	end
	if not M.BuildAccepted(State.canonical.gameBuild) then
		return status(locale('appearance.buildMismatch'), false)
	end
	if State.Wearing() then
		return status(locale('appearance.panel.alreadyWorn'), true)
	end
	if State.commit ~= nil or nativeUp() then
		return status(locale('appearance.panel.busy'), false)
	end

	-- Both captured: the wait ends if either the character or its stored face
	-- changed while the mirror was working.
	local snapshot, citizen = State.canonical, State.citizenId
	status(locale('appearance.panel.wearing'), true)
	CreateThread(function()
		local ok, failure = Runtime.ApplySnapshot(snapshot, 8, nil)
		if State.citizenId ~= citizen or State.canonical ~= snapshot then return end
		if ok then State.Wore() end
		Runtime.Publish({ ok = ok, event = 'applied', citizenId = citizen,
			error = (not ok) and tostring(failure) or nil })
		if ok then
			status(locale('appearance.panel.wornNow'), true)
		else
			status(locale('appearance.restoreFailed', { reason = tostring(failure) }), false)
		end
	end)
end

--- Takes the panel down, then asks for the native editor.
-- The panel goes first and is not reopened: the mirror must never be drawn over.
local function openNative(mode)
	Panel.Close('caller')
	local ok, reason = M.Editor.Open(mode)
	if ok then return end
	Runtime.Notify('error', 'appearance.editorUnavailable', { reason = tostring(reason) })
end

--- Runs one pass over an open panel: a native modal or a gone owner closes it.
local function panelTick()
	if panelOwner == nil then return end
	if nativeUp() then return Panel.Close('appearance_busy') end
	if not OPX.Modules.IsRunning(panelOwner) and GetResourceState(panelOwner) ~= 'running' then
		Panel.Close('owner_stopped')
	end
end

-- ── the fitting room ────────────────────────────────────────────────────────
-- It borrows the puppet from the clothing half rather than dressing it behind its
-- back: while the puppet is lent, nothing is saved and no look is published, so a
-- jacket the player is only trying on never reaches the database or anybody else.

-- The seven visible slots the room dresses, in the order the tabs show them, and
-- the nine a put-on states.
local SLOTS = Clothing.OUTFIT_SLOTS
local EQUIPMENT_SLOTS = Clothing.SLOTS

local IS_SLOT = {}
for index = 1, #SLOTS do IS_SLOT[SLOTS[index]] = true end

-- The tab the room opens on.
local FIRST_SLOT = 'InnerChest'

-- Catalogue entries carried by one batch, and records handled between two yields.
local CATALOGUE_PART = 100
local CATALOGUE_STRIDE = 256

-- Milliseconds between two tries at opening the room after a creation, and how
-- long a kept outfit's save is listened for.
local RETRY_MS = 500
local SAVE_WAIT_MS = 30000

-- Degrees one turn of the camera moves.
local TURN_DEGREES = 45

-- Shipped WARDROBE.CREATION_WAIT_MS, for a configuration that lost it.
local CREATION_WAIT_MS = 60000

-- Refusals that mean 'not yet' while a created character settles.
local RETRYABLE = {
	clothing_not_ready = true,
	clothing_saving = true,
	player_unavailable = true,
	player_down = true,
	input_captured = true,
	no_view = true,
}

-- closed, opening while the puppet is asked for, or open; and the room
-- generation, so a stale opening or catalogue stream stops.
local phase = 'closed'
local generation = 0

-- The module or resource the open room belongs to.
local roomOwner = nil

-- The nine slots the puppet wore when the room opened, and the nine the player
-- chose. The difference between them is what `save` means.
local baseline, draft = nil, nil

-- The record pointed at and put on over the draft, the slot whose tab is shown,
-- and every catalogue record read this room, to its slot.
local hovered, tab, known = nil, FIRST_SLOT, {}

-- The status line under the grid, whether this room follows a creation, the
-- character the puppet was lent for, and the family the catalogue is read for.
local statusText, creating, citizen, family = nil, false, nil, nil

-- Whether the room turned the active outfit off, the perspective requested before
-- it took the camera, and the camera's orbit in degrees.
local outfitCleared, savedPerspective, orbit = false, nil, 180

-- Creation handoff generation, so an older wait stops, and the kept outfit whose
-- save is listened for.
local creationWatch, awaitSave = 0, nil

--- Whether the room is up or opening.
-- @author dop42
-- @return boolean
function M.Wardrobe.IsOpen()
	return phase ~= 'closed'
end

--- Whether the open room follows a character creation.
-- @author dop42
-- @return boolean
function M.Wardrobe.Creation()
	return creating
end

--- The caller the open room belongs to.
-- @author dop42
-- @return string|nil
function M.Wardrobe.Owner()
	return roomOwner
end

--- The display name of a record: `Items.Jacket_01_basic` reads 'Jacket 01 basic'.
local function title(record)
	local text = tostring(record):gsub('^Items%.', ''):gsub('_', ' '):gsub('(%l)(%u)', '%1 %2')
	return (text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Whether the puppet is alive on foot in the world and the player is not down.
local function playable()
	if Runtime.IsDown() then return false end
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return false end
	local read, value = pcall(character.state)
	if not read or type(value) ~= 'table' then return false end
	if value.attached == false or value.alive ~= true then return false end
	-- Never in a vehicle: the room turns the body around in front of a camera.
	if type(value.vehicle) == 'table' and value.vehicle.mounted then return false end
	return true
end

--- Why the room cannot open now, or nil.
local function refusal()
	if phase ~= 'closed' then return 'wardrobe_busy' end
	if type(Open77.equipment) ~= 'table' or type(Open77.equipment.apply) ~= 'function' or
		type(Open77.equipment.records) ~= 'function' then
		return 'equipment_api_unavailable'
	end
	if Runtime.IsDown() then return 'player_down' end
	if not playable() then return 'player_unavailable' end
	if OPX.Keys.IsCaptured() then return 'input_captured' end
	return nil
end

--- The nine equipment slots of a clothing record, false for empty.
local function slotsOf(clothing)
	local equipment = type(clothing) == 'table' and type(clothing.equipment) == 'table' and
		clothing.equipment or {}
	local out = {}
	for index = 1, #EQUIPMENT_SLOTS do
		local slot = EQUIPMENT_SLOTS[index]
		local item = equipment[slot]
		out[slot] = type(item) == 'string' and item ~= '' and item or false
	end
	return out
end

--- A shallow copy of a slot table.
local function copy(slots)
	local out = {}
	for slot, item in pairs(slots) do out[slot] = item end
	return out
end

--- Whether the player chose something other than what was worn when it opened.
local function changed()
	if baseline == nil or draft == nil then return false end
	if outfitCleared then return true end
	for index = 1, #EQUIPMENT_SLOTS do
		local slot = EQUIPMENT_SLOTS[index]
		if baseline[slot] ~= draft[slot] then return true end
	end
	return false
end

--- States the nine slots on the puppet, turning a covering outfit off first.
local function putOn(slots)
	local wardrobe = Open77.wardrobe
	if not outfitCleared and type(wardrobe) == 'table' and type(wardrobe.active) == 'function' then
		local read, active = pcall(wardrobe.active)
		if read and type(active) == 'number' then
			local called, ok, reason = pcall(wardrobe.activate, false)
			if not called then return false, tostring(ok) end
			if not ok then return false, tostring(reason or 'outfit_not_cleared') end
			outfitCleared = true
		end
	end
	local called, ok, reason = pcall(Open77.equipment.apply, slots, { allowRestricted = true })
	if not called then return false, tostring(ok) end
	if not ok then return false, tostring(reason or 'apply_failed') end
	return true
end

--- The draft with one piece in its slot, uncovered by a full-body suit.
local function wearing(slot, record)
	local wanted = copy(draft)
	wanted[slot] = record
	if slot ~= 'Outfit' and record ~= false then wanted.Outfit = false end
	return wanted
end

--- States the camera's orbit around the puppet; the host may have reset its rig.
local function orbitCamera()
	local camera = Open77.camera
	if type(camera) ~= 'table' or type(camera.orbit) ~= 'function' then return false end
	local called, ok = pcall(camera.orbit, orbit)
	return called and ok == true
end

--- Whether this client can orbit the camera around the puppet.
local function hasOrbit()
	return type(Open77.camera) == 'table' and type(Open77.camera.orbit) == 'function'
end

--- Remembers the perspective, goes third person and faces the puppet.
local function holdCamera()
	orbit = 180
	local perspective = Open77.perspective
	if type(perspective) == 'table' then
		local requested
		if type(perspective.state) == 'function' then
			local read, value = pcall(perspective.state)
			if read and type(value) == 'table' then requested = value.requested end
		end
		if requested == nil and type(perspective.get) == 'function' then
			local read, value = pcall(perspective.get)
			if read then requested = value end
		end
		savedPerspective = requested
		if type(perspective.set) == 'function' then pcall(perspective.set, 'tps') end
	end
	orbitCamera()
end

--- Lets go of the orbit and puts the remembered perspective back.
local function freeCamera()
	local camera = Open77.camera
	if type(camera) == 'table' and type(camera.clearOrbit) == 'function' then
		pcall(camera.clearOrbit)
	end
	local perspective = Open77.perspective
	if savedPerspective ~= nil and type(perspective) == 'table' and
		type(perspective.set) == 'function' then
		pcall(perspective.set, savedPerspective)
	end
	savedPerspective = nil
end

--- The part of the room that follows the draft: tabs, choices and summary.
local function roomState()
	local tabs, selected = {}, {}
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		tabs[index] = { id = slot, label = locale('wardrobe.slot.' .. slot),
			marked = draft[slot] ~= false }
		selected[slot] = draft[slot]
	end
	local worn = draft[tab]
	return {
		tabs = tabs,
		tab = tab,
		selected = selected,
		summary = {
			label = locale('wardrobe.slot.' .. tab),
			value = worn and title(worn) or locale('wardrobe.ui.nothing'),
			action = { id = 'remove', label = locale('wardrobe.ui.remove'), disabled = worn == false },
		},
		status = statusText and { text = statusText, kind = 'error' } or false,
	}
end

--- Sends the view the current draft.
local function refresh()
	if phase ~= 'open' or draft == nil then return end
	publish('roomState', roomState())
end

--- A record's sort key, numbers padded so 2 comes before 10.
local function sortKey(name)
	return (name:lower():gsub('%d+', function(digits) return ('%010d'):format(tonumber(digits)) end))
end

--- Reads the body's clothing catalogue and hands it to the view in batches.
-- On its own thread and yielding every CATALOGUE_STRIDE records: two thousand
-- entries sorted and formatted in one resume is exactly the shape that exceeds
-- the per-resume instruction budget.
local function streamCatalogue(mine)
	CreateThread(function()
		Wait(0)
		if mine ~= generation or phase ~= 'open' then return end
		local called, records, reason = pcall(Open77.equipment.records,
			{ family = family, restricted = false, limit = 2000 })
		if not called or type(records) ~= 'table' then
			local failure = tostring(called and reason or records)
			Open77.log.warn('[appearance] the clothing catalogue could not be read: ' .. failure)
			TriggerServerEvent(M.Event.DIAGNOSTIC, 'wardrobe catalogue: ' .. failure)
			statusText = locale('wardrobe.ui.failed', { reason = failure })
			publish('roomItems', { items = {}, final = true, status = statusText })
			return
		end

		local entries = {}
		for index = 1, #records do
			local entry = records[index]
			if type(entry) == 'table' and type(entry.record) == 'string' and IS_SLOT[entry.slot] then
				known[entry.record] = entry.slot
				if entry.nonvisual ~= true then
					local name = title(entry.record)
					entries[#entries + 1] = { id = entry.record, tab = entry.slot, label = name,
						detail = entry.record, key = sortKey(name) }
				end
			end
			if index % CATALOGUE_STRIDE == 0 then
				Wait(0)
				if mine ~= generation or phase ~= 'open' then return end
			end
		end
		table.sort(entries, function(left, right) return left.key < right.key end)
		Wait(0)

		local first = 1
		repeat
			if mine ~= generation or phase ~= 'open' then return end
			local last = math.min(#entries, first + CATALOGUE_PART - 1)
			local part = {}
			for index = first, last do
				local entry = entries[index]
				part[#part + 1] = { id = entry.id, tab = entry.tab, label = entry.label,
					detail = entry.detail }
			end
			publish('roomItems', { items = part, final = last >= #entries })
			first = last + 1
			Wait(0)
		until first > #entries
	end)
end

--- The first frame of the room.
local function roomSpec()
	local opened = roomState()
	opened.eyebrow = locale(creating and 'wardrobe.ui.eyebrowCreation' or 'wardrobe.ui.eyebrow')
	opened.title = locale('wardrobe.ui.heading')
	opened.subtitle = family == 'male' and locale('wardrobe.ui.male') or
		(family == 'female' and locale('wardrobe.ui.female') or nil)
	opened.intro = locale(creating and 'wardrobe.ui.introCreation' or 'wardrobe.ui.intro')
	opened.search = locale('wardrobe.ui.search')
	opened.loading = true
	opened.labels = {
		count = locale('wardrobe.ui.count'),
		empty = locale('wardrobe.ui.empty'),
		loading = locale('wardrobe.ui.loading'),
	}
	opened.actions = {
		{ id = 'cancel', label = locale(creating and 'wardrobe.ui.skip' or 'wardrobe.ui.cancel') },
		{ id = 'save', label = locale(creating and 'wardrobe.ui.saveCreation' or 'wardrobe.ui.save'),
			primary = true },
	}
	if hasOrbit() then
		opened.tools = {
			{ id = 'front', label = locale('wardrobe.ui.front') },
			{ id = 'left', label = 'left' },
			{ id = 'right', label = 'right' },
			{ id = 'back', label = locale('wardrobe.ui.back') },
		}
	end
	return opened
end

--- Borrows the puppet and puts the room up, from a coroutine.
-- @param expected string|nil the character the room must be for
local function begin(owner, creation, expected)
	local refused = refusal()
	if refused then return false, refused end
	phase = 'opening'
	generation = generation + 1
	local mine = generation

	local answer, reason = Clothing.BeginPreview(owner)
	if answer == nil then
		if mine == generation then phase = 'closed' end
		return false, reason
	end

	-- Everything is re-checked after the borrow: it is the first thing here that
	-- can have taken time.
	local stale = mine ~= generation or phase ~= 'opening'
	local wrong = expected ~= nil and State.citizenId ~= expected
	if stale or wrong or not playable() then
		Clothing.EndPreview(owner, false)
		if mine == generation then phase = 'closed' end
		if wrong then return false, 'character_changed' end
		return false, stale and 'superseded' or 'player_unavailable'
	end

	baseline = slotsOf(answer)
	draft = copy(baseline)
	known, outfitCleared, hovered, statusText, tab = {}, false, nil, nil, FIRST_SLOT
	citizen, family, creating = State.citizenId, Runtime.BodyFamily(), creation == true
	roomOwner = owner

	phase = 'open'
	publish('room', roomSpec())
	holdCamera()
	streamCatalogue(mine)
	Runtime.Publish({ ok = true, event = 'wardrobeOpened', creation = creating,
		citizenId = citizen })
	return true
end

--- Takes the room down and gives the puppet back, kept or restored.
local function release(keep, reason)
	if phase == 'opening' then
		generation = generation + 1
		phase = 'closed'
		return
	end
	if phase ~= 'open' then return end
	-- Keeping what was never changed is not a save.
	keep = keep and changed()
	phase = 'closed'
	generation = generation + 1
	freeCamera()

	local mine, wasCreation, worn, owner = citizen, creating, draft, roomOwner
	baseline, draft, known, citizen, family, creating = nil, nil, {}, nil, nil, false
	hovered, statusText, outfitCleared, roomOwner = nil, nil, false, nil

	publish('roomClosed', { reason = reason, kept = keep })
	-- The registry reads pieces back as TweakDB ids: the names go with them so the
	-- clothing half can store names.
	local ok, failure = Clothing.EndPreview(owner, keep, worn)
	if not ok then
		Open77.log.warn(('[appearance] the puppet was not taken back: %s'):format(tostring(failure)))
	elseif keep and mine ~= nil then
		awaitSave = { citizenId = mine, untilMs = Runtime.NowMs() + SAVE_WAIT_MS }
	end

	Runtime.Publish({ ok = true, event = 'wardrobeClosed', reason = reason, kept = keep,
		creation = wasCreation, citizenId = mine })
	Open77.log.info(('[appearance] the fitting room closed (%s, %s)')
		:format(reason, keep and 'kept' or 'restored'))
end

--- Takes the room down and puts back what the puppet wore.
-- @author dop42
-- @param reason string
function M.Wardrobe.Close(reason)
	release(false, reason)
end

--- Asks for the room on the live character, opened on a thread.
-- @author dop42
-- @param owner string the caller's own name
-- @return boolean
-- @return string|nil the refusal
function M.Wardrobe.Open(owner)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	local refused = refusal()
	if refused then return false, refused end
	CreateThread(function()
		local ok, reason = begin(owner, false, nil)
		if ok or reason == 'superseded' then return end
		Runtime.Publish({ ok = false, event = 'wardrobeOpened', error = reason })
		Runtime.Notify('error', 'wardrobe.unavailable', { reason = tostring(reason) })
	end)
	return true
end

--- Puts the piece pointed at on the puppet, over what the player chose.
local function hover(record, slot)
	if phase ~= 'open' or not IS_SLOT[slot] or type(record) ~= 'string' or
		known[record] ~= slot then
		return
	end
	if hovered == record or draft[slot] == record then return end
	local ok = putOn(wearing(slot, record))
	hovered = ok and record or nil
	if not ok then putOn(draft) end
end

--- Puts back what the player chose once nothing is pointed at.
local function unhover()
	if phase ~= 'open' or hovered == nil then return end
	hovered = nil
	putOn(draft)
end

--- Makes a piece, or an empty slot, the player's choice for that slot.
local function choose(slot, record)
	if phase ~= 'open' or not IS_SLOT[slot] then return end
	-- A record the catalogue did not offer for this slot is not a choice: the view
	-- is not trusted to name one.
	if record ~= false and (type(record) ~= 'string' or known[record] ~= slot) then return end
	local wanted = wearing(slot, record)
	local ok, failure = putOn(wanted)
	hovered = nil
	if ok then
		draft, statusText = wanted, nil
	else
		Open77.log.debug(('[appearance] %s refused on %s: %s')
			:format(tostring(record), slot, tostring(failure)))
		statusText = locale('wardrobe.ui.failed', { reason = tostring(failure):gsub('_', ' ') })
		putOn(draft)
	end
	refresh()
end

--- Leaves at once when nothing changed, otherwise asks before dropping the draft.
local function ask()
	if phase ~= 'open' then return end
	if not changed() then return release(false, 'cancelled') end
	publish('confirm', {
		id = 'discard',
		title = locale(creating and 'wardrobe.ui.confirmTitleCreation' or 'wardrobe.ui.confirmTitle'),
		text = locale(creating and 'wardrobe.ui.confirmTextCreation' or 'wardrobe.ui.confirmText'),
		yes = locale('wardrobe.ui.confirmYes'),
		no = locale('wardrobe.ui.confirmNo'),
	})
end

-- What each button of the room does.
local ACTIONS = {
	remove = function() choose(tab, false) end,
	save = function() release(true, 'saved') end,
	cancel = ask,
	front = function() orbit = 180 orbitCamera() end,
	back = function() orbit = 0 orbitCamera() end,
	left = function() orbit = ((orbit - TURN_DEGREES + 180) % 360) - 180 orbitCamera() end,
	right = function() orbit = ((orbit + TURN_DEGREES + 180) % 360) - 180 orbitCamera() end,
}

--- WARDROBE.CREATION_WAIT_MS, or the shipped value for an unusable one.
local function creationWaitMs()
	local config = type(M.Settings.WARDROBE) == 'table' and M.Settings.WARDROBE or {}
	return M.ConfigMs(config.CREATION_WAIT_MS) or CREATION_WAIT_MS
end

--- Opens the room once a created character's starting clothes are on.
local function awaitCreation(owner, citizenId)
	creationWatch = creationWatch + 1
	local mine = creationWatch
	CreateThread(function()
		local deadline, reason, said = Runtime.NowMs() + creationWaitMs(), nil, nil
		while mine == creationWatch and Runtime.NowMs() < deadline do
			local ok
			ok, reason = begin(owner, true, citizenId)
			if ok or reason == 'wardrobe_busy' then return end
			if not RETRYABLE[reason] and reason ~= 'superseded' then
				Open77.log.info(('[appearance] no fitting room after the creation of %s: %s')
					:format(tostring(citizenId), tostring(reason)))
				return
			end
			if reason ~= said then
				said = reason
				Open77.log.debug(('[appearance] fitting room for %s not yet: %s')
					:format(tostring(citizenId), tostring(reason)))
			end
			Wait(RETRY_MS)
		end
		if mine == creationWatch then
			Open77.log.info(('[appearance] no fitting room after the creation of %s: still %s')
				:format(tostring(citizenId), tostring(reason)))
		end
	end)
end

-- ── the other half of the seam ──────────────────────────────────────────────

--- What a view module calls.
-- @author dop42
--
-- `ready` says the view can be drawn on and answers with every string it draws
-- plus whatever is currently up; everything else is an intent, and every one of
-- them is re-checked here against state this module owns. Nothing a view computes
-- is trusted -- not a record name, not a slot, not a tab.
-- @param action string
-- @param payload table|nil
function M.FromView(action, payload)
	payload = type(payload) == 'table' and payload or {}

	if action == 'ready' then
		local text = {}
		for _, key in ipairs(TEXT_KEYS) do text[key] = locale(key) end
		publish('config', { text = text })
		if panelOwner ~= nil then publish('panel', panelSpec()) end
		if phase == 'open' then publish('room', roomSpec()) end
		return
	end

	if action == 'panel.select' then
		if panelOwner == nil then return end
		local id = payload.item
		if id == 'wear' then return wearStored() end
		if id == 'editFace' then return openNative('ripperdoc') end
		if id == 'editHair' then return openNative('hairdresser') end
		if id == 'wardrobe' then
			local owner = panelOwner
			Panel.Close('caller')
			local ok, reason = Wardrobe.Open(owner)
			if not ok then
				Runtime.Notify('error', 'wardrobe.unavailable', { reason = tostring(reason) })
			end
		end
		return
	end

	if action == 'panel.close' then
		return Panel.Close(payload.reason == 'player' and 'player' or 'view_closed')
	end

	if action == 'room.hover' then return hover(payload.item, payload.tab) end
	if action == 'room.leave' then return unhover() end
	if action == 'room.select' then return choose(payload.tab, payload.item) end
	if action == 'room.tab' then
		if not IS_SLOT[payload.tab] then return end
		unhover()
		tab, statusText = payload.tab, nil
		return refresh()
	end
	if action == 'room.action' then
		local run = ACTIONS[payload.value]
		if run then run() end
		return
	end
	if action == 'room.dismiss' then return ask() end
	if action == 'room.confirm' then
		if payload.item == 'discard' and payload.value == true then release(false, 'cancelled') end
		return
	end
	if action == 'room.close' then
		return release(false, tostring(payload.reason or 'view_closed'))
	end
	if action == 'diag' then
		Open77.log.info('[appearance] view: ' .. tostring(payload.text or ''))
	end
end

--- Runs one pass over both views.
-- @author dop42
function M.Wardrobe.Check()
	local ok, failure = pcall(panelTick)
	if not ok then Open77.log.error('[appearance] panel: ' .. tostring(failure)) end

	local ran, reason = pcall(function()
		if phase == 'open' then
			if not playable() then
				release(false, 'player_unavailable')
			else
				orbitCamera()
			end
			if roomOwner ~= nil and not OPX.Modules.IsRunning(roomOwner) and
				GetResourceState(roomOwner) ~= 'running' then
				release(false, 'owner_stopped')
			end
		end
		if awaitSave ~= nil and Runtime.NowMs() >= awaitSave.untilMs then awaitSave = nil end
	end)
	if not ran then Open77.log.error('[appearance] fitting room: ' .. tostring(reason)) end
end

--- Wires both views to the decisions this module reaches.
-- @author dop42
function M.Wardrobe.Wire()
	AddEventHandler(M.Event.ON_DECISION, function(decision)
		if type(decision) ~= 'table' then return end
		local event = decision.event

		if event == 'characterChanged' then
			creationWatch = creationWatch + 1
			awaitSave = nil
			Panel.Close('character_changed')
			return release(false, 'character_changed')
		end

		if event == 'created' then
			local config = type(M.Settings.WARDROBE) == 'table' and M.Settings.WARDROBE or {}
			if decision.ok ~= true or config.OPEN_AFTER_CREATION == false then return end
			return awaitCreation(M.Id, type(decision.citizenId) == 'string' and
				decision.citizenId or nil)
		end

		if event == 'clothingSaved' and awaitSave ~= nil and
			decision.citizenId == awaitSave.citizenId then
			awaitSave = nil
			if decision.ok == true then return Runtime.Notify('success', 'wardrobe.saved') end
			return Runtime.Notify('error', 'wardrobe.notSaved', { reason = tostring(decision.error) })
		end

		-- The panel shows the stored face and whether it is worn, so it follows
		-- every decision about one.
		if panelOwner ~= nil and (event == 'saved' or event == 'restored' or
			event == 'applied') then
			Panel.Refresh()
		end
	end)

	-- A new world entry dresses the puppet again, so the room goes down first.
	AddEventHandler(OPX.Host.WORLD_READY, function()
		release(false, 'world_changed')
	end)
end
