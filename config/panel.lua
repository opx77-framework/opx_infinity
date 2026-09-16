--- The panel's defaults and who opens one while the player is down.
-- @author dop42
--
-- The panel has no anchor or width of its own: it is the full-bleed drawer and
-- the page lays it out. What is left is how many item columns a spec that names
-- none gets, and the owners exempt from the down rule.

OPX.Config.MODULES.panel = {
	enabled = true,

	-- 1 or 2. A spec may override it per panel.
	COLUMNS = 2,

	-- Owners whose panel opens, and stays open, while the player is down.
	WHILE_DOWN = { admin = true },
}
