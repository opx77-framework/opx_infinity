import { createApp } from 'vue'
import type { Component } from 'vue'
import { emit, subscribe } from '@/bridge/channel'
import { installDevShimIfMissing } from '@/bridge/devshim'
import { installDiagnostics, report } from '@/bridge/diag'
import { configureFocus } from '@/bridge/focus'
import { configureRpc } from '@/bridge/rpc'
import { setOpen, setStrings, setSurface } from '@/stores/ui'
import type { SurfaceName } from '@/stores/ui'
import '@/design/fonts.css'
import '@/design/tokens.css'
import '@/design/augmented.css'

/**
 * One `createApp` per surface. Everything a surface needs to be different from the
 * other surface is a parameter here and nowhere else.
 *
 * The order below is not arbitrary:
 *  1. the dev shim, so a browser has a bridge before anything asks for one;
 *  2. diagnostics, so step 3 onwards has somewhere to report to;
 *  3. rpc and focus identity, so the first request cannot collide with the other
 *     surface's refs and the overlay cannot take focus even by accident;
 *  4. mount;
 *  5. `opx:ui:ready` LAST. Lua takes it as permission to start pushing state, and a
 *     payload arriving before the channels are bound is a payload that is simply lost.
 */
export interface SurfaceOptions {
  name: SurfaceName
  root: Component
  rootProps?: Record<string, unknown>
  /**
   * Only one surface platform-wide may hold focus. The overlay passes false and that
   * is enforced, not documented: see bridge/focus.ts.
   */
  allowFocus: boolean
}

export function createSurface(options: SurfaceOptions): void {
  const { name, root, rootProps, allowFocus } = options

  const shimmed = installDevShimIfMissing(name)
  installDiagnostics(name)
  configureRpc(name)
  configureFocus(name, allowFocus)
  setSurface(name)

  // Lua owns the player's language and may change it mid-session. Bound at boot and
  // never released: there is no moment on either surface where a locale change is
  // uninteresting.
  subscribe('opx:locale:set', setStrings)
  subscribe(`opx:${name}:show`, (payload) => setOpen(payload.visible !== false))

  const app = createApp(root, rootProps)

  // The last line of defence, below ModuleHost. Reaching this means something threw
  // outside every module boundary, and the app is already coming down; the report is
  // the only thing that will survive it.
  app.config.errorHandler = (error, _instance, info) => {
    report(error, `app ${name} [${info}]`)
  }

  const mount = document.getElementById('app')
  if (!mount) {
    report('no #app element in the document', `boot ${name}`)
    return
  }
  app.mount(mount)

  if (shimmed) document.documentElement.classList.add('opx-dev-shim')

  // `opx:ready`, not `opx:ui:ready`. `lib/client/surface.lua` owns this handshake
  // and wires it as `<surface id>:ready`; it sets `surface.ready` from that channel
  // and nothing else, and `OPX.Surface.Send` refuses everything until it is set.
  // Emitting any other name leaves the surface permanently unready -- silently,
  // because a refused send is a `false` return nobody reads.
  emit('opx:ready', { surface: name })
}
