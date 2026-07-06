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
| [rally-roster.md](rally-roster.md) | `RallyLibrary` — the curated rally list + pure functions (eligibility, QSS-based PAR times via `LapTimeModel`, opponent field, showdown gating) |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — upgrade items + the effect-application pipeline (slotted parts, repair kit, tuning gates) |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) + the tuning-lift UI |
| [engine-swap.md](engine-swap.md) | `EngineSwap` — free/unlimited/reversible engine exchange between owned cars (gated on 100% HP), engine mass + weight-distribution recompute, and the engine-detune tuning axis |
| [reward-system.md](reward-system.md) | `RewardSystem` — pure draw policy (tier clamp, per-event upgrade, per-rally car with anti-soft-lock) |
| [rally-session.md](rally-session.md) | `RallySession` autoload — event-flow orchestrator (3 events, standings, placement, rewards, wreck/DNF, no-retry) |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, wreck at 0 HP |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift; `EngineLibrary` (`scripts/engine_library.gd`) — the catalog of real engines cars reference by id |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [forced-induction.md](forced-induction.md) | Turbocharger (inertia-based shaft sim, boost, lag/anti-lag) + supercharger (audio-only) — engine property, stock or via `turbo_small`/`turbo_large` upgrades |
| [terrain.md](terrain.md) | Infinite chunked Perlin terrain, collision, chunk loading |
| [track.md](track.md) | Rally corner shape library (Curve2D pacenotes) + catalog scene |
| [progress.md](progress.md) | `TrackProgress` — distance along the road centerline + off-track auto-reset |
| [stage.md](stage.md) | `StageManager` — per-stage countdown → run timer → completion + the car control lock |
| [start-line.md](start-line.md) | `StartLine` — the pre-event start-line scene (diegetic briefing panel + atmosphere presence cars) before the countdown |
| [trees.md](trees.md) | Billboard tree & bush sprites scattered around each track turn |
| [signs.md](signs.md) | Roadside A-frame signs — sector boards, turn arrows, start/finish gates (planner + builder; light knockable bodies, no damage) |
| [spectators.md](spectators.md) | Roadside crowds (start/mid/end) — boids-style steering while upright, knocked into single-capsule ragdolls by the car; ghost to the car, not obstacles |
| [finish-arch.md](finish-arch.md) | `FinishArch` — procedural inflatable rally start/finish gates (Dakar-style portal + banners); finish sits at 100% progress so crossing it ends the stage |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [wheel-dust.md](wheel-dust.md) | `WheelParticles` — cheap gravel spray flung from the driven wheels under wheelspin (CPU pool + MultiMesh, ring-buffered, gated to the gravel) |
| [engine-smoke.md](engine-smoke.md) | `EngineSmoke` — grey smoke puffed from the bonnet on each damage misfire (own small CPU pool + MultiMesh, grows & fades) |
| [camera.md](camera.md) | Chase camera follow behavior |
| [hud.md](hud.md) | On-screen speed/gear/rpm readout and mode buttons |
| [menus.md](menus.md) | Game-loop shell — HQ hub, podium, run-scene fielding (vertical slice; full diegetic UI deferred) |
| [ui-design-system.md](ui-design-system.md) | `UITheme` + global theme — palette, pixel font, panel/button styling shared by every screen |
| [garage.md](garage.md) | Procedural rally-team service-park garage model + the multi-angle render harness |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [debug-tools.md](debug-tools.md) | Force-arrow visualization overlay |
| [benchmark.md](benchmark.md) | In-game benchmark mode — Settings → Benchmark: pre-run feature toggles, auto-driven long stage at 50 km/h, perf overlay + end-of-run stats breakdown |
| [controls.md](controls.md) | Full input map / key bindings |
| [testing.md](testing.md) | GUT test suite, render smoke test, `run_tests.sh` |

## File-to-feature quick map

| Feature | Primary source |
|---------|----------------|
| Car control | `scripts/car.gd`, `car.tscn` |
| Tire forces | `scripts/drivetrain.gd` |
| Engine/gearbox | `scripts/engine.gd`, `scripts/engine_library.gd` (`EngineLibrary` — engine catalog) |
| Engine sound | `scripts/engine_audio.gd`, `scripts/engine_audio_synth.gd` |
| Terrain | `scripts/terrain_manager.gd`, `scripts/terrain_chunk.gd`, `scripts/terrain_layer.gd` |
| Corner shapes | `scripts/corner_library.gd`, `scripts/corner_catalog.gd`, `corner_catalog.tscn` |
| Track generation | `scripts/track_generator.gd` |
| Trees & bushes | `scripts/tree_scatter.gd`, `scripts/billboard_field.gd`, `shaders/billboard.gdshader` |
| Roadside signs | `scripts/sign_layout.gd` (`SignLayout` planner), `scripts/sign_field.gd` (`SignField` builder) |
| Finish arch | `scripts/finish_arch.gd` (`FinishArch`), `tools/render_model.gd` |
| Camera | `scripts/chase_camera.gd`, `scripts/camera_manager.gd` (`CameraManager` — modes, cycle, persistence) |
| HUD | `scripts/hud.gd` |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Rally roster | `scripts/rally_library.gd` (`RallyLibrary` — rallies, eligibility, opponents, progress), `scripts/lap_time_model.gd` (`LapTimeModel` — QSS physics PAR) |
| Upgrade catalogue | `scripts/upgrade_library.gd` (`UpgradeLibrary` — items, effects, slots, repair kit) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/hq.gd` (tuning lift) |
| Engine swap / detune | `scripts/engine_swap.gd` (`EngineSwap` — current-engine resolution, mass/weight-front recompute, swap eligibility), `scripts/save_manager.gd` (`Save.swap_engines`/`set_engine_detune`), `scripts/car.gd` (`_apply_engine_swap`) |
| Reward draws | `scripts/reward_system.gd` (`RewardSystem` — tier clamp, upgrade/car draws) |
| Rally session | `scripts/rally_session.gd` (`RallySession` autoload — event-flow orchestration) |
| Stage flow | `scripts/stage_manager.gd` (`StageManager`), `scripts/car.gd` (`controls_locked`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Wreck menu | `scripts/wreck_screen.gd` (`WreckScreen` — crash → orbit camera + Return to HQ) |
| Settings page | `scripts/settings_menu.gd` (`SettingsMenu` — shared camera-angle + key-binding + mobile-control picker) |
| Key rebinding | `scripts/input_remap.gd` (`InputRemap` autoload — keyboard/controller rebind over the InputMap) |
| Pause menu | `scripts/pause_menu.gd` (`PauseMenu` — top-right freeze button → Resume / Settings) |
| Game-loop shell | `hq.tscn`/`scripts/hq.gd`, `podium.tscn`/`scripts/podium.gd`, `scripts/world.gd` (session fielding) |
| Garage model | `garage.tscn`/`scripts/garage.gd`, `tools/render_garage.gd`/`.sh` (multi-angle renders) |
| Scene wiring | `scripts/world.gd`, `main.tscn` |
| Shaders | `shaders/ps1_models.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/billboard.gdshader` |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/perf_overlay.gd` |
| Perf benchmark | `benchmark/perf_benchmark.gd`, `run_benchmark.sh` |
| In-game benchmark | `scripts/benchmark_mode.gd` (`Benchmark` autoload), `scripts/benchmark_runner.gd`, `scripts/benchmark_stats.gd`, `scripts/benchmark_results.gd` |
| Tests | `tests/`, `run_tests.sh` |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
