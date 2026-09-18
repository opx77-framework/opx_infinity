<script setup lang="ts">
import { computed } from 'vue'
import { useLocale } from '@/composables/useLocale'
import { GLYPHS } from '@/modules/target/glyphs'

/**
 * ONE TOAST -- design pass 02.
 *
 * WHY THIS IS NOT `design/components/OpToast.vue`. It was, and that component is
 * still there untouched. Pass 02 is agreed on the menu surface only, and
 * `MenuView.vue` says what to do about that in as many words: it dropped `OpPanel`
 * and `OpRow` for local copies "because those two are shared... and changing them
 * changes every surface at once", and the local copy is deleted when the pass is
 * promoted into `design/`. `OpToast` has exactly one consumer -- this module -- so
 * nothing else moves when it is left behind, and the same rule applies for the same
 * reason: `ui/src/design/**` is off limits until the pass lands.
 *
 * WHAT CAME ACROSS FROM IT, unchanged: the shape (a leading icon column, a body, a
 * 2px lifetime bar), the `progress` contract (0..1, or -1 for "draw no bar", set by
 * width and never by a keyframe, because the bar tracks a deadline Lua is also
 * counting), and the rule that severity is one variable and moves as little as
 * possible. What did not: the fill, `data-augmented-ui`, `op-panel`, `op-lift`, the
 * `--op77-notch-clip` shape, and `--op77-accent` -- which `.op-theme-city` makes
 * Night City yellow on <html>, and pass 02 bans yellow outright.
 *
 * THE ICON IS A GLYPH NOW, not a text badge. `OpToast` took "up to a few characters
 * of caller text", which is what the PLATFORM's own notification package means by
 * `icon` (a short badge, at most 16 bytes). This surface is not that package: it is
 * our page, fed by `core/client/notify.lua`, so `icon` here is a name from the
 * closed glyph set and Lua refuses a toast naming anything outside it.
 */
const props = withDefaults(
  defineProps<{
    title: string
    message?: string
    /** A glyph name from the closed set Lua validates against, or '' for none. */
    icon?: string
    kind?: 'info' | 'success' | 'warning' | 'error'
    /** 0..1, or -1 for "draw no bar". Lua owns the lifetime; this is its remainder. */
    progress?: number
  }>(),
  { message: '', icon: '', kind: 'info', progress: -1 }
)

const { t, has } = useLocale()

/**
 * THE KIND, IN WORDS. Rule 8 of the pass: technical filler is content, and a
 * micro-label has to state something the surface actually knows. The kind is the
 * one thing every toast knows about itself, and now that toasts are the runtime's
 * only channel for "that worked" / "that failed" it is the thing a player most
 * needs off a glance -- so it is said outright rather than left to be inferred
 * from a frame's weight.
 *
 * A catalogue key first, because the page holds no English (see `useLocale`). The
 * fallback is not a sentence, it is a four-character mono tag of the same class as
 * `FormView`'s `FORM`, and it exists so this reads correctly before anyone adds
 * `notify.kind.*` to `locales/`. `has` rather than `t` alone: `t` renders a missing
 * key AS the key, and `notify.kind.error` in the tag slot would be worse than
 * nothing.
 */
const TAGS: Record<string, string> = {
  info: 'NOTICE',
  success: 'CONFIRMED',
  warning: 'CAUTION',
  error: 'FAILED'
}

const tag = computed(() => {
  const key = `notify.kind.${props.kind}`
  return has(key) ? t(key) : TAGS[props.kind]
})

/** The paths of one glyph, empty for a toast carrying none and for a name this page
    does not know. The set is CLOSED and Lua refuses a toast naming anything outside
    it, so an empty answer here means a toast with no icon, never a silent typo --
    the same call, for the same reason, as `MenuView.vue`'s `paths`.

    Imported from the target module rather than re-declared: it is one closed set,
    now shared by three surfaces. It belongs in `design/` and moves there when this
    pass is promoted. */
const glyph = computed<string[]>(() => (props.icon && GLYPHS[props.icon]) || [])

const barWidth = computed(() => `${Math.max(0, Math.min(1, props.progress)) * 100}%`)
</script>

<template>
  <article class="toast" :class="kind">
    <!-- No column is held open for an absent glyph, and this is the one place this
         surface parts with the menu. A row holds its icon column open so every
         label in a dense column lands on one x; a toast is three lines tall with a
         title of its own, arrives alone, and most of them carry no icon at all --
         so an empty 18px gutter on every toast would be paid for by all of them to
         align two that are rarely on screen together. -->
    <span v-if="glyph.length" class="glyph" aria-hidden="true">
      <svg viewBox="0 0 24 24">
        <path v-for="(d, at) in glyph" :key="at" :d="d" />
      </svg>
    </span>

    <div class="body">
      <span class="tag">{{ tag }}</span>
      <!-- A toast with no title is common (`inventory.change` sends none), and the
           tag standing in as the header line is why this order is tag-then-title. -->
      <span v-if="title" class="title">{{ title }}</span>
      <span v-if="message" class="message">{{ message }}</span>
    </div>

    <!-- Width, not a CSS animation: the bar has to track the deadline Lua is also
         counting, and a keyframe drifts from it the moment the surface is throttled. -->
    <span v-if="progress >= 0" class="bar" :style="{ width: barWidth }" />
  </article>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED. The style block of `MenuView.vue` is
   the spec; this is that idiom applied to a toast, and where it differs it says
   why in place.

   RED IS THE VOICE, SO RED CANNOT BE THE ALARM -- and a toast has four kinds,
   which is the hard version of that problem the menu only had to solve for one
   status line. A second saturated hue is not available: two hues on an unfilled
   red surface over live gameplay is the yellow `--op77-accent` mistake with extra
   steps. So the four kinds are told apart on THREE axes that are already in the
   language, and a fourth that is words:

     1. TONE SAYS WHETHER SOMETHING IS WRONG. Red for `info` and `success`; white
        (`--op77-text`) for `warning` and `error`. This is rule 4 read as a rule
        rather than an exception: the menu's failed status line goes white and
        heavier, so white already means "something is wrong" everywhere in this
        runtime, and success must therefore never take it.
     2. WEIGHT SAYS HOW LOUD. The frame's stroke climbs 1.4 -> 1.4 -> 1.8 -> 2.4
        across info, success, warning, error, and only `error` blooms -- the menu
        gives its bloom to the chosen row alone, and on a toast the equivalent of
        "the one thing you are looking at" is the one that failed.
     3. LIT VERSUS AT REST SEPARATES THE TWO QUIET KINDS. `info` is the resting
        red every menu row wears; `success` is the lit red of a chosen one, with
        the same widened tracking. The player learned that pair on the strip.
     4. AND THE KIND IS SAID IN WORDS, because the three above are read at a
        glance and a glance is all a toast gets.

   WHAT IS NOT USED for this: `--op77-danger`, `--op77-ok`, `--op77-warn`,
   `--op77-signal`, `--op77-accent`. Five tokens that would each have solved it in
   one line, and every one of them puts a second hue on the surface.
   ========================================================================== */

/* --- THE RED --------------------------------------------------------------
   Copied from `MenuView.vue` verbatim, for the reason given there: `.op-theme-city`
   makes `--op77-accent` Night City yellow for every surface, and repainting the HUD
   is a separate decision from settling these two. When the pass is agreed these
   move into that class and this block is deleted. `--red-hi` is the lit arete,
   which the menu names in the contract but only uses in its frame sprites. */
.toast {
  --red:      #ff3b47;                    /* lit                              */
  --red-deep: #c8202e;                    /* denser, no bloom                 */
  --red-idle: rgba(232, 67, 79, 0.62);    /* at rest                          */
  --red-hi:   #ff6b78;                    /* the lit arete                    */
  --red-glow: rgba(255, 59, 71, 0.55);

  /* THE 9-SLICE FRAMES, one per kind. 24x24, 8px corner tiles, the chamfer living
     entirely inside the top-right tile so stretching an edge can never skew it,
     exactly as the menu's rows are drawn -- and for the same documented reason:
     `clip-path` cuts the painted result, so a bordered box under one loses its
     stroke along the diagonal and the chamfer arrives as a GAP.

     THE FRAME IS ALSO WHY THIS IS NOT A CLIPPED PANEL. `error` blooms, a bloom is
     an OUTSET shadow, and a clip shears an outset shadow off the element. The menu
     can afford `clip-path` on its bay because its only shadows there are inset.

     TWO PATHS, NOT ONE, and this is the pair augmented-ui cannot express: the top
     and left runs (with the chamfer) take the lit arete, the right and bottom runs
     take the base tone. `border-image` slices them into edge tiles per side, so a
     lit leading edge and a darker trailing one survive any width the stack is set
     to -- which is the whole depth of this design on a surface with no fill. */
  --frame-info: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23ff6b78" stroke-opacity="0.5" stroke-width="1.4"/><path d="M23.5 8.5V23.5H0.5" fill="none" stroke="%23e8434f" stroke-opacity="0.62" stroke-width="1.4"/></svg>');
  --frame-success: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23ff6b78" stroke-width="1.4"/><path d="M23.5 8.5V23.5H0.5" fill="none" stroke="%23ff3b47" stroke-opacity="0.85" stroke-width="1.4"/></svg>');
  --frame-warning: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23e8434f" stroke-width="1.8"/><path d="M23.5 8.5V23.5H0.5" fill="none" stroke="%23c8202e" stroke-width="1.8"/></svg>');
  --frame-error: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 23.5V0.5H15.5L23.5 8.5" fill="none" stroke="%23ff6b78" stroke-width="2.4"/><path d="M23.5 8.5V23.5H0.5" fill="none" stroke="%23ff3b47" stroke-width="2.4"/></svg>');
}

/* =============================================================================
   THE TOAST -- a closed 1px frame with a chamfered top-right corner, and text.
   Nothing behind it.

   `border-image-width` is 8px while `border-width` is 1px: the image draws its 8px
   corner tiles while layout only reserves one, so the chamfer is full size and the
   toast still sits on a 1px box.
   ========================================================================== */
.toast {
  position: relative;
  display: flex;
  align-items: flex-start;
  gap: var(--op77-space-3);
  /* The right pad clears the chamfer, so a long title never runs under the cut. */
  padding: var(--op77-space-3) calc(var(--op77-space-4) + var(--op77-cut-md))
    var(--op77-space-3) var(--op77-space-4);
  color: #e8646d;
  /* NO BACKGROUND. `--op77-notify-veil` is this surface's dial, the same escape
     hatch `--op77-menu-veil` is for the menu and 0 for the same reason: an unbacked
     sentence over a blown-out daylight plaza is gone, and this takes that risk
     deliberately with one number to reverse it. Around 0.5 if toasts wash out --
     and a toast has a stronger claim on it than the menu does, because a player
     cannot re-open one to read it again. */
  /* THE DIAL IS TURNED ON. Same call, same reason, as `.bay` in MenuView.vue:
     the owner read the unbacked surfaces in game as illegible and asked for a
     background under everything carrying text, and this dial is the one number
     that was left here so the decision would not need a rewrite. The rgb moves
     from this file's own near-black to `--op77-plate`'s, so a toast and the
     surface it lands over share one ground instead of two that nearly match. */
  background: rgba(28, 8, 9, var(--op77-notify-veil, 0.78));
  /* EVERYTHING CARRIES A BLACK SHADOW, and it INHERITS -- one declaration for the
     tag, the title and the message. Two passes: the tight dark one gives an edge
     its contrast, the wide soft one lifts the toast off a bright backdrop. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
  border: 1px solid transparent;
  border-image-source: var(--frame-info);
  border-image-slice: 8;
  border-image-width: 8px;
  /* The frame needs its own: a 1.4px stroke over a daylight plaza is gone. A
     border-image cannot take a shadow, so this is a soft outset one on the box --
     rectangular where the frame is chamfered, which at this blur reads as the
     corner darkening rather than as a second shape. */
  /* NO OUTSET BLACK HERE. It followed the BORDER BOX and squared off the very
     corner the chamfer cuts. The black is a wide under-stroke inside the sprite
     now, which follows the diagonal exactly -- the same fix every chamfered
     element in the runtime took. */
  /* A toast can change kind mid-life (`notify:update`), and that is the only state
     change it has. `border-image-source` is not animatable, so the tone cuts with
     the frame in one step -- which is the rule anyway: it cuts, it does not fade. */
  transition: color var(--op77-dur-fast) linear;
}

/* THE INTERLACE. It is over the panel in every frame of the reference and it is
   what stops an unfilled surface reading as a web page floating in the air. One
   static gradient on a pseudo-element nothing else is using, no transition, so it
   costs a single paint for the life of the toast. Last in paint order, so it lies
   over the lifetime bar as it does over everything in the menu's bay. */
.toast::after {
  content: "";
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: repeating-linear-gradient(
    to bottom,
    rgba(255, 59, 71, 0.05) 0 1px,
    transparent 1px 3px
  );
}

.glyph {
  flex: none;
  display: block;
  width: 18px;
  height: 18px;
  /* Optically on the tag's cap line rather than its box top. */
  margin-top: 2px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  /* The stroke follows the toast's colour, so the glyph restates the kind without a
     second declaration anywhere -- including going white on a warning and an error. */
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
  /* A stroke takes no text-shadow. One drop-shadow on an 18px icon is the cheapest
     filter this surface could be asked to carry, and the only one on it. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
}

.body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.tag {
  font: 600 var(--op77-fs-micro) / 1 var(--op77-font-mono);
  letter-spacing: var(--op77-track-micro);
  text-transform: uppercase;
}

.title {
  font: 700 var(--op77-fs-title) / 1.15 var(--op77-font-display);
  letter-spacing: var(--op77-track-head);
  text-transform: uppercase;
  /* A title is one caller-supplied line and may be a single long token. */
  overflow-wrap: anywhere;
}

.message {
  font: 400 var(--op77-fs-body) / 1.35 var(--op77-font-body);
  color: var(--op77-text-dim);
  overflow-wrap: anywhere;
}

/* The lifetime bar is the second and last mark on this surface that is filled, and
   it is the same kind of thing as the menu's 13px tick: a mark, not a backdrop. An
   outlined 2px meter is not a meter, and a remaining-time readout is the one piece
   of a toast that cannot be drawn as a stroke. */
.bar {
  position: absolute;
  left: 0;
  bottom: 0;
  height: 2px;
  background: var(--red-idle);
}

/* =============================================================================
   THE FOUR KINDS. Each one moves the frame (one property), the tone, and nothing
   else it does not have to.
   ========================================================================== */

/* INFO -- the resting red of a menu row, the thinnest frame, no bloom. The
   baseline: red is the voice, and this is the voice saying something ordinary. */
.info {
  border-image-source: var(--frame-info);
}

/* SUCCESS -- the same thin frame lit to full red, the text lit with it, and the
   widened tracking the menu gives a chosen row. Brighter than info, not louder:
   nothing is wrong, so nothing goes white and nothing blooms. */
.success {
  color: var(--red);
  border-image-source: var(--frame-success);
}

.success .title {
  letter-spacing: 0.055em;
}

.success .bar {
  background: var(--red);
}

/* WARNING -- white and denser. The frame takes the middle red (`--red-deep`) at a
   heavier stroke, which is the menu's hover step: denser rather than brighter,
   because a red that loses brightness on a night street loses the toast with it.
   The words go white because something is wrong. Still no bloom: a warning is not
   the loudest thing that can happen. */
.warning {
  color: #ffa8ae;
  border-image-source: var(--frame-warning);
}

.warning .bar {
  background: var(--red-deep);
}

/* ERROR -- white, the heaviest frame, and the one bloom on the surface. The message
   takes full-strength text as well, which `OpToast` had as its single documented
   exception and was right about: a dim grey line inside a bright frame is the one
   combination that fails to read. The bloom is a `box-shadow` and not a `filter`:
   a filter here would give the toast its own backing store on a page that
   composites over live gameplay. */
.error {
  color: #ffa8ae;
  border-image-source: var(--frame-error);
  /* The bloom only: the black went into the sprite. A wide blur has no edge for
     the chamfer to disagree with, so it stays a box-shadow. */
  box-shadow: 0 0 18px -4px var(--red-glow);
}

.error .message {
  color: #ffa8ae;
}

.error .bar {
  background: var(--red);
}
</style>
