import type { Component } from 'vue'
import type { SurfaceName } from '@/stores/ui'

/**
 * Which feature modules exist, and which surface each belongs on.
 *
 * STATIC IMPORTS ONLY. A `defineAsyncComponent(() => import(...))` is a chunk fetched
 * at runtime, and there is no runtime fetch inside the surface: the import would
 * resolve to a path the CEF cannot reach and the module would simply never appear,
 * with no error anywhere. Every module is in the bundle from the first frame, and the
 * cost of that is the reason there are two surfaces rather than one.
 *
 * The registry also encodes the surface split itself, which is not a style choice:
 *
 *   overlay  z 700, 30fps, never focused, never destroyed. The HUD.
 *   modal    z 740, 60fps, takes focus, created on demand. Anything the player drives.
 *
 * A module declaring the wrong surface is a module that either steals the player's
 * controls (a HUD asking for focus) or dies with the dialog above it (a HUD living on
 * the interactive surface).
 */
export interface ModuleDefinition {
  /** Stable. Reported on `opx:diag` when the module fails, so it must be greppable. */
  id: string
  surface: SurfaceName
  component: Component
}

const modules: ModuleDefinition[] = []

export function registerModule(definition: ModuleDefinition): void {
  if (modules.some((existing) => existing.id === definition.id)) {
    throw new Error(`duplicate module id "${definition.id}"`)
  }
  modules.push(definition)
}

export function modulesFor(surface: SurfaceName): ModuleDefinition[] {
  return modules.filter((definition) => definition.surface === surface)
}
