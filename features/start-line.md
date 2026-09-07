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

> **The rival reveal is BACK, one rival wide** (decision 5 still holds — no
> rival FIELD). Before the pivot this screen ran a four-phase sequence —
> `MENU → FLY_IN → REVEAL → FADE` — where `FLY_IN`/`REVEAL` lined up the real
> top-three rivals ahead of the player and walked them to the line one Next
> press at a time, reading the career session's `current_event_leaders(3)`. The
> pivot deleted that along with the field; what runs today revives its SHAPE
> for the one rival the roguelike kept: the ghost is parked ON THE GRID ahead
> of the player, the menu auto-flies to a low 3/4 shot in front of it (no press
> needed — the reveal is the intro, not a reward for starting), and the rival
> card appears only when the camera arrives. `setup()` still takes no `leaders`
> argument, and the grid-spawn / roll-up / proximity-attenuation machinery
> stays gone — one parked ghost replaces the three-car queue.

> **The rival is a ghost, not a field** ([rival-ghost.md](rival-ghost.md)).
> A staged region run's fixed clock (`RegionRunMode.stage_target_ms`) is
> visualised as a single posed `Car` — `RivalGhost` — driving `world.gd`'s
> pace-scaled profile. The start line poses it ONCE, on its grid slot
> (`RivalGhost.pose_at_distance`, `start_queue_gap` down the lead-in); it sits
> scripted-solid through the sequence and keeps driving through the
> countdown/run afterward for the live HUD delta ([hud.md](hud.md)). This is a
> much lighter thing than the deleted field — ONE car, posed not simulated — so
> it does not reopen decision 5 ("no rival field"): there is still no opponent
> to race position against, only a pace line to read a delta off.

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
2. **FLY_IN** — after `start_reveal_idle_seconds` of orbit (no press needed),
   the camera flies from the orbit pose to the reveal shot: a low 3/4 in FRONT
   of the rival on its grid slot (the deleted per-opponent anchor re-framed on
   the one ghost), lerping its FOV to `start_reveal_cam_fov`. Only a profiled
   ghost WITH a frameable car triggers the fly; a profiled ghost with none
   (unsolvable roster — nothing to frame) skips straight to the reveal, and no
   ghost at all never leaves the orbit idle.
3. **REVEAL** — arrived at the rival, the **rival card** shows: the ghost's
   **driver name** (`RivalGhost.rival_name()`), the **car they wear**
   (`rival_car_name()` — a real CarLibrary entry picked to match the target's
   pace, see [rival-ghost.md](rival-ghost.md)), and a gold **"Time to beat"**
   stat row with the target clock itself (`RivalGhost.target_ms()`, formatted
   exactly like the HUD's timer via `UITheme.format_time`). This is the deleted
   per-opponent reveal card, trimmed to the one rival — and the timing is the
   point: the target lands WITH the car it belongs to, not while the menu
   idles. The menu row stays live (Start / Tune Car / Exit all work from
   here), so the player can tune against the clock on screen. Test readouts:
   `rival_card_visible()` / `rival_card_name()` / `rival_card_car()` /
   `rival_card_time()`. The card is filled at overlay build
   (`_refresh_rival_card`) and re-filled on reveal entry; it hides entirely
   when there is no ghost or no target (challenge stages, degenerate tracks,
   plain dev boots), restoring the header + clear-band shape.
4. **FADE_OUT / FADE_IN** — on Start (from MENU or REVEAL), the screen fades to
   black (`start_fade_seconds` each half). At full black the camera hands back to the
   player's **selected** camera (chase or bonnet, via `CameraManager`), the
   driving UI returns, the player is released from staging and snapped exactly
   onto the line, and `StageManager.begin_countdown()` starts the countdown;
   then the screen fades back in. `launch()` goes straight from a passed
   eligibility gate to `Seq.FADE_OUT`; a press mid-fly is ignored for the fly's
   second or so, the way the deleted sequence treated input between its phases.

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

**Who reveals, by construction** — `_driven_car()` resolves to whichever car
`RunSession`/`DrivingContext` has locked for the active run. The rival GHOST
([rival-ghost.md](rival-ghost.md)) `world.gd` may hand `setup()` is the only
reveal participant: a stage whose track solved no target gets no ghost, the
MENU never auto-flies, and the sequence is the pre-pivot challenge stage's
rival-free MENU → fade path again. The card hides with the ghost; the fly
hides without a frameable car.

## Staging the player (and the one grid rival)

The player is staged at the line: `reset_to` (a queued teleport, since a
bare `global_transform` write on a `VehicleBody3D` is discarded by the physics
server — see `car.gd::reset_to`) places it at the captured start pose, seated
`start_spawn_clearance` above the road so it settles onto its wheels. It is
scripted like the old grid cars were (`ai_controlled` + zeroed `ai_throttle` /
`ai_steer`, axis-locked laterally and in yaw so it can't drift during the MENU
orbit idle) and released at the hand-off (`_release_player`): AI override and
axis locks cleared, gearbox-auto restored, snapped back onto the line via
`reset_to`.

What parks on the grid today is the ONE ghost: `setup()` calls
`RivalGhost.pose_at_distance(start_queue_gap)` — a raw track distance one gap
down the lead-in, in the ghost's usual cosmetic lane offset — and nothing
re-poses it until the hand-off, which snaps it back to the line (where the
profile's s=0 puts it for the run) under cover of the fade. The **roll-up and
per-car proximity attenuation staging** that kept three extra cars alive
through the old sequence stay gone; the ghost is kinematic and
collision-free, so it neither shoves the staged player nor needs despawning —
there is nothing left to spawn, sequence or despawn but the player and the
rival that was always going to drive the stage.

## Wiring & lifecycle

`world.gd._should_stage()` gates the whole sequence (see above). When true,
`world.gd` sets up the `StageManager` `staged` and builds the `StartLine` after
generation, handing it `$Car`, `$Floor`, `$CameraManager`, `$HUD`,
`$MobileControls`, the pause menu, and — for a staged region run whose track
actually solved a target — the `RivalGhost` it built in `_setup_rival_ghost`
(see [rival-ghost.md](rival-ghost.md)). Each stage reloads `main.tscn`, so a
fresh `StartLine` is built per stage; the `RivalGhost` node, like the other
persistent managers `_build_persistent_managers` owns, is reused across a
same-run stage change rather than rebuilt. A between-stage repair popup (`RepairReveal`,
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
| `start_queue_gap` | Grid gap (m) the rival ghost parks ahead of the player on the lead-in. |
| `start_reveal_idle_seconds` | Orbit beat before the reveal fly begins (the fly is automatic). |
| `start_reveal_fly_seconds` | Fly from the orbit pose to the reveal shot. |
| `start_reveal_cam_front_m` / `_side_m` / `_height_m` / `_look_height_m` / `start_reveal_cam_fov` | The reveal shot: a low 3/4 in front of the rival on its grid slot. |

See [configuration.md](configuration.md). Most of the reveal-only knobs the
pre-pivot screen read came back with the one-rival revival (`start_queue_gap`,
`start_reveal_*` — old defaults included, plus a new idle beat); the
`start_queue_stagger_seconds` and `start_roll_*` knobs stayed deleted with the
queue and roll-up they drove, and the `start_lead_in_*` road reservation
remains the generator's, untouched by this screen — the grid slot needs far
less straight road than the three-car queue it replaced.

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
rating ceiling; a wired rival ghost is parked one grid gap ahead of the player
at setup and never re-posed by the sequence, the menu auto-flies once the idle
beat is out (FOV and anchor landed), the rival card appears only in REVEAL and
not during the menu, a carless ghost reveals the card without the fly, Start
from REVEAL fades straight to the countdown, and a `null` ghost (a challenge
stage, or a degenerate track) is a harmless no-op that never leaves the MENU
or shows a card. See
[rival-ghost.md](rival-ghost.md) for the ghost's own maths/pose tests
(`tests/headless/test_rival_ghost.gd`).
covers the `STAGING` phase holding until `begin_countdown()`, a no-op outside
`STAGING`.
