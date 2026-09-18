--- The index over the ped allowlist, read by both halves.
-- @author dop42
--
-- PEDS ARE NOT INDEXED HERE, for the same reason vehicles are not indexed in
-- `shared/catalog.lua`: the host checks a script's load time every 10,000 VM
-- instructions and cancels the whole resource set when a check falls past its
-- deadline. This file only reads the families, and each `shared/peds-<n>.lua`
-- indexes `PART` of the rows. The last part calls `FinishPeds`, which indexes
-- whatever is left and says so when that is more than one part's worth. A
-- missing part costs load time, never a ped.
--
-- A malformed row is a boot warning and nothing more: an operator reading the
-- log sees which row was dropped, and every other ped still works.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

--- Malformed data rows, one English line each, logged by the server at start.
M.Problems = M.Problems or {}

M.Peds = {}
local Peds = M.Peds

--- Ped rows one `shared/peds-<n>.lua` part indexes.
Peds.PART = 63

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

-- The families in menu order, by key, and the two row lookups.
local families, familyIndex = {}, {}
local byName, byRecord = {}, {}

-- The raw rows the parts index, and the next one to take.
local rows, nextRow = {}, 1

do
	local source = (M.Data or {}).PEDS
	if type(source) ~= 'table' or type(source.FAMILIES) ~= 'table' then
		problem('data/peds.lua: FAMILIES must be a table')
	else
		for position, row in ipairs(source.FAMILIES) do
			local key = type(row) == 'table' and Text.Slug(row.KEY) or nil
			if key == nil or familyIndex[key] ~= nil then
				problem(('data/peds.lua: family #%d needs a unique KEY'):format(position))
			else
				local family = { key = key, label = M.Trimmed(row.LABEL, 48) or key, members = {} }
				families[#families + 1] = family
				familyIndex[key] = family
			end
		end
		if type(source.PEDS) == 'table' then
			rows = source.PEDS
		else
			problem('data/peds.lua: PEDS must be a table')
		end
	end
end

--- Indexes the next `count` rows into their families and both lookups.
-- The record shape is the platform's own rule, checked here so that a typo is a
-- boot warning rather than an `invalid_record` in front of an operator: it
-- starts with `Character.`, is 11 to 255 ASCII characters, and carries only
-- letters, digits, `_`, `.` and `-`.
-- @author dop42
-- @param count integer
function Peds.IndexPeds(count)
	local last = math.min(#rows, nextRow + count - 1)
	for position = nextRow, last do
		local row = rows[position]
		local name = type(row) == 'table' and Text.Slug(row.NAME) or nil
		local raw = type(row) == 'table' and type(row.RECORD) == 'string' and row.RECORD or ''
		local record = raw:match('^Character%.[%w_%.%-]+$') and #raw >= 11 and #raw <= 255
			and raw or nil
		local family = type(row) == 'table' and familyIndex[tostring(row.FAMILY or '')] or nil
		local lowered = record and record:lower()
		local wrong = name == nil and 'NAME must be 1..32 letters, digits, _ or -'
			or record == nil and 'RECORD must be a Character.* record name'
			or family == nil and 'FAMILY is not a KEY in FAMILIES'
			or (byName[name] ~= nil or byRecord[lowered] ~= nil) and 'NAME or RECORD is declared twice'
			or nil
		if wrong then
			problem(('data/peds.lua: row #%d: %s'):format(position, wrong))
		else
			local entry = {
				name = name,
				label = M.Trimmed(row.LABEL, 48) or name,
				record = record,
				family = family.key,
			}
			family.members[#family.members + 1] = entry
			byName[name] = entry
			byRecord[lowered] = entry
		end
	end
	nextRow = last + 1
end

--- Indexes every row left, naming an overloaded last part.
-- @author dop42
function Peds.FinishPeds()
	local left = #rows - nextRow + 1
	if left > Peds.PART then
		problem(('data/peds.lua: %d rows were left to the last ped part; add a ' ..
			'modules/admin/shared/peds-<n>.lua line to open77.lua for every %d rows past it')
			:format(left, Peds.PART))
	end
	Peds.IndexPeds(left)
end

--- The families in menu order, each with its indexed members.
-- @author dop42
-- @return table[]
function Peds.Families()
	return families
end

--- A ped row by the name staff type or by its exact record, without case.
-- @author dop42
-- @param token any
-- @return table|nil
function Peds.Ped(token)
	if type(token) ~= 'string' then return nil end
	local lowered = token:lower()
	return byName[lowered] or byRecord[lowered]
end

--- The label of a ped named by `name`, or the name itself.
-- @author dop42
-- @param name any
-- @return string
function Peds.LabelOf(name)
	local entry = Peds.Ped(name)
	return entry and entry.label or tostring(name)
end
