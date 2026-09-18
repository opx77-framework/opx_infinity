/**
 * The grid's fixed geometry, taken from `opx77_inventory/web/inventory.css`.
 *
 * ONE SOURCE, because two need it and they are in different files: the grid
 * virtualises and therefore has to know the numbers in JS, and the view sizes the
 * panel from them in CSS. The old resource kept them as `--slot`, `--slot-gap`,
 * `--columns` and `--rows` in one `:root` block and did not virtualise, so CSS
 * alone was enough there; here the same four numbers have to be readable from
 * both sides, and a copy in each is a drift waiting to happen.
 *
 * WHY THEY ARE FIXED AT ALL. The grid used to measure its own width and choose a
 * column count from it, which meant the bag re-columned itself whenever the
 * window changed size or the second panel appeared -- a slot was never twice in
 * the same place. The old resource sized the grid absolutely and scaled the whole
 * pair to fit instead, so five columns of one square is what a player learns
 * whatever surface they are on. That is the positioning the owner asked for back.
 */

/** One cell, square. `--slot` in the old stylesheet. */
export const CELL = 90

/**
 * The gap between two cells.
 *
 * NOT the old resource's 6px, and this is the one number that could not be taken
 * verbatim. Our cells carry a 9-slice frame drawn with `border-image-width: 6px`
 * on a 1px border, which puts the visible stroke ~4.5px OUTSIDE each cell's
 * border box on every side. Two neighbours therefore need ~9px between their
 * boxes or their outlines collide and every internal edge is drawn twice. The old
 * cells were a background and a border with no spill, so 6px was free there.
 */
export const GAP = 10

/** Columns. `--columns` in the old stylesheet. */
export const COLUMNS = 5

/** Rows visible before the grid scrolls. `--rows` in the old stylesheet. */
export const ROWS = 7

/**
 * The gutter around the grid that the outermost cells' frame spill needs, or the
 * scroll container's own `overflow` shears their corner brackets off.
 */
export const BLEED = 5

/** The grid's outer width, gutter included. What a panel is as wide as. */
export const GRID_WIDTH = COLUMNS * CELL + (COLUMNS - 1) * GAP + BLEED * 2

/** The grid's outer height, gutter included. */
export const GRID_HEIGHT = ROWS * CELL + (ROWS - 1) * GAP + BLEED * 2
