<script setup lang="ts">
import { computed, nextTick, onUnmounted, reactive, ref } from 'vue'
import OpChip from '@/design/components/OpChip.vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import OpScrim from '@/design/components/OpScrim.vue'
import OpSpinner from '@/design/components/OpSpinner.vue'
import CreateForm from './CreateForm.vue'
import RosterCard from './RosterCard.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import type { Card, Draft, FormFrame, Handle, KeyHint, Mode, Row } from './types'

/**
 * THE FIRST SCREEN -- the character roster and the creation flow.
 *
 * REDESIGNED, not ported. `opx77_charselector` had no surface at all: it borrowed
 * `opx77_menu`'s keyboard strip and drew a character as a row with a label, a
 * right-hand value and a one-line description. That was the only shape the
 * framework had. A roster is a grid of identities, and this is the first thing
 * anybody sees.
 *
 * THE PANEL SITS ON THE LEFT AND THE SCRIM IS DIRECTIONAL. Lua turns the camera
 * to face the player's own character while they choose; a full-screen grid would
 * make that camera pointless. The right of the screen is left to the character
 * the player is looking at, which is also the only face that exists -- a roster
 * summary carries none, so a card's plate is a monogram and not a portrait
 * pretending to be one.
 *
 * ONE AUGMENTED ELEMENT FOR THE ROSTER. The panel is the frame; every card inside
 * it is a plain box with an inset accent rule when it is chosen. Rule 1 of
 * design/augmented.css, and the list length is the account's slot count, which
 * this page does not bound.
 *
 * FULLY OPERABLE FROM THE KEYBOARD. The old flow was keyboard-only and players
 * are used to it: arrows move, Enter chooses, Escape steps back. The mouse does
 * the same things, and neither of them decides anything -- the page reports which
 * card was chosen and Lua answers with a frame.
 */

/** The four keys the screen owns. Everything else belongs to the focused field. */
const MOVES: Record<string, number> = {
  ArrowUp: -1,
  ArrowDown: 1,
  ArrowLeft: -1,
  ArrowRight: 1
}

/** A pointer crossing a grid must not raise an event per card. */
const POINT_MS = 110

function emptyForm(): FormFrame {
  return {
    step: '',
    index: 1,
    total: 1,
    steps: [],
    count: '',
    about: '',
    field: '',
    rows: [],
    values: {},
    actions: { back: '', next: '', submit: '' },
    last: false,
    busy: false,
    error: '',
    errorField: '',
    warning: ''
  }
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const mode = ref<Mode>('roster')

const eyebrow = ref('')
const title = ref('')
const keys = ref<KeyHint[]>([])

const cards = ref<Card[]>([])
const cursor = ref('')
const slotsLabel = ref('')
const busy = ref(false)
const status = ref('')
const tone = ref('info')

const form = ref<FormFrame>(emptyForm())
const rowAt = ref(0)
/** The candidate answers. Lua holds the accepted draft and sends it back with
    every frame; this is what the player has typed or picked since the last one. */
const values = reactive<Draft>({})

const listEl = ref<HTMLElement | null>(null)

let release: (() => void) | undefined
let pointTimer: ReturnType<typeof setTimeout> | undefined
let pointed = ''

/** Two abreast once a roster is long enough to need it, one when it is not: a
    wide card at three-quarters the panel's width reads worse than a full one. */
const columns = computed(() => (cards.value.length > 4 ? 2 : 1))

const navigable = computed(() => form.value.rows.filter((row) => row.kind !== 'fact'))

const chosen = computed(() => cards.value.findIndex((card) => card.id === cursor.value))

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

/** Sends an intent, always stamped with the frame it answers. A stale handle is
    a message from a screen that has been replaced, and Lua drops it. */
function tell(channel: string, payload: Payload = {}): void {
  emit(channel, { ...payload, handle: handle.value })
}

function clearPointTimer(): void {
  if (pointTimer !== undefined) clearTimeout(pointTimer)
  pointTimer = undefined
}

function setCursor(id: string, report: boolean): void {
  if (id === '' || id === cursor.value) return
  cursor.value = id
  if (report) tell('opx:entry:focus', { id })
}

function readCards(payload: Payload): void {
  cards.value = list<Payload>(payload.cards).map((entry) => ({
    id: text(entry.id),
    kind: text(entry.kind, 'empty') as Card['kind'],
    name: text(entry.name),
    monogram: text(entry.monogram),
    identifier: text(entry.identifier),
    lifepath: text(entry.lifepath),
    body: text(entry.body),
    role: text(entry.role),
    affiliation: text(entry.affiliation),
    lastSeen: text(entry.lastSeen),
    note: text(entry.note),
    disabled: bool(entry.disabled)
  }))
  slotsLabel.value = text(payload.slotsLabel)
  busy.value = bool(payload.busy)
  status.value = text(payload.status)
  tone.value = text(payload.tone, 'info')

  const wanted = text(payload.cursor)
  if (cards.value.some((card) => card.id === wanted)) {
    cursor.value = wanted
  } else {
    const first = cards.value.find((card) => !card.disabled)
    cursor.value = first ? first.id : ''
  }
}

function readForm(payload: Payload): void {
  const incoming = table(payload.values)
  const next: FormFrame = {
    step: text(payload.step),
    index: num(payload.index, 1),
    total: num(payload.total, 1),
    steps: list<Payload>(payload.steps).map((mark) => ({
      id: text(mark.id),
      label: text(mark.label)
    })),
    count: text(payload.count),
    about: text(payload.about),
    field: text(payload.field),
    rows: list<Payload>(payload.rows).map((row) => ({
      id: text(row.id),
      kind: text(row.kind, 'text') as Row['kind'],
      label: text(row.label),
      value: text(row.value),
      placeholder: text(row.placeholder),
      note: text(row.note),
      max: num(row.max, 0),
      chosen: bool(row.chosen)
    })),
    values: {},
    actions: {
      back: text(table(payload.actions).back),
      next: text(table(payload.actions).next),
      submit: text(table(payload.actions).submit)
    },
    last: bool(payload.last),
    busy: bool(payload.busy),
    error: text(payload.error),
    errorField: text(payload.errorField),
    warning: text(payload.warning)
  }
  for (const key of Object.keys(incoming)) next.values[key] = text(incoming[key])
  form.value = next

  status.value = text(payload.status)
  tone.value = text(payload.tone, 'info')

  // Lua's draft is the accepted one: it is what this page last sent and what the
  // rules were run against, so it replaces the candidate rather than merging.
  for (const key of Object.keys(values)) delete values[key]
  for (const key of Object.keys(next.values)) values[key] = next.values[key]

  const rows = next.rows.filter((row) => row.kind !== 'fact')
  const refused = rows.findIndex((row) => row.id === next.errorField)
  rowAt.value = refused >= 0 ? refused : 0
  void nextTick(syncCaret)
}

/** Puts the caret in the focused text row and takes it out of every other, so the
    document keeps the keyboard and keydown still reaches the arrows. */
function syncCaret(): void {
  guard('entry:caret', () => {
    const root = listEl.value
    if (!root) return
    const row = navigable.value[rowAt.value]
    if (row && row.kind === 'text') {
      const input = root.querySelector<HTMLInputElement>(`[data-row="${row.id}"] input`)
      if (input && document.activeElement !== input) input.focus()
      return
    }
    const active = document.activeElement
    if (active instanceof HTMLElement) active.blur()
  }, undefined)
}

function blank(): void {
  clearPointTimer()
  pointed = ''
  open.value = false
  cards.value = []
  cursor.value = ''
  keys.value = []
  status.value = ''
  form.value = emptyForm()
  rowAt.value = 0
  for (const key of Object.keys(values)) delete values[key]
  const active = document.activeElement
  if (active instanceof HTMLElement) active.blur()
}

// ── what the player did ─────────────────────────────────────────────────────

function choose(card: Card): void {
  if (card.disabled || busy.value) return
  tell('opx:entry:choose', { id: card.id })
}

function point(card: Card): void {
  if (busy.value || card.disabled) return
  clearPointTimer()
  pointTimer = setTimeout(() => {
    pointTimer = undefined
    if (pointed === card.id) return
    pointed = card.id
    setCursor(card.id, true)
  }, POINT_MS)
}

/** Walks the grid, stepping over a card that cannot be chosen and stopping at
    either end rather than wrapping: a roster is short and a wrap reads as a jump. */
function moveCursor(delta: number): void {
  if (cards.value.length === 0) return
  let next = chosen.value < 0 ? 0 : chosen.value + delta
  const step = delta > 0 ? 1 : -1
  while (next >= 0 && next < cards.value.length && cards.value[next].disabled) next += step
  if (next < 0 || next >= cards.value.length) return
  setCursor(cards.value[next].id, true)
}

function moveRow(delta: number): void {
  const rows = navigable.value
  if (rows.length === 0) return
  const at = Math.max(0, Math.min(rows.length - 1, rowAt.value + delta))
  if (at === rowAt.value) return
  rowAt.value = at
  const row = rows[at]
  // Moving over a choice list IS choosing: the highlight and the answer are the
  // same thing, and Enter is what commits the step.
  if (row.kind === 'choice' && form.value.field !== '') values[form.value.field] = row.id
  void nextTick(syncCaret)
}

function pick(id: string): void {
  if (form.value.busy) return
  if (form.value.field !== '') values[form.value.field] = id
  const at = navigable.value.findIndex((row) => row.id === id)
  if (at >= 0) rowAt.value = at
  advance()
}

function edit(id: string, value: string): void {
  values[id] = value
}

function focusRow(at: number): void {
  if (at < 0) return
  rowAt.value = at
  void nextTick(syncCaret)
}

function advance(): void {
  if (form.value.busy) return
  const draft = { ...values }
  if (form.value.last) {
    tell('opx:entry:submit', { values: draft })
    return
  }
  tell('opx:entry:step', { step: form.value.step, direction: 1, values: draft })
}

function back(): void {
  if (form.value.busy) return
  tell('opx:entry:step', { step: form.value.step, direction: -1, values: { ...values } })
}

/** Escape. On the roster it is a dismissal Lua answers by putting the screen
    straight back up; in the form it is one step back, and Lua cancels the whole
    creation when there is no step to go back to. */
function dismiss(): void {
  if (mode.value === 'create') {
    back()
    return
  }
  tell('opx:entry:dismiss')
}

function keyDown(event: KeyboardEvent): void {
  if (!open.value) return
  // Escape belongs to bridge/focus.ts, in the capture phase.
  if (event.key === 'Escape') return

  if (event.key === 'Enter') {
    event.preventDefault()
    if (mode.value === 'create') {
      advance()
      return
    }
    const card = cards.value[chosen.value]
    if (card) choose(card)
    return
  }

  const delta = MOVES[event.key]
  if (delta === undefined) return

  if (mode.value === 'create') {
    const row = navigable.value[rowAt.value]
    // The one rule that lets a typed line and a picked list share a surface:
    // left and right belong to the caret unless the focused row is a choice.
    if ((event.key === 'ArrowLeft' || event.key === 'ArrowRight') && row?.kind !== 'choice') return
    event.preventDefault()
    moveRow(delta)
    return
  }

  event.preventDefault()
  const sideways = event.key === 'ArrowLeft' || event.key === 'ArrowRight'
  moveCursor(sideways || columns.value === 1 ? delta : delta * columns.value)
}

function listen(on: boolean): void {
  if (on) window.addEventListener('keydown', keyDown)
  else window.removeEventListener('keydown', keyDown)
}

// ── what Lua says ───────────────────────────────────────────────────────────

useBridge('opx:entry:open', (payload: Payload) => {
  guard('entry:open', () => {
    if (!isHandle(payload.handle)) return
    const fresh = payload.handle !== handle.value
    if (fresh) release?.()
    handle.value = payload.handle
    mode.value = text(payload.mode, 'roster') === 'create' ? 'create' : 'roster'
    eyebrow.value = text(payload.eyebrow)
    title.value = text(payload.title)
    keys.value = list<Payload>(payload.keys).map((cap) => ({
      key: text(cap.key),
      label: text(cap.label)
    }))
    open.value = true
    listen(true)
    if (fresh || release === undefined) {
      release = acquireFocus({ id: 'entry', onEscape: dismiss })
    }
  }, undefined)
})

useBridge('opx:entry:roster', (payload: Payload) => {
  guard('entry:roster', () => {
    if (!mine(payload)) return
    readCards(payload)
  }, undefined)
})

useBridge('opx:entry:form', (payload: Payload) => {
  guard('entry:form', () => {
    if (!mine(payload)) return
    readForm(payload)
  }, undefined)
})

useBridge('opx:entry:status', (payload: Payload) => {
  guard('entry:status', () => {
    if (!mine(payload)) return
    status.value = text(payload.text)
    tone.value = text(payload.tone, 'info')
  }, undefined)
})

useBridge('opx:entry:close', (payload: Payload) => {
  guard('entry:close', () => {
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    blank()
    listen(false)
    release?.()
    release = undefined
  }, undefined)
})

// Says the page is mounted and can be drawn on. A surface DROPS every send made
// before its page reported ready rather than queueing it, so Lua pushes the frame
// again when it hears this -- and again on its own tick, because this fires during
// mount and the surface's own ready handshake is emitted after it.
emit('opx:entry:ready', {})

onUnmounted(() => {
  listen(false)
  clearPointTimer()
  release?.()
})
</script>

<template>
  <div class="room" :class="{ open }">
    <!-- Directional, not flat: it dims the side the panel is on and leaves the
         character the stage camera is facing visible on the other. -->
    <OpScrim mode="lead" :visible="open" />

    <div class="column">
      <OpPanel bay>
        <template #header>
          <div class="head-text">
            <span class="op77-eyebrow">{{ eyebrow }}</span>
            <h1>{{ title }}</h1>
          </div>
          <OpChip v-if="mode === 'roster' && slotsLabel" :label="slotsLabel" tone="accent" />
          <OpSpinner v-if="busy || form.busy" />
        </template>

        <div v-if="mode === 'roster'" class="grid" :class="{ busy }" :style="{ '--columns': columns }">
          <RosterCard
            v-for="card in cards"
            :key="card.id"
            :class="{ wide: card.kind === 'create' }"
            :card="card"
            :selected="card.id === cursor"
            @choose="choose(card)"
            @point="point(card)"
          />
        </div>

        <div v-else ref="listEl" class="sheet">
          <CreateForm
            :form="form"
            :row-at="rowAt"
            :values="values"
            @edit="edit"
            @pick="pick"
            @row="focusRow"
          />
        </div>

        <template #footer>
          <div class="lines">
            <p v-if="status" class="status" :class="tone">{{ status }}</p>
            <div v-if="mode === 'create'" class="buttons">
              <OpRow
                class="button grow"
                :label="form.actions.back"
                :disabled="form.busy"
                @select="back"
              />
              <OpRow
                class="button grow"
                :label="form.last ? form.actions.submit : form.actions.next"
                selected
                :disabled="form.busy"
                @select="advance"
              />
            </div>
            <div v-if="keys.length" class="keys">
              <span v-for="cap in keys" :key="cap.key" class="cap">
                <OpKeyCap :label="cap.key" />
                <span class="cap-label">{{ cap.label }}</span>
              </span>
            </div>
          </div>
        </template>
      </OpPanel>
    </div>
  </div>
</template>

<style scoped>
.room {
  position: absolute;
  inset: 0;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op77-dur) var(--op77-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

.column {
  position: absolute;
  left: var(--op77-inset-x);
  top: var(--op77-inset-y);
  bottom: var(--op77-inset-y);
  display: flex;
  width: 680px;
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin-right: auto;
  min-width: 0;
}

.head-text h1 {
  margin: 0;
  font: 700 var(--op77-fs-head) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
}

.grid {
  display: grid;
  grid-template-columns: repeat(var(--columns, 1), minmax(0, 1fr));
  gap: var(--op77-space-2);
  align-content: start;
  flex: 1 1 auto;
  min-height: 0;
  transition: opacity var(--op77-dur-fast) var(--op77-ease);
}

.grid.busy {
  opacity: 0.55;
}

/* The create card is the end of the list, not one more identity in it. */
.wide {
  grid-column: 1 / -1;
}

.sheet {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
}

.lines {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  min-width: 0;
}

.status {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  color: var(--op77-text-dim);
}

.status.ok {
  color: var(--op77-ok);
}

.status.error {
  color: var(--op77-danger);
}

.buttons {
  display: flex;
  gap: var(--op77-space-2);
}

.button {
  justify-content: center;
  cursor: pointer;
}

.grow {
  flex: 1;
}

.keys {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op77-space-3);
}

.cap {
  display: inline-flex;
  align-items: center;
  gap: var(--op77-space-2);
}

.cap-label {
  font: 400 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--op77-text-dim);
}

@keyframes card-in {
  from {
    opacity: 0;
    transform: translateX(-12px);
  }
}

.room.open .grid > * {
  animation: card-in var(--op77-dur) var(--op77-ease) backwards;
}
</style>
