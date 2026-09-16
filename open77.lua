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

client_script "lib/client/rpc.lua"
client_script "lib/client/surface.lua"
client_script "lib/client/keys.lua"
client_script "core/client/scheduler.lua"
client_script "core/client/ui.lua"

shared_script "modules/diagnostics/module.lua"
server_script "modules/diagnostics/server/main.lua"
client_script "modules/diagnostics/client/main.lua"

server_script "core/server/boot.lua"
client_script "core/client/boot.lua"

permissions {
  "network.events",

  "database.access",
}
