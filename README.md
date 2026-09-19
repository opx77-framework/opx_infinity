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
