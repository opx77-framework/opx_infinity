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
--
-- ONLY A KNOCK OPENS THE TREE. The server answers three things with a frame --
-- the knock, a spend, and a re-ask after an admin moved the ledger -- and only
-- the first may put a closed panel up. A spend answered after the player
-- stowed, or an admin's refresh racing a stow, lands on a panel that is down
-- and is dropped: a tree that re-opened itself would be a tree the player
-- cannot get rid of.
--
-- ONE PRESS, ONE CLOSE. The tree is modal and holds the keyboard, so on this
-- platform the key mapping is inert while it is up and the PAGE catches its own
-- stow key and asks to close; a build whose mapping fires anyway sends a
-- second close for the same press. Close is idempotent, and for a moment after
-- a close the key cannot open again -- the press that closed the tree never
-- re-opens it.

local M = OPX.Modules.Get('skills')

--- Whether the tree is up, and the frame it is up on.
local open = false
local frame = nil

--- Whether a knock is out: the one answer allowed to open a closed panel.
local knocking = false

--- When the tree last closed, so the same press cannot open it again.
local closedAtMs = nil

--- How long after a close the key cannot re-open the tree: one press, in any
--- order the page and the mapping report it.
local REOPEN_GUARD_MS = 400

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

--- Closes the tree. Idempotent: a stow asked by the page's button, by Escape,
-- by the stow key the page caught and by a mapping that fired anyway is ONE
-- close, whichever lands first.
-- @param why string|nil for the log only
function M.Skill.Close(why)
	knocking = false
	if not open then return end
	open = false
	frame = nil
	closedAtMs = OPX.Now()
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
	-- THE PRESS THAT CLOSED IT: the page caught the key and closed the tree a
	-- moment ago, and this is the mapping reporting the same press.
	if closedAtMs ~= nil and OPX.Now() - closedAtMs < REOPEN_GUARD_MS then return end
	if captured() then
		OPX.Toast.Locale('skills.menuOpen', nil, 'error')
		return
	end
	knocking = true
	TriggerServerEvent(M.Event.ASK)
end

--- Whether the tree is up. For a test, and for whatever asks next.
-- @return boolean
function M.Skill.IsOpen()
	return open
end

--- Takes the page's intents: the one spend, and the stow. The spend names a
-- node and nothing else -- what it costs and whether it is reachable are the
-- server's to say.
-- @param action string `spend` or `close`
-- @param payload table|nil
function M.Skill.FromView(action, payload)
	if action == 'spend' then
		if not open then return end
		local node = type(payload) == 'table' and tostring(payload.node or '') or ''
		if node == '' then return end
		TriggerServerEvent(M.Event.SPEND, node)
	elseif action == 'close' then
		M.Skill.Close('view')
	end
end

--- Runs the preload's `develop` export on THIS machine -- the base game's own
--- Level, Street Cred, attributes, skills, perk and relic points, set to their
--- tops. Nothing else can reach those numbers: they are the engine's, and the
--- preload is what speaks to it. Answers ok and, when not, why -- the export's
--- own refusal (`invalid_code`, `boosting`, `no_timescale_on_this_build`) or
--- the reason it could not be asked at all (the resource not running, a build
--- with no synchronous exports).
-- @return boolean
-- @return string|nil
function M.Skill.Develop()
	local settings = M.Skill.DevelopSettings()
	if settings == nil then return false, 'off' end
	local exports = Open77 and Open77.exports
	if type(exports) ~= 'table' or type(exports.callSync) ~= 'function' then
		return false, 'no_sync_exports'
	end
	local ran, ok, why = pcall(exports.callSync, settings.RESOURCE, settings.EXPORT, settings.CODE)
	if not ran then return false, tostring(ok) end
	if ok == true then return true end
	return false, why ~= nil and tostring(why) or (ok == nil and 'no_answer' or 'refused')
end

--- Declares the tree's key and wires the two upstream handlers' seam.
-- The mapping's name is translated at registration and its id is stable,
-- because a player's rebind is stored under it. Two answer shapes are
-- documented for `RegisterKeyMapping` -- the effective key, or `true, key` --
-- and reading only the second logged a working mapping as refused (the
-- scanner's own lesson).
function M.Start()
	local declared = M.Skill.KeySettings()
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
		-- ONLY A KNOCK OPENS THE TREE (the header): an answer to a spend or a
		-- refresh that lands after the stow is for a panel that is gone.
		if not open and not knocking then return end
		knocking = false
		frame = payload
		local was = open
		open = true
		show({
			kind = 'frame',
			frame = payload,
			key = bound or M.Skill.KeySettings().DEFAULT,
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

	-- Somebody else moved the ledger: the sentence, in this player's language,
	-- and a re-ask ONLY when the tree is up -- a closed tree stays closed.
	RegisterNetEvent(M.Event.REFRESH, function(notice)
		if type(notice) == 'table' and type(notice.key) == 'string' and notice.key ~= '' then
			OPX.Toast.Locale(notice.key, type(notice.args) == 'table' and notice.args or nil, 'success')
		end
		if open then TriggerServerEvent(M.Event.ASK) end
	end)

	-- The base game's own levels, asked of this machine by an admin's `max`.
	-- The player is told either way, and the server is told what happened.
	RegisterNetEvent(M.Event.DEVELOP, function(nonce)
		local ok, why = M.Skill.Develop()
		if ok then
			OPX.Toast.Locale('skills.develop.done', nil, 'success')
		else
			OPX.Toast.Locale('skills.develop.refused', { why = tostring(why or 'refused') }, 'error')
		end
		TriggerServerEvent(M.Event.DEVELOPED, nonce, ok == true, why)
	end)

	M.SkillView.Start()
end

--- Takes the tree down. The next session knocks again from scratch.
function M.Stop()
	M.Skill.Close('stop')
	M.SkillView.Stop()
	bound = nil
	knocking = false
	closedAtMs = nil
end
