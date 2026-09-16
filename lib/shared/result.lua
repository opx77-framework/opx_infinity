--- Success or failure as a value, never an ambiguous nil.
-- @author dop42

OPX.Result = {}

--- Wraps a success; its value may be nil.
-- @author dop42
-- @param value any
-- @return Result
function OPX.Result.Ok(value)
	return { ok = true, value = value }
end

--- Wraps a failure with a stable code and a log-only detail.
-- @author dop42
-- @param code string
-- @param detail string|nil
-- @return Result
function OPX.Result.Err(code, detail)
	return { ok = false, error = code, detail = detail }
end
