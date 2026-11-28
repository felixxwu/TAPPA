# Parity checklist (Phase 1.10)

**Depends on:** Phase 1.1 (`todo/2026-11-28-phase-1-1-determinism-plan.md`, the golden replay) and the
yardsticks of `todo/2026-11-28-phase-1-rest-plan.md`. This is step 1.10 of
`todo/2026-11-27-rust-native-migration.md` ("The parity contract": one row per feature file, each naming its
parity check or a written reason the feature may differ). Switch-over needs every row `done` or `allowed`.

**Kept true by** `tests/headless/test_parity_checklist.gd`: every `features/*.md` (except `README.md`) needs a
row, every row's file must exist, and every `scripts/` path cited here must exist. Add the row in the same
piece of work as a new feature doc.

Status: `done` (the check exists and passes), `todo` (the check is planned; the WP names who builds it),
`allowed` (may differ; the last column says why), `n/a` (tooling outside the shipped game).

The checks, by name:
- **golden replay**: `./run_level_replay.sh --golden-check`, two runs give identical per-tick traces (1.1).
- **car step**: `goldens/car_step.jsonl.gz`, the free-run car snapshot per tick (1.2, WP1/WP2/WP9).
- **drift report**: `tools/drift_report.py` over a free run (1.3, WP11), reviewed, not a gate.
- **events**: `goldens/events.jsonl.gz`, the game-state trace (1.4, WP3/WP10).
- **menu flow** / **touch flow**: `goldens/menus.jsonl.gz`, `goldens/touch.jsonl.gz` (1.5, WP6/WP7).
- **scene counts**: `goldens/scene_counts.jsonl.gz`, world items within 1 cm (1.6, WP5).
- **save round-trip**: `tests/headless/test_save_round_trip.gd` (1.7, WP4).
- **audio synth**: a sample comparison of the engine synth (Phase 4; not built yet).
- **visual review**: side-by-side screenshots, judged by eye.
- **device targets**: `tools/device_targets.py` (1.8, WP-D).

## Features

| Feature | Parity check | Status | Allowed difference |
|---|---|---|---|
| [adaptive-graphics.md](../features/adaptive-graphics.md) | device targets; controller logic in its GUT tests (no parity golden, see 1.1 chosen default 5) | allowed | Knob choices follow each version's own frame times; off in every replay |
| [aero-parts.md](../features/aero-parts.md) | visual review (the wing mesh); downforce rides in car step | todo (WP9) | none |
| [architecture.md](../features/architecture.md) | none: describes project layout | n/a | Rust has its own layout |
| [asset-pipeline.md](../features/asset-pipeline.md) | none: build-time export sizing | n/a | Rust may package assets differently |
| [benchmark.md](../features/benchmark.md) | the harness itself; golden replay | done | Frame times are expected to differ (better) |
| [buildings.md](../features/buildings.md) | scene counts (building boxes); visual review | todo (WP5) | none |
| [camera.md](../features/camera.md) | visual review; camera cycle in menu flow (settings page) | todo (WP6) | Smoothing may differ within what the eye can't tell |
| [car-cargo.md](../features/car-cargo.md) | events (`cargo_hp` via delivery); visual review | todo (WP3/WP10) | none |
| [car-lamps.md](../features/car-lamps.md) | visual review | todo | Halo shading within a loose perceptual diff |
| [car-physics.md](../features/car-physics.md) | car step; drift report | todo (WP1/WP9/WP11) | Float tolerance per tick, wider on contact ticks |
| [car-scanning.md](../features/car-scanning.md) | none: offline tool | n/a | — |
| [car-shadow.md](../features/car-shadow.md) | visual review | todo | Loose perceptual diff |
| [card-carousel.md](../features/card-carousel.md) | menu flow (focus, boxes) | todo (WP6) | Car-card 3D preview by visual review only |
| [cloud-save.md](../features/cloud-save.md) | save round-trip (same JSON schema); manual sign-in test | todo (WP4) | iOS and Play Store builds open the email link in the app instead of pasting a code (Phase 0.3) |
| [configuration.md](../features/configuration.md) | every golden pins `GameConfig` values through behaviour | todo (WP9) | none |
| [controls.md](../features/controls.md) | car step inputs (`TickInput`); menu flow; touch flow | todo (WP2/WP6/WP7) | none |
| [damage.md](../features/damage.md) | events (`hp`, `wrecked`); car step (`damage` snapshot) | todo (WP3/WP9) | HP within a stated tolerance; events derived from it exact |
| [debug-tools.md](../features/debug-tools.md) | none: developer overlays | allowed | Dev keys and arrows may differ or be absent |
| [determinism.md](../features/determinism.md) | golden replay (RNG stream states per tick) | done | none; Rust ports PCG32 and `fnv1a32` exactly |
| [drivetrain-and-tires.md](../features/drivetrain-and-tires.md) | car step | todo (WP1/WP9) | Float tolerance per tick |
| [dust-puffs.md](../features/dust-puffs.md) | visual review (seeded stream `dust_puffs`) | todo | Loose perceptual diff |
| [engine-and-transmission.md](../features/engine-and-transmission.md) | car step (`engine` snapshot); events (`engine_sfx`) | todo (WP1/WP3) | Float tolerance per tick |
| [engine-audio.md](../features/engine-audio.md) | audio synth | todo (Phase 4) | Within a tolerance on the samples |
| [engine-smoke.md](../features/engine-smoke.md) | visual review | todo | Loose perceptual diff |
| [engine-swap.md](../features/engine-swap.md) | events (`bought_part`); save round-trip; car step for the swapped engine | todo (WP3/WP4) | none |
| [exhaust-flames.md](../features/exhaust-flames.md) | visual review (frames seeded by `fnv1a32`) | todo | Loose perceptual diff |
| [forced-induction.md](../features/forced-induction.md) | car step (`boost`, `omega_turbo`); events (`engine_sfx` BOV) | todo (WP1/WP3) | Float tolerance per tick |
| [geo-pipeline.md](../features/geo-pipeline.md) | none: offline level build | n/a | — |
| [hud.md](../features/hud.md) | visual review | todo | Layout matches by eye; pixel font at the same sizes |
| [level-ao.md](../features/level-ao.md) | visual review | todo | Loose perceptual diff |
| [level-editor.md](../features/level-editor.md) | events (deliveries, discovery); scene counts | todo (WP3/WP5) | none |
| [level-streamer.md](../features/level-streamer.md) | golden replay (chunk counts per tick); scene counts | done (1.1); todo (WP5) | Streaming order and timing may differ in normal play; the drained golden result may not |
| [neutral-format.md](../features/neutral-format.md) | neutral manifest diff (`tools/neutral_check.sh`, Phase 2): decoded data equals Godot's in memory | todo (Phase 2 WP7) | Lossy WebP decoding and LOD generation may differ by platform |
| [loading.md](../features/loading.md) | device targets (load time) | allowed | Load time may differ (expected faster); the loading cover by visual review |
| [loot.md](../features/loot.md) | events (`bought_part`); save round-trip; menu flow (shop pages) | todo (WP3/WP4/WP6) | none |
| [menu-navigation.md](../features/menu-navigation.md) | menu flow, keyboard and gamepad | todo (WP6) | none |
| [menus.md](../features/menus.md) | menu flow | todo (WP6) | none |
| [mobile-controls.md](../features/mobile-controls.md) | touch flow (touch and tilt) | todo (WP7) | none |
| [modals.md](../features/modals.md) | menu flow | todo (WP6) | none |
| [music.md](../features/music.md) | events (music state per tick) | todo (WP3/WP10) | none |
| [nitrous.md](../features/nitrous.md) | car step (`nitrous_*`); events (`engine_sfx`) | todo (WP1/WP3) | none |
| [npc-dialogue.md](../features/npc-dialogue.md) | menu flow (pages and confirm); visual review (typewriter) | todo (WP6) | none |
| [rallies.md](../features/rallies.md) | events (`rally`); scene counts for the start lines | todo (WP3/WP5) | none |
| [regions.md](../features/regions.md) | visual review | todo | Loose perceptual diff |
| [release-pipeline.md](../features/release-pipeline.md) | none: CI and store packaging | n/a | Rust ships its own pipeline |
| [rendering.md](../features/rendering.md) | visual review; device targets (draw calls) | todo | Loose perceptual diff; draw calls may differ (expected fewer) |
| [save-persistence.md](../features/save-persistence.md) | save round-trip | todo (WP4) | none; same values and schema |
| [settings.md](../features/settings.md) | menu flow (settings pages, `changed`); save round-trip | todo (WP4/WP6) | none |
| [sfx.md](../features/sfx.md) | events (`beep`) | todo (WP3) | none; same sounds on the same ticks |
| [shop-lab.md](../features/shop-lab.md) | scene counts (shop boxes); visual review | todo (WP5) | none |
| [snow-region.md](../features/snow-region.md) | car step on snow (grip, deep-snow drag) | todo (WP9) | Float tolerance per tick |
| [spectators.md](../features/spectators.md) | golden replay (groups, ragdolls); scene counts; car step `world` (ragdolls) | done (1.1); todo (WP5/WP9) | none |
| [start-lab.md](../features/start-lab.md) | scene counts (start-line boxes); visual review | todo (WP5) | none |
| [testing.md](../features/testing.md) | none: describes the test suite | n/a | — |
| [tire-marks.md](../features/tire-marks.md) | visual review | todo | Loose perceptual diff |
| [trees.md](../features/trees.md) | golden replay (felled trees); scene counts; car step `world` | done (1.1); todo (WP5/WP9) | none |
| [tuning.md](../features/tuning.md) | save round-trip (`tuning`); car step for a tuned car | todo (WP4/WP9) | none |
| [ui-design-system.md](../features/ui-design-system.md) | menu flow (boxes); visual review | todo (WP6) | none |
| [update-check.md](../features/update-check.md) | manual check on each native build | allowed | Off on iOS (Phase 0.6); store builds may defer to the store |
| [upgrade-catalogue.md](../features/upgrade-catalogue.md) | car step for a car with parts; save round-trip | todo (WP4/WP9) | none |
| [weather.md](../features/weather.md) | golden replay (`drive_time`, shown weather); events (`weather`) | done (1.1); todo (WP3) | Fades by visual review |
| [wheel-customization.md](../features/wheel-customization.md) | save round-trip; visual review | todo (WP4) | none |
| [wheel-dust.md](../features/wheel-dust.md) | visual review (seeded stream `wheel_particles`) | todo | Loose perceptual diff |
| [world-session.md](../features/world-session.md) | save round-trip (world block); golden replay (seeded `world` stream) | todo (WP4) | none |

## Per-frame and threaded systems under a golden replay (the 1.1 audit)

Every `_process`, `process_frame` hook and worker-thread user, and why each one can't make two golden replays
differ. "Present only" means it draws, plays sound or reads input for the camera and never feeds the sim, so a
Rust port may run it at its own frame rate. "Game state" ran per frame and was moved onto the physics tick.
"Streaming" finishes inside the frame under `Benchmark.golden`. The traces run headless with `--fixed-fps 60`,
so `_process` runs once per tick anyway; the tick moves are what keep normal play frame-rate independent.

| System | What runs per frame or on a worker | Kind | Under a golden replay |
|---|---|---|---|
| `scripts/camera_manager.gd` | camera cycle input | present only | no sim effect |
| `scripts/car_card_preview.gd` | menu card spin | present only | no sim effect |
| `scripts/display_stretch.gd` | window scaling | present only | no sim effect |
| `scripts/engine_audio.gd` | engine synth feed | present only | headless has no audio; the synth is seeded (`_rng.seed = 1`) |
| `scripts/engine_audio_feed.gd` | `Thread` filling the audio buffer | present only | no sim effect |
| `scripts/hud.gd` | dials and readouts | present only | no sim effect |
| `scripts/level_minimap.gd` | minimap draw | present only | no sim effect |
| `scripts/level_stats.gd` | wall-clock stats | present only | measurement only |
| `scripts/loading_screen.gd` | loading cover | present only | no sim effect |
| `scripts/mobile_controls.gd` | touch buttons | present only | inactive headless; touch flow covers it (WP7) |
| `scripts/npc_dialogue.gd` | typewriter text | present only | no sim effect |
| `scripts/perf_log.gd` | `PerfLog.track` brackets | present only | measurement only |
| `scripts/photo_mode.gd`, `scripts/photo_mode_controls.gd` | photo camera | present only | never opened in a replay |
| `scripts/post_process_view.gd` | post-process quad | present only | no sim effect |
| `scripts/route_arrow.gd` | nav arrow | present only | no sim effect |
| `scripts/speed_lines.gd` | speed lines | present only | no sim effect |
| `scripts/teleport_beacons.gd` | beacon animation | present only | no sim effect |
| `scripts/web_fullscreen.gd` | fullscreen prompt | present only | hidden under `Benchmark.active` |
| `scripts/level_trees.gd` → `_process` / `_step_falls` | felled tree card falling | present only | the hitbox is already off in `knock_down` |
| `scripts/level_view.gd` → `_process` | nav beam, delivery and cargo labels, conflict prompt | present only | conflict prompt skipped under `Benchmark.active` |
| `scripts/level_view.gd` → `process_frame` hooks | `_sync_mouse`, `_place_service_prompt`, `_place_money`, `_orbit_step`, `_follow_photo_cam` | present only | no sim effect |
| `scripts/level_map.gd` → `_process` | panning, painter poll | present only | map stays closed |
| `scripts/level_map.gd` | painter `Thread` | present only | no sim effect |
| `scripts/music_director.gd` → `_process` | music grid on `_audio_now` | game state (traced by 1.4) | clock is `Engine.get_physics_frames()` under `golden` |
| `scripts/level_weather.gd` | `drive_time`, wanted weather | game state | moved to `_physics_process`; `_process` keeps only the fade |
| `scripts/level_view.gd` | `_check_delivery`, delivery mass | game state | moved to `_timed_physics_process` |
| `scripts/level_view.gd` | pose-save `Timer`, wreck-page timer | game state | both process in physics |
| `scripts/level_spectators.gd` | placement, refresh timer | game state | moved to `_timed_physics_process` |
| `scripts/level_map.gd` → `_physics_process` | discovery reveal (`reveal_at_car`) | game state | moved onto the tick |
| `scripts/spectator_group.gd` | sim stagger | game state | per-group `_ticks` counter instead of the absolute frame count |
| `scripts/level_streamer.gd` → `_process` | chunk plan and builds (`WorkerThreadPool`) | streaming | `_clock_us` frame clock; `threaded_chunk_build` off; drains every frame; `prefill_async` fills in one go |
| `scripts/ground_cover.gd` | tile jobs (`WorkerThreadPool`) | streaming | same flag off; `_settle_cover` drains |
| `scripts/level_trees.gd` | tile repacks and hitboxes (`WorkerThreadPool`) | streaming | `threaded_tree_build` off; builds every due tile, then `settle()` |
| `scripts/level_spectators.gd` | crowd placement (`WorkerThreadPool`) | streaming | `_threaded()` false under `golden`, so placement is inline |
| `scripts/spectator_group.gd` → `_steer_wide` | steering group task | streaming | off by default (`threaded_spectators`); golden uses the serial loop |
| `scripts/level_view.gd` → `load_level` | bake `Thread` | streaming | only with no bake and not headless, so never in a golden run |
| physics server | `3d/run_on_separate_thread` | streaming | turned off by the `override.cfg` `--golden-check` writes |
| `scripts/cloud/cloud_manager.gd`, `scripts/adaptive/adaptive_graphics.gd` | cloud sync, adaptive knobs | ruled out | cloud returns early headless and never syncs under `Benchmark.active`; adaptive is off under `Benchmark.active` |
