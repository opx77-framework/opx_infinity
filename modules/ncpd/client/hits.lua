--- The hit relay's client half: the host's `open77:npcHit`, forwarded to the server.
-- @author XEROX710
--
-- WHY THIS FILE EXISTS. When the local player's shot lands on an NPC the platform
-- raises `open77:npcHit(npcId, damage, hitZ, weaponTdbId, attackKind)` on THIS
-- client and carries it no further: the server never learns of the hit, so a
-- server-owned officer or crowd body never loses a point of health there and
-- never dies. The server half (`server/hits.lua`) is what admits and prices a
-- report; this half only makes one. The full argument is in that file's header.
--
-- A LOCAL EVENT, SO `AddEventHandler` AND NOT `RegisterNetEvent`. The host raises
-- this one on the client that fired the shot; `RegisterNetEvent` listens to the
-- server-to-client channel, which nothing ever publishes it on. The platform's own
-- cordon mode shipped that exact mistake and a player could empty a magazine into
-- a bot with nothing happening anywhere (`resources/gamemodes/open77_cordon`).
--
-- EVERY ARGUMENT ARRIVES AS TEXT, AND THE BODY'S ID STAYS TEXT. A 64-bit id does
-- not survive a Lua double past 2^53, so it is forwarded exactly as it arrived and
-- never passed through `tonumber`. The damage and the intercept height are numbers.
--
-- COALESCED, NOT CHATTY. A shotgun fires a pellet per report and a rifle ten a
-- second; the reports for one body inside a tenth of a second are summed into one
-- (the height is their mean) and sent together, so the wire carries at most ten
-- small tables a second per body and the server's cadence gate never meets a
-- burst. Nothing here is trusted by the server for the number it carries.

local M = OPX.Modules.Get('ncpd')

M.Hits = {}
local Hits = M.Hits

--- How long reports gather before they are sent, and how many bodies one send
--- carries. A player who shoots more bodies than that in a tenth of a second is
--- not playing the game; the rest wait for the next send.
local FLUSH_MS = 100
local MAX_BODIES = 8

--- The most bodies held waiting. A full table drops new bodies, never old ones.
local MAX_PENDING = 32

--- One row per body waiting, in the order it was first hit.
local pending = {}
local order = {}

--- How many reports have gone out, and when the last line was written about one.
local sent = 0
local spoke = 0

--- Bumped by `Start`, so a loop from an earlier start stands down.
local generation = 0

--- Whether the host event is subscribed: `Start` runs again on a restart and a
--- second handler would double every report.
local subscribed = false

--- A finite number, or nil.
-- @param value any
-- @return number|nil
local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return number
end

--- Notes one hit. Called from the host's event, so it is cheap and never raises.
-- @param npcId any as the host spelled it
-- @param damage any the engine's number
-- @param hitZ any the intercept's absolute height
-- @param weapon any the weapon's TweakDB id as text
-- @return boolean whether the hit is waiting to be sent
function Hits.Record(npcId, damage, hitZ, weapon)
	if npcId == nil then return false end
	local key = tostring(npcId)
	if key == '' or #key > 32 then return false end

	local row = pending[key]
	if row == nil then
		if #order >= MAX_PENDING then return false end
		row = { npcId = key, damage = 0.0, heights = 0.0, samples = 0, weapon = weapon, hits = 0 }
		pending[key] = row
		order[#order + 1] = key
	end

	local number = finite(damage)
	if number ~= nil and number > 0 then row.damage = row.damage + number end
	local height = finite(hitZ)
	if height ~= nil then
		row.heights = row.heights + height
		row.samples = row.samples + 1
	end
	row.hits = row.hits + 1
	return true
end

--- Sends what has gathered: one report per body.
-- @return integer how many reports went out
function Hits.Flush()
	if #order == 0 then return 0 end

	local count = math.min(#order, MAX_BODIES)
	local keys = {}
	for index = 1, count do keys[index] = order[index] end
	local rest = {}
	for index = count + 1, #order do rest[#rest + 1] = order[index] end
	order = rest

	for _, key in ipairs(keys) do
		local row = pending[key]
		pending[key] = nil
		if row ~= nil then
			sent = sent + 1
			TriggerServerEvent(M.Event.NPC_HIT, {
				npcId = row.npcId,
				damage = row.damage > 0 and row.damage or nil,
				hitZ = row.samples > 0 and row.heights / row.samples or nil,
				weapon = row.weapon,
				seq = sent,
			})
		end
	end

	-- One line every few seconds, so the client log shows the relay is carrying
	-- hits without a line per bullet.
	local now = OPX.Now()
	if now - spoke >= 5000 then
		spoke = now
		Open77.log.info(('[ncpd] hit relay: %d report(s) sent to the server so far'):format(sent))
	end
	return count
end

--- What has gone out, for the status probe and the tests.
-- @return table `{ sent, waiting }`
function Hits.Status()
	return { sent = sent, waiting = #order }
end

--- Subscribes to the host's event and starts the send loop.
function Hits.Start()
	generation = generation + 1
	local mine = generation
	Hits.running = true

	if not subscribed then
		subscribed = true
		AddEventHandler('open77:npcHit', function(npcId, damage, hitZ, weaponTdbId)
			-- A stopped relay holds nothing: the handler outlives `Stop` (the host
			-- has no way to take one away), and a hit kept through the stop would
			-- go to the server, minutes stale, on the next start.
			if not Hits.running then return end
			pcall(Hits.Record, npcId, damage, hitZ, weaponTdbId)
		end)
	end

	CreateThread(function()
		while Hits.running and mine == generation do
			Wait(FLUSH_MS)
			pcall(Hits.Flush)
		end
	end)
end

--- Stops the loop and forgets what was waiting: a hit that was never sent belongs
--- to a session that is over.
function Hits.Stop()
	Hits.running = false
	generation = generation + 1
	pending = {}
	order = {}
end
