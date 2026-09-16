import type { Component } from 'vue'
import type { LayerName } from '@/stores/ui'

/**
 * Which feature modules exist, and which layer each draws on.
 *
 * STATIC IMPORTS ONLY. A `defineAsyncComponent(() => import(...))` is a chunk fetched
 * at runtime, and there is no runtime fetch inside the surface: the import would
 * resolve to a path the CEF cannot reach and the module would simply never appear,
 * with no error anywhere. Every module is in the bundle from the first frame.
 *
 * The registry also encodes the layer split, which is not a style choice:
 *
 *   overlay  the HUD. Never focused, never takes a pointer, always drawn.
 *   modal    anything the player drives. Takes focus and the cursor while open.
 *
 * These were two CEF pages and are two stacking contexts in one now, so declaring the
 * wrong layer no longer costs a whole browser -- but it still breaks the module: a
 * view on `overlay` cannot be clicked, and a HUD on `modal` goes inert the moment
 * nothing holds focus.
 */
export interface ModuleDefinition {
  /** Stable. Reported on `opx:diag` when the module fails, so it must be greppable. */
  id: string
  surface: LayerName
  component: Component
}

const modules: ModuleDefinition[] = []

export function registerModule(definition: ModuleDefinition): void {
  if (modules.some((existing) => existing.id === definition.id)) {
    throw new Error(`duplicate module id "${definition.id}"`)
  }
  modules.push(definition)
}

export function modulesFor(surface: LayerName): ModuleDefinition[] {
  return modules.filter((definition) => definition.surface === surface)
}
