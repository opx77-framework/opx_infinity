<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import OpChip from '@/design/components/OpChip.vue'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE VEHICLE DIAL -- shown only while Lua says the character is sitting in one.
 *
 * Outer ring: engine speed, red past the redline. Inner ring: integrity. The gear sits in
 * the dial's open bottom, between the ring's two ends.
 *
 * WHY THIS IS STILL AN SVG AND NOT A ROW OF `OpGauge`s. A speedometer is the one read-out
 * on this HUD that is not a quantity in a list -- it is a quantity you glance at without
 * reading, which is what a radial does and what a segmented bar does not. There is no
 * radial in the design system and this is the only caller for one, so it stays module
 * art: two `stroke-dasharray` writes on two leaf paths, which is the cheap case. It is
 * NOT augmented and must never be -- see rule 3 in design/augmented.css.
 *
 * `rpm` and `integrity` are OPTIONAL and their absence is not zero. A vehicle whose engine
 * speed is not reported fills the outer ring from road speed instead, and one whose
 * integrity is not reported draws no inner ring and no integrity line at all: an empty
 * integrity ring is a thing a player brakes for.
 */
const { t } = useLocale()

/** Past this share of the outer ring the engine reads as redlining. hud.js REDLINE. */
const REDLINE = 85
/** Road speed that fills the outer ring when engine speed is not reported. hud.js DIAL_KPH. */
const DIAL_KPH = 250

/** The arc both rings are drawn on, `pathLength="100"` so a percent is a dash length. */
const OUTER = 'M23.2 96.8A52 52 0 1 1 96.8 96.8'
const INNER = 'M29 91A44 44 0 1 1 91 91'

type Tone = 'neutral' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'warn', 'bad']

interface Vehicle {
  active: boolean
  speed: number
  unit: string
  gear: string
  /** -1 when the engine speed is not reported. */
  rpm: number
  /** -1 when integrity is not reported, which is not the same as 0. */
  integrity: number
  integrityLabel: string
  tone: Tone
  airborne: string
}

const EMPTY: Vehicle = {
  active: false,
  speed: 0,
  unit: '',
  gear: 'N',
  rpm: -1,
  integrity: -1,
  integrityLabel: '',
  tone: 'neutral',
  airborne: ''
}

const vehicle = shallowRef<Vehicle>(EMPTY)

useBridge('opx:hud:vehicle', (payload: Payload) => {
  if (payload.active !== true) {
    vehicle.value = { ...vehicle.value, active: false }
    return
  }

  const tone = text(payload.tone, 'neutral')
  vehicle.value = {
    active: true,
    speed: Math.max(0, Math.round(num(payload.speed))),
    unit: text(payload.unit),
    gear: text(payload.gear, 'N') || 'N',
    // `typeof` and not `num`: 0 rpm is a real reading and -1 has to mean "not reported".
    rpm: typeof payload.rpm === 'number' ? Math.max(0, Math.min(100, payload.rpm)) : -1,
    integrity:
      typeof payload.integrity === 'number' ? Math.max(0, Math.min(100, payload.integrity)) : -1,
    integrityLabel: t(text(payload.integrityLabel)),
    tone: (TONES.indexOf(tone) === -1 ? 'neutral' : tone) as Tone,
    airborne: payload.airborne === true ? t(text(payload.airborneLabel)) : ''
  }
})

const outerFill = computed(() => {
  const value = vehicle.value
  const share = value.rpm >= 0 ? value.rpm : (value.speed / DIAL_KPH) * 100
  return Math.max(0, Math.min(100, share))
})

const redlining = computed(() => vehicle.value.rpm >= REDLINE)

const gearClass = computed(() => {
  const gear = vehicle.value.gear
  if (gear === 'R') return 'reverse'
  if (gear === 'N') return 'neutral'
  return ''
})
</script>

<template>
  <div class="vehicle" :class="{ live: vehicle.active }">
    <div class="dial">
      <svg class="rings" viewBox="0 0 120 120" aria-hidden="true">
        <path class="track" :d="OUTER" pathLength="100" />
        <path class="redline" :d="OUTER" pathLength="100" />
        <path
          class="rpm"
          :class="{ hot: redlining }"
          :d="OUTER"
          pathLength="100"
          :style="{ strokeDasharray: outerFill + ' 100' }"
        />
        <path v-if="vehicle.integrity >= 0" class="inner-track" :d="INNER" pathLength="100" />
        <path
          v-if="vehicle.integrity >= 0"
          class="integrity"
          :class="vehicle.tone"
          :d="INNER"
          pathLength="100"
          :style="{ strokeDasharray: vehicle.integrity + ' 100' }"
        />
      </svg>

      <div class="core">
        <span class="speed">{{ vehicle.speed }}</span>
        <span v-if="vehicle.unit" class="unit">{{ vehicle.unit }}</span>
      </div>
      <span class="gear" :class="gearClass">{{ vehicle.gear }}</span>
    </div>

    <div class="meta">
      <span v-if="vehicle.integrity >= 0" class="integrity-row" :class="vehicle.tone">
        <span class="label">{{ vehicle.integrityLabel }}</span>
        <b>{{ Math.round(vehicle.integrity) }}%</b>
      </span>
      <OpChip v-if="vehicle.airborne" :label="vehicle.airborne" icon="!" tone="accent" />
    </div>
  </div>
</template>

<style scoped>
.vehicle {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--op77-space-1);
  opacity: 0;
  /* The slide is a transform on this block, and the block is not augmented. */
  transform: translateY(8px);
  transition:
    opacity var(--op77-dur) var(--op77-ease),
    transform var(--op77-dur) var(--op77-ease);
}

.vehicle.live {
  opacity: 1;
  transform: none;
}

.dial {
  position: relative;
  width: 112px;
  height: 112px;
}

.rings {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  fill: none;
  stroke-linecap: butt;
}

.track,
.inner-track {
  stroke: var(--op77-panel-raised);
}

.track,
.redline,
.rpm {
  stroke-width: 7;
}

.inner-track,
.integrity {
  stroke-width: 2.5;
}

/* The last stretch of the outer ring, tinted, before the needle reaches it. */
.redline {
  stroke: var(--op77-danger);
  opacity: 0.35;
  stroke-dasharray: 15 100;
  stroke-dashoffset: -85;
}

.rpm,
.integrity {
  stroke-dasharray: 0 100;
  transition:
    stroke-dasharray var(--op77-dur-fast) linear,
    stroke var(--op77-dur-fast) var(--op77-ease);
}

.rpm { stroke: var(--op77-accent); }
.rpm.hot { stroke: var(--op77-danger); }
.integrity { stroke: var(--op77-text-dim); }
.integrity.warn { stroke: var(--op77-warn); }
.integrity.bad { stroke: var(--op77-danger); }

.core {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
}

.speed {
  font: 700 var(--op77-fs-head) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

.unit {
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-dim);
}

/* The gear sits in the dial's open bottom, between the ring's ends. A 4px corner on a
   20px badge: `.op-tag` would put a 6px cut on it and swallow the letter. */
.gear {
  position: absolute;
  bottom: 8px;
  left: 50%;
  transform: translateX(-50%);
  min-width: 18px;
  padding: 3px 4px 2px;
  background: var(--op77-accent);
  clip-path: polygon(0 0, calc(100% - 4px) 0, 100% 4px, 100% 100%, 0 100%);
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  text-align: center;
  color: var(--op77-ink);
}

.gear.neutral {
  background: var(--op77-panel-raised);
  color: var(--op77-text-dim);
}

.gear.reverse {
  background: var(--op77-warn);
}

.meta {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--op77-space-2);
}

.integrity-row {
  display: flex;
  align-items: baseline;
  gap: var(--op77-space-1);
}

.integrity-row .label {
  font: 400 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--op77-text-faint);
  white-space: nowrap;
}

.integrity-row b {
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

.integrity-row.warn b { color: var(--op77-warn); }
.integrity-row.bad b { color: var(--op77-danger); }
</style>
