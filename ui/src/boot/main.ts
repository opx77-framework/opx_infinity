import EntryView from '@/modules/entry/EntryView.vue'
import FormView from '@/modules/form/FormView.vue'
import HudRoot from '@/modules/hud/HudRoot.vue'
import InventoryView from '@/modules/inventory/InventoryView.vue'
import MenuView from '@/modules/menu/MenuView.vue'
import NotifyRoot from '@/modules/notify/NotifyRoot.vue'
import PanelView from '@/modules/panel/PanelView.vue'
import PromptsRoot from '@/modules/prompts/PromptsRoot.vue'
import TargetView from '@/modules/target/TargetView.vue'
import { createSurface } from './createSurface'
import { registerModule } from './registry'
import SurfaceRoot from './SurfaceRoot.vue'

/**
 * THE SURFACE -- one CEF page, two layers.
 *
 * This was two pages. One build is simpler, and the duplication it removed was not
 * small: eight woff2 faces at 158 kB byte-identical in both, plus the Vue runtime and
 * the whole design system, twice. ~400 kB of 926.
 *
 * `surface` on a registration is now a LAYER inside this page, and it still matters:
 *   overlay  the HUD. Never focused, never takes a pointer, always drawn.
 *   modal    everything the player drives. Takes focus and the cursor when open.
 *
 * `allowFocus` is true because the page as a whole can be focused; `configureFocus`
 * no longer refuses it for the HUD, so the rule that a HUD must not ask for focus is
 * now carried by the layer a module registers on rather than by the surface it lives
 * on. A HUD module calling `acquireFocus` would take the player's controls away, and
 * nothing in the code stops it -- which is the one guarantee this merge gave up.
 */
registerModule({ id: 'hud', surface: 'overlay', component: HudRoot })
registerModule({ id: 'notify', surface: 'overlay', component: NotifyRoot })
registerModule({ id: 'prompts', surface: 'overlay', component: PromptsRoot })

registerModule({ id: 'entry', surface: 'modal', component: EntryView })
registerModule({ id: 'inventory', surface: 'modal', component: InventoryView })
registerModule({ id: 'menu', surface: 'modal', component: MenuView })
registerModule({ id: 'form', surface: 'modal', component: FormView })
registerModule({ id: 'panel', surface: 'modal', component: PanelView })
registerModule({ id: 'target', surface: 'modal', component: TargetView })

createSurface({
  name: 'ui',
  root: SurfaceRoot,
  rootProps: {},
  allowFocus: true
})
