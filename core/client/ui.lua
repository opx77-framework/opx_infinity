--- The surface, the bridge to it, and the focus stack.
-- @author dop42
--
-- Twelve resources used to own a full-screen CEF surface each, ranked by a
-- hand-maintained z-index ladder from 700 to 760. One resource may have eight,
-- so a surface per feature is not an option any more -- and it was never a good
-- one: twelve browsers meant twelve copies of the same stylesheet, because each
-- WebUI runs on its own isolated origin and cannot load a file from another.
--
-- ONE surface, two layers inside the page. It was two surfaces -- an overlay and
-- an interactive layer -- and that split cost 400 kB of byte-identical duplication
-- (the Vue runtime, the design system, eight woff2 faces) for two properties: a
-- frame rate per layer, and an exception in a heavy view being unable to blank the
-- HUD. Both are given up knowingly. `fps` is fixed at creation for the whole page,
-- and the layers are now separated by a component boundary in one JS realm rather
-- than by two browsers.
--
-- `Overlay()` and `Interactive()` both answer with that one surface. Callers still
-- pass a target, because which LAYER a module draws on is still real on the page
-- side -- the overlay layer never takes a pointer.
--
-- Channel names are `opx:<module>:<verb>`. The surface id is `opx` and
-- `OPX.Surface` prefixes it, so a caller passes `character:loaded` and the page
-- sees `opx:character:loaded`.

OPX.UI = OPX.UI or {}

local ID = 'opx'
local REPLY = 'reply'

-- One surface, built on first use and kept until Teardown.
local page = nil

local focusStack = {}

--- Wires every channel a view may emit before its own module is running.
--
-- THE PAGE IS BUILT BEFORE THE MODULES ARE. `core/client/boot.lua` creates the
-- surface first -- deliberately, so a module drawing from `Start` has something
-- to draw on -- and then walks the modules a FRAME AT A TIME, because `Start`
-- yields between them to reset the instruction budget. That is a window of
-- twenty-odd frames.
--
-- A view emits `opx:<module>:ready` from its `onMounted`, and `ui/src/bridge/
-- channel.ts` releases all of them in the same tick as `opx:ready`. With warm CEF
-- assets the page mounts inside the window -- which is every reconnection, and a
-- character switch ends the session -- so those signals arrived while the module
-- that answers them was still several frames from registering. There was no host
-- listener on the channel at all, so nothing was dropped by this resource: it was
-- never delivered to it. And the page says ready ONCE.
--
-- Wiring them here, against the module list rather than a hand-kept one, gives
-- every `<id>:ready` a listener from the moment the page exists. What arrives
-- with no handler yet is held by `lib/client/surface.lua` and replayed to the
-- module when it finally registers.
local function wireReadyChannels(surface)
	for _, module in ipairs(OPX.Modules.All()) do
		OPX.Surface.Wire(surface, module.Id .. ':ready')
	end
end

--- Builds the surface from its configured layer, z-index and frame rate.
local function create()
	local settings = OPX.Config.CLIENT.SURFACE or {}
	local surface, why = OPX.Surface.Create({
		id = ID,
		entry = 'web/index.html',
		layer = settings.layer,
		zIndex = settings.zIndex,
		fps = settings.fps,
		-- Created VISIBLE, deliberately. Creation is asynchronous, and a `show()`
		-- issued straight after `create` loses the race against the `visible` flag
		-- the request carried -- the surface then never paints at all.
		visible = true,
	})
	if surface == nil then
		Open77.log.error(('[ui] the surface failed: %s'):format(tostring(why)))
		Open77.log.error('  nothing can be drawn; every view will answer no_surface.')
		return nil
	end

	OPX.Surface.On(surface, 'ready', function()
		surface.ready = true
		-- `locale:set`, which is the channel the page's boot subscribes to. The
		-- page cannot call back for a string per render, so it gets the whole
		-- catalogue once; a name nobody listens to leaves every label rendering
		-- as its own key, which reads as a missing translation rather than as a
		-- broken channel.
		OPX.Surface.Send(surface, 'locale:set', {
			locale = OPX.Locale.Current(),
			strings = OPX.Locale.Catalogue(),
		})
	end)

	-- Before anything can be emitted, which is the whole point: a channel wired
	-- after the page mounted is wired too late.
	wireReadyChannels(surface)

	return surface
end

--- The surface, created on first use and kept for the life of the resource.
-- @author dop42
-- @return table|nil
function OPX.UI.Surface()
	if page == nil then page = create() or false end
	return page or nil
end

-- Two names for one surface. They were two CEF pages; they are two layers of one
-- page now, and both names still answer so the modules that draw on them did not
-- have to be touched. The distinction they carry is still true -- `overlay` is the
-- layer that never takes a pointer -- it is just enforced on the page side.
OPX.UI.Overlay = OPX.UI.Surface
OPX.UI.Interactive = OPX.UI.Surface

--- Resolves a target name to the surface. There is one, so the name survives as a
--- layer hint the page reads off the channel rather than as a choice of browser.
local function surfaceOf()
	return OPX.UI.Surface()
end

--- Sends a payload to a surface.
-- @author dop42
-- @param target string 'overlay' or 'interactive'
-- @param channel string `<module>:<verb>`
-- @param payload table|nil
-- @return boolean
function OPX.UI.Send(target, channel, payload)
	local surface = surfaceOf(target)
	if surface == nil then return false end
	return OPX.Surface.Send(surface, channel, payload)
end

--- Handles a channel the page emits. The page sends INTENTS, never facts:
--- nothing it computes is trusted, and every handler re-derives from state the
--- runtime owns.
-- @author dop42
-- @param target string
-- @param channel string
-- @param handler fun(payload: table)
-- @return boolean
function OPX.UI.On(target, channel, handler)
	local surface = surfaceOf(target)
	if surface == nil then return false end
	return OPX.Surface.On(surface, channel, function(payload)
		if type(payload) ~= 'table' then return end
		handler(payload)
	end)
end

--- Answers a request the page made. The page generates the ref and waits on it
--- with its own timeout, so an answer that never comes degrades into a rejected
--- promise rather than a view stuck forever.
-- @author dop42
-- @param target string
-- @param ref any the ref the request carried
-- @param payload table
function OPX.UI.Answer(target, ref, payload)
	if ref == nil then return end
	payload = payload or {}
	payload.ref = ref
	OPX.UI.Send(target, REPLY, payload)
end

--- Registers a request handler: the answer is sent back on the reply channel
--- under the ref the page supplied.
-- @author dop42
-- @param target string
-- @param channel string
-- @param handler fun(payload: table): table
function OPX.UI.Serve(target, channel, handler)
	OPX.UI.On(target, channel, function(payload)
		local ok, answer = pcall(handler, payload)
		if not ok then
			Open77.log.error(('[ui] %s raised: %s'):format(channel, tostring(answer)))
			answer = { ok = false, error = 'error.unavailable' }
		end
		OPX.UI.Answer(target, payload.ref, answer)
	end)
end

--- Applies whatever is on top of the focus stack, or drops focus entirely.
---
--- It does NOT hide the surface when the stack empties. It used to, back when the
--- interactive layer was its own page and hiding it was free; the HUD lives on this
--- surface now, and hiding it would blank the health bar every time a menu closed.
--- The page inerts its own modal layer instead -- `Focus(false, false)` reaches it
--- as a focus event, and the layer drops `pointer-events` on it.
local function applyFocus()
	local surface = OPX.UI.Surface()
	if surface == nil then return end

	local top = focusStack[#focusStack]
	if top == nil then
		OPX.Surface.Focus(surface, false, false)
		return
	end
	OPX.Surface.Focus(surface, top.keyboard == true, top.cursor == true)
end

--- Takes keyboard and cursor for a named owner. Stacked rather than set, so a
--- view opened over another gives focus back to it on release instead of
--- dropping it to nothing.
-- @author dop42
-- @param owner string
-- @param wants table|nil keyboard, cursor
-- @return boolean
function OPX.UI.AcquireFocus(owner, wants)
	if type(owner) ~= 'string' or owner == '' then return false end
	wants = wants or {}

	for index = 1, #focusStack do
		if focusStack[index].owner == owner then table.remove(focusStack, index) break end
	end
	focusStack[#focusStack + 1] = {
		owner = owner,
		keyboard = wants.keyboard ~= false,
		cursor = wants.cursor == true,
	}
	applyFocus()
	return true
end

--- Gives focus back. Safe for an owner that never held it.
-- @author dop42
-- @param owner string
function OPX.UI.ReleaseFocus(owner)
	for index = #focusStack, 1, -1 do
		if focusStack[index].owner == owner then table.remove(focusStack, index) end
	end
	applyFocus()
end

--- Who currently holds focus, or nil.
-- @author dop42
-- @return string|nil
function OPX.UI.FocusOwner()
	local top = focusStack[#focusStack]
	return top and top.owner or nil
end

--- Destroys the surface. The page is not replaced in place, which is why this
--- resource reloads with `reconnect`; this is the stop path, not a reload path.
-- @author dop42
function OPX.UI.Teardown()
	focusStack = {}
	if page then OPX.Surface.Destroy(page) end
	page = nil
end
