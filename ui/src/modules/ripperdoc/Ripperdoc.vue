<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE RIPPERDOC CLINIC -- a chair, a tray of chrome, and the two people it
 * takes. One view, four states, drawn from one kind-discriminated channel.
 *
 * IT DECIDES NOTHING. Which grades exist, what each costs, what is fitted in
 * which slot, who may offer and what an offer prices at all arrive from the
 * server; this page draws the frame and reports presses. A fit is an INTENT
 * (`ripperdoc:offer`) and the tray only redraws when a fresh frame comes back
 * -- chrome bought in the page would be a second authority over one fact.
 *
 * THE OFFER IS A CONVERSATION WITH ONE SPEAKER AT A TIME. With an operator at
 * the chair the patient reads and answers; with nobody there the patient's own
 * rows are the controls (the request's self-service door). Same rows, same
 * prices -- only who may press them changes, and the frame says which.
 *
 * STOWING IS AN INTENT TOO. Escape and the leave control both ask (`stand` for
 * the patient, `close` for the operator, a decline for an invite); the panel
 * goes down when the close comes back on `ripperdoc:view`.
 *
 * -- DESIGN, per ui/README.md --
 *
 * CENTRED, so there is NO TILT: rotating a centred plane about its middle is
 * paper on a spindle, not a surface receding (rule 5). A clinic menu is read
 * head-on.
 *
 * A GRADE THE PLAYER CANNOT ACT ON IS A READOUT, NOT A CONTROL (rule 2): what
 * is not a control gets no frame -- a pressable row is a closed `.op-frame` box,
 * a readout is a dim line that STATES ITS CONDITION instead (`FITTED`,
 * `PULL FIRST`, `WORK IN PROGRESS` -- rule 8: technical filler is content).
 *
 * EVERY MICRO-LABEL STATES A REAL NUMBER: the prices in the verbs, and each
 * grade's own numbers in its stats run (`STRIKE 15`, `JUMP COST 15`). Nothing
 * here is invented chrome text.
 *
 * FRESHNESS IS THE HUE'S LUMINANCE DESCENT (rule 4): the flash strip's line is
 * the voice at full (`--op-red`), alarm spent only on a refusal.
 */

interface Flash {
  key: string
  args: Record<string, unknown>
}

interface Grade {
  id: string
  name: string
  price: number
  owned: boolean
  /** Raw wire values; `num` coerces each when the stats run reads it. */
  stats: Record<string, unknown>
}

interface Entry {
  id: string
  name: string
  slot: string
  remove: number
  fitted: string
  mine: boolean
  grades: Grade[]
}

interface Offer {
  id: number
  mode: string
  entry: string
  grade: string
  name: string
  price: number
  by: string
}

interface Invitee {
  id: number
  name: string
}

const { t } = useLocale()

/** The page's own ceilings, repeating Lua's rather than trusting the sender. */
const MAX_ENTRIES = 8
const MAX_GRADES = 8
const MAX_INVITEES = 8

type Mode = 'sitter' | 'desk' | 'invite' | 'notice'

const open = ref(false)
const mode = ref<Mode>('sitter')
const chairName = ref('')
const attended = ref(false)
const busy = ref(false)
const patientName = ref('')
const from = ref('')
const entries = ref<Entry[]>([])
const offer = ref<Offer | null>(null)
const invitees = ref<Invitee[]>([])
const flash = ref<Flash | null>(null)

let release: (() => void) | undefined
let noticeTimer: ReturnType<typeof setTimeout> | undefined

/** The stat run per slot: the numbers that grade actually carries (rule 8). */
const ARM_STATS = [
  'normalDamage',
  'chargedDamage',
  'knockbackMeters',
  'cooldownMs',
  'chargeMs'
]
const LEG_STATS = ['jumpStaminaCost', 'cooldownMs', 'maxAirborneMs', 'maxFallSpeed']

function statsOf(entry: Entry, grade: Grade): Array<{ key: string; value: number }> {
  const order = entry.slot === 'legs' ? LEG_STATS : ARM_STATS
  const run: Array<{ key: string; value: number }> = []
  for (const key of order) {
    const value = num(grade.stats[key])
    if (value !== 0) run.push({ key, value })
  }
  return run.slice(0, 4)
}

/** Locale arguments, coerced: `t` takes strings or numbers, nothing else. */
function vars(args: Record<string, unknown>): Record<string, string | number> {
  const out: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(args)) {
    out[name] = typeof value === 'number' ? value : String(value ?? '')
  }
  return out
}

/** The one locale key a flash speaks, refusing a blank line. */
function flashText(line: Flash | null): string {
  if (line === null) return ''
  const key = text(line.key)
  return key ? t(key, vars(line.args)) : ''
}

/** A flash off the wire, coerced field by field -- or null for none. */
function flashOf(payload: Payload): Flash | null {
  const raw = table(payload.flash)
  const key = text(raw.key)
  return key ? { key, args: table(raw.args) } : null
}

/** Whether this player may press a fit/pull on the patient's behalf. */
const operating = computed(() => mode.value === 'desk')

/** Whether the patient may press their own rows (nobody at the desk). */
const selfService = computed(() => mode.value === 'sitter' && !attended.value)

/** A row is a control only when pressing it would mean something. */
function pressable(): boolean {
  return !busy.value && offer.value === null
}

function blank(): void {
  open.value = false
  entries.value = []
  offer.value = null
  invitees.value = []
  flash.value = null
  busy.value = false
  patientName.value = ''
  from.value = ''
  if (noticeTimer !== undefined) {
    clearTimeout(noticeTimer)
    noticeTimer = undefined
  }
  release?.()
  release = undefined
}

/** Escape's meaning, per state: leave the chair, step away, or decline. */
function leave(): void {
  if (!open.value) return
  if (mode.value === 'sitter') emit('opx:ripperdoc:stand', {})
  else if (mode.value === 'desk') emit('opx:ripperdoc:close', {})
  else if (mode.value === 'invite') answer(false)
}

function answer(accept: boolean): void {
  emit('opx:ripperdoc:answer', { what: 'invite', accept })
}

function toOffer(accept: boolean): void {
  if (offer.value === null) return
  emit('opx:ripperdoc:answer', { what: 'offer', accept })
}

/** A fit or a pull, named by entry and grade -- what it costs is the server's. */
function propose(entry: Entry, grade: Grade | null, kind: 'install' | 'remove'): void {
  if (!pressable()) return
  emit('opx:ripperdoc:offer', {
    entry: entry.id,
    grade: grade === null ? '' : grade.id,
    mode: kind
  })
}

function invite(player: Invitee): void {
  emit('opx:ripperdoc:invite', { player: player.id })
}

useBridge('opx:ripperdoc:view', (payload: Payload) => {
  guard(
    'ripperdoc:view',
    () => {
      const kind = text(payload.mode)

      if (kind === 'notice') {
        // A transient line, no panel and no focus: the world keeps turning.
        flash.value = flashOf(payload)
        if (noticeTimer !== undefined) clearTimeout(noticeTimer)
        noticeTimer = setTimeout(() => {
          flash.value = null
          noticeTimer = undefined
        }, 4000)
        return
      }

      if (kind === 'sitter' || kind === 'desk' || kind === 'invite') {
        const rows: Entry[] = []
        for (const raw of list<Payload>(payload.catalogue).slice(0, MAX_ENTRIES)) {
          const id = text(raw.id)
          if (!id) continue
          const grades: Grade[] = []
          for (const grade of list<Payload>(raw.grades).slice(0, MAX_GRADES)) {
            const gradeId = text(grade.id)
            if (!gradeId) continue
            grades.push({
              id: gradeId,
              name: text(grade.name, gradeId),
              price: num(grade.price),
              owned: text(grade.owned) === '1' || grade.owned === true,
              stats: table(grade.stats)
            })
          }
          rows.push({
            id,
            name: text(raw.name, id),
            slot: text(raw.slot),
            remove: num(raw.remove),
            fitted: text(raw.fitted),
            mine: raw.mine === true,
            grades
          })
        }

        const seen = table(payload.offer)
        const offerId = num(seen.id)
        mode.value = kind
        chairName.value = text(payload.name)
        attended.value = payload.attended === true
        busy.value = payload.busy === true
        patientName.value = text(payload.patientName)
        from.value = text(payload.from)
        entries.value = rows
        invitees.value = list<Payload>(payload.invitees)
          .slice(0, MAX_INVITEES)
          .map((row) => ({ id: num(row.id), name: text(row.name) }))
          .filter((row) => row.id !== 0)
        offer.value =
          offerId > 0
            ? {
                id: offerId,
                mode: text(seen.mode),
                entry: text(seen.entry),
                grade: text(seen.grade),
                name: text(seen.name),
                price: num(seen.price),
                by: text(seen.by)
              }
            : null
        flash.value = flashOf(payload)

        if (!open.value) {
          open.value = true
          // The invite card answers to no Escape but its own decline; the
          // panels leave (rule: leaving is always allowed).
          release?.()
          release = acquireFocus({
            id: 'ripperdoc.panel',
            onEscape: () => leave()
          })
        }
        return
      }

      // `closed` and anything this does not know: the reason is Lua's and it
      // has already said it. This page only takes the panel down.
      blank()
    },
    undefined
  )
})

onUnmounted(() => {
  if (noticeTimer !== undefined) clearTimeout(noticeTimer)
  release?.()
})
</script>

<template>
  <div class="room op-ink" :class="{ open: open || flash !== null }">
    <!-- A notice is a line and nothing else: no panel behind it. -->
    <div v-if="flash !== null && !open" class="notice op-eyebrow">{{ flashText(flash) }}</div>

    <div v-if="open" class="clinic op-plane op-enter">
      <div class="unit op-bay op-arete op-interlace" data-augmented-ui="tl-clip br-clip border">
        <div class="unit-inner">
          <header class="head">
            <div class="head-text">
              <div class="op-eyebrow">
                {{ t('ripperdoc.title') }} · {{ t('ripperdoc.chair', { name: chairName }) }}
              </div>
              <div class="op-value title">
                {{ mode === 'desk' ? t('ripperdoc.desk') : mode === 'invite' ? t('ripperdoc.title') : t('ripperdoc.tray') }}
              </div>
            </div>
            <div class="op-eyebrow state">
              <template v-if="mode === 'desk'">
                {{ patientName ? t('ripperdoc.patient', { name: patientName }) : t('ripperdoc.vacant') }}
              </template>
              <template v-else-if="mode === 'invite'">
                {{ t('ripperdoc.invite', { from }) }}
              </template>
              <template v-else>
                {{ attended ? t('ripperdoc.attended') : t('ripperdoc.self') }}
              </template>
            </div>
          </header>

          <div class="rule"></div>

          <div v-if="flash !== null" class="flash op-eyebrow">{{ flashText(flash) }}</div>

          <!-- THE OPTION TO SIT: accept and decline, and nothing else. -->
          <div v-if="mode === 'invite'" class="invite">
            <div class="op-copy">{{ t('ripperdoc.invite', { from }) }}</div>
            <div class="invite-actions">
              <button type="button" class="act op-frame" data-augmented-ui="tr-clip border" @click="answer(true)">
                {{ t('ripperdoc.accept') }}
              </button>
              <button type="button" class="act quiet op-frame" data-augmented-ui="tr-clip border" @click="answer(false)">
                {{ t('ripperdoc.decline') }}
              </button>
            </div>
          </div>

          <!-- THE DESK WITH NOBODY IN THE CHAIR: offer the seat. -->
          <div v-else-if="mode === 'desk' && patientName === ''" class="invitees">
            <div class="op-eyebrow list-head">{{ t('ripperdoc.invitees') }}</div>
            <div v-if="invitees.length === 0" class="op-copy empty">{{ t('ripperdoc.noInvitees') }}</div>
            <div v-for="row in invitees" :key="row.id" class="invitee">
              <span class="who">{{ row.name }}</span>
              <button
                type="button"
                class="act op-frame"
                data-augmented-ui="tr-clip border"
                @click="invite(row)"
              >
                {{ t('ripperdoc.offerSeat') }}
              </button>
            </div>
          </div>

          <!-- THE TRAY: the patient reads it, the operator works it. -->
          <div v-else class="tray">
            <div v-if="offer !== null" class="offer">
              <div class="offer-text">
                <div class="op-eyebrow perk">{{ offer.by ? t('ripperdoc.offer') : t('ripperdoc.offerSelf') }}</div>
                <div class="op-copy">
                  {{ t(offer.mode === 'install' ? 'ripperdoc.offerFit' : 'ripperdoc.offerPull', { name: offer.name, price: offer.price }) }}
                </div>
              </div>
              <div class="offer-actions">
                <button type="button" class="act op-frame" data-augmented-ui="tr-clip border" @click="toOffer(true)">
                  {{ t('ripperdoc.accept') }}
                </button>
                <button type="button" class="act quiet op-frame" data-augmented-ui="tr-clip border" @click="toOffer(false)">
                  {{ t('ripperdoc.decline') }}
                </button>
              </div>
            </div>
            <div v-else-if="busy" class="op-eyebrow working">{{ t('ripperdoc.working') }}</div>

            <section v-for="entry in entries" :key="entry.id" class="entry">
              <div class="entry-head">
                <span class="op-eyebrow ord">{{ t('ripperdoc.slot.' + entry.slot) }}</span>
                <span class="entry-name">{{ entry.name }}</span>
                <span class="op-eyebrow fit">
                  {{ entry.fitted ? t('ripperdoc.fitted') + ' ' + entry.fitted : t('ripperdoc.empty') }}
                </span>
              </div>

              <div class="grades">
                <template v-for="grade in entry.grades" :key="grade.id">
                  <!-- A control when pressing means something, a readout that
                       STATES ITS CONDITION when it does not (rules 2 and 8). -->
                  <button
                    v-if="operating || selfService"
                    type="button"
                    class="grade op-frame"
                    :class="{ 'is-on': grade.owned }"
                    data-augmented-ui="tr-clip border"
                    :disabled="!pressable() || entry.fitted !== ''"
                    @click="propose(entry, grade, 'install')"
                  >
                    <span class="grade-name">{{ grade.name }}</span>
                    <span class="stats op-eyebrow">
                      <span v-for="stat in statsOf(entry, grade)" :key="stat.key">
                        {{ t('ripperdoc.stat.' + stat.key) }} {{ stat.value }}
                      </span>
                    </span>
                    <span class="op-eyebrow cost">
                      {{ grade.owned ? t('ripperdoc.fitted') : entry.fitted !== '' ? t('ripperdoc.removeFirst') : t('ripperdoc.fit', { price: grade.price }) }}
                    </span>
                  </button>
                  <div v-else class="grade dark">
                    <span class="grade-name">{{ grade.name }}</span>
                    <span class="stats op-eyebrow">
                      <span v-for="stat in statsOf(entry, grade)" :key="stat.key">
                        {{ t('ripperdoc.stat.' + stat.key) }} {{ stat.value }}
                      </span>
                    </span>
                    <span class="op-eyebrow cost">
                      {{ grade.owned ? t('ripperdoc.fitted') : t('ripperdoc.price', { price: grade.price }) }}
                    </span>
                  </div>
                </template>
              </div>

              <button
                v-if="entry.fitted !== '' && (operating || selfService)"
                type="button"
                class="pull op-frame"
                data-augmented-ui="tr-clip border"
                :disabled="!pressable()"
                @click="propose(entry, null, 'remove')"
              >
                {{ t('ripperdoc.pull', { price: entry.remove }) }}
              </button>
            </section>
          </div>

          <footer class="foot">
            <button
              v-if="mode !== 'invite'"
              type="button"
              class="leave op-frame"
              data-augmented-ui="tr-clip border"
              @click="leave()"
            >
              {{ mode === 'desk' ? t('ripperdoc.stepAway') : t('ripperdoc.leave') }}
            </button>
          </footer>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Centred and unrotated (rule 5): a clinic menu is read head-on, like the
   tree, not held at an angle like the scanner. */
.room {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  visibility: hidden;
  transition:
    opacity var(--op-dur) var(--op-ease),
    visibility var(--op-dur);
}

.room.open {
  opacity: 1;
  visibility: visible;
}

.notice {
  position: absolute;
  top: 18%;
  padding: var(--op-space-2) var(--op-space-4);
  background: var(--op-plate-quiet);
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red);
}

.unit {
  width: 760px;
  --aug-tl: var(--op-cut-lg);
  --aug-br: var(--op-cut-lg);
  background: var(--op-plate-quiet);
}

.unit-inner {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
  padding: var(--op-space-4) var(--op-space-4) var(--op-space-3);
}

.head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: var(--op-space-4);
}

.title {
  font-family: var(--op-font-display);
  font-size: var(--op-fs-title);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
}

.state {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.rule {
  height: 1px;
  background: var(--op-line);
}

/* The flash is the ledger's newest word: the voice at full, alarm only for a
   refusal (rule 4). */
.flash {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red);
}

.invite,
.invitees {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 120px;
  justify-content: center;
}

.invite-actions,
.offer-actions {
  display: flex;
  gap: var(--op-space-3);
}

.list-head {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.invitee {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op-space-3);
  padding-bottom: var(--op-space-2);
  border-bottom: 1px solid var(--op-line);
}

.invitee .who {
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
}

.tray {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 220px;
}

.offer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-4);
  padding-bottom: var(--op-space-2);
  border-bottom: 1px solid var(--op-line);
}

.offer-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.perk {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red-text);
}

.working {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.entry {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
}

.entry-head {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
}

.entry-head .ord,
.entry-head .fit {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.entry-name {
  flex: 1;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-lead);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
  color: var(--op-text);
}

.grades {
  display: flex;
  flex-direction: column;
}

.grade {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
  width: 100%;
  padding: var(--op-space-2) var(--op-space-3);
  text-align: left;
  cursor: pointer;
}

.grade:disabled {
  cursor: default;
  opacity: 0.75;
}

.grade-name {
  min-width: 132px;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
}

.grade.is-on .grade-name {
  color: var(--op-red-hi);
}

.stats {
  flex: 1;
  display: flex;
  gap: var(--op-space-3);
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.cost {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red-text);
  white-space: nowrap;
}

/* A row the player cannot act on is a readout: no frame (rule 2), and the row
   STATES ITS CONDITION rather than sitting mute (rule 8). */
.grade.dark {
  cursor: default;
  border-bottom: 1px solid var(--op-line);
}

.grade.dark .grade-name {
  color: var(--op-text-faint);
}

.pull {
  align-self: flex-start;
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red-hi);
  cursor: pointer;
}

.pull:disabled {
  cursor: default;
  opacity: 0.75;
}

.act {
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red-hi);
  cursor: pointer;
}

.act.quiet {
  color: var(--op-text);
}

.empty {
  color: var(--op-text-faint);
}

.foot {
  display: flex;
  justify-content: flex-end;
}

.leave {
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
  cursor: pointer;
}
</style>
