--- What a character carries between runs: reputation, the day's count and the wait.
-- @author dop42
--
-- No table of its own, and that is deliberate. Everything here is ONE metadata
-- key on the character, which the character module already loads, saves and
-- deletes with the character. A gig is day work; it does not deserve a schema
-- migration, and a module that can be dropped from the manifest should not leave
-- a table behind when it is.
--
-- TIME IS READ TWICE, FROM TWO CLOCKS, ON PURPOSE. `OPX.Now` is monotonic since
-- the process started, which is the right clock for "has this run stalled" and
-- the wrong one for "may they take another": a restart would hand everyone their
-- cooldowns back. The wait and the day come from the host's wall clock instead,
-- and a host that answers neither falls back to the monotonic one with the
-- consequence written down rather than hidden.

local M = OPX.Modules.Get('gigs')
local Catalog = M.Catalog

M.Ledger = {}
local Ledger = M.Ledger

-- The shape stored under the metadata key:
--   rep   integer, lifetime reputation across every gig
--   day   'YYYY-MM-DD' the counts below belong to
--   runs  gig id -> runs taken that day
--   done  gig id -> runs completed, lifetime
--   at    gig id -> unix seconds of the last run taken
local EMPTY_DAY = '0000-00-00'

-- Whether a missing wall clock has been said. Once: it is a property of the
-- host, not of the player who happened to trigger the read.
local warnedClock = false

--- Wall-clock seconds, or nil when this host answers no clock.
-- @author dop42
-- @return integer|nil
function Ledger.Unix()
	local time = Open77.time
	if type(time) ~= 'table' or type(time.unix) ~= 'function' then return nil end
	local read, seconds = pcall(time.unix)
	if not read or type(seconds) ~= 'number' then return nil end
	return math.floor(seconds)
end

--- Today as `YYYY-MM-DD` in UTC, or a sentinel when this host answers no clock.
--- The sentinel is stable for the life of the process, so a daily cap still
--- caps -- it simply never rolls over.
-- @author dop42
-- @return string
function Ledger.Today()
	local time = Open77.time
	if type(time) == 'table' and type(time.utc) == 'function' then
		local read, iso = pcall(time.utc)
		if read and type(iso) == 'string' and #iso >= 10 then
			local day = iso:sub(1, 10)
			if day:match('^%d%d%d%d%-%d%d%-%d%d$') then return day end
		end
	end
	if not warnedClock then
		warnedClock = true
		Open77.log.warn('[gigs] this host answers no wall clock: daily caps never roll over and ' ..
			'a cooldown does not survive a restart')
	end
	return EMPTY_DAY
end

-- The character contract, or nil. Read at the moment of use: the contract is
-- required, so this is nil only while the module is coming up or going down.
local function character()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetMetadata) ~= 'function' then return nil end
	return api
end

--- Reads a player's gig record, with every field present and sane.
--- A record whose `day` is not today is answered with the day's counts cleared,
--- but is NOT written back: a read must not cost a write, and the next run that
--- counts will store the new day anyway.
-- @author dop42
-- @param source Source
-- @return table
function Ledger.Read(source)
	local api = character()
	local raw = nil
	if api ~= nil then
		local read, value = pcall(api.GetMetadata, source, M.Settings.METADATA_KEY)
		if read and type(value) == 'table' then raw = value end
	end
	raw = raw or {}

	local record = {
		rep = Catalog.Integer(raw.rep, 0, 1000000) or 0,
		day = Ledger.Today(),
		runs = {},
		done = {},
		at = {},
	}

	local storedDay = type(raw.day) == 'string' and raw.day or EMPTY_DAY
	local sameDay = storedDay == record.day

	if type(raw.done) == 'table' then
		for id, value in pairs(raw.done) do
			local count = Catalog.Integer(value, 0, 1000000)
			if type(id) == 'string' and count ~= nil then record.done[id] = count end
		end
	end
	if type(raw.at) == 'table' then
		for id, value in pairs(raw.at) do
			local seconds = Catalog.Integer(value, 0, 4102444800)
			if type(id) == 'string' and seconds ~= nil then record.at[id] = seconds end
		end
	end
	if sameDay and type(raw.runs) == 'table' then
		for id, value in pairs(raw.runs) do
			local count = Catalog.Integer(value, 0, 100000)
			if type(id) == 'string' and count ~= nil then record.runs[id] = count end
		end
	end

	return record
end

--- Writes a record back onto the character.
-- @author dop42
-- @param source Source
-- @param record table
-- @return boolean
function Ledger.Write(source, record)
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return false end
	local written = pcall(api.SetMetadata, source, M.Settings.METADATA_KEY, {
		rep = record.rep,
		day = record.day,
		runs = record.runs,
		done = record.done,
		at = record.at,
	})
	return written == true
end

--- Whether a player may take a gig now, and why not when they may not.
-- @author dop42
-- @param record table
-- @param gig table
-- @return boolean
-- @return string|nil the refusal code
-- @return integer|nil seconds left, for a refusal that is a wait
function Ledger.MayTake(record, gig)
	if record.rep < gig.minReputation then
		return false, 'not_trusted'
	end

	if gig.maxRunsPerDay > 0 and (record.runs[gig.id] or 0) >= gig.maxRunsPerDay then
		return false, 'day_full'
	end

	if gig.cooldownMs > 0 then
		local now = Ledger.Unix()
		local last = record.at[gig.id]
		if now ~= nil and last ~= nil then
			local waited = (now - last) * 1000
			-- A clock that went backwards -- a correction, a restored snapshot --
			-- reads as no wait rather than as a wait of days.
			if waited >= 0 and waited < gig.cooldownMs then
				return false, 'cooling', math.ceil((gig.cooldownMs - waited) / 1000)
			end
		end
	end

	return true
end

--- Counts one run taken: the day's counter and the wall-clock stamp the cooldown
--- is measured from. Written at the START of a run, so taking one and walking
--- away still costs the attempt.
-- @author dop42
-- @param source Source
-- @param gig table
-- @return table the record as written
function Ledger.Taken(source, gig)
	local record = Ledger.Read(source)
	record.runs[gig.id] = (record.runs[gig.id] or 0) + 1
	local now = Ledger.Unix()
	if now ~= nil then record.at[gig.id] = now end
	Ledger.Write(source, record)
	return record
end

--- Counts one run completed and adds its reputation.
-- @author dop42
-- @param source Source
-- @param gig table
-- @return integer the reputation the character now holds
function Ledger.Completed(source, gig)
	local record = Ledger.Read(source)
	record.done[gig.id] = (record.done[gig.id] or 0) + 1
	record.rep = record.rep + gig.reputation
	Ledger.Write(source, record)
	return record.rep
end

-- Rolls a whole number in a band, inclusive. A band of zero width answers its
-- own value without touching the generator.
local function roll(band)
	if band.max <= band.min then return band.min end
	return math.random(band.min, band.max)
end

--- Pays a leg. Answers what was paid, which is zero when the gig pays nothing
--- per leg or the money could not be added.
-- @author dop42
-- @param source Source
-- @param gig table
-- @return integer
function Ledger.PayLeg(source, gig)
	local amount = roll(gig.pay.perStep)
	if amount <= 0 then return 0 end
	return Ledger.Pay(source, gig, amount, 'gig:' .. gig.id .. ':leg') and amount or 0
end

--- Pays the completion bonus. Answers what was paid.
-- @author dop42
-- @param source Source
-- @param gig table
-- @return integer
function Ledger.PayBonus(source, gig)
	local amount = roll(gig.pay.bonus)
	if amount <= 0 then return 0 end
	return Ledger.Pay(source, gig, amount, 'gig:' .. gig.id .. ':bonus') and amount or 0
end

--- Adds money through the character contract, logging a refusal rather than
--- letting it pass as a payment that happened.
-- @author dop42
-- @param source Source
-- @param gig table
-- @param amount integer
-- @param reason string
-- @return boolean
function Ledger.Pay(source, gig, amount, reason)
	local api = character()
	if api == nil or type(api.AddMoney) ~= 'function' then return false end
	local called, paid, code = pcall(api.AddMoney, source, gig.pay.moneyType, amount, reason)
	if not called then
		Open77.log.error(('[gigs] %s: AddMoney raised: %s'):format(gig.id, tostring(paid)))
		return false
	end
	if paid ~= true then
		Open77.log.warn(('[gigs] %s: %d %s were refused for player %d: %s')
			:format(gig.id, amount, tostring(gig.pay.moneyType), source, tostring(code)))
		return false
	end
	return true
end

--- Rolls the bonus items of a completed run and hands over the ones that landed.
--- Answers what was actually given, so the player is told about the item they
--- have and not the one the roll picked before their bag refused it.
-- @author dop42
-- @param source Source
-- @param gig table
-- @return table[] rows of { name, count }
function Ledger.GiveItems(source, gig)
	local given = {}
	if #gig.items == 0 then return given end

	local api = OPX.Api.Get('inventory')
	if api == nil or type(api.AddItem) ~= 'function' then
		-- Said at info: a server running gigs without an inventory is a choice,
		-- and the eddies still arrive.
		Open77.log.info(('[gigs] %s: no inventory contract, so no bonus item was handed over')
			:format(gig.id))
		return given
	end

	for index = 1, #gig.items do
		local row = gig.items[index]
		if row.chance > 0 and math.random(1, 100) <= row.chance then
			local called, answer = pcall(api.AddItem, source, row.name, row.count)
			if not called then
				Open77.log.error(('[gigs] %s: AddItem raised: %s'):format(gig.id, tostring(answer)))
			elseif type(answer) == 'table' and answer.ok == true then
				given[#given + 1] = { name = row.name, count = row.count }
			else
				local code = type(answer) == 'table' and tostring(answer.error) or 'malformed_answer'
				Open77.log.info(('[gigs] %s: %dx %s was not given to player %d: %s')
					:format(gig.id, row.count, row.name, source, code))
			end
		end
	end
	return given
end
