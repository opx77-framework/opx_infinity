<script setup lang="ts">
import { computed } from 'vue'
import OpField from '@/design/components/OpField.vue'
import OpRow from '@/design/components/OpRow.vue'
import type { Draft, FormFrame, Row } from './types'

/**
 * The creation form, one step at a time.
 *
 * It was one modal of five fields; it is five steps now, and the reason is the
 * sentence the old form carried under its title: "None of this can be changed
 * later." A player asked for five irreversible answers at once reads none of them.
 * A step asks one thing, says what it is for, and ends on a review that reads all
 * five back before anything is written.
 *
 * It renders what it is TOLD and reports what the player DID. Every rule --
 * the name pattern, the two bounds, the calendar, the two closed lists -- is
 * checked in Lua, which repeats the server's own checks, and the message under a
 * refused row arrives here as a finished sentence in the player's language.
 */
const props = defineProps<{
  form: FormFrame
  /** Which navigable row the keyboard is on. Owned by the view above. */
  rowAt: number
  /** The candidate answers, as typed and picked so far. */
  values: Draft
}>()

const emit = defineEmits<{
  (event: 'edit', id: string, value: string): void
  (event: 'pick', id: string): void
  (event: 'row', at: number): void
}>()

/** The rows the keyboard walks. The review step has none: it only reads back. */
const navigable = computed(() => props.form.rows.filter((row) => row.kind !== 'fact'))

/** Lua counts characters and JS counts UTF-16 units: a surrogate pair is one
    character on both sides once its low half is dropped. The counter under a
    field has to agree with the bound Lua and the server are enforcing. */
function characters(value: string): number {
  return value.replace(/[\uDC00-\uDFFF]/g, '').length
}

function counter(row: Row): string {
  if (row.max <= 0) return ''
  return `${characters(props.values[row.id] ?? '')}/${Math.round(row.max)}`
}

function indexOf(row: Row): number {
  return navigable.value.indexOf(row)
}

function isOn(row: Row): boolean {
  return indexOf(row) === props.rowAt
}

/** A choice row carries the value of the field its step owns. */
function isChosen(row: Row): boolean {
  if (props.form.field === '') return false
  return props.values[props.form.field] === row.id
}
</script>

<template>
  <div class="form">
    <ol class="rail" :style="{ '--columns': form.steps.length }">
      <li
        v-for="(mark, at) in form.steps"
        :key="mark.id"
        class="pip"
        :class="{ on: mark.id === form.step, done: at + 1 < form.index }"
      >
        <span class="pip-n">{{ at + 1 }}</span>
        <span class="pip-label">{{ mark.label }}</span>
      </li>
    </ol>

    <p class="count">{{ form.count }}</p>
    <p class="about">{{ form.about }}</p>

    <div class="rows" :class="{ busy: form.busy }">
      <template v-for="row in form.rows" :key="row.id">
        <OpField
          v-if="row.kind === 'text'"
          :data-row="row.id"
          :label="row.label"
          kind="text"
          :model-value="values[row.id] ?? ''"
          :placeholder="row.placeholder"
          :count="counter(row)"
          :selected="isOn(row)"
          :disabled="form.busy"
          @input="emit('edit', row.id, $event)"
          @focus="emit('row', indexOf(row))"
        />
        <OpRow
          v-else-if="row.kind === 'choice'"
          :label="row.label"
          :hint="row.note"
          :value="isChosen(row) ? '◆' : ''"
          :selected="isOn(row)"
          :disabled="form.busy"
          @select="emit('pick', row.id)"
        />
        <OpRow v-else :label="row.label" :value="row.value" />
      </template>
    </div>

    <p v-if="form.error" class="error">{{ form.error }}</p>
    <p v-else-if="form.last" class="warning">{{ form.warning }}</p>
  </div>
</template>

<style scoped>
.form {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  min-height: 0;
}

/* Not augmented and never will be: five cut boxes in a row read as five plates,
   which is the opposite of what a progress rail says. */
.rail {
  display: grid;
  grid-template-columns: repeat(var(--columns, 5), 1fr);
  gap: var(--op77-space-1);
  margin: 0 0 var(--op77-space-2);
  padding: 0;
  list-style: none;
}

.pip {
  display: flex;
  align-items: center;
  gap: var(--op77-space-2);
  padding: var(--op77-space-2) var(--op77-space-2) var(--op77-space-2) 0;
  border-top: 2px solid var(--op77-line);
  color: var(--op77-text-faint);
}

.pip.done {
  border-top-color: var(--op77-accent-line);
  color: var(--op77-text-dim);
}

.pip.on {
  border-top-color: var(--op77-accent);
  color: var(--op77-text);
}

.pip-n {
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
}

.pip-label {
  font: 600 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.count {
  margin: 0;
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--op77-accent);
}

.about {
  margin: 0 0 var(--op77-space-2);
  font: 400 var(--op77-fs-body) / 1.4 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.rows {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  min-height: 0;
  transition: opacity var(--op77-dur-fast) var(--op77-ease);
}

.rows.busy {
  opacity: 0.55;
}

.error {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  color: var(--op77-danger);
}

.warning {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  color: var(--op77-warn);
}
</style>
