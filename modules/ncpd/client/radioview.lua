--- The scanner's view seam: the one file here that knows the other end is a
-- CEF surface (README: the view seam).
-- @author XEROX710
--
-- A TRANSLATOR AND NOTHING ELSE. The state half publishes what the page draws
-- on `M.Event.RADIO_VIEW`; this file turns those into one page channel and
-- turns the page's two intents back into `M.Radio.FromView` calls. It owns no
-- state and makes no decision -- the moment it does either, the state half is
-- no longer the only answer to "is the scanner open".
--
-- ONE CHANNEL OUT, KIND-DISCRIMINATED (`radio:view`), the shape
-- `admin/client/tagsview.lua` draws with; five channels in (`radio:tune`,
-- `radio:talk`, `radio:volume`, `radio:place`, `radio:close`), one per intent,
-- the shape `chat/client/view.lua` takes.

local M = OPX.Modules.Get('ncpd')

local SURFACE = 'interactive'
local CHANNEL = 'radio:view'

--- What this module answers for on `focus:set`, and what it asks for when it
-- does.
--
-- THE KEYBOARD IS NOT HANDED OVER BY ASKING THE PAGE. `focus:set` is a
-- BROADCAST: the page announces that its own stack changed, and every view
-- module on this surface answers for ITS OWN owner by calling
-- `OPX.UI.AcquireFocus`. Nothing else calls it, so an owner no module claims is
-- an owner nobody acquires -- and the game keeps the keyboard.
--
-- `keyboard = false`, like the cursor-mode menus: the scanner is a device
-- panel, not a dialog -- the game keeps the movement keys and the F2 that
-- stows it, and rows are chosen by clicking them.
local FOCUS = {
	['ncpd.radio'] = { keyboard = false, cursor = true },
}

--- The probe, from the page: what the browser actually delivered, logged with
--- whether this surface holds the client's ONE focus slot when it did. The
--- host's virtual pointer can fail before the browser ever sees a press, and
--- another surface can silently take the focus slot -- two failure classes no
--- page-side test can see. This line names the guilty layer.
-- @param payload table|nil
local function slotHeld()
	local surface = OPX.UI.Surface()
	if surface == nil or type(OPX.Surface) ~= 'table' or type(OPX.Surface.HasFocus) ~= 'function' then
		return 'unknown'
	end
	local read, held = pcall(OPX.Surface.HasFocus, surface)
	return read and tostring(held) or 'unknown'
end

local function onProbe(payload)
	if type(payload) ~= 'table' then return end
	local held = slotHeld()
	local captured = false
	local input = Open77 and Open77.input
	if type(input) == 'table' and type(input.isCaptured) == 'function' then
		local read, taken = pcall(input.isCaptured)
		captured = read and taken == true
	end
	Open77.log.info(('[ncpd] probe %s on %s at %s,%s -- focus held: %s, input captured: %s')
		:format(tostring(payload.t), tostring(payload.target), tostring(payload.x),
			tostring(payload.y), held, tostring(captured)))
end

--- Answers the surface-wide focus broadcast for this module's own owners.
--
-- The broadcast names the whole stack's TOP, not just "empty or not": a top
-- that moved from one of ours to somebody else's must release ours and acquire
-- nothing, or the stale entry sits above the surface actually on screen and
-- applies its wants over that one's. Release every owner of mine that is not
-- the announced one, then acquire the announced one if it is mine.
-- @param payload table|nil
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	local owner = payload.owner
	local held = (payload.focus == true and type(owner) == 'string') and owner or nil
	for name in pairs(FOCUS) do
		if name ~= held then OPX.UI.ReleaseFocus(name) end
	end
	local wants = held ~= nil and FOCUS[held] or nil
	if wants == nil then return end
	OPX.UI.AcquireFocus(held, wants)
	Open77.log.info(('[ncpd] focus: %s takes the input (%s); the client slot now held: %s')
		:format(tostring(held), tostring(wants.cursor) .. ' cursor / ' .. tostring(wants.keyboard)
			.. ' keyboard', slotHeld()))
end

--- Gives up every focus this module took. The stow path calls it (a scanner
-- put away must hand the cursor back, or the page is gone and the surface is
-- still claimed by `ncpd.radio`), and `Stop` says it the same way.
function M.RadioView.Release()
	for name in pairs(FOCUS) do OPX.UI.ReleaseFocus(name) end
end

--- Publishes one message to the page.
-- Both answers of `OPX.UI.Send` are read: the host bounds a WebUI payload and
-- refuses an oversized one whole, and a frame lost that way is a scanner that
-- silently never opens -- named here so it cannot pass for a quiet one.
-- @param payload table
local function toPage(payload)
	local sent, refused = OPX.UI.Send(SURFACE, CHANNEL, payload)
	if not sent or refused then
		Open77.log.warn('[ncpd] the scanner frame did not reach the page: '
			.. (refused and 'the host refused the payload' or 'no surface'))
	end
end

--- Wires the state half to the page and the page's intents back.
function M.RadioView.Start()
	-- Before the intents: the page announces its focus during the same burst
	-- that opens the panel, and an announcement with no handler is dropped.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	OPX.UI.On(SURFACE, 'radio:tune', function(payload)
		M.Radio.FromView('tune', payload)
	end)
	OPX.UI.On(SURFACE, 'radio:talk', function(payload)
		M.Radio.FromView('talk', payload)
	end)
	OPX.UI.On(SURFACE, 'radio:volume', function(payload)
		M.Radio.FromView('volume', payload)
	end)
	OPX.UI.On(SURFACE, 'radio:place', function(payload)
		M.Radio.FromView('place', payload)
	end)
	OPX.UI.On(SURFACE, 'radio:close', function(payload)
		M.Radio.FromView('close', payload)
	end)
	OPX.UI.On(SURFACE, 'radio:probe', onProbe)

	AddEventHandler(M.Event.RADIO_VIEW, toPage)
end

--- Takes the seam down and gives up anything the page still holds.
function M.RadioView.Stop()
	M.RadioView.Release()
	toPage({ kind = 'close', why = 'stop' })
end
