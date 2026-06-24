# Stage Start & End Procedure — implementation spec

> Status: **planned, not yet implemented.** Implementation brief, referencing the
> code as it exists on this branch. Follow the config-first convention
> (`CLAUDE.md`): every new tunable goes in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`), never hardcoded.
> Update the relevant `features/*.md` doc and add/adjust tests in the same piece
> of work.
>
> **Depends on `todo/track-progress-and-reset.md`.** The "stage complete" trigger
> reads the progress value produced by the `TrackProgress` node defined there
> (`progress_percent()` / `_best_offset` / `_baked_length`). Implement track
> progress first, or at least land its `TrackProgress` API, before this.

## Goal

A per-stage start/end flow on top of the existing always-live scene:

1. **Start** — at the start of a stage, **lock the car's controls** and run a
   **3-second countdown** shown as a **big centered `3 · 2 · 1 · GO`** overlay.
   While locked the car holds position (handbrake forced on) so it can't roll.
2. **Run** — the instant the countdown finishes, **unlock controls** and **start
   an elapsed timer**, shown as **small text in the top-right corner**.
3. **End** — when **progress reaches 100%**, **stop the timer** and **show the
   stage-complete menu**.

> The contents/actions of the stage-complete menu (restart, retry same seed, new
> track, best time, etc.) are **out of scope here** and will be specified in a
> separate menus todo. This spec only goes as far as: stop the timer, freeze the
> final time, and **surface a `stage_completed(elapsed_seconds)` hook + show a
> placeholder panel** that the future menu attaches to. *(The rally-level consumer
> of that hook is `todo/rally-event-flow.md`, which sequences 3 events into a
> rally.)*

## Context / current state (measured from the code)

- **The scene is live the moment it loads.** `world.gd._ready()` applies config,
  spawns the car, and generates the track (`scripts/world.gd:10-69`); the car is
  immediately drivable. There is **no stage / countdown / race concept today.**
- **Car input** is read every physics tick in `Car._physics_process`
  (`scripts/car.gd:85-198`): gear/shift via `is_action_just_pressed`
  (`:88-96`), throttle via `Input.get_axis("brake_reverse","accelerate")`
  (`:98`), handbrake via `Input.is_action_pressed("handbrake")` passed straight
  into `drivetrain.step(...)` (`:134`), steering via
  `Input.get_axis("steer_right","steer_left")` (`:164`), and the manual reset via
  `is_action_just_pressed("reset_car")` (`:196-197`). **No control-lock flag
  exists.**
- **HUD** is a `CanvasLayer` (layer 2), `scripts/hud.gd`, with labels positioned
  by offsets in `main.tscn:87-142` (`SpeedLabel`, `GearLabel`, `RPMLabel`,
  buttons). Updated each frame in `hud.gd._process` (`:39-46`) via
  `label.text = "..."`. **The top-right corner is currently empty.** No menu /
  popup / pause UI exists anywhere; nothing uses `get_tree().paused`.
- **Timing** is delta-based throughout (`_physics_process(delta)` /
  `_process(delta)`); the project uses no `Timer` nodes and tracks no elapsed
  time today.
- **Main scene** root is `Main` (Node3D, `world.gd`) — children `Floor`, `Car`,
  `ChaseCamera`, `CameraManager`, `PostProcess`, `HUD`, `MobileControls`
  (`project.godot:run/main_scene="res://main.tscn"`).
- **Progress (from the dependency spec):** `TrackProgress` exposes
  `progress_percent() -> float` (0–100) over a monotonic `_best_offset`
  (metres along the `Curve2D`) and cached `_baked_length`. Monotonic = it only
  ever advances, so "reached 100%" is a one-way edge.
- **Config** lives in `scripts/game_config.gd` as `@export_group` blocks (e.g.
  `@export_group("Track")` at `:252-267`, `@export_group("HUD")` with
  `hud_enabled`); read via the `Config.data` autoload.
- **Tests:** GUT in `tests/headless/`; instantiate `main.tscn` in `before_each`,
  `add_child_autofree`, `await get_tree().physics_frame` /
  `process_frame`, assert on nodes (`test_smoke.gd`, `test_hud.gd`).

---

## 1. A `StageManager` to own the flow

Add a small coordinator node (`scripts/stage_manager.gd`,
`class_name StageManager extends Node`), created and wired in
`world.gd._ready()` (after the car + track exist, near `scripts/world.gd:48`).
It owns a tiny state machine and the elapsed timer; it does **not** contain
gameplay physics or UI layout — it drives the car lock flag, the HUD, and reads
`TrackProgress`.

State:
```gdscript
enum Phase { COUNTDOWN, RUNNING, COMPLETE }
var _phase: int = Phase.COUNTDOWN
var _countdown_left: float          # seconds remaining, starts at cfg.stage_countdown_seconds
var _elapsed: float = 0.0           # stage time, starts at 0 when RUNNING begins
signal stage_started                # countdown finished, timer running
signal stage_completed(elapsed_seconds: float)
```

References passed in via a `setup(car, hud, progress)` call from `world.gd`:
`Car`, the HUD (for countdown + timer + complete panel), and the `TrackProgress`
node.

`_process(delta)` (per-frame is fine; this is UI/timing, not physics):
```gdscript
func _process(delta: float) -> void:
    match _phase:
        Phase.COUNTDOWN:
            _countdown_left -= delta
            _hud.show_countdown(_countdown_left)         # see §3
            if _countdown_left <= 0.0:
                _phase = Phase.RUNNING
                _car.controls_locked = false             # see §2
                _hud.hide_countdown()
                stage_started.emit()
        Phase.RUNNING:
            _elapsed += delta
            _hud.show_elapsed(_elapsed)                  # see §4
            if _progress.progress_percent() >= cfg().stage_complete_percent:
                _phase = Phase.COMPLETE
                _hud.show_stage_complete(_elapsed)       # see §5
                stage_completed.emit(_elapsed)
```

On `_ready()` of the manager: `_countdown_left = cfg().stage_countdown_seconds`
and `_car.controls_locked = true` so controls are locked from frame one.

Notes:
- **100% edge:** because progress is monotonic and the reset snaps the car to the
  centerline, `_best_offset` may approach but not exactly equal `_baked_length`.
  Use a config threshold `stage_complete_percent` (default **99.0**), not an
  exact `== 100.0`, so finishing is reliable. (Document the relationship with the
  track-progress reset behaviour.)
- Keep `_elapsed` on the **same clock** that's displayed; `_process` delta is
  fine for a stopwatch. (If frame-rate independence at the millisecond level ever
  matters, switch to physics-tick accumulation — not needed for a stopwatch.)

## 2. Lock controls via a flag on the car (hold handbrake)

Add a public flag to `scripts/car.gd` and gate the input reads in
`_physics_process` (`:85-198`). Rather than skipping the whole tick, **neutralise
driver input and force the handbrake on** so the car physically holds still on a
slope during the countdown:

```gdscript
var controls_locked: bool = false   # set by StageManager

# inside _physics_process, replacing the raw input reads:
var throttle := 0.0 if controls_locked else Input.get_axis("brake_reverse", "accelerate")
var steer_input := 0.0 if controls_locked else Input.get_axis("steer_right", "steer_left")
var handbrake := controls_locked or Input.is_action_pressed("handbrake")
# ... pass `handbrake` into drivetrain.step(...) at :134 ...
# Guard the discrete actions too (gear/shift at :88-96, reset at :196-197):
if not controls_locked:
    # gear/shift/reset handling
```

This keeps drag/downforce/suspension running so the car settles naturally, the
camera stays live, and the countdown animates — matching the "input gate flag"
choice. Forcing the handbrake covers the "in case it starts to roll" case
without freezing the whole simulation.

(The existing manual `reset_car` is gated too, so the player can't reset mid-
countdown; the off-track auto-reset from the track-progress spec is unaffected
and still protects the run.)

## 3. Countdown UI — big centered `3 · 2 · 1 · GO`

Add a large centered label to the HUD (`main.tscn` under the `HUD` CanvasLayer,
anchored center; large `font_size`, e.g. 64) — `CountdownLabel`, hidden by
default. Drive it from `hud.gd`:

```gdscript
func show_countdown(seconds_left: float) -> void:
    _countdown_label.visible = true
    if seconds_left > 0.0:
        _countdown_label.text = str(ceili(seconds_left))   # 3, 2, 1
    else:
        _countdown_label.text = "GO"

func hide_countdown() -> void:
    # brief "GO" flash then hide — e.g. keep visible ~0.5s after RUNNING starts,
    # or hide immediately. Tunable; start with a short fade/flash.
    _countdown_label.visible = false
```

`ceili(seconds_left)` gives `3` for (3,2], `2` for (2,1], `1` for (1,0], then
`GO` at 0. Optional polish: a quick scale/fade tween per tick — keep cheap,
respect the project's lean rendering. The brief `GO` flash can be handled by the
`StageManager` holding the label visible for ~0.5 s into `RUNNING` before calling
`hide_countdown()`; start simple and tune.

## 4. Elapsed timer — small text, top-right

Add `ElapsedLabel` to the HUD, anchored top-right (`anchor_left=1.0`,
`anchor_right=1.0`, `offset_left=-100`, `offset_top=8`, `offset_right=-8`,
`offset_bottom=28`; small `font_size` ~14 to match the speed label). Hidden until
`RUNNING`. Formatting in `hud.gd`:

```gdscript
func show_elapsed(t: float) -> void:
    _elapsed_label.visible = true
    var minutes := int(t) / 60
    var seconds := t - minutes * 60.0
    _elapsed_label.text = "%d:%05.2f" % [minutes, seconds]   # e.g. 1:07.43
```

Avoid extra per-frame allocation beyond the single formatted string (consistent
with the HUD note in `todo/performance-optimisations.md` item 10). Gate behind a
`hud_elapsed_enabled` config flag (mirrors the existing `hud_enabled` pattern).

## 5. Stage-complete hook (menu deferred to a later todo)

On reaching `stage_complete_percent`:
- Freeze the timer (stop incrementing `_elapsed`; `_phase = COMPLETE`).
- `stage_completed.emit(_elapsed)`.
- `hud.show_stage_complete(_elapsed)` shows a **placeholder** panel
  (`StageCompletePanel`, a hidden `PanelContainer`/`Control` under `HUD`) with at
  minimum the final time. **Do not design the menu's buttons/actions here** —
  that's a separate menus todo. Leave the panel as a clearly-marked stub plus the
  `stage_completed` signal so the menu work can hang off it.
- Consider re-locking controls (`car.controls_locked = true`) on completion so
  the finished car doesn't keep driving under the panel — decide alongside the
  menu spec; default to **re-lock** here.

## 6. Config knobs (config-first)

Add a new `@export_group("Stage")` to `scripts/game_config.gd` (alongside the
`Track`/`HUD` groups) and document defaults; override in
`config/game_config.tres` only if the live game needs different values:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `stage_countdown_seconds` | float | `3.0` | Countdown length before controls unlock. |
| `stage_complete_percent` | float | `99.0` | Progress % that ends the stage (monotonic; <100 for reliability — see §1). |
| `hud_elapsed_enabled` | bool | `true` | Show the top-right elapsed timer. |

No quality-tier branching — single shipped values, tunable for dev/debug,
consistent with the project's inherently-lean design.

## 7. Tests

Add to `tests/headless/` (GUT; `./run_tests.sh` in the background):
- **Locked at start:** instantiate `main.tscn`; assert `Car.controls_locked` is
  `true` during the countdown phase and driver input is ignored (set inputs /
  call the input path and assert no drive applied / handbrake held).
- **Countdown → run:** advance time `stage_countdown_seconds`; assert phase flips
  to `RUNNING`, `controls_locked` becomes `false`, `stage_started` fired.
- **Countdown label text:** `show_countdown(2.5)` → `"2"`, `show_countdown(0.0)`
  → `"GO"` (test the formatting function directly).
- **Timer runs:** in `RUNNING`, `_elapsed` increases each frame; `ElapsedLabel`
  visible and formatted (`"%d:%05.2f"`).
- **Complete edge:** drive `progress_percent()` to ≥ `stage_complete_percent`
  (use a stub/fake `TrackProgress`); assert phase → `COMPLETE`, timer frozen,
  `stage_completed(elapsed)` fired with the frozen value, panel visible.
- Prefer unit-testing `StageManager` against a **fake progress source** so the
  end condition doesn't require driving the whole track.

## Implementation order

1. §6 — config group (so nothing is hardcoded).
2. §2 — `Car.controls_locked` flag + input gating (small, testable in isolation).
3. §1 — `StageManager` state machine, wired in `world.gd._ready()`.
4. §3 + §4 — countdown label and elapsed label in `main.tscn` + `hud.gd`.
5. §5 — stage-complete stub + `stage_completed` signal (full menu = later todo).
6. §7 — tests; update `features/` (HUD/rendering doc, + optional
   `features/stage.md` indexed in `features/README.md`).

## Files touched (summary)

| File | Change |
|---|---|
| `scripts/car.gd` | Add `controls_locked` flag; gate input reads in `_physics_process` (`:88-96`, `:98`, `:134`, `:164`, `:196-197`); force handbrake when locked. |
| `scripts/stage_manager.gd` | **New.** COUNTDOWN→RUNNING→COMPLETE state machine; owns `_elapsed`; signals `stage_started` / `stage_completed`. |
| `scripts/world.gd` | Create + `setup()` the `StageManager` after car/track/progress exist (`:48`). |
| `scripts/hud.gd` | `show_countdown` / `hide_countdown` / `show_elapsed` / `show_stage_complete`; new label refs. |
| `main.tscn` | Add `CountdownLabel` (centered, large), `ElapsedLabel` (top-right, small), `StageCompletePanel` (hidden stub) under `HUD` (`:87-142`). |
| `scripts/game_config.gd` | New `@export_group("Stage")`: `stage_countdown_seconds`, `stage_complete_percent`, `hud_elapsed_enabled`. |
| `config/game_config.tres` | Overrides only if needed. |
| `features/` (+ `features/README.md`) | Document the stage flow. |
| `tests/headless/` | Stage start/end tests (with a fake progress source). |

## Open / deferred (own a follow-up todo)

- **Stage-complete menu contents & actions** (restart, retry same seed, new
  track, best/previous time, etc.) — explicitly deferred to a separate menus
  todo; this spec only provides the `stage_completed` signal + placeholder panel.
