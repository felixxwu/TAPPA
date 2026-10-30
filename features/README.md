# Rally — Feature Documentation

This folder is the **agent-oriented overview** of the `rally` project. Each file
documents one feature area: what it does, where it lives, how the pieces fit
together, and which config knobs control it. Read this folder first to get
oriented before diving into source.

`rally` (TAPPA) is a small PS1-aesthetic **free-roam rally game** built in **Godot 4.6**
(GL Compatibility renderer). One persistent procedural island per save: you drive outward from
the spawn rest stop on a road network that streams in around you, through biome rings that get
rarer further out, finding cars and parts. Damage is unforgiving: once the cooling fails you
race the temperature gauge to the next rest stop, where you repair, buy cars and parts, fit parts and
fast-travel. See [free-roam.md](free-roam.md), [loot.md](loot.md) and
[world-session.md](world-session.md).

> **New to this codebase?** Read [`../PIVOT-CHANGES.md`](../PIVOT-CHANGES.md) first. The game
> has pivoted twice: a rally *career* became a run-based roguelike (September 2026), and the
> roguelike became free roam (October 2026, `todo/2026-10-19-free-roam-pivot.md`). That file is
> the two-minute map of what changed and which seams not to work around. The stage scene
> (`main.tscn` / `world.gd`) survives only as a dev stage and the physics test harness.

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
| [save-persistence.md](save-persistence.md) | `Save` autoload — player profile (owned cars, HP, inventory, the world block) at `user://profile.json` |
| [cloud-save.md](cloud-save.md) | Optional Firebase account — sign-in, Firestore profile sync, conflict resolution |
| [weather.md](weather.md) | Per-event weather (dry / rain / sandstorm / fog / storm / snowfall / night) — the `WeatherLibrary` table that is the single source of truth for every condition, the `GameConfig` blocks it names, and the fake headlight cone night re-lights the world with (authored on five stages, one per region) |
| [snow-region.md](snow-region.md) | The Alps — the map's NE corner. The first region to influence HANDLING as well as look: per-surface grip overrides, deep snow you sink into and bog down in, frozen lakes you drive on, snowfall, and the six rallies (two carrying re-sited part unlocks) |
| [regions.md](regions.md) | `RegionLibrary` — region catalogue (look overrides per region), the `region` rally tag, driven-world theming, per-corner waterlines, the unconditional sky re-seed that stops one region's sky leaking into the next stage. Regions gate NOTHING any more — look + `water_level` only |
| [progress.md](progress.md) | `TrackProgress` — distance along the road centerline + off-track auto-reset. **Per-stage distance, NOT career progress** — run state lives in [save-persistence.md](save-persistence.md) |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — the `EFFECTS` descriptor table and the `apply` pipeline that writes a car's `boosts` onto its config, plus the drive-mode resolver |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) + the tuning-lift UI |
| [aero-parts.md](aero-parts.md) | Spoiler/splitter meshes tagged `_aero` in a car glb — hidden by default, revealed when the aero kit is enabled |
| [wheel-customization.md](wheel-customization.md) | Cosmetic wheel swap — any car's wheels on any owned car (free, ungated, texture-only); the solo car-park wheel view |
| [engine-swap.md](engine-swap.md) | `EngineSwap` + `car.gd::_apply_engine_swap`, plus the legacy owned-car `swapped_engine` read path and the engine-detune power knob |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, misfire + rev cap as HP falls; in free roam 0 HP gives up into the wreck page |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift; `EngineLibrary` (`scripts/engine_library.gd`) — the catalog of real engines cars reference by id |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [sfx.md](sfx.md) | **One-shot sound effects — `Audio` autoload (`scripts/audio.gd`), `Audio.play_beep(...)`, the SFX bus. Read this before playing ANY sound; never hand-roll an `AudioStreamGenerator` at a call site.** |
| [music.md](music.md) | Interactive looping background music — `MusicSchedule` timing math, `MusicLibrary` catalogue, `MusicDirector` autoload (single-player polyphonic double-buffer), Music bus |
| [forced-induction.md](forced-induction.md) | Turbocharger (inertia-based shaft sim, boost, lag/anti-lag) + supercharger (stateless rpm-linear belt drive, rpm-scaled drag) — engine property, stock or fitted as `BoostLibrary` `turbo` / `supercharger` loot parts |
| [nitrous.md](nitrous.md) | Held-button torque multiplier with a per-stage tank — a loot part (`BoostLibrary` `nitrous`, `install_nitrous`), `EngineSim` delivery/drain, the violet HUD gauge, LEFT-Shift / joypad-X / mobile NOS input, and the all-hiss synth layer |
| [loot.md](loot.md) | **Free-roam coins and shops** — `LootRules` (ring tables, prices, parts through the owned-car funnel), `LootDirector` (coins, money, the wreck loses it all, what's on sale), buying on the rest-stop Parts / Garage pages |
| [world-session.md](world-session.md) | **The persistent free-roam world** — `WorldSession` (the world block in the profile: seed, car, pose, lit rest stops, map), the title screen the game boots into, and the map / stats pages |
| [hud.md](hud.md) | `hud.gd` — speed / gear / rpm readouts, the Health / boost / nitrous / temperature gauges, and the debug readouts (H) |
| [minimap.md](minimap.md) | **Free roam's minimap** — `MiniMap` (heading-up, perspective-tilted nav-style map top-centre: driven roads, nearby road ahead, seen rest stops and loot; tap / M opens the full map), the `seen` sites record |
| [free-roam.md](free-roam.md) | **The free-roam game, entered from the title screen** — `RoadNetwork` (radial-growth road layout), `RoadTerrain` (height built from the roads, base-field lakes), `TerrainStreamer` (resumable chunk jobs under a strict per-frame time budget, two LODs, skirts, collision ring) |
| [loading.md](loading.md) | Stage-load pipeline: `_stage` timing, cached vs live generation, the `load_finished` hook |
| [terrain.md](terrain.md) | Infinite chunked Perlin terrain, collision, chunk loading |
| [terrain-streaming.md](terrain-streaming.md) | `TerrainManager`'s streaming opt-ins for the stage harness — load radius, generate-on-miss, the LRU cap |
| [terrain-chunk-modifiers.md](terrain-chunk-modifiers.md) | How `TerrainManager.bake_track` splits its per-vertex work into `_bake_vertex_block`/`_emit_cliff_offsets` |
| [lakes.md](lakes.md) | Per-event water level floods natural basins; the track DFS routes the road around water; soft-hazard drag; `TrackGenParams` shape contract |
| [track.md](track.md) | Corner shape library (Curve2D) + catalog scene |
| [stage.md](stage.md) | `StageManager` — the dev stage's countdown → run timer → completion + the car control lock |
| [trees.md](trees.md) | Billboard tree & bush sprites scattered around each track turn |
| [rocks.md](rocks.md) | Roadside boulders — low-poly collidable MESHES (not billboards), density set per region |
| [barriers.md](barriers.md) | Solid crash barriers on the outside of sharp corners — 2 m modules stitched into a run; armco guardrail on gravel, concrete jersey rail on tarmac (`BarrierSection` / `BarrierLayout` / `BarrierField`) |
| [spectators.md](spectators.md) | Roadside crowds (start/mid/end) — boids-style steering while upright, knocked into single-capsule ragdolls by the car; ghost to the car, not obstacles |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [wheel-dust.md](wheel-dust.md) | `WheelParticles` — cheap surface debris flung from the driven wheels under wheelspin (one CPU pool + MultiMesh, ring-buffered; per-particle colour/size/roll picks gravel clods, grass blades, or nothing on tarmac) |
| [dust-puffs.md](dust-puffs.md) | `DustPuffs` — opaque, flat-shaded low-poly dust clouds left behind the rear wheels on road (gravel-coloured on gravel, near-white on tarmac) (one blob mesh + MultiMesh; size/tumble in the instance basis; hidden near the camera; pops at end of life) |
| [engine-smoke.md](engine-smoke.md) | `EngineSmoke` — grey smoke puffed from the bonnet on each damage misfire (own small CPU pool + MultiMesh, grows & fades) |
| [exhaust-flames.md](exhaust-flames.md) | `ExhaustFlames` — backfire flame from each exhaust pipe on a rev-limiter bang and while nitrous delivers; plus the exhaust lab dev scene for positioning the pipes |
| [car-lamps.md](car-lamps.md) | `CarLamps` — glowing head and tail lamp flares at each car's authored lamp centres; headlights with the night cone, tail lamps with it and under the foot brake |
| [camera.md](camera.md) | Camera modes: chase follow, bonnet hood, and photo mode free-fly |
| [card-carousel.md](card-carousel.md) | **Every menu is a card list** — `CardCarousel` (the side-scrolling card widget) and `CardUI` (`card_page` / `card_list` — build a menu from a list of entry dicts); which menus are cards and which are plain pages |
| [menus.md](menus.md) | Scene routing (`Scenes`), the title menu, the pause menu, the rest-stop page and world pages, modals |
| [menu-navigation.md](menu-navigation.md) | **Keyboard / gamepad menu navigation — the `MenuNav` framework.** Focus, WASD/arrow/D-pad movement, back routing, remembering the selected row. Read this before adding or changing ANY menu: every menu must work on keyboard and controller, and that is a CLAUDE.md rule with a required nav test |
| [lifetime-stats.md](lifetime-stats.md) | Persistent lifetime counters (`LifetimeStats`) — one authored registry, only ever grows, survives run failure; the ledger skill unlock gates read |
| [settings.md](settings.md) | **Adding or changing a persisted setting** — the one-module-per-setting apply-owner pattern (`*_setting.gd`), boot re-application, the shared `SettingsMenu` used by both the title screen and the pause menu, and the developer-only pages |
| [modals.md](modals.md) | **Modals and confirms** — `ConfirmPopup`, the one-modal-at-a-time `MODAL_GROUP`, the scrolled-body / pinned-exit modal page shape, and `MenuNav.input_blocked` |
| [ui-design-system.md](ui-design-system.md) | `UITheme` + global theme — palette, pixel font, panel/button styling shared by every screen |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [asset-pipeline.md](asset-pipeline.md) | Source art → PCK: texture import settings, the live/orphan car-texture trap, the 1024×512 sky-panorama house format, export exclude filters, PCK sizing |
| [car-scanning.md](car-scanning.md) | `tools/car_scan/` — walk-around video of a car → Apple Object Capture photogrammetry → low-poly textured body glb |
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
| Jumps / road vertical profile | `scripts/track_profile.gd` (`TrackProfile` — the crest offset keyed on arc distance, the launch-speed formula), the `Jump` entry in `scripts/corner_library.gd`, the `road_heights` seam in `scripts/terrain_manager.gd` — see [track.md](track.md) → *Jumps* |
| Lakes / water | `scripts/lake_field.gd` (`LakeField`), `scripts/track_gen_params.gd` (`TrackGenParams`), `scripts/terrain_noise.gd` (`TerrainNoise`), `shaders/water.gdshader` |
| Track shape params | `scripts/track_gen_params.gd` (`TrackGenParams` — the required shape contract for `TrackGenerator.generate`) |
| Trees & bushes | `scripts/tree_scatter.gd`, `scripts/billboard_field.gd`, `shaders/billboard_opaque.gdshader` |
| Corner barriers | `scripts/barrier_layout.gd` (`BarrierLayout` planner), `scripts/barrier_field.gd` (`BarrierField` builder), `scripts/barrier_section.gd` (`BarrierSection` module), `tools/render_barriers.gd`/`.sh` |
| Camera | `scripts/chase_camera.gd`, `scripts/camera_manager.gd` (`CameraManager` — modes, cycle, persistence), `tools/bonnet_clearance.gd` (per-car bonnet cam height) |
| HUD | `scripts/hud.gd` |
| Config | `scripts/game_config.gd`, `scripts/config.gd`, `config/game_config.tres` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Regions | `scripts/region_library.gd` (`RegionLibrary` — region catalogue, look overrides, the linear unlock order) |
| Effects funnel | `scripts/upgrade_library.gd` (`UpgradeLibrary` — the `EFFECTS` table, `apply`; no longer a catalogue), `scripts/boost_library.gd` (`BoostLibrary` — the in-run boosts) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/tuning_panel.gd` (the slider UI, hosted by the rest stop page) |
| Cosmetic wheels | `scripts/wheel_style.gd` (`WheelStyle` — style resolution), `scripts/car_library.gd` (`wheel_catalogue`), `scripts/save_manager.gd` (`Save.set_wheels`), `scripts/car.gd` (`reskin_wheels`) — **no screen fits them today** |
| Engine swap / detune | `scripts/engine_swap.gd` (`EngineSwap` — current-engine resolution, layout label, mass/weight-front recompute), `scripts/car.gd` (`_apply_engine_swap`) |
| Stage flow | `scripts/stage_manager.gd` (`StageManager`), `scripts/car.gd` (`controls_locked`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Settings page | `scripts/settings_menu.gd` (`SettingsMenu` — shared camera-angle + key-binding + mobile-control picker) |
| Key rebinding | `scripts/input_remap.gd` (`InputRemap` autoload — keyboard/controller rebind over the InputMap) |
| Pause menu | `scripts/pause_menu.gd` (`PauseMenu` — top-right freeze button → Resume / Settings) |
| Scene wiring | `scripts/world.gd`, `main.tscn` |
| Shaders | `shaders/ps1_models.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/billboard_opaque.gdshader` |
| Headlight cone (night + storm) | `shaders/headlight_cone.gdshaderinc` (the shared `global uniform` block + `headlight_lit()`, included by the five lit shaders), `scripts/headlight_cone.gd` (`HeadlightCone` — `amount` / `has_headlights` / `params` / `push` / `reset`), the weather table's `headlights` key (`scripts/weather_library.gd` → `headlight_amount`), `project.godot` `[shader_globals]`, `scripts/world.gd` (`_process` / `_exit_tree`) — see [rendering.md](rendering.md), [weather.md](weather.md) |
| Tree wind sway | `shaders/wind_sway.gdshaderinc` (the shared `global uniform` block + `wind_sway_offset()`, included by `billboard_opaque`), `scripts/wind_sway.gd` (`WindSway` — `strength` / `direction_deg` / `params` / `push` / `base` / `reset`), the weather table's `foliage_wind` key (`scripts/weather_library.gd`), `project.godot` `[shader_globals]`, `scripts/world.gd` (`_apply_weather_look` / `_exit_tree`), `scripts/foliage.gd` (`spawn_trees` seeds the base) — see [trees.md](trees.md), [weather.md](weather.md) |
| Weather dimming of fake-lit materials | `scripts/game_config.gd` (`weather_lit` — the rule; `apply_car_light` / `apply_foliage_light`; the runtime `weather_sun_mult`), `scripts/world.gd` (`_apply_overcast_look` seeds it, `_apply_weather_look` re-seeds 1.0, `_exit_tree` resets it), and the callers `scripts/billboard_field.gd`, `scripts/lake_field.gd` — see [weather.md](weather.md), [rendering.md](rendering.md) |
| Sky panorama | `scripts/world.gd` (`_apply_region_look` seeds it unconditionally from the region look or `GameConfig.default_sky_panorama`; `_apply_weather_look` lets a condition override it — only night does, via `night_sky_panorama` / `textures/sky-night.jpg`), `main.tscn` (`WorldEnvironment`'s shared `PanoramaSkyMaterial`) — see [regions.md](regions.md), [weather.md](weather.md) |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/perf_overlay.gd` |
| Perf benchmark | `benchmark/perf_benchmark.gd`, `run_benchmark.sh` |
| In-game benchmark | `scripts/benchmark_mode.gd` (`Benchmark` autoload), `scripts/benchmark_runner.gd`, `scripts/benchmark_stats.gd`, `scripts/benchmark_results.gd` |
| Tests | `tests/`, `run_tests.sh` |
| Release / CI | `.github/workflows/deploy.yml`, `.github/actions/install-butler/action.yml`, `build_web.sh`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh` |
| Update check | `scripts/update_check.gd` (`UpdateCheck`; `title_screen.gd` → `_check_for_update` / `show_update_prompt` calls it), `deploy.yml` → `deploy-pages` (`docs/version.json`) |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
