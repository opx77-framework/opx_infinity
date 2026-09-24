--- The ripperdoc's view seam: the one file here that knows the other end is a
-- CEF surface (README: the view seam).
-- @author XEROX710
--
-- A TRANSLATOR AND NOTHING ELSE, the shape `modules/skills/client/view.lua`
-- states: the state half publishes what the page draws on `M.Event.VIEW`; this
-- file turns those into one page channel and turns the page's five intents back
-- into `M.Ripper.FromView` calls. It owns no state and makes no decision.
--
-- ONE CHANNEL OUT, KIND-DISCRIMINATED (`ripperdoc:view`); five channels in
-- (`ripperdoc:offer`, `ripperdoc:answer`, `ripperdoc:invite`, `ripperdoc:stand`,
-- `ripperdoc:close`), one per intent -- the scanner's own shape.

local M = OPX.Modules.Get('ripperdoc')

local SURFACE = 'interactive'
local CHANNEL = 'ripperdoc:view'

--- What this module answers for on `focus:set`, and what it asks for when it
-- does. `keyboard = false`, like the scanner and the tree: the clinic is a
-- menu to read and press, not a dialog -- the game keeps the movement keys and
-- the E that works the chair, and rows are chosen by clicking them.
local FOCUS = {
	['ripperdoc.panel'] = { keyboard = false, cursor = true },
}

--- Answers the surface-wide focus broadcast for this module's own owners.
-- Release every owner of mine that is not the announced one, then acquire the
-- announced one if it is mine (the scanner's own rule, for the same reason).
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
end

--- Gives up every focus this module took. Both the stand path and `Stop` call
-- it -- a menu put away must hand the cursor back.
function M.RipperView.Release()
	for name in pairs(FOCUS) do OPX.UI.ReleaseFocus(name) end
end

--- Publishes one message to the page. Both answers of `OPX.UI.Send` are read:
-- the host bounds a WebUI payload and refuses an oversized one whole, and a
-- frame lost that way is a menu that silently never opens -- named here so it
-- cannot pass for a quiet one.
-- @param payload table
local function toPage(payload)
	local sent, refused = OPX.UI.Send(SURFACE, CHANNEL, payload)
	if not sent or refused then
		Open77.log.warn('[ripperdoc] the frame did not reach the page: '
			.. (refused and 'the host refused the payload' or 'no surface'))
	end
end

--- Wires the state half to the page and the page's intents back.
function M.RipperView.Start()
	-- Before the intents: the page announces its focus during the same burst
	-- that opens the panel, and an announcement with no handler is dropped.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	OPX.UI.On(SURFACE, 'ripperdoc:offer', function(payload)
		M.Ripper.FromView('offer', payload)
	end)
	OPX.UI.On(SURFACE, 'ripperdoc:answer', function(payload)
		M.Ripper.FromView('answer', payload)
	end)
	OPX.UI.On(SURFACE, 'ripperdoc:invite', function(payload)
		M.Ripper.FromView('invite', payload)
	end)
	OPX.UI.On(SURFACE, 'ripperdoc:stand', function(payload)
		M.Ripper.FromView('stand', payload)
	end)
	OPX.UI.On(SURFACE, 'ripperdoc:close', function(payload)
		M.Ripper.FromView('close', payload)
	end)

	AddEventHandler(M.Event.VIEW, toPage)
end

--- Takes the seam down and gives up anything the page still holds.
function M.RipperView.Stop()
	M.RipperView.Release()
	toPage({ mode = 'closed', why = 'stop' })
end
