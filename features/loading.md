# Loading — the level-load pipeline

Where the level's load time goes, how it is measured, and what the loading cover shows.
Start here before optimising load time.

Related: [level-streamer.md](level-streamer.md) (the tile streaming),
`rendering.md` (shader pre-warm), `testing.md` (why tests avoid the real level).

**Tests:** `tests/headless/test_loading_screen.gd`, `tests/headless/test_loading_tips.gd`

## The pipeline

`level_view.gd` → `_ready` runs the whole load behind the `LoadingScreen`. In order:

| step | what it does | `load_ms` key |
|---|---|---|
| Parse | reads the level JSON (`GameConfig.level_path`) | `parse` |
| Build | `load_level` — the baked ground, buildings, props, streamer | `built` |
| Field the car | restores the saved car and pose (`restore_saved_car`, `saved_pose`) | — |
| Prefill | `LevelStreamer.prefill_async` streams in the tiles around the car | `prefill` |
| Effects | `_add_effects` (dust, smoke, tyre marks, flames, lamps, shadow) | — |
| Warm-up | `_warm_up` compiles shaders behind the cover (skipped headless) | `warm_up` |

Each step `print()`s its time (`level view: … ms`) and lands in `LevelView.load_ms`, which the
benchmark report reads. `loaded` is emitted once the level is up.

`LoadingScreen`'s visible line is never the build step: it is a random pick from
`LoadingTips.TIPS` (`scripts/loading_tips.gd`), drawn once in `_init()` and then **cycled
to a fresh draw every 7 seconds** (`LoadingScreen._TIP_CYCLE_SEC`) for as long as the
overlay is up, so a long load doesn't sit on one sentence for its whole duration. Each tip
is a short, standalone gameplay fact about the Hafren level (the free Shop and Garage, turbo lag, snow grip, the map teleport, …) verified
against the mechanic it names — every entry must read correctly in ISOLATION, since the
player only ever sees one at a time.

**Pinned headline** (`LoadingScreen.pin_title`, via `Scenes.change_to(tree, path, cover_title)`): names why
the load is happening, and later `set_title()` calls leave it in place.

`set_step()` **locks** the step line (`_step_locked`) so the
7-second tip cycle never overwrites a caller's own status text.

The headline's trailing ellipsis is **animated** (0 → 1 → 2 → 3 dots, looping on
`LoadingScreen._DOT_STEP_SEC`) rather than a static "…". Because the headline is
center-aligned, the dots live in a **sibling label** (`_dots`) with a `custom_minimum_size`
pinned (once, in `_init`) to the pixel width of `_MAX_DOTS` "." glyphs, measured directly
from `UITheme.font()` — the label's text itself just holds the visible dots (0 to
`_MAX_DOTS`, no padding). Sizing off a measured pixel width rather than a fixed character
count means this holds even though the UI font (Jersey10) is **not** monospace — an earlier
version relied on monospace character padding and visibly shifted the headline when the UI
font changed away from the old (monospace) Syne Mono. `set_title()` strips a trailing "…"
from the supplied text so the static character and the animated dots don't stack.

## Frame cap during load

`level_view.gd` → `_ready` applies a **loading-phase** cap before the build
(`WorldRuntime.loading_cap(touch)`) and the player's real cap (`FpsSetting.resolve()`) once the
warm-up is done, both through `WorldRuntime.apply_fps_cap`.

**The two caps are GameConfig fields** — `loading_max_fps` (non-touch) and
`loading_touch_max_fps` (touch/web), authored in `scripts/game_config.gd` and read by
`loading_cap`; see
[configuration.md](configuration.md) → *Loading*.

`applied_fps_caps` records each cap applied, so tests can read the intent.

Why it matters, measured on a real web export at the web-touch branch:

```
max_fps=30  100 x await process_frame = 3341.9 ms  (33.42 ms/frame)
max_fps=0   100 x await process_frame =  833.5 ms  ( 8.34 ms/frame)
```

The limiter is exact to within 0.3%, so **every awaited frame during the load costs a
full frame period** at a 30 fps cap. The load awaits hundreds of frames.

The loading cap is bounded rather than uncapped on touch: running a phone flat-out for a
long load is a thermal/battery problem that then throttles gameplay. It is skipped
entirely when `Benchmark.active`, because `benchmark_mode.gd` snapshots `Engine.max_fps`
into `_saved_max_fps` and a transient value must never land there.

> When measuring this in a browser, **keep the tab foregrounded** — Chrome suspends
> `requestAnimationFrame` in a background tab, which freezes the Godot main loop and
> produces junk samples in the hundreds of ms per frame.

## Cost model, in one line

Tests never load the real level: they use `SceneTestHelpers.add_level_world()`, a tiny flat
level that loads in well under a second. See `testing.md`.
