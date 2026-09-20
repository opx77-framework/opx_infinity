--- `OPX.Note`: the one line a client can put where the OPERATOR will read it.
-- @author dop42
--
-- `Open77.log` on a client writes to a file on the PLAYER's machine, in a folder
-- they have to be talked into finding, on a PC that is not the one the server is
-- run from. So from the journal a client module that failed and a client module
-- that was never written look identical, and both look like "it does not work"
-- from the player's side. That is not a hypothetical: three diagnoses of the
-- fitting room hanging on a loading line were argued in one day from the absence
-- of lines that were never going to be in the journal at all.
--
-- The relay was then invented TWICE, independently -- `modules/diagnostics` for a
-- view that threw, `modules/appearance` for a clothing record that would not read
-- back -- which is the usual sign that a thing belongs one level down. This is
-- that level: one event, one bound, one counter, instead of two of each competing
-- for the same journal.
--
-- IT IS NOT IN `opx_lib`, and the reason is the half that is not in this file.
-- Everything worth having here is on the server -- the budget, the rate window,
-- the audit truncation, the refusal of a payload a client chose -- and the
-- library has no server half and cannot have one, because the dedicated-server
-- sandbox has no `require`. A library version would contribute a function
-- signature and leave every caller to write the part that matters.
--
-- IT COSTS A NET EVENT PER CALL. It is for decisions and failures -- the room is
-- owed, the clothes went on, the gate never opened -- and never for a tick. The
-- 216 `Open77.log` calls in this runtime are mostly tick-level detail that SHOULD
-- stay on the player's machine; converting them wholesale would flood the journal
-- and lose the one property this has, which is that a `[note]` line is worth
-- reading. `Note`, not `Log`, for the same reason.

-- Client to server, and the only wire this file owns. `runtime` is what core
-- calls itself on the net channel, as in `opx:net:runtime:notify`.
local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')

-- Longest note that crosses, in characters. The server cleans and cuts to the
-- same figure and refuses anything grossly past it, so cutting here costs a
-- talkative module nothing and saves a byte count on the wire.
local MAX_TEXT = 400

-- Longest module name that crosses. A module id in this runtime is a short
-- lowercase word; the server refuses anything that is not.
local MAX_MODULE = 32

-- Notes one client puts on the wire per session. The LAST of them is spent
-- saying that the budget is spent: a line that stopped arriving and a module
-- that stopped deciding look identical from the journal, which is the exact
-- confusion this whole file exists to end -- reproducing it inside its own fix
-- would be absurd.
local BUDGET = 60

local sent = 0

--- The module id a note is filed under, or a placeholder.
--- Forgiving on purpose, and only in this direction: a caller who passed the
--- wrong thing still gets their evidence into the journal, where the server's own
--- pattern is what decides whether the id is one it will print.
local function idOf(module)
	if type(module) ~= 'string' or module == '' then return 'unnamed' end
	return module:sub(1, MAX_MODULE)
end

--- Everything `OPX.Note` does, so that the whole of it sits under one `pcall`.
local function relay(module, text)
	if type(text) ~= 'string' or text == '' then return false end

	module = idOf(module)
	text = OPX.Text.Clean(text, MAX_TEXT, '...') or ''
	if text == '' then return false end

	-- The local copy is kept even once the budget is gone: when somebody DOES
	-- have the player's machine, the client log is still the complete trail, and
	-- it is the journal that has the hole.
	Open77.log.info(('[note] %s: %s'):format(module, text))

	if sent >= BUDGET then return false end
	sent = sent + 1

	if sent == BUDGET then
		-- The reserved slot. `runtime` rather than the caller's id, because this
		-- line is about the door and not about what the caller was saying.
		TriggerServerEvent(NOTE, 'runtime',
			('the client note budget of %d is spent; further notes this session stay on the ' ..
				'player\'s machine'):format(BUDGET))
		return false
	end

	TriggerServerEvent(NOTE, module, text)
	return true
end

--- Says one thing to the OPERATOR, in the SERVER's journal, not only here.
-- @author dop42
--
-- EVIDENCE, NEVER AUTHORITY. The text is chosen entirely by a client and reaches
-- nothing but a log line; no decision anywhere may read it back. See the server
-- half for the end of that argument, which is the end that can be attacked.
--
-- Safe from anywhere and at any time, including before the session is up and
-- before the modules have run: a diagnostic that can break the thing it is
-- diagnosing is worse than no diagnostic at all, so the whole body is under a
-- `pcall` and every failure is silent.
--
-- ONE NET EVENT PER CALL, and sixty per session. Decisions and failures only.
-- @param module string a module id, for the journal line
-- @param text string
-- @return boolean whether the operator will see this one
function OPX.Note(module, text)
	local ok, crossed = pcall(relay, module, text)
	return ok and crossed == true
end
