# Adam Smasher's ghost trail on the player's own model — how `opx_sandy_ghost.archive` is built

The archive is made from the base game's own files (Cyberpunk 2077 2.31); no
other mod's files are in it. It draws the afterimages with the player's OWN
silhouette (1.4.0 drew twenty parts of Smasher's body instead).

**1.4.8 (this build): no loader.** The sixteen parts and the effect spawner
are no longer an ArchiveXL patch of V's body: the archive carries V's two
body files themselves -- `base\characters\common\player_base_bodies\
appearances\t0_000_base__full.app` and `..._censored.app`, the base game's
own (2.31), every field kept, with the patch's parts appended to each of the
36 appearances (`merge.py`). The game loads a file of `archive/pc/mod` in
place of the base game's by its depot path, with no plugin; the `.xl` is
gone, so a game that does run ArchiveXL does not add the parts twice. Why: in
the first two-player test the second player's game ran no ArchiveXL (RED4ext
loaded one plugin, Open77), and their log said of their own third-person model
"0 of 16 parts (none), its effect spawner MISSING" -- no trail on them, and
none on the boosted player either. Twelve files: the two body files, the
eight meshes, the material and the effect.

**1.4.7:** 1.4.6's next-frame ticker ran twice and stopped (its
log: "2 frames in 0.58 s"), so no afterimage was ever placed; the ticker is
now a 5 ms real-time timer and the watch that lit the body places them too,
every tenth of a second. The archive was 1.4.6's, unchanged.

**1.4.6 draws the afterimages itself.** Every player body gets
FOUR LAYERS of the ghost's parts -- `opx_sandy_ghost1_body` / `_arm_l` /
`_arm_r` / `_head` up to `opx_sandy_ghost4_*`, V's own body, arms and head in
Smasher's look, switched off -- and the REDscript places layer k, every frame,
where the body was k x 0.08 s before (its own placement, relative to the
body; this frame's pose, as Smasher's copies are), shows it once it is 0.35 m
from the body and un-hides it every frame. 1.4.2-1.4.5 left the copies to
Smasher's shader (`customParameter0` from his effect); 1.4.5 lit the parts,
started the effect three times, and the player saw no trail. The effect stays
in the archive (`opx_sandy_ghost_x150`, now on all sixteen parts) but nothing
plays it; the four calibration strengths are gone. Eleven files.

1.4.2, after 1.4.1 switched its four parts on in game and drew
nothing, changes three things, each to what V's own files and every working
copy of this shader outside Smasher's own files do:

* every part is an `entGarmentSkinnedMeshComponent` — V's own body component
  with a new name, mesh and appearance. V's meshes are garment meshes (vertex
  factories `MVF_GarmentMeshSkinned` / `ExtSkinned`, garment data in their
  buffers); 1.4.1 hung them on a plain `entSkinnedMeshComponent` copied from
  Smasher's rig. The ghost appearance is each mesh's FIRST (its default);
* the material's `enableMask` is off (Smasher's own armour material has it on,
  for his destruction masks);
* the effects are the archive's own, with no loop region:
  `opx_sandy_ghost_trail.effect` (fades in over half a second, then holds) and
  `opx_sandy_ghost_hold.effect` (the peak from its first frame) —
  `ch_smasher_sandevistan_high.effect`'s two `customParameter0` tracks, same
  RUIDs, held at his peak (1.5, 1) for 30 s. 1.4.1 started Smasher's own
  looping effect in the same frame the parts came on.

1.4.3 (a test build) found why nothing showed -- Open77's self view keeps the
parts hidden (`TemporaryHide`) -- and the player's screenshots then showed the
trail stretched metres behind the body and broken into fragments. The shader
places its copies by the body's motion times `customParameter0.x`; the working
guess was that the third-person model, exempt from a world slowed to 0.15,
reads several times too fast. 1.4.4 tested it and shipped the trail at five
strengths: `opx_sandy_ghost_x010`, `_x022`, `_x045`, `_x090`, `_x150`, the
held peak (X, 1) with X = 0.1, 0.225, 0.45, 0.9, 1.5 (each 30 s, a fifth of a
second's fade in, no loop). The 1.4.2 `opx_sandy_ghost_trail` / `_hold` and
the 1.4.3 probes are gone.

1.4.4 started at 0.1 and un-hid the parts for their first 0.6 s only; the
player saw no ghost at all. The guess does not hold -- the base game's own
Sandevistan exempts V from the world's slowdown the same way, and ESDE plays
Smasher's full (1.5, 1) on V in single player with this same shader, these
same Smasher armour layers and the same kind of garment parts. 1.4.5 (this
build):

* every strength is HELD FROM ITS FIRST FRAME: the curve is the peak at both
  of its points, (0, peak) and (1, peak), so it reads the same whether the
  engine takes a curve's points as a fraction of the item (CDPR's own
  `ch_smasher_sandevistan_high.effect`: its loop region 0.10-0.15 s is points
  0.4 / 0.6 of 0.25 s) or as seconds (ESDE's 20 s loop is written 0.1 / 19.9 /
  20). 1.4.2-1.4.4 held the peak to point 0.995 and fell to zero at point 1:
  read as seconds, a trail that ends one second after it starts;
* the REDscript plays `opx_sandy_ghost_x150`, Smasher's own (1.5, 1), on the
  owner's third-person model and on every other player's copy alike; it
  starts it at 0.25 s and again at 1 s and 2.5 s (an instance over a running
  one writes the same value), and un-hides the parts every step for two
  seconds, then every second -- Open77 hides every skinned mesh of a body
  while it dresses or parks it and lifts only its own record.

What it holds (`src/archive/pc/mod/`):

| path | what |
|---|---|
| `base\characters\common\player_base_bodies\appearances\t0_000_base__full.app` and `t0_000_base__full_censored.app` | V's own body files (the base game's, every field kept) with, in each of the 36 appearances, four layers of the parts -- `opx_sandy_ghost1_body`, `_arm_l`, `_arm_r`, `_head` ... `opx_sandy_ghost4_*` -- on that appearance's gender (switched off, no shadows, V's own chunk mask on the bodies) and the effect spawner `opx_sandy_ghost_fx` appended after V's own body component |
| `opx\sandy\ghost\v_body_ma.mesh` / `v_body_wa.mesh` | V's own third-person body (`t0_000_pma_base__full.mesh` / `t0_000_pwa_base__full.mesh`: torso, legs, feet -- the arms are a customization group of their own) plus one appearance, `opx_sandy_ghost` (first), every chunk on `opx_sandy_ghost.mi` |
| `opx\sandy\ghost\v_arm_l_ma.mesh`, `v_arm_r_ma.mesh`, `v_arm_l_wa.mesh`, `v_arm_r_wa.mesh` | V's own arms and hands (`a0_000_p?a_base_hq__l/r.mesh`, what `a0_000_base__full.app` puts on every player), the same appearance added |
| `opx\sandy\ghost\v_head_ma.mesh` / `v_head_wa.mesh` | V's base head (`h0_000_p?a_c__basehead.mesh`), the same appearance added, its 244 face-rig bones re-rigged onto `Head` |
| `opx\sandy\ghost\opx_sandy_ghost.mi` | `base\fx\_shaders\sandevistan_multilayer.mt` with Smasher's armour layer set, mask and normal — his own `sandevistan` material, as a file, unmasked |
| `opx\sandy\ghost\opx_sandy_ghost_x150.effect` | Smasher's peak (1.5, 1), held from its first frame to its last (kept; played by nothing in 1.4.6) |

Each mesh's buffers (render data, local materials, garment data) are the base
game's own, byte for byte: only the main part changes (an external material,
its entry, one appearance; for the heads the re-rig). A re-rig renames a bone
the player skeleton lacks AND gives it the new bone's inverse bind matrix and
bind position, so the vertex rides that bone rigidly.

The effect spawner's descriptors: `opx_sandy_ghost_x150` on the archive's own
effect, both `customParameter0` tracks on all sixteen parts (played by nothing
in 1.4.6), and `opx_sandy_ghost_on`, a trigger that drives nothing -- another
client plays it on a boosted player's body, and the REDscript answers it by
lighting that body's afterimages. A spawner inside a part merged into a body receives the effect events
sent to that body, as CDPR's own `fx_thruster_boots` does inside the thruster
boots' garment part (the base game plays `thrusters` on the player).

The shader draws the afterimages BEHIND a body that moves: standing still, a
body covers its own ghost; running, dashing and jumping leave the trail.

## Rebuild

1. Extract the inputs from the game, as raw CR2W (main part + buffers as
   stored): `t0_000_base__full.app`, `t0_000_base__full_censored.app`,
   `boss__adam_smasher_mm.app`, `adam_smasher.ent`, Smasher's armour mesh
   (for his `sandevistan` material) and `ch_smasher_sandevistan_high.effect`,
   V's `t0_000_pma_base__full.mesh`, `t0_000_pwa_base__full.mesh`,
   `h0_000_pma_c__basehead.mesh`, `h0_000_pwa_c__basehead.mesh`, the four
   `a0_000_p?a_base_hq__l/r.mesh`, and the man/woman deformation rigs' bone
   names (`rigs.json`).
2. `WolvenKit.CLI convert serialize` them to JSON (`json/` for Smasher's and
   V's body `.app`, `v/json/` for V's meshes).
3. `python3 build.py` writes the patch, the eight meshes, the material and the
   effect as WolvenKit JSON (`build_v146/json/`); `python3 merge.py` appends
   the patch's parts to each appearance of V's two body files
   (`build_v148/json/`, and checks that the result minus the parts IS the base
   game's file, handles resolved); `WolvenKit.CLI convert deserialize` makes
   them CR2W. The patch itself is not shipped.
4. `python3 pack.py <root> opx_sandy_ghost.archive depot=original ...` (each
   mesh mapped to V's original file; the two body files at their base-game
   depot paths) packs them with EVERY SEGMENT STORED.
   WolvenKit's Linux Kraken encoder writes large streams no decoder reads back
   (its own included), so nothing is compressed: the meshes' buffers are the
   base game's own, byte for byte (checked), and every CRC is recomputed
   (buffer table: crc32 of the stored bytes; CR2W header: crc32 of the
   160-byte header with its crc field set to 0xDEADBEEF; RDAR index:
   CRC-64/XZ from the counts on).
5. (Up to 1.4.7, `opx_sandy_ghost.xl` declared the ArchiveXL patch; 1.4.8 has
   none.)

Checked for 1.4.8: WolvenKit reads all twelve files back from the packed
archive equal to what build.py and merge.py wrote (handles resolved; mesh and
effect paths as their FNV-1a 64 hashes, as a compiled package stores them);
each merged body file minus the appended parts equals the base game's own
(handles resolved), and the parts equal the 1.4.7 patch's, appearance by
appearance; the two depot-path hashes are the ones the installed
`basegame_4_appearance.archive` holds; an independent reader confirms the RDAR
index CRC, every CR2W header and buffer-table CRC, and that each mesh's
buffers equal the base game's. (1.4.6 was checked the same way, with the
patch in place of the two body files.)
