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
| **Ripperdoc chair (clinic marker)** | `/opx.clinic.add [key] [label]` | key auto-named (`clinic1`…) |
| Chair remove / list | `/opx.clinic.remove <key>` · `/opx.clinic.list` | |

### Ripperdoc chairs

One command, like every other station: stand at the chair, look the way the
patient should face, run **`/opx.clinic.add`** (or `/opx.clinic.add victor
"VICTOR'S CHAIR"` to name it). It saves the chair to the database and prints
the config line to check into `config/ripperdoc.lua` `CHAIRS`:

```lua
  victor = { id = 'victor', NAME = "VICTOR'S CHAIR", X = -1546.96, Y = 1233.77, Z = 11.52, YAW = 0.0 },
```

The chair needs no mesh — the patient is seated on the platform's portable
`chair` workspot. A captured key shadows a config row of the same id (one chair
moved, not two); config rows are edited in `config/ripperdoc.lua` by hand.

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
