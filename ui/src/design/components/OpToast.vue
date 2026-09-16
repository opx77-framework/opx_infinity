<script setup lang="ts">
import { computed } from 'vue'

/**
 * Derived from `opx77_notify/web/notify.css` `.toast`, which was the only direct
 * consumer of the 12px `--op77-notch-clip` token -- so it is the one component whose
 * shape did not have to be renegotiated, only moved onto `.op-panel`.
 *
 * Severity is one variable. notify.css got this right: each of `.info` / `.success` /
 * `.warning` / `.error` re-points `--accent` and changes nothing else, with exactly one
 * exception (an error's message takes full-strength text, because a red-accented line
 * of dim grey is the one combination that fails to read over a bright frame).
 */
const props = withDefaults(
  defineProps<{
    title: string
    message?: string
    /** Up to a few characters of caller text, not an icon font. notify.js allows 16. */
    icon?: string
    kind?: 'info' | 'success' | 'warning' | 'error'
    /** 0..1. Lua owns the lifetime; this is its last reported remainder. */
    progress?: number
  }>(),
  { message: '', icon: '', kind: 'info', progress: -1 }
)

const barWidth = computed(() => `${Math.max(0, Math.min(1, props.progress)) * 100}%`)
</script>

<template>
  <article class="toast op-panel op-lift" :class="kind" data-augmented-ui="tl-clip br-clip border">
    <span v-if="icon" class="icon">{{ icon }}</span>
    <div class="body">
      <span class="title">{{ title }}</span>
      <span v-if="message" class="message">{{ message }}</span>
    </div>
    <!-- Width, not a CSS animation: the bar has to track Lua's remaining time, and a
         keyframe would drift from it the moment the surface is throttled. -->
    <span v-if="progress >= 0" class="bar" :style="{ width: barWidth }" />
  </article>
</template>

<style scoped>
.toast {
  --accent: var(--op77-accent);
  position: relative;
  display: flex;
  align-items: flex-start;
  gap: var(--op77-space-3);
  padding: var(--op77-space-3) calc(var(--op77-space-4) + var(--op77-cut-md))
    var(--op77-space-3) var(--op77-space-4);
  box-shadow: inset var(--op77-rule) 0 0 0 var(--accent);
  overflow: hidden;
}

.icon {
  flex: none;
  min-width: 18px;
  max-width: 64px;
  padding-top: 1px;
  font: 900 var(--op77-fs-meta) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--accent);
  overflow-wrap: anywhere;
}

.body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.title {
  font: 700 var(--op77-fs-title) / 1.15 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  overflow-wrap: anywhere;
}

.message {
  font: 400 var(--op77-fs-body) / 1.35 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.bar {
  position: absolute;
  left: 0;
  bottom: 0;
  height: 2px;
  background: var(--accent);
}

.info { --accent: var(--op77-accent); }
.success { --accent: var(--op77-ok); }
.warning { --accent: var(--op77-warn); }
.error { --accent: var(--op77-signal); }

/* The one exception to "severity only moves --accent". */
.error .message {
  color: var(--op77-text);
}
</style>
