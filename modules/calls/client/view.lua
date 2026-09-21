--- The other half of the seam: the state machine on one side, the page on the
--- other.
-- @author dop42
--
-- `client/main.lua` owns the call state and draws nothing. It says everything
-- it has to say on the local `calls:view` event and takes everything back
-- through `M.FromView`. This file is the only thing that knows those two ends
-- are a CEF page, which is what lets the state half stay testable without one.
--
-- ONE CHANNEL, NOT ONE PER VERB, for the reason `modules/downed/client/view.lua`
-- gives at length: the seam is already a single event carrying a `kind`, and
-- splitting it would mean a switch in this file and a second switch on the
-- page, both kept in step with a list that lives in a third.
--
-- ── the overlay layer, and why this view may never leave it ──────────────────
--
-- `SURFACE = 'overlay'`, and that is the owner's hard requirement made
-- structural rather than promised. The overlay layer is `pointer-events: none`
-- for its whole height and is never focused, so nothing this module draws can
-- take the mouse, swallow a key, or stand between the player and what they are
-- aiming at. A card on the `interactive` layer would draw identically and
-- would be exactly the thing the owner said not to build.
--
-- IT FOLLOWS THAT THE CARD CANNOT HAVE BUTTONS. A view that cannot be clicked
-- cannot carry an Accept button, which is why the answer is on the target eye
-- -- ALT on your own body -- and why the card's own text says so. That is not
-- a workaround for the layer; it is the owner's design, and the layer is what
-- keeps it honest.
--
-- THERE IS NO `focus:set` HANDLER HERE, and its absence is deliberate. Every
-- other view module in this resource answers that broadcast for its own owners
-- -- see the six-copy idiom in `modules/downed/client/view.lua` -- because they
-- all live on the `interactive` layer and have focus to claim. This module
-- claims none, so answering the broadcast would mean calling
-- `OPX.UI.AcquireFocus` for an owner that must never hold focus, which is the
-- one thing that could make an overlay card take the keyboard.

local M = OPX.Modules.Get('calls')

M.View = {}
local View = M.View

-- The layer. See the header: this is the requirement, not a preference.
local SURFACE = 'overlay'

-- What a published payload travels on, and the local event it comes from.
local CHANNEL = 'calls:view'
local EVENT_VIEW = M.Event.VIEW

-- Every action the seam documents. An unknown one reaching `FromView` is
-- ignored there, so nothing here filters a second time.
--
-- `dismiss` and `repop` are the pair that make the owner's re-pop button work:
-- the page reports that the player waved the card away, and the eye's
-- `callRepop` row -- or the page itself -- asks for it back. Neither touches
-- the call; both are about this screen.
local ACTIONS = { 'ready', 'dismiss', 'repop', 'accept', 'decline', 'hangUp', 'diag' }

--- Wires the page to the seam.
-- @author dop42
function View.Start()
	-- The page to the state half.
	for _, action in ipairs(ACTIONS) do
		OPX.UI.On(SURFACE, 'calls:' .. action, function(payload)
			M.FromView(action, payload)
		end)
	end

	-- The state half to the page. Registered BEFORE anything can publish: the
	-- first payload this module ever causes is the one `FromView('ready')`
	-- draws straight back, and a handler added after that would miss it.
	AddEventHandler(EVENT_VIEW, function(payload)
		if type(payload) ~= 'table' then return end
		OPX.UI.Send(SURFACE, CHANNEL, payload)
	end)
end
