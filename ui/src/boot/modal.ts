import PanelDemo from '@/modules/panel/PanelDemo.vue'
import { createSurface } from './createSurface'
import { registerModule } from './registry'
import SurfaceRoot from './SurfaceRoot.vue'

/**
 * THE INTERACTIVE SURFACE -- z 740, 60fps, takes focus, created on demand.
 *
 * Above the overlay and destroyed when the player closes it, which is also the cheap
 * recovery path: a view wedged badly enough that ModuleHost cannot help is a surface
 * Lua can drop and re-create, with the HUD underneath never having noticed.
 *
 * 60fps because a pointer that lags is a pointer that feels broken; the overlay does
 * not need it and pays 30fps for the frame budget this one spends.
 *
 * Surfaces are capped at 8 per resource. Two of them are spoken for here; adding a
 * third means answering why it cannot be a module on one of these.
 */
registerModule({ id: 'panel', surface: 'modal', component: PanelDemo })

createSurface({
  name: 'modal',
  root: SurfaceRoot,
  rootProps: { surface: 'modal' },
  allowFocus: true
})
