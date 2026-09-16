<script setup lang="ts">
import { onUnmounted, shallowRef } from 'vue'
import OpChip from '@/design/components/OpChip.vue'
import { guard } from '@/bridge/diag'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE STATUS STRIP -- bleeding, burning, netrunning, whatever else the status source
 * publishes. This surface draws them and owns none of them.
 *
 * THE STRIP IS UNTRUSTED INPUT. The client's local bus is shared with every resource on
 * the host, so the original bounded everything in Lua before it reached the page: at most
 * MAX_CHIPS, no id means dropped, the overflow count clamped. The page repeated those
 * bounds rather than trusting its sender, and so does this.
 *
 * The countdown is the page's own arithmetic. `remainingMs` arrives as a DURATION and is
 * turned into a deadline here, on arrival, exactly as hud.js did: the two clocks then
 * never have to agree, and a frame that took 40ms to arrive does not make the chip run
 * 40ms long. `remainingMs` is also deliberately not part of Lua's frame signature -- a
 * counter ticking down is not a new image, and the page animates it alone.
 */
const { t } = useLocale()

/** hud.js MAX_CHIPS. The +N overflow chip does not count against it. */
const MAX_CHIPS = 12
/** The largest `+N` that still reads as a number. */
const MAX_HIDDEN = 999
/** 20 Hz: the underline is 2px tall and this is not the vitals stream. */
const TICK_MS = 50

type Tone = 'neutral' | 'accent' | 'ok' | 'warn' | 'bad' | 'shock'

/**
 * The Cyberpunk damage types hud.css drew separately collapse onto the three tones that
 * already meant the same thing. `shock` survives as itself because it is the one colour
 * in the whole system with no token behind it, and OpChip carries it for that reason.
 */
const TONES: Record<string, Tone> = {
  neutral: 'neutral',
  accent: 'accent',
  ok: 'ok',
  warn: 'warn',
  bad: 'bad',
  shock: 'shock',
  bleed: 'bad',
  burn: 'warn',
  chem: 'ok'
}

interface Chip {
  id: string
  icon: string
  label: string
  tone: Tone
  /** Epoch ms, or 0 when this chip is not counting down. */
  endsAt: number
  /** The lifetime the remainder is drawn against; 0 when there is none. */
  totalMs: number
  /** 0..1, or -1 for "draw no underline", which is what OpChip reads. */
  progress: number
}

const chips = shallowRef<Chip[]>([])
const hidden = shallowRef(0)

let timer: ReturnType<typeof setInterval> | undefined

useBridge('opx:hud:status', (payload: Payload) => {
  const atMs = Date.now()
  const seen: Record<string, boolean> = {}
  const next: Chip[] = []

  for (const row of list<Payload>(payload.chips)) {
    if (next.length >= MAX_CHIPS) break
    const id = text(row.id)
    if (!id || seen[id]) continue
    seen[id] = true

    const remainingMs = num(row.remainingMs)
    const totalMs = num(row.totalMs)
    const timed = remainingMs > 0 && totalMs > 0
    // A static share, for an effect with a level rather than a lifetime.
    const fixed = typeof row.progress === 'number' ? Math.max(0, Math.min(1, row.progress)) : -1

    next.push({
      id,
      icon: text(row.icon).slice(0, 4),
      label: t(text(row.label)),
      tone: TONES[text(row.tone, 'neutral')] ?? 'neutral',
      endsAt: timed ? atMs + remainingMs : 0,
      totalMs: timed ? totalMs : 0,
      progress: timed ? Math.max(0, Math.min(1, remainingMs / totalMs)) : fixed
    })
  }

  chips.value = next
  hidden.value = Math.max(0, Math.min(MAX_HIDDEN, Math.round(num(payload.hidden))))
  pump()
})

function tick(): void {
  const atMs = Date.now()
  let running = false
  let changed = false

  const next = chips.value.map((chip) => {
    if (chip.endsAt === 0) return chip
    const left = Math.max(0, Math.min(1, (chip.endsAt - atMs) / chip.totalMs))
    if (left > 0) running = true
    if (Math.abs(left - chip.progress) < 0.002) return chip
    changed = true
    return { ...chip, progress: left }
  })

  if (changed) chips.value = next
  // Nothing is removed at zero: the chip leaves when the status source stops sending it,
  // and an empty underline under a chip that is still real is the truth.
  if (!running) stop()
}

function pump(): void {
  if (timer !== undefined) return
  if (!chips.value.some((chip) => chip.endsAt > 0)) return
  // Outside a bridge handler, so channel.ts is not above this to catch a throw.
  timer = setInterval(() => guard('hud status tick', tick, undefined), TICK_MS)
}

function stop(): void {
  if (timer === undefined) return
  clearInterval(timer)
  timer = undefined
}

onUnmounted(stop)
</script>

<template>
  <div v-if="chips.length" class="strip">
    <OpChip
      v-for="chip in chips"
      :key="chip.id"
      :label="chip.label"
      :icon="chip.icon"
      :tone="chip.tone"
      :progress="chip.progress"
    />
    <!-- What did not fit, counted rather than dropped. -->
    <OpChip v-if="hidden > 0" :label="'+' + hidden" overflow />
  </div>
</template>

<style scoped>
.strip {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op77-space-2);
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}
</style>
