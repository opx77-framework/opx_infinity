--- Job-gated lifts: a floor list on the lifts Night City already has.
-- @author dop42
--
-- The client half finds the lifts, reads the character and decides what it
-- shows; the server half adopts the lifts, locks them and moves the cabin after
-- re-checking everything it can prove. Nothing is persisted and no interface of
-- its own is drawn: the panel is the menu module's.
--
-- This module is the framework's worked example of a satellite, and the one most
-- safely deleted. `character` is required, because the whole point is the job a
-- character holds. `menu` and `downed` are optional: without the first there is
-- no panel and everything else works, and the second only keeps the panel shut.
--
-- LIVE CONFLICT: the official `open77_doors` depends on `open77_elevators`, which
-- refuses a lift adopted by anything else. The platform rejects a different
-- owner, so whichever starts first owns the cabin; the server half says so at
-- start and that warning must not be dropped.

local M = OPX.Modules.Declare{
	id = 'elevators',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'menu', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection
	-- and never from the payload.
	SIGHTED = OPX.Event(NET, 'elevators', 'sighted'),
	REQUEST = OPX.Event(NET, 'elevators', 'request'),

	-- Server to client.
	BOUND = OPX.Event(NET, 'elevators', 'bound'),
	RELEASED = OPX.Event(NET, 'elevators', 'released'),
	ANSWER = OPX.Event(NET, 'elevators', 'answer'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'elevators', 'decision'),
}

--- The host raises this when it drops a lift this module had adopted.
M.ELEVATOR_REMOVED = 'onElevatorRemoved'

--- The platform package that also owns cabins; `open77_doors` depends on it.
M.OFFICIAL = 'open77_elevators'
