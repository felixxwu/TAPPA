# Opponent Wrecks

A rival can **crash out** of an event, and when one does the run scene stages the
wreck by the roadside: the **actual car** that rival drove, sitting frozen off the
verge with a small crowd of onlookers gathered around it and lazy engine smoke
rising from it. Purely presentational on top of the existing opponent DNF — a
crashed rival was always a DNF; now you also drive past the evidence.

## The wreck decision (rare, capped) — `RallyLibrary`

Wrecks are decided when the opponent field is generated
([rally-roster.md](rally-roster.md), `generate_opponent_field`), deterministically
from the rally seed so a re-attempt sees the same wrecks in the same places.

- After every rival's per-event times are drawn, a **wreck pass** runs over the
  events: each event independently rolls `OPPONENT_WRECK_CHANCE` (0.5) to crash out
  **exactly one** not-yet-wrecked rival.
- So on average **one rival wrecks about every two events**, and **at most one per
  event** — the invariant the run scene relies on to show at most one roadside
  wreck per stage. (These are the two guarantees the tests pin;
  `OPPONENT_WRECK_CHANCE` itself is a tunable.)
- A wrecked rival has `event_times_ms[wreck_event..] = -1` and **DNFs the rally**
  (`combined_ms = -1`, doesn't rank) — a wreck *is* a DNF, exactly as before. It
  also carries the seeded roadside placement the run scene reads:
  - `wreck_event` — the event they crashed in (`-1` = finished).
  - `wreck_progress` — fraction along the timed track (0.15–0.85, kept off the
    start/finish).
  - `wreck_side` — which verge (`±1`).

`RallyLibrary.event_wreck(field, event_index)` is the pure read: it returns the
rival who wrecked that event as `{name, car_id, car_name, progress, side}`, or `{}`
when nobody did.

`RallySession.current_event_wreck()` ([rally-session.md](rally-session.md)) wraps
that for the current event, so the run scene doesn't touch the field directly.

## The roadside staging — `world.gd`

`_spawn_opponent_wreck()` runs in `_generate_track` (after the arches, once the
centerline + terrain exist). With no active session, the feature off, no wreck this
event, or an unresolved car id it's a no-op. Otherwise it builds a named
`OpponentWreck` container (replaced, not stacked, on an in-place regeneration) with:

- **The car** (`_spawn_wreck_car`) — the rival's ACTUAL car (`car_id` →
  `CarLibrary.index_of`), spawned from `car.tscn` with the same display-car recipe
  as the podium / HQ props: an **isolated config** (so its reshape can't clobber the
  player car's tuning in the shared `Config.data`), its **own mesh copies**, engine
  audio silenced. It's placed on the verge on the seeded side, its near edge
  `opponent_wreck_road_offset_m` off the road — but the exact spot is chosen by
  **searching a small patch near the seeded crash point for the flattest ground**
  (`_flattest_wreck_spot` samples the terrain-height spread under the car footprint
  over a few along-track + outward offsets, preferring the flatter shoulder), so the
  wreck rests on **level ground next to the road** instead of buried in a slope. The
  car is **seated on the highest point under its footprint** so it can never spawn
  buried, yawed along the road and **skewed** (`opponent_wreck_yaw_skew`) so it reads
  as crashed, not parked.
  The site search now also **gates candidates on the car's suspension droop budget**
  (`Car.compression_budget` for the *resolved* wreck car's stiffness/travel): it walks
  candidate verges nearest-shoulder-first over a widened along-track + lateral search and
  picks the first whose terrain height spread fits the budget, so **no wheel is left
  floating over a dip / cliff edge**. If nothing in the widened search fits, it falls back
  to the flattest and `push_warning`s. Each wheel is then drooped onto the **actual terrain
  height under it** (`settle_wheels_to_ground` + `terrain.height_at`, see
  [car-physics.md](car-physics.md) → "Ground-conforming wheels"), so the wreck conforms to
  uneven ground instead of assuming a flat plane.
  It is placed **at rest and frozen at once** — the ground seat lifted by the car's
  **analytic rest ride height** (`car.gd:settled_ride_height`, see
  [car-physics.md](car-physics.md) → "Static rest pose") so its wheels sit on the
  ground — with **no live physics settle**. This is what keeps the wreck reliable out
  on the course, where it spawns far from the player: terrain collision is streamed
  only around the player car ([terrain-manager](terrain.md)), so at spawn there is no
  ground collider under the wreck at all — a live car would free-fall through the world
  and sink out of sight (leaving the crowd, placed by cached height sampling, around
  empty ground). Placing it analytically sidesteps that entirely; it also can't roll
  down the verge or re-wreck itself on landing. Freeze uses the default
  `FREEZE_MODE_STATIC`, so **the collider stays live** — the frozen wreck is a solid,
  immovable obstacle: crashing into it still bites (via the unified deceleration
  [damage model](damage.md)), it just won't be shoved.
- **The smoke** (`_add_wreck_smoke`) — an `EngineSmoke` in **synthetic mode**
  ([engine-smoke.md](engine-smoke.md)), parented to the car and `PROCESS_MODE_ALWAYS`
  so it keeps puffing though the car is frozen / process-disabled. The wreck's HP is
  **zeroed** (`car.damage.hp = 0`) so the severity-timed puffer reads it as a wreck
  and smokes hardest — the same self-timed smoke a damaged parked car shows in HQ.
- **The crowd** (`_spawn_wreck_crowd`) — `opponent_wreck_crowd_size` onlookers in a
  crescent (`opponent_wreck_crowd_radius_m`) on the **verge side** of the wreck (away
  from the carriageway), each facing it. Pure scenery in one `MultiMesh` of the shared
  low-poly spectator figure (no steering / ragdolls, like the HQ crowd), feet on the
  terrain. The scatter is stored on the
  node's `positions` meta (headless `MultiMesh` buffers can't be read back).

## Config (`GameConfig`, *Opponent Wrecks* group)

`opponent_wrecks_enabled` (off = a crashed rival still DNFs, just isn't staged),
`opponent_wreck_road_offset_m`, `opponent_wreck_yaw_skew`, `opponent_wreck_crowd_size`,
`opponent_wreck_crowd_radius_m`. The wreck *rate* is not here — how often / how many
rivals wreck is `RallyLibrary.OPPONENT_WRECK_CHANCE` (see above).

## Tests

- `tests/headless/test_rally_library.gd` — the wreck invariants: **at most one wreck
  per event** (swept over the roster), a wrecked rival **DNFs from its wreck event on**
  and carries a valid placement, `event_wreck` **surfaces the crashed rival (with the
  actual car) or {}**, and wrecks **occur across the roster** (the mechanism fires).
- `tests/headless/test_rally_session.gd` — `current_event_wreck` **tracks the crashed
  rival per event** and is empty for a clean event.
