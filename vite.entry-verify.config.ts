// TEMPORARY. Builds ui/entry-verify.html -- the modal surface carrying the entry
// module and nothing else -- through the REAL vite.config.ts, so the inline-surface
// plugin under test is the shipped one. Deleted once the check has run.
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import base from './vite.config'

const here = dirname(fileURLToPath(import.meta.url))

export default (env: { command: 'build' | 'serve'; mode: string }) => {
  const config = (base as unknown as (e: typeof env) => Record<string, any>)({
    ...env,
    mode: 'modal'
  })
  config.build.outDir = resolve(here, '.entry-verify')
  config.build.emptyOutDir = true
  config.build.rollupOptions.input = resolve(here, 'ui/entry-verify.html')
  config.plugins = config.plugins.filter((plugin: any) => plugin && plugin.name !== 'opx-copy-probe')
  return config
}
