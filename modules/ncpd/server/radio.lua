--- The scanner feed: which band reaches whom, the lines on the air, and the
-- ring of recent traffic a stowed scanner comes back to.
-- @author XEROX710
--
-- ROUTING IS A PUSH-TIME DECISION AND NEVER A SUBSCRIPTION GRANT. Every line
-- walks the audience for its band -- on duty, and answering through a job the
-- band is FOR -- so a trooper who clocks off stops hearing the band with the
-- very next line. There is no subscriber list to leak, sweep or lose an `off`
-- in, and a scanner that is stowed simply drops what it is sent (the client's
-- half says so); the ring below is what a reopened scanner reads.
--
-- THE SUSPECT IS NOT ON THE AIR. The call-out withholds its toast from the
-- player it names, and the dispatch band reuses that moment's key and
-- arguments -- so the same exclusion is carried here as `except`, by the same
-- id, for the same reason: being told personally and hearing yourself called
-- out are two different things.
--
-- LINES CARRY KEYS, NOT SENTENCES. The page holds no English and its catalogue
-- is already complete (`locale:set`), so a line is `{ key, args }` and the
-- words live once, in `locales.lua`, shared with the toast that says the same
-- thing.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

-- The traffic ring and its ids. Bounded by `M.Radio.BACKLOG` so the frame that
-- carries it is one host payload (a line is about ten value nodes against a
-- ceiling of 1024), oldest dropped first.
local ring = {}
local sequence = 0

-- The two readers the airwaves below seat with, forward-declared: that block
-- keeps its own section above them and Lua closures bind VARIABLES -- a later
-- `local function` would shadow these names and leave every seat calling nil.
-- The declarations below are therefore plain assignments to these two.
local dataOf, mayHear

-- ── the airwaves: one voice channel per band ─────────────────────────────
--
-- MEMBERSHIP IS STATE, AND THE RULE IS THE LINE FEED'S OWN. Text routing stays
-- a push-time decision (above); a VOICE channel needs membership, so the same
-- `mayHear` is applied continuously instead of per line -- a seat is granted
-- at the knock and reconciled on a pass, so a trooper who clocks off is off
-- the air within seconds. The HOST then enforces it at the packet (voice.md:
-- "The server is the only component that decides who may receive a frame"),
-- so even a forged press can only talk to a band this rule seated you on.

local VOICE_RECONCILE_MS = 10000

local voiceIds = {}
local seated = {}

--- The native voice seam, or nil on a build without it. One reader, so the
--- scanner degrades to its text feed with one warning rather than raising.
--- @return table|nil
local function airwaves()
	local voice = Open77.voice
	if type(voice) ~= 'table' or type(voice.createChannel) ~= 'function' then return nil end
	return voice
end

--- Creates one voice channel per band and seats the air continuously.
--- @return boolean whether the air exists at all
function M.Radio.VoiceStart()
	local voice = airwaves()
	if voice == nil then
		Open77.log.warn('[ncpd] radio: no voice contract (Open77.voice): the scanner carries text only and nobody can talk')
		return false
	end
	for _, band in ipairs(M.Radio.CHANNELS) do
		local made, why = voice.createChannel({
			name = ('%s %s'):format(band.FREQ, band.id),
			mode = 'radio',
			persistent = false,
			effect = M.Radio.VOICE_EFFECT,
		})
		if type(made) == 'table' and made.id ~= nil then
			voiceIds[band.id] = made.id
		else
			Open77.log.warn(('[ncpd] radio: band %s has no air: %s')
				:format(band.id, tostring(why or made)))
		end
	end

	CreateThread(function()
		while true do
			Wait(VOICE_RECONCILE_MS)
			M.Radio.VoiceReconcile()
		end
	end)
	return true
end

--- Seats one connection on exactly the bands its duty earns -- the SAME rule
--- the line feed pushes with, so the two halves cannot disagree about who is
--- on the air. Only the difference is written (the host is asked per change)
--- and the seat is remembered so the reconcile pass can withdraw it.
--- @param source number
function M.Radio.VoiceSeat(source)
	local voice = airwaves()
	if voice == nil then return end
	local data = dataOf(source)
	local held = seated[source]
	for _, band in ipairs(M.Radio.CHANNELS) do
		local id = voiceIds[band.id]
		if id ~= nil then
			local should = data ~= nil and mayHear(source, data, band.id) == true
			local has = held ~= nil and held[band.id] == true
			if should ~= has then
				if should then
					local ok = voice.addPlayer(id, source, { canSpeak = true, canListen = true })
					if ok then
						held = held or {}
						held[band.id] = true
					end
				else
					voice.removePlayer(id, source)
					held[band.id] = nil
				end
			end
		end
	end
	if held ~= nil and next(held) ~= nil then seated[source] = held else seated[source] = nil end
end

--- One reconcile pass: every seat withdrawn from anybody gone, and everybody
--- connected put on exactly the air their duty earns.
function M.Radio.VoiceReconcile()
	local voice = airwaves()
	if voice == nil then return end

	local read, ids = pcall(Open77.players.all)
	local live = {}
	if read and type(ids) == 'table' then
		for index = 1, #ids do
			local source = tonumber(ids[index])
			if source ~= nil then live[source] = true end
		end
	end

	for source, held in pairs(seated) do
		if live[source] ~= true then
			for bandId in pairs(held) do
				if voiceIds[bandId] ~= nil then voice.removePlayer(voiceIds[bandId], source) end
			end
			seated[source] = nil
		end
	end

	for source in pairs(live) do
		M.Radio.VoiceSeat(source)
	end
end

--- The character a connection has loaded, as the character contract sees it.
-- The contract is optional (`module.lua`), so a missing one is a refusal with a
-- line rather than a feed that takes the resource down. The same read
-- `server/main.lua` makes, kept here so neither half depends on the other's
-- load order.
-- @param playerId number
-- @return table|nil PlayerData
function dataOf(playerId)
	local character = OPX.Api.Get('character')
	if character == nil then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' then return nil end
	local citizenId = data.citizenId
	if type(citizenId) ~= 'string' or citizenId == '' then return nil end
	return data
end

--- The jobs one band is FOR, read from the config at call time.
-- The dispatch band is for everyone who answers for the city -- the call-out's
-- own audience, `ALERTS.JOBS`; the MaxTac band is for the MaxTac division,
-- `MAXTAC.OPT_IN.JOBS` as the law validates it into `Law.Maxtac.Jobs`. A
-- division is the config's answer and never a literal in code.
-- @param channel string
-- @return table|nil job names
local function bandJobs(channel)
	-- The city's own three bands answer through the call-out's audience; the
	-- MaxTac band through the division's jobs. A channel this map does not
	-- name is not a band at all (`Push` refuses it).
	if channel == 'ncpd' or channel == 'tactical' or channel == 'air' then
		local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
		return type(alerts) == 'table' and alerts.JOBS or nil
	end
	if channel == 'maxtac' then
		local maxtac = Law.Maxtac
		return maxtac ~= nil and maxtac.Jobs or nil
	end
	return nil
end

--- Whether this connection holds the MaxTac division's opt-in right -- the
-- band's other door, exactly as it is the crew door's (`mayBoard`).
-- @param source number
-- @return boolean
local function holdsRight(source)
	local maxtac = Law.Maxtac
	if maxtac == nil or maxtac.Right == nil then return false end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, source, maxtac.Right)
	return read and allowed == true
end

--- Whether this player may hear one band, right now.
-- DUTY IS THE WHOLE FILTER before anything else -- the same `job.onDuty` the
-- call-out and the crew door use, so a clocked-off officer hears nothing.
-- @param source number
-- @param data table PlayerData
-- @param channel string
-- @return boolean
function mayHear(source, data, channel)
	local job = data.job
	if type(job) ~= 'table' or job.onDuty ~= true then return false end
	local name = job.name
	if type(name) ~= 'string' then return false end
	for _, listed in ipairs(bandJobs(channel) or {}) do
		if listed == name then return true end
	end
	-- The opt-in right is the division's other door -- and air support is the
	-- division's flying band, so it answers to the same right.
	return (channel == 'maxtac' or channel == 'air') and holdsRight(source)
end

--- Calls back for every connected player who may hear a band right now.
-- The host lists the connections and the character contract resolves each one,
-- which is the walk `walkOnDuty` makes for the call-out and the crew door; the
-- audience RULE differs per band, so the walk lives here with the rule.
-- @param channel string
-- @param fn function(source, data)
local function eachListener(channel, fn)
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local source = tonumber(ids[index])
		if source ~= nil and source > 0 then
			local data = dataOf(source)
			if data ~= nil and mayHear(source, data, channel) then fn(source, data) end
		end
	end
end

--- Puts one line of traffic on a band.
-- The words are the caller's to choose (a KEY and its arguments), so the
-- dispatch band and its toast are one wording by construction: the call-out
-- passes the very key and args it just toasted with.
--
-- `except` is the suspect of a call-out: named lines go out to the band and
-- never back to the body they name.
-- @param channel string `M.Radio.CHANNELS[].id`
-- @param key string locale key
-- @param args table|nil locale arguments
-- @param except number|nil a connection to keep off this line
-- @return integer how many heard it
function M.Radio.Push(channel, key, args, except)
	if bandJobs(channel) == nil then
		Open77.log.warn(('[ncpd] radio: %q is not a band; the line was not put up')
			:format(tostring(channel)))
		return 0
	end

	sequence = sequence + 1
	local line = {
		id = sequence,
		channel = channel,
		key = tostring(key),
		args = type(args) == 'table' and args or {},
		at = OPX.Now(),
	}
	ring[#ring + 1] = line
	if #ring > M.Radio.BACKLOG then table.remove(ring, 1) end

	local told = 0
	eachListener(channel, function(source)
		if except ~= nil and source == except then return end
		local sent, failure = pcall(TriggerClientEvent, M.Event.RADIO_LINE, source, line)
		if sent then
			told = told + 1
		else
			Open77.log.warn(('[ncpd] radio line %d did not reach %d: %s')
				:format(sequence, source, tostring(failure)))
		end
	end)
	return told
end

--- Answers a scanner's knock: the whole frame, or a refusal that names why.
--
-- THE KNOCK CARRIES NOTHING, deliberately -- the same property the crew door's
-- has. The server resolves the player from the connection it arrived on, the
-- bands from its own rule and the backlog from its own ring, so a modified
-- client can ask and nothing else.
--
-- The frame decides nothing about the VIEW: the effective key and the tuned
-- band are the client's own and are added there. What crosses here is what is
-- true of the world -- which bands exist for this listener and what was said on
-- them -- and the hearing flags say it per band, so a band this listener cannot
-- hear is drawn as a dark band rather than looking like a quiet one.
RegisterNetEvent(M.Event.RADIO, function()
	-- THE SENDER IS THE `source` GLOBAL, never a parameter. The host hands
	-- a net handler its payload only and names the connection in `source`
	-- around the call -- so a parameter named `source` here took the first
	-- payload (nil for this knock), shadowed the global with it, and every
	-- answer went out with a nil target: the live `bad argument #2 to
	-- 'TriggerClientEvent'` that made the scanner open for nobody.
	source = tonumber(source)
	if source == nil or source <= 0 then return end
	local data = dataOf(source)
	if data == nil then
		TriggerClientEvent(M.Event.RADIO_STATE, source, { open = false, reason = 'noCitizen' })
		return
	end

	local job = data.job
	if type(job) ~= 'table' or job.onDuty ~= true or type(job.name) ~= 'string' then
		TriggerClientEvent(M.Event.RADIO_STATE, source, { open = false, reason = 'notOnDuty' })
		return
	end

	local heard = {}
	local any = false
	for _, band in ipairs(M.Radio.CHANNELS) do
		heard[band.id] = mayHear(source, data, band.id) == true
		any = any or heard[band.id]
	end
	if not any then
		TriggerClientEvent(M.Event.RADIO_STATE, source, { open = false, reason = 'notDivision' })
		return
	end

	-- On the air the moment the scanner comes out: the seat follows the very
	-- rule the `hear` flags above were just computed with.
	M.Radio.VoiceSeat(source)

	local channels = {}
	for _, band in ipairs(M.Radio.CHANNELS) do
		channels[#channels + 1] = {
			id = band.id,
			name = band.NAME,
			freq = band.FREQ,
			hear = heard[band.id] == true,
			-- The host's own channel handle, and the ONLY place it crosses to
			-- the client: the panel needs it to key the PTT (`channel:<id>`
			-- transmit intent) and turn the volume knob (`setChannelVolume`).
			voice = voiceIds[band.id],
		}
	end

	-- The backlog this listener may hear, oldest first, already inside the
	-- ring's bound -- one frame, one payload.
	local lines = {}
	for index = 1, #ring do
		local line = ring[index]
		if heard[line.channel] then lines[#lines + 1] = line end
	end

	TriggerClientEvent(M.Event.RADIO_STATE, source, { open = true, channels = channels, lines = lines })
end)
