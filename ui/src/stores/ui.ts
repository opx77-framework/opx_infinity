import { computed, reactive, readonly } from 'vue'
import { table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * Surface-wide state. Deliberately not Pinia.
 *
 * Pinia would be one more runtime to bundle into two pages for a store with four
 * fields and no devtools to inspect it with -- the CEF has no extensions. A module
 * scope plus `reactive` is the same thing minus the ceremony, and it stays portable:
 * `reactive` and `computed` are the whole API and both exist in Vue 2.7.
 *
 * Nothing here is authoritative. Every field is the last thing LUA SAID, cached so
 * the render does not have to ask again. The page never writes a value it invented.
 */

export type SurfaceName = 'overlay' | 'modal'

interface UiState {
  surface: SurfaceName
  /** Lua has answered at least once. Until then the surface shows nothing at all. */
  ready: boolean
  /** The surface is being shown. Separate from `ready`: a ready HUD can still be hidden. */
  open: boolean
  /** `opx:locale:set`. Keys, never sentences -- see useLocale. */
  strings: Record<string, string>
  /** Modules ModuleHost has unmounted after a throw. Shown in the diag overlay only. */
  failed: string[]
}

const state = reactive<UiState>({
  surface: 'overlay',
  ready: false,
  open: false,
  strings: {},
  failed: []
})

export const ui = readonly(state)

export const isReady = computed(() => state.ready)
export const isOpen = computed(() => state.open)

export function setSurface(surface: SurfaceName): void {
  state.surface = surface
}

export function setOpen(open: boolean): void {
  state.open = open
  state.ready = true
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
