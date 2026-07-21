# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` (`_build_start_line`) for staged session runs. Holds the
[`StageManager`](stage.md) in its `STAGING` phase and launches it after a cinematic
reveal. Uses the scripted-control hook on [`car.gd`](car-physics.md) for the grid cars.

The diegetic sequence between picking a car in HQ and the `3·2·1·GO` countdown
(`todo/menus.md` location 2). It runs **inside the live run scene** (`main.tscn`) once
the world is built and a [`RallySession`](rally-session.md) is active, while the car is
held locked. It lines up the **real top-three rivals** ahead of the player and walks the
player up to the line one opponent at a time.

Phases (`StartLine.Seq`), driven in `_process`:

1. **MENU** — **design-system** (`UITheme`) black house panels: a `Rally — Event N of 3`
   header hugs the top, and **Start / Tune Car / Upgrades** buttons hug the bottom, with
   an expanding clear band between so the car shows through. An **orbit camera** idles on
   the player's car. The HUD + mobile controls are hidden. All three buttons and both
   sub-overlays are keyboard/gamepad navigable via `MenuNav`; a tap on the clear band also
   launches. Pressing **Start** runs the eligibility gates (below); only on passing them
   does the sequence advance.
   - **Tune Car** opens the shared `TuningPanel` (grip / brake-bias / aero / detune for
     this race, mirroring the HQ lift; edits re-field the live car via `car.retune()`;
     passed the rally's `pw_max` so the detune label flags **OVER LIMIT**, detune spans the
     full 0–100 % since eligibility is enforced at Start).
   - **Upgrades** opens the shared `UpgradesMenu` (swap parts/engine for this race; edits
     re-field via `car.refit_upgrades()`; Back/Done gated on the rally's p/w cap).
2. **FLY_IN** — on Start, the single camera lerps (eased, `start_reveal_fly_seconds`) from
   its captured orbit pose to a fixed **low 3/4 shot ahead of the start line, facing the car
   on the line** (`start_reveal_cam_front_m` ahead, `start_reveal_cam_side_m` to the side,
   `start_reveal_cam_height_m` high, looking at `start_reveal_cam_look_height_m` up the car,
   at `start_reveal_cam_fov`). The shot is anchored — computed once from the start pose — and
   held for the rest of the sequence (no re-fly per opponent). The orbit idle stops the
   moment Start is pressed so the lerp source is fixed.
3. **REVEAL** — a compact house card at the **top** of the screen names the opponent
   currently on the line (`P{n}  Driver`, their car beneath) and shows a labelled stat
   column — the gold **`TIME TO BEAT  m:ss.cc`**, the **`GAP TO P1`** (`_format_gap`; the
   fastest rival reads `FASTEST`), and, from **event 2 on**, their **`OVERALL`**
   championship position (`_ordinal` of the standings `placed`, matched by driver name via
   `_build_overall_ranks` → `RallySession.current_standings()`; the row is hidden on event 1
   and in dev/test where the ranking is unknown). The card hugs the top so it never covers
   the car; a simple **Next** button (Enter / gamepad A / tap) hugs the bottom. It shows the
   top-three rivals fastest-first (`RallySession.current_event_leaders(3)`), P1 on the line
   first. **Next** (`next_car`)
   floors the front car off down the lead-in and **immediately reveals the next opponent** —
   the reveal is **tap-driven and does NOT wait for the field to line up**, so the player can
   tap straight through P1 → P2 → P3 without pausing for each car to roll up. Underneath,
   every REVEAL frame keeps rolling the rest of the field (the other opponents **and** the
   player) up toward their slots as ambient motion (`_roll_grid_to_slots` → `_roll_car_to`:
   drive → coast into a speed-aware brake point → brake → cut throttle + hold the handbrake,
   so the auto box can't grab reverse and rev against the hold). Departed cars keep driving
   straight off and are despawned once they pass the line by `start_lead_in_ahead_m` (before
   the first corner), so they never fight their axis-lock into a bend. Once **Next** on the
   last opponent leaves only the player in the grid, on to **FADE** — any roll-up still in
   flight is purely cosmetic, since the hand-off snaps the player exactly onto the line.
4. **FADE** — the screen **fades to black** (`start_fade_seconds`); at full black the player
   is released to normal driving and snapped exactly onto the line (`reset_to`), the
   remaining grid/departed cars are despawned, the camera hands back to the player's
   **selected** camera (chase OR bonnet, via the `CameraManager`), the **driving UI returns**,
   and `StageManager.begin_countdown()` starts the countdown; then it **fades back in**.

**Eligibility gate** — Pressing **Start** computes the car's effective stats and calls
`RallyLibrary.ineligibility_reason(_rally, meta, floor_meta)` — where `floor_meta` is the
car's `UpgradeLibrary.max_potential_meta`, so the `pw_min` floor is judged at the car's max
potential (matching the car park); if non-empty, launch is blocked with a `ConfirmPopup`
(mirroring the HQ car park). Over the rally's **power-to-weight ceiling** with a detune that
can admit it (`RallyLibrary.qualifying_detune` in `(0,1)`) → **"Too powerful"** popup
offering **"Change Upgrades"** / **"Cancel"** (the gated Upgrades overlay won't close until
the build is under the cap; a permanent garage edit — close → re-press Start). Any other
reason (including a car **under the band floor** even at max potential — the hard floor
replaced the old soft "underpowered" warning) → the reason with the same buttons.

**No opponents to reveal** — dev/test harnesses (and any event that somehow fields no rivals)
pass an empty `leaders` list: no cars line up, the player is already on the line, and **Start
goes straight to the FADE** + countdown. In a real session this never happens (the field is
10–15 rivals and wrecks are cumulative but capped, so the live floor is comfortably ≥ 3).

The grid cars are the **real top-three rivals** in their **actual cars** (spawned from each
leader's `car_id`), NOT the abstract opponent field's flavour — but they are still
atmosphere: they carry collision exceptions with the player and each other and never affect
the timed result (the standings come from `RallyLibrary`'s per-seed roster).

## Physically-simulated cars (rolling start)

To avoid placing the grid against unfinished ground, `world.gd` waits **one rendered
frame** after the terrain is generated before building the `StartLine` — so the fielded
car has dropped onto the settled terrain and the staged cars seat against it rather than
mid-build (skipped under headless, where generation is synchronous). The **loading overlay
is held up across that frame** so the car is never flashed at its un-staged spot.

The three opponent cars **and the player** drive under real physics during the roll-up, so
they load their suspension (squat / weight transfer) instead of sliding. They run full
physics but read **scripted control** instead of player Input via the `car.gd` hook
(`ai_controlled` + `ai_throttle` / `ai_steer` / `ai_handbrake`), with an auto gearbox, and
are **axis-locked to a straight line** (`axis_lock_linear_x` lateral + `axis_lock_angular_y`
yaw — the start heading is always world −Z) so they can't veer.

**Grid layout** — from the line, back toward the player: **P1 on the line → P2 → P3 →
player**, each `start_queue_gap` apart (opponent slot _i_ at `_start_xform * (0, 0, i·gap)`;
the player is staged `GRID_AHEAD · gap` back). Nothing is staged behind the player. On each
**Next** the front car drives off and is removed; the rest (incl. the player) roll up one
slot and brake to a stop, so after three Nexts the player is on the line.

**Placement uses `reset_to`, not a bare `global_transform` write** — `car._ready()` captures
its spawn pose at add-child time (the origin) and a plain `global_transform` write on a
`VehicleBody3D` is discarded by the physics server (see `car.gd` `reset_to`, which queues a
pending teleport applied inside `_integrate_forces`). A bare write makes every prop snap back
to the origin and **stack on top of each other** in-game (it survives only in headless, where
no physics step runs — which is why a spacing test can pass while the live grid is broken).
`StartLine` places both the grid props (`_spawn_prop`) and the staged player (`_stage_player`)
via `reset_to`.

Once a car is nearly stopped and holding the handbrake it is **position-locked**
(`Car._apply_handbrake_lock` freezes the body below `HANDBRAKE_LOCK_SPEED`), so a settling car
can't creep into the one ahead; the lock releases when the handbrake does. At the fade the
player is **released** — AI override and axis locks cleared, gearbox-auto restored, snapped
onto the line — so the run drives normally; the `StageManager` keeps it locked through the
countdown.

All cars are **seated `start_spawn_clearance` (0.5 m) above the road** at spawn (via
`_start_xform`, which cascades to every grid slot through `_ground`) so they settle onto
their wheels. Grid cars are **despawned** (departed past the line, or the remainder at the
fade), so they cost nothing during the run.

**Engine audio — proximity attenuation, no bespoke muting.** Every car (grid props and the
player) simply idles its own engine voice throughout the reveal; loudness comes entirely
from the shared **proximity attenuation** in `engine_audio.gd`, which scales each car's
`volume_db` by its distance from the active reveal/orbit camera (see
[engine-audio.md](engine-audio.md) → *Proximity attenuation*). `apply_car` rebuilt each
prop's synth off that car's isolated `config`, so you hear its actual engine. A car driving
off the line recedes naturally as it drives away, and is silenced
(`car.silence_engine_audio()`) the frame before `_prune_departed()` frees it, so its
still-audible distant idle isn't hard-cut. (This replaced the earlier custom
per-car mute + manual distance fade, which proximity attenuation subsumes.)

## Straight start lead-in (staged runs)

The grid needs straight road ahead (for the cars' run-off) and behind (for the staged
player, now the full `GRID_AHEAD · start_queue_gap` back), but the generated track can start
on a corner. So for staged runs `world.gd` generates the track from a point
`start_lead_in_ahead_m` **ahead** of the spawn, then `_with_start_lead_in` prepends a
handle-free straight stub `start_lead_in_behind_m` **behind** the spawn. The road mesh,
terrain flattening, `TrackProgress`, tree rejection and tire marks use this extended
centerline; the **signs** keep the raw generated centerline, so the start gate sits ahead of
the launch point (the cars cross it as they pull away).

**Constraint:** the player is staged three gaps back, so
`start_lead_in_behind_m ≥ 3 · start_queue_gap + ~4 m` (a car length) — otherwise the player
spawns past the end of the flattened stub. The default `start_lead_in_behind_m` is **30 m**
for the default 7 m gap; widening the gap needs a wider stub.

So the search doesn't loop the track back across the stub, `world.gd` **reserves** the whole
lead-in corridor in the generator (`reserve_behind_m = start_lead_in_ahead_m +
start_lead_in_behind_m`); the reservation is relative to the start frame, so the generated
track SHAPE stays a pure function of `(seed, turn_count, width, reserve)`, and
`RallySession._compute_event_targets` passes the same reserve so the opponents' derived
target times match the track the player drives.

## Wiring & lifecycle

`world.gd._should_stage()` gates the start line: a session run **and** `start_line_enabled`
**and** a resolvable rally. When true, `world.gd` sets up the `StageManager` `staged`, builds
the lead-in, and builds the `StartLine` after generation, handing it `$Car`, `$Floor`,
`$CameraManager`, `$HUD`, `$MobileControls` and `RallySession.current_event_leaders(3)`. Each
event reloads `main.tscn`, so the `StartLine` is created fresh per event. A plain dev boot (no
session) never builds a `StartLine` and the countdown arms immediately.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `start_line_enabled` | `true` | Run the start-line sequence in a session. Off → straight to the countdown. |
| `start_orbit_speed` | `0.5` | Orbit camera angular speed (rad/s) during the MENU idle. |
| `start_orbit_radius` | `7.0` | Orbit camera radius (m) from the car. |
| `start_orbit_height` | `2.4` | Orbit camera height (m) above the car. |
| `start_orbit_fov` | `70.0` | FOV (deg) of the MENU orbit camera. |
| `start_reveal_fly_seconds` | `1.2` | Camera fly-in from the orbit pose to the anchored 3/4 reveal shot. |
| `start_reveal_cam_front_m` | `6.0` | Reveal camera distance (m) ahead of the line. |
| `start_reveal_cam_side_m` | `4.0` | Reveal camera lateral offset (m) — the 3/4 angle. |
| `start_reveal_cam_height_m` | `1.0` | Reveal camera height (m) — low to the ground. |
| `start_reveal_cam_look_height_m` | `0.8` | Height (m) of the look-at point on the car. |
| `start_reveal_cam_fov` | `55.0` | FOV (deg) of the anchored reveal shot. |
| `start_queue_gap` | `7.0` | Gap (m) between grid cars along the start heading. |
| `start_queue_stagger_seconds` | `0.35` | (Reserved) stagger between successive launches. |
| `start_fade_seconds` | `0.6` | Length of each half (out, back) of the fade. |
| `start_lead_in_ahead_m` | `22.0` | Straight road forced ahead of the start line (also the departed-car despawn distance). |
| `start_lead_in_behind_m` | `30.0` | Straight road behind the line for the staged player (three gaps back). |
| `start_spawn_clearance` | `0.5` | Height (m) cars are seated above the road at spawn. |

See [configuration.md](configuration.md).

## Tests

- `tests/headless/test_start_line.gd` — three real opponents line up ahead (from the leaders'
  `car_id`s) and **nothing behind** the player, spaced one gap apart (a spacing assertion, so
  the physics-server stacking regression can't recur); grid cars are scripted + axis-locked +
  live; the player is staged three gaps back; the grid spawn doesn't clobber the player's
  config; Start flies the camera then reveals P1; the reveal card shows the current front
  opponent's name/car/time, the gap to P1 (P1 = FASTEST), and the overall championship rank
  (hidden on event 1, shown from event 2); **Next** floors the front car and reveals the next
  opponent **immediately** (eager reveal — no wait for the roll-up); three Nexts walk
  P1→P2→P3, then the player reaches the line, the fade runs and `begin_countdown()` fires
  exactly once; empty leaders skip straight to the fade; the eligibility / over-power gates
  and the Tune Car / Upgrades overlays behave as before; an underpowered-but-eligible car
  launches straight through (its warning now lives at car selection, not the start line).
- `tests/headless/test_rally_session.gd` — `current_event_leaders()` returns the top three
  rivals (fastest first, DNF-this-event omitted) each with `car_id` (so the grid can spawn
  their actual car), `car_name` and `time_ms`.
- `tests/headless/test_stage_manager.gd` — the `STAGING` phase holds until
  `begin_countdown()`, which is a no-op outside `STAGING`.
