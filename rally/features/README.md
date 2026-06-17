# Rally — Feature Documentation

This folder is the **agent-oriented overview** of the `rally` project. Each file
documents one feature area: what it does, where it lives, how the pieces fit
together, and which config knobs control it. Read this folder first to get
oriented before diving into source.

`rally` is a small PS1-aesthetic arcade driving sandbox built in **Godot 4.6**
(GL Compatibility renderer). You drive a single car over procedurally generated
rolling terrain. There is no scoring or objective — it's a physics/feel sandbox.

## How to use this folder

- Skim this README for the big picture and file map.
- Open the feature file that matches what you're working on.
- Every gameplay/look value lives in `config/game_config.tres` (a `GameConfig`
  resource). Scripts/scenes only hold fallback defaults. See
  [configuration.md](configuration.md).

## Feature index

| File | Covers |
|------|--------|
| [architecture.md](architecture.md) | Project layout, scene tree, autoloads, data flow |
| [configuration.md](configuration.md) | `GameConfig` resource — every tunable, the `Config` autoload |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [terrain.md](terrain.md) | Infinite chunked Perlin terrain, collision, chunk loading |
| [track.md](track.md) | Rally corner shape library (Curve2D pacenotes) + catalog scene |
| [trees.md](trees.md) | Billboard tree & bush sprites scattered around each track turn |
| [camera.md](camera.md) | Chase camera follow behavior |
| [hud.md](hud.md) | On-screen speed/gear/rpm readout and mode buttons |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [debug-tools.md](debug-tools.md) | Force-arrow visualization overlay |
| [controls.md](controls.md) | Full input map / key bindings |
| [testing.md](testing.md) | GUT test suite, render smoke test, `run_tests.sh` |

## File-to-feature quick map

| Feature | Primary source |
|---------|----------------|
| Car control | `scripts/car.gd`, `car.tscn` |
| Tire forces | `scripts/drivetrain.gd` |
| Engine/gearbox | `scripts/engine.gd` |
| Engine sound | `scripts/engine_audio.gd`, `scripts/engine_audio_synth.gd` |
| Terrain | `scripts/terrain_manager.gd`, `scripts/terrain_chunk.gd`, `scripts/terrain_layer.gd` |
| Corner shapes | `scripts/corner_library.gd`, `scripts/corner_catalog.gd`, `corner_catalog.tscn` |
| Track generation | `scripts/track_generator.gd` |
| Trees & bushes | `scripts/tree_scatter.gd`, `scripts/billboard_field.gd`, `shaders/billboard.gdshader` |
| Camera | `scripts/chase_camera.gd` |
| HUD | `scripts/hud.gd` |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Scene wiring | `scripts/world.gd`, `main.tscn` |
| Shaders | `shaders/ps1_models.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/billboard.gdshader` |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/perf_overlay.gd` |
| Perf benchmark | `benchmark/perf_benchmark.gd`, `run_benchmark.sh` |
| Tests | `tests/`, `run_tests.sh` |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
