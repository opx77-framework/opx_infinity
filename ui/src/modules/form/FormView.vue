<script setup lang="ts">
import { computed, nextTick, onUnmounted, ref } from 'vue'
import OpField from '@/design/components/OpField.vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpScrim from '@/design/components/OpScrim.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

/**
 * THE FORM -- port of `opx77_input/web/{index.html,input.css,input.js}`.
 *
 * Text, choice and slider answered together in one modal. Like the menu it is a
 * renderer: Lua holds the authoritative buffer, runs `maxLength`, `charset`, `pattern`
 * and `required`, and answers every keystroke with the buffer it ACCEPTED. The page
 * reports candidates.
 *
 * That round trip is not caution, it is the contract in `form-spec.md`: "A refused
 * keystroke is not merely hidden: the accepted buffer stays as it was and the page is
 * told to put it back." A field that kept its own text would be showing a value the
 * server has already refused.
 *
 * Unlike the menu, this page always held the keyboard -- `input.js` forwarded six keys
 * to Lua and left every other key to the focused <input>. That is unchanged here, down
 * to the one rule that makes it work: LEFT and RIGHT belong to the caret unless the
 * frame said the focused row spins.
 */

type Handle = string | number

interface Field {
  id: string
  kind: 'text' | 'choice' | 'slider'
  label: string
  /** Text kind: the buffer Lua accepted. */
  buffer: string
  /** Choice and slider: the value as Lua rendered it, suffix and all. */
  value: string
  /** Slider: the number, for the track. See the note on `suffix` in the report. */
  number: number
  min: number
  max: number
  placeholder: string
  /** `12/24`, drawn under the focused text field. */
  count: string
  /** LEFT and RIGHT change this row's value rather than moving the caret. */
  spin: boolean
  on: boolean
}

interface KeyHint {
  key: string
  label: string
}

/** The six keys input.js forwards. Everything else is the focused field's. */
const KEYS: Record<string, string> = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Enter: 'enter'
}

const ANCHORS: Record<string, string> = {
  'center': 'anchor-center',
  'top-left': 'anchor-top-left',
  'top-right': 'anchor-top-right',
  'left': 'anchor-left',
  'right': 'anchor-right'
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const title = ref('')
const note = ref('')
const hint = ref('')
const status = ref('')
const statusBad = ref(false)
const fields = ref<Field[]>([])
const keys = ref<KeyHint[]>([])
const anchor = ref('anchor-center')
const width = ref(420)
const dim = ref(true)

const listEl = ref<HTMLElement | null>(null)

const stripStyle = computed(() => `width: ${width.value}px`)

const focused = computed(() => fields.value.find((field) => field.on))

/** Lua counts characters and JS counts UTF-16 units: a surrogate pair is one character
    on both sides once its low half is dropped. Straight from input.js. */
function characters(value: string): number {
  return value.replace(/[\uDC00-\uDFFF]/g, '').length
}

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function readConfig(payload: Payload): void {
  anchor.value = ANCHORS[text(payload.anchor)] ?? ANCHORS['center']
  const wide = num(payload.width)
  if (wide > 0) width.value = Math.round(wide)
  dim.value = payload.dim !== false
}

function readFrame(payload: Payload): void {
  title.value = text(payload.title) || 'INPUT'
  note.value = text(payload.note)
  hint.value = text(payload.hint)
  status.value = text(payload.status)
  statusBad.value = payload.statusBad === true

  keys.value = list<Payload>(payload.keys).map((cap) => ({
    key: text(cap.key),
    label: text(cap.label)
  }))

  fields.value = list<Payload>(payload.rows).map((row) => {
    const named = text(row.kind, 'text')
    const kind: Field['kind'] = named === 'choice' || named === 'slider' ? named : 'text'
    const buffer = text(row.text)
    // `max` is the field's own bound either way: `maxLength` on a text field, the top of
    // the range on a slider. A row has one kind, so the two never meet.
    const min = num(row.min)
    const max = num(row.max, kind === 'slider' ? 100 : 0)
    return {
      id: text(row.id),
      kind,
      label: text(row.label),
      buffer,
      value: text(row.value),
      // `fill` is what opx77_input already sends; `number` is preferred when Lua sends
      // it, because a value re-derived from a rounded ratio would not step evenly.
      number: typeof row.number === 'number' ? row.number : min + num(row.fill) * (max - min),
      min,
      max: kind === 'slider' ? max : 100,
      placeholder: text(row.placeholder),
      // A display of the buffer Lua sent, counted the way Lua counts it. Nothing
      // derived here ever leaves the page.
      count: kind === 'text' && max > 0 ? `${characters(buffer)}/${Math.round(max)}` : '',
      spin: row.spin === true,
      on: row.on === true
    }
  })

  // input.js put the caret in the focused text field and blurred everything otherwise,
  // so the document -- not a field -- keeps the keyboard and keydown still fires.
  void nextTick(syncCaret)
}

function syncCaret(): void {
  guard('form:caret', () => {
    const root = listEl.value
    if (!root) return
    const field = focused.value
    if (field && field.kind === 'text') {
      const input = root.querySelector<HTMLInputElement>(`[data-field="${field.id}"] input`)
      if (input && document.activeElement !== input) input.focus()
      return
    }
    const active = document.activeElement
    if (active instanceof HTMLElement) active.blur()
  }, undefined)
}

function blank(): void {
  open.value = false
  fields.value = []
  keys.value = []
  note.value = ''
  hint.value = ''
  status.value = ''
  statusBad.value = false
  const active = document.activeElement
  if (active instanceof HTMLElement) active.blur()
}

let release: (() => void) | undefined

function keyDown(event: KeyboardEvent): void {
  // Escape is bridge/focus.ts's, in the capture phase.
  if (event.key === 'Escape') return
  const key = KEYS[event.key]
  if (key === undefined) return
  // The one rule that lets a typed line and an arrow-stepped list share a surface.
  if ((key === 'left' || key === 'right') && focused.value?.spin !== true) return
  event.preventDefault()
  emit('opx:form:key', { handle: handle.value, key, repeat: event.repeat === true })
}

function listen(on: boolean): void {
  if (on) window.addEventListener('keydown', keyDown)
  else window.removeEventListener('keydown', keyDown)
}

useBridge('opx:form:open', (payload: Payload) => {
  guard('form:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    handle.value = payload.handle
    readConfig(payload)
    readFrame(payload)
    open.value = true
    listen(true)
    release = acquireFocus({
      id: 'form',
      // Escape is `cancel` in `opx77_input/client/main.lua`; Lua raises the answer with
      // `action = "cancel"` and closes. The page does not decide that.
      onEscape: () => emit('opx:form:dismiss', { handle: handle.value })
    })
  }, undefined)
})

useBridge('opx:form:frame', (payload: Payload) => {
  guard('form:frame', () => {
    if (!mine(payload)) return
    readFrame(payload)
  }, undefined)
})

useBridge('opx:form:close', (payload: Payload) => {
  guard('form:close', () => {
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

/** A CANDIDATE buffer, never an accepted one. Lua answers with a frame carrying the
    text it kept, which may be shorter, unchanged, or the same string back. */
function edit(field: Field, value: string): void {
  emit('opx:form:edit', { handle: handle.value, id: field.id, text: value })
}

/** The choice arrows, which are LEFT and RIGHT by another name. */
function step(field: Field, direction: -1 | 1): void {
  emit('opx:form:step', { handle: handle.value, id: field.id, direction })
}

/** The player pointed at a field. Lua moves its own cursor; this does not. */
function focusField(field: Field): void {
  if (field.on) return
  emit('opx:form:focus', { handle: handle.value, id: field.id })
}
</script>

<template>
  <div class="room" :class="{ open }">
    <OpScrim v-if="dim" mode="flat" :visible="open" />
    <div class="strip" :class="anchor" :style="stripStyle">
      <OpPanel bay>
        <template #header>
          <div class="head-text">
            <span class="op77-eyebrow">FORM</span>
            <h1>{{ title }}</h1>
          </div>
        </template>

        <p v-if="note" class="note">{{ note }}</p>

        <ul ref="listEl" class="list">
          <li
            v-for="(field, at) in fields"
            :key="field.id"
            class="slot"
            :data-field="field.id"
            :style="`--slot: ${at}`"
          >
            <OpField
              :label="field.label"
              :kind="field.kind"
              :model-value="field.kind === 'text' ? field.buffer : field.kind === 'slider' ? field.number : field.value"
              :placeholder="field.placeholder"
              :min="field.min"
              :max="field.max"
              :count="field.count"
              :selected="field.on"
              @input="edit(field, $event)"
              @step="step(field, $event)"
              @focus="focusField(field)"
            />
          </li>
        </ul>

        <template #footer>
          <div class="lines">
            <p v-if="hint" class="hint">{{ hint }}</p>
            <p v-if="status" class="status" :class="{ bad: statusBad }">{{ status }}</p>
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

.strip {
  position: absolute;
  display: flex;
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}

/* Where a form ships. The other four are opx77_menu's anchors, for a caller that wants
   the form where the list before it sat. */
.anchor-center {
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
}

.anchor-top-left,
.anchor-left {
  left: var(--op77-inset-x);
}

.anchor-top-right,
.anchor-right {
  right: var(--op77-inset-x);
}

.anchor-top-left,
.anchor-top-right {
  top: var(--op77-inset-y);
}

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

.note {
  margin: 0 0 var(--op77-space-2);
  font: 400 var(--op77-fs-body) / 1.35 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.list {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin: 0;
  padding: 0;
  list-style: none;
  min-height: 0;
}

.lines {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  min-width: 0;
}

.hint {
  margin: 0;
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

@keyframes field-in {
  from {
    opacity: 0;
    transform: translateX(-12px);
  }
}

.room.open .slot {
  animation: field-in var(--op77-dur) var(--op77-ease) backwards;
  animation-delay: calc(var(--slot, 0) * 30ms + 40ms);
}
</style>
