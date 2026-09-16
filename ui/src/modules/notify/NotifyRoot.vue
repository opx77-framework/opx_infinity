<script setup lang="ts">
import { onMounted, onUnmounted, ref, shallowRef } from 'vue'
import OpToast from '@/design/components/OpToast.vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * TOASTS -- the port of `opx77_notify/web/{index.html,notify.js,notify.css}`.
 *
 * THE PAGE OWNS THE CLOCK, and that is not a style choice here: `core/client/notify.lua`
 * has no expiry loop at all. It raises a toast carrying its whole lifetime, keeps the id
 * so it can address the toast later, and waits for this page to say the toast has gone.
 * If this module never emits `notify:gone`, Lua's `live` table grows for the session and
 * a dismiss aimed at a toast that left the screen minutes ago does nothing.
 *
 * WHY A TIMER AND NOT `requestAnimationFrame`, which is what notify.js used: rAF is
 * paced by painting, and a CEF surface that is throttled or not compositing stops
 * painting. Under notify.js that only stalled a progress bar, because Lua was counting
 * too and Lua removed the toast. Here a stalled clock is a toast that never expires and
 * never reports, so the countdown runs on a timer, which fires whether or not the
 * surface drew.
 *
 * WHY `useCountdown` IS NOT USED: it is display-only by contract -- it deliberately does
 * not fire a callback at zero, because a countdown on this platform is normally a smooth
 * animation of a deadline the server is also counting. This one IS the authority, so it
 * needs the one thing that composable refuses to do.
 */
const { t } = useLocale()

type Kind = 'info' | 'success' | 'warning' | 'error'

/** The platform's seven, and only those. notify.js `POSITIONS`. */
type Position =
  | 'top_left'
  | 'top_center'
  | 'top_right'
  | 'middle_left'
  | 'bottom_left'
  | 'bottom_center'
  | 'bottom_right'

const POSITIONS: Position[] = [
  'top_left',
  'top_center',
  'top_right',
  'middle_left',
  'bottom_left',
  'bottom_center',
  'bottom_right'
]

const KINDS: readonly string[] = ['info', 'success', 'warning', 'error']

/** The page's own ceilings, repeating Lua's rather than trusting the sender for them. */
const MAX_PER_STACK = 8
const MAX_TOTAL = 32

/** How long a leaving toast stays mounted. Must be >= --op77-dur-slow (220ms). */
const EXIT_MS = 260

/** 20 Hz. The bar is 2px of width; under the surface's 30fps and smooth enough for it. */
const TICK_MS = 50

const DEFAULT_MS = 5000

interface Toast {
  id: string
  kind: Kind
  title: string
  message: string
  icon: string
  position: Position
  /** 0 is a PERSISTENT toast: no bar, no expiry, and no `notify:gone` ever. */
  durationMs: number
  /** Epoch ms, or 0 when persistent. This page's own arithmetic from arrival onwards. */
  endsAt: number
  /** Whether a lifetime bar was asked for at all -- notify.js `row.progress`. */
  bar: boolean
  /** 0..1, or -1 for "draw no bar", which is what OpToast reads. */
  progress: number
  /** On its way out: still mounted so the exit transition can run. */
  out: boolean
}

/**
 * Replaced wholesale, never mutated in place. A `shallowRef` over plain objects costs one
 * dependency for the whole stack instead of one per field per toast, and there is nothing
 * here a deep proxy would buy: no descendant ever writes to a toast.
 */
const toasts = shallowRef<Toast[]>([])

/** notify.js `settings.position` -- where a toast with no position of its own lands. */
const fallbackPosition = ref<Position>('top_right')
const width = ref(340)

/** The player is down: the stacks go off screen and EVERY CLOCK KEEPS RUNNING. */
const down = ref(false)

let timer: ReturnType<typeof setInterval> | undefined

function positionOf(value: unknown, fallback: Position): Position {
  const name = text(value)
  return POSITIONS.indexOf(name as Position) === -1 ? fallback : (name as Position)
}

function kindOf(value: unknown): Kind {
  const name = text(value, 'info')
  return KINDS.indexOf(name) === -1 ? 'info' : (name as Kind)
}

/** The toasts of one stack, in arrival order. Bottom stacks reverse in CSS. */
function at(position: Position): Toast[] {
  return toasts.value.filter((toast) => toast.position === position)
}

function liveCount(): number {
  let count = 0
  for (const toast of toasts.value) if (!toast.out) count += 1
  return count
}

/**
 * Starts a toast leaving and, after the transition, unmounts it.
 *
 * `report` decides whether Lua hears about it. A toast that ran out of time, or that this
 * page evicted to stay under its ceiling, is one Lua is still holding an id for and must
 * be told about. A dismiss or a clear came FROM Lua, which has already forgotten it --
 * reporting those back would be an echo.
 */
function leave(id: string, report: boolean): void {
  const toast = toasts.value.find((entry) => entry.id === id)
  if (!toast || toast.out) return

  toasts.value = toasts.value.map((entry) =>
    entry.id === id ? { ...entry, out: true, progress: -1 } : entry
  )
  if (report) emit('opx:notify:gone', { id })

  window.setTimeout(() => {
    toasts.value = toasts.value.filter((entry) => entry.id !== id || !entry.out)
  }, EXIT_MS)
}

/** Unmounts immediately, with no exit transition. The eviction path only. */
function evict(position: Position): void {
  const oldest = toasts.value.find((toast) => toast.position === position && !toast.out)
  if (!oldest) return
  // Told to Lua: it is holding this id, and from here on nothing can address it.
  emit('opx:notify:gone', { id: oldest.id })
  toasts.value = toasts.value.filter((toast) => toast !== oldest)
}

/** Builds the record a payload describes, over `previous` when this is a patch. */
function build(payload: Payload, previous: Toast | undefined): Toast {
  const durationMs = Math.max(
    0,
    Math.round(num(payload.durationMs, previous ? previous.durationMs : DEFAULT_MS))
  )

  // A patch that does not change the lifetime keeps the deadline the toast already had.
  // Without this, a caller updating a progress line once a second restarts the bar once a
  // second and the toast never expires.
  const sameLife = previous !== undefined && previous.durationMs === durationMs
  let endsAt = sameLife ? previous.endsAt : 0
  if (durationMs === 0) {
    endsAt = 0
  } else if (!sameLife || typeof payload.remainingMs === 'number') {
    // `remainingMs` is how a toast held before this page was ready resumes mid-life
    // instead of starting a full bar and vanishing before it has emptied.
    const left = Math.max(0, Math.min(durationMs, num(payload.remainingMs, durationMs)))
    endsAt = Date.now() + left
  }

  // A persistent toast has no lifetime to draw, whatever the caller asked for.
  const bar = durationMs > 0 && payload.progress !== false && (previous ? previous.bar : true)

  return {
    id: text(payload.id),
    kind: payload.kind === undefined && previous ? previous.kind : kindOf(payload.kind),
    // A locale KEY or the sentence Lua already resolved: `t` returns anything it does not
    // know unchanged, so both spellings pass through the same call.
    title: payload.title === undefined && previous ? previous.title : t(text(payload.title)),
    message:
      payload.message === undefined && previous ? previous.message : t(text(payload.message)),
    icon: payload.icon === undefined && previous ? previous.icon : text(payload.icon).slice(0, 16),
    position: positionOf(payload.position, previous ? previous.position : fallbackPosition.value),
    durationMs,
    endsAt,
    bar,
    progress: bar ? 1 : -1,
    out: false
  }
}

/**
 * Draws a new toast or redraws a known one.
 *
 * `notify:update` lands here too, exactly as notify.js folded `notify:add` and
 * `notify:update` into one `add`: a page that reloaded mid-session does not know the id
 * an update names, and refusing it would lose the toast rather than redraw it.
 */
function put(payload: Payload): void {
  const id = text(payload.id)
  if (!id) return

  const previous = toasts.value.find((toast) => toast.id === id && !toast.out)
  const next = build(payload, previous)

  if (previous) {
    // Replaced in place: same index in the stack, same element, so the entrance animation
    // does not replay under a caller that patches once a second.
    toasts.value = toasts.value.map((toast) => (toast === previous ? next : toast))
    pump()
    return
  }

  // Reaching Lua's own ceiling means something other than Lua is talking to this page.
  if (liveCount() >= MAX_TOTAL) return
  if (at(next.position).filter((toast) => !toast.out).length >= MAX_PER_STACK) {
    evict(next.position)
  }
  toasts.value = [...toasts.value, next]
  pump()
}

/** One pass: every bar's remainder, and every deadline that has come due. */
function tick(): void {
  const atMs = Date.now()
  const expired: string[] = []
  let running = false
  let changed = false

  const next = toasts.value.map((toast) => {
    if (toast.out || toast.endsAt === 0) return toast
    const left = Math.max(0, Math.min(1, (toast.endsAt - atMs) / toast.durationMs))
    if (left <= 0) {
      expired.push(toast.id)
      return toast
    }
    running = true
    if (!toast.bar) return toast
    // A bar is 2px tall: redrawing for a change smaller than a screen pixel is work
    // nobody can see, twenty times a second, for as long as a toast is up.
    if (Math.abs(left - toast.progress) < 0.002) return toast
    changed = true
    return { ...toast, progress: left }
  })

  if (changed) toasts.value = next
  // `leave` rewrites the array itself, so it runs after the map and never inside it.
  for (const id of expired) leave(id, true)
  if (!running && expired.length === 0) stop()
}

function pump(): void {
  if (timer !== undefined) return
  // A throw inside a timer is not a throw inside a bridge handler: channel.ts is not
  // above it, and nothing else would ever report it.
  timer = setInterval(() => guard('notify tick', tick, undefined), TICK_MS)
}

function stop(): void {
  if (timer === undefined) return
  clearInterval(timer)
  timer = undefined
}

useBridge('opx:notify:config', (payload: Payload) => {
  fallbackPosition.value = positionOf(payload.position, fallbackPosition.value)
  const wanted = num(payload.width)
  if (wanted > 0) width.value = Math.round(wanted)
})

useBridge('opx:notify:show', put)
useBridge('opx:notify:update', put)

useBridge('opx:notify:dismiss', (payload: Payload) => {
  // No `notify:gone`: this came from Lua, which has already dropped the id.
  leave(text(payload.id), false)
})

useBridge('opx:notify:clear', () => {
  for (const toast of toasts.value) leave(toast.id, false)
})

useBridge('opx:notify:down', (payload: Payload) => {
  down.value = payload.down === true
})

onMounted(() => {
  // An INTENT: "this module is mounted and bound". Lua decides whether to replay what it
  // is holding. Per module and not per surface, because ModuleHost can remount a module
  // long after the surface announced itself.
  emit('opx:notify:ready', {})
})

onUnmounted(stop)
</script>

<template>
  <div class="notify" :class="{ down }" :style="{ '--toast-width': width + 'px' }">
    <div v-for="position in POSITIONS" :key="position" class="stack" :class="position">
      <!-- A wrapper per toast rather than classes on OpToast itself: the entrance and the
           exit move `transform`, and OpToast's root carries `filter: drop-shadow` from
           `.op-lift`. Transforming the element a filter sits on re-rasterises the filter
           on every frame of the move. -->
      <div v-for="toast in at(position)" :key="toast.id" class="entry" :class="{ out: toast.out }">
        <OpToast
          :kind="toast.kind"
          :title="toast.title"
          :message="toast.message"
          :icon="toast.icon"
          :progress="toast.progress"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
.notify {
  position: absolute;
  inset: 0;
}

/* The player is down. `visibility`, not `display`: a node taken out of layout replays its
   entrance animation when it comes back, and every clock under here is still running, so
   what comes back is what is still due. */
.down .stack {
  visibility: hidden;
}

.stack {
  position: fixed;
  display: flex;
  flex-direction: column;
  gap: var(--op77-space-2);
  width: var(--toast-width, 340px);
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}

.top_left,
.top_center,
.top_right {
  top: var(--op77-inset-y);
}

/* Bottom stacks grow upward, so the newest toast is nearest the edge. DOM order is the
   same in every stack, so nothing in script has to know which way one grows. */
.bottom_left,
.bottom_center,
.bottom_right {
  bottom: var(--op77-inset-y);
  flex-direction: column-reverse;
}

.top_left,
.bottom_left,
.middle_left {
  left: var(--op77-inset-x);
}

.top_right,
.bottom_right {
  right: var(--op77-inset-x);
}

.top_center,
.bottom_center {
  left: 50%;
  transform: translateX(-50%);
}

/* The one position with no vertical partner in the platform's set. */
.middle_left {
  top: 50%;
  transform: translateY(-50%);
}

.entry {
  transition:
    opacity var(--op77-dur-slow) var(--op77-ease),
    transform var(--op77-dur-slow) var(--op77-ease);
}

.entry.out {
  opacity: 0;
  transform: scale(0.98);
}

/* Each edge enters from its own side. The stack knows the direction; a toast never does. */
.top_left .entry,
.bottom_left .entry,
.middle_left .entry {
  animation: enter-left var(--op77-dur) var(--op77-ease);
}

.top_right .entry,
.bottom_right .entry {
  animation: enter-right var(--op77-dur) var(--op77-ease);
}

.top_center .entry {
  animation: enter-down var(--op77-dur) var(--op77-ease);
}

.bottom_center .entry {
  animation: enter-up var(--op77-dur) var(--op77-ease);
}

@keyframes enter-left {
  from { opacity: 0; transform: translateX(-12px); }
}

@keyframes enter-right {
  from { opacity: 0; transform: translateX(12px); }
}

@keyframes enter-down {
  from { opacity: 0; transform: translateY(-6px); }
}

@keyframes enter-up {
  from { opacity: 0; transform: translateY(6px); }
}
</style>
