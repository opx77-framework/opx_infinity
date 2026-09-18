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

/**
 * Which screen edge a block reads as its LEADING one -- and on a right-anchored block that
 * is the right. Design pass 02 spends the answer on three things at once: which pair of
 * corners the frame chamfers, which corner carries the lit arete, and which way a column of
 * numbers is justified. (It used to name `op-rail`, the accent rule the house marker drew
 * down that edge; that rule went with the fill it sat on.)
 */
export function railOf(anchor: Anchor): 'start' | 'end' {
  return anchor.indexOf('-right') === -1 ? 'start' : 'end'
}
