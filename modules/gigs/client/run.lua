--- The run in progress: one row, one mappin, one animation, one claim.
-- @author dop42
--
-- The client knows the leg it is standing at and nothing else. It draws a target
-- row inside a sphere at that point, plays an animation for as long as the leg
-- says, and then asks the server whether that counted. It never decides that it
-- did: the toast a player reads comes back off the wire.
--
-- THE ANIMATION IS NOT THE CLOCK. It is what the action looks like, and the
-- server's floor is what the action costs. Killing the animation early, having no
-- animations module at all, or holding a body that refuses the clip all leave the
-- claim exactly where it was -- the wait is a `Wait` in this file and a stamp in
-- the server's, and neither asks the presenter anything.
--
-- WALKING AWAY CANCELS. The reach is re-read while the action runs, because the
-- alternative is a player who starts a leg, walks off, and is refused by the
-- server at the end of an animation they watched for six seconds.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog

M.Run = {}
local Run = M.Run

local OWNER = M.OWNER

-- The row every leg shares. One id, re-registered as the run moves.
local LEG_ROW = 'gigs.leg'
local ABANDON_ROW = 'gigs.abandon'

-- Milliseconds between two reach checks while an action runs.
local WATCH_MS = 400

-- Metres past the leg's reach the player may drift before the action is dropped.
-- Wider than the row's own reach on purpose: the row decides whether the action
-- may START, and this decides whether it was walked out of.
local DRIFT = 1.5

-- The leg the server last handed out, or nil.
local leg = nil

-- Tokens of the two rows this file owns, and the mappin on the leg.
local legToken, abandonToken, pin = nil, nil, nil

-- Whether an action is running, and the leg it was started for.
local acting, actingFor = false, nil

-- Whether the mappin failed once. Said once, then never tried again: without
-- `ui.vanilla.map` every call refuses, and a refusal per leg is a log nobody
-- reads.
local pinsOff, pinsReported = false, false

-- Whether the player is on the floor, as `downed` last said.
local down = false

-- Calls one function of a contract, answering nil and a code rather than raising.
local function call(name, fn, ...)
	if type(fn) ~= 'function' then return nil, 'not_running' end
	local ran, answer = pcall(fn, ...)
	if not ran then
		Open77.log.error(('[gigs] %s raised: %s'):format(name, tostring(answer)))
		return nil, 'raised'
	end
	if type(answer) ~= 'table' then return nil, 'malformed_answer' end
	if answer.ok ~= true then return nil, tostring(answer.error or 'refused') end
	return answer.value or answer
end

--- The local character's position, or nil.
-- `Open77.character.position()` answers THREE NUMBERS and not a table. Read as a
-- table it answers nil for every field, every leg is out of reach and nothing can
-- ever be worked.
local function position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read then return nil end
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		return nil
	end
	return { x = x, y = y, z = z }
end

-- Whether the player stands within a distance of the current leg.
local function withinLeg(extra)
	if leg == nil then return false end
	local here = position()
	if here == nil then return false end
	local reach = leg.reach + (extra or 0)
	return Catalog.GapSquared(here, leg) <= reach * reach
end

--- Whether the player is on the floor. Without the `downed` contract nobody is.
-- @author dop42
-- @return boolean
function Run.IsDown()
	return down
end

--- Takes what `downed` last said about the local player.
-- @author dop42
-- @param value boolean
function Run.SetDown(value)
	down = value == true
	-- A player who goes down mid-action does not finish it standing up.
	if down and acting then acting, actingFor = false, nil end
end

-- Raises one replaced toast, so a run never stacks a column of them.
local function toast(kind, message, icon)
	if M.Settings.NOTIFY == false or type(message) ~= 'string' or message == '' then return end
	OPX.Toast.Show({
		id = 'opx.gigs.answer',
		kind = kind,
		title = leg ~= nil and leg.title or locale('gigs.title'),
		message = message,
		icon = icon,
		durationMs = 5000,
	})
end

--- Shows a refusal the server sent, or one this file decided alone.
-- @author dop42
-- @param code string
-- @param key string|nil the catalogue key the server chose
-- @param wait integer|nil seconds left on a cooldown
function Run.Refused(code, key, wait)
	local catalogue = type(key) == 'string' and key or Catalog.REFUSAL[code]
	if catalogue == nil or not OPX.Locale.Exists(catalogue) then catalogue = 'gigs.refuse.generic' end
	toast('error', locale(catalogue, { seconds = wait or 0 }))
end

-- Takes the mappin off the map.
local function clearPin()
	if pin == nil then return end
	local blips = Open77.blips
	if type(blips) == 'table' and type(blips.remove) == 'function' then pcall(blips.remove, pin) end
	pin = nil
end

-- Puts a mappin on the leg, when the operator asked for one and the permission
-- is there. A refusal switches mappins off for the session rather than trying
-- again on every leg.
local function drawPin()
	clearPin()
	if M.Settings.BLIPS == false or pinsOff or leg == nil then return end

	local blips = Open77.blips
	if type(blips) ~= 'table' or type(blips.create) ~= 'function' then
		pinsOff = true
		return
	end

	local made, id = pcall(blips.create, {
		position = { x = leg.x, y = leg.y, z = leg.z },
		label = leg.label or leg.title,
		routable = true,
		active = true,
	})
	if made and type(id) == 'string' and id ~= '' then
		pin = id
	else
		pinsOff = true
		if not pinsReported then
			pinsReported = true
			Open77.log.info('[gigs] no mappin was drawn (ui.vanilla.map): the target row is the ' ..
				'only thing marking a leg')
		end
		return
	end

	if M.Settings.WAYPOINT == true and type(blips.setWaypoint) == 'function' then
		pcall(blips.setWaypoint, { x = leg.x, y = leg.y, z = leg.z })
	end
end

-- Takes the leg row off the eye.
local function clearRow()
	local token = legToken
	legToken = nil
	if token == nil then return end
	local target = OPX.Api.Get('target')
	if target ~= nil then call('target.Unregister', target.Unregister, OWNER, token) end
end

-- Whether the leg row may be worked: standing, not already acting, in reach is
-- the eye's own job through the sphere.
local function canWork()
	return leg ~= nil and not acting and not down
end

-- Forward-declared: the row's definition carries this, and it is written below
-- the registration it answers.
local work

-- Puts the leg row on the eye at the leg's point.
local function drawRow()
	clearRow()
	if leg == nil then return end

	local target = OPX.Api.Get('target')
	if target == nil then return end

	local label = leg.kind == 'drop' and locale('gigs.row.drop') or locale('gigs.row.pick')
	if type(leg.label) == 'string' and leg.label ~= '' then
		label = ('%s: %s'):format(label, leg.label)
	end

	local registered, failure = call('target.RegisterSpheres', target.RegisterSpheres, OWNER,
		{ { x = leg.x, y = leg.y, z = leg.z, radius = leg.radius } },
		{
			id = LEG_ROW,
			label = label,
			description = locale('gigs.row.progress', { index = leg.index, total = leg.total }),
			icon = leg.icon,
			distance = leg.reach,
			canInteract = canWork,
			onSelect = work,
			-- Work: the leg is what this player took on.
			order = 40,
		})
	if registered == nil then
		Open77.log.warn('[gigs] the leg row was not registered: ' .. tostring(failure))
		return
	end
	legToken = registered.token
end

-- Plays the leg's animation, when there is one and the module is running. A
-- refusal is not a failure of the leg: the action still takes as long.
local function playAnimation(name, durationMs)
	if type(name) ~= 'string' or name == '' then return end
	local api = OPX.Api.Get('animations')
	if api == nil or type(api.Play) ~= 'function' then return end
	pcall(api.Play, name, { durationMs = durationMs, loop = true, cancelable = true }, OWNER)
end

-- Ends whatever this module started, and only that: the owner is the capability.
local function stopAnimation()
	local api = OPX.Api.Get('animations')
	if api == nil or type(api.Stop) ~= 'function' then return end
	pcall(api.Stop, OWNER)
end

-- Works the current leg: the animation, the wait, the drift watch, the claim.
work = function()
	if not canWork() then return false end
	if not withinLeg(0) then
		Run.Refused('too_far')
		return false
	end

	local working = leg
	acting, actingFor = true, working.run .. ':' .. tostring(working.index)

	local duration = Catalog.Integer(working.actionMs, 100, 60000) or 3000
	playAnimation(working.animation, duration)
	toast('info', locale(working.kind == 'drop' and 'gigs.acting.drop' or 'gigs.acting.pick'),
		working.icon)

	-- One shot, and it ends with the leg. There is no repeating job here: the
	-- scheduler's pass is for work that keeps happening, and this happens once.
	CreateThread(function()
		local ticket = actingFor
		local waited = 0
		while waited < duration do
			local slice = math.min(WATCH_MS, duration - waited)
			Wait(slice)
			waited = waited + slice

			-- Anything that moved on underneath drops the action without a claim:
			-- a new leg, a cancelled run, a body on the floor, a walk away.
			if ticket ~= actingFor or not acting then return end
			if leg == nil or leg.run ~= working.run or leg.index ~= working.index then
				acting, actingFor = false, nil
				stopAnimation()
				return
			end
			if down or not withinLeg(DRIFT) then
				acting, actingFor = false, nil
				stopAnimation()
				Run.Refused('too_far')
				return
			end
		end

		acting, actingFor = false, nil
		stopAnimation()
		TriggerServerEvent(M.Event.WORK, working.run, working.index)
	end)

	return true
end

-- Puts the abandon row on the player's own body while a run is held.
local function drawAbandonRow()
	if M.Settings.ABANDON_ROW == false or abandonToken ~= nil then return end
	local target = OPX.Api.Get('target')
	if target == nil then return end

	local registered, failure = call('target.RegisterSelf', target.RegisterSelf, OWNER, {
		id = ABANDON_ROW,
		label = locale('gigs.row.abandon'),
		icon = 'ban',
		distance = 3.0,
		danger = true,
		canInteract = function() return leg ~= nil end,
		onSelect = function() Run.Abandon() end,
		-- Leaving, which is always under the work it leaves.
		order = 70,
	})
	if registered == nil then
		Open77.log.warn('[gigs] the abandon row was not registered: ' .. tostring(failure))
		return
	end
	abandonToken = registered.token
end

-- Takes the abandon row off the eye.
local function clearAbandonRow()
	local token = abandonToken
	abandonToken = nil
	if token == nil then return end
	local target = OPX.Api.Get('target')
	if target ~= nil then call('target.Unregister', target.Unregister, OWNER, token) end
end

-- Announces the run state on the module's public local bus. Anything that draws
-- a run -- a HUD, another resource -- listens here and never to the wire.
local function announce(verb, payload)
	payload = payload or {}
	payload.verb = verb
	payload.working = leg ~= nil
	TriggerEvent(M.Event.ON_CHANGED, payload)
end

--- Takes the leg the server handed out and draws everything that marks it.
-- @author dop42
-- @param payload table
function Run.Took(payload)
	if type(payload) ~= 'table' then return end
	local index = Catalog.Integer(payload.index, 1, 1000)
	local total = Catalog.Integer(payload.total, 1, 1000)
	local x = Catalog.Number(payload.x, -100000, 100000)
	local y = Catalog.Number(payload.y, -100000, 100000)
	local z = Catalog.Number(payload.z, -100000, 100000)
	if index == nil or total == nil or x == nil or y == nil or z == nil then
		Open77.log.warn('[gigs] a malformed leg was dropped')
		return
	end

	-- Anything in flight belongs to the leg before this one.
	acting, actingFor = false, nil
	stopAnimation()

	leg = {
		run = tostring(payload.run),
		gig = tostring(payload.gig),
		title = Catalog.Text(payload.title, 80) or locale('gigs.title'),
		-- Measured against the set a second time. The eye refuses a ROW whose glyph
		-- it does not know, and a toast refuses the words with it, so a gig whose
		-- ICON drifted would cost this leg the only thing marking it.
		icon = Catalog.ICONS[payload.icon] and payload.icon or 'interact',
		kind = payload.kind == 'drop' and 'drop' or 'pick',
		index = index,
		total = total,
		x = x, y = y, z = z,
		label = Catalog.Text(payload.label, 60),
		actionMs = Catalog.Integer(payload.actionMs, 100, 60000) or 3000,
		animation = Catalog.Text(payload.animation, 64),
		reach = Catalog.Number(payload.reach, 0.5, 12.0) or 2.5,
		radius = Catalog.Number(payload.radius, 0.2, 10.0) or 1.6,
		earned = Catalog.Integer(payload.earned, 0, 100000000) or 0,
	}

	drawRow()
	drawPin()
	drawAbandonRow()

	toast('info', locale(leg.kind == 'drop' and 'gigs.leg.drop' or 'gigs.leg.pick', {
		index = leg.index, total = leg.total, place = leg.label or '',
	}), leg.icon)

	announce('leg', { gig = leg.gig, index = leg.index, total = leg.total, kind = leg.kind })
end

--- Closes a run the server ended, paid or not.
-- @author dop42
-- @param payload table
function Run.Ended(payload)
	if type(payload) ~= 'table' then return end

	local gig = leg ~= nil and leg.gig or tostring(payload.gig)
	local reason = type(payload.reason) == 'string' and payload.reason or 'ended'
	local earned = Catalog.Integer(payload.earned, 0, 100000000) or 0

	leg = nil
	acting, actingFor = false, nil
	stopAnimation()
	clearRow()
	clearPin()
	clearAbandonRow()

	local pay = type(payload.pay) == 'table' and payload.pay or nil
	if reason == 'completed' and pay ~= nil then
		local items = {}
		if type(pay.items) == 'table' then
			for index = 1, #pay.items do
				local row = pay.items[index]
				if type(row) == 'table' and type(row.name) == 'string' then
					items[#items + 1] = ('%dx %s'):format(Catalog.Integer(row.count, 1, 100) or 1, row.name)
				end
			end
		end
		toast('success', locale('gigs.done.paid', {
			total = earned,
			bonus = Catalog.Integer(pay.bonus, 0, 100000000) or 0,
			reputation = Catalog.Integer(pay.reputation, 0, 1000000) or 0,
		}), 'money')
		if #items > 0 then
			Open77.log.debug('[gigs] bonus items: ' .. table.concat(items, ', '))
		end
	elseif reason == 'expired' then
		toast('warning', locale('gigs.done.expired', { total = earned }))
	elseif reason == 'abandoned' then
		toast('warning', locale('gigs.done.abandoned', { total = earned }))
	elseif reason ~= 'stopped' then
		toast('warning', locale('gigs.done.stopped', { total = earned }))
	end

	announce('ended', { gig = gig, reason = reason, earned = earned })
end

--- Asks the server to drop the run this client holds.
-- @author dop42
-- @return boolean whether there was one to drop
function Run.Abandon()
	if leg == nil then
		Run.Refused('not_working')
		return false
	end
	TriggerServerEvent(M.Event.QUIT)
	return true
end

--- Asks the server for a gig. The answer is a leg, or a refusal.
-- @author dop42
-- @param gigId string
-- @return boolean
function Run.Take(gigId)
	if down then
		Run.Refused('player_down')
		return false
	end
	if leg ~= nil then
		Run.Refused('already_working')
		return false
	end
	TriggerServerEvent(M.Event.TAKE, gigId)
	return true
end

--- Whether this client holds a run.
-- @author dop42
-- @return boolean
function Run.Working()
	return leg ~= nil
end

--- What this client is standing at, for the contract. A copy: the caller must
--- not be able to move the leg under the row that draws it.
-- @author dop42
-- @return table|nil
function Run.State()
	if leg == nil then return nil end
	return {
		gig = leg.gig, run = leg.run, kind = leg.kind, index = leg.index, total = leg.total,
		label = leg.label, earned = leg.earned, acting = acting,
	}
end

--- Clears everything this file holds. Called from `Init`.
-- @author dop42
function Run.Init()
	leg, legToken, abandonToken, pin = nil, nil, nil, nil
	acting, actingFor = false, nil
	pinsOff, pinsReported, down = false, false, false
end

--- Takes the row, the mappin and the animation down with the module.
-- @author dop42
function Run.Shutdown()
	leg = nil
	acting, actingFor = false, nil
	stopAnimation()
	clearRow()
	clearPin()
	clearAbandonRow()
end
