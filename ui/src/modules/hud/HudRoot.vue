<script setup lang="ts">
import { onMounted, ref, shallowRef } from 'vue'
import { emit } from '@/bridge/channel'
import { num } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import HudInfo from './HudInfo.vue'
import HudStatus from './HudStatus.vue'
import HudVehicle from './HudVehicle.vue'
import HudVitals from './HudVitals.vue'
import HudVoice from './HudVoice.vue'
import { anchorOf } from './anchors'
import type { Anchor } from './anchors'

/**
 * THE HUD -- the port of `opx77_hud/web/{index.html,hud.js,hud.css}`.
 *
 * This file owns the LAYOUT and nothing else: where each block sits, and whether the HUD
 * is on screen at all. Every block below subscribes to its own channel and holds its own
 * state, which is the split that matters on this surface -- the vitals stream runs at
 * roughly 30 Hz and the money line changes when the player is paid. One `opx:hud:frame`
 * carrying both, as hud.js had, means re-rendering the street cred thirty times a second
 * to move a health bar.
 *
 * HIDDEN IS NOT UNMOUNTED. `open` is an opacity, exactly as `body.open` was in hud.css: a
 * block taken out of layout replays its entrance when it comes back, and every clock
 * under here keeps running while it is off screen, so what comes back is current rather
 * than a frame from before the player went down.
 *
 * DEFAULT VISIBLE. There is no Lua module behind `opx:hud:config` or `opx:hud:show` yet.
 * A HUD that waited for permission to draw would be a black screen until someone wrote
 * one, and on the surface that "must not stop drawing for any reason" the safe default is
 * on. Lua turns it off; Lua does not have to turn it on.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THIS FILE IS ALSO THE HUD'S PALETTE. The five blocks below are five scoped
 * stylesheets and a scoped rule cannot reach into a child component, but a CUSTOM
 * PROPERTY set on `.hud` inherits down the whole tree regardless of scoping. So the
 * three red steps, the alarm, the five 9-slice frames and the black ink shadow are
 * declared once, here, and every block reads them. One place to change the voice of the
 * surface, and no `:deep()` anywhere.
 *
 * THE HUD IS NO LONGER CYAN. tokens.css says "the HUD stays cyan deliberately: cyan is
 * the platform speaking, yellow is the world speaking", and that distinction is over --
 * `--op77-accent` is not read by any file in this folder any more, which also means
 * `.op-theme-city` can no longer turn a health bar Night City yellow.
 *
 * THE INK SHADOW IS ONE DECLARATION. `text-shadow` inherits, and this surface has no
 * backing of any kind, so every glyph under `.hud` -- in every block -- is carried by the
 * pair below. A block that wants a red bloom on a word restates BOTH passes plus the
 * bloom, because an override replaces the whole list.
 */

interface Layout {
  anchor: Anchor
  infoAnchor: Anchor
  statusAnchor: Anchor
  /** Pixels of clearance between the status strip and the vitals column beneath it. */
  statusOffset: number
  vehicleAnchor: Anchor
  width: number
  segments: number
  voiceSegments: number
}

const DEFAULTS: Layout = {
  anchor: 'bottom-left',
  infoAnchor: 'top-right',
  statusAnchor: 'bottom-left',
  statusOffset: 120,
  vehicleAnchor: 'bottom-center',
  width: 210,
  segments: 10,
  voiceSegments: 8
}

const layout = shallowRef<Layout>(DEFAULTS)
const visible = ref(true)

useBridge('opx:hud:config', (payload: Payload) => {
  const anchor = anchorOf(payload.anchor, DEFAULTS.anchor)
  const segments = Math.round(num(payload.segments, DEFAULTS.segments))
  const voiceSegments = Math.round(num(payload.voiceSegments, DEFAULTS.voiceSegments))
  const width = num(payload.width, DEFAULTS.width)
  const statusOffset = num(payload.statusOffset, DEFAULTS.statusOffset)

  layout.value = {
    anchor,
    infoAnchor: anchorOf(payload.infoAnchor, DEFAULTS.infoAnchor),
    // The strip rides in the vitals column's corner until Lua says otherwise, which is
    // hud.js `stripFallback` -- and it has to be read out of THIS payload's anchor, not
    // the one that was in force before it.
    statusAnchor: anchorOf(payload.statusAnchor, anchor),
    statusOffset: statusOffset >= 0 ? Math.round(statusOffset) : DEFAULTS.statusOffset,
    vehicleAnchor: anchorOf(payload.vehicleAnchor, DEFAULTS.vehicleAnchor),
    width: width > 0 ? Math.round(width) : DEFAULTS.width,
    // Two is the fewest that still reads as segmented rather than as a light.
    segments: segments >= 2 ? segments : DEFAULTS.segments,
    voiceSegments: voiceSegments >= 2 ? voiceSegments : DEFAULTS.voiceSegments
  }
})

useBridge('opx:hud:show', (payload: Payload) => {
  // `!== false` and not `=== true`: any other value, `nil` included, shows. That is the
  // `setVisible` contract in opx77_hud/client/exports.lua and players inherit it.
  visible.value = payload.visible !== false
})

onMounted(() => {
  emit('opx:hud:ready', {})
})
</script>

<template>
  <div class="hud" :class="{ open: visible }">
    <div class="at" :class="layout.anchor">
      <HudVitals :segments="layout.segments" :width="layout.width" />
    </div>

    <div class="at" :class="layout.infoAnchor">
      <HudInfo :anchor="layout.infoAnchor" />
    </div>

    <div
      class="at"
      :class="layout.statusAnchor"
      :style="{ '--block-offset': layout.statusOffset + 'px' }"
    >
      <HudStatus />
    </div>

    <div class="at" :class="layout.vehicleAnchor">
      <HudVehicle />
    </div>

    <!-- The voice block pins itself: it is the one read-out with no anchor, because the
         right edge at eye level is the only place a mic has ever been on this HUD. It
         therefore carries its own perspective and its own tilt sign; every other block
         gets both from the `.at` it sits in. -->
    <HudVoice :segments="layout.voiceSegments" />
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED. The HUD's half of it.

   The menu settled the language and this folder takes it. What is different
   about the HUD, and what every decision below turns on:

     * IT REPAINTS CONTINUOUSLY. A menu changes when a key is pressed; the
       vitals stream is ~30 Hz and the speedometer moves whenever the car does.
       So the rules that are advisory on a menu are load-bearing here: no
       `filter` on anything whose value changes, no fill that has to be
       re-rasterised, and a moving quantity moves by `transform` -- the one
       thing the compositor can do without a repaint at all.
     * IT HAS NO BACKING WHATSOEVER. Not even the menu's veil dial is raised.
       Every glyph sits on live gameplay, which is why `text-shadow` is
       declared once here and inherited by all five blocks.
     * IT IS FIVE CLUSTERS, NOT ONE SURFACE. Each is anchored to a different
       screen edge, so each gets its own tilt sign -- and the one Lua anchors
       to a centre gets none.
   ========================================================================== */

.hud {
  /* --- THE RED -------------------------------------------------------------
     The menu's three steps, verbatim, meaning the same things in the same
     order: dim at rest, denser in the middle, lit at the top.

     THE HUD HAS NO HOVER. `.layer-overlay` in SurfaceRoot.vue sets
     `pointer-events: none` and nothing in this folder re-enables it, so
     `--red-deep` -- the menu's pointer step -- is unspent here, and it goes on
     the middle rung of a STATE ladder instead: voice `detected` sits between
     `idle` and `talking` exactly where hover sat between rest and chosen. */
  --red:      #ff3b47;                    /* lit: live, on, talking           */
  --red-deep: #c8202e;                    /* denser: the middle rung          */
  --red-idle: rgba(232, 67, 79, 0.62);    /* at rest                          */
  --red-hi:   #ff6b78;                    /* the lit arete, and `warn`        */
  --red-glow: rgba(255, 59, 71, 0.55);

  /* --- THE ALARM, WHICH IS NOT RED ----------------------------------------
     Rule 4 of the contract, carried from a menu's status line to a gauge: red
     is the VOICE of this surface, so it cannot also be its alarm. A red bar
     going redder inside a red frame on an all-red HUD says nothing.

     The escalation is therefore LUMINANCE inside one hue, and then out of it:

         rest   --red-idle   a pale wash
         live   --red        lit
         warn   --red-hi     the brightest red on the surface
         bad    --alarm      WHITE-HOT, and heavier with it

     White is the one thing on this HUD that cannot be mistaken for the HUD
     talking about itself; it is the highest contrast the palette owns
     (16.2:1); and a bar that goes white changes FAMILY rather than shade,
     which is what an alarm has to do to be read without being looked at.
     `--op77-danger` is not used anywhere in this folder. */
  --alarm: #ffa8ae;

  /* --- THE 9-SLICE FRAMES --------------------------------------------------
     Copied from MenuView.vue and extended by two, because the HUD needs two
     rungs a menu has no use for. 24x24, 8px corner tiles, the chamfer living
     entirely inside the top-right tile so stretching an edge can never skew
     it.

     `clip-path` cannot draw this: a clip cuts the painted result, so a
     bordered box under one loses its stroke along the diagonal and the chamfer
     arrives as a GAP. A state change swaps `border-image-source` -- one
     property -- and the geometry never distorts with the element's width.

     A small item (a chip, a keycap, a gauge track) sets `border-image-width`
     BELOW the 8px slice, which scales the whole corner tile down rather than
     needing a second set of sprites at a second size. */
  --frame-idle: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23e8434f" stroke-opacity="0.7" stroke-width="1.4"/></svg>');
  --frame-live: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23ff3b47" stroke-width="2"/></svg>');
  --frame-hot: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23ff6b78" stroke-width="2"/></svg>');
  --frame-alarm: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23ffa8ae" stroke-width="2.6"/></svg>');
  --frame-off: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="4.5"/><path d="M0.5 0.5H15.5L23.5 8.5V23.5H0.5Z" fill="none" stroke="%23aed3e0" stroke-opacity="0.14"/></svg>');

  /* A border-image cannot take a shadow, so the black under a frame is a soft
     OUTSET one on the box -- rectangular where the frame is chamfered, which
     at this blur and alpha reads as the corner darkening rather than as a
     second shape. Named because nine elements across five files want the same
     one. */
  --hud-shadow: 0 1px 7px rgba(0, 0, 0, 0.55);

  /* How much room a cluster's shadows and blooms need INSIDE its wrapper. The
     wrapper clips (see `.at`), so the bleed is padding and the anchor offsets
     pay it straight back. */
  --hud-bleed: 10px;

  /* The interlace, for the two clusters that have an enclosing frame to put it
     on. Declared here so both draw the same one. */
  --hud-interlace: repeating-linear-gradient(
    to bottom,
    rgba(255, 59, 71, 0.05) 0 1px,
    transparent 1px 3px
  );

  position: absolute;
  inset: 0;
  opacity: 0;

  /* THE ONE INK SHADOW FOR THE WHOLE HUD. It inherits, so this single
     declaration carries every label, every number and every readout in all
     five blocks. Two passes: the tight dark one gives a glyph its edge, the
     wide soft one lifts it off a blown-out plaza. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);

  /* Layout and style containment here; the PAINT containment is one level down,
     on each cluster, which is where it buys something and where the bleed has
     been budgeted for it. Note what layout containment already does: it makes
     this element the containing block for its `position: fixed` children. That
     is safe only because `.hud` is `inset: 0` inside `.layer-overlay`, which is
     itself fixed at `inset: 0` -- so this box IS the viewport box and every
     `.at` lands exactly where it did before. Take that guarantee away and the
     five clusters move. */
  contain: layout style;
  /* It cuts, it does not fade. */
  transition: opacity 190ms steps(3, end);
}

.hud.open {
  opacity: 1;
}

/* =============================================================================
   A CLUSTER'S WRAPPER -- the positioned element, so this is what carries the
   perspective, the containment and the tilt SIGN. The block inside it is the
   plane that rotates; perspective on the plane itself would give every
   descendant its own vanishing point.

   THE BLEED. `contain: paint` clips to the padding box, and a black shadow or
   a bloom landing outside it is simply gone -- so the wrapper is padded by
   `--hud-bleed` and every anchor offset below subtracts the same amount. The
   cluster ends up exactly where `--op77-inset-*` put it, with 10px of room
   around it that nothing can paint outside of.
   ========================================================================== */
.at {
  position: fixed;
  box-sizing: border-box;
  display: flex;
  padding: var(--hud-bleed);
  max-width: calc(100vw - var(--op77-inset-x) * 2 + var(--hud-bleed) * 2);
  perspective: var(--op77-persp);
  contain: layout paint style;
}

.bottom-left,
.top-left {
  left: calc(var(--op77-inset-x) - var(--hud-bleed));
  justify-content: flex-start;
  /* A LEFT-anchored surface gets +7deg and pivots on the left edge. */
  --tilt: var(--op77-tilt);
  --origin: left center;
}

.bottom-right,
.top-right {
  right: calc(var(--op77-inset-x) - var(--hud-bleed));
  justify-content: flex-end;
  /* A RIGHT-anchored one gets -7deg and pivots on the right. */
  --tilt: calc(var(--op77-tilt) * -1);
  --origin: right center;
}

/* A CENTRED CLUSTER GETS NO TILT. There is no edge for it to recede towards,
   and 7deg about its own middle is not a plane on the inside of a visor -- it
   is a card lying on a table. */
.top-center,
.bottom-center {
  left: 50%;
  transform: translateX(-50%);
  justify-content: center;
  --tilt: 0deg;
  --origin: center center;
}

.bottom-left,
.bottom-right,
.bottom-center {
  bottom: calc(var(--op77-inset-y) + var(--block-offset, 0px) - var(--hud-bleed));
}

.top-left,
.top-right,
.top-center {
  top: calc(var(--op77-inset-y) + var(--block-offset, 0px) - var(--hud-bleed));
}
</style>
