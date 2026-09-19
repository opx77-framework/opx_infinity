--- The server's visual identity, pushed to every page that asks for it.
-- @author dop42
--
-- The surface has always been red because `design-system/tokens.css` says so,
-- and a stylesheet inside a signed resource is not somewhere an operator can
-- reach. This module is the reach: a block in `config/theme.lua`, resolved once
-- on the server, sent to a client that asks, and written onto the page's root as
-- custom properties. No stylesheet is rebuilt and no file is patched -- the
-- tokens were already the single place a value is decided, so overriding them at
-- run time is the whole mechanism.
--
-- SERVER-AUTHORITATIVE, AND IT IS NOT A SECURITY CLAIM. Nobody is harmed by a
-- player who recolours their own HUD, and a modified client can do it anyway --
-- the page is on their machine. What the direction buys is that the identity is
-- the SERVER'S: the operator sets it, every player sees the same one, and a
-- resource on the client cannot announce a theme. So the wire carries exactly
-- one server-to-client name and one client-to-server name, and the second one is
-- a REQUEST with no arguments. There is no setter to abuse, on either side.
--
-- `side = 'both'` and `fatal = false`. A theme is the last thing in the runtime
-- that may take a session down with it: without this module the page keeps the
-- ladder in its own stylesheet, which is the look that shipped.
--
-- The configuration is a SERVER script, so `Settings` is empty on the client and
-- the client half deliberately reads none of it. Everything the page is told
-- came over the wire.

local M = OPX.Modules.Declare{
	id = 'theme',
	side = 'both',
	fatal = false,
}

M.Event = {
	-- Client to server: "I have a page, what is the theme". No arguments, so
	-- there is nothing in it to validate and nothing in it to forge.
	REQUEST = OPX.Event(OPX.Channel.NET, 'theme', 'request'),

	-- Server to client: the resolved payload, or an empty one.
	SET = OPX.Event(OPX.Channel.NET, 'theme', 'set'),
}

-- What the page calls the channels at its end. `<id>:` is added by
-- `OPX.Surface`, so these reach CEF as `opx:theme:ready` and `opx:theme:set`.
--
-- `theme:ready` is wired at page creation like every other module's, by
-- `wireReadyChannels` in `core/client/ui.lua` walking the module list -- which
-- is why this module is declared at all on a side that only forwards. A page
-- with warm CEF assets mounts before this module starts, and the latch in
-- `lib/client/surface.lua` is what hands the signal over when it does.
M.Page = {
	READY = 'theme:ready',
	SET = 'theme:set',
}
