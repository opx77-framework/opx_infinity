-- opx_sandy_view, server: says the base game's Sandevistan view is being
-- delivered (the preload does the work; see open77.lua).
AddEventHandler('onResourceStart', function(name)
	if name ~= GetCurrentResourceName() then return end
	print('[opx_sandy_view] the base game\'s Sandevistan screen ships with this world ' ..
		'(r6/scripts/opx_infinity/OpxSandevistanView.reds)')
	-- The ghost trail's parts ride in the preload's own archive: its copies of
	-- V's body files (t0_000_base__full.app and the censored cut) carry them,
	-- and the game loads those by their depot path -- no loader. Up to 1.4.7
	-- they were an ArchiveXL patch, and a player whose game had no ArchiveXL saw
	-- no trail at all; the platform's `archivexl` resource is no longer needed
	-- for it (whatever else in this world may use it).
	print('[opx_sandy_view] the ghost trail ships in this preload\'s own archive ' ..
		'(archive/pc/mod/opx_sandy_ghost.archive: V\'s body files with the parts) -- no ArchiveXL needed')
end)
