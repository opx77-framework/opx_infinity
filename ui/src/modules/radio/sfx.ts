/**
 * THE DEVICE'S HARDWARE SOUNDS, and the only thing besides NotifyRoot that makes
 * a noise on this page.
 *
 * A police scanner is half its acoustics: the squelch that opens when a carrier
 * lands, the tail it drops when the carrier goes, the thunk of the fist-mic
 * keying, the tick of a knob crossing its detent. The clips are synthesized by
 * `tools/scanner-sfx.py` into `ui/public/audio/` (static is shaped noise, a
 * squelch tail is that noise losing an argument with a comparator), and this
 * file plays them the way `notify/stinger.ts` plays its stingers -- plain
 * `HTMLAudioElement`s against the page's own `audio/` origin. The WebUI host
 * runs autoplay-permissive (wiki/sound.md), so a press is never waiting on a
 * gesture to be heard.
 *
 * NEVER THROWS, NEVER BLOCKS, AND NEVER ASKS. These clips are the sound of
 * hardware, not information: a device that cannot speak is a silent device, not
 * a broken one. A file the engine refuses to decode is remembered and skipped
 * forever after (`dead`), because a decoder that will not take a file will not
 * take it twice -- and a refused `play()` (autoplay policy on some other host)
 * is swallowed the same way. The finger's work is never held up by audio.
 *
 * OVERLAP IS REAL, so voices are pooled: a knob swept through its detents can
 * tick over itself, and a squelch tail can land on a mic unkey. Three voices
 * per file is more than the device can ever ask for; the pool grows lazily, so
 * an unopened scanner allocates nothing at all (`prime()` warms the pool the
 * moment the device appears).
 *
 * THE VOLUME KNOB IS THE SPEAKER KNOB. One physical control, one acoustic
 * policy: every clip is scaled by the device's own VOL position (0-100), the
 * same control that sets the listener's channel gains. At zero the speaker is
 * genuinely silent and the clips are not even started.
 */

/** Where the clips live, relative to the page. `web/audio/` in the built resource. */
const AUDIO_DIR = 'audio/'

/**
 * The device's vocabulary. Each cue lists its clip variants -- a real radio
 * never makes the same static twice, so the squelches and tails come in twos
 * and one is picked per event -- plus that clip's own mix level, which the
 * volume knob then scales.
 */
export type Cue =
  | 'boot'
  | 'off'
  | 'channel'
  | 'squelch'
  | 'tail'
  | 'micOn'
  | 'micOff'
  | 'detent'
  | 'key'
  | 'denied'

interface Clip {
  /** Clip variants; one is picked per event. */
  names: string[]
  /** The clip's own mix level; the speaker knob scales it further. */
  gain: number
}

const CLIPS: Record<Cue, Clip> = {
  /** The speaker waking: relay click, static wash, two-tone beep. */
  boot: { names: ['scan-boot.wav'], gain: 0.6 },
  /** The speaker dying. */
  off: { names: ['scan-off.wav'], gain: 0.6 },
  /** The between-channels sweep -- Lua's TUNED receipt moved the dial. */
  channel: { names: ['scan-channel.wav'], gain: 0.55 },
  /** The squelch opening on a carrier: someone is talking on this band. */
  squelch: { names: ['scan-squelch-1.wav', 'scan-squelch-2.wav'], gain: 0.5 },
  /** The squelch tail dropping as the carrier goes. */
  tail: { names: ['scan-tail-1.wav', 'scan-tail-2.wav'], gain: 0.55 },
  /** The fist-mic keying under the finger. */
  micOn: { names: ['scan-mic-on.wav'], gain: 0.7 },
  /** The fist-mic unkeying. */
  micOff: { names: ['scan-mic-off.wav'], gain: 0.65 },
  /** A knob detent ticking over. */
  detent: { names: ['scan-detent.wav'], gain: 0.5 },
  /** A rubber preset key (or the stow key) bottoming out. */
  key: { names: ['scan-key.wav'], gain: 0.55 },
  /** A dead band's key, or the dial locked under a keyed transmitter. */
  denied: { names: ['scan-denied.wav'], gain: 0.5 }
}

/** Voices per clip file. The device can overlap itself; three is more than it asks. */
const POOL = 3

const pools = new Map<string, HTMLAudioElement[]>()
const cursors = new Map<string, number>()
/** Files the engine already refused to decode. Tried once, never again. */
const dead = new Set<string>()

/** The speaker knob's position, 0-1. Set from the device's VOL. */
let master = 1

/** One file's next voice slot, created on first use and reused after. */
function voiceOf(name: string): HTMLAudioElement | null {
  if (dead.has(name)) return null
  let pool = pools.get(name)
  if (!pool) {
    pool = []
    pools.set(name, pool)
  }
  const slot = (cursors.get(name) ?? 0) % POOL
  cursors.set(name, slot + 1)
  if (!pool[slot]) {
    try {
      const audio = new Audio(AUDIO_DIR + name)
      audio.preload = 'auto'
      // A decode or fetch failure is the end of this file for the session.
      audio.addEventListener('error', () => {
        dead.add(name)
      })
      pool[slot] = audio
    } catch {
      dead.add(name)
      return null
    }
  }
  return pool[slot] ?? null
}

/** The speaker knob. 0 is silent, 1 is full -- the clips' own gains ride under it. */
export function setMaster(level: number): void {
  master = Math.max(0, Math.min(1, level))
}

/** Warms every voice slot so the first press does not pay for construction.
 * Call it the moment the device appears. Cheap: silence allocates nothing. */
export function prime(): void {
  for (const clip of Object.values(CLIPS)) {
    for (const name of clip.names) voiceOf(name)
  }
}

/** Plays one cue. Fire-and-forget: nothing to await, nothing to catch. */
export function play(cue: Cue): void {
  const clip = CLIPS[cue]
  const level = clip.gain * master
  if (level <= 0) return // the speaker knob is at zero: the device is quiet
  const picked = Math.floor(Math.random() * clip.names.length)
  const name = clip.names[picked] ?? clip.names[0]
  if (!name) return
  const voice = voiceOf(name)
  if (!voice) return
  try {
    voice.currentTime = 0
    voice.volume = Math.max(0, Math.min(1, level))
    const started = voice.play()
    // Autoplay can be refused on a host that still demands a gesture. Read the
    // rejection so it is silent instead of unhandled; the device stays quiet.
    if (started && typeof started.then === 'function') {
      started.then(undefined, () => undefined)
    }
  } catch {
    /* a device that cannot speak is a silent device */
  }
}

/** The device's sounds, as one object for the view layer. */
export const sfx = { play, prime, setMaster }
