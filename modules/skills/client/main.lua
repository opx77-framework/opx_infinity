--- The client half: the key, the knock, and the two sentences a player reads.
-- @author XEROX710
--
-- THIS HALF DECIDES NOTHING, exactly as the scanner's does. It holds whether
-- the panel is up and what the server last said, and every number the page
-- draws arrived in a frame from the server. A press is an intent; a spend is an
-- intent; the panel only moves when the answer comes back.
--
-- A GAIN IS NEWS, NOT STATE. The line is toasted when it is a level or a node
-- (the two moments a player should look up for), fed to the panel's strip when
-- the panel is up, and dropped when it is not -- the tree is always the
-- server's to answer for, so nothing here needs a backlog.

local M = OPX.Modules.Get('skills')

--- Whether the tree is up, and the frame it is up on.
local open = false
local frame = nil

--- The player's own binding, as `RegisterKeyMapping` answered it. The page has
-- no keyboard layout to resolve a mapping id with.
local bound = nil

--- Whether another surface holds the keyboard. A key pressed into a menu must
-- do nothing rather than put a tree over somebody else's menu -- the same
-- guard the scanner's key makes, for the same reason.
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
	TriggerEvent(M.Event.SKILL_VIEW, payload)
end

--- The sentence a refusal is read as: `M.Skill.Refusal` maps the server's code
-- to the same words the panel would use, and an unknown code names itself.
-- @param code string|nil
local function toastWhy(code)
	local text = tostring(code or 'failed')
	OPX.Toast.Locale(M.Skill.Refusal[text] or 'skills.failed', { reason = text }, 'error')
end

--- Closes the tree. Idempotent: a stow pressed twice is one close.
-- @param why string|nil for the log only
function M.Skill.Close(why)
	if not open then return end
	open = false
	frame = nil
	M.SkillView.Release()
	show({ kind = 'close', why = tostring(why or 'stowed') })
	Open77.log.info('[skills] tree closed (' .. tostring(why or 'stowed') .. ')')
end

--- Toggles the tree. The open half is a knock the server answers; the stow half
-- is local, because closing needs no verdict.
function M.Skill.Toggle()
	if open then
		M.Skill.Close('key')
		return
	end
	if captured() then
		OPX.Toast.Locale('skills.menuOpen', nil, 'error')
		return
	end
	TriggerServerEvent(M.Event.ASK)
end

--- Takes the page's intents: the one spend, and the stow. The spend names a
-- node and nothing else -- what it costs and whether it is reachable are the
-- server's to say.
-- @param action string `spend` or `close`
-- @param payload table|nil
function M.Skill.FromView(action, payload)
	if action == 'spend' then
		local node = type(payload) == 'table' and tostring(payload.node or '') or ''
		if node == '' then return end
		TriggerServerEvent(M.Event.SPEND, node)
	elseif action == 'close' then
		M.Skill.Close('view')
	end
end

--- Declares the tree's key and wires the two upstream handlers' seam.
-- The mapping's name is translated at registration and its id is stable,
-- because a player's rebind is stored under it. Two answer shapes are
-- documented for `RegisterKeyMapping` -- the effective key, or `true, key` --
-- and reading only the second logged a working mapping as refused (the
-- scanner's own lesson).
function M.Start()
	local declared = M.Skill.KEY
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				local ran, failure = pcall(M.Skill.Toggle)
				if not ran then
					Open77.log.error(('[skills] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[skills] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		else
			bound = effective
		end
	end

	-- The frame is the whole tree, or a refusal said once. A frame that REFUSES
	-- a spend (`payload.refused`) still refreshes the panel -- the tree moved
	-- nowhere and the words say why -- so the toast and the draw both run.
	RegisterNetEvent(M.Event.STATE, function(payload)
		if type(payload) ~= 'table' then return end
		if payload.open ~= true then
			toastWhy(payload.reason)
			M.Skill.Close('refused')
			return
		end
		if payload.refused ~= nil then toastWhy(payload.refused) end
		frame = payload
		local was = open
		open = true
		show({
			kind = 'frame',
			frame = payload,
			key = bound or M.Skill.KEY.DEFAULT,
			fresh = not was,
		})
	end)

	-- News from the ledger. A level or a node is worth looking up for; work
	-- credited is the panel's strip and nobody else's.
	RegisterNetEvent(M.Event.GAIN, function(line)
		if type(line) ~= 'table' then return end
		if open then show({ kind = 'gain', line = line }) end
		if line.key == 'skills.gain.node' then
			OPX.Toast.Locale(line.key, line.args, 'success')
		end
		local leveled = tonumber(line.level) or 0
		if leveled > 0 then
			OPX.Toast.Locale('skills.gain.level',
				{ level = leveled, points = line.points }, 'success')
		end
	end)

	M.SkillView.Start()
end

--- Takes the tree down. The next session knocks again from scratch.
function M.Stop()
	M.Skill.Close('stop')
	M.SkillView.Stop()
	bound = nil
end
