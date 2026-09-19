--- Resolves the operator's block once and answers the clients that ask for it.
-- @author dop42
--
-- RESOLVED AT INIT AND NEVER AGAIN. The payload is the same for every player and
-- cannot change while the resource runs -- `config/theme.lua` is read at load
-- like every other config file -- so re-deriving it per request would be the
-- same eight HSL conversions per connection for an identical answer. It is also
-- what makes the journal useful: whatever an operator mistyped is named once, at
-- boot, next to the rest of the boot rather than the first time somebody joins.
--
-- THE ANSWER IS ADDRESSED, NOT BROADCAST. A player asks when their page exists,
-- which is not when they connect: a reconnection, a character switch and a
-- `/opx.reload` all rebuild the page without a new connection. Answering the
-- asker is the only shape that covers all three, and it is the shape the chat's
-- completion list already uses.

local M = OPX.Modules.Get('theme')
local Palette = M.Palette

-- The resolved payload, built once in Init. Empty when nothing is configured,
-- and an empty theme is still sent: the client needs to hear the answer to stop
-- waiting for it, and an empty payload writes no property.
local theme

-- A request is answered at most this often per player. Not a security boundary:
-- the answer is a couple of hundred bytes and a client that asks twice has
-- rebuilt its page twice, which is normal. It is the same floor the chat puts
-- under its completion list, for the same reason -- anyone can raise the name.
local REQUEST_MS = 2000

--- Sends the theme to one player.
local function answer(player)
	TriggerClientEvent(M.Event.SET, player, theme)
end

--- A page has appeared on some client and wants to know what it looks like.
local function onRequest()
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if OPX.Cooling(player, 'theme.request', REQUEST_MS) then return end
	answer(player)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Resolves the configured theme and says what it refused. Never yields.
-- @author dop42
function M.Init()
	-- READ AT Init, NOT THROUGH `M.Settings`. `Settings` is captured at Declare
	-- time from `OPX.Config.MODULES[id]`, and this module's config is the only
	-- one in the resource that is a `server_script` rather than a
	-- `shared_script` -- deliberately, so the client never holds a copy. The
	-- server does not load the two groups in manifest line order the way the
	-- test harness does, so `modules/theme/module.lua` can be declared before
	-- `config/theme.lua` has run and capture an empty table. It did: the first
	-- live deploy logged "nothing configured" with every value set.
	--
	-- Reading the config here is correct under either ordering, which is the
	-- point -- the fix does not depend on knowing which one the host uses.
	local block = OPX.Config.MODULES.theme
	if block == nil or next(block) == nil then block = M.Settings end

	local notes
	theme, notes = Palette.Resolve(block)

	-- SAID OUT LOUD, ONE LINE PER VALUE. A refused colour is invisible
	-- otherwise: the surface simply keeps the shipped red, which is exactly what
	-- an operator who has not configured anything sees, so "my accent did
	-- nothing" and "I have not set an accent" look identical from the game.
	for index = 1, #notes do
		Open77.log.warn(('[theme] %s'):format(notes[index]))
	end

	if Palette.IsEmpty(theme) then
		Open77.log.info('[theme] nothing configured; every page keeps the shipped ladder')
	else
		local keys = {}
		for key in pairs(theme) do keys[#keys + 1] = key end
		table.sort(keys)
		Open77.log.info(('[theme] %d value(s) pushed to every page: %s')
			:format(#keys, table.concat(keys, ' ')))
	end
end

--- Publishes the resolved theme to anything server-side that wants to draw in
--- the house colours -- a webhook embed's stripe, say. Read-only on purpose:
--- there is no setter, here or on the wire, because the operator's file is the
--- authority and a second writer would make "what colour is this server" a
--- question with two answers.
-- @author dop42
function M.Api()
	OPX.Api.Provide('theme', 1, {
		--- The payload every page is sent. A copy, so a caller cannot edit it.
		-- @return table
		Current = function()
			return OPX.Table.DeepCopy(theme)
		end,
	})
end

--- Opens the one door.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.REQUEST, onRequest)
end
