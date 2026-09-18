--- The board: one target row, and one mappin, at every gig's starting point.
-- @author dop42
--
-- Registered once at start and left alone. A sphere row costs nothing until the
-- ray lands inside it, so there is no loop here following the player around --
-- the eye already does that, and it does it for every owner at once.
--
-- The row is drawn from the same reading of `config/gigs.lua` the server pays
-- from, so a row offered here is a gig the server admits exists. What it does NOT
-- do is decide whether the player may take it: the cooldown, the daily count and
-- the reputation are all on the character, the server holds the character, and a
-- client that greyed the row out would be guessing. The row is always offered and
-- the refusal comes back as a sentence that says which of the three it was.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog
local Run = M.Run

M.Board = {}
local Board = M.Board

local OWNER = M.OWNER

-- Tokens of the rows this file registered, and the mappins it drew.
local tokens = {}
local pins = {}

-- Whether the mappins failed. Said once: without `ui.vanilla.map` every call
-- refuses, and one line per gig is a log nobody reads.
local pinsOff = false

-- Puts a mappin on a gig's starting point.
local function drawPin(gig)
	if M.Settings.BLIPS == false or pinsOff then return end
	local blips = Open77.blips
	if type(blips) ~= 'table' or type(blips.create) ~= 'function' then
		pinsOff = true
		return
	end
	local made, id = pcall(blips.create, {
		position = { x = gig.start.x, y = gig.start.y, z = gig.start.z },
		label = gig.label,
		routable = true,
		active = true,
	})
	if made and type(id) == 'string' and id ~= '' then
		pins[#pins + 1] = id
		if type(blips.setDescription) == 'function' and gig.description ~= nil then
			pcall(blips.setDescription, id, gig.description)
		end
		return
	end
	pinsOff = true
	Open77.log.info('[gigs] no mappin was drawn for the board (ui.vanilla.map): the gigs are ' ..
		'found by walking into them')
end

-- Registers one gig's row inside a sphere at its starting point.
local function drawRow(target, gig)
	local registered = target.RegisterSpheres(OWNER,
		{ { x = gig.start.x, y = gig.start.y, z = gig.start.z, radius = gig.radius } },
		{
			id = 'gigs.take.' .. gig.id,
			label = locale('gigs.board.take', { gig = gig.label }),
			description = gig.description,
			icon = gig.icon,
			distance = gig.reach,
			-- Not "may they": "is there any point offering it". A player already on
			-- a run has one row that matters and it is the leg's.
			canInteract = function() return not Run.Working() and not Run.IsDown() end,
			onSelect = function() Run.Take(gig.id) end,
			-- Work: taking a gig on.
			order = 41,
		})
	if not registered.ok then
		Open77.log.warn(('[gigs] the board row of %s was not registered: %s')
			:format(gig.id, tostring(registered.error)))
		return
	end
	tokens[#tokens + 1] = registered.value.token
end

--- Clears what this file holds. Called from `Init`.
-- @author dop42
function Board.Init()
	tokens, pins, pinsOff = {}, {}, false
end

--- Draws every enabled gig's row and mappin.
-- @author dop42
function Board.Start()
	local gigs = Catalog.List()
	if #gigs == 0 then return end

	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterSpheres) ~= 'function' then
		Open77.log.warn('[gigs] no target contract: no gig can be taken from the world. The board ' ..
			'is readable with the list command and nothing else')
		return
	end

	for index = 1, #gigs do
		local gig = gigs[index]
		local drawn, failure = pcall(drawRow, target, gig)
		if not drawn then
			Open77.log.error(('[gigs] the board row of %s raised: %s')
				:format(gig.id, tostring(failure)))
		end
		drawPin(gig)
	end
end

--- Takes every row and mappin this file drew back down.
-- @author dop42
function Board.Shutdown()
	local target = OPX.Api.Get('target')
	if target ~= nil and type(target.Unregister) == 'function' then
		for index = 1, #tokens do pcall(target.Unregister, OWNER, tokens[index]) end
	end
	tokens = {}

	local blips = Open77.blips
	if type(blips) == 'table' and type(blips.remove) == 'function' then
		for index = 1, #pins do pcall(blips.remove, pins[index]) end
	end
	pins = {}
end
