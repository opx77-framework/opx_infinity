import { report } from '@/bridge/diag'
import { num, text } from '@/bridge/types'

/**
 * THE CLIPS THAT PLAY AROUND A TOAST, and the only thing on this page that makes
 * a sound.
 *
 * A toast may carry two: `open`, which runs BEFORE the message is drawn and holds
 * it back while it runs, and `close`, which runs once the message has gone. The
 * names arrive from the runtime as BARE FILE NAMES, and the reason is a boundary
 * rather than a preference: `audio/` below is this page's own origin, and a page
 * that honoured a path out of it would fetch from wherever a server's config
 * pointed. `core/client/notify.lua` refuses a name that is not bare; this file
 * repeats the test, because a page never trusts the wire it was handed.
 *
 * NEVER THROWS, NEVER REJECTS, AND ALWAYS ANSWERS. Every caller is holding a
 * message the player is waiting to read: a clip that cannot decode, a clip that
 * is missing, a machine that refused the playback, and an engine that answered no
 * at all all have to end in the message being drawn. So the answer is a value and
 * not an exception, and there is a deadline as well as an `ended` -- a clip that
 * stalls must not hold an announcement hostage.
 */

/** Where the clips live, relative to the page. `web/audio/` in the built resource. */
const AUDIO_DIR = 'audio/'

/** A bare file name. Identical in effect to the pattern the runtime enforces. */
const BARE_NAME = /^[A-Za-z0-9_-]+\.[A-Za-z0-9]+$/

/**
 * How long a hold may last before the message is drawn anyway.
 *
 * The two shipped clips are 1.8 s and 2.1 s, so this is not a limit they can
 * reach: it exists so that a longer or a stalling file can delay an announcement
 * by a bounded amount instead of until the end of a sound nobody can hear.
 */
const CLIP_DEADLINE_MS = 4000

export interface Stinger {
  /** A file name under `audio/`, or '' for none. */
  open: string
  close: string
  /** 0..1. */
  volume: number
}

export interface Played {
  /** Whether sound actually came out. A refusal is not an error worth raising;
   *  it is the ordinary case of a client whose audio is off. */
  played: boolean
  /** Why not, for the log. Empty when it played. */
  reason: string
}

/** One clip's name, or '' for a name this page will not use. */
function bareName(value: unknown): string {
  const name = text(value)
  return BARE_NAME.test(name) ? name : ''
}

/**
 * Reads a stinger off a payload. Null when there is nothing to play, which is the
 * ordinary case: a toast that carries no stinger and a payload from a runtime
 * that predates the field both land here.
 */
export function stingerOf(value: unknown): Stinger | null {
  if (value === null || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>

  const open = bareName(raw.open)
  const close = bareName(raw.close)
  if (!open && !close) return null

  // Asked for with `num`, then clamped rather than refused: a volume nobody can
  // parse is not a reason to lose the message, and it cannot be allowed to be
  // louder than full either.
  return { open, close, volume: Math.min(1, Math.max(0, num(raw.volume, 1))) }
}

/**
 * Plays one clip and answers when it has finished, failed or run past the
 * deadline. The promise always resolves.
 */
export function playClip(name: string, volume: number): Promise<Played> {
  return new Promise<Played>((resolve) => {
    let settled = false
    let deadline: ReturnType<typeof setTimeout> | undefined

    const settle = (played: boolean, reason: string): void => {
      if (settled) return
      settled = true
      if (deadline !== undefined) clearTimeout(deadline)
      resolve({ played, reason })
    }

    let audio: HTMLAudioElement
    try {
      audio = new Audio(AUDIO_DIR + name)
    } catch (error) {
      report(error, `notify stinger ${name}`)
      settle(false, 'audio_unavailable')
      return
    }

    audio.volume = volume
    audio.preload = 'auto'
    audio.addEventListener('ended', () => settle(true, ''))
    audio.addEventListener('error', () => {
      // The code is the whole diagnosis: 4 is a source the engine could not
      // decode, 1 is an abort, 2 a network fault inside the resource host.
      settle(false, `media_error_${audio.error ? audio.error.code : '?'}`)
    })

    // Started before `play()`, deliberately: the deadline covers a clip that never
    // begins AND one that begins and stalls, and `currentTime` is what tells the
    // two apart in the reason.
    deadline = setTimeout(() => {
      settle(audio.currentTime > 0, audio.currentTime > 0 ? 'clip_deadline' : 'clip_never_started')
    }, CLIP_DEADLINE_MS)

    try {
      const started = audio.play()
      // Autoplay can be refused (a client on a build that still demands a gesture),
      // and the rejection is silent unless it is read. It is not an error to raise
      // on the surface: the message is about to be drawn either way.
      if (started && typeof started.then === 'function') {
        started.then(
          () => undefined,
          (reason: unknown) => settle(false, `play_refused:${reason instanceof Error ? reason.name : String(reason)}`)
        )
      }
    } catch (error) {
      report(error, `notify stinger ${name}`)
      settle(false, 'play_threw')
    }
  })
}
