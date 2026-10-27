# Debug Tools

## Dev keys (exposed to every build)

| Key | Action | Does |
|-----|--------|------|
| **H** | `toggle_debug_arrows` | Per-wheel force arrows + the HUD dev readout (below) |
| **F8** | `reload_config` | Re-read `config/game_config.tres` from disk and re-apply, no restart |

Both are gated on `SettingsMenu.dev_tools_enabled()`, which defaults to **true** — release
exports (including the web build) get them too, same as the editor and debug exports. A config
value that starts a feature on still works in any build regardless of the switch.

**Tests:** `tests/headless/test_debug_arrows.gd`, `tests/headless/test_hud.gd`, `tests/headless/test_perf_overlay.gd`, `tests/headless/test_perf_log.gd`, `tests/headless/test_benchmark_mode.gd`

## Wheel force visualization

**Source:** `scripts/wheel_force_debug.gd` (`class_name WheelForceDebug extends
MeshInstance3D`). Created by `car.gd` in `_ready()`.

Draws per-wheel and aero force arrows as an immediate mesh. Toggled with **H**
(`toggle_debug_arrows` input action). The **H** toggle responds whenever
`SettingsMenu.dev_tools_enabled()` is true (the default in every build, including
release exports such as the web build), so players can summon the dev arrows too.
A config that starts them visible (`debug_wheel_forces`) still works in any build.

The **H** toggle is handled in `car.gd._timed_physics_process`, **before** the
drivetrain step — not in the overlay. The car flips the overlay's `visible`, hides
the body, and sets `drivetrain.publish_readouts = <overlay visible>`. The drivetrain
only builds its per-wheel `readouts` dicts while `publish_readouts` is on (pure waste
otherwise). Deciding it before the step is essential: the overlay is a **child** of
the car, so it runs *after* the parent's step — if it flipped the gate itself the
readouts would lag a frame and the arrows would draw in empty the frame they're
toggled on. The overlay now just renders whatever visibility it's left in.

| Color | Force |
|-------|-------|
| Green | suspension normal force |
| Red | tire friction force (applied by drivetrain) |
| Blue | aero downforce (at axle midpoints) |
| Yellow | combined steer-assist torque (single arrow above the roof) |

The **yellow** arrow is a single helper for the two steering aids combined —
the understeer steer assist and the spin-protection torque, which are both yaw
torques about the car's up axis. `car.steer_assist_readout` sums them into one
signed scalar (positive = the aids are rotating the nose **left**), reset and
re-accumulated every physics tick. The overlay draws it above the roof pointing
**left/right** along the car's lateral axis, its length scaling with the total
torque (`debug_assist_arrow_scale`, m per N·m). A zero-length arrow (no assist
active) is skipped.

`_physics_process(delta)` rebuilds the mesh each frame from:
- `drivetrain.readouts` — per-wheel `{normal, demand, applied, grip}` data (the arrows
  use the first three; `grip` feeds the HUD grid below),
- `car.downforce_readouts` — `[global_point, force_vector]` pairs.

The same **H** toggle also reveals the HUD's numeric readout cluster — membership is
`hud.gd` → `DEBUG_READOUT_NODES`, read it there rather than from any prose list
(hidden by default — a dev diagnostic; see [hud.md](hud.md)). The boost line
reads the live boost pressure as a percentage of full boost (`hud.gd`'s pure
`boost_text` off `maxf(EngineSim.boost, EngineSim.sc_boost)`, so a supercharger's belt
boost shares the gauge), or `Boost N/A` on a naturally-aspirated engine (no turbo and
no blower gain) — see [forced-induction.md](forced-induction.md). A **seed**
line below it shows the current world seed (`Config.data.track_seed`, via the pure
`seed_text`) so a generated stage can be identified and reproduced. It also shows a transparent overlay of
the chassis collision hull (a chamfered octagon — see
[car-physics.md](car-physics.md) → "Hitbox shape"). It's a `MeshInstance3D` with an
`ArrayMesh`, parented under the car's `CollisionShape3D` so it inherits the shape's exact
transform; the prism is rebuilt from the `ConvexPolygonShape3D` points whenever they
change while visible (cars swap the hull at runtime via `apply_car`).

While the overlay is shown the **car body is hidden** (`Car.set_body_hidden(true)` —
procedural chassis/cabin boxes and any glb model body), because the hull is drawn a
little smaller than the visible body and would otherwise be obscured by it. Dismissing
the overlay restores the body by re-running the normal per-spec visibility
(`_apply_model_visibility`). Wheels stay visible either way.

## Per-tire grip grid

**Source:** `hud.gd` → `_build_grip_grid` / `_update_grip_grid`, plus the pure
`grip_text` / `grip_color` / `corner_index` statics. Revealed by the **same H toggle**
as everything else above (`GripGrid`, a code-built `GridContainer`, stacked under the
seed label).

Four readouts laid out as the car's **plan view** — front axle on the top row, left
wheel in the left column — so a number maps onto a corner of the car without being read
off its label:

```
FL 62%   FR 118%
RL 41%   RR  38%
```

Each cell is how far up its grip curve that tire is — its combined slip over the slip
it peaks at (`Drivetrain.grip_fraction`, recorded per contact as `WheelContact.slip_use`
and published as `readouts[wheel].grip`). **100% = exactly on the limit**, and readings
**climb past 100%** while the tire slides; they are deliberately not clamped, because
that's the part worth seeing. Tinted neutral with grip in reserve, **gold** approaching
the limit, **red** at or past it. `--` means no reading: the wheel is off the ground (no
contact, or zero normal force), which is deliberately distinguished from `0%`.

**Why slip and not force.** The obvious metric — force generated over the `μN` limit —
**cannot exceed 100%**, because `_tire_force`'s force *is* `μN * _grip_curve(s)` and the
curve is capped at `1.0` at peak. Worse, past peak the curve *falls* toward the sliding
plateau (`sliding_grip_ratio`), so a force-based reading comes back **down** as the tire
lets go: "70%" would mean either "30% of the grip still in reserve" or "already sliding,
grip has collapsed to 70%" — opposite situations behind one number. Slip rises
monotonically through the limit, so it separates them.

The slip is the combined magnitude in `_tire_force`'s **scaled** slip space, with the
longitudinal component weighted by `traction_ellipse_ratio`. That's what lets one number
cover combined braking-and-cornering: the traction budget is an **ellipse**, not a
circle, and the weighting puts both axes on the same scale. The divisor is the contact's
own `slip_peak`, which is surface-dependent (gravel peaks at a larger slip angle than
tarmac), so the same reading means the same thing on any surface.

**This readout is now load-bearing, not just diagnostic.** The same per-wheel slip state
drives grip-servo steering (`Drivetrain.front_axle_state()` →
[car-physics.md](car-physics.md) → Steering), and the choice of a **slip** basis over a force
basis is what makes that servo stable. If you change `grip_fraction`, you change how the car
steers — see `tests/headless/test_grip_servo_steering.gd`.

Unlike the other H-gated readouts, this one does **not** keep
refreshing while hidden — `Drivetrain.readouts` is only populated while
`publish_readouts` is on, which the car ties to the force-arrow overlay's visibility
(the same H toggle), so there is nothing to read when it's down.

## Frame profiler overlay

**Source:** `scripts/perf_overlay.gd` (`class_name PerfOverlay extends
CanvasLayer`). Created by `world.gd` in `_ready()` (like the wheel-force
overlay), passing the `Floor` terrain manager for correlation and pointing
`measure_viewport` at the `PostProcess/View` SubViewport (where the 3D pass
actually runs in `main.tscn` — the root's 3D is disabled there). Toggled with
**P** (`toggle_perf_overlay`); hidden and idle by default. Forced on for a whole
run in benchmark mode via `activate()` ([benchmark.md](benchmark.md)). Text is
`FONT_SIZE` = 15 px so the readout is legible at a glance.

Diagnoses choppiness by separating the suspects per frame:

| Line | Tells you |
|------|-----------|
| frame current / avg / **MAX** | spike vs steady (max ≫ avg ⇒ intermittent stutter) |
| cpu process / physics | main-thread script + collision/physics cost |
| render **cpu** vs **gpu** | CPU-bound vs GPU-bound (fill rate, post-process shader) |
| draws / objects / prims | scene complexity / draw-call pressure |
| vram (tex) / nodes / phys objs | video-memory + scene-tree + active-physics pressure |
| chunks loaded / spikes / **audio overruns** | terrain ring size; running spike count; engine-audio buffer underruns |

The **audio overruns** count is the fielded car's engine `AudioStreamGenerator`
buffer underruns (`EngineAudio.skip_count()`), wired in by `world.gd`. It's the live
signal for main-thread audio starvation — most visible on the single-threaded web
build at the 30 fps cap, where a long frame drains the buffer before the next
`_process` fill (see `engine_audio.gd`'s `buffer_seconds()`). Drive normally with the
overlay up to catch which frames cause overruns.

While active it enables `RenderingServer.viewport_set_measure_render_time` and, on
every frame over the **spike threshold** — now relative to the fps cap
(`BenchmarkStats.spike_threshold_ms(Engine.max_fps)`: ~28 ms uncapped, ~50 ms at a
30 fps cap, so a steady 33 ms frame isn't miscounted) **or on any audio overrun** —
prints a `[PERF SPIKE]` line to stdout with the full breakdown **plus** whether a
terrain chunk was integrated that frame (`TerrainManager.integrations_total` delta)
and the frame's `audio_skips`. The GPU timer reads 0 on backends that don't support
it (and always headless); the overlay labels that case.

## PerfLog autoload (per-second log lines + per-script timing)

**Source:** `scripts/perf_log.gd`, registered as the `PerfLog` autoload. Gated on
`SettingsMenu.dev_tools_enabled()` (true by default in every build). Once per second it
prints to stdout (and therefore the Godot log at
`user://logs/godot.log`):

- `[perf] fps=… process=… physics=… draw_calls=… mem=…` — the headline
  `Performance` monitors, so a play session leaves a CPU/GPU cost trail that can
  be analyzed after the fact.
- `[perf-scripts] ms/frame: engine_audio=0.956 car=0.189 …` — average
  main-thread cost per rendered frame of each instrumented script, sorted
  descending, summed across all instances of the script (e.g. every AI car).

The per-script numbers come from a timing wrapper pattern: each per-frame
script keeps its real body in `_timed_process` / `_timed_physics_process`, and
the public `_process` / `_physics_process` callback times that call and reports
it via `PerfLog.track(&"<script name>", usec)`. When adding a NEW script with a
per-frame callback, follow the same pattern so it shows up in the table (and
note tests may call the public callback directly — keep its signature).

`PerfLog` also exposes a **benchmark capture window** (`begin_capture()` /
`end_capture(frame_count)`) that `track()` feeds regardless of
`OS.is_debug_build()`, so the benchmark's report can carry a per-script CPU
breakdown from the representative *release* web build (the per-second logger
above is off there). See [benchmark.md](benchmark.md) → "Feedback loop".

## Standalone dev scenes

Two scenes exist purely as dev rigs. Neither is the project's main scene and nothing in
the game links to either — **run them directly from the editor** (F6 / Run Current Scene),
or with `Godot res://<scene>.tscn`. Being editor-only, they sit outside the "every menu is
keyboard + gamepad navigable" rule in `CLAUDE.md`.

| Scene | Script | What it's for |
|-------|--------|---------------|
| `corner_catalog.tscn` | `corner_catalog.gd` | Draws every `CornerLibrary` turn type side by side so the bezier shapes can be eyeballed. Pure 2D. |
| `exhaust_lab.tscn` | `exhaust_lab.gd` | Positions each car's exhaust pipes by eye — one frozen car, flames forced permanently on, orbit camera. See [exhaust-flames.md](exhaust-flames.md). |

The exhaust lab is the one place **F8** (`reload_config`) is handled outside the HQ, and
that hot-reload is the whole reason `GameConfig.exhaust_offsets` lives in
`config/game_config.tres` rather than in `CarLibrary`: a `.tres` can be re-read from disk
mid-session, a `.gd` cannot. Drag to orbit, wheel to zoom, `[` / `]` (or Left/Right) to
cycle cars, F8 to re-read the config and re-apply the pipes. The readout prints each pipe
as a literal `Vector3(x, y, z)` ready to paste back into `exhaust_offsets`.

## Standalone performance benchmark

**Source:** `benchmark/perf_benchmark.gd` + `benchmark/perf_benchmark.tscn`, run
via `./run_benchmark.sh`. **NOT part of the test suite** — an on-demand tool for
investigating choppiness, with no pass/fail gate (numbers are machine-dependent).
It drives the SAME run as the player-facing, in-game benchmark (Settings →
Benchmark: feature toggles, auto-driven run, results breakdown — see
[benchmark.md](benchmark.md)), just headless/CLI instead of an on-screen results
panel.

```bash
./run_benchmark.sh             # windowed: real frame timing + GPU/render time
./run_benchmark.sh --headless  # CPU-only (no GPU timing), quick
```

It calls `Benchmark.begin()` and hosts `free_roam.tscn` as a child, so free roam
runs the benchmark drive (straight road, `Benchmark.WORLD_SEED`) while
`BenchmarkRunner` records per-frame samples. At the end it prints the `BenchmarkStats.summarise` breakdown to
stdout — fps (avg + 1% low), frame ms (avg/p95/p99/max), process/physics ms,
render cpu/gpu ms, draws/objects/prims, spike count and the `AutoDriver` streaming
report — then calls `Benchmark.end()` and quits. GPU timers
need a real display (skipped/zero under `--headless`) and aren't supported on
every backend (e.g. OpenGL/macOS may report 0) — then infer GPU cost from the
frame interval minus render-cpu.

## Road-curve probe jitter

`tools/probe_jitter.tscn` (headless) generates a real stage and reports, for several probe
spans, the worst frame-to-frame heading change and the number of curvature SIGN flips along
it.

It exists because the road curve is baked every 5 m and lerped, so anything sampling it
with a probe shorter than a chord gets a piecewise-constant reading that jumps at each
vertex. That is invisible in code review and hard to reproduce synthetically (a uniform arc
turns by the same angle at every vertex, so short probes look fine on one) — but it once made
the (now-deleted) rival ghost slide side to side, because a curvature sign flip swaps which
side of the road it sits on. Use this before trusting any new consumer of the road
centerline's geometry.

## Tests

`tests/headless/test_debug_arrows.gd` — verifies the force-arrow overlay updates
from the force readouts. `tests/headless/test_hud.gd` — the grip grid's 2x2 layout, H
gate, corner mapping and cell formatting; `tests/headless/test_drivetrain.gd` —
`grip_fraction` against the friction ellipse (and its zero-load guard). `tests/headless/test_perf_overlay.gd` — verifies the
profiler overlay toggles, samples, formats, and reads the loaded chunk count.
