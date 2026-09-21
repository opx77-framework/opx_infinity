--- Teleports: operator-placed shortcuts to the parts of Night City you cannot
--- walk to, some of them locked to a job.
-- @author dop42
--
-- THE MOTIVE IS TRAVERSAL. Cyberpunk's map has rooftops with no stair,
-- mezzanines whose lift is set dressing and interiors the single-player game
-- enters through a cutscene. A server whose players can only use what they can
-- walk to loses those places entirely. The job lock is the second feature and
-- not the first: it is what lets a rooftop belong to somebody.
--
-- THE SERVER DECIDES, and the shape of this module is that sentence. The client
-- draws a marker where it was told, posts a row while the player stands on one,
-- and sends a KEY AND A LEG -- never a coordinate. The server looks that key up
-- in its own copy of `config/teleports.lua`, re-derives the job gate, re-reads
-- the player's own position and bucket from the host, and only then asks the
-- platform to move the body. A client that hides a prompt has hidden a prompt;
-- it has not passed a gate, and this module never treats the two as the same
-- thing. `modules/elevators` refuses a floor the same way and for the same
-- reason.
--
-- MOVING THE BODY IS THE PLATFORM'S JOB. `Open77.players.teleport` is the
-- server-side native for exactly this: it changes the bucket first, fades,
-- moves, and then WATCHES the client until the body is on the point, grounded
-- and not falling for three consecutive frames -- re-issuing the move every
-- 250 ms while the destination streams in. Nothing here poks a position, and
-- nothing here assumes the move took: the promise it answers is awaited, and a
-- trip that does not arrive is reported as one. See the server half for what
-- happens then.
--
-- WHAT IT DOES NOT DO. It persists nothing -- a teleport is a place an operator
-- wrote in a file, not a thing a player owns -- and it draws no interface of its
-- own: the marker is the platform's, the row is `prompts`', and the answer is a
-- toast. `character` is required, because a job gate with no character to read
-- is not a gate. `prompts` and `downed` are optional: without the first there is
-- no row and the key still works, and the second only adds a refusal.

local M = OPX.Modules.Declare{
	id = 'teleports',
	side = 'both',
	-- Not fatal. A server with no teleports is a server where players walk, and
	-- that is a choice an operator makes with `enabled = false` -- or simply by
	-- never surveying a point.
	fatal = false,
	requires = { 'character' },
	optional = { 'prompts', 'downed' },
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
	--
	-- ASK carries nothing at all: a list is asked for, never claimed. USE carries
	-- a key and a leg and nothing else -- no position, no destination, nothing a
	-- client could invent that the server would then act on.
	ASK = OPX.Event(NET, 'teleports', 'ask'),
	USE = OPX.Event(NET, 'teleports', 'use'),

	-- Server to client: the entrances of this player's own routing bucket, each
	-- already marked allowed or refused, and the verdict on one trip.
	SYNC = OPX.Event(NET, 'teleports', 'sync'),
	ANSWER = OPX.Event(NET, 'teleports', 'answer'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'teleports', 'decision'),
}

--- The host raises this when a player rebinds or resets a mapping.
M.KEYBINDS_CHANGED = 'onKeybindsChanged'

--- The two directions a teleport can be taken in.
-- `OUT` is ENTRY -> EXIT and is the leg the job gate guards. `BACK` is
-- EXIT -> ENTRY, exists only when the operator wrote `RETURN = true`, and is
-- never gated: see the long note in `config/teleports.lua` about not stranding
-- somebody on the far side of their own revoked job.
M.Leg = { OUT = 'out', BACK = 'back' }
