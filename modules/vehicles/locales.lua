--- Player-facing text owned by the vehicles module.
-- @author dop42
--
-- Every key here is a refusal code or a confirmation: it reaches `locale()`
-- through a variable, never as a literal, so a rename breaks nothing at load and
-- everything at the moment a player is refused. Both halves need them: the
-- server renders a toast, and the client renders the code `OPX.Refuse` carries.

OPX.Locale.Register('en', {
	['vehicle.notFound'] = 'No vehicle carries that plate.',
	['vehicle.limit'] = 'This character owns as many vehicles as it may.',
	['vehicle.spawned'] = 'Vehicle {plate} brought out.',
	['vehicle.stored'] = 'Vehicle {plate} put away.',
	['vehicle.notSpawned'] = 'That vehicle is not out.',
	['vehicle.noPosition'] = 'You have no position to spawn beside.',
	['vehicle.spawnRefused'] = 'The vehicle could not be created.',
	['vehicle.occupied'] = 'Somebody is sitting in that vehicle. It cannot be moved.',
	-- A second request for a plate whose spawn is already in flight. Not an
	-- error the player caused: it is the answer the loser of a double-press gets
	-- now that a plate is claimed before it is created.
	['vehicle.busy'] = 'That vehicle is already being brought out.',
	['vehicle.badRecord'] = 'That vehicle record cannot be used.',
	['vehicle.plateExhausted'] = 'No free plate could be drawn. Try again.',
	['vehicle.notLoggedIn'] = 'You have no character loaded.',
})

OPX.Locale.Register('fr', {
	['vehicle.notFound'] = 'Aucun véhicule ne porte cette plaque.',
	['vehicle.limit'] = "Ce personnage possède déjà autant de véhicules qu'il le peut.",
	['vehicle.spawned'] = 'Véhicule {plate} sorti.',
	['vehicle.stored'] = 'Véhicule {plate} rangé.',
	['vehicle.notSpawned'] = "Ce véhicule n'est pas sorti.",
	['vehicle.noPosition'] = 'Aucune position pour faire apparaître le véhicule.',
	['vehicle.spawnRefused'] = "Le véhicule n'a pas pu être créé.",
	['vehicle.occupied'] = 'Quelqu\'un est assis dans ce véhicule. Impossible de le déplacer.',
	['vehicle.busy'] = 'Ce véhicule est déjà en train de sortir.',
	['vehicle.badRecord'] = 'Ce modèle de véhicule ne peut pas être utilisé.',
	['vehicle.plateExhausted'] = "Aucune plaque libre n'a pu être tirée. Réessayez.",
	['vehicle.notLoggedIn'] = "Vous n'avez aucun personnage chargé.",
})
