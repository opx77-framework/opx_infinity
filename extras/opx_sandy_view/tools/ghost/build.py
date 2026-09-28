"""Builds opx_sandy_view's ghost-trail package (1.4.6): the AFTERIMAGES OF THE
PLAYER'S OWN MODEL, in Adam Smasher's Sandevistan look.

1.4.6: FOUR LAYERS of the ghost's parts -- `opx_sandy_ghost1_body` / `_arm_l`
/ `_arm_r` / `_head` up to `opx_sandy_ghost4_*`, sixteen parts on V's own
meshes -- which the REDscript places, every frame, where the body was 0.08,
0.16, 0.24 and 0.32 s before: four afterimages along the path it really ran.
1.4.5 lit the one layer at the body and started Smasher's effect on it three
times, and the player saw no trail: the shader's own copies (placed by the
motion the renderer records for a part) do not show on this body, so the
copies are no longer left to the shader. Each layer is drawn by the
material's first pass -- the part itself -- which 1.4.3 showed on screen. The
effect stays in the package (`opx_sandy_ghost_x150`, now on all sixteen
parts) but nothing plays it; the four weaker strengths are gone.

1.4.5: every effect is its strength HELD FROM ITS FIRST FRAME -- a curve that is
the peak at both of its points, (0, peak) and (1, peak), so it reads the same
whether the engine takes a curve's points as a fraction of the item (CDPR's
own `ch_smasher_sandevistan_high.effect`: points 0.4 / 0.6 of 0.25 s are its
loop region, 0.10-0.15 s) or as seconds (ESDE's 20 s loop is written 0.1 /
19.9 / 20). 1.4.2-1.4.4 held the peak to point 0.995 and fell to zero at point
1: read as seconds, that is a trail that ends one second after it starts. With
no fade the REDscript can also start the effect again over a running one
without a dip (both write the same value).

1.4.4: 1.4.3's test showed the parts DRAW once un-hidden, and the trail
stretched metres behind the body and broke into fragments. The shader places
its copies by the body's motion times `customParameter0.x`; the working guess
is that a body exempt from a world slowed to 0.15 reads several times too
fast, and 1.4.4 is the test of it: the effects are five strengths of the same
held peak -- `opx_sandy_ghost_x010`, `_x022`, `_x045`, `_x090`, `_x150`
(`customParameter0` = (X, 1)) -- one of which the REDscript starts on a lit
ghost.

1.4.2, after a test in game showed nothing (1.4.1: the four parts were found and
switched on, and still nothing was drawn): every part is now what V's own body
part is -- an `entGarmentSkinnedMeshComponent`, V's own component with a new
name, mesh and appearance (V's meshes are garment meshes; 1.4.1 hung them on a
plain `entSkinnedMeshComponent` copied from Smasher's rig); the ghost appearance
is each mesh's FIRST (its default); the material's `enableMask` is off, as in
every working copy of this material outside Smasher's own files; and the
effects are this package's own -- `opx_sandy_ghost_trail.effect` (fades in,
then holds) and `opx_sandy_ghost_hold.effect` (the peak from its first frame),
Smasher's `ch_smasher_sandevistan_high.effect` with its two `customParameter0`
tracks held at his peak (1.5, 1) for 30 s and no loop region, so nothing
depends on a loop the spawner may not keep.

Adam Smasher's afterimages are his own meshes drawn with the base game's
`base\\fx\\_shaders\\sandevistan_multilayer.mt` (each of his meshes'
`sandevistan` appearance), switched on by `ch_smasher_sandevistan_*.effect`'s
`customParameter0` tracks. Here the SAME shader and the SAME effects draw V's
own body and head, so the ghosts that trail a boosted player are that player's
silhouette -- not Smasher's armour.

  * `v_body_ma.mesh` / `v_body_wa.mesh`: V's own third-person body
    (`t0_000_pma_base__full.mesh` / `t0_000_pwa_base__full.mesh`: torso, legs,
    feet -- the arms are a group of their own), plus one appearance,
    `opx_sandy_ghost`, whose every chunk wears `opx_sandy_ghost.mi`;
  * `v_arm_l_ma.mesh`, `v_arm_r_ma.mesh`, `v_arm_l_wa.mesh`, `v_arm_r_wa.mesh`:
    V's own arms and hands (`a0_000_p?a_base_hq__l/r.mesh`, what
    `a0_000_base__full.app` puts on every player), the same appearance added;
  * `v_head_ma.mesh` / `v_head_wa.mesh`: V's base head
    (`h0_000_p?a_c__basehead.mesh`), the same appearance added, and its 244
    face-rig bones (which the body's skeleton does not have) re-rigged onto
    `Head` -- the name AND that bone's inverse bind matrix and bind position,
    so each vertex rides the head rigidly;
  * `opx_sandy_ghost.mi`: `sandevistan_multilayer.mt` with Smasher's armour
    layer set, mask and normal (his own `sandevistan` material, as a file);
  * `opx_sandy_ghost_x150.effect`: Smasher's peak (1.5, 1), held (kept, not
    played in 1.4.6);
  * `opx_sandy_ghost_patch.app`: ArchiveXL patch of V's `t0_000_base__full.app`
    and its censored cut -- in every appearance (36) the sixteen parts
    `opx_sandy_ghost1_body`, `_arm_l`, `_arm_r`, `_head` ... `opx_sandy_ghost4_*`
    (four layers of V's body, arms and head) on that appearance's gender
    (switched OFF, no shadows), and the effect spawner `opx_sandy_ghost_fx` (a
    spawner inside a customization part, as CDPR's own `fx_mantis` is inside
    the player's Mantis Blades arms): `opx_sandy_ghost_x150` on this package's
    effect, both material tracks on every part, and the trigger
    `opx_sandy_ghost_on`, which drives nothing.

The meshes' buffers (render data, local materials, garment data) stay the base
game's, byte for byte: only each file's main part changes (pack.py checks it).
Nothing here comes from another mod.

Output: build_v/json/opx/sandy/ghost/*.json (WolvenKit JSON), then
`WolvenKit.CLI convert deserialize` and pack.py.
"""
import copy
import json
import os
import random
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'json')          # Smasher's app/ent, V's body .app (serialized earlier)
VSRC = os.path.join(HERE, 'v', 'json')     # V's own meshes, serialized
OUT = os.path.join(HERE, 'build_v146', 'json', 'opx', 'sandy', 'ghost')
RIGS = '/mnt/user-data/uploads/_opx_infinity/.open77-scratch/ghostbuild/flat/rigs.json'

GHOST_DIR = 'opx\\sandy\\ghost'
PATCH_NAME = 'opx_sandy_ghost_patch.app'
MATERIAL = GHOST_DIR + '\\opx_sandy_ghost.mi'
LOOK = 'opx_sandy_ghost'

rng = random.Random(0x5A4E)  # deterministic ids: a rebuild of the same input is byte-identical


def cname(value):
    return {'$type': 'CName', '$storage': 'string', '$value': value}


def depot(path, flags='Default'):
    return {'DepotPath': {'$type': 'ResourcePath', '$storage': 'string', '$value': path}, 'Flags': flags}


def cruid():
    return str(rng.getrandbits(62) | (1 << 61))


def load(folder, name):
    with open(os.path.join(folder, name)) as f:
        return json.load(f)


def save(obj, name):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), 'w') as f:
        json.dump(obj, f, indent=1)


rigs = json.load(open(RIGS))
player_bones = set(rigs['man']) & set(rigs['woman'])
assert set(rigs['man']) == set(rigs['woman'])

# ── the material: Smasher's own `sandevistan` material, as a file ───────────
armor = load(SRC, 'smasher_armor.mesh.json')
armor_rc = armor['Data']['RootChunk']
armor_entry = [e for e in armor_rc['materialEntries'] if e['name']['$value'] == 'sandevistan']
assert len(armor_entry) == 1 and armor_entry[0]['isLocalInstance'] == 1
material = copy.deepcopy(armor_rc['localMaterialBuffer']['materials'][armor_entry[0]['index']])
assert material['$type'] == 'CMaterialInstance'
assert material['baseMaterial']['DepotPath']['$value'] == 'base\\fx\\_shaders\\sandevistan_multilayer.mt'
material['cookingPlatform'] = 'PLATFORM_PC'
material['enableMask'] = 0
header = dict(armor['Header'], ArchiveFileName='', ExportedDateTime='2026-09-27T00:00:00Z')
save({'Header': header, 'Data': {'Version': armor['Data']['Version'], 'BuildVersion': armor['Data']['BuildVersion'],
                                 'RootChunk': material, 'EmbeddedFiles': []}}, 'opx_sandy_ghost.mi.json')


# ── the effects: Smasher's own, held at his peak ────────────────────────────
#
# `ch_smasher_sandevistan_high.effect` is two `customParameter0` tracks
# (0 -> (1.5, 1) -> 0 over 0.25 s) and a loop region at the peak (0.10-0.15 s)
# that holds it until the loop is broken. Here the same two tracks, with the
# same RUIDs (the descriptor's component masks are keyed on them), hold the
# peak for 30 s and there is no loop region at all: nothing depends on a loop.
#
#   * `opx_sandy_ghost_trail.effect` fades in (0 -> peak over the first 1.5 %
#     of 30 s, about half a second) and holds: the one a boost starts;
#   * `opx_sandy_ghost_hold.effect` is the peak from its first frame: started
#     over it a moment later, a second instance that binds the parts again in
#     case the first started before they were drawn -- both write the same
#     value, so the two never fight.
smasher_fx = load(SRC, 'ch_smasher_sandevistan_high.effect.json')
TRAIL_SECONDS = 30.0
PEAK = {'$type': 'Vector4', 'W': 0, 'X': 1.5, 'Y': 1, 'Z': 0}
ZERO = {'$type': 'Vector4', 'W': 0, 'X': 0, 'Y': 0, 'Z': 0}


def held_effect(points, samples):
    fx = copy.deepcopy(smasher_fx)
    rc = fx['Data']['RootChunk']
    assert rc['$type'] == 'worldEffect' and len(rc['effectLoops']) == 1
    kept, dropped = [], set()
    for event in rc['events']:
        data = event['Data']
        if data['$type'] == 'effectTrackItemLoopMarker':
            dropped.add(event['HandleId'])
            continue
        assert data['$type'] == 'effectTrackItemMaterialParameter', data['$type']
        data['timeBegin'] = 0
        data['timeDuration'] = TRAIL_SECONDS
        evaluator = data['customParameter0']['evaluator']['Data']
        curve = evaluator['curves']
        peak = [e['Value'] for e in curve['Elements'] if e['Value']['X'] > 1.4]
        assert peak and abs(peak[0]['X'] - 1.5) < 1e-6 and abs(peak[0]['Y'] - 1) < 1e-6
        curve['Elements'] = [{'Point': at, 'Value': dict(value)} for at, value in points]
        evaluator['numberOfCurveSamples'] = samples
        kept.append(event)
    assert len(kept) == 2 and len(dropped) == 1
    rc['events'] = kept
    rc['effectLoops'] = []
    rc['length'] = TRAIL_SECONDS
    tracks = rc['trackRoot']['Data']['tracks']
    rc['trackRoot']['Data']['tracks'] = [t for t in tracks
                                         if not any(i.get('HandleRefId') in dropped for i in t['Data']['items'])]
    assert len(rc['trackRoot']['Data']['tracks']) == 2
    ruids = sorted(e['Data']['ruid'] for e in kept)
    assert ruids == ['4107658665465827328', '4115960124918923264'], ruids
    fx['Header'] = dict(fx['Header'], ArchiveFileName='', ExportedDateTime='2026-09-27T00:00:00Z')
    return fx


# Five strengths, each (X, 1) held for 30 s from the first frame: the curve is
# the peak at both of its points, so no reading of its time axis can take the
# value anywhere else. The REDscript plays `_x150`, Smasher's own peak (1.5, 1)
# -- the value his `ch_smasher_sandevistan_high.effect` reaches and the value
# ESDE plays on V's own body in single player; the others stay for tuning.
STRENGTHS = [('x150', 1.50)]
for tag, x in STRENGTHS:
    peak = {'$type': 'Vector4', 'W': 0, 'X': x, 'Y': 1, 'Z': 0}
    save(held_effect([(0, peak), (1, peak)], 16), 'opx_sandy_ghost_%s.effect.json' % tag)


# ── V's own meshes, with the ghost's appearance added ────────────────────────

def max_handle(obj):
    text = json.dumps(obj)
    return max(int(x) for x in re.findall(r'"HandleId": "(\d+)"', text))


def ghost_mesh(src_name, dst_name, rerig_head):
    mesh = load(VSRC, src_name)
    rc = mesh['Data']['RootChunk']
    names = [b['$value'] for b in rc['boneNames']]
    moved = 0
    if rerig_head:
        head = names.index('Head')
        mats = rc['boneRigMatrices']
        positions = rc['renderResourceBlob']['Data']['header']['bonePositions']
        eps = rc['boneVertexEpsilons']
        assert len(mats) == len(names) == len(positions) == len(eps)
        for i, n in enumerate(names):
            if n in player_bones:
                continue
            rc['boneNames'][i] = cname('Head')
            mats[i] = copy.deepcopy(mats[head])
            positions[i] = copy.deepcopy(positions[head])
            eps[i] = eps[head]
            moved += 1
    missing = [b['$value'] for b in rc['boneNames'] if b['$value'] not in player_bones]
    assert not missing, (dst_name, missing)
    chunks = {len(a['Data']['chunkMaterials']) for a in rc['appearances']}
    assert len(chunks) == 1, chunks
    count = chunks.pop()
    assert count == len(rc['renderResourceBlob']['Data']['header']['renderChunkInfos'])
    assert rc['externalMaterials'] == [] and rc['preloadExternalMaterials'] == []
    assert LOOK not in [e['name']['$value'] for e in rc['materialEntries']]
    rc['externalMaterials'] = [depot(MATERIAL)]
    rc['materialEntries'].append({'$type': 'CMeshMaterialEntry', 'index': 0, 'isLocalInstance': 0, 'name': cname(LOOK)})
    # FIRST: the mesh's default appearance is the ghost's.
    rc['appearances'].insert(0, {'HandleId': str(max_handle(mesh) + 1), 'Data': {
        '$type': 'meshMeshAppearance', 'chunkMaterials': [cname(LOOK) for _ in range(count)],
        'name': cname(LOOK), 'tags': []}})
    mesh['Header']['ArchiveFileName'] = ''
    save(mesh, dst_name + '.json')
    return {'chunks': count, 'bones': len(names), 'rerigged': moved}


MESHES = {
    'v_body_ma.mesh': ghost_mesh('t0_000_pma_base__full.mesh.json', 'v_body_ma.mesh', False),
    'v_body_wa.mesh': ghost_mesh('t0_000_pwa_base__full.mesh.json', 'v_body_wa.mesh', False),
    'v_head_ma.mesh': ghost_mesh('h0_000_pma_c__basehead.mesh.json', 'v_head_ma.mesh', True),
    'v_head_wa.mesh': ghost_mesh('h0_000_pwa_c__basehead.mesh.json', 'v_head_wa.mesh', True),
    'v_arm_l_ma.mesh': ghost_mesh('a0_000_pma_base_hq__l.mesh.json', 'v_arm_l_ma.mesh', False),
    'v_arm_r_ma.mesh': ghost_mesh('a0_000_pma_base_hq__r.mesh.json', 'v_arm_r_ma.mesh', False),
    'v_arm_l_wa.mesh': ghost_mesh('a0_000_pwa_base_hq__l.mesh.json', 'v_arm_l_wa.mesh', False),
    'v_arm_r_wa.mesh': ghost_mesh('a0_000_pwa_base_hq__r.mesh.json', 'v_arm_r_wa.mesh', False),
}

# ── the patch ────────────────────────────────────────────────────────────────

# V's own body component carries the chunk mask of its gender (the female body
# keeps chunks 5-7 off in both cuts); the ghost keeps the same silhouette.
body_app = load(SRC, 't0_000_base__full.app.json')
V_MASK = {}
for a in body_app['Data']['RootChunk']['appearances']:
    for c in a['Data']['compiledData']['Data']['Chunks']:
        if c.get('name', {}).get('$value') == 't0_000_pma_base__full':
            V_MASK.setdefault('ma', c['chunkMask'])
        if c.get('name', {}).get('$value') == 't0_000_pwa_base__full':
            V_MASK.setdefault('wa', c['chunkMask'])
assert set(V_MASK) == {'ma', 'wa'}, V_MASK
ALL_CHUNKS = str((1 << 63) - 1)

# Four layers of the same four parts: layer k is `opx_sandy_ghost<k>_body`,
# `_arm_l`, `_arm_r`, `_head` (k = 1..4), every layer on the same meshes.
LAYERS = 4
PART_KINDS = ['body', 'arm_l', 'arm_r', 'head']
PARTS = ['opx_sandy_ghost%d_%s' % (layer, kind) for layer in range(1, LAYERS + 1) for kind in PART_KINDS]
ALL = str((1 << len(PARTS)) - 1)


def parts_of(gender):
    meshes = {
        'body': (GHOST_DIR + '\\v_body_%s.mesh' % gender, V_MASK[gender]),
        'arm_l': (GHOST_DIR + '\\v_arm_l_%s.mesh' % gender, ALL_CHUNKS),
        'arm_r': (GHOST_DIR + '\\v_arm_r_%s.mesh' % gender, ALL_CHUNKS),
        'head': (GHOST_DIR + '\\v_head_%s.mesh' % gender, ALL_CHUNKS),
    }
    parts = [(name, meshes[name.split('_', 3)[3]][0], meshes[name.split('_', 3)[3]][1]) for name in PARTS]
    assert [p[0] for p in parts] == PARTS and len(parts) == 16
    return parts


# Smasher's peak held (his two material tracks, same RUIDs) on all sixteen
# parts -- kept in the package, played by nothing in 1.4.6 -- and a trigger
# that drives nothing: another client plays the trigger on a boosted body and
# this package's REDscript answers it by lighting the afterimages.
EFFECTS = [('opx_sandy_ghost_' + tag, GHOST_DIR + '\\opx_sandy_ghost_%s.effect' % tag,
            ['4107658665465827328', '4115960124918923264'], ALL) for tag, _ in STRENGTHS] + [
    ('opx_sandy_ghost_on', 'base\\fx\\characters\\boss_adam_shasher\\ch_smasher_sandevistan_low.effect',
     ['4109073175128920064', '4115965977197740032'], '0'),
]

smasher_app = load(SRC, 'boss__adam_smasher_mm.app.json')
stage = smasher_app['Data']['RootChunk']['appearances'][0]['Data']
by_name = {c['name']['$value']: c for c in stage['compiledData']['Data']['Chunks'] if 'name' in c}
# V's OWN body part: the male body's component in t0_000_base__full.app.
body_app_for_template = load(SRC, 't0_000_base__full.app.json')
template_mesh = None
for chunk in body_app_for_template['Data']['RootChunk']['appearances'][0]['Data']['compiledData']['Data']['Chunks']:
    if chunk.get('name', {}).get('$value') == 't0_000_pma_base__full':
        template_mesh = copy.deepcopy(chunk)
assert template_mesh is not None and template_mesh['$type'] == 'entGarmentSkinnedMeshComponent'
for key in ('parentTransform', 'skinning'):
    assert template_mesh[key]['Data']['bindName']['$value'] == 'root'

smasher_ent = load(SRC, 'adam_smasher.ent.json')
template_fx = None
for chunk in smasher_ent['Data']['RootChunk']['compiledData']['Data']['Chunks']:
    if chunk.get('$type') == 'entEffectSpawnerComponent' and chunk['name']['$value'] == 'fx_sandevistan':
        template_fx = copy.deepcopy(chunk)
        template_desc = copy.deepcopy(chunk['effectDescs'][0]['Data'])
assert template_fx is not None

handle = [0]


def next_handle():
    value = handle[0]
    handle[0] += 1
    return str(value)


def ghost_part(name, mesh, chunk_mask, component_id):
    c = copy.deepcopy(template_mesh)
    c['acceptDismemberment'] = 0
    c['castLocalShadows'] = 'Never'
    c['castShadows'] = 'Never'
    c['chunkMask'] = chunk_mask
    c['id'] = component_id
    c['isEnabled'] = 0
    c['LODMode'] = 'AlwaysVisible'
    c['mesh'] = depot(mesh)
    c['meshAppearance'] = cname(LOOK)
    c['name'] = cname(name)
    for key in ('parentTransform', 'skinning'):
        c[key] = {'HandleId': next_handle(), 'Data': copy.deepcopy(template_mesh[key]['Data'])}
    return c


def effect_desc(name, path, ruids, component_mask, desc_id):
    d = copy.deepcopy(template_desc)
    d['effectName'] = cname(name)
    d['effect'] = depot(path)
    d['id'] = desc_id
    d['isAutoSpawn'] = 0
    d['randomWeight'] = 1
    info = d['compiledEffectInfo']
    info['componentNames'] = [cname(n) for n in PARTS]
    events = []
    for ruid in sorted(ruids, key=int):
        events.append({'$type': 'worldCompiledEffectEventInfo', 'componentIndexMask': component_mask,
                       'eventRUID': ruid, 'flags': 1, 'placementIndexMask': '0'})
    info['eventsSortedByRUID'] = events
    info['placementInfos'] = []
    info['placementTags'] = []
    info['relativePositions'] = []
    info['relativeRotations'] = []
    return d


# One id per part and per descriptor, shared by every appearance.
PART_IDS = [cruid() for _ in PARTS]
FX_ID = cruid()
DESC_IDS = [cruid() for _ in EFFECTS]


def reference(value):
    """The `components` list repeats the compiled chunks with every handle as a
    reference to the chunk's own (WolvenKit's JSON form of a shared handle)."""
    if isinstance(value, dict):
        if 'HandleId' in value and 'Data' in value:
            return {'HandleRefId': value['HandleId']}
        return {k: reference(v) for k, v in value.items()}
    if isinstance(value, list):
        return [reference(v) for v in value]
    return value


def gender_of(name):
    if 'pwa' in name:
        return 'wa'
    if 'pma' in name:
        return 'ma'
    raise ValueError(name)


buffers = []


def appearance(name):
    own = next_handle()
    buffers.append(name)
    chunks = []
    for (part, mesh, chunk_mask), pid in zip(parts_of(gender_of(name)), PART_IDS):
        chunks.append(ghost_part(part, mesh, chunk_mask, pid))
    fx = copy.deepcopy(template_fx)
    fx['id'] = FX_ID
    fx['name'] = cname('opx_sandy_ghost_fx')
    fx['effectDescs'] = [{'HandleId': next_handle(), 'Data': effect_desc(n, p, r, m, i)}
                         for (n, p, r, m), i in zip(EFFECTS, DESC_IDS)]
    chunks.append(fx)
    data = copy.deepcopy(base_definition)
    data['name'] = cname(name)
    data['compiledData'] = {
        'BufferId': str(len(buffers) - 1), 'Flags': 0,
        'Type': 'WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version=9.0.1.0, Culture=neutral, PublicKeyToken=null',
        'Data': {'Version': 4, 'Sections': 7, 'CruidIndex': -1,
                 'CruidDict': {str(i): c['id'] for i, c in enumerate(chunks)},
                 'Chunks': chunks},
    }
    data['components'] = [reference(c) for c in chunks]
    return {'HandleId': own, 'Data': data}


# The appearance definition every patched appearance starts from: V's own
# body's, emptied of everything it carries (the patch ADDS; ArchiveXL merges an
# appearance of the same name into the target's).
base_definition = copy.deepcopy(body_app['Data']['RootChunk']['appearances'][0]['Data'])
for key, empty in (('components', []), ('partsValues', []), ('partsOverrides', []), ('partsMasks', []),
                   ('looseDependencies', []), ('resolvedDependencies', []), ('hitRepresentationOverrides', [])):
    base_definition[key] = empty
none_path = {'DepotPath': {'$type': 'ResourcePath', '$storage': 'uint64', '$value': '0'}, 'Flags': 'Soft'}
base_definition['proxyMesh'] = copy.deepcopy(none_path)
base_definition['cookedDataPathOverride'] = copy.deepcopy(none_path)
# No tags of its own: the target keeps its `Male`/`Female` and `PlayerBodyPart`.
base_definition['visualTags'] = {'$type': 'redTagList', 'tags': []}
base_definition['inheritedVisualTags'] = {'$type': 'redTagList', 'tags': []}
base_definition['censorFlags'] = 0
base_definition['parentAppearance'] = cname('None')
base_definition['proxyMeshAppearance'] = cname('None')

names = []
for source in ('t0_000_base__full.app.json', 't0_000_base__full_censored.app.json'):
    for a in load(SRC, source)['Data']['RootChunk']['appearances']:
        n = a['Data']['name']['$value']
        if n not in names:
            names.append(n)

# The resource itself carries nothing but the appearances: every field at its
# empty default (V's own file's wound configs, censorship and the like stay the
# target's).
root = {
    '$type': 'appearanceAppearanceResource',
    'alternateAppearanceMapping': [],
    'alternateAppearanceSettingName': cname('None'),
    'alternateAppearanceSuffixes': [],
    'appearances': [],
    'baseEntity': copy.deepcopy(none_path),
    'baseEntityType': cname('None'),
    'baseType': cname('None'),
    'censorshipMapping': [],
    'commonCookData': copy.deepcopy(none_path),
    'cookingPlatform': 'PLATFORM_None',
    'DismEffects': [],
    'DismWoundConfig': {'$type': 'entdismembermentWoundsConfigSet', 'Configs': []},
    'forceCompileProxy': 0,
    'generatePlayerBlockingCollisionForProxy': 0,
    'partType': cname('None'),
    'preset': cname('None'),
    'proxyPolyCount': 1400,
    'Wounds': [],
}
assert set(root) == set(body_app['Data']['RootChunk']), set(root) ^ set(body_app['Data']['RootChunk'])
root['appearances'] = [appearance(n) for n in names]

patch = {
    'Header': dict(body_app['Header'], ArchiveFileName='', ExportedDateTime='2026-09-27T00:00:00Z'),
    'Data': {'Version': body_app['Data'].get('Version'), 'BuildVersion': body_app['Data'].get('BuildVersion'),
             'RootChunk': root, 'EmbeddedFiles': []},
}
for key in list(body_app['Data'].keys()):
    if key not in patch['Data']:
        patch['Data'][key] = copy.deepcopy(body_app['Data'][key])
patch['Data']['RootChunk'] = root
patch['Data']['EmbeddedFiles'] = []
save(patch, PATCH_NAME + '.json')

manifest = {'parts': PARTS, 'strengths': STRENGTHS, 'effects': [e[0] for e in EFFECTS], 'appearances': names,
            'genders': {n: gender_of(n) for n in names}, 'meshes': MESHES, 'material': MATERIAL,
            'masks': V_MASK}
os.makedirs(os.path.join(HERE, 'build_v146'), exist_ok=True)
with open(os.path.join(HERE, 'build_v146', 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=1)
print('meshes:', json.dumps(MESHES))
print('patch: %d appearances x %d parts + 1 effect spawner (%d descriptors), %d handles'
      % (len(names), len(PARTS), len(EFFECTS), handle[0]))
