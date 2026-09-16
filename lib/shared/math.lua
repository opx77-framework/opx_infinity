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
