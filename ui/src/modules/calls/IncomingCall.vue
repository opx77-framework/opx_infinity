<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, shallowRef } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE INCOMING CALL CARD -- who is calling, and how long they will wait.
 *
 * THE OWNER'S REQUIREMENT IS THE WHOLE SHAPE OF THIS FILE: "il faut pas que ca
 * gene la vision du joueur". A holocall card is not a dialogue box. It sits at
 * the right edge, it is 232px wide, it is three lines of type, and it is on the
 * `overlay` layer -- which is `pointer-events: none` for its whole height and
 * is never focused. Nothing here re-enables either.
 *
 * WHICH IS WHY IT HAS NO BUTTONS, AND WHY IT MUST NOT GROW ONE. The card SAYS
 * how it is answered -- hold ALT on yourself -- and the answer is a row on the
 * target eye. That is the owner's design and the layer is what keeps it honest.
 *
 * The first version carried a small × to wave the card away, with
 * `pointer-events: auto` on it and a paragraph defending the exception. The
 * defence was wrong: the overlay layer only ever sees a pointer when SOME OTHER
 * module has taken the cursor on the modal layer, so that × was clickable
 * exactly when the inventory or the menu happened to be open and dead the rest
 * of the time. A control that works under a condition it does not state is
 * worse than no control. The card takes ITSELF down after its dwell now --
 * `CARD_DWELL_S` in `config/calls.lua` -- and the eye's re-pop row brings it
 * back, which is the owner's re-pop button seen from the other end.
 *
 * NOTHING HERE DECIDES ANYTHING. It does not know whether the call was
 * answered, whether it may be answered, or who the caller is beyond the name it
 * was handed. It draws what Lua pushed and emits ONE intent -- `ready` when it
 * mounts. Everything else it might have said is Lua's: whether the card is up
 * at all is a field in the payload, because the dwell clock and the re-pop row
 * are both on the Lua side and a page that hid itself on its own would be a
 * second opinion about a question that already has an answer.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * RIGHT-ANCHORED, SO IT TILTS THE OTHER WAY. `.op-anchor-right` is `-7deg`
 * about the right edge, which is the rule in `ui/README.md`: the tilt comes
 * from the anchor, and a surface on the right edge that leaned left would be a
 * plane receding into the screen from the wrong side. That tilt is also the
 * only "curve" a CSS page has -- `tokens.css` says it out loud: CP2077's HUD is
 * curved by a shader, and a page cannot warp a plane but it can BE one.
 *
 * IT IS A BAY, NOT A FRAME. Rule 2 of the contract: a frame means "press this",
 * and there is nothing here to press. `.op-bay` is the enclosure preset -- two
 * opposite corners at the large cut -- and the interlace goes on it because
 * rule 9 says the interlace goes on what is enclosed.
 *
 * THE COUNTDOWN IS DRAWN, NOT TICKED FROM LUA. Lua sends `expiresInMs` once per
 * push; this counts it down locally at 1Hz. A card that asked the server for
 * the time every second would put a net event on the wire once a second per
 * ringing call, to redraw a number that is arithmetic.
 */
const { t } = useLocale()

const open = ref(false)
const kind = ref('call')
const fromName = ref('')

/** Milliseconds left, counted down locally off the last push. */
const remaining = ref(0)

/** When the last push arrived, on the page's own clock. */
const takenAt = shallowRef(0)

let tick: ReturnType<typeof setInterval> | undefined

function stopTick(): void {
  if (tick !== undefined) clearInterval(tick)
  tick = undefined
}

function startTick(): void {
  stopTick()
  tick = setInterval(() => {
    const spent = Date.now() - takenAt.value
    remaining.value = Math.max(0, remaining.value - spent)
    takenAt.value = Date.now()
    // AT ZERO IT STOPS COUNTING AND STAYS PUT. It does not hide itself: the
    // invite expiring is the server's to notice, and a card that vanished on
    // its own clock would be the page asserting something it cannot know. The
    // push that follows the sweep is what takes it down.
    if (remaining.value <= 0) stopTick()
  }, 1000)
}

/** The title, which names what is being offered rather than always "call". */
const title = computed(() => {
  if (kind.value === 'join') return t('calls.incoming.join')
  if (kind.value === 'contact') return t('calls.incoming.contact')
  return t('calls.incoming.title')
})

/** `0:07`. Tabular numerals, so it does not jitter as the digits change. */
const clock = computed(() => {
  const whole = Math.ceil(remaining.value / 1000)
  const minutes = Math.floor(whole / 60)
  const seconds = whole % 60
  return `${minutes}:${String(seconds).padStart(2, '0')}`
})

useBridge('opx:calls:view', (payload: Payload) => {
  guard('calls:view', () => {
    if (text(payload.kind) !== 'state') return
    const invite = table(payload.invite)
    // AN EMPTY LUA TABLE SERIALISES TO `{}`, so the presence of the object is
    // not the test -- `from` is. A card drawn off an empty table would be a
    // call from nobody.
    const from = text(invite.fromName)
    if (from === '') {
      open.value = false
      stopTick()
      return
    }
    kind.value = text(invite.kind, 'call')
    fromName.value = from
    remaining.value = Math.max(0, num(invite.expiresInMs))
    takenAt.value = Date.now()
    open.value = true
    startTick()
  }, undefined)
})

onMounted(() => {
  // The handshake. Lua answers with this player's whole call state, and nothing
  // is published to a view that has not reported ready.
  emit('opx:calls:ready', {})
})

onUnmounted(stopTick)
</script>

<template>
  <aside v-if="open" class="incoming op-plane">
    <section
      class="card op-bay op-anchor-left op-arete is-end op-interlace op-ink op-enter"
      data-augmented-ui="tr-clip bl-clip border"
    >
      <p class="eyebrow op-eyebrow">{{ t('calls.incoming.eyebrow') }}</p>
      <p class="title op-label op-truncate">{{ title }}</p>

      <p class="who op-copy op-truncate">
        <span class="who-label op-eyebrow">{{ t('calls.incoming.from') }}</span>
        {{ fromName }}
      </p>

      <p class="hint op-eyebrow">{{ t('calls.incoming.hint') }}</p>

      <p class="clock op-value">
        {{ t('calls.incoming.expires', { time: clock }) }}
      </p>
    </section>
  </aside>
</template>

<style scoped>
/* =============================================================================
   A card at the edge of the view, and it stays at the edge of the view.

   232px wide against a 1920px screen is 12% of it, pinned to the right rail at
   the standard inset, at the vertical middle where nothing else on this surface
   lives -- the prompts strip is bottom-centre, the vehicle chip bottom-right,
   the toasts top-right, the chat log left. It overlaps nothing, and it is the
   only surface in the runtime placed for what it must NOT cover rather than for
   what it says.
   ========================================================================== */

.incoming {
  position: absolute;
  /* LEFT, ON THE OWNER'S WORD: "pass la a gauche meme l'appel en cours a
     gauche". It sat on the right, which is where the vanilla HUD keeps its own
     phone -- and that was the argument for it until the owner looked at it. */
  left: 0;
  top: 50%;
  transform: translateY(-50%);
  display: flex;
  align-items: flex-start;
  gap: var(--op-space-1);
  /* Inherited from the layer and said again here, the way `ProgressRoot` says
     it: this is drawn over whatever the player is aiming at. */
  pointer-events: none;
}

.card {
  box-sizing: border-box;
  width: 232px;
  padding: var(--op-space-3) var(--op-space-3) var(--op-space-2);
  /* NO PLATE. "remove le background sur la notif d'appel a droite". The card
     is text and an outline over the world now:  still draws its
     chamfered border, and what the player loses is the slab that was sitting
     between them and the street. */
  background: none;
  --aug-tr: var(--op-cut-lg);
  --aug-bl: var(--op-cut-lg);
}

.eyebrow {
  margin: 0 0 var(--op-space-1);
  color: var(--op-text-faint);
}

/* THE ONE LINE THAT IS ALLOWED TO BE LOUD, and it climbs in luminance rather
   than leaving the hue -- rule 4. `--op-red-hi` is the rung above the voice;
   the alarm is reserved for what is actually wrong, and a call is not. */
.title {
  margin: 0 0 var(--op-space-2);
  color: var(--op-red-hi);
}

.who {
  margin: 0 0 var(--op-space-2);
  color: var(--op-text);
}

.who-label {
  display: block;
  margin-bottom: 2px;
  color: var(--op-text-dim);
}

/* NOT `.op-truncate`. The test in `surface.css` is whether the text NAMES
   something or SAYS something: this is an instruction telling the player how to
   answer, and half an instruction is worse than two lines of one. */
.hint {
  margin: 0 0 var(--op-space-2);
  color: var(--op-red-text);
  text-transform: none;
  line-height: 1.4;
  overflow-wrap: break-word;
}

/* A 1px rule and a line of type. A readout does not get a frame -- rule 2. */
.clock {
  margin: 0;
  padding-top: var(--op-space-1);
  border-top: 1px solid var(--op-line);
  color: var(--op-text-dim);
}

/* NO `pointer-events: auto` ANYWHERE BELOW THIS LINE, and the test suite holds
   both call views to it. The overlay layer only ever sees a pointer while some
   OTHER module has taken the cursor on the modal layer, so a control here works
   exactly when the inventory or the menu happens to be open and is dead the
   rest of the time. The dwell clock in `modules/calls/client/main.lua` and the
   re-pop row on the eye are what replaced the × this file used to carry. */
</style>
