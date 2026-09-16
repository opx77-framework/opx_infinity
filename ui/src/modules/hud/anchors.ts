import { text } from '@/bridge/types'

/**
 * Where a HUD block sits on the screen.
 *
 * A CLOSED SET, exactly as `ANCHORS` in `opx77_hud/web/hud.js` was. The name reaches a
 * class attribute, so an unrecognised one has to fall back rather than travel: Lua is
 * trusted to be well-behaved, but the bus it sits on is shared with every other resource
 * on the client and `anchor = "'; --"` must be a shrug and not a broken layout.
 */
export type Anchor =
  | 'bottom-left'
  | 'bottom-right'
  | 'top-left'
  | 'top-right'
  | 'top-center'
  | 'bottom-center'

const ANCHORS: readonly string[] = [
  'bottom-left',
  'bottom-right',
  'top-left',
  'top-right',
  'top-center',
  'bottom-center'
]

export function anchorOf(value: unknown, fallback: Anchor): Anchor {
  const name = text(value)
  return ANCHORS.indexOf(name) === -1 ? fallback : (name as Anchor)
}

/** `op-rail` is a leading-edge marker, and on a right-anchored block the lead is the right. */
export function railOf(anchor: Anchor): 'start' | 'end' {
  return anchor.indexOf('-right') === -1 ? 'start' : 'end'
}
