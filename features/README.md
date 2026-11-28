# Rally — Feature Documentation

This folder is the **agent-oriented overview** of the `rally` project. Each file
documents one feature area: what it does, where it lives, how the pieces fit
together, and which config knobs control it. Read this folder first to get
oriented before diving into source.

`rally` (TAPPA) is a small PS1-aesthetic **rally game** built in **Godot 4.6**
(GL Compatibility renderer). **The game world is one authored level, Hafren Forest**
(`Scenes.WORLD` = `level_view.tscn`, see [level-editor.md](level-editor.md)) — the default mode.

Earlier versions (a rally career, a run-based roguelike, a procedural free-roam island with a
generated-stage harness) were deleted in November 2026 (the Hafren-only cleanup; its spec is in git history);
git history has them. The island's parts shop survives as the level's part pages ([loot.md](loot.md)).

## How to use this folder

- Skim this README for the big picture and file map.
- Open the feature file that matches what you're working on.
- Every gameplay/look value lives in `scripts/game_config.gd` (a `GameConfig`
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
| [weather.md](weather.md) | Weather (dry / rain / sandstorm / fog / storm / snowfall / night) — the `WeatherLibrary` table every condition is read from, how `LevelWeather` drifts and cross-fades it on the level, and the headlight cone |
| [snow-region.md](snow-region.md) | The Alps — the map's NE corner. The first region to influence HANDLING as well as look: per-surface grip overrides, deep snow you sink into and bog down in, frozen lakes you drive on, snowfall |
| [regions.md](regions.md) | `RegionLibrary` — region catalogue (look overrides per region). The level reads only `home`'s look, for its wheel particles and dust |
| [upgrade-catalogue.md](upgrade-catalogue.md) | `UpgradeLibrary` — the `EFFECTS` descriptor table and the `apply` pipeline that writes a car's `boosts` onto its config, plus the drive-mode resolver |
| [tuning.md](tuning.md) | `TuningLibrary` — free, reversible per-car handling tuning (grip / brake-bias / aero sliders) |
| [aero-parts.md](aero-parts.md) | Spoiler/splitter meshes tagged `_aero` in a car glb — hidden by default, revealed when the aero kit is enabled |
| [wheel-customization.md](wheel-customization.md) | Cosmetic wheel swap — any car's wheels on any owned car (free, ungated, texture-only) |
| [engine-swap.md](engine-swap.md) | `EngineSwap` + `car.gd::_apply_engine_swap`, plus the legacy owned-car `swapped_engine` read path and the engine-detune power knob |
| [car-cargo.md](car-cargo.md) | Delivery boxes and straps on the car while cargo is aboard — `CarCargo`, authored per car in `tools/cargo_lab.html` |
| [damage.md](damage.md) | `DamageModel` — per-car HP, impact attrition, power/steer degradation, misfire + rev cap as HP falls; in free roam 0 HP gives up into the wreck page |
| [car-physics.md](car-physics.md) | Chassis, suspension, steering, braking, reset |
| [drivetrain-and-tires.md](drivetrain-and-tires.md) | Custom tire model, wheel spin, RWD/AWD/FWD |
| [engine-and-transmission.md](engine-and-transmission.md) | Torque curve, gearbox, clutch, rev limiter, auto-shift; `EngineLibrary` (`scripts/engine_library.gd`) — the catalog of real engines cars reference by id |
| [engine-audio.md](engine-audio.md) | Procedural engine sound synthesis |
| [sfx.md](sfx.md) | **One-shot sound effects — `Audio` autoload (`scripts/audio.gd`), `Audio.play_beep(...)`, the SFX bus. Read this before playing ANY sound; never hand-roll an `AudioStreamGenerator` at a call site.** |
| [music.md](music.md) | Interactive looping background music — `MusicSchedule` timing math, `MusicLibrary` catalogue, `MusicDirector` autoload (single-player polyphonic double-buffer), Music bus |
| [forced-induction.md](forced-induction.md) | Turbocharger (inertia-based shaft sim, boost, lag/anti-lag) + supercharger (stateless rpm-linear belt drive, rpm-scaled drag) — engine property, stock or fitted as `BoostLibrary` `turbo` / `supercharger` loot parts |
| [nitrous.md](nitrous.md) | Held-button torque multiplier with a per-stage tank — a loot part (`BoostLibrary` `nitrous`, `install_nitrous`), `EngineSim` delivery/drain, the violet HUD gauge, LEFT-Shift / joypad-X / mobile NOS input, and the all-hiss synth layer |
| [loot.md](loot.md) | **Parts** — `LootRules` (the parts catalogue, parts through the owned-car funnel, fitting rules) and `RestStopPage`, the level's Parts / Engine swaps / Tune pages |
| [world-session.md](world-session.md) | `WorldSession` (the profile's world block: seed and starter car), and the boot scene |
| [hud.md](hud.md) | `hud.gd` — speed / gear / rpm readouts, the Health / boost / nitrous / temperature gauges, and the debug readouts (H) |
| [loading.md](loading.md) | The loading screen and how `LevelView` loads the level behind it |
| [trees.md](trees.md) | The level's trees and bushes; `tools/tree_lab.html` procedural tree playground; `tools/groundcover_lab.html` opaque grass-tuft playground |
| [geo-pipeline.md](geo-pipeline.md) | `tools/geo/` scripts: fetch Welsh LiDAR, OSM and satellite for a real square, build a level editor save and a ground-cover mask |
| [buildings.md](buildings.md) | `tools/building_lab.html` — procedural cottages / huts / barns as one-mesh, one-atlas low-poly buildings; `bake_buildings.js` + `LevelBuildings` put a level's buildings in the game |
| [shop-lab.md](shop-lab.md) | `tools/shop_lab.html` — procedural roadside car shop / tuning garage generated from a seed and a level `stock` list (cars on the forecourt, part props, sign, bunting) |
| [start-lab.md](start-lab.md) | `tools/start_lab.html` + `tools/start_lines.js` — procedural rally stage start (baked into the level's buildings.json) (arch, start control, gazebos, tape, seeded sponsor adverts) laid out around a road of a given width |
| [rallies.md](rallies.md) | `LevelRallies` — the level's named rallies: spot finder (`tools/rally_spots.gd`), baked gravel pads, the active rally's start lines (solid) and crowds, the Dev rally picker |
| [level-ao.md](level-ao.md) | Fake ambient occlusion in the level view: a ground-darkening map round trees / buildings / log piles, bush-cover vertex shade, and base-darkening on trees, bushes, buildings and log piles |
| [level-streamer.md](level-streamer.md) | `LevelStreamer` (`scripts/level_streamer.gd`): the level's ground streamed in four levels of detail with collision under the car, under a strict frame budget, on worker threads |
| [level-editor.md](level-editor.md) | **The game world (default mode):** `level_view.tscn` (`LevelView`, `Scenes.WORLD`), which drives the Hafren level (`GameConfig.level_path`), and `tools/level_editor_lab.html` (2D/3D level editor) that authors it; its map (M), with discovery fog (`LevelDiscovery`) |
| [spectators.md](spectators.md) | Roadside crowds (start/mid/end) — boids-style steering while upright, knocked into single-capsule ragdolls by the car; ghost to the car, not obstacles; `tools/spectator_lab.html` procedural stylised spectator generator |
| [tire-marks.md](tire-marks.md) | `TireMarks` — gravel ruts laid behind the wheels (per-wheel ribbon mesh, gated to the road, capped) |
| [wheel-dust.md](wheel-dust.md) | `WheelParticles` — cheap surface debris flung from the driven wheels under wheelspin (one CPU pool + MultiMesh, ring-buffered; per-particle colour/size/roll picks gravel clods, grass blades, or nothing on tarmac) |
| [dust-puffs.md](dust-puffs.md) | `DustPuffs` — opaque, flat-shaded low-poly dust clouds left behind the rear wheels on road (gravel-coloured on gravel, near-white on tarmac) (one blob mesh + MultiMesh; size/tumble in the instance basis; hidden near the camera; pops at end of life) |
| [engine-smoke.md](engine-smoke.md) | `EngineSmoke` — grey smoke puffed from the bonnet on each damage misfire (own small CPU pool + MultiMesh, grows & fades) |
| [exhaust-flames.md](exhaust-flames.md) | `ExhaustFlames` — backfire flame from each exhaust pipe on a rev-limiter bang and while nitrous delivers |
| [car-shadow.md](car-shadow.md) | `CarShadow` — the fake blob shadow laid on the ground under the player's car, fading with height |
| [car-lamps.md](car-lamps.md) | `CarLamps` — glowing head and tail lamp flares at each car's authored lamp centres; headlights with the night cone, tail lamps with it and under the foot brake |
| [camera.md](camera.md) | Camera modes: chase follow, bonnet hood, and photo mode free-fly |
| [card-carousel.md](card-carousel.md) | **Every menu is a card list** — `CardCarousel` (the side-scrolling card widget) and `CardUI` (`card_page` / `card_list` — build a menu from a list of entry dicts); which menus are cards and which are plain pages |
| [menus.md](menus.md) | Scene routing (`Scenes`), the pause menu, the rest-stop page and world pages, modals |
| [menu-navigation.md](menu-navigation.md) | **Keyboard / gamepad menu navigation — the `MenuNav` framework.** Focus, WASD/arrow/D-pad movement, back routing. Read this before adding or changing ANY menu: every menu must work on keyboard and controller, and that is a CLAUDE.md rule with a required nav test |
| [settings.md](settings.md) | **Adding or changing a persisted setting** — the one-module-per-setting apply-owner pattern (`*_setting.gd`), boot re-application, the shared `SettingsMenu` on the pause menu, and the developer-only pages |
| [modals.md](modals.md) | **Modals and confirms** — `ConfirmPopup`, the one-modal-at-a-time `MODAL_GROUP`, the scrolled-body / pinned-exit modal page shape, and `MenuNav.input_blocked` |
| [ui-design-system.md](ui-design-system.md) | `UITheme` + global theme — palette, pixel font, panel/button styling shared by every screen |
| [mobile-controls.md](mobile-controls.md) | On-screen touch buttons: steer/throttle/brake (phones/web) |
| [rendering.md](rendering.md) | PS1 shaders, dither post-process, materials, fog |
| [asset-pipeline.md](asset-pipeline.md) | Source art → PCK: texture import settings, the live/orphan car-texture trap, the 1024×512 sky-panorama house format, export exclude filters, PCK sizing |
| [car-scanning.md](car-scanning.md) | `tools/car_scan/` — walk-around video of a car → Apple Object Capture photogrammetry → low-poly textured body glb |
| [debug-tools.md](debug-tools.md) | Force-arrow visualization overlay |
| [adaptive-graphics.md](adaptive-graphics.md) | The level tunes its own draw distances, effects and resolution live to hold the frame rate; full-detail terrain kept under the car; the P overlay's adaptive page |
| [benchmark.md](benchmark.md) | The Hafren replay benchmark (`run_level_replay.sh`, `?replay=1`): record a drive, replay it and measure every frame; the report and the phone profiling loop |
| [controls.md](controls.md) | Full input map / key bindings |
| [testing.md](testing.md) | GUT test suite, render smoke test, `run_tests.sh` |
| [release-pipeline.md](release-pipeline.md) | The `Release` workflow — cache gate, Cloudflare Pages (web), itch/Play/GitHub Pages/Firestore jobs, the `install-butler` composite action, secrets |
| [update-check.md](update-check.md) | Launch-time "a newer build is out" prompt for every NATIVE build (Play included — a testing track doesn't self-update) — `UpdateCheck`, the Pages-published `version.json`, per-store destinations, why web is excluded |

## File-to-feature quick map

| Feature | Primary source |
|---------|----------------|
| Car control | `scripts/car.gd`, `car.tscn` |
| Tire forces | `scripts/drivetrain.gd` |
| Engine/gearbox | `scripts/engine.gd`, `scripts/engine_library.gd` (`EngineLibrary` — engine catalog) |
| Engine sound | `scripts/engine_audio.gd`, `scripts/engine_audio_synth.gd` |
| Sound effects (any "play a sound when X" task) | `scripts/audio.gd` (`Audio` autoload — `play_beep`), see `features/sfx.md` |
| Exhaust flames | `scripts/exhaust_flames.gd` |
| Level ground | `scripts/level_streamer.gd` (`LevelStreamer`) — see [level-streamer.md](level-streamer.md) |
| Trees & bushes | `scripts/level_trees.gd`, `scripts/foliage.gd`, `shaders/level_tree.gdshader` |
| Camera | `scripts/chase_camera.gd`, `scripts/camera_manager.gd` (`CameraManager` — modes, cycle, persistence), `tools/bonnet_clearance.gd` (per-car bonnet cam height) |
| HUD | `scripts/hud.gd` |
| Character dialogue | `scripts/npc_dialogue.gd` (`NpcDialogue`), `tools/render_npc.sh` (portraits) — see [npc-dialogue.md](npc-dialogue.md) |
| Config | `scripts/game_config.gd`, `scripts/config.gd` |
| Player profile / saves | `scripts/save_manager.gd` (`Save` autoload), `scripts/car_library.gd` (car metadata + stable ids) |
| Regions | `scripts/region_library.gd` (`RegionLibrary` — region catalogue, look overrides, the biome-ring order) |
| Effects funnel | `scripts/upgrade_library.gd` (`UpgradeLibrary` — the `EFFECTS` table, `apply`; no longer a catalogue), `scripts/boost_library.gd` (`BoostLibrary` — the parts catalogue) |
| Per-car tuning | `scripts/tuning_library.gd` (`TuningLibrary` — grip/brake/aero sliders), `scripts/drivetrain.gd` (brake-bias split), `scripts/tuning_panel.gd` (the slider UI, hosted by the rest stop page) |
| Cosmetic wheels | `scripts/wheel_style.gd` (`WheelStyle` — style resolution), `scripts/car_library.gd` (`wheel_catalogue`), `scripts/car.gd` (`reskin_wheels`) — **no screen fits them today** |
| Engine swap / detune | `scripts/engine_swap.gd` (`EngineSwap` — current-engine resolution, layout label, mass/weight-front recompute), `scripts/car.gd` (`_apply_engine_swap`) |
| Damage / HP | `scripts/damage_model.gd` (`DamageModel`), `scripts/car.gd` (contacts + effects) |
| Settings page | `scripts/settings_menu.gd` (`SettingsMenu` — shared camera-angle + key-binding + mobile-control picker) |
| Photo mode | `scripts/photo_mode_host.gd` (`PhotoModeHost`: the pause menu's row, screen clearing), `scripts/photo_mode.gd` (the camera), `scripts/photo_mode_controls.gd` (touch) — see [camera.md](camera.md) |
| Key rebinding | `scripts/input_remap.gd` (`InputRemap` autoload — keyboard/controller rebind over the InputMap) |
| Pause menu | `scripts/pause_menu.gd` (`PauseMenu` — top-right freeze button → Resume / Settings) |
| Scene wiring | `scripts/level_view.gd`, `level_view.tscn` |
| Shaders | `shaders/ps1_models_lit.gdshader`, `shaders/ps1_post_process.gdshader`, `shaders/level_tree.gdshader`, `shaders/level_ground.gdshader` (level view ground + gravel and tarmac roads, [level-editor.md](level-editor.md)) |
| Headlight cone (night + storm) | `shaders/headlight_cone.gdshaderinc` (the shared `global uniform` block + `headlight_lit()`, included by the five lit shaders), `scripts/headlight_cone.gd` (`HeadlightCone` — `amount` / `has_headlights` / `params` / `push` / `reset`), the weather table's `headlights` key (`scripts/weather_library.gd` → `headlight_amount`), `project.godot` `[shader_globals]`, `scripts/level_view.gd` and `scripts/level_weather.gd` (push / reset) — see [rendering.md](rendering.md), [weather.md](weather.md) |
| Tree wind sway | `shaders/wind_sway.gdshaderinc` (the shared `global uniform` block + `wind_sway_offset()`, included by `level_tree`), `scripts/wind_sway.gd` (`WindSway` — `strength` / `direction_deg` / `params` / `push` / `base` / `reset`), the weather table's `foliage_wind` key (`scripts/weather_library.gd`), `project.godot` `[shader_globals]`, `scripts/level_view.gd` (`apply_weather` / `_exit_tree`) — see [trees.md](trees.md), [weather.md](weather.md) |
| Weather dimming of fake-lit materials | `scripts/game_config.gd` (`weather_lit` — the rule; `apply_car_light`; the runtime `weather_sun_mult`) — see [weather.md](weather.md), [rendering.md](rendering.md) |
| Sky panorama | `scripts/level_weather.gd` (`LevelWeather` — `GameConfig.default_sky_panorama`, overridden by a condition's `sky_panorama` key; only night has one, `night_sky_panorama` / `textures/sky-night.jpg`), `level_view.tscn` (`WorldEnvironment`'s `PanoramaSkyMaterial`) — see [weather.md](weather.md) |
| Debug | `scripts/wheel_force_debug.gd`, `scripts/level_stats.gd` |
| Benchmark | `benchmark/level_replay.gd`, `run_level_replay.sh`, `scripts/benchmark_mode.gd` (`Benchmark` autoload), `scripts/benchmark_stats.gd`, `scripts/benchmark_report.gd` |
| Tests | `tests/`, `run_tests.sh` |
| Release / CI | `.github/workflows/deploy.yml`, `.github/actions/install-butler/action.yml`, `build_web.sh`, `tools/deploy_pages.sh`, `cloudflare/`, `build_android.sh`, `build_windows.sh`, `build_android_play.sh` |
| Update check | `scripts/update_check.gd` (`UpdateCheck`; no screen hosts it since the title screen was deleted), `deploy.yml` → `deploy-pages` (`docs/version.json`) |

> **Keep this current:** when you add or change a feature, update the matching
> file here in the same piece of work (see CLAUDE.md).
