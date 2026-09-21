--- Every SQL statement the shops module runs, and nowhere else.
-- @author dop42
--
-- THE ONLY FILE IN THIS MODULE THAT MAY CONTAIN SQL, which is a rule the suite
-- enforces rather than a habit. Named parameters (`@citizen`) only -- never `?`
-- -- and no comments inside a statement string: the bridge rewrites the query
-- text to bind, and a comment inside it is rewritten too.
--
-- NO MIGRATIONS, by the same decision the rest of the resource took:
-- `CREATE TABLE IF NOT EXISTS` never touches a table that already exists, so a
-- changed shape is dropped and recreated by hand and any later index is a
-- documented `ALTER TABLE`. Pretending otherwise would be a migration system
-- that silently does nothing.

local M = OPX.Modules.Get('shops')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

--- The saved-outfit table.
--
-- ONE ROW PER SAVED LOOK, not one per slot. The look is a JSON blob because
-- that is what it is everywhere else in this resource -- `opx77_character_clothing`
-- stores the worn record the same way -- and because nothing ever queries
-- inside it: a look is read whole, written whole, and shown whole.
--
-- `citizen_id` IS `ascii` / `ascii_bin`, MATCHING THE COLUMN IT POINTS AT, and
-- this is not decoration. A foreign key between two columns of different
-- character sets is refused by InnoDB with SQL 1005 -- "can't create table" and
-- nothing else -- which is exactly how this table failed on its first deploy.
-- `opx77_characters.citizen_id` is ascii/ascii_bin and so is every column in
-- this resource that points at it; `share_code` takes the same treatment
-- because a code is A-Z and 2-9 by construction, and a binary collation is what
-- makes its UNIQUE index case-exact.
--
-- `share_code` IS THE INDEX A REDEEM READS, so it is unique and nullable: a
-- look nobody has shared has none, and two looks may not answer the same code.
-- MySQL lets any number of rows hold NULL in a UNIQUE column, which is exactly
-- the shape wanted -- unique among the shared, unconstrained among the rest.
--
-- The foreign key cascades, but a character delete here is SOFT, so the cascade
-- never fires on one; `PurgeCharacter` below is what actually removes them and
-- the appearance module's own storage carries the same note for the same
-- reason.
M.Storage.SCHEMA = {
	[[
		CREATE TABLE IF NOT EXISTS opx77_saved_outfits (
			outfit_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
			citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
			name VARCHAR(64) NOT NULL,
			look JSON NOT NULL,
			share_code VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
			created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (outfit_id),
			UNIQUE KEY uq_share_code (share_code),
			KEY ix_citizen (citizen_id),
			CONSTRAINT fk_saved_outfit_character FOREIGN KEY (citizen_id)
				REFERENCES opx77_characters (citizen_id) ON DELETE CASCADE
		) ENGINE=InnoDB
	]],
}

--- Every look one character has saved, newest first.
-- @author dop42
-- @param citizenId string
-- @return table a Result carrying an array of rows
function M.Storage.List(citizenId)
	return Storage.Query(
		'SELECT outfit_id, name, look, share_code FROM opx77_saved_outfits '
		.. 'WHERE citizen_id = @citizen ORDER BY outfit_id DESC',
		{ ['@citizen'] = citizenId })
end

--- How many a character has, for the ceiling.
-- @author dop42
-- @param citizenId string
-- @return table a Result carrying a number
function M.Storage.Count(citizenId)
	return Storage.Scalar(
		'SELECT COUNT(*) FROM opx77_saved_outfits WHERE citizen_id = @citizen',
		{ ['@citizen'] = citizenId })
end

--- Writes a new saved look.
-- @author dop42
-- @param citizenId string
-- @param name string
-- @param look string the encoded record
-- @return table a Result carrying the new id
function M.Storage.Save(citizenId, name, look)
	return Storage.Insert(
		'INSERT INTO opx77_saved_outfits (citizen_id, name, look) '
		.. 'VALUES (@citizen, @name, @look)',
		{ ['@citizen'] = citizenId, ['@name'] = name, ['@look'] = look })
end

--- One of a character's own looks, by id.
--
-- THE CITIZEN IS IN THE WHERE CLAUSE and not checked afterwards: a request
-- naming somebody else's outfit id must find nothing, rather than find a row
-- and be refused by a second test somebody can forget to write.
-- @author dop42
-- @param citizenId string
-- @param outfitId integer
-- @return table a Result carrying the row or nil
function M.Storage.Own(citizenId, outfitId)
	return Storage.Single(
		'SELECT outfit_id, name, look, share_code FROM opx77_saved_outfits '
		.. 'WHERE outfit_id = @outfit AND citizen_id = @citizen',
		{ ['@outfit'] = outfitId, ['@citizen'] = citizenId })
end

--- The look a share code names, whoever saved it.
-- @author dop42
-- @param code string
-- @return table a Result carrying the row or nil
function M.Storage.ByCode(code)
	return Storage.Single(
		'SELECT outfit_id, name, look FROM opx77_saved_outfits WHERE share_code = @code',
		{ ['@code'] = code })
end

--- Puts a minted code on one of a character's own looks.
--
-- Answers the rows affected, so a caller can tell "the code is now on it" from
-- "that outfit is not yours". A code that collides raises at the unique index
-- and the Result carries it; the caller mints another.
-- @author dop42
-- @param citizenId string
-- @param outfitId integer
-- @param code string
-- @return table a Result carrying rows affected
function M.Storage.SetCode(citizenId, outfitId, code)
	return Storage.Update(
		'UPDATE opx77_saved_outfits SET share_code = @code '
		.. 'WHERE outfit_id = @outfit AND citizen_id = @citizen',
		{ ['@code'] = code, ['@outfit'] = outfitId, ['@citizen'] = citizenId })
end

--- Removes one of a character's own looks.
-- @author dop42
-- @param citizenId string
-- @param outfitId integer
-- @return table a Result carrying rows affected
function M.Storage.Delete(citizenId, outfitId)
	return Storage.Update(
		'DELETE FROM opx77_saved_outfits WHERE outfit_id = @outfit AND citizen_id = @citizen',
		{ ['@outfit'] = outfitId, ['@citizen'] = citizenId })
end

--- Removes every look a deleted character saved.
--
-- The foreign key above cascades on a real delete and a character delete in
-- this resource is a SOFT one, so the cascade never fires and this is what
-- actually clears them. Same shape, and same reason, as the appearance
-- module's own purge.
-- @author dop42
-- @param citizenId string
-- @return table a Result carrying rows affected
function M.Storage.PurgeCharacter(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return Result.Err('invalid_citizen', 'no citizen id given')
	end
	return Storage.Update(
		'DELETE FROM opx77_saved_outfits WHERE citizen_id = @citizen',
		{ ['@citizen'] = citizenId })
end
