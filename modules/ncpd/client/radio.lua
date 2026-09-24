--- The scanner's state half: the key, the toggle, and what the wire says.
-- @author XEROX710
--
-- THE PAGE DECIDES NOTHING. This half owns whether the scanner is open and
-- which band is tuned, and publishes every change on `M.Event.RADIO_VIEW`;
-- `client/radioview.lua` draws it. What comes back through `M.Radio.FromView`
-- is an INTENT -- "the player pressed tune on the MaxTac band" -- and is
-- re-derived here against what the server last said, so a page that asks for a
-- band this listener cannot hear gets nothing rather than a dark panel.
--
-- STOWING IS LOCAL, AND THAT IS THE WHOLE DESIGN. The server's routing is a
-- push-time decision (see `server/radio.lua`): it keeps no subscriber list, so
-- closing the panel needs no wire message and a lost one could not leak. What
-- a stowed scanner misses is in the ring, and the next open frame brings it.
--
-- THE KEY IS THE HOST'S OWN. `RegisterKeyMapping` is what puts it in the
-- pause menu's KEY BINDINGS tab, where a player may rebind it -- under the id,
-- which is therefore stable for ever.

local M = OPX.Modules.Get('ncpd')

--- Whether the scanner is open, the frame the server last answered with, and
-- the band currently tuned. View state, owned here and nowhere else.
local open = false
local frame = nil
local tuned = nil

--- The airwaves, as the panel holds them: whether the key is down, how many
--- remote talkers are on the speaker, and the speaker knob's position. A knob
--- is LOCAL presentation policy (`voice.md`: "Device/gain/block settings are
--- local presentation policy"), so the gain is applied per band and never
--- crosses the wire.
local talking = false
local rxCount = 0
local volume = 100

--- The native voice seam, or nil on a build without it.
--- @return table|nil
local function airwaves()
	local voice = Open77 and Open77.voice
	if type(voice) ~= 'table' or type(voice.setTransmitting) ~= 'function' then return nil end
	return voice
end

--- The tuned band's host voice handle, read from the frame the server sent --
--- the ONLY source for it (the client never mints channel ids).
--- @param bandId string|nil
--- @return any
local function voiceOf(bandId)
	if bandId == nil or frame == nil then return nil end
	for _, band in ipairs(frame.channels or {}) do
		if band.id == bandId then return band.voice end
	end
	return nil
end

--- Applies the speaker knob to every band the frame named.
local function applyVolume()
	local voice = airwaves()
	if voice == nil or frame == nil then return end
	local gain = math.max(0.0, math.min(2.0, (volume / 100.0) * 2.0))
	for _, band in ipairs(frame.channels or {}) do
		if band.voice ~= nil then
			pcall(voice.setChannelVolume, band.voice, gain)
		end
	end
end

--- The key the host answered with at registration, or nil. Carried to the page
-- as the stow cap, because a cap says what the player's OWN binding says and
-- the page has no keyboard layout to resolve a mapping id with.
local bound = nil

--- WHERE THE PLAYER PARKED IT. The device is the player's to place anywhere on
-- the glass, and the machine remembers: two coordinates in client KVP
-- (`client-kvp.md`), namespaced per connection address, so a different server
-- is a different memory. Cached here because a frame is drawn many times a
-- session and a store read belongs at the edges. KVP is SCALAR-only, so it is
-- two keys and never a table.
local place = nil
local placeRead = false

--- A coordinate off the wire: a finite pixel inside the surface, or nil. NaN
-- and the infinities are refusals, because a device placed once at NaN is a
-- device no drag can ever find again.
-- @param value any
-- @return number|nil
local function finiteCoord(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	if number < 0 or number > 4096 then return nil end
	return math.floor(number)
end

--- The place this machine remembers, or nil for the built-in dock.
-- @return table|nil { x, y }
local function savedPlace()
	if placeRead then return place end
	placeRead = true
	local store = Open77 and Open77.kvp
	if type(store) ~= 'table' or type(store.get) ~= 'function' then return nil end
	local readX, x = pcall(store.get, 'radio:place:x')
	local readY, y = pcall(store.get, 'radio:place:y')
	x = readX and finiteCoord(x) or nil
	y = readY and finiteCoord(y) or nil
	if x == nil or y == nil then return nil end
	place = { x = x, y = y }
	return place
end

--- Remembers the place: in memory at once, on disk best-effort. A store that
-- cannot write is a device that starts docked next session -- said on the log
-- rather than a placement that quietly happens once.
-- @param x number
-- @param y number
local function savePlace(x, y)
	place = { x = x, y = y }
	placeRead = true
	local store = Open77 and Open77.kvp
	if type(store) ~= 'table' or type(store.set) ~= 'function' then return end
	local okX, setX, whyX = pcall(store.set, 'radio:place:x', x)
	local okY, setY, whyY = pcall(store.set, 'radio:place:y', y)
	if not okX or not okY or setX ~= true or setY ~= true then
		local why = (not okX and whyX) or (not okY and whyY)
			or (setX ~= true and whyX) or (setY ~= true and whyY) or 'refused'
		Open77.log.warn('[ncpd] radio place not remembered: ' .. tostring(why))
	end
end

--- Whether another surface holds the keyboard. A key pressed into a menu must
-- do nothing rather than put a scanner over somebody else's menu -- the same
-- guard the crew door's key makes, for the same reason.
-- @return boolean
local function captured()
	local input = Open77 and Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, taken = pcall(input.isCaptured)
	return read and taken == true
end

--- Publishes what the page draws. One seam, one event (README: the view seam).
-- @param payload table
local function show(payload)
	TriggerEvent(M.Event.RADIO_VIEW, payload)
end

--- The sentence a refusal is read as: `M.Radio.Refusal` maps the server's code
-- to the same words the panel would use, and an unknown code names itself.
-- @param code string|nil
local function toastWhy(code)
	local text = tostring(code or 'failed')
	OPX.Toast.Locale(M.Radio.Refusal[text] or 'ncpd.radio.failed', { reason = text }, 'error')
end

--- Closes the scanner. Idempotent: a stow pressed twice is one close.
-- @param why string|nil for the log only
function M.Radio.Close(why)
	if not open then return end
	if talking then M.Radio.Talk(false) end
	open = false
	frame = nil
	tuned = nil
	talking = false
	rxCount = 0
	M.RadioView.Release()
	show({ kind = 'close', why = tostring(why or 'stowed') })
	Open77.log.info('[ncpd] scanner stowed (' .. tostring(why or 'stowed') .. ')')
end

--- Toggles the scanner. The open half is a knock the server answers; the stow
-- half is local, because routing needs no word of it.
function M.Radio.Toggle()
	if open then
		M.Radio.Close('key')
		return
	end
	if captured() then
		toastWhy('captured')
		return
	end
	-- A knock that carries nothing: the server resolves who is asking and what
	-- exists for them (see `server/radio.lua`).
	TriggerServerEvent(M.Event.RADIO)
end

--- Keys (or releases) the transmitter on the TUNED band. The band's voice
--- handle comes from the frame the server sent and the intent is
--- `channel:<id>` -- `voice.md`: "a transmit scope is only a request", and the
--- host routes the frames by the membership `server/radio.lua` seats on the
--- same duty rule that draws the panel, so even a forged press can only talk
--- to the band the server put this listener on.
-- @param on boolean
function M.Radio.Talk(on)
	local voice = airwaves()
	-- EVERY DEAD END SAYS SO. A transmitter that does nothing for no stated
	-- reason is indistinguishable from a broken button, and that is exactly the
	-- bug class these lines exist to rule out.
	if not open or frame == nil then
		Open77.log.warn('[ncpd] radio TX: no scanner is open')
		return
	end
	if voice == nil then
		Open77.log.warn('[ncpd] radio TX: no voice contract on this client (Open77.voice)')
		return
	end
	local id = voiceOf(tuned)
	if id == nil then
		Open77.log.warn('[ncpd] radio TX: the tuned band carries no voice handle')
		return
	end
	if on == talking then return end

	if on then
		if type(voice.setCaptureEnabled) == 'function' then voice.setCaptureEnabled(true) end
		local ok, why = voice.setTransmitting(true, 'channel:' .. tostring(id))
		if ok ~= true then
			Open77.log.warn('[ncpd] radio TX refused: ' .. tostring(why))
			return
		end
		talking = true
		Open77.log.info('[ncpd] radio TX open on ' .. tostring(tuned))
		-- The TX meter is a READING, never chrome: the native capture level,
		-- polled while the key is held (the wiki's own meter idiom).
		CreateThread(function()
			while talking do
				local read, snapshot = pcall(voice.status)
				if read and type(snapshot) == 'table' then
					show({ kind = 'txlevel', level = tonumber(snapshot.inputLevel) or 0 })
				end
				if type(Wait) ~= 'function' then break end
				Wait(100)
			end
		end)
	else
		voice.setTransmitting(false)
		talking = false
		Open77.log.info('[ncpd] radio TX closed on ' .. tostring(tuned))
	end
	show({ kind = 'tx', on = talking, channel = tuned })
end

--- The speaker knob: one gain for the whole scanner, applied to every band the
--- frame named. LOCAL presentation policy (voice.md: "local gain retained for
--- current and future route streams"), so the knob is instant and no server
--- ever hears about it. The panel's `level` is 0-100; the host's gain is
--- 0.0-2.0, with unity at the knob's centre.
-- @param level number 0-100
function M.Radio.SetVolume(level)
	volume = math.max(0, math.min(100, tonumber(level) or 100))
	applyVolume()
	Open77.log.info(('[ncpd] radio volume: %d'):format(volume))
end

--- The one wire handler, upstream: a frame or a refusal, to the asker alone.
RegisterNetEvent(M.Event.RADIO_STATE, function(payload)
	if type(payload) ~= 'table' then return end
	if payload.open ~= true then
		toastWhy(payload.reason)
		M.Radio.Close('refused')
		return
	end

	local channels = {}
	local first = nil
	for _, band in ipairs(payload.channels or {}) do
		if type(band) == 'table' and type(band.id) == 'string' then
			channels[#channels + 1] = {
				id = band.id,
				name = tostring(band.name or band.id),
				freq = tostring(band.freq or ''),
				hear = band.hear == true,
				-- The host's channel handle, crossed in the frame: the PTT and
				-- the volume knob both speak through it, and it is the only
				-- thing on the wire that is not vocabulary.
				voice = band.voice,
			}
			if first == nil and band.hear == true then first = band.id end
		end
	end

	open = true
	frame = {
		open = true,
		key = bound or M.Radio.KEY.DEFAULT,
		-- Where this machine last parked it, or nil for the built-in dock.
		at = savedPlace(),
		tuned = first or (channels[1] and channels[1].id) or nil,
		channels = channels,
		lines = payload.lines or {},
	}
	tuned = frame.tuned
	rxCount = 0
	applyVolume()
	show({ kind = 'frame', frame = frame })
	Open77.log.info('[ncpd] scanner open: ' .. tostring(#channels) .. ' band(s), '
		.. tostring(#frame.lines) .. ' line(s) of backlog')
end)

--- The other wire handler, upstream: one line of traffic. A stowed scanner
-- drops it -- the ring on the server is what a reopen reads.
RegisterNetEvent(M.Event.RADIO_LINE, function(line)
	if not open or type(line) ~= 'table' then return end
	show({ kind = 'line', line = {
		id = tonumber(line.id) or 0,
		channel = tostring(line.channel or ''),
		key = tostring(line.key or ''),
		args = type(line.args) == 'table' and line.args or {},
	} })
end)

--- Everything the view says, as intents. Nothing here is believed until it is
-- re-derived against the frame the server sent.
-- @param action string `tune` | `talk` | `volume` | `place` | `close`
-- @param payload table|nil
function M.Radio.FromView(action, payload)
	-- The receipt trail: every intent the page sends lands here, so a press that
	-- dies in the browser is told apart from one that dies on the wire.
	Open77.log.info('[ncpd] radio intent: ' .. tostring(action))
	if action == 'tune' then
		if not open or frame == nil then return end
		local id = type(payload) == 'table' and tostring(payload.channel or '') or ''
		for _, band in ipairs(frame.channels or {}) do
			-- A dark band is not tunable: there is nothing on it to hear, and
			-- the page draws it as a readout rather than a control.
			if band.id == id and band.hear == true then
				tuned = id
				frame.tuned = id
				show({ kind = 'tuned', channel = id })
				return
			end
		end
		return
	end
	if action == 'talk' then
		M.Radio.Talk(type(payload) == 'table' and payload.on == true)
		return
	end
	if action == 'volume' then
		local level = type(payload) == 'table' and tonumber(payload.level) or nil
		if level == nil then return end
		M.Radio.SetVolume(level)
		return
	end
	if action == 'place' then
		local x = type(payload) == 'table' and finiteCoord(payload.x) or nil
		local y = type(payload) == 'table' and finiteCoord(payload.y) or nil
		if x == nil or y == nil then return end
		savePlace(x, y)
		Open77.log.info(('[ncpd] radio placed at %d,%d'):format(x, y))
		return
	end
	if action == 'close' then
		M.Radio.Close('view')
	end
end

--- Declares the scanner's key and wires the two upstream handlers' seam.
-- The mapping's name is translated at registration and its id is stable,
-- because a player's rebind is stored under the id. Two answer shapes are
-- documented for `RegisterKeyMapping` -- the effective key, or `true, key` --
-- and reading only the second logged a working mapping as refused.
function M.Radio.Start()
	local declared = M.Radio.KEY
	if declared.DEFAULT == false then return end

	local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
		declared.DEFAULT, function()
			local ran, failure = pcall(M.Radio.Toggle)
			if not ran then
				Open77.log.error(('[ncpd] key %s: %s'):format(declared.ID, tostring(failure)))
			end
		end)
	local effective = nil
	if called then
		effective = type(ok) == 'string' and ok ~= '' and ok
			or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	end
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[ncpd] key mapping %s (%s) not registered: %s')
			:format(declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
	else
		bound = effective
	end

	-- The RX lamp is a READING: the host's own talker state
	-- (`open77:voice:talkingChanged`), never invented here. Counted, because
	-- two talkers releasing one at a time must not dim the lamp early.
	AddEventHandler('open77:voice:talkingChanged', function(_, speaking, level)
		if not open then return end
		if speaking == true then
			rxCount = rxCount + 1
		else
			rxCount = math.max(0, rxCount - 1)
		end
		show({ kind = 'rx', on = rxCount > 0, level = tonumber(level) or 0, channel = tuned })
	end)
end

--- Takes the scanner down. The next session knocks again from scratch.
function M.Radio.Stop()
	M.Radio.Close('stop')
	bound = nil
end
