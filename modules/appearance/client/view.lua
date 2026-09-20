--- The other half of the seam: the two state machines on one side, two view
--- modules on the other.
-- @author dop42
--
-- `client/wardrobe.lua` owns the appearance panel and the fitting room and draws
-- neither -- its own header says so, and says the drawing "must not be" there. It
-- says everything it has to say on `M.Event.ON_VIEW` with a `kind`, and takes
-- everything back through the one function `M.FromView`. This file is the only
-- thing that knows what the two ends are, which is what lets the state half stay
-- testable without a surface, exactly as `modules/chat/client/view.lua` does for
-- the chat box.
--
-- WHAT THE TWO ENDS ARE, AND WHY THERE IS NO NEW PAGE HERE. They are the `menu`
-- and `panel` modules, which already draw in the house style on the one CEF
-- surface this resource owns. That is not a convenience: the seam was DESIGNED
-- against them. `panelSpec()` publishes a title and a tree of rows carrying
-- `separator`, `value`, `description` and nested `items` -- which is the menu
-- contract field for field -- and `roomSpec()` publishes `eyebrow`, `title`,
-- `subtitle`, `intro`, `actions`, `tools`, `sliders` and `status`, which is a
-- subset of the panel contract's PATCHABLE set field for field, down to the
-- `confirm` that `Confirm` takes. The wardrobe's own header records
-- where that came from: "the panel was a list drawn by a menu resource and the
-- fitting room a page drawn by a panel resource". Both of those resources have
-- since been rebuilt as modules in here. Writing a third Vue view would be a
-- second answer to a question this runtime has already answered twice, and it
-- would be the answer that did not get the search plate, the paging, the confirm
-- step or the keyboard for free.
--
-- NOTHING HERE DECIDES ANYTHING. Every action is forwarded verbatim and every
-- one of them is re-checked on the other side against state this file cannot
-- see: a slider index against the length of the list the state half read for
-- that slot, a slot against the seven it dresses, a button against the list it
-- drew. A modified page that asked for the four-thousandth jacket gets the same
-- nothing a mistyped slot does -- and what a character may actually WEAR is
-- settled further out still, by the server, when the clothing half saves the
-- record. THE PAGE NEVER NAMES A RECORD AT ALL NOW: it sends an index, and the
-- only side that can turn one into a record name is the side that holds the list.
--
-- THE FAILURE PATH IS DEFERRED ON PURPOSE. When a view refuses to open there is
-- nothing to draw and the state half has to be told -- but it publishes `room`
-- from inside `begin`, which goes on to take the camera and announce the room on
-- its decision bus afterwards. Answering inline would tear the room down
-- underneath a function still setting it up, so the answer is left for the
-- upkeep pass one tick later. See `undrawn`.

local M = OPX.Modules.Get('appearance')

M.View = {}
local View = M.View

-- This module's own name to the two view modules. One owner for both: they are
-- separate surfaces with separate handles, and a caller names itself to each.
local OWNER = 'appearance'

-- The ids the two views carry. Stable, because a payload coming back names them.
local PANEL_ID = 'appearance'
local ROOM_ID = 'wardrobe'

-- The two contracts, resolved once the Api phase has ended, or nil.
local Menu, Panel

-- The open menu's handle and the open panel's handle, or nil for none.
local menuHandle, roomHandle

-- True while this file is taking one of the two down itself. Both raise a close
-- back at their caller, and without this the answer to "the state half closed the
-- panel" would be reported to the state half as "the player closed the panel".
local closing = false

-- A `FromView` call held for the next upkeep pass, or nil. See the header.
local undrawn

-- Menu close reasons the PLAYER caused. The seam distinguishes exactly two
-- things -- the player took it down, or something else did -- so the rest map to
-- `view_closed` rather than being passed through under names the state half has
-- never heard of.
local PLAYER_CLOSED = { dismissed = true, back = true, pause = true, item = true }

--- Holds one answer for the upkeep pass.
-- Last one wins: two failures in a tick are the same failure, and the state half
-- only has one room to be told about.
local function later(action, payload)
	undrawn = { action = action, payload = payload }
end

-- ── the appearance panel, drawn by `menu` ───────────────────────────────────

--- What the player did to the appearance panel.
local function fromMenu(payload)
	if type(payload) ~= 'table' or payload.handle ~= menuHandle then return end
	local action = payload.action

	if action == 'select' then
		return M.FromView('panel.select', { item = payload.itemId })
	end

	if action == 'close' then
		-- Cleared BEFORE the state half is told: its answer is a `panelClosed`
		-- publication, and a handle still standing at that point would send a
		-- second close into a menu that has already gone.
		menuHandle = nil
		if closing then return end
		return M.FromView('panel.close', {
			reason = PLAYER_CLOSED[payload.reason] and 'player' or 'view_closed',
		})
	end
	-- `open`, `back` and `change` are the menu walking its own tree. The state
	-- half publishes the whole tree on every refresh and keeps no cursor, so
	-- there is nothing here for it to know.
end

--- Draws the appearance panel, or redraws the one that is up.
-- `Update` rather than a second `Open`, because the menu re-walks its navigation
-- stack onto the rebuilt tree by id: the panel is refreshed after every decision
-- about a face, and reopening it would throw a player standing two levels in back
-- out to the root each time.
local function showPanel(spec)
	if Menu == nil then return later('panel.close', { reason = 'no_view' }) end

	local shown = {
		owner = OWNER,
		id = PANEL_ID,
		title = spec.title,
		items = spec.items,
		on = fromMenu,
	}

	if menuHandle ~= nil then
		local patched = Menu.Update(menuHandle, shown)
		if patched.ok then return end
		-- The handle went stale under us -- something stole the menu, or the
		-- player was put down. Fall through and ask for it back.
		menuHandle = nil
	end

	local opened = Menu.Open(shown)
	if not opened.ok then
		Open77.log.warn(('[appearance] the appearance panel was not drawn: %s')
			:format(tostring(opened.error)))
		return later('panel.close', { reason = 'no_view' })
	end
	menuHandle = opened.value.handle
end

-- ── the fitting room, drawn by `panel` ──────────────────────────────────────

--- What the player did in the fitting room.
local function fromPanel(payload)
	if type(payload) ~= 'table' or payload.handle ~= roomHandle then return end
	local action = payload.action

	-- The room draws no rows and no tabs, so the panel contract's `select`,
	-- `hover`, `leave` and `tab` cannot be raised for it -- `panel` checks a
	-- clicked item against the items it was sent and a tab against the tabs it
	-- drew, and there are none of either. Forwarding them would be four branches
	-- nothing can reach.
	if action == 'slide' then
		return M.FromView('room.slide',
			{ slot = payload.id, index = payload.index, commit = payload.commit })
	end
	if action == 'action' then return M.FromView('room.action', { value = payload.id }) end
	if action == 'confirm' then
		return M.FromView('room.confirm', { item = payload.item, value = payload.value })
	end
	-- Escape. `dismiss = 'ask'` is what routes it here instead of closing the
	-- panel: a room with changes in it asks before dropping them, and only the
	-- state half knows whether there are any.
	if action == 'dismiss' then return M.FromView('room.dismiss') end

	if action == 'close' then
		roomHandle = nil
		if closing then return end
		return M.FromView('room.close', { reason = payload.reason })
	end
end

--- Draws the fitting room's first frame, or patches the one that is up.
local function showRoom(spec)
	if Panel == nil then return later('room.close', { reason = 'no_view' }) end

	-- `kind` is the seam's own routing field and is not part of the panel
	-- contract, which refuses a spec or a patch carrying a field it does not
	-- know -- whole, rather than dropping the one field, so this has to be off
	-- both paths below.
	local view = {}
	for key, value in pairs(spec) do
		if key ~= 'kind' then view[key] = value end
	end

	-- A second `room` for a room already drawn is a redraw, not a reopen: opening
	-- again would close the live one first, and the close it raises would be
	-- reported back to the state half as the player leaving.
	if roomHandle ~= nil then
		local patched = Panel.Update(roomHandle, view)
		if patched.ok then return end
		roomHandle = nil
	end

	view.owner = OWNER
	view.id = ROOM_ID
	view.on = fromPanel
	-- No `hover`: the preview is the slider's own uncommitted position now, which
	-- rides `slide` rather than a pointer resting on a row there are none of.
	-- Escape is put to the state half rather than taken as a close, because
	-- leaving a room with unsaved changes asks first.
	view.dismiss = 'ask'

	local opened = Panel.Open(view)
	if not opened.ok then
		Open77.log.warn(('[appearance] the fitting room was not drawn: %s')
			:format(tostring(opened.error)))
		return later('room.close', { reason = 'no_view' })
	end
	roomHandle = opened.value.handle
end

-- ── the seam ────────────────────────────────────────────────────────────────

--- Everything the state half has to say, by `kind`.
local function onView(payload)
	if type(payload) ~= 'table' then return end
	local kind = payload.kind

	-- `config` is every string a CEF page would have to draw for itself. Nothing
	-- is drawn here: `menu` and `panel` are handed specs whose text the state
	-- half has already resolved through `locale`, so there is nothing to apply.
	if kind == 'config' then return end

	if kind == 'panel' then return showPanel(payload) end

	if kind == 'panelClosed' then
		if Menu == nil or menuHandle == nil then return end
		local handle = menuHandle
		menuHandle = nil
		closing = true
		Menu.Close(handle, payload.reason)
		closing = false
		return
	end

	if kind == 'status' then
		if Menu == nil or menuHandle == nil then return end
		Menu.SetStatus(menuHandle, payload.text, payload.ok ~= true)
		return
	end

	if kind == 'room' then return showRoom(payload) end

	if kind == 'roomState' then
		if Panel == nil or roomHandle == nil then return end
		-- THE CATEGORY STRIP IS FORWARDED TOO, and it is named here rather than
		-- the payload being passed straight through because this list is the
		-- contract: a `roomState` field that is not written down on this line does
		-- not reach the page, silently, and the panel refuses a patch carrying any
		-- field it does not know. The strip HAS to ride on state and not only on
		-- the first frame -- whoever fills it cannot do so until it has heard the
		-- room open, which happens after the frame has gone out.
		Panel.Update(roomHandle, { sliders = payload.sliders, status = payload.status,
			groups = payload.groups })
		return
	end

	if kind == 'roomClosed' then
		if Panel == nil or roomHandle == nil then return end
		local handle = roomHandle
		roomHandle = nil
		closing = true
		Panel.Close(handle, payload.reason)
		closing = false
		return
	end

	if kind == 'confirm' then
		if Panel == nil or roomHandle == nil then return end
		Panel.Confirm(roomHandle, {
			id = payload.id,
			title = payload.title,
			text = payload.text,
			yes = payload.yes,
			no = payload.no,
		})
		return
	end
end

--- Runs one pass: answers a publication that could not be drawn.
-- Called from the wardrobe's own scheduler pass, a tick after the failure, so
-- the state half is never torn down from inside its own publication.
-- @author dop42
function View.Check()
	local held = undrawn
	if held == nil then return end
	undrawn = nil
	local ran, failure = pcall(M.FromView, held.action, held.payload)
	if not ran then
		Open77.log.error('[appearance] view answer: ' .. tostring(failure))
	end
end

--- Resolves the two view contracts and attaches to the seam.
-- @author dop42
--
-- Attached BEFORE anything can publish, which is the same call `chat/client/view.lua`
-- makes and for the same reason: a handler added after the first publication does
-- not receive it, because a local raise is dispatched rather than queued.
--
-- THERE IS NO `ready` REPORTED. The seam's `ready` exists for a CEF page saying it
-- can be drawn on, and neither view here is one: `menu` and `panel` hold their own
-- open back until their page reports ready and re-send it from their own sweeps. So
-- there is no moment for this bridge to report, and nothing to resync -- the state
-- machines are rebuilt in `Init`, so nothing is ever up when this runs.
function View.Start()
	Menu = OPX.Api.Get('menu')
	Panel = OPX.Api.Get('panel')

	-- Said once, at start, because a view that is simply absent has no other
	-- symptom: the state machines run, refuse correctly and publish, and nothing
	-- appears on the player's screen.
	if Menu == nil then
		Open77.log.warn('[appearance] no menu module: the appearance panel cannot be drawn')
	end
	if Panel == nil then
		Open77.log.warn('[appearance] no panel module: the fitting room cannot be drawn')
	end

	AddEventHandler(M.Event.ON_VIEW, onView)
end

--- Takes down whatever this bridge put up.
-- The two view modules close their own on a stop, but this one may be stopping
-- while they keep running -- and a panel left up with nothing answering it is a
-- player holding a cursor over a dead surface.
-- @author dop42
function View.Stop()
	undrawn = nil
	closing = true
	if Panel ~= nil and roomHandle ~= nil then Panel.Close(roomHandle, 'stopped') end
	if Menu ~= nil and menuHandle ~= nil then Menu.Close(menuHandle, 'stopped') end
	closing = false
	roomHandle, menuHandle = nil, nil
end
