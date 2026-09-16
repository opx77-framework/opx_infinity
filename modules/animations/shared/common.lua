--- Wire value tests shared by both halves.
-- @author dop42
--
-- The clock and the loop guard the source resource carried are gone: `OPX.Now`
-- is the runtime's monotonic reading, and `OPX.Scheduler` already runs every
-- client slice under pcall.

local M = OPX.Modules.Get('animations')

M.Common = {}
local Common = M.Common

--- Widest integer either half accepts off the wire.
Common.MAX_INTEGER = 9007199254740991

--- Answers a whole number inside the range, or nil.
-- Kept module-local rather than folded into `OPX.Text.Integer`, which takes no
-- range; NaN and the infinities are refused before any comparison, because NaN
-- passes every interval test written with two `<`.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return integer|nil
function Common.Integer(value, low, high)
	if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
	if value < low or value > high then return nil end
	return math.floor(value)
end

--- Whether a value is a bounded string without control characters.
-- Kept module-local rather than folded into `OPX.Text.Clean`, which replaces a
-- control character rather than refusing the value: a clip name that carries
-- one is a wire the two halves disagree about, not text to be tidied. Spaces
-- pass, because a platform clip name carries one.
-- @author dop42
-- @param value any
-- @param maximum integer
-- @return boolean
function Common.Text(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum and
		value:find('%c') == nil
end

--- Answers a code shaped as the service answers them, or nil.
-- Anything else becomes a generic refusal rather than reaching a log line or a
-- catalogue lookup.
-- @author dop42
-- @param value any
-- @return string|nil
function Common.Code(value)
	if type(value) ~= 'string' or #value == 0 or #value > 64 then return nil end
	if value:match('^[%w_%.:%-]+$') == nil then return nil end
	return value
end
