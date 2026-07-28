# Mobile + Web Performance Spec

> Scope: wins available for the **mobile and web export targets** — download size,
> cold start, stage-load time, in-race frame cost, and resident memory.
>
> Source: a five-agent read-only audit of the codebase (2026-07-28) covering
> load-time world generation, per-frame runtime cost, GPU/render configuration,
> build size, and memory/web-platform behaviour. Every headline claim in Tier 1
> was independently re-verified against the code before this spec was written;
> items marked *(estimated)* are derived from array shapes and config values, not
> from a profiler run.
>
> **Relationship to `todo/performance-optimisations.md`:** that spec remains the
> deep-dive on the carve/cliff distance-field work and the chunk precompute, and its
> "done" sections are accurate history. Its measured per-stage table is **partially**
> contaminated by item 1.1 below: the **track-generation** number is badly affected (and
> that stage is free-roam-only), while **carve, precompute, scatter and lakes are roughly
> sound** and remain valid targets. A matching correction header has been added there.
>
> **Cross-reference:** `todo/web-save-persistence.md` covers the save-flush
> correctness bug — now **in scope for this work** as a release blocker, see §5.1.
> `todo/audio.md` covers audio buffer tuning, which interacts with §2.1.

---

## Implementation status (2026-07-28)

Execution is following `todo/mobile-web-performance-plan.md`.

| item | status |
|---|---|
| 1.2 stage boundaries | ✅ landed (+ `features/loading.md` created) |
| shared `load_finished` hook + tier config fields | ✅ landed (plan Wave 0) |
| 1.3 wasm compression | ✅ **resolved as a non-issue — the win never existed.** See the item. |
| 5.1 / 1.0 web save flush | ✅ landed — **manual browser verification still outstanding** |
| 2.1 engine synth | ✅ landed; `game_config.tres` now sets the web-touch rate to 11025 |
| 2.2 centerline lookup | ✅ landed — **the ±3 m "cheap version" this spec recommended was rejected**; see the item |
| 2.14 HQ premise | ⚠️ **inverted by measurement** — mesh duplication is negligible (~26 KB/prop); the cost is `_prewarm_free_roam` at ~3x the rest of HQ boot |
| 2.5 lake water texture | ✅ landed (committed asset, per-pixel verified) |
| 2.8 fingerprint memo | ✅ landed (mtime-keyed, self-invalidating) |
| 2.11 lazy music | ✅ landed |
| 2.14 HQ | ✅ instrumented — **and the finding inverts the item's premise**; see it |
| 1.6 / 1.7 / 2.7 / 2.9-terrain | ✅ landed — chunk cache **226 KB → ~30 KB per chunk** (46.2 → 9.2 MB). 2.7's estimate was **3–4x too high**; see the item. |
| 1.1 / 2.3 / 2.4 / 2.6 | ✅ landed — **Step 0 confirmed the premise on a real web export (33.4 vs 8.3 ms/frame)**. 2.3+2.4 proved output-identical across all 39 events, so **no `CACHE_VERSION` bump was needed**. 2.6's free-roam premise was wrong; see the item. |
| 1.4 / 1.5 / 2.10 / §4 knobs | ✅ landed — **PCK 17.35 MB → 7.61 MB (−56.1%)**, measured by parsing the pack directory |
| Wave E items, deferred items | not started |

## How to use this spec

Three tiers, ordered by effort-to-value, not by subsystem:

- **Tier 1** — small, high-confidence, several of them unblocking. Do these first.
  > **Note on 1.1's placement.** After its correction (see the item), 1.1's career-mode
  > win is order 1–2 s, which is *less* than **2.5** (~1.0 s off every career load, S) or
  > **2.1 step 1** (halves the largest per-frame script cost, S). 1.1 stays in Tier 1 for
  > **prerequisite and correctness reasons** — nothing else's measurement can be trusted
  > until it lands, and a 30 fps cap over a long load is wrong regardless — **not because
  > it is the highest-value item.** If you want value first, do **1.0 (saves), 2.5, and
  > 2.1 step 1** immediately after 1.1's five-minute Step 0.
- **Tier 2** — real CPU and size wins, mostly mechanical, low behavioural risk.
- **Tier 3** — larger changes, some needing a design or feel judgement.

Effort ratings are S (a sitting), M (a session), L (a project).

> **Decision (2026-07-28) — no *performance-profile* gates.** The user will benchmark on
> real hardware *after* the work lands. Do not block an item waiting for a profile to
> justify it; implement on the merits of the code reading. Where a number here is marked
> *(estimated)* that is a confidence note, not a prerequisite. The two cheap
> instrumentation one-liners (dictionary sizes in 2.7, `RENDER_VIDEO_MEM_USED` in 3.6)
> should land *alongside* their items to make the post-hoc measurement easy.
>
> **This does not remove correctness checks.** Three kinds of check remain mandatory and
> are called out on the items that carry them:
> - **Correctness re-measurement** where a number is the deliverable — 1.2 exists purely
>   to make the stage timings truthful.
> - **Visual verification** where a build could look wrong — 1.5, 2.5, 2.10, 3.1.
> - **Feel verification** where the car's handling could change — 3.3, and 2.2 via
>   progress/split timing.
>
> These are qualitative sanity checks, not profiling. Do not skip them.

### Test policy for every item in this spec

`CLAUDE.md` requires tests in the same piece of work, and constrains them hard. For this
spec that means:

- **Never assert a tunable value.** Do not write `assert cap == 30`,
  `assert mix_rate == 11025`, or `assert resolution == Vector2(320, 240)`. Every number
  in this spec is a knob the user intends to retune on real hardware — pinning one
  guarantees a broken test later.
- **Assert the behaviour instead.** "The applied cap equals whatever `FpsSetting.resolve()`
  returns", "the `(web and touch)` branch selects the low tier and every other platform
  selects the high tier", "the baked-offset lookup agrees with `sample_baked` within
  tolerance".
- Catalogue-dependent tests use `CarFixtures.install()`; never reach for a specific
  car/engine/rally by id.
- Prefer `SceneTestHelpers.minimal_world()` over full generation, and mind the ~5 minute
  suite budget (`features/testing.md`).

Items below carry a **Test:** line where they change behaviour. Items with no Test line
are genuinely inert (config/asset/doc changes) and say so.

---

# Tier 1 — do first

> **1.0 — web save persistence is the highest-priority item in this spec.** It is a
> release blocker and it is *not* a performance item, so it lives in §5.1 with the other
> correctness findings. Do it **before** anything below. Effort **M**. Working the tiers
> top-down without reading §5.1 would leave it until last, which is exactly backwards:
> every hour of performance work is worthless on a build that silently loses the
> player's career progress.

## 1.1 Don't cap FPS during world generation

**File:** `scripts/world.gd` → `_ready` (the `Engine.max_fps = fps_cap` assignment,
guarded by `Platform.is_headless()`), plus the yield sites listed below.

`_ready` resolves `fps_cap` (via `FpsSetting.resolve()`, which returns **30 on
web-touch**) and applies it to `Engine.max_fps` **before** `await _generate_track(...)`
runs. World generation yields hundreds of frames, and at a 30 fps cap each of those
yields idles for `max(0, 33 ms − work already done in that frame)`. Where the work
between yields is cheap, that is close to a full 33 ms of wall-clock idle per yield.

> ### ⚠️ Corrected 2026-07-28 — the first draft of this item overstated the win badly
>
> The first draft multiplied every yield by a full 33 ms. **That is wrong** — Godot's
> frame limiter sleeps only the *remainder* of the frame budget. A second revision then
> overcorrected to "~0 everywhere except the DFS", which is also wrong. The accurate
> picture, verified against the code:
>
> | site | yields | work between yields | real idle |
> |---|---|---|---|
> | `bake_track` — `progress_stride = cand_total / 40` | 40 | ~1/40 of a ~3.5 s carve ≈ **87 ms** | **~0** |
> | precompute, **full-res** chunks — `precompute_done % 8` | ~20 | 8 × `compute_chunk_data` + `TerrainLod.build_all` | **~0** |
> | precompute, **coarse** chunks | ~19 | `cache_chunk` early-returns a cheap `build_levels_from` — no full-res grid, no collision | **~33 ms each, but see caveat** |
> | `_prewarm_corridor` — `STEPS = 14`, 2 frames per waypoint | 30 | only the first few waypoints compile new shaders; the second frame of each pair and all later waypoints render an already-warm view | **~33 ms for most ≈ 0.5–1.0 s** |
> | `_stage` boundaries | ~8 | varies | small |
> | **`track_generator.gd::_search`** — `PROGRESS_STEP_INTERVAL = 2` | 55–1300 | **2 DFS steps — genuinely cheap** | **the largest block by far** |
>
> **Caveat on the coarse-chunk row:** `world.gd` yields every 8th chunk over a *single*
> `floor_tm.corridor()` iteration, so batches **interleave** coarse and full-res chunks.
> Most batches therefore contain at least one expensive `compute_chunk_data` +
> `build_all` and have ~0 idle. The coarse contribution depends entirely on `corridor()`
> ordering and is **likely well under the naive estimate** — measure it in Step 0 rather
> than quoting a figure.
>
> **Two conclusions:**
>
> 1. **The largest idle is in the DFS** — and per 2.6 the DFS runs on **free roam and
>    benchmark only**, since career stages hit `TrackCache`.
> 2. **Career mode still gets a real but modest win** — the pre-warm frames and the
>    coarse-chunk batches, together **order 1–2 s**, both of which run on every boot.
>    (An earlier revision claimed "~3.9 s" and a later one implied "~0"; neither is
>    right.)
>
> `cache_chunk`'s coarse branch (`precompute_prune_enabled and not cls["full_res"]`) and
> `_prewarm_corridor`'s two-frames-per-waypoint loop are the specific reasons — read
> both before re-deriving this.
>
> ### ⚠️ And the existing web capture was NOT taken at 30 fps
>
> The measured web table in `performance-optimisations.md` was captured in **desktop
> Chrome on a Mac** via `?bench=1`. On that path `Benchmark.active` →
> `FpsSetting.default_cap()` → `target_fps_for(mobile_or_web = true, web = true,
> touch = Platform.is_touch())`, and `Platform.is_touch()` is
> `DisplayServer.is_touchscreen_available()` — **false on a desktop browser**. So it
> resolved to `target_fps` (**60**), not `target_fps_web` (30).
>
> **Every idle figure above is therefore derived from a 16.7 ms budget, not 33 ms, for
> that capture — roughly 2× overstated.** Halve them when reasoning about the existing
> numbers: the coarse-chunk and pre-warm contributions are order **0.25–0.5 s** each, and
> the "career mode order 1–2 s" estimate becomes **order 0.5–1 s**.
>
> The 33 ms figure is still the right one for a **real phone browser**, which is the
> target — but no capture from one exists. This is a further reason Step 0 matters.

> ### ✅ STEP 0 ANSWERED 2026-07-28 — the premise is REAL
>
> Measured on an actual web export (Chrome, `mobile_controls_force = true` to reach the
> web-touch branch; probe confirmed `is_web=true is_touch=true`), timing 100 consecutive
> `await get_tree().process_frame`:
>
> ```
> max_fps=30  100 frames = 3341.9 ms  (33.42 ms/frame)
> max_fps=0   100 frames =  833.5 ms  ( 8.34 ms/frame)
> ```
>
> 33.42 ms/frame is the frame limiter to within 0.3%, a **4x** difference in wall clock
> per awaited frame. `thread_support = false` does **not** neuter the limiter. The
> contamination thesis stands and the correction header in
> `todo/performance-optimisations.md` must **NOT** be withdrawn.
>
> Measurement caveat: Chrome suspends `requestAnimationFrame` in a background tab, which
> freezes the Godot main loop entirely — three of five samples (1037/479/356 ms per
> frame) were hidden-tab artefacts and were discarded. **Foreground the tab** when
> repeating this.
>
> <details><summary>Original Step 0 instructions</summary>
>
> ### Step 0 — verify the premise before acting on it
>
> The whole thesis assumes `Engine.max_fps` actually paces `await process_frame` **on the
> web export**. That is unverified. Godot's web main loop is driven by
> `requestAnimationFrame`, and the frame delay goes through a platform `delay_usec` that
> behaves differently — possibly not at all — with `thread_support = false`.
>
> **Before rewriting the load table or acting on the contamination claim, run one
> five-minute check:** on the deployed web build, log the wall-clock delta across 100
> consecutive `process_frame` awaits, capped versus uncapped.
>
> **Force the web-touch path when you do it.** A desktop browser resolves to 60, never
> 30 (see above), so "cap 30 vs uncapped" is not reproducible there at all. Use
> `Config.data.mobile_controls_force` (which `Platform.is_touch()` also honours) or run
> it on a real phone. Otherwise you will measure the wrong branch and conclude the wrong
> thing.
>
> If capped and uncapped are the same, the contamination thesis is void, the correction
> header in `todo/performance-optimisations.md` must be **withdrawn**, and this item
> reduces to a tidiness fix.
>
> </details>

Even after that correction, the *direction* of the finding stands for the stages where
idle is non-zero, and it is the reason the per-stage table cannot be trusted as-is.

**Change:**

1. Raise the cap for the duration of `_generate_track`, then apply `fps_cap` afterwards.
   The loading overlay still repaints — the yields still happen, they are simply no
   longer rate-limited at 30.

   **Use a bounded loading cap, not 0.** Running a phone flat-out for a multi-second
   (possibly multi-tens-of-seconds) load is the same thermal and battery failure mode
   this item warns about below for the permanently-uncapped case, and a hot phone will
   then throttle the actual gameplay. Suggested: **uncapped on non-touch platforms,
   ~60 fps during load on touch-web.** Even 60 removes most of the DFS idle versus 30
   while keeping a ceiling.

   Use a **`const` in `world.gd` with a comment**, not a `GameConfig` field. 3.2's rule
   exists for gameplay tier values the user intends to A/B on hardware; a transient
   loading-only cap is not one, and promoting it would add a persisted, documented knob
   nobody will retune.

   **Benchmark interaction:** `benchmark_mode.gd` snapshots `Engine.max_fps` into
   `_saved_max_fps` and restores it later, so it is already snapshot/restore state.
   Do **not** apply the loading cap when `Benchmark.active`, or apply and restore it
   without ever letting it be captured into `_saved_max_fps`. Cover this in the test.

   **Apply the cap in `_ready`, on the line after the `_end_load_timing()` call — not
   inside `_end_load_timing` itself.** That function early-returns on
   `_headless or _stage_label == ""`, so putting the assignment inside it would silently
   skip the cap on any path that reaches it without a recorded stage, leaving the game
   permanently uncapped. This is a real failure mode: the symptom (a phone rendering
   flat-out and overheating) looks nothing like the cause.
2. **Scope reduced (2026-07-28):** make the yields time-based **in `_search` only**, and
   justify it on preview smoothness, not load time. At the batched sites the batches
   already exceed any sensible threshold, so a time rule changes nothing there; applying
   it broadly would add nondeterminism for no gain. In `_search` it bounds an unbounded
   yield count (55–1300) and is where the idle actually is.

   **Determinism requirement.** Wall-clock yielding makes the yield *count* machine- and
   load-dependent. That is fine only if yielding never influences results: the time check
   may decide **when to pause**, never **what to search, in what order, or when to stop**.
   Do not let elapsed time feed a step budget, a restart decision or a bake ordering.
   Under `Platform.is_headless()` keep the existing deterministic fixed stride, so the
   `--fixed-fps 60` test runner stays reproducible.

**Effort:** S. **Win:** large on free roam (the DFS yields); **small and unquantified on
career mode**. See the two correction blocks above before quoting any number.

**Mode split:** see the correction block above — the idle is concentrated in the
free-roam-only DFS. Career mode's share is small and unquantified until Step 0 and a
re-measurement.

**Verification:** re-capture the web `load stage:` table afterwards.

> ⚠️ **Capture on a NON-benchmark boot.** The only existing web capture was taken on the
> `?bench=1` path — which is exactly the path this item excludes from the loading-cap
> change. Re-running it there would show no improvement and look like a failed change.
> Capture a **free-roam boot** (to see the DFS effect) and a **career stage** (to see the
> pre-warm/coarse-chunk effect) instead.

Confirm the benchmark path (`Benchmark.active`, which uses `FpsSetting.default_cap()`)
still gets its intended cap once loading completes — the benchmark's uncap toggle must
keep working.

**Test:** assert that once loading completes the applied cap **equals whatever
`FpsSetting.resolve()` returns** — never a literal `30`, which is a tunable and would
break the moment the user retunes it. The point of the test is that the cap is applied
*at all* and that a refactor can't leave the game permanently uncapped, not what its
value is. `Platform.is_headless()` suppresses the real assignment under the test runner,
so assert on the resolved intent rather than reading `Engine.max_fps`.

Assert that **a loading cap was applied at all** and that the **post-load cap equals the
value `_ready`'s resolver selects for that mode** — `FpsSetting.default_cap()` when
`Benchmark.active`, `FpsSetting.resolve()` otherwise (see `world.gd`'s
`FpsSetting.default_cap() if Benchmark.active else FpsSetting.resolve()`). Asserting
`resolve()` unconditionally would fail on the benchmark path this same item asks you to
cover. Do *not* assert the two caps differ — they legitimately
coincide when a desktop user is uncapped or a web-touch user has chosen 60, and such an
assertion would also pin a tunable.

---

## 1.2 Fix the load-stage boundaries before trusting any stage number

**File:** `scripts/world.gd` → `_stage` / `_end_load_timing` / `_generate_track`.

`_end_load_timing()` is called in `_ready` *after* `_generate_track` returns, and
`_stage()` closes the previous label. The final label — `"Placing signs…"` — therefore
accumulates **everything after `_build_signs`**: `_spawn_spectators`, `_build_arches`,
`_spawn_opponent_wreck`, `_build_persistent_managers`, the `warm_up()` sweep, and
**`_prewarm_corridor()`** (30 rendered frames of first-use GL-Compatibility shader
compilation).

The real sign work is small: `data/track_cache.json` shows every cached stage has 15
pieces, of which 8–11 match `SignLayout.TURN_CORNERS`, giving **16–22 signs per stage**.
The reported 6379 ms would be 320 ms per sign, which is not credible for a `RigidBody3D`
plus two boxes, an `Area3D` and one `MultiMesh` — `_material_for` loads at most 10
distinct ~2 KB textures and memoises per key.

**Change:** add `_stage(loading, "Warming shaders…")` before `_prewarm_corridor()`, and
a stage boundary before the spectators/arches/wreck block. Then re-measure.

**Expected outcome:** signs collapse to <200 ms; the corridor pre-warm reveals itself
as the multi-second stage it actually is.

**Explicitly do not optimise `sign_field.gd` for load time.** It is not the problem.

**Effort:** S.

---

## 1.3 wasm compression — ✅ RESOLVED AS A NON-ISSUE (2026-07-28)

> ### The −28 MB win does not exist. It was already being realised.
>
> **The premise was wrong in one important way: GitHub Pages does not serve the game.**
> The `deploy-pages` job publishes `docs/`, which is only an `index.html` meta-refresh
> redirect to itch.io. The playable build goes to itch via `butler push` in `export-web`
> and is served from `html.itch.zone` behind Cloudflare.
>
> Measured live response headers:
>
> | asset | on disk | `content-length` | `content-encoding` |
> |---|---|---|---|
> | `index.wasm` | 37,700,666 | **9,925,878** | **gzip** |
> | `index.pck` | 17,324,664 | **9,282,176** | **gzip** |
> | `index.js` | 315,759 | 82,293 | gzip |
>
> Also `content-type: application/wasm`, `vary: Accept-Encoding`, strong `etag`.
>
> **Do NOT add a pre-compression step** — butler uploads `build/web` verbatim, so an
> `index.wasm.gz` would ship as an extra unreferenced 9 MB file rather than being
> content-negotiated.
>
> **Caching (step 4) is also already safe** and also not ours to set: itch serves each
> upload from a build-unique path (`/html/<upload-id>-<build-id>/`), so every asset URL
> is inherently version-stamped and a redeploy can never be masked by a cached response.
>
> Brotli is **not** offered (~1.7 MB further available) — a Cloudflare/itch setting, not
> ours.
>
> **Consequences for the rest of this spec:** remove the −28 MB from any plan-level
> total; §8's "if the host is not compressing today" branch is void; and **2.13 (custom
> size-optimised wasm template) becomes relatively more attractive**, since transport
> compression turned out to be a non-lever and the wasm is now unambiguously the
> majority of the download.
>
> **Landed:** header comments recording the measured production headers in
> `build_web.sh`, a warning in `serve_web.sh` that local serving is uncompressed (so
> local timings overstate real transfer cost by ~3-4x), and a note in `deploy.yml` that
> it does not publish the game. No behaviour change.

### Original item (superseded, kept for the reasoning)

**Files:** `.github/workflows/deploy.yml` (the `deploy-pages` job,
`upload-pages-artifact@v5`), `build_web.sh`, `serve_web.sh`.

`build/web/index.wasm` is **37,700,666 bytes** uncompressed; it gzips to ~9.44 MB (measured, default level) and
brotli-q5s to ~7.76 MB. Nothing in the workflow, `build_web.sh`, or `serve_web.sh` sets
`Content-Encoding` or pre-compresses.

If GitHub Pages is not gzipping `application/wasm`, **mobile users are downloading
37.7 MB instead of 9.44 MB** — which dwarfs every other size finding in this spec
combined.

**Change:**

1. First, just check the response headers on the deployed URL. This is a five-minute
   task and it determines whether anything else here matters.
2. If uncompressed, pre-compress in the workflow (or move to a host that negotiates
   encoding for wasm).
3. Separately, `serve_web.sh` does not compress either, which makes **local load
   timings misleading** — any measurement taken through it overstates the real-world
   transfer cost. Worth noting in the script's header regardless of the outcome.
4. **Set long-lived versioned/immutable cache headers on the wasm and PCK.** (Folded in
   from the cut item 2.12 — see §5A.) This captures most of the repeat-visit benefit a
   service worker would have given, without a service worker's ability to pin players to
   a stale build. Version the URL or filename so a redeploy is always picked up.

**Effort:** S. **Win:** up to −28 MB on the wire.

---

## 1.4 Remove the live-reload poller from the shipped Web preset

**File:** `export_presets.cfg` → `[preset.0.options] html/head_include`.

The second `<script>` in the head include runs `setInterval(p, 1000)` forever,
`fetch('/reload-token')` every second, and calls `location.reload()` if the response
body changes. Because it lives in the **Web preset itself**, it ships to itch.io and to
every player's phone.

Consequences: one network request per second per player for the entire session (battery
drain and radio wake on mobile), a 404 per second against the host, and a genuine reload
hazard if any host ever returns a varying body for an unknown path — CDN error pages, ad
interstitials, or an SPA catch-all would all trigger it.

**Change:** move the poller out of the preset. `serve_web.sh` already serves
`/reload-token`, so it can append the script to `build/web/index.html` after export, for
local dev only.

**The landscape-lock script in the same string is legitimate and must stay.**

**Effort:** S. **Win:** removes a permanent background timer from production and closes
a live-reload footgun.

---

## 1.5 Stop shipping duplicate car textures

**Files:** `blender/*/`, `export_presets.cfg` exclude filters.

**Seven of the nine car folders** contain two byte-identical body textures (verified by
md5). `blender/acty/` and `blender/charger/` have only one each and are not affected.

> ### ⚠️ The orphan is NOT consistently named — check each car individually
>
> It is tempting to assume the bare `texture.png` is always the dead one (it is the
> `"uri"` the `.gltf` sidecars point at). **That is wrong for three cars.** For 911,
> viper and xjs the *live* texture is `texture.png` and the `*_texture.png` is the
> orphan. An exclude filter written from the wrong assumption would **strip three
> cars' body textures from the build.**

Verified against `CarLibrary.CARS` (`scripts/car_library.gd`, `model_texture` field):

| car | **live** (referenced) | **orphan** (delete/exclude) |
|---|---|---|
| 911 | `blender/911/texture.png` | `blender/911/911_texture.png` |
| viper | `blender/viper/texture.png` | `blender/viper/viper_texture.png` |
| xjs | `blender/xjs/texture.png` | `blender/xjs/xjs_texture.png` |
| focus | `blender/focus/focus_texture.png` | `blender/focus/texture.png` |
| twingo | `blender/twingo/twingo_texture.png` | `blender/twingo/texture.png` |
| thebeast | `blender/thebeast/mrbeast_texture.png` | `blender/thebeast/texture.png` |
| mx5 | `blender/mx5/mx5_texture.png` | `blender/mx5/mx5_Untitled.png` |

Each orphan is still VRAM-imported and lands in the PCK at ~0.667 MB apiece —
**4.67 MB, or 28% of the 16.5 MB PCK.**

They exist because the unreferenced `.gltf` sidecars (`blender/*/*.gltf`) are imported
alongside the `.glb` the game actually uses. The PCK contains **18 `.scn` for 10
models** — every car model is imported twice. (10 models = 9 cars + the spectator.)

**Decision (2026-07-28): keep the sidecars on disk, exclude them from export.** The
`.gltf`/`.bin` files may be part of the Blender round-trip and are not ours to delete
blind. Add exclude filters for `blender/**/*.gltf`, `blender/**/*.bin` and the seven
orphan PNGs **named individually from the table above** — do not use a `*_texture.png`
or `texture.png` glob, which would hit live files either way.

**Success criteria for this item (both required):**
1. After re-exporting, **all 9 cars in `CarLibrary.CARS` still render with their body
   texture** in the HQ car park. This is the check that catches a mis-written exclude
   filter. (`CARS` has 9 entries; the "10 models" figure elsewhere counts
   `blender/spectator/spectator.glb`, which is not a car.)
2. **Re-parse the PCK directory and confirm the seven orphan `.ctex` entries are gone**
   and total size dropped by ~4.67 MB. An exclude filter on a *source* file does not
   necessarily drop an already-imported `.ctex` — do not assume the saving landed just
   because the build succeeded.

**Sequencing:** this lands **before** 2.10, so 2.10 only touches live textures.

**Test:** none needed beyond the above — this is an asset/config change, and a test
asserting a particular car's texture path would violate the no-catalogue-dependency
rule.

**Effort:** S. **Win:** −4.67 MB PCK. Note this leaves the double-import cost at *edit*
time, which is a minor annoyance, not a shipped cost.

---

## 1.6 Free the dead terrain-cache arrays

**File:** `scripts/terrain_manager.gd` → `cache_chunk()` / `_chunk_cache`.

`cache_chunk()` stores the entire `TerrainChunkBuilder.data()` dict, then adds
`data["lod_meshes"] = TerrainLod.build_all(data, …)`. After `build_all` has consumed
them, **five of the seven arrays are never read again**:

- `TerrainChunk.apply_data()` reads `center`, `lod_meshes`, `heights`, `coarse` — **plus
  a fallback branch** that calls `TerrainLod.build_all(data, …)` when `lod_meshes` is
  empty, which *does* read `vertices`/`indices`/`uvs`/`colors`. Unreachable for cached
  chunks today because `cache_chunk` always populates `lod_meshes` — but this is the one
  path that makes erasing the arrays unsafe, so it must be handled (see Guards).
- `_cached_height_at` reads `heights`; `_cached_light_at` reads `lights`.
- `TerrainLod.mesh_from_grid` reads `vertices` etc. only off a **local** builder in
  `build_levels_from`, never off the cache.

Per full-res chunk (`SAMPLES = 51` → 2601 verts, 15 000 indices), by `cache_size_mb()`'s
own accounting:

| array | KB/chunk | still needed after load? |
|---|---|---|
| `indices` | 60.0 | dead |
| `colors` | 41.6 | dead |
| `lights` | 41.6 | load-time only — see 1.7 |
| `vertices` | 31.2 | dead |
| `uvs` | 20.8 | dead |
| `uv2s` | 20.8 | dead |
| `heights` | 10.4 | **yes** — collision + `height_at` |
| **total** | **226.4** | **10.4 truly resident** |

Coarse chunks store no arrays, so the observed 35–40 MB is ~155–175 full-res chunks at
226 KB each.

**Change:** erase the five dead keys after `build_all`.

**Effort:** S. **Win:** ~35–40 MB → ~9 MB. Best win-to-effort ratio in the audit.

**Test:** assert terrain collision and `height_at` still return correct values for a
spawned chunk after the dead keys are erased, and that a chunk can still be spawned,
despawned and re-spawned from cache. Use `SceneTestHelpers.minimal_world()` where
possible. No assertion on cache size in MB — that scales with tunables.

**Guards:**

- `_rebuild_loaded()` refills from scratch anyway, and `_reconcile`'s on-demand path only
  fires when `_chunk_cache.is_empty()` — both remain correct.
- **`TerrainChunk.apply_data`'s `build_all` fallback is the real hazard.** Once the
  arrays are erased, a cached chunk that somehow reached that branch would build garbage
  or crash instead of silently rebuilding. Assert that `lod_meshes` is non-empty for
  cached chunks, or remove the fallback, as part of this item — do not leave it as a
  latent trap.
- Fix the now-misleading cache-size log in `world.gd`.

---

## 1.7 Free the baked `lights` array once loading completes

**File:** `terrain_chunk_builder.gd` → `data()["lights"]`, read via
`TerrainManager.light_at`.

Every `light_at` caller is a one-shot build: `tree_mesh_field.gd` (per-instance bush
tint at scatter time), `distant_terrain.gd` (backdrop, built once), `road_markings.gd`
(static mesh). Nothing samples baked light per frame, and the value is *also* already
folded into the `colors` RGB.

At 41.6 KB × ~170 full-res chunks that is **~7 MB** held for the entire run.

**Change:** free it after the load stages finish (after `_prewarm_corridor`). Combined
with 1.6, the residual cache goes to **~1.8 MB — heights only.**

**Effort:** S. **Guard:** verify no replay or regeneration path re-enters `light_at`
mid-run before landing this — grep every caller, not just the three known ones.

> ⚠️ **Freeing `lights` fails SILENTLY, not loudly.** `TerrainManager._cached_light_at`
> reads `_chunk_cache[...].get("lights", PackedColorArray())` and its comment says it
> "falls through when the chunk is unlit (empty lights array)" — so after the free, a
> `light_at` call does not error, it quietly returns the live-noise value instead of the
> baked one. A future feature would get subtly wrong colours with no warning.
>
> **Add an explicit "freed" sentinel** (a flag on the manager, checked in
> `_cached_light_at`, that `push_error`s or asserts once the free has happened) so the
> failure is loud. Do this as part of the item — it is the difference between a safe
> optimisation and a landmine.

**Test:** assert that a `light_at` call after the free triggers the sentinel, and that
before the free it still returns baked values.

**Hook:** uses the shared "load finished" hook — see the sequencing note in Tier 2.

---

# Tier 2 — real wins, mostly mechanical

> ### Sequencing: the track cache is shared state — regenerate it ONCE, LAST
>
> Three items can change generated track shape and therefore invalidate
> `data/track_cache.json`: **2.3** (the sort, if it reorders ties), **2.4**
> (`rasterize_cells` changing the reserved corridor), and **2.6** (adding free-roam and
> benchmark entries to the same lockfile).
>
> Done independently they produce conflicting lockfile diffs and three wasted
> regenerations. **Land the code for all three first, then do a single
> `TrackCache.CACHE_VERSION` bump and one `./cache_all.sh` run at the end**, and review
> that one lockfile diff. Any item that lands before the regeneration must be understood
> to leave the cache stale in the interim.
>
> **This is why 2.6 is pulled back into the batch despite being deprioritised.** 2.6 is
> S-effort and touches the same lockfile; doing it "last, separately" (as its own
> decision block suggests) would force a *second* `CACHE_VERSION` bump and regeneration.
> If you are regenerating anyway, land 2.6 in the same pass — that is the whole point of
> this note. It remains low *value*; it is just cheap to include here.
>
> ### Sequencing: texture work
>
> **1.5 lands before 2.10.** 1.5 removes the seven orphan textures; 2.10 then only has to
> touch textures that are actually live. Doing them in the other order means re-importing
> files that are about to be deleted.
>
> ### Sequencing: one shared "load finished" hook
>
> **1.7** and **2.7** both want to free memory once loading completes, and an earlier
> draft gave them different anchors. Define **one** hook in `world.gd` and hang both off
> it. Whichever item lands first creates the hook.
>
> **Put it in `_ready`, on the line after the `_end_load_timing()` call — never inside
> that function.** `_end_load_timing()` early-returns on `_headless or _stage_label == ""`
> (the same trap 1.1 warns about for the fps cap), so a hook placed inside it would
> **never fire under the headless test runner** — which would make 1.7's and 2.7's
> prescribed tests impossible to write. The hook must fire unconditionally, headless
> included.

> **Ordering note (2026-07-28 decision):** these are *not* gated on re-measuring the
> load table. Several of them — the throwaway tessellations, the 26k `sample_baked`
> calls/sec, the duplicated 50k-key dictionary copies — are self-evidently wasteful
> regardless of what the profile says. Do them on their merits. Re-measure anyway after
> Tier 1, but don't block on it.

## 2.1 Drop the engine-synth mix rate on mobile/web

**Files:** `scripts/engine_audio.gd` (`const MIX_RATE := 22050.0`, used at
`gen.mix_rate` and both `EngineAudioSynth.new(cfg, MIX_RATE)` sites),
`scripts/engine_audio_synth.gd` → `fill()`.

Per the project's own perf log (`features/debug-tools.md`:
`[perf-scripts] ms/frame: engine_audio=0.956 car=0.189 …`), the synth is **already the
largest single script cost on native desktop**. It is a per-sample GDScript DSP loop, so
it scales with **sample rate, not frame rate**: 22 050 iterations per second, each doing
three `lerpf` smoothers, two `fposmod`, one or two `_read_voice` calls, several
`randf()`s, an SVF whistle recurrence, an air-rush low-pass, a DC block and a soft clip.

Under wasm, GDScript VM dispatch is typically 2–4× worse, so budget **2–4 ms/frame** —
6–12% of a 33 ms web-touch frame. On single-threaded web the mixer *is* the main loop.

`MIX_RATE` is a bare const cleanly injected through the synth's `_init(cfg, mix_rate)`,
so a platform switch is genuinely a one-line change.

**Changes, in order of value:**

1. **Halve the mix rate on mobile/web** (22050 → 11025). Straight ~50% cut of the
   largest script cost. The note is a buzzy PS1 synth; losing the top octave is not a
   significant aesthetic hit. **S.**
   **Decision (2026-07-28): approved — the changed engine note is acceptable.** Note the
   audible consequence for whoever implements it: Nyquist drops to 5.5 kHz, so the
   crackle and turbo-whistle layers will dull noticeably more than the engine
   fundamental. Mobile/web only; desktop keeps 22050.

   **Route this through the tier, not a script constant.** `MIX_RATE` is currently a
   `const` in `engine_audio.gd`, so the temptation is a one-line `Platform` branch there
   — but that conflicts with 3.2's rule (and the project's config rule) that platform
   tier values live in `GameConfig` / `game_config.tres` where the user can retune them.

   **Do not wait for 3.2.** 3.2 is a later Tier 3 item; blocking on it would stall this
   one. Add a `GameConfig` field and resolve it with the **existing**
   `*_for(web, touch)` helper pattern that `tree_render_distance_for` already uses —
   that *is* the current mechanism, and 3.2 later consolidates these helpers into one
   `quality_tier`. This is not "a second notion of mobile"; it is the same gate. The same
   applies to 3.1's subdivision field.
2. **Skip synthesis when inaudible.** `_timed_process` computes `volume_db` from camera
   distance but always runs the full fill. At or near
   `engine_audio_max_attenuation_db`, push a zero/decimated buffer instead. Matters at
   the start line and around the opponent wreck. **S.**
3. **Replace the per-sample `randf()` calls with a precomputed noise table.** Up to five
   `_rng.randf()` bound-method calls per sample — **~110k engine calls/second** — and two
   of them (noise, crackle) fire unconditionally even when their envelope is zero. A few
   thousand samples in a `PackedFloat32Array` with per-layer offsets so the layers
   decorrelate is audibly indistinguishable. **S**, ~20–30% of synth CPU.
4. **Pre-blend `_read_voice`'s two load tables once per `fill()`** instead of lerping
   per sample. The throttle smoother runs inside the loop, but per-buffer table
   selection at ~60 buffers/s is inaudible. **M**, halves the hottest inner function.
5. Long term, this is the one part of the codebase that genuinely wants to be a C++
   `AudioStreamPlayback` rather than GDScript. **L**, out of scope here.

**Interaction:** `BUFFER_SECONDS_TOUCH = 0.2` and `audio/driver/output_latency.web = 150`
are tuned around this loop (see `features/engine-audio.md` and commit `dc8a105`).
Changing the mix rate changes buffer frame counts — re-check `skip_count()` in the
benchmark afterwards.

**Verification:** the `engine_audio` key already exists in `PerfLog`, so items 1–4 can
be measured rather than estimated.

## 2.2 Bake the centerline; stop calling `Curve2D.sample_baked` 26,000×/second

**Files:** `scripts/track_progress.gd` → `_local_closest_offset`;
`scripts/tire_marks.gd` → `_search_offset` / `_windowed_offset` / `_wheel_offset` /
`_normal_at`.

Two independent brute-force nearest-point scans, both every physics tick:

- `track_progress.gd`: a −40 m…+140 m window at `SEARCH_STEP_M = 1.0` ⇒ **181
  `sample_baked` calls/tick.**
- `tire_marks.gd`: a 90 m window (91 calls) **plus once per wheel** at a 40 m window
  (41 × 4) ⇒ **~255 calls/tick**, plus `_normal_at` (3 per emitting wheel) and the
  gate's `sample_baked(w_off)`.

At 60 Hz that is **~26,000 `Curve2D.sample_baked` calls per second**, each a binary
search over the baked point table plus GDScript↔engine call overhead. On wasm the call
overhead is the expensive part.

> ### ⚠️ REJECTED ON IMPLEMENTATION (2026-07-28) — the cheap version breaks corner cutting
>
> The "try the ±3 m local search first" advice below **was tried and rejected**, for a
> concrete reason this spec missed:
>
> **`track_progress.gd::_accrue_cut` detects a corner cut by seeing the nearest-point
> offset LEAP tens of metres in one tick** as the car crosses a hairpin's neck
> (`test_cutting_the_neck_bills_the_stolen_metres` drives a jump from ~5 m to ~103 m).
> A ±3 m window can never observe that jump, so **corner-cutting penalties would silently
> stop being billed** — a real behaviour regression, not a stale test. The same width is
> also what lets the off-track leash re-acquire after a big excursion without a
> discontinuity handler.
>
> **The window is load-bearing. Optimise the per-probe cost, never the window.**
>
> What actually landed: the search geometry is byte-for-byte unchanged, and the engine
> calls underneath it were removed via the shared baked table (below), which interpolates.
> See `features/progress.md` → *Baked centerline table*.
>
> <details><summary>Original (rejected) advice, kept for the reasoning</summary>
>
> ### Try the cheap version first (added 2026-07-28)
>
> Before building a shared baked table, note that **`track_progress.gd` already keeps
> `_prev_offset`, and the car moves well under 1 m per physics tick.** A **±3 m local
> search around the previous offset (~7 probes)**, plus a one-shot `get_closest_offset`
> on reset/teleport/respawn, removes ~95% of the calls with:
> - no baked table,
> - no interpolation hazard,
> - no `TrackProgress` / `TireMarks` ownership refactor.
>
> That is **S effort instead of M**, and it may make the rest of this item unnecessary.
> Do it first, re-check whether `sample_baked` still shows up, and only then consider the
> full bake below. The one thing to get right is the recovery path: any discontinuity
> (reset, teleport, a big off-track excursion) must fall back to a full search, or the
> tracked offset can get stranded.

> </details>

**What landed:** the centerline is **static for the whole event**. Bake
it once into a `PackedVector2Array` at 1 m spacing and index it directly — zero engine
calls, pure array reads. Then make the search coarse-to-fine (8 m stride, then ±8 m at
1 m) to cut 181 probes to ~30.

> ### ⚠️ Interpolate — do not truncate
>
> A naive `pts[int(o)]` replaces `sample_baked`'s **interpolated** result with a
> nearest-sample lookup, quantising position to 1 m. That is **gameplay-visible**: it
> feeds stage progress and split timing (`TrackProgress`) and tire-mark placement, and
> could perturb replays and ghosts. **Linearly interpolate between adjacent baked
> points.** The win comes from removing the engine call and shrinking the search, not
> from dropping precision.

**Ownership:** `TrackProgress` builds and owns the table and exposes it; `TireMarks.setup`
consumes it. `TireMarks` currently tracks the car's offset independently of
`TrackProgress`, duplicating the entire scan — collapse to one cached offset.

**Test:** assert the baked lookup agrees with `Curve2D.sample_baked` within a tight
tolerance across the whole curve, and that the coarse-to-fine search finds the same
nearest offset as an exhaustive scan on a synthetic curve. No assertions on stride or
window values — those are tunables.

**Feel check:** confirm split times on a known stage are unchanged before/after.

**Effort:** M (shared helper plus tests). **Win:** likely the largest non-audio
physics-tick saving available.

## 2.3 Track-generator hot-path fixes

> ### ⚠️ Not all of these are bit-identical — an earlier draft said they were
>
> The memoisation, the `occupied.duplicate()` removal and the `range()` conversions are
> **provably output-identical**: they change how a value is obtained, never which value.
>
> **The sort change is not.** Replacing `keyed.sort_custom(...)` with an index sort
> against a `PackedFloat32Array` — and precomputing the candidate list — can reorder
> **ties**, which changes DFS exploration order and therefore generated track shape.
> `sort_custom` is not a stable sort in Godot.
>
> Treat the sort as a shape-affecting change: either give it an explicit documented
> tie-break (e.g. fall back to candidate index) so the order is fully determined and
> verify same-seed equality before/after, **or** fold it into the shared cache
> regeneration described in the sequencing note below. Do not ship it assuming it is
> free.

**File:** `scripts/track_generator.gd`.

- **`_candidates` re-tessellates every corner curve on every DFS step.** With
  `straightness > 0` (free roam ships `free_roam_straightness = 0.5`) it calls
  `_candidate_straightness` → `_corner_straightness(spec)` for **all 64 candidates**
  (8 turn corners × 2 flips × 4 straight options), and `_corner_straightness` does
  `CornerLibrary.build_curve(spec).tessellate()` — allocate a `Curve2D`, add points, run
  adaptive bezier tessellation, discard. A 200-step search performs **~12,800 curve
  tessellations to compute 8 constant numbers.** Memoise in a `static var` dict keyed by
  corner name, or precompute the whole 64-entry candidate list once per `generate()`
  (the set is identical at every depth; only the random keys change).
- **`_search` deep-copies the occupancy set per candidate at the final corner.**
  `var occ_with := occupied.duplicate()` where `occupied` holds the whole track
  footprint — on the order of **50,000 `Vector2i` keys** — once per candidate tried at
  the last depth (up to 64), and again on every backtrack that re-reaches it. Give
  `_collide_and_cells` an optional `extra: Dictionary` parameter and test
  `occupied.has(cell) or extra.has(cell) or reserved.has(cell)`. No copy at all.
- **`keyed.sort_custom(func(a,b): …)`** allocates 64 dicts and runs ~380 GDScript-lambda
  comparisons per step. Sort an index array against a `PackedFloat32Array` of keys, or
  reuse a preallocated buffer.
- **`range(a, b)` in inner loops.** `_collide_and_cells` rebuilds an Array per row per
  segment per candidate; `rasterize_cells` has two nested `range(-reach, reach + 1)`
  calls and so allocates `2 * reach + 2` Arrays **per raster sample**, scaling with
  `reach`; `TreeScatter.scatter` and `TerrainManager.corridor_coords` do the same. The
  prior cliff work already found `range()` removal to be its single biggest win.
  Mechanical `while`-loop conversion.

> **Not a hazard:** bare `for i in range(n)` compiles to a counted-loop opcode in
> GDScript 4 and does **not** allocate. Only the two- and three-argument forms above
> are worth converting.

**Effort:** S each. **Win:** should collapse the DFS stage.

**Mode caveat:** like 1.1's `_search` component, all of 2.3 affects **uncached generation
only** — career stages skip the DFS entirely. Given the 2.6 decision that free roam is
low priority, these are cheap and satisfying but should not displace career-affecting
work. They stay in Tier 2 because they are S-effort and mostly provably output-identical,
not because they are urgent.

## 2.4 Rewrite `rasterize_cells` to the per-segment scan

**File:** `scripts/track_generator.gd` → `rasterize_cells`.

`_collide_and_cells` carries an explicit comment that stamping a `reach × reach` block
at every `RASTER_STEP_M` sample "re-tested the same cells ~half/RASTER_STEP times over,
which made each candidate ~70 ms and turned a heavy-backtracking seed into a multi-minute
hang" — and it was rewritten to a per-segment bounding-box scan with `_point_seg_dist_sq`.

**`rasterize_cells` got only half the treatment.** It already carries a
`cells.has(cell)` early-skip whose comment says it avoids "~half/RASTER_STEP redundant
distance checks per cell" — so the *distance test* is not duplicated. What remains is
the O(samples × reach²) **iteration**: a `Vector2i` construct plus a dictionary hash for
every cell in the block at every sample, most of which are immediate skips. The win is
therefore smaller than a naive reading suggests — it is eliminating per-sample cell
construction and hashing, not redundant maths.

`world.gd` calls it three times per load on the full tessellated centerline:
`road_footprint` and the strictly wider `bush_footprint` in `_build_foliage`, plus
`reserve_behind` in `generate()`/`rebuild_from_pieces`.

Cost is quadratic in `reach = ceil(half / CELL_M) + 1`. This is consistent with the
measured asymmetry the old spec could not explain: **bushes 2594 ms vs trees 849 ms on
web** — same scatter, same renderer, but the bush pass rasterises a wider footprint.
(Those timings are inherited from `performance-optimisations.md`. Under the corrected
model in 1.1 the scatter stages contain **no batched yield sites** — only the single
`_stage` boundary — so unlike the track-generation number these measurements are
**clean**, and the correlation is real evidence.)

**Change:** port the `_collide_and_cells` per-segment bbox + `_point_seg_dist_sq` scan
into `rasterize_cells`.

**Effort:** M. **Win:** estimated 1–2 s off the web load.

**Decision (2026-07-28): accept a shape change and regenerate.** The per-segment version
is the *more* correct one, but the cell set may differ at the margins, and
`reserve_behind` feeds generated track shape. This item therefore **includes** bumping
`TrackCache.CACHE_VERSION` and re-running `./cache_all.sh`, plus a before/after check
that stages still generate sensibly. Run `test_tree_scatter` and any road-cell tests.

## 2.5 Commit the lake water texture as an asset

**File:** the `_make_water_texture()` path reached from `world.gd::_build_lakes` →
`LakeField.build`.

"Filling lakes" measured 1121 ms on web against 14 ms native — an 80× ratio that is
entirely one texture. `_make_water_texture()` builds a **128×128 seamless FBM Perlin
`NoiseTexture2D`**. Its doc comment says the bake happens on a worker thread, but the
web export ships `variant/thread_support = false`, so **there is no worker thread and
the bake lands on the main loop.** `seamless = true` makes Godot generate and cross-blend
a larger buffer, roughly 4× the samples.

**Change:** bake it once and commit it as a `.png`/`.webp` — it is a fixed,
seed-independent 128×128 tile. Also switch the `load(WATER_SHADER)` in the same function
to `preload`.

**Effort:** S. **Win:** ~1.0 s — and unlike the track-generation number, **this
measurement is clean**: the lake stage has no batched yield sites, so 1.1's frame-cap
correction does not apply to it. This is one of the best-evidenced items in the spec, and
it hits **every** career load.

**Import settings for the committed asset:** state them explicitly so it does not
silently land uncompressed and undo 2.10's intent — it is a small tiling noise texture,
so lossy with mipmaps is appropriate. Do not leave it on whatever the importer defaults
to at the time.

**Success criterion:** before/after screenshot of a lake showing no visible change. The
texture is generated, so "looks the same" is the only correctness bar that matters.

## 2.6 Prebake benchmark + default-config tracks (NOT free roam)

> ### ⚠️ PREMISE CORRECTED ON IMPLEMENTATION (2026-07-28)
>
> **A real free-roam entry is unbakeable.** `hq.gd::_prepare_free_roam` randomises
> `track_seed`, `track_water_level_m` **and** `terrain_layer1_amplitude` on every entry,
> and all three feed the cache key — so free roam misses by construction and always
> live-generates. **§2.6's "free roam" win does not exist as written.**
>
> What IS bakeable, and what landed: the **benchmark stage** (fixed seed/turns/
> straightness, produced by calling `Benchmark.apply_overrides` on a config copy so it
> cannot drift) and the **default-config boot**. Both verified to hit:
> `complete=true, pieces=30`. `good-seeds.md` seeds were deliberately not baked — same
> randomised water/relief reason.
>
> This also means the DFS cost on free roam is **permanent** unless free-roam entry stops
> randomising, which is a gameplay decision, not a performance one.

**Files:** `cache_tracks.sh` → `tools/generate_track_cache.tscn`; the `for_config`
branch in `world.gd`.

`generate_cached` is only reached when `RallySession.current_event()` is non-empty;
`world.gd` routes `for_config` — free roam and the benchmark boot — straight to
`TrackGenerator.generate()`. **This is why the web measurement showed a 29 s DFS.**
Free roam is a shipped mode.

`cache_tracks.sh` currently emits 39 entries (all rally events, 248 KB). Extending it to
also bake the free-roam and benchmark parameter sets — `good-seeds.md` already exists —
removes the live DFS from **every** shipped boot path for a few KB of lockfile.

**Effort:** S. **Win:** combined with 1.1, likely the largest end-to-end web-load
reduction available *for free roam specifically*.

> **Decision (2026-07-28): low value, but land it WITH the 2.3/2.4 cache batch.** Career
> mode is the focus and this only improves a secondary mode, so its *value* is low. But
> it touches the same lockfile as 2.3 and 2.4, and doing it "later, separately" would
> force a **second** `CACHE_VERSION` bump and regeneration.
>
> **The Tier 2 sequencing note is authoritative:** if you are regenerating the cache
> anyway, include 2.6. Do not skip it and do not schedule it separately. It also lowers
> the urgency of the DFS micro-fixes in 2.3, which likewise only affect uncached
> generation.

## 2.7 Free the road/cliff bake dictionaries after precompute

**File:** `scripts/terrain_manager.gd` → `bake_track()`; fields `road_heights`,
`road_blend`, `track_weights`, `track_surface`, `cliff_offsets`.

Five `Vector2i → float` **Dictionaries** retained for the whole stage. Godot's
`HashMap<Variant, Variant>` costs roughly 60–90 bytes per entry (two 24-byte Variants
plus bucket and hash) versus 4 bytes in a flat array.

Band widths from `config/game_config.tres`: road band `f_outer = 7/2 + 3 = 6.5 m`
(13 m ribbon); cliff band `c_outer = 6.5 + cliff_run 2 + cliff_fade 30 = 38.5 m`
(**77 m ribbon**) at 1 m resolution. For a multi-kilometre centerline that is on the
order of 10⁵–10⁶ entries, dominated by `cliff_offsets` — plausibly **25–40 MB**
*(estimated)*, as much again as the chunk cache. `cache_size_mb()` counts none of it.

**Change:** once `precompute_corridor` has cached every chunk, `road_heights`,
`road_blend` and `cliff_offsets` are only read by `TerrainChunkBuilder` — i.e. never
again in shipped play. Free them behind a "corridor complete" gate so the editor and
test on-demand paths can still rebake. **`track_weights` and `track_surface` must
stay** — `surface_at()` drives per-tick grip.

**Add one line logging the five dicts' `.size()` at the end of `bake_track` as part of
this item** — this is the least verified number in the spec, and the log makes the
post-hoc measurement trivial. Per the no-gate decision above it is not a prerequisite for
starting, but land it in the same change.

**Effort:** S–M. **Win:** ~20–30 MB *(estimated)* — ⚠️ **MEASURED 2026-07-28: the
estimate was 3–4x too high.** A real generated stage logs:

```
track bake fields: road_heights=17338 road_blend=17338 track_weights=17319
                   track_surface=17319 cliff_offsets=64249
```

The three freed dicts total ~99k entries ≈ **6–9 MB** at 60–90 B/entry, not 20–30 MB.
`cliff_offsets` does dominate as predicted, and it is the part that scales with stage
length (a 1-turn test stage logs ~4k/4k/0). Still worth doing; just not the headline it
looked like.

**Test:** assert `surface_at()` still returns correct grip after the free (it reads
`track_weights`/`track_surface`, which must survive), and that the editor/test on-demand
rebake path still works once the corridor-complete gate has fired.

**Hook:** uses the shared "load finished" hook — see the sequencing note in Tier 2.

A follow-on — flat-arraying these fields over the band bbox instead of dict-hashing —
is already open item (a) in `todo/performance-optimisations.md` as a CPU win. Note there
that it is *also* a ~15× memory win on these fields. **L**, deferred.

## 2.8 Memoise the opponent-cache fingerprint

**File:** `scripts/opponent_cache.gd` → `global_fingerprint()` →
`TrackCache.stored_source_hash()`.

`stored_source_hash()` does `FileAccess.get_file_as_string` + `JSON.parse_string` on the
**full 248 KB** `data/track_cache.json`, bypassing `_ensure_loaded()`'s static cache.
`global_fingerprint()` additionally does `load(Config.CONFIG_PATH)`, stringifies the
whole `CarLibrary.CARS` + `EngineLibrary.ENGINES` catalogue, and SHA-256s the lot.

All of it is recomputed on **every `OpponentCache.lookup()`** (from
`rally_session.gd`), i.e. once per rally start. On wasm, a 248 KB JSON parse plus a
resource load is likely 50–150 ms of a menu transition.

**Change:** memoise both in a `static var`.

> ### ⚠️ The inputs are immutable at *runtime* — not in the tooling process
>
> `cache_all.sh` / `cache_tracks.sh` / `cache_opponents.sh` and the editor **rewrite the
> track cache and config in-process**. A `static var` memo that never invalidates would
> let a stale fingerprint be baked into a regenerated opponent cache — silent, and
> exactly the kind of corruption that surfaces much later as mismatched opponents.
>
> Scope the memo to runtime: expose a `reset_cache()` (or bypass the memo when
> `Engine.is_editor_hint()` / under the generator tools) and call it from the cache
> generators. This matters more once 2.6 adds free-roam entries to the same pipeline.

**Test:** assert the fingerprint is recomputed after `reset_cache()` and that two calls
without an intervening reset return the same value. No assertion on the hash itself.

**Effort:** S.

## 2.9 The small batch

Each of these is a few lines. **They are not all inert** — an earlier draft called this
batch "no behavioural risk", which is wrong for three of them.

**Genuinely inert** (pure mechanical change, no observable difference): the
`_focus_node()` cache, the `start_line.gd` `set_process(false)`, the
`basis.inverse()` → `transposed()` swap, the `.values()` allocation removal, the
`_update_visuals` colour change-guard, and the HUD string comparisons. No tests needed
beyond existing coverage.

**Behaviour-affecting — these need a test:**

- **`speed_lines` visibility gating** introduces a visible transition; a badly chosen
  epsilon causes pop-in at the threshold. Test that the rect is hidden at zero intensity
  and visible above it, using the resolved threshold rather than a literal speed.
- **`_apply_steer` change-guards** alter *when* `Input.action_press`/`action_release`
  fire. Getting the edge wrong means dropped or stuck steering input. Test that actions
  still press and release across threshold crossings.
- **`perf_log.track()` early-return** must not break benchmark capture. Test that
  `_capturing` still records, and that a release-mode path records nothing.
  > **Downgraded (2026-07-28):** the win is ~34 timer reads plus 34 hash ops per frame —
  > a few microseconds, roughly 0.01% of a 33 ms budget — while the test to protect
  > benchmark capture costs more than that. **Do it opportunistically** if you are in
  > `perf_log.gd` anyway; do not schedule it, and do not count it in any estimate.

- **`terrain_manager.gd::_focus_node()` resolves a NodePath every frame** via
  `get_node_or_null(focus_path)`, purely to read `global_position`. This is the exact
  per-frame scene-tree walk the project already banned elsewhere — see the comment block
  in `engine_audio.gd` that made this same fix for the car/engine refs. Cache on first
  use; re-resolve only when `focus_path` is assigned.
- **`perf_log.gd::track()` is not free in release.** `_process` is disabled when
  `not OS.is_debug_build()`, but `track()` still accumulates into `_script_us` — a
  dictionary never read and never cleared in a shipped build. With **17 call sites**,
  each wrapping a `_process`/`_physics_process` with two `Time.get_ticks_usec()` calls,
  that is ~34 timer reads plus 34 hash ops per frame for nothing. Early-return unless
  `_capturing` or a **cached** debug flag is set (calling `OS.is_debug_build()` per call
  would defeat the point).
- **`start_line.gd::_timed_process` never stops.** It reaches `Seq.DONE: pass` and never
  calls `set_process(false)`, costing a match plus the PerfLog wrapper every frame for
  the rest of the drive. One line.
- **`speed_lines.gd` runs a full-screen shader at zero intensity.** `_timed_process`
  eases `_intensity` toward a speed-derived target, but the `ColorRect` stays visible
  whenever `speed_lines_enabled`. Below `speed_lines_start_kmh` the shader still runs its
  `atan` and three `sin`-based hashes across the whole viewport to blend a fully
  transparent result. Gate `_rect.visible = _intensity > 0.001`, and skip the
  `set_shader_parameter` when unchanged.
- **`mobile_controls.gd` allocates ~10 arrays per frame** — `_region_pressed()` does
  `for r in _pointers.values()`, and `.values()` allocates a fresh Array on every call;
  it runs 2–4× in `_apply_actions` plus once per panel in `_update_visuals`. Iterate the
  Dictionary directly. In the same file, `_update_visuals` writes `ColorRect.color` for
  every panel every frame regardless of change (dirtying 2–4 canvas items for nothing),
  and `_apply_steer` calls `Input.action_press`/`action_release` unconditionally while
  `_set_action` right beside it already has the change-guard pattern.
- **`car.gd::_update_steering`** does `global_transform.basis.inverse() * linear_velocity`
  every tick. The basis is orthonormal — `transposed()` is exact and far cheaper.
- **HUD throwaway strings.** `hud.gd`'s `boost_text()` and `seed_text()` build a
  formatted String every frame purely to compare it against the cached one — compare the
  underlying int/bool instead. `show_elapsed` re-formats and re-assigns
  `_elapsed_label.text` every frame, re-running TextServer shaping; gate on a changed
  centisecond.
> **Withdrawn (2026-07-28):** an earlier draft suggested `web_fullscreen.gd` could
> `set_process(false)` once landscape is confirmed. **It cannot** — the file's own header
> explains the prompt "must re-appear whenever the page falls back to portrait, not just
> at boot", and documents why it polls rather than using `size_changed`. `_process` is
> already a cheap early-returning `Vector2i` compare. Deliberate design; leave it alone.

## 2.10 Texture import hygiene

**Files:** `project.godot` `[importer_defaults]`, the per-texture `.import` files.

`[importer_defaults] texture = {"compress/mode": 1}` is **Lossy, not VRAM Compressed
(mode 2)** — Lossy means WebP on disk and **RGBA8 in VRAM**. The actual import settings
are inconsistent:

- mode **1** (uncompressed in VRAM): `textures/tree.png`, `textures/tree-greece.webp`,
  `textures/greece.png`, all five `garage_*.png`, `map_table.jpg`,
  `blender/mx5/mx5_texture.png` (1024² ⇒ 4 MB VRAM), and **seven of the eight**
  `blender/*/wheel.png` — `blender/mx5/wheel.png` is already mode 2.
- mode **2**: `grass.jpg`, `gravel.jpg`, `sky_field.png`, and most car body atlases.

So `textures/vram_compression/import_etc2_astc = true` and
`texture_format/etc2_astc = true` in the presets **do nothing for the tree atlas** — the
single most-sampled texture in the frame. Sampler bandwidth on the foliage draw is 4×
what it needs to be on a tile-based mobile GPU.

Separately, seven of the eight `blender/*/wheel.png` (all but `mx5`, which has
`mipmaps/generate = true`) and `blender/mx5/mx5_texture.png` have
`mipmaps/generate = false` on 3D-sampled textures, causing texture-cache thrash at
distance. Trees were already fixed for this (noted in `features/rendering.md`); the
wheels were missed. **`blender/mx5/wheel.png` is the reference for what "fixed" looks
like** — match the others to it.

**Decision (2026-07-28) for the seven 1024² VRAM-compressed car bodies: 512 *and*
lossy.** Smallest download, and no VRAM-decompression surprise on any platform
(~0.25 MB RGBA8 each). At 480×360 with nearest filtering the quality risk is judged
acceptable, but **capture before/after screenshots in the HQ car park and on-stage** as
part of the item — the car park shows several cars at once and is the worst case.

**Effort:** S–M. **Win:** ~−4 MB PCK plus a real reduction in mobile sampler bandwidth.

**Related — the web preset ships S3TC only.** `export_presets.cfg` has
`vram_texture_compression/for_desktop = true`, `for_mobile = false`, and the PCK was
confirmed to contain only `*.s3tc.ctex` (38 references, zero etc2/astc). iOS Safari
exposes no S3TC, so Godot decompresses to RGBA8 at load — slower boot *and* several
times the texture RAM, on exactly the devices with the tightest tab budget.

**Do not simply flip `for_mobile = true`** — that *adds* an ETC2/ASTC copy rather than
replacing, making the download bigger. Moving the car bodies to lossy (above) makes them
format-agnostic and fixes iOS in the same move. Reserve `for_mobile = true` for the case
where a real iOS Safari test shows a quality problem on the textures that remain mode 2
(`grass`, `gravel`, `sky_field`).

## 2.11 Lazy-load music

**File:** `scripts/music_library.gd`.

`SONGS` is a const table built from **24 `preload("res://music/*.ogg")` calls**, and
`MusicDirector` is an autoload (`project.godot [autoload] Music`). Touching
`MusicLibrary` at boot therefore forces every segment of every song into memory on the
cold-start path of a single-threaded wasm build — **4.47 MB resident before the first
frame**, when only ~4 × 180 KB is ever needed at once.

**Change:** `load()` on first use of a song id.

**Effort:** M. **Win:** ~4.3 MB off the boot allocation. No download saving.

A further ~1.2–1.5 MB is available by re-encoding (currently 24 × ~22 s stereo Vorbis at
59–72 kbps; 48 kbps, or mono for the ambient layers, would do it) — but that is a
designer quality call, not a free win. The `.mp3` originals are already correctly
excluded by every preset.

## 2.12 PWA service worker — CUT, folded into 1.3

**File:** `export_presets.cfg` → `progressive_web_app/enabled = false`.

No service worker means the ~37 MB wasm pair is at the mercy of the HTTP cache on every
visit. **S** effort, same file as 1.4.

**Risk — this changes update semantics.** A service worker caching a ~37 MB wasm can pin
players to a stale build indefinitely, which is a worse failure than a slow load. The
item must include a cache-busting strategy (version the cache key on build) and a
**success criterion: deploy a change, revisit, and confirm the new build is picked up on
the next visit.**

**Interactions:** 1.4 (the dev reload script must not be cached, and is being removed
from production anyway) and 1.3 (a service worker caches whatever encoding the host
served — verify compression is in place first).

> **Decision (2026-07-28): CUT.** The benefit is HTTP-cache reliability, and most of that
> is obtainable by setting **long-lived versioned cache headers** as part of 1.3 — without
> a service worker's ability to pin players to a stale 37 MB build. The machinery this
> item needs (cache-busting strategy, deploy-revisit verification) costs more than the
> remainder is worth.
>
> **Folded into 1.3:** set immutable/versioned cache headers on the wasm and PCK.
> Revisit a real service worker only if offline play becomes a goal.

---

## 2.13 Evaluate a size-optimised custom web export template — *Tier 3 by effort*

> **Tier note:** rated **L** and "do this last", which matches the Tier 3 definition.
> Numbered in Tier 2 only because it belongs beside the other download items; treat its
> priority as Tier 3.

**Files:** `build_web.sh`, `export_presets.cfg`.

**Added 2026-07-28 — the audit missed this entirely.** Once the PCK work lands, the wasm
is the **majority of the download**: ~9.44 MB gzip versus ~4–5 MB PCK. The spec's only
lever on it (1.3) is transport compression, which does not shrink the binary.

A custom template built with `optimize=size` and unused modules disabled is plausibly the
**single largest remaining download win**, and §6 already assembled the evidence for what
is safe to strip: no `RegEx` anywhere in `scripts/`, no threads, no GDExtension, no
`ResourceLoader` async. Navigation, CSG, multiplayer/ENet, WebRTC, WebXR, Theora, and the
mobile/forward-plus renderers (the game ships GL Compatibility) are all candidates.

**Effort:** L — it means building and maintaining a custom template in CI, and a stripped
module can fail at runtime rather than at build time. **Win:** potentially several MB
gzipped.

**Do this last**, after 1.5 and 2.10 have made the PCK small enough that the wasm
genuinely dominates. **Success criterion:** full playthrough of a career stage plus HQ,
garage, podium and standings on the custom build — a missing module typically surfaces as
a runtime error in a scene nobody thought to open.

## 2.14 HQ boot cost and session-resident car props — *Tier 3 by effort*

> **Tier note:** rated **M** with an unquantified win, which matches Tier 3. Numbered
> here to sit beside the other memory items.

**File:** `scripts/hq.gd` (3108 lines, and `run/main_scene` — the boot scene).

**Added 2026-07-28 — the audit only covered HQ's ground plane (3.1).** HQ is what every
player loads first, and `_ready` does substantial work behind its own loading cover:

- **`_prewarm_free_roam()`** instantiates free-roam car props at boot and keeps them
  `_car_cache`d, hidden, **for the whole session**.
- **One `CarProp` per owned car** in the parked lineup, each with **its own mesh copies**
  (`CarProp.dup_meshes`) so a mixed lot can show different liveries.

> **This is a deliberate, documented trade** — the comments state plainly that the cost is
> paid once at boot and kept in memory to hide the first-entry lag spike. **Do not
> "fix" it blindly**; removing the cache trades a memory win for exactly the stutter it
> was written to prevent.

What is genuinely missing is that **nobody has measured it**, and it is absent from §8's
resident-RAM budget on a platform where the tab budget is the binding constraint. As the
player's garage grows, per-car duplicated meshes scale linearly.

**Change (no measurement gate — instrument now, decide later):** land the
instrumentation as this item's deliverable — log HQ `_ready` wall-clock and the resident
cost of `_car_cache` at a realistic garage size. **Do not block on reading it.** Whether
to then bound the cache (evict least-recently-shown beyond N cars) or make prewarm
conditional on available memory is a follow-up decision once the user has the numbers,
consistent with the no-profile-gate decision in the header.

**Effort:** M. **Win:** unquantified — that is the point of the item.

**Test:** if the cache is bounded, assert an evicted car still displays correctly when
re-shown, and that the currently-selected car is never evicted.

# Tier 3 — larger, needs judgement

## 3.1 The HQ ground plane is 115,200 triangles for a flat plane

**Files:** `scripts/hq_environment.gd` → `build()`; `scripts/mesh_util.gd` →
`feathered_ground_mesh`; `scripts/podium.gd`.

`feathered_ground_mesh(240.0, 240, [apron], …)` builds an `(n+1)²` grid: **58,081
vertices / 115,200 triangles** for a flat plane whose only per-vertex variation is the
tarmac feather weight in `COLOR.a`. `hq.tscn` is `run/main_scene` — this is drawn
continuously on the main menu, every frame, on the lowest-end device the player owns,
before they have started a stage. `podium.gd` has the same shape at
`FLOOR_SUBDIV = 160` ⇒ 26k verts.

The subdivision exists only so the smoothstep feather band around the apron has
resolution; ~95% of the plane is uniform.

**Options:** (a) drop `subdiv` to ~64 and widen `podium_tarmac_feather_m` slightly —
near-zero visual change, ~90% vertex cut, **S**; (b) generate a coarse outer grid with a
fine ring only within `feather` metres of a pad edge, **M**.

**Recommendation:** (a), tiered per platform.

**Where the value lives:** `feathered_ground_mesh`'s `subdiv` argument and `podium.gd`'s
`FLOOR_SUBDIV` are script constants today. Per 3.2's rule and the project config rule,
the tiered value must become a `GameConfig` field — **add HQ/podium ground subdivision to
3.2's lever list.**

**Success criterion:** before/after screenshots of the HQ apron and the podium floor
showing the tarmac feather band still reads correctly. That band is the entire reason the
subdivision exists, so it is the only thing that can visibly break.

**Test:** none — this is a geometry/tunable change, and asserting a subdivision count
would pin a tunable.

**Context — how the render resolution actually works (corrected 2026-07-28):** the
stage renders at roughly **640×360 (~230k pixels)**, not 480×360. `project.godot
[display]` sets `stretch/mode = "viewport"`, `viewport_height = 360` and
`stretch/aspect = "keep_height"`, with `viewport_width = 100` — so the **height is
authoritative and the width is derived from the window aspect**. On a 16:9 display that
gives ~640×360.

`GameConfig.virtual_resolution` (`Vector2(480, 360)`) is a *separate* post-process
shader parameter, carrying the comment "keep matching `[display]` in project.godot
(360 tall, 4:3)". The two are related by convention, not by code.

With no lights, no shadows and no glow/SSAO/SDFGI, the game is still **not
fragment-bound** — the remaining GPU wins are vertex count, draw calls, texture
bandwidth and shader-compile stalls, and this item is the largest vertex-count outlier
in the project. But any resolution work (§3.2) must change **`viewport_height` plus the
aspect setting**, and keep `virtual_resolution` in sync per its own comment — there is
no single "480×360 setting" to turn down.

## 3.2 Generalise the platform tier

**Files:** `scripts/game_config.gd` (`target_fps_for`, `tree_render_distance_for`,
`terrain_lod_bands_for`); `scripts/settings_menu.gd` (`_build_display_page`).

Exactly **three** fields are platform-aware, and Settings exposes only the FPS cap under
Display. `features/rendering.md` states the "one lean pipeline for every device" position
explicitly — which is now stale, since the web-touch tier already exists.

Untiered levers, roughly in value order:

- **Render resolution** — the one true fragment lever. **Read the corrected note in
  §3.1 first**: the real render is ~640×360 driven by `[display] viewport_height` +
  `stretch/aspect`, and `GameConfig.virtual_resolution` is a separate post-process
  parameter that must be kept in sync. Dropping the height to 240 on web-touch is
  roughly 55% fewer fragments. Both values need a mobile-web-only override, and the
  ratio between them must be preserved.
- **Terrain density** — `terrain_chunk.gd` / `terrain_manager.gd` `CELL_M`,
  `SAMPLES = 51`, `RADIUS = 3` (a 7×7 ring, up to five LOD `MeshInstance3D` per chunk
  ⇒ ~245 GeometryInstances culled per frame, ~49 drawn). Halving near-chunk resolution
  on web-touch is the biggest remaining vertex lever in the stage.
- **`distant_terrain_cell_m`** (10 m over 250 m tiles ⇒ 1,250 tris/tile across the whole
  corridor bounds).
- **Foliage and prop density** — `tree_*`, `bush_*`, `spectator_group_size = 50`,
  `speed_lines_enabled`, `engine_smoke_max`.
- **HQ / podium ground subdivision** — see 3.1; currently script constants that need to
  become `GameConfig` fields to be tierable.
- **Engine synth mix rate** — see 2.1; same argument, same mechanism.

**Decision (2026-07-28): auto-detect only, no Settings UI.** Generalise the existing,
proven `*_for(web, touch)` mechanism — resolved once in `world._ready()` and written
back — into a single `quality_tier` resolved from platform. No new menu control, and
therefore no MenuNav wiring or nav test. Adding a user-facing picker later remains
possible but is explicitly out of scope.

**Decision (2026-07-28): lowering `virtual_resolution` is approved for mobile web, under
two hard constraints.**

1. **Mobile web only — desktop web must be untouched.** The existing gate is already
   correct for this: `tree_render_distance_for(web, touch)` and
   `terrain_lod_bands_for(web, touch)` both branch on `(web and touch)`, and their doc
   comments state that "native mobile, desktop, **desktop browser**" all take the
   high-quality path. `Platform.is_touch()` is
   `DisplayServer.is_touchscreen_available() or Config.data.mobile_controls_force`. Reuse
   this gate exactly; do not introduce a second notion of "mobile".
   Note the asymmetry to preserve: `target_fps_for` treats *native* mobile separately
   from web-touch, so check per-field which of the two shapes applies rather than
   assuming.
2. **Every tier value must be a tunable `GameConfig` field** (in
   `config/game_config.tres`, per the project's config rule), not a constant in a script.
   The user will measure and tune on real hardware after implementation.

Because no target device is pinned yet (see the note below), **ship conservative
defaults** — prefer a modest resolution drop that is obviously safe over an aggressive
guess. Sharper defaults can follow a real device measurement.

> **Open — target device unknown.** The right magnitude for the mobile-web resolution
> drop, and whether the iOS S3TC issue in 2.10 is a live blocker or theoretical, both
> depend on the actual test device. Not blocking: tunable fields plus conservative
> defaults let this be settled empirically later.

**Effort:** M.

## 3.3 Physics tick rate and drivetrain substeps

**Files:** `project.godot [physics]` (no `physics/common/physics_ticks_per_second`
override exists — verified); `scripts/drivetrain.gd` (`SPIN_SUBSTEPS = 8`, with
`engine.step()` called **inside** the substep loop).

On a phone browser capped at 30 fps the engine runs **two physics ticks per rendered
frame**, and each tick pays `car._timed_physics_process` + `drivetrain.step` (8 full
`EngineSim.step` and turbo integrations, i.e. **960 engine steps/second**) +
`track_progress` + `tire_marks` + `spectator_group` + `bush_field` + `wheel_particles` +
`engine_smoke` + `chase_camera`.

**Decision (2026-07-28): spec both options, gated on a feel check.** Neither may land
without a side-by-side feel test on a real device and a full physics-test pass.

- **Option A — scale `SPIN_SUBSTEPS` by platform** (8 → 4 on mobile/web), with the
  substep count derived from a target substep *duration* rather than a fixed count.
  Halves the drivetrain and engine cost without touching chassis integration.
  `SPIN_SUBSTEPS` is a stability constant, not a designer tunable, so this is a
  legitimate platform knob. Requires `features/drivetrain-and-tires.md` updated. **M.**
- **Option B — `Engine.physics_ticks_per_second = 30` on mobile/web.** Halves
  *everything* above at a stroke. Risk: the substepped tire solver is explicitly tuned
  for `delta/8`; at 30 Hz the substep becomes 4.2 ms and the stability caps in
  `_tire_force` (which divide by `h`) loosen. **M**, higher risk.

**Test for either option:** the existing physics tests are the guard and must pass
unchanged — they encode agreed behaviour (W drives the car forward, reset returns to
start). Per CLAUDE.md, if one of them breaks, the change is the suspect, not the test:
do not weaken a threshold or flip a sign to get back to green. Add a test that the
substep count is derived from the target substep *duration* rather than asserting the
count itself.

**Feel check (mandatory, and the reason this is Tier 3):** side-by-side on a real device
before it lands.

Option A is the safer half and should be tried first. Option B is documented here so
nobody re-audits it as a novel finding, but it is the kind of change that is hard to
un-ship once tuning drifts around it — treat the feel check as a hard gate, not a
formality.

## 3.4 Spectator forces are recomputed against a static world

**File:** `scripts/spectator_group.gd` → `road_force`, `obstacle_force`,
`separation_force`, called from `_timed_physics_process`.

`road_force` probes 8 directions × `STEPS = 10` ⇒ up to **80 `ScatterMath.on_road()`
calls per member** (each a `Vector2i` construct plus a `Dictionary.has`). With
`spectator_group_size = 50` and `spectator_sim_interval = 2` that is up to **~120,000
dictionary probes per second** for the active group alone — **against a road that does
not move**, for members that barely move.

**Change:** either (a) precompute a per-member road-push vector at spawn and refresh
only when the member has drifted >1 m, or (b) bake a coarse signed-distance-to-road grid
once and sample it in O(1). The same argument applies verbatim to `obstacle_force` —
tree points are also static.

**Effort:** M. **Win:** removes most of the spectator cost at the three crowd flyovers —
exactly the frames that already spike.

**Test:** assert the cached/baked road-push field produces the same steering decision as
the live probe for a set of synthetic member positions, and that members still avoid the
road and each other. Behaviour, not force magnitudes — those are tunables.

Three **S** adjuncts in the same file: `obstacle_force` and `separation_force` call
`grid.get(Vector2i(...), PackedVector2Array())`, and **the default argument allocates a
fresh empty Packed array on every one of the 9 cell probes, hit or miss** (~900 throwaway
allocations per steered tick) — use `has()` plus index, or a shared `static var _EMPTY`;
the ten `_p["flee_radius_m"]`-style string-keyed lookups sit **inside** the per-member
loop and should be hoisted; and the knock-over scan uses `distance_to` (sqrt) where
`distance_squared_to` against `knock_r * knock_r` is free.

## 3.5 Tire-mark mesh uploads

**File:** `scripts/tire_marks.gd` → `_emit_segment` → `_upload`.

`_upload` does `mesh.clear_surfaces()` + `add_surface_from_arrays(...)`. At 30 m/s with
`tire_mark_segment_step_m = 0.5` each wheel emits ~60 segments/s ⇒ **~240 complete
ArrayMesh surface rebuilds per second**, each preceded by `_sync_snapshot` copying the
whole ring. Under GL Compatibility every `add_surface_from_arrays` is a fresh buffer
allocation, an upload and a `surface_set_material` re-bind — a driver-level cost the CPU
profiler under-reports.

The ring-buffer machinery upstream is genuinely allocation-free and well built; the
problem is only the last mile.

**Options:** raise `tire_mark_segment_step_m` on mobile (fewest changes, immediate 2×,
**S**); coalesce uploads to at most one per wheel per *rendered* frame rather than per
physics tick (**S–M**); or move the ribbon to a `MultiMesh` of quads where laying a mark
is a single `set_instance_transform` with no buffer re-upload (**L**).

## 3.6 Prebaked LOD meshes hold ~30 MB of VRAM for chunks that are never drawn

**Files:** `terrain_manager.gd` → `cache_chunk()` / `_classify_chunk`; `terrain_lod.gd`
→ `build_all()`.

`ArrayMesh.add_surface_from_arrays` uploads to the RenderingServer immediately, so
**every corridor chunk's meshes live in GPU memory from load** — not just the
`RADIUS = 3` ⇒ 49 loaded ones. ~170 full-res chunks × 5 levels ≈ **~30 MB VRAM**
*(estimated)*. `cache_size_mb()` skips it entirely: `lod_meshes` is an `Array` of
`ArrayMesh` and the loop only sums `Packed*Array` values, so the shipped log understates
true footprint by roughly the whole GPU side.

The driver is the full-res classification, not the LOD prune: in `_classify_chunk`,
`closest_cam = min_dist − leash(15) − precompute_safety_slack_m(40)`, and the chunk
half-diagonal (35 m) is subtracted before that — so **any chunk within ~110 m of the
centerline gets `l_min == 0` → full-res → all five meshes prebaked.** That is a 220 m-wide
full-res ribbon to protect a 40 m replay-camera offset.

**Order of work:** log the true VRAM first (`Performance.RENDER_VIDEO_MEM_USED`); then
consider tightening `terrain_precompute_safety_slack_m` (the `GameConfig` field, copied into `TerrainManager.precompute_safety_slack_m`; sized for
`replay_camera.gd`'s FLYBY shot); then lazy-build the finest level on first spawn.

**Effort:** M. **Win:** ~10–20 MB VRAM *(estimated)*. **Do 1.6 first** — it is free and
strictly better.

## 3.7 Chunk-cache redundancy beyond the dead arrays

Distinct from 1.6 (which frees arrays that are simply never read again), these are
arrays that *are* read but need not be stored:

- **`indices` is byte-identical for every full-res chunk** — built from pure arithmetic
  in `data()` with no chunk-specific input. That is ~11 MB of duplicated buffer *and*
  ~180 × 15,000 GDScript loop iterations at load. One shared `static`
  `PackedInt32Array` per `_samples` value, memoised. Packed arrays are copy-on-write, so
  sharing the reference is free provided nothing mutates it. **S.**
- **`uvs` is `Vector2(world_x, world_z) * _tile`** (`_vertex_row`) — a pure function of
  the vertex's world position, which the vertex shader already has via
  `MODEL_MATRIX * VERTEX`. Deriving it in-shader drops the array: ~4 MB plus one
  `Vector2` construct per vertex at load. **M** (shader plus `TerrainChunk.apply_data`;
  note `uv2` interacts).
- **`heights` duplicates the `y` channel of `vertices`.** Either `_cached_height_at`
  reads `vertices[i].y`, or `vertices` is reconstructed from `heights` at `_spawn_chunk`
  time (only ~9 chunks are live at once). **S–M**, 2–6 MB.

Largely subsumed by 1.6 for the *resident* case; still relevant to load-time CPU and to
the on-disk cache format.

## 3.8 Deferrable work currently on the critical path

- **`ObstacleBody.build`** adds ~6,000 `PhysicsServer3D.body_add_shape` calls up front
  for the tree field. The runtime cost is already open item 3 in
  `performance-optimisations.md`; the *load* cost is also real and sits inside the
  "Scattering trees" bucket. Chunk across frames, or bin them as that item proposes.
- **`TerrainLod.build_all` per chunk in `cache_chunk`** (~666 ms measured) — "defer
  distant-chunk LOD prebake, build lazily on first render" is already listed as open
  there. **With 1.1 landed this becomes a clean win**, because a deferred build no longer
  competes with a 30 fps cap.
- **`world.gd::_drop_submerged`** rebuilds a whole `PackedVector2Array` for trees and
  again for bushes. Folding the water test into `TreeScatter.scatter`'s existing
  per-point reject chain removes two full array rebuilds and two passes over ~6,000
  points. Small but free.

## 3.9 Sign draw calls — noted, probably not worth it yet

`sign_field.gd::_build_multimeshes()` creates a `MultiMeshInstance3D` **per sign** (two
panel instances each) because `visibility_range` measures camera-to-node origin, and a
single track-wide batch anchored at the world origin would cull wrong. The header
acknowledges this.

`TreeMeshField` and `BillboardField` already solved the identical problem with **spatial
bins** (a per-bin MMI at the bin centre); applying `SpatialGrid.of_indices` here would
give the same cull granularity in a handful of draw calls. With `sign_sector_count = 4`
plus turn signs the visible count within 120 m is genuinely small today, so **only do
this if sign density grows.**

Separately, each sign is a `RigidBody3D` plus an `Area3D` waker — a CPU and broadphase
cost worth someone's attention independently of the draw-call question.

---

# 4. Small `project.godot` knobs

All **S**, all in `[rendering]`, none currently set:

- **`textures/default_filters/anisotropic_filtering_level`** — unset, so the default is
  **2 (4×)**. Every 3D material in the game is `TEXTURE_FILTER_NEAREST_WITH_MIPMAPS` for
  the PS1 look; anisotropic sampling on top of nearest is pure wasted bandwidth on a tile
  GPU. Set to `0`.
- **`mesh_lod/lod_change/threshold_pixels`** — unset (1.0). Every car GLB imports with
  `meshes/generate_lods = true` (verified in `blender/mx5/mx5.glb.import`), so the LODs
  exist and are barely used. 2–4 px on mobile is free triangles.
- **`limits/opengl/max_lights_per_object`** — unset (8). Only bites in HQ and garage (the
  stage has no lights), but it drives the GL-Compatibility shader variant's light loop.
  4 is plenty — HQ has one sun, garage has one sun plus per-bay omnis.
- **`meshes/create_shadow_meshes`** is `true` on every GLB import while the stage has no
  lights and no shadows — import-time and memory overhead for nothing. Safe to disable
  for stage cars; **check HQ and garage first**, they do have a sun.

**Explicitly not recommended:** occlusion culling (rolling terrain gives poor occluders
and the CPU raster cost on a phone likely exceeds the win); MSAA/TAA/SSAA (already off,
and inappropriate in GL Compatibility).

---

# 5. Correctness items found in the sweep

## 5.1 Web save persistence — release blocker

**File:** `scripts/save_manager.gd` → `_notification()`. **Owner:
`todo/web-save-persistence.md`** — cross-referenced here, not duplicated.

The only flush triggers are `NOTIFICATION_WM_CLOSE_REQUEST` (a desktop WM event the
browser never sends) and `NOTIFICATION_APPLICATION_PAUSED`. There is no
`visibilitychange`/`pagehide` listener, no `FS.syncfs`, and no `OS.has_feature("web")`
branch — despite `JavaScriptBridge.eval` already being used and proven in this codebase
(`web_fullscreen.gd`, `hq.gd`, `benchmark_report.gd`).

**This is a correctness, not a performance, item**, and the fix is a lifecycle listener
rather than anything about write cost: `save_now()` is cheap and correctly debounced at
1 s, and in IDBFS the rename operations are in-memory MEMFS work. The risk is purely that
the async IndexedDB sync never lands.

**It gates any public web release.**

> **Decision (2026-07-28): in scope, and it is item 1.0 — do it FIRST.** Upgraded from
> the original "cross-reference only" call once its status as a release blocker was
> clear. It sits in this section because it is a correctness fix, not because it is low
> priority; see the pointer at the top of Tier 1.
>
> Implement here; update `todo/web-save-persistence.md` to match (including its stale
> `thread_support=true` and `user://settings.cfg` claims — see §9) and retire it if this
> fully covers it. Settings ride on the same fix for free, since they persist through
> `Save.get_setting`/`set_setting` into `profile.json`.

**Effort:** M.

**Change:** add a `visibilitychange` / `pagehide` listener via `JavaScriptBridge.eval`
(proven in this codebase — `web_fullscreen.gd`, `hq.gd`, `benchmark_report.gd`) behind an
`OS.has_feature("web")` branch, flushing and then triggering an IndexedDB sync.

**Test:** assert that the web lifecycle path invokes the same flush entry point as the
desktop close notification — i.e. the flush is reachable on web, without asserting the
browser event itself. Keep the existing debounce behaviour covered.

**Success criterion:** on a real web build, make a career change, background or close the
tab, reopen, and confirm the change survived. This is a manual check and it is the whole
point of the item — do not mark it done without it.

## 5.2 Touch events are processed twice

`project.godot` leaves `input_devices/pointing/emulate_mouse_from_touch` at its default
`true`, and `mobile_controls.gd::_input` handles **both** touch and mouse events — so
each finger is processed twice, once at `event.index` and once at index −1. Harmless
today (the slider capture and the `_pointers` dict both tolerate it), but it doubles
touch event work and is a latent source of odd multi-touch states.

**Proposed change:** set `emulate_mouse_from_touch = false` and keep the touch path only.

**Safe default — do this without waiting for an answer:** ignore index −1 inside
`mobile_controls.gd::_input`. That halves the touch work with **no project-wide effect**,
so nothing else can regress.

**Optional follow-up, needs a user answer:** setting
`emulate_mouse_from_touch = false` project-wide is cleaner but riskier — it would break
anything relying on touch-generated mouse events (Control-based UI in HQ or the garage,
any menu driven by mouse rather than `MenuNav`). Ask before doing that one.

**Test:** a multi-touch nav test asserting two simultaneous touches produce two distinct
pointers.

## 5.3 Dead billboard shader

`billboard_field.gd` preloads both `BILLBOARD_SHADER` and `BILLBOARD_OPAQUE_SHADER` and
picks on `use_opaque`, but the only production caller — `foliage.gd::spawn_trees` —
passes `true` unconditionally ("Trees are ALWAYS opaque billboard cutouts"). The quad
path is the one with the per-fragment `discard` that `billboard_opaque.gdshader`'s own
header describes as disabling early-Z/HSR for the whole draw on tile-based GPUs. It is
unreachable outside tests but still ships.

**Proposed change:** delete `shaders/billboard.gdshader`, the `BILLBOARD_SHADER` preload,
and the `use_opaque` branch in `billboard_field.gd`.

**This breaks the tests that are its only remaining callers** — they must be updated or
removed in the same change. Confirm no test is actually asserting the transparent path's
*behaviour* (as opposed to merely exercising it) before deleting.

**Alternative if the branch is wanted for future use:** keep it but document it as
test-only in the file header, so the next audit does not re-report it.

## 5.4 Latent visual bug

`wheel_particles.gd` sets `mat.albedo_color = cfg.wheel_particle_color` but never sets
`transparency`, so the material is opaque and the config colour's alpha is silently
ignored — unlike `engine_smoke.gd`, which does set `TRANSPARENCY_ALPHA`. Needs a
designer's eye on whether the dust is meant to be translucent.

**Question for the user:** should wheel dust be translucent like engine smoke? If yes,
set `TRANSPARENCY_ALPHA` on the material to make `wheel_particle_color`'s alpha
meaningful. If no, remove the alpha channel from the config field's documentation so it
stops implying an effect it does not have.

**Not a performance item** — listed only because the sweep found it.

---

# 5A. Considered and recorded — NOT in the work list

These are real findings, kept so a future audit does not re-derive them, but the spec's
own analysis concludes they should not be scheduled. **Skip them when working top-down.**

| item | why it is not scheduled |
|---|---|
| **2.6** prebake free-roam/benchmark tracks | Low value (free roam only) — but **not skippable in isolation**: land it inside the 2.3/2.4 cache-regeneration batch, per the Tier 2 sequencing note, or you pay a second `CACHE_VERSION` bump. |
| **2.12** PWA service worker | Cut — folded into 1.3 as versioned cache headers. |
| **3.7** further chunk-cache redundancy | Largely subsumed by 1.6, which frees the same arrays outright. Only relevant to load CPU and the on-disk format. |
| **3.9** sign draw calls | Visible sign count within 120 m is small today; the per-sign MMI is a documented deliberate trade. Revisit only if sign density grows. |
| **5.3** dead billboard shader | Saves a few KB and breaks its only remaining callers (tests). Cleanup, not performance. |
| **5.4** wheel-dust alpha | A visual bug, not a performance item. Needs a designer answer, not engineering time. |
| **perf_log early-return** (in 2.9) | ~0.01% of a frame; the protective test costs more than the win. |

# 6. Verified clean — do not re-audit

Recorded so future sweeps don't re-derive these.

**Runtime:** `TerrainManager` chunk streaming (`update_focus` early-returns unless the
focus crosses a chunk boundary; `_reconcile` is genuinely event-driven);
`TerrainManager.surface_at` (correctly hoisted out of the drivetrain substep loop);
the `CpuParticlePool` single-buffer upload design; `car.gd`'s `_resolve_drive_inputs` /
`_update_steering` / `_step_replay` scratch buffers (allocation-free, with comments
explaining why); `EngineAudio`'s cached car/engine/config refs; `TreeMeshField` and
`BillboardField` `_process` (self-disabling via `set_process(false)` once falls land);
`RallySession` and `StageManager`; `Drivetrain.readouts` (gated on `publish_readouts`);
`Car.downforce_readouts` (gated on overlay visibility); `_debug_overlay` toggles (gated
on `OS.is_debug_build()`). **No per-frame raycasts exist in the gameplay path** —
`intersect_ray` appears only in `car.gd`'s one-shot wheel settle and `hq.gd`'s mouse
picking.

**Threads — narrowed claim.** `grep` for `Thread` / `WorkerThreadPool` / `Mutex` /
`Semaphore` / `load_threaded` across `scripts/` and `tools/` returns **zero** hits (only
`addons/gut/`, excluded from every export). `variant/thread_support = false` is correct
and `serve_web.sh`'s "no SAB, no COOP/COEP needed" note is correct.

> **This only clears *user* threading code.** It does **not** clear engine-internal async
> APIs that silently fall back to the main loop when threads are unavailable — and 2.5 is
> exactly that failure (`NoiseTexture2D` bakes on an engine worker that does not exist on
> web, costing the entire 1121 ms "lakes" stage). A GDScript grep would never have caught
> it.
>
> **Outstanding sweep:** audit engine APIs with implicit threading —
> `NoiseTexture2D`/`NoiseTexture3D` and other procedural texture bakes, `ResourceLoader`
> async paths, `Image` compression/mipmap generation, and any `*.changed`-driven resource
> baking — for other instances of the same pattern. Not yet done.

**Audio:** no bus effects anywhere (`music_director.gd` adds a bare Music bus, no reverb
or compressor); exactly one live `EngineAudio` per stage (`car_prop.gd` calls
`silence_engine_audio()` on every display and queue prop); the
`BUFFER_SECONDS_TOUCH = 0.2` + `output_latency.web = 150` pairing is correctly reasoned
in `features/engine-audio.md`.

**Export excludes:** the parsed pack directory contains **zero** files under `addons/`,
`tests/`, `docs/`, `ref/`, `todo/`, `features/`, `benchmark/`, and no `.blend`. GUT
(3.1 MB), `ref/` (28 MB of screenshots) and `blender/*.blend` (28 MB) are all genuinely
out. The only residue is `.godot/uid_cache.bin` leaking dev paths — cosmetic, ~77 KB.

**DPI:** `project.godot` sets `stretch/mode = "viewport"` with `viewport_height = 360`,
and `display_stretch.gd` drives `content_scale_mode = CONTENT_SCALE_MODE_VIEWPORT` with
`DESIGN_HEIGHT` read from that same setting — so a 3× DPI phone still renders ~640×360
and scales up. **No over-rendering to fix.**

**Other web APIs:** no `RegEx` anywhere in `scripts/`; no
`ResourceLoader.load_threaded_*`; `FileAccess` limited to the two JSON lockfiles plus the
save file; all `OS.*` calls are feature/debug queries; all four `JavaScriptBridge.eval`
sites are guarded and trivial. `data/track_cache.json` (248 KB) earns its weight.
Models are 0.257 MB total in the PCK — polycount is irrelevant to *size* (though 3.1
shows it is very relevant to vertex cost). `fonts/SyneMono.ttf` is 72 KB → 39 KB fontdata.

**Not an allocation hazard:** bare `for i in range(n)` compiles to a counted-loop opcode
in GDScript 4. Only `range(a, b)` and `range(a, b, c)` in inner loops are worth
converting (see 2.3).

---

# 7. Measured baseline

**Web build, 55.4 MB total:**

| component | bytes | gzip | brotli(q5) |
|---|---|---|---|
| `build/web/index.wasm` | 37,700,666 | 9.44 MB | 7.76 MB |
| `build/web/index.pck` | 17,324,664 | 8.92 MB | — |
| `index.js` + html + icons | ~0.39 MB | — | — |

**PCK contents** (parsed from the pack directory, 481 files, 16.52 MB):

| group | MB | files |
|---|---|---|
| `.godot/imported/*.ctex` (textures) | **10.64** | 63 |
| `.godot/imported/*.oggvorbisstr` (music) | **4.47** | 24 |
| `scripts/*.gdc` | 0.645 | 234 |
| `data/*.json` (track + opponent cache) | 0.294 | 2 |
| `.godot/imported/*.scn` (all car + vegetation models) | 0.257 | 18 |
| fontdata / shaders / misc | ~0.17 | rest |

Fifteen `.ctex` files are exactly 699,050 B each (1024² S3TC with mipmaps) = **10.0 MB,
61% of the PCK**. **Fourteen are car body textures** (7 orphans + 7 live — enumerated in
§8); the fifteenth is a non-car 1024² mode-2 texture. Note that the two *live* bodies
already on `compress/mode = 1` (`blender/911/texture.png`,
`blender/mx5/mx5_texture.png`) are **not** in this set and cost ~0.1 MB each — they are
outside 2.10's −3.5/−4.0 MB, which covers only the 7 live mode-2 files.

**Runtime anchor** (native desktop, from `features/debug-tools.md`):
`[perf-scripts] ms/frame: engine_audio=0.956 car=0.189 …`

**Memory:** corridor chunk cache 35–40 MB (~155–175 full-res chunks); bake dictionaries
25–40 MB *(estimated, unmeasured)*; prebaked LOD meshes ~30 MB VRAM *(estimated)*.

---

# 8. Estimated combined effect

Recomputed after the round-1 and round-2 spec corrections. **Compressed figures are
compared against compressed figures** — the headline "55 MB" is the uncompressed build
and is not the right baseline for a download claim.

> ### ✅ MEASURED 2026-07-28 — both items landed, PCK **17,349,280 B → 7,612,460 B (−56.1%)**
>
> | build | entries | `index.pck` |
> |---|---|---|
> | baseline | 483 | 17,349,280 B |
> | after **1.5** (orphans + sidecars excluded) | 455 | 12,369,260 B (**−4.75 MB**) |
> | after **2.10 + §4** | 455 | **7,612,460 B** (a further **−4.54 MB**) |
>
> Criterion (b) satisfied: all 7 orphan `.ctex` confirmed **gone** from the pack
> directory; all 9 live body textures confirmed **present**, re-derived
> programmatically from `car_library.gd` rather than from this spec's table. The 9 live
> bodies went from 699,116 B each to 20,368–33,902 B. Car-park visual check passed.
>
> **`detect_3d/compress_to = 0` was the missing piece and is NOT in the original item.**
> With Godot's default of `1`, a 3D-sampled texture is silently re-imported as
> VRAM-compressed on first 3D detection — **which is how these drifted to mode 2 in the
> first place**, and would have quietly undone this entire item within one editor
> session. Any future texture work must set it explicitly.
>
> ⚠️ **`build/web/` still holds the OLD build.** The measurement exports went to `/tmp`
> deliberately, because `build_web.sh` temporarily rewrites `project.godot` and would
> have raced the other agents. Re-run `build_web.sh` before shipping or re-measuring.

**Download (PCK).** The two savings are **disjoint — verified, not assumed.** There are
14 car body textures at 1024² with `compress/mode = 2` (699,050 B each in the PCK); two
further live bodies (`blender/911/texture.png`, `blender/mx5/mx5_texture.png`) are
already mode 1 and cost ~0.1 MB. The 14 split cleanly:

| set | files | item |
|---|---|---|
| **7 orphans** (all mode 2, 1024²) — `911/911_texture`, `focus/texture`, `mx5/mx5_Untitled`, `thebeast/texture`, `twingo/texture`, `viper/viper_texture`, `xjs/xjs_texture` | 7 × 699,050 B | **1.5** removes |
| **7 live** (all mode 2, 1024²) — `acty/acty_texture`, `charger/charger_texture`, `focus/focus_texture`, `thebeast/mrbeast_texture`, `twingo/twingo_texture`, `viper/texture`, `xjs/texture` | 7 × 699,050 B | **2.10** resizes |

| item | saving |
|---|---|
| 1.5 remove the 7 orphans | −4.67 MB |
| 2.10 resize the 7 live bodies to 512 + lossy | −3.5 to −4.0 MB |
| **PCK total** | **16.5 MB → ~8 MB** |

2.11 (lazy music) is **excluded here** — it explicitly saves no download, only boot
allocation. Optional music re-encoding would add ~1.2–1.5 MB but is a quality decision.

**Download (wasm): no win available.** Resolved 2026-07-28 — itch/Cloudflare already
gzips it to **9,925,878 B** on the wire (measured). See 1.3. The only remaining lever on
the wasm is **2.13**, a size-optimised custom export template.

**First load — measured, compressed-to-compressed.** Today the browser actually fetches
**~9.93 MB wasm + ~9.28 MB PCK ≈ 19.2 MB**. After the PCK work (1.5 + 2.10) the PCK
roughly halves, giving **~14–15 MB**. There is no "46 MB" scenario — that was the
uncompressed on-disk figure, never what a player downloaded.

**Resident RAM:**

**Measured 2026-07-28** where marked. The estimates that have since been measured came in
**lower** than predicted — treat any remaining *(estimated)* figure here as an upper
bound, not a target.

| item | saving | basis |
|---|---|---|
| 1.6 free dead chunk arrays | **~37 MB** | measured: 46.2 MB → 9.2 MB cached on a real stage; per-chunk 226 KB → ~30 KB |
| 1.7 free `lights` post-load | ~7 MB | included in the residual below |
| 2.7 free bake dictionaries | **~6–9 MB** | measured dict entry counts (~99k) — the 20–30 MB estimate was 3–4× too high |
| 2.11 lazy music | ~4.3 MB | boot allocation, not download |
| **total** | **~47–50 MB** | |

1.6 and 1.7 together take the corridor chunk cache to roughly **heights-only**, which is
where the bulk of this comes from. Note 1.6 over-delivered relative to its ~27 MB estimate
while 2.7 under-delivered — they roughly cancel.

**VRAM (separate budget, and it competes for the same mobile tab limit):**

| item | saving |
|---|---|
| 3.6 lazy/tightened LOD prebake | ~10–20 MB *(estimated)* |
| 2.10 smaller car textures | a few MB |

**Web load time:** unquantified until 1.1's Step 0 and a re-capture. What can be said:

- The **carve and full-res precompute** numbers in the old table are roughly sound — they
  have ~0 frame-cap idle. Optimising them remains legitimate work.
- The **track-generation** number is heavily contaminated, and that stage is **free-roam
  and benchmark only**.
- **Career mode's 1.1 win is order 1–2 s** — the corridor pre-warm frames plus the
  coarse-chunk precompute batches. Real, but not transformative.
- The largest *career* load costs are therefore still the carve and the chunk precompute
  themselves, which is what `todo/performance-optimisations.md` already targets.

---

# 9. Documentation debt to close

Per the project's self-correcting-index rule, these must be fixed in the same piece of
work. **Each is assigned an owning item** so none is left to "whoever touches the area":

| doc debt | owned by |
|---|---|
| new `features/loading.md` (stage pipeline, chunk-cache layout) | **1.2** |
| new asset-pipeline / export-sizing doc | **1.5** (create) and **2.10** (extend) |
| `features/rendering.md` quality-tier + resolution corrections | **3.2** |
| `features/rendering.md` texture-compression note | **2.10** |
| `fog_density` three-way drift | **3.2** |
| `features/drivetrain-and-tires.md` substep note | **3.3** |
| `todo/web-save-persistence.md` corrections / retirement | **5.1** |
| `todo/performance-optimisations.md` stale threading machinery | **1.2** |
| `todo/performance-optimisations.md` correction header — including **withdrawing it** if 1.1's Step 0 shows `Engine.max_fps` does not pace web frames | **1.1** |
| `build_web.sh` stale header comment | **1.3** |

The individual items:

- **`features/rendering.md`** claims the game "ships one lean pipeline for every device
  (no quality tiers)" — stale; the web-touch tier exists and is documented two sections
  lower. Neither file records that `[importer_defaults] compress/mode = 1` means most
  textures are uncompressed in VRAM (2.10).
- **`fog_density` has drifted three ways.** `features/rendering.md` says `0.012`;
  `game_config.gd`'s `@export` default and `main.tscn`'s env both say `0.005`; and
  `config/game_config.tres` — **the shipped, effective value**, since `world.gd` assigns
  `env.fog_density = cfg.fog_density` — says **`0.02`**. Document `0.02` and reconcile
  the rest. (Per the project's config rule the `.tres` is authoritative; the script and
  scene literals are fallback defaults.)
- **`todo/performance-optimisations.md`** describes frame-budgeted threaded generation
  machinery — `_use_budgeted_generation()`, `is_streaming_chunks()`,
  `MAX_BUILD_ROWS_PER_FRAME`, `DistantTerrain.ROWS_PER_FRAME`, `force_main_thread_budget`
  — that appears **only in that document** and never in `scripts/`. Its per-stage table
  also needs the frame-cap correction header (being added alongside this spec).
- **`build_web.sh`**'s header still claims "Terrain generation runs on a frame-budgeted
  main-thread queue on web". Same stale machinery.
- **`todo/web-save-persistence.md`** states "The export is threaded…
  `thread_support=true`… itch.io must enable SharedArrayBuffer" — the **opposite** of the
  shipped preset, and it would send someone down a dead end. It also says settings live in
  `user://settings.cfg`; they don't — `settings_menu.gd` goes through
  `Save.get_setting`/`set_setting` into `profile.json`, and there is no `ConfigFile`
  anywhere in `scripts/`. **Fixing the save flush fixes settings for free.**
- **No `features/` file covers the load-time stage pipeline** (`world.gd::_stage`,
  `_end_load_timing`, `_prewarm_corridor`) or the chunk-cache memory layout — which is
  exactly where anyone chasing load performance needs to start. A `features/loading.md`
  would have prevented the 1.2 mismeasurement.
- **No `features/` file covers the asset pipeline / export sizing** — import modes, which
  texture belongs to which car, why `blender/` is inside the export at all.
