<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { GLYPHS } from '@/modules/target/glyphs'

/**
 * THE MENU -- port of `opx77_menu/web/{index.html,menu.css,menu.js}`.
 *
 * The strip is a RENDERER and nothing else, exactly as the original was: Lua owns the
 * navigation stack, the cursor and the window of rows, and `opx:menu:frame` is the
 * window it decided to draw. Nothing here moves a cursor, flips a checkbox or resolves
 * a submenu -- see `opx77_menu/docs/ARCHITECTURE.md`, "Navigation", where every one of
 * those lives in `client/model.lua`.
 *
 * ONE THING MOVED, and it had to. The original page was created on the `hud` layer
 * precisely so it could never be focused, and Lua read the six keys itself through
 * `Open77.input.isDown` with its own 260ms/55ms repeat machine. This surface DOES take
 * focus, so the keystrokes now land here first -- which makes the page the only thing
 * that can see them. It forwards each one as an intent (`opx:menu:key`) and waits to be
 * told what it meant, which is the same division of labour by a different route. The
 * repeat machine is gone with it: the browser's own key repeat is the same edge
 * detector, and `event.repeat` rides along so Lua can still tell a press from a hold.
 *
 * ── DESIGN PASS 01 ──────────────────────────────────────────────────────────
 *
 * THIS SURFACE DRAWS ITS OWN FRAME AND ITS OWN ROWS. It used `OpPanel` and `OpRow`,
 * and they are gone from here on purpose, not by accident: those two are shared with
 * prompts, target, panel and the entry form, and changing them changes every surface
 * at once. The menu is the surface the new look is being settled on, so it carries a
 * local copy while that happens. When the pass is agreed the frame and the row go back
 * into `design/`, every surface takes them, and this local copy is deleted. A duplicate
 * that nobody has decided to keep is the cheapest thing in this file to remove.
 *
 * AUGMENTED UI IS NOT USED HERE, for three reasons that are structural rather than
 * aesthetic:
 *
 *   1. `--aug-border-bg` is ONE colour on all four sides with no per-side form, so a
 *      lit leading arete and a shadowed trailing one -- which is the entire depth of
 *      this design -- cannot be expressed as its border at all.
 *   2. It draws with the element's own `::before` and `::after`. This file already
 *      said so, about the scroll rail: "an augmented element's own pseudo-elements
 *      belong to Augmented UI". Those two are now spent on the accent rule and the
 *      registration ticks, which is a better use of them.
 *   3. `clip-path` does the corners in one property, needs no pseudo-element, and --
 *      the part that matters -- CONTAINS an inset shadow instead of shearing it off,
 *      which is the documented failure of an outset shadow under a clip.
 *
 * Nothing about the protocol changed. Same channels, same handle guard, same keys,
 * same `choose` intent. Only what the player sees.
 */

/** Lua's handle, echoed back untouched. Never coerced -- an integer must stay one. */
type Handle = string | number

interface Slot {
  /** The row's ABSOLUTE index in the level, which is also the v-for key. */
  index: number
  /** Position within the window, for the open stagger. */
  at: number
  label: string
  /** A glyph name from the closed set Lua validates against, or '' for none. */
  icon: string
  value: string
  /** `>` descends, `<>` means LEFT and RIGHT change the value beside it. */
  mark: string
  rule: boolean
  /** A separator with no caption: pure space, per menu.css `.rule.blank`. */
  blank: boolean
  off: boolean
  on: boolean
  /** `undefined` means no checkbox at all, not an unchecked one. */
  checked: boolean | undefined
}

/** The six keys of `opx77_menu/client/input.lua`, as the browser names them. */
const KEYS: Record<string, string> = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Enter: 'enter',
  Backspace: 'back'
}

const ANCHORS: Record<string, string> = {
  'top-left': 'anchor-top-left',
  'top-right': 'anchor-top-right',
  'left': 'anchor-left',
  'right': 'anchor-right'
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const hint = ref('')
const slots = ref<Slot[]>([])
const first = ref(1)
const total = ref(0)
const anchor = ref('anchor-top-left')
const focusMode = ref('full')
const closable = ref(true)
const width = ref(340)
const maxHeight = ref(56)

/** Right-anchored strips read the leading edge as the right edge, per menu.css. The
    curve follows it: a strip on the right recedes the other way. */
const railEnd = computed(() => anchor.value.endsWith('right'))

/* NEITHER THE RAIL NOR THE COUNTER SURVIVES. menu.css drew a track and a thumb at the
   window's proportions; pass 02 replaced it with a `03-09/24` readout in the header;
   the header is gone now and the readout with it. `first` and `total` are still read
   off every frame because Lua sends them and they cost nothing to hold -- but the strip
   says where the window sits by what it is showing, and nothing else. */

/** The paths of one glyph, empty for a row that carries none and for a name this page
    does not know. The set is CLOSED and Lua refuses an item naming anything outside it,
    so an empty answer here means a row with no icon, never a silent typo.

    Imported from the target module rather than re-declared: it is one closed set shared
    by two surfaces. It belongs in `design/` and moves there when this pass is promoted. */
function paths(name: string): string[] {
  return (name && GLYPHS[name]) || []
}

const stripStyle = computed(() => `width: ${width.value}px; max-height: ${maxHeight.value}vh`)

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

/** A payload for a handle that is not the open one is DROPPED, never applied. */
function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function readConfig(payload: Payload): void {
  anchor.value = ANCHORS[text(payload.anchor)] ?? ANCHORS['top-left']
  const wide = num(payload.width)
  if (wide > 0) width.value = Math.round(wide)
  const tall = num(payload.maxHeight)
  if (tall > 0) maxHeight.value = Math.round(tall)
}

function readFrame(payload: Payload): void {
  hint.value = text(payload.hint)
  first.value = Math.max(1, num(payload.first, 1))
  total.value = num(payload.total)

  const rows = list<Payload>(payload.rows)
  slots.value = rows.map((row, at) => {
    const rule = row.rule === true
    const label = text(row.label)
    return {
      index: first.value + at,
      at,
      label,
      icon: rule ? '' : text(row.icon),
      value: rule ? '' : text(row.value),
      mark: row.arrow === true ? '>' : row.spin === true ? '‹›' : '',
      rule,
      blank: rule && label === '',
      off: row.off === true,
      on: row.on === true,
      checked: row.check === true && !rule ? row.ticked === true : undefined
    }
  })
}

/** Blanked on hide, not on the next open: a frame arriving during the fade-out would
    otherwise show the previous menu's rows. Straight from menu.js `hide()`. */
function blank(): void {
  open.value = false
  slots.value = []
  hint.value = ''
  total.value = 0
}

/* Focus is held for exactly as long as a menu is open, and released by whatever ends it
   -- Lua's close, or this module being unmounted by ModuleHost after a throw. A module
   that died holding focus is a player who cannot move. */
let release: (() => void) | undefined

function keyDown(event: KeyboardEvent): void {
  // Escape belongs to bridge/focus.ts, which handles it in the capture phase and calls
  // `onEscape` below. Reading it here as well would send the intent twice.
  if (event.key === 'Escape') return
  const key = KEYS[event.key]
  if (key === undefined) return
  event.preventDefault()
  emit('opx:menu:key', { handle: handle.value, key, repeat: event.repeat === true })
}

function listen(on: boolean): void {
  if (on) window.addEventListener('keydown', keyDown)
  else window.removeEventListener('keydown', keyDown)
}

useBridge('opx:menu:open', (payload: Payload) => {
  guard('menu:open', () => {
    if (!isHandle(payload.handle)) return
    // A second open replaces the first rather than stacking: the resource allows one
    // menu at a time and the previous handle is dead the moment this one arrives.
    release?.()
    handle.value = payload.handle
    readConfig(payload)
    readFrame(payload)
    open.value = true

    // HOW THIS MENU TAKES INPUT. `full` is what every menu did before the option
    // existed, and taking the keyboard is taking the movement keys -- so a menu meant
    // to sit open while the player walks asks for `cursor` and is navigated by
    // pointing at rows. The keydown listener is only worth installing when the
    // keystrokes can actually reach this page.
    focusMode.value = text(payload.focus, 'full')
    closable.value = payload.closable !== false
    listen(focusMode.value === 'full')

    if (focusMode.value !== 'none') {
      release = acquireFocus({
        id: 'menu',
        // An INTENT. The page does not close itself: Lua owns the close reason
        // (`pause`, `back`, `item`, ...) and answers with `opx:menu:close`. A menu
        // its owner declared unclosable gets no Escape handler at all, so the key
        // falls through to the focus stack, which releases nothing it does not own.
        onEscape: closable.value
          ? () => emit('opx:menu:dismiss', { handle: handle.value })
          : undefined
      })
    }
  }, undefined)
})

useBridge('opx:menu:frame', (payload: Payload) => {
  guard('menu:frame', () => {
    if (!mine(payload)) return
    readFrame(payload)
  }, undefined)
})

useBridge('opx:menu:close', (payload: Payload) => {
  guard('menu:close', () => {
    // A close with no handle closes whatever is open; one naming a dead handle is a
    // late message about a menu that has already gone and is dropped.
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    blank()
    listen(false)
    release?.()
    release = undefined
  }, undefined)
})

onUnmounted(() => {
  listen(false)
  release?.()
})

/** The cursor, pointed at. Lua re-resolves the index and decides what landing there
    means -- this says where the player pointed, never what happened. */
function choose(row: Slot): void {
  if (row.rule || row.off) return
  emit('opx:menu:choose', { handle: handle.value, index: row.index })
}
</script>

<template>
  <div class="strip" :class="[anchor, { open, end: railEnd }]" :style="stripStyle">
    <div class="bay">
      <!-- NO HEADER. The reference has none: its main menu is a bare column of
           framed rows under a logo, and its character panel is a bare column of
           framed rows under nothing at all. The title and the breadcrumb Lua
           sends still arrive and are simply not drawn -- so a nested screen no
           longer says where it is, which is the cost of this and is deliberate. -->
      <div class="bay-inner">
        <ul class="list">
          <!-- A KEYED v-for, where the original reused a fixed window of <li> slots.
               Its reason -- "a fresh element has no previous computed style, so menu.css
               could not transition it" -- is satisfied better here: the key is the row's
               ABSOLUTE index, so a row that stays in the window across a frame keeps its
               element even when the window scrolls under it, and the fill and tick
               transitions run. The original's slot reuse kept element 3 alive while the
               row standing in it changed, which transitioned the wrong thing. -->
          <li
            v-for="row in slots"
            :key="row.index"
            class="slot"
            :class="{ gap: row.blank }"
            :style="`--slot: ${row.at}`"
          >
            <!-- A separator with no caption draws nothing at all: the <li> is the space. -->
            <div v-if="row.rule && !row.blank" class="sep">{{ row.label }}</div>

            <div
              v-else-if="!row.blank"
              class="row"
              :class="{ on: row.on && !row.off, off: row.off }"
              role="button"
              :aria-disabled="row.off"
              @click="choose(row)"
            >
              <!-- A GLYPH WHERE THE ORDINAL WAS. `01 02 03` told the player which row
                   they were on, which the cursor already says louder; an icon says what
                   the row IS, which nothing else on the strip does. The column is held
                   open whether or not this row carries one, so a menu that ices half its
                   rows still has its labels on one x. -->
              <span class="glyph" aria-hidden="true">
                <svg v-if="paths(row.icon).length" viewBox="0 0 24 24">
                  <path v-for="(d, at) in paths(row.icon)" :key="at" :d="d" />
                </svg>
              </span>
              <span class="label">{{ row.label }}</span>
              <span v-if="row.value" class="value">{{ row.value }}</span>
              <span
                v-if="row.checked !== undefined"
                class="check"
                :class="{ ticked: row.checked }"
                role="checkbox"
                :aria-checked="row.checked"
              >
                <!-- The tick draws in after the fill lands and wipes instantly: a
                     stroke-dashoffset transition with a delay, straight out of menu.css. -->
                <svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg>
              </span>
              <span v-if="row.mark" class="mark">{{ row.mark }}</span>
            </div>
          </li>
        </ul>

        <!-- NO STATUS LINE. It was a second, weaker notification channel: a
             confirmation written into a footer only a player already looking at
             the menu could see, expiring on a timer nobody was watching. Lua
             reroutes `SetStatus` to a toast now, so the same line still reaches
             the player -- somewhere they are actually looking. The hint stays:
             it describes the row under the cursor and belongs to the strip. -->
        <div v-if="hint" class="foot">
          <p v-if="hint" class="hint">{{ hint }}</p>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED.

   Drawn against IDEDARY/Bevypunk, a Cyberpunk UI recreation whose screenshots
   settle three things this surface had wrong:

     1. NOTHING IS FILLED. Not even the chosen row. In the reference the active
        item is the same 1px outline as every other one -- it goes bright and it
        BLOOMS, and that is the whole of its state. Pass 01 filled the chosen row
        with accent; that fill was the last background on the surface and it is
        gone.
     2. A ROW IS A CLOSED BOX, not a left rule. Every control in the reference is
        a full thin frame with the top-right corner chamfered.
     3. The technical filler is not decoration. The reference ships
        `UNAUTHORIZED ACCESS / PLEASE CONTACT LOCAL NETRUNNER / DO NOT PROCEED
        FURTHER` under a real menu. The row index and the window readout here do
        the same job while being true.

   WHY `border-image` AND NOT `clip-path` FOR A ROW. A clip cuts the painted
   result, so a bordered box under one loses its stroke exactly along the
   diagonal -- the chamfer arrives as a GAP in the outline. Bevypunk solves it
   with 9-slice sprites; this solves it the same way, with a 9-slice SVG data URI
   whose corner tiles carry the chamfer at a fixed size while the edge tiles
   stretch. One property (`border-image-source`) swaps the whole frame's colour
   on a state change, and the geometry never distorts with the row's width.

   WHY IT IS ALSO FASTER THAN PASS 01. Per row, pass 01 paid for a `clip-path`
   mask, a two-shadow bevel, a background fill and a `transform-style:
   preserve-3d` that gave every row its own 3D rendering context. All four are
   gone. What a row changes now is `border-image-source` and `color`. The whole
   surface holds ONE clip-path (the frame), ONE composited rotation, and ZERO
   fills.
   ========================================================================== */

/* --- THE RED --------------------------------------------------------------
   Local to this surface on purpose. `.op-theme-city` on <html> makes
   `--op77-accent` Night City yellow for EVERY surface, and repainting the whole
   HUD is a separate decision from settling the menu. When this pass is agreed,
   these move into that class and this block is deleted.

   The three steps are dim -> deep -> lit, and the middle one is the pointer.
   "Darker on hover" taken as DENSER: a red that loses brightness on a night
   street loses the row with it, so hover drops the pale wash of the resting
   state for a saturated blood red, and the chosen row is the only one that
   blooms. Invert `--red-deep` and `--red` if the literal reading was wanted. */
.strip {
  --red:      #ff3b47;                    /* chosen: lit, and the only bloom  */
  --red-deep: #c8202e;                    /* HOVER: denser, no bloom          */
  --red-idle: rgba(232, 67, 79, 0.62);    /* at rest                          */
  --red-glow: rgba(255, 59, 71, 0.55);

  /* The 9-slice frames. 24x24, 8px corner tiles, the chamfer living entirely
     inside the top-right tile so stretching an edge can never skew it. */
  --frame-idle: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23e8434f" stroke-opacity="0.7" stroke-width="1.4"/></svg>');
  --frame-hover: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23c8202e" stroke-width="1.8"/></svg>');
  --frame-on: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="%234a1519" fill-opacity="0.9" stroke="%23ff3b47" stroke-width="2.4"/></svg>');
  --frame-off: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="%231c0809" fill-opacity="0.78" stroke="%23aed3e0" stroke-opacity="0.14"/></svg>');
}

/* =============================================================================
   THE STRIP -- carries the perspective so the frame inside it is the plane that
   tilts. On the strip and not the frame: perspective on the frame would give
   every descendant its own vanishing point.
   ========================================================================== */
.strip {
  position: absolute;
  display: flex;
  max-width: calc(100vw - var(--op77-inset-x) * 2);
  opacity: 0;
  pointer-events: none;
  perspective: var(--op77-persp);
  /* Nothing inside can affect layout or paint outside it, so the compositor
     never has to consider the rest of the surface when one row changes. */
  contain: layout paint style;
  transition: opacity var(--op77-dur-fast) linear;
}

.strip.open {
  opacity: 1;
  pointer-events: auto;
}

.anchor-top-left,
.anchor-left {
  left: var(--op77-inset-x);
  --pop: 10px;
  --tilt: var(--op77-tilt);
  --origin: left center;
}

.anchor-top-right,
.anchor-right {
  right: var(--op77-inset-x);
  --pop: -10px;
  --tilt: calc(var(--op77-tilt) * -1);
  --origin: right center;
}

.anchor-top-left,
.anchor-top-right {
  top: var(--op77-inset-y);
}

/* The mid band: below the minimap and above the control hints. */
.anchor-left,
.anchor-right {
  top: 33vh;
}

/* =============================================================================
   THE FRAME -- no fill.
   ========================================================================== */
.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  /* THE DIAL IS BACK AT 0, AND THE GROUND MOVED TO THE ROWS. It was turned up
     to the house plate and the owner answer was precise: not the panel, the
     buttons. That is the better read anyway -- a plate behind the whole bay
     fills the gaps between the rows and the empty space under the last one, so
     the menu becomes a window; a plate per row fills exactly what carries words
     and leaves the surface open between them.

     The dial stays, and it stays at 0: it is still one number to turn if a bay
     ever has to be closed over a plaza. Its rgb moves to the 28,8,9 of
     `--op77-plate` so that turning it up lands on the same ground the rows are
     already on, instead of on a near-match. */
  background: rgba(28, 8, 9, var(--op77-menu-veil, 0));
  transform-origin: var(--origin, left center);
  transform: rotateY(var(--tilt, 0deg));
  clip-path: polygon(
    0 0,
    calc(100% - var(--op77-cut-lg)) 0,
    100% var(--op77-cut-lg),
    100% 100%,
    var(--op77-cut-lg) 100%,
    0 calc(100% - var(--op77-cut-lg))
  );
  /* The frame is the one place a clip and a stroke can live together, because
     an INSET shadow is painted over the padding box and the clip then trims it
     to the chamfer instead of shearing an outset shadow off the element. The
     two aretes are the entire depth of the design. */
  /* ONE arete, on the leading corner, and nothing on the trailing one. The pair
     was the bevel of a solid panel; on a frame with nothing inside it the dark
     half only ever read as a smudge down the right edge. */
  box-shadow:
    inset 1px 1px 0 var(--op77-edge-hi),
    inset 0 0 0 1px var(--red-idle);
}

/* Mirrored for a right-anchored strip: the cuts and the aretes follow the
   leading edge, which over there is the right one. */
.strip.end .bay {
  clip-path: polygon(
    var(--op77-cut-lg) 0,
    100% 0,
    100% calc(100% - var(--op77-cut-lg)),
    calc(100% - var(--op77-cut-lg)) 100%,
    0 100%,
    0 var(--op77-cut-lg)
  );
  box-shadow:
    inset -1px 1px 0 var(--op77-edge-hi),
    inset 0 0 0 1px var(--red-idle);
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  max-height: inherit;
}

/* The interlace. It is over the panel in every frame of the reference and it is
   what stops an unfilled surface reading as a web page floating in the air. One
   static gradient on a pseudo-element nothing else was using, no transition, so
   it costs a single paint for the life of the menu. */
.bay-inner::before {
  content: "";
  position: absolute;
  inset: 0;
  z-index: 2;
  pointer-events: none;
  background: repeating-linear-gradient(
    to bottom,
    rgba(255, 59, 71, 0.05) 0 1px,
    transparent 1px 3px
  );
}

/* =============================================================================
   THE LIST -- it never scrolls: Lua sends the window it wants drawn.
   ========================================================================== */
.list {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin: 0;
  /* The trailing padding is the chosen row's runway: it leaves the column by
     `--pop` and the perspective scales it slightly wider on the way out, and
     both have to land inside the frame, because the frame is a clip-path. */
  padding: var(--op77-space-3) var(--op77-space-4) var(--op77-space-3)
    calc(var(--op77-space-3) + var(--op77-rule));
  list-style: none;
  min-height: 0;
}

.slot {
  display: flex;
  min-width: 0;
}

/* A separator with no caption is pure space: the gap, doubled. */
.slot.gap {
  height: var(--op77-space-1);
}

/* =============================================================================
   A ROW -- a closed 1px frame with a chamfered top-right corner, and text.
   There is nothing behind it and there never will be.

   `border-image-width` is 8px while `border-width` is 1px: the image draws its
   8px corner tiles while layout only reserves one, so the chamfer is full size
   and the row still sits on a 1px box.
   ========================================================================== */
.row {
  position: relative;
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op77-space-3);
  min-width: 0;
  padding: var(--op77-space-2) var(--op77-space-3) calc(var(--op77-space-2) + 1px);
  color: #e8646d;
  white-space: nowrap;
  cursor: pointer;
  /* THE GROUND, AND IT IS HERE RATHER THAN ON THE BAY. This is the owner's call
     and it is the right one: the bay is mostly the space BETWEEN rows, so a
     plate on it fills what carries nothing and turns the strip into a window.
     A row is a button -- it has an outline, it has padding, it is the shape the
     eye lands on -- so the floor goes exactly under the words and the surface
     stays open around them.

     The chosen row goes up to `--op77-plate-lit` and nothing else changes: with
     a fill on every row, a brighter fill is what "chosen" now means, on top of
     the lit frame and the pop it already had. */
  /* THE GROUND IS IN THE SPRITE, not behind it. A `background` fills the BORDER
     BOX, so it painted the very corner the chamfer had just cut off and squared
     it back up -- the same shape mismatch an outset shadow has, and the reason
     both are gone from every chamfered element. `fill` makes the border-image
     paint its middle tile too, so the ground IS the cut shape. The chosen row
     changes ground by changing sprite, like every other state on this row. */
  /* The ink stays, plate or no plate: the plate holds the row against a bright
     street, the shadow keeps each glyph's own edge crisp on top of it. A
     text-shadow INHERITS, so this one declaration carries the label, the value
     and the affordance mark.

     Two passes, not one: the tight dark pass gives an edge its contrast, the wide
     soft pass lifts the row off a blown-out backdrop. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
  border: 1px solid transparent;
  border-image-source: var(--frame-idle);
  border-image-slice: 8 fill;
  border-image-width: 8px;
  transition:
    color var(--op77-dur-fast) linear,
    transform 120ms var(--op77-ease);
}

/* THE FRAME'S SHADOW LIVES IN THE SPRITE, not on the box. It was an outset
   `box-shadow` here, and an outset shadow follows the BORDER BOX -- so on a row
   whose visible edge is a `border-image` with a cut corner, the blur ran straight
   past the diagonal and squared off the one corner the whole shape is about. The
   comment that used to sit here called that "the corner darkening rather than a
   second shape". It was not: the owner spotted it immediately.

   A wide black stroke under the coloured one, on the same path inside the sprite,
   traces the chamfer exactly. It is rasterised once when the image decodes, so it
   costs less than the shadow it replaces, and a state change still swaps exactly
   one property. */

/* The column is held open by the span whether or not a glyph is inside it, so a
   menu that ices half its rows still has every label on one x. */
.glyph {
  flex: none;
  display: block;
  width: 16px;
  height: 16px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  /* The stroke follows the row colour, so the whole icon restates on hover and
     on the chosen row without a second declaration anywhere. */
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
  /* A stroke takes no text-shadow. One drop-shadow on a 16px icon, nine of them
     on screen at the very most, is the cheapest filter this surface could be
     asked to carry. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
}

.label {
  flex: 0 1 auto;
  min-width: 0;
  font: 700 var(--op77-fs-lead) / 1.25 var(--op77-font-display);
  letter-spacing: 0.04em;
  text-transform: uppercase;
  overflow: hidden;
  text-overflow: ellipsis;
}

.value {
  flex: none;
  margin-left: auto;
  max-width: 45%;
  font: 500 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  opacity: 0.88;
  font-variant-numeric: tabular-nums;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* The affordance column, always last so every mark lands at the same x. */
.mark {
  flex: none;
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
}

/* The checkbox is a frame too, and the tick is a stroke -- the one fill left on
   the surface is 13 pixels square, and it is a mark rather than a backdrop. */
.check {
  flex: none;
  width: 13px;
  height: 13px;
  border: 1px solid currentcolor;
  transition: background var(--op77-dur-fast) linear;
}

/* With no value beside it the checkbox takes the value column's job of pushing right. */
.value + .check,
.glyph + .label + .check {
  margin-left: auto;
}

/* AND WITH NEITHER, THE MARK DOES. A row that only leads somewhere carries a
   glyph, a label and a `>` and nothing else, and without this the arrow sits
   against the last letter of its own label -- where it reads as punctuation
   rather than as the column that says this row opens a list. Every mark on the
   strip lands at the same x whether or not the row beside it has a value. */
.glyph + .label + .mark {
  margin-left: auto;
}

.check svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: currentcolor;
  stroke-width: 2.2;
  stroke-linecap: square;
  stroke-dasharray: 13;
  stroke-dashoffset: 13;
  transition: stroke-dashoffset var(--op77-dur) var(--op77-ease) var(--op77-dur-fast);
}

.check.ticked svg {
  stroke-dashoffset: 0;
}

/* --- HOVER: denser red, no bloom ------------------------------------------- */
.row:hover:not(.off):not(.on) {
  color: var(--red-deep);
  border-image-source: var(--frame-hover);
}

/* --- ON: lit, blooming, and the one thing that leaves the plane -------------
   No fill. The frame goes to full red at a heavier stroke, the text lights, and
   the row steps out of the column by `--pop` and 14px toward the player -- the
   surface's only 3D transform besides the frame's rotation. The bloom is a
   `box-shadow` and not a `filter`: a filter on a row would give that row its own
   backing store inside a surface that repaints over live gameplay. */
.row.on {
  color: var(--red);
  border-image-source: var(--frame-on);
  transform: translate3d(var(--pop, 10px), 0, 14px);
  box-shadow: 0 0 18px -4px var(--red-glow);
}

.row.on .label {
  font-weight: 700;
  letter-spacing: 0.055em;
  text-shadow: 0 0 10px var(--red-glow);
}

.row.on .value {
  opacity: 0.9;
}

.row.on .check.ticked {
  background: var(--red);
}

/* --- OFF ---------------------------------------------------------------- */
.row.off {
  color: var(--op77-text-faint);
  cursor: default;
  border-image-source: var(--frame-off);
}

/* --- a captioned separator: a mono eyebrow and a rule, no frame ---------- */
.sep {
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
  min-width: 0;
  padding: var(--op77-space-3) 0 var(--op77-space-1) var(--op77-space-1);
  font: 600 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--red-deep);
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.95), 0 0 9px rgba(0, 0, 0, 0.8);
}

.slot:first-child .sep {
  padding-top: 0;
}

.sep::after {
  content: "";
  flex: 1;
  height: 1px;
  background: var(--red-idle);
}

/* =============================================================================
   FOOTER
   ========================================================================== */
.foot {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  min-width: 0;
  padding: var(--op77-space-2) calc(var(--op77-space-3) + var(--op77-cut-lg))
    calc(var(--op77-space-2) + var(--op77-cut-lg)) calc(var(--op77-space-3) + var(--op77-rule));
  border-top: 1px solid var(--red-idle);
}

.hint {
  margin: 0;
  /* The one place the strip wraps: a description is a sentence. */
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-body);
  color: var(--op77-text-dim);
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.95), 0 0 9px rgba(0, 0, 0, 0.8);
}

/* =============================================================================
   THE BOOT-IN -- a stutter, not a fade. One shot, and only on elements the keyed
   v-for has just created: a row that survived the last frame does not re-run it.
   Both keyframes touch `opacity` and `transform` only, which the compositor can
   run without a repaint.
   ========================================================================== */
@keyframes plate-in {
  0% {
    opacity: 0;
    transform: translate3d(calc(var(--pop, 10px) * -1), 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(2px, 0, 0);
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0);
  }
}

@keyframes plate-in-on {
  0% {
    opacity: 0;
    transform: translate3d(0, 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(calc(var(--pop, 10px) + 2px), 0, 14px);
  }

  100% {
    opacity: 1;
    transform: translate3d(var(--pop, 10px), 0, 14px);
  }
}

.strip.open .row {
  animation: plate-in 190ms steps(3, end) backwards;
  animation-delay: calc(var(--slot, 0) * 28ms + 40ms);
}

.strip.open .row.on {
  animation-name: plate-in-on;
}
</style>
