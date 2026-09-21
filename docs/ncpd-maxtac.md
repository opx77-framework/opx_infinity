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
