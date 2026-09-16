--- The validated view of config/animations.lua both halves read.
-- @author dop42
--
-- Every value either half computes or looks up is resolved here, once, at load
-- on each side, so that a typo is a warning at boot and a fallback rather than a
-- raise in the middle of a request. The defaults are written once, in these
-- calls. Switches that are true by default read `~= false` on purpose: a
-- misspelled flag keeps the default. `RESTRICTED` reads `== true` instead, in
-- server/commands.lua: those commands act on their caller alone, so a misspelled
-- flag leaves them open.
--
-- This runs after shared/catalogue.lua, because DISABLED is checked against it.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common

-- The operator table, or an empty one.
local Config = type(M.Settings) == 'table' and M.Settings or {}

M.Opt = {}
local Opt = M.Opt

--- Everything wrong with config/animations.lua, in English, for the boot log.
M.Problems = {}

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

-- Answers a configured whole number in range, or the fallback.
local function bounded(key, value, low, high, fallback)
	local parsed = Common.Integer(value, low, high)
	if parsed == nil then
		problem(('%s must be a whole number in %d..%d; using %d'):format(key, low, high, fallback))
		return fallback
	end
	return parsed
end

local PRESENTERS = { auto = true, always = true, never = true }
Opt.PRESENTER = Config.PRESENTER
if not PRESENTERS[Opt.PRESENTER] then
	problem('PRESENTER must be "auto", "always" or "never"; using "auto"')
	Opt.PRESENTER = 'auto'
end

Opt.NOTIFY = Config.NOTIFY ~= false
Opt.PROMPTS = Config.PROMPTS ~= false
Opt.TOAST_MS = bounded('TOAST_MS', Config.TOAST_MS, 750, 120000, 4000)

Opt.LOOP_BY_DEFAULT = Config.LOOP_BY_DEFAULT ~= false
Opt.MAX_DURATION_MS = bounded('MAX_DURATION_MS', Config.MAX_DURATION_MS,
	M.MIN_DURATION_MS, M.SERVICE_MAX_MS, M.SERVICE_MAX_MS)
Opt.ONE_SHOT_MS = bounded('ONE_SHOT_MS', Config.ONE_SHOT_MS, M.MIN_DURATION_MS,
	Opt.MAX_DURATION_MS, math.min(10000, Opt.MAX_DURATION_MS))

local rate = type(Config.RATE_LIMIT) == 'table' and Config.RATE_LIMIT or {}
if type(Config.RATE_LIMIT) ~= 'table' then problem('RATE_LIMIT must be a table') end
Opt.WINDOW_MS = bounded('RATE_LIMIT.WINDOW_MS', rate.WINDOW_MS, 250, 600000, 10000)
Opt.REQUESTS = bounded('RATE_LIMIT.REQUESTS', rate.REQUESTS, 1, 1000, 6)

local picker = type(Config.PICKER) == 'table' and Config.PICKER or {}
Opt.CLOSE_ON_SELECT = picker.CLOSE_ON_SELECT ~= false
Opt.SHOW_VARIANT_WORDS = picker.SHOW_VARIANT_WORDS ~= false

-- Answers a configured default key, false, or the fallback.
local function keyName(key, value, fallback)
	if value == false then return false end
	if value == nil then return fallback end
	if type(value) == 'string' and #value > 0 and #value <= 32 and not value:find('[%s%c]') then
		return value
	end
	problem(('%s must be a key name or false; using %q'):format(key, fallback))
	return fallback
end

local keys = type(Config.KEYS) == 'table' and Config.KEYS or {}
if Config.KEYS ~= nil and type(Config.KEYS) ~= 'table' then
	problem('KEYS must be a table; using the default keys')
end
Opt.KEY_PICKER = keyName('KEYS.PICKER', keys.PICKER, 'F3')
Opt.KEY_STOP = keyName('KEYS.STOP', keys.STOP, 'X')
-- Two identical keys keep the picker's alone; the stop key is not registered.
if Opt.KEY_PICKER and Opt.KEY_PICKER == Opt.KEY_STOP then
	problem(('KEYS.PICKER and KEYS.STOP are both %q; the stop key is not registered'):format(
		Opt.KEY_STOP))
	Opt.KEY_STOP = false
end

--- Catalogue names the operator switched off.
Opt.DISABLED = {}
if Config.DISABLED ~= nil and type(Config.DISABLED) ~= 'table' then
	problem('DISABLED must be a list of catalogue names')
elseif type(Config.DISABLED) == 'table' then
	for _, name in pairs(Config.DISABLED) do
		local entry = Catalogue.Entry(name)
		if entry == nil then
			problem(('DISABLED names %q, which is not in the catalogue'):format(tostring(name)))
		else
			Opt.DISABLED[entry.name] = true
		end
	end
end

--- The raw command table server/commands.lua registers from.
Opt.COMMANDS = type(Config.COMMANDS) == 'table' and Config.COMMANDS or {}
if type(Config.COMMANDS) ~= 'table' then problem('COMMANDS must be a table; no command exists') end

--- Answers the first configured command a name is typed after.
-- @author dop42
-- @return string|nil
function Opt.PlayCommand()
	for _, key in ipairs({ 'EMOTE', 'ANIM' }) do
		local entry = Opt.COMMANDS[key]
		local name = type(entry) == 'table' and entry.NAME or nil
		if type(name) == 'string' and name ~= '' then return name end
	end
	return nil
end

--- Answers the name the LIST command is registered under.
-- @author dop42
-- @return string|nil
function Opt.ListCommand()
	local entry = Opt.COMMANDS.LIST
	local name = type(entry) == 'table' and entry.NAME or nil
	if type(name) == 'string' and name ~= '' then return name end
	return nil
end
