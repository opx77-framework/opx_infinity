<script setup lang="ts">
/**
 * Derived from `opx77_panel/web/panel.css` `.tabs` / `.tab` -- the only tabs anywhere
 * in the tree, and the one panel surface with no cut at all. That is kept: a row of
 * notched tabs reads as a row of separate plates, which is the opposite of what a tab
 * strip is saying.
 *
 * `.marked` is panel's unread dot.
 */
export interface Tab {
  id: string
  label: string
  marked?: boolean
  disabled?: boolean
}

defineProps<{
  tabs: Tab[]
  selected: string
}>()

const emit = defineEmits<{
  (event: 'select', id: string): void
}>()
</script>

<template>
  <nav class="tabs" role="tablist" :style="{ '--columns': tabs.length }">
    <button
      v-for="tab in tabs"
      :key="tab.id"
      class="tab"
      type="button"
      role="tab"
      :class="{ selected: tab.id === selected, marked: tab.marked }"
      :aria-selected="tab.id === selected"
      :disabled="tab.disabled"
      @click="emit('select', tab.id)"
    >
      {{ tab.label }}
    </button>
  </nav>
</template>

<style scoped>
.tabs {
  display: grid;
  grid-template-columns: repeat(var(--columns, 4), 1fr);
  gap: var(--op77-space-1);
}

.tab {
  position: relative;
  min-height: 40px;
  padding: var(--op77-space-2);
  font: 600 var(--op77-fs-label) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
  background: var(--op77-panel);
  border: 1px solid var(--op77-line-hud);
  cursor: default;
  transition:
    color var(--op77-dur-fast) var(--op77-ease),
    background var(--op77-dur-fast) var(--op77-ease),
    border-color var(--op77-dur-fast) var(--op77-ease);
}

.tab:hover:not(:disabled) {
  color: var(--op77-text);
  border-color: var(--op77-line-strong);
}

.tab.selected {
  color: var(--op77-ink);
  background: var(--op77-accent);
  border-color: var(--op77-accent);
}

.tab:disabled {
  opacity: 0.4;
}

/* Not augmented, so this element's own ::after is free. */
.tab.marked:not(.selected)::after {
  content: "";
  position: absolute;
  top: 5px;
  right: 5px;
  width: 5px;
  height: 5px;
  background: var(--op77-accent);
}
</style>
