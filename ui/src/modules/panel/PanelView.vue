<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
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
  marked: boolean
  disabled: boolean
}

/**
 * THE PANEL -- and, in practice, the fitting room, because nothing else opens one.
 *
 * The mouse-driven surface, and the resource the handle pattern was taken from: Lua
 * opens with a spec and keeps the handle, every payload in either direction carries it,
 * and a message whose handle is not the open one is dropped rather than applied.
 *
 * Three things the page decides for itself, and only these three, because none of them
 * is a fact about the world:
 *  - the search filter, over items Lua has already sent;
 *  - where the dial is standing, and therefore which slice of the list is drawn;
 *  - whether the confirm dialog is on screen.
 * Everything else is Lua's answer, applied verbatim. The panel does not select an item
 * because it was clicked; it says it was clicked and waits for `selected` to come back.
 *
 * ── WHAT THIS SCREEN IS, AND WHY IT IS LAID OUT LIKE THIS ───────────────────────────
 *
 * A player dressing a character is looking at the character. Everything here is
 * arranged around that one fact, which the previous layout did not concede: it filled
 * the screen with a scrim, put a 600px drawer down the middle-left with a title block
 * on top of it, and paged a two-column wall of names. The body was behind all of it.
 *
 * So: NO SCRIM -- the room is transparent and the player watches their own character
 * through it. NO HEADER -- the tab strip is the first thing in the column and it says
 * what the screen is by naming the seven slots, which is more than 'WARDROBE' ever
 * said. `eyebrow`, `title` and `subtitle` still arrive and are simply not drawn; that
 * is `MenuView`'s precedent for the same decision, and the cost is the same -- the
 * panel no longer names itself, and a second caller would have to live with that.
 * `intro` IS drawn, because it is the one of the four that states something the screen
 * cannot show: that nothing is kept until you save.
 *
 * ── THE DIAL, WHICH IS WHERE THE SLIDER WENT ────────────────────────────────────────
 *
 * Browsing a slot's pieces is one-dimensional and ordered, every step has a visible
 * consequence on the body, and the seam already carries a preview -- `hover` shows a
 * piece without choosing it and `select` chooses it. That is a slider, exactly: drag,
 * and the body wears what is under the thumb; let go, and that is your choice.
 * `@input` previews through the same debounced hover a pointer uses, `@change` commits.
 * A keyboard does both per arrow press, which is the behaviour you want.
 *
 * It replaced the pager, not the list. The list is still under the dial as a window
 * that follows the thumb, because a slider with no names beside it tells the player
 * nothing about where they are, and clicking a row is still the precise way to land on
 * one. `columns` keeps meaning what it meant: how many of that window sit abreast.
 *
 * ── THE SLOT BAR, WHICH IS THE DIAL WITHOUT THE LIST ────────────────────────────────
 *
 * A caller that sends `sliders` instead of items gets a different screen: a row of
 * tracks along the bottom, one per slot, all of them on screen at once. Everything
 * above -- the column, the tabs, the window, the search plate -- is not drawn, because
 * there is nothing in it. The caller kept its lists; what crossed is a COUNT per
 * slider and the one label under the thumb.
 *
 * WHY THERE IS NO TAB STRIP AND NO ENCLOSURE. Seven sliders are seven controls and a
 * tab strip exists to show one of seven things at a time, so the strip has nothing
 * left to switch between. And `ui/README.md` rule 2 settles the frame: a control is a
 * closed box, and what is NOT a control does not get one. The bar is not a control --
 * it is a row of them -- so the `.op-bay` goes, and rule 9 takes the interlace with it,
 * since the interlace belongs to what is enclosed. What holds the row together is the
 * row itself, a rule above it, and the cut corner each control carries. Rule 5 keeps it
 * flat: a centred surface takes no tilt.
 *
 * THE THUMB IS THE PAGE'S, THE INDEX IS THE CALLER'S. `@input` previews through a
 * debounce and `@change` commits, exactly as the dial does -- but a drag outruns the
 * answers, so the page holds its own position per slot while the player is on it and
 * lets the caller's index win again the moment they let go. That is how a refused
 * piece puts the thumb back: the caller answers with the index it still believes in.
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

/** One named range. `count` is how many positions it has past 0, and 0 is a real
    position -- it is how a caller offers "none of them" without a second control. */
interface Slider {
  id: string
  label: string
  count: number
  index: number
  value: string
  disabled: boolean
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
  /** Arrives and is not drawn. See the header. */
  eyebrow: string
  title: string
  subtitle: string
  intro: string
  tabs: Tab[]
  tab: string
  /** One control per named range. Non-empty is what puts the slot bar on screen
      instead of the column; see the header. */
  sliders: Slider[]
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

/* panel.js's numbers, kept: the window is sized by measured height, so a column that is
   short on one screen and tall on another shows what fits rather than a fixed count. */
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
    sliders: [],
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
/** Where the dial is standing, as an index into the filtered list. */
const cursor = ref(0)
const query = ref('')
const dialog = ref<Dialog | null>(null)

/** Where the player is holding each slot's thumb, for slots they have touched. It
    is dropped for a slot as soon as the caller answers about it -- unless they are
    still dragging that one, because a drag outruns the answers and a thumb yanked
    back under a finger is worse than a label a frame behind. */
const thumb = reactive<Record<string, number>>({})

const gridEl = ref<HTMLElement | null>(null)
const gridHeight = ref(0)

let hovered: string | null = null
let hoverTimer: ReturnType<typeof setTimeout> | undefined
let leaveTimer: ReturnType<typeof setTimeout> | undefined
let slideTimer: ReturnType<typeof setTimeout> | undefined
/** The slot whose thumb is under the pointer, or null. */
let dragging: string | null = null
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
  // Kept, and not drawn. The three of them are the header this screen no longer has;
  // holding them means a caller is not silently refused and a later surface may draw
  // them again without a contract change.
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
  if (given('sliders')) {
    const incoming = list<Payload>(payload.sliders).map((entry) => ({
      id: text(entry.id),
      label: text(entry.label),
      count: Math.max(0, num(entry.count)),
      index: Math.max(0, num(entry.index)),
      value: text(entry.value),
      disabled: entry.disabled === true
    }))
    // The caller has spoken about these slots, so its index is the truth again --
    // for every one of them except the slot still under the player's finger.
    for (const entry of incoming) if (dragging !== entry.id) delete thumb[entry.id]
    view.sliders = incoming
  }
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

/** The dial's real position. `cursor` is clamped here rather than on write, because the
    list shrinks under it: a batch arriving, a tab changing and a keystroke in the search
    field all move the floor without the player touching the dial. */
const at = computed(() => Math.max(0, Math.min(cursor.value, shown.value.length - 1)))

const windowSize = computed(() => {
  const rows = Math.max(1, Math.floor((gridHeight.value + ROW_GAP) / (ROW_HEIGHT + ROW_GAP)))
  return rows * (view.columns === 1 ? 1 : 2)
})

/* The window follows the thumb instead of jumping a page at a time, and it stops at both
   ends rather than centring on a position the list does not have. */
const windowStart = computed(() => {
  const size = windowSize.value
  const last = Math.max(0, shown.value.length - size)
  return Math.max(0, Math.min(at.value - Math.floor(size / 2), last))
})

const visible = computed(() =>
  shown.value.slice(windowStart.value, windowStart.value + windowSize.value)
)

const count = computed(() => {
  if (shown.value.length === 0) return ''
  return label('count', {
    from: windowStart.value + 1,
    to: Math.min(shown.value.length, windowStart.value + windowSize.value),
    total: shown.value.length
  })
})

const gridStyle = computed(() => `--columns: ${view.columns}`)

/** `search` carries two things -- whether the plate is drawn and what it says -- so the
    template gets a string and the `v-if` gets the boolean. */
const searchPlaceholder = computed(() => (view.search === false ? '' : view.search))

const summaryAction = computed(() => view.summary?.action ?? null)

/** Where in the filtered list Lua's own choice sits, or the top when it is not in it. */
function indexOfChosen(): number {
  if (chosen.value === '') return 0
  const found = shown.value.findIndex((item) => item.id === chosen.value)
  return found < 0 ? 0 : found
}

/* THE DIAL FOLLOWS LUA, NOT THE OTHER WAY ROUND. A tab the player opened, and a choice
   Lua made -- including `remove`, which sets the slot to nothing -- both move the thumb
   to where the truth now is. Without this the dial would still be standing over the
   jacket the player just took off. */
watch([currentTab, chosen], () => {
  cursor.value = indexOfChosen()
})

/* A new filter is a new list, and an index into the old one means nothing in it. */
watch(query, () => {
  cursor.value = 0
})

function measure(): void {
  gridHeight.value = gridEl.value?.clientHeight ?? 0
}

function clearHoverTimers(): void {
  if (hoverTimer !== undefined) clearTimeout(hoverTimer)
  if (leaveTimer !== undefined) clearTimeout(leaveTimer)
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  hoverTimer = undefined
  leaveTimer = undefined
  slideTimer = undefined
}

/** Debounced both ways: a pointer crossing a grid must not raise an event per row, and
    a pointer that left for two frames on its way to the next row has not left. A dial
    dragged across four hundred pieces is the same problem with a different input, so it
    goes through the same gate. */
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
  dragging = null
  for (const key of Object.keys(thumb)) delete thumb[key]
  open.value = false
  items.value = []
  cursor.value = 0
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
    // A tab Lua switched under us resets the filter, exactly as a tab the player
    // switched does: the query belonged to the list that is no longer shown. The dial
    // is moved by the watcher above, which sees the same change.
    if (currentTab.value !== before) query.value = ''
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
    // Appended: `opx:panel:items` is a batch, and a catalogue of five thousand rows
    // arrives in many. `clearItems` on an update is what empties the list.
    items.value = items.value.concat(batch)
    if (payload.done === true) {
      view.loading = false
      // The dial could not stand on Lua's choice while the piece had not arrived yet.
      cursor.value = indexOfChosen()
    }
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
  query.value = ''
  clearHoverTimers()
  hovered = null
  emit('opx:panel:tab', { handle: handle.value, tab: id })
}

function choose(item: Item): void {
  if (item.disabled || view.busy) return
  emit('opx:panel:select', { handle: handle.value, item: item.id })
}

/** A row clicked: the dial moves to it as well, so the two never disagree. */
function pick(item: Item, offset: number): void {
  cursor.value = windowStart.value + offset
  choose(item)
}

/** The thumb moved: preview only. Committing on every intermediate value of a drag
    would put four hundred selections through the seam for one gesture. */
function scrub(raw: string): void {
  const length = shown.value.length
  if (length === 0) return
  const index = Math.max(0, Math.min(length - 1, Math.trunc(Number(raw)) || 0))
  cursor.value = index
  const item = shown.value[index]
  if (item && !item.disabled) pointAt(item.id)
}

/** The thumb let go, or an arrow key pressed: that is the choice. */
function settle(): void {
  const item = shown.value[at.value]
  if (item) choose(item)
}

/* ── the slot bar ───────────────────────────────────────────────────────────── */

/** Where one slot's thumb is drawn: the player's hold on it, or the caller's index.
    Clamped against the caller's count, because a track can shrink under a hold. */
function standing(slider: Slider): number {
  const held = thumb[slider.id]
  return held === undefined ? Math.min(slider.index, slider.count) : Math.min(held, slider.count)
}

/** One slot's thumb moved: preview only, and debounced through the same gate the
    pointer uses. Committing every intermediate value of a drag would put four
    hundred choices across the seam for one gesture. */
function scrubSlot(slider: Slider, raw: string): void {
  if (view.busy || slider.disabled) return
  const next = Math.max(0, Math.min(slider.count, Math.trunc(Number(raw)) || 0))
  thumb[slider.id] = next
  dragging = slider.id
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = setTimeout(() => {
    slideTimer = undefined
    if (handle.value === null) return
    emit('opx:panel:slide',
      { handle: handle.value, id: slider.id, index: next, commit: false })
  }, HOVER_MS)
}

/** Let go, or an arrow key pressed: that is the choice, and it does not wait. */
function settleSlot(slider: Slider): void {
  if (view.busy || slider.disabled) return
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = undefined
  dragging = null
  if (handle.value === null) return
  emit('opx:panel:slide',
    { handle: handle.value, id: slider.id, index: standing(slider), commit: true })
}

/** A number typed straight in: the same choice an arrow press makes, without the
    walk. Committed at once rather than previewed, because typing a number is a
    destination and not a browse -- there is no intermediate value to show.

    THE FIELD IS WRITTEN BACK after clamping. `:value` follows `standing`, so Vue
    repaints whenever the thumb actually moves -- but typing 900 into a range of
    12 lands on 12, and if the thumb was ALREADY on 12 nothing changed and the
    box would sit there reading 900. */
function jumpSlot(slider: Slider, field: HTMLInputElement): void {
  if (view.busy || slider.disabled) return
  const raw = field.value.trim()
  // An empty box is somebody mid-edit, not a request to wear nothing: `Number('')`
  // is 0, which would silently undress the slot on a backspace.
  if (raw === '') {
    field.value = String(standing(slider))
    return
  }
  const wanted = Math.trunc(Number(raw))
  if (!Number.isFinite(wanted)) {
    field.value = String(standing(slider))
    return
  }

  const next = Math.max(0, Math.min(slider.count, wanted))
  field.value = String(next)
  thumb[slider.id] = next
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = undefined
  dragging = null
  if (handle.value === null) return
  emit('opx:panel:slide', { handle: handle.value, id: slider.id, index: next, commit: true })
}

function press(button: Button): void {
  if (button.disabled || view.busy) return
  emit('opx:panel:action', { handle: handle.value, id: button.id })
}

function filter(value: string): void {
  query.value = value
}
</script>

<template>
  <div class="room" :class="{ open }">
    <!-- NO SCRIM, AND THAT IS THE POINT OF THE SCREEN. The old one covered the
         whole surface with `--op-plate-quiet` and defended it: "a panel is read
         for as long as it takes to choose something". True of a list of elevator
         floors; false of a fitting room, where the thing being chosen is only
         visible THROUGH the panel. The body is the content. If a second caller
         ever needs a wash behind a long read, it belongs on that caller's spec,
         not on every panel. -->

    <!-- THE COLUMN IS ON THE LEFT AND HINGED THERE. `.op-plane` carries the
         perspective and the containment; `.op-anchor-left` is what makes the
         tilt +7deg about the left edge rather than a spin about the middle.

         It is the screen for a caller that sent ITEMS. A caller that sent
         sliders kept its lists, so there is no window to draw, no tab to
         switch, nothing to search and no summary to read: the slot bar below
         is that caller's whole screen. -->
    <section v-if="!view.sliders.length" class="column op-plane op-anchor-left op-ink">
      <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <!-- NO INTERLACE. It exists to stop an unfilled frame reading as a web
             page floating in the air, and it earned its place over a plate. With
             the plate gone it is stripes over the player's own body, which is the
             fill this pass is removing -- the frame and the lit leading edge are
             what hold the surface down now. -->
        <div class="bay-inner">
          <!-- THE TAB STRIP IS THE HEADING. Seven named slots, each saying
               whether something is on it, is a better answer to "what is this
               screen" than the word WARDROBE was. -->
          <nav v-if="view.tabs.length" class="tabs">
            <button
              v-for="tab in view.tabs"
              :key="tab.id"
              type="button"
              class="tab op-frame"
              :class="{ 'is-on': tab.id === currentTab, 'is-off': tab.disabled }"
              :disabled="tab.disabled"
              data-augmented-ui="tr-clip border"
              @click="chooseTab(tab.id)"
            >
              {{ tab.label }}
              <!-- A slot with something on it. A mark, not a frame: what is not a
                   control does not get one. -->
              <span v-if="tab.marked" class="mark" aria-hidden="true">&bull;</span>
            </button>
          </nav>

          <p v-if="view.intro" class="intro op-copy">{{ view.intro }}</p>

          <label
            v-if="view.search !== false"
            class="field op-frame"
            data-augmented-ui="tr-clip border"
          >
            <span class="field-label op-eyebrow">{{ label('search') }}</span>
            <input
              class="field-entry"
              type="text"
              :value="query"
              :placeholder="searchPlaceholder"
              @input="filter(($event.target as HTMLInputElement).value)"
            >
          </label>

          <!-- THE DIAL. Only drawn when there is somewhere to travel: one piece
               is not a range, and a track with a thumb that cannot move is a
               control that lies about what it does. -->
          <div
            v-if="shown.length > 1"
            class="dial op-frame"
            :class="{ 'is-off': view.busy }"
            data-augmented-ui="tr-clip border"
          >
            <input
              class="dial-track"
              type="range"
              min="0"
              :max="shown.length - 1"
              step="1"
              :value="at"
              :disabled="view.busy"
              :aria-label="view.summary?.label ?? ''"
              :aria-valuetext="shown[at]?.label ?? ''"
              @input="scrub(($event.target as HTMLInputElement).value)"
              @change="settle"
            >
          </div>

          <div ref="gridEl" class="grid" :class="{ busy: view.busy }" :style="gridStyle">
            <button
              v-for="(item, offset) in visible"
              :key="item.id"
              type="button"
              class="row op-frame"
              :class="{
                'is-on': item.id === chosen,
                'op-lift': item.id === chosen,
                'is-hover': item.id !== chosen && windowStart + offset === at,
                'is-off': item.disabled || view.busy
              }"
              :disabled="item.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="pick(item, offset)"
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

          <!-- A READOUT, SO NO FRAME. Where the window sits in the list, and the
               one mark that says the runtime is still working. -->
          <div v-if="count || view.busy" class="readout">
            <span class="count op-value">{{ count }}</span>
            <!-- NOT augmented, and never will be: a clip is recomputed as the
                 element turns, so a spinner is the one shape that pays for the
                 cut on every frame of its animation. -->
            <span v-if="view.busy" class="spinner" aria-hidden="true" />
          </div>

          <!-- WHAT IS ON THE SLOT, next to the buttons that commit it, because
               this is the line a player reads before pressing Save. It used to
               sit above the search field, which is where you look when you have
               not chosen yet. -->
          <div v-if="view.summary" class="summary">
            <div class="plate">
              <span class="plate-label op-eyebrow">{{ view.summary.label }}</span>
              <span class="plate-value op-value">{{ view.summary.value }}</span>
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
              'op-lift': button.primary && !button.disabled && !view.busy,
              'is-off': button.disabled || view.busy
            }"
            :disabled="button.disabled || view.busy"
            data-augmented-ui="tr-clip border"
            @click="press(button)"
          >
            <span class="row-label op-label">{{ button.label }}</span>
          </button>
        </footer>
      </div>
    </section>

    <!-- THE CAMERA, BOTTOM RIGHT, IN ONE ROW. It is the only cluster on this
         screen that does not change what the character wears, so it is the only
         one that belongs away from the column -- and the far corner is the one
         place a control can sit without standing in front of the body. Hinged on
         the right edge, so `.is-end` mirrors the lit edge to match. -->
    <div v-if="view.tools.length && !view.sliders.length"
         class="tools op-plane op-anchor-right op-ink">
      <div class="tool-row op-bay op-arete is-end" data-augmented-ui="tr-clip bl-clip border">
        <button
          v-for="button in view.tools"
          :key="button.id"
          type="button"
          class="row button tool op-frame"
          :class="{ 'is-off': button.disabled || view.busy }"
          :disabled="button.disabled || view.busy"
          data-augmented-ui="tr-clip border"
          @click="press(button)"
        >
          <span class="row-label op-label">{{ button.label }}</span>
        </button>
      </div>
    </div>

    <!-- =====================================================================
         THE SLOT BAR. One control per slot, all of them along the bottom, and
         nothing above them: the body is what the player is looking at and this
         screen exists to stay out of its way.

         THE DOCK IS A STACK, NOT A CORNER. The camera cluster used to sit
         bottom-right on its own, which is a place a centred bar reaches on a
         narrow screen -- so it is lifted into the same column, right-aligned
         above the bar. It keeps its own plane and its own -7deg hinge; the bar
         under it is centred and therefore takes neither.
         ================================================================== -->
    <div v-if="view.sliders.length" class="dock">
      <div v-if="view.tools.length" class="tools op-plane op-anchor-right op-ink">
        <div class="tool-row op-bay op-arete is-end" data-augmented-ui="tr-clip bl-clip border">
          <button
            v-for="button in view.tools"
            :key="button.id"
            type="button"
            class="row button tool op-frame"
            :class="{ 'is-off': button.disabled || view.busy }"
            :disabled="button.disabled || view.busy"
            data-augmented-ui="tr-clip border"
            @click="press(button)"
          >
            <span class="row-label op-label">{{ button.label }}</span>
          </button>
        </div>
      </div>

      <!-- NO ENCLOSURE AND NO INTERLACE. `ui/README.md` rule 2: a control is a
           closed box and what is not a control does not get a frame. This bar
           is a row OF controls, not one, so the `.op-bay` goes -- and rule 9
           takes the interlace with it, because the interlace belongs to what is
           enclosed and a striped rectangle with nothing round it is exactly the
           floating rectangle it exists to prevent. The rule above the row and
           the cut corner on every slot are what hold it together. -->
      <section class="bar op-plane op-ink">
        <div class="bar-inner">
          <p v-if="view.intro" class="lead op-copy">{{ view.intro }}</p>
          <p v-if="view.status" class="status op-copy" :class="view.status.kind">
            {{ view.status.text }}
          </p>

          <div class="slots">
            <div
              v-for="slider in view.sliders"
              :key="slider.id"
              class="slot op-frame"
              :class="{
                'is-on': standing(slider) > 0 && !slider.disabled && !view.busy,
                'is-off': slider.disabled || view.busy || slider.count === 0
              }"
              data-augmented-ui="tr-clip border"
            >
              <span class="slot-name op-eyebrow">{{ slider.label }}</span>
              <span class="slot-value op-value">{{ slider.value }}</span>
              <input
                class="slot-track"
                type="range"
                min="0"
                :max="slider.count"
                step="1"
                :value="standing(slider)"
                :disabled="slider.disabled || view.busy || slider.count === 0"
                :aria-label="slider.label"
                :aria-valuetext="slider.value"
                @input="scrubSlot(slider, ($event.target as HTMLInputElement).value)"
                @change="settleSlot(slider)"
              >
              <!-- THE READOUT IS NOW A WAY IN. It was required technical filler
                   under rule 8 -- where the thumb stands, in a range the player
                   cannot otherwise see the size of -- and it still states that.
                   But a track is a poor instrument for "piece 47 of 300": a
                   pointer drag overshoots and an arrow key takes forty-seven
                   presses, so the number you are already being shown is the
                   number you can type.
                   A CONTROL IS A CLOSED BOX (rule 2), so it takes the frame and
                   the chamfer, exactly like `.field` does. -->
              <label class="slot-step op-frame" data-augmented-ui="tr-clip border">
                <input
                  class="slot-number op-eyebrow"
                  type="number"
                  inputmode="numeric"
                  min="0"
                  :max="slider.count"
                  :value="standing(slider)"
                  :disabled="slider.disabled || view.busy || slider.count === 0"
                  :aria-label="slider.label"
                  @keydown.stop
                  @keyup.enter="jumpSlot(slider, $event.target as HTMLInputElement)"
                  @change="jumpSlot(slider, $event.target as HTMLInputElement)"
                >
                <span class="slot-of op-eyebrow">/ {{ slider.count }}</span>
              </label>
            </div>
          </div>
        </div>

        <footer v-if="view.actions.length" class="foot acts">
          <button
            v-for="button in view.actions"
            :key="button.id"
            type="button"
            class="row button act op-frame"
            :class="{
              'is-on': button.primary,
              'op-lift': button.primary && !button.disabled && !view.busy,
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

    <div v-if="dialog" class="confirm">
      <!-- THE ONE FILL LEFT ON THIS SURFACE, and it stays. A yes-or-no question
           over a live street is the one thing here that must not be read
           through. It is also the one surface that takes no tilt: rotating a
           centred plane about its middle is paper on a spindle. -->
      <div class="scrim" />
      <div class="dialog op-ink">
        <section class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
          <div class="bay-inner">
            <h2>{{ dialog.title }}</h2>
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

/* =============================================================================
   THE TWO CLUSTERS.

   Both are positioned wrappers carrying `.op-plane`, which owns the perspective
   and the paint containment; the anchor class only says which edge it is hinged
   on. EVERY OFFSET PAYS THE BLEED BACK -- `.op-plane` pads by `--op-bleed` so a
   bloom has room inside the containment, and padding moves the wrapper, so each
   offset subtracts exactly what it added.
   ========================================================================== */
.column {
  position: absolute;
  left: calc(var(--op-inset-x) - var(--op-bleed));
  top: calc(var(--op-inset-y) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  /* Narrow on purpose. The drawer was 600px and the body was behind it. */
  width: 420px;
  display: flex;
}

.tools {
  position: absolute;
  right: calc(var(--op-inset-x) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  display: flex;
}

/* Neither cluster fades on its own: `.room` above owns the opacity and the
   pointer for the whole surface, and a second transition on each would be two
   curves running the same change at different speeds. */

/* NO GROUND ON THE ENCLOSURE, and this is the last of the three passes that
   argument has taken. The scrim went first, then the wash over the whole
   surface, and the plate on this bay was what was left: the body is the content
   of this screen and a filled column stands in front of it. The frame stays --
   the cut corners and the lit leading edge are what say this is a surface rather
   than text lying on the street -- and the ground goes where the contract puts
   it, under the type: every row, tab and button here is an `.op-frame` and
   carries its own. */
.bay {
  display: flex;
  flex: 1;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
}

/* THE ONE FILL LEFT, and the file already says why: a yes-or-no question over a
   live street is the one thing here that must not be read through. It is scoped
   to the dialog now, because the bay above no longer has one to inherit. */
.dialog .bay {
  background: var(--op-plate);
}

.bay-inner {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 0;
  padding: var(--op-space-4);
  padding-top: calc(var(--op-space-4) + var(--op-cut-lg));
}

/* Unfilled for the same reason the column is, and more so: this cluster sits in
   the corner the body is framed against. Its four buttons each carry the ground
   the contract allows. */
.tool-row {
  flex: none;
  display: flex;
  gap: var(--op-space-2);
  padding: var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-lg));
}

.tool {
  flex: none;
  min-width: 78px;
  justify-content: center;
}

.foot {
  display: flex;
  gap: var(--op-space-2);
  padding: var(--op-space-3) var(--op-space-4)
    calc(var(--op-space-3) + var(--op-cut-lg)) var(--op-space-4);
  border-top: 1px solid var(--op-red-idle);
}

.tabs {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
}

.tab {
  display: flex;
  align-items: center;
  gap: var(--op-space-1);
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  cursor: pointer;
}

.mark {
  color: var(--op-red);
}

.intro {
  margin: 0;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
}

/* =============================================================================
   THE DIAL.

   The container carries the shape, as everything here does: augmented-ui needs
   a real element and a slider's track and thumb are user-agent pseudo-elements,
   so the frame is the box around the control and the parts inside it are drawn
   with the tokens by hand. That is the same exception the spinner takes, for the
   same kind of reason.
   ========================================================================== */
.dial {
  display: flex;
  align-items: center;
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

/* The track itself is written once for both sliders on this surface -- the
   column's dial and every slot on the bar. It is the vocabulary being shared,
   not the markup: the two are laid out differently, labelled differently and
   answered differently, and only the four pseudo-elements are the same. */
.dial-track,
.slot-track {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: var(--op-space-5);
  margin: 0;
  background: transparent;
  cursor: pointer;
}

.dial-track:disabled,
.slot-track:disabled {
  cursor: default;
}

/* A 1px rule, not a filled bar: nothing on this surface is filled. */
.dial-track::-webkit-slider-runnable-track,
.slot-track::-webkit-slider-runnable-track {
  height: 1px;
  background: var(--op-red-idle);
}

/* The thumb is a control, so it is a closed box with the top-right corner taken
   off -- by `clip-path` off the same cut token, because a pseudo-element cannot
   carry `data-augmented-ui`. No literal: change `--op-cut-sm` and this follows. */
.dial-track::-webkit-slider-thumb,
.slot-track::-webkit-slider-thumb {
  -webkit-appearance: none;
  appearance: none;
  width: var(--op-space-4);
  height: var(--op-space-5);
  margin-top: calc(var(--op-space-5) / -2);
  border: 2px solid var(--op-red);
  background: var(--op-plate-lit);
  clip-path: polygon(
    0 0,
    calc(100% - var(--op-cut-sm)) 0,
    100% var(--op-cut-sm),
    100% 100%,
    0 100%
  );
}

.dial-track:focus-visible::-webkit-slider-thumb,
.slot-track:focus-visible::-webkit-slider-thumb {
  border-color: var(--op-red-hi);
}

.dial-track:disabled::-webkit-slider-thumb,
.slot-track:disabled::-webkit-slider-thumb {
  border-color: var(--op-text-faint);
}

/* =============================================================================
   THE SLOT BAR.

   A row of controls along the bottom and no box round them. `ui/README.md` rule
   2 is what decides that: a control is a closed box, and what is not a control
   does not get a frame -- so each slot keeps its `.op-frame` and the thing
   holding them together does not get one. Rule 9 takes the interlace with the
   enclosure, since the interlace is what stops an unfilled FRAME floating and
   there is no longer a frame here to float. Rule 5 keeps the bar flat: it is
   centred, and a centred plane rotated about its middle is paper on a spindle.

   What is left to give it structure is the row itself -- seven cut boxes on one
   baseline read as one thing -- and the 1px rule between browsing and
   committing. That rule is `.foot`, which the column uses for the same job.
   ========================================================================== */
.dock {
  position: absolute;
  left: calc(var(--op-inset-x) - var(--op-bleed));
  right: calc(var(--op-inset-x) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  display: flex;
  flex-direction: column;
  align-items: stretch;
}

/* THE CAMERA CLUSTER IS IN THE STACK, NOT IN THE CORNER. On its own it is
   absolutely placed bottom-right, which is a place a centred bar reaches as soon
   as the screen is narrow. Here it is a row above the bar and still hinged on
   its own right edge, so `.op-anchor-right` and `.is-end` still say what they
   said. */
.dock .tools {
  position: static;
  align-self: flex-end;
}

.bar {
  align-self: center;
  display: flex;
  flex-direction: column;
  width: 100%;
  max-width: 1120px;
}

.bar-inner {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
}

/* Centred readouts, no frame: neither of them is a control. */
.lead,
.bar .status {
  margin: 0;
  text-align: center;
  color: var(--op-text-dim);
}

.slots {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
}

/* Every slot the same width, so the row reads as one control repeated rather
   than as seven things that happen to be next to each other. They wrap rather
   than shrink past legibility on a narrow surface. */
.slot {
  flex: 1 1 130px;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

.slot-name {
  color: var(--op-red-idle);
}

.slot-value {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Now a control, so it is a closed box like every other one (rule 2). Kept to
   the width of its content and pushed to the slot's right edge, which is where
   the readout already sat -- a player who never types into it should not be
   able to tell it changed. */
.slot-step {
  align-self: flex-end;
  display: flex;
  align-items: baseline;
  gap: var(--op-space-1);
  padding: 0 calc(var(--op-space-2) + var(--op-cut-sm)) 0 var(--op-space-2);
  color: var(--op-text-faint);
  font-variant-numeric: tabular-nums;
}

/* Three digits' worth and no spinners: the arrows a number input draws are a
   second, worse slider sitting beside the real one, and on this surface they
   are also the one piece of chrome nothing in the theme can style. */
.slot-number {
  width: 3ch;
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background: transparent;
  text-align: right;
  font: inherit;
  font-variant-numeric: tabular-nums;
  color: var(--op-text);
  caret-color: var(--op-red);
  -moz-appearance: textfield;
  appearance: textfield;
}

.slot-number::-webkit-outer-spin-button,
.slot-number::-webkit-inner-spin-button {
  margin: 0;
  -webkit-appearance: none;
  appearance: none;
}

.slot-number:disabled {
  color: var(--op-text-faint);
}

/* The frame answers the keyboard, because the box is small and the caret alone
   is not enough to say which of seven slots is taking the digits. */
.slot-step:focus-within {
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  color: var(--op-text-dim);
}

/* The commit row. It takes the rule and not the bay's bottom cut, because there
   is no bay under it to leave room for. */
.acts {
  justify-content: center;
  padding: var(--op-space-3) 0 0;
}

.acts .row {
  width: auto;
  min-width: 150px;
}

/* The window of names under the dial. One place items are laid out abreast; the
   frame around it is the bay's, and every cell inside is a plain row. */
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

.readout {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

.count {
  flex: 1;
  font: 400 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-dim);
  font-variant-numeric: tabular-nums;
}

/* The chosen piece: a readout and a rule, no frame, because it is not a control.
   The one button beside it is. */
.summary {
  display: flex;
  align-items: stretch;
  gap: var(--op-space-2);
  padding-top: var(--op-space-2);
  border-top: 1px solid var(--op-red-idle);
}

.plate {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  justify-content: center;
}

.plate-label {
  color: var(--op-red-idle);
}

.plate-value {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
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

.scrim {
  position: absolute;
  inset: 0;
  background: var(--op-plate-quiet);
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
  color: var(--op-red);
}

.ask {
  margin: 0;
  font: 400 var(--op-fs-body) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
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

/* =============================================================================
   A ROW -- label, optional hint. The states come from `.op-frame` and nothing
   about them is restated here.

   There is no shared row component and that is deliberate: a menu row, a target
   row, an inventory cell and a panel row look alike and behave nothing alike.
   What is shared is the vocabulary -- `.op-frame`, `.op-bay`, `.op-arete`, the
   states, the type roles and the ink -- not the markup.
   ========================================================================== */
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
