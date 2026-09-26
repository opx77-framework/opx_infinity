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
| **Job signup board** | `/opx.jobs.add [key] <job>` | `job` required (e.g. `ncpd`); `key` auto-named (`signup1`…) if omitted |
| **Job boss desk** | `/opx.jobs.add boss [key] <job>` | same; a desk shows only to the boss grade + its capturer |
| Remove a board | `/opx.jobs.remove <key>` | only captured boards; config rows are edited in `config/jobs.lua` |
| List all boards | `/opx.jobs.list` | prints kind, job, pos, yaw, bucket, captured/config |
| Garage (config now) | edit `config/garages.lua` | `add`/`remove` are **gone** — nothing places a garage in game; capture a point with `/opx.admin.self.pos` and paste it in |
| Export DB-only garages | `/opx.garages.export` | the paste-ready config block for every garage still living only in `opx77_garages` |
| List garages | `/opx.garages.list` | |
| Bring a stored vehicle out | `/opx.garages.bring [key] [plate]` | |
| **NCPD/MaxTac headquarters** | `/opx.headquarters.add [key] [label]` | one command, capture AND set: key auto-named (`hq1`…), answer prints the line to check into `config/headquarters.lua` |
| Headquarters remove / list | `/opx.headquarters.remove <key>` · `/opx.headquarters.list` | marker + name only — it designates the station where pads, garages and stores go |
| **MaxTac AV recall pad** | *config only* — `config/avgarages.lua` `GARAGES` (`KIND = 'avpad'`) | same block shape as `config/garages.lua`; gated to the `JOBS`/`ON_DUTY` at the top of that file |

| **Dealership spot** | `/opx.dealership.add [garage\|avpad] [key] [label]` | same shape as garages |
| Remove dealer | `/opx.dealership.remove <key>` | |
| List dealers | `/opx.dealership.list` | |
| List for-sale stock | `/opx.dealership.stock` | anyone |
| Buy from console | `/opx.dealership.buy <key> [garage]` | anyone; stand at the dealer |
| **Clothing store** | `/opx.clothing.add [key] [label]` | key auto-named (`store1`…) |
| Remove store | `/opx.clothing.remove <key>` | |
| List stores | `/opx.clothing.list` | |
| **Admin travel location** | `/opx.admin.world.loc.add <name> [label]` | captures where you stand; feeds `player.send` |
| Remove location | `/opx.admin.world.loc.remove <name>` | config rows are edited in `config/admin.lua` |
| **Teleport points** | *config only* — `config/teleports.lua` `POINTS` | verify with `/opx.teleports.where [key]` |
| **Elevators** | *config only* — `config/elevators.lua` `ELEVATORS` | verify with `/opx.elevators.where [key]` |
| **Ripperdoc chair (clinic marker)** | `/opx.clinic.add [key] [label]` | key auto-named (`clinic1`…); **aim at the base game's ripperdoc chair** and it snaps to it |
| Chair remove / list | `/opx.clinic.remove <key>` · `/opx.clinic.list` | |
| Nudge the seat inside a chair | `/opx.clinic.tune <key> <forward> <right> [up] [yaw]` | metres along the chair's own axes, degrees |
| Why "chrome record not ready" | `/opx.clinic.diag [playerId]` | binding, support resource, body, capacity, every fitted piece, the client's projection |
| Record the base-game menus | `/opx.clinic.record [on\|off\|snap\|dump] [playerId]` | lines land in the server journal as `[ripperdoc:rec]` |

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

### Durability: every piece wears out

Every fitted piece has a **condition** (100 = fresh) and four things take it down:

- **use** — the host's own action events on the piece that did the work
  (melee hits on the arms, jumps on the legs, dashes, overdrives, slams, uploads);
- **time** — `LIFESPAN_HOURS` of play from fresh to broken (iconic pieces last
  `ICONIC_LIFESPAN` times longer);
- **damage** — `DAMAGE_WEAR` points per 100 damage on every piece carrying armor plating;
- **death** — `DEATH_WEAR` points off everything.

Below `WORN_AT` a piece reads **WORN**; below `FAILING_AT` it is **FAILING** and
gives only `FAILING_EFFECT` of what it is worth; at 0 it **BREAKS** and gives
nothing (a broken implant is pulled by the platform, remembering its grade)
until a ripperdoc **repairs** it — `REPAIR_FRACTION` of the grade's price for the
share that is missing, never less than `REPAIR_MIN`. The player is told at each
band. All of it is the `DURABILITY` block in `config/ripperdoc.lua`.

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
| `/opx.withdraw <amount>` | cash out banked money | everyone |

## 4. NCPD (job: law desk)

| Command | Args | Who |
|---|---|---|
| `/opx.ncpd.status [player]` | heat/stage readout | restricted |
| `/opx.ncpd.report <law> [player]` | charge a player | restricted |
| `/opx.ncpd.heat <stage> [player]` | set heat stage | restricted |
| `/opx.ncpd.av [player]` | call the MaxTac AV | restricted |
| `/opx.ncpd.clear [player]` | wipe the record | restricted |
| `/opx.ncpd.laws` | print the law book | restricted |
| `/opx.ncpd.board [seat]` | take a crew seat on the AV | restricted |

**The dispatch board** is not a command. When a crime raises a wanted stage, the
same call-out the radio carries is shouted on the screens of every on-duty
holder of `ALERTS.JOBS`: one full-stress toast, wrapped in two clips, on one
fixed id so a firefight is one board and not three. Tune it in `config/ncpd.lua`
`ALERTS.DISPATCH` — `KIND`, `DURATION_MS`, the two `STINGER` clip names
(`web/audio/`, bare file names), and `JOBS` to give the board its own air crew
(e.g. MaxTac alone). `enabled = false` darkens the board and leaves the radio
call-out standing.

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
