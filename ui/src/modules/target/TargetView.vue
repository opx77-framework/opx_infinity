<script setup lang="ts">
import { computed, nextTick, onUnmounted, ref } from 'vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import OpSpinner from '@/design/components/OpSpinner.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { glyphPaths } from './glyphs'

/**
 * THE TARGET EYE -- port of `opx77_target/web/{index.html,target.css,target.js}`.
 *
 * Hold the key, an eye follows the pointer, a click lists what can be done with
 * whatever is under it. LUA CASTS EVERY RAY AND DECIDES EVERY ROW. This page draws
 * three things and reports two.
 *
 * WHAT IT REPORTS, and it is intents in the strictest sense this tree has:
 *  - where the pointer is (`hover`) and where it was CLICKED (`pick`). The click's
 *    own coordinates travel, never the pointer's current ones: Lua casts the ray at
 *    the point the player clicked, and by the time the handler runs the pointer has
 *    already moved.
 *  - which row was clicked (`select`), by token. Nothing else -- not the label, not
 *    what it means, not whether it should have been clickable. Lua re-resolves the
 *    token, re-checks the target and re-asks the row's owner before anything runs.
 *
 * WHAT IT DECIDES FOR ITSELF, and only this, because none of it is a fact about the
 * world: which folder of the group tree is showing, and which row has keyboard
 * focus. Every row in the tree was already allowed by Lua before it was sent.
 *
 * THE THREE STATES, all three carried over deliberately:
 *  - LOADING is delayed by `LOADING_DELAY_MS`. A pick that resolves faster than that
 *    never shows a panel at all, which is most of them; without the delay every
 *    click flashes a spinner.
 *  - EMPTY DRAWS NOTHING. Not an empty panel and not a line saying there is nothing
 *    here: the eye goes back to hovering as if the click had not happened.
 *  - the LIST, anchored at the click point and kept inside the viewport.
 */

/** Lua's handle, echoed back untouched. Never coerced -- an integer must stay one. */
type Handle = string | number

interface Row {
  token: string
  label: string
  description: string
  group: string
  icon: string
  danger: boolean
  /** `undefined` means this row has no box at all, not an unchecked one. */
  checked: boolean | undefined
}

interface Labels {
  hint: string
  looking: string
  unavailable: string
  back: string
}

/** A group is a folder path: "Staff/Weather" lists under Staff, then Weather. */
const GROUP_SEPARATOR = '/'

/** A pick that answers faster than this never shows its panel. */
const LOADING_DELAY_MS = 180

/** Half of --eye, and the gaps the list keeps from the eye and from the edge. */
const EYE_HALF = 20
const GAP = 6
const EDGE = 12

const handle = ref<Handle | null>(null)
const open = ref(false)
const busy = ref(false)
const available = ref(false)
const loading = ref(false)
const failed = ref(false)
const rows = ref<Row[]>([])
const path = ref<string[]>([])
const labels = ref<Labels>({ hint: '', looking: '', unavailable: '', back: '' })
const pendingToken = ref('')

/** 0..1 of the viewport. The eye follows the pointer; the list stays where the click was. */
const eye = ref({ x: 0.5, y: 0.5 })
const anchor = ref({ x: 0.5, y: 0.5 })

const listEl = ref<HTMLElement | null>(null)
const left = ref(0)
const top = ref(0)
const keyboard = ref(false)

let hoverMs = 90
let hoverTimer: ReturnType<typeof setTimeout> | undefined
let loadingTimer: ReturnType<typeof setTimeout> | undefined
let sentPoint: { x: number; y: number } | null = null
let release: (() => void) | undefined
let frame = 0

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

/** A message for a session that has gone is dropped, never applied. */
function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value))
}

function send(channel: string, payload: Payload = {}): void {
  if (handle.value === null) return
  emit(channel, { ...payload, handle: handle.value })
}

/** The rows under the folder currently open, folders first as their own rows. */
const shown = computed(() => {
  const depth = path.value.length
  const out: Array<{ kind: 'row'; row: Row } | { kind: 'folder'; name: string; count: number }> = []
  const folders = new Map<string, number>()

  for (const row of rows.value) {
    const parts = row.group
      .split(GROUP_SEPARATOR)
      .map((part) => part.trim())
      .filter((part) => part !== '')

    let inside = true
    for (let index = 0; index < depth; index += 1) {
      if (parts[index] !== path.value[index]) {
        inside = false
        break
      }
    }
    if (!inside) continue

    if (parts.length > depth) {
      const name = parts[depth]
      const seen = folders.get(name)
      if (seen === undefined) {
        folders.set(name, 1)
        out.push({ kind: 'folder', name, count: 1 })
      } else {
        folders.set(name, seen + 1)
      }
      continue
    }
    out.push({ kind: 'row', row })
  }

  // The counts are only known once every row has been walked.
  return out.map((entry) =>
    entry.kind === 'folder' ? { ...entry, count: folders.get(entry.name) ?? 1 } : entry
  )
})

const showList = computed(() => open.value && (loading.value || failed.value || shown.value.length > 0))

const showHint = computed(() => open.value && !showList.value && labels.value.hint !== '')

const eyeStyle = computed(() => {
  const x = clamp(eye.value.x * window.innerWidth - EYE_HALF, EDGE, window.innerWidth - EYE_HALF * 2 - EDGE)
  const y = clamp(eye.value.y * window.innerHeight - EYE_HALF, EDGE, window.innerHeight - EYE_HALF * 2 - EDGE)
  return { transform: `translate3d(${x}px, ${y}px, 0)` }
})

/**
 * Puts the list beside the anchor and keeps it inside the viewport: to the right of
 * the eye when it fits, to its left when it does not.
 *
 * `left` and `top`, never `transform`: the appear animation owns transform, and a
 * translated list would sit at 0,0 for as long as the animation runs.
 */
function place(): void {
  frame = 0
  const node = listEl.value
  if (!node) return
  const width = window.innerWidth
  const height = window.innerHeight
  const x = anchor.value.x * width
  const y = anchor.value.y * height
  const right = x + EYE_HALF + GAP
  const wanted = right + node.offsetWidth > width - EDGE ? x - EYE_HALF - GAP - node.offsetWidth : right
  left.value = clamp(wanted, EDGE, Math.max(EDGE, width - node.offsetWidth - EDGE))
  top.value = clamp(y - EYE_HALF, EDGE, Math.max(EDGE, height - node.offsetHeight - EDGE))
}

function schedule(): void {
  if (frame === 0) frame = requestAnimationFrame(place)
}

function clearTimers(): void {
  if (hoverTimer !== undefined) clearTimeout(hoverTimer)
  if (loadingTimer !== undefined) clearTimeout(loadingTimer)
  hoverTimer = undefined
  loadingTimer = undefined
}

function blank(): void {
  clearTimers()
  busy.value = false
  loading.value = false
  failed.value = false
  available.value = false
  rows.value = []
  path.value = []
  pendingToken.value = ''
  sentPoint = null
}

function shut(): void {
  blank()
  open.value = false
  handle.value = null
  keyboard.value = false
  release?.()
  release = undefined
}

/** The rows the keyboard can reach, in the order they are drawn. */
function reachable(): HTMLElement[] {
  const node = listEl.value
  if (!node) return []
  return Array.from(node.querySelectorAll<HTMLElement>('[role="button"]:not([aria-disabled="true"])'))
}

function openFolder(next: string[]): void {
  if (busy.value) return
  path.value = next
  keyboard.value = false
  void nextTick(place)
}

function choose(row: Row): void {
  if (busy.value) return
  // Disabled here and not by Lua's answer: the list must stop taking clicks the
  // instant one is sent, or a second click races the first one's resolution.
  busy.value = true
  pendingToken.value = row.token
  send('opx:target:select', { token: row.token })
}

function onPointerMove(event: MouseEvent): void {
  if (!open.value || busy.value || showList.value) return
  keyboard.value = false
  const point = {
    x: clamp(event.clientX / window.innerWidth, 0, 1),
    y: clamp(event.clientY / window.innerHeight, 0, 1)
  }
  eye.value = point
  schedule()
  if (hoverTimer !== undefined) return
  hoverTimer = setTimeout(() => {
    hoverTimer = undefined
    if (!open.value || busy.value || showList.value) return
    if (sentPoint && sentPoint.x === eye.value.x && sentPoint.y === eye.value.y) return
    sentPoint = { ...eye.value }
    send('opx:target:hover', sentPoint)
  }, hoverMs)
}

function onClick(event: MouseEvent): void {
  if (!open.value || busy.value) return
  const node = listEl.value
  if (node && event.target instanceof Node && node.contains(event.target)) return
  // The CLICK's own coordinates, read here and sent as they are. Lua casts the ray
  // at this point and not at wherever the pointer has since moved to.
  send('opx:target:pick', {
    x: clamp(event.clientX / window.innerWidth, 0, 1),
    y: clamp(event.clientY / window.innerHeight, 0, 1)
  })
}

function onContextMenu(event: MouseEvent): void {
  event.preventDefault()
  if (open.value) send('opx:target:cancel')
}

const ARROWS = ['ArrowDown', 'ArrowUp', 'Home', 'End']

function onKeyDown(event: KeyboardEvent): void {
  if (!open.value || ARROWS.indexOf(event.key) === -1) return
  event.preventDefault()
  const buttons = reachable()
  if (buttons.length === 0) return
  const current = buttons.indexOf(document.activeElement as HTMLElement)
  let index: number
  if (event.key === 'Home') index = 0
  else if (event.key === 'End') index = buttons.length - 1
  else if (current < 0) index = event.key === 'ArrowUp' ? buttons.length - 1 : 0
  else index = (current + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length
  keyboard.value = true
  buttons[index].focus()
}

function onResize(): void {
  schedule()
}

function onBlur(): void {
  if (open.value) send('opx:target:cancel')
}

function readRows(value: unknown): Row[] {
  return list<Payload>(value).map((entry) => ({
    token: text(entry.token),
    label: text(entry.label),
    description: text(entry.description),
    group: text(entry.group),
    icon: text(entry.icon, 'interact'),
    danger: bool(entry.danger),
    checked: typeof entry.checked === 'boolean' ? entry.checked : undefined
  }))
}

useBridge('opx:target:open', (payload: Payload) => {
  guard('target:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    blank()
    handle.value = payload.handle
    hoverMs = clamp(num(payload.hoverMs, 90), 30, 1000)
    const given = table(payload.labels)
    labels.value = {
      hint: text(given.hint),
      looking: text(given.looking),
      unavailable: text(given.unavailable),
      back: text(given.back)
    }
    eye.value = { x: 0.5, y: 0.5 }
    anchor.value = { x: 0.5, y: 0.5 }
    open.value = true
    release = acquireFocus({ id: 'target', onEscape: () => send('opx:target:cancel') })
  }, undefined)
})

useBridge('opx:target:hover', (payload: Payload) => {
  if (!mine(payload) || busy.value || showList.value) return
  available.value = payload.available === true
})

useBridge('opx:target:loading', (payload: Payload) => {
  guard('target:loading', () => {
    if (!mine(payload)) return
    clearTimers()
    busy.value = true
    failed.value = false
    rows.value = []
    path.value = []
    available.value = false
    anchor.value = { x: clamp(num(payload.x, 0.5), 0, 1), y: clamp(num(payload.y, 0.5), 0, 1) }
    // Delayed, not immediate. Most picks answer inside this window and never draw a
    // panel at all; without the delay every click flashes a spinner.
    loadingTimer = setTimeout(() => {
      loadingTimer = undefined
      if (!open.value || !busy.value) return
      loading.value = true
      void nextTick(place)
    }, LOADING_DELAY_MS)
  }, undefined)
})

useBridge('opx:target:empty', (payload: Payload) => {
  // Nothing to offer: the panel goes away and the eye hovers again, as if nothing
  // had been clicked. Deliberately not an empty panel and not a sentence.
  if (!mine(payload)) return
  blank()
})

useBridge('opx:target:menu', (payload: Payload) => {
  guard('target:menu', () => {
    if (!mine(payload)) return
    clearTimers()
    busy.value = false
    loading.value = false
    failed.value = false
    rows.value = readRows(payload.options)
    path.value = []
    available.value = rows.value.length > 0
    anchor.value = { x: clamp(num(payload.x, anchor.value.x), 0, 1), y: clamp(num(payload.y, anchor.value.y), 0, 1) }
    keyboard.value = false
    void nextTick(place)
  }, undefined)
})

useBridge('opx:target:busy', (payload: Payload) => {
  if (!mine(payload)) return
  busy.value = true
  pendingToken.value = text(payload.token)
})

useBridge('opx:target:error', (payload: Payload) => {
  if (!mine(payload)) return
  busy.value = false
  loading.value = false
  pendingToken.value = ''
  failed.value = true
  void nextTick(place)
})

useBridge('opx:target:close', (payload: Payload) => {
  if (payload.handle !== undefined && !mine(payload)) return
  shut()
})

window.addEventListener('resize', onResize)
window.addEventListener('blur', onBlur)
window.addEventListener('keydown', onKeyDown)

onUnmounted(() => {
  window.removeEventListener('resize', onResize)
  window.removeEventListener('blur', onBlur)
  window.removeEventListener('keydown', onKeyDown)
  clearTimers()
  release?.()
})
</script>

<template>
  <div
    v-if="open"
    class="eye-room"
    @mousemove="onPointerMove"
    @click="onClick"
    @contextmenu="onContextMenu"
  >
    <!-- The eye. A leaf node moved with transform, per rule 3 in augmented.css: never
         an --aug-* value, and never on the panel below. -->
    <div class="eye" :class="{ available, busy }" :style="eyeStyle" aria-hidden="true">
      <svg viewBox="0 0 40 40" fill="none">
        <path class="corner" d="M3 12V3h9M28 3h9v9M37 28v9h-9M12 37H3v-9" />
        <path class="lid" d="M7 20s4.8-8 13-8 13 8 13 8-4.8 8-13 8-13-8-13-8Z" />
        <circle class="iris" cx="20" cy="20" r="4.2" />
        <circle class="pupil" cx="20" cy="20" r="1.8" />
      </svg>
    </div>

    <!-- ONE augmented container for the whole list; every row inside is OpRow's own
         plate and nothing else is augmented. -->
    <div
      v-if="showList"
      ref="listEl"
      class="list"
      :class="{ keyboard }"
      :style="{ left: `${left}px`, top: `${top}px` }"
      role="menu"
    >
      <OpPanel :lift="true">
        <p v-if="loading" class="status">
          <OpSpinner :size="10" />
          <span>{{ labels.looking }}</span>
        </p>

        <p v-else-if="failed" class="status bad">{{ labels.unavailable }}</p>

        <!-- The refusal stays ABOVE the rows and the rows stay clickable: Lua said
             this pick could not be run, not that the list was wrong. -->
        <template v-if="!loading">
          <div v-if="path.length > 0" class="line back">
            <span class="glyph" aria-hidden="true">
              <svg viewBox="0 0 24 24">
                <path v-for="(d, at) in glyphPaths('back')" :key="at" :d="d" />
              </svg>
            </span>
            <OpRow :label="labels.back" @select="openFolder(path.slice(0, -1))" />
          </div>

          <div
            v-for="entry in shown"
            :key="entry.kind === 'folder' ? `d:${entry.name}` : `r:${entry.row.token}`"
            class="line"
            :class="{
              danger: entry.kind === 'row' && entry.row.danger,
              pending: entry.kind === 'row' && entry.row.token === pendingToken
            }"
          >
            <span class="glyph" aria-hidden="true">
              <OpSpinner
                v-if="entry.kind === 'row' && entry.row.token === pendingToken"
                :size="10"
                inverted
              />
              <svg v-else viewBox="0 0 24 24">
                <path
                  v-for="(d, at) in glyphPaths(entry.kind === 'folder' ? 'folder' : entry.row.icon)"
                  :key="at"
                  :d="d"
                />
              </svg>
            </span>

            <OpRow
              v-if="entry.kind === 'folder'"
              :label="entry.name"
              :value="String(entry.count)"
              :disabled="busy"
              @select="openFolder(path.concat([entry.name]))"
            />
            <OpRow
              v-else
              :label="entry.row.label"
              :hint="entry.row.description"
              :checked="entry.row.checked"
              :disabled="busy"
              @select="choose(entry.row)"
            />
          </div>
        </template>
      </OpPanel>
    </div>

    <p v-if="showHint" class="hint">{{ labels.hint }}</p>
  </div>
</template>

<style scoped>
/* The eye owns the whole screen while it is up: it reads the pointer everywhere and
   the system cursor is replaced by the eye itself. Closed, this element does not
   exist at all, so the surface underneath is untouched. */
.eye-room {
  position: fixed;
  inset: 0;
  cursor: none;
  user-select: none;
}

.eye {
  position: absolute;
  left: 0;
  top: 0;
  width: 40px;
  height: 40px;
  color: var(--op77-text-dim);
  pointer-events: none;
  filter: drop-shadow(0 1px 3px rgba(0, 0, 0, 0.85));
  transition: color var(--op77-dur-fast) var(--op77-ease);
}

.eye svg {
  display: block;
  width: 100%;
  height: 100%;
  overflow: visible;
}

.corner {
  stroke: currentColor;
  stroke-width: 2.4;
  stroke-linecap: square;
  transform-origin: 20px 20px;
  transition: transform var(--op77-dur) var(--op77-ease);
}

.lid { fill: currentColor; }
.iris { fill: var(--op77-void); }
.pupil { fill: currentColor; }

/* Something under the pointer has rows: the eye lights and the corners close in. */
.eye.available { color: var(--op77-accent); }
.eye.available .corner { transform: scale(0.84); }

.eye.busy .corner { animation: seek 0.8s linear infinite; }

@keyframes seek {
  to { transform: rotate(90deg); }
}

.list {
  position: absolute;
  width: 208px;
  max-height: calc(100vh - 24px);
  display: flex;
  cursor: default;
  animation: appear var(--op77-dur) var(--op77-ease);
}

@keyframes appear {
  from { opacity: 0; transform: translateX(-6px); }
  to { opacity: 1; transform: none; }
}

.status {
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
  margin: 0;
  font: 600 var(--op77-fs-micro) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
}

.status.bad {
  color: var(--op77-danger);
}

/* The glyph sits INSIDE the row's plate, and the row pays for it in padding. It is
   `pointer-events: none` so the plate under it still takes the click: the tile is a
   mark on the row, not a second control. */
.line {
  position: relative;
  display: flex;
}

.line :deep(.row) {
  flex: 1;
  min-width: 0;
  padding-left: 30px;
  cursor: pointer;
}

.glyph {
  position: absolute;
  left: 4px;
  top: 4px;
  z-index: 1;
  display: grid;
  place-items: center;
  width: 18px;
  height: 18px;
  color: var(--op77-accent);
  background: var(--op77-accent-soft);
  border: 1px solid var(--op77-accent-line);
  pointer-events: none;
  transition:
    color var(--op77-dur-fast) var(--op77-ease),
    background var(--op77-dur-fast) var(--op77-ease);
}

.glyph svg {
  display: block;
  width: 11px;
  height: 11px;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: square;
  stroke-linejoin: miter;
}

.line:hover .glyph,
.list.keyboard .line:focus-within .glyph,
.line.pending .glyph {
  color: var(--op77-ink);
  background: var(--op77-accent);
}

.line.danger .glyph {
  color: var(--op77-danger);
  background: rgba(255, 92, 92, 0.12);
  border-color: rgba(255, 92, 92, 0.45);
}

.line.danger:hover .glyph {
  color: var(--op77-ink);
  background: var(--op77-danger);
}

.line.back :deep(.row) .label {
  color: var(--op77-text-dim);
}

.hint {
  position: absolute;
  left: 50%;
  bottom: calc(var(--op77-inset-y) + 96px);
  transform: translateX(-50%);
  margin: 0;
  padding: 7px var(--op77-space-3) 6px;
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
  background: var(--op77-panel-quiet);
  border: 1px solid var(--op77-line);
  pointer-events: none;
}
</style>
