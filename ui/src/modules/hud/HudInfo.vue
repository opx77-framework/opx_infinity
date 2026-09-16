<script setup lang="ts">
import { shallowRef } from 'vue'
import OpPanel from '@/design/components/OpPanel.vue'
import { list, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import type { Anchor } from './anchors'
import { railOf } from './anchors'

/**
 * THE READ-OUT -- money, job, street cred, and anything else Lua decides to name.
 *
 * `buildMoney` and `buildIdentity` in `opx77_hud/client/state.lua` decide which lines
 * exist, in which order, and with which tone; this draws them. It has no idea what a
 * currency is.
 *
 * WHAT CHANGED: hud.css drew these as bare text over gameplay and paid for legibility
 * with a double `text-shadow`, because a shadow was the only thing holding a grey mono
 * line against a blown-out white plaza. That worked and looked like nothing else on the
 * platform. It is an `OpPanel` now -- ONE augmented frame, `--op77-panel` at 0.94 alpha
 * behind it, and the `op-rail` house marker on its leading edge. The panel is what makes
 * it legible, so the shadow is gone with it.
 *
 * `:lift="false"` is deliberate. `.op-lift` is THE one shadow in the system, a separation
 * device and not a depth ramp, and the toasts already spend it on this surface.
 */
const { t } = useLocale()

withDefaults(defineProps<{ anchor?: Anchor }>(), { anchor: 'top-right' })

type Tone = 'neutral' | 'on' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'on', 'warn', 'bad']

interface Line {
  id: string
  label: string
  value: string
  tone: Tone
}

const eyebrow = shallowRef('')
const lines = shallowRef<Line[]>([])

function toneOf(value: unknown): Tone {
  const name = text(value, 'neutral')
  return TONES.indexOf(name) === -1 ? 'neutral' : (name as Tone)
}

useBridge('opx:hud:info', (payload: Payload) => {
  eyebrow.value = t(text(payload.eyebrow))
  lines.value = list<Payload>(payload.lines)
    .filter((row) => text(row.id) !== '')
    .map((row) => ({
      id: text(row.id),
      label: t(text(row.label)),
      // Already formatted by Lua: separators, currency symbols and rounding are all
      // decisions, and a page that formatted a number would be making one.
      value: text(row.value),
      tone: toneOf(row.tone)
    }))
})
</script>

<template>
  <OpPanel
    v-if="lines.length"
    class="info"
    :anchor="railOf(anchor)"
    :lift="false"
    :class="railOf(anchor) === 'end' ? 'to-end' : 'to-start'"
  >
    <template v-if="eyebrow" #header>
      <span class="op77-eyebrow">{{ eyebrow }}</span>
    </template>

    <div v-for="line in lines" :key="line.id" class="line" :class="line.tone">
      <span class="label">{{ line.label }}</span>
      <span v-if="line.value" class="value">{{ line.value }}</span>
    </div>
  </OpPanel>
</template>

<style scoped>
.info {
  min-width: 180px;
  max-width: 34vw;
}

.line {
  display: flex;
  align-items: baseline;
  gap: var(--op77-space-3);
  font: 400 var(--op77-fs-meta) / 1.3 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
  white-space: nowrap;
}

/* Right-anchored: the value lands on the edge the panel is pinned to, so a column of
   numbers reads down the outside instead of down the middle. */
.to-end .line {
  justify-content: space-between;
}

.value {
  margin-left: auto;
  font-weight: 700;
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

/* Tones are Lua's. `on` is the one the job line uses for on duty. */
.on .value { color: var(--op77-ok); }
.warn .value { color: var(--op77-warn); }
.bad .value { color: var(--op77-danger); }
</style>
