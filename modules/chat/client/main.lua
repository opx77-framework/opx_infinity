--- The client half: the box's state, the typed command path, and the seam a
--- view attaches to.
-- @author dop42

local M = OPX.Modules.Get('chat')

local Result = OPX.Result

local EVENT_VIEW = M.Event.VIEW

-- Fragment both known queue acknowledgement wordings share. The dispatcher
-- carries no field that tells its own acknowledgement from a command's answer,
-- so it is recognised by the English text the platform writes.
local QUEUE_ACK = 'queued by '

-- Most arguments the dispatcher takes, the command name included.
local MAX_ARGUMENTS = 32

-- Which view has reported ready. Nothing is sent to one that has not: a payload
-- sent earlier is dropped, not queued.
local ready

-- Whether the input line is open and holds the keyboard.
local opened

-- The one enabled flag for the whole box, not one per caller.
local enabled

-- Whether the player is down, kept apart from `enabled`: standing up gives back
-- whatever `SetEnabled` last said, and `IsEnabled` does not lie meanwhile.
local down

-- Down states heard, so that a late catch-up read never overrides a newer one.
local downHeard

-- Whether a toast that did not appear has already been logged once.
local toastReported

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state and nothing else: no surface is created here.
-- Everything it has to say to whatever draws the box leaves on EVENT_VIEW, and
-- everything a view has to say comes back through the one function `M.FromView`.
-- A view module attaches by listening to the first and calling the second.
--
-- Every payload names the surface it belongs to, because the box is two
-- concerns on two surfaces: the LOG is drawn on the always-on overlay, and the
-- INPUT line on the interactive layer, which is the only one that may take the
-- keyboard. A view drawing one of them ignores the other's payloads.

--- Tells one view something. `kind` is, for the overlay, 'config', 'line',
--- 'clear' or 'visible'; for the interactive layer, 'config', 'open', 'close',
--- 'focus', 'suggest', 'unsuggest' or 'suggestions'.
local function publish(surface, kind, payload)
	if not ready[surface] then return false end
	payload = payload or {}
	payload.kind = kind
	payload.surface = surface
	TriggerEvent(EVENT_VIEW, payload)
	return true
end

--- The settings the log half of a view needs.
local function logConfig()
	return {
		anchor = M.Settings.ANCHOR,
		offset = M.Settings.OFFSET,
		width = M.Settings.WIDTH,
		history = M.Settings.HISTORY,
		fadeMs = M.Settings.FADE_MS,
		visible = not down,
	}
end

--- The settings the input half of a view needs.
local function inputConfig()
	return {
		anchor = M.Settings.ANCHOR,
		offset = M.Settings.OFFSET,
		width = M.Settings.WIDTH,
		maxLength = M.Settings.MAX_LENGTH,
		placeholder = locale('chat.placeholder'),
	}
end

--- Puts one line in this player's log.
-- Answers a Result: a line nothing can draw is refused rather than silently
-- dropped, exactly as the old export refused `page_not_ready`.
local function addLine(message)
	if type(message) == 'string' then message = { text = message } end
	if type(message) ~= 'table' then return Result.Err('chat.invalidMessage') end
	if not publish('overlay', 'line', { line = message }) then
		return Result.Err('chat.noView')
	end
	return Result.Ok(true)
end

--- Puts one error line, tagged with an author, in the log.
-- No colour is sent with it: the view paints `error` from its own tokens, and a
-- colour written into the line would freeze it outside the stylesheet.
local function addErrorLine(author, text)
	addLine({ kind = 'error', author = author, text = text })
end

--- Tells the player why a command went nowhere, as a toast or a red line.
local function commandRefused(kind, text)
	if M.Settings.NOTIFY == false then
		return addErrorLine(locale('chat.author.command'), text)
	end

	-- One replaced toast, addressed by id: a player who runs a refused command
	-- twice sees one answer, not a pile.
	local raised = OPX.Toast.Show({
		id = 'opx.chat.command',
		kind = kind,
		title = locale('chat.author.command'),
		message = text,
		durationMs = 5000,
	})
	if raised ~= nil then return end

	if not toastReported then
		toastReported = true
		Open77.log.warn('[chat] no toast: command refusals go to the chat box instead')
	end
	addErrorLine(locale('chat.author.command'), text)
end

--- Words a dispatcher refusal for the player and grades it.
-- The codes and the older English phrasings are both recognised; anything else
-- is a refusal a command wrote itself and is already in words.
local function refusalText(name, message)
	if message == 'unknown_command' or message:find("unknown command '", 1, true) == 1 then
		return locale('chat.command.unknown', { command = name }), 'warning'
	end
	if message:find('permission_denied:', 1, true) == 1
		or message:find("permission denied for command '", 1, true) == 1 then
		return locale('chat.command.denied', { command = name }), 'error'
	end
	local lowered = message:lower()
	if lowered:find('rate_limit', 1, true) or lowered:find('rate limit', 1, true) then
		return locale('chat.command.tooFast'), 'warning'
	end
	if message == '' then return locale('chat.command.failed', { command = name }), 'error' end
	return message, 'error'
end

--- Splits a typed command into dispatcher tokens, honouring quotes and escapes.
-- Each token is accumulated in a table and joined once: appending to a string a
-- character at a time is quadratic.
local function commandTokens(text)
	local line = text:sub(2)
	local tokens, buffer, quote, escaped, started = {}, {}, nil, false, false
	for index = 1, #line do
		local character = line:sub(index, index)
		if escaped then
			buffer[#buffer + 1], escaped, started = character, false, true
		elseif character == '\\' then
			escaped, started = true, true
		elseif quote ~= nil then
			if character == quote then quote = nil else buffer[#buffer + 1] = character end
			started = true
		elseif character == '"' or character == "'" then
			quote, started = character, true
		elseif character:match('%s') then
			if started then
				tokens[#tokens + 1] = table.concat(buffer)
				buffer, started = {}, false
				if #tokens > MAX_ARGUMENTS then
					return nil, locale('chat.tooManyArgs', { max = MAX_ARGUMENTS })
				end
			end
		else
			buffer[#buffer + 1], started = character, true
		end
	end
	if escaped then return nil, locale('chat.escapeAtEnd') end
	if quote ~= nil then return nil, locale('chat.unterminatedQuote') end
	if started then
		tokens[#tokens + 1] = table.concat(buffer)
		if #tokens > MAX_ARGUMENTS then
			return nil, locale('chat.tooManyArgs', { max = MAX_ARGUMENTS })
		end
	end
	if #tokens == 0 or tokens[1] == '' then return nil, locale('chat.commandExpected') end
	return tokens
end

--- Hands the keyboard back, then tells the view to close.
-- In that order: a close the view paints before the keyboard goes back is not
-- seen. A box that is already closed is not told twice, because closing it again
-- would fade every line in the log back in.
local function closeChat(asked)
	if opened then
		opened = false
		publish('interactive', 'focus', { hold = false })
	elseif asked ~= true then
		return
	end
	publish('interactive', 'close', {})
end

--- Opens the input line and takes the keyboard, logging every refusal.
local function openChat()
	if not enabled then
		Open77.log.warn('[chat] open refused: the chat is disabled by the server')
		return
	end
	if down then
		Open77.log.warn('[chat] open refused: the player is down')
		return
	end
	if not ready.interactive then
		-- Taking the keyboard before the view can draw the input line would
		-- capture it with nowhere to type. `opened` stays false, so the next
		-- press succeeds as soon as a view reports ready.
		Open77.log.warn('[chat] open refused: no view has reported ready')
		return
	end
	if opened then return end
	opened = true

	-- The focus is asked for BEFORE the open: both travel on one ordered
	-- channel, and the element focus has to land in a surface that already holds
	-- the keyboard.
	publish('interactive', 'focus', { hold = true })
	publish('interactive', 'open', {})
	TriggerServerEvent(M.Event.READY)
end

--- Adds or replaces one completion entry.
-- Accepts three positional arguments or one whole entry, and reads `command` or
-- `name` and `parameters` or `params`, because both spellings are written by the
-- packets that used to carry them.
local function addSuggestion(command, help, parameters)
	if type(command) == 'table' then
		local entry = command
		command = entry.command or entry.name
		help = entry.help
		parameters = entry.parameters or entry.params
	end
	local name = tostring(command or '')
	if name == '' then return Result.Err('chat.invalidCommand') end
	local sent = publish('interactive', 'suggest', {
		suggestion = {
			name = name,
			help = tostring(help or ''),
			params = type(parameters) == 'table' and parameters or {},
		},
	})
	if not sent then return Result.Err('chat.noView') end
	return Result.Ok(true)
end

--- Takes one completion entry back down.
local function removeSuggestion(command)
	local name = tostring(command or '')
	if name == '' then return Result.Err('chat.invalidCommand') end
	if not publish('interactive', 'unsuggest', { name = name }) then
		return Result.Err('chat.noView')
	end
	return Result.Ok(true)
end

--- Empties the visible log, leaving the suggestions alone.
local function clearMessages()
	if not publish('overlay', 'clear', {}) then return Result.Err('chat.noView') end
	return Result.Ok(true)
end

--- Closes and hides the whole box while down, and opens nothing after.
local function setDown(value)
	if down == value then return end
	down = value
	if down then closeChat() end
	-- The whole box, log included: lines keep arriving in the hidden log, so
	-- nothing said while down is lost.
	publish('overlay', 'visible', { visible = not down })
end

--- Catches up once with a player who went down before this module started.
-- A state heard while the read was in flight is newer than the read, and wins.
local function adoptDownState()
	local downed = OPX.Api.Get('downed')
	if downed == nil then return end

	local heard = downHeard
	local answer = downed.IsDown()
	if not answer.ok then
		Open77.log.warn(('[chat] the downed contract did not answer: %s')
			:format(tostring(answer.error)))
		return
	end
	if downHeard ~= heard then return end
	setDown(answer.value.down == true)
end

--- Puts a line another module sent in this player's log.
local function onMessage(message)
	addLine(message)
end

--- Hands a whole list of completion entries to the view.
local function onSuggestions(payload)
	local list = type(payload) == 'table' and payload.suggestions or nil
	publish('interactive', 'suggestions', {
		suggestions = type(list) == 'table' and list or {},
	})
end

--- Toasts a refused command and prints nothing for an accepted one.
-- The box is for what players say and for reports someone asked to read, not
-- for command bookkeeping.
local function onCommandResult(raw, accepted, message)
	raw, message = tostring(raw or ''), tostring(message or '')
	if message:find(QUEUE_ACK, 1, true) ~= nil then return end
	if accepted then return end
	local text, kind = refusalText(raw:match('^/?(%S+)') or raw, message)
	commandRefused(kind, text)
end

--- Sends one typed line, as a command or as a message.
local function submit(text)
	-- The box closes first whatever happens next: nothing below may leave the
	-- keyboard held, and a command that answers nothing gives the view no other
	-- reason to redraw.
	closeChat(true)
	if #text == 0 then return end

	if text:sub(1, 1) ~= '/' then
		-- The host answers whether the event left, and why it did not: a line
		-- the transport dropped must say so rather than vanish.
		local sent, why = TriggerServerEvent(M.Event.SAY, text)
		if not sent then
			Open77.log.warn('[chat] message not sent: ' .. tostring(why))
			addErrorLine(locale('chat.author.network'), locale('chat.messageNotSent'))
		end
		return
	end

	-- An unusable line concerns a command and not a message, so it is answered
	-- like any other command refusal.
	local tokens, failure = commandTokens(text)
	if tokens == nil then
		commandRefused('warning', failure)
		return
	end

	TriggerEvent(M.Event.SUBMITTED, { text = text, tokens = tokens })
	local sent, why = TriggerServerEvent(M.Host.COMMAND_EXECUTE, table.unpack(tokens))
	if not sent then
		Open77.log.warn('[chat] command not sent: ' .. tostring(why))
		commandRefused('error', locale('chat.commandNotSent'))
	end
end

--- What a view module calls. `action` is 'ready', 'submit', 'close' or 'diag'.
-- @author dop42
--
-- The other half of the seam. `ready` says which surface can be drawn on and
-- answers with that surface's settings; `submit` carries one typed line; `close`
-- is the view asking to be closed, which it may do whether or not Lua thinks the
-- box is open; `diag` carries a view-side failure to the client log, which it
-- could not otherwise reach.
-- @param action string
-- @param payload table|nil surface, text
function M.FromView(action, payload)
	payload = type(payload) == 'table' and payload or {}
	local surface = payload.surface == 'interactive' and 'interactive' or 'overlay'

	if action == 'ready' then
		ready[surface] = true
		if surface == 'overlay' then
			publish('overlay', 'config', logConfig())
		else
			publish('interactive', 'config', inputConfig())
		end
		-- The box has somewhere to put them now, so the suggestions are asked
		-- for: this is the signal the server answers with the command list.
		TriggerServerEvent(M.Event.READY)
	elseif action == 'submit' then
		submit(tostring(payload.text or ''))
	elseif action == 'close' then
		closeChat(true)
	elseif action == 'diag' then
		Open77.log.info('[chat] view: ' .. tostring(payload.text or ''))
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	ready = { overlay = false, interactive = false }
	opened = false
	enabled = true
	down = false
	downHeard = 0
	toastReported = false
end

--- Publishes what another module may do to the box.
-- @author dop42
function M.Api()
	OPX.Api.Provide('chat', 1, {
		AddMessage = addLine,
		AddSuggestion = addSuggestion,
		RemoveSuggestion = removeSuggestion,
		ClearMessages = clearMessages,
		SetEnabled = function(value)
			-- Anything but false enables, and the flag is real before any view
			-- exists: this is the one call that does not need one.
			enabled = value ~= false
			if not enabled then closeChat() end
			return Result.Ok(enabled)
		end,
		IsEnabled = function() return Result.Ok(enabled) end,
	})
end

--- Wires the events and catches up with a player who is already down.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.MESSAGE, onMessage)
	RegisterNetEvent(M.Event.SUGGESTIONS, onSuggestions)
	RegisterNetEvent(M.Host.COMMAND_RESULT, onCommandResult)

	-- Core answers a command that asked to read something back on its own name.
	-- It belongs to `core/server/answer.lua` and cannot be renamed from here.
	RegisterNetEvent(M.CORE_MESSAGE, onMessage)

	-- The key belongs to the host, which raises this when the player presses it;
	-- this module has no binding of its own. Escape is swallowed before any
	-- surface sees it, and arrives as the pause key instead.
	AddEventHandler(M.Host.CHAT_KEY, openChat)
	AddEventHandler(M.Host.PAUSE_KEY, function() closeChat() end)

	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
	end)

	adoptDownState()
end

--- Gives the keyboard back and forgets what was on screen.
-- A focus held across a stop leaves the player unable to move.
-- @author dop42
function M.Stop()
	closeChat()
	ready = { overlay = false, interactive = false }
	opened = false
end
