--- Command registration, the short aliases beside it, and the suggestions the
--- chat box asks for.
-- @author dop42
--
-- A module registers here rather than calling `RegisterCommand` directly, so
-- that one place knows every command's name, whether it is restricted, and what
-- to suggest. Registering without the chat box learning the restricted flag is
-- how a suggestion ends up offered to someone the ACL will refuse.
--
-- The host resolves `command.<name>` against the ACL BEFORE the handler runs, so
-- nothing here grants anything. `acl.read` is read-only and is used for two
-- things: not suggesting a command the player could not run anyway, and gating
-- an alias on the entry of the command it is an alias FOR -- see `Register`.
--
-- ALIASES. Every command in this resource is spelt `opx.something`, and typing
-- that prefix forty times an evening is the complaint this answers. An alias is
-- a SECOND host registration of one handler under a short name, configured in
-- `OPX.Config.SERVER.COMMAND_ALIASES`. Three properties hold and each is worth
-- more than the convenience:
--
--   * the long name never changes and never stops working. `acl.jsonc`,
--     `config/admin.lua`'s LINKS block, the staff menu and the eye all name
--     commands by their full spelling, and nothing here touches that.
--   * an alias the host will not give us costs the alias and nothing else. It
--     is logged and skipped; the boot does not die and the long name is there.
--   * an alias can never be less restricted than its command, because it is
--     gated on the COMMAND's ACL entry and not on its own name.

OPX.Command = OPX.Command or {}

local registered = {}

-- Every command name and every alias this resource has taken, lower-cased,
-- mapped to the command that owns it.
--
-- LOWER-CASED BECAUSE THE HOST MATCHES THAT WAY. `RegisterCommand` matches names
-- case-insensitively -- `opx.Foo` and `opx.foo` are one name to it, and the
-- second raises `duplicate command`. The old check here was `registered[name]`,
-- an exact-match index, so those two got past the legible refusal below and
-- raised inside the host instead, naming neither caller. This index is the one
-- the host would keep.
local taken = {}

--- Whether the ACL would let this player run a restricted command. A read that
--- raises counts as a refusal: the command is then suggested to nobody rather
--- than to everybody.
---
--- THE INDEX IS INSIDE THE PCALL, and it was not. `pcall(Open77.acl.isAllowed,
--- ...)` resolves `Open77.acl.isAllowed` BEFORE pcall is called, so a host that
--- does not install `Open77.acl` -- one without the `acl.read` grant, or an
--- older build -- raised on the index, outside the protection written for
--- exactly that. The paragraph above described behaviour the code did not have.
---
--- THE NAME IS LOWER-CASED, and it was asked as spelt. The host resolves
--- `command.<name>` against the LOWER-CASED registration -- which is why `taken`
--- below is a lower-cased index and why `configuredAlias` lower-cases -- so a
--- command registered as `opx.Foo` was gated by the host on `command.opx.foo`
--- while this asked about `command.opx.Foo`: a different ACL entry, and one
--- nobody has written down. Every name in this resource happens to be lower-case
--- today, so the two agreed by luck rather than by construction.
local function permitted(source, name)
	local read, allowed = pcall(function()
		return Open77.acl.isAllowed(source, 'command.' .. name:lower())
	end)
	return read and allowed == true
end

--- The short spelling an operator wants for this command, or nil.
---
--- KEYED BY THE FULL NAME, and that is the whole reason this is a config table
--- rather than anything cleverer. Two alternatives were weighed:
---
---   * A DERIVED RULE -- `opx.foo.bar` becomes `bar`, or `foobar`. It is a
---     collision generator on this resource's own names: `opx.admin.self.heal`
---     and `opx.admin.player.heal` both derive to `heal`, and so do the `.god`,
---     `.revive` and `.model` pairs; `opx.inventory.give` and
---     `opx.admin.inventory.give` both derive to `give`; `opx.weather.set`
---     derives to `set`. Six collisions out of eighty names, resolved by
---     whichever module started first, is not a rule -- it is a coin toss with
---     a privilege on one side of it.
---   * AN `alias` FIELD ON EACH `Register` CALL. Most commands are not
---     registered at a literal call site: roughly sixty come out of one loop
---     over `modules/admin/module.lua`'s `M.Command`, and `garages`,
---     `dealership`, `clothing` and `appearance` each register from a table of
---     their own. The field would have to be threaded through five wrappers,
---     and it would put what is purely an operator's keyboard preference inside
---     module code where they cannot reach it.
---
--- The objection to a hand-written list is real -- this repo spent a day
--- deleting three copies of one glyph vocabulary that had drifted to 47, 45 and
--- 14 entries. It does not apply here, and the difference is the direction of
--- the key. Those were three COMPLETE copies of one list, each of which had to
--- grow when the list did. This is a PARTIAL INDEX INTO a list it does not
--- duplicate: adding a command requires no entry here, and an entry naming a
--- command nobody registers is inert -- it never fires, because nothing ever
--- looks it up.
-- @param name string the full command name
-- @return string|nil
local function configuredAlias(name)
	local server = type(OPX.Config) == 'table' and OPX.Config.SERVER or nil
	local aliases = type(server) == 'table' and server.COMMAND_ALIASES or nil
	if type(aliases) ~= 'table' then return nil end
	if type(aliases[name]) ~= 'string' then return nil end
	-- Lower-cased because the host matches that way and `command.<name>` is
	-- resolved against the lower-cased name; trimmed because a stray space in a
	-- config file is a name nobody can ever type.
	local alias = OPX.String.Trim(aliases[name]):lower()
	if alias == '' then return nil end
	return alias
end

--- Why this alias may not be taken, or nil when it may. Every answer costs the
--- alias and nothing else: the full name is registered before this runs.
-- @param alias string already trimmed and lower-cased
-- @return string|nil
local function aliasRefusal(alias)
	-- THE HOST'S OWN GRAMMAR, checked here so the raise never happens. A name
	-- outside 1..64 characters of letters, digits, `_`, `.`, `:` or `-` makes
	-- `RegisterCommand` raise, and that raise comes out of whichever module's
	-- `Start` was halfway through -- which is how `opx.appearance` took the
	-- clothing-load hook down with it.
	if #alias > 64 or alias:match('^[%w_%.:%-]+$') == nil then
		return 'it is not a legal command name'
	end

	-- AN ALIAS INSIDE OUR OWN NAMESPACE IS THE ONE WAY THIS FEATURE COULD KILL A
	-- BOOT, and this closes it completely rather than mostly. Aliases are taken
	-- as each module starts, so an alias spelt `opx.something` could take a name
	-- a module registered LATER wants -- and a long name's registration is
	-- deliberately fatal, so that later module would raise and unwind. There is
	-- no way back either: the host's `unregisterCommand` exists on the client
	-- runtime only, so an alias, once taken, is taken for the session. An alias
	-- is by definition the SHORT spelling, so refusing the prefix costs an
	-- operator nothing and makes the collision impossible instead of unlikely.
	if alias:sub(1, 4) == 'opx.' then
		return 'an alias may not be spelt inside the opx. namespace'
	end

	local owner = taken[alias]
	if owner ~= nil then
		return ('%q already answers to it'):format(owner)
	end

	-- WHAT THE REST OF THE SESSION HAS ALREADY TAKEN. `taken` knows only what
	-- this resource registered, and the session also runs open77_shell,
	-- open77_pause, open77_voice, open-voice, open77_weapons,
	-- open77_interactions and open77_props -- any of which may already own a
	-- bare word like `noclip`, which is exactly why a bare name is a worse bet
	-- than a prefixed one. `Open77.runtime.commands` is the registry for
	-- commands that `Open77.input.mappings` is for keys, and its card says it
	-- needs no capability: it is a read of the operator's own installation, so
	-- nothing is added to the manifest for it.
	--
	-- It is a CHECK AND NOT THE CHECK. Its own documentation says the ACL, ban,
	-- routing-bucket and phantom verbs are absent from it, because they live in
	-- a hand-written dispatcher with no registry to read -- so a name can be
	-- free here and taken by the host. The pcall in `Register` is the authority;
	-- this only means the common case never reaches a raise whose catchability
	-- the devkit does not actually document.
	local listed = nil
	if type(GetRegisteredCommands) == 'function' then
		local read, rows = pcall(GetRegisteredCommands)
		listed = read and type(rows) == 'table' and rows or nil
	end
	for _, row in ipairs(listed or {}) do
		if type(row) == 'table' and type(row.name) == 'string'
			and row.name:lower() == alias then
			return ('%s already registers it'):format(tostring(row.resource or 'another resource'))
		end
	end

	return nil
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

	-- REFUSED HERE RATHER THAN BY THE HOST, and named. `RegisterCommand` raises
	-- on a name it already has, so a duplicate was always fatal; what it was not
	-- was legible. The raise came out of the host with no idea which two callers
	-- collided, unwinding whichever module's `Start` was halfway through -- and
	-- it happened, to `opx.appearance`, taking the clothing-load hook with it.
	--
	-- The row is also written AFTER the host agrees, not before. It used to be
	-- written first, so the loser's help text and restricted flag stayed in the
	-- suggestion list for a command the host had just refused to give it.
	--
	-- The lookup is through `taken` and not `registered`, so it is case-blind
	-- like the host and so it also catches a long name an ALIAS already holds.
	local owner = taken[name:lower()]
	if owner ~= nil then
		error(('Register(%q): %q is already registered'):format(name, owner), 2)
	end

	-- A COOLDOWN THAT IS NOT A NUMBER IS REFUSED, not quietly turned off. This
	-- read `tonumber(opts.cooldownMs) or 0` and the gate below is `if cooldownMs
	-- > 0`, so `cooldownMs = '5000'` worked by accident while `cooldownMs =
	-- Config.SOMETHING_MISSPELLED` silently removed the rate limit from a
	-- command that had asked for one. Absent is the normal case and stays legal;
	-- present and not a number is a typo, and the only thing it can do here is
	-- take a guard away.
	local cooldownMs = 0
	if opts.cooldownMs ~= nil then
		cooldownMs = tonumber(opts.cooldownMs)
		if cooldownMs == nil or cooldownMs < 0 then
			error(('Register(%q): cooldownMs must be a number of milliseconds, got %s')
				:format(name, type(opts.cooldownMs)), 2)
		end
	end
	local key = opts.key or ('command.' .. name)
	local restricted = opts.restricted == true

	-- ONE BODY, REACHED BY BOTH SPELLINGS, and the cooldown key is closed over
	-- here rather than derived from the name the caller typed. That is the whole
	-- of the shared-window guarantee: `noclip` and `opx.admin.self.noclip` are
	-- one operation, so they must be one window. Deriving the key inside would
	-- give the alias a second independent floor and let an operator halve every
	-- rate limit in the resource by typing the short name and the long one
	-- alternately.
	local function run(source, args, raw)
		-- The gate cooldown is checked before anything the handler might do,
		-- and on its own key: sharing the key of the operation the handler
		-- consumes would make the operation refuse itself.
		if cooldownMs > 0 and OPX.Cooling(source, key, cooldownMs) then
			return OPX.Refuse(source, 'error.tooFast', name)
		end
		handler(source, args or {}, raw or '')
	end

	local entry = {
		name = name,
		restricted = restricted,
		help = opts.help,
		params = opts.params or {},
	}
	RegisterCommand(name, run, restricted)
	registered[name] = entry
	taken[name:lower()] = name

	local alias = configuredAlias(name)
	if alias == nil then return end

	local refusal = aliasRefusal(alias)
	if refusal == nil then
		-- THE HOST IS THE AUTHORITY ON WHETHER A NAME IS FREE, and this pcall is
		-- the only thing that actually asks it. Everything above is a courtesy
		-- that names the culprit; this is the check that cannot be wrong. It is
		-- also the reason a collision costs the alias and never the boot: the
		-- long name is already registered on the line above, so whatever comes
		-- back here, `opx.admin.self.noclip` works.
		local claimed, why = pcall(RegisterCommand, alias, function(source, args, raw)
			-- AN ALIAS MAY NOT BE LESS RESTRICTED THAN ITS COMMAND, and this is
			-- the line that makes that true. The obvious spelling -- passing
			-- `restricted` to `RegisterCommand` below and stopping -- does NOT
			-- make it true, for a reason that is easy to miss: the host resolves
			-- the ACL against the name it was REGISTERED under, so a restricted
			-- `noclip` is gated on `command.noclip`. That is a DIFFERENT entry
			-- from `command.opx.admin.self.noclip`, and it is one nobody has
			-- written down -- grants in `acl.jsonc` are exact strings, `*`, or a
			-- trailing wildcard, and no `command.opx.*` wildcard covers a bare
			-- word. So the alias would be dead for everybody, and the repair an
			-- operator would reach for -- adding `command.noclip` -- is the
			-- actual bug: one power with two ACL keys, revocable out of step,
			-- and the day somebody removes the long one and forgets the short
			-- one the alias is a privilege escalation with a paper trail saying
			-- the access was revoked.
			--
			-- So the alias asks the ACL about the COMMAND's entry instead. One
			-- power, one key, and the answer is by construction the same answer
			-- the long name got. The host is told `false` below because its own
			-- gate could only ever ask the wrong question.
			--
			-- A READ THAT RAISES COUNTS AS A REFUSAL, the same rule `permitted`
			-- follows: on a host with no `Open77.acl` -- no `acl.read`, an older
			-- build -- every restricted alias goes inert and every long name
			-- still works, which is the degradation this whole feature is built
			-- around. Defaulting to yes here would turn an unreadable ACL into
			-- an open door on sixty staff commands.
			--
			-- The console is source 0. The host lets the console run any
			-- restricted command, and `isAllowed` answers `invalid_player_id`
			-- for it rather than yes, so asking would lock the server's own
			-- console out of every alias while leaving it the long name.
			--
			-- THE CONSOLE IS NAMED, NOT DEFAULTED TO. This read was
			-- `tonumber(source) or 0` followed by `player > 0`, so ANY source that
			-- does not parse -- nil, a table, a string the host did not format as
			-- a number -- folded to 0 and skipped the check entirely. The alias is
			-- registered unrestricted on purpose, so this branch is the only thing
			-- between a bare `god`/`noclip`/`freeze` and every player on the
			-- server. Every other source read in this runtime rejects that input
			-- (`core/client/note.lua`, `core/server/answer.lua`, `core/server/gate.lua`);
			-- this is the one place a source is read as PERMISSION, which is the
			-- one place it may not be guessed at.
			local player = tonumber(source)
			local console = source == nil or player == 0
			if restricted and not console then
				if player == nil or player < 0 or not permitted(player, name) then
					return OPX.Refuse(source, 'error.noPermission', name)
				end
			end
			return run(source, args, raw)
		end, false)
		if claimed then
			taken[alias] = name
			entry.alias = alias
			return
		end
		refusal = ('the host refused it (%s)'):format(tostring(why))
	end

	-- AN OPERATOR HAS TO BE ABLE TO SEE THIS. They wrote the alias in
	-- `config/server.lua` and it is not there; without a line they find out by
	-- typing it and getting nothing, which reads as the whole feature being
	-- broken. `Open77.log` HERE is the server's own journal, the one the server
	-- is run from -- the warning in `core/client/note.lua` about logs landing on
	-- the player's machine is about the client half, and `OPX.Note` is that
	-- half's relay into this journal. There is nothing to relay from: this runs
	-- on the server, at start, before any player exists.
	Open77.log.warn(('[commands] the alias %q for %q was skipped: %s')
		:format(alias, name, refusal))
end

--- Every command this player may be shown, with its help text resolved now
--- rather than at registration: the catalogue is read at send time so a language
--- change is reflected without re-registering anything.
---
--- A COMMAND WITH A LIVE ALIAS IS OFFERED UNDER THE ALIAS AND NOT BESIDE IT.
--- Both spellings work whatever this list says -- the chat box is a typing aid,
--- not the dispatcher -- so the only question is which one helps. Two rows per
--- command turns an eighty-row list into a hundred and sixty and buries the
--- short spelling among the long ones, which is the exact problem the aliases
--- were added to solve. The long name stays the one that `acl.jsonc`,
--- `config/admin.lua`'s LINKS block, the staff menu and the eye all use, and it
--- stays typeable; it just is not the one suggested.
-- @author dop42
-- @param source Source
-- @return table[]
function OPX.Command.Suggestions(source)
	local list = {}
	for _, entry in pairs(registered) do
		if not entry.restricted or permitted(source, entry.name) then
			list[#list + 1] = {
				name = entry.alias or entry.name,
				help = entry.help and locale(entry.help) or nil,
				params = entry.params,
			}
		end
	end
	-- pairs has no order, and two players must be offered the same list. Sorted
	-- on the name actually shown, so an aliased row lands where a reader looking
	-- for it would look rather than where its long name would have put it.
	table.sort(list, function(left, right) return left.name < right.name end)
	return list
end

--- Whether a command is registered here, and whether it is restricted.
---
--- ANSWERS FOR AN ALIAS TOO, with the COMMAND's restricted flag. A caller asking
--- "may anyone run this?" must get the same answer for both spellings of one
--- command, or this function becomes the way to launder a restricted command
--- into an unrestricted-looking one. Case-blind, because the host is.
-- @author dop42
-- @param name string a command name or an alias
-- @return boolean registered
-- @return boolean restricted
function OPX.Command.Known(name)
	if type(name) ~= 'string' then return false, false end
	local owner = taken[name:lower()]
	local entry = owner ~= nil and registered[owner] or nil
	if entry == nil then return false, false end
	return true, entry.restricted
end

--- Every alias in force, mapped to the command it answers for. For an operator
--- asking what actually took, after the journal has scrolled: the answer is not
--- `config/server.lua`, because an entry there may have been skipped.
-- @author dop42
-- @return table<string, string>
-- @return integer how many
function OPX.Command.Aliases()
	local out = {}
	for _, entry in pairs(registered) do
		if entry.alias ~= nil then out[entry.alias] = entry.name end
	end
	return out, OPX.Table.Count(out)
end
