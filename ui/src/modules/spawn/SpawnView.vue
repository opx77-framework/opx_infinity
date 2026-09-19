<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import OpPanel from '@/design/components/OpPanel.vue'
import OpRow from '@/design/components/OpRow.vue'
import OpScrim from '@/design/components/OpScrim.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useCountdown } from '@/composables/useCountdown'

/**
 * THE SPAWN MENU -- where a brand new character starts.
 *
 * Asked on every join. Lua opens it with the places to draw and a duration, and the page
 * answers with the ID of one of them; the place itself is the server's to look up, so
 * nothing here can move anybody anywhere the server has not already agreed to. Picking
 * nothing is a real answer -- the server places the body where the character's own row
 * already says -- which is why nothing here insists on one.
 *
 * ONE PRESS IS THE CHOICE. Clicking a card sends it -- you do not select and then
 * confirm, because "spawn me at the coast" is one intent and asking for it twice is
 * a menu pretending the first click did not count. The arrow keys plus Enter take the
 * same route for a keyboard, and the confirm row under the grid is the same call
 * again, so the three input paths cannot drift apart.
 *
 * THE MENU DOES NOT CLOSE ON THAT PRESS. It closes when Lua says so -- `spawn:close`,
 * carrying what actually happened -- for the same reason a panel does not select its
 * own item: a page that closed itself would show the player a spawn the server
 * refused, and there is no second chance at this one. The one thing this page decides
 * for itself is which card is highlighted, and that is a receipt for a press already
 * sent rather than a fact about the world.
 *
 * THE COUNTDOWN IS DISPLAY ONLY. It counts down to `Date.now() + timeoutMs` -- the
 * duration the server gave, turned into a local deadline -- and when it reaches zero it
 * does nothing at all. The server is counting the same duration against its own clock,
 * and only that count ends the choice. A page that acted on its own zero would act early
 * on a fast clock and late on a surface the CEF has throttled.
 */

interface Place {
  id: string
  label: string
  district: string
}

const open = ref(false)
const title = ref('')
const about = ref('')
const hint = ref('')
const confirmLabel = ref('')
const places = ref<Place[]>([])
/** Empty until a card is chosen: confirming is deliberate, never a default. */
const chosen = ref('')
const hasTimer = ref(false)
const deadline = ref(0)

const { clock } = useCountdown(deadline)

let release: (() => void) | undefined

function blank(): void {
  open.value = false
  places.value = []
  chosen.value = ''
  title.value = ''
  about.value = ''
  hint.value = ''
  confirmLabel.value = ''
  hasTimer.value = false
  deadline.value = 0
}

/** Moves the highlight, wrapping. From nothing, it starts at the end it came from. */
function move(delta: number): void {
  const total = places.value.length
  if (total === 0) return
  const at = places.value.findIndex((place) => place.id === chosen.value)
  if (at === -1) {
    chosen.value = delta > 0 ? places.value[0].id : places.value[total - 1].id
    return
  }
  chosen.value = places.value[(at + delta + total) % total].id
}

function confirm(): void {
  // An INTENT. Lua re-derives which place this is and where it is, and this page
  // stays open until the answer comes back on `spawn:close`.
  if (!open.value || chosen.value === '') return
  emit('opx:spawn:choose', { id: chosen.value })
}

/**
 * Clicking a card IS the choice. One click places you; the highlight is the
 * receipt, not a step. The card is picked first so the highlight lands on the
 * row that was pressed even if the answer takes a moment, and the send is the
 * same `confirm` everything else uses -- there is one path to the wire.
 *
 * A second press is not a second choice: the server rate-limits the id it is
 * sent, and the menu is unmounted by the answer either way.
 */
function pick(id: string): void {
  chosen.value = id
  confirm()
}

function onKeyDown(event: KeyboardEvent): void {
  if (!open.value) return
  // A row that has DOM focus handles Enter and Space itself and has already
  // prevented the default by the time this sees the event -- so this is what stops
  // one Enter from confirming twice.
  if (event.defaultPrevented) return

  if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
    event.preventDefault()
    move(1)
    return
  }
  if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
    event.preventDefault()
    move(-1)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    confirm()
  }
}

useBridge('opx:spawn:open', (payload: Payload) => {
  guard(
    'spawn:open',
    () => {
      const rows: Place[] = []
      for (const entry of list<Payload>(payload.locations)) {
        const id = text(entry.id)
        if (!id) continue
        rows.push({ id, label: text(entry.label, id), district: text(entry.district) })
      }
      // No places to draw is not a menu: the server only offers a choice it can
      // serve, so this is a configuration that changed under a live session.
      if (rows.length === 0) return

      places.value = rows
      title.value = text(payload.title)
      about.value = text(payload.about)
      hint.value = text(payload.hint)
      confirmLabel.value = text(payload.confirm)

      const ms = num(payload.timeoutMs)
      hasTimer.value = ms > 0
      deadline.value = ms > 0 ? Date.now() + ms : 0

      chosen.value = ''
      open.value = true

      release?.()
      release = acquireFocus({
        id: 'spawn',
        // THE CHOICE IS MANDATORY, so Escape does nothing on purpose. Supplying a
        // handler at all is the point: without one, bridge/focus.ts releases the
        // owner on Escape and the menu is left on screen with no pointer and no
        // keyboard -- visible, unanswerable, and only the server can end it.
        onEscape: () => {}
      })
    },
    undefined
  )
})

useBridge('opx:spawn:close', (payload: Payload) => {
  guard(
    'spawn:close',
    () => {
      // The reason is Lua's and it has already said it: a toast, in the player's
      // language. This page only takes the menu down.
      void payload
      blank()
      release?.()
      release = undefined
    },
    undefined
  )
})

onMounted(() => {
  window.addEventListener('keydown', onKeyDown)
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeyDown)
  release?.()
})
</script>

<template>
  <div class="room" :class="{ open }">
    <OpScrim mode="flat" :visible="open" />

    <div class="stage">
      <OpPanel bay>
        <template #header>
          <div class="head-text">
            <span class="op77-eyebrow">OPEN//77</span>
            <h1>{{ title }}</h1>
          </div>
          <span v-if="hasTimer" class="timer">{{ clock }}</span>
        </template>

        <p v-if="about" class="intro">{{ about }}</p>

        <div class="grid">
          <OpRow
            v-for="place in places"
            :key="place.id"
            :label="place.label"
            :hint="place.district"
            :selected="place.id === chosen"
            @select="pick(place.id)"
          />
        </div>

        <p v-if="hint" class="hint">{{ hint }}</p>

        <template #footer>
          <OpRow
            class="button grow"
            :label="confirmLabel"
            :disabled="chosen === ''"
            selected
            @select="confirm"
          />
        </template>
      </OpPanel>
    </div>
  </div>
</template>

<style scoped>
.room {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op77-dur) var(--op77-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

.stage {
  position: relative;
  display: flex;
  width: min(880px, calc(100vw - var(--op77-space-4) * 2));
  max-height: calc(100vh - var(--op77-space-4) * 2);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-1);
  margin-right: auto;
  min-width: 0;
}

.head-text h1 {
  margin: 0;
  font: 700 var(--op77-fs-title) / 1.1 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
}

/* The auto-spawn countdown. Tabular so the digits do not shuffle the header as
   they tick, and muted: it is a deadline, not a warning. */
.timer {
  flex: none;
  font: 700 var(--op77-fs-title) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-dim);
  font-variant-numeric: tabular-nums;
}

.intro {
  margin: 0 0 var(--op77-space-2);
  font: 400 var(--op77-fs-body) / 1.35 var(--op77-font-body);
  color: var(--op77-text-dim);
}

/* Two abreast where there is room, one where there is not: eleven cards is two
   columns of six on a 1080p surface, which is the whole grid at a glance. */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: var(--op77-space-1);
  align-content: start;
  min-height: 0;
  overflow: hidden auto;
  scrollbar-width: none;
}

.hint {
  margin: var(--op77-space-2) 0 0;
  font: 400 var(--op77-fs-meta) / 1.4 var(--op77-font-mono);
  letter-spacing: var(--op77-track-label);
  color: var(--op77-text-faint);
}

.button {
  justify-content: center;
  cursor: pointer;
}

.grow {
  flex: 1;
}
</style>
