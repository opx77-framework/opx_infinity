# Upgrade notes — what has to move with the resource

Short notes for whoever updates a running world: what this resource now needs
from outside itself, why, and what a mismatch looks like. Newest first.

---

## opx_lib 0.2.0 → 0.4.0 — required from 2026-09-25

**Update the `opx_lib` resource to 0.4.0 in the same breath as this resource.**
`opx_infinity` declares `dependency "opx_lib"` and imports it once, with
`require('@opx_lib')`; from the 2026-09-25 merge the pair that works is
`opx_infinity` with `opx_lib` **0.4.0**, and the test suite refuses to call
anything else green. The library and this resource are one dependency in two
directories.

### Which version is installed

The library's manifest carries the version, and it is the number to trust:

```sh
grep -m1 '^version' resources/opx_lib/open77.lua     # want: version "0.4.0"
```

From inside a client session, `OPX.Lib.VERSION` answers the same number —
0.4.0 is the release that tied the logged version, the manifest and this
field to one source (`boot: the logged version was stale, and nothing held it
to the others`), so all three agree from here on.

The suite pins it outright in `tests/run.lua` (`LIB_VERSION = '0.4.0'`) and
its failure names the checkout that answered:

```
FAIL and it is the version this suite was written against
  -- ../opx_lib answered 0.2.0, wanted 0.4.0 -- set OPX_LIB_PATH at the right checkout
```

### Why the requirement moved

0.2.0 → 0.4.0 is almost entirely additions and fixes; **nothing was removed**,
so a library at 0.2.0 still imports and still answers. That is exactly what
makes the mismatch dangerous — see the symptoms below. What the releases
brought:

| Release work | What it is | Why this resource cares |
|---|---|---|
| `native: the platform was raw-read, so a host with a metatable answered nothing` | `Lib.Native.Reach`/`Call` resolved the live `Open77` table through raw reads | This resource probes the platform through those wrappers in 13 places — the wardrobe's `camera.orbit` preview and the admin tags' `players.nearby` sweep among them. On 0.2.0 a host that arrives carrying a metatable answers **nothing** to a probe, and the feature takes its fallback as if the platform lacked the native. |
| `validate: getmetatable is not in the Open77 client sandbox` (+ `pure/class`) | The pure helpers stopped reaching for a global the client sandbox does not provide | Anything validating in a client VM on 0.2.0 raises `attempt to call a nil value (global 'getmetatable')` instead of answering a refusal. |
| `camera and screen: the view is something you have to give back` | New `client/camera.lua` and `client/screen.lua` | The view helpers this resource's next work leans on. Not called today (the surface in use is `Input`, `Native`, `Rpc`, `Store`, `Players`) — but the suite is written against the 0.4.0 surface, and the drift it is there to catch is the drift these modules sit in the middle of. |
| `marker: the whole documented surface, and whether the thing drew` | `client/marker.lua` grows the full documented wrapper | Same: new surface, same contract. |
| `boot: the logged version was stale…` | `Lib.VERSION`, the logged line and the manifest held to one number | The version check above is only trustworthy from here. |

### What a mismatch looks like

**The boot is green.** `require('@opx_lib')` answers a table on 0.2.0, the
manifest dependency is satisfied, every module starts — and the differences
bite later, quietly:

- a `Lib.Native` probe against a metatable-bearing host answers nothing, so
  the wardrobe camera preview and the other probed features read as absent
  and take their fallback as if the platform lacked the native — no error,
  no line naming the library;
- a pure-helper validation in the client VM raises far from the cause;
- the suite fails the one check quoted above. That check exists because of
  the alternative: without the pin, a wrong checkout fails **21 checks
  scattered through the rest of the file**, not one of which mentions the
  library. When the failures make no sense, look at the library version
  first.

### One dependency, two resources

The wiring is a manifest line and an import:

- `open77.lua` declares `dependency "opx_lib"`, so the platform starts the
  library first. Without the line, `require('@opx_lib')` answers
  `module_dependency_not_declared`; with the library not running it answers
  `module_dependency_not_running`. The library is `auto_start` for this
  reason — a lazily-started library fails at the first call of every session.
- The library declares **no permissions**: its wrappers are charged to the
  importing resource, so the permissions live in *this* manifest (each wrapper
  carries a `NEEDS` field, and `OPX.Lib.Manifest()` answers the lines to
  paste). A permission missing there surfaces as `permission_denied:<name>`
  at call time, mid-gameplay.

Ship the pair together: replace `resources/opx_lib` with 0.4.0 in the same
deployment as `resources/opx_infinity`, and restart once. A world that
updates one directory and not the other is the state this note exists to
prevent, and nothing at boot will say a word about it.

### The checkout a developer (and CI) runs against

The suite loads the **real** library, never a stub — a stub would pass while
the two repositories drifted apart, which is the only drift worth a test. It
resolves `@opx_lib` against a sibling checkout at `../opx_lib` by default,
which is how the two repositories sit on a working machine; `OPX_LIB_PATH`
overrides the location, and CI uses exactly that (the runner clones
`opx77-framework/opx_lib` INTO the workspace — `actions/checkout` refuses a
path outside it — and points `OPX_LIB_PATH` at it). A stale sibling checkout
is therefore not a suite bug: it is the version check doing its job. Pull the
library and re-run.
