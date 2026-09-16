<script setup lang="ts">
import { computed } from 'vue'
import { ammoOf, durabilityOf, grams, imageFor, labelOf, monogram, weightOf } from './format'
import type { CatalogEntry, ScreenConfig, Stack } from './types'

/**
 * One cell of a grid.
 *
 * A PLAIN box, deliberately. Augmented UI spends up to two pseudo-elements per
 * augmented element, and a 200-slot bag would be four hundred of them re-clipped
 * on every resize -- rule 1 in design/augmented.css. The frame belongs to the one
 * `OpPanel` around the grid; a cell is a border and a fill.
 *
 * It renders what it is given and emits what the player did. It never changes its
 * own count, and it never decides that a drop was legal.
 */
const props = defineProps<{
  index: number
  stack: Stack | null
  entry: CatalogEntry | undefined
  config: ScreenConfig
  /** The hotbar key drawn in the corner, for the first slots of the bag only. */
  hotkey: string
  selected: boolean
  /** The cell the pointer is currently over while a drag is in flight. */
  over: boolean
  /** This cell is the one being dragged; it fades rather than moving. */
  dragging: boolean
  /** Dimmed because the active tab does not gather this item's category. */
  muted: boolean
  /** Item names whose picture has already failed to load once, surface-wide. */
  broken: Set<string>
}>()

const emit = defineEmits<{
  (event: 'grab', index: number, native: PointerEvent): void
  (event: 'open', index: number, native: MouseEvent): void
  (event: 'hover', index: number | null): void
  (event: 'broke', name: string): void
}>()

const label = computed(() =>
  props.stack ? labelOf(props.stack, props.entry, props.config.labels.unknown || '?') : ''
)

const image = computed(() => (props.stack ? imageFor(props.stack.name, props.entry) : ''))

const weight = computed(() =>
  props.stack
    ? grams(weightOf(props.stack, props.entry, props.config.defaultWeight), props.config)
    : ''
)

const ammo = computed(() => (props.stack ? ammoOf(props.stack) : -1))
const wear = computed(() => (props.stack ? durabilityOf(props.stack) : -1))

const wearTone = computed(() => {
  if (wear.value < 0) return ''
  if (wear.value < 0.25) return 'bad'
  if (wear.value < 0.6) return 'warn'
  return ''
})

/** A picture that will not load is reported up once, so the monogram is drawn
    from then on for every cell holding that item rather than per cell. */
function onBroken(): void {
  if (props.stack) emit('broke', props.stack.name)
}

const showArt = computed(() => props.stack !== null && !props.broken.has(props.stack.name))
</script>

<template>
  <div
    class="cell"
    :class="{
      filled: stack !== null,
      selected,
      over,
      dragging,
      muted,
      weapon: entry?.weapon === true
    }"
    :data-slot="index"
    @pointerdown.prevent="stack && emit('grab', index, $event)"
    @contextmenu.prevent="stack && emit('open', index, $event)"
    @mouseenter="emit('hover', index)"
    @mouseleave="emit('hover', null)"
  >
    <span v-if="hotkey" class="key">{{ hotkey }}</span>

    <template v-if="stack">
      <span class="art">
        <img v-if="showArt" :src="image" alt="" draggable="false" @error="onBroken" />
        <span v-else class="initials">{{ monogram(label) }}</span>
      </span>

      <span v-if="stack.count > 1" class="count">{{ stack.count }}</span>
      <span v-if="ammo >= 0" class="rounds">{{ ammo }}</span>

      <span v-if="wear >= 0" class="wear" :class="wearTone">
        <i :style="{ width: `${wear * 100}%` }" />
      </span>

      <span class="foot">
        <span class="name">{{ label }}</span>
        <span class="mass">{{ weight }}</span>
      </span>
    </template>
  </div>
</template>

<style scoped>
.cell {
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  box-sizing: border-box;
  height: 100%;
  padding: var(--op77-space-1);
  background: var(--op77-panel-quiet);
  border: 1px solid var(--op77-line);
  /* The whole grid is one scroll container; a cell must not be a drag source for
     the browser's own drag, which fights the pointer tracking. */
  user-select: none;
  touch-action: none;
  transition:
    background var(--op77-dur-fast) var(--op77-ease),
    border-color var(--op77-dur-fast) var(--op77-ease),
    opacity var(--op77-dur-fast) var(--op77-ease);
}

.cell.filled {
  background: var(--op77-panel);
  border-color: var(--op77-line-hud);
  cursor: grab;
}

.cell.filled:hover {
  border-color: var(--op77-line-strong);
}

.cell.selected,
.cell.over {
  border-color: var(--op77-accent);
  background: var(--op77-accent-soft);
}

.cell.dragging {
  opacity: 0.32;
}

.cell.muted {
  opacity: 0.26;
}

.key {
  position: absolute;
  top: 3px;
  left: 4px;
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-faint);
}

.cell.filled .key {
  color: var(--op77-accent-line);
}

.art {
  position: absolute;
  inset: 12px 6px 26px;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}

.art img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

.initials {
  font: 700 var(--op77-fs-title) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  color: var(--op77-text-faint);
}

.cell.weapon .initials {
  color: var(--op77-accent-line);
}

.count,
.rounds {
  position: absolute;
  top: 3px;
  right: 5px;
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

.rounds {
  top: auto;
  bottom: 24px;
  color: var(--op77-accent);
}

.wear {
  position: absolute;
  left: 4px;
  right: 4px;
  bottom: 22px;
  height: 2px;
  background: var(--op77-line);
}

.wear i {
  display: block;
  height: 100%;
  background: var(--op77-text-dim);
}

.wear.warn i { background: var(--op77-warn); }
.wear.bad i { background: var(--op77-danger); }

.foot {
  display: flex;
  align-items: baseline;
  gap: var(--op77-space-1);
  min-width: 0;
  pointer-events: none;
}

.name {
  flex: 1 1 auto;
  min-width: 0;
  font: 400 var(--op77-fs-micro) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.cell.filled:hover .name,
.cell.selected .name {
  color: var(--op77-text);
}

.mass {
  flex: none;
  font: 400 var(--op77-fs-micro) / 1.2 var(--op77-font-mono);
  color: var(--op77-text-faint);
  font-variant-numeric: tabular-nums;
}
</style>
