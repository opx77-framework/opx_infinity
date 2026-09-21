--- NCPD and MaxTac: one law book, one heat ladder, two divisions.
-- @author XEROX710
--
-- THE WANTED LEVEL IS A CRIME SCORE THE ENGINE RAISES ITSELF. `PreventionSystem`
-- keeps `m_totalCrimeScore` and raises `m_heatStage` (`Heat_0 .. Heat_5`) when
-- the score reaches the current stage's capacity, zeroing it as it crosses. The
-- `wanted_level` quest fact is written FROM that stage and read only by a debug
-- overlay, so a feature that sets the fact moves the bar and nothing else. This
-- module therefore owns the SCORE -- what a crime is worth, who is charged, how
-- fast it drains -- and drives the engine's own ladder so the sirens, the radio,
-- the roadblocks, the wanted bar and the response units are the game's.
--
-- THE TWO DIVISIONS ARE THE ENGINE'S OWN SPLIT, not a taxonomy we invented:
-- `Heat_1 .. Heat_4` is the NCPD ladder (Cortes, Archer Hella, Emperor,
-- Merrimac, the Hellhound at `Heat_5`), and MaxTac is the separate division that
-- arrives at `Heat_5` in a Zetatech Surveyor with its own agent registry, its
-- own tag (`MaxTac_NotPrevention`), its own status effect and its own insertion
-- run. `config/ncpd.lua` names every record; nothing in this module spells one
-- as a literal.
--
-- TROOPERS ARE PLAYERS FIRST AND BOTS SECOND. A MaxTac summon fills the squad
-- from players who opted into the division and any seat still empty at the
-- response deadline is filled with the engine's own trooper records, so an empty
-- division never means an empty street. `FILL = 'bots'` in config is what makes
-- that the default, and `'players'` makes the job player-only on purpose.
--
-- THE LEVER IS A PLATFORM SEAM. `PreventionSystem`'s 287 methods are all
-- scripted, so nothing native can raise a stage: the client enqueues a command
-- string and its REDscript loop executes it inside the script frame it owns, on
-- the local player only. `open77-base` now carries the two this feature needs --
-- `prevention.heat:<0-5>` and `prevention.av`, each addressed to the player it
-- was asked for and refused when that player is not the client running it -- and
-- the client reads the effect back with `prevention.state`.
--
-- A CRIME COMMITTED IN THE WORLD ARRIVES AS THE CLIENT'S OWN READING. The engine
-- scores its own crimes and publishes nothing, so the client reads its own
-- `PreventionSystem` through `Open77.prevention.state()` and reports the stage it
-- holds; the server mirrors that into the ledger and stands the response up. The
-- law book is therefore the server's own instrument -- for jobs, for the operator
-- commands, for anything a script wants charged -- rather than the only way a
-- player becomes wanted.
--
-- `character` is optional here and not required: the ledger binds heat to a
-- loaded character, and without that contract it has nobody to charge, which is
-- a refusal with a line rather than a module that takes the whole resource down.
-- `vehicles`, `hud` and `prompts` are optional for the same reason: without them
-- the law book still loads and still scores, and only the surfaces are missing.

local M = OPX.Modules.Declare{
	id = 'ncpd',
	side = 'both',
	fatal = false,
	requires = {},
	optional = { 'character', 'vehicles', 'hud', 'prompts' },
}

--- The two divisions, spelled the way the config's `LADDER` spells them.
-- A stage's division is the config's answer, never a literal in code.
M.DIVISION = { NCPD = 'ncpd', MAXTAC = 'maxtac' }

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Server to client. ONE payload carries the whole instruction: which stage
	-- the engine should be at, which division owns it, and whether this crossing
	-- is the one that calls MaxTac. A second event for the AV would be a second
	-- thing to lose.
	STAGE = OPX.Event(NET, 'ncpd', 'stage'),

	-- Client to server. The stage its own engine is holding -- the ONLY report of a
	-- real crime, because the engine charges its own score and never publishes it.
	-- The payload is one number and the server attributes it to the connection it
	-- arrived on, so a client cannot report a crime for anybody but itself.
	REPORT = OPX.Event(NET, 'ncpd', 'engine'),

	-- The client's own bus: what the module decided, local refusals included, so
	-- a HUD or a job resource can hear a crossing without asking for it.
	ON_STAGE = OPX.Event(LOCAL, 'ncpd', 'stage'),
	ON_REFUSED = OPX.Event(LOCAL, 'ncpd', 'refused'),
}

--- Which request a refusal answers. Passed to `OPX.Refuse` so a client waiting
--- on one of several requests can tell which refusal is its own.
M.Operation = { REPORT = 'ncpdReport', HEAT = 'ncpdHeat', AV = 'ncpdAv' }

--- The command names, in one place, spelled the way the ACL checks them
--- (`command.<name>`).
M.Command = {
	STATUS = 'opx.ncpd.status',
	REPORT = 'opx.ncpd.report',
	HEAT = 'opx.ncpd.heat',
	AV = 'opx.ncpd.av',
	CLEAR = 'opx.ncpd.clear',
	LAWS = 'opx.ncpd.laws',
}
