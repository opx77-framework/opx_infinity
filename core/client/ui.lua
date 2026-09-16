--- The two surfaces, the bridge to them, and the focus stack.
-- @author dop42
--
-- Twelve resources used to own a full-screen CEF surface each, ranked by a
-- hand-maintained z-index ladder from 700 to 760. One resource may have eight,
-- so a surface per feature is not an option any more -- and it was never a good
-- one: twelve browsers meant twelve copies of the same stylesheet, because each
-- WebUI runs on its own isolated origin and cannot load a file from another.
--
-- Two surfaces, split where the platform already splits:
--
--   overlay      z 700, 30 fps, created at start, never focused, never destroyed
--   interactive  z 740, 60 fps, created on first use, takes focus, disposable
--
-- Four reasons for the split rather than one surface: only one surface may hold
-- focus, so putting every focusing view on one gives focus a single owner; the
-- two have genuinely different frame budgets; the interactive layer can be
-- destroyed to give its memory back, and `page.destroy` exists; and an exception
-- in a heavy view must not be able to blank the HUD. That last one is a property
-- twelve separate browsers gave away for free, and this recovers it rather than
-- improving on it.
--
-- Channel names are `opx:<module>:<verb>`. The surface id is `opx` and
-- `OPX.Surface` prefixes it, so a caller passes `character:loaded` and the page
-- sees `opx:character:loaded`.

OPX.UI = OPX.UI or {}

local ID = 'opx'
local REPLY = 'reply'

local surfaces = {}

local focusStack = {}

--- Builds one surface from its configured z-index and frame rate.
local function create(name, visible)
	local settings = OPX.Config.CLIENT.SURFACE[name:upper()] or {}
	local surface, why = OPX.Surface.Create({
		id = ID,
		entry = ('web/%s.html'):format(name == 'overlay' and 'index' or 'modal'),
		zIndex = settings.zIndex,
		fps = settings.fps,
		visible = visible,
	})
	if surface == nil then
		Open77.log.error(('[ui] the %s surface failed: %s'):format(name, tostring(why)))
		Open77.log.error('  nothing on it can be drawn; every view will answer no_surface.')
		return nil
	end

	OPX.Surface.On(surface, 'ready', function()
		surface.ready = true
		OPX.Surface.Send(surface, 'config', {
			locale = OPX.Locale.Current(),
			strings = OPX.Locale.Catalogue(),
		})
	end)

	return surface
end

--- The always-on overlay: HUD, toasts, key strip, chat log.
-- @author dop42
-- @return table|nil
function OPX.UI.Overlay()
	if surfaces.overlay == nil then surfaces.overlay = create('overlay', true) or false end
	return surfaces.overlay or nil
end

--- The interactive layer, created on first use. Anything that takes the keyboard
--- or the cursor lives here.
-- @author dop42
-- @return table|nil
function OPX.UI.Interactive()
	if surfaces.interactive == nil then
		surfaces.interactive = create('interactive', false) or false
	end
	return surfaces.interactive or nil
end

--- Resolves a target name to its surface.
local function surfaceOf(target)
	if target == 'interactive' then return OPX.UI.Interactive() end
	return OPX.UI.Overlay()
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
local function applyFocus()
	local surface = OPX.UI.Interactive()
	if surface == nil then return end

	local top = focusStack[#focusStack]
	if top == nil then
		OPX.Surface.Focus(surface, false, false)
		OPX.Surface.Visible(surface, false)
		return
	end
	OPX.Surface.Visible(surface, true)
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

--- Destroys both surfaces. The page is not replaced in place, which is why this
--- resource reloads with `reconnect`; this is the stop path, not a reload path.
-- @author dop42
function OPX.UI.Teardown()
	focusStack = {}
	for name, surface in pairs(surfaces) do
		if surface then OPX.Surface.Destroy(surface) end
		surfaces[name] = nil
	end
end
