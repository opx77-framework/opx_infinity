--- Checks for values that cross a trust boundary.
-- @author dop42

local Result = OPX.Result

OPX.Validate = {}

--- Trims text and checks its length in characters and its pattern.
-- @author dop42
-- @param value any
-- @param opts table|nil min, max and pattern.
-- @return Result
function OPX.Validate.Text(value, opts)
	opts = opts or {}
	if type(value) ~= 'string' then
		return Result.Err('type', 'expected string, got ' .. type(value))
	end

	-- Reject on bytes before any UTF-8 work is done. A character costs at most
	-- four bytes, so anything past that ceiling cannot fit the character limit
	-- whatever it holds, and the hard 1024 cap stops a caller with a generous
	-- max from letting a client hand us an arbitrarily long string to scan.
	local ceiling = math.min(((opts.max or 255) * 4) + 16, 1024)
	if #value > ceiling then return Result.Err('too-long') end

	local trimmed = OPX.String.Trim(value)
	local length = OPX.String.Length(trimmed)
	if not length then return Result.Err('not-utf8') end
	if length < (opts.min or 1) then return Result.Err('too-short') end
	if length > (opts.max or 255) then return Result.Err('too-long') end
	if opts.pattern and not trimmed:match(opts.pattern) then
		return Result.Err('format')
	end
	return Result.Ok(trimmed)
end

--- Reads a finite number and checks integrality and bounds.
-- @author dop42
-- @param value any
-- @param opts table|nil integer, min and max.
-- @return Result
function OPX.Validate.Number(value, opts)
	opts = opts or {}
	local n = tonumber(value)
	if n == nil then
		return Result.Err('type', 'expected number, got ' .. type(value))
	end
	-- Finiteness first: NaN and the infinities pass min and max unchallenged.
	if not OPX.Math.IsFinite(n) then return Result.Err('not-finite') end
	if opts.integer and n % 1 ~= 0 then return Result.Err('not-integer') end
	if opts.min and n < opts.min then return Result.Err('too-small') end
	if opts.max and n > opts.max then return Result.Err('too-large') end
	return Result.Ok(n)
end

--- @author dop42
-- @param value any
-- @param allowed table<any, boolean>
-- @return Result
function OPX.Validate.OneOf(value, allowed)
	if allowed[value] then return Result.Ok(value) end
	return Result.Err('not-allowed', tostring(value))
end
