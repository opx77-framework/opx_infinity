"""Builds opx_sandy_view's ghost-trail package (1.4.8): the ghost's parts are IN
V's own body files, so no loader is needed to put them there.

1.4.0-1.4.7 added the sixteen parts and the effect spawner to V's body with an
ArchiveXL patch of `t0_000_base__full.app` (and its censored cut). A player
whose game does not run ArchiveXL never gets them: on 2026-09-27 the second
player's log said, of their OWN third-person model, "0 of 16 parts (none), its
effect spawner MISSING", and of the boosting player's body "no ghost parts yet
-- ... or this game has no ArchiveXL patch" -- while the same package's
REDscript (1.4.7) ran on that machine. The trail therefore depended on a
plugin the package does not control.

1.4.8 ships the two files themselves: `base\\characters\\common\\
player_base_bodies\\appearances\\t0_000_base__full.app` and
`..._censored.app` are the base game's own (2.31), every field kept, with the
patch's parts appended to each of the 36 appearances -- the components the
ArchiveXL patch added at run time: the same sixteen parts and the same
spawner, with the same ids, meshes, chunk masks and bindings. An archive in
`archive/pc/mod` replaces a base-game file by its depot path, which the game
does on its own; the `.xl` is gone, so a game that DOES run ArchiveXL does not
add the parts twice.

Inputs: the base game's two files as WolvenKit JSON (`json/`), and the
package `build.py` writes (`build_v146/json/opx/sandy/ghost/`: the patch this
merges, the meshes, the material and the effect -- unchanged since 1.4.6).

Output: `build_v148/json/` (the two merged files) for `WolvenKit.CLI convert
deserialize`, and `build_v148/manifest.json`.
"""
import copy
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'json')
PATCH = os.path.join(HERE, 'build_v146', 'json', 'opx', 'sandy', 'ghost', 'opx_sandy_ghost_patch.app.json')
OUT = os.path.join(HERE, 'build_v148', 'json')
DEPOT_DIR = 'base\\characters\\common\\player_base_bodies\\appearances'
FILES = ['t0_000_base__full.app', 't0_000_base__full_censored.app']

LAYERS, KINDS = 4, ['body', 'arm_l', 'arm_r', 'head']
PARTS = ['opx_sandy_ghost%d_%s' % (layer, kind) for layer in range(1, LAYERS + 1) for kind in KINDS]
SPAWNER = 'opx_sandy_ghost_fx'


def load(path):
    with open(path) as f:
        return json.load(f)


def offset_handles(value, by):
    """Every handle id and reference in `value` moved by `by` (so the patch's
    numbering cannot meet the base file's)."""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k in ('HandleId', 'HandleRefId') and isinstance(v, str):
                out[k] = str(int(v) + by)
            else:
                out[k] = offset_handles(v, by)
        return out
    if isinstance(value, list):
        return [offset_handles(v, by) for v in value]
    return value


def renumber(doc):
    """Handle ids renumbered 0.. in document order (a definition always comes
    before its references: `compiledData` sorts before `components`)."""
    mapping = {}
    counter = [0]

    def walk(value):
        if isinstance(value, dict):
            if 'HandleId' in value and 'Data' in value:
                old = value['HandleId']
                assert old not in mapping, 'handle %s defined twice' % old
                mapping[old] = str(counter[0])
                counter[0] += 1
                value['HandleId'] = mapping[old]
            if 'HandleRefId' in value:
                old = value['HandleRefId']
                assert old in mapping, 'handle %s referenced before it is defined' % old
                value['HandleRefId'] = mapping[old]
            for k, v in value.items():
                if k not in ('HandleId', 'HandleRefId'):
                    walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)

    walk(doc)
    return counter[0]


def max_handle(doc):
    return max(int(x) for x in re.findall(r'"Handle(?:Ref)?Id": "(\d+)"', json.dumps(doc)))


def gender_of(name):
    if 'pwa' in name:
        return 'wa'
    if 'pma' in name:
        return 'ma'
    raise ValueError(name)


patch = load(PATCH)
patch_apps = {a['Data']['name']['$value']: a['Data'] for a in patch['Data']['RootChunk']['appearances']}
assert len(patch_apps) == 36, len(patch_apps)

os.makedirs(OUT, exist_ok=True)
manifest = {'files': {}, 'parts': PARTS, 'spawner': SPAWNER}
for name in FILES:
    doc = load(os.path.join(SRC, name + '.json'))
    base = copy.deepcopy(doc)
    shift = max_handle(doc) + 1000
    rc = doc['Data']['RootChunk']
    seen = []
    for entry in rc['appearances']:
        app = entry['Data']
        app_name = app['name']['$value']
        mine = patch_apps[app_name]
        cd = app['compiledData']['Data']
        chunks = cd['Chunks']
        vanilla = len(chunks)
        assert vanilla == len(app['components']), (app_name, vanilla, len(app['components']))
        own_names = [c.get('name', {}).get('$value') for c in chunks]
        assert not set(own_names) & set(PARTS + [SPAWNER]), (app_name, 'already carries the ghost')
        extra_chunks = offset_handles(copy.deepcopy(mine['compiledData']['Data']['Chunks']), shift)
        extra_components = offset_handles(copy.deepcopy(mine['components']), shift)
        assert [c['name']['$value'] for c in extra_chunks] == PARTS + [SPAWNER], app_name
        assert [c['name']['$value'] for c in extra_components] == PARTS + [SPAWNER], app_name
        # The parts on THIS appearance's gender (the patch was built that way).
        g = gender_of(app_name)
        for c in extra_chunks[:len(PARTS)]:
            path = c['mesh']['DepotPath']['$value']
            assert path.endswith('_%s.mesh' % g), (app_name, path)
            assert c['isEnabled'] == 0 and c['castShadows'] == 'Never'
        # The compiled package: chunks appended, their ids in the cruid map.
        cruids = cd['CruidDict']
        assert sorted(int(k) for k in cruids) == list(range(vanilla)), (app_name, cruids)
        for i, c in enumerate(extra_chunks):
            cruids[str(vanilla + i)] = c['id']
        chunks.extend(extra_chunks)
        app['components'].extend(extra_components)
        seen.append(app_name)
        shift += 1000
    assert sorted(seen) == sorted(patch_apps), name
    count = renumber(doc)
    # Nothing of the base file changed but the appended parts: the base file
    # is the merged one with the parts taken out again.
    check = copy.deepcopy(doc)
    for entry, before in zip(check['Data']['RootChunk']['appearances'], base['Data']['RootChunk']['appearances']):
        app = entry['Data']
        n = len(before['Data']['compiledData']['Data']['Chunks'])
        del app['compiledData']['Data']['Chunks'][n:]
        del app['components'][n:]
        app['compiledData']['Data']['CruidDict'] = {k: v for k, v in app['compiledData']['Data']['CruidDict'].items()
                                                    if int(k) < n}
    manifest['files'][name] = {'depot': DEPOT_DIR + '\\' + name, 'appearances': len(seen), 'handles': count,
                               'partsPerAppearance': len(PARTS) + 1}
    doc['Header'] = dict(doc['Header'], ArchiveFileName='', ExportedDateTime='2026-09-28T00:00:00Z')
    with open(os.path.join(OUT, name + '.json'), 'w') as f:
        json.dump(doc, f, indent=1)
    with open(os.path.join(OUT, '..', name + '.stripped.json'), 'w') as f:
        json.dump(check, f, indent=1)
    print('%s: %d appearances, +%d parts each, %d handles' % (name, len(seen), len(PARTS) + 1, count))

with open(os.path.join(HERE, 'build_v148', 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=1)
