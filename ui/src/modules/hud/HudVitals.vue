<script setup lang="ts">
import { shallowRef } from 'vue'
import OpGauge from '@/design/components/OpGauge.vue'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { iconPaths } from './icons'

/**
 * THE VITALS COLUMN -- health, armour, stamina, hunger, thirst.
 *
 * THE ONE HOT CHANNEL ON THIS SURFACE. `opx:hud:vitals` is a numeric stream at roughly
 * the surface's 30 Hz, and the store is a `shallowRef` REPLACED WHOLESALE for exactly
 * that reason: `ref([])` over five rows of five fields is twenty-five reactive
 * dependencies re-validated thirty times a second to move five numbers, and Vue's deep
 * proxy would be walking a fresh array of fresh objects on every frame to discover that
 * all of it is new. One dependency, one assignment, one render.
 *
 * Nothing below decides what is low. `tone` arrives decided: Lua holds the thresholds
 * because Lua holds the configuration, and a page that coloured its own gauge would be
 * a second opinion about the player's health.
 */
const { t } = useLocale()

withDefaults(defineProps<{ segments?: number; width?: number }>(), {
  segments: 10,
  width: 210
})

type Tone = 'neutral' | 'health' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'health', 'warn', 'bad']

interface Vital {
  id: string
  icon: string[]
  label: string
  value: number
  tone: Tone
}

const vitals = shallowRef<Vital[]>([])

function toneOf(value: unknown): Tone {
  const name = text(value, 'neutral')
  return TONES.indexOf(name) === -1 ? 'neutral' : (name as Tone)
}

useBridge('opx:hud:vitals', (payload: Payload) => {
  // `list()` and not `payload.gauges || []`: an empty Lua table is `{}`, which is truthy,
  // and `{}.map` is the throw the bridge would swallow -- at 30 Hz, silently, forever.
  vitals.value = list<Payload>(payload.gauges)
    .filter((row) => text(row.id) !== '')
    .map((row) => ({
      id: text(row.id),
      icon: iconPaths(text(row.icon)),
      label: t(text(row.label)),
      value: num(row.pct),
      tone: toneOf(row.tone)
    }))
})
</script>

<template>
  <div class="vitals" :style="{ '--vitals-width': width + 'px' }">
    <OpGauge
      v-for="vital in vitals"
      :key="vital.id"
      :value="vital.value"
      :label="vital.label"
      :tone="vital.tone"
      :segments="segments"
    >
      <template v-if="vital.icon.length" #icon>
        <svg
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path v-for="(d, index) in vital.icon" :key="index" :d="d" />
        </svg>
      </template>
    </OpGauge>
  </div>
</template>

<style scoped>
.vitals {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  width: var(--vitals-width, 210px);
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}

/* No frame, and deliberately so: OpGauge is segmented because a segment count can be
   read against a moving backdrop, and a panel behind it would be a plate over gameplay
   paying for nothing. The segments carry themselves. */
/* Slot content is compiled in THIS component's scope, so the glyph carries this file's
   scope id and needs no `:deep` to reach. */
.vitals svg {
  display: block;
  width: 100%;
  height: 100%;
}
</style>
