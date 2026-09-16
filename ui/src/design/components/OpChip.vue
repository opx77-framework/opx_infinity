<script setup lang="ts">
/**
 * Derived from `opx77_hud/web/hud.css` `.chip` (status effects) and
 * `opx77_admin/web/tags.css` `.tag-id` / `.tag-badge` (staff tags). The HUD cut a
 * 10px bottom-right shear, admin cut a 6px top-right notch; they are the same object
 * and they are `.op-tag` now.
 *
 * Tones are the HUD's, including the Cyberpunk damage types, which are the reason the
 * list is longer than ok/warn/bad: `shock` is the one colour in the whole system with
 * no token, so it stays local and stays commented.
 */
withDefaults(
  defineProps<{
    label: string
    /** A few characters, same contract as the toast icon. */
    icon?: string
    tone?: 'neutral' | 'accent' | 'ok' | 'warn' | 'bad' | 'shock'
    /** 0..1 of remaining duration, drawn as the underline. -1 hides it. */
    progress?: number
    /** hud.css `.chip.more`: the "+3 more" overflow chip. */
    overflow?: boolean
  }>(),
  { icon: '', tone: 'neutral', progress: -1, overflow: false }
)
</script>

<template>
  <span
    class="chip op-tag"
    :class="[tone, { overflow }]"
    :data-augmented-ui="overflow ? undefined : 'tr-clip'"
  >
    <span v-if="icon" class="icon">{{ icon }}</span>
    <span class="label">{{ label }}</span>
    <span
      v-if="progress >= 0"
      class="time"
      :style="{ width: `${Math.max(0, Math.min(1, progress)) * 100}%` }"
    />
  </span>
</template>

<style scoped>
.chip {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: var(--op77-space-2);
  padding: 5px var(--op77-space-3);
  padding-right: calc(var(--op77-space-3) + var(--op77-cut-sm));
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text);
  background: var(--op77-panel);
  white-space: nowrap;
  overflow: hidden;
}

.icon {
  flex: none;
  font: 900 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  color: var(--op77-text-dim);
}

.time {
  position: absolute;
  left: 0;
  bottom: 0;
  height: 2px;
  background: var(--op77-text-dim);
}

.accent .icon, .accent .time { color: var(--op77-accent); background: var(--op77-accent); }
.ok .icon { color: var(--op77-ok); }
.ok .time { background: var(--op77-ok); }
.warn .icon { color: var(--op77-warn); }
.warn .time { background: var(--op77-warn); }
.bad .icon { color: var(--op77-danger); }
.bad .time { background: var(--op77-danger); }

/* The only colour in the system with no token. It is a damage type, not a UI role, so
   promoting it to the token file would say something about the design system that is
   not true. */
.shock .icon { color: #7fb4ff; }
.shock .time { background: #7fb4ff; }

/* Square and dashed on purpose: the overflow chip is a count, not a status. */
.overflow {
  padding-right: var(--op77-space-3);
  background: var(--op77-panel-quiet);
  border: 1px dashed var(--op77-line-strong);
  color: var(--op77-text-faint);
}
</style>
