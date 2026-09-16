<script setup lang="ts">
import { computed } from 'vue'
import type { Card } from './types'

/**
 * One card in the roster. A PLAIN box, deliberately.
 *
 * Rule 1 of design/augmented.css: augment containers, never cells. The roster's
 * one augmented element is the panel around it, and a card's selected state is an
 * inset accent rule (`.op-rail`) plus a fill -- both colours, both cheap, neither
 * of them a shape. An augmented card would cost two pseudo-elements each, re-clipped
 * on every resize, for a list whose length is the account's slot count and is not
 * bounded by anything this page controls.
 *
 * THERE IS NO PORTRAIT TO DRAW. A roster summary carries no face, and the one face
 * that exists is the puppet the stage camera is pointed at, standing to the right of
 * this panel. The plate is the character's initials, which is an identity mark rather
 * than a picture pretending to be one.
 */
const props = defineProps<{
  card: Card
  selected: boolean
}>()

const emit = defineEmits<{
  (event: 'choose'): void
  (event: 'point'): void
}>()

/** Lifepath, body, role and affiliation on one line: the identifying facts that
    are not the name. Empty parts are dropped rather than drawn as separators. */
const meta = computed(() =>
  [props.card.lifepath, props.card.body, props.card.role, props.card.affiliation]
    .filter((part) => part !== '')
    .join(' · ')
)

const mark = computed(() => {
  if (props.card.kind === 'character') return props.card.monogram
  return '+'
})

/** An INTENT. The card does not select itself and does not know whether the
    choice took: Lua reads the card this id names and answers with a frame. */
function choose(): void {
  if (props.card.disabled) return
  emit('choose')
}
</script>

<template>
  <article
    class="card"
    :class="[card.kind, { on: selected && !card.disabled, off: card.disabled }]"
    role="button"
    :tabindex="card.disabled ? -1 : 0"
    :aria-disabled="card.disabled"
    @click="choose"
    @mouseenter="emit('point')"
  >
    <span class="plate" aria-hidden="true">{{ mark }}</span>
    <div class="ident">
      <h2 class="name">{{ card.name }}</h2>
      <span v-if="card.identifier" class="id">{{ card.identifier }}</span>
      <p v-if="meta" class="meta">{{ meta }}</p>
      <p v-if="card.note" class="note">{{ card.note }}</p>
      <p v-if="card.lastSeen" class="seen">{{ card.lastSeen }}</p>
    </div>
  </article>
</template>

<style scoped>
.card {
  display: flex;
  align-items: flex-start;
  gap: var(--op77-space-3);
  min-width: 0;
  padding: var(--op77-space-3);
  background: var(--op77-panel-quiet);
  border: 1px solid var(--op77-line);
  cursor: default;
  transition:
    background var(--op77-dur-fast) var(--op77-ease),
    border-color var(--op77-dur-fast) var(--op77-ease),
    box-shadow var(--op77-dur-fast) var(--op77-ease);
}

.card:hover:not(.off) {
  border-color: var(--op77-line-strong);
}

/* The house marker, as an INSET shadow: an outset one would be cut off by the
   panel's own clip, and a border cannot carry a single coloured edge. */
.card.on {
  background: var(--op77-panel-raised);
  border-color: var(--op77-line-hud);
  box-shadow: inset var(--op77-rule) 0 0 0 var(--op77-accent);
}

.card.off {
  opacity: 0.45;
}

.plate {
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 52px;
  height: 52px;
  font: 700 var(--op77-fs-title) / 1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  color: var(--op77-text-dim);
  background: var(--op77-bg-elev);
  border: 1px solid var(--op77-line-strong);
}

.card.on .plate {
  color: var(--op77-ink);
  background: var(--op77-accent);
  border-color: var(--op77-accent);
}

.empty .plate,
.create .plate {
  border-style: dashed;
  font-size: var(--op77-fs-head);
  font-weight: 400;
}

.ident {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.name {
  margin: 0;
  font: 600 var(--op77-fs-lead) / 1.15 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  color: var(--op77-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.card.on .name {
  font-weight: 700;
}

.id {
  font: 700 var(--op77-fs-label) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-accent);
}

.card.off .id,
.empty .id {
  color: var(--op77-text-faint);
}

.meta {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.35 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  text-transform: uppercase;
  color: var(--op77-text-dim);
  overflow: hidden;
  text-overflow: ellipsis;
}

.note {
  margin: 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-body);
  color: var(--op77-text-dim);
}

.seen {
  margin: 0;
  font: 400 var(--op77-fs-micro) / 1.4 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--op77-text-faint);
}
</style>
