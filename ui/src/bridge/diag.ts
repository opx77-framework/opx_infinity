/**
 * The only way an error leaves this surface.
 *
 * The CEF console does not reach the client log, and the WebUI bridge swallows anything
 * thrown inside an `Open77.on` handler. An unreported exception here is not a stack trace
 * somewhere inconvenient -- it is silence, and a HUD that quietly stopped updating.
 *
 * This file deliberately touches `window.Open77` directly instead of going through
 * channel.ts: diag has to still work when the channel layer is the thing that broke.
 */

const DIAG_CHANNEL = 'opx:diag'

// A throwing render loop can produce an error per frame at 30fps. The cap is the whole
// point of the budget -- past it we are flooding the client log, not diagnosing anything.
const MAX_REPORTS = 20

let reportCount = 0
let reporting = false
let installed = false

export function describe(value: unknown): string {
  try {
    if (value instanceof Error) return `${value.name || 'Error'}: ${value.message}`
    if (value === null || value === undefined) return String(value)
    if (typeof value === 'object') return Object.prototype.toString.call(value)
    return String(value)
  } catch {
    return '<undescribable>'
  }
}

/** Reports one line. Never throws, never recurses, and gives up after MAX_REPORTS. */
export function report(what: unknown, where?: string): void {
  // `reporting` guards the case where the emit itself throws into console.error.
  if (reporting || reportCount >= MAX_REPORTS) return
  reporting = true
  reportCount += 1
  try {
    const line = where ? `${where}: ${describe(what)}` : describe(what)
    window.Open77?.emit(DIAG_CHANNEL, {
      surface: surfaceName,
      text: line.slice(0, 400),
      dropped: reportCount === MAX_REPORTS ? 'budget reached, further reports suppressed' : ''
    })
  } catch {
    /* nowhere left to complain to */
  }
  reporting = false
}

/** Runs `fn`, reports anything it throws, and returns `fallback` instead of propagating. */
export function guard<T>(where: string, fn: () => T, fallback: T): T {
  try {
    return fn()
  } catch (error) {
    report(error, where)
    return fallback
  }
}

let surfaceName = 'unknown'

export function installDiagnostics(surface: string): void {
  surfaceName = surface
  if (installed) return
  installed = true

  window.addEventListener('error', (event) => {
    report(`uncaught ${event.message || '?'} at ${event.filename || '?'}:${event.lineno || 0}`)
  })

  // A rejected promise inside an async handler throws nowhere the bridge can see it.
  window.addEventListener('unhandledrejection', (event) => {
    report(event.reason, 'unhandled rejection')
  })

  const original = console.error
  console.error = function (...args: unknown[]) {
    report(args.map(describe).join(' '))
    try {
      original.apply(console, args)
    } catch {
      /* no console */
    }
  }
}

/** Test seam: the budget is process-wide, so a test that exhausts it poisons the next one. */
export function resetDiagnosticsBudget(): void {
  reportCount = 0
}
