# Debug Tools

## Wheel force visualization

**Source:** `scripts/wheel_force_debug.gd` (`class_name WheelForceDebug extends
MeshInstance3D`). Created by `car.gd` in `_ready()`.

Draws per-wheel and aero force arrows as an immediate mesh. Toggled with **H**
(`toggle_debug_arrows` input action). The **H** toggle only responds in a **debug
build** (`OS.is_debug_build()` — editor / debug export); release exports such as
the web build ignore the key, so players can't summon the dev arrows. A config
that starts them visible (`debug_wheel_forces`) still works in any build.

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
- `drivetrain.readouts` — per-wheel `{normal, demand, applied}` data,
- `car.downforce_readouts` — `[global_point, force_vector]` pairs.

The same **H** toggle also reveals the HUD's speed / gear / rpm / **turbo boost**
readout (hidden by default — a dev diagnostic; see [hud.md](hud.md)). The boost line
reads the live boost pressure as a percentage of full boost (`hud.gd`'s pure
`boost_text` off `EngineSim.boost`), or `Boost N/A` on a naturally-aspirated engine
(`turbo_enabled` false) — see [forced-induction.md](forced-induction.md). A **seed**
line below it shows the current world seed (`Config.data.track_seed`, via the pure
`seed_text`) so a generated stage can be identified and reproduced. It also shows a transparent overlay of
the chassis collision hull (a chamfered octagon — see
[car-physics.md](car-physics.md) → "Hitbox shape"). It's a `MeshInstance3D` with an
`ArrayMesh`, parented under the car's `CollisionShape3D` so it inherits the shape's exact
transform; the prism is rebuilt from the `ConvexPolygonShape3D` points whenever they
change while visible (cars swap the hull at runtime via `apply_car`).

## Skip to finish (event cheat)

**Key: F** (`skip_to_finish` input action), handled in `world.gd._unhandled_input`.
Instantly completes the current rally event: teleports the car onto the finish
line and force-completes the stage, so the real completion → reward → progression
flow fires exactly as it would on a genuine finish (nothing is faked downstream).

Gated the same way as the H arrows — **debug builds only** (`OS.is_debug_build()`),
so release/web builds ignore the key. It also does nothing unless a rally event is
active (`RallySession.is_active()`) with a live `StageManager` that hasn't already
finished. Mechanism:

- `TrackProgress.jump_to_finish()` pins progress to 100% (the local-window search
  can't discover a far teleport on its own) and returns the finish pose.
- `Car.reset_to(pose)` places the car on the finish line.
- `StageManager.force_complete()` runs the shared `_complete()` path (freeze timer,
  re-lock car, show panel, emit `stage_completed`) regardless of phase.

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
| chunks loaded / spikes | terrain ring size; running spike count |

While active it enables `RenderingServer.viewport_set_measure_render_time` and,
on every frame over `SPIKE_MS` (28 ms), prints a `[PERF SPIKE]` line to stdout
with the full breakdown **plus whether a terrain chunk was integrated that
frame** (`TerrainManager.integrations_total` delta) — so terrain-correlated
hitches are obvious in a play-session log. The GPU timer reads 0 on backends
that don't support it (and always headless); the overlay labels that case.

## Standalone performance benchmark

**Source:** `benchmark/perf_benchmark.gd` + `benchmark/perf_benchmark.tscn`, run
via `./run_benchmark.sh`. **NOT part of the test suite** — an on-demand tool for
investigating choppiness, with no pass/fail gate (numbers are machine-dependent).
For the player-facing, in-game benchmark (Settings → Benchmark: feature toggles,
auto-driven run, results breakdown) see [benchmark.md](benchmark.md).

```bash
./run_benchmark.sh             # windowed: CPU chunk timings + GPU/render time
./run_benchmark.sh --headless  # CPU-only (no GPU timing), quick
```

Two halves, printed to stdout:
- **CPU** — `compute_chunk_data` (load-time precompute cost: noise + mesh arrays),
  `_spawn_chunk` (main-thread cache spawn at runtime), and a load-time boundary
  crossing diagnostic.
- **RENDER** — per-frame render cpu/gpu time for the real `main.tscn`, so a
  GPU-bound frame is distinguishable from a CPU one. Needs a real display;
  skipped under `--headless` (dummy renderer reports 0). GPU timestamp queries
  aren't supported on every backend (e.g. OpenGL/macOS may report 0) — then
  infer GPU cost from frame-total minus render-cpu.

## Tests

`tests/headless/test_debug_arrows.gd` — verifies the force-arrow overlay updates
from the force readouts. `tests/headless/test_perf_overlay.gd` — verifies the
profiler overlay toggles, samples, formats, and reads the loaded chunk count.
