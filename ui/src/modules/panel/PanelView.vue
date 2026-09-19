<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, reactive, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

/** A tab as this surface draws it. It was imported from `OpTabs`; the component
    is gone and the shape is three fields, so it lives where it is used. */
interface Tab {
  id: string
  label: string
}

/**
 * THE PANEL -- port of `opx77_panel/web/{index.html,panel.css,panel.js}`.
 *
 * The mouse-driven one, and the resource the handle pattern was taken from: Lua opens
 * with a spec and keeps the handle, every payload in either direction carries it, and a
 * message whose handle is not the open one is dropped rather than applied. That is what
 * lets five systems share one surface without a late reply from a closed panel landing
 * in the one that replaced it.
 *
 * Three things the page decides for itself, and only these three, because none of them
 * is a fact about the world:
 *  - the search filter, over items Lua has already sent;
 *  - the page of that filtered list;
 *  - whether the confirm dialog is on screen.
 * Everything else is Lua's answer, applied verbatim. The panel does not select an item
 * because it was clicked; it says it was clicked and waits for `selected` to come back.
 */

type Handle = string | number

interface Button {
  id: string
  label: string
  primary: boolean
  disabled: boolean
}

interface Item {
  id: string
  tab: string
  label: string
  detail: string
  disabled: boolean
  /** label + detail + id, lower-cased once so the filter is not re-lowering per keystroke. */
  search: string
}

interface Summary {
  label: string
  value: string
  action: Button | null
}

/** The confirm step. Parsed on arrival rather than kept as a raw payload, so the
    template never reaches into an `unknown` and a malformed dialog cannot render. */
interface Dialog {
  id: string
  title: string
  text: string
  yes: string
  no: string
}

interface PanelView {
  eyebrow: string
  title: string
  subtitle: string
  intro: string
  tabs: Tab[]
  tab: string
  /** `false` hides the search plate; a string is its placeholder. */
  search: string | false
  summary: Summary | null
  actions: Button[]
  tools: Button[]
  /** Per tab: the id of the item Lua considers chosen there. */
  selected: Record<string, string>
  status: { text: string; kind: string } | null
  busy: boolean
  loading: boolean
  labels: Record<string, string>
  /** Spec-only: whether Lua wants to hear about the pointer at all. */
  hover: boolean
  columns: 1 | 2
}

/* panel.js's numbers, kept: the grid pages by measured height, so a drawer that is short
   on one screen and tall on another does not paginate differently from what fits. */
const ROW_HEIGHT = 58
const ROW_GAP = 4
const HOVER_MS = 110
const LEAVE_MS = 160

function emptyView(): PanelView {
  return {
    eyebrow: '',
    title: '',
    subtitle: '',
    intro: '',
    tabs: [],
    tab: '',
    search: false,
    summary: null,
    actions: [],
    tools: [],
    selected: {},
    status: null,
    busy: false,
    loading: false,
    labels: {},
    hover: false,
    columns: 2
  }
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const view = reactive<PanelView>(emptyView())
const items = ref<Item[]>([])
const page = ref(0)
const query = ref('')
const dialog = ref<Dialog | null>(null)

const gridEl = ref<HTMLElement | null>(null)
const gridHeight = ref(0)

let hovered: string | null = null
let hoverTimer: ReturnType<typeof setTimeout> | undefined
let leaveTimer: ReturnType<typeof setTimeout> | undefined
let release: (() => void) | undefined
let releaseDialog: (() => void) | undefined

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

/** The view's own label table, which a caller's spec overrides -- not `useLocale`. The
    strings are Lua's already-translated defaults, or the caller's replacements. */
function label(key: string, vars?: Record<string, number | string>): string {
  const template = text(view.labels[key])
  if (!vars) return template
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => {
    const value = vars[name]
    return value === undefined ? whole : String(value)
  })
}

function readButtons(value: unknown): Button[] {
  return list<Payload>(value).map((entry) => ({
    id: text(entry.id),
    label: text(entry.label),
    primary: entry.primary === true,
    disabled: entry.disabled === true
  }))
}

function readSummary(value: unknown): Summary | null {
  const source = table(value)
  if (Object.keys(source).length === 0) return null
  const action = table(source.action)
  return {
    label: text(source.label),
    value: text(source.value),
    action: Object.keys(action).length === 0 ? null : readButtons([action])[0]
  }
}

/**
 * Applies whatever the payload carries and leaves the rest alone -- panel.js walked the
 * payload's own keys for exactly this reason, and `opx:panel:update` is a patch. The
 * difference here is that the key list is written down: an unknown field is dropped
 * instead of being written into the view under a name nothing renders.
 */
function apply(payload: Payload): void {
  const given = (key: string): boolean => payload[key] !== undefined
  if (given('eyebrow')) view.eyebrow = text(payload.eyebrow)
  if (given('title')) view.title = text(payload.title)
  if (given('subtitle')) view.subtitle = text(payload.subtitle)
  if (given('intro')) view.intro = text(payload.intro)
  if (given('tabs')) {
    view.tabs = list<Payload>(payload.tabs).map((tab) => ({
      id: text(tab.id),
      label: text(tab.label),
      marked: tab.marked === true,
      disabled: tab.disabled === true
    }))
  }
  if (given('tab')) view.tab = text(payload.tab)
  if (given('search')) view.search = payload.search === false ? false : text(payload.search)
  if (given('summary')) view.summary = readSummary(payload.summary)
  if (given('actions')) view.actions = readButtons(payload.actions)
  if (given('tools')) view.tools = readButtons(payload.tools)
  if (given('selected')) {
    // Merged, not replaced: an update naming one tab's choice must not forget the others.
    const incoming = table(payload.selected)
    for (const key of Object.keys(incoming)) view.selected[key] = text(incoming[key])
  }
  if (given('status')) {
    const status = table(payload.status)
    view.status = Object.keys(status).length === 0
      ? null
      : { text: text(status.text), kind: text(status.kind, 'info') }
  }
  if (given('busy')) view.busy = payload.busy === true
  if (given('loading')) view.loading = payload.loading === true
  if (given('labels')) {
    const incoming = table(payload.labels)
    const next: Record<string, string> = {}
    for (const key of Object.keys(incoming)) next[key] = text(incoming[key], key)
    view.labels = next
  }
  if (given('hover')) view.hover = payload.hover === true
  if (given('columns')) view.columns = num(payload.columns) === 1 ? 1 : 2
}

/** The tab actually drawn: the one Lua named if it still exists, else the first. */
const currentTab = computed(() => {
  if (view.tabs.length === 0) return ''
  if (view.tabs.some((tab) => tab.id === view.tab)) return view.tab
  return view.tabs[0].id
})

const chosen = computed(() => text(view.selected[currentTab.value]))

const shown = computed(() => {
  const tab = currentTab.value
  const needle = query.value.trim().toLowerCase()
  return items.value.filter((item) => {
    if (tab !== '' && item.tab !== '' && item.tab !== tab) return false
    return needle === '' || item.search.indexOf(needle) !== -1
  })
})

const pageSize = computed(() => {
  const rows = Math.max(1, Math.floor((gridHeight.value + ROW_GAP) / (ROW_HEIGHT + ROW_GAP)))
  return rows * (view.columns === 1 ? 1 : 2)
})

const lastPage = computed(() => Math.max(0, Math.ceil(shown.value.length / pageSize.value) - 1))

const visible = computed(() => {
  const at = Math.min(page.value, lastPage.value)
  return shown.value.slice(at * pageSize.value, (at + 1) * pageSize.value)
})

const count = computed(() => {
  if (shown.value.length === 0) return ''
  const at = Math.min(page.value, lastPage.value)
  return label('count', {
    from: at * pageSize.value + 1,
    to: Math.min(shown.value.length, (at + 1) * pageSize.value),
    total: shown.value.length
  })
})

const gridStyle = computed(() => `--columns: ${view.columns}`)

/** `search` carries two things -- whether the plate is drawn and what it says -- so the
    template gets a string and the `v-if` gets the boolean. */
const searchPlaceholder = computed(() => (view.search === false ? '' : view.search))

const summaryAction = computed(() => view.summary?.action ?? null)

function measure(): void {
  gridHeight.value = gridEl.value?.clientHeight ?? 0
}

function clearHoverTimers(): void {
  if (hoverTimer !== undefined) clearTimeout(hoverTimer)
  if (leaveTimer !== undefined) clearTimeout(leaveTimer)
  hoverTimer = undefined
  leaveTimer = undefined
}

/** Debounced both ways: a pointer crossing a grid must not raise an event per row, and
    a pointer that left for two frames on its way to the next row has not left. */
function pointAt(id: string): void {
  if (!view.hover || handle.value === null) return
  clearHoverTimers()
  hoverTimer = setTimeout(() => {
    hoverTimer = undefined
    if (handle.value === null || hovered === id) return
    hovered = id
    emit('opx:panel:hover', { handle: handle.value, item: id })
  }, HOVER_MS)
}

function pointAway(): void {
  if (!view.hover || handle.value === null) return
  clearHoverTimers()
  leaveTimer = setTimeout(() => {
    leaveTimer = undefined
    if (handle.value === null || hovered === null) return
    hovered = null
    emit('opx:panel:leave', { handle: handle.value })
  }, LEAVE_MS)
}

function closeDialog(): void {
  dialog.value = null
  releaseDialog?.()
  releaseDialog = undefined
}

/** The confirm answer. Both buttons take the dialog down here rather than waiting for
    Lua, because the dialog is the page's own and a handler that reopens one would
    otherwise race its own dismissal. The ANSWER is still entirely Lua's to act on. */
function answer(value: boolean): void {
  const current = dialog.value
  if (!current) return
  closeDialog()
  emit('opx:panel:answer', { handle: handle.value, id: current.id, value })
}

function blank(): void {
  clearHoverTimers()
  hovered = null
  open.value = false
  items.value = []
  page.value = 0
  query.value = ''
  closeDialog()
  Object.assign(view, emptyView())
}

useBridge('opx:panel:open', (payload: Payload) => {
  guard('panel:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    blank()
    handle.value = payload.handle
    apply(payload)
    open.value = true
    release = acquireFocus({
      id: 'panel',
      // `dismiss` is `close` or `ask` in the spec, and which one it is belongs to Lua.
      onEscape: () => emit('opx:panel:dismiss', { handle: handle.value })
    })
    void nextTick(measure)
  }, undefined)
})

useBridge('opx:panel:update', (payload: Payload) => {
  guard('panel:update', () => {
    if (!mine(payload)) return
    const before = currentTab.value
    apply(payload)
    if (payload.clearItems === true) items.value = []
    // A tab Lua switched under us resets the page and the filter, exactly as a tab the
    // player switched does: the query belonged to the list that is no longer shown.
    if (currentTab.value !== before) {
      page.value = 0
      query.value = ''
    }
  }, undefined)
})

useBridge('opx:panel:items', (payload: Payload) => {
  guard('panel:items', () => {
    if (!mine(payload)) return
    const batch: Item[] = []
    for (const entry of list<Payload>(payload.items)) {
      const id = text(entry.id)
      if (!id) continue
      const itemLabel = text(entry.label)
      const detail = text(entry.detail)
      batch.push({
        id,
        tab: text(entry.tab),
        label: itemLabel,
        detail,
        disabled: entry.disabled === true,
        search: `${itemLabel} ${detail} ${id}`.toLowerCase()
      })
    }
    // Appended: `opx:panel:items` is a batch, and a panel of 5000 rows arrives in
    // several. `clearItems` on an update is what empties the list.
    items.value = items.value.concat(batch)
    if (payload.done === true) view.loading = false
  }, undefined)
})

useBridge('opx:panel:confirm', (payload: Payload) => {
  guard('panel:confirm', () => {
    if (!mine(payload)) return
    // `id = false` takes the dialog down without an answer -- Lua withdrawing its own
    // question, which happens when the thing being confirmed stopped being true.
    const id = text(payload.id)
    if (id === '') {
      closeDialog()
      return
    }
    dialog.value = {
      id,
      title: text(payload.title),
      text: text(payload.text),
      yes: text(payload.yes),
      no: text(payload.no)
    }
    releaseDialog?.()
    /* A second owner OVER the panel's. Releasing it hands focus back to `panel`, which
       is the whole reason bridge/focus.ts is a stack: a confirm that released to nothing
       would leave a panel on screen that no longer answers the keyboard. */
    releaseDialog = acquireFocus({ id: 'panel.confirm', onEscape: () => answer(false) })
  }, undefined)
})

useBridge('opx:panel:close', (payload: Payload) => {
  guard('panel:close', () => {
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    blank()
    release?.()
    release = undefined
  }, undefined)
})

onMounted(() => {
  window.addEventListener('resize', measure)
  measure()
})

onUnmounted(() => {
  window.removeEventListener('resize', measure)
  clearHoverTimers()
  releaseDialog?.()
  release?.()
})

function chooseTab(id: string): void {
  if (id === currentTab.value) return
  // The page shows the new tab at once because the tab strip is a view of items it
  // already holds; `selected` -- what the tab CONTAINS -- still comes from Lua.
  view.tab = id
  page.value = 0
  query.value = ''
  clearHoverTimers()
  hovered = null
  emit('opx:panel:tab', { handle: handle.value, tab: id })
}

function choose(item: Item): void {
  if (item.disabled || view.busy) return
  emit('opx:panel:select', { handle: handle.value, item: item.id })
}

function press(button: Button): void {
  if (button.disabled || view.busy) return
  emit('opx:panel:action', { handle: handle.value, id: button.id })
}

function turn(delta: number): void {
  page.value = Math.max(0, Math.min(lastPage.value, page.value + delta))
}

function filter(value: string): void {
  query.value = value
  page.value = 0
}
</script>

<template>
  <div class="room" :class="{ open }">
    <!-- THE SCRIM. The largest fill on a surface that otherwise has none, and it
         stays: a panel is read for as long as it takes to choose something, and
         the street moving behind a list of names is the one backdrop this
         runtime cannot ask a player to read through. `InventoryView` dropped its
         scrim for the opposite reason -- a bag is read at a glance. -->
    <div class="scrim" :class="{ shown: open }" />

    <div class="stage">
      <div class="drawer">
        <section
          class="panel op-bay op-arete op-interlace op-ink"
          data-augmented-ui="tr-clip bl-clip border"
        >
          <header class="head">
            <div class="head-text">
              <span v-if="view.eyebrow" class="eyebrow op-eyebrow">{{ view.eyebrow }}</span>
              <h1>{{ view.title }}</h1>
            </div>
            <span v-if="view.subtitle" class="family">{{ view.subtitle }}</span>
            <!-- NOT augmented, and never will be: a clip is recomputed as the
                 element turns, so a spinner is the one shape that pays for the
                 cut on every frame of its animation. -->
            <span v-if="view.busy" class="spinner" aria-hidden="true" />
          </header>

          <div class="body">
            <p v-if="view.intro" class="intro op-copy">{{ view.intro }}</p>

            <nav v-if="view.tabs.length" class="tabs">
              <button
                v-for="tab in view.tabs"
                :key="tab.id"
                type="button"
                class="tab op-frame"
                :class="{ 'is-on': tab.id === currentTab }"
                data-augmented-ui="tr-clip border"
                @click="chooseTab(tab.id)"
              >
                {{ tab.label }}
              </button>
            </nav>

            <div v-if="view.summary" class="summary">
              <div class="row op-frame" data-augmented-ui="tr-clip border">
                <span class="row-label op-label">{{ view.summary.label }}</span>
                <span class="row-value op-value">{{ view.summary.value }}</span>
              </div>
              <button
                v-if="summaryAction"
                type="button"
                class="row button op-frame"
                :class="{ 'is-off': summaryAction.disabled || view.busy }"
                :disabled="summaryAction.disabled || view.busy"
                data-augmented-ui="tr-clip border"
                @click="press(summaryAction)"
              >
                <span class="row-label op-label">{{ summaryAction.label }}</span>
              </button>
            </div>

            <label v-if="view.search !== false" class="field op-frame" data-augmented-ui="tr-clip border">
              <span class="field-label op-eyebrow">{{ label('search') }}</span>
              <input
                class="field-entry"
                type="text"
                :value="query"
                :placeholder="searchPlaceholder"
                @input="filter(($event.target as HTMLInputElement).value)"
              >
            </label>

            <div ref="gridEl" class="grid" :class="{ busy: view.busy }" :style="gridStyle">
              <button
                v-for="item in visible"
                :key="item.id"
                type="button"
                class="row op-frame"
                :class="{
                  'is-on': item.id === chosen,
                  'op-lift': item.id === chosen,
                  'is-off': item.disabled || view.busy
                }"
                :disabled="item.disabled || view.busy"
                data-augmented-ui="tr-clip border"
                @click="choose(item)"
                @mouseenter="pointAt(item.id)"
                @mouseleave="pointAway"
              >
                <span class="row-label op-label">{{ item.label }}</span>
                <span v-if="item.detail" class="row-hint op-copy">{{ item.detail }}</span>
              </button>

              <p v-if="!visible.length" class="empty op-copy">
                {{ label(view.loading ? 'loading' : 'empty') }}
              </p>
            </div>

            <div v-if="shown.length > pageSize" class="pager">
              <button
                type="button"
                class="row button op-frame"
                :class="{ 'is-off': page === 0 }"
                :disabled="page === 0"
                data-augmented-ui="tr-clip border"
                @click="turn(-1)"
              >
                <span class="row-label op-label">&larr;</span>
              </button>
              <span class="count op-value">{{ count }}</span>
              <button
                type="button"
                class="row button op-frame"
                :class="{ 'is-off': page >= lastPage }"
                :disabled="page >= lastPage"
                data-augmented-ui="tr-clip border"
                @click="turn(1)"
              >
                <span class="row-label op-label">&rarr;</span>
              </button>
            </div>

            <p v-if="view.status" class="status op-copy" :class="view.status.kind">
              {{ view.status.text }}
            </p>
          </div>

          <footer v-if="view.actions.length" class="foot">
            <button
              v-for="button in view.actions"
              :key="button.id"
              type="button"
              class="row button grow op-frame"
              :class="{
                'is-on': button.primary,
                'is-off': button.disabled || view.busy
              }"
              :disabled="button.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="press(button)"
            >
              <span class="row-label op-label">{{ button.label }}</span>
            </button>
          </footer>
        </section>
      </div>

      <div v-if="view.tools.length" class="tools">
        <section class="panel op-bay op-arete op-ink" data-augmented-ui="tr-clip bl-clip border">
          <div class="body">
            <button
              v-for="button in view.tools"
              :key="button.id"
              type="button"
              class="row button op-frame"
              :class="{ 'is-off': button.disabled || view.busy }"
              :disabled="button.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="press(button)"
            >
              <span class="row-label op-label">{{ button.label }}</span>
            </button>
          </div>
        </section>
      </div>
    </div>

    <div v-if="dialog" class="confirm">
      <div class="scrim shown flat" />
      <div class="dialog">
        <section class="panel op-bay op-arete op-ink" data-augmented-ui="tr-clip bl-clip border">
          <header class="head">
            <h2>{{ dialog.title }}</h2>
          </header>
          <div class="body">
            <p class="ask op-copy">{{ dialog.text }}</p>
          </div>
          <footer class="foot">
            <button
              type="button"
              class="row button grow op-frame"
              data-augmented-ui="tr-clip border"
              @click="answer(false)"
            >
              <span class="row-label op-label">{{ dialog.no }}</span>
            </button>
            <button
              type="button"
              class="row button grow op-frame is-on op-lift"
              data-augmented-ui="tr-clip border"
              @click="answer(true)"
            >
              <span class="row-label op-label">{{ dialog.yes }}</span>
            </button>
          </footer>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped>
.room {
  position: absolute;
  inset: 0;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur) var(--op-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

.stage {
  position: absolute;
  left: var(--op-inset-x);
  top: var(--op-inset-y);
  bottom: var(--op-inset-y);
  right: var(--op-inset-x);
  display: flex;
  align-items: stretch;
  gap: var(--op-space-3);
}

.drawer {
  flex: 0 0 600px;
  display: flex;
  min-height: 0;
}

.tools {
  flex: 0 0 200px;
  display: flex;
  align-items: flex-start;
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  margin-right: auto;
  min-width: 0;
}

.head-text h1 {
  margin: 0;
  font: 700 var(--op-fs-head) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
}

.family {
  font: 400 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text-dim);
}

.intro {
  margin: 0 0 var(--op-space-2);
  font: 400 var(--op-fs-body) / 1.35 var(--op-font-body);
  color: var(--op-text-dim);
}

.summary {
  display: flex;
  gap: var(--op-space-1);
}

.summary > *:first-child {
  flex: 1;
}

/* The grid is the one place items are laid out two abreast. The frame around it is
   OpPanel's; every cell inside is a plain row. */
.grid {
  display: grid;
  grid-template-columns: repeat(var(--columns, 2), minmax(0, 1fr));
  gap: var(--op-space-1);
  align-content: start;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  transition: opacity var(--op-dur-fast) var(--op-ease);
}

.grid.busy {
  opacity: 0.55;
}

.empty {
  grid-column: 1 / -1;
  margin: var(--op-space-4) 0;
  text-align: center;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-faint);
}

.pager {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

.count {
  flex: 1;
  text-align: center;
  font: 400 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-dim);
  font-variant-numeric: tabular-nums;
}

.status {
  margin: 0;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  color: var(--op-text-dim);
}

.status.error {
  color: var(--op-alarm);
}

/* A button is a row with nothing on its right: the label centres and the plate shrinks
   to it. Scoped to this module, so OpRow stays one component and not two. */
.button {
  justify-content: center;
  cursor: pointer;
}

.grow {
  flex: 1;
}

.confirm {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}

.dialog {
  position: relative;
  display: flex;
  width: 420px;
}

.dialog h2 {
  margin: 0;
  font: 700 var(--op-fs-title) / 1.15 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
}

.ask {
  margin: 0;
  font: 400 var(--op-fs-body) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
}

/* =============================================================================
   THE PIECES THIS SURFACE USED TO IMPORT.

   `PanelView` was the last file on `design/components/*` -- `OpPanel`, `OpRow`,
   `OpField`, `OpTabs`, `OpScrim` and `OpSpinner`, six shared Vue components on
   the pass-01 idiom: filled, `--op77-accent` (which the Night City theme turned
   yellow), and augmented through a wrapper rather than by the element that
   needs the shape.

   They are not replaced by six new shared components. Every other surface in
   this runtime draws its own row, because a menu row, a target row, an
   inventory cell and a panel row look alike and behave nothing alike -- one
   shared row is what coupled five surfaces together last time, and unpicking it
   is most of what this rebuild was. What IS shared is the design system:
   `.op-frame`, `.op-bay`, `.op-arete`, the states, the type roles and the ink.
   A row here is that vocabulary plus the twenty lines below that are true of a
   panel row and of nothing else.
   ========================================================================== */

/* The wash behind the drawer. The one large fill on the surface, and the reason
   is in the template. */
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

/* Under the confirm dialog: flat and immediate, because the question is already
   on screen by the time it paints. */
.scrim.flat {
  opacity: 1;
  transition: none;
}

.panel {
  display: flex;
  flex: 1;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
  background: var(--op-plate);
}

.head {
  display: flex;
  align-items: flex-start;
  gap: var(--op-space-3);
  padding: var(--op-space-4) calc(var(--op-space-4) + var(--op-cut-lg))
    var(--op-space-3) var(--op-space-4);
  border-bottom: 1px solid var(--op-red-idle);
}

.head h2 {
  margin: 0;
  font: 700 var(--op-fs-title) / 1.15 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red);
}

.body {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 0;
  padding: var(--op-space-4);
  overflow-y: auto;
}

.foot {
  display: flex;
  gap: var(--op-space-2);
  padding: var(--op-space-3) var(--op-space-4)
    calc(var(--op-space-3) + var(--op-cut-lg)) var(--op-space-4);
  border-top: 1px solid var(--op-red-idle);
}

/* The spinner: a stroke that turns, and the one shape here that is not cut. */
.spinner {
  flex: none;
  width: 14px;
  height: 14px;
  border: 2px solid var(--op-red-idle);
  border-top-color: var(--op-red);
  border-radius: 50%;
  animation: panel-spin 700ms linear infinite;
}

@keyframes panel-spin {
  to {
    transform: rotate(360deg);
  }
}

.tabs {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
}

.tab {
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  cursor: pointer;
}

/* A ROW. Label, optional hint, optional value -- the states come from
   `.op-frame` and nothing about them is restated here. */
.row {
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  width: 100%;
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  text-align: left;
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

.row:disabled {
  cursor: default;
}

.row-label {
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.row-hint {
  flex: 1 1 auto;
  min-width: 0;
  opacity: 0.7;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.row-value {
  flex: none;
  margin-left: auto;
}

/* THE ONE FIELD. The caret is the only thing on this surface allowed to blink,
   and the input itself is transparent: the frame and the ground belong to the
   label that wraps it, which is the element that carries the shape. */
.field {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-3);
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

.field-label {
  flex: none;
  color: var(--op-red-idle);
}

.field-entry {
  flex: 1;
  min-width: 0;
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background: transparent;
  font: 400 var(--op-fs-body) / 1.3 var(--op-font-body);
  color: var(--op-text);
  caret-color: var(--op-red);
}

.field-entry::placeholder {
  color: var(--op-text-faint);
}
</style>
