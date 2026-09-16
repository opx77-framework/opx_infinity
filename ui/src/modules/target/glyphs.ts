/**
 * The row glyphs, carried over verbatim from `GLYPHS` in `opx77_target/web/target.js`.
 *
 * Inline path data and not an icon font: there is no network inside a CEF surface, so a
 * font would resolve to nothing and every row would show a blank box. Paths rather than
 * markup strings because the original built them with `createElementNS`, and `v-html` on
 * a payload-selected key is the same hole with a Vue accent.
 *
 * The set is CLOSED and Lua validates against the same names (`Model.ICONS`), so an
 * unknown name is a bug on one side or the other and falls back to `interact` rather
 * than travelling into an attribute nobody wrote.
 *
 * `currentColor` is what carries the tone rules down to the stroke, so nothing here
 * names a colour.
 */
export const GLYPHS: Record<string, string[]> = {
  interact: ['M8 12V5a2 2 0 0 1 4 0v6', 'M12 9h3l4 4v4l-3 4h-5l-6-7a2 2 0 0 1 3-2Z'],
  person: ['M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z', 'M4 21v-3a8 8 0 0 1 16 0v3'],
  vehicle: ['M4 10l2-6h12l2 6', 'M3 10h18v8H3Z', 'M5 18v3m14-3v3M6 14h2m8 0h2'],
  info: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z', 'M12 11v6m0-10v.2'],
  lock: ['M6 10V7a6 6 0 0 1 12 0v3', 'M4 10h16v11H4ZM12 14v3'],
  tool: ['M14 3a6 6 0 0 0-6 8l-6 6 5 5 6-6a6 6 0 0 0 8-7l-4 4-5-5 4-4Z'],
  location: ['M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z', 'M15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z'],
  box: ['M3 7l9-4 9 4v10l-9 4-9-4Z', 'M3 7l9 4 9-4M12 11v10'],
  door: ['M5 21V3h11l3 2v16', 'M3 21h18M13 12h.2'],
  heal: ['M9 3h6v6h6v6h-6v6H9v-6H3V9h6Z'],
  money: ['M2 6h20v12H2Z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM6 9v.2M18 15v.2'],
  talk: ['M4 4h16v12H9l-5 4Z', 'M8 9h8M8 12h5'],
  folder: ['M3 6h6l2 2h10v11H3Z'],
  back: ['M15 5l-7 7 7 7']
}

/** An unknown name draws the generic glyph, never nothing and never raw markup. */
export function glyphPaths(name: string): string[] {
  return GLYPHS[name] ?? GLYPHS.interact
}
