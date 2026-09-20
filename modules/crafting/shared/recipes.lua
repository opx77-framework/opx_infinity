--- Every decision crafting makes that does not need a world, a bag or a database.
-- @author dop42
--
-- PURE, AND KEPT PURE ON PURPOSE. Nothing in this file reads the clock, the
-- roster, the catalogue or a player -- a recipe is validated, a bill is counted,
-- a queue is ordered and a screen is laid out, all of it from the arguments
-- alone. That is what lets `tests/run.lua` check the arithmetic a player's
-- materials disappear into without booting a server, and it is what stops the
-- rules leaking into whichever of the two halves happened to need them first.
--
-- The one thing that looks like an exception is the item LABEL, which is the
-- inventory catalogue's to answer and nobody else's. It arrives as a function
-- rather than as a lookup, so this file still knows nothing about the catalogue
-- and the server still does not reach into another module's namespace for it.
--
-- SHARED, not server-only: the client validates nothing here today, but the
-- refusal vocabulary and the row shape are what the screen is written against,
-- and a copy of either on the client is the drift `core/shared/glyphs.lua` has
-- the long story about.

local M = OPX.Modules.Get('crafting')

M.Recipes = {}
local Recipes = M.Recipes

local Refusal = M.Refusal

--- Pattern a bench key and a recipe key match.
-- The colon is in the set because a bench key is namespaced by its owner --
-- `gunsmith:arasaka_armoury` -- so two consumers cannot collide on `workbench`.
Recipes.KEY = '^[%w_%-%.:]+$'

--- Longest key in bytes. Both columns are VARCHAR(64).
Recipes.KEY_MAX = 64

--- Longest label in bytes, matched to what a menu row draws before it elides.
Recipes.LABEL_MAX = 64

-- Coerces to a number, rejecting NaN and both infinities. Written out rather
-- than borrowed from `OPX.Math.IsFinite` so the coercion and the test are one
-- step: every caller below wants the number or nil, never a boolean about a
-- value it then has to convert again.
local function finite(value)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end
Recipes.Finite = finite

--- A whole number inside a range, or nil.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return integer|nil
function Recipes.Integer(value, low, high)
	local parsed = finite(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	if parsed < low or parsed > high then return nil end
	return math.floor(parsed)
end

local integer = Recipes.Integer

--- A well-formed key, or nil.
-- @author dop42
-- @param value any
-- @return string|nil
function Recipes.Key(value)
	if type(value) ~= 'string' then return nil end
	local trimmed = OPX.String.Trim(value)
	if trimmed == '' or #trimmed > Recipes.KEY_MAX then return nil end
	if not trimmed:match(Recipes.KEY) then return nil end
	return trimmed
end

local key = Recipes.Key

--- The bounds a bench and its recipes are held to, read at the moment of use.
--
-- READ AND NOT CAPTURED. `config/crafting.lua` is a `shared_script` and so has
-- run by the time this file does, but a module never captures `M.Settings` into
-- a file-scope local -- see `OPX.Modules.Rebind` -- and a test that moves a bound
-- to check the refusal would otherwise be moving a table nothing reads.
-- @author dop42
-- @return table
function Recipes.Limits()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local rate = type(settings.RATE_LIMIT) == 'table' and settings.RATE_LIMIT or {}
	return {
		reach = finite(settings.REACH) or 3.0,
		maxReach = finite(settings.MAX_REACH) or 25.0,
		queue = integer(settings.QUEUE, 1, 100) or 3,
		maxQueue = integer(settings.MAX_QUEUE, 1, 100) or 10,
		minSeconds = integer(settings.MIN_SECONDS, 1, 86400) or 5,
		maxSeconds = integer(settings.MAX_SECONDS, 1, 604800) or 86400,
		maxYield = integer(settings.MAX_YIELD, 1, 1000000) or 1000,
		maxInputs = integer(settings.MAX_INPUTS, 1, 64) or 8,
		maxRecipes = integer(settings.MAX_RECIPES, 1, 500) or 40,
		windowMs = integer(rate.WINDOW_MS, 0, 600000) or 10000,
		requests = integer(rate.REQUESTS, 0, 10000) or 20,
		refreshMs = integer(settings.REFRESH_MS, 250, 600000) or 5000,
		handoverMs = integer(settings.HANDOVER_MS, 0, 10000) or 0,
	}
end

--- A count of seconds as a person reads a clock: `45s`, `12:30`, `3h 04m`.
--
-- FORMATTED HERE RATHER THAN ON THE PAGE, because the same string is wanted in
-- a menu row, in a toast and in a log line, and three copies of the rounding
-- rule is three places for it to disagree. Rounded UP, so a craft never reads
-- `0s` while it is still cooking -- the one value a player would act on and be
-- refused for.
-- @author dop42
-- @param seconds any
-- @return string
function Recipes.Clock(seconds)
	local total = finite(seconds)
	if total == nil or total <= 0 then return '0s' end
	total = math.ceil(total)
	if total < 60 then return ('%ds'):format(total) end
	local hours = total // 3600
	local minutes = (total % 3600) // 60
	if hours > 0 then return ('%dh %02dm'):format(hours, minutes) end
	return ('%d:%02d'):format(minutes, total % 60)
end

--- Normalises one recipe, or refuses it whole and says why.
--
-- REFUSED WHOLE AND NEVER PATCHED. A recipe with a broken INPUTS table could be
-- read as a recipe with no inputs, which is a recipe that makes a rifle out of
-- nothing -- so a fault anywhere in it drops the whole row, and the caller turns
-- the reason into a boot warning. This is the same choice `Access.Problems` makes
-- for an elevator floor and for the same reason: a silently repaired
-- configuration is one nobody ever fixes.
--
-- The INPUTS are flattened to a SORTED ARRAY here rather than left as a map. A
-- bill walked with `pairs` would list its materials in a different order every
-- boot, and the order is what the player reads and what the tests compare.
-- @author dop42
-- @param recipeKey any
-- @param raw any
-- @param known function|nil answers whether an item name is in the catalogue
-- @return table|nil
-- @return string|nil the problem, for the boot log
function Recipes.Recipe(recipeKey, raw, known)
	local bounds = Recipes.Limits()

	local id = key(recipeKey)
	if id == nil then
		return nil, ('%s: a recipe key is letters, digits, _ - . : up to %d')
			:format(tostring(recipeKey), Recipes.KEY_MAX)
	end
	if type(raw) ~= 'table' then return nil, id .. ': every recipe must be a table' end

	local output = key(raw.OUTPUT)
	if output == nil then return nil, id .. ': OUTPUT must name an item' end
	if known ~= nil and not known(output) then
		return nil, ('%s: OUTPUT %s is not in the item catalogue'):format(id, output)
	end

	local count = raw.COUNT == nil and 1 or integer(raw.COUNT, 1, bounds.maxYield)
	if count == nil then
		return nil, ('%s: COUNT must be a whole number from 1 to %d')
			:format(id, bounds.maxYield)
	end

	local seconds = integer(raw.SECONDS, bounds.minSeconds, bounds.maxSeconds)
	if seconds == nil then
		return nil, ('%s: SECONDS must be a whole number from %d to %d')
			:format(id, bounds.minSeconds, bounds.maxSeconds)
	end

	if type(raw.INPUTS) ~= 'table' then
		return nil, id .. ': INPUTS must be a table of item name -> units'
	end

	local inputs, names = {}, {}
	for name in pairs(raw.INPUTS) do names[#names + 1] = name end
	-- Sorted before anything is read, so the refusal a broken row produces is the
	-- same refusal on every boot. `table.sort` raises on a mixed-type list, so the
	-- names are proved to be strings first.
	for index = 1, #names do
		if type(names[index]) ~= 'string' then
			return nil, id .. ': every INPUTS key must be an item name'
		end
	end
	table.sort(names)

	if #names == 0 then return nil, id .. ': INPUTS names nothing, so it costs nothing' end
	if #names > bounds.maxInputs then
		return nil, ('%s: INPUTS names %d materials, and a recipe may name %d')
			:format(id, #names, bounds.maxInputs)
	end

	for index = 1, #names do
		local item = key(names[index])
		local need = integer(raw.INPUTS[names[index]], 1, bounds.maxYield)
		if item == nil then
			return nil, ('%s: %s is not an item name'):format(id, tostring(names[index]))
		end
		if need == nil then
			return nil, ('%s: %s must cost a whole number of units, 1 or more'):format(id, item)
		end
		if known ~= nil and not known(item) then
			return nil, ('%s: %s is not in the item catalogue'):format(id, item)
		end
		inputs[index] = { item = item, count = need }
	end

	-- A PRICE IS OPTIONAL AND A MONEY TYPE IS NOT CHECKED HERE. Which balances
	-- this server keeps is the character module's answer and it is not loadable
	-- from a shared file; the server half asks that module before it charges, and
	-- a type it does not know is a refusal there rather than a dropped recipe
	-- here. Zero is the same as absent: a bench that charges nothing is the
	-- ordinary case.
	local price = raw.PRICE == nil and 0 or integer(raw.PRICE, 0, 1000000000)
	if price == nil then
		return nil, id .. ': PRICE must be a whole number of eddies, 0 or more'
	end
	local money = nil
	if price > 0 then
		money = key(raw.MONEY)
		if money == nil then
			return nil, id .. ': a recipe with a PRICE must name the MONEY it is paid in'
		end
	end

	local icon = raw.ICON
	if icon ~= nil and (type(icon) ~= 'string' or OPX.Glyphs[icon] ~= true) then
		-- Refused rather than dropped, exactly as a menu row's glyph is: an author
		-- who wrote `wepaon` wants to hear about it at boot and not to wonder later
		-- why one recipe in ten has no picture.
		return nil, ('%s: ICON %s is not a name in OPX.Glyphs'):format(id, tostring(icon))
	end

	local label = nil
	if raw.LABEL ~= nil then
		if type(raw.LABEL) ~= 'string' then return nil, id .. ': LABEL must be text' end
		label = OPX.String.Trim(raw.LABEL)
		if label == '' or #label > Recipes.LABEL_MAX then
			return nil, ('%s: LABEL must be 1 to %d bytes'):format(id, Recipes.LABEL_MAX)
		end
	end

	return {
		key = id,
		label = label,
		icon = icon,
		inputs = inputs,
		output = output,
		count = count,
		seconds = seconds,
		price = price,
		money = money,
	}, nil
end

--- Normalises a whole bench, keeping the recipes that survive and naming the rest.
--
-- A BENCH WITH A BROKEN RECIPE STILL OPENS. The opposite -- refusing the bench --
-- would let one mistyped row take a whole armoury off the map, and the operator
-- would see a place that does not exist rather than a place with one row
-- missing and a warning in the log saying which.
--
-- A bench with NO surviving recipe is refused, because that is a screen with
-- nothing on it and there is no way to tell it apart from a broken one.
-- @author dop42
-- @param benchKey any
-- @param raw any
-- @param known function|nil
-- @return table|nil
-- @return string[] every problem, in the order it was met
function Recipes.Bench(benchKey, raw, known)
	local bounds = Recipes.Limits()
	local problems = {}

	local id = key(benchKey)
	if id == nil then
		problems[1] = ('%s: a bench key is letters, digits, _ - . : up to %d')
			:format(tostring(benchKey), Recipes.KEY_MAX)
		return nil, problems
	end
	if type(raw) ~= 'table' then
		problems[1] = id .. ': a bench definition must be a table'
		return nil, problems
	end

	local label = nil
	if raw.label ~= nil then
		if type(raw.label) ~= 'string' or OPX.String.Trim(raw.label) == '' then
			problems[#problems + 1] = id .. ': label must be text'
		else
			label = OPX.String.Trim(raw.label):sub(1, Recipes.LABEL_MAX)
		end
	end

	local owner = key(raw.owner)
	if owner == nil then
		problems[#problems + 1] = id .. ': owner must name the module registering the bench'
		return nil, problems
	end

	-- A POSITION IS OPTIONAL AND ITS ABSENCE IS NOT A MISTAKE. A bench with no
	-- position is reachable from anywhere, which is what a consumer wants when
	-- the place is proved some other way -- a vehicle it is bolted into, a
	-- property the player is standing in. A bench with a position is measured
	-- against it on the server and nowhere else.
	local position = nil
	if raw.position ~= nil then
		local at = raw.position
		local x = type(at) == 'table' and finite(at.x) or nil
		local y = type(at) == 'table' and finite(at.y) or nil
		local z = type(at) == 'table' and finite(at.z) or nil
		if x == nil or y == nil or z == nil then
			problems[#problems + 1] = id .. ': position needs a finite x, y and z'
			return nil, problems
		end
		position = { x = x, y = y, z = z, bucket = integer(at.bucket, 0, 2147483647) or 0 }
	end

	local reach = finite(raw.reach)
	if reach == nil or reach <= 0 or reach > bounds.maxReach then
		if raw.reach ~= nil then
			problems[#problems + 1] = ('%s: reach must be above 0 and at most %.1f; using %.1f')
				:format(id, bounds.maxReach, bounds.reach)
		end
		reach = bounds.reach
	end

	local queue = integer(raw.queue, 1, bounds.maxQueue)
	if queue == nil then
		if raw.queue ~= nil then
			problems[#problems + 1] = ('%s: queue must be a whole number from 1 to %d; using %d')
				:format(id, bounds.maxQueue, bounds.queue)
		end
		queue = bounds.queue
	end

	if raw.canUse ~= nil and type(raw.canUse) ~= 'function' then
		problems[#problems + 1] = id .. ': canUse must be a function'
		return nil, problems
	end

	if type(raw.recipes) ~= 'table' then
		problems[#problems + 1] = id .. ': recipes must be a list'
		return nil, problems
	end

	local list, byKey = {}, {}
	for index = 1, #raw.recipes do
		if #list >= bounds.maxRecipes then
			problems[#problems + 1] = ('%s: past recipe %d the list is dropped; a bench carries %d')
				:format(id, bounds.maxRecipes, bounds.maxRecipes)
			break
		end
		local row = raw.recipes[index]
		local recipeKey = type(row) == 'table' and row.KEY or nil
		local recipe, problem = Recipes.Recipe(recipeKey, row, known)
		if recipe == nil then
			problems[#problems + 1] = ('%s recipe #%d: %s'):format(id, index, problem)
		elseif byKey[recipe.key] ~= nil then
			problems[#problems + 1] = ('%s: recipe %s is declared twice; the first is kept')
				:format(id, recipe.key)
		else
			list[#list + 1] = recipe
			byKey[recipe.key] = recipe
		end
	end

	if #list == 0 then
		problems[#problems + 1] = id .. ': no usable recipe, so the bench would open empty'
		return nil, problems
	end

	-- EVERY MATERIAL THE BENCH CAN ASK FOR, ONCE, SORTED. Building the screen
	-- means counting what the bag holds of each of them, and the count is one
	-- call to the inventory contract per NAME -- so a bench whose forty recipes
	-- all start with scrap metal must ask about scrap metal once, not forty
	-- times. Sorted rather than `pairs`-ordered so the calls happen in the same
	-- sequence on every open, which is what makes a log of them readable.
	local materials, seen = {}, {}
	for index = 1, #list do
		local inputs = list[index].inputs
		for at = 1, #inputs do
			if not seen[inputs[at].item] then
				seen[inputs[at].item] = true
				materials[#materials + 1] = inputs[at].item
			end
		end
	end
	table.sort(materials)

	return {
		key = id,
		label = label or id,
		owner = owner,
		position = position,
		reach = reach,
		queue = queue,
		recipes = list,
		byKey = byKey,
		materials = materials,
		canUse = raw.canUse,
	}, problems
end

--- What a recipe is short of, given what the bag holds. Empty when nothing is.
-- @author dop42
-- @param recipe table
-- @param have table<string, integer>|nil item name -> units carried
-- @return table[] { item, need, held }, in the recipe's own order
function Recipes.Missing(recipe, have)
	have = type(have) == 'table' and have or {}
	local short = {}
	for index = 1, #recipe.inputs do
		local input = recipe.inputs[index]
		local held = integer(have[input.item], 0, math.maxinteger) or 0
		if held < input.count then
			short[#short + 1] = { item = input.item, need = input.count, held = held }
		end
	end
	return short
end

--- Whether an order may be placed, and the first reason it may not.
--
-- THE ORDER OF THE TESTS IS THE ORDER OF THE ANSWERS, and it runs from the
-- cheapest thing to fix to the most: a full queue is a minute's wait, missing
-- materials are an errand, and the fee is the one a player can do least about.
-- Only one reason is reported, because a screen that says three things at once
-- says none of them.
-- @author dop42
-- @param recipe table
-- @param have table<string, integer>|nil
-- @param money number|nil the balance in the recipe's own money type
-- @param cooking integer how many orders are already on this bench for them
-- @param queue integer how many the bench allows
-- @return boolean
-- @return string|nil an M.Refusal code
-- @return table[] what is short, when that is the reason
function Recipes.Allowed(recipe, have, money, cooking, queue)
	cooking = integer(cooking, 0, math.maxinteger) or 0
	queue = integer(queue, 1, math.maxinteger) or 1
	if cooking >= queue then return false, Refusal.QUEUE_FULL, {} end

	local short = Recipes.Missing(recipe, have)
	if #short > 0 then return false, Refusal.SHORT, short end

	if recipe.price > 0 then
		local balance = finite(money)
		if balance == nil or balance < recipe.price then
			return false, Refusal.CANNOT_PAY, {}
		end
	end

	return true, nil, {}
end

--- Seconds from now until a bench is free for this character.
--
-- The queue is SEQUENTIAL: a new order starts when the last one on the shelf
-- finishes, not now. `tail` is what the database answered for "seconds until my
-- last order here is ready", and a tail in the past -- every order already
-- finished, nobody collected them -- is not negative time.
-- @author dop42
-- @param tailSeconds any
-- @return integer
function Recipes.StartOffset(tailSeconds)
	local tail = finite(tailSeconds)
	if tail == nil or tail < 0 then return 0 end
	return math.floor(tail)
end

--- Seconds from now until an order placed now would be ready.
-- @author dop42
-- @param tailSeconds any
-- @param seconds integer the recipe's own duration
-- @return integer
function Recipes.ReadyIn(tailSeconds, seconds)
	local duration = integer(seconds, 0, math.maxinteger) or 0
	return Recipes.StartOffset(tailSeconds) + duration
end

--- Whether an order the database described is ready to collect.
-- A missing or unreadable `remaining` reads as NOT ready: the database is the
-- only thing that decides this, and a row it could not describe is one no player
-- should be handed the output of.
-- @author dop42
-- @param order table
-- @return boolean
function Recipes.IsReady(order)
	if type(order) ~= 'table' then return false end
	local remaining = finite(order.remaining)
	return remaining ~= nil and remaining <= 0
end

--- The orders on a shelf, soonest first.
--
-- SORTED HERE AND NOT IN SQL, and the duplication would be the mistake: the
-- statement orders them too, so that a LIMIT takes the right ones, but a screen
-- that trusted the row order would be trusting a detail of one statement. At
-- equal remaining the id decides, so two orders placed in the same second never
-- swap places between two reads of the same shelf.
-- @author dop42
-- @param orders table[]
-- @return table[] a new list; the argument is not reordered
function Recipes.Order(orders)
	local out = {}
	if type(orders) ~= 'table' then return out end
	for index = 1, #orders do out[index] = orders[index] end
	table.sort(out, function(left, right)
		local a = finite(left.remaining) or 0
		local b = finite(right.remaining) or 0
		if a ~= b then return a < b end
		return (finite(left.id) or 0) < (finite(right.id) or 0)
	end)
	return out
end

--- The whole screen, as one payload.
--
-- BUILT ON THE SERVER AND SENT WHOLE. Every `ok` and every `error` below is the
-- server's own answer from the server's own tables -- what the bag holds, what
-- the purse holds, what is on the shelf -- so the screen is a renderer and
-- nothing it draws is a decision it made. A client that redrew the same list
-- from its own idea of the bag would be a client deciding what a player may
-- make, and the refusal it drew would then disagree with the one the server
-- sends back.
-- @author dop42
-- @param bench table a normalised bench
-- @param have table<string, integer>|nil
-- @param money table<string, number>|nil balance by money type
-- @param orders table[] rows the database answered, each { id, recipe, remaining }
-- @param label function|nil item name -> display name
-- @param allowed function|nil recipe key -> boolean, code; the consumer's gate
-- @return table
function Recipes.View(bench, have, money, orders, label, allowed)
	have = type(have) == 'table' and have or {}
	money = type(money) == 'table' and money or {}
	label = type(label) == 'function' and label or function(name) return name end

	local shelf = Recipes.Order(orders)
	local cooking = #shelf

	local rows = {}
	for index = 1, #bench.recipes do
		local recipe = bench.recipes[index]

		-- The consumer's gate first, because a recipe this player may never make
		-- should not also be told they cannot afford it.
		local gated, gateCode = true, nil
		if allowed ~= nil then
			local answered, why = allowed(recipe.key)
			gated = answered == true
			gateCode = (not gated) and (type(why) == 'string' and why or Refusal.NOT_FOR_YOU) or nil
		end

		local ok, code, short = false, gateCode, {}
		if gated then
			ok, code, short = Recipes.Allowed(recipe, have, money[recipe.money or ''], cooking,
				bench.queue)
		end

		local inputs = {}
		for at = 1, #recipe.inputs do
			local input = recipe.inputs[at]
			inputs[at] = {
				item = input.item,
				label = label(input.item),
				need = input.count,
				held = integer(have[input.item], 0, math.maxinteger) or 0,
			}
		end

		rows[#rows + 1] = {
			key = recipe.key,
			label = recipe.label or label(recipe.output),
			icon = recipe.icon,
			output = recipe.output,
			outputLabel = label(recipe.output),
			count = recipe.count,
			seconds = recipe.seconds,
			price = recipe.price,
			money = recipe.money,
			inputs = inputs,
			ok = ok,
			error = code,
			short = short,
		}
	end

	local shelfRows = {}
	for index = 1, #shelf do
		local order = shelf[index]
		local recipe = bench.byKey[order.recipe]
		shelfRows[index] = {
			id = order.id,
			recipe = order.recipe,
			label = recipe and (recipe.label or label(recipe.output)) or order.recipe,
			output = recipe and recipe.output or nil,
			count = recipe and recipe.count or nil,
			remaining = math.max(0, math.floor(finite(order.remaining) or 0)),
			ready = Recipes.IsReady(order),
		}
	end

	return {
		bench = bench.key,
		label = bench.label,
		queue = bench.queue,
		cooking = cooking,
		free = math.max(0, bench.queue - cooking),
		recipes = rows,
		orders = shelfRows,
	}
end
