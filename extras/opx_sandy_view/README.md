# opx_sandy_view

The part of the ripperdoc's Sandevistan that a Lua resource cannot do on its own, shipped to every
player as a preload (`dist/opx_sandy_view.zip`, built from this folder):

- **the base game's Sandevistan screen and clock**: the camera's time-dilation curve
  `Sandevistan`, V exempt from the owner's slowed world, the keyboard's `SlowMotion`;
- **the owner's third-person model** kept as fast as V for the boost, with Smasher's gold eyes;
- **Adam Smasher's ghost trail**: twelve afterimages of the player's own model (1.4.9; four up to
  1.4.8), placed every frame where the body was 0.045, 0.09 ... 0.54 s before and shown from
  0.2 m behind it (working since 1.4.7), on the owner's model and on every other player's copy
  of the owner; from 1.4.8 its parts ship in the archive's own copy of V's body files, so it
  needs no ArchiveXL on anyone's game; from 1.4.10 with their arms and hands (the arm meshes
  list the ghost's material in `preloadExternalMaterials`, where a mesh that keeps its own as
  `preloadLocalMaterialInstances` reads it); from 1.4.12 with their legs on a female V too (her
  body part hid the knees, calves and feet, which the base game draws from a part of their own);
- **the owner at full speed on every machine the boost slows**: every other player's copy of the
  boosted body keeps the owner's pace in the slowed world, for boosts of up to 40 s (45 s with
  the ease: the owner's claim and every window of the REDscript cover it from 1.4.9);
- **the real item**: the base game's `Items.AdvancedSandevistanApogee` in the Operating System
  slot (currently refused by the base game, see the doc below);
- **the base game's own development, maxed** (1.4.9, for an admin's "max all levels"):
  `develop(10)` has the REDscript set this machine's character to the base game's own maxima --
  level, street cred, attributes, skills, perk and relic points -- once per request, again on a
  new body for the rest of the session;
- **the MaxTac AV, visible** (1.4.10): every TweakDB record of the MaxTac AV names the base
  game's cloaked livery (`zetatech_surveyor__basic_maxtac_camo_01`), which only the base game's
  prevention AI ever lifts, and a vehicle created without an appearance comes out in its
  record's -- so it came out invisible but for its stickers, one door and its thrusters.
  `OpxMaxTacAv.reds` schedules the airframe's visible MaxTac livery
  (`zetatech_surveyor__basic_ep1_maxtac_01`) on it the moment it attaches, on every player's
  game, in a multiplayer session. Since 1.4.11 opx_infinity also creates the division's AV in
  that livery, so this is the second line, for a MaxTac hull created without one;
- **the Sandevistan user, really faster** (1.4.11): while the boost holds, V's own `MaxSpeed`
  gets one more multiplier (x1.5, `OpxSandevistanSpeedBoost`) on top of the platform's reflex
  overdrive, through the base game's stats system, taken off the moment the boost ends;
- **the base game's missions, playable** (1.4.11): `OpxQuests.reds` gives back, in a session, what
  Open77's policy switches off and a side job waits on -- a quest's holocalls (answered on the
  phone key's press, since this server's chat opens on the same key), texts and "call X" steps;
  a quest's own items in containers, bodies and pickups (and a quest pickup the platform's sweep
  empties goes into the player's inventory instead of vanishing); the scanner; the objective
  tracker, quest markers and quest toasts; V's own lines in a conversation; a quest's unlock of a
  door the server owns. It is the outermost wrapper of the same base-game methods, and each
  client log says whether it really runs (`opx_sandy_view quests: missions restored ...`).
- **Phantom Liberty on a female V's world** (1.4.13): a female V enters on `NCMP-Template-F`, a
  save that never started the expansion, so Dogtown had its crowd and nothing else -- no
  Barghest, vendors, Heavy Hearts, gate, gigs or story. `OpxQuests.reds` sets `ep1_active` and
  `ep1_side_content` to 1 where they read 0 (the male save's values), and the base game's graph
  does the rest: Songbird calls to start "Dog Eat Dog". The client log says what it found
  (`opx_sandy_view quests: Phantom Liberty opened on this world ...`).
- **The map, step by step in the client log** (1.4.14): opening the map hard-crashed the game
  (2026-09-29), and the log stopped at `map:composition=ready` without saying which step the game
  died in. `OpxQuests.reds` now writes `opx_sandy_view quests: map: opening`, `tooltips hidden 1`,
  `tooltips hidden 2`, `opened`, `reading the zoom levels`, `scene attaching`, `scene attached`,
  each quest marker and `closed`, so the last line after a crash is the step it died in. It changes
  nothing on the map.
- **Opening the map no longer crashes the game** (1.4.15): the crash probe's record was an access
  violation (a read at `0x38`) inside the game's own native `IMappin.GetScriptData`, reading the data
  pointer of the marker the fullscreen map makes for the player's own arrow -- a runtime marker
  that never had one. `OpxQuests.reds`' marker gate asked every marker for its script data first
  (the arrow included, and before the `opx_quests_off` switch); it now judges the init data first,
  the object's class next, the off switch after, and reads a marker's data last, and the map's
  wrapper passes a runtime marker on after a class test alone. Each marker the map asks about is
  still written to the client log (`map: marker asked N: ...`) before it is judged. Every player
  boots the game again through the launcher once.

The full record (design, every build and what it taught, configuration, deploy, testing, known
issues) is **[`docs/sandevistan.md`](../../docs/sandevistan.md)**. The build history is also in the
header of [`open77.lua`](open77.lua) and of the REDscript
[`src/r6/scripts/opx_infinity/OpxSandevistanView.reds`](src/r6/scripts/opx_infinity/OpxSandevistanView.reds).

| Path | What |
|---|---|
| `open77.lua` | manifest (version, preload, the `archivexl` note, exports) |
| `client/main.lua` | `engage` / `release` / `wear` / `develop` / `info` exports: the owner's clock claim (`open77:opx_sandy_view`, at most 45 s), the real-item message (codes 0-9) and the development message (code 10) |
| `server/main.lua` | the server side: says the view and the ghost trail ship with this world |
| `src/r6/scripts/opx_infinity/OpxSandevistanView.reds` | the REDscript |
| `src/r6/scripts/opx_infinity/OpxMaxTacAv.reds` | the MaxTac AV's visible livery (1.4.10) |
| `src/r6/scripts/opx_infinity/OpxQuests.reds` | the base game's missions, playable in a session (1.4.11); Phantom Liberty opened on a world that never started it (1.4.13); the fullscreen map's steps in the client log (1.4.14) |
| `src/archive/pc/mod/opx_sandy_ghost.archive` | V's two body files with the ghost trail's 48 parts (12 layers from 1.4.9), and its meshes, material and effect (no `.xl` from 1.4.8; the arms' material fixed in 1.4.10; a female V's legs in 1.4.12) |
| `tools/ghost/` | `build.py`, `merge.py`, `pack.py` and the README that rebuilds and verifies the archive |

**Requirements on the server:** `requiredMods.unsecured = true` (the preload is executable
content). No loader: up to 1.4.7 the ghost trail was an ArchiveXL patch and needed the platform's
`archivexl` resource and ArchiveXL on every player's game. After any change to the `.reds` or the
archive, the server restarts and every player boots the game once more through the launcher (the
required-mod digest changes).
