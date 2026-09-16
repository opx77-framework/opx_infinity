import type { Handler, Open77Bridge, Payload } from './types'

/* =============================================================================
   DEVELOPMENT SHIM -- NOT PART OF THE GAME RUNTIME
   =============================================================================
   Stands in for `window.Open77` when there isn't one, so the surface can be
   opened in an ordinary browser. It installs ONLY if the real bridge is absent,
   and when it does it puts `data-opx-shim` on <html> and a banner class on the
   page, because a shimmed surface that looks identical to a live one is how you
   spend an afternoon debugging fake data.

   In game this file costs one `if`. Nothing here is ever reached: WebUI installs
   `Open77` before the document runs.

   Everything it answers is invented. It is not a model of the Lua side and must
   never become one -- if a behaviour matters, it belongs in a Lua test.
   ========================================================================== */

export function isDevShim(): boolean {
  return window.__OPX_DEV_SHIM__ === true
}

export function installDevShimIfMissing(surface: string): boolean {
  if (window.Open77) return false

  const handlers = new Map<string, Handler[]>()

  const bridge: Open77Bridge = {
    on(channel, handler) {
      const list = handlers.get(channel) ?? []
      list.push(handler)
      handlers.set(channel, list)
    },
    emit(channel, payload) {
      // eslint-disable-next-line no-console -- the shim's entire purpose is to be visible
      console.info('[opx:dev-shim] emit', channel, payload)
      answer(channel, payload)
    }
  }

  function send(channel: string, payload: Payload): void {
    for (const handler of handlers.get(channel) ?? []) handler(payload)
  }

  /** A canned Lua. Replies to anything carrying a ref so rpc.ts never just times out. */
  function answer(channel: string, payload: Payload): void {
    if (typeof payload.ref === 'string') {
      setTimeout(() => {
        send('opx:reply', { ref: payload.ref, ok: true, data: { echo: channel } })
      }, 120)
    }
  }

  window.Open77 = bridge
  window.__OPX_DEV_SHIM__ = true
  document.documentElement.setAttribute('data-opx-shim', surface)

  // Deferred so the surface has finished registering its channels before the fake
  // traffic starts. Same ordering the real Lua side has to respect.
  setTimeout(() => seed(send, surface), 0)
  return true
}

/** Fake traffic, shaped exactly as Lua would shape it -- including `{}` for empty lists. */
function seed(send: (channel: string, payload: Payload) => void, surface: string): void {
  send('opx:locale:set', {
    strings: {
      'error.rpc_timeout': 'No answer from the server',
      'error.rpc_failed': 'The server refused',
      'demo.title': 'Ripperdoc',
      'demo.eyebrow': 'Session',
      'demo.tab.chrome': 'Chrome',
      'demo.tab.stock': 'Stock',
      'demo.tab.log': 'Log',
      'demo.row.name': 'Operator',
      'demo.row.balance': 'Balance',
      'demo.row.consent': 'Consent on file',
      'demo.row.hint': 'Lua re-derives the balance; this is a display of its last answer.',
      'demo.field.callsign': 'Callsign',
      'demo.field.district': 'District',
      'demo.field.dose': 'Dose',
      'demo.toast': 'Link established',
      'demo.gauge.health': 'Health',
      'demo.gauge.armour': 'Armour'
    }
  })

  if (surface === 'overlay') {
    send('opx:notify:show', {
      id: 'dev-1',
      kind: 'success',
      title: 'demo.toast',
      message: 'Shimmed payload. No Lua is running.',
      durationMs: 60000
    })
    send('opx:hud:gauges', {
      gauges: [
        { id: 'health', label: 'demo.gauge.health', value: 78, tone: 'health' },
        { id: 'armour', label: 'demo.gauge.armour', value: 34, tone: 'warn' }
      ]
    })
  } else {
    send('opx:panel:open', {
      title: 'demo.title',
      eyebrow: 'demo.eyebrow',
      tabs: [
        { id: 'chrome', label: 'demo.tab.chrome' },
        { id: 'stock', label: 'demo.tab.stock', marked: true },
        { id: 'log', label: 'demo.tab.log' }
      ],
      // Deliberately `{}` and not `[]`: this is what an empty Lua table actually
      // serialises to, and every list guard in the app exists because of it.
      rows: {}
    })
  }
}
