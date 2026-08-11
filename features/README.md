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
| [cloud-save.md](cloud-save.md) | Optional Firebase account — sign-in, Firestore profile sync, conflict resolution |
| [global-leaderboards.md](global-leaderboards.md) | Optional per-stage world leaderboards — `Leaderboard`, `FirestoreCodec`, the standings interstitial's page 2, the one world-readable Firestore collection |
| [rally-roster.md](rally-roster.md) | `RallyLibrary` — the curated rally list + pure functions (eligibility, QSS-based PAR times via `LapTimeModel`, opponent field, the star-per-placement curve; reveal is geometric now — see map-exploration.md) |
| [rival-ghost.md](rival-ghost.md) | The rally leader shown on track while you drive — a kinematic ghost posed from `LapTimeModel` re-solved with a degraded driver-skill envelope, so it crosses the line exactly when the standings say it did |
| [star-economy.md](star-economy.md) | Stars as the one currency — the persisted `stars_earned`/`stars_spent` ledger, what pays them, why gating counts completions instead, buying a car at the present box + the dead-end rescue, and the podium's stars beat |
| [weather.md](weather.md) | Per-event weather (dry / rain / sandstorm) — the `WeatherLibrary` table that is the single source of truth for every condition, `RallyLibrary.event_weather`, the `GameConfig` blocks it names, and the `RallySession.apply_event_config` funnel that seats it |
| [prize-rallies.md](prize-rallies.md) | Rallies that award a CAR or a PART — `prize_car` authored, part prizes derived from `UpgradeLibrary`; the prize tops its own band; first-win-only claiming. Cars are no longer bought or drawn |
| [map-exploration.md](map-exploration.md) | The world map's fog of war — HQ starts lit, every completed rally lights a circle around its own pin, `map_pos` IS the progression graph. Replaced the `reveal_after` / `requires_completions` wave counters |
| [regions.md](regions.md) | `RegionLibrary` — region catalogue (look overrides per region), the `region` rally tag, driven-world theming, per-corner waterlines. Regions gate NOTHING any more — look + `water_level` only |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — upgrade items + the effect-application pipeline (slotted parts, consumables, tuning gates, the per-car prerequisite + won-event (`unlocked_by_rally`) gates, and the two flavours of `max_potential_meta`) |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) + the tuning-lift UI |
| [aero-parts.md](aero-parts.md) | Spoiler/splitter meshes tagged `_aero` in a car glb — hidden by default, revealed when the aero kit is enabled |
| [wheel-customization.md](wheel-customization.md) | Cosmetic wheel swap — any car's wheels on any owned car (free, ungated, texture-only); the solo car-park wheel view |
| [engine-swap.md](engine-swap.md) | `EngineSwap` — free/unlimited/reversible engine exchange between owned cars (gated on 100% HP), engine mass + weight-distribution recompute, and the engine-detune power knob (a slider in the upgrades menu) |
| [reward-system.md](reward-system.md) | `RewardSystem` — pure draw policy (flat event-gated per-event upgrade pool that may award nothing, the mystery-box roll, the car pick/pricing with its tier clamp + anti-soft-lock) |
| [rally-session.md](rally-session.md) | `RallySession` autoload — event-flow orchestrator (3 events, standings, placement, rewards, wreck/DNF, no-retry) |
| [rally-challenge.md](rally-challenge.md) | Daily/Weekly/Monthly seeded Rally Challenge — `ChallengeLibrary` (period/seed/ceiling), `ChallengeSession` autoload (resume persistence, per-stage flow, placement reward), the HQ entry-point screen |
| [event-replay.md](event-replay.md) | `ReplayRecorder`/`ReplayCamera` — cinematic transform-playback replay of the just-driven event behind the standings overlay |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, wreck at 0 HP |
| [opponent-wrecks.md](opponent-wrecks.md) | Rival crash-outs — the rare/capped wreck decision (`RallyLibrary`) + the roadside staging (frozen car + crowd + smoke) in `world.gd` |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift; `EngineLibrary` (`scripts/engine_library.gd`) — the catalog of real engines cars reference by id |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [music.md](music.md) | Interactive looping background music — `MusicSchedule` timing math, `MusicLibrary` catalogue, `MusicDirector` autoload (single-player polyphonic double-buffer), Music bus |
| [forced-induction.md](forced-induction.md) | Turbocharger (inertia-based shaft sim, boost, lag/anti-lag) + supercharger (stateless rpm-linear belt drive, rpm-scaled drag) — engine property, stock or via the shared-slot `turbo_small` / `turbo_large` / `supercharger` upgrade ladder |
| [nitrous.md](nitrous.md) | Held-button torque multiplier with a per-stage tank — the hidden fifth upgrade slot (auto-fitted, excluded from power-to-weight), `EngineSim` delivery/drain, the violet HUD gauge, LEFT-Shift / joypad-X / mobile NOS input, and the all-hiss synth layer |
| [loading.md](loading.md) | Stage-load pipeline: `_stage` timing, cached vs live generation, the `load_finished` hook |
| [terrain.md](terrain.md) | Infinite chunked Perlin terrain, collision, chunk loading |
| [lakes.md](lakes.md) | Per-event water level floods natural basins; the track DFS routes the road around water; soft-hazard drag; `TrackGenParams` shape contract; dev seed-lab |
| [track.md](track.md) | Rally corner shape library (Curve2D pacenotes) + catalog scene |
| [progress.md](progress.md) | `TrackProgress` — distance along the road centerline + off-track auto-reset |
| [corner-cutting.md](corner-cutting.md) | Corner-cutting time penalty — arc-gained-vs-driven cut detection in `TrackProgress`, snapshot at the finish, live HUD flash + finish-panel breakdown |
| [stage.md](stage.md) | `StageManager` — per-stage countdown → run timer → completion + the car control lock |
| [start-line.md](start-line.md) | `StartLine` — the pre-event start-line scene (diegetic briefing panel + atmosphere presence cars) before the countdown |
| [trees.md](trees.md) | Billboard tree & bush sprites scattered around each track turn |
| [signs.md](signs.md) | Roadside A-frame signs — sector boards, turn arrows, start/finish gates (planner + builder; light knockable bodies, no damage) |
| [spectators.md](spectators.md) | Roadside crowds (start/mid/end) — boids-style steering while upright, knocked into single-capsule ragdolls by the car; ghost to the car, not obstacles |
| [finish-arch.md](finish-arch.md) | `FinishArch` — procedural inflatable rally start/finish gates (Dakar-style portal + banners); finish sits at 100% progress so crossing it ends the stage |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [wheel-dust.md](wheel-dust.md) | `WheelParticles` — cheap surface debris flung from the driven wheels under wheelspin (one CPU pool + MultiMesh, ring-buffered; per-particle colour/size/roll picks gravel clods, grass blades, or nothing on tarmac) |
| [engine-smoke.md](engine-smoke.md) | `EngineSmoke` — grey smoke puffed from the bonnet on each damage misfire (own small CPU pool + MultiMesh, grows & fades) |
| [camera.md](camera.md) | Chase camera follow behavior |
| [hud.md](hud.md) | On-screen speed/gear/rpm readout and mode buttons |
| [menus.md](menus.md) | Game-loop shell — HQ hub, podium, run-scene fielding (vertical slice; full diegetic UI deferred) |
| [world-panel.md](world-panel.md) | `WorldPanel` — menus hosted in the 3D world, welded off-square to an anchor (6 HQ screens, off by default) |
| [ui-design-system.md](ui-design-system.md) | `UITheme` + global theme — palette, pixel font, panel/button styling shared by every screen |
| [garage.md](garage.md) | Procedural rally-team service-park garage model + the multi-angle render harness |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [asset-pipeline.md](asset-pipeline.md) | Source art → PCK: texture import settings, the live/orphan car-texture trap, export exclude filters, PCK sizing |
| [debug-tools.md](debug-tools.md) | Force-arrow visualization overlay |
| [benchmark.md](benchmark.md) | In-game benchmark mode — Settings → Benchmark: pre-run feature toggles, auto-driven long stage at 50 km/h, perf overlay + end-of-run stats breakdown |
| [controls.md](controls.md) | Full input map / key bindings |
| [testing.md](testing.md) | GUT test suite, render smoke test, `run_tests.sh` |
| [release-pipeline.md](release-pipeline.md) | The `Release` workflow — cache gate, itch/Play/Pages/Firestore jobs, the `install-butler` composite action, secrets |

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
| Track turn cache | `scripts/track_cache.gd` (`TrackCache`), `data/track_cache.json`, `tools/generate_track_cache.gd`, `tools/verify_track_cache.gd`, `cache_tracks.sh` |
| Opponent field cache | `scripts/opponent_cache.gd` (`OpponentCache`), `data/opponent_cache.json`, `tools/generate_opponent_cache.gd`, `tools/verify_opponent_cache.gd`, `cache_opponents.sh`, `cache_all.sh` |
| Eligibility report (rally x car authoring check) | `tools/report_eligibility.gd`/`.tscn`, `report_eligibility.sh` — see [rally-roster.md](rally-roster.md) |
| Career simulation (progression pacing / soft-lock check) | `tools/sim_career.gd`/`.tscn`, `sim_career.sh`, `tests/headless/test_sim_career.gd` — see [rally-roster.md](rally-roster.md) |
| Cache freshness hook | `.githooks/pre-commit` (regenerates + stages stale `data/*.json` lockfiles on commit), `install_hooks.sh` (one-time `core.hooksPath` setup) — see [track.md](track.md) → *Turn cache* |
| Lakes / water | `scripts/lake_field.gd` (`LakeField`), `scripts/track_gen_params.gd` (`TrackGenParams`), `scripts/terrain_noise.gd` (`TerrainNoise`), `shaders/water.gdshader` |
| Track shape params | `scripts/track_gen_params.gd` (`TrackGenParams` — the required shape contract for `TrackGenerator.generate`) |
| Trees & bushes | `scripts/tree_scatter.gd`, `scripts/billboard_field.gd`, `shaders/billboard.gdshader` |
| Roadside signs | `scripts/sign_layout.gd` (`SignLayout` planner), `scripts/sign_field.gd` (`SignField` builder) |
| Finish arch | `scripts/finish_arch.gd` (`FinishArch`), `tools/render_model.gd` |
| Camera | `scripts/chase_camera.gd`, `scripts/camera_manager.gd` (`CameraManager` — modes, cycle, persistence) |
| HUD | `scripts/hud.gd` |
| Pacenote strip | `scripts/pacenotes.gd` (`Pacenotes` — note list, arrow keys, progress fractions), `scripts/hud.gd` (the strip), `scripts/stage_manager.gd` (advance) |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Rally roster | `scripts/rally_library.gd` (`RallyLibrary` — rallies, eligibility, opponents, progress), `scripts/lap_time_model.gd` (`LapTimeModel` — QSS physics PAR) |
| Regions | `scripts/region_library.gd` (`RegionLibrary` — region catalogue, look overrides, sequential unlock) |
| Upgrade catalogue | `scripts/upgrade_library.gd` (`UpgradeLibrary` — items, effects, slots, consumables) |
| Upgrades-page stat bars | `scripts/stat_bar.gd` (`StatBar` — segmented bar widget), `scripts/car_stat_bounds.gd` (`CarStatBounds` — cached roster-wide min/max the bars scale against), `scripts/upgrades_simple.gd` (`_stat_rows`) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/hq.gd` (tuning lift) |
| Cosmetic wheels | `scripts/wheel_style.gd` (`WheelStyle` — style resolution), `scripts/car_library.gd` (`wheel_catalogue`), `scripts/save_manager.gd` (`Save.set_wheels`), `scripts/car.gd` (`reskin_wheels`), `scripts/hq.gd` (`CarparkMode.WHEELS`) |
| Engine swap / detune | `scripts/engine_swap.gd` (`EngineSwap` — current-engine resolution, mass/weight-front recompute, swap eligibility), `scripts/save_manager.gd` (`Save.swap_engines`/`set_engine_detune`), `scripts/car.gd` (`_apply_engine_swap`) |
| Reward draws | `scripts/reward_system.gd` (`RewardSystem` — upgrade/car draws; the tier clamp is car-draw-only) |
| Rally session | `scripts/rally_session.gd` (`RallySession` autoload — event-flow orchestration) |
| Event replay | `scripts/replay_recorder.gd` (`ReplayRecorder`), `scripts/replay_camera.gd` (`ReplayCamera`), `scripts/car.gd` (`replay_playback`) |
| Stage flow | `scripts/stage_manager.gd` (`StageManager`), `scripts/car.gd` (`controls_locked`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Opponent wrecks | `scripts/rally_library.gd` (`generate_opponent_field` / `event_wreck`), `scripts/world.gd` (`_spawn_opponent_wreck`) |
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
| Release / CI | `.github/workflows/deploy.yml`, `.github/actions/install-butler/action.yml`, `build_web.sh`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh` |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
