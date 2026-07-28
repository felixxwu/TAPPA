# Mobile + Web Performance — Implementation Plan

> **Spec:** `todo/mobile-web-performance.md`. This document does not restate the
> findings; it says **who does what, in what order, and which files they may touch.**
> Read the spec item before implementing it — the correction blocks matter.
>
> **Structured for parallel subagents.** The organising principle is **file ownership**,
> not subsystem. Three files (`world.gd`, `terrain_manager.gd`, `track_generator.gd`) and
> one resource (`game_config.gd` / `game_config.tres`) are touched by items scattered
> across all three tiers; the waves below exist to stop two agents editing them at once.

---

## The rules every agent follows

1. **Never touch a file you do not own.** Ownership is listed per workstream and is
   exclusive for the duration of the wave. If you need a change in someone else's file,
   stop and report it — do not make it.
2. **One workstream = one commit** (or a small clean series). Do not bundle unrelated
   items.
3. **Tests in the same commit**, per `CLAUDE.md`. Follow the spec's test policy: never
   assert a tunable value; assert behaviour. Use `CarFixtures.install()` for
   catalogue-touching tests and `SceneTestHelpers.minimal_world()` where the track and
   terrain are not under test.
4. **Run the tests your blast radius implies**, generously, before reporting done. Do
   **not** run the full suite by reflex, and **never** start a run while another
   `./run_tests.sh` is in progress.
5. **Update `features/` docs in the same work** — the spec's §9 assigns an owner to every
   doc-debt item. Look up yours.
6. **Do not create branches or worktrees.** Work in this checkout, on the current branch.
7. **If an existing test breaks, the change is the suspect, not the test.** Do not weaken
   a threshold or delete an assertion to get green.

---

## Wave 0 — the shared-surface pass (ONE agent, blocks everything else)

**Why this exists:** almost every later workstream wants to add a `GameConfig` field or
hang off a "load finished" moment. If eight agents each edit `game_config.gd` and
`world.gd` to do that, you get eight merge conflicts in the two largest files in the
project. So one agent lays the shared surface down first and everyone else only *reads*
it.

**Owns:** `scripts/game_config.gd`, `config/game_config.tres`, `scripts/world.gd`.

**Tasks:**

1. **Add every `GameConfig` field the plan needs, with conservative defaults**, resolved
   through the existing `*_for(web, touch)` helper pattern that `tree_render_distance_for`
   already uses (per spec 2.1 and 3.2 — do **not** invent a second notion of "mobile"):
   - engine synth mix rate (spec 2.1)
   - HQ / podium ground subdivision (spec 3.1)
   - render-resolution tier values (spec 3.2) — **field only, not yet wired**
   Leave the values at today's behaviour so this wave is a no-op at runtime.
2. **Add the shared "load finished" hook** in `world.gd::_ready`, on the line **after**
   the `_end_load_timing()` call — never inside it, which early-returns on
   `_headless or _stage_label == ""` and would never fire under the test runner. It must
   fire unconditionally, headless included. (Spec: Tier 2 sequencing note.)
3. **Item 1.2** — fix the load-stage boundaries (`_stage` before `_prewarm_corridor` and
   before the spectators/arches/wreck block). This is in `world.gd` and must not collide
   with Wave B.

**Test:** the load-finished hook fires exactly once per load, including headless.

**Docs:** create `features/loading.md` (spec §9 assigns it to 1.2), and fix the stale
threading machinery in `todo/performance-optimisations.md`.

**Do not** change any tuning value in this wave. Fields only.

---

## Wave A — fully parallel, zero file overlap

Eight independent workstreams. **All can run simultaneously.** None shares a file with
another.

| # | Item(s) | Owns (exclusive) | Effort |
|---|---|---|---|
| **A1** | **1.0 / 5.1** web save persistence — *highest priority in the whole plan* | `scripts/save_manager.gd`, `todo/web-save-persistence.md` | M |
| **A2** | **2.1** engine synth: mix rate, inaudible skip, noise table | `scripts/engine_audio.gd`, `scripts/engine_audio_synth.gd` | S–M |
| **A3** | **2.2** centerline lookup | `scripts/track_progress.gd`, `scripts/tire_marks.gd` | S then M |
| **A4** | **2.5** lake water texture | `scripts/lake_field.gd`, new texture asset | S |
| **A5** | **2.8** opponent-cache fingerprint memo | `scripts/opponent_cache.gd`, `scripts/track_cache.gd` | S |
| **A6** | **2.11** lazy music loading | `scripts/music_library.gd` | M |
| **A7** | **1.3** wasm compression + versioned cache headers | `.github/workflows/deploy.yml`, `build_web.sh`, `serve_web.sh` | S |
| **A8** | **2.14** HQ boot instrumentation | `scripts/hq.gd` | M |

**Notes per stream:**

- **A1** — do this first if you only run one thing. A build that loses career progress
  makes every other item worthless. Manual success criterion (change → close tab →
  reopen → survives) is mandatory.
- **A2** — read the mix-rate field from `GameConfig` (Wave 0 created it); do not add a
  `Platform` branch on the `const`. Re-check `skip_count()` in the benchmark after,
  since buffer frame counts change.
- **A3** — **try the cheap version first**: incremental ±3 m tracking off `_prev_offset`,
  with a full-search fallback on reset/teleport. Only build the shared baked table if
  `sample_baked` still shows up. If you do build it, **interpolate** — do not truncate.
- **A4** — state the committed texture's import mode explicitly; do not leave it on
  importer defaults.
- **A5** — scope the memo to runtime; expose `reset_cache()` and call it from the cache
  generator tools, or the lockfile regeneration in Wave C can bake a stale fingerprint.
- **A7** — **step 1 is just reading response headers on the deployed URL.** Do that
  before writing any code; it may turn out there is nothing to fix.
- **A8** — land the instrumentation only. Do not bound the cache yet; that is a follow-up
  decision once the user has numbers.

---

## Wave B — the terrain cluster (ONE agent, serial internally)

`terrain_manager.gd` is touched by four spec items and they interact. One agent, one
sequence.

**Owns:** `scripts/terrain_manager.gd`, `scripts/terrain_chunk.gd`,
`scripts/terrain_chunk_builder.gd`.

**Runs in parallel with:** Wave A, Wave C, Wave D.

**Order (do not reorder):**

1. **1.6** — free the five dead chunk-cache arrays. **Handle `TerrainChunk.apply_data`'s
   `build_all` fallback**: assert `lod_meshes` is non-empty for cached chunks, or remove
   the fallback. Leaving it is a landmine.
2. **1.7** — free `lights` on the Wave 0 hook. **Add the "freed" sentinel** — the current
   `_cached_light_at` falls through silently to live noise, so without it a later
   regression is invisible.
3. **2.7** — free the bake dictionaries behind a corridor-complete gate. Land the
   `.size()` logging in the same commit. Keep `track_weights` / `track_surface` —
   `surface_at()` needs them per tick.
4. **2.9 (terrain bullet only)** — cache `_focus_node()` instead of resolving a NodePath
   every frame.

**Test:** collision and `height_at` still correct after the frees; a chunk can be spawned,
despawned and re-spawned from cache; the sentinel fires on a post-free `light_at`;
`surface_at()` still returns correct grip.

**Blast radius is wide** — pull in the car/terrain, chunk, and physics tests, not just the
terrain ones.

---

## Wave C — the track-generation cluster (ONE agent, serial internally)

All of these touch `track_generator.gd` and share one lockfile. **This wave ends with a
single cache regeneration** — that is its whole reason for existing as a unit.

**Owns:** `scripts/track_generator.gd`, `scripts/track_cache.gd` *(coordinate with A5 —
see below)*, `cache_tracks.sh`, `tools/generate_track_cache.tscn`, `data/track_cache.json`.

> ⚠️ **`track_cache.gd` is shared with A5.** A5 memoises `stored_source_hash()`; this wave
> bumps `CACHE_VERSION`. **Let A5 land first**, then start this wave — or agree that A5
> owns the file and this wave only edits the version constant.

**Order:**

1. **1.1 Step 0** — the five-minute empirical check. On the deployed web build, log the
   wall-clock delta across 100 `process_frame` awaits, capped vs uncapped, **forcing the
   web-touch path** (`Config.data.mobile_controls_force`, or a real phone — a desktop
   browser resolves to 60 and cannot reproduce the 30 branch). **If capped and uncapped
   are identical, stop: report it, withdraw the correction header in
   `todo/performance-optimisations.md`, and skip to step 3.**
2. **1.1** — bounded loading cap (a `const` in `world.gd` with a comment, *not* a
   `GameConfig` field), applied in `_ready` after `_end_load_timing()`. Skip it when
   `Benchmark.active`. Time-based yielding in `_search` **only**, justified on preview
   smoothness. Keep a deterministic fixed stride under headless.
   > **This needs `world.gd`, which Wave 0 owns.** Either Wave 0 lands first (it does —
   > it blocks everything), or this step waits for it. Do not start before Wave 0 is
   > merged.
3. **2.3** — memoise `_corner_straightness`, drop the `occupied.duplicate()`, convert the
   `range(a,b)` inner loops. **The sort change is NOT bit-identical** — give it an
   explicit tie-break and verify same-seed equality, or accept it as shape-affecting.
4. **2.4** — rewrite `rasterize_cells` to the per-segment scan. Note it already has a
   `cells.has(cell)` skip, so the win is removing per-sample construction and hashing,
   not duplicate distance maths.
5. **2.6** — add free-roam and benchmark entries to the lockfile. **Low value, but do it
   here** — doing it separately later costs a second `CACHE_VERSION` bump.
6. **Finally:** one `TrackCache.CACHE_VERSION` bump, one `./cache_all.sh` run, and review
   the single lockfile diff. Verify stages still generate sensibly.

**Test:** `test_tree_scatter` and any road-cell tests; same-seed generation equality where
claimed bit-identical.

---

## Wave D — assets and export config (ONE agent, serial internally)

**Owns:** `export_presets.cfg`, `blender/**`, `textures/**`, all `.import` files,
`project.godot` `[rendering]` and `[importer_defaults]`.

**Order (1.5 strictly before 2.10):**

1. **1.4** — remove the live-reload poller from the Web preset; move it into
   `serve_web.sh`. **Keep the landscape-lock script.**
   > ⚠️ `serve_web.sh` is owned by **A7**. Coordinate: either A7 lands first, or A7 makes
   > the `serve_web.sh` edit on this item's behalf.
2. **1.5** — exclude the seven orphan textures and the `.gltf`/`.bin` sidecars.
   **Use the per-car table in the spec — the orphan is NOT consistently named.** For
   911, viper and xjs the live file is `texture.png`; a `*_texture.png` glob would strip
   three cars. Verify all **9** cars still render, **and** re-parse the PCK to confirm the
   orphan `.ctex` entries actually left the build.
3. **2.10** — resize the seven live 1024² mode-2 bodies to 512 + lossy; fix the seven
   `wheel.png` files missing mipmaps (mx5 is already correct — match it). Capture
   before/after screenshots in the HQ car park.
4. **§4** — the `project.godot` knobs: anisotropic filtering to 0, `mesh_lod` threshold,
   `max_lights_per_object`, and shadow meshes (**check HQ and garage first — they have a
   sun**).

> **Commit 2.10 and the shadow-mesh change separately.** Both rewrite files Godot
> regenerates, and both are the kind of change you may want to revert cleanly.

---

## Wave E — after Waves A–D land

**Start Wave E only after the integration checkpoint below.** Three of its streams reclaim
files that Waves C and D own (`world.gd`, `project.godot`, `terrain_manager.gd`).

| # | Item(s) | Owns | Depends on |
|---|---|---|---|
| **E1** | **3.2** wire the resolution tier | `project.godot [display]`, tier resolution in `world.gd` | Wave 0 (fields), Wave C (`world.gd`), **Wave D (`project.godot`)** |
| **E2** | **3.1** HQ + podium ground subdivision | `scripts/hq_environment.gd`, `scripts/mesh_util.gd`, `scripts/podium.gd` | Wave 0 (field) |
| **E3** | **3.4** spectator force caching | `scripts/spectator_group.gd` | — (could run in Wave A; here only to limit concurrency) |
| **E4** | **3.5** tire-mark upload coalescing | `scripts/tire_marks.gd` | **A3** (same file) |
| **E5** | **2.9** remainder | `perf_log.gd`, `start_line.gd`, `speed_lines.gd`, `mobile_controls.gd`, `car.gd`, `hud.gd` | — |
| **E6** | **3.6** LOD VRAM | `scripts/terrain_lod.gd`, `terrain_manager.gd` | **Wave B** |
| **E7** | **5.2** touch double-processing (safe default only) | `scripts/mobile_controls.gd` | **E5** (same file) |

**E5 note:** three of its bullets are behaviour-affecting and need tests (speed-lines
visibility, `_apply_steer` guards, `perf_log` early-return). The rest are inert. The
`perf_log` bullet is **opportunistic only** — do not schedule it on its own.

---

## Deferred — do not schedule

**3.3** (physics tick / substeps — needs a real-device feel check), **2.13** (custom wasm
template, L, do after the PCK shrinks), **3.7**, **3.9**, **5.3**, **5.4**. See spec §5A.

---

## Suggested parallel schedule

```
Wave 0  ────────────────                          (1 agent, blocks all)
        │
        ├── Wave A: A1 A2 A3 A4 A5 A6 A7 A8       (8 agents, concurrent)
        ├── Wave B: terrain cluster                (1 agent)
        ├── Wave C: track-gen cluster              (1 agent, after A5)
        └── Wave D: assets/export                  (1 agent, after A7)
                    │
                    └── Wave E: E1–E7              (up to 6 agents)
```

**Peak concurrency: 11 agents** after Wave 0, which is the realistic ceiling given the
file-ownership constraints. Trying to go wider means two agents in `world.gd` or
`terrain_manager.gd`, which will cost more in conflict resolution than it saves.

**If you want value fastest rather than maximum parallelism:** run **A1** (saves), then
**A4** (lake texture, ~1.0 s off every career load, cleanest evidence in the spec) and
**A2 step 1** (halves the largest per-frame script cost). All three are small, all three
are well-evidenced, and none depends on the unresolved 1.1 measurement.

---

## Integration checkpoints

Run the **full** `./run_tests.sh` at three points only — it is a ~5 minute suite and
concurrent runs are forbidden:

1. After Wave 0 merges (it touched the two largest files).
2. After Waves A–D all merge, before starting Wave E.
3. Before handing back.

Between those, each agent runs its own blast radius. Known baseline failures are recorded
in the project memory (`test_car_spawns`, a chase-camera orbit case, a `test_reward_system`
stuck-player case, a `test_menu_flow` swap-token case, and an intermittent audio-thread
SIGSEGV) — **do not chase those as regressions**, but do confirm the set has not grown.
