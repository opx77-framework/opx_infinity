--- Numeric helpers: clamp, finiteness, distance and digit grouping.
-- @author dop42

OPX.Math = {}

--- @author dop42
-- @param value number
-- @param low number
-- @param high number
-- @return number
function OPX.Math.Clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

--- True only for a real number that is neither NaN nor infinite.
-- NaN is rejected by the value == value test rather than by a comparison
-- against a bound: NaN arrives from a client through JSON like any other
-- number and passes every comparison, so a plain min/max guard lets it
-- straight through and it then poisons whatever it is stored in.
-- @author dop42
-- @param value any
-- @return boolean
function OPX.Math.IsFinite(value)
	return type(value) == 'number'
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

--- Coerces to a finite number, or nil.
-- @author dop42
--
-- THE COERCING HALF OF `IsFinite`, and it is here because it was written out by
-- hand in ELEVEN files -- every `shared/access.lua` that reads a config, the job
-- gate, and three module-local `finite`s -- with the same four-clause body and
-- the same comment explaining why it is not `OPX.Text.Finite`. That reasoning is
-- right and is the reason this exists: `OPX.Text.Finite` also caps at 2^53,
-- which is correct for a value that has been through JSON and wrong for a
-- millisecond clock, and a caller that wanted the number got a boolean from
-- `IsFinite` and had to convert it twice.
--
-- What is NOT here is the coordinate box. `BOUND = 1000000` and the `coordinate`
-- and `integer` helpers over it are still one copy per module, because a bound
-- on WORLD SPACE is a policy about a map and this library knows nothing about
-- one; they belong with the placed-spot vocabulary those modules share, which is
-- a bigger extraction than this.
-- @param value any
-- @return number|nil
function OPX.Math.Finite(value)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return nil end
	return value
end

--- Squared distance between two points.
-- Squared on purpose: a within-range test compares against a squared radius
-- and so never pays for the square root, which matters on a per-frame loop.
-- @author dop42
-- @param a Vector3Like
-- @param b Vector3Like
-- @return number
function OPX.Math.DistanceSquared(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
	return dx * dx + dy * dy + dz * dz
end

--- Groups a whole amount's digits by thousands for display.
-- @author dop42
-- @param value number
-- @param separator string|nil A space when omitted.
-- @return string
function OPX.Math.GroupDigits(value, separator)
	separator = separator or ' '
	local whole = tostring(math.floor(math.abs(value)))
	local grouped = whole:reverse():gsub('(%d%d%d)', '%1' .. separator):reverse()
	grouped = grouped:gsub('^' .. separator:gsub('%p', '%%%0'), '')
	return (value < 0 and '-' or '') .. grouped
end
