--- The world announcement, drawn on this client's own overlay.
-- @author XEROX710
--
-- WHY THIS MOVED OFF `OPX.Notify`. That is the platform's `open77_notifications`
-- package and it draws a good banner, but it is a surface this runtime does not
-- own -- so it could be told what to say and for how long, and never when to
-- wait. The message here is wrapped in two clips, one that runs BEFORE it appears
-- and one after it has gone, and holding a toast back until a clip has finished
-- is only possible on the page that owns that toast's clock.
--
-- THE SERVER SENDS A SENTENCE AND A DURATION. Nothing about the presentation
-- crosses the wire: the two clips are named by each RECEIVING client's own
-- config, so a client that has them plays them, a client that turned one off by
-- naming `''` does not, and neither case can make an announcement fail to arrive.
--
-- ONE TOAST ID, so a second announcement replaces the one still on screen rather
-- than stacking under it. Two announcements in a row are one message, the later.

local M = OPX.Modules.Get('admin')

M.Announce = {}
local Announce = M.Announce

-- The toast every announcement shares. Fixed, so `OPX.Toast.Show` replaces.
local TOAST_ID = 'opx.admin.announce'

-- `warning` rather than `info`, which is what this announcement carried when it
-- went through the platform's notification package. An announcement arriving in
-- the same shape as a "saved" toast is an announcement players learn to ignore.
local KIND = 'warning'

-- Draws one announcement. The payload has crossed the wire, so every field is
-- checked: this handler is reachable by anything that can raise the event.
local function onAnnounce(payload)
	if type(payload) ~= 'table' then return end

	local text = payload.text
	if type(text) ~= 'string' or text == '' then return end

	-- A lifetime that is not a finite number is left to the runtime's own
	-- default rather than refused: the sentence is the part that matters.
	local durationMs = tonumber(payload.durationMs)
	if durationMs == nil or durationMs ~= durationMs or durationMs < 0 then durationMs = nil end

	local raised, why = OPX.Toast.Show({
		id = TOAST_ID,
		kind = KIND,
		title = locale('admin.announce.title'),
		message = text,
		durationMs = durationMs,
		-- Read at the moment of use, and validated by the runtime rather than
		-- here: `core/client/notify.lua` is the one place that decides what a
		-- toast may carry, and it drops a clip name that is not a bare file name
		-- while still drawing the message.
		stinger = M.Section('ANNOUNCE').STINGER,
	})

	if raised == nil then
		Open77.log.warn(('[admin] an announcement was not drawn: %s'):format(tostring(why)))
	end
end

--- Wires the announcement channel.
-- @author XEROX710
function Announce.Start()
	RegisterNetEvent(M.Event.ANNOUNCE, onAnnounce)
end
