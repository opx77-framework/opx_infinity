-- opx_logo_hud -- the OPX badge at the top centre of every player's screen, in
-- the strip the platform's pre-alpha watermark (`open77_watermark`) holds.
--
-- THE OWNER, 2026-09-29: "make this into a hud in the center of the screen at
-- top where open77 base hud is rn on both xbuniverse also it needs to have
-- solid background". One passive WebUI page on the `hud` layer, never focused
-- and with pointer events off, so it can never take a key or a click: the OPX
-- logo on its own solid dark plate, 76 px tall at 1080 -- the platform's
-- CHROME_STRIP, the top 7% the design system reserves for exactly this -- with
-- a cyan rule under it. zIndex 650 sits it under opx_infinity's own surface
-- (700), so the chat and every menu still draw over it.
--
-- A RESOURCE OF ITS OWN, not a page of opx_infinity: the server's load list is
-- what decides which top strip a player sees, and the watermark is taken out
-- of that list (`"!open77_watermark"`) in the same change that puts this one
-- in -- see `deploy-hud.sh`. It carries no server script and asks for nothing
-- over the wire.

resource "opx_logo_hud"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    "local.events"
}
