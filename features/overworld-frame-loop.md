# Overworld frame loop — `_process_stages` and the shared `WorldRuntime` leaves

**Source:** `scripts/overworld.gd` (`Overworld._process`, `_process_stages`,
`_log_frame_spike`), `scripts/world_runtime.gd` (`class_name WorldRuntime`).

**Tests:** `tests/headless/test_overworld.gd`, `tests/headless/test_world_runtime.gd`

Split out of [overworld.md](overworld.md) (which stayed on the oversized-doc baseline in
`tests/headless/test_features_docs.gd`) because the per-frame sequence and the leaf helpers it
shares with `world.gd` are a self-contained topic.

## `WorldRuntime` — the shared leaf helpers

`main.tscn`'s host (`world.gd`) and `overworld.tscn`'s host (`overworld.gd`) share several
behaviours that are now literally the same code: the leaf helpers live in
`scripts/world_runtime.gd` (`class_name WorldRuntime`, all statics) — `loading_cap` +
`apply_fps_cap`, `apply_deep_snow`, `layers_match`, `yield_frame`, `warm_up_point`, and the
`TERRAIN_BASE_SHADER` / `TERRAIN_SNOW_SHADER` and `LOADING_MAX_FPS` / `LOADING_TOUCH_MAX_FPS`
consts. It is a static module rather than a common base class deliberately: a base class would
change the scene↔script relationship for both `main.tscn` and `overworld.tscn` while only these
leaves are actually common. Each host keeps its thin wrapper (`_apply_fps_cap`,
`_apply_deep_snow_ground`, `_yield_frame`, `_warm_up_point`) because they differ in how they
reach their floor material and their car — the `_warm_up_point` FALLBACK is the deliberate
divergence (an authored `$Car` in `world.gd`, a by-name lookup in `overworld.gd`).

## The per-frame pass — one sequence

`Overworld._process` does no per-frame work of its own: it calls `_process_stages(cfg, delta)`
(**the** definition of the sequence — region look, fog boundary, foliage streaming, cache
eviction, zones), then `_log_frame_spike(delta)` and `_track_pause_menu()`.

There used to be TWO copies of that sequence — a timed one inlined in `_process` and an untimed
one in `_process_stages` — with a comment asking whoever added a stage to add it to both. A
stage added to one silently did not run on the other path. The spike timing is now a
side-channel written *into* the single sequence: `_process_stages` stamps `_spike_us[0..5]` at
each stage boundary, but only when `_spike_log` is armed (`SettingsMenu.dev_tools_enabled()`, non-headless,
`OVERWORLD_SPIKE_LOG != 0`), and `_log_frame_spike` reads the stamps from there instead of
taking them as arguments.

⚠️ **Do not "tidy" that into an array of Callables or a timings dict.** `_spike_us` is a
PackedInt64Array preallocated once at declaration precisely so the shipping path allocates
NOTHING per frame; the `if _spike_log` guards are one test of an already-cached bool per
boundary (constant for the whole run, so perfectly predicted). This hot path runs on the oldest
phones we support. The guard test `test_each_per_frame_stage_is_called_from_exactly_one_place`
in `tests/headless/test_overworld.gd` fails if a second copy of the sequence reappears.
