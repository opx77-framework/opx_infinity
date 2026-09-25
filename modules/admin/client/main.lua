--- The client half's spine: the command channel, the answers, and travel.
-- @author dop42
--
-- EVERY STAFF ACTION LEAVES THIS CLIENT AS A TYPED COMMAND LINE. A menu row, a
-- staff row on the eye and a submitted form all end in `Client.Execute`, which
-- sends `open77:command:execute` exactly as the chat box would, and the host
-- resolves `command.<name>` against the ACL before any handler runs. Nothing here
-- calls another module's contract to change the world, and nothing should: a
-- contract call inside one runtime is a function call, and a function call is not
-- a permission check.
--
-- There are no `CreateThread` loops in this half. Exceeding the per-resume
-- instruction budget unwinds straight out of a coroutine body and a
-- `while true ... Wait(n)` loop that hits it is never resumed again, silently;
-- `OPX.Scheduler.Every` is the one loop. A one-shot thread that runs once and
-- exits is fine, and is used wherever something has to yield on a promise.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

--- The client helpers the other client files call.
M.Client = {}
local Client = M.Client

--- Writes a line to the client log AND to the server journal.
---
--- `Open77.log` on the client is a file on the player's machine, and the
--- operator reading it is somewhere else, so a fault nobody can see is a fault
--- nobody fixes.
---
--- THROUGH `OPX.Note`, AND IT USED TO GO THROUGH `diagnostics.PAGE`. That module
--- is declared optional, so every line this function has ever written was
--- conditional on a module nobody checks the state of -- which means a silent
--- journal proved nothing at all: the fault could be absent, or the relay could
--- be. The name tags were diagnosed twice from that silence. `OPX.Note` is core,
--- is always there, is bounded at sixty a session and keeps the local copy
--- regardless, so a missing line is now evidence rather than an unknown.
---
--- It is also the end of the second relay that `core/client/note.lua` was
--- written to replace: two channels competing for one journal is how a line ends
--- up on neither.
-- @author dop42
-- @param message string
function Client.Journal(message)
	OPX.Note('admin', message)
end

-- Fragment both known queue acknowledgement wordings share. The dispatcher
-- answers an accepted command with one, and it is not something to show.
local QUEUE_ACK = 'queued by '

-- How long an answer is still taken as belonging to a line the menu sent.
local AWAITING_MS = 15000

-- Command name to when this client sent it, so the answer lands under the list.
local awaiting = {}

-- Whether this module armed noclip and map travel on this client.
local noclipOn, mapArmed = false, false

--- Scheduler clock in milliseconds.
-- @author dop42
-- @return integer
function Client.NowMs()
	return OPX.Now()
end

--- Whether a genuinely external resource is running.
-- Only for resources OUTSIDE this runtime. A module is asked for with
-- `OPX.Api.Get`, never by name through the host.
-- @author dop42
-- @param resource string
-- @return boolean
function Client.Running(resource)
	return OPX.Lib.Rpc.IsRunning(resource)
end

--- One optional contract, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function Client.Contract(name)
	return M.Contracts[name]
end

--- Raises this module's toast, replacing the one already up rather than stacking.
-- @author dop42
-- @param kind string info, success, warning or error
-- @param message string
function Client.Notice(kind, message)
	-- THE ANSWER IS CHECKED, because it can be refused. `OPX.Toast.Show` answers
	-- nil for a surface that is not up, and this used to discard that: the notice
	-- went nowhere and said so to nobody. Six other modules already fall back to
	-- the client journal on this exact path; these three did not, and the toast's
	-- own docstring claimed they did.
	local raised = OPX.Toast.Show({ id = 'opx.admin', kind = kind, message = message,
		title = locale('admin.toast.title') })
	if raised == nil then Open77.log.info('[admin] ' .. tostring(message)) end
end

--- Raises a notice whose text comes from a catalogue key.
-- @author dop42
-- @param key string
-- @param params table|nil
-- @param kind string|nil
function Client.Toast(key, params, kind)
	Client.Notice(kind or 'info', locale(key, params))
end

--- Sends one command line exactly as the chat box would.
-- @author dop42
-- @param tokens string[]
-- @return boolean whether the line left this client
function Client.Execute(tokens)
	local clean = {}
	for _, token in ipairs(type(tokens) == 'table' and tokens or {}) do
		local word = M.Trimmed(token, 256)
		if word then
			for piece in word:gmatch('%S+') do clean[#clean + 1] = Text.Bytes(piece, 256) end
		end
	end
	if #clean == 0 or #clean > 32 then return false end
	-- The host answers whether the event left and why it did not: a line the
	-- transport dropped must say so rather than vanish.
	local sent, reason = TriggerServerEvent(M.Host.COMMAND_EXECUTE, table.unpack(clean))
	if not sent then
		Open77.log.warn(('[admin] command %s not sent: %s'):format(clean[1], tostring(reason)))
		return false
	end
	awaiting[clean[1]:lower()] = Client.NowMs()
	return true
end

-- Writes an answer under the list when this client sent the line lately.
--
-- Two answers, and the second one is what stops the same sentence going up
-- twice: whether the menu actually put it on screen. `modules/menu` reroutes
-- `SetStatus` to a toast, so "under the list" IS a toast now, and a caller that
-- writes the status and then raises its own is the duplicate the owner reported.
-- With the menu shut the line is only queued, so the caller's toast is still the
-- one thing that will say anything.
local function underList(raw, accepted, message)
	local name = (raw:match('^/?(%S+)') or ''):lower()
	local sentAt = awaiting[name]
	if sentAt == nil or Client.NowMs() - sentAt > AWAITING_MS then return false, false end
	local shown = M.Menu.Status(message, accepted == true)
	-- THE ANSWER IS THE SIGNAL, and it was being read for its text alone. The
	-- menu had already sent whatever list read the line makes necessary, on a
	-- fixed 1200ms sleep, because nothing told it the server was done -- while
	-- this function was holding exactly that. It is told now.
	M.Menu.Answered(name, accepted == true)
	-- A refused switch flipped its own box already; the redraw puts back the
	-- state that actually holds.
	if accepted ~= true then M.Menu.Refresh() end
	return true, shown == true
end

--- Whether this module has noclip on, as the menu's switch row reads it.
-- @author dop42
-- @return boolean
function Client.IsNoclip()
	return noclipOn
end

--- Whether a player's replicated health snapshot has god mode on.
-- @author dop42
-- @param playerId integer|nil nil for this player
-- @return boolean|nil nil when it cannot be read
function Client.GodMode(playerId)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getHealthState) ~= 'function' then return nil end
	local read, health
	if playerId == nil then
		read, health = pcall(players.getHealthState)
	else
		read, health = pcall(players.getHealthState, playerId)
	end
	if not read or type(health) ~= 'table' or type(health.godMode) ~= 'boolean' then return nil end
	return health.godMode
end

--- One `Open77.travel` function, or nil when this client build lacks it.
-- @author dop42
-- @param name string
-- @return function|nil
function Client.TravelNative(name)
	local travel = Open77.travel
	if type(travel) ~= 'table' or type(travel[name]) ~= 'function' then return nil end
	return travel[name]
end

-- Applies one travel native, saying so when it is missing or refuses.
local function applyTravel(name, value)
	local native = Client.TravelNative(name)
	if native == nil then
		Open77.log.warn(('[admin] Open77.travel.%s is not in this client build'):format(name))
		Client.Toast('admin.client.travelMissing', nil, 'error')
		return false
	end
	local ok, reason = native(value)
	if not ok then Open77.log.warn(('[admin] %s refused: %s'):format(name, tostring(reason))) end
	return ok == true
end

-- Handles the dispatcher's own refusals: no access, and no such command.
local function onCommandResult(raw, accepted, message)
	if type(raw) ~= 'string' or type(message) ~= 'string' then return end
	if accepted == true then
		if message:find(QUEUE_ACK, 1, true) then return end
		if underList(raw, true, message) and message:find('\n', 1, true) then
			Client.Notice('info', message)
		end
		return
	end
	M.Controls.Answered(raw, false)
	local name = raw:match('^/?(%S+)') or raw
	if message == 'unknown_command' then
		message = locale('admin.client.unknownCommand', { command = name })
	elseif message:find('permission_denied:', 1, true) == 1 then
		message = locale('admin.client.denied', { command = name })
	end
	underList(raw, false, message)
end

-- Shows this module's own answer under the list, in chat, or as a toast.
local function onAnswer(raw, accepted, message, kind)
	if type(raw) ~= 'string' or type(message) ~= 'string' or message == '' then return end
	local _, shown = underList(raw, accepted == true, message)
	if M.Controls.Answered(raw, accepted == true) then return end
	-- ONE SENTENCE, ONE TOAST. This raised the module's own toast unconditionally,
	-- and `underList` above had just put the same words up as well: the owner gave
	-- themselves an item as staff and got the line twice, once titled STAFF and
	-- once bare. That was not a duplicate when it was written -- `SetStatus` drew
	-- a line under the menu's list back then -- and `modules/menu` rerouting it to
	-- a toast turned two surfaces into one. `onCommandResult` above already keeps
	-- this rule, including the exception: the status lane is a single truncated
	-- line, so an answer that spans several still needs the toast to be readable.
	if shown and not message:find('\n', 1, true) then return end
	if kind ~= 'info' and kind ~= 'success' and kind ~= 'warning' and kind ~= 'error' then
		kind = accepted == true and 'success' or 'error'
	end
	Client.Notice(kind, message)
end

-- Applies noclip, a speed, map picking or a clipboard row sent by the server.
local function onTravel(action, value)
	if action == 'noclip' then
		if applyTravel('setNoclip', value == true) then noclipOn = value == true end
		M.Menu.Refresh()
		M.Controls.Noclip(noclipOn)
	elseif action == 'speed' then
		local speed = Text.Finite(value)
		if speed and speed >= 0.1 and speed <= 500 and applyTravel('setNoclipSpeed', speed) then
			M.Controls.Speed(speed)
		end
	elseif action == 'mapPick' then
		mapArmed = value == true and applyTravel('setMapPick', true)
		if value ~= true then applyTravel('setMapPick', false) end
		M.Controls.MapPick(mapArmed)
	elseif action == 'copy' then
		-- Shape-checked before it reaches the clipboard: this is the one place the
		-- server hands this client a string to put somewhere the player will paste.
		if type(value) ~= 'string' or #value > 160 or not value:match('^{ NAME = ') then return end
		local clipboard = Open77.clipboard
		if type(clipboard) == 'table' and type(clipboard.setText) == 'function' then
			pcall(clipboard.setText, value)
		end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the held state. Never yields, and reaches no other module.
-- @author dop42
function M.Init()
	M.Contracts = {}
	awaiting = {}
	noclipOn, mapArmed = false, false
end

--- Publishes what another module may ask of the staff menu.
-- Opening is ASKING: the opener is a restricted command like any other, so `ok`
-- means the line was sent, never that the ACL allowed it.
-- @author dop42
function M.Api()
	OPX.Api.Provide('admin', 1, {
		Open = function()
			if M.Menu.IsOpen() then return OPX.Result.Ok({ open = true }) end
			if not Client.Execute({ M.OPENER }) then return OPX.Result.Err('not_sent') end
			return OPX.Result.Ok({ queued = true })
		end,
		OpenAt = function(screen, arg, form)
			if not M.Menu.OpenAt(screen, arg, form) then return OPX.Result.Err('not_sent') end
			return OPX.Result.Ok(true)
		end,
		Close = function()
			M.Menu.Close()
			return OPX.Result.Ok(true)
		end,
		State = function()
			return OPX.Result.Ok({ open = M.Menu.IsOpen(), screen = M.Menu.Screen() })
		end,
	})
end

--- Wires the events, registers the keys and the passes. Runs on a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.character = OPX.Api.Get('character')
	M.Contracts.menu = OPX.Api.Get('menu')
	M.Contracts.form = OPX.Api.Get('form')
	M.Contracts.target = OPX.Api.Get('target')
	M.Contracts.inventory = OPX.Api.Get('inventory')
	M.Contracts.downed = OPX.Api.Get('downed')
	M.Contracts.prompts = OPX.Api.Get('prompts')
	-- THE ONLY CONTRACT THE STAFF MENU ACTS THROUGH RATHER THAN READS. The Dev
	-- screen's showroom rows end here instead of in a command line, because the
	-- commands they would have used were deleted with the rest of the placement
	-- commands. It is optional like every other: without it those two rows say so
	-- when they are pressed.
	M.Contracts.dealership = OPX.Api.Get('dealership')

	if M.Contracts.menu == nil then
		Open77.log.warn('[admin] no menu contract: the staff menu cannot be drawn. Every command ' ..
			'still works from the chat box.')
	end
	if M.Contracts.form == nil then
		Open77.log.warn('[admin] no form contract: the rows that ask for a value are greyed. ' ..
			'Their commands still work from the chat box.')
	end
	if M.Contracts.target == nil then
		Open77.log.warn('[admin] no target contract: no staff row is drawn on the eye.')
	end
	if M.Contracts.prompts == nil then
		Open77.log.info('[admin] no prompts contract: the travel controls are not drawn.')
	end

	RegisterNetEvent(M.Host.COMMAND_RESULT, onCommandResult)
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.TRAVEL, onTravel)

	-- A point the player double-clicked on the map, sent back as a travel command
	-- so that the server decides whether they may go there.
	AddEventHandler('open77:map:picked', function(x, y, z)
		if not mapArmed then return end
		x, y, z = Text.Finite(x), Text.Finite(y), Text.Finite(z)
		if x == nil or y == nil or z == nil then return end
		Client.Execute({ M.Command.SELF_MAPTRAVEL, ('%.3f'):format(x), ('%.3f'):format(y),
			('%.3f'):format(z) })
	end)

	M.Keys.Start()
	-- Before the controls: its first transition reads what this read.
	M.Noclip.Start()
	M.Controls.Start()
	M.Tags.Start()
	-- After the state half: it attaches to `ON_TAGS`, and the first payload that
	-- event ever carries is the config `Tags.Start` publishes on switch-on.
	M.TagsView.Start()
	M.Combat.Start()
	M.Doors.Start()
	-- The world announcement. Registered here with the rest so a client that
	-- joins late is listening before an operator's next line, and NOT tied to the
	-- menu: an announcement reaches a player who has never opened the panel.
	M.Announce.Start()
	-- Before the menu: the menu's own handlers hand the access map straight to
	-- the eye, and a map that arrived before the rows were built would register
	-- an empty set and never be asked again.
	M.Target.Start()
	M.Menu.Start()
end

--- Switches off the noclip and the map picking this module armed, and takes the
--- menu, the form and the staff rows down with it.
-- @author dop42
function M.Stop()
	-- THE ANSWERS ARE READ. Both were discarded, and this is the one path that
	-- puts a member of staff back on their feet: a refused `setNoclip(false)`
	-- with the flags cleared underneath it leaves them flying with nothing left
	-- that knows to switch it off. The flags follow what actually happened, so a
	-- later stop -- or the toggle itself -- still has something to act on.
	if noclipOn and Client.TravelNative('setNoclip') then
		local called, off, why = pcall(Open77.travel.setNoclip, false)
		if called and off ~= false then
			noclipOn = false
		else
			Open77.log.error(('[admin] noclip would not switch off: %s')
				:format(tostring(called and why or off)))
		end
	else
		noclipOn = false
	end
	if mapArmed and Client.TravelNative('setMapPick') then
		local called, off = pcall(Open77.travel.setMapPick, false)
		mapArmed = not (called and off ~= false)
	else
		mapArmed = false
	end
	M.Menu.Close()
	M.Menu.Stop()
	M.TagsView.Stop()
	M.Tags.Stop()
	M.Doors.Stop()
	M.Target.Stop()
	M.Controls.Stop()
	M.Noclip.Stop()
end
