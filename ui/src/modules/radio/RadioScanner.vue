<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { sfx } from './sfx'

/**
 * THE POLICE SCANNER -- a DEVICE. A moulded body with screws and a speaker
 * grille, a recessed screen of segmented glass, four preset keys, two rotary
 * knobs and a fist-mic bar. This is the one panel that DRESSES AS THE OBJECT IT
 * IS: where every other view here is a red plate of type, this one is black
 * plastic with a green screen, because a police scanner that looks like a menu
 * is a bug even when it works.
 *
 * IT DECIDES NOTHING, the way no view here does. Which bands exist, which of
 * them this listener may hear and what was said on them all arrive from the
 * server; this page draws the device and reports presses. Tuning is an INTENT
 * (`radio:tune`) and the screen's channel only moves when Lua echoes it back,
 * so a press on a key nobody can hear is a press that does nothing rather than
 * a display showing static it invented. Talking is an INTENT (`radio:talk`)
 * and the TX lamp is Lua's echo of it -- the lamp is never lit by the press.
 *
 * THE LAMPS ARE READINGS. TX comes from Lua's echo of the keyed transmitter,
 * RX from the host's own talker state (`open77:voice:talkingChanged`), and the
 * bar meter is the native capture level Lua polled while the key is held
 * (`txlevel`). A lamp no message lit stays dark.
 *
 * THE KNOBS ARE CONTROLS WITH RECEIPTS WHERE IT MATTERS. VOL is LOCAL
 * presentation policy (voice.md: gains never cross the wire), so it turns
 * instantly and says `opx:radio:volume`. TUNE steps the channel bank and its
 * rotation follows the TUNED receipt, never the press -- and the dial locks
 * while the PTT is held, because a keyed transmitter stays on the band it was
 * keyed on.
 *
 * STOWING IS AN INTENT TOO. Escape and the stow control both ask (`radio:close`);
 * the device goes down when the close comes back on `radio:view`.
 *
 * ── DESIGN ──────────────────────────────────────────────────────────────────
 *
 * THE SCREEN IS SEGMENTED GLASS, NOT A FONT. The frequency is drawn as
 * seven-segment SVG glyphs with their unlit ghosts showing, the way a real LCD
 * holds its dead strokes faintly visible; behind everything sits a scanline
 * texture and one glass glare. The rest of the readout -- channel, meter, the
 * traffic log -- is the phosphor's own luminance descent (ui/README rule 4,
 * survived the costume change): the newest line burns brightest, the settled
 * backlog sinks to a dim green.
 *
 * EVERY NUMBER ON IT IS REAL (rule 8, survived too): the declared frequencies
 * in segments, the channel ordinal over the bank's real size, the knob
 * positions (`02/04`, `VOL 100`), the meter's percent as it was drawn, each
 * line's id in the log. The ONE piece of invented chrome is the model plate,
 * and it stays because a device with no maker's engraving reads as a UI panel
 * -- which is the exact bug this rebuild exists to fix.
 *
 * THE ONLY RED IS THE TX LAMP, and it is hardware. The body is charcoal
 * plastic (bevelled with inset highlights and drop shadow), the keys are
 * rubber that depresses a pixel on press, and the knobs are ridged caps over
 * engraved tick dots.
 *
 * DOCKED RIGHT AND LEVEL BY DEFAULT, AND THE PLAYER'S TO PARK. The head rail
 * is the handle: carry it and the device goes where they drop it, square to the
 * glass (no cant -- the face stays parallel to the screen), and Lua keeps the
 * place in client KVP so the next session finds it there (`radio:place` out,
 * `frame.at` back). The carry is written for a pointer that DELIVERS NO MOVES
 * -- the game's virtual one: the release POINT is the drop, so a press-carry-
 * release still lands the device. Live following is the bonus a real mouse gets.
 */

interface Band {
  id: string
  /** A locale KEY, never a sentence -- the page holds no English. */
  name: string
  freq: string
  hear: boolean
}

interface Line {
  id: number
  channel: string
  /** A locale KEY; the words live in `locales.lua`. */
  key: string
  args: Record<string, unknown>
}

const { t } = useLocale()

/** The page's own ceilings, repeating Lua's rather than trusting the sender. */
const MAX_LINES = 30
const MAX_ROWS = 14
/** One knob detent per this many pixels of drag -- a knob, not a slider. */
const DRAG_STEP_PX = 10
/** The VOL knob's detents: 0-100 in steps of 5, unity at the centre. */
const VOL_STEP = 5

const open = ref(false)
const bands = ref<Band[]>([])
const lines = ref<Line[]>([])
const tuned = ref('')
/** The stow cap says what the player's OWN binding says; Lua resolved it. */
const keycap = ref('F2')
/** Lines the panel holds -- the count the feed header states. */
const held = ref(0)
/** The speaker knob's position, 0-100. LOCAL policy; no echo comes back. */
const volume = ref(100)

/** Physical PTT press (what the finger is doing) vs the lamp (what Lua said). */
const pttHeld = ref(false)
const txOn = ref(false)
const txChannel = ref('')
const txLevel = ref(0)
const rxOn = ref(false)
const rxLevel = ref(0)
const rxChannel = ref('')

let release: (() => void) | undefined

/** Where the player parked it -- absolute page pixels -- or the built-in dock. */
const at = ref<{ x: number; y: number } | null>(null)
/** The body, for the one measurement a carry needs: its own rendered box. */
const unitEl = ref<HTMLElement | null>(null)

/** The device keeps this much glass between itself and the edge. */
const EDGE = 8

/** The carry in progress: the grab offset, the place it started from, and
 *  whether any move ever arrived. */
let drag: { ox: number; oy: number; from: { x: number; y: number }; moved: boolean } | null = null

/** Keeps the whole device on the glass. Rounds: a place is whole pixels. */
function clamp(x: number, y: number): { x: number; y: number } {
  const w = unitEl.value?.offsetWidth ?? 458
  const h = unitEl.value?.offsetHeight ?? 560
  return {
    x: Math.round(Math.max(EDGE, Math.min(window.innerWidth - w - EDGE, x))),
    y: Math.round(Math.max(EDGE, Math.min(window.innerHeight - h - EDGE, y)))
  }
}

/** The head rail is the handle: press and carry. Best-effort capture, as every
 *  press here is -- the state is set first and a virtual pointer that cannot be
 *  captured is covered by the window-level release below. */
function grabDown(e: PointerEvent): void {
  if (e.button > 0 || !open.value || drag !== null) return
  const box = unitEl.value?.getBoundingClientRect()
  if (!box) return
  drag = {
    ox: e.clientX - box.left,
    oy: e.clientY - box.top,
    from: { x: Math.round(box.left), y: Math.round(box.top) },
    moved: false
  }
  window.addEventListener('pointermove', grabMove)
  window.addEventListener('pointerup', grabUp)
  window.addEventListener('pointercancel', cancelGrab)
  window.addEventListener('blur', cancelGrab)
}

function grabMove(e: PointerEvent): void {
  if (!drag) return
  drag.moved = true
  at.value = clamp(e.clientX - drag.ox, e.clientY - drag.oy)
}

/** Ends the carry wherever it lands: a release carries the drop POINT (the
 *  move-less virtual pointer's whole story), an interruption keeps whatever
 *  the moves already applied. A tap is not a move -- the device keeps the dock
 *  it had, and nothing is said. */
function endDrag(e?: { clientX: number; clientY: number }): void {
  const d = drag
  drag = null
  window.removeEventListener('pointermove', grabMove)
  window.removeEventListener('pointerup', grabUp)
  window.removeEventListener('pointercancel', cancelGrab)
  window.removeEventListener('blur', cancelGrab)
  if (!d) return
  const target = e !== undefined ? clamp(e.clientX - d.ox, e.clientY - d.oy) : (at.value ?? d.from)
  const changed = target.x !== d.from.x || target.y !== d.from.y
  if (!changed) return
  at.value = target
  emit('opx:radio:place', { x: target.x, y: target.y })
}

function grabUp(e: PointerEvent): void {
  endDrag(e)
}

function cancelGrab(): void {
  endDrag()
}

/** The tuned band's rows, oldest first, cut to what the page draws. */
const visible = computed<Line[]>(() => {
  const rows = lines.value.filter((line) => line.channel === tuned.value)
  return rows.slice(-MAX_ROWS)
})

const tunedBand = computed<Band | undefined>(() =>
  bands.value.find((band) => band.id === tuned.value)
)

/** The bands the dial can actually land on, in bank order. */
const hearable = computed<Band[]>(() => bands.value.filter((band) => band.hear))

/** The TUNE knob's detent: the tuned band's place among the hearable ones. */
const tunedIndex = computed<number>(() =>
  Math.max(0, hearable.value.findIndex((band) => band.id === tuned.value))
)

/** A knob is a rotary: ±135° of travel, and the pointer says where it sits. */
function knobAngle(position: number, span: number): number {
  if (span <= 0) return -135
  return -135 + (Math.max(0, Math.min(span, position)) / span) * 270
}

const tuneAngle = computed<number>(() => {
  const n = hearable.value.length
  return n > 1 ? knobAngle(tunedIndex.value, n - 1) : 0
})

const volAngle = computed<number>(() => knobAngle(volume.value, 100))

/** The meter's source: the keyed capture level while talking, the host's
 * talker level while hearing, and dark otherwise. */
const meterLevel = computed<number>(() => {
  if (txOn.value) return txLevel.value
  if (rxOn.value) return rxLevel.value
  return 0
})

const canTalk = computed<boolean>(() => open.value && tunedBand.value?.hear === true)

const txBand = computed<Band | undefined>(() =>
  bands.value.find((band) => band.id === txChannel.value)
)

const rxBand = computed<Band | undefined>(() =>
  bands.value.find((band) => band.id === rxChannel.value)
)

/** A line's id as the page counts it: stable, so the key survives a re-render. */
function ordinal(id: number): string {
  return String(id).padStart(3, '0')
}

function count(at: number): string {
  return String(at).padStart(2, '0')
}

/** The frequency as the screen draws it: one glyph box per character, the
 * decimal point as its own dot. `---.---` walks in the same glass. */
const freqChars = computed<string[]>(() =>
  (tunedBand.value?.freq ?? '---.---').split('')
)

/** SEVEN SEGMENTS PER GLYPH, a..g from the top and clockwise. The screen is
 * segmented glass and not a font pretending to be hardware -- the unlit
 * strokes of every digit stay faintly drawn, the ghost that sells the whole
 * device. */
const SEG7: Record<string, number[]> = {
  '0': [1, 1, 1, 1, 1, 1, 0],
  '1': [0, 1, 1, 0, 0, 0, 0],
  '2': [1, 1, 0, 1, 1, 0, 1],
  '3': [1, 1, 1, 1, 0, 0, 1],
  '4': [0, 1, 1, 0, 0, 1, 1],
  '5': [1, 0, 1, 1, 0, 1, 1],
  '6': [1, 0, 1, 1, 1, 1, 1],
  '7': [1, 1, 1, 0, 0, 0, 0],
  '8': [1, 1, 1, 1, 1, 1, 1],
  '9': [1, 1, 1, 1, 0, 1, 1],
  '-': [0, 0, 0, 0, 0, 0, 1],
  ' ': [0, 0, 0, 0, 0, 0, 0]
}

/** The seven strokes as mitred hexagons in a 20x36 glyph box. */
const SEG7_POLY = [
  '4,4 6,2 14,2 16,4 14,6 6,6', // a -- top
  '16,4 18,6 18,15 16,17 14,15 14,6', // b -- upper right
  '16,19 18,21 18,30 16,32 14,30 14,21', // c -- lower right
  '4,32 6,30 14,30 16,32 14,34 6,34', // d -- bottom
  '4,19 6,21 6,30 4,32 2,30 2,21', // e -- lower left
  '4,4 6,6 6,15 4,17 2,15 2,6', // f -- upper left
  '4,18 6,16 14,16 16,18 14,20 6,20' // g -- middle
]

function seg7(ch: string): number[] {
  return SEG7[ch] ?? SEG7[' ']
}

/** A voice level to the percent the meter draws, whatever scale it arrived on
 * (0.0-1.0 or 0-100) -- the label then states the percent it drew. */
function pct(raw: number): number {
  const value = Number.isFinite(raw) ? raw : 0
  return Math.max(0, Math.min(100, Math.round(value <= 1 ? value * 100 : value)))
}

/** The line, in the player's language. Every value coerced: a Lua number
 * arrives as a number and `t` takes strings or numbers, nothing else. */
function words(line: Line): string {
  const vars: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(line.args)) {
    vars[name] = typeof value === 'number' ? value : String(value ?? '')
  }
  return t(line.key, vars)
}

function blank(): void {
  open.value = false
  bands.value = []
  lines.value = []
  tuned.value = ''
  held.value = 0
  pttHeld.value = false
  txOn.value = false
  txChannel.value = ''
  txLevel.value = 0
  rxOn.value = false
  rxLevel.value = 0
  rxChannel.value = ''
  release?.()
  release = undefined
}

function tune(channel: string): void {
  if (!open.value || pttHeld.value) return
  emit('opx:radio:tune', { channel })
}

/** Keys (or releases) the transmitter. The lamp is NOT lit here: it lights
 * when Lua echoes the key state back, so a refused press stays dark. */
function talk(on: boolean): void {
  if (!open.value || pttHeld.value === on) return
  if (on && !canTalk.value) {
    // No band answers, so the transmitter never keys -- and the hardware says
    // so with its dead-key thunk instead of a silent nothing.
    sfx.play('denied')
    return
  }
  pttHeld.value = on
  // The mic's own mechanics: a thunk as the finger keys it, another as it
  // lets go. The TX lamp stays Lua's alone -- this is only the switch moving.
  sfx.play(on ? 'micOn' : 'micOff')
  emit('opx:radio:talk', { on })
}

/** The speaker knob: local presentation policy, so it is instant and no
 * server ever hears about it -- one gain for every band the frame named. It is
 * also the device's physical speaker, so the hardware sounds ride the same
 * knob. Answers whether anything actually moved: a knob at its stop does not
 * turn, and a step that changed nothing is a step that does not click. */
function setVolume(level: number): boolean {
  if (!open.value) return false
  const next = Math.max(0, Math.min(100, Math.round(level)))
  if (next === volume.value) return false
  volume.value = next
  sfx.setMaster(next / 100)
  emit('opx:radio:volume', { level: next })
  return true
}

/** Steps the TUNE dial to the next (or previous) hearable band. */
function stepTune(delta: number): void {
  const n = hearable.value.length
  if (n < 2 || pttHeld.value) return
  const next = ((tunedIndex.value + delta) % n + n) % n
  const band = hearable.value[next]
  if (band) {
    // The detent ticks where the knob actually turns: a locked dial and a
    // dial at the end of its bank are hardware that does not move, and the
    // silence says so.
    sfx.play('detent')
    tune(band.id)
  }
}

function stepVol(delta: number): void {
  if (setVolume(volume.value + delta * VOL_STEP)) sfx.play('detent')
}

/** PTT press: key it, and capture the pointer so a drag off the bar still
 * ends in a release instead of a stuck transmitter. Capture is BEST-EFFORT:
 * the game's virtual pointer cannot be captured and throws, and a throw here
 * would cost the whole press -- so the key goes first and a window-level
 * pointerup releases us if the capture never happened. */
function pttDown(e: PointerEvent): void {
  talk(true)
  try {
    ;(e.currentTarget as HTMLElement | null)?.setPointerCapture(e.pointerId)
  } catch {
    /* a virtual pointer cannot be captured */
  }
}

/** A press-release pair activates ONCE, whichever half of the pair the pointer
 * model delivers: a desktop mouse says `click` after `up`, the game's virtual
 * pointer may say only one of them, and one press must never mean two tunes. */
let lastPress = 0
function activate(run: () => void): void {
  const now = Date.now()
  if (now - lastPress < 300) return
  lastPress = now
  run()
}

/** A rotary's gestures, for whatever pointer model turns up. DRAG up to climb
 * (capable pointers), one wheel tick per step, and -- because the game's
 * virtual pointer offers neither moves nor capture -- PRESS AND HOLD to let the
 * knob motor through its detents, plus one detent per plain press-release.
 *
 * THE PATHS MUST NOT STACK: a press that dragged or held is served once and
 * its trailing `click` is swallowed, or every gesture ends a detent too far.
 */
const HOLD_DELAY = 350
const HOLD_EVERY = 160

function rotary(step: (delta: number) => void) {
  let press: { y: number; applied: number; held: number; timer: number | undefined } | null = null
  let served = false

  function stopHold(): void {
    if (press && press.timer !== undefined) {
      clearTimeout(press.timer)
      press.timer = undefined
    }
  }

  /** Ends the press wherever it lands: the element's own up, or any release
   * anywhere on the window when the capture the press wanted never happened. */
  function up(): void {
    window.removeEventListener('pointerup', up)
    window.removeEventListener('pointercancel', up)
    if (!press) return
    stopHold()
    served = press.held > 0 || press.applied !== 0
    press = null
  }

  return {
    down(e: PointerEvent): void {
      if (e.button > 0) return
      up()
      served = false
      // Capture is best-effort and must never cost the gesture: the state is
      // set first and the throw is swallowed (a virtual pointer cannot be
      // captured -- window-level release covers us instead).
      try {
        ;(e.currentTarget as HTMLElement | null)?.setPointerCapture(e.pointerId)
      } catch {
        /* a virtual pointer cannot be captured */
      }
      press = { y: e.clientY, applied: 0, held: 0, timer: undefined }
      window.addEventListener('pointerup', up)
      window.addEventListener('pointercancel', up)
      // HOLD TO TURN: the motor starts after a beat and steps every beat after,
      // so a knob held is a knob turning even if no move ever arrives.
      press.timer = window.setTimeout(function repeat() {
        const p = press
        if (!p) return
        step(1)
        p.held += 1
        p.timer = window.setTimeout(repeat, HOLD_EVERY)
      }, HOLD_DELAY)
    },
    move(e: PointerEvent): void {
      if (!press) return
      const steps = Math.round((press.y - e.clientY) / DRAG_STEP_PX)
      if (steps === press.applied) return
      stopHold() // a hand is dragging; the motor stands down
      step(steps - press.applied)
      press.applied = steps
    },
    /** The element's own release. Idempotent with the window-level one. */
    up(): void {
      up()
    },
    /** Click-only pointers: one detent per press-release pair -- unless the
     * press it belongs to already turned the knob by drag or hold. */
    click(): void {
      if (served) {
        served = false
        return
      }
      step(1)
    },
    wheel(e: WheelEvent): void {
      step(e.deltaY < 0 ? 1 : -1)
    }
  }
}

const tuneDial = rotary(stepTune)
const volDial = rotary(stepVol)

/** THE PROBE. One build of evidence beats ten theories: every pointer event
 * the browser actually delivers is reported to the log with its hit target, so
 * a press that dies between the host's virtual pointer and this page is told
 * apart from a press this page mishandles. Throttled hard -- it is a witness,
 * not a chatterbox -- and it rides its own channel so the diag budget is never
 * spent on it. */
const PROBE_MS = 250
const probeAt: Record<string, number> = {}

function probe(type: string, event: Event): void {
  const now = Date.now()
  if (now - (probeAt[type] ?? 0) < PROBE_MS) return
  probeAt[type] = now
  const at = event as MouseEvent
  const el = event.target as HTMLElement | null
  emit('opx:radio:probe', {
    t: type,
    target: el ? `${el.tagName.toLowerCase()}[${el.getAttribute('class') ?? '-'}]` : '?',
    x: Math.round(at.clientX ?? -1),
    y: Math.round(at.clientY ?? -1)
  })
}

const probes: Array<[string, EventListener]> = (
  ['pointerdown', 'pointerup', 'click', 'wheel'] as const
).map((type) => {
  const listener: EventListener = (event) => probe(type, event)
  // Capture phase: the witness testifies even if a handler stops propagation.
  document.addEventListener(type, listener, true)
  return [type, listener]
})

function stow(): void {
  if (!open.value) return
  emit('opx:radio:close', {})
}

/** The finger left the page mid-press (blur, tab-away): a held key must not
 * stay keyed. Lua would close it on the next stow; this closes it now. */
function releasePtt(): void {
  if (pttHeld.value) talk(false)
}

useBridge('opx:radio:view', (payload: Payload) => {
  guard(
    'radio:view',
    () => {
      const kind = text(payload.kind)

      if (kind === 'frame') {
        const frame = table(payload.frame)
        const rows: Band[] = []
        for (const entry of list<Payload>(frame.channels)) {
          const id = text(entry.id)
          if (!id) continue
          rows.push({
            id,
            name: text(entry.name, id),
            freq: text(entry.freq),
            hear: bool(entry.hear)
          })
        }
        // Nothing to draw is not a scanner: Lua only opens one for a listener
        // some band answers for, so this is a frame that lost its contents.
        if (rows.length === 0) return

        // The backlog comes in the same frame -- what a stowed scanner missed
        // is in the server's ring, and the reopen reads it back.
        const backlog: Line[] = []
        for (const entry of list<Payload>(frame.lines)) {
          const channel = text(entry.channel)
          const key = text(entry.key)
          if (!channel || !key) continue
          backlog.push({ id: num(entry.id), channel, key, args: table(entry.args) })
        }

        bands.value = rows
        lines.value = backlog.slice(-MAX_LINES)
        held.value = lines.value.length
        keycap.value = text(frame.key, 'F2')
        // Where this machine remembers the player parked it; a frame that
        // carries no place means the built-in dock.
        const where = table(frame.at)
        const px = num(where.x, -1)
        const py = num(where.y, -1)
        at.value = px >= 0 && py >= 0 ? { x: px, y: py } : null
        tuned.value = text(frame.tuned) || (rows.find((band) => band.hear)?.id ?? '')
        volume.value = 100
        pttHeld.value = false
        txOn.value = false
        txChannel.value = ''
        txLevel.value = 0
        rxOn.value = false
        rxLevel.value = 0
        rxChannel.value = ''
        open.value = true
        // The speaker wakes with the screen: decoders warmed, the knob at full
        // (the frame reset it), one boot chirp.
        sfx.prime()
        sfx.setMaster(1)
        sfx.play('boot')
        release?.()
        release = acquireFocus({
          id: 'ncpd.radio',
          // Escape stows it -- the scanner is a device, not a decision, so
          // leaving is always allowed (unlike SpawnView's mandatory choice).
          onEscape: () => stow()
        })
        return
      }

      if (kind === 'line') {
        const entry = table(payload.line)
        const channel = text(entry.channel)
        const key = text(entry.key)
        if (!channel || !key) return
        lines.value = [
          ...lines.value,
          { id: num(entry.id), channel, key, args: table(entry.args) }
        ].slice(-MAX_LINES)
        held.value += 1
        return
      }

      if (kind === 'tuned') {
        // The highlight is a RECEIPT for a press already sent: it moves when
        // Lua says which band is tuned, and not before. The TUNE knob turns
        // with it, so the dial never claims a band the echo has not granted.
        // A receipt that actually moves the dial sweeps the receiver past the
        // channels in between -- that is the between-channels static.
        const channel = text(payload.channel)
        if (bands.value.some((band) => band.id === channel && band.hear)) {
          if (tuned.value !== channel) {
            tuned.value = channel
            sfx.play('channel')
          }
        }
        return
      }

      if (kind === 'tx') {
        // The TX lamp is Lua's account of the transmitter, not the press's.
        txOn.value = bool(payload.on)
        txChannel.value = text(payload.channel)
        if (!txOn.value) txLevel.value = 0
        return
      }

      if (kind === 'rx') {
        // The squelch sounds around OTHER people's carriers and stays quiet
        // over this device's own keyed transmitter: a radio does not squelch
        // at itself. On is the burst as a carrier lands, off the tail as it
        // drops -- the one sound every scanner owner knows.
        const on = bool(payload.on)
        if (on !== rxOn.value && !txOn.value && !pttHeld.value) {
          sfx.play(on ? 'squelch' : 'tail')
        }
        rxOn.value = on
        rxLevel.value = pct(num(payload.level))
        rxChannel.value = text(payload.channel)
        return
      }

      if (kind === 'txlevel') {
        txLevel.value = pct(num(payload.level))
        return
      }

      if (kind === 'close') {
        // The reason is Lua's and it has already said it. The device goes
        // down, and its speaker signs off first.
        sfx.play('off')
        blank()
        return
      }

      // A kind this build does not know is not a reason to stow a working
      // device mid-transmission: it is drawn by nothing and does nothing.
    },
    undefined
  )
})

window.addEventListener('blur', releasePtt)
// Belt and braces for the virtual pointer: any release anywhere ends a held PTT.
window.addEventListener('pointerup', releasePtt)

onUnmounted(() => {
  window.removeEventListener('blur', releasePtt)
  window.removeEventListener('pointerup', releasePtt)
  for (const [type, listener] of probes) document.removeEventListener(type, listener, true)
  release?.()
})
</script>

<template>
  <div
    class="room"
    :class="{ open, placed: at !== null }"
    :style="at ? { left: at.x + 'px', top: at.y + 'px' } : undefined"
  >
    <div ref="unitEl" class="unit">
      <span class="screw s-tl" aria-hidden="true"></span>
      <span class="screw s-tr" aria-hidden="true"></span>
      <span class="screw s-bl" aria-hidden="true"></span>
      <span class="screw s-br" aria-hidden="true"></span>

      <!-- The head: brand engraving, speaker grille, power lamp -- and the
           HANDLE. It carries no controls, so the whole rail is the carry. -->
      <div class="top" @pointerdown="grabDown">
        <div class="brand">{{ t('ncpd.radio.title') }}</div>
        <div class="grille" aria-hidden="true"></div>
        <div class="pwr" aria-hidden="true"></div>
      </div>

      <!-- THE SCREEN: segmented glass. The frequency walks in as seven-segment
           glyphs (dead strokes still ghosting), the channel and feed count sit
           above it, the bar meter and the traffic log burn below. -->
      <div class="screen">
        <div class="glass">
          <div class="lcd-head">
            <span class="lcd-ch">CH{{ count(tunedIndex + 1) }}/{{ count(bands.length) }}</span>
            <span class="lcd-name">{{ tunedBand ? t(tunedBand.name) : t('ncpd.radio.title') }}</span>
            <span class="lcd-feed">{{ t('ncpd.radio.feed') }} {{ count(held) }}</span>
          </div>

          <div class="lcd-freq">
            <template v-for="(ch, i) in freqChars" :key="i">
              <span v-if="ch === '.'" class="d7-dot"></span>
              <svg v-else class="d7" viewBox="0 0 20 36" aria-hidden="true">
                <polygon
                  v-for="(pts, s) in SEG7_POLY"
                  :key="s"
                  :points="pts"
                  :class="{ lit: seg7(ch)[s] === 1 }"
                />
              </svg>
            </template>
            <span class="lcd-unit">MHz</span>
            <div class="lcd-meter">
              <div class="meter-bars">
                <span
                  v-for="n in 10"
                  :key="n"
                  class="bar"
                  :class="{ lit: meterLevel >= n * 10 - 5 }"
                ></span>
              </div>
              <span class="meter-num">{{ count(meterLevel) }}%</span>
            </div>
          </div>

          <div class="lcd-log">
            <div v-if="visible.length === 0" class="log-empty">{{ t('ncpd.radio.empty') }}</div>
            <div
              v-for="(line, index) in visible"
              :key="line.id"
              class="log-line"
              :class="{ hot: index === visible.length - 1, warm: index >= visible.length - 4 }"
            >
              <span class="log-tag">{{ ordinal(line.id) }}</span>
              <span class="log-words">{{ words(line) }}</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Hardware lamps: the only lit colours on the body. -->
      <div class="led-row">
        <div class="led-unit">
          <span class="led led-tx" :class="{ on: txOn }"></span>
          <span class="led-cap">{{ t('ncpd.radio.tx') }} {{ txBand ? txBand.freq : '' }}</span>
        </div>
        <div class="led-unit">
          <span class="led led-rx" :class="{ on: rxOn }"></span>
          <span class="led-cap">{{ t('ncpd.radio.rx') }} {{ rxBand ? rxBand.freq : '' }}</span>
        </div>
      </div>

      <!-- The preset bank: rubber keys that depress on press. A band this
           listener cannot hear is a key with no voice behind it -- dim, no
           lamp, and a press that is refused rather than faked. -->
      <div class="keys">
        <template v-for="(band, index) in bands" :key="band.id">
          <button
            v-if="band.hear"
            type="button"
            class="key"
            :class="{ 'is-on': tuned === band.id }"
            :disabled="pttHeld"
            @pointerdown="sfx.play('key')"
            @pointerup="activate(() => tune(band.id))"
            @click="activate(() => tune(band.id))"
          >
            <span class="key-num">{{ index + 1 }}</span>
            <span class="key-label">{{ t(band.name) }}</span>
          </button>
          <div
            v-else
            class="key is-dark"
            :title="t('ncpd.radio.dark')"
            @pointerdown="sfx.play('denied')"
          >
            <span class="key-num">{{ index + 1 }}</span>
            <span class="key-label">{{ t(band.name) }}</span>
          </div>
        </template>
      </div>

      <!-- The rotaries: ridged caps over engraved tick dots. VOL answers to
           the finger at once; TUNE turns only to the tuned receipt. -->
      <div class="knobs">
        <div class="knob-unit">
          <div
            class="dial"
            role="slider"
            :aria-label="t('ncpd.radio.vol')"
            :aria-valuenow="volume"
            aria-valuemin="0"
            aria-valuemax="100"
            @pointerdown="volDial.down"
            @pointermove="volDial.move"
            @pointerup="volDial.up"
            @pointercancel="volDial.up"
            @wheel.prevent="volDial.wheel"
            @click="volDial.click"
          >
            <span
              v-for="tick in 11"
              :key="tick"
              class="tick"
              :style="{ transform: `rotate(${-135 + (tick - 1) * 27}deg)` }"
            ></span>
            <span class="cap">
              <span class="cap-line" :style="{ transform: `rotate(${volAngle}deg)` }"></span>
            </span>
          </div>
          <div class="knob-cap">{{ t('ncpd.radio.vol') }} {{ count(volume) }}</div>
        </div>

        <div class="knob-unit">
          <div
            class="dial"
            :class="{ locked: pttHeld }"
            role="slider"
            :aria-label="t('ncpd.radio.tune')"
            :aria-valuenow="tunedIndex + 1"
            :aria-valuemax="Math.max(1, hearable.length)"
            @pointerdown="tuneDial.down"
            @pointermove="tuneDial.move"
            @pointerup="tuneDial.up"
            @pointercancel="tuneDial.up"
            @wheel.prevent="tuneDial.wheel"
            @click="tuneDial.click"
          >
            <span
              v-for="tick in 11"
              :key="tick"
              class="tick"
              :style="{ transform: `rotate(${-135 + (tick - 1) * 27}deg)` }"
            ></span>
            <span class="cap">
              <span class="cap-line" :style="{ transform: `rotate(${tuneAngle}deg)` }"></span>
            </span>
          </div>
          <div class="knob-cap">{{ t('ncpd.radio.tune') }} {{ count(tunedIndex + 1) }}/{{ count(bands.length) }}</div>
        </div>
      </div>

      <!-- The fist-mic bar: press and hold to talk, and the TX lamp above is
           what proves it landed. -->
      <button
        type="button"
        class="ptt"
        :class="{ 'is-keyed': txOn }"
        :disabled="!canTalk"
        @pointerdown.prevent="pttDown"
        @pointerup.prevent="talk(false)"
        @pointercancel="talk(false)"
        @lostpointercapture="talk(false)"
      >
        <span class="ptt-grip" aria-hidden="true"></span>
        {{ t('ncpd.radio.ptt') }}
      </button>

      <div class="foot">
        <span class="model">BCT-77</span>
        <button
          type="button"
          class="stow"
          @pointerdown="sfx.play('key')"
          @pointerup="activate(stow)"
          @click="activate(stow)"
        >
          {{ t('ncpd.radio.stow', { key: keycap }) }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* ── THE BODY ───────────────────────────────────────────────────────────────
   Charcoal plastic: a light bevel along the top edge, a deep one at the
   bottom, and one drop shadow lifting the whole device off the world. */
.room {
  position: fixed;
  top: 50%;
  right: 28px;
  /* LEVEL: square to the screen. No tilt -- a canted device reads as a
     crooked scan, and the owner reads it that way too. */
  transform: translateY(-50%);
  /* The gate is bypassed here, deliberately: the modal layer is
     `pointer-events: none` until something holds focus, and a child may
     re-enable itself. This panel is `visibility: hidden` when closed, which
     already keeps it from eating clicks -- so the device stays clickable even
     if a focus announcement is ever lost in the seam. */
  pointer-events: auto;
  opacity: 0;
  visibility: hidden;
  transition:
    opacity 220ms ease,
    visibility 220ms;
}

.room.open {
  opacity: 1;
  visibility: visible;
}

/* PARKED: the player's own coordinates beat the built-in dock -- right
   anchoring off, the centring transform off, absolute pixels in. */
.room.placed {
  right: auto;
  transform: none;
}

.unit {
  position: relative;
  width: 420px;
  padding: 16px 18px 14px;
  border-radius: 20px 20px 14px 14px;
  background:
    linear-gradient(180deg, #26282d 0%, #1d1f23 18%, #191b1e 82%, #141518 100%);
  border: 1px solid #0a0b0d;
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.1),
    inset 0 -3px 8px rgba(0, 0, 0, 0.55),
    inset 2px 0 4px rgba(0, 0, 0, 0.3),
    0 18px 44px rgba(0, 0, 0, 0.65);
  user-select: none;
  /* The body is charcoal and never inherits the theme's red: every mark on it
     is painted by this file, and the only red that survives is the TX lamp. */
  color: #b3b9c0;
}

/* Four corner screws: a machined circle with one slot. */
.screw {
  position: absolute;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.14), rgba(0, 0, 0, 0.3)),
    radial-gradient(circle at 40% 35%, #3c4046, #23262b 70%);
  box-shadow: inset 0 -1px 2px rgba(0, 0, 0, 0.7), 0 1px 0 rgba(255, 255, 255, 0.05);
}

.screw::after {
  content: '';
  position: absolute;
  left: 2px;
  right: 2px;
  top: 4.5px;
  height: 1.5px;
  background: rgba(0, 0, 0, 0.65);
  transform: rotate(28deg);
}

.s-tl { top: 9px; left: 10px; }
.s-tr { top: 9px; right: 10px; }
.s-bl { bottom: 9px; left: 10px; }
.s-br { bottom: 9px; right: 10px; }

.top {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 2px 18px 12px;
  cursor: grab;
  touch-action: none;
}

.top:active {
  cursor: grabbing;
}

.brand {
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.22em;
  text-transform: uppercase;
  color: #8b9199;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
}

/* The speaker: a recessed field of holes punched into the moulding. */
.grille {
  flex: 1;
  height: 26px;
  border-radius: 6px;
  background-color: #101216;
  background-image: radial-gradient(circle, #07080a 1.3px, transparent 1.7px);
  background-size: 6px 6px;
  box-shadow:
    inset 0 2px 5px rgba(0, 0, 0, 0.8),
    0 1px 0 rgba(255, 255, 255, 0.06);
}

.pwr {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #2fe08a;
  box-shadow: 0 0 6px rgba(47, 224, 138, 0.8), inset 0 -1px 2px rgba(0, 0, 0, 0.5);
}

/* ── THE SCREEN ─────────────────────────────────────────────────────────────
   Segmented glass in a recessed bezel: scanline texture, one glare across the
   top-left corner, and phosphor green that sinks with age (the luminance
   descent rule, wearing its device costume). */
.screen {
  border-radius: 8px;
  padding: 7px;
  background: linear-gradient(180deg, #101114, #17191d);
  box-shadow:
    inset 0 3px 7px rgba(0, 0, 0, 0.85),
    0 1px 0 rgba(255, 255, 255, 0.07);
}

.glass {
  position: relative;
  overflow: hidden;
  border-radius: 4px;
  padding: 10px 12px 8px;
  background: linear-gradient(180deg, #0d1a0f 0%, #0a130b 55%, #0c160e 100%);
  box-shadow: inset 0 0 26px rgba(0, 0, 0, 0.66);
  font-family: 'Cascadia Mono', Consolas, ui-monospace, monospace;
  color: #8bea52;
}

/* The LCD's own pixels, and one sheet of glass over them. */
.glass::before {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: repeating-linear-gradient(
    0deg,
    rgba(0, 0, 0, 0.16) 0 1px,
    transparent 1px 3px
  );
}

.glass::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: linear-gradient(118deg, rgba(255, 255, 255, 0.07) 0%, transparent 34%);
}

.lcd-head {
  display: flex;
  align-items: baseline;
  gap: 10px;
  font-size: 11px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #5f9e3f;
}

.lcd-ch {
  color: #8bea52;
}

.lcd-name {
  flex: 1;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  color: #8bea52;
}

.lcd-feed {
  color: #5f9e3f;
}

/* The hero: seven-segment glass. Lit strokes burn; dead strokes ghost faintly,
   the way a real LCD keeps them. */
.lcd-freq {
  display: flex;
  align-items: flex-end;
  gap: 6px;
  padding: 8px 0 6px;
}

.d7 {
  width: 26px;
  height: 46px;
}

.d7 polygon {
  fill: rgba(139, 234, 82, 0.07);
}

.d7 polygon.lit {
  fill: #a6ff64;
  filter: drop-shadow(0 0 3px rgba(166, 255, 100, 0.55));
}

.d7-dot {
  width: 7px;
  height: 7px;
  margin-bottom: 3px;
  border-radius: 1.5px;
  background: #a6ff64;
  box-shadow: 0 0 4px rgba(166, 255, 100, 0.55);
}

.lcd-unit {
  margin-left: 2px;
  margin-bottom: 5px;
  font-size: 10px;
  letter-spacing: 0.12em;
  color: #5f9e3f;
}

/* The bar meter: ten strokes of glass and the percent they were drawn at. */
.lcd-meter {
  margin-left: auto;
  margin-bottom: 4px;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 3px;
}

.meter-bars {
  display: flex;
  gap: 2px;
  align-items: flex-end;
  height: 22px;
}

.bar {
  width: 4px;
  height: 100%;
  background: rgba(139, 234, 82, 0.08);
}

.bar.lit {
  background: #8bea52;
  box-shadow: 0 0 4px rgba(139, 234, 82, 0.5);
}

.meter-num {
  font-size: 10px;
  letter-spacing: 0.08em;
  color: #5f9e3f;
}

/* The traffic log: the phosphor's luminance descent. */
.lcd-log {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-height: 104px;
  max-height: 104px;
  overflow-y: auto;
  border-top: 1px solid rgba(139, 234, 82, 0.14);
  padding-top: 5px;
  font-size: 11px;
  line-height: 1.35;
}

.log-empty {
  color: #46722f;
}

.log-line {
  display: flex;
  gap: 7px;
}

.log-tag {
  color: #46722f;
}

.log-words {
  flex: 1;
  color: #46722f;
}

.log-line.warm .log-words {
  color: #6cbf43;
}

.log-line.hot .log-words {
  color: #b6ff7a;
  text-shadow: 0 0 5px rgba(182, 255, 122, 0.4);
}

.log-line.hot .log-tag {
  color: #8bea52;
}

/* ── HARDWARE LAMPS ───────────────────────────────────────────────────── */
.led-row {
  display: flex;
  gap: 22px;
  padding: 11px 18px 4px;
}

.led-unit {
  display: flex;
  align-items: center;
  gap: 7px;
}

.led {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #1e2126;
  box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.8);
}

.led-tx.on {
  background: #ff453a;
  box-shadow: 0 0 7px rgba(255, 69, 58, 0.9), inset 0 -1px 2px rgba(0, 0, 0, 0.4);
}

.led-rx.on {
  background: #2fe08a;
  box-shadow: 0 0 7px rgba(47, 224, 138, 0.9), inset 0 -1px 2px rgba(0, 0, 0, 0.4);
}

.led-cap {
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: #767c84;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
}

/* ── PRESET KEYS ───────────────────────────────────────────────────────────
   Rubber keys with a moulded top edge; a pressed key sinks a pixel. The tuned
   key carries a small lamp of its own. */
.keys {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  padding: 8px 0 4px;
}

.key {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border: 1px solid #0e1013;
  border-radius: 7px;
  background: linear-gradient(180deg, #2a2d32 0%, #1d1f24 100%);
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.09),
    0 2px 3px rgba(0, 0, 0, 0.5);
  cursor: pointer;
}

.key:active:not(:disabled) {
  transform: translateY(1px);
  box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.55);
}

.key:disabled {
  cursor: default;
  opacity: 0.55;
}

.key-num {
  font-family: 'Cascadia Mono', Consolas, monospace;
  font-size: 11px;
  color: #7d838b;
}

.key-label {
  flex: 1;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  text-align: left;
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: #b3b9c0;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.7);
}

.key.is-on {
  border-color: #2c3a24;
  background: linear-gradient(180deg, #2e3529 0%, #22281e 100%);
}

.key.is-on .key-label {
  color: #cdf5a0;
}

.key.is-on .key-num {
  color: #8bea52;
}

.key.is-dark {
  cursor: default;
  opacity: 0.45;
  box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.55);
}

.key.is-dark .key-label {
  color: #6a7078;
}

/* ── THE ROTARIES ────────────────────────────────────────────────────────
   A ridged aluminium-look cap over engraved tick dots; the indicator line is
   the only bright mark and it reads the value the caption states. */
.knobs {
  display: flex;
  justify-content: space-evenly;
  gap: 24px;
  padding: 10px 0 6px;
}

.knob-unit {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
}

.dial {
  position: relative;
  width: 68px;
  height: 68px;
  border-radius: 50%;
  cursor: ns-resize;
  touch-action: none;
}

.dial.locked {
  cursor: default;
  opacity: 0.55;
}

.tick {
  position: absolute;
  left: 50%;
  top: -4px;
  width: 2px;
  height: 5px;
  margin-left: -1px;
  border-radius: 1px;
  background: rgba(255, 255, 255, 0.16);
  transform-origin: 50% 38px;
}

.cap {
  position: absolute;
  inset: 6px;
  border-radius: 50%;
  background:
    radial-gradient(circle at 50% 34%, #484d55 0%, #30343a 42%, #1c1f24 100%);
  background-image:
    repeating-conic-gradient(from 0deg, rgba(255, 255, 255, 0.05) 0deg 5deg, rgba(0, 0, 0, 0.12) 5deg 10deg),
    radial-gradient(circle at 50% 34%, #484d55 0%, #30343a 42%, #1c1f24 100%);
  box-shadow:
    inset 0 1px 1px rgba(255, 255, 255, 0.18),
    inset 0 -3px 6px rgba(0, 0, 0, 0.6),
    0 3px 6px rgba(0, 0, 0, 0.55);
}

.cap-line {
  position: absolute;
  left: 50%;
  top: 5px;
  width: 3px;
  height: 20px;
  margin-left: -1.5px;
  border-radius: 2px;
  background: #e8eaec;
  box-shadow: 0 0 3px rgba(255, 255, 255, 0.35);
  transform-origin: 50% 24px;
}

.knob-cap {
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: #767c84;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
}

/* ── THE FIST-MIC BAR ───────────────────────────────────────────────────
   Press and hold. Grip ridges across the rubber, and a red rim only while
   the transmitter is keyed. */
.ptt {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  width: 100%;
  margin: 6px 0 2px;
  padding: 15px;
  border: 1px solid #0e1013;
  border-radius: 9px;
  background:
    linear-gradient(180deg, #2c2f35 0%, #1b1e22 100%);
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.09),
    0 3px 5px rgba(0, 0, 0, 0.55);
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.24em;
  text-transform: uppercase;
  color: #c3c9d0;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
  cursor: pointer;
  touch-action: none;
}

.ptt:active:not(:disabled) {
  transform: translateY(1px);
  box-shadow: inset 0 3px 6px rgba(0, 0, 0, 0.6);
}

.ptt:disabled {
  color: #5c626a;
  cursor: default;
}

.ptt.is-keyed {
  border-color: #7a2420;
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.07),
    inset 0 0 14px rgba(255, 69, 58, 0.22),
    0 3px 5px rgba(0, 0, 0, 0.55);
}

.ptt-grip {
  width: 34px;
  height: 12px;
  border-radius: 3px;
  background: repeating-linear-gradient(
    90deg,
    rgba(255, 255, 255, 0.1) 0 2px,
    rgba(0, 0, 0, 0.35) 2px 5px
  );
}

/* ── THE FOOT ─────────────────────────────────────────────────────────── */
.foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 18px 2px;
}

.model {
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.22em;
  color: #5c626a;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
}

.stow {
  padding: 7px 14px;
  border: 1px solid #0e1013;
  border-radius: 6px;
  background: linear-gradient(180deg, #26292e 0%, #1a1c20 100%);
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.08),
    0 2px 3px rgba(0, 0, 0, 0.5);
  font-family: 'Segoe UI', Inter, sans-serif;
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: #9aa1a8;
  text-shadow: 0 1px 0 rgba(0, 0, 0, 0.8);
  cursor: pointer;
}

.stow:active {
  transform: translateY(1px);
  box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.55);
}
</style>
