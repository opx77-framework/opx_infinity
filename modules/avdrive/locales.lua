--- Player-facing text for the autopilot: the binding's name, every toast the
--- run answers with, and every refusal.
-- @author XEROX710
--
-- Log lines stay in English. There is no menu and no row here -- the autopilot
-- is one key and a toast -- so this catalogue is small on purpose.

local EN = {
	-- The binding's name, shown in the pause menu's key list. A key with no
	-- name says nothing, which is why `RegisterKeyMapping`'s second argument
	-- is always this.
	['avdrive.key.toggle'] = 'Toggle the AV autopilot',

	['avdrive.engaged'] = 'Autopilot on: flying to your waypoint. Press again to take the controls.',
	['avdrive.cancelled'] = 'Autopilot off. You have the controls.',
	['avdrive.arrived'] = 'Autopilot: holding at the waypoint. The controls are yours.',
	['avdrive.pilotLeft'] = 'Autopilot off: you left the controls.',
	['avdrive.timeout'] = 'Autopilot off: the flight took too long.',

	['avdrive.notSeated'] = 'You are not sitting in anything to fly.',
	['avdrive.notAv'] = 'The autopilot flies aircraft. That is not one.',
	['avdrive.noAircraft'] = 'The aircraft you are in could not be read.',
	['avdrive.noWaypoint'] = 'Drop a waypoint on the map first.',
	['avdrive.waypointUnavailable'] = 'The map could not be read, so there is nowhere to fly.',
	['avdrive.tooFar'] = 'That waypoint is too far. Fly closer and try again.',
	['avdrive.busy'] = 'That aircraft is already under autopilot.',
	['avdrive.rateLimited'] = 'Slow down and try again in a moment.',
	['avdrive.unavailable'] = 'The autopilot is unavailable on this server.',
}

local FR = {
	['avdrive.key.toggle'] = 'Activer ou couler le pilote automatique de l’AV',

	['avdrive.engaged'] = 'Pilote automatique : cap sur votre point de repère. Appuyez encore pour reprendre les commandes.',
	['avdrive.cancelled'] = 'Pilote automatique désactivé. Les commandes sont à vous.',
	['avdrive.arrived'] = 'Pilote automatique : stationnement au point de repère. Les commandes sont à vous.',
	['avdrive.pilotLeft'] = 'Pilote automatique désactivé : vous avez quitté les commandes.',
	['avdrive.timeout'] = 'Pilote automatique désactivé : le vol a duré trop longtemps.',

	['avdrive.notSeated'] = 'Vous n’êtes assis dans rien à piloter.',
	['avdrive.notAv'] = 'Le pilote automatique vole des aéronefs. Ceci n’en est pas un.',
	['avdrive.noAircraft'] = "L'aéronef dans lequel vous êtes n'a pas pu être lu.",
	['avdrive.noWaypoint'] = 'Posez d’abord un point de repère sur la carte.',
	['avdrive.waypointUnavailable'] = 'La carte n’a pas pu être lue : nulle part où voler.',
	['avdrive.tooFar'] = 'Ce point de repère est trop loin. Approchez et réessayez.',
	['avdrive.busy'] = 'Cet aéronef est déjà sous pilote automatique.',
	['avdrive.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['avdrive.unavailable'] = 'Le pilote automatique est indisponible sur ce serveur.',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
