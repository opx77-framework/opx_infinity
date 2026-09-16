--- Client-only configuration. Not authoritative: a modified client can change
--- every value here, and the server re-derives anything that matters.
-- @author dop42

OPX.Config.CLIENT = {
	-- ONE surface. It was two -- an overlay and an interactive layer -- and the two
	-- pages carried the Vue runtime, the design system and eight woff2 faces each:
	-- 926 kB where one page is 522. The HUD and the views are layers inside the page
	-- now, and the page takes focus only while a view is open.
	--
	-- `fps` is fixed at creation; the page handle has no setter. 60, because a
	-- pointer that lags feels broken, and a HUD that repaints more often than it
	-- changes costs only what CEF charges for an undamaged frame.
	--
	-- `hud` rather than `modal` for the layer: it is the only value the eleven
	-- shipped resources use, including `opx77_chat` and `opx77_target`, which both
	-- take focus on it. `modal` is real but unproven here.
	SURFACE = { layer = 'hud', zIndex = 700, fps = 60 },
}
