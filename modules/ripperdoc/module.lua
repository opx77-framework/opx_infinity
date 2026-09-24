--- The ripperdoc clinic: a chair, a tray of chrome, and the two people it takes.
-- @author XEROX710
--
-- WHAT THIS IS FOR. A job a player can hold (the catalogue already names
-- `ripperdoc` -- Apprentice, Ripperdoc, Chrome Surgeon), a chair a patient sits
-- in, and the platform's own cyberware store behind it. The ripperdoc offers;
-- the patient accepts; the platform stages the work and says when it is done.
--
-- THE MONEY RULE IS THE PLATFORM'S, FOLLOWED EXACTLY. The .87 wiki states it
-- for RP payments: "reserve funds before submission, finalize only on
-- successful completion and compensate failure". So the price is taken at
-- ACCEPT, the charge stands only when `onCyberwareOperationCompleted` says
-- `result.ok == true`, and anything else is refunded to the cent. A staged
-- ticket is pending work, never a finished installation -- which is why the
-- ledger keeps its own transaction record beside it.
--
-- TWO WAYS TO SIT, ONE FUNNEL. With a ripperdoc operating the chair they drive:
-- the patient browses and answers offers. With nobody operating it the patient
-- may serve themselves -- same validation, same reserve-and-settle, just nobody
-- to pay. The request asked for both ("players can work as ripperdocs" and
-- "give users the option to equip/unequip cyberware"), and one code path
-- answers both because the difference is only who may make the offer.
--
-- THE COMPLETION ARRIVES AS A SERVER-LOCAL EVENT and names the player the way
-- the host names them (a string). Tickets are matched to OUR transaction and
-- nobody else's, per the wiki's "never consume someone else's ticket".

local M = OPX.Modules.Declare{
	id = 'ripperdoc',
	side = 'both',
	-- The job side hooks onto `jobs` (the operator's pay funnel); a server
	-- without jobs simply has nobody to bank. The clinic itself works
	-- regardless.
	fatal = false,
	optional = { 'jobs' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Client to server: the press at the chair, and every intent.
	USE = OPX.Event(NET, 'ripperdoc', 'use'),
	STAND = OPX.Event(NET, 'ripperdoc', 'stand'),
	INVITE = OPX.Event(NET, 'ripperdoc', 'invite'),
	OFFER = OPX.Event(NET, 'ripperdoc', 'offer'),
	ANSWER = OPX.Event(NET, 'ripperdoc', 'answer'),
	CLOSE = OPX.Event(NET, 'ripperdoc', 'close'),

	-- Server to client, one player at a time: the whole truth in one frame.
	FRAME = OPX.Event(NET, 'ripperdoc', 'frame'),

	-- THE PLACEMENT ROUND-TRIP, the same shape `modules/garages` uses. A typed
	-- command has no facing of its own, so the server asks the capturer's client
	-- for one (`CAPTURE` out, `CAPTURED` back). `CHAIRS` carries the captured
	-- chairs to every client, and `ASK` is a client asking for them on start.
	CAPTURE = OPX.Event(NET, 'ripperdoc', 'capture'),
	CAPTURED = OPX.Event(NET, 'ripperdoc', 'captured'),
	CHAIRS = OPX.Event(NET, 'ripperdoc', 'chairs'),
	ASK = OPX.Event(NET, 'ripperdoc', 'ask'),

	-- Client-local: what the state half says the page should draw.
	VIEW = OPX.Event(LOCAL, 'ripperdoc', 'view'),
}

-- The two namespaces the module's own files fill. Created here, beside each
-- other, so no file has to index a table that does not exist yet (the reason
-- `modules/skills/module.lua` gives for owning the namespaces in one place).
M.Ripper = {}
M.RipperView = {}

-- The key, in the same shape as the scanner's and the tree's: the id is stable
-- because a player's rebind is stored under it.
M.Ripper.KEY = { ID = 'opx.ripperdoc.use', NAME = 'ripperdoc.key.use', DEFAULT = 'E' }

-- The name a refusal on the placement routeway carries, so a client can tell
-- one operation's refusal from another's.
M.Operation = { CAPTURE = 'clinicCapture' }

-- What a chair key and a chair label may be. The key is the durable name the
-- commands name a chair by; the label is the operator's own words and is never
-- translated.
M.Ripper.MAX_KEY = 48
M.Ripper.MAX_LABEL = 64

--- The captured chairs as rows. The config rows beside them never move: a
-- capture is a chair an operator placed in game, kept in the database and
-- merged into `M.Ripper.Chairs` so every reader sees both without knowing
-- which is which.
M.Ripper.Captured = {}

-- ONE TABLE, TWO READERS, exactly as `M.Radio.Refusal` and `M.Skill.Refusal`
-- are: the server refuses with a code, a player reads a sentence, and the map
-- between them lives here so the panel and the toast say the same thing in the
-- same words. A code this table has not heard of names itself rather than
-- going blank.
M.Ripper.Refusal = {
	noCharacter = 'ripperdoc.noCharacter',
	noSuchChair = 'ripperdoc.noSuchChair',
	noSuchEntry = 'ripperdoc.noSuchEntry',
	noSuchGrade = 'ripperdoc.noSuchGrade',
	noSuchTarget = 'ripperdoc.noSuchTarget',
	tooFar = 'ripperdoc.tooFar',
	taken = 'ripperdoc.taken',
	seated = 'ripperdoc.seated',
	notRipperdoc = 'ripperdoc.notRipperdoc',
	noPatient = 'ripperdoc.noPatient',
	busy = 'ripperdoc.busy',
	slotFilled = 'ripperdoc.slotFilled',
	slotEmpty = 'ripperdoc.slotEmpty',
	noOffer = 'ripperdoc.noOffer',
	noInvite = 'ripperdoc.noInvite',
	cannotPay = 'ripperdoc.cannotPay',
	notReady = 'ripperdoc.notReady',
	hostRefused = 'ripperdoc.hostRefused',
	noHost = 'ripperdoc.noHost',
}

-- The config readers. Resolved when read and never captured (the README's own
-- rule for `M.Settings`), so a reloaded config is the next answer rather than
-- the first one for ever.

--- The tray as the config declares it.
-- @return table the CATALOG array, never nil
function M.Ripper.Catalog()
	return type(M.Settings.CATALOG) == 'table' and M.Settings.CATALOG or {}
end

--- Every chair in the world: the config rows and the captured ones, with a
-- captured chair SHADOWING a config row of the same id (a capture is one chair
-- moved, not two).
-- @return table the merged CHAIRS array, never nil
function M.Ripper.Chairs()
	local config = type(M.Settings.CHAIRS) == 'table' and M.Settings.CHAIRS or {}
	if #M.Ripper.Captured == 0 then return config end
	local taken, merged = {}, {}
	for _, chair in ipairs(M.Ripper.Captured) do taken[chair.id] = true end
	for _, chair in ipairs(config) do
		if not taken[chair.id] then merged[#merged + 1] = chair end
	end
	for _, chair in ipairs(M.Ripper.Captured) do merged[#merged + 1] = chair end
	return merged
end

--- One chair row by id, a captured one before a config one.
-- @param id string
-- @return table|nil
function M.Ripper.Chair(id)
	for _, chair in ipairs(M.Ripper.Captured) do
		if chair.id == id then return chair end
	end
	local config = type(M.Settings.CHAIRS) == 'table' and M.Settings.CHAIRS or {}
	for _, chair in ipairs(config) do
		if chair.id == id then return chair end
	end
	return nil
end

--- One chair row, checked and in the shape every reader already uses -- the
-- shape `config/ripperdoc.lua` CHAIRS declares. Anything that cannot be a
-- chair in the world answers nil and why, named once here so the command, the
-- capture routeway and a row read back out of the database are all refused by
-- one rule.
-- @param key string the durable name
-- @param label string|nil the operator's words; the key when empty
-- @param x any
-- @param y any
-- @param z any
-- @param yaw any
-- @return table|nil, string|nil
function M.Ripper.Row(key, label, x, y, z, yaw)
	if type(key) ~= 'string' or not key:match('^[%w_%-%.]+$') or #key > M.Ripper.MAX_KEY then
		return nil, ('a chair key is 1 to %d letters, digits, dots, dashes or underscores')
			:format(M.Ripper.MAX_KEY)
	end
	label = type(label) == 'string' and label or ''
	label = OPX.String.Trim((label:gsub('%c', ' ')))
	if label == '' then label = key end
	if #label > M.Ripper.MAX_LABEL then label = label:sub(1, M.Ripper.MAX_LABEL) end

	local function coordinate(value)
		local number = tonumber(value)
		if number == nil or number ~= number
			or number == math.huge or number == -math.huge or math.abs(number) > 20000 then
			return nil
		end
		return number
	end
	local X, Y, Z = coordinate(x), coordinate(y), coordinate(z)
	if X == nil or Y == nil or Z == nil then
		return nil, 'the position must be three finite numbers on the map'
	end
	local heading = tonumber(yaw)
	if heading == nil or heading ~= heading
		or heading == math.huge or heading == -math.huge then heading = 0.0 end
	return { id = key, NAME = label, X = X, Y = Y, Z = Z, YAW = heading % 360.0 }
end

--- Replaces the captured list with what is checked, sorted so two runs draw
-- the same chairs in the same order.
-- @param rows table array of rows in the `M.Ripper.Row` shape
-- @return integer how many were accepted
function M.Ripper.SetCaptured(rows)
	local accepted, seen = {}, {}
	for _, row in ipairs(type(rows) == 'table' and rows or {}) do
		local chair = M.Ripper.Row(type(row) == 'table' and row.id or nil,
			type(row) == 'table' and row.NAME or nil,
			type(row) == 'table' and row.X or nil,
			type(row) == 'table' and row.Y or nil,
			type(row) == 'table' and row.Z or nil,
			type(row) == 'table' and row.YAW or nil)
		if chair ~= nil and not seen[chair.id] then
			seen[chair.id] = true
			accepted[#accepted + 1] = chair
		end
	end
	table.sort(accepted, function(a, b) return a.id < b.id end)
	M.Ripper.Captured = accepted
	return #accepted
end

--- One tray entry by its short id.
-- @param id string
-- @return table|nil
function M.Ripper.Entry(id)
	for _, entry in ipairs(M.Ripper.Catalog()) do
		if entry.id == id then return entry end
	end
	return nil
end

--- One grade of an entry.
-- @param entry table
-- @param gradeId string
-- @return table|nil
function M.Ripper.Grade(entry, gradeId)
	for _, grade in ipairs(type(entry) == 'table' and entry.GRADES or {}) do
		if grade.id == gradeId then return grade end
	end
	return nil
end

--- What the clinic charges in.
-- @return string a money type of `OPX.Config.SHARED.MONEY.TYPES`
function M.Ripper.Money()
	return type(M.Settings.MONEY) == 'string' and M.Settings.MONEY or 'EDDIES'
end

--- Metres between the patient and the chair for the press to mean anything.
-- @return number
function M.Ripper.Reach()
	return type(M.Settings.REACH) == 'number' and M.Settings.REACH or 2.5
end

--- Jobs bank points a finished installation pays the operator.
-- @return number
function M.Ripper.Points()
	return type(M.Settings.POINTS) == 'number' and M.Settings.POINTS or 5
end

--- The marker look, in the engine's own vocabulary.
-- @return table
function M.Ripper.Marker()
	return type(M.Settings.MARKER) == 'table' and M.Settings.MARKER
		or { shape = 'cylinder', style = 'interaction', RADIUS = 1.2, LIFT = 0.06 }
end

--- Metres a marker draws from at all.
-- @return number
function M.Ripper.MaxDistance()
	return type(M.Settings.MAX_DISTANCE) == 'number' and M.Settings.MAX_DISTANCE or 150.0
end
