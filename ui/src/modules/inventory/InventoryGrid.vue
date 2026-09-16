<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import InventorySlot from './InventorySlot.vue'
import type { CatalogEntry, Container, ScreenConfig, Stack } from './types'

/**
 * The slot grid, windowed.
 *
 * A container goes to two hundred slots today and the format does not stop
 * there, so the grid renders the rows that are on screen and nothing else. Five
 * thousand slots are five thousand map lookups and about forty elements: the
 * spacer above and below carries the rest of the scroll height.
 *
 * ONE augmented frame lives around this component, not inside it -- see
 * InventorySlot.vue. Nothing here animates an `--aug-*` value, because nothing
 * here has one.
 */
const props = defineProps<{
  container: Container
  catalog: Map<string, CatalogEntry>
  config: ScreenConfig
  /** Categories the active tab gathers; empty means every category. */
  categories: string[]
  /** Hotbar keys, drawn on the first slots. Empty for a container that is not the bag. */
  hotbar: string[]
  selected: number
  /** The slot the pointer is over during a drag, or 0. */
  over: number
  /** The slot being dragged out of this container, or 0. */
  dragging: number
  broken: Set<string>
}>()

const emit = defineEmits<{
  (event: 'grab', slot: number, native: PointerEvent): void
  (event: 'open', slot: number, native: MouseEvent): void
  (event: 'hover', slot: number | null): void
  (event: 'broke', name: string): void
}>()

/* The cell is a fixed box so a row's height is known without measuring one. Both
   numbers are also in the stylesheet below; they are the same grid. */
const CELL = 78
const GAP = 4

/* Rows kept above and below the window. Two is enough to cover a fast wheel
   between two frames without rendering a screenful of cells nobody sees. */
const OVERSCAN = 2

const viewport = ref<HTMLElement | null>(null)
const columns = ref(1)
const height = ref(0)
const scrollTop = ref(0)

let observer: ResizeObserver | null = null

function measure(): void {
  const element = viewport.value
  if (!element) return
  const width = element.clientWidth
  columns.value = Math.max(1, Math.floor((width + GAP) / (CELL + GAP)))
  height.value = element.clientHeight
  scrollTop.value = element.scrollTop
}

function onScroll(): void {
  scrollTop.value = viewport.value?.scrollTop ?? 0
}

onMounted(() => {
  measure()
  // ResizeObserver, not a window listener: the drawer changes width when the
  // second panel appears, and the window never moves.
  if (typeof ResizeObserver === 'function') {
    observer = new ResizeObserver(measure)
    if (viewport.value) observer.observe(viewport.value)
  }
  window.addEventListener('resize', measure)
})

onBeforeUnmount(() => {
  observer?.disconnect()
  observer = null
  window.removeEventListener('resize', measure)
})

// A different container is a different scroll position; keeping the old one
// leaves the player looking at row forty of a bag that has eight.
watch(
  () => props.container.id,
  () => {
    if (viewport.value) viewport.value.scrollTop = 0
    scrollTop.value = 0
  }
)

const rows = computed(() => Math.ceil(props.container.slots / columns.value))

const firstRow = computed(() =>
  Math.max(0, Math.floor(scrollTop.value / (CELL + GAP)) - OVERSCAN)
)

const lastRow = computed(() => {
  const visible = Math.ceil(height.value / (CELL + GAP)) + OVERSCAN * 2
  return Math.min(rows.value, firstRow.value + visible)
})

interface Cell {
  index: number
  stack: Stack | null
  entry: CatalogEntry | undefined
  muted: boolean
}

const wanted = computed(() => new Set(props.categories))

/** The cells actually rendered, in order. Everything else is spacer height.
    Built once per window rather than resolved per binding in the template, so a
    cell's stack and catalogue entry are each looked up exactly once. */
const cells = computed<Cell[]>(() => {
  const out: Cell[] = []
  const from = firstRow.value * columns.value + 1
  const to = Math.min(props.container.slots, lastRow.value * columns.value)
  const filter = wanted.value
  for (let index = from; index <= to; index += 1) {
    const stack = props.container.bySlot.get(index) ?? null
    const entry = stack ? props.catalog.get(stack.name) : undefined
    out.push({
      index,
      stack,
      entry,
      // A tab that gathers no category gathers every one; that is the "all" tab.
      muted:
        stack !== null && filter.size > 0 && !filter.has(entry ? entry.category : 'misc')
    })
  }
  return out
})

const padTop = computed(() => firstRow.value * (CELL + GAP))
const padBottom = computed(() => Math.max(0, (rows.value - lastRow.value) * (CELL + GAP)))

const gridStyle = computed(() => ({
  gridTemplateColumns: `repeat(${columns.value}, minmax(0, 1fr))`,
  gridAutoRows: `${CELL}px`,
  gap: `${GAP}px`
}))

</script>

<template>
  <div ref="viewport" class="viewport" @scroll.passive="onScroll">
    <div :style="{ height: `${padTop}px` }" />
    <div class="grid" :style="gridStyle">
      <InventorySlot
        v-for="cell in cells"
        :key="cell.index"
        :index="cell.index"
        :stack="cell.stack"
        :entry="cell.entry"
        :config="config"
        :hotkey="hotbar[cell.index - 1] ?? ''"
        :selected="selected === cell.index"
        :over="over === cell.index"
        :dragging="dragging === cell.index"
        :muted="cell.muted"
        :broken="broken"
        @grab="(at, native) => emit('grab', at, native)"
        @open="(at, native) => emit('open', at, native)"
        @hover="(at) => emit('hover', at)"
        @broke="(name) => emit('broke', name)"
      />
    </div>
    <div :style="{ height: `${padBottom}px` }" />
  </div>
</template>

<style scoped>
.viewport {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden auto;
  /* A CEF scrollbar is a Chromium scrollbar drawn over gameplay. */
  scrollbar-width: none;
}

.viewport::-webkit-scrollbar {
  width: 0;
  height: 0;
}

.grid {
  display: grid;
  align-content: start;
}
</style>
