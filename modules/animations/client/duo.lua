--- The invitation to an emote with a nearby player, on the invited screen.
-- @author dop42
--
-- The server chose this player as the nearest one in range and asks them; the
-- answer goes back to the server, which measures the distance again and only
-- then hands the pair to the platform's coordinator. Nothing here plays.
--
-- Two ways to answer, because one of them can be unavailable: a two-row menu,
-- and the toast that names the typed command (`/e accept`). The menu is refused
-- while another one is up -- the inventory, a shop -- and the toast still says
-- how to answer. An invitation nobody answers is withdrawn by the server.

local M = OPX.Modules.Get('animations')
local Common = M.Common
local Opt = M.Opt
local Runtime = M.Runtime

M.Invite = {}
local Invite = M.Invite

local OWNER = 'animations'
local SPEC_ID = 'animations.invite'

-- The invitation on screen: id, pair, inviter's name and the menu handle.
local current = nil

-- Calls one function of the menu contract, answering its value or nil.
local function call(name, ...)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api[name]) ~= 'function' then return nil end
	local ran, answer = pcall(api[name], ...)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value or answer
end

-- Takes the invitation's menu down, if it is up.
local function closeMenu()
	local shown = current and current.handle or nil
	if current ~= nil then current.handle = nil end
	if shown ~= nil then call('Close', shown, 'invite') end
end

-- Sends the answer once and forgets the invitation.
local function answer(accepted)
	if current == nil then return end
	local id = current.id
	closeMenu()
	current = nil
	local sent = Runtime.Reply(id, accepted)
	if not sent.ok then Runtime.Refuse(sent.error) end
end

--- Whether an invitation is waiting for this player's answer.
-- @author dop42
-- @return boolean
function Invite.Pending()
	return current ~= nil
end

-- The menu's rows. Shape-checked: the menu also raises every action on its
-- public bus.
local function onMenu(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end
	if current == nil or payload.handle ~= current.handle then return end
	if payload.action == 'close' then
		-- Closed without a choice: the invitation still stands until it
		-- expires, and the typed command still answers it.
		current.handle = nil
		return
	end
	if payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
	answer(payload.data.accept == true)
end

-- The name a pair reads, or its id when no locale names it.
local function pairLabel(id)
	local key = 'animations.duo.name.' .. id
	return OPX.Locale.Exists(key) and locale(key) or id
end

-- Takes an invitation from the server and puts it in front of the player.
local function onInvite(inviteId, pairId, fromName)
	inviteId = Common.Integer(inviteId, 1, M.MAX_REQUEST_ID)
	if inviteId == nil or not Common.Text(pairId, 32) or not pairId:match('^[%l%d_]+$') then
		return
	end
	local name = Common.Text(fromName, 32) and fromName or '?'
	-- A newer invitation replaces an unanswered one; the server withdrew it.
	closeMenu()
	current = { id = inviteId, pair = pairId, name = name }

	local emote = pairLabel(pairId)
	local command = Opt.PlayCommand()
	if command then
		Runtime.Notify('info', 'animations.duo.invited',
			{ name = name, emote = emote, command = '/' .. command })
	else
		Runtime.Notify('info', 'animations.duo.invitedMenu', { name = name, emote = emote })
	end

	local opened = call('Open', {
		owner = OWNER,
		id = SPEC_ID,
		title = locale('animations.duo.title'),
		on = onMenu,
		cursor = 'accept',
		items = {
			{ id = 'what', label = emote, value = name, icon = 'person', disabled = true,
				description = locale('animations.duo.from', { name = name }) },
			{ id = 'accept', label = locale('animations.duo.accept'), icon = 'emote',
				data = { accept = true } },
			{ id = 'decline', label = locale('animations.duo.decline'), icon = 'ban',
				data = { accept = false } },
		},
	})
	if opened ~= nil and current ~= nil and current.id == inviteId then
		current.handle = opened.handle
	end
end

-- The server withdrew an invitation: expired, or the inviter stopped.
local function onUninvite(inviteId)
	inviteId = Common.Integer(inviteId, 1, M.MAX_REQUEST_ID)
	if current == nil or current.id ~= inviteId then return end
	closeMenu()
	current = nil
	Runtime.Notify('info', 'animations.duo.withdrawn')
end

--- Forgets any invitation.
-- @author dop42
function Invite.Init()
	current = nil
end

--- Wires the two invitation channels.
-- @author dop42
function Invite.Start()
	RegisterNetEvent(M.Event.INVITE, onInvite)
	RegisterNetEvent(M.Event.UNINVITE, onUninvite)
end

--- Takes the invitation's menu down.
-- @author dop42
function Invite.Shutdown()
	closeMenu()
	current = nil
end
