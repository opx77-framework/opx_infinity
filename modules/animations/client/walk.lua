--- Walking while an emote plays, and giving the ability back.
-- @author dop42
--
-- WHAT THE PLATFORM ACTUALLY OFFERS, because the obvious name for this does not
-- exist. There is no `canWalk` flag on an animation anywhere in the catalogue.
-- What arrived in client 2.31.13+op77.75 is `Open77.movement.setWalkMode`, and
-- it is not a switch on the emote -- it is a LEASE ON THE LOCAL PLAYER, held by
-- a resource, asking their body to move at a bounded speed:
--
--   Open77.movement.setWalkMode(enabled, speed?)   -- players.controls
--
-- The platform's own words: "Every resource holds its own request and the
-- slowest live request wins; `false` releases only this resource's request and
-- never touches another's." Speed is 0.5 to 2.5 m/s.
--
-- THAT SHAPE IS WHY THIS IS SAFE TO USE AND DANGEROUS TO FORGET. Safe, because
-- another resource carrying a body at 1.0 m/s cannot be overridden by us asking
-- for 2.0, and we cannot be overridden either -- the slowest wins and every
-- release is private. Dangerous, because a lease is not tied to the animation
-- that justified it: if the emote ends and nothing releases, the player walks
-- for the rest of the session and has no idea why.
--
-- So there are two mechanisms here and not one. The lease is taken and released
-- on the state change, AND a watchdog re-checks every sweep that a held lease
-- still has an emote under it. The second exists because the first is a
-- promise about every exit path -- stop, expiry, death, a character change, the
-- resource stopping -- and a promise about every path is the kind that is kept
-- until somebody adds a path.

local M = OPX.Modules.Get('animations')

local Catalogue = M.Catalogue

M.Walk = {}
local Walk = M.Walk

-- The speed the lease is currently held at, or nil when it is not held. The
-- speed is kept rather than a boolean because re-asking at a different speed is
-- how one is changed, and asking again at the SAME speed every sweep would be a
-- native call a second for no reason.
local heldAt = nil

--- Whether this build has the walk lease at all.
--
-- op77.75 is recent, and a client older than that is not broken -- it simply
-- cannot walk through an emote. Asked by name at call time rather than captured,
-- like every other native this runtime reaches for.
-- @author dop42
-- @return boolean
function Walk.Available()
	local movement = Open77.movement
	return type(movement) == 'table' and type(movement.setWalkMode) == 'function'
end

--- Asks for the lease at one speed, or moves it to another.
-- @author dop42
-- @param speed number metres per second
-- @return boolean
function Walk.Hold(speed)
	if not Walk.Available() then return false end
	local wanted = tonumber(speed)
	-- Bounded here as well as by the platform: a config that wandered outside
	-- the range would otherwise refuse once a second and log nothing anybody
	-- reads, which is the shape of a fault that lasts for months.
	if wanted == nil or wanted < 0.5 or wanted > 2.5 then return false end
	if heldAt == wanted then return true end

	local ok, reason = pcall(Open77.movement.setWalkMode, true, wanted)
	if not ok then
		Open77.log.warn('[animations] the walk lease raised: ' .. tostring(reason))
		return false
	end
	heldAt = wanted
	return true
end

--- Gives the lease back. Safe to call when it is not held.
--
-- CALLED FROM EVERY EXIT, and deliberately cheap enough that a caller never has
-- to ask itself whether it is holding one. `false` releases only our own
-- request, so this can never take the ground out from under another resource.
-- @author dop42
function Walk.Release()
	if heldAt == nil then return end
	heldAt = nil
	if not Walk.Available() then return end
	local ok, reason = pcall(Open77.movement.setWalkMode, false)
	if not ok then
		Open77.log.warn('[animations] the walk lease would not release: ' .. tostring(reason))
	end
end

--- Whether the lease is held, and at what speed. Nil when it is not.
-- @author dop42
-- @return number|nil
function Walk.Held()
	return heldAt
end

--- Takes or releases the lease for one state of the local player.
--
-- THE ONE PLACE THE DECISION IS MADE, fed by `onOwnChanged`, which is the single
-- funnel for "what my own body is doing now". An emote that does not walk, an
-- emote this client does not know, and no emote at all are the same answer:
-- release.
-- @author dop42
-- @param active boolean whether an emote is playing
-- @param profile string|nil the profile it is playing
function Walk.Follow(active, profile)
	if active ~= true then return Walk.Release() end

	local entry = Catalogue.Entry(profile)
	local speed = entry ~= nil and entry.walk or nil
	if speed == nil then return Walk.Release() end
	Walk.Hold(speed)
end

--- Releases a lease that has outlived whatever justified it.
--
-- THE WATCHDOG, and the reason it exists is written in the header: the release
-- above is a promise about every exit path, and this is what makes the promise
-- survive somebody adding a path. Asked from the module's own sweep, which
-- already runs.
--
-- It reads the presenter rather than a flag of its own: a flag would answer the
-- question "did we think we should be walking", and the question worth asking
-- is "is there an emote on this body right now".
-- @author dop42
function Walk.Check()
	if heldAt == nil then return end
	local state = M.Presenter.State()
	if type(state) == 'table' and state.active == true then
		local entry = Catalogue.Entry(state.animation)
		if entry ~= nil and entry.walk ~= nil then return end
	end

	-- Said out loud, once per occurrence: a lease that had to be swept is a path
	-- somebody forgot, and the whole point of the watchdog is to name it rather
	-- than to quietly paper over it.
	Open77.log.warn('[animations] a walk lease outlived its emote and was swept')
	Walk.Release()
end
