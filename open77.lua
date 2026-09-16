--- Resource manifest: scripts, permissions and reload policy.
-- @author dop42
--
-- One file per line, in dependency order, and no globs: this list is the only
-- dependency declaration the platform offers. A file that is both listed here and
-- reached by `require` executes twice, and an empty glob refuses the whole set it
-- belongs to -- a failure that only appears after a rename.
--
-- `reload_policy "reconnect"` because this resource owns WebUI surfaces, and a
-- CEF page is never replaced in place.
--
-- This header is the only comment the manifest may carry: it is a declarative
-- DSL, not Lua, and a comment inside a block is unverified here. The permissions
-- that are not self-evident, in order:
--   players.damage.apply  armour is re-applied after the respawn, and nothing
--                         reads it back; it is not a combat permission
--   players.disconnect    only for a connection with no verified identity.
--                         Releasing the gate alone would leave them in bucket 0
--                         with no character, for ever. Not a moderation tool
--   players.access        `Open77.players.all`, for the downed scan. opx77_medic
--                         called it without this, and its scan would have found
--                         nobody, silently, because the call is under a pcall
--   ui.vanilla.hud        hiding the game's own HUD while a player is down

resource "opx-infinity"
version "0.1.0"
open77_version ">=0.0.1"
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
shared_script "config/hud.lua"
shared_script "config/prompts.lua"

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

shared_script "modules/hud/module.lua"
shared_script "modules/hud/locales.lua"
client_script "modules/hud/client/main.lua"

shared_script "modules/prompts/module.lua"
shared_script "modules/prompts/locales.lua"
server_script "modules/prompts/server/main.lua"
client_script "modules/prompts/client/main.lua"

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

  "players.damage.apply",

  "players.disconnect",

  "players.access",

  "player.appearance.read",
  "player.appearance.edit",
  "player.equipment.read",
  "player.equipment.edit",
  "puppets.present",

  "camera.preview",

  "input.actions",

  "players.stats.read",
  "vehicles.read",
  "voice.client",

  "ui.vanilla.hud",
}
