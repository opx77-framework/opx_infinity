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

-- Every action the seam accepts. An unknown one reaching `FromView` is ignored
-- there, so nothing here filters a second time.
--
-- TODAY THE PAGE EMITS ONE OF THEM -- `ready`, from the card's `onMounted`.
-- That is not an oversight and the other six are not dead: a view on this layer
-- has no way to be pressed, so every DECISION arrives through the eye and calls
-- `M.FromView` in process. The list is the seam's vocabulary rather than a
-- record of what the current page happens to use, and it is written out here so
-- that a view which later gains a legitimate way to speak -- a keybind, a
-- surface that moves -- finds the wire already there rather than adding a
-- seventh spelling of it.
--
-- `dismiss` and `repop` are the pair behind the owner's re-pop button.
-- Dismissing is the card leaving the screen; the call goes on ringing, the
-- sound goes on re-arming, and the server is never told. Both are about this
-- screen and neither touches the call.
local ACTIONS = { 'ready', 'dismiss', 'repop', 'accept', 'decline', 'hangUp', 'diag' }

-- ── THE SECOND SURFACE, AND WHY THERE ARE TWO ────────────────────────────────
--
-- THE OWNER: "fait une touche qui ouvre un menu style halogram tous se passe
-- desus", "le halo prend vrais le devant de l'ecran", "en plein centre".
--
-- The card above may never be pressed, and everything in this file's header
-- explains why: it arrives unbidden, so it lives on a layer that cannot take
-- the mouse. The hologram is the exact opposite and for the exact same reason
-- -- the player OPENED it, on a key, deliberately -- so it is centred, in
-- front, focused and pressable, and it carries every verb this module has.
--
-- The two could not share a layer. A passive notice that could steal input and
-- a deliberate screen that could not would both be the wrong way round.
local HOLO_SURFACE = 'interactive'
local HOLO_CHANNEL = 'calls:holo'

-- What the hologram may say. `close` and `toggle` are about the screen; the
-- rest name a player the server judges again.
local HOLO_ACTIONS = { 'ready', 'close', 'toggle', 'call', 'share',
	'accept', 'decline', 'hangUp', 'diag' }

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
	-- The hologram's own end of the seam.
	for _, action in ipairs(HOLO_ACTIONS) do
		OPX.UI.On(HOLO_SURFACE, 'calls:' .. action, function(payload)
			M.FromView(action, payload)
		end)
	end

	AddEventHandler(EVENT_VIEW, function(payload)
		if type(payload) ~= 'table' then return end
		-- ROUTED BY KIND, because the two surfaces are two screens. Sending the
		-- hologram's roster to the overlay would put a contact list on a layer
		-- nobody can press, and sending the card to the interactive layer would
		-- give an unbidden notice the keyboard.
		if payload.kind == 'holo' then
			OPX.UI.Send(HOLO_SURFACE, HOLO_CHANNEL, payload)
			-- FOCUS FOLLOWS THE SCREEN, and only this screen ever takes it. A
			-- hologram the player cannot type into or click is not a menu, and
			-- one that kept focus after closing would be a player who cannot
			-- move.
			-- `(owner, wants)`, and the cursor is asked for explicitly: it
			-- defaults to false, and a hologram whose rows cannot be clicked is
			-- a picture. The stack is what gives focus back to whatever was
			-- under this when it closes, rather than dropping it to nothing.
			if payload.open == true then
				OPX.UI.AcquireFocus('calls', { keyboard = true, cursor = true })
			else
				OPX.UI.ReleaseFocus('calls')
			end
			return
		end
		OPX.UI.Send(SURFACE, CHANNEL, payload)
	end)
end
