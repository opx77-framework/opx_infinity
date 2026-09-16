import HudDemo from '@/modules/hud/HudDemo.vue'
import { createSurface } from './createSurface'
import { registerModule } from './registry'
import SurfaceRoot from './SurfaceRoot.vue'

/**
 * THE OVERLAY SURFACE -- z 700, 30fps, transparent, never focused, never destroyed.
 *
 * It is the HUD. It is created once at spawn and torn down at disconnect, and between
 * those two moments it must not stop drawing for any reason. That is why the heavy,
 * fallible, player-driven work lives on a second surface: an exception in a shop view
 * must not be able to blank the health bar.
 */
registerModule({ id: 'hud', surface: 'overlay', component: HudDemo })

createSurface({
  name: 'overlay',
  root: SurfaceRoot,
  rootProps: { surface: 'overlay' },
  // Never. A HUD that takes focus takes the player's controls with it.
  allowFocus: false
})
