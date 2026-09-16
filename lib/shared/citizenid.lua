--- Citizen ids: seven unambiguous symbols with a prime-modulus check.
-- @author dop42

local Result = OPX.Result

OPX.CitizenId = {}
local CitizenId = OPX.CitizenId

-- The symbols a citizen id is written with. Chosen so no two read alike when
-- an id is spoken aloud or copied by hand, which is why 0/O, 1/I/L, 2/Z, 5/S,
-- 8/B, U/V and Q are all absent. Changing this string changes BASE, and so
-- invalidates every id already issued.
CitizenId.ALPHABET = '34679ACDEFGHJKMNPRTWXYZ'

-- The alphabet size is also the check modulus, and it is 23, a prime. That is
-- what makes the check sum worth having: over a prime modulus the weights are
-- all invertible, so every single-symbol substitution and every transposition
-- of two adjacent symbols changes the sum and is caught. A composite modulus
-- would let whole families of typos through undetected.
local BASE = #CitizenId.ALPHABET

local PAYLOAD = 6

-- Distinct and non-zero mod BASE, which is what catches transpositions.
local WEIGHTS = { 2, 3, 4, 5, 6, 7 }

-- Symbol to value and value to symbol, built once from the alphabet.
local valueOf, symbolOf = {}, {}
for i = 1, BASE do
	local symbol = CitizenId.ALPHABET:sub(i, i)
	valueOf[symbol] = i - 1
	symbolOf[i - 1] = symbol
end

--- Answers the check symbol that completes a weighted sum to zero mod BASE.
local function checkSymbolFor(weightedSum)
	return symbolOf[(BASE - weightedSum % BASE) % BASE]
end

--- Writes seven raw symbols in their three-dash-four display form.
local function grouped(raw)
	return raw:sub(1, 3) .. '-' .. raw:sub(4)
end

--- @author dop42
-- @param values integer[]
-- @return CitizenId
function OPX.CitizenId.Build(values)
	local symbols, sum = {}, 0
	for i = 1, PAYLOAD do
		local value = values[i] % BASE
		symbols[i] = symbolOf[value]
		sum = sum + WEIGHTS[i] * value
	end
	symbols[PAYLOAD + 1] = checkSymbolFor(sum)
	return grouped(table.concat(symbols))
end

--- @author dop42
-- @param rng fun(low: integer, high: integer): integer|nil Injectable, so a test can generate deterministically.
-- @return CitizenId
function OPX.CitizenId.Generate(rng)
	rng = rng or math.random
	local values = {}
	for i = 1, PAYLOAD do values[i] = rng(0, BASE - 1) end
	return CitizenId.Build(values)
end

--- Reads typed input, forgiving on case and separators, strict on symbols.
-- @author dop42
-- @param input any
-- @return Result
function OPX.CitizenId.Parse(input)
	if type(input) ~= 'string' then
		return Result.Err('type', 'expected string')
	end

	-- Bound the input before upper and gsub touch it. This is reached with a
	-- string a client chose, and a seven-symbol id padded with every separator
	-- a human might type still fits well inside 32 bytes.
	if #input > 32 then
		return Result.Err('length', ('expected %d symbols, got %d'):format(PAYLOAD + 1, #input))
	end

	local cleaned = input:upper():gsub('[%s%-_]', '')
	if #cleaned ~= PAYLOAD + 1 then
		return Result.Err('length', ('expected %d symbols, got %d'):format(PAYLOAD + 1, #cleaned))
	end

	local sum = 0
	for i = 1, PAYLOAD do
		local symbol = cleaned:sub(i, i)
		local value = valueOf[symbol]
		if value == nil then
			return Result.Err('alphabet', ('%q is not a citizen id symbol'):format(symbol))
		end
		sum = sum + WEIGHTS[i] * value
	end

	local check = cleaned:sub(PAYLOAD + 1)
	if valueOf[check] == nil then
		return Result.Err('alphabet', ('%q is not a citizen id symbol'):format(check))
	end
	if checkSymbolFor(sum) ~= check then
		return Result.Err('checksum', 'this is not a valid citizen id')
	end

	return Result.Ok(grouped(cleaned))
end

--- @author dop42
-- @param value any
-- @return boolean
function OPX.CitizenId.IsValid(value)
	return CitizenId.Parse(value).ok
end
