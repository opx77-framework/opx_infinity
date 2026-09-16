--- The stop key in the prompt strip while your animation plays.
-- @author dop42
--
-- A looping animation runs until something stops it, and nothing on screen said
-- what. The prompts contract is optional: without it the key still works and the
-- row is simply not drawn, at the cost of one logged line.

local M = OPX.Modules.Get('animations')
local Opt = M.Opt
local Keys = M.Keys

M.Prompt = {}
local Prompt = M.Prompt

-- What the prompts contract records as this module's own: the owner tells two
-- callers apart, the group names this particular strip entry.
local OWNER = 'animations'
local GROUP = 'playing'

-- Mapping id of the stop key the row names. The strip redraws it itself on a
-- rebind, so nothing here listens for one.
local KEY_STOP = 'opx.animations.stop'

-- Whether the row is up, and whether the local player's animation plays.
local shown, wanted = false, false

-- Whether a missing or refusing strip was already logged.
local reported = false

-- Brings the strip in line with the local player's playback. No key to name, no
-- row: a player without a stop key stops by the command.
local function sync()
	if not Opt.PROMPTS then return end
	local want = wanted and Keys.Effective(KEY_STOP) ~= nil
	if want == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		if want and not reported then
			reported = true
			Open77.log.info('[animations] no prompts contract; the stop key is not shown')
		end
		shown = false
		return
	end

	shown = want
	local ran, answer
	if want then
		-- The label is short on purpose: the strip never wraps a line.
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = {
			{ keys = { action = KEY_STOP }, label = locale('animations.prompt.stop') },
		} })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reported then
		reported = true
		Open77.log.warn('[animations] the stop prompt was refused: ' .. failure)
	end
end

--- Takes whether the local player's playback started or ended.
-- @author dop42
-- @param active boolean
function Prompt.Changed(active)
	wanted = active == true
	sync()
end

--- Clears the strip state.
-- @author dop42
function Prompt.Init()
	shown, wanted, reported = false, false, false
end

--- Hands the strip back.
-- @author dop42
function Prompt.Shutdown()
	wanted = false
	sync()
end
