--- Wire constants and the clock arithmetic both halves share.
-- @author dop42
--
-- Everything here is plumbing, not operator settings: the two halves validate a
-- snapshot against the same numbers, so a value that lived on only one side
-- would let the halves disagree about what is on the wire.

local M = OPX.Modules.Get('weather')

--- Wire version a snapshot and a carried state must match.
M.PROTOCOL = 1

--- Loop cadences, drift tolerance and request floors shared by both halves.
--
--   HEARTBEAT_MS             the authority republishes when nothing changed
--   CLIENT_SYNC_MS           a client asks for a fresh stamp
--   APPLY_MS                 the client recomputes the hour it should show
--   ENFORCE_MS               the client checks nothing stole the sky
--   SCHEDULER_MS             the authority looks for a roll that is due
--   DRIFT_TOLERANCE_SECONDS  game seconds of drift before the clock is corrected
--   MAX_LATENCY_MS           ceiling on the half round trip added to a snapshot
--   MIN_REQUEST_MS           floor between two requests from one player
M.SYNC = {
	HEARTBEAT_MS = 5000,
	CLIENT_SYNC_MS = 15000,
	APPLY_MS = 500,
	ENFORCE_MS = 5000,
	SCHEDULER_MS = 1000,
	DRIFT_TOLERANCE_SECONDS = 120,
	MAX_LATENCY_MS = 2000,
	MIN_REQUEST_MS = 1000,
}

--- Real seconds the boot preset holds before the first roll.
M.INITIAL_WEATHER_SECONDS = 180

--- Priority the client hands to setWeather.
M.WEATHER_PRIORITY = 5

--- Longest crossfade in seconds either half accepts.
M.MAX_TRANSITION_SECONDS = 300

--- Host wall clock in milliseconds, or nil where there is none.
-- Never used to measure an interval -- that is `OPX.Now` -- only to order the
-- incarnations of the authority and to seed the rolls. Monotonic milliseconds
-- restart near zero with the process, so a fresh incarnation would sort under
-- the one clients still hold and every snapshot it sent would look stale. The
-- wall clock is the only reading that grows across a restart. The server
-- sandbox has no `os`.
-- @author dop42
-- @return integer|nil
function M.UnixMs()
	local time = Open77.time
	if type(time) ~= 'table' or type(time.unix) ~= 'function' then return nil end
	local read, seconds = pcall(time.unix)
	if not read or type(seconds) ~= 'number' or seconds ~= seconds
		or seconds <= 0 or seconds >= math.huge then
		return nil
	end
	return math.floor(seconds * 1000)
end

M.Clock = {}
local Clock = M.Clock

local DAY_SECONDS = 24 * 60 * 60

--- Seconds in one game day, for the other files.
Clock.DAY_SECONDS = DAY_SECONDS

--- Widest magnitude a carried or wire number may hold.
Clock.MAX_MAGNITUDE = 2 ^ 53

--- Fastest clock a client follows, in game seconds per real second.
Clock.MAX_RATE = 120.0

--- Whether a value is a real number within MAX_MAGNITUDE.
-- `OPX.Math.IsFinite` with the bound the wire needs: past 2^53 a double no
-- longer separates a whole number from its neighbour, so `% 1 ~= 0` stops seeing
-- a non-integer and `%d` has no integer form left to print.
-- @author dop42
-- @param value any
-- @return boolean
function Clock.Finite(value)
	return OPX.Math.IsFinite(value)
		and value >= -Clock.MAX_MAGNITUDE and value <= Clock.MAX_MAGNITUDE
end

--- Whether a value is a finite whole number, at least minimum.
-- @author dop42
-- @param value any
-- @param minimum number
-- @return boolean
function Clock.Whole(value, minimum)
	return Clock.Finite(value) and value >= minimum and value % 1 == 0
end

--- Folds any second-of-day onto 0..86399, negatives included.
-- A value that is not finite folds to 0 rather than through the modulo: a folded
-- NaN stays NaN and raises at the first `%d`.
-- @author dop42
-- @param seconds any
-- @return number
function Clock.Normalize(seconds)
	seconds = tonumber(seconds)
	if not Clock.Finite(seconds) then return 0 end
	return ((seconds % DAY_SECONDS) + DAY_SECONDS) % DAY_SECONDS
end

--- Whole seconds since midnight, or nil for an impossible time.
-- @author dop42
-- @param hour any
-- @param minute any
-- @param second any|nil
-- @return number|nil
-- @return string|nil
function Clock.FromHms(hour, minute, second)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second or 0)
	if hour == nil or minute == nil or second == nil then return nil, 'invalid_time' end
	if hour % 1 ~= 0 or minute % 1 ~= 0 or second % 1 ~= 0 then return nil, 'invalid_time' end
	if hour < 0 or hour > 23 then return nil, 'invalid_time' end
	if minute < 0 or minute > 59 then return nil, 'invalid_time' end
	if second < 0 or second > 59 then return nil, 'invalid_time' end
	return hour * 3600 + minute * 60 + second
end

--- Splits a second-of-day into hour, minute and second.
-- @author dop42
-- @param seconds number
-- @return integer
-- @return integer
-- @return integer
function Clock.ToHms(seconds)
	local whole = math.floor(Clock.Normalize(seconds))
	return math.floor(whole / 3600), math.floor((whole % 3600) / 60), whole % 60
end

--- Parses HH:MM or HH:MM:SS into seconds since midnight.
-- The pattern is anchored at both ends so a suffix such as `12:30pm` is refused
-- rather than read as half past noon.
-- @author dop42
-- @param text any
-- @return number|nil
-- @return string|nil
function Clock.Parse(text)
	if type(text) ~= 'string' then return nil, 'invalid_time' end
	local hour, minute, second = string.match(text, '^(%d%d?):(%d%d):?(%d*)$')
	if hour == nil then return nil, 'invalid_time' end
	return Clock.FromHms(hour, minute, second ~= '' and second or 0)
end

--- Where the clock stands now, given where it stood at the anchor.
-- @author dop42
-- @param baseSeconds number Second-of-day at the anchor.
-- @param anchorMs number Host-monotonic milliseconds.
-- @param rate number Game seconds per real second.
-- @param frozen boolean
-- @param nowMs number
-- @return number
function Clock.At(baseSeconds, anchorMs, rate, frozen, nowMs)
	local elapsed = frozen and 0 or math.max(0, (nowMs - anchorMs) / 1000)
	return Clock.Normalize(baseSeconds + elapsed * rate)
end

--- Forward distance from origin to target on a 24-hour dial, where midnight is
--- one step rather than a wall.
-- @author dop42
-- @param target number
-- @param origin number
-- @return number
function Clock.ForwardDelta(target, origin)
	return Clock.Normalize(target - origin)
end

--- Game seconds per real second from a day length in minutes.
-- Bounded by MAX_RATE: past it a client corrects drift continuously and the
-- world jumps on every correction.
-- @author dop42
-- @param minutes any
-- @return number|nil
-- @return string|nil
function Clock.RateFromDayLength(minutes)
	minutes = tonumber(minutes)
	if not Clock.Finite(minutes) then return nil, 'invalid_day_length' end
	if minutes < 1 or minutes > 10080 then return nil, 'invalid_day_length' end
	local rate = DAY_SECONDS / (minutes * 60)
	if rate > Clock.MAX_RATE then return nil, 'day_too_short' end
	return rate
end
