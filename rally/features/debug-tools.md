# Debug Tools

## Wheel force visualization

**Source:** `scripts/wheel_force_debug.gd` (`class_name WheelForceDebug extends
MeshInstance3D`). Created by `car.gd` in `_ready()`.

Draws per-wheel and aero force arrows as an immediate mesh. Toggled with **H**
(`toggle_debug_arrows` input action).

| Color | Force |
|-------|-------|
| Green | suspension normal force |
| Red | tire friction force (applied by drivetrain) |
| Blue | aero downforce (at axle midpoints) |

`_physics_process(delta)` rebuilds the mesh each frame from:
- `drivetrain.readouts` — per-wheel `{normal, demand, applied}` data,
- `car.downforce_readouts` — `[global_point, force_vector]` pairs.

The same **H** toggle also shows a transparent overlay of the chassis collision
box. It's a `MeshInstance3D` with a `BoxMesh`, parented under the car's
`CollisionShape3D` so it inherits the shape's exact transform; its size is synced
from the `BoxShape3D` each frame while visible (cars can swap the box at runtime).

## Frame profiler overlay

**Source:** `scripts/perf_overlay.gd` (`class_name PerfOverlay extends
CanvasLayer`). Created by `world.gd` in `_ready()` (like the wheel-force
overlay), passing the `Floor` terrain manager for correlation. Toggled with
**P** (`toggle_perf_overlay`); hidden and idle by default.

Diagnoses choppiness by separating the suspects per frame:

| Line | Tells you |
|------|-----------|
| frame current / avg / **MAX** | spike vs steady (max ≫ avg ⇒ intermittent stutter) |
| cpu process / physics | main-thread script + collision/physics cost |
| render **cpu** vs **gpu** | CPU-bound vs GPU-bound (fill rate, post-process shader) |
| draws / objects / prims | scene complexity / draw-call pressure |
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

```bash
./run_benchmark.sh             # windowed: CPU chunk timings + GPU/render time
./run_benchmark.sh --headless  # CPU-only (no GPU timing), quick
```

Two halves, printed to stdout:
- **CPU** — `compute_chunk_data` (worker-thread noise + mesh arrays),
  `_spawn_chunk` (main-thread ArrayMesh + `HeightMapShape3D` build — the
  per-frame hitch suspect), and a simulated boundary crossing.
- **RENDER** — per-frame render cpu/gpu time for the real `main.tscn`, so a
  GPU-bound frame is distinguishable from a CPU one. Needs a real display;
  skipped under `--headless` (dummy renderer reports 0). GPU timestamp queries
  aren't supported on every backend (e.g. OpenGL/macOS may report 0) — then
  infer GPU cost from frame-total minus render-cpu.

## Tests

`tests/headless/test_debug_arrows.gd` — verifies the force-arrow overlay updates
from the force readouts. `tests/headless/test_perf_overlay.gd` — verifies the
profiler overlay toggles, samples, formats, and reads the loaded chunk count.
