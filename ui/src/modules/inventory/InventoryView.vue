<script setup lang="ts">
import { computed, onUnmounted, reactive, ref, shallowRef } from 'vue'
import OpGauge from '@/design/components/OpGauge.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import OpScrim from '@/design/components/OpScrim.vue'
import OpTabs from '@/design/components/OpTabs.vue'
import type { Tab } from '@/design/components/OpTabs.vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import { emit as send } from '@/bridge/channel'
import { guard, report } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { BridgeError, request } from '@/bridge/rpc'
import { bool, table } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import InventoryGrid from './InventoryGrid.vue'
import { ammoOf, durabilityOf, grams, labelOf, loadPercent, serialOf, weightOf } from './format'
import {
  readCatalogEntry,
  readConfig,
  readContainer,
  readNearby,
  readTabs
} from './types'
import type { CatalogEntry, Container, Handle, NearbyPlayer, ScreenConfig, TabSpec } from './types'

/**
 * THE INVENTORY -- the bag on the left, whatever is open beside it on the right.
 *
 * THE PAGE SENDS INTENTS. It reports that the player dragged slot 3 of container
 * 41 onto slot 9 of container 58. Whether that is a move, a stack, a swap or a
 * refusal is decided in Lua, along with what the bag then weighs. Nothing here
 * writes a count, a weight or a slot; every number drawn is one Lua last pushed.
 *
 * The handle: Lua opens with a spec carrying a handle, every emit echoes it, and
 * a payload carrying a different one belongs to a screen that has been replaced
 * and is dropped. A staff search opening over an inventory that is already up is
 * exactly that case.
 */

const TIMEOUT_MS = 16000

const handle = ref<Handle | null>(null)
const open = ref(false)

const config = ref<ScreenConfig>({
  labels: {},
  hotbar: [],
  openKey: '',
  drops: false,
  defaultWeight: 0
})
const tabs = ref<TabSpec[]>([])

/* `shallowRef` for the containers: each is replaced whole on every push, and a
   deep reactive proxy over a Map of two hundred stacks is work nobody reads. */
const primary = shallowRef<Container | null>(null)
const secondary = shallowRef<Container | null>(null)

/* The catalogue arrives in parts and is only adopted on the part marked `done`:
   a half-arrived catalogue drawn over a whole one is every second item losing
   its name. */
const catalog = shallowRef<Map<string, CatalogEntry>>(new Map())
let incoming: Map<string, CatalogEntry> | null = null

const nearby = ref<NearbyPlayer[]>([])
const broken = reactive(new Set<string>())

const tab = ref('')
const busy = ref(false)
const status = ref('')

/** Which cell the pointer is over, for the detail plate. */
const hovered = reactive({ container: 0, slot: 0 })

/** The drag in flight: where it came from, and the cell it is over now. */
const drag = reactive({ container: 0, slot: 0, overContainer: 0, overSlot: 0, active: false })

/** The cell whose menu is up, and where to draw it. */
const menu = reactive({ container: 0, slot: 0, x: 0, y: 0, open: false })

/** The split step: how many units of the chosen stack to take out. */
const split = reactive({ container: 0, slot: 0, count: 1, max: 1, open: false })

let release: (() => void) | undefined
let pointerBound = false

function label(key: string, fallback = ''): string {
  return config.value.labels[key] || fallback || key
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

/* -- talking to Lua ------------------------------------------------------------
   Everything below carries the handle and an INTENT. `ask` is the round trip the
   bridge's rpc provides; `tell` is fire and forget for the things whose answer is
   the next push. */

function tell(action: string, payload: Payload = {}): void {
  if (handle.value === null) return
  send('opx:inventory:request', { handle: handle.value, action, payload })
}

async function ask(action: string, payload: Payload = {}): Promise<Payload | null> {
  if (handle.value === null) return null
  busy.value = true
  status.value = ''
  try {
    return await request(
      'opx:inventory:request',
      { handle: handle.value, action, payload },
      { timeoutMs: TIMEOUT_MS }
    )
  } catch (error) {
    // Every refusal the SERVER makes is already a toast Lua raised, so the page
    // does not render one: it only says that the round trip failed or never came
    // back, in words the open spec carried in the player's language. A raw code
    // is never put on screen.
    const timedOut = error instanceof BridgeError && error.localeKey === 'error.rpc_timeout'
    status.value = label(timedOut ? 'timeout' : 'failed')
    return null
  } finally {
    busy.value = false
  }
}

/* -- the view ------------------------------------------------------------------ */

const tabList = computed<Tab[]>(() => tabs.value.map((spec) => ({ id: spec.key, label: spec.label })))

const currentTab = computed(() => {
  if (tabs.value.length === 0) return ''
  if (tabs.value.some((spec) => spec.key === tab.value)) return tab.value
  return tabs.value[0].key
})

/** The categories the active tab gathers. A `rest` tab gathers what no other
    tab names, which is computed here because only the page knows the full set. */
const activeCategories = computed<string[]>(() => {
  const spec = tabs.value.find((entry) => entry.key === currentTab.value)
  if (!spec) return []
  if (!spec.rest) return spec.categories
  const named = new Set<string>()
  for (const other of tabs.value) {
    if (other.rest) continue
    for (const category of other.categories) named.add(category)
  }
  const rest = new Set<string>()
  for (const entry of catalog.value.values()) {
    if (!named.has(entry.category)) rest.add(entry.category)
  }
  // `misc` is the catalogue's own default category, so a rest tab always holds it.
  rest.add('misc')
  return Array.from(rest)
})

function containerById(id: number): Container | null {
  if (primary.value && primary.value.id === id) return primary.value
  if (secondary.value && secondary.value.id === id) return secondary.value
  return null
}

function stackAt(containerId: number, slot: number) {
  const container = containerById(containerId)
  if (!container) return null
  return container.bySlot.get(slot) ?? null
}

/** The stack the detail plate describes: the dragged one, else the hovered one. */
const detail = computed(() => {
  const at = drag.active ? drag : hovered
  const containerId = drag.active ? drag.container : hovered.container
  const slot = drag.active ? drag.slot : at.slot
  const stack = stackAt(containerId, slot)
  if (!stack) return null
  const entry = catalog.value.get(stack.name)
  return {
    stack,
    entry,
    label: labelOf(stack, entry, label('unknown', '?')),
    description: entry ? entry.description : '',
    weight: grams(weightOf(stack, entry, config.value.defaultWeight), config.value),
    ammo: ammoOf(stack),
    serial: serialOf(stack),
    wear: durabilityOf(stack)
  }
})

function titleOf(container: Container | null, fallbackKey: string): string {
  if (!container) return label(fallbackKey)
  if (container.title) return container.title
  return label(container.kind, label(fallbackKey))
}

const primaryLoad = computed(() =>
  primary.value ? loadPercent(primary.value.weight, primary.value.maxWeight) : 0
)
const secondaryLoad = computed(() =>
  secondary.value ? loadPercent(secondary.value.weight, secondary.value.maxWeight) : 0
)

function loadText(container: Container | null): string {
  if (!container) return ''
  return `${grams(container.weight, config.value)} / ${grams(container.maxWeight, config.value)}`
}

function toneFor(percent: number): 'neutral' | 'warn' | 'bad' {
  if (percent >= 95) return 'bad'
  if (percent >= 75) return 'warn'
  return 'neutral'
}

/* -- the drag ------------------------------------------------------------------
   Pointer events and not the browser's own drag: a `dragstart` inside a CEF page
   carries an image nothing can style and fires no move events over a scrolling
   grid. What is tracked here is only where the pointer went; the MOVE it turns
   into is Lua's to accept. */

function cellUnder(x: number, y: number): { container: number; slot: number } | null {
  const element = document.elementFromPoint(x, y)
  if (!element) return null
  const cell = element.closest('[data-slot]')
  if (!cell) return null
  const owner = cell.closest('[data-container]')
  if (!owner) return null
  const slot = Number(cell.getAttribute('data-slot'))
  const container = Number(owner.getAttribute('data-container'))
  if (!Number.isFinite(slot) || !Number.isFinite(container)) return null
  return { container, slot }
}

function onPointerMove(event: PointerEvent): void {
  if (!drag.active) return
  const at = cellUnder(event.clientX, event.clientY)
  drag.overContainer = at ? at.container : 0
  drag.overSlot = at ? at.slot : 0
}

function endDrag(): void {
  drag.active = false
  drag.container = 0
  drag.slot = 0
  drag.overContainer = 0
  drag.overSlot = 0
}

function onPointerUp(event: PointerEvent): void {
  if (!drag.active) return
  const at = cellUnder(event.clientX, event.clientY)
  const from = { container: drag.container, slot: drag.slot }
  endDrag()
  if (!at) return
  if (at.container === from.container && at.slot === from.slot) return

  // An INTENT: two slots and two containers. Not a result, not a count, and not
  // a new weight -- Lua decides whether this is a move, a stack or a swap.
  void ask('move', {
    from: from.container,
    fromSlot: from.slot,
    to: at.container,
    toSlot: at.slot
  })
}

function bindPointer(): void {
  if (pointerBound) return
  pointerBound = true
  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
}

function unbindPointer(): void {
  if (!pointerBound) return
  pointerBound = false
  window.removeEventListener('pointermove', onPointerMove)
  window.removeEventListener('pointerup', onPointerUp)
}

function onGrab(containerId: number, slot: number, native: PointerEvent): void {
  if (busy.value) return
  closeMenu()
  drag.active = true
  drag.container = containerId
  drag.slot = slot
  drag.overContainer = containerId
  drag.overSlot = slot
  bindPointer()
  // A capture on the cell would be lost the moment the grid re-renders the
  // window under the pointer, so the listeners live on the window instead.
  void native
}

function onHover(containerId: number, slot: number | null): void {
  hovered.container = slot === null ? 0 : containerId
  hovered.slot = slot ?? 0
}

/* -- the per-slot menu --------------------------------------------------------- */

function openMenu(containerId: number, slot: number, native: MouseEvent): void {
  const stack = stackAt(containerId, slot)
  if (!stack) return
  menu.container = containerId
  menu.slot = slot
  menu.x = native.clientX
  menu.y = native.clientY
  menu.open = true
}

function closeMenu(): void {
  menu.open = false
}

const menuStack = computed(() => (menu.open ? stackAt(menu.container, menu.slot) : null))

const menuEntry = computed(() => {
  const stack = menuStack.value
  return stack ? catalog.value.get(stack.name) : undefined
})

const isBag = computed(() => menu.container !== 0 && menu.container === primary.value?.id)

function doUse(): void {
  const slot = menu.slot
  closeMenu()
  void ask('use', { slot })
}

function doDrop(): void {
  const slot = menu.slot
  closeMenu()
  void ask('drop', { slot })
}

function doGive(playerId: number): void {
  const slot = menu.slot
  closeMenu()
  void ask('give', { target: playerId, slot })
}

function openSplit(): void {
  const stack = menuStack.value
  if (!stack || stack.count < 2) return
  split.container = menu.container
  split.slot = menu.slot
  split.max = stack.count - 1
  split.count = Math.max(1, Math.floor(stack.count / 2))
  split.open = true
  closeMenu()
}

function doSplit(): void {
  const { container, slot, count } = split
  split.open = false
  void ask('split', { container, slot, count })
}

function stepSplit(delta: number): void {
  split.count = Math.max(1, Math.min(split.max, split.count + delta))
}

function doSort(containerId: number, mode: 'weight' | 'name'): void {
  void ask('sort', { container: containerId, mode })
}

function closeSecondary(): void {
  void ask('closeSecondary')
}

function close(): void {
  send('opx:inventory:dismiss', { handle: handle.value })
}

/* -- what Lua pushes ----------------------------------------------------------- */

function applyConfig(payload: unknown): void {
  config.value = readConfig(payload)
  const spec = readTabs(table(payload).labels)
  if (spec.length > 0) tabs.value = spec
}

function blank(): void {
  open.value = false
  primary.value = null
  secondary.value = null
  nearby.value = []
  status.value = ''
  busy.value = false
  endDrag()
  unbindPointer()
  closeMenu()
  split.open = false
  hovered.container = 0
  hovered.slot = 0
}

useBridge('opx:inventory:config', (payload) => {
  guard('inventory:config', () => applyConfig(payload), undefined)
})

useBridge('opx:inventory:catalog', (payload) => {
  guard(
    'inventory:catalog',
    () => {
      if (bool(payload.first) || incoming === null) incoming = new Map()
      const entries = table(payload.entries)
      for (const name of Object.keys(entries)) {
        incoming.set(name, readCatalogEntry(entries[name]))
      }
      if (!bool(payload.done)) return
      catalog.value = incoming
      incoming = null
    },
    undefined
  )
})

useBridge('opx:inventory:open', (payload) => {
  guard(
    'inventory:open',
    () => {
      const given = payload.handle
      if (typeof given !== 'string' || given === '') return
      release?.()
      blank()
      handle.value = given
      applyConfig(payload.config)
      primary.value = readContainer(payload.primary)
      secondary.value = payload.secondary === false ? null : readContainer(payload.secondary)
      tab.value = tabs.value.length > 0 ? tabs.value[0].key : ''
      open.value = true
      release = acquireFocus({ id: 'inventory', onEscape: close })
      // The nearby list is asked for, not assumed: who is close enough to be
      // handed something is a fact about the world, and the world is Lua's.
      tell('nearby')
    },
    undefined
  )
})

useBridge('opx:inventory:update', (payload) => {
  guard(
    'inventory:update',
    () => {
      if (!mine(payload)) return
      const container = readContainer(payload.container)
      if (!container) return
      if (primary.value && container.id === primary.value.id) primary.value = container
      else if (secondary.value && container.id === secondary.value.id) secondary.value = container
    },
    undefined
  )
})

useBridge('opx:inventory:secondary', (payload) => {
  guard(
    'inventory:secondary',
    () => {
      if (!mine(payload)) return
      secondary.value = payload.container === false ? null : readContainer(payload.container)
    },
    undefined
  )
})

useBridge('opx:inventory:nearby', (payload) => {
  guard(
    'inventory:nearby',
    () => {
      if (!mine(payload)) return
      nearby.value = readNearby(payload.players)
    },
    undefined
  )
})

useBridge('opx:inventory:close', (payload) => {
  guard(
    'inventory:close',
    () => {
      if (payload.handle !== undefined && !mine(payload)) return
      handle.value = null
      blank()
      release?.()
      release = undefined
    },
    undefined
  )
})

onUnmounted(() => {
  unbindPointer()
  release?.()
})

// Last: Lua takes this as permission to send the configuration and the catalogue,
// and a payload arriving before the channels above are bound is simply lost.
try {
  send('opx:inventory:ready', {})
} catch (error) {
  report(error, 'inventory:ready')
}

</script>

<template>
  <div class="room" :class="{ open }">
    <OpScrim mode="flat" :visible="open" />

    <div v-if="open" class="stage">
      <!-- The bag. `data-container` is what the drag resolver reads off the DOM
           to name the container a cell belongs to. -->
      <section class="column" :data-container="primary ? primary.id : 0">
        <OpPanel bay>
          <template #header>
            <div class="head-text">
              <span class="op77-eyebrow">{{ label('bag', 'BAG') }}</span>
              <h1>{{ titleOf(primary, 'bag') }}</h1>
            </div>
            <OpKeyCap v-if="config.openKey" :label="config.openKey" muted />
          </template>

          <OpTabs
            v-if="tabList.length"
            :tabs="tabList"
            :selected="currentTab"
            @select="(id: string) => (tab = id)"
          />

          <div class="load">
            <OpGauge
              :value="primaryLoad"
              :tone="toneFor(primaryLoad)"
              :label="label('weight')"
              :readout="false"
            />
            <span class="figure">{{ loadText(primary) }}</span>
          </div>

          <InventoryGrid
            v-if="primary"
            :container="primary"
            :catalog="catalog"
            :config="config"
            :categories="activeCategories"
            :hotbar="config.hotbar"
            :selected="0"
            :over="drag.overContainer === primary.id ? drag.overSlot : 0"
            :dragging="drag.container === primary.id ? drag.slot : 0"
            :broken="broken"
            @grab="(slot, native) => onGrab(primary!.id, slot, native)"
            @open="(slot, native) => openMenu(primary!.id, slot, native)"
            @hover="(slot) => onHover(primary!.id, slot)"
            @broke="(name) => broken.add(name)"
          />

          <template #footer>
            <OpRow
              class="button grow"
              :label="label('sortWeight')"
              :disabled="!primary || busy"
              @select="primary && doSort(primary.id, 'weight')"
            />
            <OpRow
              class="button grow"
              :label="label('sortName')"
              :disabled="!primary || busy"
              @select="primary && doSort(primary.id, 'name')"
            />
            <OpRow class="button grow" :label="label('close')" @select="close" />
          </template>
        </OpPanel>
      </section>

      <!-- The detail plate. It describes what the pointer is on; it never acts. -->
      <section class="detail">
        <OpPanel>
          <template #header>
            <h2>{{ detail ? detail.label : label('ground', '') }}</h2>
          </template>
          <template v-if="detail">
            <p v-if="detail.description" class="prose">{{ detail.description }}</p>
            <OpRow :label="label('weight')" :value="detail.weight" />
            <OpRow
              v-if="detail.stack.count > 1"
              :label="label('slots')"
              :value="String(detail.stack.count)"
            />
            <OpRow v-if="detail.ammo >= 0" :label="label('ammo')" :value="String(detail.ammo)" />
            <OpRow v-if="detail.serial" :label="label('serial')" :value="detail.serial" />
            <OpGauge
              v-if="detail.wear >= 0"
              :value="detail.wear * 100"
              :tone="detail.wear < 0.25 ? 'bad' : detail.wear < 0.6 ? 'warn' : 'health'"
              :label="label('condition')"
            />
          </template>
          <p v-else class="prose quiet">{{ label('groundHint', '') }}</p>

          <p v-if="status" class="status">{{ status }}</p>
        </OpPanel>
      </section>

      <!-- Whatever is open beside the bag: a stash, a trunk, a pile, another bag. -->
      <section
        v-if="secondary"
        class="column"
        :data-container="secondary.id"
      >
        <OpPanel bay anchor="end">
          <template #header>
            <div class="head-text">
              <span class="op77-eyebrow">{{ label(secondary.kind, '') }}</span>
              <h1>{{ titleOf(secondary, 'stash') }}</h1>
            </div>
          </template>

          <div class="load">
            <OpGauge
              :value="secondaryLoad"
              :tone="toneFor(secondaryLoad)"
              :label="label('weight')"
              :readout="false"
            />
            <span class="figure">{{ loadText(secondary) }}</span>
          </div>

          <InventoryGrid
            :container="secondary"
            :catalog="catalog"
            :config="config"
            :categories="[]"
            :hotbar="[]"
            :selected="0"
            :over="drag.overContainer === secondary.id ? drag.overSlot : 0"
            :dragging="drag.container === secondary.id ? drag.slot : 0"
            :broken="broken"
            @grab="(slot, native) => onGrab(secondary!.id, slot, native)"
            @open="(slot, native) => openMenu(secondary!.id, slot, native)"
            @hover="(slot) => onHover(secondary!.id, slot)"
            @broke="(name) => broken.add(name)"
          />

          <template #footer>
            <OpRow
              class="button grow"
              :label="label('sortWeight')"
              :disabled="busy"
              @select="doSort(secondary!.id, 'weight')"
            />
            <OpRow class="button grow" :label="label('close')" @select="closeSecondary" />
          </template>
        </OpPanel>
      </section>
    </div>

    <!-- The per-slot menu. Positioned in viewport pixels, outside every panel, so
         its place is the pointer's own and no frame clips it. -->
    <div v-if="menu.open && menuStack" class="menu-layer" @pointerdown.self="closeMenu">
      <div class="menu" :style="{ left: `${menu.x}px`, top: `${menu.y}px` }">
        <OpPanel>
          <OpRow
            v-if="isBag && menuEntry?.usable"
            class="button"
            :label="label('use')"
            :disabled="busy"
            @select="doUse"
          />
          <OpRow
            v-if="menuStack.count > 1"
            class="button"
            :label="label('split')"
            :disabled="busy"
            @select="openSplit"
          />
          <OpRow
            v-if="isBag && config.drops"
            class="button"
            :label="label('drop')"
            :disabled="busy"
            @select="doDrop"
          />
          <template v-if="isBag">
            <OpRow rule :label="label('giveTo')" />
            <OpRow
              v-for="person in nearby"
              :key="person.id"
              class="button"
              :label="`#${person.id}`"
              :value="`${person.distance}${label('m', 'm')}`"
              :disabled="busy"
              @select="doGive(person.id)"
            />
            <OpRow v-if="!nearby.length" rule :label="label('nobody')" />
          </template>
        </OpPanel>
      </div>
    </div>

    <!-- The split step. A number the player chooses; Lua still checks it. -->
    <div v-if="split.open" class="menu-layer" @pointerdown.self="split.open = false">
      <div class="dialog">
        <OpPanel>
          <template #header>
            <h2>{{ label('split') }}</h2>
          </template>
          <div class="stepper">
            <OpRow class="button" label="&minus;" @select="stepSplit(-1)" />
            <span class="count">{{ split.count }}</span>
            <OpRow class="button" label="+" @select="stepSplit(1)" />
          </div>
          <template #footer>
            <OpRow class="button grow" :label="label('close')" @select="split.open = false" />
            <OpRow class="button grow" :label="label('split')" selected @select="doSplit" />
          </template>
        </OpPanel>
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
  transition: opacity var(--op77-dur) var(--op77-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

.stage {
  position: absolute;
  left: var(--op77-inset-x);
  right: var(--op77-inset-x);
  top: var(--op77-inset-y);
  bottom: var(--op77-inset-y);
  display: flex;
  align-items: stretch;
  gap: var(--op77-space-3);
}

.column {
  flex: 1 1 0;
  display: flex;
  min-width: 0;
  min-height: 0;
}

.detail {
  flex: 0 0 260px;
  display: flex;
  align-items: flex-start;
  min-height: 0;
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

.detail h2 {
  margin: 0;
  font: 700 var(--op77-fs-title) / 1.15 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
}

.load {
  display: flex;
  align-items: center;
  gap: var(--op77-space-3);
  padding: var(--op77-space-1) 0 var(--op77-space-2);
}

.load .figure {
  flex: none;
  font: 400 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-dim);
  font-variant-numeric: tabular-nums;
}

.prose {
  margin: 0 0 var(--op77-space-2);
  font: 400 var(--op77-fs-body) / 1.35 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.prose.quiet {
  color: var(--op77-text-faint);
}

.status {
  margin: var(--op77-space-2) 0 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  color: var(--op77-danger);
}

.menu-layer {
  position: absolute;
  inset: 0;
}

.menu {
  position: absolute;
  width: 220px;
  /* The plate hangs down and right of the pointer, and is nudged back inside the
     viewport by the browser's own clamping of a fixed-width box at the edge. */
  transform: translate(4px, 4px);
  max-height: 60vh;
  overflow: hidden auto;
  scrollbar-width: none;
}

.dialog {
  position: absolute;
  left: 50%;
  top: 50%;
  width: 280px;
  transform: translate(-50%, -50%);
}

.stepper {
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
}

.stepper .count {
  flex: 1;
  text-align: center;
  font: 700 var(--op77-fs-head) / 1 var(--op77-font-mono);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

/* A button is a row with nothing on its right: the label centres and the plate
   shrinks to it. Scoped here, so OpRow stays one component and not two. */
.button {
  justify-content: center;
  cursor: pointer;
}

.grow {
  flex: 1;
}
</style>
