--- Every SQL statement this module runs, and the three tables it owns.
-- @author XEROX710
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: `server/main.lua` decides.
--
-- Statements bind named parameters (`@key`), never `?`: the bridge rewrites `?`
-- by walking the query text, and no comment may appear inside a SQL string for
-- the same reason. Every statement yields and answers a `Result`, so every one
-- of them has to be reached from a `CreateThread`.
--
-- No foreign key on a place, and nothing durable about a purchase lives here: a
-- dealer is a place in the world and belongs to no character. What a player
-- BOUGHT is a vehicle, and that row is the vehicles module's -- this module
-- creates none.

local M = OPX.Modules.Get('dealership')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
--
-- `opx77_dealerships` IS READ-ONLY NOW. `/opx.dealership.add` and `.remove`
-- wrote it, and both are gone: a dealer is written in `config/dealership.lua`.
-- The `Upsert` and `Delete` that stood here went with them, because a writer
-- with no caller is a writer the next reader wires a new command up to. The
-- read stays, and it is the whole migration: the server adopts every row in
-- here that config does not name and prints the line that would check it in.
-- Nothing drops it, so an operator who has not checked their dealers in yet can
-- still roll back.
--
-- `opx77_dealership_previews` IS READ-ONLY IN PRACTICE NOW, for the same reason
-- and on the same day. It was written at runtime from the staff menu's Dev
-- screen; the owner deleted that screen on 2026-09-21 and a showroom car is a
-- row in PREVIEW.POINTS in `config/dealership.lua`. The writers below are still
-- here because the routeway they serve is, but nothing in this resource reaches
-- them. The READ stays and is the migration: every row config does not name is
-- adopted at boot and printed as the line that checks it in.
--
-- A NEW TABLE rather than a `role` column on the one
-- above: an ALTER on a live table for a feature that could have its own is a
-- migration nobody needed, and a preview is not a dealer -- it has no kind and
-- it names a stock row.
--
-- `opx77_company_accounts` is where the money from a face-to-face sale lands.
-- Keyed by (kind, group) rather than by a surrogate id, because the pair IS the
-- identity: there is one account per job and one per gang, and a second row for
-- the same pair would be money in an account nobody reads. `balance` is a signed
-- BIGINT so that a bug that overdraws one is visible as a negative number rather
-- than as a wrap to something astronomical.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_dealerships (
    spot_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    label VARCHAR(64) NOT NULL,
    kind VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    captured_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_dealership_previews (
    preview_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    dealer_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    entry_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    placed_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_company_accounts (
    kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    group_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    balance BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (kind, group_key)
) ENGINE=InnoDB
]],
}

--- Every dealer still in the legacy table, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT spot_key, label, kind, x, y, z, heading, bucket, captured_by
  FROM opx77_dealerships
 ORDER BY created_at
  ]])
end

--- Every placed preview point, oldest first.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchPreviews()
	return Storage.Query([[
SELECT preview_key, dealer_key, entry_key, x, y, z, heading, bucket
  FROM opx77_dealership_previews
 ORDER BY created_at
  ]])
end

-- THE PREVIEW WRITERS STOOD HERE AND ARE GONE, with the runtime path that was
-- their only caller. The showroom is written in `PREVIEW.POINTS` now.
--
-- THE TABLE IS NOT DROPPED and `FetchPreviews` above is untouched: every row an
-- operator placed is still read at boot, still adopted, and still printed as the
-- config line that recreates it. This module reads that table and no longer
-- writes to it -- the same shape `modules/garages/server/storage.lua` took when
-- its own capture commands went, and for the same reason: a writer with no
-- caller is one the next reader wires a new command to.

--- Every company account, for the readout.
-- @author XEROX710
-- @return Result carrying an array of rows
function M.Storage.FetchAccounts()
	return Storage.Query([[
SELECT kind, group_key, balance
  FROM opx77_company_accounts
 ORDER BY kind, group_key
  ]])
end

--- Adds to one company's balance, creating the account when there is none.
-- @author XEROX710
--
-- ONE STATEMENT, AND THE ARITHMETIC IS THE DATABASE'S. A read, an add in Lua and
-- a write is three steps with two yields between them, and two sales settling in
-- the same second would each read the balance before the other wrote it -- so
-- one of the two deposits would be lost, silently, in a table nobody reconciles.
-- `balance = balance + @amount` cannot lose one.
-- @param kind string 'job' or 'gang'
-- @param group string
-- @param amount integer
-- @return Result
function M.Storage.Deposit(kind, group, amount)
	return Storage.Execute([[
INSERT INTO opx77_company_accounts (kind, group_key, balance)
VALUES (@kind, @group, @amount)
ON DUPLICATE KEY UPDATE balance = balance + @amount
  ]], { kind = kind, group = group, amount = amount })
end

--- One company's balance, or nil when the account has never been paid into.
-- @author XEROX710
-- @param kind string
-- @param group string
-- @return Result
function M.Storage.Balance(kind, group)
	return Storage.Single([[
SELECT balance
  FROM opx77_company_accounts
 WHERE kind = @kind AND group_key = @group
  ]], { kind = kind, group = group })
end
