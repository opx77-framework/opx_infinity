--- Server half: the configured headquarters, and who is standing in which bucket.
-- @author XEROX710
--
-- There is nothing to prove here and nothing to create. A headquarters is a
-- marker and a name, both written in `config/headquarters.lua`; what this half
-- owns is the one thing the client cannot know for itself -- which routing
-- bucket the connection is in. A marker drawn for another bucket is not one a
-- player can see, so the list is filtered here and never on the drawing side.
--
-- THE LIST MOVES ON ONE COMMAND. A capture (`/opx.headquarters.add`) saves a
-- station to the database and rebuilds the map under every player at once --
-- and the answer prints the config line to check in, because the file stays
-- the record that outlives a database reset. The same bargain every placed
-- spot on this server makes: capture for today, config for ever.

local M = OPX.Modules.Get('headquarters')
local Access = M.Access

-- The configured spots and the captured ones, keyed by their own name. The
-- captured list is the database's; `rebuild` merges the two into `spots` --
-- captured shadows config, because a capture is one station moved.
local spots = {}
local captures = {}

--- Rebuilds the map every reader merges against: the captured rows are
--- pushed through the one bookkeeping list first, so the module's merge and
--- the database's rows can never disagree. Called at load and after every
--- capture or removal.
local function rebuild()
	local rows = {}
	for _, spot in pairs(captures) do rows[#rows + 1] = spot end
	M.Hq.SetCaptured(rows)
	spots = M.Hq.All()
end

local coordinate, integer = Access.Coordinate, Access.Integer

--- Reads a connection's ground position and bucket, or nil.
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local bucket = integer(position.bucket)
	return { bucket = bucket or 0 }
end

--- The points of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the points of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

--- Sends every connected player their own bucket's points. Guarded: a capture
--- must not fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[headquarters] the sync failed: ' .. tostring(failure))
		end
	end
end

--- The config line to check in, in the shape `config/headquarters.lua`
--- HEADQUARTERS declares.
-- @param spot table
-- @return string
local function configLine(spot)
	return ("  %s = { LABEL = %q, X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d },")
		:format(spot.key, spot.label, spot.x, spot.y, spot.z, spot.bucket)
end

--- Saves one captured station and sets it: the position and the bucket come
--- from the world the operator stands in -- a headquarters has no facing, so
--- one command is the whole capture and there is nothing to ask a client for.
--- Yields.
-- @param player number
-- @param key string
-- @param label string
local function capture(player, key, label)
	local read, position = pcall(Open77.players.position, player)
	position = read and type(position) == 'table' and position or nil
	if position == nil then
		return OPX.CommandResult(player, false,
			'your position could not be read; stand in the world first')
	end
	-- One validator, and it is the config file's own: the shared vocabulary
	-- reads "a config or database row" through `FromDefinition`, and a
	-- capture is both.
	local spot, why = Access.FromDefinition(key, {
		LABEL = label,
		X = position.x, Y = position.y, Z = position.z,
		BUCKET = position.bucket,
	})
	if spot == nil then
		Open77.log.warn(('[headquarters] player %d capture of %s refused: %s')
			:format(player, tostring(key), tostring(why)))
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = M.Storage.Upsert(spot)
	if type(saved) ~= 'table' or saved.ok ~= true then
		local detail = type(saved) == 'table' and saved.detail or 'no answer'
		Open77.log.warn(('[headquarters] player %d could not save the capture of %s: %s')
			:format(player, tostring(spot.key), tostring(detail)))
		return OPX.CommandResult(player, false, 'could not save: ' .. tostring(detail))
	end

	captures[spot.key] = spot
	rebuild()
	syncAll()
	Open77.log.info(('[headquarters] %s captured at %.2f,%.2f,%.2f bucket=%d by %d')
		:format(spot.key, spot.x, spot.y, spot.z, spot.bucket, player))
	OPX.CommandResult(player, true,
		('%s set -- check it in to survive a database reset:\n%s')
			:format(spot.key, configLine(spot)))
end

-- ── the command ─────────────────────────────────────────────────────────────

-- Prints every configured headquarters: what it is called, where it is and
-- which bucket it lives in.
local function report(source)
	local lines = {}
	local keys = {}
	for key in pairs(spots) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local spot = spots[keys[index]]
		lines[#lines + 1] = ('%s %q at %.2f, %.2f, %.2f bucket=%d %s'):format(
			spot.key, spot.label, spot.x, spot.y, spot.z, spot.bucket,
			captures[spot.key] ~= nil and 'captured' or 'config')
	end
	if #keys == 0 then
		lines[#lines + 1] = locale('headquarters.none')
	end
	lines[#lines + 1] = ('%d headquarters'):format(#keys)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Registers one command from the config, or nothing when it is unnamed.
-- @param name string|nil
-- @param opts table
-- @param handler function
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Registers the capture, removal and listing commands -- the same three
--- every other station module ships.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'headquarters.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('headquarters.help.addKey') },
			{ name = 'label', optional = true, help = locale('headquarters.help.addLabel') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > Access.MAX_KEY then
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(Access.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a station whose key the operator never
			-- learned could not be removed or checked in afterwards.
			local index = 0
			repeat index = index + 1
				until captures['hq' .. index] == nil and spots['hq' .. index] == nil
			key = 'hq' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end
		CreateThread(function()
			capture(source, key, label)
		end)
	end)

	register(names.remove, {
		restricted = true,
		help = 'headquarters.help.remove',
		params = { { name = 'key', help = locale('headquarters.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captures[key] == nil then
			return OPX.CommandResult(source, false, spots[key] ~= nil
				and 'that headquarters comes from config; edit config/headquarters.lua to remove it'
				or 'no captured headquarters named ' .. key)
		end
		CreateThread(function()
			local gone = M.Storage.Delete(key)
			if type(gone) ~= 'table' or gone.ok ~= true then
				return OPX.CommandResult(source, false, 'could not delete: '
					.. tostring(type(gone) == 'table' and gone.detail or 'no answer'))
			end
			captures[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[headquarters] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'headquarters.help.list' }, function(source)
		report(source)
	end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and the database's captures. Never yields.
function M.Init()
	captures = {}
	rebuild()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes this module's half of the contract.
-- The spots, and nothing else: a HUD or a blip module that wants to mark the
-- station reads the same validated points the markers are drawn from.
function M.Api()
	OPX.Api.Provide('headquarters', 1, {
		Spots = function() return spots end,
		State = function()
			return { spots = OPX.Table.Count(spots) }
		end,
	})
end

--- Wires the one door and the one command.
function M.Start()
	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[headquarters] config: ' .. line)
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil then return end
		sync(player)
	end)

	-- THE CAPTURES THE DATABASE ALREADY HOLDS. Read up whatever it answers:
	-- an operator has to be able to capture into a database that had nothing.
	CreateThread(function()
		local rows = M.Storage.FetchAll()
		if type(rows) ~= 'table' or rows.ok ~= true then
			Open77.log.error('[headquarters] captured stations could not be read: '
				.. tostring(type(rows) == 'table' and rows.detail or 'no answer'))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted = {}
		for index = 1, #loaded do
			local record = loaded[index]
			local spot = nil
			if type(record) == 'table' then
				-- The database row, read through the config file's own rule:
				-- the shared vocabulary says a definition is "what an operator
				-- writes in a config file and what a captured row holds".
				spot = Access.FromDefinition(record.hq_key, {
					LABEL = record.label,
					X = record.x, Y = record.y, Z = record.z,
					BUCKET = record.bucket,
				})
			end
			if spot ~= nil then
				accepted[#accepted + 1] = spot
				captures[spot.key] = spot
			else
				Open77.log.warn('[headquarters] a captured station row was refused and skipped')
			end
		end
		rebuild()
		syncAll()
		Open77.log.info(('[headquarters] %d captured station(s) read from the database')
			:format(#accepted))
	end)

	Open77.log.info(('[headquarters] ready: %d configured'):format(OPX.Table.Count(spots)))
end
