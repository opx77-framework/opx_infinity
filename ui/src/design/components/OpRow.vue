<script setup lang="ts">
/**
 * The shared row. Derived from `opx77_menu/web/menu.css` `.row` -- which
 * `opx77_input` (`.row.kind-*`), `opx77_prompts` (`.row`), `opx77_target`
 * (`.option`) and `opx77_panel` (`.item`) had each re-drawn with the same spine:
 * label, optional value, optional checkbox, optional hint.
 *
 * Four files, four cut sizes (20px / 20px / 14px / 5px), four spellings of the
 * disabled state (`.off`, `.dim`, `:disabled`, `.item:disabled`). One row now.
 *
 * `.rule` is menu's separator variant: a label and nothing else, no frame.
 */
withDefaults(
  defineProps<{
    label: string
    value?: string
    /** The description line menu showed under the strip for the selected row. */
    hint?: string
    /** `undefined` means this row has no checkbox at all, not an unchecked one. */
    checked?: boolean
    selected?: boolean
    disabled?: boolean
    /** A section separator. Renders the label as a mono eyebrow, no plate. */
    rule?: boolean
  }>(),
  { value: '', hint: '', checked: undefined, selected: false, disabled: false, rule: false }
)

const emit = defineEmits<{
  (event: 'select'): void
  (event: 'toggle'): void
  /** The pointer is over this row. Whoever owns the highlight decides what that
      means -- the row does not move it, for the same reason it does not tick its
      own checkbox. A list driven only by the arrow keys ignores it. */
  (event: 'point'): void
}>()

function activate(): void {
  // An INTENT. The row does not flip its own checkbox and does not assume the select
  // took: Lua decides and sends the new state back. A row that ticked itself would
  // show a tick for a purchase the server refused.
  emit('select')
  emit('toggle')
}
</script>

<template>
  <div
    v-if="rule"
    class="row rule"
  >
    <span class="op77-eyebrow">{{ label }}</span>
  </div>
  <div
    v-else
    class="row op-plate"
    :class="{ 'op-is-active': selected && !disabled, 'op-is-muted': disabled }"
    data-augmented-ui="tr-clip border"
    role="button"
    :tabindex="disabled ? -1 : 0"
    :aria-disabled="disabled"
    @click="!disabled && activate()"
    @mouseenter="!disabled && emit('point')"
    @keydown.enter.prevent="!disabled && activate()"
    @keydown.space.prevent="!disabled && activate()"
  >
    <span class="label">{{ label }}</span>
    <span v-if="value || $slots.value" class="value"><slot name="value">{{ value }}</slot></span>
    <span
      v-if="checked !== undefined"
      class="check"
      :class="{ ticked: checked }"
      role="checkbox"
      :aria-checked="checked"
    >
      <!-- The tick draws in after the fill lands and wipes instantly: a stroke-dashoffset
           transition with a delay, straight out of menu.css. -->
      <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6.3 5 8.8 9.6 3.4" /></svg>
    </span>
    <span v-if="hint" class="hint">{{ hint }}</span>
  </div>
</template>

<style scoped>
.row {
  display: flex;
  align-items: center;
  gap: var(--op77-space-3);
  flex-wrap: wrap;
  padding: var(--op77-space-1) var(--op77-space-3);
  color: var(--op77-text-dim);
  white-space: nowrap;
  cursor: default;
}

.label {
  flex: 0 1 auto;
  min-width: 0;
  font: 600 var(--op77-fs-lead) / 1.25 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  overflow: hidden;
  text-overflow: ellipsis;
}

.value {
  flex: none;
  margin-left: auto;
  max-width: 45%;
  font: 400 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-faint);
  font-variant-numeric: tabular-nums;
  overflow: hidden;
  text-overflow: ellipsis;
}

.hint {
  /* The one place the row wraps. It is a sentence, not a label. */
  flex: 1 0 100%;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-body);
  color: var(--op77-text-dim);
  white-space: normal;
}

.check {
  flex: none;
  width: 13px;
  height: 13px;
  border: 1px solid var(--op77-accent-line);
  background: transparent;
  transition:
    background var(--op77-dur-fast) var(--op77-ease),
    border-color var(--op77-dur-fast) var(--op77-ease);
}

.value:empty + .check {
  margin-left: auto;
}

.check svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: var(--op77-ink);
  stroke-width: 2;
  stroke-linecap: square;
  stroke-dasharray: 12;
  stroke-dashoffset: 12;
  transition: stroke-dashoffset var(--op77-dur) var(--op77-ease) var(--op77-dur-fast);
}

.check.ticked {
  background: var(--op77-accent);
  border-color: var(--op77-accent);
}

.check.ticked svg {
  stroke-dashoffset: 0;
}

/* On the selected plate the accent IS the background, so the mark inverts. */
.op-is-active .value,
.op-is-active .hint {
  color: var(--op77-ink);
  opacity: 0.72;
}

.op-is-active .label {
  font-weight: 700;
}

.op-is-active .check {
  border-color: var(--op77-ink);
}

.op-is-active .check.ticked {
  background: var(--op77-ink);
}

.op-is-active .check.ticked svg {
  stroke: var(--op77-accent);
}

.op-is-muted .check {
  border-color: var(--op77-line-strong);
}

.rule {
  margin-top: var(--op77-space-2);
  padding: 3px var(--op77-space-3);
}

.rule:first-child {
  margin-top: 0;
}
</style>
