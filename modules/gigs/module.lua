--- Petits boulots: the day work a character can do the hour they arrive.
-- @author dop42
--
-- NOT A JOB, and the distinction is the whole design. `SetJob` is never called,
-- no grade is written and no duty clock runs. A gig is a RUN: a short list of
-- legs the server builds when the player takes it, hands out one at a time, and
-- pays for when they are done. Someone who has just made a character can walk to
-- an alley, hold the target key and earn their first eddies without anyone
-- giving them anything.
--
-- WHY THE SERVER HOLDS THE ROUTE. The client is told the leg it is standing at
-- and nothing else: not the next point, not how many are left in the pool, not
-- the payout. A client that knew the whole route could walk it in one straight
-- line with no eye and no animation, and the only thing stopping it would be a
-- number it also holds. Every leg is re-checked from the server's own snapshot
-- of where the player is.
--
-- `character` is required: a gig pays a character, the counters are kept on the
-- character's metadata, and there is nothing to run for a connection that holds
-- none. Everything else is optional and degrades rather than failing --
-- `inventory` only carries the bonus item, `animations` only makes the action
-- look like something, `prompts` only draws the abandon key, `downed` only keeps
-- a run from advancing off the floor.

local M = OPX.Modules.Declare{
	id = 'gigs',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'target', 'inventory', 'animations', 'prompts', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection
	-- and never from the payload.
	TAKE = OPX.Event(NET, 'gigs', 'take'),
	WORK = OPX.Event(NET, 'gigs', 'work'),
	QUIT = OPX.Event(NET, 'gigs', 'quit'),

	-- Server to client. LEG carries the one leg the player is standing at;
	-- ENDED closes a run, paid or not; ANSWER is a refusal with nothing else to
	-- say.
	LEG = OPX.Event(NET, 'gigs', 'leg'),
	ENDED = OPX.Event(NET, 'gigs', 'ended'),
	ANSWER = OPX.Event(NET, 'gigs', 'answer'),

	-- The client's own bus, public: a bare AddEventHandler reaches it. A HUD or
	-- a third-party resource watching the run listens here and never to the wire
	-- events above.
	ON_CHANGED = OPX.Event(LOCAL, 'gigs', 'changed'),
}

--- What the character module raises locally when a character comes and goes.
M.CHARACTER = {
	LOADED = OPX.Event(LOCAL, 'character', 'loaded'),
	UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded'),
}

--- What `downed` raises when the player goes down or gets back up.
M.DOWNED_CHANGED = OPX.Event(LOCAL, 'downed', 'changed')

--- The name both halves register their target rows and prompts under. It is the
--- module id, and the target registry reads a module id as an owner that is
--- always live.
M.OWNER = 'gigs'
