--- Table helpers: a cycle-safe deep copy and a key count.
-- @author dop42

OPX.Table = {}
local Table = OPX.Table

--- Copies a value deeply, terminating on self-referencing tables.
-- Every table met is recorded in seen before its contents are walked, so a
-- table that reaches itself resolves to the copy already under construction
-- instead of recursing until the stack gives out. Keys are copied too, so a
-- table used as a key keeps its identity with the value it was stored under.
-- @author dop42
-- @param source any
-- @param seen table|nil Already-copied table to its copy.
-- @return any
function OPX.Table.DeepCopy(source, seen)
	if type(source) ~= 'table' then return source end
	seen = seen or {}
	if seen[source] then return seen[source] end

	local out = {}
	seen[source] = out
	for key, value in pairs(source) do
		out[Table.DeepCopy(key, seen)] = Table.DeepCopy(value, seen)
	end
	return out
end

--- Counts every key of a table, array part included.
-- @author dop42
-- @param source table
-- @return integer
function OPX.Table.Count(source)
	local n = 0
	for _ in pairs(source) do n = n + 1 end
	return n
end
