<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import InventorySlot from './InventorySlot.vue'
import { BLEED, CELL, COLUMNS, GAP, GRID_HEIGHT, GRID_WIDTH, ROWS } from './geometry'
import type { CatalogEntry, Container, ScreenConfig, Stack } from './types'

/**
 * The slot grid, windowed.
 *
 * A container goes to two hundred slots today and the format does not stop
 * there, so the grid renders the rows that are on screen and nothing else. Five
 * thousand slots are five thousand map lookups and about forty elements: the
 * spacer above and below carries the rest of the scroll height.
 *
 * ── CENTRED PASS ────────────────────────────────────────────────────────────
 *
 * THE GRID NO LONGER MEASURES ITSELF. It used to read its own `clientWidth` and
 * choose a column count from it, under a `ResizeObserver` and a window listener.
 * That is gone: `geometry.ts` fixes five columns of a 90px square and seven rows
 * before it scrolls, which is `opx77_inventory`'s own geometry, and the view
 * scales the whole centred pair to fit the surface instead of reflowing it. A
 * reflowing grid re-columns on every resize and whenever the second panel
 * appears, so a slot is never twice in the same place; this one always is.
 *
 * What is left to watch is the scroll offset, which is the only thing the
 * virtual window actually depends on now.
 *
 * Nothing here draws anything. The panel around it has no frame at all any more,
 * and the outline belongs to the cell inside it -- see InventorySlot.vue.
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
  (event: 'hover', slot: number | null, native?: MouseEvent): void
  (event: 'broke', name: string): void
}>()

/* Rows kept above and below the window. Two is enough to cover a fast wheel
   between two frames without rendering a screenful of cells nobody sees. It is
   also what absorbs the BLEED gutter's shift of the first row. */
const OVERSCAN = 2

const viewport = ref<HTMLElement | null>(null)
const scrollTop = ref(0)

function onScroll(): void {
  scrollTop.value = viewport.value?.scrollTop ?? 0
}

onMounted(() => {
  scrollTop.value = viewport.value?.scrollTop ?? 0
})

onBeforeUnmount(() => {
  scrollTop.value = 0
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

const rows = computed(() => Math.ceil(props.container.slots / COLUMNS))

const firstRow = computed(() => Math.max(0, Math.floor(scrollTop.value / (CELL + GAP)) - OVERSCAN))

const lastRow = computed(() => {
  const visible = ROWS + OVERSCAN * 2
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
  const from = firstRow.value * COLUMNS + 1
  const to = Math.min(props.container.slots, lastRow.value * COLUMNS)
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

/* Every number the grid draws with, handed to CSS in one place. The view sizes
   the panel from the same module, so the two can never disagree. */
const frameStyle = computed(() => ({
  width: `${GRID_WIDTH}px`,
  height: `${GRID_HEIGHT}px`,
  padding: `${BLEED}px`
}))

const gridStyle = computed(() => ({
  gridTemplateColumns: `repeat(${COLUMNS}, ${CELL}px)`,
  gridAutoRows: `${CELL}px`,
  gap: `${GAP}px`
}))
</script>

<template>
  <div ref="viewport" class="viewport" :style="frameStyle" @scroll.passive="onScroll">
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
        @hover="(at, native) => emit('hover', at, native)"
        @broke="(name) => emit('broke', name)"
      />
    </div>
    <div :style="{ height: `${padBottom}px` }" />
  </div>
</template>

<style scoped>
/* Fixed size, from `geometry.ts`, and bound inline rather than written here: the
   grid virtualises, so the numbers exist in JS whether or not they are also in a
   stylesheet, and one copy is better than two that agree by hand. */
.viewport {
  flex: none;
  /* GRID_WIDTH and GRID_HEIGHT already include the BLEED gutter on both sides, so
     the box has to be the one that counts padding inside the size. Declared here
     because the token file sets no universal `box-sizing`. */
  box-sizing: border-box;
  overflow: hidden auto;
  overscroll-behavior: contain;
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
  justify-content: start;
}
</style>
