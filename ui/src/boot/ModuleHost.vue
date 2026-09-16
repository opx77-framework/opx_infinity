<script setup lang="ts">
import { onErrorCaptured, ref } from 'vue'
import { report } from '@/bridge/diag'
import { noteModuleFailure } from '@/stores/ui'

/**
 * Failure isolation.
 *
 * Today a thrown exception in one page cannot reach another because the twelve pages
 * are twelve separate browsers. Folding them into one Vue app gives that property up
 * for free, and this wrapper buys it back. It does not improve on it: a module that
 * throws still dies. What it guarantees is that only that module dies.
 *
 * `onErrorCaptured` returning `false` stops the error propagating to the parent, which
 * is the entire point -- an uncaught render error unmounts the whole app, and the HUD
 * shares that app with every view now, so it means the health bar goes black while the
 * player is being shot at.
 *
 * WHAT THIS DOES NOT CATCH, and none of it is theoretical:
 *  - a throw inside an `Open77.on` handler. Vue never sees it; the bridge swallows it.
 *    bridge/channel.ts wraps those separately.
 *  - a rejected promise. diag.ts listens for `unhandledrejection`.
 *  - a throw in this host's own template. There is nothing above it to catch that,
 *    which is why this template is four elements and no logic.
 *
 * There is no automatic retry. A module that threw once during render will throw again
 * on the same state, and a remount loop at 30fps is how you exhaust the 20-report
 * diagnostic budget in under a second.
 */
const props = defineProps<{ id: string }>()

const failed = ref(false)
const reason = ref('')

onErrorCaptured((error: unknown, _instance, info: string) => {
  failed.value = true
  reason.value = info
  report(error, `module ${props.id} [${info}]`)
  noteModuleFailure(props.id)
  return false
})
</script>

<template>
  <div class="module-host" :data-module="id" :data-failed="failed ? reason : undefined">
    <slot v-if="!failed" />
  </div>
</template>

<style scoped>
.module-host {
  display: contents;
}
</style>
