"""Cuts the ripperdoc screen's art out of the installed game's own 2.31 files.

Everything under `ui/public/images/ripperdoc/` comes from here: the hologram
bodies of the base game's ripperdoc paperdoll, the shapes its tiles, tooltips,
labels and buttons are drawn with, the capacity and armor meters' backgrounds,
and the icons they carry. Nothing is drawn by hand.

INPUT. A folder of the game files below converted to JSON by WolvenKit
(`WolvenKit.CLI convert serialize <folder> -o <json>`): each `.inkatlas` and
the `.xbm` texture it names, flat in one folder, named as the game names them
(`woman_body.inkatlas.json`, `woman_body.xbm.json`, ...). The files, from
`basegame_1_engine.archive` / `basegame_4_gamedata.archive`:

    base\\gameplay\\gui\\fullscreen\\ripperdoc\\woman_body.inkatlas (+ .xbm)
    base\\gameplay\\gui\\fullscreen\\ripperdoc\\man_body.inkatlas (+ .xbm)
    base\\gameplay\\gui\\fullscreen\\ripperdoc\\assets\\cw_bars_assets.inkatlas (+ .xbm)
    base\\gameplay\\gui\\common\\shapes\\atlas_shapes_sync.inkatlas (+ .xbm)
    base\\gameplay\\gui\\fullscreen\\inventory\\atlas_inventory.inkatlas (+ .xbm)
    base\\gameplay\\gui\\fullscreen\\inventory\\inventory4_atlas.inkatlas (+ .xbm)
    base\\gameplay\\gui\\common\\icons\\mappin_icons.inkatlas (+ .xbm)
    base\\gameplay\\gui\\common\\icons\\atlas_cash.inkatlas (+ .xbm)
    base\\gameplay\\gui\\common\\icons\\atlas_common.inkatlas (+ .xbm)

TWO THINGS THE GAME DOES THAT A CUT MUST UNDO. A texture is stored bottom row
first: read top-down, every atlas rectangle misses its art (the same flip the
cyberware icons need). And the shapes are white and tinted at draw time: they
ship here as white with their own alpha, and the page tints them with
`-webkit-mask-box-image` over a background colour (`MainColors.*`, read from
`base\\gameplay\\gui\\common\\main_colors.inkstyle`), slicing them where the
atlas slices them (`SLICES` below, the atlas's own `nineSliceScaleRect`).

WHERE IT GOES. The shapes and icons are small and every tile, tooltip and
button needs them at the first paint, so they go into the page itself: they are
written to `ui/src/modules/ripperdoc/art/` and the build inlines them (Vite's
`assetsInlineLimit`). The paperdoll bodies and the meters' backgrounds are the
weight, fetched once the screen opens: `ui/public/images/ripperdoc/`, which the
build copies to `web/images/ripperdoc/` (short names: a client sees nothing past
59 characters of a path, README "Keep every shipped path short").

    python3 tools/ripperdoc-art.py <json folder>

Needs Pillow (with its DDS reader: BC3 and BC7).
"""
import base64
import io
import json
import os
import struct
import sys

from PIL import Image

# DXGI formats of the two compressions these textures use.
DXGI = {'TCM_QualityColor': 98, 'TCM_DXTAlpha': 77}

# A shape: (atlas, part, file). Shipped white, alpha kept, at the atlas's own
# (4K) size -- the page scales them.
SHAPES = [
    ('atlas_shapes_sync', 'item_bg', 'item_bg.png'),
    ('atlas_shapes_sync', 'item_fg', 'item_fg.png'),
    ('atlas_shapes_sync', 'item_side_bg', 'item_side.png'),
    ('atlas_shapes_sync', 'unified_tooltip_fill', 'tip_fill.png'),
    ('atlas_shapes_sync', 'unified_tooltip_stroke', 'tip_line.png'),
    ('atlas_shapes_sync', 'unified_tooltip_outline', 'tip_edge.png'),
    ('atlas_shapes_sync', 'color_flip_bg', 'flip_bg.png'),
    ('atlas_shapes_sync', 'color_flip_bg_180', 'tab_bg.png'),
    ('atlas_shapes_sync', 'color_flip_fg_180', 'tab_fg.png'),
    ('atlas_shapes_sync', 'cell_bg', 'cell_bg.png'),
    ('atlas_shapes_sync', 'cell_fg', 'cell_fg.png'),
    ('atlas_shapes_sync', 'label_frame', 'label.png'),
    ('atlas_shapes_sync', 'label_frame_line', 'label_line.png'),
    ('atlas_shapes_sync', 'equipped_accent', 'eq_mark.png'),
    ('cw_bars_assets', 'counterLabel', 'count.png'),
    ('cw_bars_assets', 'counterLabel_stroke', 'count_line.png'),
    ('inventory4_atlas', 'button_big1_shape', 'btn_bg.png'),
    ('inventory4_atlas', 'button_big1_frame', 'btn_fg.png'),
    ('atlas_inventory', 'texture_1slot', 'slot_lines.webp'),
    ('atlas_inventory', 'texture_1slot_iconic', 'iconic.webp'),
    ('mappin_icons', 'ripperdoc', 'cap_icon.png'),
    ('mappin_icons', 'armor', 'armor_icon.png'),
    ('atlas_cash', 'cash_symbol_normal', 'eddies.png'),
    ('inventory4_atlas', 'icon_add', 'add.png'),
]

# Art with its own colours: the meters' backgrounds, as the game draws them.
COLOURED = [
    ('cw_bars_assets', 'cw_barbg', 'cap_bg.webp', 1.0),
    ('cw_bars_assets', 'armor_barbg', 'armor_bg.webp', 1.0),
]

# The hologram bodies of the paperdoll: the full body per system, and the parts
# the game lays over it for the others. (file stem, part) per body; 0.6 of the
# 4K atlas keeps them sharp at 1440p and a few hundred kilobytes each.
BODY_SCALE = 0.6
BODIES = {
    'woman_body': ('f', {
        'base': 'wo_skeleton', 'circ': 'wo_circular', 'skin': 'wo_intergumentary',
        'nerve': 'wo_nervous', 'cortex': 'wo_frontal_cortex', 'eye': 'wo_ocular',
        'os': 'wo_operating_system', 'arms': 'wo_arms', 'hands': 'wo_hands', 'legs': 'wo_legs',
    }),
    'man_body': ('m', {
        'base': 'ma_full_skeleton', 'circ': 'ma_circular', 'skin': 'ma_intergumentary',
        'nerve': 'ma_nervous', 'cortex': 'ma_pfrontal_cortex', 'eye': 'ma_ocular',
        'os': 'ma_operating_system', 'arms': 'ma_arms', 'hands': 'ma_hands', 'legs': 'ma_legs',
    }),
}


def texture(folder, stem):
    """The decoded texture of one `.xbm`, top row first."""
    root = json.load(open(os.path.join(folder, stem + '.xbm.json')))['Data']['RootChunk']
    blob = root['renderTextureResource']['renderResourceBlobPC']['Data']
    width = int(blob['header']['sizeInfo']['width'])
    height = int(blob['header']['sizeInfo']['height'])
    size = int(blob['header']['textureInfo']['textureDataSize'])
    data = base64.b64decode(blob['textureData']['Bytes'])[:size]
    fourcc = struct.unpack('<I', b'DX10')[0]
    head = struct.pack('<4s7I44s8I5I', b'DDS ', 124, 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000, height, width,
                       len(data), 0, 1, b'\0' * 44, 32, 0x4, fourcc, 0, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0)
    dx10 = struct.pack('<IIIII', DXGI[root['setup']['compression']], 3, 0, 1, 0)
    image = Image.open(io.BytesIO(head + dx10 + data))
    image.load()
    return image.convert('RGBA').transpose(Image.FLIP_TOP_BOTTOM)


_atlases = {}


def atlas(folder, name):
    """(parts, texture) of one `.inkatlas`: each part's rectangle in pixels."""
    if name not in _atlases:
        root = json.load(open(os.path.join(folder, name + '.inkatlas.json')))['Data']['RootChunk']
        slot = root['slots']['Elements'][0]
        stem = slot['texture']['DepotPath']['$value'].split('\\')[-1][:-len('.xbm')]
        image = texture(folder, stem)
        width, height = image.size
        parts = {}
        for part in slot['parts']:
            uv = part['clippingRectInUVCoords']
            parts[part['partName']['$value']] = (round(uv['Left'] * width), round(uv['Top'] * height),
                                                 round(uv['Right'] * width), round(uv['Bottom'] * height))
        _atlases[name] = (parts, image)
    return _atlases[name]


def cut(folder, name, part):
    parts, image = atlas(folder, name)
    if part not in parts:
        raise SystemExit('%s has no part %s' % (name, part))
    return image.crop(parts[part])


def white(image):
    """The shape alone: white, with the art's own alpha."""
    alpha = image.getchannel('A')
    return Image.merge('RGBA', (Image.new('L', image.size, 255),) * 3 + (alpha,))


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INLINE = os.path.join(REPO, 'ui', 'src', 'modules', 'ripperdoc', 'art')
PUBLIC = os.path.join(REPO, 'ui', 'public', 'images', 'ripperdoc')


def main(folder):
    os.makedirs(INLINE, exist_ok=True)
    os.makedirs(PUBLIC, exist_ok=True)
    written = []
    for name, part, file in SHAPES:
        image = white(cut(folder, name, part))
        if file.endswith('.webp'):
            image.save(os.path.join(INLINE, file), 'WEBP', lossless=True, method=6)
        else:
            image.save(os.path.join(INLINE, file), optimize=True)
        written.append((os.path.join(INLINE, file), image.size))
    out = PUBLIC
    for name, part, file, scale in COLOURED:
        image = cut(folder, name, part)
        if scale != 1.0:
            image = image.resize((round(image.size[0] * scale), round(image.size[1] * scale)), Image.LANCZOS)
        image.save(os.path.join(out, file), 'WEBP', quality=90, method=6)
        written.append((os.path.join(out, file), image.size))
    for name, (prefix, parts) in BODIES.items():
        for stem, part in parts.items():
            image = cut(folder, name, part)
            size = (round(image.size[0] * BODY_SCALE), round(image.size[1] * BODY_SCALE))
            image = image.resize(size, Image.LANCZOS)
            file = '%s_%s.webp' % (prefix, stem)
            image.save(os.path.join(out, file), 'WEBP', quality=86, method=6)
            written.append((os.path.join(out, file), image.size))
    for path, size in written:
        print('%-44s %4dx%-4d %7d bytes' % (os.path.relpath(path, REPO), size[0], size[1], os.path.getsize(path)))
    print('%d files, %d bytes' % (len(written), sum(os.path.getsize(p) for p, _ in written)))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
