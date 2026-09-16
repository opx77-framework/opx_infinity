import { getCurrentInstance, onUnmounted } from 'vue'
import { subscribe } from '@/bridge/channel'
import { report } from '@/bridge/diag'
import type { Channel, Handler } from '@/bridge/types'

/**
 * Binds `handler` to `channel` for exactly as long as the calling component is mounted.
 *
 * Today every hand-written page leaks its handlers, and gets away with it because a
 * page is one module that never unmounts -- the leak and the lifetime are the same
 * length. A Vue view opened, closed and opened again does not have that excuse: the
 * second open registers a second handler, both fire, and the symptom is a list that
 * doubles rather than an error anyone can see.
 *
 * Using this outside `setup()` is that bug, so it is refused rather than allowed to
 * half-work.
 */
export function useBridge(channel: Channel, handler: Handler): void {
  if (!getCurrentInstance()) {
    report(`useBridge(${channel}) called outside setup(); it can never unsubscribe`, 'lifecycle')
    return
  }
  const release = subscribe(channel, handler)
  onUnmounted(release)
}
