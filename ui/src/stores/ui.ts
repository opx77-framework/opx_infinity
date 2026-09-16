import { computed, reactive, readonly } from 'vue'
import { table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * Surface-wide state. Deliberately not Pinia.
 *
 * Pinia would be one more runtime in the bundle for a store with four
 * fields and no devtools to inspect it with -- the CEF has no extensions. A module
 * scope plus `reactive` is the same thing minus the ceremony, and it stays portable:
 * `reactive` and `computed` are the whole API and both exist in Vue 2.7.
 *
 * Nothing here is authoritative. Every field is the last thing LUA SAID, cached so
 * the render does not have to ask again. The page never writes a value it invented.
 */

/**
 * Which LAYER of the single surface a module draws on. There used to be two CEF pages
 * and this named them; there is one now, and these are stacking contexts inside it.
 *
 * The distinction still earns its keep: `overlay` never takes a pointer or the
 * keyboard, `modal` does. A module declaring the wrong one either cannot be clicked or
 * goes inert as soon as nothing holds focus.
 */
export type LayerName = 'overlay' | 'modal'

interface UiState {
  /**
   * Something on the interactive layer holds focus.
   *
   * With one surface this drives `pointer-events` on that layer: a full-screen
   * transparent div that accepts clicks while nothing is open is a player who cannot
   * shoot. Two pages got this for free by not existing.
   */
  focused: boolean
  /** `opx:locale:set`. Keys, never sentences -- see useLocale. */
  strings: Record<string, string>
  /** Modules ModuleHost has unmounted after a throw. Shown in the diag overlay only. */
  failed: string[]
}

const state = reactive<UiState>({
  focused: false,
  strings: {},
  failed: []
})

export const ui = readonly(state)

export const isFocused = computed(() => state.focused)

export function setFocused(focused: boolean): void {
  state.focused = focused
}

/**
 * Replaces the dictionary wholesale. Lua owns the player's language and may change it
 * mid-session; merging would leave the previous language's strings behind for any key
 * the new one happens not to define.
 */
export function setStrings(payload: Payload): void {
  const incoming = table(payload.strings)
  const next: Record<string, string> = {}
  for (const key of Object.keys(incoming)) next[key] = text(incoming[key], key)
  state.strings = next
}

export function noteModuleFailure(id: string): void {
  if (!state.failed.includes(id)) state.failed.push(id)
}

export function clearModuleFailure(id: string): void {
  const at = state.failed.indexOf(id)
  if (at !== -1) state.failed.splice(at, 1)
}
