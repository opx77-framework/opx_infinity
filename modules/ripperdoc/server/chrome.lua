--- The chrome that wears out, and the chrome the platform holds as a grant:
-- one condition number per patient per piece, every way it goes down, and the
-- shelves the movement kit and the decks are defined on.
-- @author XEROX710
--
-- WHY A LEDGER BESIDE THE PLATFORM'S. The platform's durable record says WHAT
-- implant is in which of its slots; it has no opinion on how worn it is, and
-- it holds nothing at all for chrome it has no adapter for. So this ledger is
-- two things. For every piece it is the CONDITION (100 fresh, 0 broken). For
-- the pieces the platform does not hold -- the movement grants, the stat
-- chrome, the roleplay chrome -- it is also the INSTALLATION: a row with a
-- grade is a piece that is fitted.
--
-- FOUR THINGS WEAR A PIECE DOWN (`M.Ripper.Lifecycle`):
--   use     the host's own action events: the punch, the jump, the dash, the
--           overdrive, the slam, the upload -- only on the piece that did it
--   time    every piece loses its lifespan's share each tick it is worn
--   damage  a body that takes a hit wears the chrome plating it
--   death   flatlining is hard on everything
-- Crossing into WORN, FAILING or BROKEN is told to the patient once, in their
-- own words. A broken piece stops paying for itself (`server/effects.lua`
-- reads the band); a broken implant is pulled through the same remove staging
-- every sale uses (`M.Event.ON_BROKEN`, answered in `server/main.lua`); a broken
-- grant has its grant dropped.
--
-- THE MOVEMENT KIT IS GRANTS, NOT RECORDS. `dash`, `reflex` and `ability`
-- pieces live in the platform's movement modules: the clinic defines one
-- immutable definition per grade at Start and arms the fitted one on the
-- patient. A grant is a session thing (the platform drops it when the player
-- leaves), so a player who is READY picks their fitted pieces back up.

local M = OPX.Modules.Get('ripperdoc')

local CreateThread, Wait = CreateThread, Wait

M.Chrome = {}

-- citizen id -> entry id -> { points, broken, grade, dirty }
local ledger = {}
-- citizen ids whose fetch has been asked for (one read per patient, ever)
local asked = {}
-- player key -> entry id -> definition id, the grants armed right now
local armed = {}
-- definition id -> true, the definitions the platform accepted at Start
local shelf = {}
-- citizen id -> the player it was last seen on, for the tick's notifications
local holders = {}
-- Per player: the re-arm refusals already said, and the last death revision
-- read (the life bus may deliver out of order).
local ensureWarned = {}
local deathRevision = {}
-- Whether a failing read has been said out loud already (once per boot, the
-- way every other module reports a storage it cannot read).
local warnedRead = false
-- the character contract, resolved on first use (an optional dependency may
-- publish after this module has run)
local character = nil
-- The tick's run flag, so Stop ends it.
local ticking = false

--- The character contract, fetched once and kept.
local function contracts()
	if character == nil then character = OPX.Api.Get('character') end
end

--- One patient's durable name, or nil when there is none to read. The same
--- contract read `server/main.lua` settles every charge with.
-- @param player number
-- @return string|nil
local function citizenOf(player)
	contracts()
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local ran, record = pcall(character.GetPlayer, player)
	if not ran or type(record) ~= 'table' then return nil end
	local data = type(record.PlayerData) == 'table' and record.PlayerData or record
	local citizenId = data.citizenId
	return type(citizenId) == 'string' and citizenId or nil
end
M.Chrome.CitizenOf = citizenOf

--- One player's ledger, loaded on first need. Yields; call from a thread.
-- @param citizenId string|nil
-- @return table the citizen's rows, never nil
function M.Chrome.Load(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then return {} end
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	if asked[citizenId] then return ledger[citizenId] end
	asked[citizenId] = true
	local rows = M.Storage.FetchChrome(citizenId)
	if type(rows) ~= 'table' or rows.ok ~= true then
		-- A ledger that could not be read is not a ledger that silently says
		-- "fresh": the read is asked for again and every answer keeps 100
		-- until a write lands. SAID ONCE, though: a database that is down is
		-- one incident, not one per patient per minute.
		asked[citizenId] = nil
		if not warnedRead then
			warnedRead = true
			Open77.log.warn('[ripperdoc] chrome condition could not be read: '
				.. tostring(type(rows) == 'table' and rows.detail or 'no answer'))
		end
		return ledger[citizenId]
	end
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		local entryId = type(row) == 'table' and row.entry_id or nil
		-- A row written by THIS session while the read was in flight is newer
		-- than the read: the read never overwrites it.
		if type(entryId) == 'string' and M.Ripper.Entry(entryId) ~= nil
			and ledger[citizenId][entryId] == nil then
			ledger[citizenId][entryId] = {
				points = math.max(0, math.min(100, tonumber(row.condition_points) or 100)),
				broken = tonumber(row.broken) == 1,
				grade = tostring(row.grade_key or ''),
			}
		end
	end
	M.Chrome.Changed(citizenId)
	return ledger[citizenId]
end

--- Whether a citizen's ledger has been read (so its silence means "nothing").
-- @param citizenId string|nil
-- @return boolean
function M.Chrome.Loaded(citizenId)
	return type(citizenId) == 'string' and asked[citizenId] == true
end

--- One piece's condition. Never nil: an unread piece is a fresh piece.
-- @param citizenId string|nil
-- @param entryId string
-- @return table { points, broken, grade }
function M.Chrome.Row(citizenId, entryId)
	local rows = type(citizenId) == 'string' and ledger[citizenId] or nil
	local row = rows ~= nil and rows[entryId] or nil
	if row == nil then return { points = 100, broken = false, grade = '' } end
	return row
end

--- Every row a citizen has, entry id -> row. Never nil.
-- @param citizenId string|nil
-- @return table
function M.Chrome.Rows(citizenId)
	return type(citizenId) == 'string' and ledger[citizenId] or {}
end

--- Whether the piece is broken (and therefore paying nobody).
-- @param citizenId string|nil
-- @param entryId string
-- @return boolean
function M.Chrome.Broken(citizenId, entryId)
	return M.Chrome.Row(citizenId, entryId).broken == true
end

--- Raises the change for one citizen, so the stat composer and any open tray
--- see it. Cheap; called on every write.
-- @param citizenId string|nil
function M.Chrome.Changed(citizenId)
	if type(citizenId) ~= 'string' then return end
	TriggerEvent(M.Event.ON_CHANGED, { citizen = citizenId })
end

--- Writes one piece's condition through to the database. Yields; call from a
--- thread. The points are written as the whole number BELOW them, so a
--- reconnect can only ever find the chrome a little more worn, never mended.
-- @param citizenId string
-- @param entryId string
local function save(citizenId, entryId)
	local row = M.Chrome.Row(citizenId, entryId)
	row.dirty = nil
	local saved = M.Storage.UpsertChrome(citizenId, entryId, tostring(row.grade or ''),
		math.floor(tonumber(row.points) or 100), row.broken == true)
	if type(saved) ~= 'table' or saved.ok ~= true then
		row.dirty = true
		Open77.log.warn(('[ripperdoc] the condition of %s could not be saved: %s')
			:format(tostring(entryId),
				tostring(type(saved) == 'table' and saved.detail or 'no answer')))
	end
end

--- Writes every row that changed since the last write. Yields.
-- @param citizenId string|nil only this citizen's, or everyone's when nil
function M.Chrome.Flush(citizenId)
	local targets = {}
	if type(citizenId) == 'string' then
		targets[citizenId] = ledger[citizenId]
	else
		targets = ledger
	end
	for citizen, rows in pairs(targets) do
		for entryId, row in pairs(rows or {}) do
			if row.dirty then save(citizen, entryId) end
		end
	end
end

--- Records a fitted piece at full condition -- the completion of an install,
--- and of an upgrade (new chrome is new chrome).
-- @param citizenId string|nil
-- @param entryId string
-- @param gradeId string|nil
function M.Chrome.Fit(citizenId, entryId, gradeId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	ledger[citizenId][entryId] = {
		points = 100, broken = false, grade = tostring(gradeId or ''),
	}
	CreateThread(function() save(citizenId, entryId) end)
	M.Chrome.Changed(citizenId)
end

--- Forgets a pulled piece entirely.
-- @param citizenId string|nil
-- @param entryId string
function M.Chrome.Pull(citizenId, entryId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if ledger[citizenId] ~= nil then ledger[citizenId][entryId] = nil end
	CreateThread(function()
		local gone = M.Storage.DeleteChrome(citizenId, entryId)
		if type(gone) ~= 'table' or gone.ok ~= true then
			Open77.log.warn(('[ripperdoc] the condition row of %s could not be deleted: %s')
				:format(tostring(entryId),
					tostring(type(gone) == 'table' and gone.detail or 'no answer')))
		end
	end)
	M.Chrome.Changed(citizenId)
end

--- Buys the wear back: a repaired piece is fresh again, and remembers its
--- grade so a pull-then-repair knows what to fit back.
-- @param citizenId string|nil
-- @param entryId string
function M.Chrome.Repair(citizenId, entryId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	local row = M.Chrome.Row(citizenId, entryId)
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	ledger[citizenId][entryId] = {
		points = 100, broken = false, grade = tostring(row.grade or ''),
	}
	CreateThread(function() save(citizenId, entryId) end)
	M.Chrome.Changed(citizenId)
end

--- Makes sure a platform implant the record holds has a row -- an implant
--- fitted before the ledger existed, or by another resource, starts fresh
--- here rather than being invisible to the lifecycle.
-- @param citizenId string|nil
-- @param entryId string
-- @param gradeId string
function M.Chrome.Adopt(citizenId, entryId, gradeId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if ledger[citizenId] == nil then ledger[citizenId] = {} end
	local row = ledger[citizenId][entryId]
	if row ~= nil and tostring(row.grade or '') == tostring(gradeId or '') then return end
	if row ~= nil and row.broken then return end
	ledger[citizenId][entryId] = {
		points = row ~= nil and row.points or 100, broken = false,
		grade = tostring(gradeId or ''), dirty = true,
	}
	M.Chrome.Changed(citizenId)
end

--- The definition the platform accepted at Start.
-- @param definitionId string
-- @return boolean
function M.Chrome.Shelf(definitionId)
	return shelf[definitionId] == true
end

--- Whether the grant for this piece is armed on the player right now.
-- @param player number
-- @param entryId string
-- @return boolean
function M.Chrome.Armed(player, entryId)
	local key = M.Ripper.KeyOf(player)
	return armed[key] ~= nil and armed[key][entryId] ~= nil
end

--- Arms the piece's grant on the player, or says why not. A grant is a
--- session thing and this is the only place that hands one out.
-- @param player number
-- @param entry table
-- @param grade table
-- @return boolean granted
-- @return string|nil why not
local function arm(player, entry, grade)
	local definitionId = M.Ripper.DefinitionFor(entry, grade)
	if not M.Chrome.Shelf(definitionId) then
		return false, 'the definition ' .. tostring(definitionId) .. ' is not on the shelf'
	end
	local module = M.Ripper.GrantModule(entry)
	if module == nil or type(module.grant) ~= 'function' then
		return false, 'no grant door on this host'
	end
	local key = M.Ripper.KeyOf(player)
	local ran, result, why = pcall(module.grant, player, definitionId)
	-- THE ANSWER IS A TABLE -- the movement modules return `{ok=true}` or
	-- `nil, reason` (`wiki/dash.md`), exactly like their `define`. Comparing
	-- the table to `true` calls every granted piece a refusal and swallows
	-- the reason with it. Read what is actually returned.
	local accepted = ran and (result == true
		or (type(result) == 'table' and result.ok == true))
	if not accepted then
		return false, tostring((not ran and result)
			or (type(result) == 'table' and (result.reason or result.error))
			or why or 'refused')
	end
	if armed[key] == nil then armed[key] = {} end
	-- ONE GRANT PER MODULE: the platform holds one dash, one overdrive and one
	-- ability per resource per player, so arming a second piece of the same
	-- kind replaced the first on the host. The bookkeeping says so too.
	local kind = M.Ripper.GrantKind(entry)
	for otherId in pairs(armed[key]) do
		local other = M.Ripper.Entry(otherId)
		if otherId ~= entry.id and other ~= nil and M.Ripper.GrantKind(other) == kind then
			armed[key][otherId] = nil
		end
	end
	armed[key][entry.id] = definitionId
	return true, nil
end

--- Drops the piece's grant, if it is armed.
-- @param player number
-- @param entry table
local function disarm(player, entry)
	local key = M.Ripper.KeyOf(player)
	local definitionId = armed[key] ~= nil and armed[key][entry.id] or nil
	if definitionId == nil then return end
	armed[key][entry.id] = nil
	local module = M.Ripper.GrantModule(entry)
	if module ~= nil and type(module.revoke) == 'function' then
		pcall(module.revoke, player, definitionId)
	end
end

--- Arms every fitted, unbroken grant the patient owns and does not hold yet.
--- Safe to call often: it only ever acts on what is missing.
-- @param player number
function M.Chrome.Ensure(player)
	local citizenId = citizenOf(player)
	if citizenId == nil then return 0 end
	local rows = ledger[citizenId]
	if rows == nil then return 0 end
	local missing = 0
	local key = M.Ripper.KeyOf(player)
	for entryId, row in pairs(rows) do
		local entry = M.Ripper.Entry(entryId)
		if entry ~= nil and M.Ripper.IsGrant(entry) and row.broken ~= true
			and tostring(row.grade or '') ~= '' then
			local grade = M.Ripper.Grade(entry, row.grade)
			if grade ~= nil and not M.Chrome.Armed(player, entryId) then
				local granted, why = arm(player, entry, grade)
				if not granted then
					missing = missing + 1
					-- Retried until it lands (a grant wants a bound, living body,
					-- and a fresh session has neither for a few seconds), and SAID
					-- once per reason rather than once per retry.
					local said = ensureWarned[key] or {}
					ensureWarned[key] = said
					if said[entryId] ~= tostring(why) then
						said[entryId] = tostring(why)
						Open77.log.warn(('[ripperdoc] could not re-arm %s on player %s: %s (retrying)')
							:format(entryId, tostring(player), tostring(why)))
					end
				elseif ensureWarned[key] ~= nil then
					ensureWarned[key][entryId] = nil
				end
			end
		end
	end
	return missing
end

--- Loads one character's ledger and arms what it names, retrying the grants
--- while the platform is still binding the body. Yields; call from a thread.
-- @param player number
function M.Chrome.Arrive(player)
	local citizenId = citizenOf(player)
	if citizenId == nil then return end
	holders[citizenId] = player
	M.Chrome.Load(citizenId)
	for _ = 1, 8 do
		if citizenOf(player) ~= citizenId then return end
		if M.Chrome.Ensure(player) == 0 then return end
		Wait(5000)
	end
end

--- Fits a movement kit piece on the patient: the grant IS the installation.
-- @param player number
-- @param entry table
-- @param grade table
-- @return boolean
-- @return string|nil
function M.Chrome.FitGrant(player, entry, grade)
	local granted, why = arm(player, entry, grade)
	if not granted then return false, why end
	M.Chrome.Fit(citizenOf(player), entry.id, grade.id)
	return true, nil
end

--- Pulls a movement kit piece: the grant goes and the row goes with it.
-- @param player number
-- @param entry table
function M.Chrome.PullGrant(player, entry)
	disarm(player, entry)
	M.Chrome.Pull(citizenOf(player), entry.id)
end

--- Tells the patient their chrome just crossed into a worse band. Said once
--- per crossing, in the server's language, with the piece named in it.
-- @param player number|nil
-- @param entry table
-- @param band string
local function announce(player, entry, band)
	if player == nil or band == 'optimal' then return end
	local key = 'ripperdoc.wear.' .. band
	pcall(OPX.NotifyLocale, player, key, { name = locale(entry.NAME) },
		band == 'worn' and 'info' or 'error')
end

--- Takes points off one fitted piece, breaking it at zero and saying so when
--- it crosses into a worse band. The write is deferred to the tick's flush:
--- a piece worn every second must not be a row written every second.
-- @param player number|nil the body wearing it, for the notice and the break
-- @param citizenId string
-- @param entry table
-- @param points number
-- @return boolean whether it broke
function M.Chrome.WearPiece(player, citizenId, entry, points)
	if type(citizenId) ~= 'string' or type(entry) ~= 'table' then return false end
	points = tonumber(points) or 0
	if points <= 0 or points ~= points then return false end
	local rows = ledger[citizenId]
	local row = rows ~= nil and rows[entry.id] or nil
	if row == nil or row.broken == true or tostring(row.grade or '') == '' then
		-- Nothing fitted here: a piece is only worn while the patient wears it.
		return false
	end
	local before = M.Ripper.ConditionState(row.points, false)
	row.points = math.max(0, (tonumber(row.points) or 100) - points)
	row.dirty = true
	local after = M.Ripper.ConditionState(row.points, false)
	if row.points <= 0 then
		row.points, row.broken = 0, true
		if M.Ripper.IsGrant(entry) and player ~= nil then disarm(player, entry) end
		announce(player, entry, 'broken')
		CreateThread(function() save(citizenId, entry.id) end)
		TriggerEvent(M.Event.ON_BROKEN, {
			player = player, citizen = citizenId,
			entry = entry.id, grade = tostring(row.grade or ''),
		})
		M.Chrome.Changed(citizenId)
		return true
	end
	if after ~= before then
		announce(player, entry, after)
		-- A band crossing changes what the piece is worth, so the numbers are
		-- recomposed now rather than at the next reconcile.
		M.Chrome.Changed(citizenId)
	end
	return false
end

--- Wears every fitted piece a predicate accepts by the same points.
-- @param player number
-- @param citizenId string
-- @param accept function(entry): boolean
-- @param points number|function(entry): number
local function wearWhere(player, citizenId, accept, points)
	local rows = ledger[citizenId]
	if rows == nil then return end
	-- Collected first: breaking a piece raises events, and the rows table is
	-- not walked while that happens.
	local targets = {}
	for entryId, row in pairs(rows) do
		if row.broken ~= true and tostring(row.grade or '') ~= '' then
			local entry = M.Ripper.Entry(entryId)
			if entry ~= nil and accept(entry, row) then targets[#targets + 1] = entry end
		end
	end
	for _, entry in ipairs(targets) do
		local amount = type(points) == 'function' and points(entry) or points
		M.Chrome.WearPiece(player, citizenId, entry, amount)
	end
end

--- Applies one use-wear event to the pieces it belongs to.
-- @param player number
-- @param eventName string a key of `DURABILITY.WEAR_BY`
function M.Chrome.Wear(player, eventName)
	local selector = M.Ripper.WearSelector(eventName)
	if selector == nil then return end
	player = tonumber(player)
	if player == nil then return end
	local citizenId = citizenOf(player)
	if citizenId == nil then return end
	holders[citizenId] = player
	CreateThread(function()
		M.Chrome.Load(citizenId)
		wearWhere(player, citizenId, function(entry)
			return M.Ripper.WearMatches(selector, entry)
		end, M.Ripper.WearPoints)
	end)
end

--- The damage a body took wears the plating it wears: every fitted piece
--- whose grade carries armor loses its share.
-- @param player number
-- @param amount number health points the hit was worth
function M.Chrome.WearDamage(player, amount)
	local life = M.Ripper.Lifecycle()
	amount = tonumber(amount) or 0
	if amount <= 0 or life.DAMAGE_WEAR <= 0 then return end
	local citizenId = citizenOf(player)
	if citizenId == nil or ledger[citizenId] == nil then return end
	holders[citizenId] = player
	wearWhere(player, citizenId, function(entry, row)
		local grade = M.Ripper.Grade(entry, row.grade)
		local effects = type(grade) == 'table' and grade.EFFECTS or nil
		return type(effects) == 'table' and (tonumber(effects.armor) or 0) > 0
	end, life.DAMAGE_WEAR * amount / 100)
end

--- A death wears everything the body was wearing.
-- @param player number
function M.Chrome.WearDeath(player)
	local life = M.Ripper.Lifecycle()
	if life.DEATH_WEAR <= 0 then return end
	local citizenId = citizenOf(player)
	if citizenId == nil or ledger[citizenId] == nil then return end
	holders[citizenId] = player
	wearWhere(player, citizenId, function() return true end, life.DEATH_WEAR)
end

--- One tick of the clock: every living, connected patient's chrome loses its
--- lifespan's share, and every row that changed is written once.
function M.Chrome.Tick()
	local life = M.Ripper.Lifecycle()
	local wearing = M.Ripper.Durability().enabled ~= false and life.LIFESPAN_HOURS > 0
	local perTick = wearing and 100 * life.TICK_SECONDS / (life.LIFESPAN_HOURS * 3600) or 0
	local read, ids = pcall(Open77.players.all)
	for _, raw in ipairs(read and type(ids) == 'table' and ids or {}) do
		local player = tonumber(raw)
		local citizenId = player ~= nil and citizenOf(player) or nil
		local alive = true
		if player ~= nil and type(Open77.players.isDead) == 'function' then
			local asked2, dead = pcall(Open77.players.isDead, player)
			alive = not (asked2 and dead == true)
		end
		if citizenId ~= nil and ledger[citizenId] ~= nil and alive then
			holders[citizenId] = player
			if wearing then
				wearWhere(player, citizenId, function() return true end, function(entry)
					return entry.ICONIC and perTick / life.ICONIC_LIFESPAN or perTick
				end)
			end
			-- A grant the platform refused at arrival is asked for again every
			-- tick until it lands.
			M.Chrome.Ensure(player)
		end
	end
	M.Chrome.Flush(nil)
end

--- Forgets one citizen's rows after writing what changed -- a character that
--- is put down must not keep wearing, and a slot reused by somebody else must
--- not inherit their chrome. Yields.
-- @param citizenId string|nil
function M.Chrome.Forget(citizenId)
	if type(citizenId) ~= 'string' then return end
	M.Chrome.Flush(citizenId)
	ledger[citizenId], asked[citizenId], holders[citizenId] = nil, nil, nil
end

--- The JSON decoder the wear events arrive through, or nil when the host has
--- none. The same tolerant shape `server/main.lua` reads completions with.
-- @param encoded any
-- @return table|nil
local function decode(encoded)
	if type(json) == 'table' and type(json.decode) == 'function' then
		local ran, result = pcall(json.decode, tostring(encoded or ''))
		if ran and type(result) == 'table' then return result end
	end
	return nil
end

--- One wear door per host event. Each reads its own result and only counts
--- the wear the platform says actually happened.
local function onMeleeHit(victim, attacker, encoded)
	local result = decode(encoded)
	if result ~= nil and result.ok == false then return end
	M.Chrome.Wear(attacker, 'hit')
end

local function onJump(player, encoded)
	local result = decode(encoded)
	if result ~= nil and result.ok == false then return end
	M.Chrome.Wear(player, 'jump')
end

local function onDash(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'accepted' then return end
	M.Chrome.Wear(player, 'dash')
end

local function onReflex(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'active' then return end
	M.Chrome.Wear(player, 'overdrive')
end

local function onAbility(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.ok == false then return end
	M.Chrome.Wear(player, 'slam')
end

--- The hacking transition names its actor inside the JSON (`wiki/hacking.md`:
--- "records correlate actionId, both participants"), and the first argument
--- the host passes is not a promise about which participant it is. Read the
--- actor from the record, and fall back to the argument.
local function onHacking(player, encoded)
	local payload = decode(encoded)
	if payload ~= nil and payload.phase ~= nil and payload.phase ~= 'upload_started'
		and payload.phase ~= 'uploading' then
		return
	end
	local actor = payload ~= nil and (payload.actor or payload.attacker or payload.player) or nil
	M.Chrome.Wear(tonumber(actor) or player, 'upload')
end

--- One definition on one of the platform's shelves, said once either way.
-- @param shelfName string for the log line
-- @param define function the platform's `define`
-- @param definition table
local function put(shelfName, define, definition)
	local ran, result, why = pcall(define, definition)
	local accepted = ran and type(result) == 'table' and result.ok == true
	if accepted then
		shelf[definition.id] = true
		Open77.log.info(('[ripperdoc] the %s %s is on the shelf'):format(shelfName, definition.id))
	else
		local reason = (not ran and result)
			or (type(result) == 'table' and (result.reason or result.error)) or why
		Open77.log.warn(('[ripperdoc] the %s %s was refused: %s')
			:format(shelfName, definition.id, tostring(reason)))
	end
end

--- Defines every movement piece, deck hack and Self-ICE on the platform's own
--- shelves, and arms the wear table. Called from `server/main.lua` at Start.
function M.Chrome.Start()
	local hacking = type(Open77) == 'table' and type(Open77.hacking) == 'table'
		and Open77.hacking or nil
	-- THE MOVEMENT KIT: one definition per distinct config, within what the
	-- platform takes per module (`M.Ripper.GrantPlan`).
	local grantPlan = M.Ripper.GrantPlan()
	local counts = {}
	for _, def in ipairs(grantPlan.defs) do
		local module = M.Ripper.GrantModule({ POWER = { GRANT = def.kind } })
		if module ~= nil and type(module.define) == 'function' then
			put(def.kind, module.define, { id = def.id, version = 1, profile = def.profile,
				config = def.config })
			counts[def.kind] = (counts[def.kind] or 0) + 1
		end
	end
	for kind, count in pairs(counts) do
		Open77.log.info(('[ripperdoc] %d %s definition(s) serve every %s grade on the tray')
			:format(count, kind, kind))
	end
	for _, entry in ipairs(M.Ripper.Catalog()) do
		local kind = M.Ripper.GrantKind(entry)
		if kind == 'hacking' and hacking ~= nil and type(hacking.define) == 'function' then
			-- THE HACK IS THE IMPLANT'S TWIN (`wiki/hacking.md`): one
			-- definition, the implant's own id and version, and every grade
			-- the implant has -- the balance living on each grade row with
			-- its `kind`. A per-grade id was a deck the hacking service had
			-- never heard of.
			local grades = {}
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local row = { id = grade.id }
				for field, value in pairs(type(grade.HACK) == 'table' and grade.HACK or {}) do
					row[field] = value
				end
				if row.kind == nil then row.kind = 'short_circuit' end
				-- The fields the service requires and a hand-written config
				-- may not name (bounds per `wiki/hacking.md`).
				if row.staminaCost == nil then row.staminaCost = 15 end
				if row.statusMs == nil then row.statusMs = 750 end
				if row.recoveryMs == nil then row.recoveryMs = math.max(4000, row.statusMs + 500) end
				if row.lockHacking == nil then row.lockHacking = false end
				if row.nonlethal == nil then row.nonlethal = false end
				grades[#grades + 1] = row
			end
			put('hack', hacking.define, { id = M.Ripper.DefinitionFor(entry, nil), version = 1,
				grades = grades })
		elseif M.Ripper.KindOf(entry) == 'ice' and hacking ~= nil
			and type(hacking.defineIce) == 'function' then
			local grades = {}
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local ice = type(grade.ICE) == 'table' and grade.ICE or {}
				grades[#grades + 1] = { id = grade.id,
					charges = tonumber(ice.charges) or 1,
					rechargeMs = tonumber(ice.rechargeMs) or 30000 }
			end
			put('ice', hacking.defineIce, { id = M.Ripper.DefinitionFor(entry, nil), version = 1,
				grades = grades })
		end
	end

	AddEventHandler('onCyberwareMeleeHit', onMeleeHit)
	AddEventHandler('onCyberwareJump', onJump)
	AddEventHandler('onDashChanged', onDash)
	AddEventHandler('onReflexChanged', onReflex)
	AddEventHandler('onAbilityActivation', onAbility)
	AddEventHandler('onHackingTransition', onHacking)

	-- THE BODY'S OWN WEAR. Arguments are scalar strings on this transport
	-- (docs/combat.md), so every id and amount is read through `tonumber`.
	AddEventHandler('open77:playerDamaged', function(victim, _, amount)
		local player = tonumber(victim)
		if player ~= nil then M.Chrome.WearDamage(player, tonumber(amount)) end
	end)
	-- A DEATH, NOT A MOVE: the platform's join spawn, every placement and
	-- every staff move is a scripted kill and a respawn, and none of them is
	-- the body going down (`wiki/server-api.md`, "Deaths that are not deaths").
	AddEventHandler('onPlayerLifeStateChanged', function(playerId, revision, phase)
		if tostring(phase) ~= 'dead' then return end
		local player = tonumber(playerId)
		if player == nil then return end
		local number = tonumber(revision)
		if number ~= nil then
			if deathRevision[player] ~= nil and number <= deathRevision[player] then return end
			deathRevision[player] = number
		end
		local players = Open77.players
		if type(players.getLifeState) == 'function' then
			local read, life = pcall(players.getLifeState, player)
			if read and type(life) == 'table' and life.cause == 'script' then return end
		end
		M.Chrome.WearDeath(player)
	end)

	-- The host drops session grants with the session; only our bookkeeping
	-- needs sweeping after them -- and the rows, written first. The HOST'S
	-- name for a departure is `onPlayerDisconnected` with the id as its
	-- argument (`OPX.Host`); the FiveM `playerDropped` this used to listen to
	-- is raised by nothing here, so a dropped patient's grants stayed "armed"
	-- in this table and the slot's next holder inherited them.
	local function release(player)
		if player == nil then return end
		armed[M.Ripper.KeyOf(player)] = nil
		ensureWarned[M.Ripper.KeyOf(player)] = nil
		deathRevision[player] = nil
		for citizenId, holder in pairs(holders) do
			if holder == player then
				CreateThread(function() M.Chrome.Forget(citizenId) end)
			end
		end
	end
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		release(tonumber(playerId))
	end)
	-- A character put down on a connection that stays (the relog switch) is a
	-- departure for THAT character's chrome: its grants go and its rows are
	-- written and forgotten, so the next character starts from its own.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(player, data)
		player = tonumber(player)
		if player == nil then return end
		local key = M.Ripper.KeyOf(player)
		for entryId in pairs(armed[key] or {}) do
			local entry = M.Ripper.Entry(entryId)
			if entry ~= nil then disarm(player, entry) end
		end
		armed[key] = nil
		local citizenId = type(data) == 'table' and data.citizenId or nil
		if type(citizenId) == 'string' then
			CreateThread(function() M.Chrome.Forget(citizenId) end)
		end
	end)

	-- THE KIT COMES BACK WITH THE SESSION. A grant dies with the session and
	-- a patient outlives sessions, so a player who is READY -- every hold
	-- cleared, a body to put their character on -- reads their ledger once
	-- and picks up every fitted, unbroken piece it names.
	AddEventHandler(OPX.Host.PLAYER_READY, function(rawPlayerId)
		local player = tonumber(rawPlayerId)
		if player == nil then return end
		CreateThread(function() M.Chrome.Arrive(player) end)
	end)
	-- AND WITH EVERY CHARACTER. A relog puts a new character on the same
	-- connection without a new ready: its ledger is read and its kit armed
	-- the moment it loads, not the next time it sits in a clinic chair.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(rawPlayerId)
		local player = tonumber(rawPlayerId)
		if player == nil then return end
		CreateThread(function() M.Chrome.Arrive(player) end)
	end)

	-- THE CLOCK. One thread for everybody, at the lifecycle's own tick.
	ticking = true
	CreateThread(function()
		while ticking do
			Wait(math.floor(M.Ripper.Lifecycle().TICK_SECONDS * 1000))
			if not ticking then return end
			local ran, failure = pcall(M.Chrome.Tick)
			if not ran then
				Open77.log.warn('[ripperdoc] the wear tick raised: ' .. tostring(failure))
			end
		end
	end)
end

--- Ends the clock. The rows are written by `Stop` in `server/main.lua`, one
--- thread per row, because a shutdown does not resume a yielded loop.
function M.Chrome.Stop()
	ticking = false
end

--- Every dirty row, for the shutdown write.
-- @return table array of { citizen, entry }
function M.Chrome.Dirty()
	local out = {}
	for citizen, rows in pairs(ledger) do
		for entryId, row in pairs(rows) do
			if row.dirty then out[#out + 1] = { citizen = citizen, entry = entryId } end
		end
	end
	return out
end

--- Writes one row now (the shutdown's per-row thread). Yields.
-- @param citizenId string
-- @param entryId string
function M.Chrome.Save(citizenId, entryId)
	save(citizenId, entryId)
end

--- The citizens the ledger holds rows for right now, with the player last
--- seen wearing them.
-- @return table citizen -> player|nil
function M.Chrome.Holders()
	local out = {}
	for citizen in pairs(ledger) do out[citizen] = holders[citizen] end
	return out
end

--- Records which player a citizen is on (the tray and the composer know it
--- first).
-- @param citizenId string
-- @param player number
function M.Chrome.Hold(citizenId, player)
	if type(citizenId) == 'string' and player ~= nil then holders[citizenId] = player end
end

--- Resets the ledger and the grants (a reload starts clean).
function M.Chrome.Init()
	ledger, asked, armed, shelf, holders = {}, {}, {}, {}, {}
	ensureWarned, deathRevision = {}, {}
	warnedRead = false
	ticking = false
end
