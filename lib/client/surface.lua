--- One WebUI page: create it, talk to it, and know when it is not there.
-- @author dop42
--
-- Every surface on this platform follows the same boot sequence:
--
--   create -> the page loads -> the page emits `<id>:ready` -> Lua sends its
--   config -> normal traffic
--
-- A page must report ready before anything is sent to it: a send made earlier
-- is dropped, not queued, so `Send` answers false until `ready` arrives.
--
-- The CEF console does not reach the client log. A page therefore reports its
-- own exceptions on `<id>:diag`, and the handler wired here forwards them to
-- `Open77.log`: that channel is the only way a page-side failure is ever seen.
--
-- The WebUI bridge swallows an exception thrown inside an `Open77.on` handler,
-- so every handler registered here runs under a pcall that logs. Without it a
-- handler that raises fails silently and the page just stops responding.

OPX.Surface = {}

-- Every surface on this platform draws on the 'hud' layer; no other value has
-- ever been used, so it is fixed here rather than taken from the spec.
local LAYER = 'hud'

local DEFAULT_WIDTH = 1920
local DEFAULT_HEIGHT = 1080
local DEFAULT_FPS = 30
local DEFAULT_Z_INDEX = 700

--- Registers the one page listener for a channel, if it has none yet.
-- One listener per channel, dispatching through `handlers`, is what makes a
-- handler replaceable and keeps a raised handler from disappearing.
-- @param surface table
-- @param channel string
-- @return boolean
local function wire(surface, channel)
	if surface.wired[channel] then return true end
	local full = surface.id .. ':' .. channel
	local page = surface.page

	local listening, failure = pcall(page.on, page, full, function(payload)
		-- Set here, not in a caller's own ready handler: the flag must be true
		-- before that handler runs, or its first Send is dropped.
		if channel == 'ready' then surface.ready = true end
		local handler = surface.handlers[channel]
		if handler == nil then return end
		local ran, raised = pcall(handler, payload)
		if not ran then
			Open77.log.error(('[surface %s] %s raised: %s'):format(surface.id, full, tostring(raised)))
		end
	end)

	if not listening then
		Open77.log.error(('[surface %s] %s not wired: %s'):format(surface.id, full, tostring(failure)))
		return false
	end
	surface.wired[channel] = true
	return true
end

--- Attaches a handler to `<id>:<channel>`, replacing any handler it had.
-- @author dop42
-- @param surface table
-- @param channel string without the `<id>:` prefix
-- @param handler fun(payload: any)|nil
-- @return boolean
function OPX.Surface.On(surface, channel, handler)
	if type(surface) ~= 'table' or surface.page == nil then return false end
	if type(channel) ~= 'string' or channel == '' then return false end
	if not wire(surface, channel) then return false end
	surface.handlers[channel] = handler
	return true
end

--- Creates a WebUI page and wires its ready and diagnostic channels.
-- A nil answer is what a caller turns into its own `no_surface`: there is
-- nothing to draw on, and every export of that resource must refuse.
-- @author dop42
-- @param spec table id, entry, zIndex, fps, width, height, transparent, visible
-- @return table|nil the surface
-- @return string|nil the failure
function OPX.Surface.Create(spec)
	if type(spec) ~= 'table' then return nil, 'bad_spec' end
	if type(spec.id) ~= 'string' or spec.id == '' then return nil, 'bad_spec' end
	if type(spec.entry) ~= 'string' or spec.entry == '' then return nil, 'bad_spec' end

	-- Read at call time, not at load: a client build without the plugin has no
	-- WebUI global, and a resource that only sometimes draws must still load.
	local webui = rawget(_G, 'WebUI')
	if type(webui) ~= 'table' or type(webui.create) ~= 'function' then
		return nil, 'no_webui'
	end

	local created, page, reason = pcall(webui.create, {
		entry = spec.entry,
		layer = LAYER,
		width = spec.width or DEFAULT_WIDTH,
		height = spec.height or DEFAULT_HEIGHT,
		fps = spec.fps or DEFAULT_FPS,
		zIndex = spec.zIndex or DEFAULT_Z_INDEX,
		transparent = spec.transparent ~= false,
		visible = spec.visible ~= false,
	})
	if not created then return nil, tostring(page) end
	if page == nil then return nil, tostring(reason or 'no_surface') end

	local surface = {
		id = spec.id,
		page = page,
		ready = false,
		-- True once the page is gone: Send and Focus then answer false for
		-- good, and a caller reading it answers `no_surface`.
		failed = false,
		handlers = {},
		wired = {},
	}

	wire(surface, 'ready')
	OPX.Surface.On(surface, 'diag', function(payload)
		if type(payload) ~= 'table' then return end
		Open77.log.info(('[surface %s] page: %s'):format(surface.id, tostring(payload.text or '')))
	end)

	return surface
end

--- Sends a payload to the page on `<id>:<channel>`.
-- @author dop42
-- @param surface table
-- @param channel string without the `<id>:` prefix
-- @param payload table|nil
-- @return boolean false while the page is not ready, or gone
function OPX.Surface.Send(surface, channel, payload)
	if type(surface) ~= 'table' or surface.failed or not surface.ready then return false end
	if surface.page == nil then return false end
	local full = surface.id .. ':' .. channel
	local sent, failure = pcall(surface.page.send, surface.page, full, payload or {})
	if not sent then
		Open77.log.error(('[surface %s] %s not sent: %s'):format(surface.id, full, tostring(failure)))
		return false
	end
	return true
end

--- Gives the page the keyboard, the cursor, both or neither.
-- @author dop42
-- @param surface table
-- @param keyboard boolean
-- @param cursor boolean
-- @return boolean
function OPX.Surface.Focus(surface, keyboard, cursor)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	local focused, taken = pcall(surface.page.setFocus, surface.page, keyboard == true, cursor == true)
	if not focused then
		Open77.log.error(('[surface %s] focus refused: %s'):format(surface.id, tostring(taken)))
		return false
	end
	-- Only an explicit false is a refusal: a build that answers nothing at all
	-- has still taken the focus.
	return taken ~= false
end

--- Shows or hides the page without destroying it. Hiding is what an overlay does
--- between uses; destroying is for a surface that will not be needed again, since
--- a CEF page is expensive to build and is never replaced in place.
-- @author dop42
-- @param surface table
-- @param visible boolean
-- @return boolean
function OPX.Surface.Visible(surface, visible)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	local page = surface.page
	local ok = pcall(visible and page.show or page.hide, page)
	return ok
end

--- Whether the page currently holds focus. A surface that lost it while open has
--- been closed by something else, and the owner has to notice.
-- @author dop42
-- @param surface table
-- @return boolean
function OPX.Surface.HasFocus(surface)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	local read, held = pcall(surface.page.hasFocus, surface.page)
	return read and held == true
end

--- Destroys the page and marks the surface gone.
-- @author dop42
-- @param surface table
function OPX.Surface.Destroy(surface)
	if type(surface) ~= 'table' then return end
	surface.ready = false
	surface.failed = true
	local page = surface.page
	surface.page = nil
	if page ~= nil then pcall(page.destroy, page) end
end
