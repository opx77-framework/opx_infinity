--- The server half: it relays what a player says, and answers the box's one
--- question with the commands that player may be shown.
-- @author dop42

local M = OPX.Modules.Get('chat')

-- When each player last spoke, for the floor between two messages.
local lastSaidMs

-- The last good clock reading, kept when the clock cannot be read.
local lastMs = 0

--- Milliseconds on the monotonic clock, never a reading that is not finite.
-- Differs from `OPX.Now` in rejecting a non-finite reading and answering the
-- last good one instead: `lastSaidMs` is compared against this clock, so a NaN
-- would make `at - previous` fail every comparison and drop every message from
-- everyone who had already spoken, in silence, until the process ended.
local function nowMs()
	local read, ms = pcall(OPX.Now)
	if read and OPX.Math.IsFinite(ms) and ms >= 0 then lastMs = math.floor(ms) end
	return lastMs
end

--- Cleans display text to MAX_LENGTH characters, never nil.
local function clean(value)
	return OPX.Text.Clean(value, M.Settings.MAX_LENGTH, '...') or ''
end

--- Reads what the host vouches for about a connection.
-- Guarded twice: the reader may be absent on a build without it, and a reader
-- that is present can still raise.
local function identityOf(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.identity) ~= 'function' then return nil end
	local read, identity = pcall(players.identity, player)
	if not read or type(identity) ~= 'table' then return nil end
	return identity
end

--- Relays a player's message to everyone, attributed to its connection.
local function onSaid(text)
	local player = tonumber(source) or 0
	if player <= 0 then return end

	-- The floor is checked before the text is touched: a burst must not buy
	-- itself a walk of the message per packet. It moves for a REFUSED message
	-- too -- recording it only after the blank test let a burst of spaces never
	-- advance it, and pay for a bounded walk every time.
	local at = nowMs()
	local previous = lastSaidMs[player]
	if previous ~= nil and at - previous < M.Settings.RATE_MS then return end
	lastSaidMs[player] = at

	local said = clean(text)
	if said:match('^%s*$') then return end

	-- `source` is the authenticated connection: a client cannot speak for
	-- another. The displayed name is the player's own and is a label, never an
	-- identity. Without one, the first eight characters of the account say
	-- something an operator can act on; a session id says nothing to anyone once
	-- the player has gone.
	local identity = identityOf(player)
	local name = identity and identity.name
	if type(name) ~= 'string' or name == '' then name = nil end
	local unknown = identity and identity.userId and identity.userId:sub(1, 8) or tostring(player)
	TriggerClientEvent(M.Event.MESSAGE, -1, {
		kind = 'chat',
		author = clean(name or locale('chat.author.unknown', { id = unknown })),
		text = said,
	})
end

--- Answers the box with every command this player may be shown.
-- Anyone can raise this name and the answer is kilobytes, so it keeps its own
-- cooldown rather than sharing one with anything else.
local function onReady()
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if OPX.Cooling(player, 'chat.ready', M.Settings.READY_MS) then return end

	-- Core owns the list, and with it the rule that a restricted command is only
	-- offered to a player the ACL would let run it.
	local list = OPX.Command.Suggestions(player)
	TriggerClientEvent(M.Event.SUGGESTIONS, player, { suggestions = list })

	-- Said out loud because the alternative is guessing. An empty completion list
	-- has two very different causes -- the server had nothing to offer, or the
	-- page never received what it sent -- and they are indistinguishable from the
	-- player's side. This line tells them apart from the journal.
	Open77.log.debug(('[chat] %d completion(s) sent to player %d')
		:format(type(list) == 'table' and #list or -1, player))
end

--- Forgets an admitted player's message floor when they leave.
-- `source` is not set on a broadcast the host raises, so the id comes from the
-- argument; one that will not convert is a log line rather than a ghost key.
local function departed(rawPlayerId)
	local player = tonumber(rawPlayerId)
	if player == nil then
		Open77.log.warn(('[chat] unusable player id %q on disconnect'):format(tostring(rawPlayerId)))
		return
	end
	lastSaidMs[player] = nil
end

--- Warns about a resource that also draws a box and answers the same names.
local function warnAboutDuplicates()
	for _, name in ipairs({ 'opx77_chat', 'open77_chat' }) do
		local read, state = pcall(GetResourceState, name)
		state = read and tostring(state or ''):lower() or ''
		if state == 'running' or state == 'starting' then
			Open77.log.warn(('%s is running and is a package this module replaces'):format(name))
			Open77.log.warn('  both draw a chat box, both answer chat:addMessage and both take')
			Open77.log.warn('  focus on the open key, so every message is rendered twice. Drop one')
			Open77.log.warn('  from resources.load in server.jsonc.')
		end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	lastSaidMs = {}
end

--- Wires the two doors.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.SAY, onSaid)
	RegisterNetEvent(M.Event.READY, onReady)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- On a thread, not inline: a resource that starts after this one has not
	-- been launched yet at the moment this runs.
	CreateThread(warnAboutDuplicates)
end
