--- String helpers: length, trim, placeholders and random templates.
-- @author dop42

OPX.String = {}

-- Absent on runtimes that do not install the 5.3 utf8 library, so every use
-- below is guarded rather than assumed.
local utf8lib = rawget(_G, 'utf8')

--- Measures text in characters, nil when it is not UTF-8.
-- @author dop42
-- @param text string
-- @return integer|nil
function OPX.String.Length(text)
	if utf8lib and utf8lib.len then return utf8lib.len(text) end
	return #text
end

--- Removes leading and trailing whitespace.
-- Deliberately not the usual '^%s*(.-)%s*$': that pattern is quadratic on a
-- long run of whitespace, and a pattern match cannot be interrupted once it
-- has entered the C level, so a crafted string would hang the whole runtime.
-- Anchoring the start with an empty capture and then matching to the last
-- non-space keeps the work linear.
-- @author dop42
-- @param text string
-- @return string
function OPX.String.Trim(text)
	local from = text:match('^%s*()')
	if from > #text then return '' end
	return text:match('.*%S', from)
end

--- Fills named placeholders, leaving unknown names in place.
-- @author dop42
-- @param text string
-- @param params table<string, any>|nil
-- @return string
function OPX.String.Interpolate(text, params)
	if not params then return text end
	return (text:gsub('{(%w+)}', function(name)
		local value = params[name]
		return value ~= nil and tostring(value) or ('{' .. name .. '}')
	end))
end

local RANDOM_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
local RANDOM_DIGITS = '0123456789'

--- @author dop42
-- @param template string A letter, 1 digit, dot either; anything else is copied through.
-- @return string
function OPX.String.Random(template)
	local out = {}
	for i = 1, #template do
		local token = template:sub(i, i)
		if token == 'A' then
			local at = math.random(#RANDOM_LETTERS)
			out[i] = RANDOM_LETTERS:sub(at, at)
		elseif token == '1' then
			local at = math.random(#RANDOM_DIGITS)
			out[i] = RANDOM_DIGITS:sub(at, at)
		elseif token == '.' then
			local pool = math.random(2) == 1 and RANDOM_LETTERS or RANDOM_DIGITS
			local at = math.random(#pool)
			out[i] = pool:sub(at, at)
		else
			out[i] = token
		end
	end
	return table.concat(out)
end
