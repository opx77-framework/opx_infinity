--- Config reads, coercions and the boot validator, for both halves.
-- @author dop42
--
-- Deliberately pure: not one host call anywhere in this file. Everything here is
-- arithmetic over the config table, which is what makes the whole of it testable
-- off-platform and what lets the server half call `Problems` at boot without
-- having to have a world yet.
--
-- The numbers are read once at load and a value `Problems` refuses reads as zero,
-- so a bad config becomes a line at boot rather than a raise from inside a
-- network handler three hours later.

local M = OPX.Modules.Get('hauling')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}
Access.Config = Config

--- The configured sites, or an empty table when missing.
-- Read as empty rather than refused, because every read below is reachable from
-- the contract and a missing block must not raise inside one.
Access.SITES = type(Config.SITES) == 'table' and Config.SITES or {}
local SITES = Access.SITES

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box and the two coercions over it, in `lib/shared/spots.lua`. Only
-- those: a hauling SITE is a run of pickup points and dropoffs with a vehicle
-- and a pay rate, not a placed spot, and that record is its own. Where a
-- coordinate stops being believable is the same question everywhere on one map.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer
local coordinate, integer = Access.Coordinate, Access.Integer

-- The %d ceiling quoted in this module's own refusal messages.
local BOUND = OPX.Spots.BOUND

--- Whether a point is the unfilled blank this config ships with.
--
-- ALL THREE AXES EXACTLY ZERO. Not "near the origin" and not a tolerance: a
-- surveyed position is a measurement and will never be three exact zeros, while
-- an unfilled template row is always exactly that. A tolerance here would
-- eventually condemn a real point somebody stood on.
--
-- THE ZEROS ARE WHY THIS CHECK CAN EXIST AT ALL, and that is the lesson taken
-- from `config/elevators.lua` rather than a check it was missing. Its four lifts
-- ship PLAUSIBLE coordinates -- `X = -1521.40` and three more like it, carried
-- over from a standalone resource that had said they were samples -- which no
-- rule here or anywhere could tell from a surveyed position: they are finite, in
-- range and fully formed, and they match nothing in Night City. No lift was ever
-- adopted, no panel ever opened, and nothing anywhere said why, for weeks. So
-- this config ships blanks instead of plausible numbers, precisely so that a
-- blank is something a validator can see.
-- @author dop42
-- @param point table|nil
-- @return boolean
local function placeholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0
		and coordinate(point.Z) == 0.0
end
Access.IsPlaceholder = placeholder

-- The operator numbers, read once. A value `Problems` refuses lands here as its
-- floor, which for every one of them means the safest behaviour and not the most
-- permissive: a zero REACH refuses every pickup, a zero MAX_CRATES spawns
-- nothing, and both are visible in a minute of play.
Access.MODEL = type(Config.MODEL) == 'string' and Config.MODEL or ''
Access.MAX_CRATES = math.max(0, integer(Config.MAX_CRATES) or 0)
Access.PICKUP_MS = math.max(0, integer(Config.PICKUP_MS) or 0)
Access.LOAD_MS = math.max(0, integer(Config.LOAD_MS) or 0)
Access.DELIVER_MS = math.max(0, integer(Config.DELIVER_MS) or 0)
Access.CLOCK_TOLERANCE_MS = math.max(0, integer(Config.CLOCK_TOLERANCE_MS) or 0)
Access.CLAIM_GRACE_MS = math.max(0, integer(Config.CLAIM_GRACE_MS) or 0)
Access.REACH = math.max(0, finiteNumber(Config.REACH) or 0)
Access.VEHICLE_REACH = math.max(0, finiteNumber(Config.VEHICLE_REACH) or 0)
Access.MIN_POINT_GAP = math.max(0, finiteNumber(Config.MIN_POINT_GAP) or 0)
Access.REFILL_MS = math.max(0, integer(Config.REFILL_MS) or 0)
Access.PAY_PER_CRATE = math.max(0, integer(Config.PAY_PER_CRATE) or 0)
Access.CURRENCY = type(Config.CURRENCY) == 'string' and Config.CURRENCY or 'EDDIES'
Access.ITEM = type(Config.ITEM) == 'string' and Config.ITEM or ''
Access.DROP_KEY = type(Config.DROP_KEY) == 'string' and Config.DROP_KEY or 'X'
Access.DROP_DISTANCE = math.min(2.0, math.max(0, finiteNumber(Config.DROP_DISTANCE) or 0.7))
Access.DROP_RETURN_MS = math.max(0, integer(Config.DROP_RETURN_MS) or 300000)

-- Squared, because every reach test below compares squares and a square root per
-- test per player per pick is arithmetic nobody needs.
Access.REACH_SQ = Access.REACH * Access.REACH
Access.VEHICLE_REACH_SQ = Access.VEHICLE_REACH * Access.VEHICLE_REACH
Access.MIN_POINT_GAP_SQ = Access.MIN_POINT_GAP * Access.MIN_POINT_GAP

-- Which target row the client draws. Anything but the two known words reads as
-- `prop`, which is the design that costs nothing; `Problems` says so separately
-- so a typo is visible rather than merely harmless.
Access.TARGET_KIND = Config.TARGET_KIND == 'world' and 'world' or 'prop'

--- The bar length for one step, in milliseconds.
-- @author dop42
-- @param step string an M.Step value
-- @return integer
function Access.StepMs(step)
	if step == M.Step.PICKUP then return Access.PICKUP_MS end
	if step == M.Step.LOAD then return Access.LOAD_MS end
	if step == M.Step.DELIVER then return Access.DELIVER_MS end
	return 0
end

--- One site by key, or nil.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Site(key)
	local site = SITES[key]
	return type(site) == 'table' and site or nil
end

--- One point of a site by its index, or nil.
-- @author dop42
-- @param key any
-- @param index any
-- @return table|nil
function Access.Point(key, index)
	local site = Access.Site(key)
	if site == nil or type(site.POINTS) ~= 'table' then return nil end
	index = integer(index)
	if index == nil or index < 1 then return nil end
	local point = site.POINTS[index]
	if type(point) ~= 'table' then return nil end
	local x, y, z = coordinate(point.X), coordinate(point.Y), coordinate(point.Z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, yaw = finiteNumber(point.YAW) or 0.0 }
end

--- One drop-off of a site by key, or nil.
-- @author dop42
-- @param key any
-- @param dropoff any
-- @return table|nil
function Access.Dropoff(key, dropoff)
	local site = Access.Site(key)
	if site == nil or type(site.DROPOFFS) ~= 'table' then return nil end
	local row = site.DROPOFFS[dropoff]
	if type(row) ~= 'table' then return nil end
	local x, y, z = coordinate(row.X), coordinate(row.Y), coordinate(row.Z)
	local radius = finiteNumber(row.RADIUS)
	if x == nil or y == nil or z == nil or radius == nil or radius <= 0 then return nil end
	-- THE SELLER, optional: a `Character.*` record standing on the drop-off. The
	-- owner: "pour les points de vente fait en sorte que ce soit une interaction
	-- alt sur un npc puis vendre".
	local npc = nil
	if type(row.NPC) == 'table' and type(row.NPC.RECORD) == 'string'
		and row.NPC.RECORD:match('^Character%.[%w_]+$') then
		npc = { record = row.NPC.RECORD, yaw = finiteNumber(row.NPC.YAW) or 0.0 }
	end
	return { key = dropoff, label = tostring(row.LABEL or dropoff), x = x, y = y, z = z,
		radius = radius, npc = npc }
end

--- Every usable drop-off of a site, sorted by key.
-- Sorted because `pairs` order would reshuffle which destination a delivery is
-- credited to between two runs that stood in the same overlapping spot.
-- @author dop42
-- @param key any
-- @return table[]
function Access.Dropoffs(key)
	local site = Access.Site(key)
	if site == nil or type(site.DROPOFFS) ~= 'table' then return {} end
	local names = {}
	for name in pairs(site.DROPOFFS) do names[#names + 1] = tostring(name) end
	table.sort(names)
	local out = {}
	for index = 1, #names do
		local row = Access.Dropoff(key, names[index])
		if row ~= nil then out[#out + 1] = row end
	end
	return out
end

--- The bucket a site's crates live in.
--
-- THE SITE'S OWN BUCKET AND NEVER THE REPORTING PLAYER'S. This is the mistake
-- `modules/elevators/server/main.lua:5-8` already warns about for lifts and the
-- one `rp_nomade` makes for crates: it creates them in the accepting driver's
-- bucket, so nobody outside that instance can ever see them and nothing is ever
-- contested. A crate created in the first passer-by's bucket is a crate pinned
-- into their instance for the life of the process.
-- @author dop42
-- @param key any
-- @return integer
function Access.Bucket(key)
	local site = Access.Site(key)
	if site == nil then return 0 end
	return integer(site.BUCKET) or 0
end

--- The crate alias a site uses.
-- @author dop42
-- @param key any
-- @return string
function Access.Model(key)
	local site = Access.Site(key)
	if site ~= nil and type(site.MODEL) == 'string' and site.MODEL ~= '' then
		return site.MODEL
	end
	return Access.MODEL
end

--- What one delivered crate pays at a site.
-- @author dop42
-- @param key any
-- @return integer
function Access.Pay(key)
	local site = Access.Site(key)
	if site ~= nil then
		local own = integer(site.PAY)
		if own ~= nil and own >= 0 then return own end
	end
	return Access.PAY_PER_CRATE
end

--- Crates a site's refill pass may add in one pass.
-- @author dop42
-- @param key any
-- @return integer
function Access.SpawnPerPass(key)
	local site = Access.Site(key)
	if site == nil then return 0 end
	return math.max(0, integer(site.SPAWN_PER_PASS) or 0)
end

--- Milliseconds a point of a site stays empty after its crate leaves.
-- @author dop42
-- @param key any
-- @return integer
function Access.RespawnMs(key)
	local site = Access.Site(key)
	if site == nil then return 0 end
	return math.max(0, integer(site.RESPAWN_MS) or 0)
end

--- The square of the distance between two points, or nil when either is unreadable.
-- @author dop42
-- @param a table|nil
-- @param b table|nil
-- @return number|nil
function Access.GapSquared(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then return nil end
	local ax, ay, az = coordinate(a.x), coordinate(a.y), coordinate(a.z)
	local bx, by, bz = coordinate(b.x), coordinate(b.y), coordinate(b.z)
	if ax == nil or ay == nil or az == nil or bx == nil or by == nil or bz == nil then
		return nil
	end
	local dx, dy, dz = ax - bx, ay - by, az - bz
	return dx * dx + dy * dy + dz * dz
end

--- How a carried crate is bound to a body, or nil when the config is unusable.
-- @author dop42
-- @return table|nil { bone, offset, rotation }
function Access.Carry()
	local carry = type(Config.CARRY) == 'table' and Config.CARRY or nil
	if carry == nil then return nil end
	local bone = carry.BONE
	if bone ~= nil and type(bone) ~= 'string' then return nil end
	local function vector(value)
		if type(value) ~= 'table' then return nil end
		local x, y, z = finiteNumber(value.x), finiteNumber(value.y), finiteNumber(value.z)
		if x == nil or y == nil or z == nil then return nil end
		return { x = x, y = y, z = z }
	end
	local offset, rotation = vector(carry.OFFSET), vector(carry.ROTATION)
	if offset == nil or rotation == nil then return nil end
	return { bone = bone or '', offset = offset, rotation = rotation }
end

--- Decides whether a character snapshot may work a site.
--
-- THE RULE ITSELF LIVES IN `lib/shared/jobgate.lua` and this is the adapter that
-- names a SITE's fields to it. This module shipped its own fourth copy of the
-- rule, and it silently dropped two things the identical config keys do on
-- `elevators`, `teleports` and `gunsmith`: `ON_DUTY = true` was read by nobody,
-- and a refusal named whichever job `pairs` reached first rather than the
-- closest near-miss. A JOBS block must mean the same thing on every surface that
-- accepts one, or the operator has to learn four rules that look like one.
--
-- NO STALENESS BOUND IS PASSED, on purpose. The other three modules read
-- `JOB_MAX_AGE_MS` because a CLIENT holds a replicated snapshot that can be
-- minutes old and draws a panel from it. Nothing on this module's client half
-- reads a job: the gate is asked only by the server, off a snapshot stamped from
-- the same clock read that is handed in as `nowMs`, so the age is exactly zero.
-- A config knob that can never change an answer would be a lie in the config
-- file.
-- @author dop42
-- @param site table|nil
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @return boolean
-- @return string|nil no_such_site, no_character, job_stale, job_required,
--   grade_too_low, off_duty
function Access.Evaluate(site, snapshot, nowMs)
	-- Closed for a site that is not a table: reading `site.JOBS` off a nil raises
	-- out of whichever network handler was asking, and the three sibling adapters
	-- all answer closed here.
	if type(site) ~= 'table' then return false, 'no_such_site' end
	return OPX.JobGate.Evaluate({ jobs = site.JOBS, onDuty = site.ON_DUTY }, snapshot, nowMs,
		{ maxAgeMs = 0, membership = Config.MEMBERSHIP })
end

-- The site keys whose points are all readable, far enough apart and not
-- placeholders. Built once at load: the refill pass walks it every minute, and a
-- site condemned at boot must never be reconsidered by a later pass that forgot
-- why.
local usable = nil

--- Whether a site passed the boot validation, so the refill pass may spawn on it.
-- @author dop42
-- @param key any
-- @return boolean
function Access.Usable(key)
	if usable == nil then Access.Problems() end
	return usable[key] == true
end

--- Every usable site key, sorted.
-- @author dop42
-- @return string[]
function Access.UsableKeys()
	if usable == nil then Access.Problems() end
	local keys = {}
	for key, ok in pairs(usable) do
		if ok then keys[#keys + 1] = tostring(key) end
	end
	table.sort(keys)
	return keys
end

--- Marks a site unusable for the rest of the process.
-- The one door through which a RUNTIME failure -- an `unknown_alias` from the
-- boot probe, say -- condemns a site the shape checks were happy with. It is
-- one-way on purpose: a site that could not produce a crate once will not
-- produce one on the ninetieth pass either, and a job that retries forever is a
-- job that writes a log line a minute forever.
-- @author dop42
-- @param key any
function Access.Condemn(key)
	if usable == nil then Access.Problems() end
	usable[key] = nil
end

-- The operator numbers that must be finite and above zero.
local POSITIVE = { 'PICKUP_MS', 'LOAD_MS', 'DELIVER_MS', 'REACH', 'VEHICLE_REACH',
	'MIN_POINT_GAP', 'REFILL_MS', 'MAX_CRATES' }

-- The operator numbers that must be finite and not negative; zero is a choice.
local NON_NEGATIVE = { 'CLOCK_TOLERANCE_MS', 'CLAIM_GRACE_MS', 'PAY_PER_CRATE' }

--- Every complaint the configuration earns, as lines for the log, and the side
--- effect of deciding which sites may be used at all.
--
-- Shape only, which is the whole point of the placeholder check above: a
-- validator that can see finite numbers but not unfilled ones certifies a config
-- that will never work. Every complaint names the site so an operator can find it.
-- @author dop42
-- @return string[]
function Access.Problems()
	local lines = {}
	usable = {}

	if type(Config.SITES) ~= 'table' then
		lines[#lines + 1] = 'SITES must be a table of site key -> definition'
	end
	for index = 1, #POSITIVE do
		local name = POSITIVE[index]
		local value = finiteNumber(Config[name])
		if value == nil or value <= 0 then
			lines[#lines + 1] = name .. ' must be a finite number above zero'
		end
	end
	for index = 1, #NON_NEGATIVE do
		local name = NON_NEGATIVE[index]
		local value = finiteNumber(Config[name])
		if value == nil or value < 0 then
			lines[#lines + 1] = name .. ' must be a finite number, zero or more'
		end
	end
	if Access.ITEM == '' then
		lines[#lines + 1] = 'ITEM must name the inventory item a loaded crate becomes'
	end
	if type(Config.MODEL) ~= 'string' or Config.MODEL == '' then
		lines[#lines + 1] = 'MODEL must be a curated prop alias, never a .mesh path'
	end
	if Config.TARGET_KIND ~= nil and Config.TARGET_KIND ~= 'prop'
		and Config.TARGET_KIND ~= 'world' then
		lines[#lines + 1] = ("TARGET_KIND must be 'prop' or 'world'; reading it as 'prop'")
	end
	if Access.Carry() == nil then
		lines[#lines + 1] = 'CARRY must name a BONE and finite OFFSET and ROTATION vectors'
	end
	if Config.MEMBERSHIP ~= 'primary' and Config.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = 'MEMBERSHIP must be primary or any'
	end

	for key, site in pairs(SITES) do
		local name = tostring(key)
		if type(site) ~= 'table' then
			lines[#lines + 1] = name .. ': every SITES entry must be a table'
		else
			local bad = false
			if type(site.LABEL) ~= 'string' or site.LABEL == '' then
				lines[#lines + 1] = name .. ': no LABEL'
				bad = true
			end
			if site.MODEL ~= nil and (type(site.MODEL) ~= 'string' or site.MODEL == '') then
				lines[#lines + 1] = name .. ': MODEL must be a curated prop alias'
				bad = true
			end
			-- ONE DIAGNOSTIC FOR ONE MISTAKE. This was a hand-written fifth copy of
			-- `OPX.JobGate.Problems` whose wording had drifted, so the same typo in
			-- the same config key was reported in two different sentences depending
			-- on which module it was written under. A site with an unreadable JOBS
			-- block is still condemned here, which the shared lister does not do:
			-- it reports, and what a report costs the site is this module's call.
			local before = #lines
			OPX.JobGate.Problems(site.JOBS, name, lines)
			if #lines > before then bad = true end

			local points = site.POINTS
			if type(points) ~= 'table' or #points == 0 then
				lines[#lines + 1] = name .. ': no POINTS, so no crate can ever stand here'
				bad = true
			else
				-- Read every point first, so the placeholder report is one line for the
				-- site rather than one per blank row, and so the gap test below never
				-- complains about two blanks being in the same place -- which they
				-- always are, and which is not the operator's next problem.
				local read, blanks = {}, 0
				for index = 1, #points do
					if placeholder(points[index]) then
						blanks = blanks + 1
					else
						local point = Access.Point(key, index)
						if point == nil then
							lines[#lines + 1] = ('%s point #%d: X, Y and Z must be finite numbers ' ..
								'inside %d'):format(name, index, BOUND)
							bad = true
						else
							read[#read + 1] = { index = index, point = point }
						end
					end
				end
				if blanks > 0 then
					lines[#lines + 1] = ('%s: %d of %d POINTS ARE STILL THE PLACEHOLDER 0,0,0 -- ' ..
						'THIS SITE IS DISABLED. Stand on each spot in game and paste your own ' ..
						'position in; nothing will spawn here until you do'):format(name, blanks,
						#points)
					bad = true
				end
				for a = 1, #read do
					for b = a + 1, #read do
						local gap = Access.GapSquared(read[a].point, read[b].point)
						if gap ~= nil and gap < Access.MIN_POINT_GAP_SQ then
							lines[#lines + 1] = ('%s: points #%d and #%d are %.2fm apart, closer ' ..
								'than MIN_POINT_GAP %.2fm; two crates there overlap and only the ' ..
								'nearer can ever be picked'):format(name, read[a].index,
								read[b].index, math.sqrt(gap), Access.MIN_POINT_GAP)
							bad = true
						end
					end
				end
			end

			local dropoffs = site.DROPOFFS
			if type(dropoffs) ~= 'table' or next(dropoffs) == nil then
				lines[#lines + 1] = name .. ': no DROPOFFS, so a crate could never be delivered'
				bad = true
			else
				local names = {}
				for dropoff in pairs(dropoffs) do names[#names + 1] = tostring(dropoff) end
				table.sort(names)
				local blanks = 0
				for index = 1, #names do
					local row = dropoffs[names[index]]
					if type(row) == 'table' and placeholder(row) then
						blanks = blanks + 1
					else
						local read = Access.Dropoff(key, names[index])
						if read == nil then
							lines[#lines + 1] = ('%s dropoff %s: X, Y, Z must be finite and RADIUS ' ..
								'above zero'):format(name, names[index])
							bad = true
						elseif read.npc == nil then
							-- The seller IS the sale: with no NPC nothing can be sold here.
							lines[#lines + 1] = ('%s dropoff %s: NPC must be { RECORD = ' ..
								'\'Character.*\', YAW = n }; the seller is the only way to sell')
								:format(name, names[index])
							bad = true
						end
					end
				end
				if blanks > 0 then
					lines[#lines + 1] = ('%s: %d DROPOFFS ARE STILL THE PLACEHOLDER 0,0,0 -- THIS ' ..
						'SITE IS DISABLED. Survey each destination and paste its position in')
						:format(name, blanks)
					bad = true
				end
			end

			if Access.SpawnPerPass(key) <= 0 then
				lines[#lines + 1] = name .. ': SPAWN_PER_PASS must be a whole number above zero'
				bad = true
			end
			if site.RESPAWN_MS ~= nil and integer(site.RESPAWN_MS) == nil then
				lines[#lines + 1] = name .. ': RESPAWN_MS must be a whole number of milliseconds'
				bad = true
			end
			if site.PAY ~= nil and (integer(site.PAY) == nil or integer(site.PAY) < 0) then
				lines[#lines + 1] = name .. ': PAY must be a whole number, zero or more'
				bad = true
			end

			if not bad then usable[key] = true end
		end
	end

	return lines
end
