--- Telling a player something, and refusing them politely.
-- @author dop42
--
-- These are runtime services rather than anything a module owns: a refusal code
-- has to be renderable by whatever draws it, and a cooldown has to be shared
-- between every door into the same operation.

local ANSWER_DEDUPE_MS = 2000
local MAX_TEXTS = 32

local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
local ANSWER = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')

local lastAnswer = {}
local cooldowns = {}

--- Whether this exact text just went to this player.
local function repeated(source, text)
	local bucket = lastAnswer[source]
	if not bucket then
		bucket = {}
		lastAnswer[source] = bucket
	end

	local now = OPX.Now()
	if bucket[text] and now - bucket[text] < ANSWER_DEDUPE_MS then return true end

	-- Bounded, or a client that provokes a new text every message grows this for
	-- the whole session. Closed windows go first; only if that frees nothing does
	-- the oldest open one go, because clearing the table wholesale would let an
	-- identical toast through before its window had passed.
	local count = 0
	for _ in pairs(bucket) do count = count + 1 end
	if count >= MAX_TEXTS then
		local oldestKey, oldestAt
		for key, at in pairs(bucket) do
			if now - at >= ANSWER_DEDUPE_MS then
				bucket[key] = nil
				count = count - 1
			elseif oldestAt == nil or at < oldestAt then
				oldestKey, oldestAt = key, at
			end
		end
		if count >= MAX_TEXTS then bucket[oldestKey] = nil end
	end

	bucket[text] = now
	return false
end

--- Sends a toast, through whatever the host routes notifications to. An exact
--- repeat inside the dedupe window is swallowed; two different toasts are two
--- things the player has to learn, so only an exact repeat counts.
-- @author dop42
-- @param source Source
-- @param message string
-- @param kind string|nil info, success, warning or error
-- @param durationMs integer|nil
function OPX.Notify(source, message, kind, durationMs)
	source = tonumber(source)
	if not source or source <= 0 then return end
	if repeated(source, ('%s:%s'):format(tostring(kind), tostring(message))) then return end

	Open77.notifications.send(source, {
		type = kind or 'info',
		title = OPX.Config.SHARED.SERVER_NAME,
		message = message,
		durationMs = durationMs or 5000,
		position = OPX.Config.SHARED.NOTIFY_POSITION,
	})
end

--- Guarantees a code a player is shown exists in the catalogue. Storage answers
--- `query-failed`, a validator answers `too-short`: those are for the log, not
--- for a player, and they become `error.unavailable` with the real code logged.
-- @author dop42
-- @param code any
-- @return string
function OPX.RefusalKey(code)
	if type(code) == 'string' and OPX.Locale.Exists(code) then return code end
	Open77.log.warn(('[answer] %q has no catalogue entry; answering error.unavailable')
		:format(tostring(code)))
	return 'error.unavailable'
end

--- Sends a toast rendered from a locale key.
-- @author dop42
-- @param source Source
-- @param key string
-- @param params table|nil
-- @param kind string|nil
function OPX.NotifyLocale(source, key, params, kind)
	OPX.Notify(source, locale(OPX.RefusalKey(key), params), kind)
end

--- Answers a command that asked to read something back -- a list, a dump, a
--- block of configuration. Source nil or 0 is the console, which reads a print.
-- @author dop42
-- @param source Source|nil
-- @param accepted boolean
-- @param message string
function OPX.CommandResult(source, accepted, message)
	if source and source > 0 then
		TriggerClientEvent('chat:addMessage', source, {
			type = accepted and 'info' or 'error',
			author = OPX.Config.SHARED.SERVER_NAME,
			text = message,
		})
	else
		print(message)
	end
end

--- Answers what a command *did*, as a toast the client half raises. `toasted`
--- means the action already raised the same toast itself, so a client that can
--- draw toasts shows one rather than two.
-- @author dop42
-- @param source Source|nil
-- @param raw string|nil
-- @param kind string success, warning or error
-- @param message string
-- @param toasted boolean|nil
function OPX.CommandNotice(source, raw, kind, message, toasted)
	if source and source > 0 then
		TriggerClientEvent(ANSWER, source, raw or '', kind, message, toasted == true)
	else
		print(message)
	end
end

--- Whether an operation is cooling for this player, recording the attempt when
--- it is not. The window is per player AND per operation, never per door: the
--- same operation reached by a net event and by a command shares one window.
--- This is not a security boundary -- ownership checks are.
-- @author dop42
-- @param source Source
-- @param key string
-- @param everyMs integer
-- @return boolean
function OPX.Cooling(source, key, everyMs)
	source = tonumber(source)
	-- The console is never cooled.
	if not source or source <= 0 then return false end

	local now = OPX.Now()
	local bucket = cooldowns[source]
	if not bucket then
		bucket = {}
		cooldowns[source] = bucket
	end
	if bucket[key] and now - bucket[key] < everyMs then return true end
	bucket[key] = now
	return false
end

--- Drops a departing player's cooldowns and toast windows. A player id is
--- recycled, and a window left behind would refuse the next holder's first
--- action or swallow their first toast.
-- @author dop42
-- @param source Source
function OPX.ForgetCooldowns(source)
	source = tonumber(source) or -1
	cooldowns[source] = nil
	lastAnswer[source] = nil
end

--- Tells a client which request was refused and with what code, and nothing
--- else: a refusal that explains itself tells an attacker which half of their
--- guess was right. The operation is not optional -- without it a client waiting
--- on one of several requests cannot tell which `error.tooFast` is its own.
-- @author dop42
-- @param source Source
-- @param code string a locale key
-- @param operation string|nil
function OPX.Refuse(source, code, operation)
	source = tonumber(source)
	if not source or source <= 0 then return end
	TriggerClientEvent(NOTIFY, source, {
		kind = 'error',
		code = OPX.RefusalKey(code),
		operation = type(operation) == 'string' and operation or 'unknown',
	})
end
