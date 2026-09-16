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
         right edge at eye level is the only place a mic has ever been on this HUD. -->
    <HudVoice :segments="layout.voiceSegments" />
  </div>
</template>

<style scoped>
.hud {
  position: absolute;
  inset: 0;
  opacity: 0;
  transition: opacity var(--op77-dur) var(--op77-ease);
}

.hud.open {
  opacity: 1;
}

.at {
  position: fixed;
  display: flex;
  max-width: calc(100vw - var(--op77-inset-x) * 2);
}

.bottom-left,
.top-left {
  left: var(--op77-inset-x);
  justify-content: flex-start;
}

.bottom-right,
.top-right {
  right: var(--op77-inset-x);
  justify-content: flex-end;
}

.top-center,
.bottom-center {
  left: 50%;
  transform: translateX(-50%);
  justify-content: center;
}

.bottom-left,
.bottom-right,
.bottom-center {
  bottom: calc(var(--op77-inset-y) + var(--block-offset, 0px));
}

.top-left,
.top-right,
.top-center {
  top: calc(var(--op77-inset-y) + var(--block-offset, 0px));
}
</style>
