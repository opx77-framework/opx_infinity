--- Client half: the markers, the strip row, the key, the job list and the desk.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT, and the list doubly so. The nearest board, the
-- radius and every row's own verdict come from the server: which jobs are on
-- offer, whether one is already the player's, which grade they hold, how far the
-- next rank is and what is missing from the terms are all decided on the other
-- side and carried on the payload. THIS FILE DERIVES NONE OF IT -- a client
-- holding a second copy of the rules would be the copy that is minutes stale.
--
-- TWO KINDS OF BOARD, TWO MENUS. A SIGN-UP board is the employment office: one
-- marker a player walks up to, listing every job the config offers with their own
-- standing against each, and a job's own screen showing its ladder and either the
-- sign-up row or the notice row. A BOSS board is a division's desk, and a player
-- only ever receives one if they hold that job's boss grade: its screen lists the
-- roster and, for each member, the three things a boss may do to them, plus a
-- hire screen for whoever is standing close enough.
--
-- The whole tree in one spec would go past the host's 1024-value bound, and a
-- roster is whatever a division grew to, so the list is the `menu` module's with
-- this file holding its own stack -- the pattern the emote picker established and
-- the dealership follows.
--
-- The heading a capture records is read HERE and not on the server: a chat
-- command has no facing, and `Open77.character.yaw` is the only place a facing
-- exists. It is the one field this half contributes, and it only turns a board.

local M = OPX.Modules.Get('jobs')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'jobs'
local GROUP = 'board'

-- The id the menu is opened under, and the same id comes back on every payload.
-- Stable, because a payload names it.
local SPEC_ID = 'jobs'

-- The boards as the server last sent them, by key, and the markers drawn for
-- them. `states[key]` is the server's own verdict about that board for this
-- player, kept beside the board rather than inside it because `FromWire` answers
-- a board and nothing else.
local boards, states, markers = {}, {}, {}

-- The roster of each desk this player may manage, as the server last sent it:
-- job name -> `{ members, top }`.
local rosters = {}

-- The board the player is standing on, and whether its row is up.
local nearest, shown = nil, false

-- The board whose verdict was last asked for, and the board whose list is
-- waiting on one. A verdict is a tree of values that arrives on its own event,
-- so a press that lands before it has can neither open an empty list nor be lost:
-- the ask goes out once per board, and the list opens when the answer does.
local askedKey, pendingOpen = nil, nil

-- Whether the key mapping answered.
local keyRegistered = false

-- The open menu's handle, and the screen stack this file owns.
local handle, stack = nil, {}

-- Whether each failure was already logged: a marker that cannot be drawn, a row
-- that cannot be posted and a list that cannot open are three different problems
-- and a player reading the log wants to know which one they have.
local reportedMarkers, reportedStrip, reportedMenu = false, false, false

-- The last "what am I holding and drawing" signature, so a CHANGE in the drawn
-- set is said once rather than every scan. A marker that is not there was silent
-- in every direction before this: the server sends the boards a player may see
-- and the client draws the ones in range, and neither said WHICH of the two had
-- decided against a board an operator had just placed.
local reportedDraw = nil

--- Whether the arrival of a board's verdict was already said. Kept apart from
--- the board list's own line because the two travel separately now, and a
--- verdict that never came has to read differently from a board that did.
local reportedState = false

--- What the server last sent, so its arrival is said once per change. Kept
--- apart from the drawn set on purpose: the drawn line only runs once there is a
--- world position to measure, so a payload that arrived while the client could
--- not read one would otherwise look exactly like a payload that never came.
local reportedReceived = nil

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- ── config and the player ───────────────────────────────────────────────────

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.jobs.use', NAME = 'jobs.key.use', DEFAULT = 'E' }
end

-- Reads the menu geometry declaration, with the shipped panel as the fallback so
-- a config that lost its MENU block still opens a large centred list rather than
-- a strip down the corner. The menu module clamps every value it is handed.
local function menuSettings()
	local declared = type(M.Settings.MENU) == 'table' and M.Settings.MENU or nil
	return declared or {
		ANCHOR = 'center', WIDTH = 708, HEIGHT = 708, MAX_HEIGHT_VH = 88, VISIBLE_ROWS = 15,
	}
end

-- The player's own ground position, or nil before there is a world to read.
local function playerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- The player's own facing in degrees, or nil. Read only when a capture is asked
-- for, because that is the only time it is used.
local function playerYaw()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.yaw) ~= 'function' then return nil end
	local read, yaw = pcall(character.yaw)
	if not read or type(yaw) ~= 'number' or yaw ~= yaw then return nil end
	return yaw
end

-- Whether another surface holds the keyboard: the chat box, a form, the pause
-- menu. Kept module-local rather than folded into `OPX.Lib.Input.IsCaptured`,
-- which answers captured when the read itself raises where this answers free.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

-- ── the markers ─────────────────────────────────────────────────────────────

-- Creates one marker, or answers why it could not be. Never raises.
local function createMarker(board)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'world.markers is unavailable'
	end
	local look = Access.Marker(board.kind)
	local read, id, reason = pcall(api.create, {
		-- The board's declared height plus the look's own lift: a marker left at
		-- floor height is co-planar with the floor and draws nothing at all.
		position = { x = board.x, y = board.y, z = board.z + look.lift },
		shape = look.shape,
		style = look.style,
		radius = look.radius,
		maxDistance = Access.MaxDistance(),
	})
	if not read then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end
	return id, nil
end

-- Removes one marker without raising.
local function removeMarker(id)
	local api = Open77.markers
	if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

-- Brings the drawn set in line with what is in range: a board within
-- MAX_DISTANCE has a marker, one beyond it does not. The position is threaded
-- through from the one scan that read it, so this module costs one host position
-- read per pass rather than two.
-- @param x number|nil
-- @param y number|nil
local function reconcile(x, y)
	local reach = Access.MaxDistance()
	local limit = reach * reach

	for key, board in pairs(boards) do
		local flat = nil
		if x ~= nil then flat = Access.FlatDistanceSquared(board, x, y) end
		local wanted = flat ~= nil and flat <= limit
		if wanted and markers[key] == nil then
			local id, failure = createMarker(board)
			if id == nil then
				if not reportedMarkers then
					reportedMarkers = true
					Open77.log.warn(('[jobs] no marker is drawn: %s'):format(tostring(failure)))
				end
			else
				markers[key] = id
			end
		elseif not wanted and markers[key] ~= nil then
			removeMarker(markers[key])
			markers[key] = nil
		end
	end

	-- A board the server no longer names loses its marker here rather than being
	-- left behind: it may have been removed while it was in range.
	for key, id in pairs(markers) do
		if boards[key] == nil then
			removeMarker(id)
			markers[key] = nil
		end
	end

	-- WHAT IS HELD AND WHAT IS DRAWN, ONCE PER CHANGE, with the nearest one in
	-- metres. This is the line the live symptom was missing: "the job marker
	-- isn't appearing" is decided by two halves that were both silent, and one
	-- line naming the boards held, the markers drawn and the shortest distance
	-- separates "the server never sent it" from "it is 3.4 km away".
	local held, drawn, nearestMetres = OPX.Table.Count(boards), 0, nil
	for key in pairs(markers) do
		drawn = drawn + 1
		local board = boards[key]
		if board ~= nil and x ~= nil then
			local flat = Access.FlatDistanceSquared(board, x, y)
			if flat ~= nil then
				local metres = math.sqrt(flat)
				if nearestMetres == nil or metres < nearestMetres then nearestMetres = metres end
			end
		end
	end
	local signature = drawn .. '/' .. held
	if signature ~= reportedDraw then
		reportedDraw = signature
		Open77.log.info(('[jobs] %d board(s) held, %d marker(s) drawn%s'):format(held, drawn,
			nearestMetres ~= nil and ('; nearest %.1f m'):format(nearestMetres) or ''))
	end
end

-- Drops every marker this module drew.
local function clearMarkers()
	for key, id in pairs(markers) do
		removeMarker(id)
		markers[key] = nil
	end
end

-- ── the strip ───────────────────────────────────────────────────────────────

-- Names the key the row is bound to, or nil when it is off or was refused -- a
-- row with no key to name says nothing.
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = keySettings()
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

-- The offer this player already holds on the board they are standing on, if any.
-- Read from the server's own state so the row never invites somebody to sign up
-- for the job they are already working.
local function heldOffer()
	if nearest == nil then return nil end
	local state = states[nearest.key]
	local offers = type(state) == 'table' and state.offers or nil
	for index = 1, type(offers) == 'table' and #offers or 0 do
		local offer = offers[index]
		if type(offer) == 'table' and type(offer.held) == 'number' then return offer end
	end
	return nil
end

-- Brings the strip in line with where the player is standing.
local function syncPrompt()
	local want = nearest ~= nil and keyLabel() ~= nil and not captured() and handle == nil
	if want == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the list, and this is
		-- said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[jobs] no prompts contract; the strip row is not shown')
		end
		shown = false
		return
	end

	shown = want
	local ran, answer
	if want then
		local row = nil
		if nearest.kind == M.KIND.BOSS then
			row = locale('jobs.prompt.boss')
		elseif heldOffer() ~= nil then
			row = locale('jobs.prompt.quit')
		else
			row = locale('jobs.prompt.signup')
		end
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line.
			label = row,
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[jobs] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Every answer shares the one id, so the last thing said replaces the
-- one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.jobs.answer',
		kind = kind,
		title = locale('jobs.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[jobs] ' .. tostring(message)) end
end

-- ── the rows ────────────────────────────────────────────────────────────────

-- The right-hand column of one job row: what the player's own standing is.
-- Nothing here is derived -- `state` is the server's answer.
-- @param state table
-- @return string
local function statusOf(state)
	if type(state.held) == 'number' then
		local parts = { state.grade or ('grade ' .. tostring(state.held)) }
		if state.isBoss then parts[#parts + 1] = locale('jobs.status.boss') end
		if state.next == nil then
			parts[#parts + 1] = locale('jobs.status.top')
		elseif type(state.points) == 'number' and type(state.required) == 'number' then
			parts[#parts + 1] = locale('jobs.status.progress', {
				points = ('%.0f'):format(state.points),
				required = ('%.0f'):format(state.required),
				next = state.nextGrade or ('grade ' .. tostring(state.next)),
			})
		end
		return table.concat(parts, '  |  ')
	end
	if state.approval == true then return locale('jobs.status.approval') end
	if state.open ~= true then return locale('jobs.status.closed') end
	if state.canJoin == true then return locale('jobs.status.open') end
	-- Shown but not joinable, and the reason is the server's own: the same
	-- refusal the press would get, before the press.
	return state.missing ~= nil and locale(state.missing, { job = state.job })
		or locale('jobs.status.closed')
end

-- The rows of one job's own screen: the ladder, then the one action that applies
-- to this player's standing.
-- @param state table
-- @return table[]|nil
local function jobRows(state)
	local grades = type(state.grades) == 'table' and state.grades or nil
	local items = {}
	for index = 1, type(grades) == 'table' and #grades or 0 do
		local grade = grades[index]
		items[#items + 1] = {
			id = 'grade' .. tostring(grade.level),
			label = ('%d  %s'):format(grade.level, tostring(grade.name or '?')),
			value = grade.level == state.held and locale('jobs.status.you')
				or (grade.isBoss and locale('jobs.status.boss') or nil),
		}
	end

	if type(state.held) == 'number' then
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'leave', label = locale('jobs.row.leave'),
			data = { action = 'leave', job = state.job } }
	else
		items[#items + 1] = { separator = true, label = '' }
		if state.canJoin == true then
			items[#items + 1] = { id = 'join', label = locale('jobs.row.join'),
				value = state.grade or locale('jobs.row.entry'),
				data = { action = 'join', job = state.job } }
		else
			items[#items + 1] = { id = 'wait', label = locale('jobs.status.closed'),
				value = state.missing ~= nil and locale(state.missing, { job = state.job }) or nil }
		end
	end

	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'back', label = locale('jobs.row.back'), back = true }
	return items
end

-- The rows of a desk's root screen: the hire row and one submenu per member.
-- @param key string the board
-- @return table[]|nil
local function deskRows(key)
	local board = boards[key]
	local roster = type(board) == 'table' and rosters[board.job] or nil
	local members = type(roster) == 'table' and roster.members or nil
	if type(members) ~= 'table' then return nil end

	local items = {
		{ id = 'hire', label = locale('jobs.row.hire'), submenu = true, data = { hire = true } },
		{ separator = true, label = '' },
	}
	if #members == 0 then
		items[#items + 1] = { id = 'nobody', label = locale('jobs.row.noMembers') }
	else
		for index = 1, #members do
			local member = members[index]
			items[#items + 1] = {
				id = tostring(member.citizenId),
				label = ('%s  %s'):format(member.gradeName or ('grade ' .. tostring(member.grade)),
					tostring(member.name)),
				value = member.isBoss and locale('jobs.status.boss') or nil,
				submenu = true,
				data = { citizenId = tostring(member.citizenId) },
			}
		end
	end
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'close', label = locale('jobs.row.close'), close = true }
	return items
end

-- The rows of one member's screen: what a boss may do to them.
-- @param key string the board
-- @param citizenId string
-- @return table[]|nil
local function memberRows(key, citizenId)
	local board = boards[key]
	local roster = type(board) == 'table' and rosters[board.job] or nil
	local members = type(roster) == 'table' and roster.members or nil
	if type(members) ~= 'table' then return nil end

	local member = nil
	for index = 1, #members do
		if tostring(members[index].citizenId) == citizenId then member = members[index] end
	end
	if member == nil then return nil end

	local items = {}
	for _, action in ipairs(M.DESK_ORDER) do
		items[#items + 1] = {
			id = action,
			label = locale('jobs.row.' .. action),
			data = { action = action, citizenId = citizenId },
		}
	end
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'back', label = locale('jobs.row.back'), back = true }
	return items
end

-- The rows of the hire screen: everybody the server said is standing close
-- enough. Read-only here; the press names a connection and the server re-measures
-- against its own positions, so a client that named somebody across the map is
-- refused by name.
-- @param key string the board
-- @return table[]|nil
local function hireRows(key)
	if boards[key] == nil then return nil end
	local state = states[key] or {}
	local candidates = type(state.candidates) == 'table' and state.candidates or {}

	local items = {}
	if #candidates == 0 then
		items[#items + 1] = { id = 'nobody', label = locale('jobs.row.noCandidates') }
	else
		for index = 1, #candidates do
			local candidate = candidates[index]
			items[#items + 1] = {
				id = tostring(candidate.source),
				label = tostring(candidate.name),
				data = { candidate = candidate.source },
			}
		end
	end
	items[#items + 1] = { separator = true, label = '' }
	items[#items + 1] = { id = 'back', label = locale('jobs.row.back'), back = true }
	return items
end

-- ── the list ────────────────────────────────────────────────────────────────

-- The row handler the menu calls back on. Declared here and assigned below,
-- because the menu contract wants the callback at open time and `draw` hands it
-- over.
local onRow
-- Forward declaration (same idiom): the open path above asks for a board\u{2019}s
-- verdict before `askState` is defined near the end of this file, and without
-- this line that call reaches for a GLOBAL `askState` -- nil -- taking the
-- whole resource down. The declaration must stand before the closures that
-- call it, so it lives here rather than beside the definition.
local askState

-- The menu contract, or nil.
local function menuApi()
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' or type(api.Close) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.info('[jobs] no menu contract: no list can be drawn, and the commands ' ..
				'still work typed')
		end
		return nil
	end
	return api
end

-- The rows and title of one screen, or nil when it cannot be built at all.
-- @param current table
-- @return string|nil title
-- @return table|nil items
-- @return table|nil extra
local function screenFor(current)
	local board = boards[current.board]
	if board == nil then return nil end
	local state = states[current.board] or {}

	if current.screen == 'signup' then
		local offers = type(state.offers) == 'table' and state.offers or {}
		if #offers == 0 then return nil end
		local items = {}
		for index = 1, #offers do
			local offer = offers[index]
			items[#items + 1] = {
				id = tostring(offer.job),
				label = tostring(offer.label or offer.job),
				value = statusOf(offer),
				submenu = true,
				data = { job = tostring(offer.job) },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'close', label = locale('jobs.row.close'), close = true }
		return locale('jobs.menu.jobs'), items
	end

	if current.screen == 'job' then
		local offers = type(state.offers) == 'table' and state.offers or {}
		local offer = nil
		for index = 1, #offers do
			if offers[index].job == current.job then offer = offers[index] end
		end
		if offer == nil then return nil end
		local items = jobRows(offer)
		if items == nil then return nil end
		return locale('jobs.menu.job', { job = tostring(offer.label or offer.job) }), items
	end

	if current.screen == 'desk' then
		local items = deskRows(current.board)
		if items == nil then return nil end
		local roster = rosters[board.job] or {}
		return locale('jobs.menu.desk', { job = tostring(state.label or board.job) }), items, {
			status = locale('jobs.status.roster', {
				count = tostring(#(roster.members or {})),
				top = tostring(roster.top or 0),
			}),
		}
	end

	if current.screen == 'member' then
		local items = memberRows(current.board, current.citizenId)
		if items == nil then return nil end
		local name = current.citizenId
		local roster = rosters[board.job] or {}
		for index = 1, #(roster.members or {}) do
			if tostring(roster.members[index].citizenId) == current.citizenId then
				name = roster.members[index].name
			end
		end
		return locale('jobs.menu.member', { name = tostring(name) }), items
	end

	if current.screen == 'hire' then
		local items = hireRows(current.board)
		if items == nil then return nil end
		return locale('jobs.menu.hire', { job = tostring(state.label or board.job) }), items
	end

	return nil
end

-- Takes the menu down for a reason of this file's own.
local function takeDown()
	local closing = handle
	handle, stack = nil, {}
	local api = OPX.Api.Get('menu')
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, OWNER)
	end
	syncPrompt()
	return closing ~= nil
end

-- Draws the screen on top of the stack, or updates the one already up.
-- `inPlace` is the redraw: a roster that arrived under an open desk, or a rank
-- that moved while its screen was up.
local function draw(inPlace)
	local current = stack[#stack]
	if current == nil then return false end

	local title, items, extra = screenFor(current)
	if title == nil then
		-- The screen cannot be built: the board or the member under an open list
		-- went away. Stepping back is the honest answer where there is a screen
		-- to step back to, and taking it down where there is not.
		if inPlace and #stack > 1 then
			stack[#stack] = nil
			return draw(true)
		end
		takeDown()
		say('error', locale('jobs.refused'))
		return false
	end
	extra = extra or {}

	local api = menuApi()
	if api == nil then
		takeDown()
		return false
	end

	if inPlace then
		if handle == nil then return false end
		local patched = api.Update(handle, { title = title, items = items, status = extra.status })
		if patched ~= nil and patched.ok then return true end
		-- The handle went stale under us: fall through and ask for the menu.
		handle = nil
	end

	local where = menuSettings()
	local opened = api.Open({
		owner = OWNER,
		id = SPEC_ID,
		title = title,
		on = onRow,
		cursor = current.cursor,
		anchor = where.ANCHOR,
		width = where.WIDTH,
		height = where.HEIGHT,
		maxHeight = where.MAX_HEIGHT_VH,
		rows = where.VISIBLE_ROWS,
		items = items,
		status = extra.status,
	})
	if opened == nil or opened.ok ~= true then
		local failure = type(opened) == 'table' and tostring(opened.error or 'refused') or 'refused'
		if not reportedMenu then
			reportedMenu = true
			Open77.log.warn(('[jobs] the list did not open: %s'):format(failure))
		end
		takeDown()
		return false
	end
	handle = opened.value.handle
	return true
end

-- Navigates to a screen under the current one.
local function push(screen, arg)
	stack[#stack + 1] = { screen = screen, board = arg.board, job = arg.job,
		citizenId = arg.citizenId }
	if draw() then return true end
	stack[#stack] = nil
	return false
end

-- Steps back one screen, closing the list at the top of the stack.
local function pop()
	if #stack <= 1 then return takeDown() end
	stack[#stack] = nil
	return draw()
end

-- Sends one desk action, and says when the wire refused the request outright.
-- The answer to the action itself arrives as its own event, and the roster is
-- re-sent with it, so nothing is assumed here about what happened.
-- @param key string
-- @param action string
-- @param target any
-- @return table
local function act(key, action, target)
	local sent, reason = TriggerServerEvent(M.Event.BOSS, key, action, target, key)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		say('error', locale('jobs.refused'))
		return verdict
	end
	local verdict = { ok = true, queued = true, board = key, action = action, source = 'key' }
	publish(verdict)
	return verdict
end

-- Sends a join for one job on one board. `M.Join` on the other side names the
-- board as the place and the job as the work, and re-derives every term.
local function join(key, job)
	local sent, reason = TriggerServerEvent(M.Event.JOIN, key, job)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		say('error', locale('jobs.refused'))
		return verdict
	end
	local verdict = { ok = true, queued = true, board = key, job = job, source = 'key' }
	publish(verdict)
	return verdict
end

-- Sends the notice for the job a board stands for.
local function leave(key, job)
	local sent, reason = TriggerServerEvent(M.Event.LEAVE, key)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		say('error', locale('jobs.refused'))
		return verdict
	end
	local verdict = { ok = true, queued = true, board = key, job = job, source = 'key' }
	publish(verdict)
	return verdict
end

-- Navigates, acts, or finishes for a row the menu raised. The shape is checked
-- because the menu also raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end

	if payload.action == 'close' then
		-- A close for a screen this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		-- Back on a one-level screen would close it; step up instead.
		if payload.reason == 'back' and #stack > 1 then return pop() end
		stack = {}
		return syncPrompt()
	end
	if payload.action ~= 'select' or captured() then return end

	local data = payload.data
	local current = stack[#stack]
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId

	if current.screen == 'signup' then
		if type(data.job) ~= 'string' then return end
		return push('job', { board = current.board, job = data.job })
	end

	if current.screen == 'job' then
		if data.action == 'join' then return join(current.board, data.job) end
		if data.action == 'leave' then return leave(current.board, data.job) end
		return
	end

	if current.screen == 'desk' then
		if data.hire == true then return push('hire', { board = current.board }) end
		if type(data.citizenId) == 'string' then
			return push('member', { board = current.board, citizenId = data.citizenId })
		end
		return
	end

	if current.screen == 'hire' then
		if data.candidate == nil then return end
		local board = boards[current.board]
		local job = type(board) == 'table' and board.job or nil
		if job == nil then return end
		return act(current.board, M.ACTION.HIRE, data.candidate)
	end

	if current.screen == 'member' then
		if type(data.action) ~= 'string' or type(data.citizenId) ~= 'string' then return end
		return act(current.board, data.action, data.citizenId)
	end
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- Opens the list for the board the player is standing on, or closes it.
-- @author XEROX710
-- @param origin string|nil the key or a caller's name
-- @return table
function Runtime.Open(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end

	-- The same key closes what it opened. Asked of this file's own handle rather
	-- than of the menu's state, because the menu is shared: another module's menu
	-- is not this one's to close.
	if handle ~= nil then
		takeDown()
		result.ok, result.closed = true, true
		publish(result)
		return result
	end

	if nearest == nil then
		result.ok, result.error = false, 'jobs.noSuchBoard'
		publish(result)
		return result
	end

	-- THE LIST IS THE SERVER'S VERDICT, so a press that lands before the verdict
	-- has does not open an empty one: the ask goes out (if it is not already on
	-- its way) and the list opens the moment the answer arrives. Nothing is said
	-- -- the row is up, the board is underfoot, and the answer is a round trip
	-- away -- which is why this is not an error a player reads.
	if states[nearest.key] == nil then
		pendingOpen = nearest.key
		askState(nearest.key)
		result.ok, result.error = false, 'jobs.loading'
		publish(result)
		return result
	end

	stack = { { screen = nearest.kind == M.KIND.BOSS and 'desk' or 'signup',
		board = nearest.key } }
	if not draw() then
		result.ok, result.error = false, 'jobs.noList'
		publish(result)
		say('error', locale(nearest.kind == M.KIND.BOSS and 'jobs.rosterFailed' or 'jobs.notOpen'))
		return result
	end
	syncPrompt()
	result.ok, result.board = true, nearest.key
	-- The candidates for a hire are a position read per player and are only worth
	-- asking for when a desk is actually open.
	if nearest.kind == M.KIND.BOSS then
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[jobs] the desk roster could not be asked for: ' .. tostring(reason))
		end
	end
	publish(result)
	return result
end

--- Closes the list this file opened.
-- @author XEROX710
-- @return table
function Runtime.Close()
	if not takeDown() then return { ok = false, error = 'not_open' } end
	return { ok = true }
end

--- Whether this file's own list is up.
-- @author XEROX710
-- @return boolean
function Runtime.IsOpen()
	return handle ~= nil
end

--- The board the player is standing on, or nil.
-- @author XEROX710
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every board this client was told about, by key.
-- @author XEROX710
-- @return table
function Runtime.Boards()
	return boards
end

--- What the server said about one board for this player.
-- @author XEROX710
-- @param key string
-- @return table|nil
function Runtime.State(key)
	return states[key]
end

--- The roster of a desk this player may manage, or nil.
-- @author XEROX710
-- @param job string
-- @return table|nil
function Runtime.Roster(job)
	return rosters[job]
end

--- What this client knows, for a diagnostic or a test.
-- @author XEROX710
-- @return table
function Runtime.Report()
	local current = stack[#stack]
	local offers = nearest ~= nil and states[nearest.key]
		and type(states[nearest.key].offers) == 'table' and #states[nearest.key].offers or 0
	local desks = 0
	for _ in pairs(rosters) do desks = desks + 1 end
	return {
		boards = OPX.Table.Count(boards),
		markers = OPX.Table.Count(markers),
		nearest = nearest and nearest.key or nil,
		kind = nearest and nearest.kind or nil,
		shown = shown,
		key = keyLabel(),
		open = handle ~= nil,
		screen = current and current.screen or nil,
		offers = offers,
		desks = desks,
		held = heldOffer() ~= nil,
	}
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- Asks the server for its verdict on one board.
--
-- Said once per board, because the answer is a tree of values and the ask is a
-- round trip: a client walking a line of boards would otherwise ask for each one
-- fifty times a second. `again` is the list's own refresh, which re-reads a
-- verdict it already holds -- the half that changes while a player stands still
-- (a rank granted at a desk, a job opened by an operator).
-- @param key string|nil
-- @param again boolean|nil
function askState(key, again)
	if key == nil or (key == askedKey and again ~= true) then return end
	local sent, reason = TriggerServerEvent(M.Event.DETAIL, key)
	if not sent then
		if key == askedKey then askedKey = nil end
		Open77.log.warn(('[jobs] the verdict for %s could not be asked for: %s')
			:format(tostring(key), tostring(reason)))
		return
	end
	askedKey = key
end

-- One pass: where the player is, which board they are on, and what is drawn.
local function scan()
	local x, y = playerXY()
	if x == nil then
		nearest = nil
		syncPrompt()
		return
	end
	nearest = Access.Nearest(boards, x, y)
	-- Walking up to a board is what makes its verdict needed, and the poll is
	-- fifteen seconds away: the ask goes out here so the strip row and the list
	-- are built from the server's answer rather than from the board's kind alone.
	if nearest ~= nil then askState(nearest.key) end
	syncPrompt()
	reconcile(x, y)
end

-- ── the capture round-trip ──────────────────────────────────────────────────

-- A command on the server cannot know a facing, so it asks this client for one:
-- the answer carries the position's heading and nothing else this half decides.
local function answerCapture(kind, job, key, label)
	local yaw = playerYaw()
	local accepted, reason = TriggerServerEvent(M.Event.CAPTURED, kind, job, key, label, yaw)
	if not accepted then
		Open77.log.warn(('[jobs] the capture of %s was not sent: %s'):format(tostring(key),
			tostring(reason)))
		return
	end
	-- Said out loud because the other end of this round trip is invisible from
	-- here: the server's own line says the request went out, and this one says it
	-- came back with a facing.
	Open77.log.info(('[jobs] answered the capture of %s as a %s board for %s yaw=%s'):format(
		tostring(key), tostring(kind), tostring(job), tostring(yaw)))
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author XEROX710
function Runtime.Init()
	boards, states, markers, rosters = {}, {}, {}, {}
	nearest, shown, keyRegistered = nil, false, false
	askedKey, pendingOpen = nil, nil
	handle, stack = nil, {}
	reportedMarkers, reportedStrip, reportedMenu = false, false, false
	reportedDraw = nil
	reportedReceived = nil
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the five server events.
-- @author XEROX710
function Runtime.Start()
	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Open, 'key')
				if not ran then
					Open77.log.error(('[jobs] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Reading only the second logged a working mapping as
		-- refused.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[jobs] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT),
					tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	-- The strip redraws a rebound key itself; this only re-reads whether the row
	-- should be up at all.
	AddEventHandler(M.KEYBINDS_CHANGED, function()
		if shown and keyLabel() == nil then shown = false end
		syncPrompt()
	end)

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.boards or nil
		if type(listed) ~= 'table' then return end

		-- A MARKER, and nothing else: what the server thinks this player may DO at
		-- a board rides its own event, for the one they are standing on. A row
		-- carrying a verdict was nine levels deep and several hundred values --
		-- past the host's decode window, which drops the whole payload without a
		-- word and left every board unfindable in game.
		local accepted = {}
		for index = 1, #listed do
			local row = listed[index]
			local board, why = Access.FromWire(row)
			if board == nil then
				Open77.log.warn('[jobs] a board was refused: ' .. tostring(why))
			else
				accepted[board.key] = board
			end
		end
		-- Verdicts are kept for the boards that are still here, and dropped with
		-- the board itself: a verdict left behind its board is a menu for a marker
		-- that is gone.
		for key in pairs(states) do
			if accepted[key] == nil then states[key] = nil end
		end
		boards = accepted
		if #listed ~= reportedReceived then
			reportedReceived = #listed
			Open77.log.info(('[jobs] %d board(s) received'):format(#listed))
		end

		-- A board the player is standing on that has gone takes an open list
		-- down with it: the list is that board's, and it is not there any more.
		if nearest ~= nil and boards[nearest.key] == nil and handle ~= nil then takeDown() end
		-- The verdict of the board they are standing on is asked for again on every
		-- list: it is the half that changes -- a rank granted at a desk, a job
		-- opened by an operator -- and a client holding yesterday's copy would draw
		-- a row the server refuses.
		if nearest ~= nil then askState(nearest.key, true) end
		-- A full pass, not just the markers: a list that arrives while the player
		-- is standing on a board must put its row up now rather than wait for the
		-- next scan.
		scan()
		-- An open list is redrawn against the new payload: a rank that moved, a
		-- job that stopped being offered or a roster that changed must not stay
		-- on screen as it was.
		if handle ~= nil then draw(true) end
	end)

	RegisterNetEvent(M.Event.STATE, function(key, state)
		if type(key) ~= 'string' or type(state) ~= 'table' then return end
		-- A verdict for a board that is not here is a race with its removal, and
		-- keeping it would draw a menu for a marker that is gone.
		if boards[key] == nil then return end
		states[key] = state
		if not reportedState then
			reportedState = true
			Open77.log.info(('[jobs] the verdict for %s arrived: %d value(s) of the platform\'s window')
				:format(tostring(key), select(1, Access.Cost(key, state))))
		end
		-- The strip row and the open list are both made of it, so both are brought
		-- in line the moment it lands -- and a press that arrived before it opens
		-- the list it was waiting for rather than an empty one.
		syncPrompt()
		if pendingOpen == key then
			pendingOpen = nil
			if not draw() then
				say('error', locale('jobs.notOpen'))
			end
		elseif handle ~= nil then
			draw(true)
		end
	end)

	RegisterNetEvent(M.Event.ROSTER, function(job, members, top)
		if type(job) ~= 'string' or type(members) ~= 'table' then return end
		rosters[job] = { members = members, top = tonumber(top) or 0 }
		if handle ~= nil then draw(true) end
	end)

	RegisterNetEvent(M.Event.ANSWER, function(ok, failure, entry, value)
		if ok ~= true then
			local message = locale(tostring(failure or 'jobs.refused'))
			publish({ ok = false, error = tostring(failure or 'jobs.refused'), entry = entry,
				source = 'server' })
			say('error', message)
			return
		end
		-- Said and not toasted: the server raises its own localized line for the
		-- outcome (`OPX.NotifyLocale`), and a second one here would double every
		-- answer. What this adds is the verdict on the local bus, which the menu
		-- and any job resource can hear without asking.
		publish({ ok = true, entry = entry, value = value, source = 'server' })
	end)

	RegisterNetEvent(M.Event.CAPTURE, function(kind, job, key, label)
		answerCapture(kind, job, key, label)
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[jobs] the board list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('jobs:ask', Access.PollMs() > 0 and Access.PollMs() or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.ScanMs() <= 0 then
		Open77.log.error('[jobs] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('jobs:scan', Access.ScanMs(), scan)
	-- One pass now, so a board already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, closes the list, takes the markers down and hands the
--- strip back.
-- @author XEROX710
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	takeDown()
	clearMarkers()
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
