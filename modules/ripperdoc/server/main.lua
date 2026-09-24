--- The clinic's server half: the chair, the ledger, and every decision about
-- chrome. One authority -- the page a player presses is a picture of what this
-- half already said.
-- @author XEROX710
--
-- THE TRANSACTION IS THE PLATFORM'S OWN RULE, FOLLOWED EXACTLY. Reserve the
-- price before submission, finalize only on a completion that says
-- `result.ok == true`, compensate anything else. So `settle` takes the money,
-- stages the work and keeps ITS OWN record beside the platform's ticket -- and
-- `onCompleted` is the only place a charge is ever kept or given back.
--
-- A TICKET IS PENDING WORK, NEVER A PURCHASE. The wiki is emphatic and this
-- file believes it: the staged response says `{ok=true, ticket=...}` and the
-- work lands later, as a server-local event that names the player the way the
-- host names them (a string). `keyOf` exists so a ticket finds its patient
-- whichever side named them, and a ticket that is not OURS is left alone --
-- "never consume someone else's ticket".
--
-- THE SEATS ARE SELF-HEALING WITHOUT A DROP EVENT. A body that left the server
-- leaves no event here worth trusting (the platform has several doorways and
-- this module opens none of them), so every seat is REAPED ON TOUCH: `use`
-- frees a chair whose bodies are gone before deciding anything about it. A
-- chair can therefore never stay taken for ever, which is the failure a
-- drop-hook would have to be perfect to avoid.

local M = OPX.Modules.Get('ripperdoc')
local Event = M.Event
local Refusal = M.Ripper.Refusal

-- Contracts, resolved on first use rather than in a phase: an optional
-- dependency may publish after this module has run.
local character, jobs = nil, nil

-- chair id -> { sitter, attendant, playback, offer, invite }
local seats = {}
-- normalized player key -> { chair, role, player }
local where = {}
-- normalized patient key -> the staged transaction awaiting its completion.
local pending = {}
-- Offer ids, so an answer names the offer it answers and not whatever is
-- current by then.
local offerSeq = 0

-- The host's ceiling discipline from `core/client/ui.lua`: frames carry one
-- page of facts and nothing more.
local ROWS_MAX = 8

--- The contracts, fetched once and kept.
local function contracts()
	if character == nil then character = OPX.Api.Get('character') end
	if jobs == nil then jobs = OPX.Api.Get('jobs') end
end

--- One player's character record, or nil when there is none to read.
-- @param player number
-- @return table|nil
local function data(player)
	contracts()
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local ran, record = pcall(character.GetPlayer, player)
	if not ran or type(record) ~= 'table' then return nil end
	-- The contract answers the PLAYER object and the facts live on its
	-- PlayerData -- the same shape `modules/ncpd/server/radio.lua` reads.
	return type(record.PlayerData) == 'table' and record.PlayerData or record
end

--- Whether this character holds the ripperdoc job (either shape the record
-- comes in: a jobs map keyed by name, or a current job with a name).
-- @param record table|nil
-- @return boolean
local function holdsRipperdoc(record)
	if record == nil then return false end
	if type(record.jobs) == 'table' and record.jobs.ripperdoc ~= nil then return true end
	return type(record.job) == 'table' and record.job.name == 'ripperdoc'
end

--- The one normalizer. The host names players as strings on the cyberware wire
-- ("Player IDs follow host string conventions") and as numbers in this
-- runtime's handlers; one key for both so a ticket matches its patient.
-- @param player number|string
-- @return number|string
local function keyOf(player)
	return tonumber(player) or tostring(player)
end

--- The cyberware store, or nil on a host without it.
local function store()
	return type(Open77) == 'table' and Open77.cyberware or nil
end

--- The durable record, or nil while it is still loading (the wiki: "Both return
-- nil while loading/projecting/restoring") -- which is `notReady`, never a
-- silent proceed.
-- @param player number
-- @return table|nil
local function recordOf(player)
	local api = store()
	if api == nil or type(api.current) ~= 'function' then return nil end
	local ran, record = pcall(api.current, player)
	if not ran then return nil end
	return type(record) == 'table' and record or nil
end

--- The implant sitting in a slot of a record, or nil.
-- @param record table|nil
-- @param slot string
-- @return table|nil
local function implantOf(record, slot)
	if type(record) ~= 'table' then return nil end
	local implant = record[slot]
	return type(implant) == 'table' and implant or nil
end

--- How far the player stands from a chair, and whether that is close enough.
-- @param player number
-- @param chair table
-- @param reach number
-- @return boolean
local function near(player, chair, reach)
	local api = type(Open77) == 'table' and Open77.players or nil
	if api == nil or type(api.position) ~= 'function' then return false end
	local ran, position = pcall(api.position, player)
	if not ran or type(position) ~= 'table' then return false end
	local dx = (position.x or 0) - (chair.X or 0)
	local dy = (position.y or 0) - (chair.Y or 0)
	local dz = (position.z or 0) - (chair.Z or 0)
	return (dx * dx + dy * dy + dz * dz) <= (reach * reach)
end

--- The seat for a chair, created on first use.
-- @param chairId string
-- @return table
local function seatOf(chairId)
	local seat = seats[chairId]
	if seat == nil then
		seat = { sitter = nil, attendant = nil, playback = nil, offer = nil, invite = nil }
		seats[chairId] = seat
	end
	return seat
end

--- Frees a chair whose bodies are no longer on the server. THE cleanup -- see
-- the file's note on drop events.
-- @param chairId string
local function reap(chairId)
	local seat = seats[chairId]
	if seat == nil then return end
	for role, key in pairs({ sitter = seat.sitter, attendant = seat.attendant }) do
		if key ~= nil then
			local at = where[key]
			local alive = at ~= nil and data(at.player) ~= nil
			if not alive then
				seat[role] = nil
				if role == 'sitter' then seat.playback, seat.offer = nil, nil end
				where[key] = nil
			end
		end
	end
end

--- The tray as the page draws it: what is fitted, what a grade costs, and the
-- numbers each grade carries (content, not decoration -- rule 8).
-- @param key number|string the normalized patient
-- @return table rows
local function rowsFor(key)
	local at = where[key]
	local record = at ~= nil and recordOf(at.player) or nil
	local rows = {}
	for _, entry in ipairs(M.Ripper.Catalog()) do
		if #rows >= ROWS_MAX then break end
		local implant = implantOf(record, entry.SLOT)
		local fitted = ''
		if implant ~= nil and type(implant.grade) == 'table' then
			fitted = tostring(implant.grade.id or '')
		end
		local grades = {}
		for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
			grades[#grades + 1] = {
				id = grade.id,
				name = grade.NAME,
				price = grade.PRICE,
				owned = fitted == tostring(grade.id),
				stats = grade.VALUE,
			}
		end
		rows[#rows + 1] = {
			id = entry.id,
			name = entry.NAME,
			slot = entry.SLOT,
			remove = entry.REMOVE,
			fitted = fitted,
			mine = implant ~= nil
				and tostring(implant.definition or '') == tostring(entry.DEFINITION),
			grades = grades,
		}
	end
	return rows
end

--- The one offer, as both sides see it.
-- @param seat table
-- @return table|nil
local function offerView(seat)
	local offer = seat.offer
	if offer == nil then return nil end
	return {
		id = offer.id,
		mode = offer.mode,
		entry = offer.entry,
		grade = offer.grade,
		name = offer.name,
		price = offer.price,
		by = offer.byName,
	}
end

--- Everybody worth offering the seat to: players at the chair who are not
-- already part of this chair. The host's own roster (`Open77.players.all`,
-- unguarded by design) read tolerantly -- a roster of ids and a roster of
-- records are both common shapes and neither is documented on the card.
-- @param chair table
-- @param seat table
-- @return table rows
local function invitees(chair, seat)
	local rows = {}
	local api = type(Open77) == 'table' and Open77.players or nil
	if api == nil or type(api.all) ~= 'function' then return rows end
	local ran, everyone = pcall(api.all)
	if not ran or type(everyone) ~= 'table' then return rows end
	for _, other in ipairs(everyone) do
		if #rows >= ROWS_MAX then break end
		local otherPlayer = type(other) == 'table'
			and (other.id or other.player or other.source or other.playerId) or other
		local otherKey = keyOf(otherPlayer)
		local record = type(otherPlayer) == 'number' and data(otherPlayer) or nil
		if record ~= nil and otherKey ~= seat.attendant and where[otherKey] == nil
			and near(otherPlayer, chair, M.Ripper.Reach() * 4) then
			rows[#rows + 1] = { id = otherPlayer, name = record.name or tostring(otherPlayer) }
		end
	end
	return rows
end

--- The whole truth for one player, in one frame. THE AUTO-OPEN IS THIS: the
-- sitter's menu appears because a `sitter` frame arrived, not because anyone
-- pressed a key.
-- @param key number|string
-- @param flash table|nil the sentence to state, if any
-- @return table frame
local function frameFor(key, flash)
	local at = where[key]
	if at == nil then return { mode = 'closed', why = 'noSeat' } end
	local seat = seats[at.chair]
	local chair = M.Ripper.Chair(at.chair)
	if seat == nil or chair == nil then return { mode = 'closed', why = 'noSeat' } end

	if at.role == 'sitter' then
		return {
			mode = 'sitter',
			chair = at.chair,
			name = chair.NAME,
			attended = seat.attendant ~= nil,
			busy = pending[key] ~= nil,
			offer = offerView(seat),
			catalogue = rowsFor(key),
			flash = flash,
		}
	end

	local patient = seat.sitter
	return {
		mode = 'desk',
		chair = at.chair,
		name = chair.NAME,
		patient = patient ~= nil and (where[patient] or {}).player or 0,
		patientName = patient ~= nil and (data((where[patient] or {}).player) or {}).name or nil,
		busy = patient ~= nil and pending[patient] ~= nil,
		offer = offerView(seat),
		invitees = patient == nil and invitees(chair, seat) or {},
		catalogue = patient ~= nil and rowsFor(patient) or {},
		flash = flash,
	}
end

--- Sends one player a frame.
-- @param player number
-- @param frame table
local function pushTo(player, frame)
	if player == nil then return end
	local sent, failure = pcall(TriggerClientEvent, M.Event.FRAME, player, frame)
	if not sent then
		Open77.log.warn('[ripperdoc] the frame did not leave: ' .. tostring(failure))
	end
end

--- Sends a seated player their own fresh frame.
-- @param key number|string
-- @param flash table|nil
local function push(key, flash)
	local at = where[key]
	if at == nil then return end
	pushTo(at.player, frameFor(key, flash))
end

--- Everyone at one chair, refreshed.
-- @param seat table
-- @param flash table|nil the sentence only the actor reads
-- @param actor number|string|nil
local function refresh(seat, flash, actor)
	-- TWO SLOTS, WALKED EXPLICITLY: `ipairs` over `{sitter, attendant}` would
	-- stop at the first nil and skip the operator on an empty chair.
	for index = 1, 2 do
		local key = index == 1 and seat.sitter or seat.attendant
		if key ~= nil then push(key, actor == key and flash or nil) end
	end
end

--- States a refusal the way this player can read it: inside the panel when
-- they have one, as a notice when they do not.
-- @param player number
-- @param code string a key of `M.Ripper.Refusal`
-- @param args table|nil
local function refuse(player, code, args)
	local key = keyOf(player)
	local flash = { key = Refusal[code] or code, args = args or {} }
	if where[key] ~= nil then
		push(key, flash)
	else
		pushTo(player, { mode = 'notice', flash = flash })
	end
end

--- Puts the patient in the chair: the platform's own portable `chair` workspot,
-- posed on the chair's spot and facing the way it faces.
-- @param source number
-- @param key number|string
-- @param chair table
-- @param seat table
local function sit(source, key, chair, seat)
	local api = type(Open77) == 'table' and Open77.animations or nil
	if api == nil or type(api.playAt) ~= 'function' then
		return refuse(source, 'noHost')
	end
	local ran, playback = pcall(api.playAt, source, 'chair',
		{ x = chair.X, y = chair.Y, z = chair.Z }, chair.YAW or 0, {})
	if not ran or type(playback) ~= 'table' or playback.playbackId == nil then
		return refuse(source, 'hostRefused')
	end
	seat.sitter = key
	seat.playback = playback.playbackId
	where[key] = { chair = chair.id, role = 'sitter', player = source }
	-- THE AUTO-OPEN: this frame is the menu appearing in front of them.
	push(key, nil)
	if seat.attendant ~= nil then push(seat.attendant, nil) end
end

--- Gives the price back. The wiki's "compensate failure", in one place.
-- @param player number
-- @param price number
local function compensate(player, price)
	contracts()
	if character == nil or type(character.AddMoney) ~= 'function' then return end
	local ran, ok = pcall(character.AddMoney, player, M.Ripper.Money(), price, 'ripperdoc:refund')
	if not ran or ok ~= true then
		Open77.log.error(('[ripperdoc] the refund of %d for player %s did not land')
			:format(price, tostring(player)))
	end
end

--- Takes the price and stages the work -- the reserve step of the platform's
-- own money rule. Nothing is kept or refunded here: the completion event owns
-- that, and it is the only thing that does.
-- @param source number the patient
-- @param key number|string the patient's key
-- @param seat table
-- @param offer table
local function settle(source, key, seat, offer)
	if pending[key] ~= nil then
		return refuse(source, 'busy')
	end
	local entry = M.Ripper.Entry(offer.entry)
	if entry == nil then
		return refuse(source, 'noSuchEntry')
	end

	-- RESERVE, before submission.
	contracts()
	local charged = false
	if character ~= nil and type(character.RemoveMoney) == 'function' then
		local ran, ok = pcall(character.RemoveMoney, source, M.Ripper.Money(), offer.price,
			('ripperdoc:%s:%s'):format(offer.mode, offer.entry))
		charged = ran and ok == true
	end
	if not charged then
		seat.offer = nil
		refresh(seat, { key = Refusal.cannotPay, args = {} }, key)
		return
	end

	local api = store()
	local record = recordOf(source)
	if api == nil or type(api.install) ~= 'function' or type(api.remove) ~= 'function'
		or type(api.newOperationId) ~= 'function' or type(record) ~= 'table' then
		compensate(source, offer.price)
		seat.offer = nil
		refresh(seat, { key = Refusal.notReady, args = {} }, key)
		return
	end

	-- A fresh operation id per intent, and the revision we actually read: the
	-- two things the wiki says a retry must keep and a new intent must not.
	local operationId = api.newOperationId()
	local out, reason
	if offer.mode == 'install' then
		local ran
		ran, out, reason = pcall(api.install, source, entry.DEFINITION, offer.grade,
			{ expectedRevision = record.revision, operationId = operationId })
		if not ran then out, reason = nil, out
		end
	else
		local ran
		ran, out, reason = pcall(api.remove, source,
			{ slot = entry.SLOT, expectedRevision = record.revision, operationId = operationId })
		if not ran then out, reason = nil, out
		end
	end
	if type(out) ~= 'table' or out.ok ~= true then
		compensate(source, offer.price)
		seat.offer = nil
		refresh(seat, {
			key = Refusal.hostRefused,
			args = { why = tostring(reason or out or 'refused') },
		}, key)
		return
	end

	pending[key] = {
		ticket = out.ticket,
		operationId = operationId,
		expectedRevision = record.revision,
		price = offer.price,
		mode = offer.mode,
		entry = offer.entry,
		grade = offer.grade,
		patient = source,
		patientCitizen = (data(source) or {}).citizenId,
		operatorPlayer = offer.byPlayer,
		operatorCitizen = offer.byCitizen,
	}
	seat.offer = nil
	refresh(seat, nil, nil)
end

--- THE OTHER HALF OF THE MONEY RULE: the platform says the work is done, and
-- only here is a charge kept or given back. A ticket that is not one of ours is
-- left for its owner ("never consume someone else's ticket").
-- @param player number|string the host's name for the patient
-- @param ticket any
-- @param encoded string the result, JSON per the wiki
local function onCompleted(player, ticket, encoded)
	local key = keyOf(player)
	local op = pending[key]
	if op == nil or tostring(op.ticket) ~= tostring(ticket) then return end
	pending[key] = nil

	local done = false
	if type(json) == 'table' and type(json.decode) == 'function' then
		local ran, result = pcall(json.decode, tostring(encoded or ''))
		done = ran and type(result) == 'table' and result.ok == true
	end

	if done then
		-- FINALIZE: the charge stands, and the operator is paid through the
		-- jobs funnel -- the same `pay` every shift and arrest goes through,
		-- so the seniority bank and the skill tree see this work like any
		-- other. Self-service pays nobody.
		if op.operatorCitizen ~= nil then
			contracts()
			if jobs ~= nil and type(jobs.Award) == 'function' then
				pcall(jobs.Award, op.operatorCitizen, 'ripperdoc', M.Ripper.Points())
			end
		end
		local flash = {
			key = op.mode == 'install' and 'ripperdoc.done.fit' or 'ripperdoc.done.pull',
			args = { grade = tostring(op.grade or op.entry) },
		}
		if where[key] ~= nil then push(key, flash) end
		if op.operatorPlayer ~= nil and where[keyOf(op.operatorPlayer)] ~= nil then
			push(keyOf(op.operatorPlayer), {
				key = 'ripperdoc.done.paid', args = { points = M.Ripper.Points() },
			})
		end
	else
		-- COMPENSATE: the wiki's word for it, and the only path that gives
		-- money back.
		compensate(op.patient, op.price)
		if where[key] ~= nil then
			push(key, { key = Refusal.hostRefused, args = { why = 'rolled_back' } })
		end
	end

	local at = where[key]
	if at ~= nil then
		local seat = seats[at.chair]
		if seat ~= nil then refresh(seat, nil, nil) end
	end
end

-- The wiki calls it a server-local event and the example names the same handler
-- as a global entry point. Both doors, one handler: the pending map makes a
-- double delivery a no-op, and neither build of the host can miss the work.
AddEventHandler('onCyberwareOperationCompleted', onCompleted)
onCyberwareOperationCompleted = onCompleted

-- ── the placement commands ──────────────────────────────────────────────────────
--
-- A chair is placed the way `modules/clothing` places a store and
-- `modules/garages` a spot: stand there, look the way the patient should face,
-- run `/opx.clinic.add`. The position is read HERE and never off the wire; the
-- facing is the one field a client contributes, because a chat command has
-- none of its own.

-- The captured chairs by key, and the captures still waiting on a facing.
local captures = {}
local captureAsked = {}
-- What an unanswered capture ask is worth waiting for.
local CAPTURE_TIMEOUT_MS = 5000

--- Whether the ACL lets this player run a capture command. The host resolves
--- `command.<name>` before a COMMAND handler runs, and the capture routeway
--- has no such gate of its own -- so the door asks the same question here. An
--- unreadable ACL answers no: a door that cannot be checked is not one to
--- leave open.
-- @param player number
-- @param name string|nil
-- @return boolean
local function aclAllows(player, name)
	if type(name) ~= 'string' or name == '' then return false end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

--- Rebuilds the captured list every reader merges against. Called at load and
--- after every capture or removal.
local function rebuild()
	local rows = {}
	for _, chair in pairs(captures) do rows[#rows + 1] = chair end
	M.Ripper.SetCaptured(rows)
end

--- The captured chairs as rows, ready for the wire.
-- @return table
local function chairList()
	local rows = {}
	for index, chair in ipairs(M.Ripper.Captured) do rows[index] = chair end
	return rows
end

--- Sends one player every captured chair.
-- @param player number
local function syncChairs(player)
	if type(player) ~= 'number' then return end
	TriggerClientEvent(M.Event.CHAIRS, player, chairList())
end

--- Sends every connected player the chairs. Guarded: a capture must not fail
--- because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(syncChairs, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[ripperdoc] chairs sync failed: ' .. tostring(failure))
		end
	end
end

--- The config line to check in, in the shape `config/ripperdoc.lua` CHAIRS
--- declares.
-- @param chair table
-- @return string
local function configLine(chair)
	return ('  %s = { id = %q, NAME = %q, X = %.2f, Y = %.2f, Z = %.2f, YAW = %.1f },')
		:format(chair.id, chair.id, chair.NAME, chair.X, chair.Y, chair.Z, chair.YAW)
end

--- Prints every chair: position, facing, and where it comes from.
-- @param source number
local function report(source)
	local lines = {}
	local capturedCount = 0
	local chairs = M.Ripper.Chairs()
	for _, chair in ipairs(chairs) do
		local fromDatabase = captures[chair.id] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s pos=%.2f,%.2f,%.2f yaw=%.1f %s'):format(
			chair.id, tostring(chair.NAME), chair.X or 0.0, chair.Y or 0.0, chair.Z or 0.0,
			chair.YAW or 0.0, fromDatabase and 'captured' or 'config')
	end
	lines[#lines + 1] = ('%d chair(s): %d from config, %d captured')
		:format(#chairs, #chairs - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Saves one captured chair: the position from the server, the facing from the
--- client that answered. Yields.
-- @param player number
-- @param key string
-- @param label string
-- @param yaw any the client's own facing, or nil
local function capture(player, key, label, yaw)
	local read, position = pcall(Open77.players.position, player)
	position = read and type(position) == 'table' and position or nil
	local chair, why = M.Ripper.Row(key, label,
		position ~= nil and position.x or nil,
		position ~= nil and position.y or nil,
		position ~= nil and position.z or nil, yaw)
	if chair == nil then
		Open77.log.warn(('[ripperdoc] player %d capture of %s refused: %s')
			:format(player, tostring(key), tostring(why)))
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = M.Storage.Upsert(chair)
	if type(saved) ~= 'table' or saved.ok ~= true then
		local detail = type(saved) == 'table' and saved.detail or 'no answer'
		Open77.log.warn(('[ripperdoc] player %d could not save the capture of %s: %s')
			:format(player, tostring(chair.id), tostring(detail)))
		return OPX.CommandResult(player, false, 'could not save: ' .. tostring(detail))
	end

	captures[chair.id] = chair
	rebuild()
	syncAll()
	Open77.log.info(('[ripperdoc] %s captured at %.2f,%.2f,%.2f yaw=%.1f by %d')
		:format(chair.id, chair.X, chair.Y, chair.Z, chair.YAW, player))
	OPX.CommandResult(player, true,
		('%s saved -- check it in to survive a database reset:\n%s'):format(chair.id, configLine(chair)))
end

--- Watches one capture ask and says so when the client never answered: a chair
--- that was never captured reads exactly like one captured elsewhere.
-- @param player number
-- @param askedAt number
-- @param key string
local function watchCapture(player, askedAt, key)
	CreateThread(function()
		while true do
			local entry = captureAsked[player]
			if entry == nil or entry.at ~= askedAt then return end
			if OPX.Now() - askedAt >= CAPTURE_TIMEOUT_MS then break end
			Wait(100)
		end
		local entry = captureAsked[player]
		if entry == nil or entry.at ~= askedAt then return end
		captureAsked[player] = nil
		Open77.log.warn(('[ripperdoc] player %d did not answer the capture of %s within %d ms; ' ..
			'nothing was saved'):format(player, tostring(key), CAPTURE_TIMEOUT_MS))
		OPX.NotifyLocale(player, 'ripperdoc.captureNoAnswer', { key = tostring(key) }, 'error')
	end)
end

--- Registers one command from the config, or nothing when it is unnamed.
-- @param name string|nil
-- @param opts table
-- @param handler function
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Registers the placement, listing and removal commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'ripperdoc.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('ripperdoc.help.addKey') },
			{ name = 'label', optional = true, help = locale('ripperdoc.help.addLabel') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > M.Ripper.MAX_KEY then
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(M.Ripper.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a chair whose key the operator never
			-- learned could not be removed or checked in afterwards.
			local index = 0
			repeat index = index + 1
				until captures['clinic' .. index] == nil and M.Ripper.Chair('clinic' .. index) == nil
			key = 'clinic' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end

		-- The facing is the operator's own and a chat command has none, so the
		-- client is asked for it -- recorded before the ask, so an answer that
		-- arrives immediately cannot be mistaken for one that arrived before it
		-- was ever requested.
		local at = OPX.Now()
		captureAsked[source] = { at = at }
		TriggerClientEvent(M.Event.CAPTURE, source, key, label)
		Open77.log.info(('[ripperdoc] asked player %d for the facing of the chair %s')
			:format(source, tostring(key)))
		watchCapture(source, at, key)
		OPX.CommandResult(source, true,
			'capturing a chair where you are standing; look the way the patient should face')
	end)

	register(names.remove, {
		restricted = true,
		help = 'ripperdoc.help.remove',
		params = { { name = 'key', help = locale('ripperdoc.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captures[key] == nil then
			return OPX.CommandResult(source, false, M.Ripper.Chair(key) ~= nil
				and 'that chair comes from config; edit config/ripperdoc.lua to remove it'
				or 'no captured chair named ' .. key)
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
			Open77.log.info(('[ripperdoc] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'ripperdoc.help.list' }, function(source)
		report(source)
	end)
end

--- Resets the module's world (a reload starts clean).
function M.Init()
	seats, where, pending = {}, {}, {}
	offerSeq = 0
	captures, captureAsked = {}, {}
	rebuild()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Wires the five doors: the press, the intents, and the completion.
function M.Start()
	-- THE SHELF GOES UP FIRST. An install against a definition the store does
	-- not know is refused by the platform itself, so registration is the
	-- clinic's precondition and not decoration. The grade rows are the
	-- platform's own shared schema (the config's VALUE fields beside each
	-- grade's id), exactly as the .87 wiki's example definitions are shaped.
	local api = store()
	if api ~= nil and type(api.define) == 'function' then
		for _, entry in ipairs(M.Ripper.Catalog()) do
			local grades = {}
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local row = { id = grade.id }
				for field, value in pairs(type(grade.VALUE) == 'table' and grade.VALUE or {}) do
					row[field] = value
				end
				grades[#grades + 1] = row
			end
			local ran, result, why = pcall(api.define, {
				id = entry.DEFINITION,
				version = 1,
				slot = entry.SLOT,
				profile = entry.PROFILE,
				grades = grades,
			})
			-- THE ANSWER IS A TABLE -- the platform's `{ok=...}`. `nil, reason`
			-- is only the transport's; a domain refusal carries its reason in
			-- the table. Comparing the table to `true` calls every acceptance a
			-- refusal AND swallows the reason, which is what the first staging
			-- boot printed: "was refused: nil" twice, for two definitions the
			-- store had accepted. Read what is actually returned.
			local accepted = ran and type(result) == 'table' and result.ok == true
			if accepted then
				Open77.log.info(('[ripperdoc] the definition %s is on the shelf')
					:format(tostring(entry.DEFINITION)))
			else
				local reason = (not ran and result)
					or (type(result) == 'table' and (result.reason or result.error))
					or why
				Open77.log.warn(('[ripperdoc] the definition %s was refused: %s')
					:format(tostring(entry.DEFINITION), tostring(reason)))
			end
		end
	else
		Open77.log.warn('[ripperdoc] no cyberware store on this host; nothing can be fitted')
	end

	-- THE PRESS AT THE CHAIR. The role decides what it means: a ripperdoc
	-- operates the chair, anybody else sits in it -- one key, one event, and
	-- the routing is the server's because only the server knows the job.
	RegisterNetEvent(M.Event.USE, function(chairId)
		-- THE SENDER IS THE `source` GLOBAL, never a parameter: the host
		-- delivers payload only and names the connection in `source` around
		-- the call. A `source` parameter here took `chairId` for its sender
		-- and shifted every parameter one place left.
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)
		local record = data(source)
		if record == nil then
			return refuse(source, 'noCharacter')
		end
		local chair = M.Ripper.Chair(tostring(chairId or ''))
		if chair == nil then
			return refuse(source, 'noSuchChair')
		end
		-- Self-healing first: a chair whose bodies are gone is a free chair.
		reap(chair.id)
		if where[key] ~= nil then
			return refuse(source, 'seated')
		end
		if not near(source, chair, M.Ripper.Reach()) then
			return refuse(source, 'tooFar')
		end
		local seat = seatOf(chair.id)
		if holdsRipperdoc(record) then
			if seat.attendant ~= nil then
				return refuse(source, 'busy')
			end
			seat.attendant = key
			where[key] = { chair = chair.id, role = 'attendant', player = source }
			push(key, nil)
			if seat.sitter ~= nil then push(seat.sitter, nil) end
			return
		end
		if seat.sitter ~= nil then
			return refuse(source, 'taken')
		end
		sit(source, key, chair, seat)
	end)

	-- THE SITTER LEAVES. The workspot is stopped by its playback handle; a
	-- staged transaction is NOT cancelled by standing -- the platform owns its
	-- outcome and the money rule still settles it.
	RegisterNetEvent(M.Event.STAND, function()
		-- The sender is the `source` global (see the press above).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)
		local at = where[key]
		if at == nil or at.role ~= 'sitter' then
			return refuse(source, 'noPatient')
		end
		local seat = seats[at.chair]
		local api = type(Open77) == 'table' and Open77.animations or nil
		if api ~= nil and type(api.stop) == 'function' and seat.playback ~= nil then
			pcall(api.stop, source, seat.playback)
		end
		seat.sitter, seat.playback, seat.offer = nil, nil, nil
		where[key] = nil
		pushTo(source, { mode = 'closed', why = 'stood' })
		if seat.attendant ~= nil then push(seat.attendant, nil) end
	end)

	-- THE OPERATOR STEPS AWAY. The patient's menu stays -- with nobody at the
	-- desk they may serve themselves (the request's second door).
	RegisterNetEvent(M.Event.CLOSE, function()
		-- The sender is the `source` global (see the press above).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)
		local at = where[key]
		if at == nil or at.role ~= 'attendant' then
			return refuse(source, 'notRipperdoc')
		end
		local seat = seats[at.chair]
		seat.attendant, seat.invite = nil, nil
		where[key] = nil
		pushTo(source, { mode = 'closed', why = 'left' })
		if seat.sitter ~= nil then push(seat.sitter, nil) end
	end)

	-- THE OPTION TO SIT, from the operator to somebody at the chair.
	RegisterNetEvent(M.Event.INVITE, function(target)
		-- The sender is the `source` global (see the press above).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)
		local at = where[key]
		if at == nil or at.role ~= 'attendant' then
			return refuse(source, 'notRipperdoc')
		end
		local seat = seats[at.chair]
		local chair = M.Ripper.Chair(at.chair)
		if seat.sitter ~= nil then
			return refuse(source, 'taken')
		end
		if seat.invite ~= nil then
			return refuse(source, 'busy')
		end
		local other = tonumber(target) or target
		local otherKey = keyOf(other)
		local record = type(other) == 'number' and data(other) or nil
		if record == nil or otherKey == key then
			return refuse(source, 'noSuchTarget')
		end
		if not near(other, chair, M.Ripper.Reach() * 4) then
			return refuse(source, 'tooFar')
		end
		seat.invite = { by = key, to = otherKey, player = other }
		push(key, nil)
		pushTo(other, {
			mode = 'invite',
			chair = at.chair,
			name = chair.NAME,
			from = (data(source) or {}).name,
		})
	end)

	-- THE ANSWERS, to the invite and to the offer. Only the addressee may
	-- answer, and an offer names the one it answers rather than trusting
	-- whatever is current.
	RegisterNetEvent(M.Event.ANSWER, function(what, accept)
		-- The sender is the `source` global (see the press above).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)

		if what == 'invite' then
			for chairId, seat in pairs(seats) do
				local invite = seat.invite
				if invite ~= nil and invite.to == key then
					seat.invite = nil
					local chair = M.Ripper.Chair(chairId)
					if accept == true then
						reap(chairId)
						if seat.sitter == nil and chair ~= nil then
							sit(source, key, chair, seat)
						else
							refuse(source, 'taken')
						end
					else
						pushTo(source, { mode = 'closed', why = 'declined' })
					end
					if where[invite.by] ~= nil then push(invite.by, nil) end
					return
				end
			end
			return refuse(source, 'noInvite')
		end

		if what == 'offer' then
			local at = where[key]
			if at == nil or at.role ~= 'sitter' then
				return refuse(source, 'noOffer')
			end
			local seat = seats[at.chair]
			local offer = seat.offer
			if offer == nil then
				return refuse(source, 'noOffer')
			end
			seat.offer = nil
			if accept ~= true then
				refresh(seat, { key = 'ripperdoc.offerDeclined', args = {} }, nil)
				return
			end
			settle(source, key, seat, offer)
			return
		end

		refuse(source, 'noOffer')
	end)

	-- THE OFFER. Two doors, one funnel: the chair's operator toward their
	-- patient, or -- with nobody operating -- the patient, for themselves.
	RegisterNetEvent(M.Event.OFFER, function(entryId, gradeId, mode)
		-- The sender is the `source` global (see the press above).
		source = tonumber(source)
		if source == nil or source <= 0 then return end
		local key = keyOf(source)
		local at = where[key]
		if at == nil then
			return refuse(source, 'noPatient')
		end
		local entry = M.Ripper.Entry(tostring(entryId or ''))
		if entry == nil then
			return refuse(source, 'noSuchEntry')
		end
		mode = mode == 'remove' and 'remove' or 'install'
		local grade = nil
		if mode == 'install' then
			grade = M.Ripper.Grade(entry, tostring(gradeId or ''))
			if grade == nil then
				return refuse(source, 'noSuchGrade', { grade = tostring(gradeId or '') })
			end
		end

		local seat = seats[at.chair]
		local patientKey, byPlayer, byCitizen, byName
		if at.role == 'attendant' then
			if seat.sitter == nil then
				return refuse(source, 'noPatient')
			end
			patientKey = seat.sitter
			byPlayer, byCitizen, byName = source,
				(data(source) or {}).citizenId, (data(source) or {}).name
		elseif at.role == 'sitter' and seat.attendant == nil then
			-- Self-service: the request's "give users the option to equip and
			-- unequip" door, open only while nobody is operating the chair.
			patientKey = key
		else
			return refuse(source, 'notRipperdoc')
		end

		if pending[patientKey] ~= nil or seat.offer ~= nil then
			return refuse(source, 'busy')
		end

		-- THE SLOT RULES, read from the platform's own record (the wiki:
		-- "consult `current` for slot-empty rules"). A change of grade is a
		-- pull and then a fit -- two honest offers, never a silent overwrite.
		local patientPlayer = (where[patientKey] or {}).player
		local record = recordOf(patientPlayer)
		if record == nil then
			return refuse(source, 'notReady')
		end
		local implant = implantOf(record, entry.SLOT)
		if mode == 'install' and implant ~= nil then
			return refuse(source, 'slotFilled', { slot = entry.SLOT })
		end
		if mode == 'remove' and implant == nil then
			return refuse(source, 'slotEmpty', { slot = entry.SLOT })
		end

		offerSeq = offerSeq + 1
		seat.offer = {
			id = offerSeq,
			mode = mode,
			entry = entry.id,
			grade = grade ~= nil and grade.id or nil,
			name = grade ~= nil and grade.NAME or entry.NAME,
			price = mode == 'install' and grade.PRICE or entry.REMOVE,
			by = patientKey ~= key and key or nil,
			byPlayer = byPlayer,
			byCitizen = byCitizen,
			byName = byName,
		}
		refresh(seat, nil, nil)
	end)

	-- THE PLACEMENT DOORS. The three commands, the capture routeway and the
	-- chairs feed, and the rows the database already holds. All of it up at
	-- Start whatever the database answered: an operator has to be able to read
	-- back what the configuration says, and `add` is how a database that
	-- answered nothing gets filled.
	registerCommands()

	-- The capture door, gated exactly as the command that opens it: a net event
	-- has no host-side ACL check, so the same question is asked here. A client
	-- that sends this unprompted is either the operator or nobody.
	RegisterNetEvent(M.Event.CAPTURED, function(key, label, yaw)
		local player = tonumber(source)
		if player == nil then return end

		-- Settled by the arrival itself, accepted or not: an answer is an answer,
		-- and a "did not answer" warning after one has landed would be a lie.
		captureAsked[player] = nil

		local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
		if not aclAllows(player, names.add) then
			Open77.log.warn(('[ripperdoc] player %d tried to capture a chair without %s')
				:format(player, tostring(names.add)))
			return OPX.Refuse(player, 'error.noPermission', M.Operation.CAPTURE)
		end

		CreateThread(function()
			capture(player, key, label, yaw)
		end)
	end)

	-- A client that has just come up wants the captured chairs, so its markers
	-- draw the ones the database holds as well as the config rows it already
	-- knows.
	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil then return end
		syncChairs(player)
	end)

	CreateThread(function()
		local rows = M.Storage.FetchAll()
		if type(rows) ~= 'table' or rows.ok ~= true then
			Open77.log.error('[ripperdoc] captured chairs could not be read: '
				.. tostring(type(rows) == 'table' and rows.detail or 'no answer'))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted = 0
		for index = 1, #loaded do
			local record = loaded[index]
			local chair = M.Ripper.Row(type(record) == 'table' and record.chair_key or nil,
				type(record) == 'table' and record.label or nil,
				type(record) == 'table' and record.x or nil,
				type(record) == 'table' and record.y or nil,
				type(record) == 'table' and record.z or nil,
				type(record) == 'table' and record.yaw or nil)
			if chair ~= nil then
				captures[chair.id] = chair
				accepted = accepted + 1
			else
				Open77.log.warn('[ripperdoc] a captured chair row was refused and skipped')
			end
		end
		rebuild()
		syncAll()
		Open77.log.info(('[ripperdoc] %d captured chair(s) read from the database')
			:format(accepted))
	end)
end

--- Publishes the read side of the clinic: the chairs and the tray, for a
-- resource that wants to price or place something beside this one.
function M.Api()
	OPX.Api.Provide('ripperdoc', 1, {
		Chairs = M.Ripper.Chairs,
		Catalog = M.Ripper.Catalog,
		--- What one grade would cost at this clinic.
		-- @param entryId string
		-- @param gradeId string
		-- @return number|nil
		Quote = function(entryId, gradeId)
			local entry = M.Ripper.Entry(tostring(entryId or ''))
			local grade = entry ~= nil and M.Ripper.Grade(entry, tostring(gradeId or '')) or nil
			return grade ~= nil and grade.PRICE or nil
		end,
	})
end
