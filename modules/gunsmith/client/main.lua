--- Two rows on the eye per armoury: the bench, and the chest beside it.
-- @author dop42
--
-- THIS HALF POINTS AND NOTHING ELSE. It puts a sphere where the config says the
-- bench is and another where the chest is, and each row does one thing: ask. The
-- bench row asks the crafting module's client half to open its screen, which
-- asks the server, which re-reads the job and re-measures the distance; the
-- chest row sends one event and the server does the same. Nothing here is
-- believed.
--
-- IT DOES NOT DRAW THE GATE, and that is deliberate rather than lazy. It would
-- be easy to read the character's job on this side and grey the row out -- the
-- snapshot is right there -- and it would be wrong twice: the row would lie
-- whenever the snapshot was stale, and hiding an armoury from somebody who is
-- not staff removes the one thing that tells them it exists. A row anybody can
-- press and a refusal in words is a better screen than a row that is not there.

local M = OPX.Modules.Get('gunsmith')

local Access = M.Access

-- What the eye owns, so the rows can be taken down on stop.
local OWNER = 'gunsmith'
local BENCH_ROW = 'gunsmith.bench'
local CHEST_ROW = 'gunsmith.chest'

-- The contracts, resolved at Start.
local target, crafting = nil, nil

-- The armouries this file registered spheres for, in the order the eye was given
-- them: the eye answers with the INDEX it matched, and this list is the only
-- thing that ties that index back to an armoury.
local placed = {}

--- Puts the two rows on every armoury that has a bench.
local function placeRows()
	placed = Access.List()
	if #placed == 0 then return end

	local radius = Access.PROMPT_RADIUS

	local benches, chests, chestAt = {}, {}, {}
	for index = 1, #placed do
		local armoury = placed[index]
		benches[index] = { x = armoury.bench.x, y = armoury.bench.y, z = armoury.bench.z,
			radius = radius }
		-- A CHEST IS OPTIONAL AND ITS SPHERE LIST IS THEREFORE NOT THE BENCH LIST.
		-- `chestAt` maps the chest sphere index back to `placed`, because an
		-- armoury with no chest leaves a hole in one list and not the other -- and
		-- an index read off the wrong list opens the wrong armoury's chest.
		if armoury.chest ~= nil then
			chests[#chests + 1] = { x = armoury.chest.x, y = armoury.chest.y,
				z = armoury.chest.z, radius = radius }
			chestAt[#chests] = index
		end
	end

	local rows = target.RegisterSpheres(OWNER, benches, {
		id = BENCH_ROW,
		label = locale('gunsmith.bench'),
		icon = 'tool',
		distance = radius,
		order = 20,
		onSelect = function(payload)
			local index = tonumber(type(payload) == 'table' and payload.index or nil)
			local armoury = index and placed[index] or nil
			if armoury == nil then return end
			if crafting == nil then
				return OPX.Toast.Locale('gunsmith.unavailable', nil, 'error')
			end
			crafting.Open(M.BENCH_PREFIX .. armoury.key)
		end,
	})
	if not rows.ok then
		Open77.log.warn(('[gunsmith] the bench rows were refused: %s'):format(tostring(rows.error)))
	end

	if #chests == 0 then return end

	rows = target.RegisterSpheres(OWNER, chests, {
		id = CHEST_ROW,
		label = locale('gunsmith.chest'),
		icon = 'box',
		distance = radius,
		order = 21,
		onSelect = function(payload)
			local index = tonumber(type(payload) == 'table' and payload.index or nil)
			local armoury = index and placed[chestAt[index]] or nil
			if armoury == nil then return end
			TriggerServerEvent(M.Event.CHEST, armoury.key)
		end,
	})
	if not rows.ok then
		Open77.log.warn(('[gunsmith] the chest rows were refused: %s'):format(tostring(rows.error)))
	end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	target, crafting, placed = nil, nil, {}
end

--- Puts the rows on the world.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	crafting = OPX.Api.Get('crafting')

	if crafting == nil then
		Open77.log.warn('[gunsmith] no crafting contract: a bench row would open nothing')
	end
	if target == nil then
		Open77.log.warn('[gunsmith] no target contract: the armouries are there and unreachable')
		return
	end

	placeRows()

	RegisterNetEvent(M.Event.REFUSED, function(_, code)
		if type(code) ~= 'string' then return end
		OPX.Toast.Locale('gunsmith.' .. code, nil, 'error')
	end)
end

--- Takes the rows down.
-- @author dop42
function M.Stop()
	if target ~= nil then pcall(target.Clear, OWNER) end
	placed = {}
end
