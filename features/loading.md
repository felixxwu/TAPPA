# Loading — the stage-load pipeline

Where world generation time goes, how it is measured, and what is freed when it
finishes. Start here before optimising load time.

Related: `terrain.md` (chunk cache, carve), `track.md` (the DFS search),
`rendering.md` (shader pre-warm), `testing.md` (why tests avoid full generation).

**Tests:** `tests/headless/test_loading_screen.gd`, `tests/headless/test_loading_tips.gd`, `tests/headless/test_stage_manager.gd`

## The pipeline

`world.gd::_ready` puts a `LoadingScreen` up, then `await _generate_track(cfg, loading)`
runs the whole build behind it. The stages, in order:

`_generate_track` is now the PHASE SEQUENCE only — it takes the car freeze, then awaits one
private coroutine per phase, each named after the load-stage label it opens:
`_generate_centerline` → `_carve_road_into_terrain` → `_build_terrain_ring` → (car unfrozen)
→ `_place_world_props` → `_warm_shaders_behind_cover`. Phase 1 returns the shape contract
(`result`, `road_centerline`, `finish_len`, `start_pos`, `start_heading`, `staged`,
`water_bounds`) the later phases read. `_ready` is split the same way:
`_apply_scene_config` → `_field_player_car` → `await _generate_track` →
`await _wire_session_and_stage` → `_build_overlays_and_benchmark`. The awaiting order is
identical to when all of this ran inline; only the nesting changed. `_interactive(loading)`
is the single definition of "an overlay is up AND we're not headless", shared by the phases.

| stage label | what it does | where |
|---|---|---|
| Building terrain | `TerrainManager.build_initial()` — the 7x7 ring, pulled from the cache | `terrain_manager.gd` |
| Generating track | DFS corner search — **skipped when a cached stage exists** | `track_generator.gd::generate` / `TrackCache` |
| Carving road into terrain | unified cliff/road distance-field pass, then the **final preview water repaint** — the first one sampled from the baked (cliff-dropped) terrain rather than pure noise, placed here so it shows through the precompute below (see [lakes.md](lakes.md) → "Three water passes") | `terrain_manager.gd::bake_track` |
| Precomputing chunks | per-chunk grid + LOD prebake over the corridor | `terrain_manager.gd::cache_chunk` |
| Scattering trees / bushes | foliage scatter + road-footprint rasterisation | `world.gd::_build_foliage` |
| Filling lakes | basin flood + water texture bake | `world.gd::_build_lakes` |
| Placing signs | roadside turn arrows (~16–22 per stage) | `world.gd::_build_signs` |
| Placing props | spectators, arches, opponent wreck, persistent managers | `world.gd::_generate_track` |
| Warming shaders | surface-FX warm-up + `_prewarm_corridor` | `world.gd::_prewarm_corridor` |

**These stage labels are perf-log-only.** `_stage(label)` still `print()`s each one (with
timing) for the "load stage: … ms" log — that's what the table above documents — but it no
longer reaches the player. `LoadingScreen`'s visible line is a random pick from
`LoadingTips.TIPS` (`scripts/loading_tips.gd`), drawn once in `_init()` and shown for the
whole load; the player doesn't need to know the game is "Placing signs…". Each tip is a
short, standalone gameplay fact (aero balance, turbo lag, engine swaps, …) verified against
the mechanic it names — every entry must read correctly in ISOLATION, since the player only
ever sees one. `_build_lakes` / `_build_foliage` / `_build_signs` dropped their now-unused
`loading: LoadingScreen` parameters when the forwarding call was removed.

Other `LoadingScreen` users (`hq.gd`, `hq_challenge.gd`) build their own instance for a
menu-transition wait and call `set_step()` on it directly with their own short status text
("Preparing the garage…") — that path is unrelated and unchanged; only world.gd's
generation stages stopped forwarding to the label.

## The stage counter

`world.gd::_ready` calls `LoadingScreen.set_stage(index, total)` right after
`DrivingContext.apply_stage_config` has seated the live stage, before any generation
starts. That swaps the headline for `"Loading stage 2 of 3…"` (uppercased by
`UITheme.caps` like every other loading line), so a multi-stage rally tells the player how
far through it they are while they wait.

`total` is the RALLY'S OWN stage count (`RallySession.stage_count`), **not** a constant 3:
the opening rallies run a single stage (`todo/opening-rally.md`). A total of 1 or less is a
no-op and keeps the default headline — "stage 1 of 1" is noise, and implies a series that
is not there. The index is clamped, because it comes from live session state that sits AT
the total once the last stage is done.

This line used to carry a **wet-stage tell** instead (`set_weather` → `"Loading stage…
rain"`). The two cannot share the headline — with weather owning it, the stage number could
only ever have shown on dry stages — so the tell and its `loading_tell` weather-table field
were both removed. Weather still announces itself in the world; see `weather.md`, and
`rendering.md` for the in-stage look.

## Measuring it

`_stage(loading, label)` opens a stage and **closes the previous one**, printing
`load stage: <label> <ms>`. `_end_load_timing()` closes the last stage and prints
`load total:`. Both are silent under `--headless`.

> **A stage's cost is everything between its label and the NEXT label.** Work added
> after a `_stage()` call is billed to that stage, not to itself. This previously made
> "Placing signs" look like a 6-second stage on web when it was absorbing the props and
> the shader pre-warm; the "Placing props" and "Warming shaders" boundaries exist to stop
> that. **If you add a slow step, give it a label** or you will mis-attribute it.

`_yield_frame()` collapses to a synchronous no-op under headless, so tests see a fully
built world within `_ready`. Its body is `WorldRuntime.yield_frame(get_tree(), _headless)`,
shared with `overworld.gd`.

## The car is frozen for the whole window

`_generate_track` sets `$Car.freeze = true` on entry and restores the previous value
immediately after `$Floor.build_initial()`. `_ready`'s `controls_locked` only stops the
player *driving*; the body itself simulates across every awaited frame below, and from
the start of generation until `build_initial()` there is deliberately **no terrain under
it** (see `terrain.md` → *Who builds the initial ring*). Without the freeze the car falls
for the length of the load. With it, the car drops onto carved, flattened ground with
several hundred ms of covered frames left to settle before `_build_start_line` or the
player sees it.

If you add work between those two points, do not assume the car is on the ground there.

## Frame cap during load

`world.gd::_apply_fps_cap()` applies a **loading-phase** cap during generation
(`WorldRuntime.loading_cap(touch)`), and the player's real cap is applied on the line
**after** `_end_load_timing()` in `_ready`.

**The two caps are GameConfig fields** — `loading_max_fps` (non-touch) and
`loading_touch_max_fps` (touch/web), authored in `config/game_config.tres` and read by
`loading_cap`. `WorldRuntime.LOADING_MAX_FPS` / `LOADING_TOUCH_MAX_FPS` remain as the
fallback defaults only, so retuning a const alone changes nothing; see
[configuration.md](configuration.md) → *Loading*.

The cap-applying logic lives in `scripts/world_runtime.gd`
(`WorldRuntime.apply_fps_cap`, `WorldRuntime.loading_cap`), shared with `overworld.gd` — the
two world hosts used to carry byte-identical copies. Each host keeps a thin `_apply_fps_cap`
wrapper that passes its own `applied_fps_caps` array and headless flag, so the recorded
intent (and the tests reading it) are unchanged. ⚠️ The two cap consts are loading-time
TUNING values and carry a `TODO(config)` to move into `GameConfig` / `game_config.tres`.

Why it matters, measured on a real web export at the web-touch branch:

```
max_fps=30  100 x await process_frame = 3341.9 ms  (33.42 ms/frame)
max_fps=0   100 x await process_frame =  833.5 ms  ( 8.34 ms/frame)
```

The limiter is exact to within 0.3%, so **every awaited frame during generation costs a
full frame period** at a 30 fps cap. Generation awaits hundreds of frames.

The loading cap is bounded rather than uncapped on touch: running a phone flat-out for a
long load is a thermal/battery problem that then throttles gameplay. It is skipped
entirely when `Benchmark.active`, because `benchmark_mode.gd` snapshots `Engine.max_fps`
into `_saved_max_fps` and a transient value must never land there.

> When measuring this in a browser, **keep the tab foregrounded** — Chrome suspends
> `requestAnimationFrame` in a background tab, which freezes the Godot main loop and
> produces junk samples in the hundreds of ms per frame.

> **Where the idle actually lands.** Each `await` idles for the *remainder* of the frame
> budget, so the cost is near zero where the work between yields is heavy (the carve, and
> full-res chunk batches) and near a full frame where it is cheap — above all the DFS,
> which yields every 2 search steps. Any per-stage timing captured under a cap is
> distorted unevenly, not uniformly. See `todo/mobile-web-performance.md` item 1.1.

## Cached vs live generation

A **rally stage** (`RallySession.current_event()` non-empty) resolves through
`TrackCache` and **skips the DFS entirely**. The `for_config` path
(`generate_optional_cached`) also hits the lockfile for the **benchmark stage** and the
**default-config boot**, which are baked.

> **Free roam is unbakeable and always pays the live DFS.**
> `hq.gd::_prepare_free_roam` randomises `track_seed`, `track_water_level_m` *and*
> `terrain_layer1_amplitude` on every entry, and all three feed the cache key — so it
> misses by construction. This is a gameplay decision (fresh terrain each time), not an
> oversight. A career load and a free-roam load therefore have materially different
> profiles: **always say which one you measured.**

`data/track_cache.json` is the lockfile; `TrackCache.CACHE_VERSION` plus
`TrackGenerator.constants_fingerprint()` invalidate it. Regenerate with `./cache_all.sh`.

## The `load_finished` hook

`world.gd` emits **`load_finished`** once, from `_on_load_finished()`, called in `_ready`
immediately after `_end_load_timing()`. Subscribers free load-only data.

> **It is deliberately NOT inside `_end_load_timing()`**, which early-returns on
> `_headless or _stage_label == ""` — a hook placed there would never fire for the test
> runner. `_on_load_finished()` is unconditional and latches on `_load_finished`, so a
> later regeneration cannot double-free.

Covered by `tests/headless/test_load_finished.gd`.

### Subscribers

`TerrainManager.free_load_only_data()` is the first and largest — it drops the baked
terrain light and the road/cliff bake dictionaries (see `terrain.md` → *What the cache
keeps — and what is freed*). It duck-types onto the parent's signal rather than requiring
`world.gd` to know about it.

> ### ⚠️ Latch on the DATA, not on the event
>
> `world.gd`'s `_load_finished` latch stops the signal re-firing. That is correct for the
> signal, but a subscriber **must not** treat "I have freed once" as permanent:
> `_generate_track` can run a **second time** on a booted world (a programmatic
> regeneration — `test_smoke` does exactly this), which rebuilds the very data that was
> freed while the signal stays latched.
>
> A naive one-way "freed" flag therefore poisons every subsequent read for the rest of
> the run. `TerrainManager` gets this right by clearing its freed-flags where the data is
> rebuilt (`set_corridor()` for the chunk light, `bake_track()` for the bake fields).
>
> This was caught by a sentinel that `push_error`s on a post-free read, not by reasoning
> — **if you add a subscriber that frees something, add the sentinel too.** The failure
> mode without one is silent wrong data, not a crash.

## Cost model, in one line

Full generation is ~15 s under headless, dominated by the DFS search and the two foliage
scatters — which is why tests use `SceneTestHelpers.minimal_world()` (1-turn track, no
foliage, <1 s) unless they genuinely assert on the track or terrain. See `testing.md`.
