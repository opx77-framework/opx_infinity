<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import OpField from '@/design/components/OpField.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import OpScrim from '@/design/components/OpScrim.vue'
import OpSpinner from '@/design/components/OpSpinner.vue'
import OpTabs from '@/design/components/OpTabs.vue'
import type { Tab } from '@/design/components/OpTabs.vue'
import { emit } from '@/bridge/channel'
import { acquireFocus } from '@/bridge/focus'
import { BridgeError, request } from '@/bridge/rpc'
import { list, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * The interactive demo: a panel the player drives.
 *
 * Every interaction below sends an INTENT and waits to be told what happened. Nothing
 * on screen changes because this component decided it should -- the consent row does
 * not tick itself, the tab does not switch until the round trip returns. That looks
 * like latency and it is: it is the latency of being correct on a platform where the
 * client is not the authority.
 */
const { t } = useLocale()

const title = ref('')
const eyebrow = ref('')
const tabs = ref<Tab[]>([])
const selected = ref('')
const consent = ref(false)
const callsign = ref('')
const district = ref('Watson')
const dose = ref(40)
const busy = ref(false)
const failure = ref('')

useBridge('opx:panel:open', (payload: Payload) => {
  title.value = t(text(payload.title))
  eyebrow.value = t(text(payload.eyebrow))
  tabs.value = list<Payload>(payload.tabs).map((tab) => ({
    id: text(tab.id),
    label: t(text(tab.label)),
    marked: tab.marked === true
  }))
  selected.value = tabs.value.length ? tabs.value[0].id : ''
})

useBridge('opx:panel:state', (payload: Payload) => {
  // Lua's answer, applied verbatim. This is the only writer of `consent`.
  consent.value = payload.consent === true
})

/* Focus is acquired for as long as this module is mounted and released the moment it
   is not -- including when ModuleHost unmounts it after a throw. A module that died
   holding focus is a player who cannot move. */
let release: (() => void) | undefined

onMounted(() => {
  release = acquireFocus({
    id: 'panel',
    onEscape: () => emit('opx:panel:close', {})
  })
})

onUnmounted(() => release?.())

async function choose(id: string): Promise<void> {
  busy.value = true
  failure.value = ''
  try {
    await request('opx:panel:select', { tab: id })
    selected.value = id
  } catch (error) {
    // The rejection carries a locale KEY, never a sentence: `t` is what turns it into
    // the player's language, and an untranslated key on screen is a visible bug.
    failure.value = error instanceof BridgeError ? t(error.localeKey) : t('error.rpc_failed')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="room">
    <OpScrim mode="lead" />
    <div class="drawer">
      <OpPanel bay>
        <template #header>
          <div class="head-text">
            <span class="op77-eyebrow">{{ eyebrow }}</span>
            <h1>{{ title }}</h1>
          </div>
          <OpSpinner v-if="busy" />
        </template>

        <OpTabs :tabs="tabs" :selected="selected" @select="choose" />

        <OpRow :label="t('demo.row.name')" rule />
        <OpRow :label="t('demo.row.name')" value="V" @select="emit('opx:panel:inspect', {})" />
        <OpRow :label="t('demo.row.balance')" value="12 450 €$" />
        <OpRow
          :label="t('demo.row.consent')"
          :checked="consent"
          :hint="t('demo.row.hint')"
          @toggle="emit('opx:panel:consent', {})"
        />

        <OpRow :label="t('demo.field.callsign')" rule />
        <OpField
          :label="t('demo.field.callsign')"
          kind="text"
          :model-value="callsign"
          placeholder="V"
          count="0/24"
          selected
          @input="callsign = $event"
        />
        <OpField
          :label="t('demo.field.district')"
          kind="choice"
          :model-value="district"
          @step="emit('opx:panel:step', { field: 'district', direction: $event })"
        />
        <OpField :label="t('demo.field.dose')" kind="slider" :model-value="dose" :max="100" />

        <template #footer>
          <span v-if="failure" class="failure">{{ failure }}</span>
        </template>
      </OpPanel>
    </div>
  </div>
</template>

<style scoped>
.room {
  position: absolute;
  inset: 0;
}

.drawer {
  position: absolute;
  left: var(--op77-inset-x);
  top: var(--op77-inset-y);
  bottom: var(--op77-inset-y);
  width: 600px;
  display: flex;
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin-right: auto;
}

.head-text h1 {
  margin: 0;
  font: 700 var(--op77-fs-head) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
}

.failure {
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-danger);
}
</style>
