# NCPD and MaxTac — the mechanic, the assets, and the build

Research for a police division in `opx_infinity`: players become **wanted** through
illegal activity, the wanted level drives an **NCPD** response, and at its top stage
the response becomes **MaxTac** — the AV flying in, troopers fast-roping down, and a
second wave. Commissioned 2026-09-20. Everything below is read from the game's own
shipped data, not recalled, and every claim carries its file and line.

> **The one-line finding:** Cyberpunk 2077 already contains all of this, and the
> wanted level is not a fact we set — it is a **crime score** the engine accumulates
> and converts, one stage at a time, into an `EPreventionHeatStage`. `Heat_5` *is*
> MaxTac, and the AV, its engine noise, its red warning lines and its trooper roster
> are all base-game assets reached by a record name. The job is therefore: **feed the
> crime score, drive the stage, and stop blocking the response** — not re-implement it.

---

## 1. How the game gets and applies a wanted level

`tools/redmod/scripts/core/systems/preventionSystem.script` (5,659 lines, the engine's
own script source shipped with the game) is the whole system.

**The ladder is six stages, not five stars.** `EPreventionHeatStage` is
`Heat_0 … Heat_5` (`:5600`), defaulting the ceiling to `Heat_5` and the floor to
`Heat_0` (`:85-88`). `Heat_5` is the MaxTac stage — the game asserts it in two places
(`:411-413`, `CanRequestAVSpawn` at `:1649`).

**Stars come from a score, not from a setter.** Damage the player deals arrives as
`PreventionDamageRequest`; `UpdateTotalCrimeScore` routes it to
`CalculateCrimeScoreForNPC` or `…ForVehicle` (`:926-1054`), which add a per-attack
weight out of the heat table — `HeatKillCiv`, `HeatMeleAttackCiv`, `HeatRangeAttackCiv`,
`HeatQuickHackCiv`, `HeatExplosionCiv`, and the police equivalents — multiplied by
`m_crimeScoreMultiplierByQuest`. When the score reaches
`m_preventionDataTable.HeatThresholdCapacity()` it **resets to zero and escalates one
stage**:

```
if m_totalCrimeScore >= HeatThresholdCapacity()   { m_totalCrimeScore = 0.0; StartPipeline(request) }   :2500-2505
PostDamageChange → HeatPipeline → ChangeHeatStage(m_heatStage + 1)                                       :2540-2546
```

So illegal activity → score → **one stage per threshold**, in order. There is no
public "add a star" call anywhere in the 298 functions.

**`ChangeHeatStage` is the one door, and it is `private` (script-frame only).**
`:2549-2570`: it clamps to `[m_minHeatLevel, m_maxHeatLevel]` when the levels are not
defaults, writes the UI blackboard (`UI_WantedBar.CurrentWantedLevel = stage`), stamps
`m_lastStarChangeTimeStamp`, and calls `OnHeatChanged(previous)`. `OnHeatChanged`
(`:2577-2619+`) is where the world reacts: `AudioSystem.RegisterPreventionHeatStage`,
`GamepadLightScriptableSystem.UpdatePoliceSiren`, `PoliceRadioScriptSystem.UpdatePoliceRadioOnHeatChange`,
a ramming-multiplier change on the vehicle system, `TryUpdateWantedLevelFact()`, a
`ReinitAll()` when coming off `Heat_0`, and a per-stage switch that spawns that stage's
units.

**Reads that are already public** (`:242-347`): `IsSystemEnabled`, `IsSystemLocked`,
`IsChasingPlayer`, `IsMaxTacDefeated` (registry MaxTac count `< 1`), `GetHeatStage`,
`GetHeatStageAsInt`, `GetStarState`, `GetLastKnownPlayerPosition`, `GetLastKnownPlayerVehicle`,
`GetPlayer`, `GetCurrentDistrict`, `GetLastStarChangeStartTimeStamp`, `GetFirstStarTimeStamp`,
`GetDamageToPlayerMultiplier`, `AreTurretsActive`.
`EStarState` is `Default / Active / Searching / Blinking` — the chase's own state, separate
from the stage.

**Two statics worth knowing:** `NotifyPolice(owner : GameObject)` (`:176`) reports a crime by
an entity, and `UseCWMask(game)` (`:161`) — the mask path, whose effector is literally named
`tryDeactivatePreventionByMask`.

**Writers that exist but are `protected`** (`:1094-1146`): `SetSystemLock`,
`SetCrimeScoreMultiplier`, `SetVehicleSpawnBlockSide`, `SetDamageToPlayerMultiplier`,
`SetChaseMultiplier`, `SetBlockVehicleSpawn`, `SetBlockOnFootSpawn`,
`SetBlockShootingFromVehicle`, `SetBlockReconDroneSpawn`,
`SetMinMaxResetHeatLevels(MinLevel, MaxLevel, isDefault)`, `SetStarStateUI`.

**The `wanted_level` fact is an output, never an input.** `SetWantedLevelFact` (`:1199`)
writes it *from* the stage; `SetWantedStateFact` (`:1209`) writes `wanted_chase_active`.
The platform proved independently that forcing the fact changes nothing — the star stays
and the police keep coming (`docs/research/multiplayer-mode.md` §8). **Do not build on
the fact.**

---

## 2. MaxTac — what the base game already does at `Heat_5`

**The AV is requested by the engine, not assembled by us.**
`preventionSpawnSystem.script` exports the spawn API (`:58-60`):

```
RequestAVSpawn(recordID : TweakDBID, spawnDistanceRange : Vector2, useOffTrafficPoints : Bool) : Uint32
RequestAVSpawnAtLocation(recordID : TweakDBID, location : Vector3) : Uint32
RequestAVSpawnPoints(scriptable, functionName, spawnDistanceRange, maxSpawnPoints, useOffTrafficPoints) : Uint32
```

`PreventionSystem.CanRequestAVSpawn()` (`:1635-1668`) gates it: at most **one** AV at a
time, `GetHeatStage() == Heat_5`, `GetStarState() == Active`,
`PreventionSystemHackerLoop.AVCanBeSpawned(game)` (a vehicle-hack check, `preventionSystemHackerLoop.script:197-212`),
and a cooldown `TimeBetweenAVSpawnsAfterEncounter` since the last MaxTac trooper died.

**The AV's own record** — `Vehicle.max_tac_av`, from
`tweaks/.../vehicles/prevention_vehicles.tweak:103`:

```
max_tac_av : q001_max_tac_av
{
    tags = [ "Av", "MaxTac" ];
    isHackable = "Vehicle.Never";
    entityTemplatePath = "base\dependencies\vehicles\special\av_zetatech_surveyor_basic_01_ep1.ent";
    appearanceName = "zetatech_surveyor__basic_maxtac_camo_01";
    preventionPassengers = [ "Character.maxtac_av_riffle_ma", "Character.maxtac_av_mantis_wa",
                             "Character.maxtac_av_netrunner_ma", "Character.maxtac_av_sniper_wa_elite" ];
}
```

A Zetatech Surveyor in MaxTac camo, carrying a rifleman, a mantis-blade, a netrunner and
an elite sniper. Variants `max_tac_av1/2/3` and `max_tac_av_LMG_mb` in the second wave
(`:120-166`) — `max_tac_av2` swaps the rifleman for the LMG. **The propulsion sound and the
red warning lines are properties of that entity template and its AI package, so they arrive
with it.** Nothing about the AV needs authoring; it needs *summoning*.

**Its approach geometry is data too** — `av_spawn_setup` in
`tweaks/.../prevention_system/prevention_system.tweak`:

```
summonDistanceMin = 20.0f   summonDistanceMax = 250.0f   verticalOffset = 1050.8f
clearAreaRadius   = 9.0f    clearAreaHeight   = 80.0f    numberOfDirections = 8
avRequestTimeout  = 30.0f   avRequestRetries  = 10
```

20–250 m out and ~1 km up, from one of 8 directions: that is the fly-in, and it is why the
AV is heard before it is seen. `roadblockade_spawn_setup` names the same record for the
roadblock AV (`avRecord = "Vehicle.max_tac_av"`, `avPerpendicularOffset = 10.0f`).

**The troopers, and the ground unit, by record:** the AV-borne family is
`Character.maxtac_av_{riffle_ma, mantis_wa, netrunner_ma, sniper_wa_elite}` plus their
`_2nd_wave` twins and `Character.maxtac_av_LMG_mb`; the ground MaxTac pair is
`Character.prevention_maxtac_rifle_ma` / `..._wa`. Related records that confirm the
division is real and separable: `Attitudes.Group_SQ018_MaxTac`,
`Attacks.PreventionMaxTac_RangedAttack`, `BaseStatusEffect.MaxTacAlone`,
`AIQuickHack.HackDeath_MaxTac`, `Ability.IsAVMaxTac`, `BaseStats.IsAVMaxTac`, and the
spawn tag **`MaxTac_NotPrevention`** (`preventionSystem.script:411`) — MaxTac NPCs spawned
outside the prevention system carry their own tag and their own heat rule.

---

## 3. The NCPD ladder — every vehicle, by stage

`tweaks/.../vehicles/prevention_vehicles.tweak`, read top to bottom. This is the list the
request asks for; the names are the record IDs to spawn, the parents are the vehicle entities:

| Stage | Record | Entity |
|---|---|---|
| bike | `ncpd_brennan_apollo_bike` | `v_sportbike3_brennan_apollo_police` |
| Heat_1 | `ncpd_villefort_cortes_heat_1` | `v_standard2_villefort_cortes_police` |
| Heat_2 | `ncpd_villefort_cortes_heat_2` / `ncpd_archer_hella_heat_2` | `v_standard2_villefort_cortes_police` / `v_standard2_archer_hella_police` |
| Heat_3 | `ncpd_archer_hella_heat_3` | `v_standard2_archer_hella_police` |
| Heat_4 | `ncpd_suv_chevalier_emperor_heat_4` / `ncpd_thorton_merrimac_police_heat_4` | `v_standard3_chevalier_emperor_police` / `v_standard25_thorton_merrimac_police` |
| Heat_5 | `ncpd_hellhound_heat_5` | `v_standard3_militech_hellhound_police` |
| MaxTac (ground) | `ncpd_suv_thorton_merrimac_maxtac` | `v_standard25_thorton_merrimac_maxtac` |
| MaxTac (air) | `max_tac_av`, `max_tac_av1/2/3`, `max_tac_av_2nd_wave1/2/3` | `q001_max_tac_av` |

The same file also carries the district-flavoured pools — `border_patrol_*`,
`wasteland_chevalier_emperor_militech_*`, and the Aldecaldo nomad set — and a
`*_prevention` alias for each, which is the name the spawn system itself uses.

**Response caps are data**: `totalEntitiesLimit = 35` in a chase, `50` out of one,
`maxCountPoliceVehiclesInCrowd = 1`, `maxCountPolicePedestriansInCrowd = 2`,
`vehicleStrategyDespawnDistanceSquared = 490000` (700 m), `forcedDespawnDistance = 1000`.

---

## 4. What the platform already does, and the two things it forbids

**The native↔script seam exists and works.** `PreventionSystem`'s 287 methods are all
scripted — none native (`client/src/api/Session.hpp:489-505`) — so the platform built a
queue: native enqueues a command string, a REDscript loop polls
`Open77ScriptNextCommand()` **five times a second** and executes each command inside the
script frame it owns, then `Open77ScriptAck(command, ok)` closes the loop
(`docs/research/multiplayer-mode.md` §9). Today it carries `prevention.lock`,
`prevention.blockfoot`, `prevention.blockvehicle`, wired to a `police on|off` command, and
its measured result is `delivered=3 acknowledged=3 failed=0`. **Adding a lever is one line
in `client/redscript/Open77ScriptBridge.reds`** — that is the seam this feature is built on.

**Open77 currently *suppresses* the police.** `multiplayer-mode.md` §9 and
`world-population-and-traffic.md` §17: the bridge locks `PreventionSystem` and blocks both
spawn paths for the whole session, because vanilla prevention would otherwise fight every
player in the world. `VehicleSpawnPolicy` also strips vanilla `NPCPuppet`s and vehicles
that arrive through the spawner broadcaster, keeping only the local player and Open77's own
entities. **A police feature therefore has to unblock deliberately, per player and per
district** — and that is a policy decision, not a detail.

**And the AV/crime route must be legal to the game.** Because `ChangeHeatStage` is private
and the crime weights come from the heat table, the honest implementation drives the
engine's own pipeline (below) instead of teleporting cops at players.

---

## 5. The design

**Two divisions, one stage ladder.**

* **NCPD** — `Heat_1 … Heat_4`. The engine's own response: patrol cars and bikes from the
  table in §3, foot units, roadblocks, the recon drone, sirens and police radio, all
  already wired to the heat stage by `OnHeatChanged`. Our job is to *cause* the heat and to
  decide who is subject to it.
* **MaxTac** — `Heat_5`. A separate division with its own records (§2), its own tag
  (`MaxTac_NotPrevention`), its own arrival (the AV), and its own roster.

**The wanted level is a per-player crime ledger, not a fact we write.** `ncpd` keeps the
score: illegal activities add to it, a decay clock subtracts, and crossings call the
bridge's `prevention.heat <stage>` which invokes the engine's `ChangeHeatStage` — so the
wanted bar, the siren audio stake, the police radio and the spawn reinit all happen
*inside the game's own path*. The fact stays an output and is only ever read back as a
cross-check (`prevention.status` returns stage, state, chasing, MaxTac count, fact).

**The law book is ours, the escalation weights can be the game's.** `config/ncpd.lua`
carries a law table — `{ id, label, score, ceiling, group }` per offence class (assault,
murder, murder of an officer, vehicle theft, property damage, weapon discharge,
resisting, trespass, contraband, job heat) — plus per-district multipliers, the decay
window, and a `LADDER` **keyed by the engine's own heat number**, so `[0]` is `Heat_0`
(not wanted, and whose capacity is the score that makes a player wanted) and each row
carries the capacity that leaves it together with the response the engine already wires
to it. `MAXTAC` is validated in the same pass even though no stage acts on it yet: a
division pointed at an NCPD row, or a bot fill with no troopers, is a summon that
silently never arrives. A law is enforced by our
activities adding score and by an ACL-gated `/opx.ncpd.laws` surface. `prevention.setcrime
<multiplier>` and `prevention.heatrange <min> <max> <default>` expose
`SetCrimeScoreMultiplier` and `SetMinMaxResetHeatLevels`, so a *job* can hold a floor (a
bank job keeps you at Heat_3 while it runs) or cap a district.

**Illegal activity has to be *observed*, and Open77 can observe it.**
`PreventionDamageRequest` is the engine's own report, but it is generated for the single
local player; in a session the server must be the ledger. The module therefore records
crimes from events the server already trusts — a kill (the downed/character path), a
discharge (weapons), damage to an NPC or a vehicle owned by another citizen (the combat
and vehicle authorities), theft (vehicles), and any resource-declared act through an
export (`ncpd.report(citizenId, lawId, context)`), with the *server* deciding the score.

**Troopers are players first, bots second.** When MaxTac is summoned, the roster is filled
from players who opted into the division (a job/role), and any seat left empty is spawned
as an engine NPC using the real records:
`Open77.npcs.create({ record = "Character.maxtac_av_riffle_ma", position = …, aiMode = Open77.npcs.ai.native })`
(`wiki/npcs.md`). The same for ground NCPD units. The AV itself is summoned through the
engine (`prevention.av` bridge command → `RequestAVSpawn("Vehicle.max_tac_av", range, false)`),
so the fast-rope insertion, the engine noise and the red lines are the real ones.

**The HUD is not re-authored.** The wanted bar is the game's (`UI_WantedBar` blackboard,
written by `ChangeHeatStage`); the module adds a division/response line through the
existing `hud` and `prompts` modules instead of drawing stars twice.

---

## 6. Build order, each phase testable on its own

| Phase | Deliverable | How it is proven |
|---|---|---|
| **P0 — the seam** (open77-base) | Bridge commands `prevention.status`, `prevention.heat <stage>`, `prevention.setcrime <float>`, `prevention.heatrange <min> <max> <default>`, `prevention.av <record>`, and a release command for the session lock. | In game: `script.state` shows `acknowledged`, stars appear/disappear, `prevention.status` reads back the stage; the existing `police off` controls unchanged. |
| **P1a — the law book** (opx_infinity) — **LANDED** | `config/ncpd.lua` + `modules/ncpd/{module,shared/law,server/main}`: the validated book, the ladder keyed by heat number with its capacities and per-stage response records, district multipliers, the decay curve, and the MaxTac division's own records. The server journals the book once at boot; nothing charges anybody yet. | `tests/run.lua`: 43 checks — score and ceiling per law, stage/heat/division lookups, the one-stage-per-crime crossing, decay hold/drain/reset, district and report multipliers, the unknown-law refusal, the ceiling no-op, the crossing into MaxTac, and eight negative controls that each name a value the validator had to drop. Suite at this tree: **1069 checks, 0 failed**, all five `check.yml` gates green. |
| **P1b — the ledger** | `modules/ncpd/server/{ledger,decay}` + the client's half of the seam call: score in, decay out, stage crossings per player, `/opx.ncpd.status`, an export for other resources to report a crime, and the ACL on who may report one. | Suite: illegal-activity → stage, a ledger per character rather than per connection, the floor/ceiling clamp, and a report from a resource without permission refused. In game once P0 lands. |
| **P2 — the response** | Stage→response map driving the bridge; NCPD vehicle/unit spawns at their stages; roadblocks; the bot fallback. | In game at each stage, with the log line naming stage, division and unit count; suite pins the map. |
| **P3 — MaxTac** | The division: eligibility/opt-in, the summon at `Heat_5`, AV request, trooper roster with bot fill, second wave, the aftermath and cooldown. | In game: at 6 stars the AV flies in, the insertion happens, killing the squad ends it; suite pins the roster rules and the one-AV-at-a-time rule. |
| **P4 — the law book and its surface** | Player-facing laws (a `/laws` page or a WebUI panel), admin ACL (`opx.ncpd.*`), custom laws per server, and the README. | Suite + the ACL gate; a second server configures its own laws and the suite proves the vocabulary is config-driven rather than hard-coded. |

## 7. Decisions that are the operator's, not the implementer's

1. **Vanilla prevention or our own response?** The engine's path (unblock `PreventionSystem`
   per wanted player) gives real sirens, radio, roadblocks, the AV and its sound for free,
   but it means re-enabling the exact system the session policy disables — and it must be
   scoped so the *other* players in the world are not policed by a stranger's stars.
2. **What counts as a crime, and who can be a trooper.** The ledger needs an initial law
   set and a division-opt-in rule (ACL right, job, or a command).
3. **Where the work lives.** The seam is `open77-base` (client REDscript + one command
   enqueue); the content is `opx_infinity` (module + config + tests). Two repos, one
   contract: the bridge command vocabulary is the interface, and it should be frozen in P0
   before P1 is written against it.

---

## 8. The six things the owner asked for beside the design

These landed after the design above and are worth knowing about here. The first
three are surfaces of the same story — the city has to SEE its police working —
and the last three are what its officers fly and drive: the job fleet, the
aircraft's own voice, and the way back into the aircraft.

**The dispatch board — "when crimes are committed they need to be shown and
displayed on NCPD/MaxTac screens loudly".** The call-out (`ALERTS`) is radio
traffic: a toast in the corner and a line on the scanner band. The dispatch
board is the same moment shouted — one full-stress toast (`KIND = 'error'`,
`DURATION_MS = 12000`) wrapped in two clips (`announce-open.mp3` /
`announce-close.mp3`), on the screens of every ON-DUTY holder of the call-out's
jobs. It rides the call-out and its cooldown exactly: a RISE, and only a rise.
The wire carries the locale key and its arguments (same words as the radio),
and each receiving client reads the frame, the lifetime and the clips out of its
own `config/ncpd.lua` `ALERTS.DISPATCH` block — the same bargain the world
announcement makes. `DISPATCH.JOBS` gives the board its own air crew (MaxTac
alone); `enabled = false` darkens the board and leaves the radio standing.

**The headquarters marker — "a marker we can configure like garages, clothing
store, dealership so we can make NCPD/MaxTac headquarters".**
`config/headquarters.lua` + `modules/headquarters`: a placed spot in the shared
`lib/shared/spots.lua` vocabulary — a glowing ring marker and, while a player
stands on it, one strip row naming the place. Marker + label ONLY, deliberately:
nothing is pressed at a designation. It exists so an operator can say WHERE the
station is and place the rest around it. Placement is config-only — capture with
`/opx.admin.self.pos`, paste into `HEADQUARTERS`, verify with
`/opx.headquarters.list`.

**The MaxTac AV recall pads — "AV garage needs its own config to".**
`config/avgarages.lua` is the garages machinery in its own file: the same
`GARAGES`-shaped blocks (`KIND = 'avpad'`, MENU/ENTRY/EXITS), merged into the
garages module at load, with one addition — every pad carries the job gate
(`lib/shared/jobgate.lua` through the garages adapter). The `JOBS`/`ON_DUTY` at
the top of the file decide who may list what is parked there, bring one out or
put one away: a ground garage there is refused at boot (it belongs in
`config/garages.lua`), a key named in both files belongs to the garages file,
and a pad with no jobs named is said out loud because it is no gate. Refusals
name the closest near-miss — job, rank or duty — through the same vocabulary
every lift floor and armory bench uses.

**The job fleet — "give all maxtac and ncpd workers the vehicles they need in there
garage with proper labels" and "required avs for the role job needs to be in the
garage for players by defualt".** `config/garages.lua` `JOB_VEHICLES` declares, per
job and grade, the vehicles every member finds at the top of every garage list —
by default, owning nothing and granted nothing (the table is in
[`docs/jobs.md`](jobs.md#job-vehicles--what-each-rank-finds-in-the-garage)). The
ground rows are the player-usable police records the prevention records in §3 are
built on, climbing with rank the way the heat ladder climbs (Cortes → Hella and the
Apollo bike → Emperor and Merrimac → Hellhound); MaxTac's are the MaxTac Merrimac and
`Vehicle.max_tac_av`, the Surveyor the insertion flies, listed at the MaxTac hangars
(and any pad MaxTac may use) to every operator on duty. They are job vehicles,
signed out through the `vehicles` contract with **no row and no plate**: not
sellable, not transferable, never a car of the member's own, back to the pool at a
garage door, and taken back when the job, the grade or the shift is gone (never
from under a driver).

*The NCPD air unit.* NCPD has no AV in the prevention ladder (the `Heat_5`
aircraft is MaxTac's), but the base game does put an aerodyne in NCPD service.
The platform flies as an AV only a `Vehicle.av_*` record, or exactly
`Vehicle.max_tac_av` (`client/src/api/VehicleFlight.cpp` `IsAvRecord`). So the two
NCPD records in the base game's tweak sources can't be flown:
`Vehicle.q001_police_av` (the prologue's) and `Vehicle.sq026_av_ncpd` (a quest's).
This server's own AV rule (`AV_MATCHES`) calls them aircraft, so they came out of a
pad and never left it.

The fleet ships `Vehicle.av_zetatech_atlus`, created in the Atlus's own NCPD livery,
`zetatech_atlus_ncpd_01`:

- Its template (`base\vehicles\special\av_zetatech_atlus_basic_02.ent`) carries
  that appearance, read from the 2.31 archive. `sq026_av_ncpd` is the same Atlus in
  it.
- The row's `APPEARANCE` is passed to `Open77.vehicles.create`. The platform applies
  a create's appearance on every client (C10, since its 2026-09-14 build).
- The livery belongs to the row, not the record. A civilian's Atlus from the
  dealer keeps the record's own Trauma Team livery.
- The MaxTac rows now do the same with `zetatech_surveyor__basic_ep1_maxtac_01`:
  the garage row and `MAXTAC.AV.APPEARANCE` for the insertion.
- `config/garages.lua` says at boot when an AV row names a hull the platform won't
  fly.

**Where the NCPD AV shows.** An AV row shows at an `avpad` the player may use. The
MaxTac hangars (`config/avgarages.lua`) are MaxTac's, so NCPD's AV needs a public
`KIND = 'avpad'` garage in `config/garages.lua` `GARAGES`. Nothing is shipped, because
a pad at a coordinate nobody stood on is a pad an AV can't land on. Stand on the
station's pad, copy the point with `/opx.admin.self.pos`, and write the block.

**The aircraft's own voice — "give the maxtac av the sfx from the in game maxtac av
when it lands releasing the maxtac assault troopers".** The base game's MaxTac AV
plays four Wwise events on its `vehicle_general_emitter` (2.31 scripts):
`av_maxtac_start_descent` as it drops (`AvStartDescentSFXBehaviour`), the
`av_maxtac_descent_horn` blast when its squad bails out (`MaxTacFearEvent`, 2.5 s
after the passengers register), `av_maxtac_hover_idle` while it hangs over the
street (`AvHoverIdleSFXBehaviour`) and `av_maxtac_start_ascent` as it leaves
(`AvStartAscentSFXBehaviour`). The insertion (`modules/ncpd/server/av.lua`) plays the
same four on the airframe from the server (`Open77.effects.sound`, kind `vehicle`),
so everyone near it hears them from where the aircraft is: the drop at the start of
the descent, the horn the moment the aircraft is down (the squad steps out
`DEPLOY_SECONDS` later, as in the base game), the hover for the street hold, and the
climb. `config/ncpd.lua` `MAXTAC.AV.SOUNDS` names them; `false` silences one.

**Back into the aircraft — "not being able to reboard the maxtac av after landing
... i dont even see press f".** The base game authors no way into an aircraft (V
boards one in a scene), so an AV used to be boarded once: by the pad's hand-off, or
through the crew door's twenty-second hold. `modules/avdoor` is the door every
aircraft now has. The SERVER finds it -- only the server holds a vehicle's world
position -- by measuring every player on foot against the aircraft in their bucket
every `SCAN_MS`, judging the nearest in reach (`REACH_METRES`), and telling that one
client its door; the row reads *Board* and **F** seats them through
`warpPlayerIntoVehicle`, judged again from scratch. Who may FLY what: a rule the
hull's owner registered, the character a pad issued it to, or an on-duty holder of
the job it belongs to. The insertion registers its own: when a crew steps out of the
MaxTac AV she is **parked for `BOARDING.PARK_SECONDS`** (600) instead of removed,
any MaxTac trooper on duty climbs back in, and a cleared stage no longer takes a
parked hull away (a new stage for the same suspect flies a new aircraft beside her).
`/opx.avdoor.why` says, for the aircraft nearest to you, what the door answers.

**Other players can ride — "make sure other players can mount in av".**
`PASSENGERS = true` (the shipped default): anybody within reach of a parked aircraft
may take a FREE passenger seat (`seat_front_right`, `seat_back_left`,
`seat_back_right`); the pilot's seat, `seat_front_left`, is never offered to a
passenger, and the aircraft's owner rule still decides who flies. A rule can close
the passenger seats for its own hull with `passengers = false`. The seat's own door
swings open as the body boards (`DOORS`) and the body is seated `BOARD.DELAY_MS`
later, judged again then, so it steps in through an open door rather than popping in.
`/opx.avdoor.why` names the seat a passenger would get, or why there is none.

**Stepping out — "the player gets thrown out av and the av door doesnt open for
some".** The platform's animated AV exit crashed the game and is switched off in its
own client, so the engine drops the mount and carries the body out in one cut. The
client log of 2026-09-29 21:04:35 has the whole exit to the millisecond: the body is
put at the cockpit's exit point INSIDE the hull, the platform wakes the chassis and
reports a car impact on the body at +0.38 s, and its own deferred eject moves the
body 3.5 m behind and 2 m UNDER the hull's centre at about +1.7 s. The old fade was
back before +1.5 s, so the player watched the throw. Three parts fix it, all in
`config/avdoor.lua`:

- *The screen* (`EXIT_FADE`): out as the mount drops and held for `HOLD_MS` after a
  pilot's exit (`PASSENGER_HOLD_MS` for the other seats, which the platform does not
  eject), until the body has been still for `EXIT.SETTLE_MS`, never past
  `MAX_HOLD_MS`, then back in on a body that is standing beside the open door.
- *The body* (`EXIT`, client guard): for `GUARD_MS` after the mount drops the body is
  kept on the ground `SIDE_METRES` out from the hull's centre on its door's side (a
  metre clear of the hull's 5 m half-width, inside `REACH_METRES`, so the boarding row
  is up the moment the screen is). A jump of more than `JUMP_METRES` between two looks
  is the platform's eject and is put back; a body left inside `DANGER_METRES` when the
  guard ends is moved once more; a body in flight (over `MAX_AIR_METRES`) falls from
  the door's height and is never carried down; a seat lost more than `NEAR_METRES`
  from the hull is a teleport and is left alone. `PLACE = false` is the old fade only.
- *The door* (`EXIT`, server): the seat's door opens as the seat empties, for every
  viewer -- the door the platform opens is a local actuation that only the parked owner
  reports, so nobody else was told it opened -- stays open `DOOR_HOLD_MS`, and is
  looked at every `DOOR_REASSERT_MS` for `DOOR_REASSERT_FOR_MS` and opened again if the
  platform's own engine shut it. Every one of those reads is journalled.

**The aircraft's voice, heard by everyone — "make sure maxtac av sound is heard from
all players not just the pilot".** The pilot's client reads the flight -- the seated
body's height over the ground (`Open77.world.groundZ`) and the climb rate -- and the
server, after checking the asker really is seated in that hull, plays the base game's
`av_maxtac_start_ascent`, `av_maxtac_start_descent` and `av_maxtac_descent_horn` on
the airframe to EVERY player within `SOUNDS.RANGE` -- the pilot included -- rather
than relying on the pilot's client to fan it out. Each listener's client answers
what it did with the event (`played`, or the reason it could not) and the server
writes every answer to ITS journal, because a sound that fails on somebody else's
machine leaves no line anywhere else. A listener the host REFUSED is given the sound
through the platform's own fan-out (`SOUNDS.RESCUE`, on by default), addressed to that
listener alone, so nobody hears it twice; "this hull is not streamed here" is not a
refusal and is not rescued.

---

## 9. A kill reaches the board — the road, and its limits

"When other player kills ncpd or other player there still isnt no toast screen
showing illegal activities/murder happening for ncpd/maxtac" (the owner, 2026-09-29,
after the call-out of §8 had shipped and passed its tests). The call-out itself was
right; the kill never reached it. Everything the earlier tests did was hand the
module a death, which is a thing the platform only does in two of the three cases
that matter.

**The chain, and where it was broken.** A kill is charged by `server/main.lua`
(`HOMICIDE`): `charge` → the ledger's book moves → `sceneCallOut` puts one toast, one
scanner line, one dispatch-board frame and one map pin on every ON-DUTY holder of
`ALERTS.JOBS`. A murder is worth 40 points and the first star needs 50, so a single
kill is called in whatever stage it lands on (`HOMICIDE.CALL_OUT`), one call-out per
suspect per `COOLDOWN_MS`. The chain is entered by a death, and there are four ways
one arrives:

- *An attributed player kill* — `open77:playerKilled(victim, killer, context)`. The
  platform raises it only for a death its damage authority could attribute; an
  unattributed one raises `open77:playerDied` alone. That was the whole of what the
  module listened to.
- *A lethal hit* — `open77:playerDamaged(victim, attacker, amount, kind, weapon, part,
  health, maxHealth, lethal, downed)`, every argument text, `lethal` `"1"` on the hit
  that ends the victim.
- *A bare death* — `open77:playerDied(player, context)`, raised for every death. The
  context may name a killer; when it does not, the last player to hurt the victim
  inside `HOMICIDE.ATTRIBUTION_MS` (8 s) is put down for it, and NEVER for a fall, the
  environment or a script, and never an NPC (an NPC's id is a 64-bit number, not a
  connection). `0` turns the fallback off; a lethal hit still charges by itself.
- *A body of ours killed by a player* — `onNpcDied(npc, source, cause)`. **This one
  the platform never raised for a player's shot.** A player's hit on a server-owned
  NPC is raised as `open77:npcHit` on the SHOOTER's client alone and goes no further
  (`docs/combat.md`: the three NPC combat events are "observations, not
  applications"). A police unit stood at 100/100 for ever, `onNpcDied` never fired,
  and the murder call-out waited for a death no player could cause.

One death is one charge, however many of these report it: the module remembers a
victim's booked death for five seconds and a body's for a minute, so the first
report wins and a second, from any door, finds the mark and stands down.

**The hit relay.** `client/hits.lua` subscribes the host's local event
(`AddEventHandler`, not `RegisterNetEvent` -- the platform's own cordon mode shipped
that mistake) and, ten times a second at most, sends the server one small table per
body hit: the body's id as TEXT (a 64-bit id does not survive a Lua double), the
engine's damage and the intercept's height, the pellets of one shot summed. It sends
at most eight bodies per send and holds at most 32; it forgets everything on stop.
`server/hits.lua` decides everything else, and trusts the client for none of it:

- *Whose body*: only a unit the response placed or a body of the test crowd; the ids
  are looked up in those two tables and the platform refuses `applyDamage` on any
  other NPC anyway. A hit on somebody else's NPC is counted `not_ours` and costs nothing.
- *The number*: the engine's damage is a hint clamped to `MIN_DAMAGE..MAX_DAMAGE`
  (12..60 -- a gang record's rifle is priced for a levelled solo player), a report
  with none is worth `FALLBACK_DAMAGE`, and a hit whose height is `HEAD_METRES` over the
  body's own feet is a headshot worth `HEADSHOT`× (2). The client never names a body part.
- *The shooter*: a character loaded, alive, in the body's bucket, inside
  `MAX_RANGE_METRES` (120), no faster than `MIN_INTERVAL_MS` (45) and no more than
  `MAX_DPS` (480) in a second. An on-duty holder of the call-out's jobs is refused
  `friendly` against the city's own units (and, on a crowd body, is not charged).
- *The damage*: `Open77.npcs.applyDamage(id, amount, 'player:<id>', 'firearm')`, which
  the platform answers with `onNpcDamaged` and, at zero, `onNpcDied` -- the event the
  kill rule already charged. Every body is created on the platform's 100-point scale
  (`health = 100, maxHealth = 100`), so a unit takes four ordinary hits.
- *The backstop*: a hit that looked lethal is checked `DEATH_CHECK_MS` later, and a
  body that is dead (or gone) with no `onNpcDied` heard since is booked from its own
  health through the same one-death-one-charge door, so a platform that stays silent is
  not a murder nobody was told about.

Every refusal is counted and named, and said once per reason every ten seconds in the
journal (the ordinary `not_ours` only counted): a relay that admits nothing says why.
`HITS = false` or `enabled = false` takes it down; the knobs are read live and each
one falls back to its shipped value when it is outside what it means.

**Who is told.** The on-duty holders of `ALERTS.JOBS` (`ncpd`, `maxtac`), and only
them. A job change starts OFF duty, so an officer who has just been given the job
hears nothing until `/opx.duty`; when a call-out reaches nobody the journal now says
why (`0 on-duty holder(s) told (2 of 5 connected hold ncpd/maxtac but are CLOCKED
OFF ...)`). `/opx.ncpd.status` prints `on the air: N on duty in ncpd/maxtac` and a
`hit relay` line with what was applied and refused. The client logs
`[ncpd] dispatch received: <key>` when the board's frame arrives and
`[ncpd] hit relay: N report(s) sent` every few seconds while it is forwarding.

**What it cannot see.** The pedestrians and police the base game spawns on each
client are not the server's: their deaths are never reported to it, and this build's
client cannot read the engine's wanted level either (`crimes cannot charge the
ledger` in the client log), so a vanilla passer-by killed with a gun is not a murder
the server hears of. The call-out covers what the server can know: players, the
response's units (police, MaxTac ground squad) and the `/opx.ncpd.bots` crowd.

**Testing it.** Two players, one of them on a job in `ALERTS.JOBS` and clocked in
(`/opx.job <playerId> ncpd 0`, then `/opx.duty` as that player):

1. `/opx.ncpd.report murder <the other player>` -- the toast, the scanner line, the
   board and the pin, with no gun; proves the audience and the surfaces.
2. `/opx.ncpd.bots spawn 3`, shoot one -- four ordinary hits kill it; the journal
   reads `player N hit npc <id> (crowd)` per shot, `... charged with murder for
   killing npc <id>` once, and the call-out reaches the officer.
3. Have the other player wanted (`/opx.ncpd.heat 2 <player>`), shoot one of the
   units that arrive -- the same road, `officer down`, `murderPolice`.
4. Kill the other player -- the journal reads `player kill seen (playerKilled|
   playerDied|lethal hit|recent hit)` and `... charged with murder for killing player
   N`. The TOAST for a player-on-player kill needs a THIRD player on duty in `ncpd` or
   `maxtac`: the killer and the victim are kept off the air, and an on-duty officer who
   kills is not charged (`... killed player N on duty: use of force, not charged`), so
   with two players the journal, not the screen, is the proof. The bots of step 2 give a
   two-player test that does reach a screen.
5. `/opx.ncpd.status` -- `hit relay : ... applied, ... lethal, ... booked; refused: ...`.

