--- Where a brand new character starts: the catalogue, and the one thing it owns.
-- @author dop42
--
-- WHAT THIS MODULE OWNS, and nothing else does: the list of places a player may
-- start, the choice a player makes between them, and the deadline that ends a
-- choice nobody makes. It does NOT own placement. `character` does, and always
-- has -- a placement is a kill followed by a respawn, and the gate, the buckets,
-- the fade and the stored-position rule all live on that side of the seam. So
-- this module decides WHERE and `character` performs the move:
--
--   character.PlacePending   ->  spawn.Offer(source, citizenId)
--   the player clicks        ->  the wire -> spawn's server half
--   spawn                    ->  character.PlaceCharacter(player, point)
--
-- The dependency runs that way round and deliberately not the other: `spawn`
-- requires nothing, and `character` reaches for this module through
-- `OPX.Api.Get('spawn')` at the moment it needs it. Declaring the dependency in
-- both directions would be a cycle, which the registry refuses at boot.
--
-- WHY THE CATALOGUE IS SHARED RATHER THAN SENT. `config/` is a shared script, so
-- both halves already hold the same list, and the server is still the only
-- authority on it: a client sends the ID of a spot and the server looks that ID
-- up in its own copy for the coordinates. Sending the whole list down the wire
-- would be the same data twice, and the page would then be able to draw a spot
-- the server has never heard of.

local M = OPX.Modules.Declare{
	id = 'spawn',
	side = 'both',
	-- Not fatal. A world with no spawn module is a world whose new characters
	-- land on `character.DEFAULT_SPAWN`, which is exactly the behaviour before
	-- this module existed.
	fatal = false,
}

local NET = OPX.Channel.NET

--- Every event name this module puts on the wire.
-- NET only, all three of them: this module has no public local bus and no
-- intra-VM channel, because nothing else needs to watch a spawn choice being
-- made. The host dispatcher matches on the name alone, so a verb repeated across
-- channels would be a re-entrant handler; there is one channel here, so there is
-- nothing to keep apart.
M.Event = {
	-- Server to client. "Pick one, and you have this many milliseconds."
	OFFER = OPX.Event(NET, 'spawn', 'offer'),
	-- Server to client. The choice is over, whichever way it ended, and every
	-- reason the menu comes down arrives on this one name with a reason on it.
	-- A second name per outcome would be four handlers on the page for one view.
	CLOSE = OPX.Event(NET, 'spawn', 'close'),
	-- Client to server. Every payload on it is attacker-controlled; only
	-- `source` is not, and the id is looked up rather than trusted.
	CHOOSE = OPX.Event(NET, 'spawn', 'choose'),
	-- Client to server. "The menu is on screen now." THIS IS WHAT STARTS THE
	-- COUNTDOWN, and it exists because the choice is deliberately deferred while
	-- the entry module is asking its own question -- a brand new character is
	-- asked for a name and a spawn at the same moment, and two modals on one
	-- keyboard is one modal losing its focus.
	--
	-- Without it the server counts from the moment the offer was QUEUED, which is
	-- before anybody can see anything: measured on the live server, the offer was
	-- queued at 16:09:33 and the name form was answered at 16:10:14, so a
	-- forty-five second window left the player four seconds of menu -- and a form
	-- that ran a little longer than the window left them none at all. The window
	-- is the player's time to CHOOSE, so it starts when there is something to
	-- choose from.
	OPENED = OPX.Event(NET, 'spawn', 'opened'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`, whose channel is core's: without it a client waiting on
-- one of several requests cannot tell which `error.tooFast` is its own.
M.Operation = {
	CHOOSE = 'spawn',
}

-- Bounds on one configured entry. The catalogue is authored by hand, so these
-- exist to catch a typo rather than an attacker -- but a bad entry is skipped
-- rather than fatal, because losing the menu is not worth losing the world.
local MAX_LOCATIONS = 64
local MAX_ID = 32
local MAX_LABEL = 48
local MAX_DISTRICT = 32

-- The catalogue, built once on first use and shared by both accessors below.
local points
local byId

--- Whether a value is a bounded identifier.
-- The same shape `form` accepts for a field id, and for the same reason: an id
-- crosses the wire as a bare string and is used as a table key on both sides.
-- @param value any
-- @param maximum integer
-- @return boolean
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Normalises one configured entry, or answers nil.
-- @param raw any
-- @param index integer
-- @return table|nil
local function normalize(raw, index)
	if type(raw) ~= 'table' then return nil end

	local id = raw.id
	if not validName(id, MAX_ID) then
		Open77.log.warn(('[spawn] location %d has no usable id and is dropped'):format(index))
		return nil
	end

	local label = raw.label
	if type(label) ~= 'string' or label == '' or #label > MAX_LABEL then
		Open77.log.warn(('[spawn] location %s has no usable label and is dropped'):format(id))
		return nil
	end

	-- The district is the hint line under the label. A spot without one is still
	-- a place to stand, so it keeps the empty string rather than being dropped.
	local district = raw.district
	if type(district) ~= 'string' or #district > MAX_DISTRICT then district = '' end

	-- NaN and infinity both fail this, and a coordinate that is neither of those
	-- but not a number would otherwise ride all the way into a respawn request.
	local x, y, z = tonumber(raw.x), tonumber(raw.y), tonumber(raw.z)
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		Open77.log.warn(('[spawn] location %s has no finite position and is dropped'):format(id))
		return nil
	end

	-- A heading that is missing or not finite is 0.0 rather than a dropped spot:
	-- the value is a facing, and north is a facing.
	local heading = tonumber(raw.heading)
	if not OPX.Math.IsFinite(heading) then heading = 0.0 end

	return {
		id = id,
		label = label,
		district = district,
		x = x,
		y = y,
		z = z,
		heading = heading,
	}
end

--- Builds the catalogue from the configuration, once.
local function build()
	if points ~= nil then return end
	points, byId = {}, {}

	local raw = M.Settings.LOCATIONS
	if type(raw) ~= 'table' then
		Open77.log.warn('[spawn] no LOCATIONS are configured: every new character ' ..
			'lands on the default spawn')
		return
	end

	for index = 1, #raw do
		if #points >= MAX_LOCATIONS then
			Open77.log.warn(('[spawn] more than %d locations are configured: the rest ' ..
				'are ignored'):format(MAX_LOCATIONS))
			break
		end
		local point = normalize(raw[index], index)
		if point ~= nil then
			-- Two spots with one id would make the choice ambiguous: the wire
			-- carries the id alone, so the second would be unreachable.
			if byId[point.id] ~= nil then
				Open77.log.warn(('[spawn] location %s is configured twice: the second ' ..
					'is ignored'):format(point.id))
			else
				points[#points + 1] = point
				byId[point.id] = point
			end
		end
	end

	if #points == 0 then
		Open77.log.warn('[spawn] every configured location was unusable: every new ' ..
			'character lands on the default spawn')
	end
end

--- Every usable location, in configured order.
-- The list belongs to this module and is handed out rather than copied: a caller
-- that reorders or edits it changes where players spawn for everybody.
-- @author dop42
-- @return table[]
function M.Catalogue()
	build()
	return points
end

--- One location by id, or nil.
-- THE lookup the server does for every choice, and the only reason the wire can
-- carry a bare id: the coordinates come from here and never from the client.
-- @author dop42
-- @param id any
-- @return table|nil
function M.Point(id)
	build()
	if type(id) ~= 'string' then return nil end
	return byId[id]
end

--- Whether there is anything to choose between.
-- Answers false for a configuration with no usable entry, which is the whole of
-- what makes this module stand down and let `character` place directly.
-- @author dop42
-- @return boolean
function M.HasPoints()
	return #M.Catalogue() > 0
end

--- Reads a configured number with a floor.
-- The floor is also the answer for a setting that is missing or not finite, so no
-- caller ever compares a number against nil. The test is finiteness and not a NaN
-- test: an infinity passes `value ~= value` and would freeze an interval.
-- @author dop42
-- @param value any
-- @param floor number
-- @return number
function M.Number(value, floor)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return floor end
	if floor and value < floor then return floor end
	return value
end
