<script setup lang="ts">
import { computed, ref } from 'vue'
import OpChip from '@/design/components/OpChip.vue'
import OpGauge from '@/design/components/OpGauge.vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import OpToast from '@/design/components/OpToast.vue'
import { useBridge } from '@/composables/useBridge'
import { useCountdown } from '@/composables/useCountdown'
import { useLocale } from '@/composables/useLocale'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * The overlay demo: the HUD half of the design system, driven entirely by channels.
 *
 * It is a demo in that the dev shim is what feeds it in a browser. In game the exact
 * same handlers are fed by Lua, and nothing here changes.
 */
const { t } = useLocale()

interface Gauge {
  id: string
  label: string
  value: number
  tone: 'neutral' | 'health' | 'warn' | 'bad'
}

interface Toast {
  id: string
  kind: 'info' | 'success' | 'warning' | 'error'
  title: string
  message: string
  deadline: number
}

const gauges = ref<Gauge[]>([])
const toasts = ref<Toast[]>([])

useBridge('opx:hud:gauges', (payload: Payload) => {
  // `list()` and not `payload.gauges || []`: an empty Lua table is `{}`, which is
  // truthy, and `{}.map` is the throw the bridge would swallow.
  gauges.value = list<Payload>(payload.gauges).map((row) => ({
    id: text(row.id),
    label: text(row.label),
    value: num(row.value),
    tone: (text(row.tone, 'neutral') as Gauge['tone'])
  }))
})

useBridge('opx:notify:show', (payload: Payload) => {
  const id = text(payload.id)
  if (!id) return
  toasts.value = [
    ...toasts.value.filter((toast) => toast.id !== id),
    {
      id,
      kind: text(payload.kind, 'info') as Toast['kind'],
      title: t(text(payload.title)),
      message: text(payload.message),
      deadline: Date.now() + num(payload.durationMs, 5000)
    }
  ]
})

useBridge('opx:notify:hide', (payload: Payload) => {
  const id = text(payload.id)
  toasts.value = toasts.value.filter((toast) => toast.id !== id)
})

/* One countdown drives the whole stack's progress bars. It is display only: nothing
   here removes a toast when it reaches zero, because Lua sends `opx:notify:hide` and
   Lua's clock is the one that counts. A surface throttled to a fraction of its 30fps
   would otherwise drop a toast the server still considers on screen. */
const soonest = computed(() =>
  toasts.value.length ? Math.min(...toasts.value.map((toast) => toast.deadline)) : 0
)
const { remainingMs } = useCountdown(soonest)

function progressFor(toast: Toast): number {
  void remainingMs.value // re-evaluates on every tick
  const left = toast.deadline - Date.now()
  return Math.max(0, Math.min(1, left / 60000))
}
</script>

<template>
  <div class="hud">
    <div class="stack">
      <OpToast
        v-for="toast in toasts"
        :key="toast.id"
        :kind="toast.kind"
        :title="toast.title"
        :message="toast.message"
        icon="//"
        :progress="progressFor(toast)"
      />
    </div>

    <div class="meters">
      <OpGauge
        v-for="gauge in gauges"
        :key="gauge.id"
        :value="gauge.value"
        :label="t(gauge.label)"
        :tone="gauge.tone"
      />
      <div class="chips">
        <OpChip label="Netrunning" icon="!" tone="accent" :progress="0.62" />
        <OpChip label="Bleeding" icon="+" tone="bad" :progress="0.25" />
        <OpChip label="+2" overflow />
      </div>
      <div class="keys">
        <OpKeyCap label="F" />
        <OpKeyCap label="G" hold />
        <OpKeyCap label="ALT" muted />
      </div>
    </div>
  </div>
</template>

<style scoped>
.hud {
  position: absolute;
  inset: 0;
}

.stack {
  position: absolute;
  top: var(--op77-inset-y);
  right: var(--op77-inset-x);
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  width: 340px;
}

.meters {
  position: absolute;
  left: var(--op77-inset-x);
  bottom: var(--op77-inset-y);
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  width: 210px;
}

.chips,
.keys {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op77-space-2);
}
</style>
