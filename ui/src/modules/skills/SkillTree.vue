<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE SKILL TREE -- three trunks of job work, fifteen nodes, and the one
 * currency a level banks.
 *
 * IT DECIDES NOTHING, the way no view here does. Which trunks exist, how deep
 * each has been fed, which nodes are yours and what a press would cost all
 * arrive from the server; this page draws the frame and reports presses. An
 * unlock is an INTENT (`skills:spend`) and the tree only redraws when a fresh
 * frame comes back -- a node bought in the page would be a second authority
 * over one fact.
 *
 * STOWING IS AN INTENT TOO. Escape and the close control both ask
 * (`skills:close`); the panel goes down when the close comes back on
 * `skills:view`, exactly as the scanner waits for its own.
 *
 * -- DESIGN, per ui/README.md --
 *
 * CENTRED, so there is NO TILT: rotating a centred plane about its middle is
 * paper on a spindle, not a surface receding (rule 5).
 *
 * A NODE THE WORK HAS NOT REACHED IS A READOUT, NOT A CONTROL (rule 2): it
 * gets no frame -- just a dim row that STATES ITS REQUIREMENT. It is still
 * pressable, because a readout you cannot ask about is half a readout: a press
 * INSPECTS (the detail strip answers with what it does and why it is closed)
 * and never offers the unlock. The unlock is the one control, and it is only
 * ever on a node the server called `available`.
 *
 * EVERY MICRO-LABEL STATES A REAL NUMBER (rule 8): trunk ordinals, each trunk's
 * `RANK 2/5` AND its own XP into the trunk (`45/100 INTO THIS TRUNK`, the
 * server's step under it), the node ordinals and point costs, the perk's value
 * in the detail strip, and the header's level, XP, points and claimed count.
 * The rank RINGS in each trunk head are that same rank, drawn.
 *
 * THE HEADER STATES WHAT THE FRAME HOLDS. The claimed count is counted off the
 * frame's own node states -- `NODES 04/15` is fifteen declared nodes and four
 * of them yours, and nothing on this surface is a number the frame did not
 * carry or the page cannot count off it.
 *
 * FRESHNESS IS THE HUE'S LUMINANCE DESCENT (rule 4): the ledger strip's newest
 * line is the voice at full (`--op-red`) when it is news a player looks up for
 * -- a level, a node claimed -- and work credited settles at `--op-text-dim`.
 * Alarm is deliberately not spent on the tree -- the tree is never an alarm.
 *
 * THE ENTRANCE IS THE STAGGER, ON THE ROWS A FRESH FRAME CREATED (`.op-enter`
 * with `--op-slot`): the whole content mounts with `open`, so every plate
 * slides in on a schedule instead of the panel fading as one block. `fresh`
 * from the state half means the tree just opened -- a fresh frame also sweeps
 * the detail strip clean, so a panel reopened never shows the last session's
 * pick.
 */

interface Node {
  id: string
  /** Locale KEYs, never sentences -- the page holds no English. */
  name: string
  desc: string
  perk: string
  value: number
  cost: number
  state: 'unlocked' | 'available' | 'locked'
  /** For a locked node: the locale key of the requirement it states. */
  why: string
}

interface Branch {
  id: string
  name: string
  rank: number
  /** XP into this trunk's CURRENT rank step, below `need`. */
  xp: number
  /** The trunk's step -- the denominator of the gauge this page draws. */
  need: number
  nodes: Node[]
}

interface Line {
  key: string
  args: Record<string, unknown>
  level: number
  points: number
}

const { t } = useLocale()

/** The page's own ceilings, repeating Lua's rather than trusting the sender. */
const MAX_NODES = 8
/** A press nobody can spend through twice: the double-click's own ceiling. */
const SPEND_DEDUPE_MS = 300

const open = ref(false)
const level = ref(1)
const xp = ref(0)
const need = ref(1)
const points = ref(0)
const depth = ref(1)
const branches = ref<Branch[]>([])
/** The stow cap says what the player's OWN binding says; Lua resolved it. */
const keycap = ref('F3')
/** The node under inspection -- the detail strip's whole content. */
const picked = ref<{ branch: Branch; node: Node } | null>(null)
/** The newest line the ledger fed us, for the strip under the header. */
const gain = ref<Line | null>(null)
/** When the last spend left this page, for the dedupe above it. */
let lastSpend = 0

let release: (() => void) | undefined

const levelText = computed(() => String(level.value).padStart(2, '0'))

/** Level progress as the header's thin gauge. One stroke, no second hue. */
const gauge = computed(() => {
  const cap = Math.max(1, need.value)
  const into = Math.min(Math.max(0, xp.value), cap)
  return `${((into / cap) * 100).toFixed(1)}%`
})

/** The claimed count the header states -- counted off the frame's own rows. */
const claimed = computed(() => {
  let have = 0
  for (const branch of branches.value) {
    for (const node of branch.nodes) if (node.state === 'unlocked') have += 1
  }
  return have
})

const totalNodes = computed(() =>
  branches.value.reduce((sum, branch) => sum + branch.nodes.length, 0)
)

/** One trunk's step toward its next rank, as the gauge draws it. */
function trunkGauge(branch: Branch): string {
  const cap = Math.max(1, branch.need)
  const into = Math.min(Math.max(0, branch.xp), cap)
  return `${((into / cap) * 100).toFixed(1)}%`
}

/** Locale arguments, coerced: `t` takes strings or numbers, nothing else. */
function vars(args: Record<string, unknown>): Record<string, string | number> {
  const out: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(args)) {
    out[name] = typeof value === 'number' ? value : String(value ?? '')
  }
  return out
}

function count(at: number): string {
  return String(at).padStart(2, '0')
}

/** A value as the detail strip states it: a sign, then the number. */
function signed(value: number): string {
  return value >= 0 ? `+${value}` : String(value)
}

/** The ledger's strip: a level or a node is news to look up for (full hue);
 *  work credited settles at dim. */
function gainWords(line: Line): string {
  return line.level > 0
    ? t('skills.gain.level', { level: line.level, points: line.points })
    : t(line.key, vars(line.args))
}

function blank(): void {
  open.value = false
  branches.value = []
  picked.value = null
  gain.value = null
  release?.()
  release = undefined
}

/** The one intent: a node and nothing else -- what it costs is the server's.
 *  Deduped like every press here: one press-release pair is one spend, however
 *  many events the pointer model makes of it. */
function spend(node: Node): void {
  if (!open.value || node.state !== 'available') return
  const now = Date.now()
  if (now - lastSpend < SPEND_DEDUPE_MS) return
  lastSpend = now
  emit('opx:skills:spend', { node: node.id })
}

function stow(): void {
  if (!open.value) return
  emit('opx:skills:close', {})
}

/** Inspecting is not deciding: every node opens the detail strip, and the
 *  locked one answers with its requirement instead of an unlock. */
function select(branch: Branch, node: Node): void {
  if (!open.value) return
  picked.value = { branch, node }
}

useBridge('opx:skills:view', (payload: Payload) => {
  guard(
    'skills:view',
    () => {
      const kind = text(payload.kind)

      if (kind === 'frame') {
        const frame = table(payload.frame)
        const rows: Branch[] = []
        for (const entry of list<Payload>(frame.branches)) {
          const id = text(entry.id)
          if (!id) continue
          const nodes: Node[] = []
          for (const raw of list<Payload>(entry.nodes).slice(0, MAX_NODES)) {
            const nodeId = text(raw.id)
            if (!nodeId) continue
            const state = text(raw.state)
            nodes.push({
              id: nodeId,
              name: text(raw.name, nodeId),
              desc: text(raw.desc),
              perk: text(raw.perk),
              value: num(raw.value),
              cost: num(raw.cost, 1),
              state:
                state === 'unlocked' || state === 'available' ? state : 'locked',
              why: text(raw.why)
            })
          }
          rows.push({
            id,
            name: text(entry.name, id),
            rank: num(entry.rank, 1),
            xp: num(entry.xp),
            need: Math.max(1, num(entry.need, 100)),
            nodes
          })
        }
        // Nothing to draw is not a tree: Lua only answers with the trunks the
        // config declares, so this is a frame that lost its contents.
        if (rows.length === 0) return

        branches.value = rows
        level.value = Math.max(1, num(frame.level, 1))
        xp.value = num(frame.xp)
        need.value = Math.max(1, num(frame.need, 1))
        points.value = Math.max(0, num(frame.points))
        depth.value = Math.max(1, num(frame.depth, 1))
        keycap.value = text(payload.key, 'F3')

        // A FRESH frame sweeps the strip clean before it draws: a tree that
        // just opened shows the tree, not whatever the last one left picked.
        const fresh = bool(payload.fresh)
        if (fresh) {
          picked.value = null
          gain.value = null
        }

        if (!open.value) {
          open.value = true
          release?.()
          release = acquireFocus({
            id: 'skills.tree',
            // Escape stows it -- the tree is a chart, not a decision, so
            // leaving is always allowed.
            onEscape: () => stow()
          })
        }

        // A pick the frame no longer supports falls back to nothing; one the
        // frame still holds is rebound to the FRESH rows, state and all, so
        // the detail strip never reads a stale frame.
        const held = picked.value
        if (held !== null) {
          const branch = rows.find((candidate) => candidate.id === held.branch.id)
          const node = branch?.nodes.find((candidate) => candidate.id === held.node.id)
          picked.value = branch !== undefined && node !== undefined ? { branch, node } : null
        }
        return
      }

      if (kind === 'gain') {
        const entry = table(payload.line)
        const key = text(entry.key)
        if (!key) return
        gain.value = { key, args: table(entry.args), level: num(entry.level), points: num(entry.points) }
        return
      }

      // `close` and anything this does not know: the reason is Lua's and it has
      // already said it. This page only takes the panel down.
      blank()
    },
    undefined
  )
})

onUnmounted(() => {
  release?.()
})
</script>

<template>
  <div class="room op-ink" :class="{ open }">
    <div v-if="open" class="tree op-plane">
      <div class="unit op-bay op-arete op-interlace" data-augmented-ui="tl-clip br-clip border">
        <div class="unit-inner">
          <header class="head">
            <div class="head-text">
              <div class="op-eyebrow">
                {{ t('skills.title') }} · {{ count(branches.length) }} BR ·
                {{ t('skills.claimed', { have: count(claimed), of: count(totalNodes) }) }}
              </div>
              <div class="op-value title">{{ t('skills.level', { level: levelText }) }}</div>
            </div>
            <div class="head-read">
              <div class="gauge-track">
                <div class="gauge-fill" :style="{ width: gauge }"></div>
              </div>
              <div class="op-eyebrow readouts">
                <span>{{ t('skills.xp', { xp, need }) }}</span>
                <span class="pts">{{ t('skills.points', { points }) }}</span>
              </div>
            </div>
          </header>

          <div class="rule"></div>

          <div v-if="gain" class="gain" :class="{ hot: gain.level > 0 || gain.key === 'skills.gain.node' }">
            <span class="op-eyebrow tag">{{ gainWords(gain) }}</span>
          </div>

          <div class="branches">
            <section
              v-for="(branch, bi) in branches"
              :key="branch.id"
              class="branch op-enter"
              :style="{ '--op-slot': bi }"
            >
              <div class="branch-head">
                <span class="op-eyebrow ord">{{ count(bi + 1) }}</span>
                <span class="branch-name op-truncate">{{ t(branch.name) }}</span>
                <span class="rungs" aria-hidden="true">
                  <span
                    v-for="r in branch.nodes.length"
                    :key="r"
                    class="rung"
                    :class="{ on: r <= branch.rank }"
                  ></span>
                </span>
                <span class="op-eyebrow rank">{{ t('skills.trunkRank', { rank: count(branch.rank), depth: count(branch.nodes.length) }) }}</span>
              </div>
              <div class="branch-xp">
                <div class="trunk-track">
                  <div class="trunk-fill" :style="{ width: trunkGauge(branch) }"></div>
                </div>
                <span class="op-eyebrow trunk-read">
                  {{ t('skills.branchXp', { xp: Math.round(branch.xp), need: branch.need }) }}
                </span>
              </div>
              <div class="chain">
                <template v-for="(node, ni) in branch.nodes" :key="node.id">
                  <div class="link" :class="{ lit: node.state !== 'locked' }"></div>
                  <button
                    type="button"
                    class="node op-enter"
                    :class="{
                      dark: node.state === 'locked',
                      'is-on': node.state === 'unlocked',
                      'is-picked': picked?.node.id === node.id
                    }"
                    :data-augmented-ui="node.state === 'locked' ? undefined : 'tr-clip border'"
                    :style="{ '--op-slot': Math.min(8, ni + 1) }"
                    @click="select(branch, node)"
                  >
                    <span class="op-eyebrow ord">{{ count(ni + 1) }}</span>
                    <span class="mark" :class="node.state" aria-hidden="true"></span>
                    <span class="node-name op-truncate">{{ t(node.name) }}</span>
                    <span v-if="node.state !== 'locked'" class="op-eyebrow cost">{{ node.cost }} PT</span>
                    <span v-else class="op-eyebrow why op-truncate">{{ t(node.why) }}</span>
                  </button>
                </template>
              </div>
            </section>
          </div>

          <div class="rule"></div>

          <div class="detail">
            <template v-if="picked">
              <div class="detail-text">
                <div class="op-eyebrow perk">
                  {{ picked.node.perk }} · {{ signed(picked.node.value) }} · {{ picked.node.cost }} PT
                </div>
                <div class="op-label detail-name">{{ t(picked.node.name) }}</div>
                <div class="op-copy">{{ t(picked.node.desc, { value: picked.node.value }) }}</div>
                <div v-if="picked.node.state !== 'available'" class="op-copy held">
                  {{ picked.node.state === 'locked' ? t(picked.node.why) : t('skills.unlocked') }}
                </div>
              </div>
              <button
                v-if="picked.node.state === 'available'"
                type="button"
                class="spend op-frame"
                data-augmented-ui="tr-clip border"
                @click="spend(picked.node)"
              >
                {{ t('skills.spend', { cost: picked.node.cost }) }}
              </button>
            </template>
            <div v-else class="op-copy empty">{{ t('skills.detail') }}</div>
          </div>

          <footer class="foot">
            <button type="button" class="stow op-frame" data-augmented-ui="tr-clip border" @click="stow()">
              {{ t('skills.stow', { key: keycap }) }}
            </button>
          </footer>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Centred and unrotated (rule 5): a chart read head-on, not a device held up
   at an angle. Wide enough for three trunks side by side, each with its own
   head, its gauge and five plates down the chain. */
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

.unit {
  width: 980px;
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

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
}

.head .op-eyebrow {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.title {
  font-family: var(--op-font-display);
  font-size: var(--op-fs-title);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
}

.head-read {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  min-width: 260px;
}

/* The gauge is the HUD's own: one thin stroke brightening across a track, the
   fill being the voice and nothing louder. */
.gauge-track {
  height: 4px;
  background: var(--op-line);
}

.gauge-fill {
  height: 100%;
  background: var(--op-red);
  transition: width var(--op-dur) var(--op-ease);
}

.readouts {
  display: flex;
  justify-content: space-between;
  gap: var(--op-space-3);
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.readouts .pts {
  color: var(--op-red-text);
}

.rule {
  height: 1px;
  background: var(--op-line);
}

/* The ledger's newest word, one line. A LEVEL OR A CLAIMED NODE is the news a
   player looks up for (it earned the voice); work credited settles at dim. */
.gain {
  min-height: 12px;
}

.gain .tag {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-dim);
}

.gain.hot .tag {
  color: var(--op-red);
}

.branches {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: var(--op-space-4);
  align-items: start;
}

.branch-head {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin-bottom: var(--op-space-2);
}

.branch-head .ord,
.branch-head .rank {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
}

.branch-name {
  flex: 1;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-lead);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
  color: var(--op-text);
}

/* The rank, DRAWN: one ring per node the trunk declares, lit to the rank the
   work has earned. The text beside it says the same number -- rule 8 twice. */
.rungs {
  display: flex;
  gap: 3px;
}

.rung {
  width: 8px;
  height: 3px;
  background: var(--op-line);
}

.rung.on {
  background: var(--op-red-idle);
}

/* The trunk's own gauge: what this rank's step has filled of its step. */
.branch-xp {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin-bottom: var(--op-space-3);
}

.trunk-track {
  flex: 1;
  height: 3px;
  background: var(--op-line);
}

.trunk-fill {
  height: 100%;
  background: var(--op-red-idle);
  transition: width var(--op-dur) var(--op-ease);
}

.trunk-read {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
  white-space: nowrap;
}

.chain {
  display: flex;
  flex-direction: column;
}

/* The chain's spine: lit where the work has reached, one rung per node. */
.link {
  align-self: center;
  width: 1px;
  height: 12px;
  background: var(--op-line);
}

.link.lit {
  background: var(--op-red-idle);
}

.node {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  width: 100%;
  padding: var(--op-space-2) var(--op-space-3);
  text-align: left;
  cursor: pointer;
}

.node .ord,
.node .cost,
.node .why {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-text-faint);
  white-space: nowrap;
}

/* The state, drawn as one mark: claimed is a filled square, reachable an open
   one, and a node the work has not reached is a dash. */
.mark {
  width: 6px;
  height: 6px;
  flex: none;
  border: 1px solid var(--op-red-text);
}

.mark.unlocked {
  background: var(--op-red);
  border-color: var(--op-red);
}

.mark.locked {
  height: 1px;
  border: none;
  background: var(--op-text-faint);
}

.node-name {
  flex: 1;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
}

.node.is-on .node-name {
  color: var(--op-red-hi);
}

.node.is-on .ord {
  color: var(--op-red-text);
}

.node.is-on .mark {
  box-shadow: 0 0 5px var(--op-red-glow);
}

.node.is-picked {
  --aug-border-bg: var(--op-red-hi);
}

/* A locked node is a readout: no frame at all (rule 2), one dim rule under it,
   and the row STATES ITS REQUIREMENT rather than sitting mute and grey
   (rule 8). It still inspects -- a press opens the detail strip -- so it is a
   button wearing a readout's clothes. */
.node.dark {
  border-bottom: 1px solid var(--op-line);
}

.node.dark .node-name {
  color: var(--op-text-faint);
}

.node.dark.is-picked .node-name,
.node.dark.is-picked .why {
  color: var(--op-text-dim);
}

.node.dark.is-picked {
  border-bottom-color: var(--op-red-idle);
}

.detail {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-4);
  min-height: 76px;
}

.detail-text {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.perk {
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red-text);
}

.detail-name {
  text-transform: uppercase;
  letter-spacing: var(--op-track-lead);
}

/* The state a node is in, said in a sentence the locale owns: what a locked
   node requires, or that a claimed one is already yours. */
.held {
  color: var(--op-text-dim);
}

.empty {
  color: var(--op-text-faint);
}

.spend {
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red-hi);
  cursor: pointer;
  white-space: nowrap;
}

.foot {
  display: flex;
  justify-content: flex-end;
}

.stow {
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
  cursor: pointer;
}
</style>
