--- Resource manifest: scripts, permissions and reload policy.
-- @author dop42
--
-- One file per line, in dependency order. Globs ARE allowed by the manifest
-- grammar and a `dependencies` directive does exist -- both were believed
-- otherwise here until the schema was read -- but a module's files load in an
-- order that matters, and a glob cannot express it. A file that is both listed
-- here and reached by `require` executes twice, so nothing uses `require`.
--
-- The manifest is Lua syntax, so a comment is legal inside a block as well as
-- here. The resource name is a lowercase slug of letters, digits and
-- underscores, and MUST equal the directory name -- a hyphen is not in the set.
--
-- `reload_policy "reconnect"` because this resource owns WebUI surfaces, and a
-- CEF page is never replaced in place.
--
-- Every permission below was checked against build 2.31.13+op77.75 through the
-- Open77 devkit. The ones that are not self-evident:
--   players.stats.apply   `Open77.players.setArmor`, re-applied after a respawn.
--                         NOT `players.damage.apply`, which does not exist at
--                         all -- armour was silently refused under that name
--   player.cyberware.read `Open77.appearance.captureBody` needs it ALONGSIDE
--                         player.appearance.read. Without it every other
--                         player's body goes undrawn, and the static validator
--                         misses it because the call is a pcall reference
--   players.disconnect    only for a connection with no verified identity.
--                         Releasing the gate alone would leave them in bucket 0
--                         with no character, for ever. Not a moderation tool
--   ui.vanilla.hud        hiding the game's own HUD while a player is down
--
-- `players.access` was declared here and is NOT required: it gates the
-- `Open77.access` door/ban list, and `Open77.players.all` needs no permission.

resource "opx-infinity"
version "0.1.0"
open77_version ">=2.31.13+op77.67"
auto_start true

reload_policy "reconnect"

shared_script "core/shared/main.lua"
shared_script "core/shared/channels.lua"
shared_script "core/shared/registry.lua"
shared_script "core/shared/lifecycle.lua"

shared_script "config/shared.lua"
server_script "config/server.lua"
client_script "config/client.lua"
shared_script "config/character.lua"
shared_script "config/needs.lua"
shared_script "config/downed.lua"
shared_script "config/weather.lua"
server_script "config/vehicles.lua"
shared_script "config/chat.lua"
shared_script "config/appearance.lua"
shared_script "config/inventory.lua"
shared_script "config/hud.lua"
shared_script "config/prompts.lua"
shared_script "config/target.lua"
shared_script "config/animations.lua"
shared_script "config/elevators.lua"

shared_script "lib/shared/result.lua"
shared_script "lib/shared/table.lua"
shared_script "lib/shared/string.lua"
shared_script "lib/shared/math.lua"
shared_script "lib/shared/text.lua"
shared_script "lib/shared/validate.lua"
shared_script "lib/shared/hooks.lua"
shared_script "lib/shared/locale.lua"
shared_script "locales/en.lua"
shared_script "locales/fr.lua"
shared_script "lib/shared/citizenid.lua"

server_script "lib/server/storage.lua"
server_script "lib/server/audit.lua"

server_script "core/server/sessions.lua"
server_script "core/server/answer.lua"
server_script "core/server/commands.lua"
server_script "core/server/gate.lua"
server_script "core/server/buckets.lua"
server_script "core/server/tunables.lua"

client_script "lib/client/rpc.lua"
client_script "lib/client/surface.lua"
client_script "lib/client/keys.lua"
client_script "core/client/scheduler.lua"
client_script "core/client/ui.lua"
client_script "core/client/notify.lua"

shared_script "modules/diagnostics/module.lua"
server_script "modules/diagnostics/server/main.lua"
client_script "modules/diagnostics/client/main.lua"

shared_script "modules/character/module.lua"
shared_script "modules/character/locales.lua"
server_script "modules/character/server/storage.lua"
server_script "modules/character/server/player.lua"
server_script "modules/character/server/groups.lua"
server_script "modules/character/server/character.lua"
server_script "modules/character/server/main.lua"
client_script "modules/character/client/main.lua"

shared_script "modules/appearance/module.lua"
shared_script "modules/appearance/locales.lua"
server_script "modules/appearance/server/storage.lua"
server_script "modules/appearance/server/main.lua"
client_script "modules/appearance/client/snapshot.lua"
client_script "modules/appearance/client/main.lua"
client_script "modules/appearance/client/editor.lua"
client_script "modules/appearance/client/clothing.lua"
client_script "modules/appearance/client/presence.lua"
client_script "modules/appearance/client/wardrobe.lua"

shared_script "modules/needs/module.lua"
shared_script "modules/needs/locales.lua"
server_script "modules/needs/server/storage.lua"
server_script "modules/needs/server/main.lua"
client_script "modules/needs/client/main.lua"

shared_script "modules/downed/module.lua"
shared_script "modules/downed/locales.lua"
server_script "modules/downed/server/storage.lua"
server_script "modules/downed/server/main.lua"
client_script "modules/downed/client/main.lua"

shared_script "modules/weather/module.lua"
shared_script "modules/weather/shared/clock.lua"
server_script "modules/weather/server/state.lua"
server_script "modules/weather/server/commands.lua"
server_script "modules/weather/server/main.lua"
client_script "modules/weather/client/main.lua"

shared_script "modules/vehicles/module.lua"
shared_script "modules/vehicles/locales.lua"
server_script "modules/vehicles/server/storage.lua"
server_script "modules/vehicles/server/main.lua"

shared_script "modules/chat/module.lua"
shared_script "modules/chat/locales.lua"
server_script "modules/chat/server/main.lua"
client_script "modules/chat/client/main.lua"

shared_script "modules/inventory/module.lua"
shared_script "modules/inventory/locales.lua"
shared_script "modules/inventory/shared/common.lua"
shared_script "modules/inventory/data/items.lua"
shared_script "modules/inventory/data/weapons.lua"
shared_script "modules/inventory/shared/catalog.lua"
shared_script "modules/inventory/shared/catalog-1.lua"
shared_script "modules/inventory/shared/catalog-2.lua"
shared_script "modules/inventory/shared/catalog-3.lua"
shared_script "modules/inventory/shared/catalog-4.lua"
shared_script "modules/inventory/shared/catalog-5.lua"
server_script "modules/inventory/server/storage.lua"
server_script "modules/inventory/server/containers.lua"
server_script "modules/inventory/server/players.lua"
server_script "modules/inventory/server/world.lua"
server_script "modules/inventory/server/actions.lua"
server_script "modules/inventory/server/weapons.lua"
server_script "modules/inventory/server/requests.lua"
server_script "modules/inventory/server/commands.lua"
server_script "modules/inventory/server/main.lua"
client_script "modules/inventory/client/main.lua"
client_script "modules/inventory/client/world.lua"
client_script "modules/inventory/client/keys.lua"

shared_script "modules/hud/module.lua"
shared_script "modules/hud/locales.lua"
client_script "modules/hud/client/main.lua"

shared_script "modules/prompts/module.lua"
shared_script "modules/prompts/locales.lua"
server_script "modules/prompts/server/main.lua"
client_script "modules/prompts/client/main.lua"

shared_script "modules/target/module.lua"
shared_script "modules/target/locales.lua"
shared_script "modules/target/shared/model.lua"
client_script "modules/target/client/main.lua"

shared_script "modules/animations/module.lua"
shared_script "modules/animations/locales.lua"
shared_script "modules/animations/shared/common.lua"
shared_script "modules/animations/shared/catalogue.lua"
shared_script "modules/animations/shared/settings.lua"
server_script "modules/animations/server/service.lua"
server_script "modules/animations/server/commands.lua"
server_script "modules/animations/server/main.lua"
client_script "modules/animations/client/presenter.lua"
client_script "modules/animations/client/main.lua"
client_script "modules/animations/client/keys.lua"
client_script "modules/animations/client/picker.lua"
client_script "modules/animations/client/prompt.lua"
client_script "modules/animations/client/exports.lua"

shared_script "modules/elevators/module.lua"
shared_script "modules/elevators/locales.lua"
shared_script "modules/elevators/shared/access.lua"
server_script "modules/elevators/server/main.lua"
client_script "modules/elevators/client/state.lua"
client_script "modules/elevators/client/main.lua"
client_script "modules/elevators/client/panel.lua"
client_script "modules/elevators/client/exports.lua"

server_script "core/server/boot.lua"
client_script "core/client/boot.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
  "network.events",

  "database.access",

  "world.environment",

  "world.vehicles",

  "acl.read",

  "players.life.read",
  "players.life.kill",
  "players.life.respawn",
  "players.life.revive",

  "players.stats.apply",

  "players.disconnect",

  "player.appearance.read",
  "player.cyberware.read",
  "player.appearance.edit",
  "player.equipment.read",
  "player.equipment.edit",
  "puppets.present",

  "camera.preview",

  "input.actions",

  "world.query",
  "players.controls",

  "players.animations.control",
  "animations.presentation",

  "world.elevators",
  "elevators.read",

  "players.stats.read",
  "vehicles.read",
  "voice.client",

  "ui.vanilla.hud",
}
