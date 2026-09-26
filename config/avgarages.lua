--- The MaxTac AV recall pads: where the division's aircraft comes out.
-- @author XEROX710
--
-- THIS FILE IS THE GARAGES MACHINERY, WORN BY ANOTHER NAME. A pad here is a
-- GARAGE in every sense `config/garages.lua` defines -- a key, locations, a
-- menu point, a door, ordered exits, a vehicle filed under the key recalled to
-- a free one -- with two differences, and both of them are the whole reason
-- this file exists rather than a block in that one:
--
--   * IT IS SEPARATE. The owner asked for it in as many words: the AV garage
--     needs its own config. A MaxTac hangar is placed at a headquarters
--     (`config/headquarters.lua` designates the place) and moved when the
--     headquarters moves; a file of its own is what lets that happen without
--     wading through every ground garage on the server.
--   * IT IS GATED. Every pad below is behind the job gate
--     (`lib/shared/jobgate.lua`, the same decision an armoury, a lift floor and
--     a hauling site make): only the jobs in `JOBS`, on the duty state
--     `ON_DUTY` names, may list what is parked there, bring one out, or put
--     one away. A division's aircraft is not a car any character may recall.
--
-- WHAT IS THE SAME AND DELIBERATELY SO. `KIND = 'avpad'` is the only KIND this
-- file accepts -- a ground garage belongs in `config/garages.lua`, beside the
-- other ground garages -- and the blocks below are shaped exactly as that
-- file's are, down to the MENU/ENTRY/EXITS triple. The keys live in the same
-- space as every garage's: a vehicle's `garage` column may hold any of them,
-- and a key is NEVER renamed, because renaming one orphans every vehicle filed
-- under it.
--
-- HOW TO CAPTURE ONE -- THE SAME BARGAIN AS THE HEADQUARTERS. Stand where the
-- pad should be and run `/opx.avgarages.add [key] [label]`: the server reads
-- where you stand and which way you face (HEADING is the yaw a recalled AV is
-- created with), saves the pad, draws it for everyone at once, and answers with
-- the block to paste below. Capture for today, config for ever: the block in
-- THIS file is the record that outlives a database reset, and `/opx.avgarages.remove`
-- takes a captured pad away again. `/opx.admin.self.pos` still copies
-- `{ NAME, LABEL, X, Y, Z, HEADING }` for the operator filling a MENU, an ENTRY
-- or an EXIT below by hand.
--
-- The marker vocabulary is fixed by the engine: styles are `interaction`,
-- `objective`, `spawn` and `danger`, shapes are `ring` and `cylinder`, RADIUS
-- is 0.1..50 and MAX_DISTANCE is 1..500. `config/garages.lua` owns the marker
-- LOOK for every pad -- `MARKER.avpad` and `MARKER.entry` there apply here too,
-- because a pad drawn one way in a hangar and another way at a dealer is a pad
-- a player has to learn twice.

OPX.Config.MODULES.avgarages = {
	enabled = true,

	-- WHO MAY USE A PAD HERE. `JOBS` is `{ jobName = minimumGrade }`, and
	-- `ON_DUTY` says whether they must be clocked on. The gate is
	-- `lib/shared/jobgate.lua` through the garages module's own adapter, so
	-- these two fields mean exactly what they mean on a lift floor, an armory
	-- bench and a hauling site: a holder of the job at the grade, in the duty
	-- state named, passes; everybody else is refused BY NAME -- job, grade or
	-- duty, whichever they were closest to.
	--
	-- An absent or emptied JOBS makes every pad below PUBLIC, which is a
	-- choice a server may make and never an accident: the boot journal and
	-- `/opx.garages.list` both say so.
	JOBS = { maxtac = 0, ncpd_maxtac = 0 },
	ON_DUTY = true,

	-- WHERE THE RECALLING PILOT SITS. An aircraft comes out of a pad hovering a
	-- lift above the marker, and the only seat that ever mattered is the one the
	-- flight controls are authored at: the platform flies an AV from ANY seat a
	-- body holds (`VehicleReplication` promotes whichever seat its pilot took),
	-- but "pilotable from inside" starts with being INSIDE -- so the moment the
	-- hull exists, the owner who recalled it is placed at the controls rather
	-- than left to find the mount of a hovering airframe.
	--
	-- A canonical seat name -- `seat_front_left`, `seat_front_right`,
	-- `seat_back_left` or `seat_back_right` -- and `false` for "hands off": the
	-- recall then behaves as it always did and the pilot climbs in themselves.
	-- A name the platform cannot spell is a boot problem and no seat at all,
	-- never a silently substituted one.
	PILOT_SEAT = 'seat_front_left',

	-- THE CAPTURE COMMANDS, and nothing is named when a name is emptied:
	-- `add = ''` switches the capture path off and leaves the file the whole
	-- placement path again. Both are ACL-gated like every other placement
	-- command (`command.<name>` in acl.jsonc).
	COMMANDS = {
		add = 'opx.avgarages.add',
		remove = 'opx.avgarages.remove',
	},

	-- EVERY MAXTAC AV PAD ON THE SERVER, in the exact block shape
	-- `config/garages.lua` uses.
	--
	-- LABEL is the operator's own words and is never translated. KIND must be
	-- `avpad`; a block naming `garage` here is refused at boot with a warning,
	-- because a ground garage in the division's hangar file is a garage the
	-- operator will look for in the wrong file.
	--
	-- NOTHING IS SHIPPED HERE, on purpose: a pad at a coordinate nobody ever
	-- stood at is a pad an AV cannot land on. Stand where the pad goes -- at
	-- the headquarters `config/headquarters.lua` designates -- run
	-- `/opx.avgarages.add`, and paste the block it answers with (the shape of
	-- the one commented out below).
	GARAGES = {
		-- maxtac_av1 = {
		-- 	LABEL = 'MaxTac AV pad',
		-- 	KIND = 'avpad',
		-- 	LOCATIONS = {
		-- 		{
		-- 			BUCKET = 0,
		-- 			MENU = { X = -1527.21, Y = -218.56, Z = 7.86 },
		-- 			ENTRY = { X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
		-- 			EXITS = {
		-- 				{ X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
		-- 			},
		-- 		},
		-- 	},
		-- },
	},
}
