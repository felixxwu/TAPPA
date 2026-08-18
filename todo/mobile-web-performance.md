# Mobile + Web Performance — remaining work

> **Status: the bulk of this spec is IMPLEMENTED and committed.** Completed items have
> been struck; what follows is only what is left, plus the history worth keeping.
> `todo/mobile-web-performance-plan.md` has been deleted — it was fully executed.
>
> The implementation detail for everything landed now lives in the code and in
> `features/` (`loading.md`, `terrain.md`, `asset-pipeline.md`, `rendering.md`,
> `engine-audio.md`, `progress.md`, `tire-marks.md`, `spectators.md`,
> `mobile-controls.md`, `save-persistence.md`, `debug-tools.md`, `menus.md`).
>
> Related: `todo/performance-optimisations.md` (carve/cliff deep-dive; carries a
> frame-cap correction header), `todo/web-save-persistence.md`, `todo/audio.md`.

---

## What landed, measured

| area | result |
|---|---|
| PCK (download) | **17.35 MB → 7.61 MB (−56.1%)** — orphan textures + sidecars excluded, live bodies 512/lossy |
| Terrain chunk cache | **226 KB → ~30 KB per chunk** (46.2 → 9.2 MB) |
| Prebaked LOD VRAM | **26.8 MB → 7.6 MB** added by the corridor prebake (~19.2 MB freed) |
| Road/cliff bake dicts | freed post-load (~6–9 MB, measured — not the 20–30 MB estimated) |
| Music at boot | 4.47 MB preloaded → ~750 KB lazy |
| HQ boot | **1442 ms → 352 ms** (prewarm moved off the critical path) |
| HQ ground plane | **58,081 → 1,681 verts (−97%)**; podium −91% |
| Engine synth | mix rate halved on web-touch, noise table, inaudible-skip |
| Centerline lookups | ~26,000 `sample_baked` calls/sec → array indexing |
| Spectator steering | ~4,000 `on_road()` probes/tick → **0** for a settled crowd |
| Render resolution | ~~360 → 288 on web-touch (~36% fewer fragments)~~ — **reverted 2026-08**: web-touch now renders at the same authored 360 as every other target, no per-platform resolution tier |
| Web saves | now flush on `visibilitychange`/`pagehide` |
| Live-reload poller | no longer ships to players |

---

## Corrections — premises that turned out WRONG

Kept deliberately: each of these was a confident claim in the original audit that
measurement or implementation refuted. Re-deriving them would waste the same effort again.

1. **The wasm compression win did not exist.** GitHub Pages does not serve the game — it
   publishes a redirect to itch.io, and itch/Cloudflare already gzips `index.wasm` to
   ~9.93 MB. Real first load is ~19.2 MB, never the 55 MB on-disk figure. **Do not add a
   pre-compression step**: butler uploads `build/web` verbatim, so a `.gz` would ship as
   an extra unreferenced file. Brotli (~1.7 MB more) is itch's setting, not ours.
2. **The frame-cap idle is NOT uniform, and it IS real.** Measured on a real web export:
   33.42 ms/frame at cap 30 vs 8.34 ms uncapped. But the limiter sleeps only the
   *remainder* of the frame budget, so idle is ~0 where work between yields is heavy
   (carve, full-res chunk batches) and near a full frame where it is cheap (the DFS).
   When measuring in a browser, **foreground the tab** — Chrome suspends `rAF` in a
   background tab and produces junk samples.
3. **Free roam is unbakeable.** `hq.gd::_prepare_free_roam` randomises `track_seed`,
   `track_water_level_m` and `terrain_layer1_amplitude` per entry, all of which feed the
   cache key. Its DFS cost is permanent unless that randomisation changes — a gameplay
   decision. Only the benchmark stage and the default-config boot were bakeable.
4. **The ±3 m centerline window would have broken corner cutting.** `_accrue_cut`
   detects a cut by the nearest-point offset *leaping* tens of metres at a hairpin neck.
   **The search window is load-bearing — optimise the per-probe cost, never the window.**
5. **HQ's memory problem was not mesh duplication** (~26 KB/prop). It was the prewarm at
   ~3× the rest of boot.
6. **Subdiv 64 was not viable for the ground plane.** The HQ plane is 240 m and the
   feather band 3 m, so 64 gives 3.75 m cells and the band collapses into one — a hard
   seam. A non-uniform grid was needed.
7. **`detect_3d/compress_to = 0` is load-bearing** and was missing from the audit. With
   Godot's default of `1`, a 3D-sampled texture is silently re-imported as
   VRAM-compressed — which is how the car textures drifted to mode 2 originally, and
   would have undone that item within one editor session. **Extended 2026-07-30:** the
   audit only covered car *bodies*; seven of the eight `blender/*/wheel.*` were still on
   the default `1`. The cosmetic wheel swap made every wheel texture 3D-sampled on every
   body, and `blender/xjs/wheel.png` is 127×127 — not ETC2/ASTC block-aligned — so the
   drift would have been an Android-only breakage. All wheel imports are now
   `detect_3d/compress_to = 0` and `tests/headless/test_wheel_texture_imports.gd` asserts
   the rule (not the values). See features/asset-pipeline.md.
8. **2.7's 20–30 MB estimate was 3–4× too high** (~99k dict entries ≈ 6–9 MB), while
   1.6 over-delivered. Treat any remaining *(estimated)* figure as an upper bound.
9. **Freed-data flags must latch on the DATA, not the event.** `_generate_track` can run
   a second time on a booted world, rebuilding what was freed while `load_finished`
   stays latched. **If you add a subscriber that frees something, add a sentinel that
   `push_error`s on a post-free read** — the failure mode is silent wrong data.
10. **Engine APIs with implicit threading silently degrade on web.** `NoiseTexture2D`'s
    "bakes on a worker thread" is conditional on threads existing; with
    `thread_support = false` it became a 1121 ms main-loop stall with no warning.

---

# Remaining work

## In progress

**F1 — the initial 7×7 chunk ring bypasses the corridor cache.** Found during the LOD
work: `TerrainManager._process` runs during the loading yields, sees an empty
`_chunk_cache`, and on-demand-builds all 49 chunks *before* the precompute;
`build_initial` then skips them. So 49 chunks are built twice and stay non-lazy until
first despawn. Constraints to respect: the car spawn raycast, `_warm_up_point()`,
`_prewarm_corridor()` and headless synchronous builds all need terrain early.

## Deferred — need a decision or a device

### 3.3 Physics tick rate and drivetrain substeps

**Files:** `project.godot [physics]` (no `physics/common/physics_ticks_per_second`
override exists — verified); `scripts/drivetrain.gd` (`SPIN_SUBSTEPS = 8`, with
`engine.step()` called **inside** the substep loop).

On a phone browser capped at 30 fps the engine runs **two physics ticks per rendered
frame**, and each tick pays `car._timed_physics_process` + `drivetrain.step` (8 full
`EngineSim.step` and turbo integrations, i.e. **960 engine steps/second**) +
`track_progress` + `tire_marks` + `spectator_group` + `bush_field` + `wheel_particles` +
`engine_smoke` + `chase_camera`.

**This is the largest remaining runtime lever, and the only change that can alter how the
car feels.** Neither option may land without a side-by-side feel test on a real device
and a full physics-test pass.

- **Option A — scale `SPIN_SUBSTEPS` by platform** (8 → 4 on mobile/web), with the count
  derived from a target substep *duration* rather than a fixed number. Halves drivetrain
  and engine cost without touching chassis integration. `SPIN_SUBSTEPS` is a stability
  constant, not a designer tunable, so this is a legitimate platform knob. Requires
  `features/drivetrain-and-tires.md` updated. **M.** *Try this first.*
- **Option B — `physics_ticks_per_second = 30` on mobile/web.** Halves everything at a
  stroke. Risk: the substepped tire solver is tuned for `delta/8`; at 30 Hz the substep
  becomes 4.2 ms and the stability caps in `_tire_force` (which divide by `h`) loosen.
  **M**, higher risk, and hard to un-ship once tuning drifts around it.

**Test:** the existing physics tests are the guard and must pass unchanged. If one
breaks, the change is the suspect — do not weaken a threshold to get green. Assert the
substep count is *derived from a duration*, never the count itself.

### 2.13 Size-optimised custom web export template

**Files:** `build_web.sh`, `export_presets.cfg`. **Effort: L.**

Now the **largest remaining download lever**, precisely because transport compression
turned out to be a non-lever (correction 1). The wasm is ~9.93 MB gzipped against a PCK
now around 4–5 MB, so it dominates.

A template built with `optimize=size` and unused modules disabled. The evidence for what
is safe to strip is in §6 below: no `RegEx` anywhere in `scripts/`, no threads, no
GDExtension, no `ResourceLoader` async. Navigation, CSG, multiplayer/ENet, WebRTC, WebXR,
Theora and the mobile/forward-plus renderers (the game ships GL Compatibility) are all
candidates.

Cost: building and maintaining a custom template in CI, and **a stripped module fails at
runtime, not at build time**. **Success criterion:** a full playthrough of a career stage
plus HQ, garage, podium and standings on the custom build.

### Small, holding — RESOLVED, none left

Both entries that sat here have landed: `lazy_finest_lod` / `detail_builds_per_frame` are
config-driven (`GameConfig.terrain_lazy_finest_lod`, `terrain_detail_builds_per_frame`,
plus `cfg.overworld_chunk_build_budget` for the overworld), and
`emulate_mouse_from_touch` has no entry in `project.godot` at all — the project runs the
engine default with `mobile_controls.gd` filtering `DEVICE_ID_EMULATION`, so there is
nothing to flip.

## Verification still outstanding

- **Re-run `build_web.sh`** — `build/web/` is stale; the −56.1% PCK was measured from a
  `/tmp` export.
- **Re-capture the web `load stage:` table** on a **non-benchmark** boot (career *and*
  free roam), tab foregrounded. This is the payoff for the frame-cap work and is still
  unmeasured post-change.
- **A real phone.** Two remaining tier values (`ground_subdiv_web_touch`,
  `engine_mix_rate_web_touch`) are conservative defaults chosen without one.
- **A replay pass** if `terrain_precompute_safety_slack_m` (now 25, was 40) is suspect —
  the failure mode is unbuilt terrain in a replay shot.

## Not scheduled — recorded so a future audit does not re-derive them

| item | why |
|---|---|
| **3.7** further chunk-cache redundancy | Largely subsumed by the array frees. Only relevant to load CPU and the on-disk format. |
| **3.9** sign draw calls | Visible sign count within 120 m is small; the per-sign MMI is a documented deliberate trade. Revisit only if density grows. |
| **5.3** dead billboard shader | Saves a few KB and breaks its only remaining callers (tests). Cleanup, not performance. |
| **5.4** wheel-dust alpha | `wheel_particles.gd` sets `albedo_color` but never `transparency`, so the config alpha is silently ignored. A visual bug needing a designer answer. |
| **PWA service worker** | Cut — a worker caching a ~37 MB wasm can pin players to a stale build. Versioned cache headers cover the benefit. |
| `.godot/uid_cache.bin` leaking dev paths | ~77 KB, cosmetic. |
| Brotli (~1.7 MB) | itch/Cloudflare's setting, not ours. |

## Remaining documentation debt

- **`features/` has no web deploy/hosting page.** The itch-vs-GitHub-Pages topology is
  non-obvious and had to be derived from scratch; the next person will too.
- **`features/drivetrain-and-tires.md`** will need the substep note if 3.3 lands.
- **`tools/render_hq_carpark.gd`** only grants 5 of the 9 cars, so half the roster is
  never visually verified by the render harness.

---

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

# 7. Pre-work baseline (HISTORICAL — superseded)

> These are the **before** numbers, kept only so the deltas above can be checked. They no
> longer describe the build. In particular: the PCK is now ~7.6 MB not 17.3 MB, the
> chunk cache ~9.2 MB not 35–40 MB, and the "55.4 MB total" is an on-disk figure that was
> never what a player downloaded (~19.2 MB over the wire — see correction 1).

**Web build as it was, 55.4 MB on disk:**

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

**Memory as it was:** corridor chunk cache 35–40 MB; bake dictionaries estimated
25–40 MB (**actually ~6–9 MB** once measured); prebaked LOD meshes estimated ~30 MB VRAM
(**actually 26.8 MB** — the one estimate that held).

---
