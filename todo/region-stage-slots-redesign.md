# Region stage SLOTS — replacing the rally pool with 3 × 8 × 5 authored stages

**Status: AGREED — implementation starting.** §9's open questions are resolved
(see "Decisions" below); nothing is implemented yet as of this note.

## Decisions (resolved 2026-09-11)

- **Q1 (weather scope): per-candidate.** Each of the 3 seeds in a slot authors
  its own weather.
- **Q2 (candidate pick): uniform random** — `rng.randi_range(0, 2)` off the run
  seed, as assumed in §4.
- **Q3 (difficulty stacking): keep both.** The clock (`stage_step`) and the
  per-slot authored terrain both escalate — intentional reinforcement, not
  double-counting.
- **Q4 (region unlock): unchanged.** `RegionLibrary.order`/`gate_for`/money
  multiplier/`region_index()` are untouched; a region stays one unlockable node.
- **Q5 (eligibility tools): delete all.** `report_eligibility.gd`,
  `export_eligibility.gd`, their shell wrappers, `data/eligibility.json`,
  `tools/fit_map_pins.py`, and `tests/headless/test_eligibility_export.gd`.
- **Q6 (rally_library.gd fate): rename to a getters-only file.** Strip the
  `RALLIES` data and the dead map/restriction/special surface; keep the live
  `event_*` getters; rename to `scripts/stage_fields.gd` (or similar) since
  "rally" no longer names anything live.
- **Q7 (migration): regenerate from scratch.** Author all 120 stages fresh with
  per-slot fixed values (not ported/scaled from the old 128), re-verifying each
  routes as part of the bake.
- **Q8 (Rally Challenge): out of scope.** `ChallengeRunMode`/`ChallengeLibrary`
  are untouched by this redesign.

**Depends on / supersedes:** `todo/roguelike-pivot.md` (the settled decision
record) — this spec proposes changing decisions **3, 7 and 32** (authored stage
pool, the seeded draw, the 16-events-per-region floor) and retiring the
`difficulty`-ordering mechanic. If it lands, `roguelike-pivot.md` and
`features/region-runs.md` → *The stage draw* must be updated in the same work.
Also touches the "What gets deleted" item that `features/rally-roster.md` →
*Dead code awaiting demolition* has been tracking since stage 2b (`633c244`).

---

## 1. Why — the thing that forced this

`StageConfig.apply_event_config` (`scripts/stage_config.gd`) does **not** generate
an event's authored track. After seating the authored fields it applies a
run-progress scale on top (the block guarded by `if stage_index >= 0:`):

```gdscript
var hilliness_scale := stage_scale(stage_index, stage_count,
    base.stage_hilliness_scale_min, base.stage_hilliness_scale_max)
cfg.terrain_layer1_amplitude *= hilliness_scale   # …and layer2 / layer3
var curviness_scale := stage_scale(stage_index, stage_count,
    base.stage_curviness_scale_min, base.stage_curviness_scale_max)
cfg.track_straightness = clampf(1.0 - (1.0 - cfg.track_straightness) * curviness_scale, 0.0, 1.0)
```

`stage_index` comes from `DrivingContext.apply_stage_config`
(`scripts/driving_context.gd`), which passes `RunSession.events_completed()` and
`RunSession.stage_count()`. `track_straightness` is a cache-key field
(`TrackGenParams.for_event` → `p.straightness` → `TrackGenParams.cache_key`), and
the terrain amplitudes are too (via `TrackCache.terrain_fingerprint(cfg)` over
`cfg.terrain_layers()`).

And `RegionStagePool.draw` (`scripts/region_stage_pool.gd`) can land **any**
pooled event at **any** of the 8 stage positions: it draws a random
`stage_count`-sized subset of the region's flattened pool and only then sorts
*that subset* by the parent rally's `difficulty`.

⇒ the same authored event is **8 different tracks**, each with its own cache key.
`TrackCache.all_event_keys()` and `tools/generate_track_cache.gd` were baking one
key per event; they were patched (this session) to loop `stage_index` over
`RegionRunMode.STAGE_COUNT`, which takes the lockfile from 128 + 2 entries to
**128 × 8 + 2 = 1026** and a full `./cache_tracks.sh` bake to ~35–45 minutes.

That patch is correct and should stay until this redesign lands. But 1026 baked
tracks is the symptom of a content model that multiplies authored content by
run-position, and the user's answer is to stop multiplying and author the
positions directly.

## 2. The ask, in the user's words

> "Each stage gets 3 seeds with the same settings based on how far into the rally
> it is, and the randomness only comes from choosing between the 3 seeds. So in
> total it should be 3 × 8 × 5."

i.e. **120 authored stages**: 5 regions × 8 stage slots × 3 candidates. Every
candidate in a slot is authored for *that* slot's difficulty, so the run's
escalation is authored rather than computed, and a stage's track is fixed the
moment the candidate is chosen — one cache entry per candidate, 120 + 2 total.

Today: **44 rallies / 128 events** (`home` 36, `greece` 40, `taiga` 18, `snow` 18,
`home_coast` 16 — counted off `RallyLibrary.RALLIES`). So this is a ~6% content
*reduction* by event count, and an 8.5× lockfile reduction.

## 3. The new authoring shape

**Proposal: a new `scripts/region_stage_library.gd`, `class_name RegionStageLibrary`**,
rather than growing `RegionLibrary` (which is already 525 lines and owns look /
water / grip overrides — a different concern) or keeping `RallyLibrary.RALLIES`
(whose whole `{id, name, difficulty, restriction, special, map_pos, events}`
wrapper is the pre-pivot artefact this deletes).

Shape — a dictionary keyed by region id, each a **fixed-length array of 8 slots**,
each slot a **fixed-length array of 3 candidates**:

```gdscript
const STAGES: Dictionary = {
    "home": [
        # slot 0 — the run's opener: gentlest authored relief and straightness
        [
            {"seed": 1007, "turn_count": 14, "straightness": 0.55, "terrain_layer1_amplitude": 18.0,
             "forestiness": 0.70, "surface_mix": 1, "cliffiness": 0.15, "width": 6.0,
             "weather": "dry", "water_level": -12.0, "terrain_layer2_amplitude": 3.0},
            {…}, {…},
        ],
        # slots 1..7 — progressively twistier / hillier, authored
    ],
    "greece": [ … ], "taiga": [ … ], "home_coast": [ … ], "snow": [ … ],
}
```

**Per-candidate authored fields** — exactly the set the live readers consume, no
more. Every one of these is read today and must keep a home:

| Field | Read by | Notes |
| --- | --- | --- |
| `seed` | `TrackGenParams.for_event`, `StageConfig.apply_event_config` | required |
| `turn_count` | same | required; hand-verified to route, baked |
| `straightness` | `RallyLibrary.event_straightness` → `for_event`/`apply_event_config` | **now authored per slot**, no runtime scale |
| `terrain_layer1_amplitude` (+ `2`/`3` optional) | `apply_event_config` | **now authored per slot**, no runtime scale |
| `width` | `RallyLibrary.event_width` | optional, cfg default |
| `forestiness` | `RallyLibrary.event_forestiness` (foliage) | optional |
| `surface_mix` | `RallyLibrary.event_tarmac_fraction` | optional |
| `cliffiness` | `RallyLibrary.event_cliffiness` | optional |
| `weather` | `RallyLibrary.event_weather` / `event_is_wet` → `WeatherLibrary` | optional, see open question Q1 |
| `water_level` / `water_enabled` | `TrackGenParams.resolve_water_level` | optional; region waterline is the fallback |
| `terrain_layer*_wavelength` | `apply_event_config` | optional |

**Computed, never authored:** `region` (stamped from the containing key, exactly as
`RegionStagePool.events_in` stamps it today — still load-bearing for
`RegionLibrary.surface_grip_of` / `deep_snow_of` / `frozen_water_of` /
`water_level_of`), `slot`, `candidate` (stamped for provenance/debugging in place
of today's `rally_id`).

**Deliberately NOT carried over:** `difficulty` (the slot index *is* the
difficulty), `rally_id`, `target_ms_override`, `restriction`, `special`,
`map_pos`, per-rally `id`/`name`.

**Field accessors stay where they are.** `RallyLibrary.event_width` /
`event_forestiness` / `event_tarmac_fraction` / `event_straightness` /
`event_cliffiness` / `event_weather` / `event_is_wet`
(`scripts/rally_library.gd:864–938`) are pure `(Dictionary) -> value` lookups with
defaults and have nothing to do with `RALLIES`. Recommendation: **move them onto
`RegionStageLibrary` verbatim** and delete `rally_library.gd` outright, rather than
keeping a 1,159-line file alive for seven getters. (Open question Q6 — the move
touches `TrackGenParams`, `StageConfig`, `challenge_library.gd`, foliage and
weather call sites.)

The catalogue seam (`all()` / `override_for_test()` / `reset()`) must be preserved
in the same shape `CarLibrary`/`EngineLibrary`/`RallyLibrary` use —
`tests/headless/test_catalogue_seam.gd` covers all three generically, and
`tests/headless/rally_fixtures.gd` is the existing synthetic-roster fixture that
catalogue-dependent tests install.

## 4. `RegionStagePool` — what it becomes

`scripts/region_stage_pool.gd` today is `events_in` / `pool_size` / `draw` /
`_easier_first`. Under this model `draw` becomes:

```gdscript
# One candidate per slot, in slot order. Deterministic in (region_id, run_seed).
static func draw(region_id: String, stage_count: int, run_seed: int) -> Array:
    var slots := RegionStageLibrary.slots_in(region_id)   # 8 slots × 3 candidates
    var rng := RandomNumberGenerator.new()
    rng.seed = run_seed
    var out: Array = []
    for slot_index in range(min(stage_count, slots.size())):
        var candidates: Array = slots[slot_index]
        out.append(_stamp(candidates[rng.randi_range(0, candidates.size() - 1)],
            region_id, slot_index))
    return out
```

What goes away with it:

- **the difficulty sort** — `_easier_first` and its seed tie-break, deleted
  outright. The array order *is* the escalation, so there is nothing to sort and
  nothing to keep stable.
- **the bag / refill logic** — every slot always has exactly 3 candidates, so the
  "pool thinner than the run" stopgap (documented at `region_stage_pool.gd`'s
  `draw` and in `features/region-runs.md` → *Pool sizes*) can never fire.
- **the 16-event floor (decision 32)** and the "no repeats while the pool lasts"
  rule — replaced by a structural invariant: 8 slots, 3 candidates, per region.
- **`events_in` / `pool_size`** — no flat pool exists any more. If a caller still
  needs "every stage in a region" (the cache baker does), that is
  `RegionStageLibrary.all_stages_in(region_id)`, which is 24 stamped dicts.

Determinism is unchanged and still load-bearing: `RunSession` persists `run_seed`
and `RegionRunMode.stages()` (`scripts/region_run_mode.gd:70`) re-derives the
stage list on resume, so the same seed must re-pick the same 3-of-1 per slot.

## 5. `StageConfig.stage_scale` — recommendation: **delete it**

**Recommendation: delete `stage_scale` and the whole `if stage_index >= 0:` block,
and drop `stage_index`/`stage_count` from both `apply_event_config` and
`canonical_event_config` signatures.**

Reasoning:

1. Its entire purpose is "later stages are hillier and curvier", which the new
   model authors directly per slot. Keeping both means a designer authoring slot 7
   as twisty and then having the runtime twist it *again* — two knobs for one
   feel, and the authored number stops being the number.
2. It is the sole reason a stage's cache key depends on run position. Deleting it
   makes `stage_index` irrelevant to generation, which is what collapses the
   lockfile from 1026 back to 122.
3. As a "smaller residual knob" it is worse than useless: it would still make the
   key position-dependent, so the 8× bake multiplier would survive in full for a
   subtler effect. There is no version of "keep it smaller" that keeps the win.

Consequences to sequence: `GameConfig.stage_hilliness_scale_min`/`_max` and
`stage_curviness_scale_min`/`_max` (`config/game_config.tres`,
`scripts/game_config.gd`) lose their only reader and should be deleted with it;
`DrivingContext.apply_stage_config` drops the two arguments it passes.

**Caveat to raise with the user:** the *clock* escalation
(`RegionRunMode.target_pace`'s `run_target_pace_stage_step`) is a separate
mechanism and is unaffected — this deletes the terrain/shape escalation only.

## 6. The track cache under the new universe

The cache-key contract in `TrackGenParams.cache_key` needs **no change** — it is
already a pure function of authored shape determinants (seed, turn_count, width,
clearance, reserve_behind, straightness, runoff, water, heading) plus the terrain
fingerprint and version tag. Recommendation: **keep keying by the resolved params,
not by `(region, slot, candidate)`.**

Reasons: the key must stay a function of what actually feeds
`TrackGenerator.generate`, or two identical-shape candidates would bake twice and,
worse, a param change that didn't touch the tuple would silently reuse a stale
entry. A tuple-based key would also break `TrackGenParams.for_config` (benchmark +
default boot), which has no region/slot at all and shares the same keyspace.

What changes is only the **enumeration**:

- `TrackCache.all_event_keys()` (`scripts/track_cache.gd:104`) loses its inner
  `for stage_index in range(stage_count)` loop and its outer
  `RallyLibrary.all()` / `rally.get("events")` walk, becoming a walk over
  `RegionStageLibrary`'s 120 stamped stages at `canonical_event_config(stage)`
  with no stage index.
- `tools/generate_track_cache.gd` (`_ready`, lines 11–36) mirrors that change
  exactly — the two **must** stay in lockstep or `tools/verify_track_cache.gd`'s
  `source_hash` comparison passes while live runs miss the cache. Its print line
  should switch from `rally %s seed %d stage %d/%d` to `region %s slot %d/%d
  candidate %d seed %d`.
- `_config_param_sets()` (the 2 `for_config` entries — default boot + benchmark)
  is unchanged and still deliberately excluded from `source_hash`.
- Lockfile size: **122 entries**, bake time roughly 122/1026 of today's ~40 min,
  i.e. ~5 minutes. `data/track_cache.json` shrinks accordingly.

`tools/verify_track_cache.gd` itself needs no edit — it calls
`TrackCache.all_event_keys()` and compares hashes.

## 7. Dead code this redesign should bundle in

All verified present in the tree at time of writing.

| What | Where | Note |
| --- | --- | --- |
| `map_pos` per rally | `scripts/rally_library.gd` — authored on ~all 44 `RALLIES` rows (e.g. line 160), plus `suggest_map_pos` / `map_pos_is_free` / `hq_map_pos` / `MIN_PIN_SEPARATION` | no live reader; only a comment reference in `region_library.gd:85` |
| `restriction` per rally + the eligibility predicates | `rally_library.gd:940 ineligibility_reason`, `:989 is_eligible`, `:1151 incomplete_rallies_enterable_by`, `eligible_car_indices` | see Q5 for the tools that call these |
| `special` per rally | `rally_library.gd` `RALLIES` rows; `all_specials_completed` / `nearest_locked_special_id` (the decision-45 credits trigger) | |
| Prize/reward residue | `rally_library.gd:1082 prize_car_id` (always `""`), `:1100 opening_rally_id_for`, `podium_count` / `completed_count` / `rally_completed`; `Save.record_podium_rally` has no live caller | |
| Map reveal geometry | `rally_revealed`, `position_revealed`, `position_lit_by`, `lit_sources`, `reveal_link_pairs`, `distance_beyond_frontier`, `reveal_depths`, `reveal_radius_of` | `save_manager.gd` ~1187–1206 still calls `rally_revealed` — untangle in the same pass |
| The whole `{id, name, difficulty, restriction, special, map_pos, events}` wrapper | `rally_library.gd` `RALLIES` (44 rows) | replaced by §3 |
| `RegionLibrary.rallies_in` / `region_for_rally` | `scripts/region_library.gd:476`, `:473` | only caller is `RegionStagePool.events_in`, which §4 deletes |

**Two corrections to the brief's dead-code list, found by reading:**

- **`scripts/rally_detail.gd` does not exist.** It has already been deleted (so has
  `tests/headless/test_rally_detail.gd`); `features/rally-roster.md` → *Dead code
  awaiting demolition* is **stale** on this point and should be corrected in the
  same work.
- **`start_line.gd`'s `Seq.MENU` / `Seq.REVEAL` / `_rival_car_ready()` are NOT
  dead.** `Seq.REVEAL` is the **rival-ghost departure** (`features/rival-ghost.md`
  — a live, post-pivot feature, not the deleted rival field), and `Seq.MENU` is the
  start-line briefing menu itself. What *is* dead is exactly one call:
  `scripts/start_line.gd:621`, `RallyLibrary.ineligibility_reason(_rally, meta)` —
  a permanent no-op because `world.gd._build_start_line` only ever hands it a
  synthesized `{"name": …}` with no `restriction`. **Delete that call and its
  branch only**; leave the sequence machine alone.

## 8. Files to change, grouped by sequencing

**Stage A — author the content (no behaviour change yet).** Nothing else can be
verified until the 120 stages exist and route.
1. New `scripts/region_stage_library.gd` + the 120 authored candidates (see Q7 on
   how they're sourced).
2. New `tests/headless/test_region_stage_library.gd` — structural invariants only
   (every region has 8 slots, every slot 3 candidates, every candidate has
   `seed`+`turn_count`, seeds unique across the catalogue). **No** assertions on
   authored values (CLAUDE.md).
3. `features/` — a new or renamed area doc, indexed in `features/README.md`, with
   the mandatory `**Source:**`/`**Tests:**` lines
   (`tests/headless/test_features_docs.gd` enforces this).

**Stage B — swap the draw over.** Behaviour change; nothing baked yet, so runs
generate live (slow but correct).
4. `scripts/region_stage_pool.gd` — rewrite per §4.
5. `scripts/region_run_mode.gd` — `stages()` (line 70) is the only caller;
   `STAGE_COUNT` (line 30) now also constrains the authored slot count, which is a
   real coupling worth a comment.
6. `tests/headless/test_region_stage_pool.gd` — see §9a, substantial rewrite.

**Stage C — delete the runtime scale.** Depends on B (slot-authored shape must be
in place before the scale is removed, or every stage flattens).
7. `scripts/stage_config.gd` — delete the `stage_index >= 0` block and
   `stage_scale`; drop both params from `apply_event_config` /
   `canonical_event_config`.
8. `scripts/driving_context.gd` — `apply_stage_config` drops the two args.
9. `scripts/game_config.gd` + `config/game_config.tres` — remove the four
   `stage_hilliness_scale_*` / `stage_curviness_scale_*` fields.
10. `tests/headless/test_stage_config.gd` — four `stage_scale` tests and
    `test_later_stage_is_hillier_and_curvier_*` lose their subject (§9a).

**Stage D — re-key and re-bake the cache.** Depends on C (the key shape is only
stable once the scale is gone).
11. `scripts/track_cache.gd::all_event_keys` and
    `tools/generate_track_cache.gd::_ready` — **in the same commit**, per §6.
12. Run `./cache_tracks.sh`, commit `data/track_cache.json` (~122 entries). The
    `.githooks/pre-commit` freshness hook will otherwise catch it.
13. `tests/headless/test_track_cache.gd` —
    `test_committed_cache_covers_every_event` and
    `test_committed_source_hash_is_fresh` need repointing (§9a).

**Stage E — demolition.** Last, because it is the only stage that can be abandoned
without leaving the game broken.
14. `scripts/rally_library.gd` — delete or reduce to the seven `event_*` getters
    (Q6).
15. `scripts/start_line.gd:621` — delete the `ineligibility_reason` branch only.
16. `scripts/region_library.gd` — delete `rallies_in` / `region_for_rally`.
17. `scripts/save_manager.gd` (~1187–1206) — the `rally_revealed` backfill.
18. `tools/report_eligibility.gd`, `tools/export_eligibility.gd`,
    `report_eligibility.sh`, `export_eligibility.sh`, `data/eligibility.json`,
    `tools/fit_map_pins.py` — Q5.
19. `tests/headless/test_rally_library.gd`, `test_rally_eligibility_reason.gd`,
    `test_eligibility_export.gd`, `tests/headless/rally_fixtures.gd` — §9a.
20. Docs: `features/rally-roster.md` (largely obsolete — likely deleted or
    rewritten as the new stage-library doc), `features/region-runs.md` → *The
    stage draw* / *Pool sizes*, `features/regions.md`, `features/terrain.md`
    (stage-based hilliness), `PIVOT-CHANGES.md`, `todo/roguelike-pivot.md`
    decisions 3/7/32, `features/README.md` index rows.

## 9. Open questions — for the user, not for the implementer

**Q1. Weather: per-slot or per-candidate?** If weather is authored on the
candidate, the three candidates in a slot differ in condition and the "same
settings, only the seed varies" framing is already broken. If it's per-slot, a
region's run has a fixed weather script (slot 3 is always the foggy one), which is
very readable but very repeatable. Weather is *not* a cache-key input
(`test_weather_does_not_affect_track_generation_params` pins this), so either is
free on the cache side. `test_every_multi_stage_rally_mixes_weather` in
`test_rally_library.gd` currently enforces variety across a rally and has no
successor under either choice.

**Q2. How is the candidate picked?** Uniform `rng.randi_range(0, 2)` off the run
seed is the assumed default above. Alternatives worth a sentence: weight against
candidates seen in the player's recent runs (needs new persisted state), or force
all-three-distinct-across-a-region somehow (meaningless with one pick per slot).
Uniform is recommended unless there's a reason.

**Q3. Does authored difficulty survive anywhere?** Under this model the slot index
is the only difficulty signal, and `RegionRunMode.target_pace`'s
`run_target_pace_stage_step` already tightens the clock by stage index — so
difficulty is expressed twice, from the same number. Is that intended reinforcement
or double-counting the designer will have to fight?

**Q4. Region unlock order.** `RegionLibrary`'s authored `order` (0–4) still drives
`is_unlocked`, `gate_for`, `region_index()` and the compounding money multiplier —
none of that is touched here. Confirm it stays exactly as is, and that a region is
still one unlockable node rather than gaining per-slot gating.

**Q5. `report_eligibility.gd` / `export_eligibility.gd` — delete or repoint?**
Both exist only to answer "which cars can enter which rally" through
`RallyLibrary.is_eligible` / `ineligibility_reason`, over `restriction` dicts this
spec deletes. `export_eligibility.gd` also writes `data/eligibility.json` for
`tools/fit_map_pins.py` — **map-pin fitting for the deleted world map**. There is
no post-pivot question for either tool to answer. Recommendation: delete both
tools, both shell wrappers, the JSON, `fit_map_pins.py`, and
`tests/headless/test_eligibility_export.gd`. Needs a yes.

**Q6. Does `rally_library.gd` survive as a getter file?** Deleting it is cleaner
but touches every `event_*` call site (`TrackGenParams.for_event`,
`StageConfig.apply_event_config`, `challenge_library.gd`, foliage, weather).
Keeping it as a ~120-line pure-getter module is a smaller diff with a now-wrong
name. Rename to something like `scripts/stage_fields.gd`?

**Q7. Migration: hand-port or regenerate?** Porting 128 existing events into 120
slots means choosing, per region, which 24 survive and re-authoring their
straightness/amplitude for their new fixed slot (the current values were authored
to be *scaled*, so a straight port would be wrong at both ends of the run).
Regenerating from scratch means re-verifying 120 `(seed, turn_count)` pairs route
— which is exactly what the bake does, so it's less scary than it sounds, but the
region *character* (`features/rally-roster.md`'s terrain-zone amplitude bands, the
Alps' deliberately gentle relief per `features/snow-region.md`) has to be
re-established by hand either way.

**Q8. What happens to the Rally Challenge?** `ChallengeRunMode` /
`ChallengeLibrary.stages_for` rolls its own stages and does **not** use
`RegionStagePool` — but it does go through `StageConfig` and shares the cache
keyspace, and `ChallengeLibrary` rolls water level and terrain amplitude together
for the same lockfile reason. Confirm the challenge is out of scope (it is, as
far as this reading goes) or say how it should participate.

### 9a. Tests that currently pin the old mechanics

These need **rewriting, not relocating**. Several also risk violating CLAUDE.md's
"never pin a tunable/authored value" and "never depend on a specific catalogue
entry" rules if ported carelessly — the temptation under the new model is to
assert "slot 7 is twistier than slot 0", which is exactly an authored-ordering
assertion the rules forbid.

- **`tests/headless/test_region_stage_pool.gd`** — the most affected file.
  `test_the_drawn_run_escalates_by_the_parent_rallys_difficulty` (line 153),
  `test_every_pooled_stage_carries_its_region_and_its_parents_difficulty` (81),
  `test_a_pool_smaller_than_the_run_refills_rather_than_returning_a_short_run`
  (141), `test_the_draw_never_repeats_a_stage_while_the_pool_lasts` (133),
  `test_every_region_can_fill_two_runs_without_repeats` (180),
  `test_every_region_offers_more_than_one_difficulty` (195),
  `test_the_pool_is_every_event_of_every_rally_tagged_with_the_region` (64) and
  `pool_size` all lose their subject outright. What survives, restated against
  slots: determinism in the run seed, "every drawn stage is a real authored
  candidate", "a drawn stage carries its region tag", "the draw never mutates the
  catalogue", and the unique-seed guard (210).
- **`tests/headless/test_stage_config.gd`** —
  `test_stage_scale_interpolates_linearly_between_synthetic_min_and_max` (97),
  `test_stage_scale_clamps_out_of_range_indices` (120),
  `test_stage_scale_with_one_stage_is_always_min_v` (127),
  `test_negative_stage_index_leaves_terrain_and_straightness_unscaled` (132) and
  `test_later_stage_is_hillier_and_curvier_than_an_earlier_stage_for_any_scale_config`
  (143) all die with `stage_scale`. The rest of the file (event override flow,
  baseline fallback, weather, region waterline resolution) is untouched and must
  stay green — it's the regression net for Stage C.
- **`tests/headless/test_track_cache.gd`** —
  `test_committed_cache_covers_every_event` (118) and
  `test_committed_source_hash_is_fresh` (155) must be repointed at the new
  enumeration; `test_canonical_event_config_applies_overrides` (91) loses its
  stage-index arguments.
- **`tests/headless/test_rally_library.gd`** — the dead-machinery block
  `features/rally-roster.md` → *Tests* already flags (reveal predicates, `map_pos`
  well-formedness, every `restriction` case, the enterable-query/anti-soft-lock
  tests, `test_podium_count_tracks_profile`) goes with the code. The live half
  (per-event field defaults, track-gen determinism, `test_turn_splits_*`) must
  move to whichever file owns the `event_*` getters after Q6.
- **`tests/headless/test_rally_eligibility_reason.gd`**,
  **`tests/headless/test_eligibility_export.gd`** — delete with Q5.
- **`tests/headless/rally_fixtures.gd`** — the synthetic-roster fixture needs a
  slot-shaped successor before any catalogue-dependent test can be rewritten;
  build it in Stage A, not Stage E.
- **`tests/headless/test_region_run.gd`** — indirect: it drives `RegionRunMode`,
  whose `stages()` changes shape. Check its assertions don't assume a
  difficulty-ordered list.
- **`tests/headless/test_region_library.gd`**, **`test_region_docs.gd`**,
  **`test_features_docs.gd`**, **`test_script_breadcrumbs.gd`** — will fail on the
  doc/breadcrumb churn in Stage A and Stage E if the docs aren't updated in the
  same commits.
