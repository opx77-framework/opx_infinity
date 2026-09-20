--- Database access through the MySQL bridge, answering Result values.
-- @author dop42
--
-- This is the only place that talks to the bridge. `MySQL` is an alias of
-- `Open77.database`, installed only with the `database.access` permission, so it
-- is read through `rawget` and may be absent.
--
-- Every call yields, so it must come from a `CreateThread` -- never from file
-- scope, and never from an event handler that is not itself on a thread.
--
-- `MySQL.<method>.await` RAISES instead of answering `value, reason`, and an
-- error raised inside a `CreateThread` kills that thread silently. `run` wraps
-- every call in a `pcall` and answers a `Result` instead: `no-database` when the
-- bridge is not installed, `query-failed` carrying the raw exception as `detail`.
-- A `nil` value is an empty result, not a failure: `single` answers `nil` for
-- 'no rows'.
--
-- Statements use named parameters (`@citizen`) rather than `?`, and NO comment
-- may appear inside a SQL string: the bridge rewrites `?` by walking the query
-- text and a comment inside it is not seen as one.

local Result = OPX.Result

OPX.Storage = {}
local Storage = OPX.Storage

-- nil until the probe has run, then kept for the life of the resource.
local ready = nil
local readyReason = 'not probed'

--- Runs one bridge method, turning a raise into a Result.
local function run(method, sql, params)
	local api = MySQL
	local fn = api and api[method]
	if not fn or type(fn.await) ~= 'function' then
		return Result.Err('no-database', ('MySQL.%s.await is unavailable'):format(method))
	end

	local ok, value = pcall(fn.await, sql, params)
	if not ok then
		return Result.Err('query-failed', tostring(value))
	end
	return Result.Ok(value)
end

--- Runs a statement answering a list of rows.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Query(sql, params) return run('query', sql, params) end

--- Runs a statement answering one row, or nil.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Single(sql, params) return run('single', sql, params) end

--- Runs a statement answering one column of one row.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Scalar(sql, params) return run('scalar', sql, params) end

--- Runs an insert answering the inserted id.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Insert(sql, params) return run('insert', sql, params) end

--- Runs a write or DDL statement answering the rows affected.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Update(sql, params) return run('update', sql, params) end

--- Runs a write whose answer nobody reads, an alias of update.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Execute(sql, params) return run('update', sql, params) end

--- Commits several statements as one unit, or none of them.
-- @author dop42
--
-- Separate from `run` because it is the one bridge method that resolves
-- `false, reason` instead of raising: routed through `run`, a rollback would
-- read as a success. It distinguishes `transaction-raised` (the bridge raised)
-- from `transaction-failed` (the bridge rolled back).
-- @param statements table a list of { query, parameters } pairs
-- @return Result
function OPX.Storage.Transaction(statements)
	local api = MySQL
	local fn = api and api.transaction
	if not fn or type(fn.await) ~= 'function' then
		return Result.Err('no-database', 'MySQL.transaction.await is unavailable')
	end

	local ok, committed, reason = pcall(fn.await, statements)
	if not ok then
		return Result.Err('transaction-raised', tostring(committed))
	end
	if committed ~= true then
		return Result.Err('transaction-failed', tostring(reason))
	end
	return Result.Ok(true)
end

--- Decodes a JSON column, answering the fallback when it cannot.
-- @author dop42
--
-- Accepts either a string or an already-decoded table, because one bridge
-- version does the one and another does the other. A column that will not decode
-- is absent rather than fatal: the row loads with the fallback.
-- @param value any
-- @param fallback table|nil
-- @return table|nil
function OPX.Storage.Decode(value, fallback)
	if type(value) == 'table' then return value end
	if type(value) ~= 'string' or value == '' then return fallback end
	local ok, decoded = pcall(json.decode, value)
	if not ok or type(decoded) ~= 'table' then return fallback end
	return decoded
end

--- Binds a nullable JSON column, absence as an empty string.
-- @author dop42
--
-- The bridge DROPS a `nil` parameter instead of binding NULL, and MySqlConnector
-- then refuses the query (`Parameter '@x' must be defined`). So a nullable column
-- receives `''` for 'nothing' and the statement turns it back with
-- `NULLIF(@x, '')`: encoded JSON is never the empty string.
-- @param value any
-- @return string
function OPX.Storage.Nullable(value)
	return value ~= nil and json.encode(value) or ''
end

--- Probes the database once and answers whether it answered.
-- @author dop42
--
-- The answer is kept for the life of the resource: nil until the probe has run,
-- then true or false. Without a database the resource still boots, and says in
-- two lines that nobody can log in until that is fixed.
-- @return boolean, string
function OPX.Storage.Ready()
	if ready ~= nil then return ready, readyReason end

	local probe = Storage.Scalar('SELECT 1')
	if not probe.ok then
		ready = false
		readyReason = tostring(probe.detail)
		Open77.log.error('[storage] no database: ' .. readyReason)
		Open77.log.error('[storage] the core will boot, but nobody can be logged in until this ' ..
			'is fixed')
		return false, readyReason
	end

	ready = true
	readyReason = 'ready'
	return true, readyReason
end

--- Runs every CREATE TABLE statement in order, stopping at the first failure.
-- @author dop42
--
-- The list is an argument rather than one hard-coded schema, so that each module
-- contributes its own tables. Order matters: foreign keys first. Stopping beats
-- carrying on with an incomplete schema, so the caller can refuse connections
-- exactly as it does without a database.
-- @param statements table a list of SQL strings
-- @return Result
function OPX.Storage.ApplySchema(statements)
	for i = 1, #statements do
		local statement = statements[i]
		local created = Storage.Execute(statement)
		if not created.ok then
			local tableName = statement:match('CREATE TABLE IF NOT EXISTS ([%w_]+)') or ('#' .. i)
			Open77.log.error(('[storage] creating %s failed: %s')
				:format(tableName, tostring(created.detail)))
			return Result.Err('schema-failed', tableName)
		end
	end

	Open77.log.info(('[storage] schema ready: %d table(s)'):format(#statements))
	return Result.Ok(#statements)
end
