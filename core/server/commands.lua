--- Command registration, and the suggestions the chat box asks for.
-- @author dop42
--
-- A module registers here rather than calling `RegisterCommand` directly, so
-- that one place knows every command's name, whether it is restricted, and what
-- to suggest. Registering without the chat box learning the restricted flag is
-- how a suggestion ends up offered to someone the ACL will refuse.
--
-- The host resolves `command.<name>` against the ACL BEFORE the handler runs, so
-- nothing here grants anything. `acl.read` is read-only and is used for one
-- thing: not suggesting a command the player could not run anyway.

OPX.Command = OPX.Command or {}

local registered = {}

--- Whether the ACL would let this player run a restricted command. A read that
--- raises counts as a refusal: the command is then suggested to nobody rather
--- than to everybody.
local function permitted(source, name)
	local read, allowed = pcall(Open77.acl.isAllowed, source, 'command.' .. name)
	return read and allowed == true
end

--- Registers a command and remembers it for the suggestion list.
--- `opts.restricted` gates `command.<name>` in the host ACL. `opts.cooldownMs`
--- applies a per-player window on the way in, shared with any other door into
--- the same operation through `opts.key`.
-- @author dop42
-- @param name string without the leading slash
-- @param opts table restricted, help, params, cooldownMs, key
-- @param handler fun(source: Source, args: string[], raw: string)
function OPX.Command.Register(name, opts, handler)
	if type(name) ~= 'string' or name == '' or type(handler) ~= 'function' then
		error('Register(name, opts, handler)', 2)
	end
	opts = opts or {}

	registered[name] = {
		name = name,
		restricted = opts.restricted == true,
		help = opts.help,
		params = opts.params or {},
	}

	local cooldownMs = tonumber(opts.cooldownMs) or 0
	local key = opts.key or ('command.' .. name)

	RegisterCommand(name, function(source, args, raw)
		-- The gate cooldown is checked before anything the handler might do,
		-- and on its own key: sharing the key of the operation the handler
		-- consumes would make the operation refuse itself.
		if cooldownMs > 0 and OPX.Cooling(source, key, cooldownMs) then
			return OPX.Refuse(source, 'error.tooFast', name)
		end
		handler(source, args or {}, raw or '')
	end, opts.restricted == true)
end

--- Every command this player may be shown, with its help text resolved now
--- rather than at registration: the catalogue is read at send time so a language
--- change is reflected without re-registering anything.
-- @author dop42
-- @param source Source
-- @return table[]
function OPX.Command.Suggestions(source)
	local names = {}
	for name in pairs(registered) do names[#names + 1] = name end
	-- pairs has no order, and two players must be offered the same list.
	table.sort(names)

	local list = {}
	for index = 1, #names do
		local entry = registered[names[index]]
		if not entry.restricted or permitted(source, entry.name) then
			list[#list + 1] = {
				name = entry.name,
				help = entry.help and locale(entry.help) or nil,
				params = entry.params,
			}
		end
	end
	return list
end

--- Whether a command is registered here, and whether it is restricted.
-- @author dop42
-- @param name string
-- @return boolean registered
-- @return boolean restricted
function OPX.Command.Known(name)
	local entry = registered[name]
	if entry == nil then return false, false end
	return true, entry.restricted
end
