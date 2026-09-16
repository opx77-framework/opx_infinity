import { emit } from './channel'
import { report } from './diag'

/**
 * Who currently owns keyboard focus, and where Escape goes.
 *
 * Only ONE surface may hold focus at a time, platform-wide. That makes focus a scarce
 * resource shared between every module on this surface and every other surface, which
 * is why it is a stack and not a boolean: a confirm dialog opened from a panel must
 * give focus back to the panel when it closes, not to nobody.
 *
 * The overlay surface must never call `acquireFocus`. It runs at 30fps behind
 * everything, it is never destroyed, and a HUD that takes focus takes the player's
 * controls away with it. `configureFocus('overlay')` makes that a reported error
 * rather than a player who cannot move.
 */

export interface FocusOwner {
  /** Stable within a surface; used in the diagnostic trail, not by Lua. */
  id: string
  /** What Escape means here. Omit and Escape simply releases. */
  onEscape?: () => void
}

const stack: FocusOwner[] = []

let surface = 'unknown'
let mayFocus = true
let keyBound = false

export function configureFocus(name: string, allowed: boolean): void {
  surface = name
  mayFocus = allowed
}

function top(): FocusOwner | undefined {
  return stack[stack.length - 1]
}

/**
 * Tells Lua the truth about this surface's focus, every time it changes.
 *
 * An INTENT, not a fact, like everything else leaving here: Lua decides whether to
 * hand over the cursor and mute game input. It may refuse -- another surface may
 * already hold it -- and if it does, this page does not get to pretend otherwise.
 */
function announce(): void {
  const owner = top()
  emit('opx:focus:set', {
    surface,
    focus: owner !== undefined,
    owner: owner ? owner.id : ''
  })
}

function onKeyDown(event: KeyboardEvent): void {
  if (event.key !== 'Escape') return
  const owner = top()
  if (!owner) return
  event.preventDefault()
  if (!owner.onEscape) {
    releaseFocus(owner)
    return
  }
  try {
    owner.onEscape()
  } catch (error) {
    // A throwing Escape handler would otherwise trap the player on this surface.
    report(error, `escape ${owner.id}`)
    releaseFocus(owner)
  }
}

/** Pushes `owner` onto the focus stack and returns the release for it. */
export function acquireFocus(owner: FocusOwner): () => void {
  if (!mayFocus) {
    report(`${owner.id} asked for focus on the ${surface} surface`, 'focus refused')
    return () => {}
  }
  if (!keyBound) {
    keyBound = true
    // Capture phase: a module that stops Escape propagating still must not be able to
    // strand the stack.
    window.addEventListener('keydown', onKeyDown, true)
  }

  stack.push(owner)
  announce()

  let released = false
  return () => {
    if (released) return
    released = true
    releaseFocus(owner)
  }
}

/**
 * Removes `owner` wherever it sits, not just from the top. A module can be unmounted
 * by ModuleHost while something it opened is still above it, and the stack has to
 * survive that without leaking an entry that nothing will ever pop.
 */
export function releaseFocus(owner: FocusOwner): void {
  const at = stack.lastIndexOf(owner)
  if (at === -1) return
  stack.splice(at, 1)
  announce()
}

export function focusOwner(): string {
  const owner = top()
  return owner ? owner.id : ''
}

export function hasFocus(): boolean {
  return stack.length > 0
}
