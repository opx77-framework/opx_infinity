--- The staff menu's server half: the opener command and the list refreshes.
-- @author dop42
--
-- The access map this file sends is a DRAWING HINT and nothing else. It says
-- which commands the ACL would let this operator run, so the menu and the eye can
-- grey out the rest; every one of those commands is still resolved against
-- `command.<name>` by the host when it is actually run. A client that ignored the
-- map, or forged one, would gain exactly nothing.
--
-- Registered last, so the map lists what every other file registered.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Inventory = M.Inventory
local Command = M.Command

M.Menu = {}
local Menu = M.Menu

-- Rows per roster, destination, catalogue or bag event. The host discards an
-- event carrying more than 1024 value nodes and says nothing.
local CHUNK = 20

-- The refresh topics a client may ask for. Anything else is dropped.
local TOPICS = { roster = true, locations = true, access = true, items = true, bag = true,
	characters = true }

-- Every command name the menu may issue, this module's own and the linked ones.
local function menuCommands()
	local names = {}
	for _, command in ipairs(Server.Commands()) do names[#names + 1] = command.name end
	for _, name in pairs(M.Section('LINKS')) do
		if type(name) == 'string' and name ~= '' then names[#names + 1] = name end
	end
	return names
end

-- Which menu commands this operator's ACL grants, and whether it could be read.
local function accessOf(playerId)
	local access, known = {}, true
	for _, name in ipairs(menuCommands()) do
		local allowed = Server.Permitted(playerId, name)
		if allowed == nil then known = false end
		if allowed == true then access[name] = true end
	end
	return access, known
end

-- Sends rows to one client in chunks under the event size limit.
local function pushChunks(playerId, event, rows, extra)
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + CHUNK, #rows) do chunk[#chunk + 1] = rows[index] end
		local payload = { rows = chunk, offset = offset, total = #rows,
			done = offset + #chunk >= #rows }
		for key, value in pairs(extra or {}) do payload[key] = value end
		TriggerClientEvent(event, playerId, payload)
		offset = offset + #chunk
	until offset >= #rows
end

-- Sends the roster, as seen from the operator, to the operator.
local function pushRoster(playerId)
	pushChunks(playerId, M.Event.ROSTER, M.World.Roster(playerId))
end

-- Sends the destination list to the operator, in chunks.
local function pushLocations(playerId)
	local rows = {}
	for _, row in ipairs(M.World.Locations()) do
		rows[#rows + 1] = { name = row.name, label = row.label, runtime = row.runtime }
	end
	pushChunks(playerId, M.Event.LOCATIONS, rows)
end

-- Sends the item catalogue for the pickers.
local function pushItems(playerId)
	local index, code = Inventory.Catalog()
	local rows = {}
	for _, entry in ipairs(index and index.items or {}) do
		rows[#rows + 1] = { name = entry.name, label = entry.label, category = entry.category,
			weapon = entry.weapon or nil, ammo = entry.ammo or nil }
	end
	pushChunks(playerId, M.Event.ITEMS, rows, { error = code })
end

-- Sends one bag's stacks for the removal picker. Yields.
local function pushBag(playerId, token)
	local target, _, _, targetCode = Inventory.Target(playerId, token)
	local bag, code
	if target ~= nil then bag, code = Inventory.Bag(target) end
	local index = bag and Inventory.Catalog() or nil
	local rows = {}
	for _, row in ipairs(bag and bag.items or {}) do
		rows[#rows + 1] = { slot = row.slot, name = row.name, count = row.count,
			label = Inventory.LabelOf(index, row.name) }
	end
	pushChunks(playerId, M.Event.BAG, rows, { target = token, error = targetCode or code })
end

--- One player's characters, tagged with the player they were read for.
-- The tag is what makes a late answer harmless: an operator who has moved on to
-- somebody else drops it rather than drawing another account's rows as theirs.
-- Coroutine only.
local function pushCharacters(playerId, token)
	local target = tonumber(token)
	local rows, code
	if target ~= nil and target > 0 then
		rows, code = M.Characters.Rows(target)
	else
		code = 'bad_target'
	end
	pushChunks(playerId, M.Event.CHARACTERS, rows or {}, { target = token, error = code })
end

--- Registers the opener command and the refresh event.
-- @author dop42
function Menu.Register()
	Server.Command(Command.MENU, {
		help = 'admin.help.menu', inGame = true, read = true,
		handler = function(source)
			local access, known = accessOf(source)
			TriggerClientEvent(M.Event.OPEN, source, {
				access = access,
				aclKnown = known,
				inventory = Inventory.Running(),
			})
			M.Players.PushBodies(source)
			pushRoster(source)
			pushLocations(source)
			if Inventory.Running() then CreateThread(function() pushItems(source) end) end
		end,
	})

	-- The one inbound event that is not a command, and it mutates nothing: it
	-- asks for a list again. The opener's grant is re-checked on every one, so a
	-- client whose grant was taken away stops being told who is connected.
	RegisterNetEvent(M.Event.REFRESH, function(topic, arg)
		local player = tonumber(source) or 0
		if player <= 0 or not TOPICS[topic] then return end
		if (topic == 'bag' or topic == 'characters') and
			(type(arg) ~= 'string' or #arg > 32) then
			return
		end

		-- Named, so a client waiting on one of several lists can tell which
		-- `error.tooFast` is its own.
		if Server.Cooled(player, 'refresh:' .. topic,
			OPX.Tune.Number('ADMIN_RATE_REFRESH_MS', 0)) then
			return OPX.Refuse(player, 'error.tooFast', 'adminRefresh')
		end

		if Server.Permitted(player, M.OPENER) ~= true then
			-- An empty map, so a client that drew staff rows takes them down again.
			if topic == 'access' then
				TriggerClientEvent(M.Event.ACCESS, player,
					{ access = {}, aclKnown = true, inventory = false })
			end
			return
		end

		if topic == 'roster' then
			pushRoster(player)
		elseif topic == 'locations' then
			pushLocations(player)
		elseif topic == 'items' then
			CreateThread(function() pushItems(player) end)
		elseif topic == 'bag' then
			-- The bag pickers end in one of these two commands; without either
			-- grant there is no reason for this operator to read a bag at all.
			if Server.Permitted(player, Command.INVENTORY_VIEW) ~= true and
				Server.Permitted(player, Command.INVENTORY_REMOVE) ~= true then
				return
			end
			CreateThread(function() pushBag(player, arg) end)
		elseif topic == 'characters' then
			-- The same idiom the bag uses one branch up: a list is served only to an
			-- operator who is granted something it feeds. Without the read grant
			-- there is no reason for them to be looking at another account's rows at
			-- all, and the list is a roster of what they could then rename or
			-- delete.
			if Server.Permitted(player, Command.CHARACTER_LIST) ~= true then return end
			CreateThread(function() pushCharacters(player, arg) end)
		else
			local access, known = accessOf(player)
			TriggerClientEvent(M.Event.ACCESS, player,
				{ access = access, aclKnown = known, inventory = Inventory.Running() })
			M.Players.PushBodies(player)
		end
	end)

	-- How a staff client's rows on the eye registered, written to the server log:
	-- a row that was refused is otherwise only visible on that one machine.
	RegisterNetEvent(M.Event.TARGET_REPORT, function(text)
		local player = tonumber(source) or 0
		if player <= 0 or type(text) ~= 'string' then return end
		if Server.Cooled(player, 'target:report', 1000) then return end
		if Server.Permitted(player, M.OPENER) ~= true then return end
		Open77.log.info(('[admin] target rows, player %d: %s')
			:format(player, M.Trimmed(text, 160) or '?'))
	end)
end
