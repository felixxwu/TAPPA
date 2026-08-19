# Rally — Feature Documentation

This folder is the **agent-oriented overview** of the `rally` project. Each file
documents one feature area: what it does, where it lives, how the pieces fit
together, and which config knobs control it. Read this folder first to get
oriented before diving into source.

`rally` is a small PS1-aesthetic rally career game built in **Godot 4.6**
(GL Compatibility renderer). You drive a garage of cars through a curated roster
of rallies on one world map, earning stars for placement, buying/upgrading cars
with them, and working toward the special-event finale.

## How to use this folder

- Skim this README for the big picture and file map.
- Open the feature file that matches what you're working on.
- Every gameplay/look value lives in `config/game_config.tres` (a `GameConfig`
  resource). Scripts/scenes only hold fallback defaults. See
  [configuration.md](configuration.md).
- **Every area doc opens with a `**Source:**` line and a `**Tests:**` line.** The
  first says which scripts own the behaviour; the second names the
  `tests/headless/test_*.gd` files that cover it, so you can tell what your change
  will break without searching for it. Keep both current when you change an area,
  and give any new doc both plus an entry in the index table below — all three are
  enforced by `tests/headless/test_features_docs.gd`.
- **The scripts point back.** Source scripts carry a `# Docs:` / `# Tests:`
  breadcrumb in their header naming the area doc(s) and covering test file(s) —
  update the doc and extend the tests **in the same change** as the code; that
  pair of lines is the reminder at the point of use. When you add a script or
  re-home one, give it the breadcrumb and keep it accurate.
  **The `# Tests:` line names at most three PRIMARY test files, not every test that
  touches the script** — it ends with the `grep` that finds the rest. A longer list
  stops being a pointer and becomes a haystack the reader skips, which is exactly
  how a change ships against an assertion nobody read. Both halves are enforced by
  `tests/headless/test_script_breadcrumbs.gd`: named docs and tests must exist, and
  the test list must stay within the cap.
- **Before you change behaviour, find the assertion that pins it.** The breadcrumb
  tells you where to look; the thing to look FOR is an existing test that encodes
  the behaviour you are about to change. Two failure shapes, both observed: the test
  goes red and you hand back a broken suite, or — worse — it keeps passing for an
  incidental reason and quietly becomes order-dependent. Renegotiating such an
  assertion (updating it, and saying so) is part of the change, not follow-up work.

## Feature index

| File | Covers |
|------|--------|
| [architecture.md](architecture.md) | Project layout, scene tree, autoloads, data flow |
| [configuration.md](configuration.md) | `GameConfig` resource — every tunable, the `Config` autoload |
| [save-persistence.md](save-persistence.md) | `Save` autoload — player profile (owned cars, HP, inventory, rally completion) at `user://profile.json` |
| [cloud-save.md](cloud-save.md) | Optional Firebase account — sign-in, Firestore profile sync, conflict resolution |
| [global-leaderboards.md](global-leaderboards.md) | Optional per-stage world leaderboards — `Leaderboard`, `FirestoreCodec`, the standings interstitial's page 2, the one world-readable Firestore collection |
| [rally-roster.md](rally-roster.md) | `RallyLibrary` — the curated rally list + pure functions (eligibility, QSS-based PAR times via `LapTimeModel`, opponent field, the star-per-placement curve; reveal is geometric now — see map-exploration.md) |
| [car-performance.md](car-performance.md) | `CarPerformance` — a car's speed as ONE number (Forza-style, higher = faster), derived from a simulated lap of the fixed `BenchmarkTrack` rather than a formula over stats; the `benchmark_*` knobs, the reference-car anchor, and the downforce / drive-mode solver enrichment behind it |
| [adaptive-difficulty.md](adaptive-difficulty.md) | The rival field pitches itself at the player — it eases after stages they don't win and tightens when they keep taking P1, by handing the rating matcher an OFFSET rating so rivals turn up in quicker or slower machinery (never by making them drive impossibly) |
| [rival-ghost.md](rival-ghost.md) | The rally leader shown on track while you drive — a kinematic ghost posed from `LapTimeModel` re-solved with a degraded driver-skill envelope, so it crosses the line exactly when the standings say it did |
| [star-economy.md](star-economy.md) | Stars as the one currency — the persisted `stars_earned`/`stars_spent` ledger, what pays them, why gating counts completions instead, buying a car at the present box + the dead-end rescue, and the podium's stars beat |
| [weather.md](weather.md) | Per-event weather (dry / rain / sandstorm / fog / storm / snowfall / night) — the `WeatherLibrary` table that is the single source of truth for every condition, `RallyLibrary.event_weather`, the `GameConfig` blocks it names, the `RallySession.apply_event_config` funnel that seats it, and the fake headlight cone night re-lights the world with (authored on five stages, one per region) |
| [prize-rallies.md](prize-rallies.md) | Rallies that award a CAR or a PART — `prize_car` authored, part prizes derived from `UpgradeLibrary`; the prize tops its own band; first-win-only claiming. Cars are no longer bought or drawn |
| [map-exploration.md](map-exploration.md) | The world map's fog of war — HQ starts lit, every completed rally lights a circle around its own pin, `map_pos` IS the progression graph. Replaced the `reveal_after` / `requires_completions` wave counters |
| [snow-region.md](snow-region.md) | The Alps — the map's NE corner. The first region to influence HANDLING as well as look: per-surface grip overrides, deep snow you sink into and bog down in, frozen lakes you drive on, snowfall, and the six rallies (two carrying re-sited part unlocks) |
| [regions.md](regions.md) | `RegionLibrary` — region catalogue (look overrides per region), the `region` rally tag, driven-world theming, per-corner waterlines, the unconditional sky re-seed that stops one region's sky leaking into the next stage. Regions gate NOTHING any more — look + `water_level` only |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — upgrade items + the effect-application pipeline (slotted parts, the `consumable` flag no shipped item claims any more, tuning gates, the per-car prerequisite + won-event (`unlocked_by_rally`) gates, and the two flavours of `max_potential_meta`) |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) + the tuning-lift UI |
| [aero-parts.md](aero-parts.md) | Spoiler/splitter meshes tagged `_aero` in a car glb — hidden by default, revealed when the aero kit is enabled |
| [wheel-customization.md](wheel-customization.md) | Cosmetic wheel swap — any car's wheels on any owned car (free, ungated, texture-only); the solo car-park wheel view |
| [engine-swap.md](engine-swap.md) | `EngineSwap` — free/unlimited/reversible engine exchange between owned cars — the only gate is the rally that unlocks the capability; neither a token nor car health blocks a swap — engine mass + weight-distribution recompute, and the engine-detune power knob (a slider in the upgrades menu) |
| [reward-system.md](reward-system.md) | `RewardSystem` — pure draw policy (the car pick/pricing with its tier clamp, the prize-rally part unlock). There is no random per-event upgrade draw any more |
| [rally-session.md](rally-session.md) | `RallySession` autoload — event-flow orchestrator (3 events, standings, placement, rewards, rival DNFs, no-retry) |
| [rally-challenge.md](rally-challenge.md) | Daily/Weekly/Monthly seeded Rally Challenge — `ChallengeLibrary` (period/seed/ceiling), `ChallengeSession` autoload (resume persistence, per-stage flow, placement reward), the HQ entry-point screen |
| [event-replay.md](event-replay.md) | `ReplayRecorder`/`ReplayCamera` — cinematic transform-playback replay of the just-driven event behind the standings overlay |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, capped misfire + rev cap at 0 HP (never a wreck) |
| [opponent-wrecks.md](opponent-wrecks.md) | Rival crash-outs — the rare/capped wreck decision (`RallyLibrary`) + the roadside staging (frozen car + crowd + smoke) in `world.gd` |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift; `EngineLibrary` (`scripts/engine_library.gd`) — the catalog of real engines cars reference by id |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [sfx.md](sfx.md) | **One-shot sound effects — `Audio` autoload (`scripts/audio.gd`), `Audio.play_beep(...)`, the SFX bus. Read this before playing ANY sound; never hand-roll an `AudioStreamGenerator` at a call site.** |
| [music.md](music.md) | Interactive looping background music — `MusicSchedule` timing math, `MusicLibrary` catalogue, `MusicDirector` autoload (single-player polyphonic double-buffer), Music bus |
| [multiplayer-lobby.md](multiplayer-lobby.md) | Round-based drop-in multiplayer — the wall-clock round derivation, the seeded stage + loaner car, the Firestore progress collection, and the extrapolated field |
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
| [rocks.md](rocks.md) | Roadside boulders — low-poly collidable MESHES (not billboards), density set per region |
| [signs.md](signs.md) | Roadside A-frame signs — sector boards, turn arrows, start/finish gates (planner + builder; light knockable bodies, no damage) |
| [barriers.md](barriers.md) | Solid crash barriers on the outside of sharp corners — 2 m modules stitched into a run; armco guardrail on gravel, concrete jersey rail on tarmac (`BarrierSection` / `BarrierLayout` / `BarrierField`) |
| [spectators.md](spectators.md) | Roadside crowds (start/mid/end) — boids-style steering while upright, knocked into single-capsule ragdolls by the car; ghost to the car, not obstacles |
| [finish-arch.md](finish-arch.md) | `FinishArch` — procedural inflatable rally start/finish gates (Dakar-style portal + banners); finish sits at 100% progress so crossing it ends the stage |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [wheel-dust.md](wheel-dust.md) | `WheelParticles` — cheap surface debris flung from the driven wheels under wheelspin (one CPU pool + MultiMesh, ring-buffered; per-particle colour/size/roll picks gravel clods, grass blades, or nothing on tarmac) |
| [engine-smoke.md](engine-smoke.md) | `EngineSmoke` — grey smoke puffed from the bonnet on each damage misfire (own small CPU pool + MultiMesh, grows & fades) |
| [exhaust-flames.md](exhaust-flames.md) | `ExhaustFlames` — backfire flame from each exhaust pipe on a rev-limiter bang and while nitrous delivers; plus the exhaust lab dev scene for positioning the pipes |
| [camera.md](camera.md) | Chase camera follow behavior |
| [hud.md](hud.md) | On-screen speed/gear/rpm readout, mode buttons, and the permanent live standings readout (`LiveStandings`) |
| [menus.md](menus.md) | Game-loop shell — HQ hub, podium, run-scene fielding, the pause menu, modals (vertical slice; full diegetic UI deferred) |
| [hq.md](hq.md) | **The HQ garage hub** (`hq.gd`, ~4,700 lines) — stations and their input branches, the two hubs and the boot redirect, the rally-detail panel, the map table, the upgrades/tune lift, the Android boot notice |
| [menu-navigation.md](menu-navigation.md) | **Keyboard / gamepad menu navigation — the `MenuNav` framework.** Focus, WASD/arrow/D-pad movement, back routing, remembering the selected row, the diegetic-HQ spatial regime. Read this before adding or changing ANY menu: every menu must work on keyboard and controller, and that is a CLAUDE.md rule with a required nav test |
| [settings.md](settings.md) | **Adding or changing a persisted setting** — the one-module-per-setting apply-owner pattern (`*_setting.gd`), boot re-application, the shared `SettingsMenu` used by both the title screen and the pause menu, and the developer-only pages |
| [modals.md](modals.md) | **Modals and confirms** — `ConfirmPopup`, the one-modal-at-a-time `MODAL_GROUP`, the scrolled-body / pinned-exit modal page shape, `MenuPage.open_modal`, and `MenuNav.input_blocked` |
| [overworld.md](overworld.md) | The Overworld HQ — a life-size drivable world map as a SECOND hub (`overworld.tscn` / `Overworld`), behind `GameConfig.overworld_enabled` (ships off). Coordinate mapping, the coastline vs the fog frontier, the on-disk chunk cache + first-launch precompute, per-position region look, streamed foliage, the zone seam, the wayfinding stack (compass, camera-up minimap, full map, and the `OverworldRoute` sat-nav that plans a road path to a picked destination), and the cheap test path |
| [world-panel.md](world-panel.md) | `WorldPanel` — menus hosted in the 3D world, welded off-square to an anchor (4 HQ screens; shipped ON) |
| [ui-design-system.md](ui-design-system.md) | `UITheme` + global theme — palette, pixel font, panel/button styling shared by every screen |
| [garage.md](garage.md) | Procedural rally-team service-park garage model + the multi-angle render harness |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [asset-pipeline.md](asset-pipeline.md) | Source art → PCK: texture import settings, the live/orphan car-texture trap, the 1024×512 sky-panorama house format, export exclude filters, PCK sizing |
| [debug-tools.md](debug-tools.md) | Force-arrow visualization overlay |
| [benchmark.md](benchmark.md) | In-game benchmark mode — Settings → Benchmark: pre-run feature toggles, auto-driven long stage at 50 km/h, perf overlay + end-of-run stats breakdown |
| [controls.md](controls.md) | Full input map / key bindings |
| [testing.md](testing.md) | GUT test suite, render smoke test, `run_tests.sh` |
| [release-pipeline.md](release-pipeline.md) | The `Release` workflow — cache gate, itch/Play/Pages/Firestore jobs, the `install-butler` composite action, secrets |
| [update-check.md](update-check.md) | Launch-time "a newer build is out" prompt for every NATIVE build (Play included — a testing track doesn't self-update) — `UpdateCheck`, the Pages-published `version.json`, per-store destinations, why web is excluded |

## File-to-feature quick map

| Feature | Primary source |
|---------|----------------|
| Car control | `scripts/car.gd`, `car.tscn` |
| Tire forces | `scripts/drivetrain.gd` |
| Engine/gearbox | `scripts/engine.gd`, `scripts/engine_library.gd` (`EngineLibrary` — engine catalog) |
| Engine sound | `scripts/engine_audio.gd`, `scripts/engine_audio_synth.gd` |
| Sound effects (any "play a sound when X" task) | `scripts/audio.gd` (`Audio` autoload — `play_beep`), see `features/sfx.md` |
| Terrain | `scripts/terrain_manager.gd`, `scripts/terrain_chunk.gd`, `scripts/terrain_layer.gd` |
| Corner shapes | `scripts/corner_library.gd`, `scripts/corner_catalog.gd`, `corner_catalog.tscn` |
| Exhaust flames | `scripts/exhaust_flames.gd`, `scripts/exhaust_lab.gd`, `exhaust_lab.tscn` |
| Track generation | `scripts/track_generator.gd` |
| Track turn cache | `scripts/track_cache.gd` (`TrackCache`), `data/track_cache.json`, `tools/generate_track_cache.gd`, `tools/verify_track_cache.gd`, `cache_tracks.sh` |
| Eligibility report (rally x car authoring check) | `tools/report_eligibility.gd`/`.tscn`, `report_eligibility.sh` — see [rally-roster.md](rally-roster.md) |
| Career simulation (progression pacing / soft-lock check) | `tools/sim_career.gd`/`.tscn`, `sim_career.sh`, `tests/headless/test_sim_career.gd` — see [rally-roster.md](rally-roster.md) |
| Benchmark fidelity calibration (C1 — does the rating rank cars like real stages?) | `tools/calibrate_benchmark.gd`/`.tscn`, `calibrate_benchmark.sh` — see [car-performance.md](car-performance.md) → *Calibration tooling* |
| Pace-floor calibration (C2 — what `PACE_MIN_FLOOR` can and cannot be derived from) | `tools/calibrate_pace_floor.gd`/`.tscn`, `calibrate_pace_floor.sh` — see [car-performance.md](car-performance.md) → *Calibration tooling* |
| Cache freshness hook | `.githooks/pre-commit` (regenerates + stages stale `data/*.json` lockfiles on commit), `install_hooks.sh` (one-time `core.hooksPath` setup) — see [track.md](track.md) → *Turn cache* |
| Lakes / water | `scripts/lake_field.gd` (`LakeField`), `scripts/track_gen_params.gd` (`TrackGenParams`), `scripts/terrain_noise.gd` (`TerrainNoise`), `shaders/water.gdshader` |
| Track shape params | `scripts/track_gen_params.gd` (`TrackGenParams` — the required shape contract for `TrackGenerator.generate`) |
| Trees & bushes | `scripts/tree_scatter.gd`, `scripts/billboard_field.gd`, `shaders/billboard_opaque.gdshader` |
| Roadside signs | `scripts/sign_layout.gd` (`SignLayout` planner), `scripts/sign_field.gd` (`SignField` builder) |
| Finish arch | `scripts/finish_arch.gd` (`FinishArch`), `tools/render_model.gd` |
| Corner barriers | `scripts/barrier_layout.gd` (`BarrierLayout` planner), `scripts/barrier_field.gd` (`BarrierField` builder), `scripts/barrier_section.gd` (`BarrierSection` module), `tools/render_barriers.gd`/`.sh` |
| Camera | `scripts/chase_camera.gd`, `scripts/camera_manager.gd` (`CameraManager` — modes, cycle, persistence) |
| HUD | `scripts/hud.gd` |
| Pacenote strip | `scripts/pacenotes.gd` (`Pacenotes` — note list, arrow keys, progress fractions), `scripts/hud.gd` (the strip), `scripts/stage_manager.gd` (advance) |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Rally roster | `scripts/rally_library.gd` (`RallyLibrary` — rallies, eligibility, opponents, progress), `scripts/lap_time_model.gd` (`LapTimeModel` — QSS physics PAR) |
| Car performance rating | `scripts/car_performance.gd` (`CarPerformance` — rating, benchmark time, `merged_meta`), `scripts/benchmark_track.gd` (`BenchmarkTrack` — the fixed test track) |
| Regions | `scripts/region_library.gd` (`RegionLibrary` — region catalogue, look overrides, sequential unlock) |
| Upgrade catalogue | `scripts/upgrade_library.gd` (`UpgradeLibrary` — items, effects, slots) |
| Upgrades page | `scripts/upgrades_grid.gd` (`UpgradesGrid` — the slot-tile grid every host mounts), `scripts/upgrade_slot_popup.gd` (`UpgradeSlotPopup` — the per-slot option list / detune slider), `scripts/upgrade_options.gd` (`UpgradeOptions` — the pure option model), `scripts/upgrade_icons.gd` (`UpgradeIcons` — the per-slot SVG icons) |
| Roster-wide stat scale | `scripts/car_stat_bounds.gd` (`CarStatBounds` — cached roster-wide min/max), `scripts/stat_bar.gd` (`StatBar` — segmented bar widget drawn against it) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/hq.gd` (tuning lift) |
| Cosmetic wheels | `scripts/wheel_style.gd` (`WheelStyle` — style resolution), `scripts/car_library.gd` (`wheel_catalogue`), `scripts/save_manager.gd` (`Save.set_wheels`), `scripts/car.gd` (`reskin_wheels`), `scripts/hq.gd` (`CarparkMode.WHEELS`) |
| Engine swap / detune | `scripts/engine_swap.gd` (`EngineSwap` — current-engine resolution, mass/weight-front recompute, swap eligibility), `scripts/save_manager.gd` (`Save.swap_engines`/`set_engine_detune`), `scripts/car.gd` (`_apply_engine_swap`) |
| Reward draws | `scripts/reward_system.gd` (`RewardSystem` — the car draw + its tier clamp, and the prize-rally part unlock) |
| Rally session | `scripts/rally_session.gd` (`RallySession` autoload — event-flow orchestration) |
| Event replay | `scripts/replay_recorder.gd` (`ReplayRecorder`), `scripts/replay_camera.gd` (`ReplayCamera`), `scripts/car.gd` (`replay_playback`) |
| Stage flow | `scripts/stage_manager.gd` (`StageManager`), `scripts/car.gd` (`controls_locked`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Opponent wrecks | `scripts/rally_library.gd` (`generate_opponent_field` / `event_wreck`), `scripts/world.gd` (`_spawn_opponent_wreck`) |
| Settings page | `scripts/settings_menu.gd` (`SettingsMenu` — shared camera-angle + key-binding + mobile-control picker) |
| Key rebinding | `scripts/input_remap.gd` (`InputRemap` autoload — keyboard/controller rebind over the InputMap) |
| Pause menu | `scripts/pause_menu.gd` (`PauseMenu` — top-right freeze button → Resume / Settings) |
| Game-loop shell | `hq.tscn`/`scripts/hq.gd`, `podium.tscn`/`scripts/podium.gd`, `scripts/world.gd` (session fielding) |
| Garage model | `garage.tscn`/`scripts/garage.gd`, `tools/render_garage.gd`/`.sh` (multi-angle renders) |
| Scene wiring | `scripts/world.gd`, `main.tscn` |
| Shaders | `shaders/ps1_models.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/billboard_opaque.gdshader` |
| Headlight cone (night + storm) | `shaders/headlight_cone.gdshaderinc` (the shared `global uniform` block + `headlight_lit()`, included by the five lit shaders), `scripts/headlight_cone.gd` (`HeadlightCone` — `amount` / `has_headlights` / `params` / `push` / `reset`), the weather table's `headlights` key (`scripts/weather_library.gd` → `headlight_amount`), `project.godot` `[shader_globals]`, `scripts/world.gd` (`_process` / `_exit_tree`) — see [rendering.md](rendering.md), [weather.md](weather.md) |
| Weather dimming of fake-lit materials | `scripts/game_config.gd` (`weather_lit` — the rule; `apply_car_light` / `apply_foliage_light`; the runtime `weather_sun_mult`), `scripts/world.gd` (`_apply_overcast_look` seeds it, `_apply_weather_look` re-seeds 1.0, `_exit_tree` resets it), and the callers `scripts/billboard_field.gd`, `scripts/lake_field.gd`, `scripts/sign_field.gd` — see [weather.md](weather.md), [rendering.md](rendering.md) |
| Sky panorama | `scripts/world.gd` (`_apply_region_look` seeds it unconditionally from the region look or `GameConfig.default_sky_panorama`; `_apply_weather_look` lets a condition override it — only night does, via `night_sky_panorama` / `textures/sky-night.jpg`), `main.tscn` (`WorldEnvironment`'s shared `PanoramaSkyMaterial`); the OVERWORLD instead cross-fades between two panoramas on its own `shaders/overworld_sky.gdshader` sky material (`Overworld._fade_sky` / `sky_fade_plan`) — see [regions.md](regions.md), [weather.md](weather.md), [overworld.md](overworld.md) |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/perf_overlay.gd` |
| Perf benchmark | `benchmark/perf_benchmark.gd`, `run_benchmark.sh` |
| In-game benchmark | `scripts/benchmark_mode.gd` (`Benchmark` autoload), `scripts/benchmark_runner.gd`, `scripts/benchmark_stats.gd`, `scripts/benchmark_results.gd` |
| Tests | `tests/`, `run_tests.sh` |
| Release / CI | `.github/workflows/deploy.yml`, `.github/actions/install-butler/action.yml`, `build_web.sh`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh` |
| Update check | `scripts/update_check.gd` (`UpdateCheck`), `scripts/hq.gd` (`_check_for_update`), `deploy.yml` → `deploy-pages` (`docs/version.json`) |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
