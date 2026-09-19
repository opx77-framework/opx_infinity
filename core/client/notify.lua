--- Toasts, drawn on the overlay.
-- @author dop42
--
-- This used to be a resource of its own that everything else reached through an
-- export, which is why twelve resources carried a copy of the three-level export
-- call just to raise a notice. In one runtime it is a call.
--
-- The page owns the timing: a toast carries its lifetime and the page animates
-- it down and asks to be told when it has gone. Lua keeps only what it needs to
-- address a toast that is still up.

OPX.Toast = OPX.Toast or {}

local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
local ANSWER = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')

local KINDS = { info = true, success = true, warning = true, error = true }
local DEFAULT_MS = 5000

--- The glyphs a toast may carry, as a CLOSED set.
-- RECOPIED from `modules/target/shared/model.lua` -- and from `M.ICONS` in
-- `modules/menu/module.lua`, which recopied it for the same reason: the page
-- selects a LOCAL path by this name, so an unknown one would reach the DOM as an
-- attribute nobody wrote. Core may not read a module's namespace, so the lists
-- are kept in step by hand; a name that drifts costs a toast its glyph, never a
-- toast.
--
-- IT IS A SET OF DOMAINS, NOT OF VERDICTS. There is no tick in it and no
-- exclamation mark, which is why no kind has a default glyph: see `Show`.
OPX.Toast.ICONS = {
	interact = true, person = true, vehicle = true, info = true, lock = true,
	tool = true, location = true, box = true, door = true, heal = true,
	money = true, talk = true, folder = true, back = true,
}
local ICONS = OPX.Toast.ICONS

local live = {}
local nextId = 0
local hidden = false

--- Whether a value is a glyph this runtime will draw. `nil` and `''` are both
--- "no glyph": a Lua patch cannot carry nil, so `''` is how an update takes one
--- back off a toast that is already up.
local function drawableIcon(value)
	if value == nil or value == '' then return true end
	return type(value) == 'string' and ICONS[value] == true
end

--- The icon of a payload that crossed the WIRE, which is a different bargain
--- from an icon a caller in this process passed. A developer's typo is refused
--- where they can see the return value; a server's typo must not cost a player
--- the refusal it was attached to, so the glyph is dropped and logged and the
--- words still arrive.
local function wireIcon(value, from)
	if drawableIcon(value) then return value end
	Open77.log.warn(('[notify] %s sent icon %q, which is not in the set; drawing none')
		:format(from, tostring(value)))
	return nil
end

--- Raises a toast and answers its id. `id` may be supplied to replace a toast
--- already on screen rather than stacking another under it -- a player who runs
--- the same command twice should see one answer, not a pile.
---
--- `icon` is a name from `OPX.Toast.ICONS` and is REFUSED rather than dropped
--- when it is not one, exactly as the menu refuses an item naming a glyph it
--- does not have: a caller who misspelt `vehcile` wants to hear about it now,
--- not to wonder later why one toast in ten has no picture. Every caller of this
--- already treats `nil` as "the toast did not go up" and falls back to a chat
--- line, so a refused toast is still a message the player reads.
---
--- THERE IS NO DEFAULT GLYPH PER KIND. The set above names domains -- a door, a
--- lock, money -- and holds no tick and no warning mark, so a default would have
--- to draw a padlock on `error.tooFast`. The kind already reaches the player as
--- the frame, the tone and the toast's own kind tag; a glyph that guessed would
--- be the one thing on the surface saying something untrue.
-- @author dop42
-- @param definition table kind, title, message, icon, durationMs, id
-- @return string|nil
-- @return string|nil why it was refused
function OPX.Toast.Show(definition)
	if type(definition) ~= 'table' then return nil, 'toast_must_be_a_table' end

	local message = definition.message
	if type(message) ~= 'string' or message == '' then return nil, 'invalid_toast_message' end

	if not drawableIcon(definition.icon) then return nil, 'invalid_toast_icon' end

	local id = definition.id
	if type(id) ~= 'string' or id == '' then
		nextId = nextId + 1
		id = ('t%d'):format(nextId)
	end

	local toast = {
		id = id,
		kind = KINDS[definition.kind] and definition.kind or 'info',
		title = definition.title,
		message = message,
		icon = definition.icon,
		durationMs = tonumber(definition.durationMs) or DEFAULT_MS,
	}

	live[id] = toast
	if not OPX.UI.Send('overlay', 'notify:show', toast) then
		live[id] = nil
		return nil, 'surface_unavailable'
	end
	return id
end

--- Raises a toast whose text comes from the catalogue. Every refusal code in
--- this runtime is a catalogue key, so this is the path a refusal takes.
-- @author dop42
-- @param key string
-- @param params table|nil
-- @param kind string|nil
-- @param icon string|nil a name from OPX.Toast.ICONS
-- @return string|nil
-- @return string|nil why it was refused
function OPX.Toast.Locale(key, params, kind, icon)
	return OPX.Toast.Show({ kind = kind, message = locale(key, params), icon = icon })
end

--- Takes a toast off screen early.
-- @author dop42
-- @param id string
function OPX.Toast.Dismiss(id)
	if live[id] == nil then return end
	live[id] = nil
	OPX.UI.Send('overlay', 'notify:dismiss', { id = id })
end

--- Rewrites a toast that is still up. Answers false for one that has gone, so a
--- caller updating a progress line stops rather than raising a fresh toast.
-- @author dop42
-- @param id string
-- @param patch table
-- @return boolean
-- @return string|nil why it was refused
function OPX.Toast.Update(id, patch)
	local toast = live[id]
	if toast == nil or type(patch) ~= 'table' then return false end

	-- The same gate as `Show`, because this is the other door into the same
	-- payload: a patch reaching the page unchecked would carry a glyph name the
	-- page has no path for straight past the one place that validates it. `''`
	-- takes a glyph back off, which is the only way a patch can, a Lua table
	-- being unable to carry a nil.
	if not drawableIcon(patch.icon) then return false, 'invalid_toast_icon' end

	for key, value in pairs(patch) do
		if key ~= 'id' then toast[key] = value end
	end
	return OPX.UI.Send('overlay', 'notify:update', toast)
end

--- Clears everything on screen.
-- @author dop42
function OPX.Toast.Clear()
	live = {}
	OPX.UI.Send('overlay', 'notify:clear', {})
end

--- Takes the stacks off screen, keeping every toast, and puts them back.
---
--- The player being down is the only thing that does this, and the module that
--- owns that state calls it: core cannot listen for `opx:on:downed:changed`
--- without depending on a module. The flag is held so a page that remounts is
--- told again -- a view that came back up would otherwise draw toasts over a
--- death screen.
-- @author dop42
-- @param down boolean
function OPX.Toast.SetDown(down)
	hidden = down == true
	OPX.UI.Send('overlay', 'notify:down', { down = hidden })
end

--- Wires the server's two answer channels and the page's own expiry report.
-- @author dop42
function OPX.Toast.Attach()
	-- The page tells us when a toast finished its own countdown, so Lua's table
	-- does not grow for the session with toasts that are long gone.
	OPX.UI.On('overlay', 'notify:gone', function(payload)
		if type(payload.id) == 'string' then live[payload.id] = nil end
	end)

	-- The view's own handshake, raised from its mount -- which is NOT once per
	-- session. The page is built before the modules are, and a page whose assets
	-- are warm in the CEF cache mounts inside the boot window; a reconnection is
	-- exactly that, and a character switch ends the session. So this can arrive
	-- before this handler exists, which is what `lib/client/surface.lua` latches
	-- payloads for, and it can arrive with toasts already live.
	--
	-- Everything the page cannot know for itself is (re)stated here: its
	-- geometry, whether the player is down, and the toasts Lua still holds. A
	-- replayed toast restarts its countdown on the page, which is the honest
	-- answer: the page owns the clock and this one is new.
	OPX.UI.On('overlay', 'notify:ready', function()
		local settings = (OPX.Config.CLIENT and OPX.Config.CLIENT.TOASTS) or {}
		OPX.UI.Send('overlay', 'notify:config', {
			position = settings.position,
			width = settings.width,
		})
		if hidden then OPX.UI.Send('overlay', 'notify:down', { down = true }) end
		for _, toast in pairs(live) do OPX.UI.Send('overlay', 'notify:show', toast) end
	end)

	-- A GLYPH TRAVELS THIS FAR, and no further. Both of these are tables and
	-- argument lists this runtime owns on both ends, so `OPX.Refuse` and
	-- `OPX.CommandNotice` may name one and it reaches the page. What CANNOT carry
	-- one is `OPX.Notify`: that hands the toast to the platform's own
	-- `open77_notifications` package, whose `icon` is a short TEXT badge -- a
	-- glyph name sent there would draw the word "lock" in a box.
	RegisterNetEvent(NOTIFY, function(payload)
		if type(payload) ~= 'table' then return end
		-- The code is always a catalogue key: the server guarantees it through
		-- RefusalKey, so rendering it raw is never a leak of an internal code.
		local code = payload.code
		if type(code) ~= 'string' then return end
		OPX.Toast.Show({
			kind = payload.kind or 'error',
			message = locale(code),
			icon = wireIcon(payload.icon, 'a refusal'),
		})
	end)

	RegisterNetEvent(ANSWER, function(_, kind, message, toasted, icon)
		-- `toasted` means the action already raised this toast itself. Without
		-- the flag a command that notifies on success would answer twice.
		if toasted == true then return end
		if type(message) ~= 'string' or message == '' then return end
		OPX.Toast.Show({
			kind = kind,
			message = message,
			icon = wireIcon(icon, 'a command answer'),
			id = 'opx.command',
		})
	end)
end
