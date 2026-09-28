# The Sandevistan: the Militech Apogee, Adam Smasher's look and his ghost trail

This is the full record of the Sandevistan work on `feature/rp-framework`. It covers what a
player gets, how it is built, how the ghost trail finally came to work, every build on the way
and what each one taught, how to deploy and test it, and what is still open.

**Status (28 September 2026, XBUNIVERSE staging, opx_sandy_view 1.4.8):**

| Part | State |
|---|---|
| Apogee on the ripperdoc tray, bought in the chair, engaged on a key | working |
| 20 s cooldown after every boost | working |
| The owner's world slows to 0.15 while V does not (the base game's own asymmetry) | working |
| The base game's Sandevistan screen (camera curve `Sandevistan`, keyboard `SlowMotion`) | working |
| Adam Smasher's look on the body (blinks, trails, loops, gold eyes, red plate) | working |
| **Ghost trail: afterimages of the player's own model, owner's third-person view** | **working since 1.4.7, confirmed in game** |
| **Ghost trail as every other player sees a boosted player**, with or without ArchiveXL on their game | **working (1.4.8), confirmed in game by two players**: the parts ship in the archive's own copy of V's body files (the second player's game had no ArchiveXL, so 1.4.7 gave them no parts at all) |
| **Players within 30 m of a boost slow to 0.15**, the owner's body at full speed on their screen | **working (1.4.8), confirmed in game by two players**: each nearby client's own time-scale claim; every slow, release and each slowed client's engine clock is journalled on the server |
| The real `Items.AdvancedSandevistanApogee` in the Operating System slot | works on a character the base game allows it on (the second player's: "fitted in the Operating System slot"); refused on a level-1 character (see Known issues) |

---

## 1. What a player gets

- **The piece.** The ripperdoc sells the Militech Apogee (`apogee_sandevistan`) like any other
  chrome. Fitted in the chair, it is the platform's reflex overdrive (`open77_reflex`): the
  owner's body moves, swings and reloads faster.
- **The key.** One action engages every Sandevistan: "Overdrive: engage the reflex boost",
  default `POWER_KEYS.reflex` (`x`). A player rebinds it in **Pause › Settings › Key bindings** or
  with **`/opx.sandy.key <key>`** (`/opx.sandy.key` says the current key, `reset` restores the
  default). The "is live" message always names the key the player really has bound.
- **The time.** For the boost the owner's world runs at 0.15 while their own body does not slow.
  NPCs, traffic, physics, particles and sound slow; V does not. Everybody within 30 m of the owner
  (including anyone who walks in mid-boost) runs at 0.15 too, so they move in slow motion on the
  owner's screen. Everybody gets real time back when the boost ends or when they leave the radius.
- **The screen.** The base game's own: the camera's time-dilation curve `Sandevistan`, the
  muffled sound the engine makes in a slowed world, the keyboard's `SlowMotion` lighting, and the
  base game's `time_dilation_sandevistan_enter/exit` sounds.
- **The look (Adam Smasher's own Sandevistan).** As it engages, his teleport blink goes off at the
  body's feet and his dash sound plays on the body. For the whole boost his afterimage trails run
  from the hands, feet, chest and head, his aberration trails sit on the hips and chest, his loops
  on the hips, the eyes glow gold on everybody else's view, and the nameplate reads
  `Name // SANDEVISTAN` in red. His end blink goes off where the body stands when it ends.
- **The ghost trail.** While the owner runs, four afterimages of **their own model** (their own
  body, arms and head in Smasher's dark armour look) trail behind them along the path they really
  ran. The owner sees them on their own third-person model; every player near enough to have the
  owner streamed sees them on the owner. On a machine the boost slows, the owner's body keeps full
  speed, so everybody near a Sandevistan sees its owner fast in a slowed world, as the owner sees
  themselves.
- **The cooldown.** Every Sandevistan the ripperdoc sells comes back 20 s after its boost ends,
  and no boost outlasts that.
- **The chair.** A power bought in the chair works as soon as the patient stands up: no relog.

---

## 2. How it is built

Three layers, each doing only what it has to.

### 2.1 The platform (Open77)

- `open77_reflex` owns the overdrive itself: the speed buff, the key action `reflex_overdrive`,
  the charge and the cooldown. It changes no clock.
- The ghost trail needs **no loader** from 1.4.8: its parts ride in the archive's own copy of V's
  body files (section 3.1). Up to 1.4.7 it was an ArchiveXL patch, which needed the platform's
  `archivexl` loader resource in `resources.load` **and** ArchiveXL on every player's game; the
  second player of the first two-player test had none (RED4ext loaded one plugin, Open77) and got
  no trail at all. The `archivexl` resource may stay in the load list for anything else.

### 2.2 opx_infinity: the ripperdoc module (Lua)

| File | What it does |
|---|---|
| `config/ripperdoc.lua` | `POWER_KEYS`, the `SANDEVISTAN` block (look, time, screen, cooldown, real item, view resource, recovery), the `/opx.sandy.key` and `/opx.sandy.test` command names |
| `modules/ripperdoc/module.lua` | the events `KIT`, `REPROJECT`, `SANDY`, `KEYBIND`, `SANDYREPORT`; the Sandevistan cooldown applied to every reflex grade when the tray is built (`M.Ripper.SandyCooldown`) |
| `modules/ripperdoc/server/sandevistan.lua` (new) | the server half: on every `open77_reflex` phase for a player whose armed overdrive has a look, one `SANDY` event to every client (whose body, which phase, which look, how long is left); the positioned dash sound; slowing the players around the owner; recovering a power a client lost; `/opx.sandy.test`; the journal of what each client reports back |
| `modules/ripperdoc/client/sandevistan.lua` (new) | the client half: draws the look on every boosted body (the owner's own included) with client-owned handles so a cut-short boost can always be stopped; the owner's clock and the players slowed around them; the screen stand-in when the view resource is absent; the key and `/opx.sandy.key`; the chair's reprojection token and the lost-power watch; the real-item request; one journal line per change |
| `modules/ripperdoc/server/chrome.lua`, `server/main.lua`, `client/main.lua` | the Apogee on its own power definition (heavy tier, reflex key, `presentation = 'none'` so the platform's blue glow is off), the kit sent to the patient's machine, the powers projected again after the chair, the two commands |
| `modules/ripperdoc/locales.lua` | the key and test strings (EN/FR) |
| `core/shared/main.lua` | `OPX.Now()` always returns whole milliseconds: the host's `GetGameTimer` returns a fraction, and a `%d` format of it killed the record reader and the stand-up reprojection token, which left a fitted Sandevistan dead until the next session |
| `open77.lua` | loads the two new scripts; client permissions `world.timescale`, `world.dilation`, `vfx.screen` |

### 2.3 opx_sandy_view: a resource of its own (`extras/opx_sandy_view`, version 1.4.8)

Everything the Lua layer cannot do lives here, and it ships to every player as a preload
(`dist/opx_sandy_view.zip`). Keeping it out of opx_infinity means a server that refuses it loses
this one layer, never the ripperdoc.

| File | What it does |
|---|---|
| `open77.lua` | the manifest, with the full build history in its header |
| `client/main.lua` | exports `engage(scale, ms, easeMs)`, `release(easeMs)`, `wear(code)`, `info()` that opx_infinity calls on the owner's machine; holds the owner's clock as a platform time-scale claim, reason `open77:opx_sandy_view` |
| `server/main.lua` | logs at start that the view and the ghost trail ship with this world (no loader needed) |
| `src/r6/scripts/opx_infinity/OpxSandevistanView.reds` | the REDscript (below) |
| `src/archive/pc/mod/opx_sandy_ghost.archive` | V's two body files with the ghost trail's parts, and its meshes, material and effect, built from the base game's own files (1.4.0-1.4.7 also shipped an ArchiveXL `.xl`) |
| `tools/ghost/build.py`, `merge.py`, `pack.py`, `README.md` | how the archive is built and verified |

**What the REDscript does:**

1. **The screen and the exemption.** Seeing the view's clock claim, it sets the camera curve
   `Sandevistan` from the player state machine, exempts V from the world's dilation every frame
   (`SetIgnoreTimeDilationOnLocalPlayerZero(true)`, exactly what the base game's
   `SandevistanEvents.OnEnter` does), plays the keyboard's `SlowMotion`, and hands everything back
   when the boost ends. A real-time watch on the owner does the same, because the stamina state
   machine's update does not run every frame in a session.
2. **The third-person model.** In third person Open77 draws the owner as a separate NPC body (the
   "self view", `Character.Open77ProxyMale/FemaleMirror`). The world's dilation would slow it like
   any NPC, so for the boost the REDscript exempts it too, and lights Smasher's gold eyes on it
   while the camera is really behind it. Each mirror body gets its own watch; nothing is shared
   between NPC bodies (1.3.0 shared one list and crashed).
3. **The ghost trail** (section 3).
4. **The owner at full speed on every machine the boost slows**: every other player's copy of the
   boosted body gets the model's own exemption for the boost (section 3.3).
5. **The real item** (section 6).
6. **The journal.** Every change is one line in the Open77 client log, prefixed
   `Open77 pristine player bootstrap trace: opx_sandy_view ...`, so a test is read back from the
   player's own log.

A change to the REDscript or the archive changes the required-mod digest: the server restarts and
every player boots the game once more through the launcher. The preload is executable content, so
the server must run with `requiredMods.unsecured = true`.

---

## 3. The ghost trail (1.4.8): how it works

### 3.1 The parts

The archive carries the player body file itself,
`base\characters\common\player_base_bodies\appearances\t0_000_base__full.app`, and its censored
cut: the base game's own (2.31), every field kept, with **four layers** of four parts each added to
every one of its 36 appearances, all switched off:

- `opx_sandy_ghost1_body`, `opx_sandy_ghost1_arm_l`, `opx_sandy_ghost1_arm_r`, `opx_sandy_ghost1_head`
- ... up to `opx_sandy_ghost4_*`

plus the effect spawner `opx_sandy_ghost_fx` (the trigger `opx_sandy_ghost_on`). The game loads a
file of `archive/pc/mod` in place of the base game's by its depot path, with no plugin at all, so
every player whose launcher laid the package has the parts. Up to 1.4.7 the same parts were an
ArchiveXL patch of these two files, and a game without ArchiveXL never got them (the second
player's log: "0 of 16 parts (none), its effect spawner MISSING"). The `.xl` is gone, so a game that
does run ArchiveXL does not add them twice.

Each part is an `entGarmentSkinnedMeshComponent` (V's own body component class) on V's own
meshes, copied from the base game with one appearance added (`opx_sandy_ghost`, using
`opx_sandy_ghost.mi`: the base game's `sandevistan_multilayer.mt` with Smasher's armour layer
set). The body mesh is V's third-person body (torso, legs, feet), the arms are V's arms and
hands, and the head is V's base head with its 244 face-rig bones re-rigged onto `Head`. The
meshes' render buffers are the base game's own, byte for byte. So every afterimage is the
player's own silhouette in Smasher's look.

### 3.2 Placing them, every frame

For each lit body the REDscript keeps a short history of where the body stood (world position and
turn, frame by frame, about half a second). Every frame:

- layer *k* (1 to 4) is placed where the body was *k* × 0.08 s ago, interpolated between the two
  frames around that moment, **relative to where the body is now**, with the parts' own
  placement (`SetLocalPosition` / `SetLocalOrientation`), in this frame's pose. At a sprint that
  is about half a metre between afterimages;
- a layer shows once it is more than 0.35 m from the body and hides again under 0.25 m, so a body
  standing still has none;
- a layer never stands within 0.9 m of the camera (the third-person camera trails the body by
  about as far as the farthest afterimage, and a body inside the lens would fill the screen);
- a shown layer is **un-hidden every frame** (`TemporaryHide(false)`): Open77 hides every skinned
  mesh of a body while it dresses it or parks it and only lifts what it hid itself, so parts
  switched on later can still carry that hide. A hidden layer is moved back onto the body and
  hidden.

The per-frame driver is a 5 ms real-time timer of the delay system (`OpxSandyTrailTicker`, not
slowed by the world's dilation) that reschedules itself while any body is lit. The watch that lit
the body also places the afterimages every tenth of a second, in case the ticker stops. A jump of
more than 4 m in one frame (a teleport) starts the history again.

### 3.3 Who lights it

- **The owner's third-person model**: the model's own watch lights it while the boost runs, the
  model stands on V and the camera is behind it. Never in first person.
- **Other players' copy of a boosted player**: opx_infinity's look holds the trigger
  `opx_sandy_ghost_on` (in `LOOKS.smasher.LOOP`) on that body for the whole boost, on every
  machine the owner is streamed to. The body's own callback answers it with a watch that lights
  the afterimages as soon as the body has its parts, keeps them placed, and ends with the trigger.
  A body seated in a vehicle carries no ghost (Open77 hides remote AV occupants).
- **The owner at full speed there.** A machine within the boost's radius runs slowed (section 4),
  and on it the boosted body is just another body of the world. So the same watch gives it the
  exemption the owner's own model gets (an individual dilation of 1.0 that ignores the global one)
  for the boost, and takes it off when the trigger stops or the body leaves.

### 3.4 What the log says

```
opx_sandy_view ghost: this game gives player bodies the ghost trail's parts -- the third-person model has 16 of 16 (opx_sandy_ghost.archive's copy of V's body)
opx_sandy_view ghost: the owner's third-person model lit -- 16 of 16 parts (entGarmentSkinnedMeshComponent), 16 switched on, its effect spawner there; 4 afterimages, 0.08 s apart, placed every frame.
opx_sandy_view afterimages: the owner's third-person model -- placed 70 times in 3.02 s, 4 of 4 showing
opx_sandy_view afterimages: the owner's third-person model -- 4 of 4 shown, the farthest 1.71 m behind; the engine has the farthest shown 1.70 m from the body (asked 1.71 m)
```

and on another player's machine:

```
opx_sandy_view ghost: a boosted player's body lit -- 16 of 16 parts (entGarmentSkinnedMeshComponent), 16 switched on, its effect spawner there; ...
opx_sandy_view ghost: the boosted player's body keeps full speed on this machine (exempt from its dilation: true); this machine is slowed by it, world 0.15
```

The first line is said once, as the third-person model attaches. `0 of 16` there says this game
does not load the archive's copy of V's body (not installed, or another archive's copy of
`t0_000_base__full.app` comes first) and gives no trail on that machine. The "placed N times" line
says how often the afterimages are really moved (about 16 to 23 times a second in the confirmed
test); "the engine has the farthest shown" is that part read back from the engine
(`GetLocalToWorld`).

---

## 4. The world around a boost: the players nearby slow

A slowdown is a per-client simulation rate: no machine can slow another. So "the world around a
Sandevistan slows" is every player close enough running their own clock at the look's rate:

- **Who.** On the boost's `active` phase, and again every half second, the server
  (`server/sandevistan.lua`, `slowAround`) finds every player in the owner's bucket, alive, within
  `TIME.RADIUS` (30 m), and tells each of them (`SANDY`, phase `slow`) to run at
  `TIME.NEARBY_SCALE` (0.15, the same rate as the owner's world) for what is left of the boost. A
  player who walks in mid-boost is slowed for the rest of it; one who walks out past 1.25 x the
  radius, dies or leaves is handed real time back (`release`), and everybody still slowed is
  released when the boost ends.
- **How.** Each slowed client (`client/sandevistan.lua`, `reslow`) holds its own time-scale claim,
  `Open77.world.setTimeScale` (reason `open77:opx_infinity`, permission `world.timescale`): the
  world AND that player's own body slow, with the look's 250 ms ease. The owner's own claim is the
  view's (`open77:opx_sandy_view`), the one reason the REDscript exempts V from, so the base game's
  asymmetry stays the owner's alone. Two overlapping boosts: the slowest wins, for as long as the
  longest lasts. A player in their own boost is not slowed by somebody else's until it ends.
- **The owner at full speed.** On each slowed machine the boosted body gets the owner's model's
  exemption (section 3.3), so the owner is seen fast in a slowed world.
- **The journal.** The server writes every slow and every release with the distance
  (`player 3: Sandevistan slows player 2 (12.4 m away) to 0.15 for 9250 ms`,
  `... no longer slows player 2 (41.0 m away, past 37.5 m)`, `... (the boost completed)`); a boost
  that slows nobody names the nearest player (`0 player(s) slowed nearby (within 30 m; nearest:
  player 2 at 41.3 m)`). Each slowed client writes `Sandevistan: player 3's boost slows this
  machine -- world 0.15 for 9250 ms, this client's time scale (the world and this body)`, reads the
  engine's clock back once the ease has landed (`Sandevistan clock on this machine, slowed by
  player 3: world at 0.15, engine dilation active; claims: opx_infinity 0.15 (holding)`) and tells
  the server, which journals it (`player 2's client: slowed by player 3's Sandevistan -- held by
  timescale; clock world at 0.15 ...`, or `REFUSED: <why>` when every door refused). So a test is
  read back from the server's journal alone (`logs.cmd`).

---

## 5. How we got here: every build and what it taught

The ghost trail took nine builds. Each one was deployed to staging and tested in game, and the
next one was decided from the players' own client logs and screenshots.

| Build | What it tried | What happened / what it taught |
|---|---|---|
| 1.2.x | The base game's screen and clock: the owner's clock claimed by the view, V exempt, camera curve `Sandevistan` | Working. |
| 1.3.0 / 1.3.1 | The third-person model exempt from the world's dilation, with Smasher's effects on it | 1.3.0 kept one shared list written from the engine's parallel attach callbacks and crashed a few seconds in; 1.3.1 gives every mirror body its own watch. |
| 1.4.0 | Ghost trail from twenty parts of **Smasher's own body** on the player; first attempt at the real item | Never shipped: the afterimages should be the player's own silhouette. |
| 1.4.1 | The player's **own** body, arms and head on Smasher's shader, as plain skinned components with Smasher's masked material; his looping effect started the same frame | Parts found and switched on; nothing drawn. The real item was asked for by an id made from the record, which the inventory never holds. |
| 1.4.2 | Parts as V's own **garment** components, unmasked material, the archive's own non-looping effects started after the parts; the real item looked up by record | Still nothing drawn. |
| 1.4.3 | Test build with probes and every part **un-hidden every step** | The parts drew. Open77's self view parks the model with `TemporaryHide(true)` and lifts only what it hid, so parts switched on later stayed hidden. |
| 1.4.4 | Calibration: five shader strengths, one per boost, smallest first; un-hide only for 0.6 s; probes and the NPC screen-space echoes removed from the owner's model | The player saw nothing on the one boost tested (the smallest strength). The theory behind calibrating (an exempt body reads too fast) was wrong: the base game exempts V the same way, and ESDE runs Smasher's full (1.5, 1) on V. |
| 1.4.5 | Smasher's full strength (1.5, 1), the effect held at its peak from first frame to last (the earlier curve fell to zero at its last point, which read as seconds ends the trail after one second), started three times, parts un-hidden every step for 2 s then every second, other players' copies un-hidden too | The log proves every step ran; still no trail. **The shader's own copies do not show on these bodies.** The shader approach was dropped. |
| 1.4.6 | **The script draws the afterimages itself**: four layers of the parts, placed every frame at the body's past positions | The per-frame driver (a next-frame callback) ran twice in half a second and stopped (`2 frames in 0.58 s`); no afterimage was ever placed. |
| 1.4.7 | The driver is a 5 ms real-time timer, and the lighting watch places them too every tenth of a second | **Working on the owner's view, confirmed in game.** Placed ~16 to 23 times a second, 4 of 4 showing while sprinting. The first two-player test then showed the second player got no trail at all, on anybody: their log said "0 of 16 parts (none), its effect spawner MISSING", and their RED4ext loaded one plugin (Open77): **no ArchiveXL on their game**, so the patch that gave player bodies the parts never ran there. |
| **1.4.8** | **No loader:** the archive carries V's two body files themselves, the base game's own with the parts appended to every appearance (`tools/ghost/merge.py`), and no `.xl`. Every other player's copy of a boosted body is exempt from that machine's slowdown for the boost; the model says once how many parts its game gives player bodies; the farthest afterimage is read back from the engine. On the ripperdoc side, every slow and release is journalled on the server with the distance, and each slowed client reports its engine clock | See the status table at the top. |

Lessons worth keeping:

- Read the client log first: `opx_sandy_view ...` lines say exactly which link ran. Three "no
  trail" reports were settled by the logs alone (one test ran an old build because the server had
  not been redeployed; one showed the driver had stopped; one showed the second player's game had
  no parts, and their `red4ext-*.log` showed why: no ArchiveXL).
- Test with a second player early, and read BOTH players' logs: the owner's view working says
  nothing about another machine's game.
- Do not make a visual feature depend on a plugin the package does not ship itself. A loader
  declared by the server is still up to each player's launcher and game.
- On a body Open77 dresses or parks, anything switched on later must be un-hidden, and kept
  un-hidden.
- `DelayCallbackNextFrame` chains and the stamina state machine's update do not run every frame in
  a session. Timed delay callbacks (not slowed by dilation) do.
- The effect in the archive (`opx_sandy_ghost_x150`, Smasher's peak held) stays in the package and
  is played by nothing.

---

## 6. The real item: the Apogee in the Operating System slot

`SANDEVISTAN.WEAR = { apogee_sandevistan = 1 }` asks the view's REDscript to fit the base game's
`Items.AdvancedSandevistanApogee` in the Operating System slot, so the inventory, the paperdoll
and every stat read of the slot see it. The only door a Lua resource has to the REDscript is the
clock: the view's `wear(code)` export holds a half-second time-scale claim whose value the
REDscript decodes (`0.999 - code / 10000`). It is sent when the kit changes, again 4 s and 12 s
later, whenever the overdrive projection comes back, never over a boost.

The REDscript finds the item in the inventory by its record, gives it once if there is none, fits
that very item with the base game's own `EquipmentSystem`, reads the slot back, retries up to five
times per request, and takes off (and out of the inventory) only what it fitted. While it is
fitted, the base game's own Sandevistan activation is off (`SandevistanDecisions.EnterCondition`),
so the key and the slowdown stay the ripperdoc's.

**Current result:** the item is given, but the base game refuses to fit it:
`... is NOT fitted after 5 tries (the base game refused it: equippable false, item level 0, V's level 1)`.
See Known issues.

---

## 7. Configuration reference (`config/ripperdoc.lua`)

| Key | Meaning |
|---|---|
| `COMMANDS.key` / `COMMANDS.test` | `opx.sandy.key` (every player), `opx.sandy.test` (staff: it slows everybody near the caller) |
| `POWER_KEYS` | default key per power class: `reflex = 'x'` (every Sandevistan), `dash = 'z'`, `ability = 'l'`. A player's own rebind always wins |
| `SANDEVISTAN.enabled` | the whole feature |
| `SANDEVISTAN.LOOK` | which piece wears which look: `{ apogee_sandevistan = 'smasher' }`. A piece not named keeps the platform's own picture |
| `SANDEVISTAN.LOOKS.smasher.BLINK` | Smasher's teleport start/end effects at the feet, left in the world 15 s |
| `...LAYERS` | effects bound to body slots for the boost: `slots` (first one the body has), `every` (restart), `once`, `who` (`self`/`others`), `self` (`fpp`/`tps` on the owner's own body), `body` (left off the owner's own body where the view resource ships) |
| `...START` / `START_SECONDS` | effects the body authors, played by name as it engages (others' view) |
| `...LOOP` | effects held by name for the boost on others' view: `eye_glow_gold` and the ghost trigger `opx_sandy_ghost_on` |
| `...TIME` | `SELF_SCALE` 0.15 (owner's world), `SELF_FALLBACK_SCALE` 0.5 (whole view, when neither the lease nor the view can exempt the body; 1 turns it off), `NEARBY_SCALE` 0.15 within `RADIUS` 30 m, `EASE_MS` 250 |
| `...SCREEN` | stand-in screen when the view resource is not running: `drugged` alias at 0.5, `damage.emp` at start |
| `...SOUND` / `SELF_SOUND` | Smasher's dash sound on the body; the base game's enter/exit sounds for the owner |
| `...PLATE` | ` // SANDEVISTAN` in `#FF2D55` |
| `SANDEVISTAN.MAPPING` | the platform's action: `open77_reflex` / `reflex_overdrive` |
| `SANDEVISTAN.COOLDOWN_MS` | 20000: every reflex grade's `cooldownMs` and `chargeRegenMs`, clamped 1 to 120 s; `nil` keeps each grade's own |
| `SANDEVISTAN.WEAR` | `{ apogee_sandevistan = 1 }`: the real item code the REDscript knows |
| `SANDEVISTAN.VIEW` | `{ RESOURCE = 'opx_sandy_view' }`; `false` turns the view off |
| `SANDEVISTAN.RECOVER.AFTER_MS` | 15000: a power the client lost is projected again at most this often, never inside its own cooldown |

---

## 8. Building the ghost archive

`extras/opx_sandy_view/tools/ghost/README.md` has the full procedure. In short: extract the listed
base-game files as raw CR2W, serialize them to JSON with WolvenKit, run `build.py` (writes the
patch, the eight meshes, the material and the effect as WolvenKit JSON, deterministically), run
`merge.py` (appends the patch's parts to every appearance of V's two body files, and checks that
each merged file minus the parts IS the base game's, handles resolved), deserialize with
WolvenKit, then `pack.py` packs the archive with every segment stored and every CRC recomputed
(each mesh's buffers checked against the base game's own). The 1.4.8 archive (twelve files: the
two body files, eight meshes, the material, the effect) was read back with WolvenKit and compared
file by file: all equal; the two body files' depot-path hashes are the ones the installed
`basegame_4_appearance.archive` holds. The archive contains no other mod's files.

---

## 9. Deploying to staging

- Build the view package from the repo (`extras/opx_sandy_view`: `open77.lua`, `client/`,
  `server/`, `src/r6/`, `tools/`, and `dist/opx_sandy_view.zip` holding the `.reds` and the
  `.archive`; from 1.4.8 no `.xl`).
- The staging deploy helper (kept outside the repo, under the gitignored `.open77-scratch/`)
  uploads opx_infinity and opx_sandy_view, keeps a backup of each, installs them, sets
  `requiredMods.unsecured = true`, restarts the server and rolls back if it does not come up. It
  still keeps `archivexl` in `resources.load`; the ghost trail no longer needs it.
- After a deploy every player relaunches through the launcher (the required-mod digest changed).
- A test only counts if the client log shows the new version's lines (for 1.4.8: `this game gives
  player bodies the ghost trail's parts`). One round of testing was lost to a server still serving
  the previous build. The server's own log (`logs.cmd`, read-only) shows the `[ripperdoc]` slows,
  releases and each client's reports.

---

## 10. Testing

**Automated.** `tests/run.lua` (run with the `opx_lib` resource beside the repo:
`lua tests/run.lua`) carries the Sandevistan checks: the Apogee's own definition and key, the kit
and its announcement, the chair and the reprojection token, the look on every client and on the
owner by the right slot names, the time around the owner (walk in, walk out, nobody slowed by
their own boost), the server's journal of every slow and release and each slowed client's
report, the slowed machine's own journal and clock read-back, the lost-power recovery and its
cooldown guard, the commands, the cooldown on the tray, the journal lines, and the view
resource's REDscript and archive (read as source and as an RDAR archive: the 16 parts, the
ticker, the placement, the un-hide, the camera clearance, the booster's exemption on a slowed
machine, the parts line and the read-back, the twelve shipped files including V's two body files,
no `.xl`, every segment stored). The whole suite passes: 4208 checks, 0 failed, on the tree
committed here.

**In game.**

1. `/opx.sandy.test [seconds]` (staff) runs the whole presentation on yourself without the
   overdrive: clock, screen, look.
2. With the Apogee fitted: third person, camera at V's side, press the key, sprint. Four dark
   afterimages of your model follow you along your path; none when you stand still.
3. Read `red4ext/logs/open77-*.log`: the `[ripperdoc] Sandevistan ...` lines (server said, the
   overdrive engaged, the clock, the look's layers) and the `opx_sandy_view ...` lines (owner,
   model, ghost, afterimages).
4. **Two players**, within 10 m, both in third person: one boosts and runs. The other sees the
   afterimages behind them and their own world in slow motion, with the booster at full speed.
   Swap. Then `logs.cmd`: the server's journal must show `Sandevistan slows player N (… m away)`
   and `player N's client: slowed by player M's Sandevistan -- held by timescale; clock world at
   0.15 …` for each, and each player's own log `this game gives player bodies the ghost trail's
   parts -- … 16 of 16` and `a boosted player's body lit -- 16 of 16 parts`.

---

## 11. Known issues and next steps

- **The real item is refused on a level-1 character.** The base game answers `equippable false`
  for `Items.AdvancedSandevistanApogee` with item level 0 against V's level 1. On the second
  player's character the same code fitted it on the first try ("fitted in the Operating System
  slot"), so it is the character, not the code: most likely a level or attribute requirement.
  Next: read the item's requirement records and either meet them or fit it past them.
- **Other players' view of the ghost trail and the slowdown around a boost** were fixed in 1.4.8
  and confirmed in game by two players on 28 September: on the observer's machine the log read
  `player 2's boost slows this machine -- world 0.15`, the engine's clock `world at 0.15 ...
  claims: opx_infinity 0.15 (holding)`, `a boosted player's body lit -- 16 of 16 parts`,
  `placed 77 times in 3.01 s, 4 of 4 showing`, and the engine's read-back of the farthest
  afterimage within a few centimetres of where it was asked (`1.72 m ... (asked 1.74 m)`).
- **Update rate.** The afterimages are moved about 16 to 23 times a second, not every frame. If
  they look steppy at high speed, the ticker is the thing to tighten.
- **Skin can flash dark.** Where V's skin shows, a hidden layer sits on the body, and a layer just
  leaving the body overlaps it. ESDE has the same behaviour.
- **Screen-space echo layers.** The `smasher` look still plays Smasher's particle trails and the
  NPC Sandevistan's aberration trails (`ch_npc_sandevistan_trail_left/_right`: the chromatic
  smear and the blurred afterimage) on the boosted body, for everybody. Since 1.4.4 the owner's
  third-person model no longer plays the echoes its own template authors
  (`fx_sandevistan_left/_right`, `fx_sandevistan_versus_loop`); only its gold eyes are lit. If any
  of the look's layers fight the ghost trail visually, each is one line in
  `SANDEVISTAN.LOOKS.smasher.LAYERS`.
