--- Display text helpers that measure and cut in characters, not bytes.
-- @author dop42

OPX.Text = {}
local Text = OPX.Text

-- Past 2^53 an integer no longer survives a round trip through a double, and
-- every number reaching us has been through JSON as one.
local MAGNITUDE = 2 ^ 53

--- Byte length of the first maximum characters of a text.
-- The scan is bounded at four bytes a character before it starts, so a long
-- string cut to a short limit costs the limit, not the string. Continuation
-- bytes are 0x80..0xBF, so anything outside that range opens a new character
-- and a cut is only ever taken there, never through the middle of one.
-- @author dop42
-- @param text string
-- @param maximum integer Characters, not bytes.
-- @return integer
function OPX.Text.Span(text, maximum)
	local size = #text
	local ceiling = maximum * 4
	if size > ceiling then size = ceiling end
	local characters, index = 0, 1
	while index <= size do
		local byte = text:byte(index)
		if byte < 0x80 or byte > 0xBF then
			if characters >= maximum then return index - 1 end
			characters = characters + 1
		end
		index = index + 1
	end
	return size
end

--- Replaces control characters and cuts display text to maximum characters.
-- @author dop42
-- @param value any
-- @param maximum integer Characters, not bytes.
-- @param ellipsis string|nil Appended when the text was cut.
-- @return string|nil
function OPX.Text.Clean(value, maximum, ellipsis)
	if value == nil then return nil end
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end
	value = value:gsub('[%c]', ' ')
	if #value <= maximum then return value end
	local cut = Text.Span(value, maximum)
	if cut >= #value then return value end
	return value:sub(1, cut) .. (ellipsis or '')
end

--- Cuts text to a byte limit without splitting a character.
-- @author dop42
-- @param text string
-- @param limit integer Bytes to keep.
-- @return string
function OPX.Text.Bytes(text, limit)
	if #text <= limit then return text end
	-- Walk back while the byte that would follow the cut is a continuation.
	local cut = limit
	while cut > 0 do
		local following = text:byte(cut + 1)
		if following == nil or following < 0x80 or following > 0xBF then break end
		cut = cut - 1
	end
	return text:sub(1, cut)
end

--- Answers a finite number within MAGNITUDE, or nil.
-- The value ~= value test rejects NaN, which arrives from a client through
-- JSON like any other number and passes every comparison on its own.
-- @author dop42
-- @param value any
-- @return number|nil
function OPX.Text.Finite(value)
	value = tonumber(value)
	if value == nil or value ~= value or value > MAGNITUDE or value < -MAGNITUDE then return nil end
	return value
end

--- @author dop42
-- @param value any
-- @return integer|nil
function OPX.Text.Integer(value)
	local parsed = Text.Finite(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	return math.floor(parsed)
end

--- Joins the typed words from one position on into a sentence.
-- @author dop42
-- @param args table
-- @param first integer
-- @return string|nil
function OPX.Text.Rest(args, first)
	-- args.n rather than #args: a trailing nil argument leaves a hole the
	-- length operator is free to stop at.
	local words = {}
	local count = Text.Integer(args.n) or #args
	for index = first, count do
		local word = args[index]
		if word ~= nil then words[#words + 1] = tostring(word) end
	end
	if #words == 0 then return nil end
	return table.concat(words, ' ')
end

--- Reads on or off and their synonyms; nil when absent.
-- @author dop42
-- @param value any
-- @return boolean|nil, string|nil
function OPX.Text.Switch(value)
	if value == nil then return nil end
	local word = tostring(value):lower()
	if word == 'on' or word == 'true' or word == '1' or word == 'yes' then return true end
	if word == 'off' or word == 'false' or word == '0' or word == 'no' then return false end
	return nil, 'invalid'
end

--- Answers a lower-cased name of letters, digits, underscores and hyphens.
-- @author dop42
-- @param value any
-- @return string|nil
function OPX.Text.Slug(value)
	if type(value) ~= 'string' then return nil end
	local lowered = value:lower()
	if #lowered > 32 or lowered:match('^[%w_%-]+$') == nil then return nil end
	return lowered
end

-- ── the air category ────────────────────────────────────────────────────────

-- The pair `open77_avcleanup` sweeps the world by, read when the operator's list
-- is empty or unusable. An empty list must not mean "nothing flies": it means
-- the operator has not said, and the documented pair is what the platform itself
-- says.
local AV_FALLBACK = { 'vehicle.av_', 'vehicle.max_tac_av' }

-- The normalised list, and the config table it was built from. Rebuilt when that
-- table is REPLACED rather than on every call, because the admin catalogue asks
-- this question once per vehicle row inside a load-time instruction budget the
-- host will cancel the resource set for overrunning. Editing the list in place
-- will not be noticed; replacing it will.
local avPrefixes, avSource = nil, nil

--- Whether a TweakDB vehicle record names an AV.
-- @author dop42
--
-- ONE RULE AND ONE CONFIG KEY, `OPX.Config.SHARED.AV_PREFIXES`. It was three
-- rules over three keys -- `config/garages.lua`, `config/dealership.lua` and
-- `VEHICLES.AV_PREFIXES` in `config/admin.lua` -- which agreed on the data and
-- not on the code: two guarded the argument's type and fell back to the
-- documented pair, the third did neither, so emptying the admin list alone
-- silently reclassified every AV as ground in the staff catalogue while the
-- garage and the dealer went on calling the same records air. Whether a record
-- flies is a fact about the record, so it cannot be three answers.
--
-- The comparison is lower-cased because the database column and the wire
-- disagree about case.
-- @param record any
-- @return boolean
function OPX.Text.IsAvRecord(record)
	if type(record) ~= 'string' then return false end

	local configured = type(OPX.Config) == 'table' and type(OPX.Config.SHARED) == 'table'
		and OPX.Config.SHARED.AV_PREFIXES or nil
	if avPrefixes == nil or avSource ~= configured then
		local list = {}
		if type(configured) == 'table' then
			for index = 1, #configured do
				local prefix = configured[index]
				if type(prefix) == 'string' and prefix ~= '' then
					list[#list + 1] = prefix:lower()
				end
			end
		end
		if #list == 0 then list = AV_FALLBACK end
		avPrefixes, avSource = list, configured
	end

	local lowered = record:lower()
	for index = 1, #avPrefixes do
		local prefix = avPrefixes[index]
		if lowered:sub(1, #prefix) == prefix then return true end
	end
	return false
end
