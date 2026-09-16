--- The key strip: "press this to do that", posted by whoever has something to say.
-- @author dop42
--
-- It decides nothing about the game and holds nothing but what it was asked to
-- draw. A caller posts a group of rows, and this module orders them, names every
-- key with the player's own binding, cuts the strip to the row budget, drops a
-- group whose owner stopped, and takes the strip down while the keyboard is held
-- elsewhere, while the HUD is off, or while the player is down.
--
-- The owner is an ARGUMENT and not a discovered identity. The old resource read
-- `GetInvokingResource()`, which a caller could not forge; inside one runtime a
-- caller is a module calling a function, so the name it gives is a label for
-- grouping and expiry, not a boundary. Two owners may each hold a group called
-- `main` without touching each other, which is the only property that mattered.
--
-- `downed` and `hud` are optional: without either, the strip simply never steps
-- aside for them.

local M = OPX.Modules.Declare{
	id = 'prompts',
	side = 'both',
	fatal = false,
	optional = { 'downed', 'hud' },
}

-- Server to client, one player at a time. The server runtime has no key strip
-- of its own, so every server-side operation is one of these four.
M.Event = {
	SHOW = OPX.Event(OPX.Channel.NET, 'prompts', 'show'),
	UPDATE = OPX.Event(OPX.Channel.NET, 'prompts', 'update'),
	HIDE = OPX.Event(OPX.Channel.NET, 'prompts', 'hide'),
	HIDE_ALL = OPX.Event(OPX.Channel.NET, 'prompts', 'hideAll'),
}

-- What a server-sent owner is stored under. `@` is outside the characters an
-- owner name is validated against, so a group sent from the server can never
-- reach a client owner's groups, nor a client owner a server-sent one.
M.SERVER_PREFIX = '@server:'
