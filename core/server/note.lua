--- The far end of `OPX.Note`: one bounded door from every client into the journal.
-- @author dop42
--
-- `core/client/note.lua` says why this exists. This file is the half that makes
-- it worth having, and the half that can be attacked: the event is reachable by
-- any client that can raise an event at all, the payload is chosen entirely by
-- that client, and the destination is a log line an operator will later read as
-- if it were a fact about the server.
--
-- So, in order:
--
--   EVIDENCE, NEVER AUTHORITY. Nothing below this handler reads a note back.
--   There is no store, no state bag, no return path and no branch anywhere in
--   this runtime that a note can reach. It is a line in a journal and nothing
--   else, and any future caller tempted to key a decision off one is looking at
--   attacker-controlled text.
--
--   A NEWLINE FORGES A LINE. `pure/string.lua` in `opx_lib` makes the argument at
--   length: text carrying "\n[2026-01-01] [info] player was banned" reaching a
--   format string writes two lines, and the second is indistinguishable from one
--   the runtime wrote. `OPX.Audit.Safe` replaces every control character with a
--   space and cuts between characters rather than between bytes, so a multi-byte
--   character cannot be split into invalid UTF-8 either. The CLIENT cutting first
--   is a courtesy; this is the enforcement.
--
--   TWO CEILINGS, BECAUSE THEY ARE TWO ATTACKS. The window stops a burst -- a
--   client looping on the event costs a comparison and nothing else. The session
--   budget stops the slow drip that would otherwise fill a night's journal one
--   line a minute and stay under any window.
--
-- The budget running out is ANNOUNCED. A door that closed quietly would put this
-- runtime back exactly where it started: an operator reading silence where there
-- was a decision, which is the fault the whole feature was written to end.

local NOTE = OPX.Event(OPX.Channel.NET, 'runtime', 'note')

-- Characters of a note that reach the journal, matched to the client's own cut.
local MAX_TEXT = 400

-- Bytes one note may arrive as. Well above `MAX_TEXT` characters at four bytes
-- each, so an honest note in any script fits; a payload past it is REFUSED whole
-- rather than truncated, because cleaning a megabyte a client sent on purpose is
-- the work the attacker wanted done.
local MAX_BYTES = 2048

-- Module ids this door prints. A module id in this runtime is a short lowercase
-- word, so anything else is either a mistake or decoration meant for whoever
-- reads the journal -- and the journal is exactly where decoration must not land.
local MAX_MODULE = 32
local MODULE_PATTERN = '^[%l%d][%l%d_%-%.]*$'

-- Notes one player may put in the journal per session, and per window.
local BUDGET = 60
local PER_WINDOW = 12
local WINDOW_MS = 10000

-- Per player: how many crossed, how many were dropped, whether the budget has
-- already announced itself, and the current window.
local seen = {}

--- The record for one player, created on first sight.
local function recordFor(player)
	local record = seen[player]
	if record == nil then
		record = { taken = 0, dropped = 0, announced = false, startedAt = 0, inWindow = 0 }
		seen[player] = record
	end
	return record
end

--- Whether this note falls inside the player's allowance for the current window.
local function withinWindow(record, at)
	if at - record.startedAt >= WINDOW_MS then
		record.startedAt = at
		record.inWindow = 0
	end
	if record.inWindow >= PER_WINDOW then return false end
	record.inWindow = record.inWindow + 1
	return true
end

--- Writes one client note to the journal, having refused everything it should.
--- The `source` global is the only part of this a client does not control.
local function onNote(module, text)
	local player = tonumber(source) or 0
	if player <= 0 then return end

	if type(module) ~= 'string' or type(text) ~= 'string' then return end
	if #module > MAX_MODULE or not module:match(MODULE_PATTERN) then return end
	if text == '' or #text > MAX_BYTES then return end

	local record = recordFor(player)
	if not withinWindow(record, OPX.Now()) then
		record.dropped = record.dropped + 1
		return
	end

	if record.taken >= BUDGET then
		record.dropped = record.dropped + 1
		if not record.announced then
			record.announced = true
			Open77.log.warn(('[note] player %d has spent their budget of %d notes; further ' ..
				'notes from them are dropped for this session'):format(player, BUDGET))
		end
		return
	end
	record.taken = record.taken + 1

	-- Through `Safe` and only then into a format string: the text came off a wire
	-- and both of its hazards -- a control character and a length -- are the
	-- client's choice, not ours.
	Open77.log.info(('[note] %s from player %d: %s')
		:format(module, player, OPX.Audit.Safe(text, MAX_TEXT)))
end

--- Reports what a departing player lost, and forgets them.
--- The announcement above says the budget went; this says how much went with it,
--- which is the difference between a trail with a known hole in it and a trail
--- nobody can size. It is written only when something really was dropped, so the
--- ordinary departure costs no line at all.
local function forget(playerId)
	local player = tonumber(playerId) or 0
	local record = seen[player]
	if record == nil then return end
	if record.dropped > 0 then
		Open77.log.warn(('[note] player %d: %d further notes suppressed')
			:format(player, record.dropped))
	end
	seen[player] = nil
end

RegisterNetEvent(NOTE, onNote)

-- A player id is recycled, and a spent budget left behind would silence the next
-- holder of the slot before they had said anything.
AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)
