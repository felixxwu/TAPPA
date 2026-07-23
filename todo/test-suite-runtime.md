# Test-suite runtime reduction

The full `./run_tests.sh` run has drifted to **~553 s (9.2 min)** — well over the
~5 min budget in `features/testing.md` / `CLAUDE.md`. This spec captures a grounded
investigation (2026-07-22) and the candidate levers, ranked by value/safety. None
is a safe mechanical edit: every one changes shared test infra or core world
generation, so each needs a **full-suite verification pass** (all terrain/physics
tests green, unchanged) before it lands.

## Measured breakdown

Runner starts Godot **once** for the whole suite (~9 s startup), so 553 s ≈ 544 s
of test work across **1369 tests** (122 scripts).

- **World builds dominate the non-physics cost.** `world.gd._ready()` runs an
  unconditional terrain precompute (`world.gd` → "Precomputing chunks…",
  `print("terrain precompute: %d chunks…")` at `world.gd:471`). Across the suite:
  - **59 builds × 143 chunks** — the `SceneHelpers.minimal_world()` path
    (`tests/headless/scene_helpers.gd:61`, sets `track_turn_count = 1`,
    `trees_per_turn = 0`).
  - **10 builds × 279 chunks** — full worlds (8 in `test_start_line.gd`, 1 each in
    `test_terrain.gd`, `test_smoke.gd`), plus a few one-off 237/295/312 counts.
- **Per-build cost ≈ 1.5 s** for a 143-chunk minimal build (measured:
  `test_turbo_fielding` 1 build = 10.5 s incl. startup; `test_car_library` 20
  builds = 40.3 s ⇒ ~1.57 s/build). Full 279-chunk builds ≈ 3 s.
- So world builds ≈ **~120 s (~22 %)** of the run. The remaining ~420 s is genuine
  per-test work — physics settles and `await`-loops across the 1369 tests (cheap
  per frame under `--fixed-fps 60`, but numerous).

**Why 143 chunks for a 1-turn track:** the corridor dilates every centerline
sample by `_corridor_margin(leash_m) = RADIUS(3) + ceil(leash/CHUNK_M) + 1 = 5`
chunks (`terrain_manager.gd:575`), i.e. an 11×11 block per sample, unioned along
the (short) track. The count is dominated by the `RADIUS = 3` render-ring
dilation, not track length — so shortening the track (what `minimal_world`
already does) barely shrinks the precompute.

## The correctness constraint on any precompute change

`TerrainManager.height_at` (`terrain_manager.gd:285`) is **cache-first and falls
back to pure noise outside the corridor** ("tests without precompute … silently
falls back to pure noise", `:284`). The cached grid includes road flattening; the
noise does not. So **skipping/shrinking the precompute changes `height_at` results**
for any test that queries terrain height off the spawn ring — it silently returns
unflattened noise instead of the collidable surface. A stationary car still
settles (its spawn ring is built by `$Floor.build_initial()`), but height/collision
assertions away from spawn would break. This is the landmine under every lever
below.

## Candidate levers (ranked)

1. **Process-wide chunk cache keyed by generation params (highest value, medium
   risk).** The 59 minimal builds almost all use *identical* params
   (`track_turn_count = 1`, default seed, baseline config) and recompute the *same*
   143 chunks 59×. A static `TerrainManager` cache keyed by
   `(seed, track params hash)` would compute once and reuse ~58× ⇒ save ~75 s.
   Risk: cross-test contamination / stale cache if any test mutates terrain config
   without changing the key; needs a clean invalidation story and a full-suite pass.
   (Note: the recent `e50d42a`/`25e8b48` commits already added a committed cache for
   the *track DFS turns* — this would be the analogous cache for the *terrain
   heightfield chunks*, which is still per-instance.)

2. **`terrain_precompute_enabled` config flag, set false by `minimal_world` (high
   value, needs per-file audit).** Gate the `world.gd` corridor-precompute loop
   behind a flag; chunks then load lazily via the RADIUS ring. Saves most of the
   ~90 s on minimal builds. Risk: the noise-fallback above — must first audit which
   of the 59 minimal-build tests query off-spawn `height_at`/`light_at` and exclude
   them (or precompute a tiny ring for them). Verify the full terrain/car suite green.

3. **Share a `before_all` world where safe (medium value, low-per-file risk).**
   Some per-test-`before_each` builders can move to one shared instance:
   `test_aero_visibility` (7 builds), `test_retune` (8), `test_turbo_fielding` (1).
   NOT `test_car_library` (its `before_each` comment documents why it can't —
   tests flip the roster to `CarFixtures` mid-test and `test_cycle_car`
   re-instantiates the Car node) and NOT `test_car_water` (mutates water config
   per-test). Each conversion needs its own file's tests green unchanged.

4. **Trim the 10 full-world (279-chunk) builds.** `test_start_line`'s 8 full builds
   come from launch tests that call `start_rally` → full track+corridor. Check
   whether those assertions actually need the full corridor or could run against a
   `minimal_world` + short leash. ~15–20 s.

## Recommended order

Start with **(1)** — biggest single win, and a static chunk cache is verifiable in
isolation (compare a full-suite run before/after; all green + faster). Then **(3)**
for the easy file conversions. Treat **(2)** as the follow-up if (1)+(3) don't get
back under ~5 min, since it carries the noise-fallback audit burden. Re-measure
after each step; keep `features/testing.md`'s cost model in sync.
