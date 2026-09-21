--- The gunsmith: job-gated armouries, each with a bench and a chest.
-- @author dop42
--
-- WHAT THIS MODULE OWNS, AND IT IS A SHORT LIST: who may work an armoury, where
-- its two pieces of furniture stand, and what it makes. Everything else is
-- somebody else's and is reached through a contract:
--
--   the bench   `crafting` -- this module registers one per armoury, hands over
--               the recipe list and a gate, and never sees an order again
--   the chest   `inventory` -- a STASH with a position, opened through
--               `OpenStash`. There is no container code here and there must
--               never be any: `config/inventory.lua` already says a stash NAME
--               is a storage key that must never be reused
--   the rows    `target` -- two spheres per armoury, one on each piece
--
-- SO THIS MODULE IS THE FIRST CONSUMER OF `crafting`, AND THAT IS ITS OTHER
-- JOB. A shared abstraction with no real consumer is an abstraction that fits
-- nothing; this one exists partly to prove the crafting contract can be used
-- without crafting knowing anything about a gunsmith. It knows nothing: the
-- word "job" does not appear in `modules/crafting/`, and the grade a recipe
-- asks for is read here, out of this module's own config, in answer to a
-- question crafting asks as `canUse(player, recipe)`.
--
-- THE GATE AGREES WITH `modules/elevators/shared/access.lua` AND SAYS SO. The
-- same MEMBERSHIP words, the same JOB_MAX_AGE_MS staleness bound, the same
-- refusal vocabulary and -- the part that matters -- the same fail direction: a
-- gated place is SHUT when the character read is missing or stale, and an
-- ungated one stays OPEN whatever happens to that read. A second answer to
-- "what does a broken roster do to a door" would be a second thing to reason
-- about at three in the morning.

local M = OPX.Modules.Declare{
	id = 'gunsmith',
	side = 'both',
	-- Not fatal: a runtime with no armouries is a runtime where nobody can make
	-- ammunition, which is a missing feature and not a broken server.
	fatal = false,
	-- `crafting` for the bench, `character` for the job the gate reads. Both
	-- required: without either, every armoury would be a place that refuses
	-- everybody, which is worse than a place that is not there.
	requires = { 'crafting', 'character' },
	-- `inventory` for the chest and `target` for the rows. Optional, and the two
	-- degrade differently: without the eye the armoury is unreachable, and
	-- without the inventory the bench still works and the chest does not open.
	optional = { 'inventory', 'target' },
}

local NET = OPX.Channel.NET

M.Event = {
	-- Client to server. "I am at this armoury and I want its chest." The server
	-- re-reads the job and the inventory module re-measures the distance: a
	-- client can ask from anywhere.
	CHEST = OPX.Event(NET, 'gunsmith', 'chest'),

	-- Server to client. The chest could not be opened, and why.
	REFUSED = OPX.Event(NET, 'gunsmith', 'refused'),
}

--- The prefix every bench key this module registers carries.
--
-- A BENCH KEY IS A DATABASE COLUMN VALUE, which is the whole reason it is
-- namespaced and the whole reason this constant exists rather than being spelt
-- at the two sites that build one. Orders are filed under it, so the day a
-- second module wants a bench called `workshop` must not be the day this one's
-- orders start resolving to somebody else's recipes -- and the day somebody
-- shortens the prefix is the day every order already on a shelf is orphaned.
M.BENCH_PREFIX = 'gunsmith:'
