#!/usr/bin/env node
/**
 * Writes the curated Open77.props alias list the tests check every pile MODEL against.
 *
 *   scp root@<server>:/opt/open77-server/resources/system/open77_admin/shared/config.lua /tmp/
 *   node tools/generate-prop-aliases.mjs /tmp/config.lua
 *
 * WHERE THE LIST COMES FROM, AND WHY NOT FROM THE API. The alias table is compiled
 * into the client plugin (`kModelAliases` in the platform's `client/src/api/Props.cpp`)
 * and `Open77.props.catalog()` on the SERVER always answers an empty table, so nothing
 * this resource can call at boot says which names exist. The platform's own
 * `open77_admin` resource carries a mirror of that table by name -- `props.models` in
 * `shared/config.lua` -- and that file ships with every server build. It is read here
 * from the server the resource runs on, because the devkit documents an older build
 * than the one deployed and the deployed one is the one that answers `unknown_alias`.
 *
 * WRITES, and nothing else:
 *   tests/prop-aliases.lua   the alias names, sorted, with the build they were read from
 *
 * Test data and not shipped: a resource cannot use the list to refuse a model at run
 * time without ALSO refusing every alias a newer client adds, and the server already
 * refuses an unknown one loudly. What the list is for is catching a typo in
 * `modules/inventory/data/*.lua` before it reaches a server and becomes a crate.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'tests/prop-aliases.lua')

// The same shape `modules/inventory/shared/catalog.lua` accepts for a MODEL.
const ALIAS = /^[a-z0-9_]+(\.[a-z0-9_]+)+$/

const [source, build = 'unknown build'] = process.argv.slice(2)
if (!source) {
  console.error('usage: node tools/generate-prop-aliases.mjs <open77_admin/shared/config.lua> [build]')
  process.exit(1)
}

const text = readFileSync(source, 'utf8')

// `models = { ... }` inside the `props` block: the first `models` table after
// `props = {`. Comments inside it are stripped before the strings are read, so a
// name quoted in a comment is not mistaken for an alias.
const props = text.indexOf('props = {')
if (props < 0) throw new Error(`${source}: no \`props = {\` block`)
const open = text.indexOf('models = {', props)
if (open < 0) throw new Error(`${source}: no \`models = {\` inside the props block`)
const close = text.indexOf('}', open)
const body = text.slice(open, close).replace(/--[^\n]*/g, '')

const aliases = [...new Set([...body.matchAll(/"([^"]+)"/g)].map((m) => m[1]))].sort()
const bad = aliases.filter((alias) => !ALIAS.test(alias))
if (bad.length > 0) throw new Error(`not an alias: ${bad.join(', ')}`)
if (aliases.length < 100) throw new Error(`only ${aliases.length} aliases read; wrong file?`)

const lines = [
  '--- The curated Open77.props aliases, by name. GENERATED: do not edit by hand.',
  '-- @author dop42',
  '--',
  `-- node tools/generate-prop-aliases.mjs, from open77_admin/shared/config.lua (${build}).`,
  `-- ${aliases.length} aliases. tests/run.lua checks every pile MODEL against this list.`,
  '',
  'return {',
  ...aliases.map((alias) => `\t'${alias}',`),
  '}',
  ''
]
writeFileSync(OUT, lines.join('\n'))
console.log(`wrote ${aliases.length} aliases to ${OUT}`)
