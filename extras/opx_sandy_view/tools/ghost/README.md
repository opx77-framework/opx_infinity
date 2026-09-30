# Adam Smasher's ghost trail on the player's own model — how `opx_sandy_ghost.archive` is built

The archive is made from the base game's own files (Cyberpunk 2077 2.31); no
other mod's files are in it. It draws the afterimages with the player's OWN
silhouette (1.4.0 drew twenty parts of Smasher's body instead).

**1.4.12 (this build): the legs.** A female V's afterimages ended at
mid-thigh (reported 2026-09-28). Her body component in V's body files keeps
chunks 5-7 of `t0_000_pwa_base__full.mesh` hidden (chunk mask
`0xFFFFFFFFFFFFFF1F`): the knees, the calves and the feet, which the base game
draws from a part of their own, `l0_000_pwa_base__cs_flat`
(`l0_000_base__cs_flat.app`, the variant chosen by the footwear). Up to 1.4.11
`build.py` gave every afterimage's body part V's own mask, and the ghost has
no such part -- so the trail had no legs. The body mesh's own chunks 5-7 are
those same legs: 260, 396 and 848 vertices, the flat part's three chunks,
and within 2.6 cm of them (its garment vertices compared point by point), on
vertex factories the ghost's material template lists
(`MVF_GarmentMeshSkinned` / `ExtSkinned`). So every body part now shows every
chunk, as a male V's always did (his body component shows all of them).
`merge.py` checks it for every part of every appearance. Only the two body
files change, and in them only those masks: 216 parts per file (18 female
appearances x 12 layers); V's own female body component keeps its mask.

**1.4.10: the afterimages' arms and hands.** V's arm meshes
(`a0_000_p?a_base_hq__l/r.mesh`) keep their own materials as
`preloadLocalMaterialInstances` (with `forceLoadAllAppearances`), and a mesh in
that mode reads an external material from `preloadExternalMaterials`. Up to
1.4.9 `build.py` wrote the ghost's material to `externalMaterials` on every
mesh -- which V's body and head (plain `localMaterialBuffer`s) read, and the
arms do not -- so the arms' `opx_sandy_ghost` appearance named a material
entry with nothing behind it, and every afterimage had its body and head and
no arms or hands (reported 2026-09-28). `ghost_mesh` now puts the material in
the list the mesh reads. The four arm meshes are the only files that change,
and in them only that list: WolvenKit reads 1.4.9's and 1.4.10's arm meshes
back identical but for `externalMaterials` (now empty) and
`preloadExternalMaterials` (now the ghost's material).

**1.4.9: twelve layers -- Adam Smasher's trail, more aggressive,
with way more clones.** Every appearance of V's two body files now carries 48
parts and the spawner: `opx_sandy_ghost1_body` / `_arm_l` / `_arm_r` / `_head`
up to `opx_sandy_ghost12_*`, which the REDscript places 0.045 s apart (the
farthest where the body was 0.54 s before) and shows once 0.2 m from the body.
The layer count is one number, `LAYERS = 12`, in `build.py` and in `merge.py`
(which checks it against build.py's manifest). Layers 5-12 are exact copies of
the first four's components -- the same meshes, material, flags, bindings,
chunk masks and appearance -- with their own names and fresh ids and cruid
entries; layers 1-4, the spawner and its descriptors keep 1.4.8's ids (the
same draws in the same order), and the spawner's two descriptors name all 48
parts (`opx_sandy_ghost_x150`'s component mask: 48 bits). The eight meshes,
the material and the effect are 1.4.8's, byte for byte. Twelve files, as in
1.4.8.

**1.4.8: no loader.** The sixteen parts and the effect spawner
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
| `base\characters\common\player_base_bodies\appearances\t0_000_base__full.app` and `t0_000_base__full_censored.app` | V's own body files (the base game's, every field kept) with, in each of the 36 appearances, twelve layers of the parts (four up to 1.4.8) -- `opx_sandy_ghost1_body`, `_arm_l`, `_arm_r`, `_head` ... `opx_sandy_ghost12_*`, 48 parts -- on that appearance's gender (switched off, no shadows, every chunk shown -- V's own chunk mask on the bodies up to 1.4.11, which left a female V's afterimages without legs) and the effect spawner `opx_sandy_ghost_fx` appended after V's own body component |
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
effect, both `customParameter0` tracks on every part (48 from 1.4.9; played by
nothing since 1.4.6), and `opx_sandy_ghost_on`, a trigger that drives nothing -- another
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
3. `python3 build.py` writes the patch (`LAYERS` layers of the parts: 12), the
   eight meshes, the material and the effect as WolvenKit JSON
   (`build_v146/json/`, and `build_v146/manifest.json`); `python3 merge.py` appends
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

Checked for 1.4.12 (archive 5,849,088 bytes, 12 files, 246 segments, all
stored; md5 `a4a27a2f1c3009f609429ffb6260f82b`): the independent reader
(`tools/unpack.py`) confirms the RDAR index CRC and every CR2W header,
buffer-table and buffer CRC; ten of the twelve files are byte for byte 1.4.10's
(the eight meshes, the material, the effect); WolvenKit reads the two body
files back equal to what `merge.py` wrote (handles resolved), and those equal
1.4.10's in every field but 432 `chunkMask` values per file (18 female
appearances x 12 body parts, in the compiled package and the components list),
`0xFFFFFFFFFFFFFF1F` -> `0x7FFFFFFFFFFFFFFF`. In the read-back, every ghost
body part of both genders shows every chunk, and V's own female body
component still hides chunks 5-7. The compiled package stores a mask equal to
the default not at all, so each female appearance's buffer is 192 bytes (12 x
16) shorter.

Checked for 1.4.10 (archive 5,853,184 bytes, 12 files, 246 segments, all
stored; md5 `7ce92a40b60add236f09735b112945d7`): an independent reader
confirms the RDAR index CRC and every CR2W header, buffer-table and buffer CRC;
of the twelve files, eight are byte for byte 1.4.9's (both body files, the
body and head meshes, the material, the effect) and the four arm meshes
differ; WolvenKit reads each arm mesh back equal to what build.py wrote
(handles resolved), and equal to 1.4.9's in every field but
`externalMaterials` (empty) and `preloadExternalMaterials` (the ghost's
material); each arm mesh's buffers are still the base game's (21 / 21 and
16 / 16 read back equal); in all four the ghost appearance's chunks name the
entry `opx_sandy_ghost` (not a local instance, index 0), and every appearance
has the same chunk count (4 left, 3 right).

Checked for 1.4.9 (archive 5,853,184 bytes, 12 files, 246 segments, all
stored; md5 `74e6d9f664ba6126c9ec1ef90532e082`): an independent reader confirms
the RDAR index CRC and every CR2W header, buffer-table and buffer CRC;
WolvenKit reads all twelve files back equal to what build.py and merge.py
wrote (handles resolved; paths as their FNV-1a 64 hashes); each merged body
file minus the appended parts equals the base game's own (handles resolved);
every one of the 36 appearances of both files carries the 48 parts in order
(`opx_sandy_ghost1_*` .. `opx_sandy_ghost12_*`) and the spawner, with unique
component ids (the base game's own included) and a cruid entry for each;
layers 1-4 equal 1.4.8's parts field for field, ids included; every part of
layers 5-12 equals the same kind of part of layer 1 in every field but its
name and id (the mesh on that appearance's gender, the appearance, flags,
bindings, chunk mask); the spawner equals 1.4.8's but for the 48 part names
and x150's 48-bit mask; the eight meshes, the material and the effect are
byte for byte 1.4.8's (so their buffers are still the base game's), and the
archive's twelve path hashes are 1.4.8's.

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
