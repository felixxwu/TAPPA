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
| [save-persistence.md](save-persistence.md) | `Save` autoload — player profile (owned cars, HP, inventory, rally completion) at `user://profile.json` |
| [rally-roster.md](rally-roster.md) | `RallyLibrary` — the curated rally list + pure functions (eligibility, target times, opponent field, showdown gating) |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — upgrade items + the effect-application pipeline (slotted parts, repair kit, tuning gates) |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) + the tuning-lift UI |
| [reward-system.md](reward-system.md) | `RewardSystem` — pure draw policy (tier clamp, per-event upgrade, per-rally car with anti-soft-lock) |
| [rally-session.md](rally-session.md) | `RallySession` autoload — event-flow orchestrator (3 events, standings, placement, rewards, wreck/DNF, no-retry) |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, wreck at 0 HP |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [terrain.md](terrain.md) | Infinite chunked Perlin terrain, collision, chunk loading |
| [track.md](track.md) | Rally corner shape library (Curve2D pacenotes) + catalog scene |
| [progress.md](progress.md) | `TrackProgress` — distance along the road centerline + off-track auto-reset |
| [stage.md](stage.md) | `StageManager` — per-stage countdown → run timer → completion + the car control lock |
| [start-line.md](start-line.md) | `StartLine` — the pre-event start-line scene (diegetic briefing panel + atmosphere presence cars) before the countdown |
| [trees.md](trees.md) | Billboard tree & bush sprites scattered around each track turn |
| [signs.md](signs.md) | Roadside A-frame signs — sector boards, turn arrows, start/finish gates (planner + builder; light knockable bodies, no damage) |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [camera.md](camera.md) | Chase camera follow behavior |
| [hud.md](hud.md) | On-screen speed/gear/rpm readout and mode buttons |
| [menus.md](menus.md) | Game-loop shell — HQ hub, podium, run-scene fielding (vertical slice; full diegetic UI deferred) |
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
| Roadside signs | `scripts/sign_layout.gd` (`SignLayout` planner), `scripts/sign_field.gd` (`SignField` builder) |
| Camera | `scripts/chase_camera.gd` |
| HUD | `scripts/hud.gd` |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Rally roster | `scripts/rally_library.gd` (`RallyLibrary` — rallies, eligibility, opponents, progress) |
| Upgrade catalogue | `scripts/upgrade_library.gd` (`UpgradeLibrary` — items, effects, slots, repair kit) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/hq.gd` (tuning lift) |
| Reward draws | `scripts/reward_system.gd` (`RewardSystem` — tier clamp, upgrade/car draws) |
| Rally session | `scripts/rally_session.gd` (`RallySession` autoload — event-flow orchestration) |
| Stage flow | `scripts/stage_manager.gd` (`StageManager`), `scripts/car.gd` (`controls_locked`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Game-loop shell | `hq.tscn`/`scripts/hq.gd`, `podium.tscn`/`scripts/podium.gd`, `scripts/world.gd` (session fielding) |
| Scene wiring | `scripts/world.gd`, `main.tscn` |
| Shaders | `shaders/ps1_models.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/billboard.gdshader` |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/perf_overlay.gd` |
| Perf benchmark | `benchmark/perf_benchmark.gd`, `run_benchmark.sh` |
| Tests | `tests/`, `run_tests.sh` |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
