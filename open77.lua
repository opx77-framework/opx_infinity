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

-- The external client library. DECLARED, not optional: `require("@opx_lib")`
-- answers `module_dependency_not_declared` without this line and
-- `module_dependency_not_running` if the resource is not up, and the platform
-- will not start this resource until it is. `lib/client/lib.lua` loads it once
-- and puts it on `OPX.Lib`; see that file for why only the client half uses it.
dependency "opx_lib"

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
-- Shared like the garages config, and for the same reason: the client draws the
-- markers and reads the prices here, and both halves must refuse the same rows.
shared_script "config/dealership.lua"
-- Shared like the two above: the client draws a store's marker and reads the
-- radius and the key here, and both halves must refuse the same rows.
shared_script "config/clothing.lua"
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
shared_script "config/admin.lua"
-- SERVER ONLY, unlike every other module's config above it. The theme is the
-- one operator block a client must not hold a copy of: the client is told its
-- colours over the wire, and a local copy would be a second answer to "what does
-- this server look like" sitting on the machine least able to be trusted with
-- one. `Settings` is therefore empty on the client, and the client half reads
-- none of it.
server_script "config/theme.lua"

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

-- FIRST in the core server block, because it is the far end of a wire the client
-- half wants available before anything else: `core/client/note.lua` says why a
-- client log line nobody can read is worse than no line at all.
server_script "core/server/note.lua"
server_script "core/server/scheduler.lua"
server_script "core/server/sessions.lua"
server_script "core/server/answer.lua"
server_script "core/server/commands.lua"
server_script "core/server/gate.lua"
server_script "core/server/buckets.lua"
server_script "core/server/tunables.lua"

client_script "lib/client/lib.lua"
client_script "lib/client/surface.lua"
-- Before anything a module can reach, so `OPX.Note` is already there for a module
-- that fails while it is still coming up.
client_script "core/client/note.lua"
client_script "core/client/scheduler.lua"
client_script "core/client/ui.lua"
client_script "core/client/notify.lua"

shared_script "modules/diagnostics/module.lua"
server_script "modules/diagnostics/server/main.lua"
client_script "modules/diagnostics/client/main.lua"

-- EARLY, and the position is the whole of its scheduling. `Start` yields between
-- modules to reset the instruction budget, so a module twenty places down the
-- list asks its question twenty frames later -- and this one's question is what
-- colour the page is. Asked here, the answer is normally in the client's hands
-- before the page has finished mounting. It depends on nothing and provides one
-- read-only contract, so nothing depends on it being later either.
shared_script "modules/theme/module.lua"
shared_script "modules/theme/shared/palette.lua"
server_script "modules/theme/server/main.lua"
client_script "modules/theme/client/main.lua"

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
-- The seam's other end. `wardrobe.lua` holds both state machines and draws
-- nothing; this is the only file that knows the appearance panel is a `menu` and
-- the fitting room a `panel`. Both contracts are resolved at Start, so this file
-- has no load-order relationship with either of those modules -- only with
-- `wardrobe.lua`, whose seam it reads.
client_script "modules/appearance/client/view.lua"

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

-- Dealerships. After `vehicles`, which owns what a character owns, and after
-- `garages`, whose spots are the destinations a purchase may name. Neither is
-- required: without `vehicles` nothing can be sold and without `garages` a
-- purchase is filed under the vehicles module's own default garage.
shared_script "modules/dealership/module.lua"
shared_script "modules/dealership/locales.lua"
shared_script "modules/dealership/shared/access.lua"
server_script "modules/dealership/server/storage.lua"
server_script "modules/dealership/server/main.lua"
client_script "modules/dealership/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/dealership/client/exports.lua"

-- Clothing stores: a marker whose key puts the appearance module's own fitting
-- room up, with the game's whole clothing catalogue in it. After `garages` and
-- `dealership` because it is the third place-shaped module and shares their
-- vocabulary rather than their subject. `appearance` and `prompts` are optional
-- and not required: without either, the markers still draw and the key still
-- answers -- out loud -- that the room is not there.
shared_script "modules/clothing/module.lua"
shared_script "modules/clothing/locales.lua"
shared_script "modules/clothing/shared/access.lua"
server_script "modules/clothing/server/storage.lua"
server_script "modules/clothing/server/main.lua"
client_script "modules/clothing/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/clothing/client/exports.lua"

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
-- LAST of the modules, because it reaches into nearly all of them and provides
-- nothing back. Every contract it uses is optional bar `character`: without the
-- menu, the form or the target eye it logs one line each and all 50 commands
-- still work typed.
shared_script "modules/admin/module.lua"
shared_script "modules/admin/locales.lua"
shared_script "modules/admin/data/vehicles.lua"
shared_script "modules/admin/data/peds.lua"
-- The catalogue is split five ways only because of its size; `-5` finishes it.
shared_script "modules/admin/shared/catalog.lua"
shared_script "modules/admin/shared/catalog-1.lua"
shared_script "modules/admin/shared/catalog-2.lua"
shared_script "modules/admin/shared/catalog-3.lua"
shared_script "modules/admin/shared/catalog-4.lua"
shared_script "modules/admin/shared/catalog-5.lua"
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
-- The staff door onto an ACCOUNT'S CHARACTERS, which outlive the session that
-- `players.lua` acts on. Before `menu.lua`, like every other register: the access
-- map that file sends lists what this one registered.
server_script "modules/admin/server/characters.lua"
-- The same door onto people who are NOT connected, which is a query over every
-- account rather than a read of one. Beside `characters.lua` and before
-- `menu.lua` for the same reason: the access map lists what both registered.
server_script "modules/admin/server/offline.lua"

-- The staff door onto a character's PURSE, beside the one onto their account:
-- both reach rows that outlive the session, so both are their own namespace.
server_script "modules/admin/server/recovery.lua"
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
client_script "modules/admin/client/announce.lua"
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
  -- `Open77.weapons.get` on the server, which is the only thing that can answer
  -- WHETHER A WEAPON IS ACTUALLY IN HAND. The inventory used to answer that from
  -- its own bookkeeping, and the game holsters a weapon by itself often enough
  -- that the two drifted: pressing Use on a weapon the game had already put away
  -- put it away again. The other four weapon calls this resource makes need no
  -- permission; this one does, and the catalogue confirms the name.
  "player.weapons.read",
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
