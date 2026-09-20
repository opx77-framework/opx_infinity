import type { CatalogEntry, ScreenConfig, Stack } from './types'

/**
 * Turning a stack into the words and the picture a cell shows.
 *
 * Presentation only. Nothing here is sent anywhere: a weight computed on this
 * page is a number for a label, and the total that matters is the one Lua puts
 * in every container payload.
 */

/** Where the 195 item pictures live once the build has copied `ui/public`. */
const IMAGE_BASE = 'images/'

/**
 * The picture for an item whose catalogue file name is already known.
 *
 * Split out of `imageFor` for the hotbar peek, which draws on the OVERLAY layer
 * and has no catalogue: the interactive screen holds it, the overlay does not,
 * so Lua resolves the five rows and sends the file name with them. Both callers
 * go through this so the base path is written once -- a second copy of
 * `images/` is the kind of thing that survives a folder rename by half.
 */
export function imageFromFile(name: string, file: string): string {
  return `${IMAGE_BASE}${file || `${name}.png`}`
}

/** Relative, and served by the resource itself: the surface has no network. */
export function imageFor(name: string, entry: CatalogEntry | undefined): string {
  return imageFromFile(name, entry && entry.image ? entry.image : '')
}

/** The fallback a picture that will not load leaves behind. */
export function monogram(label: string): string {
  const words = label.trim().split(/\s+/).filter(Boolean)
  if (words.length === 0) return '?'
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase()
  return (words[0][0] + words[1][0]).toUpperCase()
}

export function labelOf(stack: Stack, entry: CatalogEntry | undefined, unknown: string): string {
  const named = entry ? entry.label : ''
  if (named) return named
  const fromMetadata = stack.metadata.label
  if (typeof fromMetadata === 'string' && fromMetadata) return fromMetadata
  return stack.name || unknown
}

export function weightOf(stack: Stack, entry: CatalogEntry | undefined, fallback: number): number {
  const each = entry ? entry.weight : fallback
  return each * stack.count
}

/** Grams under a kilogram, kilograms above it, both to one decimal at most. */
export function grams(value: number, config: ScreenConfig): string {
  const kg = config.labels.kg || 'kg'
  const g = config.labels.g || 'g'
  if (value < 1000) return `${Math.round(value)}${g}`
  const whole = value / 1000
  return `${whole >= 100 ? Math.round(whole) : Math.round(whole * 10) / 10}${kg}`
}

/** 0..100, for the load gauge. Clamped: a container over its limit reads full. */
export function loadPercent(weight: number, maxWeight: number): number {
  if (maxWeight <= 0) return 0
  return Math.max(0, Math.min(100, (weight / maxWeight) * 100))
}

/** A stack's condition, 0..1, when it carries one. -1 when it does not. */
export function durabilityOf(stack: Stack): number {
  const value = stack.metadata.durability
  if (typeof value !== 'number' || !Number.isFinite(value)) return -1
  return Math.max(0, Math.min(1, value > 1 ? value / 100 : value))
}

/** The rounds a weapon stack carries, or -1 when it is not a weapon. */
export function ammoOf(stack: Stack): number {
  const value = stack.metadata.ammo
  if (typeof value !== 'number' || !Number.isFinite(value)) return -1
  return Math.max(0, Math.round(value))
}

export function serialOf(stack: Stack): string {
  const value = stack.metadata.serial
  return typeof value === 'string' ? value : ''
}
