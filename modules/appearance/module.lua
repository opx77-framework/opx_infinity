--- The character's face, the clothes it wears, the looks other players are sent,
--- and the one announcement that lets anybody into the world.
-- @author dop42
--
-- FATAL, and not for the usual reason. Every joining player carries a hold named
-- `__platform` on the readiness gate that no Lua may take or release and that has
-- no deadline. It clears on exactly one thing: a client announcing
-- `open77:session:gameplayReady`. This module is what sends it. Without it the
-- loading cover never lifts, no world loads, no gate ever opens and nobody sees
-- anybody else's body. It also spends the one-shot character bootstrap at join,
-- which is what decides the body the world loads with.
--
-- Two ideas run through the whole module.
--
-- 1. A FACE IS NOT A MESH. A snapshot is a list of positions in the engine's
--    customization catalogue -- for each option, which index the player chose --
--    so it only means anything against the catalogue it was captured on. A face
--    from another game build is refused, never applied: applying it would put a
--    different face on the puppet rather than failing.
-- 2. A FUNCTION THAT YIELDS MUST BE ABLE TO GIVE UP. Every restore, every editor
--    and every publication carries a generation token, and a thread holding an
--    older one stops instead of finishing work for a character that has gone.
--
-- The body family is NOT chosen by a form. The engine's own character creator
-- asks for it and builds the face in the same flow, and what it answers is
-- written once to `charInfo.gender` on the character row; from then on this
-- module only reloads the world onto it. That is also why `gender` inside a
-- snapshot is something else entirely: the engine's opaque 64-bit body hash,
-- never the female/male string.

local M = OPX.Modules.Declare{
	id = 'appearance',
	side = 'both',
	-- Every face and every clothing record is keyed on the citizen id, and only
	-- the character module knows which character a player has loaded.
	requires = { 'character' },
	fatal = true,
}

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua): the
-- host dispatcher matches on the name alone, so a local `TriggerEvent` on a NET
-- name would re-enter the `RegisterNetEvent` handler of that name.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL
local INTERNAL = OPX.Channel.INTERNAL

M.Event = {
	-- Client to server. Every payload is attacker-controlled; only `source` is not.
	SAVE_FACE = OPX.Event(NET, 'appearance', 'saveFace'),
	SAVE_CLOTHING = OPX.Event(NET, 'appearance', 'saveClothing'),
	PRESENT = OPX.Event(NET, 'appearance', 'present'),
	ABSENT = OPX.Event(NET, 'appearance', 'absent'),
	REPLAY = OPX.Event(NET, 'appearance', 'replay'),
	DIAGNOSTIC = OPX.Event(NET, 'appearance', 'diagnostic'),

	-- Server to client.
	FACE_SAVED = OPX.Event(NET, 'appearance', 'faceSaved'),
	CLOTHING_SAVED = OPX.Event(NET, 'appearance', 'clothingSaved'),
	REFUSED = OPX.Event(NET, 'appearance', 'refused'),
	PRESENT_ACK = OPX.Event(NET, 'appearance', 'presentAck'),
	REPLAYED = OPX.Event(NET, 'appearance', 'replayed'),
	LOOK = OPX.Event(NET, 'appearance', 'look'),
	RESEND = OPX.Event(NET, 'appearance', 'resend'),

	-- The client's own bus. `decision` is what this module says after every
	-- decision it reaches, and is public: a bare AddEventHandler listens to it.
	-- `view` is the seam a view module attaches to; see client/wardrobe.lua.
	ON_DECISION = OPX.Event(LOCAL, 'appearance', 'decision'),
	ON_VIEW = OPX.Event(LOCAL, 'appearance', 'view'),

	-- Between modules inside one VM. Never crosses the wire.
	IN_FACE = OPX.Event(INTERNAL, 'appearance', 'face'),
	IN_CLOTHING = OPX.Event(INTERNAL, 'appearance', 'clothing'),
}

--- Host-owned names this module listens to, or raises at the host.
-- `OPX.Host` lists the ones core uses; these belong to the appearance, session
-- and shell services, and are listed once here so a typo is a nil index.
M.HostEvent = {
	CONFIRMED = 'open77:appearance:confirmed',
	CANCELLED = 'open77:appearance:cancelled',
	RESTORE_FAILED = 'open77:appearance:restore_failed',
	RESET_COMPLETE = 'open77:playerReset:complete',
	SHELL_HIDE = 'open77:shell:hide',
	BUCKET_CHANGE = 'onPlayerBucketChange',
}

--- Which request a refusal answers.
-- Without it a client waiting on a face save and a clothing save at once cannot
-- tell which refusal is whose.
M.Operation = {
	SAVE_FACE = 'appearance.saveFace',
	SAVE_CLOTHING = 'appearance.saveClothing',
}

--- The platform's own appearance package.
-- It spends the same one-shot bootstrap, stores its own clothing and hands out
-- its own looks, so both halves of this module stand down while it runs rather
-- than fighting it over the same puppet.
M.OFFICIAL = 'open77_appearance'

-- The two body families the engine and `charInfo.gender` know. Both halves read
-- this, so a family one accepts and the other refuses cannot happen.
local FAMILIES = { female = true, male = true }

--- Whether a value names one of the two body families.
-- @author dop42
-- @param value any
-- @return boolean
function M.IsFamily(value)
	return type(value) == 'string' and FAMILIES[value] == true
end

--- Whether a stored face from this game build may be read back.
-- @author dop42
-- @param value any
-- @return boolean
function M.BuildAccepted(value)
	local builds = M.Settings.GAME_BUILDS
	return type(value) == 'string' and type(builds) == 'table' and builds[value] == true
end

--- Reads a configured duration, nil when it is not a finite non-negative number.
-- Every deadline in this module goes through it, so a setting somebody emptied
-- falls back to the shipped value rather than freezing a wait for ever: an
-- infinity passes every `<` a plain guard would write.
-- @author dop42
-- @param value any
-- @return number|nil
function M.ConfigMs(value)
	local wait = tonumber(value)
	if not OPX.Math.IsFinite(wait) or wait < 0 then return nil end
	return wait
end
