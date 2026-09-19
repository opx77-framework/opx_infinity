--- One outstanding spawn choice per player, and the deadline that ends it.
-- @author dop42
--
-- The whole of this half is a handshake with `character`, which owns placement:
--
--   1. `character.PlacePending` asks `M.Offer` on every join. Answering true means
--      this module has taken the placement over and `character` must NOT place.
--   2. `M.Offer` records the choice, puts `spawn:offer` on the wire and starts the
--      one watcher that ends a choice nobody makes.
--   3. The player's click arrives as `spawn:choose` carrying an ID and nothing
--      else. The ID is looked up in this VM's own catalogue -- see `M.Point` --
--      so the coordinates are never the client's to choose.
--   4. Either way the choice ends, `M.Settle` places the body through
--      `character.PlaceCharacter` and puts `spawn:close` on the wire.
--
-- WHY THE DEADLINE MATTERS MORE THAN IT LOOKS. Nobody places the body until step
-- 4 runs, so a menu that never closes leaves the character standing wherever the
-- join put them -- and on a first join, with no name either, because the entry
-- module's form and this module's menu are answers to the same moment. That is a
-- player stuck for the session, so the deadline is not a nicety: it is the only
-- exit a choice nobody makes ever gets.
--
-- There is no `OPX.Scheduler` here and there must not be: that is the client's
-- loop. On the server a loop is a `CreateThread` that yields.

local M = OPX.Modules.Get('spawn')

-- How often the watcher looks at its own deadline. A pick that lands inside this
-- window is answered by the handler itself, so the watcher only ever has to be
-- accurate to within one tick.
local WATCH_MS = 500

-- A floor on the configured timeout, in seconds, and also the answer for a setting
-- that is missing or unreadable. A zero from a typo would expire the offer in the same
-- tick it was made, which is not a short choice but no choice at all -- so this is the
-- one module where the floor and the fallback are deliberately LOWER than the number
-- the configuration ships with: an operator may shorten the choice, not remove it.
local TIMEOUT_FLOOR_SECONDS = 5

--- The character contract, resolved once the Api phase has ended.
local Character

--- The outstanding choice, by player id.
--  source -> { token, citizenId, expiresAtMs }
-- The token is what makes a late settle harmless: a watcher holding an old token
-- cannot clear a choice that replaced it.
local pending

local tokenSeq

--- How long a player has to choose, in milliseconds.
local function timeoutMs()
	return math.floor(M.Number(M.Settings.TIMEOUT_SECONDS, TIMEOUT_FLOOR_SECONDS) * 1000)
end

-- A bound on how long an offer nobody opens may hold a character unplaced, in
-- seconds, and also the answer for a setting that is missing or unreadable.
-- Generous, because waiting on a player is the normal case: it exists only so a
-- client that never draws the menu cannot strand a body for the session.
local HOLD_MAX_FLOOR_SECONDS = 60

local function holdMs()
	return math.floor(M.Number(M.Settings.HOLD_MAX_SECONDS, HOLD_MAX_FLOOR_SECONDS) * 1000)
end

--- Whether this module is switched on at all.
local function enabled()
	return M.Settings.enabled ~= false
end

--- Puts a payload on the wire to one player.
local function send(event, source, payload)
	if source == nil then return end
	TriggerClientEvent(event, source, payload)
end

--- Moves the body the choice selected, or leaves the target to the row when none
-- was made -- so a player who picks nothing resumes where they were, and only a
-- character whose row holds no position falls to the default spawn.
-- The player is re-resolved from the citizen id rather than held across the
-- wait: a slot is recycled, and a character that left during the choice must not
-- have its body moved -- nor somebody else's.
-- @return boolean whether a placement was attempted and took
local function place(source, held, point)
	local player = Character.GetPlayer(source)
	if not player then return false end
	if player.PlayerData == nil or player.PlayerData.citizenId ~= held.citizenId then
		return false
	end

	-- A nil point is not a fallback this module chooses: it means "no explicit
	-- target", which `character` resolves to the row's own position and then to
	-- the default spawn. Passing nothing is deliberate, so the resume and the
	-- default both stay owned by the module that owns the setting.
	local placed, reason = Character.PlaceCharacter(player, point)
	if not placed then
		Open77.log.warn(('[spawn] %s could not be placed at %s: %s')
			:format(held.citizenId, point ~= nil and point.id or 'where the row says',
				tostring(reason)))
	end
	return placed
end

--- Ends one choice: spends it, takes the menu down, and moves the body.
-- Idempotent against the token, so the deadline watcher and a click that arrive
-- together cannot both place.
-- @param source Source
-- @param token integer the choice this settles, as the caller saw it
-- @param point table|nil the spot chosen, or nil for the default
-- @param reason string what ended it: 'chosen' or 'timeout'
-- @return boolean whether it settled anything
local function settle(source, token, point, reason)
	local held = pending and pending[source]
	if held == nil or held.token ~= token then return false end
	-- SPENT HERE, SYNCHRONOUSLY, and this line is the whole of the rate limit: a
	-- second click arriving while the body is still moving finds no choice to take,
	-- and two settles can never both place.
	pending[source] = nil

	-- THE MENU COMES DOWN FIRST. Placement is a kill and a respawn -- about a
	-- second, with a fade -- and a menu held up over that is a player staring at a
	-- list while their body is moved underneath it. Sent whatever placement then
	-- does, because a choice that has been spent is spent: a menu left up because a
	-- kill was refused has nothing behind it, and the player has to be able to move.
	send(M.Event.CLOSE, source, {
		reason = reason,
		-- The label only, for the sentence the client shows. The coordinates are
		-- not the client's business in either direction.
		place = point ~= nil and point.label or nil,
	})

	if reason == 'timeout' then
		-- Not 'the default spawn': a player who picked nothing is placed by the
		-- row, which for a returning character is exactly where they left off.
		-- Only a character whose row holds nowhere reaches the default.
		Open77.log.info(('[spawn] %s chose nothing in time; the row decides where they land')
			:format(held.citizenId))
	end

	-- ON ITS OWN THREAD, and it has to be: `PlaceCharacter` yields -- it polls the
	-- life state with `Wait` -- and the routeway this is reached from is a net
	-- handler, which is not a coroutine. Yielding from one is a raise, and a raise
	-- here would be a character left where the pristine save dropped them.
	CreateThread(function() place(source, held, point) end)
	return true
end

--- Offers a spawn choice to the character a join has just loaded.
-- @author dop42
-- Called by `character.PlacePending` on EVERY world enter, for a character with a
-- position to resume as well as one without: answering true means the body is
-- placed from here instead, and a player who picks nothing is placed by the row.
-- Answers false -- "place them yourself" -- for every case this module cannot
-- serve: switched off, no usable location, no identity to place, or a choice
-- already outstanding.
-- @param source Source
-- @param citizenId CitizenId
-- @return boolean whether this module has taken the placement over
function M.Offer(source, citizenId)
	source = tonumber(source)
	if not source or source <= 0 then return false end
	if type(citizenId) ~= 'string' or citizenId == '' then return false end
	if not enabled() then return false end

	local catalogue = M.Catalogue()
	if #catalogue == 0 then return false end
	-- One choice at a time. A second offer -- a reconnect inside the window --
	-- leaves the first one standing rather than replacing its deadline.
	if pending[source] ~= nil then return false end

	local life = timeoutMs()
	tokenSeq = tokenSeq + 1
	local token = tokenSeq
	-- `expiresAtMs` is left NIL on purpose: the player's clock has not started,
	-- because the menu is not on screen yet. It starts when the client reports
	-- the menu up -- see `M.Opened` -- which is the whole reason the offer carries
	-- an event of its own. Until then `holdUntilMs` is the only bound, and it is
	-- a bound on the RUNTIME rather than on the player.
	pending[source] = {
		token = token,
		citizenId = citizenId,
		expiresAtMs = nil,
		holdUntilMs = OPX.Now() + holdMs(),
	}

	-- A DURATION, not a deadline. The page counts down to its own clock plus this
	-- number, and that display is presentation of a server number -- the server
	-- counts this same `life` itself, and only its count ends the choice. The two
	-- now agree because both start from the same moment: the menu appearing.
	send(M.Event.OFFER, source, { timeoutMs = life })
	Open77.log.info(('[spawn] %s is choosing a spawn point (%d configured)')
		:format(citizenId, #catalogue))

	-- One thread per outstanding choice. It exits the moment the choice settles,
	-- because `settle` clears the slot -- so a server with nobody choosing holds
	-- no loop for anybody.
	CreateThread(function()
		while true do
			Wait(WATCH_MS)
			local held = pending[source]
			if held == nil or held.token ~= token then return end
			local now = OPX.Now()
			if held.expiresAtMs == nil then
				-- Nobody has the menu up yet. The player's window has not begun, so
				-- the only thing that can run out here is the hold.
				if now >= held.holdUntilMs then
					settle(source, token, nil, 'timeout')
					return
				end
			elseif now >= held.expiresAtMs then
				settle(source, token, nil, 'timeout')
				return
			end
		end
	end)

	return true
end

--- The menu is on screen: the player's window starts now.
-- @author dop42
-- Reported by the client, because only the client knows when the menu became
-- visible -- and it is deliberately not sent the moment the offer arrives, since
-- the menu stands aside while the entry module is asking the same player for a
-- name. See the payload's own comment in module.lua for the measurement that
-- made this necessary.
--
-- A malicious client can call this, and the worst it buys is its own window
-- starting now instead of earlier -- a bound on the INTERVAL, not on the
-- choice, whose coordinates and deadline are still the server's alone to
-- decide. A SECOND report is ignored, so nobody can extend their own window for
-- ever: the first one starts the clock and only the hold can be reached from
-- there.
-- @param source Source
function M.Opened(source)
	local held = pending and pending[source]
	if held == nil then return end
	if held.expiresAtMs ~= nil then return end

	local life = timeoutMs()
	held.expiresAtMs = OPX.Now() + life
	Open77.log.info(('[spawn] %s has the menu up: %d second(s) to choose')
		:format(held.citizenId, math.floor(life / 1000)))
end

--- Handles the click. Every field on the payload is attacker-controlled.
-- @author dop42
-- @param source Source
-- @param payload table
function M.Choose(source, payload)
	if type(payload) ~= 'table' then return end

	local held = pending[source]
	-- The choice is over: placed already, or timed out, or this player was never
	-- offered one. Nothing to do but say so.
	if held == nil then
		OPX.Refuse(source, 'spawn.noChoice', M.Operation.CHOOSE)
		return
	end

	if OPX.Cooling(source, M.Operation.CHOOSE, M.Number(M.Settings.CHOOSE_COOLDOWN_MS, 1000)) then
		OPX.Refuse(source, 'error.tooFast', M.Operation.CHOOSE)
		return
	end

	-- THE LOOKUP. An id this module does not carry -- a typo, or a catalogue the
	-- client invented -- is refused rather than placed, and the menu stays up so
	-- the player can pick again.
	local point = M.Point(payload.id)
	if point == nil then
		OPX.Refuse(source, 'spawn.noChoice', M.Operation.CHOOSE)
		return
	end

	settle(source, held.token, point, 'chosen')
end

--- Whether a choice is outstanding for a player.
-- Read by the diagnostics command and by the tests; nothing else consults it.
-- @author dop42
-- @param source Source
-- @return boolean
function M.IsPending(source)
	return pending ~= nil and pending[tonumber(source)] ~= nil
end

--- Builds the held state.
-- @author dop42
function M.Init()
	pending = {}
	tokenSeq = 0
end

--- Publishes the decision `character` reaches for.
-- @author dop42
-- THE WHOLE SEAM. `character.PlacePending` asks this module, on every join,
-- whether it will take the placement over. It looks the contract up with
-- `OPX.Api.Get('spawn')`, because
-- declaring the dependency both ways is a cycle: `spawn` requires `character`,
-- so `character` cannot require `spawn`.
--
-- Without this phase the two halves are simply never connected: `Get` answers
-- nil, `character` places the body itself and the menu is never seen -- with NO
-- error anywhere, because an absent contract is a legitimate answer. That is
-- what happened the first time this shipped to a live server, and it is why the
-- suite now asserts the contract is published rather than only that `Offer`
-- works when called directly.
function M.Api()
	OPX.Api.Provide('spawn', 1, {
		-- Answers whether this module has taken the placement over. The only
		-- operation `character` needs, and the only one published.
		Offer = M.Offer,
	})
end

--- Resolves the character contract and registers the routeways.
-- @author dop42
function M.Start()
	Character = OPX.Api.Require('character')

	RegisterNetEvent(M.Event.CHOOSE, function(payload)
		local src = tonumber(source)
		if not src then return end
		M.Choose(src, payload)
	end)

	RegisterNetEvent(M.Event.OPENED, function(payload)
		local src = tonumber(source)
		if not src then return end
		M.Opened(src)
	end)

	-- Forget the choice with the player. Nothing is placed: their slot is gone,
	-- and the watcher notices the same way -- by finding no slot to settle.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(rawPlayerId)
		local src = tonumber(rawPlayerId)
		if src then pending[src] = nil end
	end)

	-- Said once, at start, because a spawn module that can never offer anything
	-- has no other symptom at all: every new character simply lands on the
	-- default spawn and nothing in a log says why.
	if not enabled() then
		Open77.log.info('[spawn] the module is switched off: new characters land on the ' ..
			'default spawn')
	elseif #M.Catalogue() == 0 then
		Open77.log.warn('[spawn] no destination is configured: new characters land on the ' ..
			'default spawn')
	end
end

--- Drops every outstanding choice.
-- The world is going away underneath them; nothing here is worth placing.
-- @author dop42
function M.Stop()
	pending = {}
end
