# opx_infinity

The single Open77 resource behind the OPX server: one runtime, one WebUI surface,
one test suite. It replaced twenty-one `opx77_*` resources in September 2026.

Open77 turns Cyberpunk 2077 into a server-driven multiplayer platform. Gameplay is
Lua, split across a **dedicated server** and a **game client**, and the two runtimes
are not the same — the differences below are not style, they are the platform, and
most of the surprises in this codebase come from one of them.

---

## Working here

### Branches

**Nothing is pushed to `main` directly.** Branch, push the branch, open a pull
request. `main` is what the test server is expected to be able to run.

```
feat/<thing>     a new capability
fix/<thing>      a defect
audit/<thing>    a sweep across the codebase
```

### Before you push

```bash
lua tests/run.lua                                   # must be green
luac -p $(find . -name '*.lua' -not -name 'open77.lua')
npm run typecheck && npm run build                  # only if ui/ changed
```

`open77.lua` is the manifest DSL, not Lua — `auto_start true` does not parse, so it
is excluded from the syntax check. Every Lua file must be listed in the manifest or
CI fails: a file nobody listed never loads, and nothing else tells you.

`npm run build` writes `web/index.html`, which **is** the shipped bundle. The sources
under `ui/` never leave the repository.

### Commit messages

Say what changed and **why it was wrong before**. A reader six months out needs the
argument, not the diff — they can read the diff. If a change fixes something that was
failing silently, say what the symptom looked like from the game, because that is what
somebody will search for.

---

## Two runtimes, and what only one of them has

| | server | client |
|---|---|---|
| `require` | **no** | yes |
| `load` / `loadfile` / `dofile` | no | no |
| `LoadResourceFile` | own resource only | own resource only |
| instruction budget | none (1,024 task quota) | **per-resume, and an overrun kills the coroutine silently** |

The client budget is the single most expensive thing to forget. A loop without a
`Wait` does not crash, does not log and does not repeat — it stops. `modules/target`
is built in slices for exactly this reason; read its header before writing anything
that walks a list every frame.

The server having no `require` is why `lib/shared/` exists and will keep existing.
See **The library** below.

---

## Layout

```
open77.lua              the manifest. Load order is this file, top to bottom
config/                 operator settings, one file per module
core/                   the runtime: registry, lifecycle, channels, schedulers
lib/shared/             helpers on BOTH runtimes, installed as OPX.*
lib/server/             storage and audit
lib/client/             the opx_lib bridge and the WebUI surface
modules/<id>/           one gameplay concern
  module.lua            the contract: Declare, events, page channels
  shared/  server/  client/
  data/                 catalogues
  locales.lua           EN and FR, and they must stay in step
ui/src/                 the Vue application
  design-system/        tokens, shapes, surface, fonts
  modules/<id>/         one view per module
web/                    the BUILT bundle, and the join screen
tests/                  host.lua (a stub platform) and run.lua
```

### A module

```lua
local M = OPX.Modules.Declare{ id = 'thing', side = 'both', fatal = false }
```

Four optional phases, run in dependency order across every module: `Init`, `Api`,
`Start`, `Stop`. `M.Settings` is `OPX.Config.MODULES[id]`, **captured at Declare
time** — if your config is a `server_script` rather than a `shared_script` it may not
have run yet, so read `OPX.Config.MODULES[id]` in `Init` instead. That exact trap
cost a release.

Modules talk through **contracts**, never by reaching into each other:

```lua
OPX.Api.Provide('thing', 1, { DoIt = ... })
local thing = OPX.Api.Get('thing')          -- nil when it is not running
```

Use `requires` for a hard dependency and `OPX.Api.Get` for a soft one. Two modules
that require each other are refused as a cycle.

### Three event channels

| prefix | reaches | for |
|---|---|---|
| `opx:net:` | across the wire | client ↔ server |
| `opx:on:` | this VM, public | another module listening |
| `opx:in:` | this VM, private | one module's own halves |

`OPX.Event(channel, module, name)` builds the name. **The server is authoritative:**
anything arriving on `opx:net:` is a request from a machine the player owns, and is
re-validated before it is believed.

### The view seam

A module owns state and rules; it does **not** draw. It publishes on one event and
takes everything back through one function:

```lua
TriggerEvent(M.Event.ON_VIEW, { kind = 'panel', ... })   -- out
function M.FromView(action, payload) ... end             -- in
```

A separate file — `client/view.lua` — is the only thing that knows the other end is
a CEF page. `modules/chat/client/view.lua` is the reference. Before writing a new Vue
page, check whether `menu` or `panel` already draws what you need; the wardrobe's
whole fitting room is drawn by `panel` through such a bridge.

### How a player opens one

A bridge that nothing calls draws nothing, so the appearance module declares its own
doors: `KEYS.PANEL` in `config/appearance.lua` — F7 out of the box — toggles the
appearance panel, `/opx.appearance` does the same from chat, and
`/opx.appearance.wardrobe` opens the fitting room directly. The commands are
unrestricted because both act on the caller alone.

The fitting-room command is not a convenience: `WARDROBE.OFFER_POLICY` ships `first`,
which hands the room to a character the game's own creator has just built and to
nobody else — so for a **returning** player the key, the panel's own `outfits →
wardrobe` row and that command are the whole of the way in.

### The garage key: out, and away

`garages` is a **place**, like a dealer and a store: stand on the marker, press its
key — **E** by default and rebindable — and it does one of two things. On foot it
brings one of the character's own vehicles out AT the spot; **sitting in one of them,
the same key puts it away**, filed under the spot the player is standing on, which is
what makes it come out there next time. Which of the two is decided on the SERVER, from
the seat the host reports and the plate the `vehicles` contract holds: a client that
said "I am in my car" would be a client deciding what gets stored. The client's half of
the decision is only which of the two texts the row shows.

**A vehicle that is already out is MOVED to the marker, not answered.** It used to be
answered with the id it already had — `Ok`, "Brought out XX", and an empty spot in
front of the player, because the car was parked on the other side of the map, which is
what a player found and reported by pressing the key six times in one session. The
`vehicles` contract recalls it instead: put away first, which writes its condition
back, then created again on the marker and facing the marker's own heading. It refuses
with `vehicle.occupied` when somebody is sitting in it, because the occupant is not
necessarily the player who asked. A request that names no place — the module's own
spawn event, and the nearby-the-player path — keeps the old answer: moving a car for
"somewhere near me" would be a surprise rather than a service.

It ships with **no spots**: `/opx.garages.add` captures one where the operator is
standing (the heading comes from their client, because a chat line has none) and prints
the line to check into `config/garages.lua`; `/opx.garages.remove`, `/opx.garages.list`
and `/opx.garages.bring <key> [plate]` delete one, list them and take one out from chat.
All four are ACL-gated under `command.opx.garages.*`.

### Buying a vehicle

`dealership` sells what `vehicles` owns. A **dealer is a place**, like a garage spot:
stand on its marker, press its key — **E**, the garages key, rebindable — and the list is
the `menu` module's, drawn one screen at a time. The first screen is the stock of that
dealer's category, grouped by class and priced with the currency table the server
owns; the second is the garage the bought vehicle is filed under, read from the
`garages` contract rather than kept as a copy. With no garages module the second
screen still offers one row — the vehicles module's own default — so a dealership on a
server without garages is a working dealership with one fewer choice.

The two categories are the garages ones, and they decide what may be sold where: a
`garage` dealer sells ground vehicles, an `avpad` dealer sells AVs, and a row whose
record disagrees with the dealer's kind is refused rather than redirected. The rules
are re-derived on the server — the distance across the ground, the routing bucket,
whether THAT dealer sells THAT row, and whether the money is really there — and the
charge goes first, because the vehicles contract can refund and cannot uncreate. A
registration that is refused after payment is refunded in full and the failure is
logged with what was bought; a hand-over that is refused is *not* a failed sale: the
vehicle is owned and filed, and only the convenience of driving it away is reported.

It ships with **no dealers**, exactly as garages ships with no spots: `/opx.dealership.add`
captures one where the operator is standing, under the kind and key it is given (both
optional), and prints the line to check into `config/dealership.lua` so the dealer
survives a database reset. `/opx.dealership.remove` deletes a captured one and refuses
a configured one. `/opx.dealership.list` names every dealer and its origin;
`/opx.dealership.stock` lists what is for sale and which kind sells it; and
`/opx.dealership.buy <key> [garage]` buys from chat, which is what a player uses on a
client whose list could not open. The three placement commands are ACL-gated — they
write a place every player uses — and the two that act on the caller alone are not.

### Getting dressed

`clothing` is a **place**, like a garage spot and a dealer: stand on the marker, press
its key — **E** again, and again a separate mapping — and the **fitting room** opens.
No clothing is reimplemented here. `appearance` already streams this body's whole
catalogue into a room a player may browse, try pieces on and keep
(`Open77.equipment.records`, unrestricted, every slot, batched onto its own thread),
and it owns the puppet, the save and the rules about who is offered the room at all. A
store that drew its own list would be a second catalogue with its own idea of what a
body may wear, so it has none: this module owns the place and the door, and the room
behind the door stays the appearance module's.

That is also why a store carries **no kind and no heading**, and why `/opx.clothing.add`
asks the client for **nothing at all**. The garages and the dealership ask their own
client back for a facing, because a chat line has none and a vehicle needs one; a store
has no facing, so the position — read from the connection running the command, never
off the wire — is the whole of what a capture needs. There is no capture round-trip in
this module, no deadline waiting for its answer and no "did not answer" warning,
because there is nothing to ask.

It ships with **no stores**, exactly as garages and dealerships ship with no spots:
`/opx.clothing.add [key] [label]` captures one where the operator is standing, names a
key back when it is given none, and prints the line to check into `config/clothing.lua`
so the store survives a database reset. `/opx.clothing.remove <key>` deletes a captured
one and refuses a configured one, and `/opx.clothing.list` names every store, its
position, its bucket and its origin. All three are ACL-gated, and they are the only
commands this module has.

**What a player is told when the door will not open.** The room refuses for reasons
that are about the player and not the store — `player_down`, `no_character`,
`appearance_busy` — and those reach the key as the room's own words rather than a
generic failure. On a server running the platform's own `open77_appearance` package the
contract is simply absent, and the key says that out loud instead of doing nothing: the
markers draw and the row posts either way, so silence would be the one answer nobody
could read.

### The wanted level is a crime score, not a fact

`ncpd` owns what a crime is worth, who is charged, and which division answers.
The engine's own wanted level is **an accumulated crime score**, not a value one
can set: `PreventionSystem` keeps the score, raises `EPreventionHeatStage`
(`Heat_0 .. Heat_5`) when it reaches the current stage's capacity, and zeroes it
as it crosses. The `wanted_level` quest fact is written *from* that stage and read
only by a debug overlay — setting the fact moves the bar and nothing else. So the
module drives the ladder rather than the fact, and the sirens, the radio, the
roadblocks, the wanted bar and every response unit stay the game's own.

`config/ncpd.lua` is the law book and needs no code to change: `LAWS` are
`{ id, label, score, ceiling }`, where `ceiling` is the stage at or above which an
offence stops counting; `LADDER` is keyed by the engine's own **heat number**, so
`[0]` is `Heat_0` — not wanted, whose capacity is the score that makes a player
wanted — and each row carries the score that leaves it plus the response the
engine already wires to it; `DISTRICTS` scales a score by district; `DECAY` is how
it falls again. `MAXTAC` is the separate division that arrives at `Heat_5`: the
Zetatech Surveyor and its variants, the troopers, the Merrimac and the ground pair,
the tag the engine gives a MaxTac NPC spawned outside its own system, and the rule
that troopers are **players who opted in, bots for every seat left empty** — so an
empty division is never an empty street.

Every value is validated when the resource loads and a value that cannot be used is
a **named warning, not a raise**: a law with a bad score costs that law and is
called out at boot, where an operator looks. The suite pins the arithmetic, the
vocabulary and eight negative controls; the boot line reads
`[ncpd] ready: 11 law(s), 5 heat stage(s): ncpd 1-4, maxtac 5`.

**What is not here yet, deliberately.** Raising a stage is a platform seam:
`PreventionSystem`'s 287 methods are all scripted, so the client enqueues a command
and its REDscript loop runs it inside the script frame it owns. That queue exists
and carries `prevention.lock`, `prevention.blockfoot` and `prevention.blockvehicle`
today; it does not yet carry a heat or AV command — that is one change in
`open77-base`, and it is what the per-player ledger is waiting on. Until it lands
the law book is the single source of truth for what a crime costs and nothing
charges anybody yet. The reasoning, every record involved and the build order are in
`docs/ncpd-maxtac.md`.

### The grants a staff panel needs

**Opening the panel and using it are two different permissions, and the difference is
one dot.** The host decides a line's permission from the word actually typed —
`command.<word>` — so the opener is `command.opx.admin` and every action behind it is
`command.opx.admin.<action>`. The module registers 56 restricted commands: the opener,
and 55 actions under it (`opx.admin.self.noclip`, `opx.admin.player.goto`,
`opx.admin.vehicle.spawn`, `opx.admin.recovery.money`, …). The matcher keeps the dot
and only a rule ENDING in `.*` is a prefix, so a role holding `command.opx.admin`
alone opens the menu and is then refused by every row inside it — the operator watches
a panel they cannot use, and no log line says why, because a refused command is not an
error the resource ever sees.

**A role for an operator therefore needs both spellings, and the same shape repeats
wherever a module owns a namespace:** `command.opx.admin` *and* `command.opx.admin.*`
to open the panel and use it, `command.opx.garages.*`, `command.opx.dealership.*` and
`command.opx.clothing.*` for the Dev screen's placement commands, and `command.opx.weather.*`,
`command.opx.time` and `command.opx.time.*` for the world controls. Only the `admin`
and `owner` roles the server supplies avoid the question — they are `command.*` and
`*` — which is also why granting a human `admin` on a server that loads a diagnostic
resource hands them `command.client.exec` with it. The file is the server's
`acl.jsonc`, named by `accessControl.file`; `acl.jsonc` is not in this repository, so
the list above is the thing to copy into it.

### The staff panel's spawn list

The staff menu's spawn screen is one folder per class, and **Air is the first of them**:
the six `Vehicle.av_*` records a staff member looks for by name. Which class a record
is in is not written down twice — a row's category is DERIVED from its record by
`VEHICLES.AV_PREFIXES`, the same rule the garages module and the dealership use, so a
record is in the air category for every part of the server or for none of it, and a
row cannot disagree with itself. A spawned AV is lifted clear of the ground by
`VEHICLES.AV_LIFT`, because an AV record's pivot is its chassis centre and the offset
that puts a car's wheels on the road leaves one half-buried; a car is not.

The list itself is `data/vehicles.lua`, indexed in parts because of its size — the
Air class is why there are five parts now — and a row that is malformed (a name or
record declared twice, a class that is not a class) is a boot warning rather than a
spawn that refuses in front of a player.

**A screen change UPDATES the open menu rather than replacing it.** The menu contract
owns both, and they are not the same thing: an update rebuilds the open menu from a
fresh spec and costs one frame, while an open closes the live menu first — a new
handle, a blank surface for the round trip, the configuration re-sent, and the page's
arrival walk re-run for a screen that did not arrive, it replaced one. The handle is
also the capability every intent from the page names, so a click landing inside that
window was dropped and the press had to be repeated. So `draw` updates in place
whenever its own menu is up, and passes a cursor only when the SCREEN changed: a
redraw keeps the player's position, a screen that replaced another gets the landing an
open would have given it.

### Recovery: money to a character

The staff panel has a **Recovery** category, and it is two rows: give yourself eddies,
or give them to a player you pick out of the roster. Both end in one command,
`opx.admin.recovery.money <playerId|me> <TYPE> <amount>`, which is ACL-gated under its
own name — `command.opx.admin.recovery.money` — because an operator trusted to unfreeze
somebody is not automatically an operator trusted to write a balance.

The command **owns no money**. Every call is one call into the `character` contract's
`AddMoney`/`RemoveMoney`, so the balance, the `money:beforeAdd` hook that can veto the
transaction and the audit row all stay in the module that owns them, and the answer
names the balance the character holds *after* the mutation rather than one this file
worked out. `me` is resolved from the connection, never from the line, so the row that
says "give myself" cannot be aimed at anybody else; a lower-case account is upper-cased
rather than refused; an amount is a whole number, may be negative — which takes money
back through the same door — and is capped at ten digits, which is what the amount
field beside it accepts. A refused transaction answers with the contract's own reason
(`not_enough`, `bad_type`, `vetoed`, …) and moves nothing.

The typed line works wherever a chat line does: `/opx.admin.recovery.money me EDDIES
5000` pays the caller, and `/opx.admin.recovery.money 4 BANK 2500` pays player 4.

**The panel asks for a taller window than the menu module's default.** Its root screen
now has ten rows (the Recovery category is its own block) and the module's own window
is nine, which drew the last row only after the operator scrolled — a category nobody
finds. The staff panel therefore names `rows = 12` and `maxHeight = 72` at open, in
`modules/admin/client/menu.lua`'s `draw`, and nothing else in the pack is affected.

### A broadcast announcement, and the two clips around it

The staff panel's **Announce** row sends a sentence to every player, and it is wrapped
by two stingers: one that plays **before the message appears** and one that plays **once
it has gone**. They are `ANNOUNCE.STINGER.OPEN` and `.CLOSE` in `config/admin.lua`,
next to the volume, and they ship in this resource — `ui/public/audio/` in the repo,
`web/audio/` in the pack.

**The announcement is drawn on this runtime's own overlay**, not by the platform's
`open77_notifications` package, and that move is what makes the stingers possible at
all: only the page that owns a toast's clock can hold a message back until the first
clip has finished. `OPX.Notify` hands the sentence to a surface this runtime does not
draw, so it could be told when to appear and never when to wait. The chat line still
goes out on core's own result channel, exactly as before.

**Nothing about the presentation crosses the wire.** The server sends the sentence and
its lifetime; each RECEIVING client reads its own config for the clips. A client with
no clips still gets the message, a client that turned one off by naming `''` gets the
message and one clip, and neither can make an announcement fail to arrive. The
delivery is the same best-effort fan-out the command always had — one client that
cannot be reached does not stop the rest — and the operator is told how many received
it.

**A clip name is a BARE FILE NAME, and that is a boundary rather than tidiness.** The
page resolves a name under its own `audio/` and nothing else is reachable from it, so a
name able to climb out (`../`, a slash, a scheme, a drive) would be a name able to make
every client in the city fetch from wherever a served config pointed. `core/client/
notify.lua` is the one place that decides what a toast may carry and it DROPS a name
that does not fit — the clip, never the message — because a typo in a presentation
setting must not cost a player the sentence an operator sent them. The page repeats the
test, because a page does not trust the wire.

**No stinger is ever load-bearing.** The clip helper answers on `ended`, on a decode
error, on a refused playback and on a deadline, and every one of those answers draws
the message; a page whose message never appeared because a file was missing would be a
worse fault than a silent stinger. The deadline is what stops a longer or a stalling
clip from holding an announcement hostage.

The two clips that ship are MP3, which is worth stating because this runtime's other
media path is `.webm` (VP9 + Opus) — an MP4 never plays in this CEF at all. MP3 is in
the free codec set this build carries, and it is **checked against the deployed
binary** rather than assumed: `Open77.WebHost.exe --open77-self-test-probe=<out>
--open77-self-test-url=<page>` loads a page in the shipping CEF and reports the PCM it
received, and the run that chose this format reported `packets 335, frames 343040,
peak 0.66` with no user gesture anywhere — so the clips play, and they play without a
click.

The order itself is proven in a browser rather than argued: `ui/harness/
notify-stinger.html` mounts the real page on a fake bridge and a stubbed decoder and
asserts the sequence — the message is not in the document while the opening clip plays,
it appears when that clip ends, it goes when its lifetime ends, and only then does the
closing clip start, with a refused playback still drawing the message.

---

## The library

**`opx_lib` is a separate resource**, declared as a dependency, and reached as
`OPX.Lib` (see `lib/client/lib.lua`). It is **client-only**, and that is not a
choice: the dedicated-server sandbox has no `require`, no `load` and no `loadfile`,
and `LoadResourceFile` refuses a cross-resource read. There is no mechanism by which
a server VM could load a library at all.

So:

- **client code** may use `OPX.Lib.Input`, `.Rpc`, `.World`, `.Zone`, `.Notify`, …
- **server and shared code** use `OPX.Result`, `OPX.Math`, `OPX.Text`, … from
  `lib/shared/`, which is installed into `OPX` by `shared_script`.

New client capability belongs in `opx_lib` by default. `lib/client/` is effectively
closed.

A permission is checked against the **calling** resource's manifest, so `opx_lib`
declares none and could not usefully declare any; `OPX.Lib.Manifest()` prints the
line a consumer needs.

---

## The UI

**Read `ui/README.md` first — it is binding.** augmented-ui is the foundation, not a
decoration, and the contract there explains the parts that will otherwise waste your
afternoon (a cut is required before a border renders; a clip shears an outset
box-shadow; augment containers, not cells).

One page, two layers: `overlay` is a HUD and never takes focus, `modal` does.
`open77_pause` owns Escape — never bind it.

**Hard-code no colour.** The server's theme (`config/theme.lua`) reaches a page by
writing CSS custom properties onto `:root` at runtime. A literal `#ff3b47` is a
surface the operator cannot recolour. The join screen (`web/loading.html`) is the one
exception and it is documented in place: it runs before the bundle exists, so it
carries a labelled hand copy of the tokens.

---

## Tests

`tests/run.lua` boots the real manifest against a stub platform in `tests/host.lua`
and asserts behaviour, not implementation. It runs in desktop Lua 5.4 with no game
and no database.

It also enforces things a reviewer would otherwise have to remember: that nothing
shipped reaches a global the sandbox removes, that nothing the **server** loads
reaches a client-only global such as `require`, that no module hangs its internals
off `OPX`, and that the manifest and the tree agree.

Some checks read the **source** rather than call the code. That is deliberate and
used sparingly — for a rule whose two halves are file-local and unreachable from the
harness. When you write one, make it fail on purpose once before you trust it.

---

## Deploying

Over SSH to the test server, then restart, then read the journal back — in the same
change, not later. A green suite says nothing about the running server.

```bash
git archive --format=tar HEAD open77.lua config core lib locales modules web \
  | gzip | ssh root@<host> 'cd /opt/open77-server/resources/opx_infinity && tar xzf - \
  && chown -R open77:open77 . && systemctl restart open77.service'
```

Archive from the **commit**, not the working tree, so what is deployed is what is
recorded. `opx_lib` must be installed and listed in the server's `resources.load`
before `opx_infinity`, or the platform refuses to start this resource.

Never `DROP DATABASE` — the grants live with it and the server authenticates as a
non-root user. Empty tables instead, and `mysqldump` first.

---

## Conventions

Comments carry the **argument**, not a restatement of the code. `-- @author dop42`
on a file header and on a public function. Tabs in Lua, two spaces elsewhere; see
`.editorconfig`.

Prefer a refusal with a named, branchable code over a silent fallback, and prefer
answering a value over raising. Most of this codebase answers `Result` — `{ ok,
value }` or `{ ok, error, detail }` — because a function that legitimately answers
`nil` cannot use Lua's `value, reason` convention without ambiguity.

Never guess a native. Open77's API is not in anybody's training data: look it up with
the devkit MCP, and if it does not return it for the build you target, it does not
exist. The devkit lags the live server, so a miss is "unverified", not "absent" —
say which.
