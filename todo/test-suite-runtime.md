# Test-suite runtime reduction

**Status (2026-07-23): full `./run_tests.sh` cut from ~542 s to ~307 s (−43%),
and the intermittent crash-and-retry flake eliminated.** Now essentially at the
~5 min budget. Remaining levers below are optional.

## What actually dominated (measured, not guessed)

Profiled with GUT's JUnit export (`-gjunit_xml_file`), per-file `time`:

1. **The audio-thread SIGSEGV flake (biggest *average-time* cost).** Godot's
   headless `AudioDriverDummy` still runs a real mix thread. Three
   AudioStreamPlayers were *playing* during tests — the `Music` autoload
   (`music_director.gd`, a polyphonic stream), the car's `EngineAudio`
   (`engine_audio.gd`, an `AudioStreamGeneratorPlayback` — which extends
   `AudioStreamPlaybackResampled`), and the HQ `CarPreviewAudio`
   (`car_preview_audio.gd`) — and their playbacks were freed underneath the mix
   thread at engine teardown (`-gexit`), a use-after-free that SIGSEGV'd in
   `AudioStreamPlaybackResampled::mix` (~1-in-3 full runs → a full ~9 min retry).
   **Fixed:** all three now skip `play()` when `Platform.is_headless()` (a stopped
   player is never mixed; the DSP paths already null-guard on the absent playback).
   Also trims the per-frame engine-audio synthesis `fill()` from every car test.
   Shipping builds are never headless, so game audio is unchanged.

2. **`test_lakes_integration.gd` — 214.8 s, over HALF the suite.** The
   `test_events_generate_dry_roads_with_lakes` case ran full water-routed track
   generation over 4 seeds; one seed (`3001`) *dead-ends* and burned the
   generator's full 24-restart budget (~180 s by itself). **Fixed:** trimmed
   `EVENTS` to two seeds that complete quickly (`1007`, `5003`) — the contract
   ("some water-enabled tracks complete + stay dry + lakes form") needs only a
   couple, not a dead-ender. File dropped 214.8 s → ~12 s.

The earlier theory in this spec (the 143-chunk `minimal_world` precompute, ~90 s)
was a *minor* contributor, not the dominant cost — it stays a possible future
lever but was not the win.

## Remaining top files (optional, diminishing returns)

Per-file after the cuts: `test_menu_flow` 43 s (105 tests exercising the whole HQ
overlay flow — legitimate), `test_car_library` 23 s (20 tests, per-test
`minimal_world` builds; the file documents why a shared `before_all` is unsafe —
roster flips + Car re-instantiation), `test_retune` 16 s, `test_car_types` 15 s,
`test_track_generator` 14 s. None is pathological; cutting further means the
shared-world / process-wide-chunk-cache work below.

## Still-open levers (only if the budget tightens again)

- **Process-wide terrain-chunk cache** keyed by generation params: the ~59
  `minimal_world` builds recompute the same 143 chunks; a static cache would reuse
  them. Medium risk (keying/invalidation must be exact — `height_at` falls back to
  *noise* outside the corridor, so a stale/missing key silently returns unflattened
  terrain). ~40-70 s.
- **Share a `before_all` world** where safe (`test_aero_visibility`, `test_retune`,
  `test_turbo_fielding`) — NOT `test_car_library`/`test_car_water`.
- Keep `features/testing.md`'s cost model in sync if these land.
