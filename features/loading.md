# Loading — the stage-load pipeline

Where world generation time goes, how it is measured, and what is freed when it
finishes. Start here before optimising load time.

Related: `terrain.md` (chunk cache, carve), `track.md` (the DFS search),
`rendering.md` (shader pre-warm), `testing.md` (why tests avoid full generation).

## The pipeline

`world.gd::_ready` puts a `LoadingScreen` up, then `await _generate_track(cfg, loading)`
runs the whole build behind it. The stages, in order:

| stage label | what it does | where |
|---|---|---|
| Building terrain | `TerrainManager.build_initial()` — the 7x7 ring, pulled from the cache | `terrain_manager.gd` |
| Generating track | DFS corner search — **skipped when a cached stage exists** | `track_generator.gd::generate` / `TrackCache` |
| Carving road into terrain | unified cliff/road distance-field pass | `terrain_manager.gd::bake_track` |
| Precomputing chunks | per-chunk grid + LOD prebake over the corridor | `terrain_manager.gd::cache_chunk` |
| Scattering trees / bushes | foliage scatter + road-footprint rasterisation | `world.gd::_build_foliage` |
| Filling lakes | basin flood + water texture bake | `world.gd::_build_lakes` |
| Placing signs | roadside turn arrows (~16–22 per stage) | `world.gd::_build_signs` |
| Placing props | spectators, arches, opponent wreck, persistent managers | `world.gd::_generate_track` |
| Warming shaders | surface-FX warm-up + `_prewarm_corridor` | `world.gd::_prewarm_corridor` |

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
built world within `_ready`.

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
(`LOADING_MAX_FPS = 0` on non-touch, `LOADING_TOUCH_MAX_FPS = 60` on touch), and the
player's real cap is applied on the line **after** `_end_load_timing()` in `_ready`.

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
