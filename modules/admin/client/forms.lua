--- The forms that ask for a value a menu row cannot hold.
-- @author dop42
--
-- Every form ends in a command line, and the dangerous ones end in a
-- CONFIRMATION screen rather than in the command: a ban typed into a field is one
-- keystroke from happening, and the confirm step is what makes it two.
--
-- The job, gang and money lists are read from `OPX.Config`, which is operator
-- data every script already carries, and not from the `character` contract: its
-- client half publishes what the local player IS, and never the catalogue of what
-- anybody could be. A missing section costs that one form and nothing else.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text
local Command = M.Command

M.Forms = {}
local Forms = M.Forms

-- Patterns a typed decimal and a typed whole number must match.
local NUMBER = '^%-?%d+%.?%d*$'
local INTEGER = '^%-?%d+$'

-- The open form's handle while one is up.
local handle

-- The menu module, read when called: it loads after this file.
local function menu()
	return M.Menu
end

-- One text field with its label and its extra properties.
local function text(id, labelKey, extra)
	local field = { id = id, label = locale(labelKey) }
	for key, value in pairs(extra or {}) do field[key] = value end
	return field
end

-- The LINKS table, or an empty one.
local function links()
	return M.Section('LINKS')
end

-- Options from a configured group table, sorted by label.
local function groupOptions(key)
	local character = OPX.Config.MODULES.character
	local groups = type(character) == 'table' and character[key] or nil
	if type(groups) ~= 'table' then return nil end
	local options = {}
	for name, group in pairs(groups) do
		options[#options + 1] = { label = ('%s (%s)'):format(tostring(group.label or name), name),
			value = name }
	end
	table.sort(options, function(left, right) return left.label < right.label end)
	return options
end

-- Every form by kind: how it is built and what it runs.
local FORMS = {}

FORMS.health = {
	build = function()
		return { title = locale('admin.form.health'), fields = {
			{ id = 'points', label = locale('admin.field.points'),
				slider = { min = 0, max = 100, step = 5, value = 100 } },
		} }
	end,
	submit = function(values, arg)
		local points = math.floor(Text.Finite(values.points) or 0)
		menu().Run({ Command.PLAYER_HEALTH, tostring(arg), ('%d'):format(points) })
	end,
}

FORMS.armor = {
	build = function()
		return { title = locale('admin.form.armor'), fields = {
			text('points', 'admin.field.points', { value = '100', charset = 'digits', maxLength = 5,
				required = true }),
		} }
	end,
	submit = function(values, arg)
		menu().Run({ Command.PLAYER_ARMOR, tostring(arg), values.points })
	end,
}

-- A job or gang form: the configured groups, and a typed grade.
local function groupForm(key, titleKey, linkName)
	return {
		build = function()
			local options = groupOptions(key)
			if options == nil or #options == 0 then return nil end
			return { title = locale(titleKey), fields = {
				{ id = 'group', label = locale('admin.field.group'), options = options },
				text('grade', 'admin.field.grade', { value = '0', charset = 'digits', maxLength = 2,
					required = true }),
			} }
		end,
		submit = function(values, arg)
			local link = links()[linkName]
			if type(link) ~= 'string' then return end
			menu().Run({ link, tostring(arg), values.group, values.grade })
		end,
	}
end

FORMS.job = groupForm('JOBS', 'admin.form.job', 'JOB')
FORMS.gang = groupForm('GANGS', 'admin.form.gang', 'GANG')

FORMS.money = {
	build = function()
		local money = OPX.Config.SHARED.MONEY
		local types = type(money) == 'table' and money.TYPES or nil
		if type(types) ~= 'table' then return nil end
		local options = {}
		for name in pairs(types) do options[#options + 1] = name end
		table.sort(options)
		if #options == 0 then return nil end
		return { title = locale('admin.form.money'), description = locale('admin.form.moneyHint'),
			fields = {
				{ id = 'type', label = locale('admin.field.moneyType'), options = options },
				text('amount', 'admin.field.amount', { pattern = INTEGER, maxLength = 10,
					required = true }),
			} }
	end,
	submit = function(values, arg)
		local link = links().MONEY
		if type(link) ~= 'string' then return end
		menu().Run({ link, tostring(arg), values.type, values.amount })
	end,
}

-- A count form for giving or removing items of a picked row.
local function countForm(titleKey, commandName, refresh)
	return {
		build = function(arg)
			if type(arg) ~= 'table' or type(arg.n) ~= 'string' then return nil end
			local held = Text.Integer(arg.c)
			local label = tostring(arg.l or arg.n)
			return { title = locale(titleKey),
				description = held and locale('admin.form.itemHeld', { label = label, count = held })
					or label,
				fields = {
					text('count', 'admin.field.count', { value = '1', charset = 'digits', maxLength = 6,
						required = true }),
				} }
		end,
		submit = function(values, arg)
			menu().Run({ commandName, tostring(arg.t), arg.n, values.count }, refresh)
		end,
	}
end

FORMS.itemGive = countForm('admin.form.itemGive', Command.INVENTORY_GIVE)
FORMS.itemRemove = countForm('admin.form.itemRemove', Command.INVENTORY_REMOVE, 'bag')
FORMS.ammoGive = countForm('admin.form.ammoGive', Command.WEAPON_GIVEAMMO)

FORMS.kick = {
	build = function()
		return { title = locale('admin.form.kick'), fields = {
			text('reason', 'admin.field.reason', { maxLength = 120 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.MODERATE_KICK, tostring(arg) }
		if M.Trimmed(values.reason, 120) then tokens[3] = values.reason end
		menu().Confirm(tokens, 'admin.confirm.kick')
	end,
}

FORMS.ban = {
	build = function()
		local options = {}
		local configured = M.Settings.BAN_DURATIONS
		for _, word in ipairs(type(configured) == 'table' and configured or {}) do
			options[#options + 1] = tostring(word)
		end
		if #options == 0 then options[1] = 'perm' end
		return { title = locale('admin.form.ban'), fields = {
			{ id = 'duration', label = locale('admin.field.duration'), options = options },
			text('reason', 'admin.field.reason', { maxLength = 120 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.MODERATE_BAN, tostring(arg), values.duration }
		if M.Trimmed(values.reason, 120) then tokens[4] = values.reason end
		menu().Confirm(tokens, 'admin.confirm.ban')
	end,
}

FORMS.announce = {
	build = function()
		local maximum = math.floor(M.Bounded('ANNOUNCE.MAX_CHARACTERS',
			M.Section('ANNOUNCE').MAX_CHARACTERS, 1, 512, 240))
		return { title = locale('admin.form.announce'), fields = {
			text('message', 'admin.field.message', { maxLength = maximum, required = true }),
		} }
	end,
	submit = function(values)
		menu().Confirm({ Command.WORLD_ANNOUNCE, values.message }, 'admin.confirm.announce')
	end,
}

FORMS.coords = {
	build = function()
		return { title = locale('admin.form.coords'), fields = {
			text('x', 'admin.field.x', { pattern = NUMBER, maxLength = 12, required = true }),
			text('y', 'admin.field.y', { pattern = NUMBER, maxLength = 12, required = true }),
			text('z', 'admin.field.z', { pattern = NUMBER, maxLength = 12, required = true }),
			text('heading', 'admin.field.heading', { pattern = NUMBER, maxLength = 8 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.PLAYER_TP, tostring(arg or 'me'), values.x, values.y, values.z }
		if Text.Finite(values.heading) then tokens[6] = values.heading end
		menu().Run(tokens)
	end,
}

FORMS.location = {
	build = function()
		return { title = locale('admin.form.location'), fields = {
			text('name', 'admin.field.locationName', { pattern = '^[%w_%-]+$', maxLength = 32,
				required = true }),
			text('label', 'admin.field.label', { maxLength = 48 }),
		} }
	end,
	submit = function(values)
		local tokens = { Command.WORLD_LOC_ADD, values.name }
		if M.Trimmed(values.label, 48) then tokens[3] = values.label end
		menu().Run(tokens, 'locations')
	end,
}

FORMS.time = {
	build = function()
		return { title = locale('admin.form.time'), fields = {
			text('time', 'admin.field.time', { pattern = '^%d%d?:%d%d$', maxLength = 5,
				value = '12:00', required = true }),
		} }
	end,
	submit = function(values)
		local link = links().TIME
		if type(link) ~= 'string' then return end
		menu().Run({ link, values.time })
	end,
}

-- Turns one answer into its command, or brings the menu back.
local function onAnswer(payload)
	if type(payload) ~= 'table' then return end
	if payload.handle ~= nil and handle ~= nil and payload.handle ~= handle then return end
	handle = nil
	local data = type(payload.data) == 'table' and payload.data or {}
	local form = FORMS[data.form]
	if payload.action ~= 'submit' or form == nil or type(payload.values) ~= 'table' then
		return menu().Resume()
	end
	form.submit(payload.values, data.arg)
end

--- Takes the menu down and puts one form up.
-- @author dop42
-- @param kind string
-- @param arg any
-- @return boolean
function Forms.Open(kind, arg)
	local form = FORMS[kind]
	if form == nil then return false end
	local contract = Client.Contract('form')
	if contract == nil then
		menu().Status(locale('admin.client.formMissing'), false)
		return false
	end

	-- Built before the menu is taken down, so a form that cannot be built costs
	-- the operator nothing.
	local spec = form.build(arg)
	if spec == nil then
		menu().Status(locale('admin.client.formUnavailable'), false)
		return false
	end
	spec.owner = M.OWNER
	spec.id = 'admin.' .. kind
	spec.data = { form = kind, arg = arg }
	spec.on = onAnswer

	menu().Suspend()
	local opened = contract.Open(spec)
	if not opened.ok then
		Open77.log.warn(('[admin] form %s did not open: %s'):format(kind, tostring(opened.error)))
		menu().Resume(locale('admin.client.formUnavailable'), false)
		return false
	end
	handle = opened.value.handle
	return true
end

--- Whether a form of this module is up.
-- @author dop42
-- @return boolean
function Forms.IsOpen()
	return handle ~= nil
end

--- Takes the open form down, if there is one.
-- @author dop42
function Forms.Close()
	if handle == nil then return end
	local closing = handle
	handle = nil
	local contract = Client.Contract('form')
	if contract ~= nil then contract.Close(closing) end
end
