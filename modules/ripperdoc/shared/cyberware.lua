--- The whole of Night City's chrome: every piece the base game's ripperdocs
-- sell, in the body systems the base game files it under, with what each one
-- is allowed to DO on this server.
-- @author XEROX710
--
-- WHY THE CATALOGUE LIVES HERE AND NOT IN CONFIG. A hundred-odd pieces with
-- five tiers each is data, not policy: the operator decides prices, capacity,
-- slot counts and which pieces are sold (`config/ripperdoc.lua`, `VANILLA`),
-- and this file decides what a Kiroshi optic IS. The builder below turns one
-- compact row per piece into the same entry shape the hand-tuned config
-- entries already use, so every reader -- the server's offer rules, the
-- client's page, the tests -- walks one list and cannot tell which is which.
--
-- WHAT A PIECE CAN DO IS THE PLATFORM'S DECISION, AND THE KIND SAYS WHICH.
-- Open77 runs a closed set of multiplayer adapters (wiki/cyberware.md,
-- dash.md, reflex-overdrive.md, ground-slam.md, hacking.md), so a piece is
-- one of:
--   implant  a durable platform implant (`Open77.cyberware`): Gorilla Arms,
--            Reinforced Tendons, the cyberdecks (with their hack), Self-ICE
--   grant    a session capability armed from our ledger: Kerenzikov (dash),
--            the Sandevistans (reflex overdrive), the Berserks (ground slam)
--   stat     server-owned numbers the platform really applies: armor plating,
--            max health, health regen, max stamina, stamina regen, no fall
--            damage, extra capacity -- `server/effects.lua` composes them
--   rp       chrome with no multiplayer adapter on this build: it is fitted,
--            costs capacity, wears and can be repaired, and the page says in
--            words that it does nothing mechanical here
-- A piece of any kind may ALSO carry stat EFFECTS (the Falcon Sandevistan's
-- health, the Apogee's stamina), because the base game's pieces do both.
--
-- THE NUMBERS ARE THIS SERVER'S, NOT THE BASE GAME'S. A base-game armor value
-- of 186 is meaningless against a 250-point health pool whose armor is a
-- damage-absorbing plate, so every effect below is balanced for the pools in
-- `config/shared.lua` and scales from the piece's first tier to tier 5.

local M = OPX.Modules.Get('ripperdoc')

M.Cyber = {}

-- ── the body ──────────────────────────────────────────────────────────────
--
-- The base game's own systems and slot counts (2.x). `SLOTS` is the default;
-- `config/ripperdoc.lua` `SYSTEMS` overrides any of them.
M.Cyber.SYSTEMS = {
	{ id = 'frontal_cortex', SLOTS = 3 },
	{ id = 'operating_system', SLOTS = 1 },
	{ id = 'arms', SLOTS = 1 },
	{ id = 'skeleton', SLOTS = 2 },
	{ id = 'nervous_system', SLOTS = 3 },
	{ id = 'integumentary', SLOTS = 3 },
	{ id = 'face', SLOTS = 1 },
	{ id = 'hands', SLOTS = 1 },
	{ id = 'circulatory', SLOTS = 3 },
	{ id = 'legs', SLOTS = 1 },
}

-- The stat keys a piece's EFFECTS may carry, and nothing else: an unknown key
-- is dropped at build time rather than quietly composing into nothing.
M.Cyber.EFFECT_KEYS = {
	armor = true, healthMax = true, healthRegen = true,
	staminaMax = true, staminaRegen = true, noFall = true, capacity = true,
}

-- ── the rows ──────────────────────────────────────────────────────────────
--
-- { id, system, first tier, base-game capacity, kind, effects, extra }
--   effects  key -> { at first tier, at tier 5 } (booleans are plain)
--   extra    ICONIC, and the native block a kind needs (see the builders)
--
-- The ids that already exist in `config/ripperdoc.lua` (`arms`, `legs`,
-- `dash`, `reflex`, `slam`, `deck`) are NOT here: those entries are the
-- operator's hand-tuned ones and keep their definition ids, so a patient who
-- already bought them keeps a record the tray still recognises.

local ROWS = {
	-- FRONTAL CORTEX
	{ 'axolotl', 'frontal_cortex', 4, 48, 'rp', nil, { ICONIC = true } },
	{ 'bioconductors', 'frontal_cortex', 1, 16, 'rp' },
	{ 'cox2_optimizer', 'frontal_cortex', 3, 50, 'rp', nil, { ICONIC = true } },
	{ 'camillo_ram_manager', 'frontal_cortex', 4, 8, 'rp' },
	{ 'ex_disk', 'frontal_cortex', 3, 10, 'rp' },
	{ 'kerenzikov_boost', 'frontal_cortex', 3, 3, 'stat', { staminaRegen = { 1, 3 } } },
	{ 'mechatronic_core', 'frontal_cortex', 1, 5, 'rp' },
	{ 'memory_boost', 'frontal_cortex', 2, 18, 'rp' },
	{ 'newton_module', 'frontal_cortex', 1, 14, 'rp' },
	{ 'quantum_tuner', 'frontal_cortex', 5, 45, 'rp', nil, { ICONIC = true } },
	{ 'ram_reallocator', 'frontal_cortex', 3, 40, 'rp', nil, { ICONIC = true } },
	{ 'ram_upgrade', 'frontal_cortex', 1, 8, 'rp' },
	{ 'self_ice', 'frontal_cortex', 3, 5, 'ice', nil, {
		ICE = { charges = { 1, 2 }, rechargeMs = { 45000, 20000 } },
	} },

	-- OPERATING SYSTEM (one slot: a deck, a Sandevistan, a Berserk or the
	-- compressor -- the base game's own rule)
	{ 'paraline_deck', 'operating_system', 1, 14, 'implant', nil, { DECK = 'short_circuit' } },
	{ 'rippler_deck', 'operating_system', 1, 16, 'implant', nil, { DECK = 'overheat' } },
	{ 'biotech_deck', 'operating_system', 2, 16, 'implant', nil, { DECK = 'overheat' } },
	{ 'raven_deck', 'operating_system', 3, 20, 'implant', nil, { DECK = 'reboot_optics' } },
	{ 'netdriver_deck', 'operating_system', 5, 25, 'implant', nil,
		{ DECK = 'weapon_glitch', ICONIC = true } },
	{ 'canto_deck', 'operating_system', 5, 33, 'implant', nil,
		{ DECK = 'malfunction', ICONIC = true } },
	{ 'zetatech_sandevistan', 'operating_system', 2, 20, 'grant', nil, { SANDY = true } },
	{ 'warp_dancer', 'operating_system', 3, 14, 'grant', { armor = { 4, 10 } }, { SANDY = true } },
	{ 'falcon_sandevistan', 'operating_system', 4, 39, 'grant', { healthMax = { 20, 30 } },
		{ SANDY = true, ICONIC = true } },
	{ 'apogee_sandevistan', 'operating_system', 5, 44, 'grant', { staminaMax = { 25, 25 } },
		{ SANDY = true, ICONIC = true } },
	{ 'biodyne_berserk', 'operating_system', 2, 20, 'grant', { armor = { 6, 12 } }, { BERSERK = true } },
	{ 'zetatech_berserk', 'operating_system', 3, 16, 'grant', { armor = { 8, 14 } },
		{ BERSERK = true } },
	{ 'militech_berserk', 'operating_system', 4, 35, 'grant', { armor = { 12, 18 } },
		{ BERSERK = true, ICONIC = true } },
	{ 'chrome_compressor', 'operating_system', 2, 0, 'stat', { capacity = { 40, 70 } },
		{ ICONIC = true } },

	-- ARMS (one slot: the Gorilla Arms family is the platform's own implant;
	-- blades, the monowire and the launcher have no multiplayer adapter)
	{ 'gorilla_arms_electric', 'arms', 2, 8, 'implant', nil, { ARMS = true } },
	{ 'gorilla_arms_thermal', 'arms', 2, 8, 'implant', nil, { ARMS = true } },
	{ 'gorilla_arms_toxic', 'arms', 2, 8, 'implant', nil, { ARMS = true } },
	{ 'mantis_blades', 'arms', 2, 8, 'rp' },
	{ 'mantis_blades_electric', 'arms', 2, 8, 'rp' },
	{ 'mantis_blades_thermal', 'arms', 2, 8, 'rp' },
	{ 'mantis_blades_toxic', 'arms', 2, 8, 'rp' },
	{ 'mantis_blades_maxtac', 'arms', 4, 8, 'rp' },
	{ 'monowire', 'arms', 2, 8, 'rp' },
	{ 'monowire_electric', 'arms', 2, 8, 'rp' },
	{ 'monowire_thermal', 'arms', 2, 8, 'rp' },
	{ 'monowire_toxic', 'arms', 2, 8, 'rp' },
	{ 'projectile_launcher', 'arms', 2, 8, 'rp' },
	{ 'projectile_launcher_electric', 'arms', 2, 8, 'rp' },
	{ 'projectile_launcher_thermal', 'arms', 2, 8, 'rp' },
	{ 'projectile_launcher_toxic', 'arms', 2, 8, 'rp' },

	-- SKELETON: the plating pieces
	{ 'bionic_joints', 'skeleton', 1, 8, 'stat', { armor = { 6, 20 } } },
	{ 'dense_marrow', 'skeleton', 2, 16, 'stat', { armor = { 4, 10 }, staminaMax = { 5, 15 } } },
	{ 'epimorphic_skeleton', 'skeleton', 4, 40, 'stat', { armor = { 16, 22 }, healthMax = { 25, 35 } } },
	{ 'feen_x', 'skeleton', 1, 16, 'stat', { armor = { 3, 10 } } },
	{ 'kinetic_frame', 'skeleton', 1, 16, 'stat', { armor = { 4, 14 }, staminaRegen = { 1, 3 } } },
	{ 'para_bellum', 'skeleton', 3, 25, 'stat', { armor = { 10, 20 } } },
	{ 'ram_recoup', 'skeleton', 1, 14, 'stat', { armor = { 3, 10 } } },
	{ 'rara_avis', 'skeleton', 3, 45, 'stat', { armor = { 14, 24 } }, { ICONIC = true } },
	{ 'scar_coalescer', 'skeleton', 1, 20, 'stat', { armor = { 3, 10 }, healthRegen = { 0.5, 1.5 } } },
	{ 'scarab', 'skeleton', 1, 14, 'stat', { armor = { 5, 14 } } },
	{ 'spring_joints', 'skeleton', 2, 16, 'stat', { armor = { 4, 10 }, noFall = true } },
	{ 'titanium_bones', 'skeleton', 1, 6, 'stat', { armor = { 3, 10 } } },
	{ 'universal_booster', 'skeleton', 3, 25, 'stat', { armor = { 12, 20 }, healthRegen = { 1, 2 } } },

	-- NERVOUS SYSTEM
	{ 'adrenaline_converter', 'nervous_system', 1, 6, 'stat', { staminaRegen = { 2, 6 } } },
	{ 'adreno_trigger', 'nervous_system', 3, 20, 'stat', { staminaRegen = { 5, 8 } },
		{ ICONIC = true } },
	{ 'atomic_sensors', 'nervous_system', 1, 5, 'rp' },
	{ 'deep_field_interface', 'nervous_system', 3, 40, 'rp', nil, { ICONIC = true } },
	{ 'neofiber', 'nervous_system', 3, 14, 'stat', { armor = { 6, 12 } } },
	{ 'reflex_tuner', 'nervous_system', 1, 5, 'rp' },
	{ 'revulsor', 'nervous_system', 3, 35, 'rp', nil, { ICONIC = true } },
	{ 'stabber', 'nervous_system', 2, 12, 'rp' },
	{ 'synaptic_accelerator', 'nervous_system', 2, 5, 'rp' },
	{ 'tyrosine_injector', 'nervous_system', 1, 8, 'rp' },
	{ 'visual_cortex_support', 'nervous_system', 1, 20, 'rp' },

	-- INTEGUMENTARY SYSTEM: the rest of the plating
	{ 'carapace', 'integumentary', 2, 16, 'stat', { armor = { 8, 18 } } },
	{ 'cellular_adapter', 'integumentary', 2, 10, 'stat', { armor = { 10, 20 } } },
	{ 'chitin', 'integumentary', 3, 50, 'stat', { armor = { 18, 26 }, healthRegen = { 1.5, 3 } },
		{ ICONIC = true } },
	{ 'cogito_lattice', 'integumentary', 1, 12, 'stat', { armor = { 4, 12 } } },
	{ 'countershell', 'integumentary', 1, 12, 'stat', { armor = { 4, 12 } } },
	{ 'defenzikov', 'integumentary', 3, 20, 'stat', { armor = { 6, 14 } } },
	{ 'nano_plating', 'integumentary', 2, 20, 'stat', { armor = { 8, 16 } } },
	{ 'optical_camo', 'integumentary', 2, 20, 'stat', { armor = { 3, 8 } } },
	{ 'pain_editor', 'integumentary', 4, 35, 'stat', { armor = { 16, 20 }, healthMax = { 10, 15 } } },
	{ 'painducer', 'integumentary', 4, 30, 'stat', { armor = { 18, 22 } } },
	{ 'peripheral_inverse', 'integumentary', 4, 30, 'stat', { armor = { 8, 12 } },
		{ ICONIC = true } },
	{ 'proxishield', 'integumentary', 1, 10, 'stat', { armor = { 3, 10 } } },
	{ 'rangeguard', 'integumentary', 1, 14, 'stat', { armor = { 4, 12 } } },
	{ 'shock_n_awe', 'integumentary', 1, 25, 'stat', { armor = { 8, 16 } } },
	{ 'subdermal_armor', 'integumentary', 1, 5, 'stat', { armor = { 5, 14 } } },

	-- FACE (the optics)
	{ 'kiroshi_basic', 'face', 1, 1, 'rp' },
	{ 'kiroshi_clairvoyant', 'face', 3, 8, 'rp' },
	{ 'kiroshi_cockatrice', 'face', 4, 30, 'rp', nil, { ICONIC = true } },
	{ 'kiroshi_doomsayer', 'face', 1, 2, 'rp' },
	{ 'kiroshi_sentry', 'face', 1, 2, 'rp' },
	{ 'kiroshi_stalker', 'face', 1, 2, 'rp' },
	{ 'kiroshi_oracle', 'face', 4, 10, 'rp' },
	{ 'bis_faceplate', 'face', 5, 0, 'rp', nil, { ICONIC = true } },

	-- HANDS
	{ 'ballistic_coprocessor', 'hands', 1, 2, 'rp' },
	{ 'handle_wrap', 'hands', 3, 8, 'rp' },
	{ 'immovable_force', 'hands', 2, 35, 'rp', nil, { ICONIC = true } },
	{ 'microgenerator', 'hands', 2, 9, 'rp' },
	{ 'shock_absorber', 'hands', 1, 12, 'rp' },
	{ 'smart_link', 'hands', 1, 4, 'rp' },
	{ 'tattoo_johnny', 'hands', 1, 0, 'rp', nil, { ICONIC = true } },
	{ 'tattoo_together', 'hands', 1, 0, 'rp', nil, { ICONIC = true } },
	{ 'tattoo_tyger_claws', 'hands', 1, 0, 'rp' },

	-- CIRCULATORY SYSTEM
	{ 'adrenaline_booster', 'circulatory', 1, 14, 'stat', { staminaMax = { 10, 25 } } },
	{ 'biomonitor', 'circulatory', 1, 14, 'stat', { healthRegen = { 1, 3 } } },
	{ 'black_mamba', 'circulatory', 3, 16, 'rp' },
	{ 'blood_pump', 'circulatory', 2, 15, 'stat', { healthRegen = { 2, 4 } } },
	{ 'clutch_padding', 'circulatory', 1, 12, 'stat', { staminaRegen = { 2, 5 } } },
	{ 'electromag_recycler', 'circulatory', 3, 40, 'stat',
		{ healthRegen = { 1, 2 }, staminaRegen = { 2, 4 } }, { ICONIC = true } },
	{ 'feedback_circuit', 'circulatory', 3, 14, 'stat', { healthRegen = { 1, 2 } } },
	{ 'heal_on_kill', 'circulatory', 1, 10, 'stat', { healthRegen = { 0.5, 1.5 } } },
	{ 'isometric_stabilizer', 'circulatory', 3, 40, 'stat', { staminaRegen = { 4, 8 } },
		{ ICONIC = true } },
	{ 'microrotors', 'circulatory', 1, 12, 'stat', { staminaMax = { 5, 15 } } },
	{ 'second_heart', 'circulatory', 4, 30, 'stat', { healthMax = { 30, 50 } } },
	{ 'threatevac', 'circulatory', 1, 5, 'rp' },

	-- LEGS (one slot: Reinforced Tendons is the platform's double jump)
	{ 'fortified_ankles', 'legs', 1, 6, 'stat', { noFall = true } },
	{ 'jenkins_tendons', 'legs', 2, 6, 'stat', { staminaMax = { 10, 20 } } },
	{ 'leeroy_ligaments', 'legs', 2, 8, 'stat', { staminaRegen = { 2, 5 } }, { ICONIC = true } },
	{ 'lynx_paws', 'legs', 2, 5, 'rp' },
}

-- ── the base game's own records ───────────────────────────────────────────
--
-- WHICH TWEAKDB RECORD EACH PIECE IS, read out of the installed TweakDB
-- (`tweakdb.bin` + `tweakdb_ep1.bin`, build 2.31: 1 630 live cyberware
-- records) rather than remembered. The base game names its chrome by
-- codename -- Reinforced Tendons are `AdvancedBoostedTendons`, Lynx Paws are
-- `AdvancedCatPaws`, the Monowire is `AdvancedNanoWires`, a Toxic variant is
-- `Chemical` -- and files each tier as a quality (`BY = 'tier'`: slot 1 is
-- Common .. slot 5 Legendary, `false` where the game has none) or, for the
-- decks, as one Mk per grade (`BY = 'grade'`). A piece whose codename is not
-- yet proven here has no row: the record reader (`/opx.clinic.records`) asks
-- a live client what every record is called, and a row is added from that
-- answer, never from a guess.
M.Cyber.RECORDS = {
	apogee_sandevistan = { BY = 'grade', 'Items.AdvancedSandevistanApogee' },
	arms = { BY = 'tier', false, 'Items.AdvancedStrongArmsUncommon', 'Items.AdvancedStrongArmsRare', 'Items.AdvancedStrongArmsEpic', 'Items.AdvancedStrongArmsLegendary' },
	bioconductors = { BY = 'tier', 'Items.AdvancedBioConductorsCommon', 'Items.AdvancedBioConductorsUncommon', 'Items.AdvancedBioConductorsRare', 'Items.AdvancedBioConductorsEpic', 'Items.AdvancedBioConductorsLegendary' },
	biomonitor = { BY = 'tier', 'Items.AdvancedBiomonitorCommon', 'Items.AdvancedBiomonitorUncommon', 'Items.AdvancedBiomonitorRare', 'Items.AdvancedBiomonitorEpic', 'Items.AdvancedBiomonitorLegendary' },
	bionic_joints = { BY = 'tier', 'Items.AdvancedBionicJointsCommon', 'Items.AdvancedBionicJointsUncommon', 'Items.AdvancedBionicJointsRare', 'Items.AdvancedBionicJointsEpic', 'Items.AdvancedBionicJointsLegendary' },
	biotech_deck = { BY = 'grade', 'Items.AdvancedBiotechSigmaMKIUncommon', 'Items.AdvancedBiotechSigmaMKIIRare', 'Items.AdvancedBiotechSigmaMKIIIEpic', 'Items.AdvancedBiotechSigmaMKIVLegendary' },
	camillo_ram_manager = { BY = 'tier', false, false, false, 'Items.AdvancedCamilloRamManagerEpic', 'Items.AdvancedCamilloRamManagerLegendary' },
	dash = { BY = 'tier', 'Items.AdvancedKerenzikovCommon', 'Items.AdvancedKerenzikovUncommon', 'Items.AdvancedKerenzikovRare', 'Items.AdvancedKerenzikovEpic', 'Items.AdvancedKerenzikovLegendary' },
	deck = { BY = 'grade', 'Items.AdvancedArasakaShadowMKICommon', 'Items.AdvancedArasakaShadowMKIIUncommon', 'Items.AdvancedArasakaShadowMKIIIRare', 'Items.AdvancedArasakaShadowMKIVEpic', 'Items.AdvancedArasakaShadowMKVLegendary' },
	dense_marrow = { BY = 'tier', 'Items.AdvancedDenseMarrowCommon', 'Items.AdvancedDenseMarrowUncommon', 'Items.AdvancedDenseMarrowRare', 'Items.AdvancedDenseMarrowEpic', 'Items.AdvancedDenseMarrowLegendary' },
	ex_disk = { BY = 'tier', false, false, 'Items.AdvancedExDiskRare', 'Items.AdvancedExDiskEpic', 'Items.AdvancedExDiskLegendary' },
	fortified_ankles = { BY = 'tier', false, 'Items.AdvancedReinforcedMusclesUncommon', 'Items.AdvancedReinforcedMusclesRare', 'Items.AdvancedReinforcedMusclesEpic', 'Items.AdvancedReinforcedMusclesLegendary' },
	gorilla_arms_electric = { BY = 'tier', false, 'Items.AdvancedStrongArmsElectricUncommon', 'Items.AdvancedStrongArmsElectricRare', 'Items.AdvancedStrongArmsElectricEpic', 'Items.AdvancedStrongArmsElectricLegendary' },
	gorilla_arms_thermal = { BY = 'tier', false, 'Items.AdvancedStrongArmsThermalUncommon', 'Items.AdvancedStrongArmsThermalRare', 'Items.AdvancedStrongArmsThermalEpic', 'Items.AdvancedStrongArmsThermalLegendary' },
	gorilla_arms_toxic = { BY = 'tier', false, 'Items.AdvancedStrongArmsChemicalUncommon', 'Items.AdvancedStrongArmsChemicalRare', 'Items.AdvancedStrongArmsChemicalEpic', 'Items.AdvancedStrongArmsChemicalLegendary' },
	heal_on_kill = { BY = 'tier', 'Items.AdvancedHealOnKillCommon', 'Items.AdvancedHealOnKillUncommon', 'Items.AdvancedHealOnKillRare', 'Items.AdvancedHealOnKillEpic', 'Items.AdvancedHealOnKillLegendary' },
	jenkins_tendons = { BY = 'tier', 'Items.AdvancedJenkinsTendonsCommon', 'Items.AdvancedJenkinsTendonsUncommon', 'Items.AdvancedJenkinsTendonsRare', 'Items.AdvancedJenkinsTendonsEpic', 'Items.AdvancedJenkinsTendonsLegendary' },
	kerenzikov_boost = { BY = 'tier', 'Items.AdvancedKerenziovBoostSystemCommon', 'Items.AdvancedKerenziovBoostSystemUncommon', 'Items.AdvancedKerenziovBoostSystemRare', 'Items.AdvancedKerenziovBoostSystemEpic', 'Items.AdvancedKerenziovBoostSystemLegendary' },
	legs = { BY = 'tier', false, 'Items.AdvancedBoostedTendonsUncommon', 'Items.AdvancedBoostedTendonsRare', 'Items.AdvancedBoostedTendonsEpic', 'Items.AdvancedBoostedTendonsLegendary' },
	lynx_paws = { BY = 'tier', false, 'Items.AdvancedCatPawsUncommon', 'Items.AdvancedCatPawsRare', 'Items.AdvancedCatPawsEpic', 'Items.AdvancedCatPawsLegendary' },
	mantis_blades = { BY = 'tier', false, 'Items.AdvancedMantisBladesUncommon', 'Items.AdvancedMantisBladesRare', 'Items.AdvancedMantisBladesEpic', 'Items.AdvancedMantisBladesLegendary' },
	mantis_blades_electric = { BY = 'tier', false, 'Items.AdvancedMantisBladesElectricUncommon', 'Items.AdvancedMantisBladesElectricRare', 'Items.AdvancedMantisBladesElectricEpic', 'Items.AdvancedMantisBladesElectricLegendary' },
	mantis_blades_maxtac = { BY = 'tier', false, false, false, 'Items.AdvancedMaxTacMantisBladesEpic', 'Items.AdvancedMaxTacMantisBladesLegendary' },
	mantis_blades_thermal = { BY = 'tier', false, 'Items.AdvancedMantisBladesThermalUncommon', 'Items.AdvancedMantisBladesThermalRare', 'Items.AdvancedMantisBladesThermalEpic', 'Items.AdvancedMantisBladesThermalLegendary' },
	mantis_blades_toxic = { BY = 'tier', false, 'Items.AdvancedMantisBladesChemicalUncommon', 'Items.AdvancedMantisBladesChemicalRare', 'Items.AdvancedMantisBladesChemicalEpic', 'Items.AdvancedMantisBladesChemicalLegendary' },
	mechatronic_core = { BY = 'tier', 'Items.AdvancedMechatronicCoreCommon', 'Items.AdvancedMechatronicCoreUncommon', 'Items.AdvancedMechatronicCoreRare', 'Items.AdvancedMechatronicCoreEpic', 'Items.AdvancedMechatronicCoreLegendary' },
	memory_boost = { BY = 'tier', false, 'Items.AdvancedMemoryBoostUncommon', 'Items.AdvancedMemoryBoostRare', 'Items.AdvancedMemoryBoostEpic', 'Items.AdvancedMemoryBoostLegendary' },
	microgenerator = { BY = 'tier', 'Items.AdvancedMicroGeneratorCommon', 'Items.AdvancedMicroGeneratorUncommon', 'Items.AdvancedMicroGeneratorRare', 'Items.AdvancedMicroGeneratorEpic', 'Items.AdvancedMicroGeneratorLegendary' },
	monowire = { BY = 'tier', false, 'Items.AdvancedNanoWiresUncommon', 'Items.AdvancedNanoWiresRare', 'Items.AdvancedNanoWiresEpic', 'Items.AdvancedNanoWiresLegendary' },
	monowire_electric = { BY = 'tier', false, 'Items.AdvancedNanoWiresElectricUncommon', 'Items.AdvancedNanoWiresElectricRare', 'Items.AdvancedNanoWiresElectricEpic', 'Items.AdvancedNanoWiresElectricLegendary' },
	monowire_thermal = { BY = 'tier', false, 'Items.AdvancedNanoWiresThermalUncommon', 'Items.AdvancedNanoWiresThermalRare', 'Items.AdvancedNanoWiresThermalEpic', 'Items.AdvancedNanoWiresThermalLegendary' },
	monowire_toxic = { BY = 'tier', false, 'Items.AdvancedNanoWiresChemicalUncommon', 'Items.AdvancedNanoWiresChemicalRare', 'Items.AdvancedNanoWiresChemicalEpic', 'Items.AdvancedNanoWiresChemicalLegendary' },
	neofiber = { BY = 'tier', 'Items.AdvancedNeoFiberCommon', 'Items.AdvancedNeoFiberUncommon', 'Items.AdvancedNeoFiberRare', 'Items.AdvancedNeoFiberEpic', 'Items.AdvancedNeoFiberLegendary' },
	netdriver_deck = { BY = 'grade', 'Items.AdvancedNetwatchNetdriverMKLegendary' },
	optical_camo = { BY = 'tier', 'Items.AdvancedOpticalCamoCommon', 'Items.AdvancedOpticalCamoUncommon', 'Items.AdvancedOpticalCamoRare', 'Items.AdvancedOpticalCamoEpic', 'Items.AdvancedOpticalCamoLegendary' },
	paraline_deck = { BY = 'grade', 'Items.AdvancedMilitechParalineMKICommon', 'Items.AdvancedMilitechParalineMKIIUncommon', 'Items.AdvancedMilitechParalineMKIIIRare', 'Items.AdvancedMilitechParalineMKIVEpic', 'Items.AdvancedMilitechParalineMKVLegendary' },
	projectile_launcher = { BY = 'tier', false, 'Items.AdvancedProjectileLauncherUncommon', 'Items.AdvancedProjectileLauncherRare', 'Items.AdvancedProjectileLauncherEpic', 'Items.AdvancedProjectileLauncherLegendary' },
	projectile_launcher_electric = { BY = 'tier', false, 'Items.AdvancedProjectileLauncherElectricUncommon', 'Items.AdvancedProjectileLauncherElectricRare', 'Items.AdvancedProjectileLauncherElectricEpic', 'Items.AdvancedProjectileLauncherElectricLegendary' },
	projectile_launcher_thermal = { BY = 'tier', false, 'Items.AdvancedProjectileLauncherThermalUncommon', 'Items.AdvancedProjectileLauncherThermalRare', 'Items.AdvancedProjectileLauncherThermalEpic', 'Items.AdvancedProjectileLauncherThermalLegendary' },
	projectile_launcher_toxic = { BY = 'tier', false, 'Items.AdvancedProjectileLauncherChemicalUncommon', 'Items.AdvancedProjectileLauncherChemicalRare', 'Items.AdvancedProjectileLauncherChemicalEpic', 'Items.AdvancedProjectileLauncherChemicalLegendary' },
	ram_upgrade = { BY = 'tier', 'Items.AdvancedRamUpgradeCommon', 'Items.AdvancedRamUpgradeUncommon', 'Items.AdvancedRamUpgradeRare', 'Items.AdvancedRamUpgradeEpic', 'Items.AdvancedRamUpgradeLegendary' },
	raven_deck = { BY = 'grade', 'Items.AdvancedRavenMicrocyberMKIRare', 'Items.AdvancedRavenMicrocyberMKIIEpic', 'Items.AdvancedRavenMicrocyberMKIIILegendary' },
	rippler_deck = { BY = 'grade', 'Items.AdvancedTetratronicRipplerMKICommon', 'Items.AdvancedTetratronicRipplerMKIIUncommon', 'Items.AdvancedTetratronicRipplerMKIIIRare', 'Items.AdvancedTetratronicRipplerMKIVEpic', 'Items.AdvancedTetratronicRipplerMKVLegendary' },
	second_heart = { BY = 'tier', false, false, false, 'Items.AdvancedSecondHeartEpic', 'Items.AdvancedSecondHeartLegendary' },
	self_ice = { BY = 'tier', false, false, 'Items.AdvancedSelfIceRare', 'Items.AdvancedSelfIceEpic', 'Items.AdvancedSelfIceLegendary' },
	smart_link = { BY = 'tier', 'Items.AdvancedSmartLinkCommon', 'Items.AdvancedSmartLinkUncommon', 'Items.AdvancedSmartLinkRare', 'Items.AdvancedSmartLinkEpic', 'Items.AdvancedSmartLinkLegendary' },
	synaptic_accelerator = { BY = 'tier', 'Items.AdvancedSynapticAcceleratorCommon', 'Items.AdvancedSynapticAcceleratorUncommon', 'Items.AdvancedSynapticAcceleratorRare', 'Items.AdvancedSynapticAcceleratorEpic', 'Items.AdvancedSynapticAcceleratorLegendary' },
	tattoo_johnny = { BY = 'grade', 'Items.AdvancedSilverhandTattoo' },
	titanium_bones = { BY = 'tier', 'Items.AdvancedTitaniumInfusedBonesCommon', 'Items.AdvancedTitaniumInfusedBonesUncommon', 'Items.AdvancedTitaniumInfusedBonesRare', 'Items.AdvancedTitaniumInfusedBonesEpic', 'Items.AdvancedTitaniumInfusedBonesLegendary' },
	tyrosine_injector = { BY = 'tier', 'Items.AdvancedTyrosineInjectorCommon', 'Items.AdvancedTyrosineInjectorUncommon', 'Items.AdvancedTyrosineInjectorRare', 'Items.AdvancedTyrosineInjectorEpic', 'Items.AdvancedTyrosineInjectorLegendary' },
	visual_cortex_support = { BY = 'tier', 'Items.AdvancedVisualCortexSupportCommon', 'Items.AdvancedVisualCortexSupportUncommon', 'Items.AdvancedVisualCortexSupportRare', 'Items.AdvancedVisualCortexSupportEpic', 'Items.AdvancedVisualCortexSupportLegendary' },
}

--- The base-game record one grade of a piece is, or nil.
-- @param entryId string
-- @param tier integer the grade's tier (1..5)
-- @param index integer the grade's position among the piece's grades
-- @return string|nil
function M.Cyber.RecordFor(entryId, tier, index)
	local row = M.Cyber.RECORDS[entryId]
	if row == nil then return nil end
	local slot = row.BY == 'grade' and (tonumber(index) or 1) or (tonumber(tier) or 1)
	slot = math.max(1, math.min(#row, math.floor(slot)))
	if row[slot] then return row[slot] end
	-- The nearest tier the game does have: a Common Gorilla Arm does not
	-- exist, so the first tier sold is the Uncommon one.
	for step = 1, #row do
		if row[slot + step] then return row[slot + step] end
		if row[slot - step] then return row[slot - step] end
	end
	return nil
end

-- ── the builders ──────────────────────────────────────────────────────────

--- A value at one tier of a range that runs from the first tier to tier 5.
-- @param range number|table a plain number, or { at first, at tier 5 }
-- @param first integer the piece's first tier
-- @param tier integer
-- @param integer boolean round to a whole number
-- @return number
local function at(range, first, tier, integer)
	local value
	if type(range) ~= 'table' then
		value = range
	elseif first >= 5 then
		value = range[2]
	else
		local lo, hi = range[1], range[2]
		value = lo + (hi - lo) * (tier - first) / (5 - first)
	end
	if integer then return math.floor(value + 0.5) end
	return math.floor(value * 10 + 0.5) / 10
end

--- The inert grade fields the shared cyberware schema still validates on a
--- non-arm implant (wiki/hacking.md: "explicit inert arm fields for
--- compatibility").
local function inert()
	return { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0,
		cooldownMs = 800, chargeMs = 650, jumpStaminaCost = 0,
		maxAirborneMs = 10000, maxFallSpeed = 30 }
end

--- A Gorilla Arms grade at one tier, in the platform's own schema.
local function armsValue(first, tier)
	return {
		normalDamage = at({ 15, 40 }, first, tier, true),
		chargedDamage = at({ 35, 95 }, first, tier, true),
		knockbackMeters = at({ 2, 5 }, first, tier, false),
		cooldownMs = at({ 800, 450 }, first, tier, true),
		chargeMs = at({ 650, 450 }, first, tier, true),
		jumpStaminaCost = 0, maxAirborneMs = 10000, maxFallSpeed = 30,
	}
end

--- A deck's hack at one tier, in `Open77.hacking.define`'s grade shape. Every
--- bound here is inside the documented ones (range 1-80, upload 500-15000,
--- recovery >= status + 500).
local function hackValue(kind, first, tier)
	return {
		kind = kind,
		range = at({ 12, 25 }, first, tier, true),
		uploadMs = at({ 1800, 700 }, first, tier, true),
		staminaCost = at({ 20, 10 }, first, tier, true),
		cooldownMs = at({ 6000, 3500 }, first, tier, true),
		damage = at({ 15, 60 }, first, tier, true),
		statusMs = 750,
		recoveryMs = 4000,
		lockHacking = false,
		nonlethal = false,
	}
end

--- A Sandevistan's overdrive at one tier, in `Open77.reflex.define`'s config
--- shape (duration never past the cooldown, 1-3 charges).
local function sandyValue(first, tier)
	local cooldown = at({ 45000, 25000 }, first, tier, true)
	return {
		tier = tier >= 4 and 'reflex_heavy' or 'reflex',
		durationMs = math.min(at({ 6000, 9000 }, first, tier, true), cooldown),
		cooldownMs = cooldown,
		maxCharges = 1,
		chargeRegenMs = cooldown,
		staminaCost = at({ 25, 15 }, first, tier, true),
		heatCost = 0,
		presentation = 'native',
	}
end

--- A Berserk's ground slam at one tier, in `Open77.abilities.define`'s config
--- shape (damage 0-300, knockback 0-6, radius 0.5-12, cooldown 1000-120000).
local function berserkValue(first, tier)
	return {
		damage = at({ 40, 120 }, first, tier, true),
		knockbackMeters = at({ 2.5, 5 }, first, tier, false),
		radius = at({ 3, 6 }, first, tier, false),
		innerRadius = 1,
		staminaCost = at({ 30, 15 }, first, tier, true),
		cooldownMs = at({ 12000, 6000 }, first, tier, true),
		cosmetic = false,
		nonlethal = false,
		reaction = 'knockdown',
	}
end

--- One entry from one row, in the shape `config/ripperdoc.lua`'s CATALOG
--- declares -- so the offer rules, the page and the tests read both alike.
-- @param row table
-- @return table entry
local function build(row)
	local id, system, first, capacity, kind, effects, extra = row[1], row[2], row[3],
		row[4], row[5], row[6] or {}, row[7] or {}
	local entry = {
		id = id,
		NAME = 'ripperdoc.cw.' .. id,
		DESC = 'ripperdoc.cw.' .. id .. '.desc',
		SYSTEM = system,
		KIND = kind,
		ICONIC = extra.ICONIC == true,
		TIER = first,
		VANILLA = true,
		GRADES = {},
	}

	if extra.ARMS then
		entry.KIND, entry.SLOT, entry.PROFILE = 'implant', 'arms', 'gorilla_arms'
		entry.DEFINITION = 'opx.ripperdoc.' .. id
	elseif extra.DECK then
		entry.KIND, entry.SLOT, entry.PROFILE = 'implant', 'operating_system', 'cyberdeck'
		entry.DEFINITION = 'opx.ripperdoc.' .. id
		entry.POWER = { GRANT = 'hacking' }
	elseif kind == 'ice' then
		entry.SLOT, entry.PROFILE = 'self_ice', 'self_ice'
		entry.DEFINITION = 'opx.ripperdoc.' .. id
	elseif extra.SANDY then
		entry.PROFILE = 'reflex_overdrive'
		entry.DEFINITION = 'opx.ripperdoc.' .. id
		entry.POWER = { GRANT = 'reflex', KEY = 'x' }
	elseif extra.BERSERK then
		entry.PROFILE = 'ground_slam'
		entry.DEFINITION = 'opx.ripperdoc.' .. id
		entry.POWER = { GRANT = 'ability', KEY = 'l' }
	end

	for tier = first, 5 do
		local grade = {
			id = 't' .. tier,
			NAME = 'ripperdoc.tier.' .. tier,
			TIER = tier,
			-- Capacity climbs a fifth per tier above the first, the way the
			-- base game's upgraded chrome costs more of the body.
			CAPACITY = math.floor(capacity * (1 + 0.2 * (tier - first)) + 0.5),
			RECORD = M.Cyber.RecordFor(id, tier, tier - first + 1),
		}
		local out = {}
		for key, range in pairs(effects) do
			if M.Cyber.EFFECT_KEYS[key] then
				if type(range) == 'boolean' then
					out[key] = range
				else
					out[key] = at(range, first, tier, key == 'armor' or key == 'healthMax'
						or key == 'staminaMax' or key == 'capacity')
				end
			end
		end
		if next(out) ~= nil then grade.EFFECTS = out end

		if extra.ARMS then
			grade.VALUE = armsValue(first, tier)
		elseif extra.DECK then
			grade.VALUE = inert()
			grade.HACK = hackValue(extra.DECK, first, tier)
		elseif kind == 'ice' then
			grade.VALUE = inert()
			grade.ICE = {
				charges = at(extra.ICE.charges, first, tier, true),
				rechargeMs = at(extra.ICE.rechargeMs, first, tier, true),
			}
		elseif extra.SANDY then
			grade.VALUE = sandyValue(first, tier)
		elseif extra.BERSERK then
			grade.VALUE = berserkValue(first, tier)
		end
		entry.GRADES[#entry.GRADES + 1] = grade
	end
	return entry
end

--- One base-game piece as an entry, by its row number.
-- @param index integer 1..Count()
-- @return table|nil
function M.Cyber.Entry(index)
	local row = ROWS[index]
	return row ~= nil and build(row) or nil
end

--- Every base-game piece as an entry, built in one go. SERVER ONLY in
--- practice: on a client this is more work than one resume may do -- the
--- client builds the tray a few rows per resume (`M.Ripper.WarmCatalog`).
-- @return table array of entries
function M.Cyber.Build()
	local out = {}
	for index = 1, #ROWS do out[index] = build(ROWS[index]) end
	return out
end

--- The rows as data, for the tests' catalogue integrity checks.
-- @return integer
function M.Cyber.Count()
	return #ROWS
end

-- ── what the hand-tuned config entries ARE ────────────────────────────────
--
-- The six config pieces predate the catalogue and carry no system or kind of
-- their own. This is what the base game files them as, applied when an entry
-- names none -- so an operator's config keeps working untouched, and an
-- operator who writes SYSTEM or KIND themselves wins.
M.Cyber.LEGACY = {
	arms = { SYSTEM = 'arms', KIND = 'implant', TIER = 2, CAPACITY = 8 },
	legs = { SYSTEM = 'legs', KIND = 'implant', TIER = 2, CAPACITY = 8 },
	dash = { SYSTEM = 'nervous_system', KIND = 'grant', TIER = 2, CAPACITY = 12 },
	reflex = { SYSTEM = 'operating_system', KIND = 'grant', TIER = 2, CAPACITY = 18 },
	slam = { SYSTEM = 'operating_system', KIND = 'grant', TIER = 2, CAPACITY = 12 },
	deck = { SYSTEM = 'operating_system', KIND = 'implant', TIER = 1, CAPACITY = 14 },
}
