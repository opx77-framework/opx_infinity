# The base game's missions on this server

Players can pick up the base game's side jobs by talking to NPCs. Before
opx_sandy_view 1.4.11, a job usually stopped partway through (reported
2026-09-28). Sometimes the player was stuck mid-task. Sometimes the screen stayed
black or on a loading screen after a conversation. This page covers why that
happened, what now runs instead, and how to check it in game.

## Why a mission stalled

Two layers switch off the parts of the base game that a mission waits on.

**The platform's multiplayer policy** (`r6/scripts/Open77/*.reds`, active for the
whole session) switches off the following:

| What | What the mission saw |
|---|---|
| `PhoneSystem.OnTriggerCall`, `OnUsePhone`, `IsPhoneEnabled` refused; the phone's HUD hidden | A quest holocall never rang, so the `phonecall_<npc>_with_player` fact it waits on never moved. The "wait for X's call" step waited forever. "Call X" steps and text replies were impossible. |
| Every base-game lootable hidden, and the ones the player looked at emptied | Steps like "take the keycard, shard or package" could not be done, and the item was gone for the session. |
| The scanner refused | Clue, braindance and quickhack steps could not complete. |
| The tracked objective untracked a tick after it was tracked; the tracker hidden; every quest marker denied (world, minimap, map) | The player never saw the objective or where to go next. |
| Quest toasts ("new quest", "quest updated") and V's own dialogue lines cut | The conversation lost half its lines, and progress went unannounced. |

**This resource** added more on top:

| What | Where | What the mission saw |
|---|---|---|
| The server clock put the server's hour back within 0.5 s of any drift | `modules/weather/client/main.lua` | A conversation ending "later that night" set 22:00 and then waited for it. The correction put the server's hour back, so the fade or loading screen after the talk never ended. |
| The vanilla tracker and notification stack hidden by our own HUD config | `config/hud.lua` | The same as the tracker row above, even without the platform. |
| Every weapon that nothing in the bag backs is taken off every 5 s (STILL TRUE: the anti-cheat sweep stays on, see below) | `config/inventory.lua` `REMOVE_UNBACKED` | A weapon a mission handed over is removed within seconds, so "use / shoot / bring X" steps stall. |

## What runs now

### `OpxQuests.reds` (the preload, opx_sandy_view 1.4.11)

Every wrapper in this script targets a **base-game** method. redscript compiles
`r6/scripts/Open77` before `r6/scripts/opx_infinity`, and the wrapper compiled
last is the one the game calls first. Each wrapper therefore runs the base game's
own 2.31 body instead of the platform's refusal. All 43 wrappers (38 for the
missions, 5 for the map log of 1.4.14) were checked as outermost in a compiled
bundle. The script only wraps base-game methods, so it
compiles in either folder order. In the wrong order the fixes would simply never
run, and the client log says so (see below).

- **Phone.** Quest holocalls ring, show and write their fact again.
  - A ringing call is answered by **pressing** the phone key (T). The chat opens
    on T too and takes the keyboard before the release, so the base game's
    answer-on-release never came.
  - Holding T opens the contact list only while the tracked objective asks for a
    call or a text, or from a message banner. A chat opened with T does not
    bring the phone up every time.
  - Text banners show again 20 s after the body attaches. The pristine save's
    own old banners are replayed before that.
- **Quest loot.** A quest container, body, bag or pickup (the base game's own
  `IsQuest()`) offers its quest items again: anything tagged `Quest`, keycards
  and shards.
  - Weapons, ammunition, consumables and junk stay invisible, as the platform
    decided.
  - The platform's own sweep still empties every pickup within 40 m of the player
    every couple of seconds, and no script can reach that sweep. When it empties
    a quest item near the player, the item goes into the player's inventory
    instead, and the client log says so.
- **Scanner**, while `config/hud.lua` leaves `scanner` to the game. The base
  game still requires eye cyberware for it. Other players' bodies can never be
  scanned or hacked.
- **Tracker, markers, toasts.** A quest the player starts is tracked and drawn,
  with its markers on the world, the minimap and the map. The objective the
  pristine save had tracked is still cleared at start, as the platform does. The
  quest toasts show again.
- **V's lines** in a conversation or scene (dialogue and holocall lines). Other
  players' bodies stay mute.
- **Doors.** A quest's unlock or unseal of a door that the server's door resource
  owns goes through.
- **Loading screens** are written to the client log: when one comes up, and when
  its bar is full.

### Phantom Liberty on a female V's world (opx_sandy_view 1.4.13)

Reported 2026-09-28 on a female V: Dogtown had its crowd and its traffic, but
none of its people, and the Phantom Liberty story could not be started.

**Why.** The platform enters every session on one of two bundled saves, picked
by the body the player chose:

| Save | Body | Phantom Liberty |
|---|---|---|
| `NCMP-Template-M` | male | Under way: `ep1_active = 1`, `ep1_side_content = 1`, q300 to q302 done |
| `NCMP-Template-F` | female | Never started: a save from just after the prologue, before The Heist; both facts 0 |

In the base game's own quest graph (2.31, `ep1\quest\ep1.questphase` and the
phases under `ep1\openworld`, read from `ep1_2_gamedata.archive`), nearly all of
Dogtown waits on those two facts:

| Fact | What waits on it |
|---|---|
| `ep1_active` | The story (`ep1_main_quests`: q301 "Dog Eat Dog" starts with Songbird's holocall). Dogtown's world, combat and quest communities: the Barghest, the stadium, the markets, the Heavy Hearts. Its vendors, world stories and encounters. The expansion's minor quests. |
| `ep1_side_content` | The combat zone gate. Street stories and gigs, air drops and courier runs, convoys, drones, dynamic events. The other vendors. The Heavy Hearts' lights and music. |

The base game writes `ep1_active` only once the Voodoo Boys' q110 is reached
(a node in `q110b`, and a fix-up in `base\quest\bugfixing` for saves already
past it) or in a new Phantom Liberty game. It writes `ep1_side_content` in
q302's squat scene. A session starts over from the pristine save every time,
so a female V could never get there. A male V always had both, which is why
Dogtown looked right on a male V.

**What runs now.** Five seconds after the local body attaches in a session, on a
game that has Phantom Liberty (`IsEP1()`), `OpxQuests.reds` sets each of the two
facts that reads 0 to 1. Those are the values the male save carries. It writes
no other fact and touches no journal entry or quest phase. The base game's graph
does the rest:

- the communities spawn and the gate opens;
- about ten seconds later, once V is in free play (not in combat, not in a
  call), Songbird calls, and "Dog Eat Dog" begins with "get to Dogtown".

A world that already has both facts (the male save) is left as it is. Nothing is
saved, because the session's world ends with the session.

Client log lines:

- `Phantom Liberty opened on this world (ep1_active 0 -> 1, ep1_side_content 0 -> 1): ...`,
  or `Phantom Liberty: this world already has it (...)`.
- A minute later: `Phantom Liberty a minute on: ... q301_started 1 (Songbird's
  call came and Dog Eat Dog began)`. `q301_started 0` means the call has not
  come yet. It waits until V is out of combat and out of any call.
- The `call IncomingCall with ...` line for Songbird's call, then `tracking: ...`
  for the objective.

### The map, step by step in the client log (opx_sandy_view 1.4.14)

Reported 2026-09-29: opening the map hard-crashed the game, first on a second PC
and then on the owner's own. The crash probe's record
(`red4ext/logs/open77-crash-probe.log`) shows an access violation, a read at
`0x38`, in `Cyberpunk2077.exe`, about 80 ms after the platform's map setup began.
The client log's last line is `map:composition=ready`, and it holds no
`mappin:` line after it: the game died before the map asked for a single
marker. A crash writes nothing after itself, so the log did not say which step
of the setup it died in.

**What runs now.** `OpxQuests.reds` writes each step the map takes, the moment it
happens, to the Open77 client log (each line starts `opx_sandy_view quests: map: `):

| Line | The map reached |
|---|---|
| `opening` | the game started the map's controller |
| `tooltips hidden 1` | the platform's setup got past its first natives |
| `tooltips hidden 2` | ... and past reading the map's tabs and text |
| `opened` | the platform's setup returned |
| `reading the zoom levels`, `zoom levels N` | the first per-frame tick reached, and returned from, the read of the zoom levels |
| `scene attaching`, `scene attached` | the map's 3D scene attached to its controller |
| `marker <class>:<variant>` | each quest marker the map was asked to draw |
| `closed` | the map's controller went away |

**The last line after a crash is the step the game died in.** Nothing on the map
changes: each wrapper runs the wrapped method and returns what it returned, only
in a multiplayer session, and the methods the tick reaches every frame are
written on their first call only.

### What crashed the map, and the fix (opx_sandy_view 1.4.15)

The crash probe's record was the whole answer: an access violation, a read at `0x38`,
in the game's own native `IMappin.GetScriptData`, reading the data pointer of a
`gamemappinsRuntimeMappin` that has none. It is the marker the fullscreen map makes for
the **player's own arrow**, drawn from `gameuiWorldMapPlayerInitData` and never
registered as a mappin with data behind it. `OpxQuests.reds`' marker gate (the one that
hides a quest's markers when `opx_quests_off` is set) asked every marker for its script
data **first** -- the arrow included, and before that switch was read -- where the base
game's own code and the platform's wrapper both look at the init data and never touch the
arrow.

**What runs now.** The gate judges the init data first, the object's class next, the
off switch after, and reads a marker's script data last; the map's own wrapper passes a
runtime marker on after a class test alone, and writes each marker it is asked about
(`map: marker asked N: ...`) before judging it, so a fault in a marker would still leave
its last line. Nothing on the map changes for a player.

**To verify in game.** Every player boots the game again through the launcher once (the
preload changed), then opens the map. If the game still closes, send
`red4ext/logs/open77-crash-probe.log` and the newest `open77-*.log`: the last `map:`
line is the step it died in.

### This resource

- **`modules/weather/client/main.lua`.** When the engine's clock moves in a way
  its own running cannot explain, the move is taken as the mission's. The
  server's hour then stands back for 20 minutes, and every further move re-arms
  that hold.
  - The clock is read on every pass, so a move is seen even while the server's
    clock is held (frozen), and the held hour is written back when the hold
    ends.
  - The module's own correction is never taken for a mission's move, even when
    the engine shows the new hour a few passes late.
  - A world entry (join, body reload) re-reads the save's own hour and is never
    taken as a mission. It also ends a hold: the save is loaded again, and the
    mission that moved the clock went with the world it ran in.
- **`/opx.wait <hours>`** (`config/weather.lua` `COMMANDS.WAIT`, open to every
  player). The base game's time skip is refused in a session, and at the
  engine's rate a game day is three real hours. A step that says "wait until
  22:00" or "come back tomorrow" therefore waited in real time. The command
  moves the asking player's own clock 1 to 23 hours ahead, holds the shared hour
  back on that game for the same 20 minutes, and changes nobody else's sky.
- **`config/hud.lua`.** `questTracker = true` and `vanillaNotifications = true`.
  `phone` and `scanner` were already `true`. Each flag is also the switch for
  the matching piece of the preload.
- **`config/inventory.lua`.** `REMOVE_UNBACKED = true`, as main ships it: the
  owner decided the anti-cheat sweep stays on. A weapon a mission hands over
  outside the bag is taken off, so a mission step that needs one does not
  complete. Every weapon this resource hands out goes through the bag and is
  never touched.

## Reading it in game

Each line goes to the player's Open77 client log (`Open77 pristine player
bootstrap trace: opx_sandy_view quests: ...`):

- `missions restored in this session (outermost wrapper: ...)`: written 5 s
  after the body attaches. `NOT restored: the platform's scripts were compiled
  after this module` means the fixes are not running on that machine.
- `call IncomingCall with <contact>`, `call answered: <contact>`: the phone.
- `tracking: <objective>`, `quest Active: <title>`,
  `quest Succeeded: <title>`: progress.
- `took a quest item: ...`, `the session emptied a quest pickup; its item went to
  the player instead: ...`: loot.
- `an engine loading screen is up` / `... reached 100%`: a black or loading
  screen that stays up **after** "100%" is not the game's own load.
- In the resource log (weather): `the game moved its own clock 14:10 -> 22:00 (a
  mission); the server's hour stands back for 20 min`.

## Switches

| Switch | Effect |
|---|---|
| `config/hud.lua` `VANILLA.questTracker`, `vanillaNotifications`, `phone`, `scanner` | `false` hides that piece again. For the tracker, phone and scanner, the preload obeys the flag. |
| `config/inventory.lua` `WEAPONS.REMOVE_UNBACKED = false` | Leaves missions' weapons in V's hands, and turns the anti-cheat sweep off with it. |
| `config/server.lua` `ENTRY.BUCKET.WORLD_POPULATION = false` | Empty streets, and the platform removes every quest NPC within a second (see below). |
| Quest fact `opx_quests_off = 1` | The preload hands every piece back to the platform on the next call. |
| Dropping `opx_sandy_view` from `resources.load` | No preload at all (the Sandevistan view goes with it). Every player must relaunch. |

## What is still the platform's

These cannot be changed from a resource or its preload:

- **The world sanitizer.** Every second, the platform removes every NPC and
  vehicle within 500 m that no Open77 system owns, and every new one half a
  second after it appears. A quest's actors are unowned NPCs too. The only
  thing that spares them is the bucket's population policy:
  `ENTRY.BUCKET.WORLD_POPULATION = true` in `config/server.lua` (the setting
  here) sends crowd 1, traffic 1 and police on to every client in the shared
  world, and the sanitizer then leaves unowned NPCs and vehicles alone. With it
  `false`, no mission that needs an NPC can run: the NPC is gone within a
  second. The character-selection buckets (`POPULATION = false`) are never
  where a mission runs.
- **Quest pickups.** The loot sweep's emptying of quest pickups is covered above
  by giving the item, not prevented.
- **Hub pages.** The journal, inventory, crafting and perk pages stay refused.
  To track another quest, click its marker on the map.
- **Time skip, saves and tutorial pop-ups.** The base game's time skip and saves
  are removed, and tutorial pop-ups stay suppressed. A "wait until" step waits
  on the shared clock, on the clock the mission set itself (see the hold above),
  or on `/opx.wait`.
- **The loading cover.** The platform's loading cover is fed by every engine
  loading screen. What lifts it after an in-world load is native code; the
  loading-screen lines above show which side a stall is on.
