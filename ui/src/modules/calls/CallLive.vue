<script setup lang="ts">
import { computed, onUnmounted, ref, shallowRef } from 'vue'
import { guard } from '@/bridge/diag'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE LIVE CALL CHIP -- a call is running, with whom, and for how long.
 *
 * THE OWNER ASKED FOR IT IN ONE SENTENCE: "quand on est en appel et que le menu
 * est fermer il y a une petite ui sur la gauche qui montre que l'appel est en
 * cours". That is the whole specification and it is worth taking literally --
 * SMALL, LEFT, and it says the call is running. It is not a call screen, it has
 * no controls, and it is up for as long as the call is, which on a busy server
 * is minutes: a chip that big enough to read at a glance and small enough to
 * forget is the only version of this that can be on screen that long.
 *
 * NO CONTROLS, AND THE LAYER IS WHY. This is on `overlay`, which is
 * `pointer-events: none` for its whole height and is never focused. Hanging up
 * is a row on the target eye -- ALT on yourself -- exactly as answering is. The
 * chip says what is true; the eye is where things are done.
 *
 * IT DOES NOT HIDE ITSELF WHEN THE MENU OPENS. Lua decides that, because Lua is
 * the half that knows whether a menu is open: the state push stops and the chip
 * goes with it. A page that watched for a menu would be the page holding an
 * opinion about another module's surface.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * LEFT-ANCHORED, SO IT TILTS `+7deg` ABOUT ITS LEFT EDGE -- the rule from
 * `ui/README.md`, and the mirror of the incoming card on the right. `.op-arete`
 * lights the leading edge, which for a left-anchored surface is the left one,
 * so it is used without `.is-end`.
 *
 * A BAY AND NOT A FRAME, for the same reason the card is: rule 2 says a frame
 * means "press this", and there is nothing here to press.
 *
 * THE ELAPSED CLOCK RUNS LOCALLY off the `elapsedMs` Lua pushed. The same
 * argument the countdown on the incoming card makes: a number that is
 * arithmetic does not need a net event a second to produce.
 */
const { t } = useLocale()

interface Participant {
  id: number
  name: string
  self: boolean
}

const open = ref(false)
const others = ref<Participant[]>([])

/** Milliseconds the call has been up, counted forward off the last push. */
const elapsed = ref(0)
const takenAt = shallowRef(0)

/** True when an invite is waiting that the player has waved off the screen. */
const waiting = ref(false)

let tick: ReturnType<typeof setInterval> | undefined

function stopTick(): void {
  if (tick !== undefined) clearInterval(tick)
  tick = undefined
}

function startTick(): void {
  stopTick()
  tick = setInterval(() => {
    elapsed.value += Date.now() - takenAt.value
    takenAt.value = Date.now()
  }, 1000)
}

/** `03:41`. Minutes and seconds; a holocall that ran for an hour is a bug. */
const clock = computed(() => {
  const whole = Math.floor(elapsed.value / 1000)
  const minutes = Math.floor(whole / 60)
  const seconds = whole % 60
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
})

/** The first other party by name, which is what the chip has room for. */
const headline = computed(() => (others.value[0]?.name ?? '').trim())

/** `+1` when there is a third. Rule 8: a mono micro-label states something real. */
const extra = computed(() =>
  others.value.length > 1 ? t('calls.live.others', { count: others.value.length - 1 }) : ''
)

useBridge('opx:calls:view', (payload: Payload) => {
  guard('calls:live', () => {
    if (text(payload.kind) !== 'state') return
    const call = table(payload.call)
    const rows = list<Record<string, unknown>>(call.participants)
    if (rows.length === 0) {
      open.value = false
      waiting.value = false
      stopTick()
      return
    }
    // EVERYBODY BUT ME. The payload marks the local player with `self` because
    // the page has no way of telling: a network player id means nothing here.
    others.value = rows
      .filter((row) => row.self !== true)
      .map((row) => ({
        id: num(row.id),
        name: text(row.name, '?'),
        self: false
      }))
    elapsed.value = Math.max(0, num(call.elapsedMs))
    takenAt.value = Date.now()
    // The other half of the owner's re-pop: while a call is live and an invite
    // is waiting that the player dismissed, the chip is the only thing on
    // screen that can say so.
    waiting.value = payload.invitePending === true && payload.dismissed === true
    open.value = true
    startTick()
  }, undefined)
})

onUnmounted(stopTick)
</script>

<template>
  <aside v-if="open" class="live op-plane">
    <section
      class="chip op-bay op-anchor-left op-arete op-interlace op-ink op-enter"
      data-augmented-ui="tr-clip bl-clip border"
    >
      <p class="head">
        <span class="dot" />
        <span class="title op-label">{{ t('calls.live.title') }}</span>
        <span class="time op-value">{{ clock }}</span>
      </p>

      <p class="with op-copy op-truncate">
        <span class="with-label op-eyebrow">{{ t('calls.live.with') }}</span>
        {{ headline }}<span v-if="extra" class="extra op-eyebrow">{{ extra }}</span>
      </p>

      <p v-if="waiting" class="waiting op-eyebrow">{{ t('calls.row.repop') }}</p>
    </section>
  </aside>
</template>

<style scoped>
/* =============================================================================
   Small, left, and it stays small. 168px against a 1920px screen is under 9% of
   it, on the left rail at the standard inset, below the chat log's lane and
   above the prompts strip -- the two other things that live on that side.
   ========================================================================== */

.live {
  position: absolute;
  left: 0;
  top: 58%;
  pointer-events: none;
}

.chip {
  box-sizing: border-box;
  width: 168px;
  padding: var(--op-space-2) var(--op-space-2) var(--op-space-2) var(--op-space-3);
  background: var(--op-plate-quiet);
  --aug-tr: var(--op-cut-lg);
  --aug-bl: var(--op-cut-lg);
}

.head {
  display: flex;
  align-items: center;
  gap: var(--op-space-1);
  margin: 0 0 var(--op-space-1);
}

/* THE ONE FILLED SHAPE ON THE CHIP, and rule 1 allows it because it is not a
   state block behind type -- it is a 5px mark, the whole of which is the datum.
   It does NOT pulse: `tokens.css` is explicit that this surface cuts rather
   than fades, with no idle animation, and a chip that is up for minutes is the
   last place to put one. */
.dot {
  flex: 0 0 auto;
  width: 5px;
  height: 5px;
  background: var(--op-red);
}

.title {
  flex: 1 1 auto;
  font-size: var(--op-fs-meta);
  color: var(--op-red-text);
}

.time {
  flex: 0 0 auto;
  color: var(--op-text-dim);
}

.with {
  margin: 0;
  color: var(--op-text);
}

.with-label {
  display: block;
  margin-bottom: 2px;
  color: var(--op-text-faint);
}

.extra {
  margin-left: var(--op-space-1);
  color: var(--op-text-dim);
}

/* A line, not a frame: it is a readout saying something is waiting, and the
   action that answers it is on the eye. Rule 2 again. */
.waiting {
  margin: var(--op-space-1) 0 0;
  padding-top: var(--op-space-1);
  border-top: 1px solid var(--op-line);
  color: var(--op-red-text);
  text-transform: none;
  line-height: 1.4;
  overflow-wrap: break-word;
}
</style>
