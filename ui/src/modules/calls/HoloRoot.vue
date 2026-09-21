<script setup lang="ts">
import { computed, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE HOLOGRAM -- one screen, centred, and every verb this module has on it.
 *
 * THE OWNER, in three messages: "fait en sorte que cela passe pas par alt ce
 * serais en gros fait une touche qui ouvre un menu style halogram tous se passe
 * desus call resus contact etc plus de alt", then "le halo prend vrais le devant
 * de l'ecran", then "en plein centre".
 *
 * WHAT IT REPLACED, and why the replacement is not a straight port: this module
 * lived on the target eye. Eight rows -- answer, refuse, hang up, call, add,
 * share a contact, open the contacts, bring the card back. They worked. They
 * were also the wrong mechanism: ALT needs a body under the crosshair, and a
 * holocall is the thing you reach for when the person is NOT in front of you.
 * Answering one meant pointing at your own body first.
 *
 * THIS IS THE ONE VIEW IN THE MODULE THAT MAY BE PRESSED, and that is the whole
 * reason it is a separate surface. The incoming card and the live chip are on
 * `overlay`: `pointer-events: none` for their whole height, never focused, so a
 * call arriving can never take the mouse or stand between the player and what
 * they are aiming at. This one is on `interactive`, centred, in front and
 * focused, because the player opened it on a key, deliberately. A passive notice
 * that could steal input and a deliberate screen that could not would both be
 * the wrong way round.
 *
 * NOTHING HERE DECIDES ANYTHING. Every row names a player id and sends it; the
 * server judges the invite again and refuses it in its own words. A row is drawn
 * greyed with the reason the server ALREADY gave for it -- `refusal` comes off
 * the roster, worked out by the same function that judges the real invite -- so
 * the screen never offers something the next press would refuse.
 *
 * THE LISTS ARE NOT CACHED. Lua asks for a fresh roster on every open, because
 * who is connected, who is busy and who is close enough to hand a contact to are
 * facts with a shelf life of seconds.
 */

const { t } = useLocale()

interface Row {
  id: number
  name: string
  refusal: string | null
}

interface Recent {
  outcome: string
  name: string
}

const open = ref(false)
const contacts = ref<Row[]>([])
const nearby = ref<Row[]>([])
const recent = ref<Recent[]>([])

/** The call this player is on, the one ringing at them, and the one they placed. */
const call = ref<Payload | null>(null)
const invite = ref<Payload | null>(null)
const outgoing = ref<Payload | null>(null)

/** Which list is showing. Local: the screen's own state, never Lua's. */
const tab = ref<'contacts' | 'nearby' | 'recent'>('contacts')

const onCall = computed(() => call.value !== null)
const ringing = computed(() => invite.value !== null)

/** Who is on the call, as names, for the header. */
const participants = computed(() => {
  const held = call.value === null ? [] : list<Payload>(call.value.participants)
  return held.map((row) => text(row.name, '?')).filter((name) => name !== '')
})

/**
 * The invite's kind decides which question is asked. A contact hand-over is not
 * a call and must not be answered with "Répondre": the owner asked for the share
 * to be "un input qui propose un yes or no", and this is where that lands.
 */
const inviteIsContact = computed(
  () => invite.value !== null && text(invite.value.kind) === 'contact'
)

function rowsOf(value: unknown): Row[] {
  return list<Payload>(value)
    .map((row) => ({
      id: num(row.id),
      name: text(row.name, '?'),
      // `text()` answers '' for an absent field, and '' is not a refusal. The
      // absence has to survive as one, because it is what makes a row pressable.
      refusal: row.refusal === undefined || row.refusal === null ? null : text(row.refusal)
    }))
    .filter((row) => row.id > 0)
}

useBridge('opx:calls:holo', (payload: Payload) => {
  guard('calls:holo', () => {
    open.value = payload.open === true
    contacts.value = rowsOf(payload.rows)
    nearby.value = rowsOf(payload.nearby)
    recent.value = list<Payload>(payload.recent).map((row) => ({
      outcome: text(row.outcome, 'missed'),
      name: text(row.name, '?')
    }))
    const live = table(payload.call)
    call.value = Object.keys(live).length > 0 ? live : null
    const ring = table(payload.invite)
    invite.value = Object.keys(ring).length > 0 ? ring : null
    const placed = table(payload.outgoing)
    outgoing.value = Object.keys(placed).length > 0 ? placed : null

    // A screen that opens on the tab you left it on is a screen that remembers
    // a decision you made about a list that has since been rebuilt. It opens on
    // the contacts, always, except while somebody is standing in front of you
    // and you have no contacts at all -- which is a new player's first minute
    // and the one case where the wrong default is a dead end.
    if (payload.open === true && contacts.value.length === 0 && nearby.value.length > 0) {
      tab.value = 'nearby'
    }
  }, undefined)
})

function close(): void {
  emit('opx:calls:close', {})
}

function callRow(row: Row): void {
  if (row.refusal !== null) return
  emit('opx:calls:call', { id: row.id })
}

function shareRow(row: Row): void {
  if (row.refusal !== null) return
  emit('opx:calls:share', { id: row.id })
}

function accept(): void {
  emit('opx:calls:accept', {})
}

function decline(): void {
  emit('opx:calls:decline', {})
}

function hangUp(): void {
  emit('opx:calls:hangUp', {})
}

/**
 * LITERAL KEYS, NOT BUILT ONES, and the suite is why. A catalogue check walks
 * this file for `t('calls...')` and asserts every one exists in both languages;
 * a key assembled from a prefix and a variable is invisible to it, so the first
 * missing line would reach a player as the word `calls.holo.tab.nearby` printed
 * on a button. These three maps are that check's eyes.
 */
const TAB_KEY = {
  contacts: 'calls.holo.tab.contacts',
  nearby: 'calls.holo.tab.nearby',
  recent: 'calls.holo.tab.recent'
} as const

const OUTCOME_KEY: Record<string, string> = {
  missed: 'calls.holo.outcome.missed',
  unanswered: 'calls.holo.outcome.unanswered',
  declined: 'calls.holo.outcome.declined',
  refused: 'calls.holo.outcome.refused'
}

/**
 * The refusal's own key. Nineteen of them, named in `Model.REASONS`, and the
 * suite already walks THAT list against both catalogues -- so this one is built
 * rather than listed, and deliberately not written as a `t('calls.error...')`
 * literal that would make the other check think it had found a key.
 */
function reasonKey(reason: string): string {
  return 'calls.error.' + reason
}

const shown = computed<Row[]>(() => (tab.value === 'nearby' ? nearby.value : contacts.value))
</script>

<template>
  <div v-if="open" class="holo op-ink">
    <!-- THE PANE. Centred by the wrapper, and it is the whole of "le halo prend
         vrais le devant de l'ecran": this is not a corner widget, it is the
         screen the player opened. -->
    <section class="pane op-frame op-interlace op-enter" data-augmented-ui="tl-clip br-clip border">
      <header class="head">
        <p class="eyebrow op-micro">{{ t('calls.holo.eyebrow') }}</p>
        <h2 class="title op-title">{{ t('calls.holo.title') }}</h2>
        <button class="shut op-micro" type="button" @click="close">
          {{ t('calls.holo.close') }}
        </button>
      </header>

      <!-- THE RINGING CALL COMES FIRST AND ABOVE EVERYTHING, because it is the
           one thing on this screen with a clock running on it. -->
      <div v-if="ringing" class="ring op-plate-quiet">
        <p class="ring-who">
          {{ inviteIsContact
            ? t('calls.holo.sharing', { name: text(invite?.name, '?') })
            : t('calls.holo.ringing', { name: text(invite?.name, '?') }) }}
        </p>
        <div class="acts">
          <button class="act yes op-frame" type="button" @click="accept">
            {{ inviteIsContact ? t('calls.holo.yes') : t('calls.holo.answer') }}
          </button>
          <button class="act no op-frame" type="button" @click="decline">
            {{ inviteIsContact ? t('calls.holo.no') : t('calls.holo.refuse') }}
          </button>
        </div>
      </div>

      <div v-if="onCall" class="live op-plate-quiet">
        <p class="live-who">{{ t('calls.holo.live', { names: participants.join(', ') }) }}</p>
        <button class="act no op-frame" type="button" @click="hangUp">
          {{ t('calls.holo.hangUp') }}
        </button>
      </div>

      <p v-else-if="outgoing !== null" class="waiting op-micro">
        {{ t('calls.holo.calling', { name: text(outgoing?.name, '?') }) }}
      </p>

      <nav class="tabs">
        <button
          v-for="name in (['contacts', 'nearby', 'recent'] as const)"
          :key="name"
          class="tab op-micro"
          :class="{ on: tab === name }"
          type="button"
          @click="tab = name"
        >
          {{ t(TAB_KEY[name]) }}
        </button>
      </nav>

      <ul v-if="tab !== 'recent'" class="rows">
        <li v-for="row in shown" :key="row.id" class="row" :class="{ off: row.refusal !== null }">
          <span class="who op-truncate">{{ row.name }}</span>
          <!-- THE REASON IS SHOWN, NOT MERELY OBEYED. A row that is simply dark
               says the contact is unreachable and nothing else, and the two
               commonest reasons -- already on a call, line busy -- both stop
               being true in a minute. -->
          <span v-if="row.refusal !== null" class="why op-micro">
            {{ t(reasonKey(row.refusal)) }}
          </span>
          <template v-else>
            <button class="pill op-micro" type="button" @click="callRow(row)">
              {{ onCall ? t('calls.holo.add') : t('calls.holo.call') }}
            </button>
            <!-- Sharing is offered only to the people close enough for the
                 server to accept it, which is what the `nearby` list IS. -->
            <button
              v-if="tab === 'nearby'"
              class="pill op-micro"
              type="button"
              @click="shareRow(row)"
            >
              {{ t('calls.holo.share') }}
            </button>
          </template>
        </li>
        <li v-if="shown.length === 0" class="empty op-micro">
          {{ tab === 'nearby' ? t('calls.holo.noneNear') : t('calls.holo.noContacts') }}
        </li>
      </ul>

      <ul v-else class="rows">
        <li v-for="(row, at) in recent" :key="at" class="row off">
          <span class="who op-truncate">{{ row.name }}</span>
          <span class="why op-micro">{{ t(OUTCOME_KEY[row.outcome] ?? 'calls.holo.outcome.missed') }}</span>
        </li>
        <li v-if="recent.length === 0" class="empty op-micro">
          {{ t('calls.holo.noRecent') }}
        </li>
      </ul>
    </section>
  </div>
</template>

<style scoped>
/* =============================================================================
   DEAD CENTRE, AND IN FRONT. "le halo prend vrais le devant de l'ecran", "en
   plein centre". The wrapper is the whole viewport so the pane can be centred
   against it rather than against whatever the layer happens to be sized to.
   ========================================================================== */
.holo {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  /* NO SCRIM. The owner has asked for the background off twice on this module's
     other two views, and the same answer applies here: a hologram is a thing
     projected into the room, and a room you cannot see is not one. */
  pointer-events: none;
}

.pane {
  box-sizing: border-box;
  width: min(520px, calc(100vw - var(--op-inset-x) * 2));
  max-height: calc(100vh - var(--op-inset-y) * 2);
  overflow: auto;
  padding: var(--op-space-3);
  /* The one element on this surface that takes the pointer. The wrapper stays
     transparent to it, so a click beside the pane goes to the world. */
  pointer-events: auto;
  --aug-tl: var(--op-cut-lg);
  --aug-br: var(--op-cut-lg);
}

.head {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: baseline;
  gap: var(--op-space-1);
  margin-bottom: var(--op-space-3);
}

.eyebrow {
  grid-column: 1;
  margin: 0;
  color: var(--op-text-faint);
}

.title {
  grid-column: 1;
  margin: 0;
}

.shut {
  grid-column: 2;
  grid-row: 1 / span 2;
  border: 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.shut:hover {
  color: var(--op-text);
}

.ring,
.live {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-2);
  margin-bottom: var(--op-space-2);
  padding: var(--op-space-2);
}

.ring-who,
.live-who {
  margin: 0;
  min-width: 0;
}

.acts {
  display: flex;
  gap: var(--op-space-1);
}

.act {
  padding: var(--op-space-1) var(--op-space-2);
  background: none;
  color: var(--op-text);
  cursor: pointer;
}

.act.yes {
  color: var(--op-good, var(--op-text));
}

.act.no {
  color: var(--op-red);
}

.waiting {
  margin: 0 0 var(--op-space-2);
  color: var(--op-text-faint);
}

.tabs {
  display: flex;
  gap: var(--op-space-2);
  margin-bottom: var(--op-space-2);
  border-bottom: 1px solid var(--op-line);
}

.tab {
  border: 0;
  border-bottom: 2px solid transparent;
  padding: var(--op-space-1) 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.tab.on {
  border-bottom-color: var(--op-red);
  color: var(--op-text);
}

.rows {
  margin: 0;
  padding: 0;
  list-style: none;
}

.row {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: var(--op-space-1) 0;
  border-bottom: 1px solid var(--op-line);
}

.row.off {
  color: var(--op-text-faint);
}

.who {
  flex: 1;
  min-width: 0;
}

.why {
  color: var(--op-text-faint);
}

.pill {
  border: 1px solid var(--op-line);
  padding: 2px var(--op-space-2);
  background: none;
  color: var(--op-text);
  cursor: pointer;
}

.pill:hover {
  border-color: var(--op-red);
}

.empty {
  padding: var(--op-space-2) 0;
  color: var(--op-text-faint);
}
</style>
