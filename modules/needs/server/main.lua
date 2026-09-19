--- Server half: the needs net events, the held pushes and the save paths.
-- @author dop42
--
-- Every value here came from a client: it is bounded before it reaches a column,
-- and never recalculated. The client owns the values during play, and this half
-- stores what it was last pushed. That is the project owner's ruling, so the
-- guards are ownership and bounds rather than simulation.

local M = OPX.Modules.Get('needs')
local Bounds = M.Bounds

local EVENT_PULL = OPX.Event(OPX.Channel.NET, 'needs', 'pull')
local EVENT_PUSH = OPX.Event(OPX.Channel.NET, 'needs', 'push')
local EVENT_VALUES = OPX.Event(OPX.Channel.NET, 'needs', 'values')
local EVENT_PUSHED = OPX.Event(OPX.Channel.NET, 'needs', 'pushed')

-- Length of one rate-limit window, in milliseconds.
local WINDOW_MS = 10000

-- Pulls, then pushes, one player may send within a window. A guard against
-- flooding, not a budget a correct client reaches.
local PULLS_PER_WINDOW = 4
local PUSHES_PER_WINDOW = 12

-- Last push per loaded player: citizenId, values and dirty.
local held = {}

-- Rate-limit windows per player, one table per net event.
local pullWindows, pushWindows = {}, {}

-- The character contract, looked up in `Start`: contracts only exist from the
-- api phase on.
local character

--- Counts one event against a player's window and answers whether it fits.
local function within(windows, player, limit, spanMs)
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- Answers the citizen id the character module has loaded for a player.
-- A client naming another player's character must neither receive that row nor
-- overwrite it, and must not reach another of its own characters either, so the
-- id is never taken on the client's word.
-- @return string|nil the loaded id, nil when it could not be confirmed
-- @return string|nil why, nil when the answer was read and simply did not match
local function loadedCitizenOf(player)
	if character == nil or type(character.GetPlayer) ~= 'function' then
		return nil, 'no character contract'
	end

	-- Nil for a session still at the selection screen, which is not a failure:
	-- the pull is then refused like any other id that is not the loaded one.
	local loaded = character.GetPlayer(player)
	local data = loaded and loaded.PlayerData
	if type(data) ~= 'table' or type(data.citizenId) ~= 'string' then return nil end
	return data.citizenId
end

--- Answers a value shaped like a citizen id that fits the column.
-- The shape only, not the checksum: this half stores rows for whatever the
-- character module issues, and `OPX.CitizenId.Parse` would refuse an id minted
-- under a different alphabet while the column would still hold it.
local function citizenId(value)
	if type(value) ~= 'string' or #value < 1 or #value > 16 then return nil end
	if value:match('^[%u%d%-]+$') == nil then return nil end
	return value
end

--- Clamps a payload of needs, or nil when it holds none.
local function bounded(raw)
	local values, count = Bounds.Read(raw)
	if count == 0 then return nil end
	return values
end

--- Whether the schema settled, so nothing is read or written before the table
--- exists.
local function usable()
	return OPX.BootError == nil
end

--- Writes a player's unsaved last push, now or on a new thread.
-- @param now boolean|nil write on this stack, for a stopping resource
local function flush(player, forget, now)
	local record = held[player]
	if forget then held[player] = nil end
	if record == nil or not record.dirty then return end
	record.dirty = false

	local function write()
		if not M.Storage.Save(record.citizenId, record.values) then
			record.dirty = not forget
		end
	end

	if now then write() else CreateThread(write) end
end

--- Loads the stored needs of the character the caller has loaded.
local function onPull(rawCitizenId)
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if not within(pullWindows, player, PULLS_PER_WINDOW, WINDOW_MS) then return end
	local id = citizenId(rawCitizenId)
	if id == nil or not usable() then return end

	CreateThread(function()
		local loaded, failure = loadedCitizenOf(player)
		if failure ~= nil then
			-- Unanswered rather than refused: the client asks again.
			Open77.log.warn(('%s not confirmed: %s')
				:format(OPX.Audit.Safe(id), OPX.Audit.Safe(failure)))
			return
		end
		if loaded ~= id then
			OPX.Audit.Security('needs.pull.refused',
				('%s is not their loaded character'):format(OPX.Audit.Safe(id)), nil, player)
			return
		end

		local values, reason = M.Storage.Load(id)
		if values == nil then
			Open77.log.warn(('%s could not be read: %s'):format(OPX.Audit.Safe(id), tostring(reason)))
			return
		end

		local previous = held[player]
		-- The same character pulled again answers the push still held rather than
		-- the stored row: that row can be a whole autosave behind, and replacing
		-- the client's values with it would lose what it has since sent.
		if previous ~= nil and previous.citizenId == id then
			TriggerClientEvent(EVENT_VALUES, player, id, previous.values)
			return
		end
		-- No event announces that a character was put down, so the outgoing one's
		-- last push is written before its record is replaced.
		if previous ~= nil then flush(player, false) end

		held[player] = { citizenId = id, values = values, dirty = false }
		TriggerClientEvent(EVENT_VALUES, player, id, values)
	end)
end

--- Holds a client's bounded needs for the character it pulled, and acknowledges.
local function onPush(rawCitizenId, rawValues)
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if not within(pushWindows, player, PUSHES_PER_WINDOW, WINDOW_MS) then return end
	local id = citizenId(rawCitizenId)
	if id == nil then return end
	local values = bounded(rawValues)
	if values == nil then return end

	-- A push only ever lands on the character this player pulled, the one the
	-- check admitted: the hot path costs a comparison and never a query.
	local record = held[player]
	if record == nil or record.citizenId ~= id then return end
	record.values, record.dirty = values, true
	TriggerClientEvent(EVENT_PUSHED, player, id)
end

--- Saves and forgets a departing player.
-- A client can send nothing at this point, so its last push is the freshest
-- thing there is. The reason separates a lost link, where that push can be a
-- push interval behind, from an administrative disconnect, where the client had
-- time to send one.
local function departed(rawPlayerId, reason)
	local player = tonumber(rawPlayerId) or 0
	if player <= 0 then return end
	local record = held[player]
	if record ~= nil and record.dirty then
		Open77.log.info(('%s saving on departure (%s)')
			:format(OPX.Audit.Safe(record.citizenId), OPX.Audit.Safe(reason)))
	end
	flush(player, true)
	pullWindows[player] = nil
	pushWindows[player] = nil
	OPX.Audit.Forget(player, record and record.citizenId or nil)
end

--- Runs one autosave pass over every held player.
local function autosave()
	for player in pairs(held) do flush(player, false) end
end

--- Builds the state and contributes the table.
-- @author dop42
function M.Init()
	M.ReadSettings()
	held = {}
	pullWindows, pushWindows = {}, {}
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Wires the net events and starts the autosave loop.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('no character contract: no needs will be loaded or saved')
	end

	RegisterNetEvent(EVENT_PULL, onPull)
	RegisterNetEvent(EVENT_PUSH, onPush)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	local interval = math.max(1000, math.floor(tonumber(M.Settings.AUTOSAVE_MS) or 300000))
	OPX.Scheduler.Every('needs:autosave', interval, autosave)
end

--- Writes every held push on this stack.
-- @author dop42
--
-- A stopping resource sees no further tick, so a `CreateThread` here would write
-- nothing: this runs on the stop handler's own stack.
function M.Stop()
	for player in pairs(held) do flush(player, false, true) end
end
