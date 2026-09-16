<script setup lang="ts">
/**
 * Derived from `opx77_target/web/target.css` `.spinner` -- the only loading indicator
 * that exists anywhere in the tree. `opx77_panel` shows the word "loading" instead and
 * `opx77_loadscreen` shows nothing at all, so this is not a port of a convention, it
 * is the promotion of the one implementation there was.
 *
 * Not augmented and never will be: rule 3 in design/augmented.css. This spins a
 * transform on a leaf node, which is the cheap case.
 */
withDefaults(defineProps<{ size?: number; inverted?: boolean }>(), {
  size: 10,
  inverted: false
})
</script>

<template>
  <span
    class="spinner"
    :class="{ inverted }"
    :style="{ width: `${size}px`, height: `${size}px` }"
    aria-hidden="true"
  />
</template>

<style scoped>
.spinner {
  flex: 0 0 auto;
  display: inline-block;
  border: 2px solid var(--op77-accent-soft);
  border-top-color: var(--op77-accent);
  animation: spin 0.65s linear infinite;
}

/* On an accent fill the accent is the background, so the ring inverts. */
.inverted {
  border-color: rgba(10, 10, 5, 0.25);
  border-top-color: var(--op77-ink);
}

@keyframes spin {
  to { transform: rotate(360deg); }
}
</style>
