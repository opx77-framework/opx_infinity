# opx_logo_hud

The OPX badge, drawn at the top centre of every player's screen in the strip the
platform's pre-alpha watermark (`open77_watermark`) used to hold.

- One passive WebUI page on the `hud` layer: never focused, `pointer-events: none`,
  so it cannot take a key or a click.
- The logo on a **solid** near-black plate (`#0d0c11`), 76 px tall at 1080 -- the
  platform's CHROME_STRIP, the top 7% of the screen -- with a cyan rule under it.
- `zIndex` 650: under opx_infinity's own surface (700), so the chat and every menu
  draw over it; `config/chat.lua` puts the chat box at `OFFSET = 88`, below the badge.
- No server script, nothing on the wire.

## Installing

`deploy-hud.sh` (run by `deploy-hud.cmd`) installs it beside `opx_infinity` on both
XBUNIVERSE servers -- staging first, production only if staging came back healthy --
and in each server's `config/server.jsonc`:

- adds `"opx_logo_hud"` to `resources.load`;
- adds `"!open77_watermark"`, which takes the old watermark out.

The config is backed up before the edit, the service is restarted (a load-list change
needs a restart), and the edit is undone if the restart logs a resource start failure.

## Files

| Path | What it is |
|---|---|
| `open77.lua` | Manifest: one client script, the page and its files. |
| `client/main.lua` | Creates the page when the resource starts on a player's machine. |
| `web/index.html`, `web/app.css` | The badge. |
| `web/opx-logo.png` | The logo, 246x152 (twice the drawn size, for 1440p and 4K). |
