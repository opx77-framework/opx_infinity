# The surface, and how it is drawn

`opx_infinity/ui` is ONE CEF page. Everything the player sees -- the HUD, the menu,
the inventory, the toasts, the name tags -- is a module inside it, and every module
is written in the same visual language.

This file is that language. The code is the authority: where a rule below and a style
block disagree, the style block is what ships and this file is out of date.

**The stack is one direction, and only one:**

```
augmented-ui          the shapes: every cut corner and every frame
      ↓
design-system/        the OPX vocabulary: tokens, presets, states, the plane
      ↓
modules/<name>/       what is true of THAT surface and of nothing else
```

---

## The look: red, outlined, tilted

Pass 01 was cyan and yellow, filled, and built on shared Vue components. Pass 02 is
red, unfilled except for a dark ground under type, chamfered, and tilted on a
perspective. It was drawn against IDEDARY/Bevypunk and settled on the menu.

### The contract

1. **NOTHING IS FILLED** except the ground under type. State is a stroke going bright,
   never a block of colour.
2. **A CONTROL IS A CLOSED BOX** -- a thin frame with the top-right corner chamfered.
   The converse is load-bearing: **what is not a control does not get a frame.** A
   readout is a line of type; a separator is a 1px rule. A frame means "press this".
3. **augmented-ui DRAWS EVERY SHAPE.** One attribute, and the state is one custom
   property. See [The shapes](#the-shapes).
4. **RED IS THE VOICE, SO RED CANNOT BE THE ALARM.** A red bar going redder inside a
   red frame says nothing. The escalation climbs in luminance and then leaves the hue:
   `--op-red-idle` → `--op-red` → `--op-red-hi` → `--op-alarm`, which is **white-hot**.
5. **THE TILT COMES FROM THE ANCHOR.** Left-anchored is `+7deg` about the left edge,
   right-anchored `-7deg` about the right, centred is **none** -- rotating a centred
   plane about its middle is paper on a spindle, not a surface receding. A name tag is
   pinned to a body in the world and takes no tilt at all: the world supplies one.
6. **ONE INK SHADOW PER SURFACE**, declared on the root and inherited. An override
   replaces the whole list, so a block wanting a bloom restates both passes plus it.
7. **NO SECOND HUE.** There is no accent, no green, no yellow. Each would have solved
   some problem in one line, and each puts a second saturated hue on an unfilled red
   surface over live gameplay.
8. **TECHNICAL FILLER IS CONTENT.** A mono micro-label is part of the look and must
   state something the surface knows -- a row index, a toast's kind. Never invented
   chrome text.
9. **THE INTERLACE GOES ON WHAT IS ENCLOSED.** A surface with no frame does not take
   it: a striped rectangle with nothing around it *is* the floating rectangle the
   interlace exists to prevent.

---

## The shapes

Every chamfer in the runtime is augmented-ui. An element says what it is with a
preset class and asks for the border layer:

```html
<div class="row op-frame" data-augmented-ui="tr-clip border">
```

```css
.op-frame { --aug-tr: var(--op-cut-sm); background: var(--op-plate); }
.op-frame.is-on { --aug-border-bg: var(--op-red); --aug-border-all: 2px; }
```

| Preset | What it is | Cut |
|---|---|---|
| `.op-frame` | a control: closed box, chamfered top-right | `--op-cut-sm` |
| `.op-bay` | an enclosure holding a list or a grid, two opposite corners | `--op-cut-lg` |
| `.op-cap` | a keycap -- a mark, so **no ground** | `--op-cut-sm` |

States are `.is-on`, `.is-off`, `.is-alarm` and `:hover`, and each is one
`--aug-border-bg`. `.op-arete` lights the leading edge; `.is-end` mirrors it for a
right-anchored surface. `.op-lift` is the bloom.

### What must be known before touching this

- **A cut size is required.** An augmented element with no `--aug-tr` renders as a
  plain rectangle and nothing warns you. Either carry a preset class or declare the
  cut -- or inherit it from an ancestor, which is how `HudVitals` gives its gauge
  track the same cut as its row.
- **A clip shears an outset `box-shadow`.** augmented-ui clips the element, so a bloom
  is `.op-lift` (a `drop-shadow`, which follows the cut) or it is nothing. Several
  files carried a written defence of `box-shadow` that was true only while they were
  unclipped; the defence went with the sprite.
- **A filter costs a backing store.** Never on anything whose value changes every
  frame. The HUD repaints at 30Hz and carries exactly one, on the rx counter, which
  appears when somebody talks rather than on a clock.
- **`::before` is yours, `::after` is not.** The border layer is `::after`. Asking for
  `border` without `inlay` leaves `::before` free, which is what `.op-interlace` uses.
- **Augment containers, not cells.** A 40-slot grid is one bay and forty cells; the
  cells are augmented only because each needs the cut and the ground, and they ask for
  the border layer alone so it is one pseudo-element each rather than two.

---

## The one sprite left

`InventorySlot.vue` keeps a single SVG data URI, for the **drag** state: four corner
brackets and no edges. That is a *shape class* change, not a colour change, and
augmented-ui's border layer is a continuous ring around the clip path. The cell's
augmentation is therefore bound rather than static --
`:data-augmented-ui="dragging ? undefined : 'tr-clip border'"` -- so the dragged cell
is unclipped and its sprite paints the brackets whole.

Forty other sprites are gone. They were inline 9-slice SVGs, one per state per
surface, each a copy of the same chamfer path with one number changed, plus a black
under-stroke baked in because a `border-image` cannot take a shadow.

---

## Layout

| File | What it decides |
|---|---|
| `design-system/tokens.css` | every value: the red ladder, the grounds, the neutral ramp, type, space, shape, motion |
| `design-system/shapes.css` | the three presets, the states, `.op-arete`, `.op-lift` |
| `design-system/surface.css` | the plane and tilt, the ink, the interlace, four type roles, the entrance |
| `design-system/fonts.css` | the three faces, inlined by the build |
| `boot/` | the one `createApp`, the two layers, the module registry |
| `bridge/` | the channel, rpc, focus and diagnostics -- no module talks to CEF directly |
| `modules/<name>/` | one surface each |

**`overlay` vs `modal`** is declared per module in `boot/registry.ts` and decides
style as much as behaviour. An overlay surface is never focused, takes no pointer, and
has no backing of any kind; a modal surface takes focus and the cursor while open.

---

## There is no shared row component, and that is deliberate

A menu row, a target row, an inventory cell and a panel row look alike and behave
nothing alike. One shared row is what coupled five surfaces together in pass 01 --
changing it changed every surface at once, which is why each of them ended up with a
local copy anyway. What is shared is the *vocabulary*, not the markup: a surface draws
its own row out of `.op-frame`, the states and the type roles, and adds the twenty
lines that are true of that row alone.

Wrap something in a component when it carries real behaviour, not to avoid repeating a
class list.
