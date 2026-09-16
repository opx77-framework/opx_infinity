--- The roster as cards, the creation form as steps, and the rules both are checked against.
-- @author dop42
--
-- Every rule below is the SERVER'S, repeated. The character module re-checks all
-- of it and a modified client skips this file entirely; what it buys is a
-- refusal that names the field, in the player's language, instead of a round
-- trip that names nothing.

local M = OPX.Modules.Get('entry')

M.Model = {}
local Model = M.Model

local Text = OPX.Text
local Validate = OPX.Validate

-- Longest card text kept, in characters. A card is drawn and not measured, so
-- these are display hygiene rather than a limit somebody below would refuse: a
-- name of four thousand characters is a card that owns the screen.
local MAX_NAME = 96
local MAX_VALUE = 48
local MAX_NOTE = 160

-- Most cards built from one roster. The account's slot count bounds the real
-- number; a payload claiming more is clamped rather than handed to the page as
-- an unbounded grid.
local MAX_CARDS = 99

-- The five steps, in the order they are asked in. The first three are text, the
-- next two are choices, and the last one only reads back what the other four
-- answered.
local STEPS = { 'identity', 'birth', 'lifepath', 'body', 'review' }

-- Which values each step is responsible for. `Model.Check` walks these, so a
-- step cannot be advanced past a field it did not check.
local STEP_FIELDS = {
	identity = { 'firstName', 'lastName' },
	birth = { 'birthDate' },
	lifepath = { 'origin' },
	body = { 'gender' },
	review = { 'firstName', 'lastName', 'birthDate', 'origin', 'gender' },
}

--- The roster the character contract last answered.
Model.roster = { list = {}, slots = 0, origins = {} }

--- Whether any roster has arrived, whatever its slot count.
-- `slots = 0` does not tell "no roster" from "no slots", and the retry loop has
-- to know the difference.
Model.hasRoster = false

-- The cards, rebuilt when a roster arrives and never per frame.
local cards = {}

-- Card id -> its index in `cards`, so a chosen id is read back in one lookup.
local byId = {}

--- Cleaned display text, or an empty string.
local function display(value, maximum)
	return Text.Clean(value, maximum) or ''
end

--- A character's two names joined, empty when it has neither.
local function fullName(summary)
	local first = display(summary.firstName, MAX_NAME)
	local last = display(summary.lastName, MAX_NAME)
	if first == '' then return last end
	if last == '' then return first end
	return first .. ' ' .. last
end

--- One or two initials, for the plate that stands in for a portrait.
-- There is no portrait to draw: a roster summary carries no face, and the face
-- the player can actually see is the puppet the stage camera is pointed at.
local function monogram(summary)
	local first = display(summary.firstName, MAX_NAME)
	local last = display(summary.lastName, MAX_NAME)
	local mark = first:sub(1, 1) .. last:sub(1, 1)
	if mark == '' then return '??' end
	return mark:upper()
end

--- The lifepath label for an origin key, or the key itself.
local function originLabel(key)
	local origin = type(key) == 'string' and Model.roster.origins[key] or nil
	if type(origin) == 'table' and origin.label ~= nil then
		return display(origin.label, MAX_VALUE)
	end
	return display(key, MAX_VALUE)
end

--- The translated body label for a family, or the raw value.
local function bodyLabel(gender)
	if gender == 'female' then return locale('entry.body.female') end
	if gender == 'male' then return locale('entry.body.male') end
	return display(gender, MAX_VALUE)
end

--- One character's card: the identifying facts, and nothing else.
local function characterCard(summary, index)
	local name = fullName(summary)
	-- A character with no name would otherwise draw a nameless card. It keeps its
	-- slot number, so the player can still tell it from the next one.
	if name == '' then name = locale('entry.slot.number', { index = index }) end

	local lastSeen = summary.lastLoggedOut ~= nil and display(summary.lastLoggedOut, MAX_VALUE)
		or locale('entry.card.never')

	return {
		id = 'character_' .. tostring(index),
		kind = 'character',
		index = index,
		-- Kept on this side only: the page reports the card id, and the card it
		-- names is what is read. Nothing the page sends is trusted as an identity.
		citizenId = summary.citizenId,
		name = name,
		monogram = monogram(summary),
		identifier = locale('entry.card.id', { citizenId = display(summary.citizenId, 32) }),
		lifepath = originLabel(summary.origin),
		body = bodyLabel(summary.gender),
		role = summary.job ~= nil and display(summary.job, MAX_VALUE)
			or locale('entry.card.unemployed'),
		affiliation = summary.gang ~= nil and display(summary.gang, MAX_VALUE) or nil,
		lastSeen = locale('entry.card.lastSeen', { when = lastSeen }),
	}
end

--- An empty slot's card.
local function emptyCard(index)
	return {
		id = 'slot_' .. tostring(index),
		kind = 'empty',
		index = index,
		name = locale('entry.slot.empty'),
		identifier = locale('entry.slot.number', { index = index }),
		note = locale('entry.slot.note'),
	}
end

--- The trailing create card, disabled with its reason when the account is full.
-- Always drawn, even when it cannot be used: a player who may not create has to
-- be able to see why.
local function createCard(free)
	local used, slots = #Model.roster.list, Model.roster.slots
	return {
		id = 'create',
		kind = 'create',
		name = locale('entry.create.card'),
		note = free and locale('entry.create.note', { used = used, slots = slots })
			or locale('entry.create.full'),
		disabled = (not free) or nil,
	}
end

--- Rebuilds the cards from the adopted roster.
local function buildCards()
	cards, byId = {}, {}
	local list = Model.roster.list
	local total = math.max(Model.roster.slots, #list)
	if total > MAX_CARDS then total = MAX_CARDS end
	for index = 1, total do
		cards[index] = list[index] ~= nil and characterCard(list[index], index) or emptyCard(index)
	end
	cards[total + 1] = createCard(#list < Model.roster.slots)
	for index = 1, #cards do byId[cards[index].id] = index end
end

--- The citizen ids the account holds right now.
-- @author dop42
-- @return table<string, boolean>
function Model.KnownIds()
	local known = {}
	local list = Model.roster.list
	for index = 1, #list do known[list[index].citizenId] = true end
	return known
end

--- Adopts a roster in either shape it arrives in.
-- The contract answers `list`; the wire payload the server sends carries
-- `characters`. Both are accepted so that a roster read back from the mirror and
-- a roster that arrived on the bus build the same cards.
-- @author dop42
-- @param payload table|nil
-- @return boolean
function Model.Adopt(payload)
	if type(payload) ~= 'table' then return false end

	local offered = payload.list
	if type(offered) ~= 'table' then offered = payload.characters end
	if type(offered) ~= 'table' then offered = {} end

	local list = {}
	for index = 1, #offered do
		local summary = offered[index]
		-- A summary with no citizen id names nothing selectable, so it is dropped
		-- rather than drawn as a card that refuses every time it is chosen.
		if type(summary) == 'table' and type(summary.citizenId) == 'string' then
			list[#list + 1] = summary
		end
	end

	local slots = tonumber(payload.slots)
	slots = OPX.Math.IsFinite(slots) and math.floor(slots) or 0
	if slots < 0 then slots = 0 end

	Model.roster = {
		list = list,
		slots = slots,
		origins = type(payload.origins) == 'table' and payload.origins or {},
	}
	Model.hasRoster = true
	buildCards()
	return true
end

--- Forgets the roster of a player who left the world.
-- @author dop42
function Model.Forget()
	Model.roster = { list = {}, slots = 0, origins = {} }
	Model.hasRoster = false
	cards, byId = {}, {}
end

--- The cards, in the order they are drawn.
-- @author dop42
-- @return table[]
function Model.Cards()
	return cards
end

--- The card an id names, or nil.
-- @author dop42
-- @param id any
-- @return table|nil
function Model.Card(id)
	if type(id) ~= 'string' then return nil end
	local at = byId[id]
	return at ~= nil and cards[at] or nil
end

--- The card at a position, or nil.
-- @author dop42
-- @param index any
-- @return table|nil
function Model.At(index)
	if type(index) ~= 'number' or index % 1 ~= 0 then return nil end
	return cards[index]
end

--- The id the cursor starts on: the first character, else the first usable card.
-- @author dop42
-- @return string|nil
function Model.FirstFocus()
	for index = 1, #cards do
		if cards[index].kind == 'character' then return cards[index].id end
	end
	for index = 1, #cards do
		if cards[index].disabled == nil then return cards[index].id end
	end
	return cards[1] ~= nil and cards[1].id or nil
end

--- The id of the first card holding a character that was not there before.
-- A roster that gained a character answers a creation, whoever made it.
-- @author dop42
-- @param known table<string, boolean>
-- @return string|nil
function Model.FirstNew(known)
	for index = 1, #cards do
		local id = cards[index].citizenId
		if id ~= nil and known[id] == nil then return cards[index].id end
	end
	return nil
end

--- Renders a refusal code, or names one the catalogues do not carry.
-- The code IS the key: every refusal the server answers is a catalogue key, so
-- there is no table of codes here to fall out of step.
-- @author dop42
-- @param code any
-- @param params table|nil
-- @return string
function Model.Refusal(code, params)
	local key = type(code) == 'string' and code or 'error.unavailable'
	if OPX.Locale.Exists(key) then return locale(key, params) end
	return locale('entry.refusal.unknown', { code = key })
end

-- ── the creation form ────────────────────────────────────────────────────────

--- The lifepaths as options, sorted by key.
-- Sorted because `pairs` has no stable order: a list a player compares between
-- two sessions must not shuffle itself.
-- @author dop42
-- @return table[]
function Model.Origins()
	local keys = {}
	for key in pairs(Model.roster.origins) do
		if type(key) == 'string' and key ~= '' then keys[#keys + 1] = key end
	end
	table.sort(keys)

	local list = {}
	for index = 1, #keys do
		local key = keys[index]
		local entry = Model.roster.origins[key]
		list[index] = {
			id = key,
			label = type(entry) == 'table' and display(entry.label, MAX_VALUE) or key,
			note = type(entry) == 'table' and display(entry.description, MAX_NOTE) or '',
		}
	end
	return list
end

--- Whether any lifepath is known, which is what a creation needs before it starts.
-- @author dop42
-- @return boolean
function Model.HasOrigins()
	return #Model.Origins() > 0
end

--- The body families as options.
local function families()
	local list = {}
	for index = 1, #M.FAMILIES do
		local family = M.FAMILIES[index]
		list[index] = { id = family, label = locale('entry.body.' .. family), note = '' }
	end
	return list
end

--- The step ids, in order.
-- @author dop42
-- @return string[]
function Model.Steps()
	return STEPS
end

--- The position of a step id, or nil.
-- @author dop42
-- @param step any
-- @return integer|nil
function Model.StepAt(step)
	for index = 1, #STEPS do
		if STEPS[index] == step then return index end
	end
	return nil
end

--- The name bounds in force, mirrored from the character module's own.
local function nameBounds()
	local bounds = type(M.Settings.NAME) == 'table' and M.Settings.NAME or {}
	local minimum = math.floor(M.Number(bounds.MIN, 1))
	local maximum = math.floor(M.Number(bounds.MAX, minimum))
	if maximum < minimum then maximum = minimum end
	return minimum, maximum
end

--- The step that owns a field, so a refusal sends the form back to it.
-- @author dop42
-- @param field any
-- @return string|nil
function Model.StepOf(field)
	for index = 1, #STEPS - 1 do
		local owned = STEP_FIELDS[STEPS[index]]
		for at = 1, #owned do
			if owned[at] == field then return STEPS[index] end
		end
	end
	return nil
end

--- The rows one step draws, and which value they answer.
local function rowsFor(step, draft)
	if step == 'identity' then
		local _, maximum = nameBounds()
		return {
			{ id = 'firstName', kind = 'text', label = locale('entry.field.firstName'),
				value = display(draft.firstName, maximum),
				placeholder = locale('entry.hint.firstName'), max = maximum },
			{ id = 'lastName', kind = 'text', label = locale('entry.field.lastName'),
				value = display(draft.lastName, maximum),
				placeholder = locale('entry.hint.lastName'), max = maximum },
		}, nil
	end
	if step == 'birth' then
		return {
			{ id = 'birthDate', kind = 'text', label = locale('entry.field.birthDate'),
				value = display(draft.birthDate, M.BIRTH_MAX),
				placeholder = locale('entry.hint.birthDate'), max = M.BIRTH_MAX },
		}, nil
	end
	if step == 'lifepath' then
		local rows = Model.Origins()
		for index = 1, #rows do
			rows[index].kind = 'choice'
			rows[index].chosen = rows[index].id == draft.origin or nil
		end
		return rows, 'origin'
	end
	if step == 'body' then
		local rows = families()
		for index = 1, #rows do
			rows[index].kind = 'choice'
			rows[index].chosen = rows[index].id == draft.gender or nil
		end
		return rows, 'gender'
	end

	return {
		{ id = 'firstName', kind = 'fact', label = locale('entry.field.firstName'),
			value = display(draft.firstName, MAX_VALUE) },
		{ id = 'lastName', kind = 'fact', label = locale('entry.field.lastName'),
			value = display(draft.lastName, MAX_VALUE) },
		{ id = 'birthDate', kind = 'fact', label = locale('entry.field.birthDate'),
			value = display(draft.birthDate, MAX_VALUE) },
		{ id = 'origin', kind = 'fact', label = locale('entry.field.origin'),
			value = originLabel(draft.origin) },
		{ id = 'gender', kind = 'fact', label = locale('entry.field.gender'),
			value = bodyLabel(draft.gender) },
	}, nil
end

--- The whole frame one step of the form draws.
-- The draft comes back with it, so a step the player returns to is refilled with
-- what they typed rather than blank.
-- @author dop42
-- @param step string
-- @param draft table
-- @return table
function Model.Frame(step, draft)
	local at = Model.StepAt(step) or 1
	step = STEPS[at]

	local marks = {}
	for index = 1, #STEPS do
		marks[index] = { id = STEPS[index], label = locale('entry.step.' .. STEPS[index]) }
	end

	local rows, field = rowsFor(step, draft)
	return {
		step = step,
		index = at,
		total = #STEPS,
		steps = marks,
		count = locale('entry.step.count', { step = at, steps = #STEPS }),
		about = locale('entry.about.' .. step),
		field = field,
		rows = rows,
		-- The footer's two buttons, worded here: the page holds no English. On the
		-- first step there is no step to go back to, so back is what it really
		-- does -- it leaves the creation.
		actions = {
			back = at == 1 and locale('entry.action.cancel') or locale('entry.action.back'),
			next = locale('entry.action.next'),
			submit = locale('entry.action.submit'),
		},
		values = {
			firstName = draft.firstName,
			lastName = draft.lastName,
			birthDate = draft.birthDate,
			origin = draft.origin,
			gender = draft.gender,
		},
		last = at == #STEPS,
	}
end

--- Whether a date exists on the calendar, from 1900.
-- The form checks the shape and then the calendar: the pattern alone accepts
-- 9999-99-99 and 2077-02-31, which the server would otherwise be asked to store
-- for the life of the character.
local function realDate(value)
	local year, month, day = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if year == nil or year < 1900 then return false end
	if month == nil or month < 1 or month > 12 then return false end
	return day ~= nil and day >= 1 and day <= M.MONTH_DAYS[month]
end

-- What `OPX.Validate.Text` answers, and the message each answer becomes. It is
-- the same checker the server runs, so a message here is never a rule of its own.
local TEXT_REFUSAL = {
	type = 'entry.refusal.required',
	['not-utf8'] = 'entry.refusal.notText',
	['too-short'] = 'entry.refusal.tooShort',
	['too-long'] = 'entry.refusal.tooLong',
}

--- Checks one text value and answers a refusal message, or nil.
local function checkText(value, opts, format)
	local checked = Validate.Text(value, opts)
	if checked.ok then return nil end
	if checked.error == 'format' then return locale(format) end
	local key = TEXT_REFUSAL[checked.error] or 'entry.refusal.required'
	return locale(key, { min = opts.min, max = opts.max })
end

--- Checks one field and answers its refusal message, or nil.
local function checkField(id, values)
	local value = values[id]

	if id == 'firstName' or id == 'lastName' then
		local minimum, maximum = nameBounds()
		return checkText(value, { min = minimum, max = maximum, pattern = M.NAME_PATTERN },
			'entry.refusal.badName')
	end

	if id == 'birthDate' then
		local refused = checkText(value, { min = M.BIRTH_MIN, max = M.BIRTH_MAX,
			pattern = M.BIRTH_PATTERN }, 'entry.refusal.badDate')
		if refused ~= nil then return refused end
		-- The shape passed; the calendar is the second half of the same rule.
		if not realDate(OPX.String.Trim(value)) then
			return locale('entry.refusal.noSuchDate')
		end
		return nil
	end

	if id == 'origin' then
		if Model.roster.origins[value] == nil then return locale('entry.refusal.badChoice') end
		return nil
	end

	if id == 'gender' then
		if value ~= 'female' and value ~= 'male' then return locale('entry.refusal.badChoice') end
		return nil
	end

	return nil
end

--- Checks everything one step is responsible for.
-- @author dop42
-- @param step string
-- @param values table
-- @return string|nil the field that refused
-- @return string|nil its message
function Model.Check(step, values)
	if type(values) ~= 'table' then return 'firstName', locale('entry.refusal.required') end
	local fields = STEP_FIELDS[step]
	if fields == nil then return nil end
	for index = 1, #fields do
		local refused = checkField(fields[index], values)
		if refused ~= nil then return fields[index], refused end
	end
	return nil
end

--- The registration to send, once every step has been checked again.
-- The last step re-checks all five: a player who walked back and edited a field
-- must not submit a value no step happened to look at on the way forward.
-- @author dop42
-- @param values table
-- @return table|nil
-- @return string|nil the field that refused
-- @return string|nil its message
function Model.Registration(values)
	local field, message = Model.Check('review', values)
	if field ~= nil then return nil, field, message end
	return {
		firstName = OPX.String.Trim(values.firstName),
		lastName = OPX.String.Trim(values.lastName),
		birthDate = OPX.String.Trim(values.birthDate),
		origin = values.origin,
		gender = values.gender,
	}
end

--- Keeps only the five answers, as strings, so a reopened form comes back filled.
-- @author dop42
-- @param values any
-- @return table
function Model.Draft(values)
	local kept = {}
	if type(values) ~= 'table' then return kept end
	local fields = STEP_FIELDS.review
	for index = 1, #fields do
		local id = fields[index]
		if type(values[id]) == 'string' then kept[id] = values[id] end
	end
	return kept
end
