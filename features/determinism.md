# Determinism (seeded random streams)

**Source:** `scripts/rng_streams.gd` (`RngStreams`).

**Tests:** `tests/headless/test_rng_streams.gd`, `tests/headless/test_no_global_rng.gd`

Every random draw in game code comes from a named `RandomNumberGenerator` stream seeded off one
`RngStreams.game_seed`, so a replay run with the same seed draws exactly the same numbers. This is
step 2 of `todo/2026-11-28-phase-1-1-determinism-plan.md` (Phase 1.1 of the Rust migration).

- **`game_seed`** comes from `--seed=N` among the user args (after `--`), else a random seed per boot,
  so normal play still varies (weather, misfires, world seed).
- **`make(name, id := 0)`** returns a fresh generator seeded with
  `fnv1a32("<game_seed>/<name>/<id>")`. The same triple always draws the same numbers. Instance
  owners keep their own: `DamageModel` (`"damage"`, wheel toe in `nudge_wheels`), `EngineSim`
  (`"engine"`, misfires), `DustPuffs`, `WheelParticles` (passed into the static `_jittered`),
  `EngineSmoke`, `ExhaustFlames` (frame picking), `CloudSync` (backoff jitter). One-off draws:
  `LevelWeather.attach` (`"weather"`, the drift seed) and `title_boot.gd` (`"world"`, the new world's seed).
- **`shared(name)`** caches one stream per name for static callers: `LoadingTips._pick_avoiding`
  (`"loading_tips"`), `MusicLibrary._random_from_pool` (`"music"`).
- **`reseed(s)`** sets `game_seed` and forgets every cached and live stream. Generators already
  handed out keep their old seed, so a replay must reseed before it builds the level (the replay
  harness reseeds with `Benchmark.RNG_SEED`; see [benchmark.md](benchmark.md)).
- **`live_states()`** returns `{"name/id#n": state}` for every stream still alive (`n` counts
  repeat makes of one stream, e.g. one engine per car), which the golden replay trace dumps per tick.
- **`fnv1a32(text)`** is FNV-1a 32 over the UTF-8 bytes, masked to 32 bits each step so a Rust port
  can copy it exactly. `ExhaustFlames.build_frames` seeds its frame images with it instead of
  Godot's `hash()`.

Already-seeded local generators (`ground_cover.build_tuft`, `log_pile.build`, `level_spectators`,
`SpectatorGroup`, the dust-puff blob, `EngineAudioSynth`) need no stream. `test_no_global_rng.gd`
scans `scripts/` and fails on a global `randf()`/`randi()`/`randomize()`/`seed()` call, on
`.shuffle()` / `.pick_random()`, and on a `var x := RandomNumberGenerator.new()` whose file never
sets `x.seed =` or `x.state =`.

## Threads finishing on a wall-clock frame

A background thread's result must not change game state on "whichever frame it finished": that frame
depends on CPU load, so two replays diverge (the `--golden-check` B run is under `yes` load for this).
Example fixed in November 2026: `LevelMap` paints its image on a thread (`_painter`), and the
minimap only shows once `LevelMap.build()` has uploaded it (`LevelMinimap._tick` gates on
`map._texture`). Each minimap redraw calls `LevelMap.reveal_at_car`, which stamps discovery and
moves the `_revealed_at` gate, so the map's own `REVEAL_TICK_S` stamps shift too. Headless skips
`LevelView._warm_up` (where `build()` used to be the only load-time call), so the texture appeared
when `_timed_process` noticed the thread had ended, and the `discovered` event landed on different
ticks between runs (only on CI's 2-core runners). `LevelView` now calls `map.build()` after the
warm-up in every mode, which waits for the painter before the level reports loaded.
