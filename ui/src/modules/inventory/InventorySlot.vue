<script setup lang="ts">
import { computed } from 'vue'
import { ammoOf, durabilityOf, grams, imageFor, labelOf, monogram, weightOf } from './format'
import type { CatalogEntry, ScreenConfig, Stack } from './types'

/**
 * One cell of a grid.
 *
 * It renders what it is given and emits what the player did. It never changes its
 * own count, and it never decides that a drop was legal.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * NO FILL, ANYWHERE -- AND THEN ONE, ON PURPOSE. Read this paragraph and the
 * next one together; neither is true on its own. The cell used to be
 * `background: var(--op77-panel)` with a `--op77-line` border and an accent wash
 * on the drop target -- three fills in one 78px box. All three are gone, and
 * none of the three came back: a cell's STATE is still an OUTLINE and nothing
 * else, expressed in that outline's WEIGHT, its COLOUR and whether it BLOOMS.
 *
 * THE GROUND IS BACK UNDER THE OUTLINE, AND ONLY UNDER IT. The owner asked for
 * it in as many words -- "give the slots a background, and the drop one too" --
 * and it is his call to make. It is also the one place the no-fill rule was
 * actually costing something: a 50px item picture and a white stack count
 * sitting directly on a blown-out daylight plaza are unreadable however good the
 * frame around them is, and no amount of stroke fixes a picture. So a cell gets
 * a GROUND -- a dark, low-alpha plate whose entire job is to buy the ART and the
 * COUNT a backdrop.
 *
 * AND THE GROUND IS RED, which is his second instruction on it -- "for the
 * inventory backgrounds, make them red please" -- and the correct one: a cold
 * blue-black plate was the one thing on this surface belonging to no palette at
 * all, a borrowed `--op77-panel-quiet` sitting inside a red frame, and it read as
 * a hole cut in the design rather than as part of it. So the ground is the
 * surface's OWN red, taken down until it is a black: #1c0809 is `--red-idle`'s
 * rgb at 12%, #4a1519 the same rgb at 32%. Nothing else about it moved.
 *
 * RED, NOT A RED PLATE, and the difference is the whole job. The ground exists
 * so a 50px picture and a white stack count survive a blown-out street; a
 * saturated red behind them would swallow both and be worse than the no-fill
 * state this started from, because it would be a fill that pays for nothing. The
 * test every value below has to pass is that it reads as a SHADOW with a red
 * cast at a glance and only declares its hue when you look for it. That is why
 * these are 12% and 32% of a red rather than a red, and why raising them is not
 * a free hand: past roughly 40% the icons start to go.
 *
 * THIS IS NOT A LICENCE TO FILL ANYTHING ELSE. Two elements were named and two
 * elements changed: the cell here, and `.ground` in `InventoryView.vue`. The
 * panels, the tabs, the rows, the readouts, the load rules and the detail plate
 * stay unfilled, and the surface is still outlines over live gameplay. If you
 * are here to "fix" a fill back out of the pass, these two are deliberate --
 * anything else you find is not.
 *
 * TWO CHANNELS, NOT ONE LONGER LADDER. The ground does not restate the frame and
 * must not be read as another rung of it. The FRAME says what is HAPPENING to a
 * slot -- at rest, under the pointer, receiving, vacated. The GROUND says what
 * the slot IS, which is only ever one of two things. Five frames, two grounds:
 *
 *   plate    #1c0809 @ 0.78   a slot                 -- empty or occupied
 *   slab     #4a1519 @ 0.90   something is ABOUT TO BE -- the drop target
 *
 * AN EMPTY CELL USED TO BE A THIRD, HOLLOW GROUND at 0.28 with a 1px stroke at
 * 0.30, so that "an empty cell and a full one no longer read alike". The owner
 * asked for the opposite, in a sentence that covered the whole screen: the
 * buttons, the slots and the drop zone all in the menu's one style. He is right
 * about what it costs, too -- an empty slot is not a fainter kind of slot, it is
 * a slot with nothing in it, and the thing that says so is that nothing is drawn
 * in it. Spending a whole channel to restate that left a grid of forty cells
 * where the container's own edges were the palest thing on screen.
 *
 * A hovered cell still does not gain a ground: the frame has already said it and
 * a second statement would only dilute the first.
 *
 * THE TARGET USED TO BE THE ONLY WARM GROUND ON THE GRID, and that was doing the
 * work of saying "it lands here" while the other two were blue-black. Now that
 * every ground is red, warmth is a constant and cannot separate anything, so the
 * target was re-pitched onto the two channels that survive a shared hue:
 *
 *   DENSITY   0.90 against 0.78 and 0.28 -- it is the one CLOSED cell on a grid
 *             of windows, and the only one the street does not come through
 *   DEPTH     #4a1519 against #1c0809 -- the same red carried up two and a half
 *             stops toward the LIT frame standing on it, so the ground and the
 *             2.4px `--red` outline are finally saying one thing rather than a
 *             dark thing under a bright one
 *
 * which together make the receiving cell the lightest, reddest and solidest
 * thing on a surface of thin outlines, before its bloom is counted. `.ground` in
 * `InventoryView.vue` takes the SAME slab when a drag is over the drop zone, so
 * a stack about to land reads one way wherever it is about to land.
 *
 * THE GROUND IS PAINTED BY THE FRAME ITSELF, which is why there is no
 * `background` property anywhere below. `border-image-slice: 6 fill` paints the
 * ninth, middle tile as well as the eight edge ones, so the ground is the SVG
 * path's own `fill` -- the CHAMFERED shape exactly, registered against its own
 * stroke by construction instead of by arithmetic. A `background` cannot do
 * this: it is a rectangle, and a rectangle under a chamfered frame leaves a 6px
 * triangle of plate sticking out past the diagonal, which cancels the one shape
 * the house owns. It also leaves the idiom below intact -- one property,
 * `border-image-source`, still moves a cell a whole step on BOTH channels at
 * once, with no second declaration to keep in agreement and nothing to animate.
 *
 * HOW FIVE STATES READ APART IN THE OUTLINE ALONE. This ladder was carrying all
 * five of them before there was a ground beneath it and it still is: the ground
 * added a channel beside it and took nothing from it. Weight is the ordering and
 * colour is the voice; they move together, so either alone is enough to rank a
 * cell:
 *
 *   empty      1.4px   --red-idle    -- the slot exists, and that is all it says
 *   occupied   1.4px   --red-idle    -- something is in it, and the item says so
 *   hover      1.8px   --red-deep    -- denser, NOT brighter, and no bloom
 *   target     2.4px   --red         -- lit and the ONLY cell that blooms
 *
 * THE DRAGGED CELL IS NOT ON THAT RAMP, and that is the whole solve. A fifth
 * step of weight between hover and target would be indistinguishable from both
 * at 78px. So the cell the stack is being dragged OUT of does not get a heavier
 * frame -- it gets a BROKEN one: four corner brackets in `--red-hi` and no edges
 * at all. It is the only discontinuous outline on the surface, so it cannot be
 * confused with any closed frame however heavy, and the shape states exactly
 * what is true -- this slot has been vacated and is waiting to be closed again.
 * Its content drops to 0.3 opacity so the brackets are what is left.
 *
 * WHY 9-SLICE AND NOT `clip-path`. A clip cuts the painted result, so a bordered
 * box under one loses its stroke along the diagonal and the chamfer arrives as a
 * GAP. The frames below are 9-slice SVG data URIs: 20x20 with 6px corner tiles,
 * the chamfer living entirely inside the top-right tile so a stretched edge can
 * never skew it, and the BRACKET frame's edge tiles simply empty. A state change
 * swaps `border-image-source` -- one property, no relayout, no new paint node.
 *
 * WHY THE TILES ARE 6px AND NOT THE MENU'S 8px. `border-image-width` paints
 * outside the 1px border box, so an 8px tile would spill 7px into the 8px grid
 * gap and every cell corner would be drawn twice, doubled, against its
 * neighbour's. 6px spills 5px, which the gap absorbs. Same idiom, sized for a
 * grid instead of a column.
 *
 * THE COLOURS AND THE SHADOWS ARE NOT DECLARED HERE. They are inherited, from
 * `.room` in `InventoryView.vue`, and that is the mechanism HudRoot.vue settled:
 * a scoped stylesheet cannot reach into a child component, but a CUSTOM PROPERTY
 * set on an ancestor inherits down the whole tree regardless of scoping. So the
 * ink, the separation shadow, the bloom, the resting lettering red and the
 * unfilled part of a rule are declared once on the surface and read from here --
 * one place to change the voice, and no `:deep()` anywhere.
 *
 * WHAT IS STILL LOCAL, and why the split falls where it does: the five FRAMES
 * below, because they are geometry before they are colour and the 6px tile above
 * is sized for this grid and nothing else. HudVitals.vue draws the same line --
 * it takes the palette from the root and keeps its own track.
 *
 * EVERY INHERITED VALUE CARRIES A LITERAL FALLBACK. A cell rendered outside the
 * surface -- in isolation, in a test, or by a view that has not declared the
 * palette -- still draws itself rather than drawing nothing.
 */
const props = defineProps<{
  index: number
  stack: Stack | null
  entry: CatalogEntry | undefined
  config: ScreenConfig
  /** The hotbar key drawn in the corner, for the first slots of the bag only. */
  hotkey: string
  selected: boolean
  /** The cell the pointer is currently over while a drag is in flight. */
  over: boolean
  /** This cell is the one being dragged; its frame breaks rather than moving. */
  dragging: boolean
  /** Dimmed because the active tab does not gather this item's category. */
  muted: boolean
  /** Item names whose picture has already failed to load once, surface-wide. */
  broken: Set<string>
}>()

const emit = defineEmits<{
  (event: 'grab', index: number, native: PointerEvent): void
  (event: 'open', index: number, native: MouseEvent): void
  (event: 'hover', index: number | null, native?: MouseEvent): void
  (event: 'broke', name: string): void
}>()

const label = computed(() =>
  props.stack ? labelOf(props.stack, props.entry, props.config.labels.unknown || '?') : ''
)

const image = computed(() => (props.stack ? imageFor(props.stack.name, props.entry) : ''))

const weight = computed(() =>
  props.stack
    ? grams(weightOf(props.stack, props.entry, props.config.defaultWeight), props.config)
    : ''
)

const ammo = computed(() => (props.stack ? ammoOf(props.stack) : -1))
const wear = computed(() => (props.stack ? durabilityOf(props.stack) : -1))

/* A worn item is NOT an alarm, and red is not the alarm on this surface anyway:
   a red bar inside a red frame beside a red label says nothing at all. The rule
   runs red -> lit red -> WHITE as condition falls, so the one cell in a bag that
   is nearly broken is the one carrying the only non-red mark on screen. */
const wearTone = computed(() => {
  if (wear.value < 0) return ''
  if (wear.value < 0.25) return 'spent'
  if (wear.value < 0.6) return 'worn'
  return ''
})

/** A picture that will not load is reported up once, so the monogram is drawn
    from then on for every cell holding that item rather than per cell. */
function onBroken(): void {
  if (props.stack) emit('broke', props.stack.name)
}

const showArt = computed(() => props.stack !== null && !props.broken.has(props.stack.name))
</script>

<template>
  <div
    class="cell"
    :class="{
      filled: stack !== null,
      selected,
      over,
      dragging,
      muted,
      weapon: entry?.weapon === true
    }"
    :data-slot="index"
    @pointerdown.prevent="stack && emit('grab', index, $event)"
    @contextmenu.prevent="stack && emit('open', index, $event)"
    @mouseenter="emit('hover', index, $event)"
    @mouseleave="emit('hover', null)"
  >
    <span v-if="hotkey" class="key">{{ hotkey }}</span>

    <template v-if="stack">
      <span class="art">
        <img v-if="showArt" :src="image" alt="" draggable="false" @error="onBroken" />
        <span v-else class="initials">{{ monogram(label) }}</span>
      </span>

      <span v-if="stack.count > 1" class="count">{{ stack.count }}</span>
      <span v-if="ammo >= 0" class="rounds">{{ ammo }}</span>

      <span v-if="wear >= 0" class="wear" :class="wearTone">
        <i :style="{ width: `${wear * 100}%` }" />
      </span>

      <span class="foot">
        <span class="name">{{ label }}</span>
        <span class="mass">{{ weight }}</span>
      </span>
    </template>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE FIVE FRAMES. 20x20, 6px corner tiles, chamfer inside the top-right tile.

   Each carries its colour and its stroke width TOGETHER, because that is what
   makes one property (`border-image-source`) able to move a cell a whole step
   along both ramps at once. The hex values are literal and not `var()`: a data
   URI is a string to the parser and a custom property inside one never resolves.
   They are the same three reds as `--red-idle / --red-deep / --red` on `.room`,
   plus `--red-hi` for the brackets.

   EACH NOW CARRIES ITS GROUND IN THE SAME STRING, as the path's own `fill`, and
   `border-image-slice: 6 fill` below is what puts that fill on the screen: three
   values -- hollow, plate, slab -- across the five frames, reasoned at the top of
   the file. `fill-opacity` rather than a functional colour, because that is the
   idiom `stroke-opacity` is already using two attributes along, and because a
   presentation attribute is the one place an `rgba()` is not certain to parse.

   THE TWO GROUND COLOURS ARE THE SAME RED AS THE STROKES, TAKEN DOWN. #1c0809 is
   `--red-idle`'s rgb(232, 67, 79) at 12% and #4a1519 is the same rgb at 32%, so
   the fill and the stroke in any one of these strings are one colour at two
   depths rather than two colours that have to be kept in agreement. They are
   literal for the reason the reds above are literal, and they are DARK for the
   reason set out at the top: the ground is paid for by the item art it makes
   readable, and a red bright enough to announce itself stops paying.
   ========================================================================== */
.cell {
  /* empty -- 1.0px, red at 0.30, on the HOLLOW ground. Present, and saying
     nothing else: 0.28 of a red-black is a warm shade over the street rather
     than a plate on it, which is what an empty socket should be next to a full
     one. At this alpha the hue is barely a cast, and that is correct -- an empty
     slot is the one cell with nothing to make legible. */
  --cell-empty: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23e8434f" stroke-opacity="0.70" stroke-width="1.4"/></svg>');
  /* occupied -- 1.4px at rest, the same weight the menu's resting row carries,
     on the PLATE. The colour is this surface's red at 12%; the 0.78 is
     `--op77-panel-quiet`'s alpha, kept when the hue changed because it is the
     token file's own ceiling for a fill that is not carrying body copy -- enough
     to hold an item picture against a white plaza, not enough to become a panel.
     This is the ground thirty-nine cells out of forty are standing on, so it is
     the one value here that had to stay a shadow first and a red second. */
  --cell-full: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23e8434f" stroke-opacity="0.70" stroke-width="1.4"/></svg>');
  /* hover -- 1.8px, DENSER not brighter, it does not bloom, and its ground is the
     SAME plate as at rest. The pointer is a frame event, so the frame answers it
     alone; a ground that also moved would make the two channels one again. */
  --cell-hover: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23c8202e" stroke-width="1.8"/></svg>');
  /* drop target -- 2.4px, lit, the only cell on the grid that blooms, and the
     only one standing on the SLAB: the same red as every other ground, carried
     up to 32% and 0.90. Hue cannot separate it now that the whole grid is red,
     so DENSITY and DEPTH do: it is the only ground the street does not come
     through and the only one pitched at the lit frame standing on it, which
     makes one CLOSED cell on a wall of windows. That is the literal thing being
     said -- the stack lands here. It is `.ground`'s over-state ground too, and
     the two must move together if either is ever retuned. */
  --cell-over: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%234a1519" fill-opacity="0.90" stroke="%23ff3b47" stroke-width="2.4"/></svg>');
  /* dragged -- four corner brackets and NO edges. Every stroke lives inside a
     corner tile, because anything drawn outside one lands in a stretched edge
     slice and would tile down the whole side. The top-right bracket IS the
     chamfer, which is what keeps the broken frame the same shape as the closed
     one. Its ground is the HOLLOW one, and that is not a compromise: a vacated
     slot is about to be empty, so it stands on what an empty slot stands on. It
     is carried by a SEPARATE unstroked path ahead of the bracket group, because
     the brackets are four open strokes and a fill on those would close four
     shapes that are meant to stay open. */
  --cell-drag: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%231c0809" fill-opacity="0.28" stroke="none"/><g fill="none" stroke="%23ff6b78" stroke-width="1.6"><path d="M0.5 5.5V0.5H5.5"/><path d="M13.5 0.5L19.5 6.5"/><path d="M19.5 13.5V19.5H13.5"/><path d="M0.5 14.5V19.5H5.5"/></g></svg>');

  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  box-sizing: border-box;
  height: 100%;
  padding: var(--op77-space-1);
  /* STILL NO `background`, ON ANY STATE -- and a cell is nonetheless no longer
     transparent. The ground arrives with the frame, through the `fill` keyword
     on `border-image-slice` below; the header says why it exists, whose call it
     was and why it is painted this way rather than as a property of its own. */
  color: var(--red-idle, rgba(232, 67, 79, 0.62));
  /* THE INK STAYS, and the ground does not make it redundant: the plate is a
     low-alpha wash and not an opaque panel, so a glyph in a cell is still half
     on the street. They do different jobs at different scales -- the plate buys
     a 50px PICTURE its contrast, which no text-shadow can, and the ink buys a
     9px LETTER its edge, which no 0.78 wash can.
     One declaration: `text-shadow` inherits, so the count, the rounds, the name
     and the mass all take it from here -- and the value itself comes from the
     surface, so the grid and the panel around it are in the same ink. */
  text-shadow: var(--ink, 0 1px 2px rgba(0, 0, 0, 0.95), 0 0 9px rgba(0, 0, 0, 0.8));
  border: 1px solid transparent;
  border-image-source: var(--cell-empty);
  /* `fill` paints the ninth tile -- the middle one, the ground. Without it the
     eight edge tiles draw the frame and the centre stays empty, which is what
     this said before the owner asked for a background. */
  border-image-slice: 6 fill;
  border-image-width: 6px;
  /* THE BLACK IS IN THE SPRITE, and this is where it stopped being a box-shadow.

     It was an outset `var(--dark)` on the cell box, and the comment here argued
     that being "square where the frame is chamfered... at this blur reads as the
     corner darkening rather than as a second shape". It does not: the owner
     picked it out on sight, on these cells and on every other chamfered element
     in the runtime. An outset shadow follows the BORDER BOX, so it repaints
     exactly the corner the chamfer just cut and squares it back up.

     Every `--cell-*` sprite now carries a wide black under-stroke on the same
     path as the red one, so the separation follows the diagonal by construction.
     3.5 rather than the 4.5 the full-size frames take: a cell's
     `border-image-width` is 6px against a 20px sprite, so its stroke is already
     being scaled up relative to theirs.

     The drop target's bloom stays a `box-shadow`: a wide blur has no edge for
     the chamfer to disagree with. */
  /* The whole grid is one scroll container; a cell must not be a drag source for
     the browser's own drag, which fights the pointer tracking. */
  user-select: none;
  touch-action: none;
  /* IT CUTS, IT DOES NOT FADE. `border-image-source` is not an animatable
     property, which is exactly right here: the frame swaps on the frame the
     state changes. Only the two continuous values transition. */
  transition:
    color var(--op77-dur-fast) linear,
    opacity var(--op77-dur-fast) linear;
}

.cell.filled {
  color: var(--red-text, #e8646d);
  border-image-source: var(--cell-full);
  cursor: grab;
}

/* --- HOVER: denser red, heavier stroke, no bloom -------------------------- */
.cell.filled:hover:not(.over):not(.dragging) {
  color: var(--red-deep, #c8202e);
  border-image-source: var(--cell-hover);
}

/* --- TARGET: lit, heaviest, and the one thing on the grid that blooms -----
   `selected` rides the same frame: Lua sends 0 for it today, and a cell the
   runtime has chosen and a cell the pointer is over mean the same thing to the
   eye -- this is where the stack lands. */
.cell.over,
.cell.selected {
  color: var(--red, #ff3b47);
  border-image-source: var(--cell-over);
  /* Replaces the dark shadow above; never stacked with it. A box-shadow and not
     a `filter`, because a filter on a grid cell gives that cell its own backing
     store inside a surface that repaints over live gameplay -- forty of them. */
  box-shadow: var(--bloom, 0 0 18px -4px rgba(255, 59, 71, 0.55));
}

/* --- DRAGGED: the frame BREAKS. ------------------------------------------
   Not a step on the weight ramp -- a different shape class, so it reads apart
   from hover and from the target no matter which of them is also on screen. The
   dark shadow goes with the edges: there is no closed box left to separate. */
.cell.dragging,
.cell.dragging:hover {
  color: var(--red-hi, #ff6b78);
  border-image-source: var(--cell-drag);
  box-shadow: none;
  cursor: grabbing;
}

/* What is left in a vacated slot is the brackets. */
.cell.dragging .art,
.cell.dragging .count,
.cell.dragging .rounds,
.cell.dragging .wear,
.cell.dragging .foot {
  opacity: 0.3;
}

/* A cell whose item the active tab does not gather. It keeps its frame -- the
   slot is still there and still a legal drop -- and loses its content. */
.cell.muted {
  opacity: 0.26;
}

/* =============================================================================
   WHAT IS IN A CELL
   ========================================================================== */

/* The hotbar cap. Mono, in the frame's own colour, so it restates on hover and
   on the target without a declaration of its own. */
.key {
  position: absolute;
  top: 3px;
  left: 5px;
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: currentcolor;
  opacity: 0.6;
}

.cell.filled .key {
  opacity: 1;
}

.art {
  position: absolute;
  inset: 13px 7px 26px;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
  transition: opacity var(--op77-dur-fast) linear;
}

/* No drop-shadow on the picture: a `filter` is allowed on an icon and this is a
   50px image, forty of them in a window. The items ship with their own contrast. */
.art img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

/* The fallback when a picture will not load. Display face, the cell's colour. */
.initials {
  font: 700 var(--op77-fs-title) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  color: currentcolor;
  opacity: 0.75;
}

.cell.weapon .initials {
  opacity: 1;
}

/* The stack count reads WHITE and the rounds read red: two numbers in the same
   corner region of the same cell, and the only way to tell them apart with no
   fill behind either is for them not to be the same colour. White is also the
   honest choice for the count -- it is the one number here that is not a
   property of the frame's state. */
.count {
  position: absolute;
  top: 3px;
  right: 6px;
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
  transition: opacity var(--op77-dur-fast) linear;
}

.rounds {
  position: absolute;
  right: 6px;
  bottom: 24px;
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: currentcolor;
  font-variant-numeric: tabular-nums;
  transition: opacity var(--op77-dur-fast) linear;
}

/* The condition rule. Two pixels of stroke, which is what the menu's separator
   is: a rule, not a fill. It is also the only mark in a cell that carries no
   text-shadow, because it carries no text -- and it carries a READING, so losing
   it over a blown-out plaza loses information rather than structure. It gets the
   tight dark pass as a box-shadow. The 1px structural hairlines elsewhere on the
   surface deliberately do not: they say where things are, not what they are.

   IT IS NOT DIVIDED, and the two load rules on the panels are. The notches there
   are a 1px mask on a 4px bar; this one is 2px tall inside a 90px square, so ten
   divisions of it would be a dotted line rather than a count -- and there is
   nothing to count anyway. A load is a quantity the player is managing and reads
   off in steps; condition is a state, and what it has to say is which of the
   three colours it is. Same object, two sizes, one of them below the size at
   which a division means anything. */
.wear {
  position: absolute;
  left: 5px;
  right: 5px;
  bottom: 22px;
  height: 2px;
  background: var(--red-track, rgba(232, 67, 79, 0.22));
  box-shadow: var(--ink-tight, 0 1px 2px rgba(0, 0, 0, 0.95));
  transition: opacity var(--op77-dur-fast) linear;
}

.wear i {
  display: block;
  height: 100%;
  background: var(--red-idle, rgba(232, 67, 79, 0.62));
}

.wear.worn i {
  background: var(--red-hi, #ff6b78);
}

/* SPENT READS WHITE, and heavier, for the same reason a failure does: red is the
   voice of this whole surface, so red cannot also be the alarm. It is the SAME
   hot rung `.room` calls `--red-hot` and the load rule's `full` state uses, and
   it was the one colour in this file still spelling that rung out by hand. */
.wear.spent i {
  background: var(--red-hot, #ffa8ae);
}

.foot {
  display: flex;
  align-items: baseline;
  gap: var(--op77-space-1);
  min-width: 0;
  pointer-events: none;
  transition: opacity var(--op77-dur-fast) linear;
}

.name {
  flex: 1 1 auto;
  min-width: 0;
  font: 400 var(--op77-fs-micro) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: currentcolor;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.cell.filled:hover .name,
.cell.over .name,
.cell.selected .name {
  color: var(--op77-text);
}

.mass {
  flex: none;
  font: 400 var(--op77-fs-micro) / 1.2 var(--op77-font-mono);
  color: currentcolor;
  opacity: 0.75;
  font-variant-numeric: tabular-nums;
}
</style>
