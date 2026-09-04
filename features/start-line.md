# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` (`_build_start_line`) for staged `RunSession` runs
(a Daily/Weekly/Monthly challenge period or a region run — see
[region-runs.md](region-runs.md)). Holds the [`StageManager`](stage.md) in its
`STAGING` phase and launches it after a short menu + fade. Uses the
scripted-control hook on [`car.gd`](car-physics.md) to stage the player.

**Tests:** `tests/headless/test_start_line.gd`, `tests/headless/test_stage_manager.gd`

The moment between picking a car and the `3·2·1·GO` countdown. It runs **inside
the live stage scene** (`main.tscn`) once the world is built and a `RunSession`
run is active, while the car is held locked. `world.gd._should_stage()` gates it:
`Config.data.start_line_enabled` **and** `RunSession.is_active()` **and** a
resolvable stage — a run with no stage left never strands the car in `STAGING`
with nothing to launch it. A plain dev boot of `main.tscn` (no session) never
builds a `StartLine` and the countdown arms immediately.

> **The rival reveal is DELETED; the MENU survives** (`todo/roguelike-pivot.md`
> decisions 5 and 29). Before the pivot this screen ran a four-phase sequence —
> `MENU → FLY_IN → REVEAL → FADE` — where `FLY_IN`/`REVEAL` lined up the real
> top-three rivals ahead of the player and walked them up to the line one
> opponent at a time, reading `RallySession.current_event_leaders(3)`. Rivals are
> gone entirely (decision 5: "rivals are dropped entirely; you race the clock,
> not a field"), so there is no field left to reveal. `StartLine.Seq` is now just
> `{ MENU, FADE_OUT, FADE_IN, DONE }`; `setup()` no longer takes a `leaders`
> argument, and the grid-spawn / roll-up / proximity-attenuation machinery that
> used to stage three extra cars is gone with it. What survives from the old
> sequence is the **MENU itself and its fade** — a challenge stage already ran an
> identical rival-free path before the pivot (the empty-leaders branch), so this
> is the shape every session now uses, not a new one.

## Sequence (`StartLine.Seq`), driven in `_process`

1. **MENU** — house-style black panels (`UITheme`): a top card reads
   `<rally/stage name> — Stage N of TOTAL` (`_stage_total`: the rally's own
   authored `events` count if the rally carries one, else `RunSession.stage_count()`
   — only the latter applies today, since no career rally reaches this screen any
   more), and a bottom action row holds **`< Exit`**, **`Tune Car`**, **`Start`**
   (leftmost-to-primary order). An **orbit camera** idles on the player's car
   in the clear band between the two cards. The HUD and mobile controls are
   hidden. All three buttons and the Tune Car overlay are keyboard/gamepad
   navigable via `MenuNav`.
   - **Only Start launches.** Pressing it runs the eligibility gate (below);
     only on passing does the sequence advance to the fade.
   - **`< Exit`** routes through the pause menu's `confirm_quit_to_hq()` (a
     no-op with no pause menu wired, e.g. bare test harnesses) — it exists here
     because the pause menu is suppressed for the whole staged window (a second
     full-screen menu stacked over this one would just fight it for input), so
     without this button the player would be stuck on the start line with no way
     out short of finishing the stage.
   - **Tune Car** opens the shared `TuningPanel` (grip / brake-bias / aero for
     this stage; edits re-field the live car via `car.retune()` — **not**
     `apply_owned`, which would reshape and corrupt the staged body). Detune is
     a power lever, not a handling one, and has no home here any more — see
     "The Upgrades page is gone" below.
   - **The Upgrades page is gone** (decision 29: "the start line offers Tune
     Car only"). Before the parts model was deleted this screen also hosted an
     `UpgradesGrid` for swapping parts or detuning pre-stage; upgrades have
     nothing to show once parts are gone and boosts are picked **between**
     stages instead (`todo/roguelike-pivot-plan.md` stage 5). `car.gd`'s
     `refit_upgrades()` — the live re-derive that page drove — is kept
     specifically for stage 5 to apply a picked boost through; see its own
     comment.
2. **FADE_OUT / FADE_IN** — on Start, the screen fades to black
   (`start_fade_seconds` each half). At full black the camera hands back to the
   player's **selected** camera (chase or bonnet, via `CameraManager`), the
   driving UI returns, the player is released from staging and snapped exactly
   onto the line, and `StageManager.begin_countdown()` starts the countdown;
   then the screen fades back in. There is no per-opponent reveal step between
   MENU and the fade any more — `launch()` goes straight from a passed
   eligibility gate to `Seq.FADE_OUT`.

**Eligibility gate** — Pressing **Start** resolves the driven car
(`DrivingContext.driven_car()`), computes its effective stats
(`UpgradeLibrary.effective_meta`) and calls
`RallyLibrary.ineligibility_reason(_rally, meta)`; if non-empty, launch is
blocked with a **"Can't start"** `ConfirmPopup` carrying the reason and a
**Cancel** button — there is no "Change Upgrades" route from here any more,
since nothing reachable from this screen can change the KIND of car (an engine
swap or drivetrain conversion) now that the Upgrades page is gone. The gate is
purely **categorical** (body type, country, doors, cylinders, displacement,
drive mode); there is no power-to-weight band or detune-to-qualify flow.

**No leaders to reveal, by construction** — `_driven_car()` resolves to
whichever car `RunSession`/`DrivingContext` has locked for the active run; there
is no rival field for any run mode any more, so the old "empty leaders skip the
reveal" branch is simply the only path there ever is now.

## Staging the player (no grid any more)

The player alone is staged at the line: `reset_to` (a queued teleport, since a
bare `global_transform` write on a `VehicleBody3D` is discarded by the physics
server — see `car.gd::reset_to`) places it at the captured start pose, seated
`start_spawn_clearance` above the road so it settles onto its wheels. It is
scripted like the old grid cars were (`ai_controlled` + zeroed `ai_throttle` /
`ai_steer`, axis-locked laterally and in yaw so it can't drift during the MENU
orbit idle) and released at the hand-off (`_release_player`): AI override and
axis locks cleared, gearbox-auto restored, snapped back onto the line via
`reset_to`. The **grid of opponent cars, the roll-up, and the per-car proximity
attenuation staging** that used to keep three extra cars alive during the
sequence are gone with the rival field — there is nothing left to spawn,
sequence or despawn but the player.

## Wiring & lifecycle

`world.gd._should_stage()` gates the whole sequence (see above). When true,
`world.gd` sets up the `StageManager` `staged` and builds the `StartLine` after
generation, handing it `$Car`, `$Floor`, `$CameraManager`, `$HUD`,
`$MobileControls` and the pause menu. Each stage reloads `main.tscn`, so a fresh
`StartLine` is built per stage. A between-stage repair popup (`RepairReveal`,
shown before the `StartLine` overlay exists) re-seats keyboard/gamepad focus on
Start via `grab_start_focus()` once dismissed, since freeing its own focused
button clears the viewport's focus owner outright and nothing else re-grabs it.

## Config knobs

| Field | Purpose |
|-------|---------|
| `start_line_enabled` | Run the start-line sequence at all. Off → straight to the countdown. |
| `start_orbit_speed` / `start_orbit_radius` / `start_orbit_height` / `start_orbit_fov` | The MENU idle orbit camera. |
| `start_fade_seconds` | Length of each half (out, back) of the hand-off fade. |
| `start_spawn_clearance` | Height (m) the player is seated above the road at spawn. |

See [configuration.md](configuration.md). The reveal-only knobs this screen used
to read (`start_reveal_*`, `start_queue_gap`, `start_queue_stagger_seconds`,
`start_lead_in_*`) went with the rival field and the grid it staged — a stage
still needs *some* straight road at its start for the countdown, but the
multi-car lead-in reservation these drove is gone along with the grid it was
sized for.

## Tests

`tests/headless/test_start_line.gd` — the MENU hides the HUD and takes the
camera; the action row is horizontal, fits the screen, and offers a way out
(`< Exit`); `grab_start_focus` seats the cursor on Start; **Start** is gated by
rally eligibility and, once eligible, goes straight to the fade and starts the
countdown (idempotent against a second press); the hand-off releases the player
to normal driving and restores the player's **selected** camera (not always
chase); the Tune Car overlay opens/closes and edits go through `retune`
(preserving the staged pose) rather than reshaping the car; a fitted turbo
reaches the same live config the HUD reads (config-identity regression guard);
a challenge stage's menus bind to the challenge's locked car, fade straight to
the countdown, count the run's own stage total, and read the challenge period's
rating ceiling. `tests/headless/test_stage_manager.gd` covers the `STAGING`
phase holding until `begin_countdown()`, a no-op outside `STAGING`.
