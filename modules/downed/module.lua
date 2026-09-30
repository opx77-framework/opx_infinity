--- Death and revive: who is down, and the two ways back up.
-- @author dop42
--
-- The server decides who is down. A player is down from the moment their life
-- phase is `dead`; a placement -- a kill and a respawn in one tick, the way a
-- character is moved -- goes straight to `respawnpending` and never opens the
-- screen. Every player's life state is read again each second, so a death that
-- happened while this module was stopped is caught, and a revive done by
-- anything at all closes it.
--
-- Nothing else in the runtime respawns a dead player: the platform leaves a body
-- dead until something revives or respawns it.
--
-- A player who is down gets one full-screen view with two choices -- wait for
-- help, which broadcasts a distress signal, or give up, which unlocks after a
-- delay and wakes them at the nearest medical center. Every rule behind give up
-- is checked on the server and never on the view.
--
-- The view itself is not here. The client half owns the state machine and hands
-- it to whatever draws it, over the seam marked in `client/main.lua`.

local M = OPX.Modules.Declare{
	id = 'downed',
	side = 'both',
	fatal = false,
	-- Every stored row is keyed on the citizen id, and only the character module
	-- knows which character a player has loaded.
	requires = { 'character' },
}

-- ── the Trauma Team ─────────────────────────────────────────────────────────
--
-- A distress signal pages the on-duty medics, and a medic standing over the
-- body treats it: `server/trauma.lua` decides every step, `client/trauma.lua`
-- draws the page, the row and the bar. See `TRAUMA` in `config/downed.lua`.

local NET = OPX.Channel.NET

M.TraumaEvent = {
	-- Server to a medic: somebody is down and asked for help.
	-- `{ patient, name, x, y, z, seconds, sprite }`.
	PAGE = OPX.Event(NET, 'downed', 'page'),
	-- Server to a medic: that page is over (the patient is up, or gone).
	UNPAGE = OPX.Event(NET, 'downed', 'unpage'),
	-- Server to a medic: the downed body within reach now, `{ patient, name }`,
	-- or `{}` when there is none. Sent only when it changes.
	NEAR = OPX.Event(NET, 'downed', 'near'),
	-- Medic to server: treat the body the row named, `{ patient }`.
	TREAT = OPX.Event(NET, 'downed', 'treat'),
	-- Server to a medic: the treatment is running, `{ patient, name, durationMs }`.
	RUN = OPX.Event(NET, 'downed', 'treatrun'),
	-- Medic to server: the bar ran out.
	DONE = OPX.Event(NET, 'downed', 'treatdone'),
	-- Medic to server: the bar was cut short, with the reason.
	ABORT = OPX.Event(NET, 'downed', 'treatabort'),
	-- Server to a medic: what came of it, `{ ok, code, name, reward }`.
	ANSWER = OPX.Event(NET, 'downed', 'treatanswer'),
	-- Server to a downed player: one line for their screen, `{ key, args }`.
	NOTICE = OPX.Event(NET, 'downed', 'notice'),
}

-- Every refusal a medic can be told, by the code `server/trauma.lua` returns. A
-- code outside this set reads as the generic sentence, never as a raw key.
M.TRAUMA_REFUSALS = {
	off = true, no_patient = true, self = true, not_medic = true, down = true, busy = true,
	cooldown = true, not_down = true, taken = true, no_position = true, too_far = true,
	too_soon = true, nothing_running = true, revive_refused = true, patient_up = true,
	medic_gone = true, cancelled = true, interrupted = true, stopped = true, no_bar = true,
}

--- The catalogue key for a treatment refusal code.
-- @param code any
-- @return string
function M.TraumaRefusalKey(code)
	if M.TRAUMA_REFUSALS[tostring(code)] then return 'medic.treat.refused.' .. tostring(code) end
	return 'medic.treat.refused.failed'
end

--- A number from config, finite and inside a band, or the fallback.
local function number(value, low, high, fallback)
	local read = tonumber(value)
	if read == nil or read ~= read or read < low or read > high then return fallback end
	return read
end

--- The Trauma Team settings, each inside a band. A missing or malformed block
--- is the defaults; `TRAUMA = false` or `enabled = false` is `off`.
-- @return table
function M.TraumaSettings()
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.TRAUMA end
	local block = type(declared) == 'table' and declared or {}
	local page = type(block.PAGE) == 'table' and block.PAGE or {}
	local treat = type(block.TREAT) == 'table' and block.TREAT or {}
	local reward = type(block.REWARD) == 'table' and block.REWARD or {}
	local jobs, listed = {}, false
	for _, name in ipairs(type(block.JOBS) == 'table' and block.JOBS or {}) do
		if type(name) == 'string' and name ~= '' then
			jobs[name] = true
			listed = true
		end
	end
	if not listed and type(block.JOBS) ~= 'table' then jobs.trauma = true end
	local key = type(block.KEY) == 'table' and block.KEY or {}
	return {
		off = declared == false or block.enabled == false,
		jobs = jobs,
		key = {
			id = type(key.ID) == 'string' and key.ID ~= '' and key.ID or 'opx.downed.treat',
			name = type(key.NAME) == 'string' and key.NAME ~= '' and key.NAME or 'medic.key.treat',
			default = key.DEFAULT == false and false
				or (type(key.DEFAULT) == 'string' and key.DEFAULT ~= '' and key.DEFAULT or 'E'),
		},
		round = number(page.ROUND_METRES, 0.0, 100.0, 5.0),
		pinSeconds = math.floor(number(page.PIN_SECONDS, 0, 900, 300)),
		sprite = type(page.PIN_SPRITE) == 'string' and page.PIN_SPRITE ~= '' and page.PIN_SPRITE or 'objective',
		toastMs = math.floor(number(page.TOAST_MS, 0, 60000, 12000)),
		reach = number(treat.REACH_METRES, 1.0, 15.0, 4.0),
		treatMs = math.floor(number(treat.SECONDS, 1, 60, 6) * 1000),
		cooldownMs = math.floor(number(treat.COOLDOWN_MS, 0, 600000, 3000)),
		amount = math.floor(number(reward.AMOUNT, 0, 1000000, 150)),
		account = type(reward.ACCOUNT) == 'string' and reward.ACCOUNT ~= '' and reward.ACCOUNT or 'BANK',
		perPatientMs = math.floor(number(reward.PER_PATIENT_MS, 0, 86400000, 600000)),
	}
end
