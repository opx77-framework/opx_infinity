<script setup lang="ts">
import ModuleHost from './ModuleHost.vue'
import { modulesFor } from './registry'
import type { SurfaceName } from '@/stores/ui'

/**
 * The root of both surfaces. It renders the registry and nothing else.
 *
 * Every module is a sibling under its own ModuleHost, deliberately: siblings cannot
 * reach each other, so the failure of one is contained by construction rather than by
 * discipline. Nesting a module inside another module would put the inner one's
 * failures inside the outer one's blast radius.
 */
const props = defineProps<{ surface: SurfaceName }>()

const modules = modulesFor(props.surface)
</script>

<template>
  <div class="surface" :class="`surface-${surface}`">
    <ModuleHost v-for="module in modules" :id="module.id" :key="module.id">
      <component :is="module.component" />
    </ModuleHost>
  </div>
</template>

<style scoped>
.surface {
  position: fixed;
  inset: 0;
}

/* The overlay is never focused and never takes a click: it sits at z 700 over live
   gameplay, and a transparent full-screen div that eats pointer events is a player who
   cannot shoot. Modules that need a pointer re-enable it on themselves -- and on the
   overlay, nothing should. */
.surface-overlay {
  pointer-events: none;
  user-select: none;
}
</style>
