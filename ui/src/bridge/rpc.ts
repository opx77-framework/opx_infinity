import { emit, subscribe } from './channel'
import { report } from './diag'
import { num, table, text } from './types'
import type { Channel, Payload } from './types'

/**
 * Request/response over a bridge that only does fire-and-forget.
 *
 * Generalised from `opx77_inventory/web/inventory.js` (`function request`), which is
 * the only page in the tree that has this and is the reason several others quietly
 * hang: without a ref there is no way to tell one reply from the next, and without a
 * timeout a Lua-side error means a spinner that never stops.
 *
 * Three things the inventory version does not do, each of which has bitten:
 *
 * - It RESOLVES on timeout, with `{ ok: false, error: "timeout" }`. Callers then have
 *   to remember to check `ok`, and the ones that forget treat a timeout as success.
 *   This rejects, so forgetting is a caught error rather than wrong data.
 * - Its `error` is the raw string "timeout", which ends up rendered. Everything here
 *   rejects with a LOCALE KEY: the page does not own the player's language, Lua does,
 *   and `locales/en.lua` is where that string lives.
 * - Its refs are integers counted from 1 in a single page. Two surfaces do that and
 *   both send ref 1. The prefix below makes a ref unique per surface so Lua can key
 *   its pending table on the ref alone.
 */

/** Every reply, for every request, on one channel. Lua echoes `ref` back unchanged. */
const REPLY_CHANNEL: Channel = 'opx:reply'

const DEFAULT_TIMEOUT_MS = 5000

/** Rejection carries a locale key. `message` is the key; never render it raw. */
export class BridgeError extends Error {
  readonly localeKey: string

  constructor(localeKey: string) {
    super(localeKey)
    this.name = 'BridgeError'
    this.localeKey = localeKey
  }
}

interface Waiting {
  resolve: (value: Payload) => void
  reject: (reason: BridgeError) => void
  timer: ReturnType<typeof setTimeout>
  channel: Channel
}

const pending = new Map<string, Waiting>()

let refCount = 0
let refPrefix = 'ui'
let replyBound = false

/** Called once per surface at boot, so refs from the overlay cannot collide with the modal's. */
export function configureRpc(surface: string): void {
  refPrefix = surface
}

function bindReply(): void {
  if (replyBound) return
  replyBound = true
  // Never unsubscribed: replies outlive the component that asked for them, and a
  // reply arriving for a request whose caller has gone is a normal race, not an error.
  subscribe(REPLY_CHANNEL, (payload) => {
    const ref = text(payload.ref)
    const waiting = pending.get(ref)
    if (!waiting) return // late reply, or one for a request that already timed out
    pending.delete(ref)
    clearTimeout(waiting.timer)

    if (payload.ok === false) {
      waiting.reject(new BridgeError(text(payload.error, 'error.rpc_failed')))
      return
    }
    waiting.resolve(table(payload.data))
  })
}

export interface RequestOptions {
  timeoutMs?: number
}

/**
 * Sends `payload` on `channel` and resolves with whatever Lua puts in `data`.
 *
 * The resolved value is Lua's answer, not ours. An empty Lua table arrives as `{}`, so
 * treat every field as absent until coerced -- `list`, `text`, `num` in bridge/types.
 */
export function request(
  channel: Channel,
  payload: Payload = {},
  options: RequestOptions = {}
): Promise<Payload> {
  bindReply()

  refCount += 1
  const ref = `${refPrefix}:${refCount}`
  const timeoutMs = num(options.timeoutMs, DEFAULT_TIMEOUT_MS)

  return new Promise<Payload>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(ref)
      // Reported as well as rejected: a caller may well catch this and show a quiet
      // empty state, and then nobody would ever learn that Lua stopped answering.
      report(`no reply on ${channel} after ${timeoutMs}ms`, 'rpc timeout')
      reject(new BridgeError('error.rpc_timeout'))
    }, timeoutMs)

    pending.set(ref, { resolve, reject, timer, channel })
    emit(channel, { ...payload, ref })
  })
}

/** Diagnostics only: requests still waiting, oldest first. */
export function pendingRequests(): string[] {
  return Array.from(pending.values(), (waiting) => waiting.channel)
}
