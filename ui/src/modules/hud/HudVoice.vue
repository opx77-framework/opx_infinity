<script setup lang="ts">
import { shallowRef } from 'vue'
import OpChip from '@/design/components/OpChip.vue'
import OpGauge from '@/design/components/OpGauge.vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE VOICE BLOCK -- right edge, vertically centred, as it has always been.
 *
 * Lua decides the state and every word. This lights what it is told and never infers:
 * `talking` is not "the meter is above a threshold", it is what the voice stack said.
 *
 * WHAT CHANGED: hud.css drew a 52px column with a bespoke cut mic plate and a VERTICAL
 * eight-slat meter, hand-clipped, with its own `.voice-key` keycap that the design system
 * explicitly refused to fold into OpKeyCap. That column is a card now: one `OpPanel`
 * frame, a horizontal `OpGauge` for the input level, and real `OpKeyCap`s for the keys.
 *
 * Folding `.voice-key` into OpKeyCap is the change I am least able to defend from the
 * design system's own notes, which call it "a different, unrelated thing". It is not: it
 * is the name of a key the player presses, drawn next to the thing pressing it does, and
 * the whole point of the exercise is that there is one keycap now. The vertical meter is
 * the real casualty -- see the report.
 */
const { t } = useLocale()

withDefaults(defineProps<{ segments?: number }>(), { segments: 8 })

type State = 'idle' | 'detected' | 'talking' | 'muted' | 'offline'

const STATES: readonly string[] = ['idle', 'detected', 'talking', 'muted', 'offline']

/**
 * OpGauge knows four tones and they are roles, not moods. `talking` takes the accent
 * (`health` is OpGauge's name for it), `muted` takes the danger tone, and the three quiet
 * states share the neutral one -- the mic plate beside the meter is what separates those.
 */
const METER_TONES: Record<State, 'neutral' | 'health' | 'warn' | 'bad'> = {
  idle: 'neutral',
  detected: 'neutral',
  talking: 'health',
  muted: 'bad',
  offline: 'neutral'
}

interface Voice {
  active: boolean
  state: State
  caption: string
  mode: string
  distance: string
  /** 0..100, the input level. A percentage, because OpGauge takes percentages. */
  level: number
  /** How many reach modes there are, and which one is current. */
  count: number
  index: number
  key: string
  activation: string
  /** How many players are audible right now. */
  heard: number
}

const EMPTY: Voice = {
  active: false,
  state: 'offline',
  caption: '',
  mode: '',
  distance: '',
  level: 0,
  count: 0,
  index: 0,
  key: '',
  activation: '',
  heard: 0
}

const voice = shallowRef<Voice>(EMPTY)

useBridge('opx:hud:voice', (payload: Payload) => {
  if (payload.active !== true) {
    // Not emptied: the block fades on `active`, and a cleared payload would make it fade
    // out with its caption already gone.
    voice.value = { ...voice.value, active: false }
    return
  }

  const state = text(payload.state, 'offline')
  const count = Math.max(0, Math.min(8, Math.round(num(payload.count))))

  voice.value = {
    active: true,
    state: (STATES.indexOf(state) === -1 ? 'offline' : state) as State,
    caption: t(text(payload.caption)),
    mode: t(text(payload.mode)),
    distance: text(payload.distance),
    level: Math.max(0, Math.min(100, num(payload.level))),
    count,
    index: Math.max(0, Math.min(count, Math.round(num(payload.index)))),
    key: text(payload.key),
    activation: text(payload.activation),
    heard: Math.max(0, Math.round(num(payload.heard)))
  }
})
</script>

<template>
  <div class="voice" :class="[voice.state, { live: voice.active }]">
    <OpPanel anchor="end" :lift="false">
      <div class="head">
        <span class="mic">
          <svg
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M8 10.2a2.5 2.5 0 0 0 2.5-2.5V4.1a2.5 2.5 0 1 0-5 0v3.6A2.5 2.5 0 0 0 8 10.2Z" />
            <path d="M3.9 7.2v.5a4.1 4.1 0 0 0 8.2 0v-.5M8 11.8v2.4M5.9 14.2h4.2" />
          </svg>
          <!-- The slash draws itself on with a scaleX transform on a child, never on the
               frame: an --aug-* value would recompute the polygon to cross out a mic. -->
          <i class="slash" />
        </span>
        <span v-if="voice.caption" class="caption">{{ voice.caption }}</span>
      </div>

      <OpGauge
        :value="voice.level"
        :segments="segments"
        :tone="METER_TONES[voice.state]"
        :readout="false"
        label="voice"
      />

      <div v-if="voice.mode || voice.distance" class="reach">
        <span v-if="voice.mode" class="mode">{{ voice.mode }}</span>
        <span v-if="voice.distance" class="distance">{{ voice.distance }}</span>
      </div>

      <!-- Which reach mode of the cycle is active. Not a meter: a meter is a quantity and
           this is a selection, so it is five lines of CSS and not an OpGauge. -->
      <div v-if="voice.count > 0" class="pips">
        <i v-for="n in voice.count" :key="n" class="pip" :class="{ on: n <= voice.index }" />
      </div>

      <div v-if="voice.key || voice.activation" class="keys">
        <OpKeyCap v-if="voice.key" :label="voice.key" />
        <!-- The activation key is `muted`, which in OpKeyCap means outlined rather than
             filled. It is how you talk, not what you press to act. -->
        <OpKeyCap v-if="voice.activation" :label="voice.activation" muted />
      </div>

      <!-- The one live counter here, so the one thing allowed to glow. -->
      <span v-if="voice.heard > 0" class="rx">
        <OpChip :label="String(voice.heard)" icon="RX" tone="ok" />
      </span>
    </OpPanel>
  </div>
</template>

<style scoped>
.voice {
  position: fixed;
  right: var(--op77-inset-x);
  top: 50%;
  width: 168px;
  --voice-tone: var(--op77-text-dim);
  opacity: 0;
  transform: translate(8px, -50%);
  transition:
    opacity var(--op77-dur) var(--op77-ease),
    transform var(--op77-dur) var(--op77-ease);
}

.voice.live {
  opacity: 1;
  transform: translate(0, -50%);
}

.idle { --voice-tone: var(--op77-text-dim); }
.detected { --voice-tone: var(--op77-text); }
.talking { --voice-tone: var(--op77-accent); }
.muted { --voice-tone: var(--op77-danger); }
.offline { --voice-tone: var(--op77-text-faint); }

.head {
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
}

.mic {
  position: relative;
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  color: var(--voice-tone);
  transition: color var(--op77-dur-fast) var(--op77-ease);
}

.mic svg {
  display: block;
  width: 18px;
  height: 18px;
}

.talking .mic svg {
  filter: drop-shadow(0 0 5px var(--op77-accent-line));
}

.slash {
  position: absolute;
  left: 50%;
  top: 50%;
  width: 22px;
  height: 2px;
  background: var(--voice-tone);
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(0);
  transition: transform var(--op77-dur-fast) var(--op77-ease);
}

.muted .slash,
.offline .slash {
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(1);
}

.caption {
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--voice-tone);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.reach {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op77-space-2);
}

.mode {
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-accent);
  white-space: nowrap;
}

.distance {
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

.pips {
  display: flex;
  gap: 3px;
}

.pip {
  width: 10px;
  height: 3px;
  background: var(--op77-panel-raised);
  clip-path: polygon(2px 0, 100% 0, calc(100% - 2px) 100%, 0 100%);
}

.pip.on {
  background: var(--op77-accent);
}

.keys {
  display: flex;
  gap: var(--op77-space-1);
}

/* `--op77-glow` is for live things only, and someone talking in your ear is the most live
   thing on this surface. The pulse is opacity on a wrapper, never a shape. */
.rx {
  display: inline-flex;
  box-shadow: var(--op77-glow);
  animation: rx 1.1s ease-in-out infinite;
}

@keyframes rx {
  0%, 100% { opacity: 0.62; }
  50% { opacity: 1; }
}
</style>
