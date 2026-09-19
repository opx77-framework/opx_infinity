import { createApp } from 'vue'
import type { Component } from 'vue'
import { handshake, subscribe } from '@/bridge/channel'
import { installDevShimIfMissing } from '@/bridge/devshim'
import { installDiagnostics, report } from '@/bridge/diag'
import { configureFocus } from '@/bridge/focus'
import { configureRpc } from '@/bridge/rpc'
import { setStrings } from '@/stores/ui'
import '@/design-system/fonts.css'
import '@/design-system/tokens.css'
import '@/design-system/shapes.css'
import '@/design-system/surface.css'

/**
 * The one `createApp`, and everything that has to happen around it in order.
 *
 * There were two of these, one per CEF page. There is one page now, and `name` is what
 * is left of that: an identity for diagnostics and for the prefix on rpc refs, not a
 * choice of surface.
 *
 * The order below is not arbitrary:
 *  1. the dev shim, so a browser has a bridge before anything asks for one;
 *  2. diagnostics, so step 3 onwards has somewhere to report to;
 *  3. rpc and focus identity, so refs are prefixed before the first request;
 *  4. mount;
 *  5. `opx:ready` LAST. Lua takes it as permission to start pushing state, and a
 *     payload arriving before the channels are bound is a payload that is simply lost.
 */
export interface SurfaceOptions {
  /** Identity for diagnostics and rpc refs -- not a layer. */
  name: string
  root: Component
  rootProps?: Record<string, unknown>
  /**
   * Whether `acquireFocus` is honoured at all. True here: the page as a whole can take
   * focus, and which modules may ask is now a property of the LAYER they register on.
   */
  allowFocus: boolean
}

export function createSurface(options: SurfaceOptions): void {
  const { name, root, rootProps, allowFocus } = options

  const shimmed = installDevShimIfMissing(name)
  installDiagnostics(name)
  configureRpc(name)
  configureFocus(name, allowFocus)

  // Lua owns the player's language and may change it mid-session. Bound at boot and
  // never released: there is no moment in the session where a locale change is
  // uninteresting.
  subscribe('opx:locale:set', setStrings)

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
  //
  // It also RELEASES the page: every emit a module made from `onMounted` -- and each
  // of the five `opx:<module>:ready` signals is one -- was held by channel.ts until
  // this line, because Lua drops its answer to anything that arrives before the
  // handshake. They go out now, in the order they were made.
  handshake('opx:ready', { surface: name })
}
