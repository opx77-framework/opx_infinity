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
-- `players.access` gates `Open77.access`, which is the server-local ban list and
-- NOT the ACL. It was dropped as unused and is back: `opx.admin.moderate.ban`
-- calls it. `Open77.players.all` still needs no permission.

resource "opx_infinity"
version "0.1.2"
-- `>=0.0.1`, which is what all 29 shipped system resources and all 21 of the old
-- opx77_* resources declare -- every resource that has ever installed on this
-- platform. A real range with build metadata (`>=2.31.13+op77.67`) is accepted by
-- the SERVER parser and refused by the client at activation, which surfaces only
-- as `resource_activation_failed` with no server-side trace at all.
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
-- Shared, unlike the vehicles config above: the client draws the markers and so
-- reads the radii, the kinds and the marker vocabulary here.
shared_script "config/garages.lua"
shared_script "config/chat.lua"
shared_script "config/appearance.lua"
shared_script "config/inventory.lua"
shared_script "config/hud.lua"
shared_script "config/prompts.lua"
shared_script "config/target.lua"
shared_script "config/animations.lua"
shared_script "config/elevators.lua"
shared_script "config/menu.lua"
shared_script "config/form.lua"
shared_script "config/panel.lua"
shared_script "config/entry.lua"
shared_script "config/spawn.lua"
-- shared_script "config/gigs.lua"   -- parked; see the gigs block below
shared_script "config/admin.lua"

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
server_script "modules/character/server/state.lua"
server_script "modules/character/server/player.lua"
server_script "modules/character/server/groups.lua"
server_script "modules/character/server/character.lua"
server_script "modules/character/server/main.lua"
client_script "modules/character/client/state.lua"
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

shared_script "modules/entry/module.lua"
shared_script "modules/entry/locales.lua"
client_script "modules/entry/client/main.lua"

-- Where a character starts, asked on every join. Depends on `character`, which owns
-- placement; `character` reaches back for it through the contract at the moment it
-- needs it, because declaring the dependency both ways is a cycle.
shared_script "modules/spawn/module.lua"
shared_script "modules/spawn/locales.lua"
server_script "modules/spawn/server/main.lua"
client_script "modules/spawn/client/main.lua"

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

shared_script "modules/menu/module.lua"
shared_script "modules/menu/locales.lua"
client_script "modules/menu/client/main.lua"

shared_script "modules/form/module.lua"
shared_script "modules/form/locales.lua"
client_script "modules/form/client/main.lua"

shared_script "modules/panel/module.lua"
shared_script "modules/panel/locales.lua"
client_script "modules/panel/client/main.lua"

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

-- Garages and AV pads. After `vehicles`, which it requires: what comes out of a
-- marker is a vehicle that module already owns, and this one creates none of its
-- own. After `character`, which proves the ownership it asks about.
shared_script "modules/garages/module.lua"
shared_script "modules/garages/locales.lua"
shared_script "modules/garages/shared/access.lua"
server_script "modules/garages/server/storage.lua"
server_script "modules/garages/server/main.lua"
client_script "modules/garages/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/garages/client/exports.lua"

shared_script "modules/chat/module.lua"
shared_script "modules/chat/locales.lua"
server_script "modules/chat/server/main.lua"
client_script "modules/chat/client/main.lua"
-- The seam's other end. `main.lua` holds the state and draws nothing; this is
-- the only file that knows the view is a CEF page, and it claims the open key.
client_script "modules/chat/client/view.lua"

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

-- PARKED. `modules/gigs/` and `config/gigs.lua` are written, tested and left on
-- disk unlisted: a file the manifest does not name never loads. They come back
-- with these lines, `shared_script "config/gigs.lua"` above, and the
-- `ui.vanilla.map` permission below -- all three together or not at all.
--
-- After `target`, `inventory` and `animations`, all three of which it reads a
-- contract from, and after `character`, which it requires. `client/run.lua`
-- before `client/board.lua`: the board's rows call into the run.
--
-- shared_script "modules/gigs/module.lua"
-- shared_script "modules/gigs/locales.lua"
-- shared_script "modules/gigs/shared/catalog.lua"
-- server_script "modules/gigs/server/ledger.lua"
-- server_script "modules/gigs/server/runs.lua"
-- server_script "modules/gigs/server/main.lua"
-- client_script "modules/gigs/client/run.lua"
-- client_script "modules/gigs/client/board.lua"
-- client_script "modules/gigs/client/main.lua"

-- LAST of the modules, because it reaches into nearly all of them and provides
-- nothing back. Every contract it uses is optional bar `character`: without the
-- menu, the form or the target eye it logs one line each and all 50 commands
-- still work typed.
shared_script "modules/admin/module.lua"
shared_script "modules/admin/locales.lua"
shared_script "modules/admin/data/vehicles.lua"
shared_script "modules/admin/data/peds.lua"
-- The catalogue is split four ways only because of its size; `-4` finishes it.
shared_script "modules/admin/shared/catalog.lua"
shared_script "modules/admin/shared/catalog-1.lua"
shared_script "modules/admin/shared/catalog-2.lua"
shared_script "modules/admin/shared/catalog-3.lua"
shared_script "modules/admin/shared/catalog-4.lua"
-- The ped allowlist, split the same way and for the same reason; `-4` finishes it.
shared_script "modules/admin/shared/peds.lua"
shared_script "modules/admin/shared/peds-1.lua"
shared_script "modules/admin/shared/peds-2.lua"
shared_script "modules/admin/shared/peds-3.lua"
shared_script "modules/admin/shared/peds-4.lua"

-- `main.lua` is the spine and declares the lifecycle; the rest register into it
-- and are called at Start. `inventory` before `weapons` and `menu`; `menu` last,
-- because its access map lists what every other file registered.
server_script "modules/admin/server/main.lua"
server_script "modules/admin/server/players.lua"
-- After `players.lua`: the body states it pushes carry the worn ped, and the two
-- files call each other by name at run time, never at load.
server_script "modules/admin/server/models.lua"
server_script "modules/admin/server/vehicles.lua"
server_script "modules/admin/server/inventory.lua"
server_script "modules/admin/server/weapons.lua"
server_script "modules/admin/server/world.lua"
server_script "modules/admin/server/tags.lua"
server_script "modules/admin/server/combat.lua"
server_script "modules/admin/server/doors.lua"
server_script "modules/admin/server/menu.lua"

client_script "modules/admin/client/main.lua"
client_script "modules/admin/client/keys.lua"
-- Before the controls: they are the only caller of its transition.
client_script "modules/admin/client/noclip.lua"
client_script "modules/admin/client/controls.lua"
client_script "modules/admin/client/forms.lua"
client_script "modules/admin/client/tags.lua"
client_script "modules/admin/client/tagsview.lua"
client_script "modules/admin/client/combat.lua"
client_script "modules/admin/client/doors.lua"
client_script "modules/admin/client/menu.lua"
client_script "modules/admin/client/target.lua"

server_script "core/server/boot.lua"
client_script "core/client/boot.lua"

-- Server-provided loading screen (FiveM-style). The client renders this page from
-- this resource's verified pack files, in a sandboxed surface over the built-in
-- cover, for the whole of the join -- so this server shows its own screen with its
-- own film on it. It runs before any Lua in this resource does and is driven only by
-- the progress events the client forwards to it.
--
-- THE FILM HAS TO BE A WEBM, AND THAT IS NOT A PREFERENCE. The browser this page runs
-- in (CEF) carries Chromium's free codec set only: no H.264 and no AAC. An MP4 handed
-- to it demuxes and then dies with `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`, which is the
-- demuxer saying the container is fine and no stream in it is playable -- so neither
-- `canPlayType` nor the filename is any guide. VP8/VP9/AV1 plus Opus/Vorbis is what
-- plays, and the page's poster and gradient cover for a clip that cannot.
--
-- `web/**` IS ALSO SIZED. scripting/src/ResourceHost.cpp refuses any web file over
-- 16 MiB with `invalid_web_file:<name>`, and that fails the WHOLE RESOURCE rather than
-- the one file -- an oversized video would not just lose the screen, it would stop this
-- resource loading at all. Both limits are checked by byte count and never trusted.
--
-- THE CLIENT PICKS THE FIRST RESOURCE THAT DECLARES ONE, BY DIRECTORY NAME, so a
-- world that also ships a resource sorting earlier than `opx_infinity` -- anything
-- named `open77_*`, `opx_*`, or `a*` -- supplies the screen instead of this one.
-- Both pages are valid; the losing one is simply never mounted. `web/**` above
-- already ships the page and its video.
loadscreen "web/loading.html"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
  "network.events",

  -- WRITING a replicated state bag; reading one needs nothing, on either side.
  -- `modules/character/server/state.lua` is the only writer in this resource and
  -- the only reason this line is here.
  --
  -- It is NOT in the op77.76 permission catalogue, and that is expected rather
  -- than a second unchecked guess like the two model names at the bottom of this
  -- block: the catalogue lists what a native HANDLER checks, and the bag writer
  -- checks further down -- `server:Open77.state.player` reports "none checked in
  -- the handler" while its own card says "requires `state.write` to write". An
  -- undeclared permission is answered with `permission_denied:<name>`, never with
  -- a refused manifest, so a host that does not know the name loses the bag and
  -- nothing else.
  "state.write",

  "database.access",

  "world.environment",

  "world.props",

  -- `Open77.vfx.play`/`stop`/`catalog` and `Open77.sfx.play` are gated on this
  -- one name, and its refusal is SILENT: the native answers `nil,
  -- permission_denied:world.effects`, logs nothing, and the effect simply never
  -- appears. The staff noclip pop is the reason this line is here -- without it
  -- there was no pop at all, and nothing on the server said why.
  "world.effects",

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
  "player.travel",

  "input.actions",

  "world.query",
  "players.controls",

  "players.animations.control",
  "animations.presentation",

  "world.elevators",
  "elevators.read",

  -- `Open77.markers.create`/`remove`: the glowing garage and AV pad markers.
  -- One declaration per native handler, and this is the handler's own name.
  "world.markers",

  "players.stats.read",
  "vehicles.read",
  "voice.client",

  "ui.vanilla.hud",

  -- The staff module, and only the staff module. Every one of these gates a
  -- single call; none is reachable without passing the ACL first.
  --   players.life.visibility  `setVisible`, for `opx.admin.self.invisible`. The
  --                            `isVisible` READER is players.life.read, which is
  --                            already declared above
  --   players.life.freeze      `setFrozen`, for `opx.admin.player.freeze`; the
  --                            `isFrozen` reader is likewise players.life.read
  --   players.access           `Open77.access.ban`
  --   clipboard.write          `Open77.clipboard.setText`, for
  --                            `opx.admin.self.pos` and the copy-door-id row
  --   combat.config            `Open77.combat.setFriendlyFire`
  --   world.doors              the whole `Open77.doors` table the staff door
  --                            switch reads and writes
  --   world.transform          NOT a transform write -- there is none, a
  --                            placement is kill-then-respawn. It gates
  --                            `Open77.character.bonePosition`, which the staff
  --                            name tags read to sit a tag above the head slot.
  --                            Without it every tag falls back to
  --                            TAGS.HEAD_OFFSET_Z and floats
  "players.life.visibility",
  "players.life.freeze",
  "players.access",
  "clipboard.write",
  "combat.config",
  "world.doors",
  "world.transform",

  -- NOT IN THE op77.76 PERMISSION CATALOGUE, and not on the build this ships
  -- against. `Open77.players.setModel` / `.resetModel` / `.getModel` are
  -- documented at https://open2077.net/docs/player-models and arrived after
  -- op77.76, which is the newest build the devkit knows; this server runs
  -- op77.75. The two names below are the ones that page declares, written
  -- exactly as it writes them, and they are the ONLY lines in this manifest that
  -- were not checked against a catalogue.
  --
  -- `server/models.lua` never assumes they took: it looks the natives up before
  -- every call and refuses with `models_unavailable` when they are absent, so an
  -- older host loses the two model commands and nothing else.
  "players.model.control",
  "players.model.read",
}
