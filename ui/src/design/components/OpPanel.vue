<script setup lang="ts">
/**
 * The surface frame. Derived from `opx77_panel/web/panel.css` (`.drawer` + `.plate`)
 * and `opx77_menu/web/menu.css` (`.strip` / `.head`).
 *
 * Panel had a 12px `--cut` and menu had 20px; both are `.op-panel` now and the size
 * is a token. The header is the leading-edge accent rule (`.op-rail`) -- the house
 * marker -- and is where the eyebrow lives.
 *
 * ONE augmented element for the whole panel. The header, body and footer inside it are
 * plain boxes: see rule 1 in design/augmented.css.
 */
withDefaults(
  defineProps<{
    /** Right-anchored surfaces read leading-edge as the right edge. */
    anchor?: 'start' | 'end'
    /** A bay is the larger frame: a panel that holds a grid or a long list. */
    bay?: boolean
    lift?: boolean
  }>(),
  { anchor: 'start', bay: false, lift: true }
)
</script>

<template>
  <!-- Single root, here and in every component: Vue 2.7 has no fragments, and a
       multi-root template is the one thing that would make the fallback a rewrite. -->
  <section
    class="op-panel-root"
    :class="[bay ? 'op-bay' : 'op-panel', { 'op-lift': lift }]"
    data-augmented-ui="tl-clip br-clip border inlay"
  >
    <header v-if="$slots.header" class="head" :class="anchor === 'end' ? 'op-rail-end' : 'op-rail'">
      <slot name="header" />
    </header>
    <div class="body">
      <slot />
    </div>
    <footer v-if="$slots.footer" class="foot">
      <slot name="footer" />
    </footer>
  </section>
</template>

<style scoped>
.op-panel-root {
  display: flex;
  flex-direction: column;
  min-width: 0;
  color: var(--op77-text);
}

.head {
  display: flex;
  align-items: baseline;
  gap: var(--op77-space-3);
  /* The leading edge pays for the rule, the trailing edge pays for the cut. */
  padding: var(--op77-space-3) calc(var(--op77-space-4) + var(--op77-cut-md))
    var(--op77-space-3) calc(var(--op77-space-4) + var(--op77-rule));
  border-bottom: 1px solid var(--op77-line);
}

.body {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  min-height: 0;
  padding: var(--op77-space-3) var(--op77-space-3) var(--op77-space-3)
    calc(var(--op77-space-3) + var(--op77-rule));
  overflow: hidden auto;
  /* A CEF scrollbar is a Chromium scrollbar drawn over gameplay. */
  scrollbar-width: none;
}

.foot {
  display: flex;
  gap: var(--op77-space-2);
  padding: var(--op77-space-2) calc(var(--op77-space-3) + var(--op77-cut-md))
    calc(var(--op77-space-2) + var(--op77-cut-md)) var(--op77-space-3);
  border-top: 1px solid var(--op77-line);
}
</style>
