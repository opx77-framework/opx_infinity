<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

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
 */

/** Lua's handle, echoed back untouched. Never coerced -- an integer must stay one. */
type Handle = string | number

interface Slot {
  /** The row's ABSOLUTE index in the level, which is also the v-for key. */
  index: number
  /** Position within the window, for the open stagger. */
  at: number
  label: string
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
const title = ref('')
const trail = ref('')
const hint = ref('')
const status = ref('')
const statusBad = ref(false)
const slots = ref<Slot[]>([])
const first = ref(1)
const total = ref(0)
const anchor = ref('anchor-top-left')
const width = ref(340)
const maxHeight = ref(56)

/** Right-anchored strips read the leading edge as the right edge, per menu.css. */
const railEnd = computed(() => anchor.value.endsWith('right'))

const paged = computed(() => total.value > slots.value.length)

/** The scroll rail's thumb, at the window's own proportions. menu.css did these sums in
    `calc`; they are three numbers Lua sent either way and nothing here is derived from
    a row. A string binding, not an object: Vue 2 cannot set a custom property from one. */
const thumb = computed(() => {
  const rows = Math.max(1, total.value)
  const top = ((Math.max(1, first.value) - 1) / rows) * 100
  const height = (slots.value.length / rows) * 100
  return `top: ${top}%; height: ${height}%`
})

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
  title.value = text(payload.title) || 'MENU'
  // Upper-cased and nothing else: Lua owns the "/" separator.
  trail.value = text(payload.trail).toUpperCase()
  hint.value = text(payload.hint)
  status.value = text(payload.status)
  // Only the failure flag crosses the bridge; anything else is a success.
  statusBad.value = payload.statusBad === true
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
  trail.value = ''
  hint.value = ''
  status.value = ''
  statusBad.value = false
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
    listen(true)
    release = acquireFocus({
      id: 'menu',
      // An INTENT. The page does not close itself: Lua owns the close reason
      // (`pause`, `back`, `item`, ...) and answers with `opx:menu:close`.
      onEscape: () => emit('opx:menu:dismiss', { handle: handle.value })
    })
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
  <div class="strip" :class="[anchor, { open }]" :style="stripStyle">
    <OpPanel bay :anchor="railEnd ? 'end' : 'start'">
      <template #header>
        <div class="head-text">
          <span v-if="trail" class="op77-eyebrow">{{ trail }}</span>
          <h1>{{ title }}</h1>
        </div>
      </template>

      <ul class="list" :class="{ paged }">
        <!-- The rail: a track and a thumb at the window's proportions. Two plain
             elements, because the list frame is the augmented one and an augmented
             element's own pseudo-elements belong to Augmented UI. -->
        <li v-if="paged" class="rail" aria-hidden="true">
          <i class="thumb" :style="thumb" />
        </li>

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
          :class="{ pop: row.on && !row.off && !row.rule, gap: row.blank }"
          :style="`--slot: ${row.at}`"
        >
          <!-- A separator with no caption draws nothing at all: the <li> is the space. -->
          <OpRow
            v-if="!row.blank"
            :label="row.label"
            :rule="row.rule"
            :selected="row.on"
            :disabled="row.off"
            :checked="row.checked"
            @select="choose(row)"
          >
            <template #value>
              <span class="cell-value">{{ row.value }}</span>
              <span v-if="row.mark" class="cell-mark">{{ row.mark }}</span>
            </template>
          </OpRow>
        </li>
      </ul>

      <template v-if="hint || status" #footer>
        <div class="lines">
          <p v-if="hint" class="hint">{{ hint }}</p>
          <p v-if="status" class="status" :class="{ bad: statusBad }">{{ status }}</p>
        </div>
      </template>
    </OpPanel>
  </div>
</template>

<style scoped>
/* The strip is absolutely placed and fades as a whole, per menu.css `body.open`. It is
   always in the document so the fade has something to run on; what comes and goes is
   its content. */
.strip {
  position: absolute;
  display: flex;
  max-width: calc(100vw - var(--op77-inset-x) * 2);
  opacity: 0;
  pointer-events: none;
  transform: translateX(var(--slide, 10px));
  transition:
    opacity var(--op77-dur) var(--op77-ease),
    transform var(--op77-dur) var(--op77-ease);
}

.strip.open {
  opacity: 1;
  pointer-events: auto;
  transform: none;
}

.anchor-top-left,
.anchor-left {
  left: var(--op77-inset-x);
  --slide: -10px;
  --pop: 18px;
}

.anchor-top-right,
.anchor-right {
  right: var(--op77-inset-x);
  --slide: 10px;
  --pop: -18px;
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

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  min-width: 0;
}

.head-text h1 {
  margin: 0;
  font: 700 var(--op77-fs-lead) / 1.1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* The list never scrolls: Lua sends the window it wants drawn. */
.list {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin: 0;
  padding: 0 0 0 var(--op77-space-3);
  list-style: none;
  min-height: 0;
}

.rail {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: var(--op77-rule);
  background: var(--op77-line-hud);
}

.thumb {
  position: absolute;
  left: 0;
  width: 100%;
  /* A two-hundred-row list would otherwise draw a thumb too small to see. */
  min-height: 12px;
  background: var(--op77-text);
}

.slot {
  transition: transform var(--op77-dur-fast) var(--op77-ease);
}

/* The selection leaves the column. On the wrapper and not on the row, so the row's own
   plate keeps its colour transition and nothing animates an `--aug-*` value. */
.slot.pop {
  transform: translateX(var(--pop, 18px));
}

/* A separator with no caption is pure space: the gap, doubled. */
.slot.gap {
  height: var(--op77-space-1);
}

.cell-value {
  overflow: hidden;
  text-overflow: ellipsis;
}

/* The affordance column, always beside the value so every mark lands at the same x. */
.cell-mark {
  margin-left: var(--op77-space-2);
  font-weight: 700;
}

.lines {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  min-width: 0;
}

.hint {
  margin: 0;
  /* The one place the strip wraps: a description is a sentence. */
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.status {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  color: var(--op77-ok);
}

.status.bad {
  color: var(--op77-danger);
}

/* The plates deal themselves in when a menu opens. One-shot, and only on elements the
   keyed v-for has just created -- a row that survived the last frame does not re-run it. */
@keyframes plate-in {
  from {
    opacity: 0;
    transform: translateX(calc(var(--pop, 18px) * -1.2));
  }
}

.strip.open .slot {
  animation: plate-in var(--op77-dur) var(--op77-ease) backwards;
  animation-delay: calc(var(--slot, 0) * 30ms + 40ms);
}
</style>
