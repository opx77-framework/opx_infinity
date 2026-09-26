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
 * THE RIPPERDOC CLINIC -- a chair, the whole of Night City's chrome, and the
 * two people it takes. One view, four states, drawn from one kind-discriminated
 * channel.
 *
 * IT DECIDES NOTHING. The server's frame says what the patient wears and what
 * the chair is doing; the Lua view seam lays the tray out from the shared
 * catalogue (the body systems with their slots, the pieces of the system being
 * browsed, the one piece opened in full) and hands this page ONE PAGE OF FACTS.
 * A fit, an upgrade, a pull and a repair are INTENTS (`ripperdoc:offer`); the
 * body only changes when a fresh frame comes back. Browsing is an intent too
 * (`ripperdoc:browse`), answered locally by the seam from the last frame.
 *
 * THE OFFER IS A CONVERSATION WITH ONE SPEAKER AT A TIME. With an operator at
 * the desk the patient reads and answers; with nobody there the patient's own
 * rows are the controls. The answer carries the offer's own id, so a stale
 * accept buys nothing.
 *
 * -- DESIGN, per ui/README.md --
 *
 * CENTRED, so there is NO TILT (rule 5). THREE COLUMNS, read left to right the
 * way the base game's ripperdoc screen is: the body (systems and their slots),
 * the system (its pieces), the piece (its tiers, what each does here, its
 * condition). Every row that can be pressed is a closed box; a readout is a
 * line of type (rule 2). Condition is ticks in the hue's luminance descent, a
 * broken piece at `--op-red-hi` (rule 4). Every micro-label states a number the
 * surface knows: slots used, capacity, tiers, prices, condition (rule 8).
 */

interface Flash {
  key: string
  args: Record<string, unknown>
}

interface Stat {
  key: string
  value: number
}

interface Grade {
  id: string
  name: string
  tier: number
  price: number
  cost: number
  upgrade: boolean
  capacity: number
  owned: boolean
  effects: Stat[]
  stats: Stat[]
  hack: string
  record: string
  game: string
}

interface Fitted {
  grade: string
  points: number
  state: string
  broken: boolean
  inBody: boolean
  repair: number
}

interface Detail {
  id: string
  name: string
  desc: string
  kind: string
  system: string
  power: string
  iconic: boolean
  remove: number
  unsold: boolean
  fitted: Fitted | null
  grades: Grade[]
}

interface Piece {
  id: string
  name: string
  kind: string
  iconic: boolean
  tierFrom: number
  tierTo: number
  priceFrom: number
  fitted: string
  points: number
  state: string
  broken: boolean
}

interface System {
  id: string
  used: number
  slots: number
}

interface Worn {
  id: string
  name: string
  state: string
  points: number
}

interface Offer {
  id: number
  mode: string
  entry: string
  grade: string
  name: string
  gradeName: string
  price: number
  by: string
}

interface Invitee {
  id: number
  name: string
}

const { t, has } = useLocale()

/** The page's own ceilings, repeating Lua's rather than trusting the sender. */
const MAX_SYSTEMS = 12
const MAX_PIECES = 24
const MAX_GRADES = 8
const MAX_WORN = 40
const MAX_INVITEES = 8
const MAX_RUN = 6

type Mode = 'sitter' | 'desk' | 'invite' | 'notice'

const open = ref(false)
const mode = ref<Mode>('sitter')
const chairName = ref('')
const attended = ref(false)
const busy = ref(false)
const ready = ref(true)
const patientName = ref('')
const seated = ref(false)
const from = ref('')
const wallet = ref<number | null>(null)
const capacityUsed = ref(0)
const capacityMax = ref(0)
const capacityEnforced = ref(true)
const systems = ref<System[]>([])
const system = ref('')
const pieces = ref<Piece[]>([])
const detail = ref<Detail | null>(null)
const worn = ref<Worn[]>([])
const offer = ref<Offer | null>(null)
const invitees = ref<Invitee[]>([])
const inviteOut = ref('')
const flash = ref<Flash | null>(null)

let release: (() => void) | undefined
let noticeTimer: ReturnType<typeof setTimeout> | undefined

/* -- coercion: every list through `list()`, every number through `num()` -- */

function runOf(value: unknown): Stat[] {
  return list<Payload>(value)
    .slice(0, MAX_RUN)
    .map((row) => ({ key: text(row.key), value: num(row.value) }))
    .filter((row) => row.key !== '')
}

function fittedOf(value: unknown): Fitted | null {
  const raw = table(value)
  const grade = text(raw.grade)
  if (!grade) return null
  return {
    grade,
    points: clampPoints(raw.points),
    state: text(raw.state),
    broken: raw.broken === true,
    inBody: raw.pulled !== true,
    repair: num(raw.repair)
  }
}

function detailOf(value: unknown): Detail | null {
  const raw = table(value)
  const id = text(raw.id)
  if (!id) return null
  const grades: Grade[] = []
  for (const row of list<Payload>(raw.grades).slice(0, MAX_GRADES)) {
    const gradeId = text(row.id)
    if (!gradeId) continue
    grades.push({
      id: gradeId,
      name: text(row.name, gradeId),
      tier: num(row.tier, 1),
      price: num(row.price),
      cost: num(row.cost, num(row.price)),
      upgrade: row.upgrade === true,
      capacity: num(row.capacity),
      owned: row.owned === true,
      effects: runOf(row.effects),
      stats: runOf(row.stats),
      hack: text(row.hack),
      record: text(row.record),
      game: text(row.game)
    })
  }
  return {
    id,
    name: text(raw.name, id),
    desc: text(raw.desc),
    kind: text(raw.kind),
    system: text(raw.system),
    power: text(raw.power),
    iconic: raw.iconic === true,
    remove: num(raw.remove),
    unsold: raw.unsold === true,
    fitted: fittedOf(raw.fitted),
    grades
  }
}

/** Condition clamped to its own scale; an absent number reads as fresh. */
function clampPoints(value: unknown): number {
  return Math.max(0, Math.min(100, Math.round(num(value, 100))))
}

/**
 * Locale arguments, coerced: `t` takes strings or numbers, nothing else. An
 * argument that IS a catalogue key speaks the player's language (piece, grade
 * and system names and the reasons cross the wire as keys); anything else -- a
 * player name, a host reason -- passes through untouched.
 */
function vars(args: Record<string, unknown>): Record<string, string | number> {
  const out: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(args)) {
    if (typeof value === 'number') {
      out[name] = value
    } else {
      const raw = String(value ?? '')
      out[name] = has(raw) ? t(raw) : raw
    }
  }
  return out
}

function flashText(line: Flash | null): string {
  if (line === null) return ''
  const key = text(line.key)
  return key ? t(key, vars(line.args)) : ''
}

function flashOf(payload: Payload): Flash | null {
  const raw = table(payload.flash)
  const key = text(raw.key)
  return key ? { key, args: table(raw.args) } : null
}

/** The one offer, in the sentence its mode speaks. */
function offerText(row: Offer): string {
  const args = { name: t(row.name), grade: row.gradeName ? t(row.gradeName) : row.grade, price: row.price }
  if (row.mode === 'upgrade') return t('ripperdoc.offerUpgrade', args)
  if (row.mode === 'remove') return t('ripperdoc.offerPull', args)
  if (row.mode === 'repair') return t('ripperdoc.offerRepair', args)
  return t('ripperdoc.offerFit', args)
}

/** A tier range as the base game writes it. */
function tiersOf(row: Piece): string {
  return row.tierFrom === row.tierTo
    ? t('ripperdoc.tierOne', { from: row.tierFrom })
    : t('ripperdoc.tiers', { from: row.tierFrom, to: row.tierTo })
}

/** An effect as a line with its number, `noFall` as the words alone. */
function effectText(row: Stat): string {
  const value = Number.isInteger(row.value) ? row.value : Number(row.value.toFixed(2))
  return t('ripperdoc.effect.' + row.key, { value })
}

/** A stat in the units the grade carries it in. */
function statText(row: Stat): string {
  const label = t('ripperdoc.stat.' + row.key)
  if (row.key.endsWith('Ms')) return `${label} ${(row.value / 1000).toFixed(1)}S`
  return `${label} ${row.value}`
}

/** Ten ticks for a condition, earned on the left. */
function ticksOn(points: number): number {
  return Math.ceil(points / 10)
}

/* -- who may press what ---------------------------------------------------- */

/** The operator, at the desk with a patient in the chair. */
const operating = computed(() => mode.value === 'desk' && seated.value)

/** The patient, with nobody at the desk. */
const selfService = computed(() => mode.value === 'sitter' && !attended.value)

/** Whether any chrome control is live right now. */
const canAct = computed(() => (operating.value || selfService.value) && !busy.value && offer.value === null)

/** The body a platform implant needs cannot be read: those grades wait. */
function blockedByRecord(kind: string): boolean {
  return !ready.value && (kind === 'implant' || kind === 'ice')
}

const capacityTicks = computed(() => {
  const max = capacityMax.value
  if (max <= 0) return 0
  return Math.min(20, Math.ceil((capacityUsed.value / max) * 20))
})

const capacityFull = computed(() => capacityEnforced.value && capacityUsed.value >= capacityMax.value)

/* -- intents --------------------------------------------------------------- */

function blank(): void {
  open.value = false
  systems.value = []
  pieces.value = []
  detail.value = null
  worn.value = []
  offer.value = null
  invitees.value = []
  inviteOut.value = ''
  flash.value = null
  busy.value = false
  patientName.value = ''
  seated.value = false
  from.value = ''
  wallet.value = null
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
  else if (mode.value === 'invite') answerInvite(false)
}

function answerInvite(accept: boolean): void {
  emit('opx:ripperdoc:answer', { what: 'invite', accept })
}

function answerOffer(accept: boolean): void {
  if (offer.value === null) return
  emit('opx:ripperdoc:answer', { what: 'offer', accept, offer: offer.value.id })
}

function browseSystem(id: string): void {
  if (id !== system.value) emit('opx:ripperdoc:browse', { system: id })
}

function browsePiece(id: string): void {
  if (detail.value === null || id !== detail.value.id) emit('opx:ripperdoc:browse', { piece: id })
}

/** A fit or an upgrade, a pull or a repair, named by piece -- the price is the server's. */
function propose(grade: Grade | null, kind: 'install' | 'remove' | 'repair'): void {
  if (!canAct.value || detail.value === null) return
  emit('opx:ripperdoc:offer', {
    entry: detail.value.id,
    grade: grade === null ? '' : grade.id,
    mode: kind
  })
}

function invite(player: Invitee): void {
  emit('opx:ripperdoc:invite', { player: player.id })
}

/**
 * What a grade row says: FITTED or BROKEN for the one worn, UPGRADE for a
 * better one (priced with the worn grade traded in, as the offer will be), FIT
 * for anything else.
 */
function gradeVerb(grade: Grade, piece: Detail): string {
  if (grade.owned && piece.fitted !== null) {
    return piece.fitted.broken ? t('ripperdoc.broken') : t('ripperdoc.fitted')
  }
  const worn = piece.grades.find((row) => row.owned)
  if (grade.upgrade && worn !== undefined && grade.price > worn.price) {
    return t('ripperdoc.upgrade', { price: grade.cost })
  }
  return t('ripperdoc.fit', { price: grade.cost })
}

/**
 * The grade worn is never a fit: whole it is fitted, broken it is the repair
 * (or the refit) below -- a fit of it would charge the full price for the
 * same result.
 */
function gradePressable(grade: Grade, piece: Detail): boolean {
  if (!canAct.value || blockedByRecord(piece.kind)) return false
  // Off the shelf: nothing on this server can fit it, so only what the
  // patient already wears stays pressable (a pull or a mend is elsewhere).
  if (piece.unsold) return false
  return !(grade.owned && piece.fitted !== null)
}

/* -- the channel ----------------------------------------------------------- */

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
        const seen = table(payload.offer)
        const offerId = num(seen.id)
        const capacity = table(payload.capacity)
        mode.value = kind
        chairName.value = text(payload.name)
        attended.value = payload.attended === true
        busy.value = payload.busy === true
        ready.value = payload.ready === true
        patientName.value = text(payload.patientName)
        seated.value = kind === 'desk' ? payload.seated === true : kind === 'sitter'
        from.value = text(payload.from)
        wallet.value = kind === 'sitter' ? num(payload.wallet) : null
        capacityUsed.value = num(capacity.used)
        capacityMax.value = num(capacity.max)
        capacityEnforced.value = capacity.enforced !== false
        systems.value = list<Payload>(payload.systems)
          .slice(0, MAX_SYSTEMS)
          .map((row) => ({ id: text(row.id), used: num(row.used), slots: num(row.slots) }))
          .filter((row) => row.id !== '')
        system.value = text(payload.system)
        pieces.value = list<Payload>(payload.pieces)
          .slice(0, MAX_PIECES)
          .map((row) => ({
            id: text(row.id),
            name: text(row.name, text(row.id)),
            kind: text(row.kind),
            iconic: row.iconic === true,
            tierFrom: num(row.tierFrom, 1),
            tierTo: num(row.tierTo, num(row.tierFrom, 1)),
            priceFrom: num(row.priceFrom),
            fitted: text(row.fitted),
            points: clampPoints(row.points),
            state: text(row.state),
            broken: row.broken === true
          }))
          .filter((row) => row.id !== '')
        detail.value = detailOf(payload.detail)
        worn.value = list<Payload>(payload.worn)
          .slice(0, MAX_WORN)
          .map((row) => ({
            id: text(row.id),
            name: text(row.name, text(row.id)),
            state: text(row.state),
            points: clampPoints(row.points)
          }))
          .filter((row) => row.id !== '')
        invitees.value = list<Payload>(payload.invitees)
          .slice(0, MAX_INVITEES)
          .map((row) => ({ id: num(row.id), name: text(row.name) }))
          .filter((row) => row.id !== 0)
        inviteOut.value = text(table(payload.invite).name)
        offer.value =
          offerId > 0
            ? {
                id: offerId,
                mode: text(seen.mode),
                entry: text(seen.entry),
                grade: text(seen.grade),
                name: text(seen.name),
                gradeName: text(seen.gradeName),
                price: num(seen.price),
                by: text(seen.by)
              }
            : null
        flash.value = flashOf(payload)

        if (!open.value) {
          open.value = true
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
              <div class="op-eyebrow faint">
                {{ t('ripperdoc.title') }} · {{ t('ripperdoc.chair', { name: t(chairName) }) }}
              </div>
              <div class="op-label title">
                {{ mode === 'desk' ? t('ripperdoc.desk') : mode === 'invite' ? t('ripperdoc.title') : t('ripperdoc.tray') }}
              </div>
            </div>
            <div class="head-side">
              <div class="op-eyebrow faint">
                <template v-if="mode === 'desk'">
                  {{ seated ? t('ripperdoc.patient', { name: patientName }) : t('ripperdoc.vacant') }}
                </template>
                <template v-else-if="mode === 'invite'">{{ t('ripperdoc.invite', { from }) }}</template>
                <template v-else>{{ attended ? t('ripperdoc.attended') : t('ripperdoc.self') }}</template>
              </div>
              <div v-if="wallet !== null" class="op-value wallet">{{ t('ripperdoc.wallet', { amount: wallet }) }}</div>
            </div>
          </header>

          <!-- THE BODY'S LIMIT, as twenty ticks and the number. -->
          <div v-if="mode !== 'invite' && (mode === 'sitter' || seated)" class="capacity">
            <span class="op-eyebrow" :class="capacityFull ? 'hot' : 'faint'">
              {{ t('ripperdoc.capacity', { used: capacityUsed, max: capacityMax }) }}
            </span>
            <div class="ticks wide" :class="{ 'is-hot': capacityFull }" role="presentation">
              <i v-for="n in 20" :key="n" :class="{ on: n <= capacityTicks }"></i>
            </div>
          </div>

          <div class="rule"></div>

          <div v-if="!ready && (mode === 'sitter' || seated)" class="banner op-eyebrow">
            {{ t('ripperdoc.notReadyBanner') }}
          </div>
          <div v-if="flash !== null" class="flash op-copy">{{ flashText(flash) }}</div>

          <!-- THE OPTION TO SIT: accept and decline, and nothing else. -->
          <div v-if="mode === 'invite'" class="invite">
            <div class="op-copy">{{ t('ripperdoc.invite', { from }) }}</div>
            <div class="pair">
              <button type="button" class="act op-frame" data-augmented-ui="tr-clip border" @click="answerInvite(true)">
                {{ t('ripperdoc.accept') }}
              </button>
              <button type="button" class="act quiet op-frame" data-augmented-ui="tr-clip border" @click="answerInvite(false)">
                {{ t('ripperdoc.decline') }}
              </button>
            </div>
          </div>

          <!-- THE DESK WITH NOBODY IN THE CHAIR: offer the seat. -->
          <div v-else-if="mode === 'desk' && !seated" class="invitees">
            <div class="op-eyebrow faint">{{ t('ripperdoc.invitees') }}</div>
            <div v-if="inviteOut !== ''" class="op-eyebrow hot">{{ t('ripperdoc.inviteOut', { name: inviteOut }) }}</div>
            <div v-if="invitees.length === 0" class="op-copy faint">{{ t('ripperdoc.noInvitees') }}</div>
            <div v-for="row in invitees" :key="row.id" class="invitee">
              <span class="op-label who op-truncate">{{ row.name }}</span>
              <button
                type="button"
                class="act op-frame"
                data-augmented-ui="tr-clip border"
                :disabled="inviteOut !== ''"
                @click="invite(row)"
              >
                {{ t('ripperdoc.offerSeat') }}
              </button>
            </div>
          </div>

          <template v-else>
            <!-- The one offer at a time, framed so it owns the row. Only the
                 patient answers it; the desk reads it. -->
            <div v-if="offer !== null" class="offer op-frame is-on" data-augmented-ui="tr-clip border">
              <div class="offer-text">
                <div class="op-eyebrow hot">{{ offer.by ? t('ripperdoc.offer') : t('ripperdoc.offerSelf') }}</div>
                <div class="op-copy">{{ offerText(offer) }}</div>
              </div>
              <div v-if="mode === 'sitter'" class="pair">
                <button type="button" class="act op-frame" data-augmented-ui="tr-clip border" @click="answerOffer(true)">
                  {{ t('ripperdoc.accept') }}
                </button>
                <button type="button" class="act quiet op-frame" data-augmented-ui="tr-clip border" @click="answerOffer(false)">
                  {{ t('ripperdoc.decline') }}
                </button>
              </div>
            </div>
            <div v-else-if="busy" class="op-eyebrow faint">{{ t('ripperdoc.working') }}</div>

            <div class="body">
              <!-- THE BODY: every system with its slots. -->
              <nav class="systems">
                <button
                  v-for="row in systems"
                  :key="row.id"
                  type="button"
                  class="system op-frame"
                  :class="{ 'is-on': row.id === system }"
                  data-augmented-ui="tr-clip border"
                  @click="browseSystem(row.id)"
                >
                  <span class="op-eyebrow sys-name op-truncate">{{ t('ripperdoc.system.' + row.id) }}</span>
                  <span class="op-value slots" :class="{ full: row.used >= row.slots }">
                    {{ t('ripperdoc.slots', { used: row.used, slots: row.slots }) }}
                  </span>
                </button>
              </nav>

              <!-- THE SYSTEM: its pieces, what is worn first. -->
              <div class="pieces">
                <button
                  v-for="(row, index) in pieces"
                  :key="row.id"
                  type="button"
                  class="piece op-frame op-enter"
                  :class="{ 'is-on': detail !== null && row.id === detail.id }"
                  :style="{ '--op-slot': index }"
                  data-augmented-ui="tr-clip border"
                  @click="browsePiece(row.id)"
                >
                  <span class="piece-top">
                    <span class="piece-name op-truncate">{{ t(row.name) }}</span>
                    <span v-if="row.fitted !== ''" class="op-eyebrow" :class="row.broken ? 'hot' : 'faint'">
                      {{ t('ripperdoc.state.' + (row.broken ? 'broken' : row.state || 'optimal')) }}
                    </span>
                    <span v-else class="op-eyebrow cost">{{ t('ripperdoc.from', { price: row.priceFrom }) }}</span>
                  </span>
                  <span class="piece-meta op-eyebrow faint">
                    <span>{{ tiersOf(row) }}</span>
                    <span>{{ t('ripperdoc.kind.' + row.kind) }}</span>
                    <span v-if="row.iconic" class="hot">{{ t('ripperdoc.iconic') }}</span>
                  </span>
                  <span v-if="row.fitted !== ''" class="ticks" :class="{ 'is-broken': row.broken }" role="presentation">
                    <i v-for="n in 10" :key="n" :class="{ on: n <= ticksOn(row.points) }"></i>
                  </span>
                </button>
              </div>

              <!-- THE PIECE: its tiers, what each does here, its condition. -->
              <article v-if="detail !== null" class="detail">
                <div class="op-eyebrow faint">
                  {{ t('ripperdoc.system.' + detail.system) }} · {{ t('ripperdoc.kind.' + detail.kind) }}
                  <template v-if="detail.power !== ''"> · {{ t('ripperdoc.power.' + detail.power) }}</template>
                  <template v-if="detail.iconic"> · {{ t('ripperdoc.iconic') }}</template>
                </div>
                <div class="op-label detail-name">{{ t(detail.name) }}</div>
                <p v-if="detail.desc !== '' && has(detail.desc)" class="op-copy desc">{{ t(detail.desc) }}</p>
                <p v-if="detail.kind === 'rp'" class="op-copy faint">{{ t('ripperdoc.rpNote') }}</p>
                <p v-if="detail.unsold" class="op-copy faint">{{ t('ripperdoc.offShelf') }}</p>

                <!-- WHAT THE PATIENT WEARS OF IT: condition, and the bench. -->
                <div v-if="detail.fitted !== null" class="wear">
                  <div class="wear-line">
                    <span class="ticks" :class="{ 'is-broken': detail.fitted.broken }" role="presentation">
                      <i v-for="n in 10" :key="n" :class="{ on: n <= ticksOn(detail.fitted.points) }"></i>
                    </span>
                    <span class="op-eyebrow" :class="detail.fitted.broken ? 'hot' : 'faint'">
                      {{ detail.fitted.broken ? t('ripperdoc.broken') : t('ripperdoc.condition', { points: detail.fitted.points }) }}
                      · {{ t('ripperdoc.state.' + (detail.fitted.state || 'optimal')) }}
                    </span>
                  </div>
                  <div v-if="!detail.fitted.inBody" class="op-eyebrow hot">{{ t('ripperdoc.outOfBody') }}</div>
                  <div v-if="operating || selfService" class="pair">
                    <button
                      type="button"
                      class="act op-frame"
                      data-augmented-ui="tr-clip border"
                      :disabled="!canAct || blockedByRecord(detail.kind) || (!detail.fitted.broken && detail.fitted.points >= 100)"
                      @click="propose(null, 'repair')"
                    >
                      {{ detail.fitted.inBody ? t('ripperdoc.repair', { price: detail.fitted.repair }) : t('ripperdoc.refit', { price: detail.fitted.repair }) }}
                    </button>
                    <button
                      v-if="detail.fitted.inBody"
                      type="button"
                      class="act quiet op-frame"
                      data-augmented-ui="tr-clip border"
                      :disabled="!canAct || blockedByRecord(detail.kind)"
                      @click="propose(null, 'remove')"
                    >
                      {{ t('ripperdoc.pull', { price: detail.remove }) }}
                    </button>
                  </div>
                </div>

                <div class="grades">
                  <template v-for="grade in detail.grades" :key="grade.id">
                    <button
                      v-if="operating || selfService"
                      type="button"
                      class="grade op-frame"
                      :class="{ 'is-on': grade.owned }"
                      data-augmented-ui="tr-clip border"
                      :disabled="!gradePressable(grade, detail)"
                      @click="propose(grade, 'install')"
                    >
                      <span class="grade-top">
                        <span class="grade-name op-truncate">{{ t(grade.name) }}</span>
                        <span class="op-eyebrow faint">{{ t('ripperdoc.cap', { value: grade.capacity }) }}</span>
                        <span class="op-eyebrow cost">{{ gradeVerb(grade, detail) }}</span>
                      </span>
                      <span v-if="grade.effects.length > 0 || grade.stats.length > 0 || grade.hack !== ''" class="run op-eyebrow">
                        <span v-for="row in grade.effects" :key="'e' + row.key" class="effect">{{ effectText(row) }}</span>
                        <span v-if="grade.hack !== ''">{{ t('ripperdoc.hack.' + grade.hack) }}</span>
                        <span v-for="row in grade.stats" :key="'s' + row.key" class="faint">{{ statText(row) }}</span>
                      </span>
                      <span v-if="grade.record !== ''" class="rec op-eyebrow faint op-truncate">
                        {{ grade.game !== '' ? grade.game + ' · ' : '' }}{{ grade.record }}
                      </span>
                    </button>
                    <div v-else class="grade dark">
                      <span class="grade-top">
                        <span class="grade-name op-truncate">{{ t(grade.name) }}</span>
                        <span class="op-eyebrow faint">{{ t('ripperdoc.cap', { value: grade.capacity }) }}</span>
                        <span class="op-eyebrow cost">
                          {{ grade.owned ? t('ripperdoc.fitted') : t('ripperdoc.price', { price: grade.price }) }}
                        </span>
                      </span>
                      <span v-if="grade.effects.length > 0 || grade.stats.length > 0" class="run op-eyebrow">
                        <span v-for="row in grade.effects" :key="'e' + row.key" class="effect">{{ effectText(row) }}</span>
                        <span v-for="row in grade.stats" :key="'s' + row.key" class="faint">{{ statText(row) }}</span>
                      </span>
                      <span v-if="grade.record !== ''" class="rec op-eyebrow faint op-truncate">
                        {{ grade.game !== '' ? grade.game + ' · ' : '' }}{{ grade.record }}
                      </span>
                    </div>
                  </template>
                </div>
              </article>
            </div>

            <!-- EVERYTHING WORN, one strip: a click opens the piece. -->
            <div class="worn">
              <span class="op-eyebrow faint">{{ t('ripperdoc.fittedChrome') }}</span>
              <span v-if="worn.length === 0" class="op-copy faint">{{ t('ripperdoc.nothingFitted') }}</span>
              <button
                v-for="row in worn"
                :key="row.id"
                type="button"
                class="chip op-eyebrow"
                :class="{ hot: row.state === 'broken' || row.state === 'failing' }"
                @click="browsePiece(row.id)"
              >
                {{ t(row.name) }} {{ row.points }}%
              </button>
            </div>
          </template>

          <footer class="foot">
            <button
              v-if="mode !== 'invite'"
              type="button"
              class="act quiet op-frame"
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
/* Centred and unrotated (rule 5): a clinic menu is read head-on. */
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
  color: var(--op-red);
}

.unit {
  width: 1180px;
  max-width: 94vw;
  --aug-tl: var(--op-cut-lg);
  --aug-br: var(--op-cut-lg);
  background: var(--op-plate-quiet);
}

.unit-inner {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
  padding: var(--op-space-4) var(--op-space-4) var(--op-space-3);
  max-height: 88vh;
}

.faint {
  color: var(--op-text-faint);
}

.hot {
  color: var(--op-red-hi);
}

.head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: var(--op-space-4);
}

.head-side {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: var(--op-space-1);
}

.title {
  font-size: var(--op-fs-title);
}

.wallet {
  color: var(--op-red-text);
}

.capacity {
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
}

.rule {
  height: 1px;
  background: var(--op-line);
}

/* The record the implants need is not there: said once, in the alarm's own
   voice because it is the one thing on the page the player cannot fix by
   pressing something here. */
.banner {
  color: var(--op-alarm);
}

.flash {
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

.pair {
  display: flex;
  gap: var(--op-space-2);
}

.invitee {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op-space-3);
  padding-bottom: var(--op-space-2);
  border-bottom: 1px solid var(--op-line);
}

.who {
  font-size: var(--op-fs-label);
  color: var(--op-text);
}

.offer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-4);
  padding: var(--op-space-2) var(--op-space-3);
}

.offer-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

/* THREE COLUMNS: the body, the system, the piece. Each scrolls on its own so
   the header, the offer and the bench never leave the screen. */
.body {
  display: grid;
  grid-template-columns: 210px 330px minmax(0, 1fr);
  gap: var(--op-space-3);
  min-height: 0;
  flex: 1;
}

.systems,
.pieces,
.detail {
  display: flex;
  flex-direction: column;
  gap: 3px;
  max-height: 58vh;
  overflow-y: auto;
  min-width: 0;
}

.system {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op-space-2);
  padding: var(--op-space-2) var(--op-space-3);
  text-align: left;
  cursor: pointer;
}

.sys-name {
  color: var(--op-text);
}

.slots {
  color: var(--op-text-faint);
}

.slots.full {
  color: var(--op-red-hi);
}

.piece {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: var(--op-space-2) var(--op-space-3);
  text-align: left;
  cursor: pointer;
}

.piece-top,
.grade-top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op-space-2);
}

.piece-name,
.grade-name {
  flex: 1;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
}

.piece-meta {
  display: flex;
  gap: var(--op-space-2);
}

.cost {
  color: var(--op-red-text);
  white-space: nowrap;
}

.detail {
  gap: var(--op-space-2);
  padding-right: var(--op-space-1);
}

.detail-name {
  font-size: var(--op-fs-head);
  color: var(--op-text);
}

.desc {
  margin: 0;
  color: var(--op-text-dim);
}

.wear {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  padding: var(--op-space-2) 0;
  border-top: 1px solid var(--op-line);
  border-bottom: 1px solid var(--op-line);
}

.wear-line {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

/* WEAR AS TICKS: earned red on the left, spent line on the right; a broken
   piece burns at the hue's brightest (rule 4). */
.ticks {
  flex: 1;
  display: flex;
  gap: 3px;
  min-width: 80px;
}

.ticks i {
  flex: 1;
  height: 2px;
  background: var(--op-line);
}

.ticks i.on {
  background: var(--op-red);
}

.ticks.is-broken i.on,
.ticks.is-hot i.on {
  background: var(--op-red-hi);
}

.ticks.wide {
  max-width: 360px;
}

.grades {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.grade {
  display: flex;
  flex-direction: column;
  gap: 3px;
  width: 100%;
  padding: var(--op-space-2) var(--op-space-3);
  text-align: left;
  cursor: pointer;
}

.grade:disabled {
  cursor: default;
  opacity: 0.7;
}

.grade.is-on .grade-name {
  color: var(--op-red-hi);
}

/* A row the player cannot act on is a readout: no frame (rule 2). */
.grade.dark {
  cursor: default;
  border-bottom: 1px solid var(--op-line);
}

.grade.dark .grade-name {
  color: var(--op-text-faint);
}

.run {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-1) var(--op-space-3);
}

.effect {
  color: var(--op-red-text);
}

/* The base game's own record for a grade, and what the game calls it. */
.rec {
  display: block;
  max-width: 100%;
  letter-spacing: 0.04em;
  text-transform: none;
}

.worn {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: var(--op-space-1) var(--op-space-3);
  padding-top: var(--op-space-2);
  border-top: 1px solid var(--op-line);
}

/* A worn piece is a link into the tray, not a control that changes chrome:
   a line of type, no frame (rule 2). */
.chip {
  background: none;
  border: 0;
  padding: 0;
  color: var(--op-text);
  cursor: pointer;
}

.chip.hot {
  color: var(--op-red-hi);
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

.act:disabled {
  cursor: default;
  opacity: 0.55;
}

.act.quiet {
  color: var(--op-text);
}

.foot {
  display: flex;
  justify-content: flex-end;
}
</style>
