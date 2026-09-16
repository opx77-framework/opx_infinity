<script setup lang="ts">
import { onMounted, ref, shallowRef } from 'vue'
import OpKeyCap from '@/design/components/OpKeyCap.vue'
import OpPanel from '@/design/components/OpPanel.vue'
import { emit } from '@/bridge/channel'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE KEY STRIP -- the port of `opx77_prompts/web/{index.html,prompts.js,prompts.css}`.
 *
 * It decides nothing, exactly as prompts.js decided nothing. Order, the cut to the row
 * budget and every key NAME arrive resolved: a cap says what the player's own binding
 * says, and this page has no keyboard layout to map a scancode with.
 *
 * WHAT CHANGED, and it is the one substantial rebuild here: prompts.css drew a
 * content-width plate per row and per group title, each one a `z-index: -1`
 * pseudo-element under an `isolation: isolate` parent. That is twenty-four clipped
 * pseudo-elements for a full strip. Rule 1 of design/augmented.css says augment
 * containers and not cells, so a GROUP is now one `OpPanel` -- one augmented frame -- and
 * its rows are plain boxes inside it. Worst case goes from 24 clipped plates to 8.
 */
const { t } = useLocale()

type Anchor = 'bottom-right' | 'bottom-left' | 'top-right' | 'top-left'

/** Closed set: an unrecognised anchor falls back rather than reaching a class name. */
const ANCHORS: readonly string[] = ['bottom-right', 'bottom-left', 'top-right', 'top-left']

/** The page's own ceilings, repeating Lua's rather than trusting the sender for them. */
const MAX_GROUPS = 32
const MAX_ROWS = 24
const MAX_CAPS = 6

interface Cap {
  /** Stable within a row, so a rebind swaps the label without remounting the cap. */
  key: string
  label: string
  /** The `+` that says these two are pressed together. Never on the first cap. */
  join: boolean
}

interface Row {
  key: string
  caps: Cap[]
  label: string
  value: string
  hold: boolean
  dim: boolean
}

interface Group {
  key: string
  title: string
  rows: Row[]
}

const groups = shallowRef<Group[]>([])
const anchor = ref<Anchor>('bottom-right')
const offset = ref(0)
const maxWidth = ref(420)
/** Lua owns the player's language, so even the word HOLD arrives from it. */
const holdText = ref('HOLD')
/** prompts.js `hide()`: hidden, never emptied -- the next frame usually says the same. */
const hidden = ref(false)

function capsOf(row: Payload): Cap[] {
  const combo = row.combo === true
  return list(row.caps)
    .slice(0, MAX_CAPS)
    .map((cap, index) => ({
      key: `${index}:${text(cap)}`,
      label: text(cap),
      join: combo && index > 0
    }))
}

useBridge('opx:prompts:config', (payload: Payload) => {
  const wanted = text(payload.anchor)
  if (ANCHORS.indexOf(wanted) !== -1) anchor.value = wanted as Anchor

  const clear = num(payload.offset, -1)
  if (clear >= 0) offset.value = Math.round(clear)

  const width = num(payload.maxWidth)
  if (width > 0) maxWidth.value = Math.round(width)

  const hold = text(payload.hold)
  if (hold) holdText.value = t(hold)
})

useBridge('opx:prompts:frame', (payload: Payload) => {
  const seenGroups: Record<string, boolean> = {}
  const next: Group[] = []
  // One budget across the whole frame, not per group: the strip is bounded by the screen
  // it sits on, and eight groups of eight rows is a wall, not a hint.
  let rowBudget = MAX_ROWS

  for (const raw of list<Payload>(payload.groups)) {
    if (next.length >= MAX_GROUPS || rowBudget <= 0) break
    const key = text(raw.key)
    if (!key || seenGroups[key]) continue

    const seenRows: Record<string, boolean> = {}
    const rows: Row[] = []
    for (const rawRow of list<Payload>(raw.rows)) {
      if (rowBudget <= 0) break
      const rowKey = text(rawRow.key)
      if (!rowKey || seenRows[rowKey]) continue
      const caps = capsOf(rawRow)
      // A prompt with no key to name says nothing. Lua drops these too; the page repeats
      // the rule because the bus it listens on is shared with every other resource.
      if (caps.length === 0) continue
      seenRows[rowKey] = true
      rows.push({
        key: rowKey,
        caps,
        label: t(text(rawRow.label)),
        value: text(rawRow.value),
        hold: rawRow.hold === true,
        dim: rawRow.dim === true
      })
      rowBudget -= 1
    }
    // An empty group is a frame, a title and no information.
    if (rows.length === 0) continue

    seenGroups[key] = true
    next.push({ key, title: t(text(raw.title)), rows })
  }

  groups.value = next
  hidden.value = false
})

useBridge('opx:prompts:hide', () => {
  hidden.value = true
})

onMounted(() => {
  emit('opx:prompts:ready', {})
})
</script>

<template>
  <div class="prompts">
    <div
      class="strip"
      :class="[anchor, { open: groups.length > 0 && !hidden }]"
      :style="{ '--strip-offset': offset + 'px', '--strip-width': maxWidth + 'px' }"
    >
      <OpPanel
        v-for="group in groups"
        :key="group.key"
        class="group"
        :anchor="anchor.indexOf('-right') === -1 ? 'start' : 'end'"
        :lift="false"
      >
        <template v-if="group.title" #header>
          <span class="op77-eyebrow">{{ group.title }}</span>
        </template>

        <!-- Plain rows inside one augmented frame. The caps are augmented by OpKeyCap
             itself and are the only cells here that are, which is the bound MAX_CAPS and
             MAX_ROWS exist to keep finite. Nothing animates an --aug-* value, so each cut
             is computed once and never again. -->
        <div v-for="row in group.rows" :key="row.key" class="row" :class="{ dim: row.dim }">
          <span class="caps">
            <span v-for="cap in row.caps" :key="cap.key" class="cap">
              <span v-if="cap.join" class="join">+</span>
              <OpKeyCap :label="cap.label" :hold="row.hold" :muted="row.dim" />
            </span>
          </span>
          <span v-if="row.hold" class="tag">{{ holdText }}</span>
          <span class="label">{{ row.label }}</span>
          <span v-if="row.value" class="reading">{{ row.value }}</span>
        </div>
      </OpPanel>
    </div>
  </div>
</template>

<style scoped>
.prompts {
  position: absolute;
  inset: 0;
}

.strip {
  position: fixed;
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  width: var(--strip-width, 420px);
  max-width: calc(100vw - var(--op77-inset-x) * 2);
  max-height: calc(100vh - var(--op77-inset-y) * 2 - var(--strip-offset, 0px));
  overflow: hidden;
  /* Opacity and transform, never `display`: a node taken out of layout replays its
     entrance when it comes back, and the strip is hidden and shown constantly -- every
     time the chat composer takes the keyboard. */
  opacity: 0;
  transform: translateY(var(--slide, 8px));
  transition:
    opacity var(--op77-dur) var(--op77-ease),
    transform var(--op77-dur) var(--op77-ease);
}

.strip.open {
  opacity: 1;
  transform: none;
}

.bottom-right,
.top-right {
  right: var(--op77-inset-x);
  align-items: flex-end;
}

.bottom-left,
.top-left {
  left: var(--op77-inset-x);
  align-items: flex-start;
}

/* Bottom anchors grow upward: the first group, the highest priority, sits nearest the
   edge. The frame arrives in priority order and the column is reversed here, so nothing
   in script has to know which way the strip grows. */
.bottom-right,
.bottom-left {
  bottom: calc(var(--op77-inset-y) + var(--strip-offset, 0px));
  flex-direction: column-reverse;
  --slide: 8px;
}

.top-right,
.top-left {
  top: calc(var(--op77-inset-y) + var(--strip-offset, 0px));
  --slide: -8px;
}

/* A group is only as wide as it needs to be: the strip's width is a ceiling, not a size.
   A full-width panel for one "E  OPEN" row reads as a menu the player should be driving. */
.group {
  max-width: 100%;
}

.row {
  display: flex;
  align-items: center;
  gap: var(--op77-space-3);
  padding: 3px 0;
  white-space: nowrap;
}

.caps {
  flex: none;
  display: flex;
  align-items: center;
  gap: 3px;
}

.cap {
  display: inline-flex;
  align-items: center;
  gap: 3px;
}

/* Between two caps pressed together. Alternatives and sequences have no joiner. */
.join {
  font: 700 var(--op77-fs-meta) / 1 var(--op77-font-mono);
  color: var(--op77-text-faint);
}

.tag {
  flex: none;
  font: 700 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
  color: var(--op77-text-dim);
}

.label {
  flex: 0 1 auto;
  min-width: 0;
  font: 600 var(--op77-fs-lead) / 1.2 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  color: var(--op77-text);
  overflow: hidden;
  text-overflow: ellipsis;
}

/* A live reading beside the label, set apart by a hairline. */
.reading {
  flex: none;
  margin-left: auto;
  padding-left: var(--op77-space-3);
  border-left: 1px solid var(--op77-line-hud);
  font: 700 var(--op77-fs-meta) / 1.2 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  /* Not upper-cased: a unit is data, and "M/S" is not metres per second. */
  color: var(--op77-text);
  font-variant-numeric: tabular-nums;
}

/* Unavailable for now. The ink carries the state and the frame stays whole -- a row that
   dropped its plate would read as a row that left. */
.dim .label,
.dim .reading {
  color: var(--op77-text-faint);
}

.dim .reading {
  border-left-color: var(--op77-line);
}
</style>
