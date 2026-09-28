# opx_sandy_view

The part of the ripperdoc's Sandevistan that a Lua resource cannot do on its own, shipped to every
player as a preload (`dist/opx_sandy_view.zip`, built from this folder):

- **the base game's Sandevistan screen and clock**: the camera's time-dilation curve
  `Sandevistan`, V exempt from the owner's slowed world, the keyboard's `SlowMotion`;
- **the owner's third-person model** kept as fast as V for the boost, with Smasher's gold eyes;
- **Adam Smasher's ghost trail**: four afterimages of the player's own model, placed every frame
  where the body was 0.08 / 0.16 / 0.24 / 0.32 s before (working since 1.4.7), on the owner's
  model and on every other player's copy of the owner; from 1.4.8 its parts ship in the archive's
  own copy of V's body files, so it needs no ArchiveXL on anyone's game;
- **the owner at full speed on every machine the boost slows**: every other player's copy of the
  boosted body keeps the owner's pace in the slowed world;
- **the real item**: the base game's `Items.AdvancedSandevistanApogee` in the Operating System
  slot (currently refused by the base game, see the doc below).

The full record (design, every build and what it taught, configuration, deploy, testing, known
issues) is **[`docs/sandevistan.md`](../../docs/sandevistan.md)**. The build history is also in the
header of [`open77.lua`](open77.lua) and of the REDscript
[`src/r6/scripts/opx_infinity/OpxSandevistanView.reds`](src/r6/scripts/opx_infinity/OpxSandevistanView.reds).

| Path | What |
|---|---|
| `open77.lua` | manifest (version, preload, the `archivexl` note, exports) |
| `client/main.lua` | `engage` / `release` / `wear` / `info` exports: the owner's clock claim (`open77:opx_sandy_view`) and the real-item message |
| `server/main.lua` | the server side: says the view and the ghost trail ship with this world |
| `src/r6/scripts/opx_infinity/OpxSandevistanView.reds` | the REDscript |
| `src/archive/pc/mod/opx_sandy_ghost.archive` | V's two body files with the ghost trail's parts, and its meshes, material and effect (no `.xl` from 1.4.8) |
| `tools/ghost/` | `build.py`, `merge.py`, `pack.py` and the README that rebuilds and verifies the archive |

**Requirements on the server:** `requiredMods.unsecured = true` (the preload is executable
content). No loader: up to 1.4.7 the ghost trail was an ArchiveXL patch and needed the platform's
`archivexl` resource and ArchiveXL on every player's game. After any change to the `.reds` or the
archive, the server restarts and every player boots the game once more through the launcher (the
required-mod digest changes).
