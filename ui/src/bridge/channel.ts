import { report } from './diag'
import type { Channel, Handler, Payload } from './types'

/**
 * The single point of contact with `window.Open77`.
 *
 * No component, composable or store may touch the global directly. Two reasons,
 * both of them things that have already gone wrong in the twelve hand-written pages:
 *
 * 1. `Open77.on` has no counterpart. There is no `off`, no returned unsubscribe, no
 *    way to take a registration back. Every page that registers a handler registers it
 *    for the lifetime of the surface. That was survivable when a page was one module
 *    that never unmounted; in a Vue app, a view opened twice registers twice and every
 *    payload is handled twice.
 *
 *    So the registration is permanent BY DESIGN and there is exactly one per channel
 *    name. What comes and goes is the handler set behind it, keyed by component
 *    lifecycle -- see composables/useBridge.ts.
 *
 * 2. The bridge swallows anything thrown inside an `Open77.on` handler. Not logs it,
 *    not surfaces it: swallows it. An unguarded handler that throws on a malformed
 *    payload is a feature that silently stopped working. Every handler below is
 *    wrapped, and a throw becomes a report on `opx:diag`.
 */

/** channel name -> the handlers currently interested in it */
const listeners = new Map<Channel, Set<Handler>>()

/** channel names we have already spent our one-and-only `Open77.on` on */
const registered = new Set<Channel>()

let missingBridgeReported = false

function bridge() {
  const open77 = window.Open77
  if (!open77 && !missingBridgeReported) {
    missingBridgeReported = true
    // Not `report`: report itself needs the bridge. This is the one case with no
    // channel out, and in a browser it is simply the expected state.
    console.warn('[opx] window.Open77 is absent; nothing will reach Lua')
  }
  return open77
}

function dispatch(channel: Channel, payload: unknown): void {
  const set = listeners.get(channel)
  if (!set || set.size === 0) return
  // A snapshot: a handler is allowed to unsubscribe itself, and often does -- an
  // `opx:*:close` handler tearing down the view that registered it is the normal case.
  for (const handler of Array.from(set)) {
    try {
      handler((payload ?? {}) as Payload)
    } catch (error) {
      report(error, `handler ${channel}`)
    }
  }
}

function registerOnce(channel: Channel): void {
  if (registered.has(channel)) return
  const open77 = bridge()
  if (!open77) return
  registered.add(channel)
  try {
    open77.on(channel, (payload) => dispatch(channel, payload))
  } catch (error) {
    // Registration itself failing is fatal for that channel; nothing will ever arrive.
    registered.delete(channel)
    report(error, `on ${channel}`)
  }
}

/**
 * Adds a handler for `channel` and returns the function that removes it again.
 * Callers in components use `useBridge`, which calls this and ties the removal to
 * `onUnmounted` so it cannot be forgotten.
 */
export function subscribe(channel: Channel, handler: Handler): () => void {
  let set = listeners.get(channel)
  if (!set) {
    set = new Set()
    listeners.set(channel, set)
  }
  set.add(handler)
  registerOnce(channel)

  let released = false
  return () => {
    // Idempotent: a component that unmounts during a dispatch would otherwise release
    // twice, once from the dispatch and once from onUnmounted.
    if (released) return
    released = true
    set.delete(handler)
  }
}

/* -- THE HANDSHAKE GATE ------------------------------------------------------
   Nothing leaves this page before `opx:ready` has, and that is not tidiness: it
   is the difference between a view being configured and a view running on its
   own defaults for the whole session.

   `lib/client/surface.lua` DROPS -- does not queue -- every `Send` made before
   the page has reported ready. A module view emits its own `opx:<module>:ready`
   from `onMounted`, which runs during `app.mount()`, and `boot/createSurface.ts`
   emits `opx:ready` AFTER the mount returns. So the order on the wire was:

       opx:chat:ready   -> Lua answers with the chat's config -> DROPPED
       opx:ready        -> Lua only now starts accepting sends

   The config is published once, in the reply to `ready`, and is never repeated.
   It was measured: the chat box reported `anchor=anchor-bottom-left offset=155`
   -- both page defaults -- while `config/chat.lua` said `top-center` and 48, and
   every other module that answers a `ready` the same way lost its first payload
   too.

   So an emit made before the handshake is HELD here and flushed, in order, the
   moment `handshake()` has gone out. The cost is one array that is emptied once
   per page load; the alternative is every module's first reply landing in the
   gap between mount and ready. */
let opened = false
const held: Array<{ channel: Channel; payload: Payload }> = []

/** Puts one payload on the wire, handshake or not. */
function send(channel: Channel, payload: Payload): void {
  const open77 = bridge()
  if (!open77) return
  try {
    open77.emit(channel, payload)
  } catch (error) {
    report(error, `emit ${channel}`)
  }
}

/**
 * Sends an intent to Lua.
 *
 * INVARIANT: this carries an INTENT, never a FACT. "The player pressed confirm on
 * option 2", not "the player bought the jacket". Lua re-derives the outcome from
 * authoritative state and tells us what actually happened. Nothing computed on this
 * page is trusted by anything downstream, and the page must not act as though it were.
 *
 * Held until the handshake has gone out. See the block above.
 */
export function emit(channel: Channel, payload: Payload = {}): void {
  if (!opened) {
    held.push({ channel, payload })
    return
  }
  send(channel, payload)
}

/**
 * The `opx:ready` handshake, and the only emit that goes out before it. Called
 * once, by `createSurface`, after the app has mounted: it puts the handshake on
 * the wire and then releases everything the mount queued behind it, in order.
 */
export function handshake(channel: Channel, payload: Payload = {}): void {
  send(channel, payload)
  opened = true
  for (const message of held.splice(0)) send(message.channel, message.payload)
}

/** Diagnostics only: which channels this surface has bound, and how deep. */
export function channelCensus(): Record<string, number> {
  const census: Record<string, number> = {}
  for (const [channel, set] of listeners) census[channel] = set.size
  return census
}
