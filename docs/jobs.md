# The job chart — every job, every grade, every command

Where employment is joined, who may join it, what a rank costs in time served, and every
command that touches it. Two catalogues make a job: `config/character.lua` owns the
EMPLOYMENT (the job's name, its grades and what they pay), and `config/jobs.lua` owns the
TERMS (where it is joined, who may join, how long a rank takes). Pay figures are EDDIES
**per paycheck** (see [Pay & duty](#pay--duty)).

---

## The nine jobs a board offers

Any job in `config/jobs.lua` `JOBS` is offered at a sign-up board. Jobs the character
catalogue defines but `JOBS` does not list (Arasaka, Militech, Delamain Driver, Bartender,
Unemployed) exist and can be given with `opx.job`, but no board ever offers them.

| Job (key) | Label | Entry needs | Ranks by time served | Sign-up |
|---|---|---|---|---|
| `ncpd` | NCPD | — | 90 / 360 / 1080 min | open |
| `maxtac` | MaxTac | NCPD Detective (grade 2)+ | 240 min | **approval only** |
| `trauma` | Trauma Team | — | 120 / 480 / 1200 min | open |
| `ripperdoc` | Ripperdoc | — | 120 / 480 min | open |
| `merc` | Mercenary | — | 60 / 300 / 900 min | open |
| `fixer` | Fixer | — | 60 / 300 min | open |
| `netrunner` | Netrunner | — | 60 / 300 min | open |
| `corp` | Corporate | — | 120 / 480 min | open |
| `nomad` | Nomad | — | 60 / 300 min | open |

**MaxTac takes no walk-ins.** The board shows it: below Detective its row reads
**Needs NCPD Detective or above**, and a Detective reads **By invitation only**. A
Squad Lead takes them on at the MaxTac desk (standing within 8 m of it), and MaxTac is
then held **beside** their NCPD badge — they choose **Work this job** on the MaxTac row
at the office to work it (see [Holding more than one job](#holding-more-than-one-job)).
The clock banks their time but never grants a MaxTac rank: Squad Lead is given at the
desk. The first Squad Lead is seated by staff: `/opx.job <playerId> maxtac 1`.

### Grades, pay and the boss

Grade 0 is the entry rank given on joining. `pay` is per paycheck. **(boss)** marks the
grade that holds the desk — only they see the boss desk and manage the roster.

| Job | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| **NCPD** | Cadet — 150 | Officer — 260 | Detective — 400 | **Captain — 620 (boss)** |
| **MaxTac** | Operator — 460 | **Squad Lead — 720 (boss)** | | |
| **Trauma Team** | Paramedic — 180 | Trauma Specialist — 320 | Team Lead — 480 | **Regional Director — 700 (boss)** |
| **Ripperdoc** | Apprentice — 140 | Ripperdoc — 300 | **Chrome Surgeon — 520 (boss)** | |
| **Mercenary** | Street Merc — 120 | Solo — 220 | Edgerunner — 380 | **Legend — 600 (boss)** |
| **Fixer** | Runner — 100 | Broker — 260 | **Fixer — 500 (boss)** | |
| **Netrunner** | Script Kiddie — 110 | Netrunner — 280 | **Blackwall Diver — 540 (boss)** | |
| **Corporate** | Intern — 150 | Associate — 320 | **Director — 560 (boss)** | |
| **Nomad** | Drifter — 90 | Clan Runner — 210 | **Road Warden — 380 (boss)** | |

`bankAuth` (NCPD Captain, Trauma Regional Director, Chrome Surgeon, Fixer, Corporate
Director, plus the hidden Arasaka/Militech/Bartender tops) is a flag carried on the character record for
bank authorisation. Nothing in the shipped modules checks it yet — it is replicated and
waiting for the feature that will.

### Holding more than one job

A character may hold any number of jobs and **works one** — the primary job. Everything
reads the worked job and nothing else: the paycheck, `/opx.duty`, seniority, skill XP,
and every door (lifts, armouries, garages and pads, the scanner, the dispatch board,
the MaxTac crew door, the clinic chair, the uniforms).

- The first job a character takes becomes the one they work. A job signed at the office
  (or hired into at a desk) while they already work another is **held beside it**: its
  row reads **Held, not worked**, and it banks no time and opens no door.
- On a held job's own screen at the office: **Work this job** makes it the worked job —
  a change of job starts **off the clock**, so a shift job wants `/opx.duty` after it —
  and **Hand in your notice** leaves THAT job (whatever the office's headline job is).
- Losing the worked job — handing in the notice, or being dismissed — puts the
  character on the other job they hold at the highest grade (off the clock), and says
  so; with nothing else held they are Unemployed. A MaxTac operator dismissed from the
  division is back at NCPD as the Detective they are.
- The last holder of a job's boss grade cannot hand in their notice, be dismissed or be
  demoted out of it: the job would have nobody able to manage it.

---

## Pay & duty

- **Paycheck**: every **10 minutes** (`PAYCHECK_MINUTES`), into the **bank**
  (`PAYCHECK_TYPE = 'BANK'`).
- A paycheck lands when the holder is **on duty**, or when the job is a **salary**
  (`offDutyPay`) — NCPD, MaxTac and Trauma pay either way; Ripperdoc, Netrunner and
  Corporate pay only while clocked in.
- **The bank balance is spent by drawing it at a bank branch.** Every price on the
  server — shops, the dealership, the clinic, the armouries — is charged in EDDIES, and
  `/opx.withdraw` turns EDDIES (not BANK) into notes. A paycheck therefore lands in BANK
  and is moved to EDDIES at a **branch** of `modules/bank`: a placed marker (an operator
  saves one where they stand with `/opx.bank.add`; none ships) with a menu to draw
  100 / 500 / 1,000 / 5,000 / 10,000, everything, or another amount, and to pay EDDIES
  back in. With no branch placed a paycheck still lands in BANK and waits there;
  `PAYCHECK_TYPE = 'EDDIES'` would land it where it can be spent at once.
- **Always-on-duty jobs** — Merc, Fixer, Nomad (also Delamain Driver, Bartender) — have
  no shift to clock into; you bank seniority and pay just by playing.
- **Clock in/out**: `/opx.duty` (2 s cooldown). The pause-menu key bindings hold no duty
  key; it is a chat command. Every session starts at the job's own default (off the
  clock for a shift job), and so does every change of job; a **promotion or demotion
  keeps the shift** it happened in.

### Seniority (time served)

On duty, a holder banks **1 point per minute** (`SENIORITY`: `TICK_MS` 60000,
`POINTS_PER_TICK` 1). The ladder numbers above are the bank a rank needs to be HELD:

- `AUTO_PROMOTE = true` — reach the bank, get the rank, announced on the spot by name
  ("Your time served has earned you Officer in NCPD."), and still on the clock.
- MaxTac (`APPROVAL`) banks its time like every job — its row reads
  `250 / 240, Squad Lead at the desk` — but the rank is only ever granted at the desk.
- Points persist to the database and survive restarts.
- The bank caps at 1,000,000 — the top defined rank simply holds after that.

A worked example: an NCPD Cadet on duty 90 minutes becomes Officer automatically; 6 more
hours on duty makes Detective (360 total); Captain (1080 = 18 h on duty) is a career.

### What the work feeds: the skill tree

Every point the bank credits — the on-duty tick and `jobs.Award` alike — is also skill-tree
XP (`config/skills.lua`, 10 XP a point): the character's level, and the trunk that names
the job. The tree (`F4`) draws its seven trunks left to right in this order, the last one as
the top of the tree:

| Trunk | Fed by |
|---|---|
| NCPD | `ncpd` |
| MaxTac | `maxtac` — banked on duty like every job; the rank itself waits for the desk |
| Corp | `corp`; `arasaka` and `militech` once `config/jobs.lua` gives them terms |
| Nomad | `nomad`; `cabbie` (Delamain Driver) once it has terms |
| Street | every job no trunk names — `netrunner` today |
| Ripperdoc | `ripperdoc`, `trauma` |
| **Fixer** (the top: Night City Legend) | `fixer`, `merc` |

Hauling pays its crates straight to the wallet and credits no bank, so a haul feeds no
trunk by itself; a hauler who holds `nomad` feeds the nomad trunk by being on the road, and
`JOBS = { nomad = 0 }` on a site in `config/hauling.lua` makes the hauling theirs. Staff
can set a tree outright with `/opx.skills.level` (see `docs/commands.md`).

---

## Trauma Team — the page, the treatment, the pay

Until 2026-09-30 the Trauma Team was a salary and nothing else: **WAIT FOR HELP** on the
down screen stored a flag and said "Help has been called" while nobody was called, and
only a staff command could stand a body up. The loop (`TRAUMA` in `config/downed.lua`,
`modules/downed/server/trauma.lua`):

1. **The page.** A downed player presses **WAIT FOR HELP**. Every connected player whose
   worked job is in `JOBS` (`trauma`) and who is **on duty** (`/opx.duty`) gets a loud
   toast — who is down and where, rounded to `PAGE.ROUND_METRES` — and a pin on the map
   for `PAGE.PIN_SECONDS`; the pin comes down the moment the patient is up. A medic who
   clocks in while somebody is still waiting is paged too. The patient's screen says how
   many medics were paged, or that **none is on duty** — never a promise nobody keeps.
2. **The treatment.** Within `TREAT.REACH_METRES` (4 m) of a downed body an on-duty medic
   sees **Treat <name>** on the strip and presses **E** (`opx.downed.treat`, rebindable),
   or types `/opx.treat`. The server checks the job, the duty, that the medic is up and
   the patient down, the distance to the body (the body's own place, from the life
   state) and the cooldown, then runs a `TREAT.SECONDS` (6 s) bar on the medic's screen;
   the patient reads "<medic> of the Trauma Team is working on you". Walking off, going
   down or leaving stops it by name. When the bar runs out everything is checked again
   and the patient is revived where they lie at `REVIVE.HEALTH`.
3. **The pay.** `REWARD.AMOUNT` (150) into the medic's `REWARD.ACCOUNT` (BANK) per revive,
   at most once per `REWARD.PER_PATIENT_MS` (10 min) for the same patient's character —
   a patient straight back down is revived for free. The salary is paid either way.

The server journal has a `[downed] trauma:` line for every page (with `N medic(s) paged`,
and `CLOCKED OFF` named when that is why nobody was), every treatment started, stopped
and finished, and every payment. `TRAUMA.enabled = false` is the old screen.

---

## Job vehicles — what each rank finds in the garage

Every NCPD and MaxTac member finds their job's vehicles **at the top of every garage
list, by default**: nothing is bought, granted or issued first, and a member hired
today and one hired a year ago see the same rows the moment they open a garage. They
are declared per job and grade in `config/garages.lua` `JOB_VEHICLES`; a grade gets
its own rows **and every row below it**.

| Job | From grade | Vehicle (EN / FR) | Record | Comes out at |
|---|---|---|---|---|
| NCPD | 0 Cadet | Villefort Cortes patrol car / Voiture de patrouille Villefort Cortes | `Vehicle.v_standard2_villefort_cortes_police` | garage |
| NCPD | 1 Officer | Archer Hella patrol car / Voiture de patrouille Archer Hella | `Vehicle.v_standard2_archer_hella_police` | garage |
| NCPD | 1 Officer | Brennan Apollo patrol bike / Moto de patrouille Brennan Apollo | `Vehicle.v_sportbike3_brennan_apollo_police` | garage |
| NCPD | 2 Detective | Chevalier Emperor patrol SUV / SUV de patrouille Chevalier Emperor | `Vehicle.v_standard3_chevalier_emperor_police` | garage |
| NCPD | 2 Detective | Thorton Merrimac interceptor / Intercepteur Thorton Merrimac | `Vehicle.v_standard25_thorton_merrimac_police` | garage |
| NCPD | 2 Detective | NCPD air unit (AV) / Unité aérienne NCPD (AV) | `Vehicle.av_zetatech_atlus`, NCPD livery (`zetatech_atlus_ncpd_01`) | AV pad (a public one: see below) |
| NCPD | 3 Captain | Militech Hellhound armoured unit / Blindé Militech Hellhound | `Vehicle.v_standard3_militech_hellhound_police` | garage |
| MaxTac | 0 Operator | MaxTac AV (Zetatech Surveyor) / AV MaxTac (Zetatech Surveyor) | `Vehicle.max_tac_av`, visible MaxTac livery (`zetatech_surveyor__basic_ep1_maxtac_01`) | AV pad (the MaxTac hangars) |
| MaxTac | 0 Operator | MaxTac ground unit (Thorton Merrimac) / Unité au sol MaxTac (Thorton Merrimac) | `Vehicle.v_standard25_thorton_merrimac_maxtac` | garage |

So a Cadet sees 1 car, an Officer 3, a Detective 5 cars plus the AV at a pad, a Captain
6 cars plus the AV; every MaxTac Operator and Squad Lead sees the MaxTac AV at the
hangar and the MaxTac Merrimac at a garage.

- **Who**: the character's **primary** job, at the row's grade or above, **on duty**
  (`ON_DUTY = true`, the MaxTac pads' own rule). A MaxTac operator who is still an NCPD
  Detective by membership gets MaxTac's rows, not NCPD's.
- **Where**: ground rows at every `garage`, AVs at every `avpad` the player may use —
  the MaxTac hangars (`config/avgarages.lua`) stay behind their own gate. NCPD's air
  unit needs a pad NCPD may use: give the station a public `KIND = 'avpad'` garage in
  `config/garages.lua` — it lists the NCPD AV to NCPD Detectives on duty only.
- **How**: open the garage list (**E** on the marker), pick the row under
  "NCPD service vehicles" / "MaxTac service vehicles". It comes out at the first free
  exit, AVs lifted and with the pilot seated, exactly like an owned vehicle. Picking a
  row that is already out brings that vehicle to you — one of each row per member.
- **Signed out, never owned**: no plate, no row in `opx77_vehicles`. It cannot be sold,
  handed over, stored as a car of your own or counted against the 8-vehicle ceiling,
  and its boot is not saved — leave nothing in it.
- **Back to the pool**: drive it into a garage door (**E** at the entry marker). It also
  goes back on its own when the holder leaves the job, drops below its grade, clocks
  off or switches character — at once on a job/duty change, within `JOB_SWEEP_MS`
  (5 s) otherwise, and never while somebody is sitting in it — and at once, aboard or
  not, when the holder leaves the server.
- **Operators**: `/opx.garages.list` ends with one `job fleet <job>` line per job
  (`key@grade`, `(av)` for aircraft). Add a job by adding a block; a job or grade
  `config/character.lua` does not define is refused at boot.

---

## The boards

A board is a **place**. Stand within **4 m** (`USE_RADIUS`) and press **E**
(`opx.jobs.use` — rebindable in the pause menu, KEY BINDINGS). Markers draw from 150 m.

| Key | Label | Kind | Roster behind it | Where |
|---|---|---|---|---|
| `jobs_signup` | EMPLOYMENT | signup | every job above (except MaxTac join) | Northside promenade arrival point (-469.47, 930.99, 56.45) |
| `jobs_desk_city` | NCPD DESK | boss | ncpd | 7 m along the spawn heading |
| `jobs_desk_maxtac` | MAXTAC DESK | boss | maxtac | 7 m further |
| `jobs_desk_trauma` | TRAUMA TEAM DESK | boss | trauma | 7 m further |

- **signup board** — a public noticeboard: every offered job with YOUR standing against
  each (grade held, points to the next rank, **Held, not worked**, or what the terms are
  missing — by name: "Needs NCPD Detective or above"). Any job may be taken at any
  sign-up board; terms are re-checked on the server at the moment of signing. A job's
  own screen lists its ladder (your grade marked **You**, the boss grade **Boss**) and
  the one action your standing allows: **Sign up**, **Work this job** (held, not
  worked), **Hand in your notice** (held), or **Not on offer** with the reason — the
  full sentence is the hint under the row.
- **boss desk** — one per division. Drawn ONLY for the holder of that job's boss grade
  (and whoever captured it). The desk manages the roster: **hire / promote / demote /
  fire**, pressed in the menu. A hire needs the candidate standing within **8 m** of the
  desk (`HIRE_RADIUS`) — hiring across the map is not a scene anybody can see.

---

## Command reference

### Player commands

| Command | What it does | Example |
|---|---|---|
| `/opx.duty` | Clock into (or out of) your job. On-duty is what pays you and banks seniority. | `/opx.duty` |
| **E** on a board | Opens the board under your feet (sign-up list or your desk). | — |
| **Work this job** (a held job's row) | Makes that job the one you work. | — |
| **Hand in your notice** (a held job's row) | Leaves that job. | — |

(Characters are managed with `/opx.characters`, `/opx.select`, `/opx.create`,
`/opx.delete`.)

### Boss commands — permitted by holding the job's **boss grade**, no ACL entry

The server checks the grade itself, for every action. 2 s cooldown between two roster
moves (`COOLDOWN_MS`). The desk's own hire press needs the candidate within 8 m of the
desk; the typed `/opx.jobs.hire` names a connection id and does not measure the distance
(a command is a deliberate act by an identified boss). These commands are the only door
for the bosses of jobs with no desk: Ripperdoc, Mercenary, Fixer, Netrunner, Corporate
and Nomad. A member who is offline can be promoted, demoted or dismissed too: the rank
on the roster is the rank they log in with.

| Command | What it does | Example |
|---|---|---|
| `/opx.jobs.hire <job> <playerId>` | Take on the player (connection id) standing at your desk, at grade 0. | `/opx.jobs.hire ncpd 3` |
| `/opx.jobs.promote <job> <citizenId>` | Move up one grade. | `/opx.jobs.promote ncpd RZ4K-8821` |
| `/opx.jobs.demote <job> <citizenId>` | Move down one grade. | `/opx.jobs.demote ncpd RZ4K-8821` |
| `/opx.jobs.fire <job> <citizenId>` | Dismiss from the job entirely. | `/opx.jobs.fire ncpd RZ4K-8821` |

### Operator commands — ACL-gated (`command.<name>` must be granted)

Each is refused unless the player holds `command.opx.jobs.<name>` — e.g. grant
`command.opx.jobs.add`. `/opx.jobs.join` and `/opx.jobs.leave` are in this group too, so
grant them deliberately.

| Command | What it does | Example |
|---|---|---|
| `/opx.jobs.add [signup\|boss] [key] <job>` | Capture a board **where you stand**, facing the way you look. Omit `key` and one is minted (`signup3`, ...). Prints the config line to check in. | `/opx.jobs.add signup jobs_signup ncpd` |
| `/opx.jobs.remove <key>` | Delete a **captured** board. Config boards are removed by editing `config/jobs.lua`. | `/opx.jobs.remove jobs_signup` |
| `/opx.jobs.list` | Every board: kind, job, position, and `captured` (database) or `config`. | `/opx.jobs.list` |
| `/opx.jobs.join <job>` | Put YOURSELF on a job at grade 0 (same server-side terms as the board; held beside your worked job if you have one). | `/opx.jobs.join ncpd` |
| `/opx.jobs.leave <job>` | Take YOURSELF off a job. Refused for the last boss of a job. | `/opx.jobs.leave ncpd` |
| `/opx.jobs.roster <job>` | Who holds the job: citizen, name, grade, points served. | `/opx.jobs.roster ncpd` |
| `/opx.jobs.rank <job> [citizenId]` | The ladder — every grade, pay, points needed — and where somebody stands on it. | `/opx.jobs.rank ncpd` |

### Staff commands that touch jobs (`opx.*`, restricted)

| Command | What it does | Example |
|---|---|---|
| `/opx.job <player> <job> [grade]` | Set a character's job and grade outright — the back door into MaxTac or a boss seat. | `/opx.job 3 maxtac 1` |
| `/opx.group <job\|gang> <name>` | List every member with grade. | `/opx.group job ncpd` |
| `/opx.where <player>` | Position and current job/duty of a player. | `/opx.where 3` |
| `/opx.players` / `/opx.here` | Who is connected / who is near you. | `/opx.players` |
| `/opx.money <player> <type> <±amount>` | Give (or take, with a minus) money. | `/opx.money 3 bank 500` |
| `/opx.save` | Save every player — run it in the minute before a restart. | `/opx.save` |

The **admin menu** (`command.opx.admin` opens `/opx.admin`, 56 restricted commands) also
sets jobs and grades through its UI.

---

## Operator recipes

**Place a new desk or board** — stand where it should be, look the way it should face:

```
/opx.jobs.add boss jobs_desk_ripperdoc ripperdoc
```

The reply names who will see it and prints the `config/jobs.lua` line — **check that line
into config** so the board survives a database reset. A desk whose job has no boss yet is
a marker drawn for nobody but its capturer; that is expected.

**Put somebody straight into MaxTac Squad Lead** (testing, or a staged promotion):

```
/opx.job 3 maxtac 1
```

**Walk-ins only for street jobs, ranks for the divisions** — the shipped defaults: open
sign-up with auto-promotion (merc/fixer/netrunner/ripperdoc/trauma/ncpd/corp/nomad), approval ranks
(maxtac). Every knob lives in `config/jobs.lua` (`JOBS`, `LADDER`, `SENIORITY`,
`AUTO_PROMOTE`) and is read at boot — edit and restart.

**Rate limits** (all boards and desk actions): 8 requests / 10 s per connection, 2 s
floor between two actions of the same kind. A stuck key is what they bound, not fairness.
