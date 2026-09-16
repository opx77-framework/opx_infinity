<script setup lang="ts">
import { computed } from 'vue'

/**
 * Derived from `opx77_hud/web/hud.css` `.gauge` / `.blocks` / `.block`, lines 47-119.
 *
 * Segmented and not a bar, because over gameplay a continuous fill has no edge to read
 * against a moving backdrop and a segment count can be counted at a glance.
 *
 * The segments are PLAIN DIVS. hud.css shears each one with a 4px `clip-path` and that
 * is exactly the thing not to port: twenty augmented segments per gauge is forty
 * pseudo-elements re-clipped on every value change, at 30fps. The container is not
 * augmented either -- a gauge has no frame. The shear stays a clip-path here because it
 * is a cheap static one on a leaf node, which is the case Augmented UI is not for.
 *
 * `value` is a percentage Lua sent. Nothing is derived from health here; the page does
 * not know what health is.
 */
const props = withDefaults(
  defineProps<{
    value: number
    label?: string
    /** hud.js writes this straight onto the gauge element. */
    tone?: 'neutral' | 'health' | 'warn' | 'bad'
    segments?: number
    /** The numeric readout on the right. Off for a bare meter. */
    readout?: boolean
  }>(),
  { label: '', tone: 'neutral', segments: 20, readout: true }
)

const lit = computed(() => {
  const ratio = Math.max(0, Math.min(100, props.value)) / 100
  return Math.round(ratio * props.segments)
})

const shown = computed(() => Math.round(Math.max(0, Math.min(100, props.value))))
</script>

<template>
  <div class="gauge" :class="tone" role="meter" :aria-valuenow="shown" :aria-label="label">
    <span v-if="$slots.icon" class="icon"><slot name="icon" /></span>
    <span class="blocks">
      <span v-for="n in segments" :key="n" class="block" :class="{ on: n <= lit }" />
    </span>
    <span v-if="readout" class="value">{{ shown }}</span>
  </div>
</template>

<style scoped>
.gauge {
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
}

.icon {
  flex: none;
  width: 14px;
  height: 14px;
  color: var(--op77-text-dim);
}

.blocks {
  flex: 1;
  display: flex;
  gap: 2px;
  min-width: 0;
}

.block {
  flex: 1;
  height: 10px;
  min-width: 3px;
  background: var(--op77-panel-raised);
  /* A static shear on a leaf. The segments read as leaning plates. */
  clip-path: polygon(4px 0, 100% 0, calc(100% - 4px) 100%, 0 100%);
  transition: background var(--op77-dur-fast) var(--op77-ease);
}

.block.on {
  background: var(--op77-text-dim);
}

.value {
  flex: none;
  min-width: 22px;
  text-align: right;
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

.health .block.on { background: var(--op77-accent); }
.health .icon { color: var(--op77-accent); }
.warn .block.on { background: var(--op77-warn); }
.warn .icon, .warn .value { color: var(--op77-warn); }
.bad .block.on { background: var(--op77-danger); }
.bad .icon, .bad .value { color: var(--op77-danger); }
</style>
