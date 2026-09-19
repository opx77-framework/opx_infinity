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
-- `subtitle`, `intro`, `search`, `loading`, `labels`, `actions`, `tools`, `tabs`,
-- `tab`, `selected`, `summary` and `status`, which is the panel contract's
-- PATCHABLE set field for field, down to the batched `roomItems` that `Append`
-- takes and the `confirm` that `Confirm` takes. The wardrobe's own header records
-- where that came from: "the panel was a list drawn by a menu resource and the
-- fitting room a page drawn by a panel resource". Both of those resources have
-- since been rebuilt as modules in here. Writing a third Vue view would be a
-- second answer to a question this runtime has already answered twice, and it
-- would be the answer that did not get the search plate, the paging, the confirm
-- step or the keyboard for free.
--
-- NOTHING HERE DECIDES ANYTHING. Every action is forwarded verbatim and every
-- one of them is re-checked on the other side against state this file cannot
-- see: a record name is checked against the catalogue the state half streamed,
-- a slot against the seven it dresses, a button against the list it drew. A
-- modified page that named a jacket nobody offered gets the same nothing a
-- mistyped one does -- and what a character may actually WEAR is settled further
-- out still, by the server, when the clothing half saves the record.
--
-- THE FAILURE PATH IS DEFERRED ON PURPOSE. When a view refuses to open there is
-- nothing to draw and the state half has to be told -- but it publishes `room`
-- from inside `begin`, which goes on to take the camera and start the catalogue
-- stream afterwards. Answering inline would tear the room down underneath a
-- function still setting it up, so the answer is left for the upkeep pass one
-- tick later. See `undrawn`.

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

-- What the catalogue batches did since the last upkeep pass: entries the view
-- took, and the first refusal among them.
--
-- SUMMED, NOT HELD LIKE `undrawn`. A catalogue is twenty-odd batches and the
-- stream yields between them, so a whole room's worth arrives between two
-- upkeep passes; "last one wins" is right for a failure to draw the room and
-- wrong for a count, which would come out as the size of whichever batch
-- happened to be last.
local batchAdded, batchError = 0, nil

--- Records what one batch did.
local function countBatch(added, failure)
	batchAdded = batchAdded + added
	if failure ~= nil and batchError == nil then batchError = failure end
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

	if action == 'select' then
		return M.FromView('room.select', { item = payload.item, tab = payload.tab })
	end
	if action == 'hover' then
		return M.FromView('room.hover', { item = payload.item, tab = payload.tab })
	end
	if action == 'leave' then return M.FromView('room.leave') end
	if action == 'tab' then return M.FromView('room.tab', { tab = payload.tab }) end
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
	-- The room previews a piece under the pointer before it is chosen, which is
	-- the whole reason the seam has a `room.hover`.
	view.hover = true
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

--- Adds a batch of catalogue entries to the open room, and says what it did.
--
-- THE ANSWER IS DEFERRED FOR THE SAME REASON THE OPEN'S IS. This runs inside the
-- state half's own publication, on the stream thread, and `room.items` sets the
-- status line and refreshes -- which publishes again, into a handler still on
-- this stack. See `later` and the header.
local function showItems(payload)
	if Panel == nil or roomHandle == nil then
		return later('room.items', { added = 0, error = 'no_view' })
	end
	local items = payload.items or {}
	local added = Panel.Append(roomHandle, items, payload.final == true)
	-- A REFUSED BATCH IS NOT A DELIVERED ONE, and it used to be reported as one:
	-- a warn on a log the operator cannot read was the entire consequence, with
	-- the room going on saying it was reading. `Append` already answers honestly;
	-- this is the caller finally reading the answer.
	countBatch(added.ok and #items or 0, (not added.ok) and tostring(added.error) or nil)
	-- The catalogue read can fail, and when it does the state half sends its
	-- reason on the same publication as the empty final batch.
	if payload.status ~= nil then
		Panel.Update(roomHandle, { status = { text = tostring(payload.status), kind = 'error' } })
	end
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
	if kind == 'roomItems' then return showItems(payload) end

	if kind == 'roomState' then
		if Panel == nil or roomHandle == nil then return end
		Panel.Update(roomHandle, {
			tabs = payload.tabs,
			tab = payload.tab,
			selected = payload.selected,
			summary = payload.summary,
			status = payload.status,
		})
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
	if batchAdded ~= 0 or batchError ~= nil then
		local added, failure = batchAdded, batchError
		batchAdded, batchError = 0, nil
		local told, why = pcall(M.FromView, 'room.items', { added = added, error = failure })
		if not told then
			Open77.log.error('[appearance] view batch answer: ' .. tostring(why))
		end
	end

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
	batchAdded, batchError = 0, nil
	closing = true
	if Panel ~= nil and roomHandle ~= nil then Panel.Close(roomHandle, 'stopped') end
	if Menu ~= nil and menuHandle ~= nil then Menu.Close(menuHandle, 'stopped') end
	closing = false
	roomHandle, menuHandle = nil, nil
end
