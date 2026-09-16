<script setup lang="ts">
/**
 * Derived from `opx77_prompts/web/prompts.css` `.cap` -- the only keycap in the tree
 * that carries the press/hold language. (`opx77_hud`'s `.voice-key` is a different,
 * unrelated thing and is not folded in here.)
 *
 * The whole idiom is the weighted base: `inset 0 -2px` reads as a key at rest, `-4px`
 * as a key being held. It is an inset shadow so the 6px cut contains it rather than
 * clipping it -- same reasoning as `.op-rail`.
 */
withDefaults(
  defineProps<{
    /** As Lua sent it. The page does not map scancodes; it has no keyboard layout. */
    label: string
    hold?: boolean
    muted?: boolean
  }>(),
  { hold: false, muted: false }
)
</script>

<template>
  <kbd class="cap op-tag" :class="{ hold, muted }" data-augmented-ui="tr-clip">{{ label }}</kbd>
</template>

<style scoped>
.cap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 24px;
  height: 22px;
  padding: 0 7px;
  padding-right: calc(7px + var(--op77-cut-sm));
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: 0.04em;
  color: var(--op77-accent);
  background: var(--op77-accent-soft);
  box-shadow:
    inset 0 0 0 1px var(--op77-accent-line),
    inset 0 -2px 0 0 var(--op77-accent);
}

.cap.hold {
  box-shadow:
    inset 0 0 0 1px var(--op77-accent-line),
    inset 0 -4px 0 0 var(--op77-accent);
}

.cap.muted {
  color: var(--op77-text-faint);
  background: none;
  box-shadow:
    inset 0 0 0 1px var(--op77-line-strong),
    inset 0 -2px 0 0 var(--op77-line-strong);
}
</style>
