--- Emotes and animations: the commands, the picker and the animation contract.
-- @author dop42
--
-- This module is NOT the authority on what plays. The platform's animation
-- service owns every playback, replicates it to the bucket, and refuses a dead
-- player, a player in a vehicle or a second animation over another owner's, on
-- its own. All this module decides is what it ASKS the service for: the
-- catalogue as config leaves it, a per-player rate and a readiness gate. It
-- provides no animation of its own and writes nothing to the database.
--
-- `downed`, `menu`, `form` and `prompts` are optional. Without `menu` there is no
-- picker and the commands and the contract still work; without `form` the picker
-- keeps every screen and loses only its search box; without `prompts` the
-- stop key is simply not drawn; without `downed` the picker never closes itself.
-- Each absence costs one logged line and nothing else.

local M = OPX.Modules.Declare{
	id = 'animations',
	side = 'both',
	fatal = false,
	optional = { 'downed', 'menu', 'form', 'prompts' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
M.Event = {
	-- Client to server. Every payload is a claim by the player; only `source` is
	-- not.
	PLAY = OPX.Event(NET, 'animations', 'play'),
	STOP = OPX.Event(NET, 'animations', 'stop'),
	HELLO = OPX.Event(NET, 'animations', 'hello'),

	-- Server to client.
	OFFER = OPX.Event(NET, 'animations', 'offer'),
	ANSWER = OPX.Event(NET, 'animations', 'answer'),
	CANCEL = OPX.Event(NET, 'animations', 'cancel'),
	PICKER = OPX.Event(NET, 'animations', 'picker'),

	-- The client's own bus. Public: a bare AddEventHandler reaches these.
	ON_RESULT = OPX.Event(LOCAL, 'animations', 'result'),
	ON_CHANGED = OPX.Event(LOCAL, 'animations', 'changed'),
	ON_FAILED = OPX.Event(LOCAL, 'animations', 'failed'),
}

--- The platform's own animation wire, observed in its client and undocumented.
-- These names belong to the service and may not be renamed or re-channelled:
-- the host refuses them from anything but the server, which is what stops a
-- neighbouring resource forging a playback state.
M.Wire = {
	STATE = 'open77:animations:state',
	SNAPSHOT = 'open77:animations:snapshot',
	RESULT = 'open77:animations:result',
	SYNC = 'open77:animations:sync',
	STOP = 'open77:animations:stopRequest',
}

--- The host raises this when a player rebinds or resets a key mapping.
M.KEYBINDS_CHANGED = 'open77:keybinds:changed'

--- The platform package whose client poses bodies instead, while it runs.
M.OFFICIAL = 'open77_animations'

--- Longest step duration the platform service accepts on the wire.
M.SERVICE_MAX_MS = 600000

--- Shortest duration a request may name: under a second a clip reads as a tic.
M.MIN_DURATION_MS = 1000

--- Largest request serial a client may send.
M.MAX_REQUEST_ID = 2147483647
