--- The hotbar peek: a few seconds of "what is in slots one to five".
-- @author dop42
--
-- WHAT IT IS FOR. The hotbar keys work with the bag shut, which is the point of
-- them, and that is also the problem: nothing on screen says what they are bound
-- to until you open the bag and look, by which time you did not need the key. So
-- one key shows the row for a few seconds and takes it away again.
--
-- IT COSTS NOTHING ON THE WIRE, and that is why it can be instant. The client
-- already holds the whole bag -- `Screen.Own()` is the mirror the server pushes
-- on every change, and `changesOf` in `client/main.lua` exists because of it --
-- so a peek is a read of a table this runtime already has. A version that asked
-- the server would be a round trip in front of a gesture whose whole value is
-- that it answers before you have finished pressing the key.
--
-- LUA KEEPS NO TIMER. The page is told how long to hold the row and takes it
-- down itself, exactly as a toast carries its own lifetime: a `Wait` loop or a
-- scheduler job here would be a client paying every tick for a thing that is on
-- screen for four seconds at a time. Lua keeps one number -- when the row is due
-- to go -- and that is only so a bag that CHANGES while the row is up can be
-- redrawn without restarting its countdown.
--
-- IT RESOLVES THE ROWS ITSELF rather than shipping the catalogue. The peek draws
-- on the OVERLAY layer, and the catalogue lives on the interactive screen: the
-- page that draws the grid has it, the page that draws this does not. Five
-- resolved rows on the wire is smaller than the catalogue and does not put a
-- second copy of it on a layer that would only ever read five entries from it.

local M = OPX.Modules.Get('inventory')

local Options = M.Options
local Catalog = M.Catalog

M.Slotbar = {}
local Slotbar = M.Slotbar

--- What the page listens on. One channel up, and none down: the row answers
--- nothing and the player cannot touch it.
local CHANNEL = 'inventory:slotbar'

--- When the row on screen is due to come down, in `OPX.Now()` milliseconds. Zero
--- when nothing is up. Not a claim that it IS up -- the page owns that -- only
--- this runtime's best idea of it, which is all a redraw needs.
local dueAt = 0

--- The stack sitting in one slot of a bag payload, or nil.
-- Walked rather than indexed because `items` is a LIST and the slot is a field
-- on each entry: the payload is sparse, so the fifth entry is not slot five.
local function stackAt(bag, slot)
	local items = type(bag) == 'table' and type(bag.items) == 'table' and bag.items or nil
	if items == nil then return nil end
	for index = 1, #items do
		local entry = items[index]
		if type(entry) == 'table' and tonumber(entry.slot) == slot then return entry end
	end
	return nil
end

--- The row for one slot: always present, so the page draws an empty cell rather
--- than closing a gap and renumbering what the player is trying to memorise.
local function rowFor(bag, slot)
	local row = {
		slot = slot,
		key = M.Keys.Effective('opx.inventory.hotbar' .. slot)
			or Options.KEYS_HOTBAR[slot] or '',
	}

	local stack = stackAt(bag, slot)
	if stack == nil then return row end

	row.name = stack.name
	row.count = tonumber(stack.count) or 0

	-- `ViewOf` answers nil for a name the catalogue does not carry, which is not
	-- an error here: an item can be in a bag and out of the catalogue after a
	-- data file is edited, and a row with a name and no picture is still a row
	-- that says what is in the slot.
	local view = Catalog.ViewOf(stack.name)
	-- The stack's OWN label first, the rule `labelOf` in the page follows: a key
	-- in slot 2 reads as the car it opens, not as "Vehicle key".
	local own = type(stack.metadata) == 'table' and stack.metadata.label or nil
	row.label = (type(own) == 'string' and own ~= '' and own)
		or (view and view.label) or Catalog.Label(stack.name)
	row.image = view and view.image or nil
	return row
end

--- Whether the player's own bag holds anything in one hotbar slot.
---
--- Published so the hotbar KEYS can ask before they send. The server is still
--- the authority on what a slot holds and still refuses an empty one -- this is
--- the client declining to ask a question it already knows the answer to, which
--- is the difference between a key that does nothing and a key that fetches a
--- refusal and puts it on screen.
-- @author dop42
-- @param slot integer
-- @return boolean
function Slotbar.Holds(slot)
	local index = tonumber(slot)
	if index == nil then return false end
	return stackAt(M.Screen.Own(), index) ~= nil
end

--- Every slot the hotbar has, in order.
local function rows(bag)
	local list = {}
	for slot = 1, Options.HOTBAR_SLOTS do list[slot] = rowFor(bag, slot) end
	return list
end

--- Says a refusal out loud, once per reason per session.
--
-- WRITTEN BECAUSE THE FIRST VERSION COULD NOT BE DIAGNOSED. The owner pressed the
-- key and nothing happened, and every refusal here answered a string to a caller
-- that discarded it: no toast, no log, and `Open77.log` on a client writes to the
-- PLAYER'S machine rather than the operator's journal, so even a log line would
-- not have reached anyone who could act on it. `OPX.Note` is the bounded relay
-- that does -- sixty per session, decisions and failures only, which is exactly
-- what this is.
--
-- Once per REASON, not once per press: a player leaning on the key must not be
-- able to spend the session's whole allowance in a second.
local reported = {}
local function refuse(reason)
	if not reported[reason] then
		reported[reason] = true
		OPX.Note('inventory', ('the hotbar peek refused: %s'):format(reason))
	end
	return false, reason
end

--- Puts the row on screen for the configured time, or refuses and says why.
--
-- The guard is `pressHotbar`'s, word for word, and deliberately: a peek is the
-- same gesture as a use minus the use, so anything that makes a hotbar key do
-- nothing has to make this do nothing too. A row drawn over the open bag would
-- be the same five slots twice, and a row drawn over a downed player is the
-- screen telling them about sandwiches.
-- @author dop42
-- @return boolean
-- @return string|nil why it was refused
function Slotbar.Peek()
	if Options.HOTBAR_SLOTS <= 0 then return refuse('no_hotbar') end

	local Screen = M.Screen
	if Screen.IsOpen() or Screen.IsDown() then return refuse('busy') end

	-- NO BAG IS NOT A REFUSAL ANY MORE, IT IS A QUESTION. The mirror is filled by
	-- `M.Event.OWN`, which the server pushes from `Containers.Publish` -- at the
	-- HELLO handshake through `Players.Attach`, and on every later change. A
	-- player whose attach answered `not_loaded` because the character was not up
	-- yet therefore holds nil until the first pickup, and the peek is exactly the
	-- gesture such a player makes first. Asking costs one event and is rate
	-- limited server-side to one every two seconds; the row appears on the next
	-- press rather than never.
	local bag = Screen.Own()
	if bag == nil then
		TriggerServerEvent(M.Event.HELLO)
		return refuse('no_bag')
	end

	local holdMs = Options.HOTBAR_PEEK_MS
	local sent = OPX.UI.Send('overlay', CHANNEL,
		{ slots = rows(bag), holdMs = holdMs })
	if not sent then
		dueAt = 0
		return refuse('surface_unavailable')
	end

	-- A second press RESTARTS the hold rather than being ignored, because the
	-- gesture a player makes when the row is fading is "keep it there".
	dueAt = OPX.Now() + holdMs
	return true
end

--- Redraws a row that is already up, keeping its countdown.
--
-- WITHOUT RESTARTING THE HOLD, which is the whole of why this is not just
-- `Peek()` again: a bag that changes twice a second while the row is up would
-- otherwise keep the row on screen for as long as the player keeps picking
-- things up. The page is told what is LEFT of the hold, so the row updates in
-- place and still goes away when it was always going to.
-- @author dop42
function Slotbar.Refresh()
	if dueAt == 0 or Options.HOTBAR_SLOTS <= 0 then return end

	local remaining = dueAt - OPX.Now()
	if remaining <= 0 then
		dueAt = 0
		return
	end

	local bag = M.Screen.Own()
	if bag == nil then
		dueAt = 0
		return
	end

	if not OPX.UI.Send('overlay', CHANNEL, { slots = rows(bag), holdMs = remaining }) then
		dueAt = 0
	end
end

--- Takes the row off now. For the paths that make it wrong rather than stale --
--- the bag opening over it, the character leaving.
-- @author dop42
function Slotbar.Hide()
	if dueAt == 0 then return end
	dueAt = 0
	OPX.UI.Send('overlay', CHANNEL, { slots = {}, holdMs = 0 })
end

--- Whether this runtime believes a row is up. For the tests and for `Refresh`.
-- @author dop42
-- @return boolean
function Slotbar.IsUp()
	return dueAt > 0 and OPX.Now() < dueAt
end

--- Listens for the three things that make a row on screen wrong.
--
-- HERE AND NOT IN `client/main.lua`, on purpose. These are all LOCAL events that
-- file already raises, so subscribing from this side keeps the peek's whole
-- behaviour in the file named after it -- and `main.lua` does not grow three
-- lines about a feature it does not otherwise know exists.
--
-- Called from `Start`, never at load: `AddEventHandler` at file scope would
-- subscribe a module the operator may have turned off, and a handler firing
-- against half-built state is the thing phases exist to prevent.
-- @author dop42
function Slotbar.Wire()
	if Options.HOTBAR_SLOTS <= 0 then return end

	-- The bag changed under a row that is up. Redrawn, not re-raised: `Refresh`
	-- keeps the countdown so a run of pickups cannot pin the row to the screen.
	AddEventHandler(M.Event.ON_CHANGED, function() Slotbar.Refresh() end)

	-- The bag opened over it. The grid draws the same five slots with the same
	-- keycaps, so leaving the row up would be the answer twice.
	AddEventHandler(M.Event.ON_OPENED, function() Slotbar.Hide() end)
end
