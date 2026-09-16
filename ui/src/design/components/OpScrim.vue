<script setup lang="ts">
/**
 * Derived from `opx77_input/web/input.css` `.scrim` and `opx77_panel`'s `.room`.
 *
 * Two modes because the two resources needed different things and both were right.
 * `flat` is input's full dim, for a surface that owns the screen. `lead` is panel's
 * directional gradient, which dims only the side the drawer is on so the player can
 * still see the world they are standing in -- the reason a shop panel does not feel
 * like a pause menu.
 *
 * `pointer-events` is the load-bearing property, not the colour: this is what makes a
 * surface modal, and only the interactive surface may ever render it.
 */
withDefaults(defineProps<{ mode?: 'flat' | 'lead'; visible?: boolean }>(), {
  mode: 'flat',
  visible: true
})
</script>

<template>
  <div class="scrim" :class="[mode, { visible }]" />
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op77-dur) var(--op77-ease);
}

.scrim.visible {
  opacity: 1;
  pointer-events: auto;
}

.flat {
  background: var(--op77-scrim);
}

.lead {
  background: linear-gradient(
    to right,
    var(--op77-scrim) 0,
    var(--op77-scrim) 34%,
    transparent 58%
  );
}
</style>
