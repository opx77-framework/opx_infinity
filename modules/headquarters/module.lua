--- NCPD and MaxTac headquarters: a marker that says where the station is.
-- @author XEROX710
--
-- A HEADQUARTERS IS A PLACE AND NOTHING MORE. It draws a marker, and while a
-- player stands on it the strip names the place. That is the whole module, and
-- it is deliberately that little: the owner's request was a marker they can
-- configure "like garages, clothing store, dealership" so a server can say
-- WHERE its NCPD and MaxTac headquarters are -- and where the things that go
-- with them (the MaxTac AV pads of `config/avgarages.lua`, the garages, the
-- stores) are placed around them. A designation is a marker and a name; a
-- door, a list or a key would be a second feature wearing this one's clothes.
--
-- THE PLACEMENT PATH IS ONE COMMAND THAT ENDS IN THE CONFIG FILE. Stand where
-- the marker should be and run `/opx.headquarters.add [key] [label]`: the
-- server reads the position (a headquarters has no facing -- nothing is
-- created at one), saves the station, and draws it for everyone at once. The
-- answer prints the line to check into `config/headquarters.lua`, and THAT is
-- the permanent record: the owner deleted the live-config menu on 2026-09-21
-- -- "il y a pas de config live c'est tous par les fichier config" -- because
-- a screen that places things teaches an operator to set a server up somewhere
-- nobody can read afterwards. A capture saved to the database and answered
-- with a line to paste is the opposite of that.
--
-- THE SERVER OWNS THE LIST, and that is not ceremony. A headquarters has a
-- BUCKET like every other placed spot, and a client that read the config file
-- for itself would draw markers in routing buckets it is not in. The client
-- asks, the server answers with the points of the player's own bucket, and the
-- half that draws never decides which places exist.
--
-- The strip is optional: without `prompts` the markers still draw and the
-- command still answers, and only the name row is missing.

local M = OPX.Modules.Declare{
	id = 'headquarters',
	side = 'both',
	-- Not fatal: a server whose headquarters are unnamed is a server with no
	-- markers, which is a choice an operator may make with `enabled = false`.
	fatal = false,
	requires = {},
	optional = { 'prompts' },
}

-- The prefix is disjoint by construction (core/shared/channels.lua): the host
-- dispatcher matches on the name alone, so a local raise on a NET name would
-- re-enter the wire handler registered under it.
local NET = OPX.Channel.NET

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated
	-- connection, and the payload carries nothing at all -- the list is asked
	-- for, never claimed.
	ASK = OPX.Event(NET, 'headquarters', 'ask'),

	-- Server to client: the points of the asker's own routing bucket, ready
	-- for the marker loop.
	SYNC = OPX.Event(NET, 'headquarters', 'sync'),
}

-- The captured stations and the map every reader merges them into. A capture
-- is a headquarters an operator placed in game, kept in the database and
-- merged into `M.Hq.All()` so every reader sees both without knowing which is
-- which -- the same bargain `modules/ripperdoc` makes with its captured
-- chairs.
M.Hq = {}
M.Hq.Captured = {}

--- Replaces the captured list with what is already normalised, sorted so two
-- runs draw the same markers in the same order. The normalising rule is
-- `M.Access.FromDefinition` and it runs at the two doors -- the capture command
-- and the row read back out of the database -- so this is bookkeeping and not
-- a second validator.
-- @param rows table array of spots in the `Serialise` shape
-- @return integer how many were accepted
function M.Hq.SetCaptured(rows)
	local accepted, seen = {}, {}
	for _, spot in ipairs(type(rows) == 'table' and rows or {}) do
		if type(spot) == 'table' and type(spot.key) == 'string' and not seen[spot.key] then
			seen[spot.key] = true
			accepted[#accepted + 1] = spot
		end
	end
	table.sort(accepted, function(a, b) return a.key < b.key end)
	M.Hq.Captured = accepted
	return #accepted
end

--- Every headquarters: the config rows and the captured ones, with a captured
-- spot SHADOWING a config spot of the same key -- a capture is one station
-- moved, not two.
-- @return table key -> spot
function M.Hq.All()
	local merged = {}
	for key, spot in pairs(M.Access.SPOTS) do merged[key] = spot end
	for _, spot in ipairs(M.Hq.Captured) do merged[spot.key] = spot end
	return merged
end

--- The one marker look a headquarters has, and the config slot that names it.
-- One kind, unlike garages: a station is a station, and a per-kind table of one
-- entry would be a choice a later author reads as a place to add a second.
M.SLOT = { HQ = 'hq' }
