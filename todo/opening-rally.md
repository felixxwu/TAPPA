# Opening rally: start in your starter car's event

**Status:** IMPLEMENTED (2026-08-08). Kept as the rationale record; the behaviour now lives in
`features/map-exploration.md`, `features/prize-rallies.md` and `features/rally-roster.md`.
Originally written as: spec, not started. Depends on map exploration + prize rallies, both shipped
(see [features/map-exploration.md](../features/map-exploration.md),
[features/prize-rallies.md](../features/prize-rallies.md)).

## The problem this solves

Each of the three starter cars has a rally that awards it (`shakedown` → MX-5,
`hm_timber_trophy` → Focus, `hm_forest_gt` → Twingo). A player who picked that car gains
nothing from the prize — `rally_session`'s `Save.owns_model` guard correctly refuses to mint
a duplicate — yet may still have to win it, because completing it is what lights the
neighbouring pins. A rally whose headline reward is dead for you, that you must drive anyway.

The fix is not to substitute the reward but to **reframe the rally**: it is not a prize to
chase, it is where your career starts.

## The change

On first run, the starter picker sends the player **straight into their car's own rally**,
before the map is ever shown. They finish it, and land on the map with that rally already
completed and its neighbours revealed.

This makes the starter pick a real decision for the first time. Today it is made before the
player knows anything and only determines which restriction bands annoy them. Under this it
decides **where on the map their career begins** — pick the MX-5 and you start in the MX-5's
corner, opening that branch first.

### Completion is unconditional

The opening rally is recorded `completed` **whatever the result** — DNF included. Placement
affects only the stars paid.

This is a deliberate carve-out from the rule everywhere else (`completed` means a top-3
finish, `Save.complete_rally`). It exists because the alternative is worse: a first-time
player who finishes 4th would land on a map with nothing lit but HQ and the rally they just
failed, which is a dead end produced by the one run they had no way to prepare for. The
opening rally is an introduction, not a test.

Note this is the ONLY place `completed` diverges from "podiumed". Keep the exception at the
opening-rally call site rather than adding a parameter to `complete_rally` — every other
caller must keep the podium rule, and a flag on the shared function is an invitation to
misuse it.

## What it deletes

Several constraints exist only because every starter had to share one opening rally:

- **`front_runners` / "Proving Ground"** was made class-free (`pw_min` 60, `pw_max` 200, no
  class field) purely so all three starters could enter it. It can go back to being an
  ordinary class-restricted rally, or be dropped.
- **`OPENING_RALLIES`** in `tools/fit_map_pins.py` — "must be wave 1, reachable from HQ,
  enterable by every starter". The player is placed into their opening rally, so it need not
  be reachable at all.
- **`NEAR_GROUP_LINK_WEIGHT`** (beginner prizes within one hop of the opener) — the beginner
  rallies *are* the openers now.
- **`test_every_starter_car_can_enter_something_on_a_fresh_profile`** — becomes "every
  starter has an opening rally", a different and simpler assertion.

## Work

### 1. Flow (`scripts/hq.gd`, `scripts/rally_session.gd`)

- `_confirm_starter` currently grants the car and lands in the garage. It must instead grant
  the car and start the rally that awards that model — resolvable with
  `RallyLibrary.prize_car_id(rally) == model_id`, no new authoring.
- The finish must record completion unconditionally, then route to the map with the reveal
  sequence armed (`hq_table._run_reveal_sequence`) rather than to the garage.
- `Save.rally_revealed_seen` for the opening rally should be seeded so the parade announces
  its NEIGHBOURS, not the rally the player just drove.

### 2. Tools — only after the flow lands

Both currently model a start state that would no longer be true. Updating them first would
optimise the map for a game that does not behave that way yet, which is a real hazard given
how many re-fits the roster has been through.

- **`tools/sim_career.gd`** — `_new_profile()` must mark the starter's opening rally
  completed; `solve_reachability(starter)` must seed its closure with that rally done and its
  circle lit, or it reports the opening rally as something to be reached rather than where
  the player begins.
- **`tools/fit_map_pins.py`** — `career(pos, starter)` needs the same seeding. Drop
  `OPENING_RALLIES` and `NEAR_GROUP_LINK_WEIGHT` per above. Then re-fit once, against real
  behaviour, and re-run `./cache_opponents.sh`.

Each rally's opening role is derived from `PRIZE_CAR`, so neither tool needs new authored
data.

### 3. Tests

- The opening rally completes on a DNF and pays stars by placement (`test_rally_session`).
- Starter pick routes into a rally rather than the garage; the map opens with that rally
  complete and its neighbours revealed (`test_menu_flow`).
- Every starter has exactly one opening rally, and it awards that starter's car
  (`test_rally_library`, replacing the fresh-profile eligibility guard).

## How it landed

- **Retry** — yes, re-enterable like any other rally, and the unconditional-completion
  carve-out is **first attempt only** (`rally_session._is_opening_first_attempt`). After
  that it is scored by the normal podium rule, so it cannot become a rally that always
  counts.
- **HQ lights nothing, and is off the map.** The open question was whether HQ's circle was
  still needed; the answer was no, and it went further — the house marker went too, since
  it advertised a centre the map no longer has. `front_runners` and `shitbox_cup` now
  unlock the ordinary way. The opening rally is lit **whether or not it is completed**,
  which is also what stops a player who quits mid-run returning to a dark map.
- **The starter previews** still back the empty lot; that path was untouched.

### Found on the way

The flow could not ship until prize rallies **admitted their own prize cars** — several did
not (the 911's and XJS's bands started above their own cars, the Acty's demanded a hatch
when the Acty is a kei, the Island GP demanded a GB car for a US Viper). Harmless while a
prize car was just something you won in whatever you owned; fatal once a player *starts*
there. Fixed, and guarded by
`test_a_car_prize_tops_the_band_of_the_rally_that_awards_it`.

Tightening a band around its prize can also make that prize its **own prerequisite** — a
roadster-only Island GP meant only a Viper owner could win the Viper, stranding two
starters. `tools/sim_career.gd` caught it; all three starters now reach 32/32 in 5 waves.
