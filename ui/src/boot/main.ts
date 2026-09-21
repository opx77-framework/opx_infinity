import ChatInput from '@/modules/chat/ChatInput.vue'
import ChatLog from '@/modules/chat/ChatLog.vue'
import DownedView from '@/modules/downed/DownedView.vue'
import FormView from '@/modules/form/FormView.vue'
import HudRoot from '@/modules/hud/HudRoot.vue'
import InventoryView from '@/modules/inventory/InventoryView.vue'
import MenuView from '@/modules/menu/MenuView.vue'
import NotifyRoot from '@/modules/notify/NotifyRoot.vue'
import PanelView from '@/modules/panel/PanelView.vue'
import ProgressRoot from '@/modules/progress/ProgressRoot.vue'
import SlotbarRoot from '@/modules/inventory/SlotbarRoot.vue'
import PromptsRoot from '@/modules/prompts/PromptsRoot.vue'
import SpawnView from '@/modules/spawn/SpawnView.vue'
import TagsRoot from '@/modules/tags/TagsRoot.vue'
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
registerModule({ id: 'progress', surface: 'overlay', component: ProgressRoot })

// THE INVENTORY IS TWO REGISTRATIONS for the same reason the chat is: two
// concerns on two layers. `InventoryView` below is the bag the player drives and
// takes focus; this is the few-second peek at the hotbar row, which is drawn
// over whatever the player is aiming at and must never take a pointer.
registerModule({ id: 'inventory-slotbar', surface: 'overlay', component: SlotbarRoot })

// Name tags draw over bodies in the world, so they are on the overlay and must
// never take focus: one that captured the keyboard would stop the player moving.
registerModule({ id: 'tags', surface: 'overlay', component: TagsRoot })

// The chat is ONE Lua module drawn as TWO registrations, because it is two
// concerns on two layers: the log is always drawn and never focused, the input
// line takes the keyboard. Lua already treats them as two views -- every payload
// it publishes names the layer it belongs to -- so this is the split it expects,
// not one imposed here.
registerModule({ id: 'chat-log', surface: 'overlay', component: ChatLog })
registerModule({ id: 'chat-input', surface: 'modal', component: ChatInput })

registerModule({ id: 'inventory', surface: 'modal', component: InventoryView })
registerModule({ id: 'menu', surface: 'modal', component: MenuView })
registerModule({ id: 'form', surface: 'modal', component: FormView })
registerModule({ id: 'panel', surface: 'modal', component: PanelView })
registerModule({ id: 'target', surface: 'modal', component: TargetView })

// The one screen a player is given rather than offered: a brand new character has no
// position, so where it starts is a question the server must have an answer to. It is
// on `modal` for the cursor, not for the style -- a spawn list nobody can click is the
// same as no choice at all.
registerModule({ id: 'spawn', surface: 'modal', component: SpawnView })

// The other screen a player is given rather than offered, and the one that MUST be
// `modal`: it is two controls, one of them held down for a second and a half, and the
// overlay layer is `pointer-events: none` for its whole height -- a death screen
// registered there would draw perfectly and refuse every press.
registerModule({ id: 'downed', surface: 'modal', component: DownedView })

createSurface({
  name: 'ui',
  root: SurfaceRoot,
  rootProps: {},
  allowFocus: true
})
