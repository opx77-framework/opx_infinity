# The job chart — every job, every grade, every command

Where employment is joined, who may join it, what a rank costs in time served, and every
command that touches it. Two catalogues make a job: `config/character.lua` owns the
EMPLOYMENT (the job's name, its grades and what they pay), and `config/jobs.lua` owns the
TERMS (where it is joined, who may join, how long a rank takes). Pay figures are EDDIES
**per paycheck** (see [Pay & duty](#pay--duty)).

---

## The seven jobs a board offers

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

**MaxTac takes no walk-ins**: the board shows it, but joining needs NCPD grade 2
(Detective) AND the rank is granted at the MaxTac desk by whoever holds Squad Lead —
the clock never grants a MaxTac rank.

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

`bankAuth` (NCPD Captain, Trauma Regional Director, Chrome Surgeon, Fixer, plus the
hidden Arasaka/Militech/Bartender tops) is a flag carried on the character record for
bank authorisation. Nothing in the shipped modules checks it yet — it is replicated and
waiting for the feature that will.

---

## Pay & duty

- **Paycheck**: every **10 minutes** (`PAYCHECK_MINUTES`), into the **bank**
  (`PAYCHECK_TYPE = 'BANK'`).
- A paycheck lands when the holder is **on duty**, or when the job is a **salary**
  (`offDutyPay`) — NCPD, MaxTac and Trauma pay either way; Ripperdoc and Netrunner pay
  only while clocked in.
- **Always-on-duty jobs** — Merc, Fixer (also Delamain Driver, Bartender) — have no shift
  to clock into; you bank seniority and pay just by playing.
- **Clock in/out**: `/opx.duty` (2 s cooldown). The pause-menu key bindings hold no duty
  key; it is a chat command.

### Seniority (time served)

On duty, a holder banks **1 point per minute** (`SENIORITY`: `TICK_MS` 60000,
`POINTS_PER_TICK` 1). The ladder numbers above are the bank a rank needs to be HELD:

- `AUTO_PROMOTE = true` — reach the bank, get the rank, announced on the spot.
  (MaxTac excepted: `APPROVAL` jobs are only ever promoted at the desk.)
- Points persist to the database and survive restarts.
- The bank caps at 1,000,000 — the top defined rank simply holds after that.

A worked example: an NCPD Cadet on duty 90 minutes becomes Officer automatically; 6 more
hours on duty makes Detective (360 total); Captain (1080 = 18 h on duty) is a career.

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
  each (grade held, points to the next rank, or what the terms are missing). Any job may
  be taken at any sign-up board; terms are re-checked on the server at the moment of
  signing.
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

(Characters are managed with `/opx.characters`, `/opx.select`, `/opx.create`,
`/opx.delete`.)

### Boss commands — permitted by holding the job's **boss grade**, no ACL entry

The server checks the grade itself. All are refused from anywhere a desk rule would
refuse; the hire's candidate must be at the desk. 5 s cooldown between roster moves.

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
| `/opx.jobs.join <job>` | Put YOURSELF on a job at grade 0 (same server-side terms as the board). | `/opx.jobs.join ncpd` |
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
sign-up with auto-promotion (merc/fixer/netrunner/ripperdoc/trauma/ncpd), approval ranks
(maxtac). Every knob lives in `config/jobs.lua` (`JOBS`, `LADDER`, `SENIORITY`,
`AUTO_PROMOTE`) and is read at boot — edit and restart.

**Rate limits** (all boards and desk actions): 8 requests / 10 s per connection, 2 s
floor between two actions of the same kind. A stuck key is what they bound, not fairness.
