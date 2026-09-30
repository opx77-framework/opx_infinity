# Every command, in one chart

Every command is typed in chat as `/name args`, or in the server console without
the slash. Names come from each module's own `config/*.lua` (`COMMANDS` /
`COMMAND` blocks), so those are the authoritative spellings.

**ACL:** `restricted = true` commands need `command.<name>` granted in
`acl.jsonc`. Unrestricted commands run for everyone. "in game" = refuses the
server console. Every placement capture is **stand where it goes, look the way
it should face, run the command** — the reply prints a config line to check in
so the row survives a database reset.

---

## 1. SETUP CHART — placing every job station

| What you're placing | Command (stand on the spot, face its direction) | Args |
|---|---|---|
| **Job signup board** | `/opx.jobs.add [key] <job>` | `job` required (e.g. `ncpd`); `key` auto-named (`signup1`…) if omitted — `/opx.jobs.add ncpd` works |
| **Job boss desk** | `/opx.jobs.add boss [key] <job>` | same; a desk shows only to the boss grade + its capturer |
| Remove a board | `/opx.jobs.remove <key>` | only captured boards; config rows are edited in `config/jobs.lua` |
| List all boards | `/opx.jobs.list` | prints kind, job, pos, yaw, bucket, captured/config |
| Garage (config now) | edit `config/garages.lua` | `add`/`remove` are **gone** — nothing places a garage in game; capture a point with `/opx.admin.self.pos` and paste it in |
| Export DB-only garages | `/opx.garages.export` | the paste-ready config block for every garage still living only in `opx77_garages` |
| List garages | `/opx.garages.list` | every garage, then one `job fleet <job>` line per job: `key@grade`, `(av)` for aircraft |
| Bring a stored vehicle out | `/opx.garages.bring [key] [plate]` | |
| **NCPD/MaxTac headquarters** | `/opx.headquarters.add [key] [label]` | one command, capture AND set: key auto-named (`hq1`…), answer prints the line to check into `config/headquarters.lua` |
| Headquarters remove / list | `/opx.headquarters.remove <key>` · `/opx.headquarters.list` | marker + name only — it designates the station where pads, garages and stores go |
| **MaxTac AV recall pad** | `/opx.avgarages.add [key] [label]` (restricted) · `/opx.avgarages.remove <key>` | captures AND sets the pad where you stand, facing = the recall heading; the answer prints the `config/avgarages.lua` `GARAGES` line to check in. Gated to the `JOBS`/`ON_DUTY` at the top of that file (MaxTac, on duty). **None ships**: until one is placed, the MaxTac AV row has nowhere to come out |
| **NCPD / MaxTac job vehicles** | *config only* — `config/garages.lua` `JOB_VEHICLES` (per job, per grade) | in every member's garage list **by default**, on duty; signed out, never owned; verify with `/opx.garages.list` (the `job fleet <job>` lines). Table: [docs/jobs.md](jobs.md#job-vehicles--what-each-rank-finds-in-the-garage) |
| NCPD air unit pad | *config only* — a public `KIND = 'avpad'` garage in `config/garages.lua` (capture the point with `/opx.admin.self.pos`) | the NCPD AV (Detective+) comes out of any pad NCPD may use; the MaxTac hangars are MaxTac's. **None ships** |

| **Dealership spot** | `/opx.dealership.add [garage\|avpad] [key] [label]` | same shape as garages |
| Remove dealer | `/opx.dealership.remove <key>` | |
| List dealers | `/opx.dealership.list` | |
| List for-sale stock | `/opx.dealership.stock` | anyone |
| Buy from console | `/opx.dealership.buy <key> [garage]` | anyone; stand at the dealer |
| **Clothing store** | `/opx.clothing.add [key] [label]` | key auto-named (`store1`…) |
| Remove store | `/opx.clothing.remove <key>` | |
| List stores | `/opx.clothing.list` | |
| **Bank branch** | `/opx.bank.add [key] [label]` | key auto-named (`bank1`…); the answer prints the `config/bank.lua` line to check in. **E** at its marker opens the branch menu: both balances, quick amounts, everything, another amount |
| Remove / list branches | `/opx.bank.remove <key>` · `/opx.bank.list` | config rows are edited in `config/bank.lua` |
| **Admin travel location** | `/opx.admin.world.loc.add <name> [label]` | captures where you stand; feeds `player.send` |
| Remove location | `/opx.admin.world.loc.remove <name>` | config rows are edited in `config/admin.lua` |
| **Teleport points** | *config only* — `config/teleports.lua` `POINTS` | verify with `/opx.teleports.where [key]` |
| **Elevators** | *config only* — `config/elevators.lua` `ELEVATORS` | verify with `/opx.elevators.where [key]` |
| **Ripperdoc chair (clinic marker)** | `/opx.clinic.add [key] [label]` | key auto-named (`clinic1`…); **aim at the base game's ripperdoc chair** and it snaps to it |
| Chair remove / list | `/opx.clinic.remove <key>` · `/opx.clinic.list` | |
| Nudge the seat inside a chair | `/opx.clinic.tune <key> <forward> <right> [up] [yaw]` | metres along the chair's own axes, degrees |
| Why "chrome record not ready" | `/opx.clinic.diag [playerId]` | binding, support resource, body, capacity, every fitted piece, the client's projection |
| Record the base-game menus | `/opx.clinic.record [on\|off\|snap\|dump] [playerId]` | lines land in the server journal as `[ripperdoc:rec]` |
| **Set your own chrome's condition** (staff) | `/opx.clinic.chrome <full\|0-100>` | every piece fitted on **you**: `full` = a fresh life on everything (repaired, re-armed, a broken implant fitted back for free), a number = that condition with the time left matching it, `0` = everything broken exactly as wear breaks it; answers each piece, its new condition and time left; in game only |
| **Your Sandevistan key** (any player) | `/opx.sandy.key [key\|reset]` | no argument says the key; a key rebinds the platform's "Overdrive" action on your machine; `reset` restores `POWER_KEYS.reflex` |
| Test the Sandevistan (staff) | `/opx.sandy.test [seconds]` | the whole presentation on your own body — clock, screen, Smasher's look — without the overdrive; 1–44 s (a level-scaled boost's whole length), 9 by default |

### Ripperdoc chairs

One command, like every other station — and at a clinic the city already
furnished, **the chair is the city's own**. Stand at the base game's ripperdoc
chair (Viktor's, in Watson), **aim at it**, and run **`/opx.clinic.add`** (or
`/opx.clinic.add viktor "VIKTOR'S CHAIR"` to name it). Your client looks for
the chair — the object under your crosshair when you are within
`SEAT.AIM_RADIUS` of it (the city's chair does not have to call itself one),
otherwise anything within `SEAT.SCAN_RADIUS` whose class or name reads as a
chair; a body, a car, a door or a weapon never counts — and sends back that
object's own position and facing from the engine. The server takes it when it
is within `SEAT.SNAP_RADIUS` of where it reads you standing, and:

- the patient is posed **in that chair**, facing the way it faces, on the
  platform's portable `chair` workspot (`Open77.animations.playAt`);
- **no chair prop is spawned** — the one the city placed is the one they sit in.

Every candidate the client saw is written to its log (`[ripperdoc] chair
candidate …`), so a capture that picked the wrong object is fixed by aiming
better and running it again. If the engine reports no facing for the chair,
it is taken to face you (you were looking at it) and the reply says so —
`/opx.clinic.tune <key> 0 0 0 180` turns it round. Away from any base-game chair the capture is where
you stand, facing your way, and `CHAIR_PROP` spawns a chair there.

If the pose sits a little off inside the chair, **`/opx.clinic.tune <key>
<forward> <right> [up] [yaw]`** moves the seat along the chair's own axes
(metres; forward is the way the chair faces) and turns the patient by the
degrees given — stand up and sit again to see it. Offsets are held to ±2 m: a
seat is nudged inside its chair, never carried out of it.

The capture saves to the database (the chair, and beside it the seat: what it
snapped to and the offsets) and prints the config line to check into
`config/ripperdoc.lua` `CHAIRS`. A captured key shadows a config row of the
same id (one chair moved, not two); config rows are edited by hand.

### The tray: every piece of chrome in the base game

The tray is the whole base-game catalogue — 115 pieces across the ten body
systems, each with its own tiers — plus the operator's own `CATALOG` pieces,
which win over a base-game piece of the same id. The menu reads like the base
game's: body systems on the left with their slots (frontal cortex 3, operating
system 1, arms 1, skeleton 2, nervous system 3, integumentary 3, face 1, hands 1,
circulatory 3, legs 1), the system's pieces in the middle, the piece in full on
the right with every tier, its price, its capacity and what it does **on this
server**.

What a piece does is the platform's decision, and the tray says which kind it is:

| Kind | Pieces | What happens |
|---|---|---|
| **Platform implant** | Gorilla Arms family, Reinforced Tendons, every cyberdeck | durable `Open77.cyberware` implant, staged and completed by the platform |
| **Counter-hack implant** | Self-ICE | durable implant with its ICE charges |
| **Ability** | Kerenzikov, every Sandevistan and Berserk | a platform grant (dash / reflex overdrive / ground slam) |
| **Body chrome** | plating, circulatory, skeleton and the rest | real stats: armor plating, max health, health regen, max stamina, stamina regen, no fall damage, capacity |
| **Roleplay chrome** | chrome with no adapter on this platform | fitted, takes capacity, wears out — and says it has no combat effect |

The body has a **capacity** (`CAPACITY.BASE`, raised by a Chrome Compressor):
a piece that would not fit is refused and the refusal says how much is free. A
better grade of a fitted piece is an **UPGRADE**: the working grade is traded
in for `UPGRADE.TRADE_IN` of its price. The operating system holds one of a
deck, a Sandevistan, a Berserk or the compressor, as in the base game —
`SYSTEMS` raises any slot count. Prices are `VANILLA.PRICE_BY_TIER` (iconic
pieces at `ICONIC_MULTIPLIER`, roleplay chrome at `RP_MULTIPLIER`); list an id
in `VANILLA.EXCLUDE` to take it off the tray.

### The Sandevistans: the key, the look, the time, and the chair

Every Sandevistan is the platform's **reflex overdrive** (`open77_reflex`): the
owner's body moves, swings and reloads faster. A piece named in
`SANDEVISTAN.LOOK` — the **Militech Apogee** out of the box — adds the rest of
a Sandevistan on top: the look on the body, the world slowing, and the screen.

- **The key.** One action on the player's machine engages every Sandevistan:
  "Overdrive: engage the reflex boost", registered by `open77_reflex` with
  `POWER_KEYS.reflex` (`x` out of the box) as its default. A player rebinds it
  under **Pause › Settings › KEY BINDINGS** or with **`/opx.sandy.key <key>`**
  (`/opx.sandy.key` alone says the key, `reset` restores the default); either
  one is kept on their machine and follows them to every server. The "is live"
  message names the key they really have bound.
- **The look — Adam Smasher's own Sandevistan.** The Apogee wears `smasher`
  and is registered with `presentation = 'none'`, so the platform's blue glow
  is off and the look is drawn instead, **by every client, on the owner's body
  and on the owner's own screen too**. It is read out of Smasher's 2.31 entity
  (`base\characters\entities\boss\adam_smasher.ent`, spawners `fx_sandevistan`
  and `fx_animalboss`):
  - as it engages, his **teleport blink** (`fx_sandevistan_start` →
    `ch_adam_smasher_sandevistan_teleport_start.effect`: debris, smoke and a
    cracked-ground decal) goes off at the body's feet and is left there, his
    dash sound plays on the body, and on everybody else's view the body's own
    authored Sandevistan start (`fx_sandevistan_left/right`) plays;
  - for the whole boost his **afterimage trails** (`sandevistan_trails_smasher`
    → `ch_npc_sandevistan_trail.effect`, restarted every 1.8 s because each is
    two seconds long) run from the hands, the feet, the chest and the head,
    with his **aberration trails** (`fx_sandevistan_trails_left/_right`: the
    chromatic smear and the blurred afterimage left behind) on the hips and
    chest, his **loops**
    (`fx_sandevistan_loop` → `ch_oda_sandevistan_loop.effect`, `sandevistan_loop`
    → `ch_npc_ability_kerenzikov_center_loop.effect`) sit on the hips with the
    centre flash, the eyes glow gold on everybody else's view (the base game's
    NPC Sandevistan buff), and the plate reads `Name // SANDEVISTAN` in red;
  - at the end his **end blink** (`fx_sandevistan_end`) goes off where the body
    stands. Every layer comes off the moment the boost ends — by time, death,
    a car door or a staff cancel.

  Each client binds the layers by the slot names of the body it draws on: the
  owner's own body names them `hips`, `left_foot`, `right_foot`…, everybody
  else's `Hips`, `LeftFoot`…. **In third person the owner sees it on their own
  model**: the platform's self-view body is drawn exactly where their own body
  is, so the trails bound to their hips, feet, chest and head are what the
  model wears — plus the head trail, minus the hand trails (their own hands
  are posed for first person). The `opx_sandy_view` REDscript lights the
  model's own gold eyes (`eye_glow_gold`) while the camera is really behind
  it, and the look's `body = true` layers (Smasher's start pair and his loop
  file) stand down on the owner's own body there. Up to opx_sandy_view 1.4.3
  the model also played the NPC Sandevistan echoes its template authors
  (`fx_sandevistan_left/right`, `fx_sandevistan_versus_loop`); since 1.4.4 it
  does not — they smeared copies of the screen around the body.
  The same REDscript keeps the model **as fast as V**: it is a body of its own
  that the world's dilation would otherwise slow like any NPC, so it gets the
  exemption V has for the boost. Switching view mid-boost switches all of it
  over. In first person the head trail stays off (it would be in their eyes).
- **His ghost trail — afterimages of the player's own model.** Smasher's
  afterimages are copies of his own body left behind where he just was.
  `opx_sandy_view` ships an archive (made from the base game's own files; see
  `extras/opx_sandy_view/tools/ghost/README.md`) that carries V's own two
  body files, `t0_000_base__full.app` and its censored cut, with **every
  player body** given four layers of a copy of **its own body, arms and
  head** — V's own third-person body (torso, legs, feet), arms and hands, and
  base head, in Smasher's armour look — switched off. The game loads those
  files in place of the base game's by their path, so **no loader is needed**
  (up to 1.4.7 they were an ArchiveXL patch, and a player whose game had no
  ArchiveXL saw no trail at all). For a boost the view's REDscript switches
  them on and places them **every frame** where the body was 0.08, 0.16, 0.24
  and 0.32 s before, relative to where it is now: four afterimages along the
  path the player really ran, about half a metre apart at a sprint, none
  while standing still, never inside the camera. **The owner sees it on their
  own third-person model** (never in first person), and **every other player
  near enough to have the owner's body streamed sees it on the owner** (the
  look plays the trigger `opx_sandy_ghost_on` on their copy of the owner for
  the whole boost — a player who walks up mid-boost gets it the moment the
  body arrives — and that body answers it with a watch of its own; not while
  seated in a vehicle). On a machine the boost slows, the owner's body keeps
  full speed (the exemption the owner's own model gets), so everybody near a
  Sandevistan sees its owner fast in a slowed world. `docs/sandevistan.md`
  has how it works and every build on the way.
- **The time — the base game's own.** The owner's world runs at
  `TIME.SELF_SCALE` (0.15, the Apogee's rate) while their body does not slow:
  the `opx_sandy_view` resource claims the owner's clock (reason
  `open77:opx_sandy_view`, the one slow-motion a session allows) and its
  REDscript exempts V from it every frame — exactly what
  `SandevistanEvents.OnEnter` does with `SetIgnoreTimeDilationOnLocalPlayerZero`.
  NPCs, traffic, physics, particles and sound slow; V does not. Everybody within
  `TIME.RADIUS` (30 m) of the owner — including whoever walks in mid-boost —
  runs at `TIME.NEARBY_SCALE` (0.15) for the boost, body and all, so on the
  owner's screen they move in slow motion. On a build with the platform's
  dilation lease the lease does the owner's clock instead; where neither can,
  the owner's whole view runs at `TIME.SELF_FALLBACK_SCALE` (0.5), body
  included (set it to 1 to turn that off). Everybody gets real time back when
  the boost ends, or leaves the radius.
- **The screen — the base game's own.** In Cyberpunk 2077 the Sandevistan
  screen is not an effect (the player buff's VFX and SFX lists are empty):
  `SandevistanEvents.OnEnter` sets the camera's time-dilation curve
  `Sandevistan` over the slowed clock, the muffled sound is the engine's own
  answer to a slowed world, and the keyboard plays `SlowMotion`. The
  `opx_sandy_view` REDscript does all three from the player state machine the
  frame the owner's clock lands, so nothing is laid over it; the owner also
  hears the base game's `time_dilation_sandevistan_enter/exit`.
  `opx_sandy_view` is a preload with executable content, so the server must
  run with `requiredMods.unsecured = true` (the staging deploy sets it, and
  puts everything back if the server does not come up with it); players boot
  the game once more through the launcher to install a new version. Without
  it the owner gets the stand-in instead: a glitch flash (`SCREEN.START`,
  `damage.emp`) and the drug-smear overlay (`SCREEN.ALIAS`, `drugged`).
- **Animations.** The base game has none for V's Sandevistan: no body
  animation — the afterimages are authored for NPCs and Adam Smasher, which is
  what the look puts on the player. What moves is the world, slowed around a
  body that is not.
- **Testing it.** `/opx.sandy.test [seconds]` (staff) runs the whole
  Sandevistan on your own body without the overdrive — the clock, the screen,
  the look — so the presentation can be checked on its own. Every link is
  written down on the way:
  - the **client log** (`red4ext/logs/open77-*.log`): `[ripperdoc] Sandevistan:
    the server says this player holds …`, `the overdrive is on this client …`,
    `the overdrive engaged on this body …` (and, if nothing followed, `… the
    server sent no Sandevistan for it`), `Sandevistan active from the server …`,
    `Sandevistan engaged for … ms: world …; screen …`, `Sandevistan clock on
    this machine: world at 0.15 …; claims: opx_sandy_view …`, `Sandevistan look
    on this player's own body: 12 of 12 layer(s) …, first person` (third person:
    `8 of 8 layer(s) …, 3 worn by the third-person model itself`), and the
    REDscript's own `Open77 pristine player bootstrap trace: opx_sandy_view on:
    claim true, …, V exempted true, engine says V ignores the world's dilation
    true, camera curve Sandevistan true, keyboard true` and, in third person,
    `opx_sandy_view ghost: this game gives player bodies the ghost trail's
    parts -- the third-person model has 16 of 16` (said once as the model
    attaches; `0 of 16` says this game does not load the archive's copy of V's
    body), `opx_sandy_view model: third-person model on V true, camera behind
    it true, exempt from the world's dilation true, Smasher's look on it true,
    his ghost trail 16 of 16 parts`, `opx_sandy_view ghost: the owner's
    third-person model lit -- 16 of 16 parts …; 4 afterimages, 0.08 s apart,
    placed every frame`, `opx_sandy_view afterimages: … placed N times in X s,
    4 of 4 showing` (how often they really move) and `… 4 of 4 shown, the
    farthest X m behind; the engine has the farthest shown X m from the body`
    (read back from the engine), `opx_sandy_view owner: boost on, …` / `… the
    boost is over, V runs with the world again`, and on every OTHER player's
    machine near the owner `opx_sandy_view ghost: a boosted player's body lit
    -- …`, `… the boosted player's body keeps full speed on this machine …;
    this machine is slowed by it, world 0.15` and `… ghost trail is off`
    (`… has no ghost parts yet …`: that body is still being dressed, or that
    game does not load the archive's copy of V's body);
  - the **server journal**: `[ripperdoc] player N: overdrive accepted/active/…
    -- armed piece …, look …`, `player N: Sandevistan (smasher, …) for … ms`,
    and what each client reported back (`player N's client: Sandevistan
    engaged …`, `… clock …`, `… drew player N's Sandevistan: …`).
- **How long a boost runs — it grows with the owner.** At level 1 a
  Sandevistan's boost is its grade's own (the Apogee's 9 s); at the skill
  tree's level cap it is `SANDEVISTAN.LEVEL_SECONDS` — **30 s** for a tier-1
  grade up to **40 s** for tier 5 (the Apogee) — linear in the level between.
  The platform's overdrive (the speed) still stops at its own 15 s ceiling and
  its definitions never change with a level; what runs on is everything the
  ripperdoc draws: the look, the owner's slowed world, the players slowed
  around them, the screen. A Sandevistan with no `LOOK` is the platform's to
  draw and keeps the platform's boost.
- **The cooldown.** Every Sandevistan the ripperdoc sells comes back
  `SANDEVISTAN.COOLDOWN_MS` (**20 s**) after its boost ends, whatever its grade
  said. For a boost the level lengthened, that is the end of the ripperdoc's
  boost, not the platform's: from the moment the platform's overdrive
  completes, the player's reflex grant is **held back** (revoked, and re-armed
  by nothing — not a re-projection, not the chair, not the lost-power watch)
  until the boost is over and the 20 s have passed, then armed again (a
  disconnect clears the hold with the session). The
  server journal says `... the grant is HELD ...` and `... grant is back`; a
  press that still lands inside is journalled and never drawn. The tray shows
  the cooldown as the piece's COOLDOWN.
- **The real item.** A piece in `SANDEVISTAN.WEAR` (the **Militech Apogee**)
  is also the base game's own item in the **Operating System** slot: the
  owner's client asks `opx_sandy_view` for it (a half-second message on the
  clock, the only door a Lua resource has to the REDscript), and the REDscript
  fits `Items.AdvancedSandevistanApogee` with the base game's own equipment
  system, checks it every second, fits it again if something took it off, and
  takes off — and out of the inventory — only what it fitted when the
  ripperdoc takes the piece out. While it is fitted the base game's own
  Sandevistan activation is off: the key and the slowdown stay the
  ripperdoc's. The client log says `opx_sandy_view real item: … is fitted in
  the Operating System slot` (or, after five tries, why not).
- **The chair.** A power bought in the chair reaches a body sitting in a
  workspot, which `open77_reflex` does not keep. It is projected again once the
  patient stands up and their body is free, so the key works straight away —
  no relog. A client that loses the overdrive later (a respawn on a new body)
  asks for it again, never inside the power's own cooldown.

### Durability: chrome lasts real days

Every fitted piece has a **condition** (100 = fresh, 0 = broken) and a **life
in real days**:

- **time** — `LIFESPAN_DAYS` (**6**) real calendar days from its fitting or its
  last repair to broken, **online or not**. While the player plays, every
  `TICK_SECONDS` wears their chrome by the time since it was last worn; the time
  they spent away is caught up the next time their character loads (one journal
  line: `chrome caught up over N h`).
- **hard use** — on top of the calendar, three things take extra life off,
  counted in minutes of it:
  - **use** — `USE_MINUTES` (**0.5**) per use, times the piece's own `WEAR`
    weight, on the piece that did the work (melee hits on the arms, jumps on
    the legs, dashes, overdrives, slams, uploads: `WEAR_BY`);
  - **damage** — `DAMAGE_MINUTES` (**4**) per 100 damage, on every piece
    carrying armor plating;
  - **death** — `DEATH_MINUTES` (**60**) off everything.

  Together they never take more than `WEAR_DAYS` (**1**) of one life: a piece
  worked as hard as a piece can be still lasts **5 days**, one barely used lasts
  6 — never sooner. A hard four-hour evening (hundreds of punches or jumps,
  thousands of damage soaked, a few deaths) spends roughly 5 to 10 hours of that
  day; two or three such evenings spend it whole, and then only the calendar
  decides.
- **the level** — the character's level on the skill tree stretches the whole
  life: `LEVEL_LIFESPAN` (**1.5**) times as long at the level cap (**9 days**,
  and 1.5 days of hard use), linear from level 1. An iconic piece's whole life
  is `ICONIC_LIFESPAN` times as long (**1**: every piece lasts the same).

Below `WORN_AT` a piece reads **WORN**; below `FAILING_AT` it is **FAILING** and
gives only `FAILING_EFFECT` of what it is worth; at 0 it **BREAKS** and gives
nothing (a broken implant is pulled by the platform, remembering its grade — one
that broke while its owner was away is pulled once their record reads) until a
ripperdoc **repairs** it — `REPAIR_FRACTION` of the grade's price for the share
that is missing, never less than `REPAIR_MIN` — which is a new life from that
day. The player is told at each band, and every break is journalled. The tray
shows how long each piece has left (`4D 06H LEFT`) and how much of its hard-use
allowance is spent. `LIFESPAN_DAYS = 0` or `enabled = false` switches wear off.
All of it is the `DURABILITY` block in `config/ripperdoc.lua`.

**The one-time reset.** Real days keep a piece's life in a table of its own,
`opx77_ripperdoc_life`. A piece fitted before it existed has no life row, and
the first time its owner loads it goes back to fresh — **once**, journalled per
piece (`the one-time chrome reset`): 100%, a new 6-day life from then. A broken
grant comes back armed; a broken implant the break pulled out of the body is
fitted back for free (and a broken implant whose slot now holds another piece
stays broken, repairable once the slot is free).

**The admin's override.** `/opx.clinic.chrome <full|0-100>` (staff, in game)
sets every piece fitted on the caller: `full` puts a fresh life on everything —
repaired, the grants armed again, a broken implant fitted back for free; a
number sets that condition with the calendar's wear already matching it (so the
time left is that share of the life) and no hard use; `0` breaks everything,
exactly as wear does (grants dropped, implants pulled). It answers each piece,
its new condition and its time left, and journals it.

**What the level is worth**, for the skill tree to show:
`OPX.Api.Get('ripperdoc').ChromeLevel(level, cap)` answers `lifeDays`,
`lifeBaseDays`, `lifeMaxDays`, `wearDays` and the Sandevistan boost range
`activeSeconds`, `activeBaseSeconds`, `activeMaxSeconds` (`{lo, hi}`).

### "Chrome record not ready"

The platform only reports a patient's chrome once their character is **bound**
(the character workflow does it on load) and their own client has
**projected** it back (within 15 s). Until then implants and decks cannot be
fitted — body chrome, abilities and roleplay chrome still can, and the menu says
so in a banner. The refusal now names the reason (the chrome service is offline,
the identity is not linked yet, the body is still syncing, a temporary loadout
is active, the patient is down or in a vehicle), the server journals the full
diagnosis, a binding stuck in "projecting" for `DIAGNOSTICS.REBIND_AFTER_MS` is
bound again automatically, and **`/opx.clinic.diag [playerId]`** prints
everything in one go — including what `open77_cyberware` on the patient's own
machine reports.

### Recording the base game's ripperdoc

With `RECORDER.AUTO` on (shipped), every client records the base game's own
vendor screens by itself: when Viktor's menu opens it writes a snapshot (the
menu, the body's numbers, the native chrome, who and what is around), and when
it closes it writes what changed. Lines land in the **server journal** as
`[ripperdoc:rec]`. **`/opx.clinic.record on`** records every base-game menu on
your client, `snap` takes one snapshot now, `dump` copies the whole session to
your clipboard as JSON, `off` stops.

### Headquarters

One command does the whole capture: stand where the marker should be, run
**`/opx.headquarters.add [key] [label]`** (or `/opx.headquarters.add` to let it
name the station `hq1`, `hq2`, …). The server reads where you stand — a
headquarters has no facing — saves the station, draws it for everyone at once,
and answers with the config line to check into `config/headquarters.lua`
`HEADQUARTERS`:

```lua
  hq_north = { LABEL = "NCPD HQ", X = -1527.21, Y = -218.56, Z = 7.86, BUCKET = 0 },
```

**The map pin is each station's own choice.** Add `BLIP` to a row to pin that
station on the map — `BLIP = true` for the defaults, or dress it per station:
`BLIP = { SPRITE = 'objective', COLOR = '#FFCC00' }` (sprite alias/variant/number,
colour exactly `#RRGGBB`/`#RRGGBBAA`), or `BLIP = { ICON = { ASSET = 'assets/blips/hq.svg', SIZE = 56 } }`
for a custom .svg declared in `open77.lua`. A row with no `BLIP` block is
never pinned.

The capture is live immediately and survives until the database resets; the
line is the permanent record, so paste it in. `/opx.headquarters.remove <key>`
takes a captured station back (a config row is not the command's to take), and
a capture of a key that already exists in config **moves** that station rather
than adding a second one.

### To make any placement permanent

Every `add`/capture reply ends with a config line like
`key = { LABEL = "…", KIND = "…", X = …, Y = …, Z = …, HEADING = …, BUCKET = 0 },`
— paste it into the module's `config/*.lua` (`BOARDS`/`SPOTS`/`STORES`/`POINTS`
as applicable). Captured rows live in the database; config rows survive resets.

---

## 2. JOB MANAGEMENT (jobs module)

| Command | Args | Who |
|---|---|---|
| `/opx.jobs.join <job>` | join yourself at grade 0 | restricted |
| `/opx.jobs.leave <job>` | leaves (last boss must hand over first) | restricted |
| `/opx.jobs.roster <job>` | members, grades, points | restricted |
| `/opx.jobs.rank <job> [citizenId]` | ladder + where a character stands | restricted |
| `/opx.jobs.hire <job> <playerId>` | hire someone standing at the desk | **boss grade**, not ACL |
| `/opx.jobs.promote <job> <citizenId>` | desk action | **boss grade** |
| `/opx.jobs.demote <job> <citizenId>` | desk action | **boss grade** |
| `/opx.jobs.fire <job> <citizenId>` | desk action | **boss grade** |

## 3. CHARACTER & ECONOMY

| Command | Args | Who |
|---|---|---|
| `/opx.players` | everyone online | restricted |
| `/opx.where [playerId]` | server-side position/job/money | restricted |
| `/opx.here` | your position as a config row | restricted, in game |
| `/opx.characters` | list your characters | everyone |
| `/opx.select <citizenId>` | switch character (disconnects) | everyone |
| `/opx.create` | new character (disconnects) | everyone |
| `/opx.delete <citizenId>` | delete a character | everyone |
| `/opx.duty` | clock in/out of your job | everyone |
| `/opx.money <playerId\|citizenId> <TYPE> <amount>` | negative removes | restricted |
| `/opx.job <playerId\|citizenId> <job> [grade]` | **set someone's job** | restricted |
| `/opx.gang <playerId\|citizenId> <gang> [grade]` | set gang | restricted |
| `/opx.group <job\|gang> <name>` | list members | restricted |
| `/opx.save` | save everyone | restricted |
| `/opx.withdraw <amount>` | turn EDDIES into `eddies` notes in your bag (use the stack to pay them back in); **BANK is untouched** — BANK becomes EDDIES at a **bank branch** (E at its marker, `modules/bank`) | everyone |
| `/opx.skills.level <max\|reset\|1..20> [playerId]` | **skill tree**: set a character's level — for testing or for fun | restricted |

**The skill tree lever** (`config/skills.lua` `COMMANDS.level`). The player defaults to
the caller; the console must name one. It is also on the staff menu (F9): **Myself →
LEVELS → Max all levels** (tree + base game) and **Reset levels** (asks first), the same two
on every player's page for that player, and on Myself **Repair all chrome**
(`/opx.clinic.chrome full`) — `config/admin.lua` LINKS `SKILLS_LEVEL` and `CHROME`, each
greyed when the ACL refuses its command.

- `max` — level 20 (the cap) with a full bar, every trunk fed to its full depth, and the
  points to buy every node still locked (never fewer than they held) — **and the base
  game's own levels maxed on that player's machine**: Level, Street Cred, attributes,
  skills, perk and relic points, through the `opx_sandy_view` preload's `develop` export
  (1.4.9+, `DEVELOP` in the config; `RESOURCE = false` turns it off). The caller is told
  it was *asked*; the journal says what the machine answered —
  `[skills] player N: base-game development maxed on their client`, or `… refused on
  their client: <why>` (`invalid_code`, `boosting`, `no_timescale_on_this_build`, or the
  preload not running) — and the player is toasted either way.
- `1..20` — that level with no XP into it; the points it banks, less what the claimed
  nodes cost (never below zero). Trunks and claimed nodes are kept.
- `reset` — level 1, nothing fed, nothing claimed, nothing banked.

Every use is written back, journalled (`[skills] … set player N (<citizen>) to <verb>:
level L/20, P point(s) to spend`), and toasted to the player; a tree they have open
redraws on the spot, and a closed one stays closed.

## 4. NCPD (job: law desk)

| Command | Args | Who |
|---|---|---|
| `/opx.ncpd.status [player]` | heat/stage readout | restricted |
| `/opx.ncpd.report <law> [player]` | charge a player | restricted |
| `/opx.ncpd.heat <stage> [player]` | set heat stage | restricted |
| `/opx.ncpd.av [player]` | asks the engine's own AV route — on this build it answers ticket 0 and **nothing spawns**; `/opx.ncpd.heat 5` is what flies the MaxTac AV and its squad | restricted |
| `/opx.ncpd.clear [player]` | wipe the record | restricted |
| `/opx.ncpd.laws` | print the law book | restricted |
| `/opx.ncpd.board [seat]` | take a crew seat on the AV (needs the AV holding at street level, you on duty as MaxTac or holding `opx.ncpd.maxtac`) | restricted |
| `/opx.ncpd.bots <spawn [count]\|clear\|status>` | civilians to test the ladder on: 24 by default (64 max), each kill charged as `murder` | restricted |

**The dispatch board** is not a command. When a crime raises a wanted stage, the
same call-out the radio carries is shouted on the screens of every on-duty
holder of `ALERTS.JOBS`: one full-stress toast, wrapped in two clips, on one
fixed id so a firefight is one board and not three. Tune it in `config/ncpd.lua`
`ALERTS.DISPATCH` — `KIND`, `DURATION_MS`, the two `STINGER` clip names
(`web/audio/`, bare file names), and `JOBS` to give the board its own air crew
(e.g. MaxTac alone). `enabled = false` darkens the board and leaves the radio
call-out standing.

**A kill is called in too** (`config/ncpd.lua` `HOMICIDE`). A player killed by a
player, or a body of this server's own killed by a player, charges the killer `murder`
(an officer on duty killed: `murderPolice`, "Officer down") and puts the call-out on
the board, the scanner and a toast for every ON-DUTY holder of `ALERTS.JOBS`
(`ncpd`, `maxtac`), with a map pin at the scene for `PIN_SECONDS`. Officers on duty
are not charged; the suspect and the victim are not told; one killer is called in at
most every `COOLDOWN_MS`.

*Whose kills the server can see.* Players (any of the three events the platform
raises for a death: the attributed kill, the lethal hit, the bare death, with the
last player to hurt the victim inside `ATTRIBUTION_MS` blamed for one that names
nobody — never for a fall, the environment or a script), and the bodies this
resource stands on the street: the response's police units, the MaxTac squad and the
`/opx.ncpd.bots` crowd. The platform does not carry a player's shot at an NPC to the
server, so `client/hits.lua` forwards it and `server/hits.lua` prices and applies it
(`HITS` in `config/ncpd.lua`); see
[`ncpd-maxtac.md` §9](ncpd-maxtac.md#9-a-kill-reaches-the-board--the-road-and-its-limits).
The street crowd the base game spawns on each client never reaches the server, so
those kills are **not** seen.

*Nobody was told?* The audience is **on duty** in `ncpd` or `maxtac`: a job change
starts off duty, and `/opx.duty` clocks in. `/opx.ncpd.status` prints
`on the air: N on duty in ncpd/maxtac` and a `hit relay` line (hits applied, kills
booked, refusals by reason); the server journal says `N on-duty holder(s) told` on
every call-out, with `CLOCKED OFF` named when the reason is duty.
`/opx.ncpd.report murder <player>` stages one without a gun.

## 5. INVENTORY / WEAPONS

| Command | Args |
|---|---|
| `/opx.inventory.give <playerId\|citizenId> <item> [count]` | |
| `/opx.inventory.remove <playerId\|citizenId> <item> [count]` | |
| `/opx.inventory.clear <playerId\|citizenId>` | |
| `/opx.inventory.open <playerId\|citizenId>` | open someone's bag |
| `/opx.inventory.holders <item>` | who holds an item |
| `/opx.admin.weapon.give <playerId\|me> <weapon> [ammo] [count]` | |
| `/opx.admin.weapon.giveammo <playerId\|me> <ammo> [count]` | |
| `/opx.admin.weapon.ammo <playerId\|me> [ammo\|all] [count]` | refill |
| `/opx.admin.weapon.remove <playerId\|me> <weapon\|all>` | |
| `/opx.admin.weapon.holster <playerId\|me>` | |
| `/opx.admin.weapon.read [playerId\|me]` | read the loadout |

## 6. VEHICLES (staff)

| Command | Args |
|---|---|
| `/opx.admin.vehicle.spawn <vehicle>` | in game |
| `/opx.admin.vehicle.give <playerId\|me> <vehicle>` | |
| `/opx.admin.vehicle.remove [vehicleId\|near\|mine]` | default `near` |
| `/opx.admin.vehicle.cleanup` | remove every staff-spawned vehicle |
| `/opx.admin.vehicle.repair [vehicleId\|near] [scope]` | scope default `full` |
| `/opx.admin.vehicle.enter <vehicleId\|near>` | in game |
| `/opx.admin.vehicle.flag <vehicleId\|near> <flag> [on\|off]` | |
| `/opx.avdoor.why` | **everyone**: why the aircraft nearest to you does or does not open its door (**F**) to you, and how far it is |

## 7. STAFF — self / player / world / moderation

| Command | Args | Notes |
|---|---|---|
| `/opx.admin` | — | opens the staff menu (the staff-grant command) |
| `/opx.admin.self.noclip [on\|off]` | | in game |
| `/opx.admin.self.speed <m/s>` | 0.1..500 | in game |
| `/opx.admin.self.maptravel [on\|off]` or `<x> <y> <z>` | | in game |
| `/opx.admin.self.heal` / `.revive` | | in game |
| `/opx.admin.self.god [on\|off]` / `.invisible [on\|off]` | | in game |
| `/opx.admin.self.pos` | prints a config row where you stand | in game |
| `/opx.admin.self.tags [on\|off]` | staff name tags | in game |
| `/opx.admin.self.model [ped\|off]` | | in game |
| `/opx.admin.player.goto <playerId>` / `.bring` / `.observe` | | in game |
| `/opx.admin.player.tp <playerId\|me> <x> <y> <z> [heading]` | | |
| `/opx.admin.player.send <playerId\|me> <location>` | uses saved locations | |
| `/opx.admin.player.freeze <playerId> [on\|off]` | | |
| `/opx.admin.player.heal / .revive / .wardrobe <playerId\|me>` | | |
| `/opx.admin.player.god <playerId\|me> [on\|off]` | | |
| `/opx.admin.player.kill <playerId>` | | |
| `/opx.admin.player.health <playerId\|me> <points>` | | |
| `/opx.admin.player.armor <playerId\|me> <0..10000>` | | |
| `/opx.admin.player.model <playerId> [ped\|off]` | | |
| `/opx.admin.character.list <playerId\|me>` | account's characters | |
| `/opx.admin.character.rename <citizenId> <first> <last>` | | |
| `/opx.admin.character.delete <citizenId>` | | |
| `/opx.admin.character.find <term>` | search the whole player base | |
| `/opx.admin.moderate.kick <playerId> [reason]` | | |
| `/opx.admin.moderate.ban <playerId> [duration] [reason]` | | |
| `/opx.admin.recovery.money <playerId\|me> <TYPE> <amount>` | refund | in game |
| `/opx.admin.world.loc.add <name> [label]` / `.loc.remove <name>` | travel points | add is in game |
| `/opx.admin.world.announce <text>` | broadcast | |
| `/opx.admin.world.pvp [on\|off]` | toggle PvP | |
| `/opx.admin.world.door <doorId> <open\|close\|lock\|unlock\|seal\|unseal\|reset>` | | in game |
| `/opx.admin.inventory.view\|give\|remove\|clear` | see §5 | |
| `/opx.admin.read.status` | server health | |
| `/opx.admin.read.audit [count]` | last staff actions (default 15, max 40) | |

## 8. WORLD / WEATHER / TIME

| Command | Args | Who |
|---|---|---|
| `/opx.weather` | current weather | everyone |
| `/opx.weather.presets` | list presets | everyone |
| `/opx.weather.set <preset> [transitionSeconds]` | | restricted |
| `/opx.weather.next` | no arguments | restricted |
| `/opx.weather.freeze <on\|off>` | | restricted |
| `/opx.time <HH:MM[:SS]>` | | restricted |
| `/opx.time.freeze <on\|off>` | | restricted |
| `/opx.time.length <realMinutes>` | | restricted |
| `/opx.wait <hours>` | 1 to 23: moves **your own** clock ahead for a mission's wait; the shared hour comes back on your game after 20 minutes | everyone |

## 9. ANIMATIONS / APPEARANCE / DIAGNOSTICS

| Command | Args | Who |
|---|---|---|
| `/opx.anim [name [variant] \| category]` | play an animation | everyone |
| `/e [name …]` | emote alias | everyone |
| `/opx.anim.stop` | stop | everyone |
| `/opx.anim.list` | list | everyone |
| `/opx.appearance` | open the appearance panel | everyone |
| `/opx.modules` / `/opx.version` | diagnostics | |
| `/opx.client` | client diagnostics | in game |

---

Command names live in `config/*.lua` (`COMMANDS` blocks) and the admin names in
`modules/admin/module.lua` `M.Command`; renaming them there renames the typed
line and the `acl.jsonc` grant `command.<name>` together.
