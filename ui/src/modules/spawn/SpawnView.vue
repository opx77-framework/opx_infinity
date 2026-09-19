<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useCountdown } from '@/composables/useCountdown'

/**
 * THE SPAWN MENU -- where a character starts.
 *
 * Offered on a world enter the operator's policy says to ask about. Lua opens it with
 * the places to draw and a duration, and the page answers with the ID of one of them;
 * the place itself is the server's to look up, so nothing here can move anybody
 * anywhere the server has not already agreed to. Picking nothing is a real answer --
 * the server places the body where the character's own row already says -- which is
 * why nothing here insists on one.
 *
 * ONE PRESS IS THE CHOICE. Clicking a card sends it -- you do not select and then
 * confirm, because "spawn me at the coast" is one intent and asking for it twice is
 * a menu pretending the first click did not count. The arrow keys plus Enter take the
 * same route for a keyboard, and the confirm control under the grid is the same call
 * again, so the three input paths cannot drift apart.
 *
 * THE MENU DOES NOT CLOSE ON THAT PRESS. It closes when Lua says so -- `spawn:close`,
 * carrying what actually happened -- for the same reason a panel does not select its
 * own item: a page that closed itself would show the player a spawn the server
 * refused, and there is no second chance at this one. The one thing this page decides
 * for itself is which card is highlighted, and that is a receipt for a press already
 * sent rather than a fact about the world.
 *
 * THE COUNTDOWN IS DISPLAY ONLY. It counts down to `Date.now() + timeoutMs` -- the
 * duration the server gave, turned into a local deadline -- and when it reaches zero it
 * does nothing at all. The server is counting the same duration against its own clock,
 * and only that count ends the choice. A page that acted on its own zero would act early
 * on a fast clock and late on a surface the CEF has throttled.
 *
 * ── THE RESTYLE ─────────────────────────────────────────────────────────────
 *
 * This file arrived written against `design/components/*` -- `OpPanel`, `OpRow`,
 * `OpScrim` -- and against the `--op77-*` token set. Neither exists: the shared row
 * components were what coupled five surfaces together in pass 01 and were deleted
 * with it, and the tokens are `--op-*` now. The import alone broke the build, so
 * this is not a restyle of a working page; it is a page that could not be bundled.
 *
 * What it is drawn out of instead is the vocabulary every other surface uses:
 * `.op-bay` for the enclosure, `.op-frame` for a card, `.op-arete` for the lit
 * leading run, `.op-interlace` over what is enclosed, `.op-lift` for the chosen
 * card's bloom, `.op-plane` for the perspective. Per `ui/README.md`, a shape is
 * augmented-ui and a state is one `--aug-border-bg`; NOTHING here writes an accent
 * channel as a literal, because the accent is the operator's -- `design-system/theme.ts`
 * overwrites the triples on `:root` at runtime and a copied `rgba(...)` would simply
 * not follow.
 *
 * A CENTRED SURFACE TAKES NO TILT. `.op-plane > *` defaults `--op-tilt-signed` to
 * 0deg and this page adds no anchor class, so the stage does not rotate: turning a
 * centred plane about its own middle is paper on a spindle, which is the call
 * `FormView` and `InventoryView` both make.
 */

interface Place {
  id: string
  label: string
  district: string
}

const open = ref(false)
const title = ref('')
const about = ref('')
const hint = ref('')
const confirmLabel = ref('')
/** Lua's own caption for the clock. Sent since the module shipped and never drawn. */
const deadlineLabel = ref('')
const places = ref<Place[]>([])
/** Empty until a card is chosen: confirming is deliberate, never a default. */
const chosen = ref('')
const hasTimer = ref(false)
const deadline = ref(0)

const { clock } = useCountdown(deadline)

let release: (() => void) | undefined

/**
 * The card's place in the list, as two digits.
 *
 * TECHNICAL FILLER IS CONTENT -- rule 8 of `ui/README.md`. This is the one mono
 * micro-label on the card and it states something the surface actually knows: which
 * card this is, counted the way the player counts them. It is not invented chrome.
 */
function ordinal(at: number): string {
  return String(at + 1).padStart(2, '0')
}

function blank(): void {
  open.value = false
  places.value = []
  chosen.value = ''
  title.value = ''
  about.value = ''
  hint.value = ''
  confirmLabel.value = ''
  deadlineLabel.value = ''
  hasTimer.value = false
  deadline.value = 0
}

/** Moves the highlight, wrapping. From nothing, it starts at the end it came from. */
function move(delta: number): void {
  const total = places.value.length
  if (total === 0) return
  const at = places.value.findIndex((place) => place.id === chosen.value)
  if (at === -1) {
    chosen.value = delta > 0 ? places.value[0].id : places.value[total - 1].id
    return
  }
  chosen.value = places.value[(at + delta + total) % total].id
}

function confirm(): void {
  // An INTENT. Lua re-derives which place this is and where it is, and this page
  // stays open until the answer comes back on `spawn:close`.
  if (!open.value || chosen.value === '') return
  emit('opx:spawn:choose', { id: chosen.value })
}

/**
 * Clicking a card IS the choice. One click places you; the highlight is the
 * receipt, not a step. The card is picked first so the highlight lands on the
 * row that was pressed even if the answer takes a moment, and the send is the
 * same `confirm` everything else uses -- there is one path to the wire.
 *
 * A second press is not a second choice: the server rate-limits the id it is
 * sent, and the menu is unmounted by the answer either way.
 */
function pick(id: string): void {
  chosen.value = id
  confirm()
}

function onKeyDown(event: KeyboardEvent): void {
  if (!open.value) return
  // A control that has DOM focus handles Enter and Space itself and has already
  // prevented the default by the time this sees the event -- so this is what stops
  // one Enter from confirming twice.
  if (event.defaultPrevented) return

  if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
    event.preventDefault()
    move(1)
    return
  }
  if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
    event.preventDefault()
    move(-1)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    confirm()
  }
}

useBridge('opx:spawn:open', (payload: Payload) => {
  guard(
    'spawn:open',
    () => {
      const rows: Place[] = []
      for (const entry of list<Payload>(payload.locations)) {
        const id = text(entry.id)
        if (!id) continue
        rows.push({ id, label: text(entry.label, id), district: text(entry.district) })
      }
      // No places to draw is not a menu: the server only offers a choice it can
      // serve, so this is a configuration that changed under a live session.
      if (rows.length === 0) return

      places.value = rows
      title.value = text(payload.title)
      about.value = text(payload.about)
      hint.value = text(payload.hint)
      confirmLabel.value = text(payload.confirm)
      deadlineLabel.value = text(payload.deadline)

      const ms = num(payload.timeoutMs)
      hasTimer.value = ms > 0
      deadline.value = ms > 0 ? Date.now() + ms : 0

      chosen.value = ''
      open.value = true

      release?.()
      release = acquireFocus({
        id: 'spawn',
        // THE CHOICE IS MANDATORY, so Escape does nothing on purpose. Supplying a
        // handler at all is the point: without one, bridge/focus.ts releases the
        // owner on Escape and the menu is left on screen with no pointer and no
        // keyboard -- visible, unanswerable, and only the server can end it.
        onEscape: () => {}
      })
    },
    undefined
  )
})

useBridge('opx:spawn:close', (payload: Payload) => {
  guard(
    'spawn:close',
    () => {
      // The reason is Lua's and it has already said it: a toast, in the player's
      // language. This page only takes the menu down.
      void payload
      blank()
      release?.()
      release = undefined
    },
    undefined
  )
})

onMounted(() => {
  window.addEventListener('keydown', onKeyDown)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeyDown)
  release?.()
})
</script>

<template>
  <div class="room op-ink" :class="{ open }">
    <div class="scrim" :class="{ shown: open }" />

    <div class="stage op-plane">
      <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <div class="bay-inner op-interlace">
          <!-- THE HEAD STAYS, where `MenuView` deleted its own. A menu row says what
               it does; a spawn card says only where it IS, and a grid of place names
               with nothing over it is a list rather than a question. The title Lua
               sends is the question, so it is the one piece of chrome this surface
               cannot drop -- the same call `FormView` makes. -->
          <div class="head">
            <div class="head-text">
              <span class="eyebrow op-eyebrow">SPAWN</span>
              <h1>{{ title }}</h1>
            </div>
            <!-- A READOUT IS A LINE OF TYPE, not a control, so it takes no frame:
                 rule 2. Muted, because it is a deadline and not a warning -- and red
                 is this runtime's voice, so a clock in the voice would be shouting
                 from the moment it appeared. -->
            <p v-if="hasTimer" class="clock">
              <span v-if="deadlineLabel" class="clock-label op-eyebrow">{{ deadlineLabel }}</span>
              <span class="clock-value">{{ clock }}</span>
            </p>
          </div>

          <p v-if="about" class="note op-copy">{{ about }}</p>

          <!-- ONE BAY, ELEVEN CARDS. The enclosure is augmented once and each card is
               augmented for its own cut and ground, asking for the border layer alone
               so it is one pseudo-element each rather than two -- which is the rule
               `ui/README.md` states for the inventory's forty cells and is the same
               trade here. The key is the id Lua sent, so a card that survives a frame
               keeps its element and does not replay the stutter under the pointer. -->
          <ul class="grid">
            <li
              v-for="(place, at) in places"
              :key="place.id"
              class="slot op-enter"
              :style="`--op-slot: ${at}`"
            >
              <div
                class="card op-frame"
                :class="{ 'is-on': place.id === chosen, 'op-lift': place.id === chosen }"
                data-augmented-ui="tr-clip border"
                role="button"
                :aria-pressed="place.id === chosen"
                @click="pick(place.id)"
              >
                <span class="index op-eyebrow" aria-hidden="true">{{ ordinal(at) }}</span>
                <span class="card-text">
                  <span class="label op-label">{{ place.label }}</span>
                  <!-- The district, and never the coordinates: what Lua sends is a
                       label and a hint line, and there is nothing here for a page to
                       be tempted to act on. -->
                  <span v-if="place.district" class="district op-value">{{ place.district }}</span>
                </span>
              </div>
            </li>
          </ul>

          <div v-if="hint || confirmLabel" class="foot">
            <p v-if="hint" class="hint op-copy">{{ hint }}</p>
            <!-- THE KEYBOARD'S CARD. A click is already the whole choice, so this
                 exists for the arrow keys: it is where Enter goes, and it says so by
                 lighting the moment the highlight lands on something. Iced until then,
                 because a control that does nothing must not look like one that does. -->
            <button
              v-if="confirmLabel"
              class="confirm op-frame"
              type="button"
              data-augmented-ui="tr-clip border"
              :class="chosen === '' ? 'is-off' : 'is-on'"
              :disabled="chosen === ''"
              @click="confirm"
            >
              {{ confirmLabel }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE SPAWN MENU -- red, outlined, untilted.

   `MenuView.vue` settled the look and `FormView.vue` is that look centred behind
   a scrim, which is what this surface is: one bounded enclosure the player drives
   with the pointer or with four keys, over a world they cannot touch yet. So this
   file takes the bay, the arete, the interlace and the frame from
   `design-system/` and says only what is true of a SPAWN MENU:

     1. IT IS A GRID, NOT A COLUMN. Eleven places read as a map at two abreast and
        as a scroll at one; a menu strip's single column would put the last four
        below the fold of a 1080p surface, and the whole point of the screen is to
        see the choices at once.
     2. THE CHOSEN CARD DOES NOT STEP OUT OF THE COLUMN. `--op-pop` is a lateral
        move away from the anchored edge, and this surface is anchored to none --
        there is no edge for it to step away from, and in a grid it would shunt a
        card into its neighbour. The frame, the ground and the bloom carry the
        state instead, which is `.op-frame.is-on` plus `.op-lift` and nothing local.
     3. THERE IS NO TILT. A centred plane rotated about its own middle sends half
        toward the player and half away. `.op-plane` gives the perspective and the
        containment; no anchor class means `--op-tilt-signed` stays 0deg.

   EVERY COLOUR IS A TOKEN. The accent is the server's -- `modules/theme` sends
   the triples and `design-system/theme.ts` writes them onto `:root` -- so an
   `rgba(232, 67, 79, ...)` written here would be the one surface that ignored an
   operator's accent, with nothing to warn anybody. The only literals below are
   black: the scrim's own ground comes from `--op-plate-quiet` and the ink from
   `--op-ink`.
   ========================================================================== */

/* The wash under the menu. The same one `FormView` draws, and for the same
   reason: this surface takes the cursor and the keyboard, so the world behind it
   has to stop looking like something the player can still act on. `--op-plate-quiet`
   is the house ground at its lightest weight, so a theme that darkens the surface
   darkens this with it. */
.scrim {
  position: absolute;
  inset: 0;
  background: var(--op-plate-quiet);
  opacity: 0;
  transition: opacity var(--op-dur) var(--op-ease);
}

.scrim.shown {
  opacity: 1;
}

.room {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

/* =============================================================================
   THE STAGE -- `.op-plane` carries the perspective, the paint containment and
   the bleed a bloom needs inside it. It is on the WRAPPER and never on the bay:
   on the bay itself every descendant would get its own vanishing point.

   No `.op-anchor-*`: a centred surface takes neither, which is how
   `design-system/surface.css` says "this one does not tilt".
   ========================================================================== */
.stage {
  position: relative;
  display: flex;
  width: min(880px, calc(100vw - var(--op-inset-x) * 2));
  max-height: calc(100vh - var(--op-inset-y) * 2);
}

/* =============================================================================
   THE BAY -- the enclosure. Two opposite corners cut, which reads as a plate
   slid into place; `.op-arete` lights the leading run across the border layer.
   ========================================================================== */
.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  /* THE DIAL IS TURNED ON, with `FormView`'s caveat: the scrim means this bay was
     never the one washing out, so it needs to be told apart from that dim rather
     than held against daylight. Quiet, on `--op-plate`'s own channels, so the
     menu, the form and this are one ground at three weights. */
  background: rgba(var(--op-plate-rgb), var(--op-spawn-veil, 0.58));
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  max-height: inherit;
}

/* =============================================================================
   THE HEAD -- the question, and the clock that ends it. One rule under both,
   which is not an enclosure: it is the only thing relating the question to the
   grid beneath it.
   ========================================================================== */
.head {
  display: flex;
  align-items: flex-end;
  gap: var(--op-space-4);
  min-width: 0;
  /* The trailing edge pays for the chamfer, so a long title never runs under it. */
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg))
    var(--op-space-2) calc(var(--op-space-4) + var(--op-rule));
  border-bottom: 1px solid var(--op-red-idle);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  margin-right: auto;
  min-width: 0;
}

.eyebrow {
  color: var(--op-red-deep);
}

/* The house device. `FormView` draws its own for the same reason: it is two
   characters of type, not a component. */
.eyebrow::before {
  content: "//";
  margin-right: 0.7em;
  color: var(--op-red);
  font-weight: 700;
  letter-spacing: -0.06em;
}

.head h1 {
  margin: 0;
  font: 700 var(--op-fs-head) / 1.1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* The auto-spawn clock: Lua's caption over Lua's number, both as type. */
.clock {
  flex: none;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: var(--op-space-1);
  margin: 0;
}

.clock-label {
  color: var(--op-text-faint);
}

/* Tabular so the digits do not shuffle the header as they tick, and grey rather
   than red: this is context, and grey is what red means when it stops meaning
   anything. */
.clock-value {
  font: 700 var(--op-fs-title) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-dim);
  font-variant-numeric: tabular-nums;
}

/* The sentence under the question. Prose, and the player's rather than an
   instrument's, so it takes the legibility grey. */
.note {
  margin: 0;
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg)) 0
    calc(var(--op-space-3) + var(--op-rule));
  color: var(--op-text-dim);
}

/* =============================================================================
   THE GRID -- two abreast where there is room, one where there is not. Eleven
   cards is two columns of six on a 1080p surface, which is the whole catalogue
   at a glance; below that it degrades to a single scrolling column rather than
   to cards too narrow to carry a place name.
   ========================================================================== */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: var(--op-space-1);
  align-content: start;
  margin: 0;
  padding: var(--op-space-3) var(--op-space-4) var(--op-space-3)
    calc(var(--op-space-3) + var(--op-rule));
  list-style: none;
  min-height: 0;
  overflow: hidden auto;
  /* No scrollbar. There is no OS chrome inside a CEF surface worth drawing, and
     a scrollbar is a second vertical rule beside the bay's own cut edge. */
  scrollbar-width: none;
}

.grid::-webkit-scrollbar {
  display: none;
}

/* THE ENTRANCE IS ON THE SLOT, NOT ON THE CARD, which is the lesson `MenuView`
   paid for: a card's classes change when the highlight moves, and an
   `animation-name` that differs between two states is cancelled and restarted by
   the change -- so both the card being left and the card being landed on would
   replay the stutter from behind their delay and be invisible for the whole wait.
   The <li> is what the keyed v-for creates and its classes say nothing about the
   highlight. */
.slot {
  display: flex;
  min-width: 0;
}

/* =============================================================================
   A CARD -- a control, so it is a closed box: a thin frame with the top-right
   corner chamfered. `.op-frame` is the frame, the ground, the hover and the
   chosen state; what is here is what a spawn card is SHAPED like.
   ========================================================================== */
.card {
  position: relative;
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  /* The right edge pays for the chamfer so a long place name never runs under it. */
  padding: var(--op-space-2) calc(var(--op-space-3) + var(--op-cut-sm))
    calc(var(--op-space-2) + 1px) var(--op-space-3);
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

/* The index column is held open whether or not it is read, so every label on the
   grid lands on one x within its column. */
.index {
  flex: none;
  width: 2ch;
  color: var(--op-red-deep);
  font-variant-numeric: tabular-nums;
}

.card-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* The hint line. Grey, because the district is context for the place name above
   it and not a second reading of it. */
.district {
  color: var(--op-text-dim);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* --- CHOSEN ------------------------------------------------------------------
   `.op-frame.is-on` lights the frame and the ground and `.op-lift` blooms it. A
   filter is affordable here for the reason `shapes.css` gives: this surface
   repaints when the player presses something, not thirty times a second. What is
   local is the letter-spacing, which is the same half-step `MenuView` gives its
   chosen row. */
.card.is-on .label {
  letter-spacing: 0.055em;
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-glow);
}

.card.is-on .index,
.card.is-on .district {
  color: var(--op-red-text);
}

/* =============================================================================
   THE FOOT -- what the keys do, and where Enter goes.
   ========================================================================== */
.foot {
  display: flex;
  align-items: center;
  gap: var(--op-space-4);
  min-width: 0;
  padding: var(--op-space-3) calc(var(--op-space-3) + var(--op-cut-lg))
    calc(var(--op-space-3) + var(--op-cut-lg)) calc(var(--op-space-3) + var(--op-rule));
  border-top: 1px solid var(--op-red-idle);
}

/* The one place this surface wraps: a hint is a sentence. */
.hint {
  margin-right: auto;
  color: var(--op-text-faint);
  letter-spacing: var(--op-track-label);
  font-family: var(--op-font-mono);
  white-space: normal;
}

.confirm {
  flex: none;
  /* The chamfer lives in the top-right corner, so the right side pays for it. */
  padding: var(--op-space-2) calc(var(--op-space-5) + var(--op-cut-sm))
    calc(var(--op-space-2) + 1px) var(--op-space-5);
  font: 700 var(--op-fs-lead) / 1.25 var(--op-font-display);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

/* `.op-frame.is-off` already ices the stroke and the type; this is the pointer,
   which a disabled <button> would not change on its own in every engine. */
.confirm:disabled {
  cursor: default;
}
</style>
