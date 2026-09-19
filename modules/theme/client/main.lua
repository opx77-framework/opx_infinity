--- Asks the server what this server looks like, and hands the answer to the page.
-- @author dop42
--
-- IT DECIDES NOTHING. There is no local default here and no fallback ladder: the
-- page already holds the shipped one in its own stylesheet, so a client that is
-- told nothing draws what it always drew. A default written on this side would
-- be a second opinion about the house palette living on the machine least able
-- to be trusted with one.
--
-- THE TWO ORDERS BOTH HAPPEN. `Start` asks the server, and the page emits
-- `opx:theme:ready` from its own boot: which of the two answers first depends on
-- whether the CEF assets were warm, and a reconnection is the warm case every
-- time. So both paths write into the same two fields and whichever completes the
-- pair does the send. The alternative -- sending on receipt and relying on
-- `OPX.Surface.Send` refusing while the page is not ready -- loses the theme
-- silently on exactly the reconnection path, because a refused send is a `false`
-- nobody reads.
--
-- WHAT ARRIVES IS SANITISED AGAIN. The server built it with the same function,
-- so this costs a walk of a dozen keys and buys the case the wire exists for: a
-- client and a server on different versions of this resource. An unknown key or
-- a number from a wider range than this build allows is dropped here rather than
-- reaching the page.

local M = OPX.Modules.Get('theme')
local Palette = M.Palette

-- The surface name. There is one page; the name is the layer hint the page reads
-- off the payload, and the theme is a property of the document rather than of
-- either layer -- `interactive` is the name the other view modules pass and it
-- resolves to the same page.
local SURFACE = 'interactive'

-- The last thing the server said, already sanitised, or nil while nothing has
-- arrived. Kept rather than forwarded and forgotten: the page can report ready
-- after it.
local theme

-- Whether the page has asked for its theme. It does so once per page load.
local pageReady = false

--- Sends the theme to the page, once both ends are there.
local function applyWhenReady()
	if theme == nil or not pageReady then return end
	OPX.UI.Send(SURFACE, M.Page.SET, theme)
end

--- The server's answer.
local function onTheme(payload)
	local clean, notes = Palette.Sanitise(payload)
	for index = 1, #notes do
		-- The client log, which is a file on the player's machine -- but this can
		-- only ever fire on a version mismatch, and then it fires for everyone on
		-- the server at once and the operator will hear about it.
		Open77.log.warn(('[theme] from the server: %s'):format(notes[index]))
	end
	theme = clean
	applyWhenReady()
end

--- The page, reporting that it has a root to write properties onto.
local function onPageReady()
	pageReady = true
	applyWhenReady()
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Nothing to build. Never yields.
-- @author dop42
function M.Init()
end

--- Wires both ends and asks.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.SET, onTheme)

	-- Wired at page creation by `core/client/ui.lua`, so a signal emitted before
	-- this module started is held and replayed to this handler the moment it
	-- registers. Registered BEFORE the request goes out, for the same reason.
	OPX.UI.On(SURFACE, M.Page.READY, onPageReady)

	-- One request per client, per resource start. The page is rebuilt more often
	-- than the resource is, which is why the page's own ready does not ask again:
	-- `theme` is still held here from the first answer and is simply re-sent.
	TriggerServerEvent(M.Event.REQUEST)
end

--- Forgets the page, not the theme. A stop destroys the surface; the next one is
--- a new page and must report ready before anything is written to it.
-- @author dop42
function M.Stop()
	pageReady = false
end
