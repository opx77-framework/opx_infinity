<script setup lang="ts">
import { computed } from 'vue'

/**
 * Derived from `opx77_input/web/input.css` and `input.js` -- one DOM shape serving
 * text, choice and slider, with the kind as a root class and the irrelevant children
 * hidden. That was the right call and is kept: three components would have been three
 * rows that drifted apart.
 *
 * No `v-model`. The field emits what the player DID and renders what it is TOLD;
 * `modelValue` comes from Lua's last answer. A field that wrote its own value would be
 * showing a number the server has not agreed to, which is the whole reason the input
 * resource round-trips every keystroke's commit.
 */
const props = withDefaults(
  defineProps<{
    label: string
    kind?: 'text' | 'choice' | 'slider'
    /** Text: the buffer. Choice: the selected option's label. Slider: the number. */
    modelValue?: string | number
    placeholder?: string
    /** Slider only, and only for drawing the track. */
    min?: number
    max?: number
    /** Text only. input.js renders it as `12/24` under the focused field. */
    count?: string
    selected?: boolean
    disabled?: boolean
  }>(),
  {
    kind: 'text',
    modelValue: '',
    placeholder: '',
    min: 0,
    max: 100,
    count: '',
    selected: false,
    disabled: false
  }
)

const emit = defineEmits<{
  (event: 'input', value: string): void
  (event: 'step', direction: -1 | 1): void
  (event: 'focus'): void
}>()

const asText = computed(() => String(props.modelValue ?? ''))

/** input.js sizes the plate to its content so the frame never outruns the text. */
const chars = computed(() => Math.max(asText.value.length, props.placeholder.length) + 1)

const fill = computed(() => {
  const span = props.max - props.min
  if (span <= 0) return '0%'
  const ratio = (Number(props.modelValue) - props.min) / span
  return `${Math.max(0, Math.min(1, ratio)) * 100}%`
})
</script>

<template>
  <div
    class="field op-plate"
    :class="[`kind-${kind}`, { 'op-is-active': selected && !disabled, 'op-is-muted': disabled }]"
    data-augmented-ui="tr-clip border"
    @click="!disabled && emit('focus')"
  >
    <span class="label">{{ label }}</span>
    <span class="cell">
      <input
        v-if="kind === 'text'"
        class="entry"
        type="text"
        spellcheck="false"
        autocomplete="off"
        :value="asText"
        :placeholder="placeholder"
        :disabled="disabled"
        :style="{ '--chars': chars }"
        @input="emit('input', ($event.target as HTMLInputElement).value)"
      >
      <span v-if="kind === 'slider'" class="bar"><i class="fill" :style="{ width: fill }" /></span>
      <span v-if="kind !== 'text'" class="value">{{ asText }}</span>
      <span v-if="kind === 'text' && count && selected" class="count">{{ count }}</span>
      <span v-if="kind === 'choice'" class="marks">
        <button class="mark" type="button" :disabled="disabled" @click.stop="emit('step', -1)">&lsaquo;</button>
        <button class="mark" type="button" :disabled="disabled" @click.stop="emit('step', 1)">&rsaquo;</button>
      </span>
    </span>
  </div>
</template>

<style scoped>
.field {
  display: flex;
  align-items: center;
  gap: var(--op77-space-3);
  padding: var(--op77-space-1) var(--op77-space-3);
  color: var(--op77-text-dim);
  white-space: nowrap;
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

/* Zero flex-basis so a long typed line scrolls the cell instead of truncating the label. */
.cell {
  flex: 1 1 0;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: var(--op77-space-3);
  min-width: 0;
}

.entry {
  flex: 0 1 auto;
  width: calc(var(--chars, 1) * (1ch + var(--op77-track-label)) + 2px);
  max-width: 100%;
  padding: 0 0 2px;
  background: none;
  border: 0;
  border-bottom: 1px solid transparent;
  border-radius: 0;
  outline: none;
  font: 400 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-faint);
  /* The only place on any surface where a caret and a text selection belong. */
  user-select: text;
  /* The plate under the pointer asks for `pointer` and `cursor` inherits; a line
     being typed into is the one child that must not. */
  cursor: text;
}

.entry::placeholder {
  color: var(--op77-text-faint);
  font-style: italic;
  opacity: 1;
}

.value {
  flex: 0 1 auto;
  font: 400 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-faint);
  font-variant-numeric: tabular-nums;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Track ahead of the number, per input.css. */
.bar {
  order: -1;
  flex: none;
  width: 48px;
  height: 2px;
  background: var(--op77-line-strong);
}

.fill {
  display: block;
  height: 100%;
  background: var(--op77-text-faint);
  transition: width var(--op77-dur-fast) var(--op77-ease);
}

.count {
  font: 400 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  color: var(--op77-text-faint);
}

.marks {
  display: flex;
  gap: 2px;
}

.mark {
  padding: 0 2px;
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  color: inherit;
  background: none;
  border: 0;
  cursor: default;
}

.op-is-active { color: var(--op77-ink); }
.op-is-active .entry { color: var(--op77-ink); border-bottom-color: rgba(10, 10, 5, 0.45); }
.op-is-active .entry::placeholder { color: rgba(10, 10, 5, 0.5); }
.op-is-active .bar { background: rgba(10, 10, 5, 0.25); }
.op-is-active .fill { background: var(--op77-ink); }
.op-is-active .value,
.op-is-active .count { color: var(--op77-ink); opacity: 0.72; }
</style>
