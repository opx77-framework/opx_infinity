/**
 * What the entry screen is told, once it has been coerced.
 *
 * Nothing here is a fact the page owns. Every field is the last thing Lua said,
 * parsed on arrival so the template never reaches into an `unknown` and a
 * malformed payload cannot render half a card.
 */

/** Lua's frame generation. Echoed on every emit; a stale one is dropped. */
export type Handle = string | number

/** Which of the two things the one panel is showing. */
export type Mode = 'roster' | 'create'

/** One roster card. Lua resolves every string; the page holds no English. */
export interface Card {
  id: string
  kind: 'character' | 'empty' | 'create'
  /** The character's name, or the empty slot's label. */
  name: string
  /** One or two initials for the plate that stands in for a portrait. */
  monogram: string
  /** `ID 77ABC123`, or the slot number. */
  identifier: string
  lifepath: string
  body: string
  role: string
  affiliation: string
  lastSeen: string
  /** The sentence an empty slot or the create card carries instead of facts. */
  note: string
  disabled: boolean
}

/** One row of the creation form's current step. */
export interface Row {
  id: string
  /** `text` is typed, `choice` is picked, `fact` is read back on the last step. */
  kind: 'text' | 'choice' | 'fact'
  label: string
  value: string
  placeholder: string
  note: string
  /** Text rows only: the character bound Lua and the server both enforce. */
  max: number
  chosen: boolean
}

/** One pip on the step rail. */
export interface StepMark {
  id: string
  label: string
}

/** The two footer buttons, worded by Lua. */
export interface FormActions {
  back: string
  next: string
  submit: string
}

/** The whole creation frame for one step. */
export interface FormFrame {
  step: string
  index: number
  total: number
  steps: StepMark[]
  count: string
  about: string
  /** Which of the five answers a `choice` step sets. Empty on the others. */
  field: string
  rows: Row[]
  values: Record<string, string>
  actions: FormActions
  /** The review step, where continue becomes submit. */
  last: boolean
  busy: boolean
  /** Already a sentence in the player's language: Lua resolved the locale key. */
  error: string
  errorField: string
  warning: string
}

/** One keycap hint in the footer. Lua names the key; the page has no layout. */
export interface KeyHint {
  key: string
  label: string
}

/** The five answers, as the player has typed or picked them so far. */
export type Draft = Record<string, string>
