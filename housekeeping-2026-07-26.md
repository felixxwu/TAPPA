# Housekeeping sweep — 2026-07-26

19 checks run · 11 clean · 8 need attention. Full suite green (1389/1389).
Two findings worth acting on before the Play publish; the rest is debt.

## Clean

- §6 config drift — 73 authored props in `config/game_config.tres`, all backed
  by `@export`s (only `script` unmatched — the resource header).
- §8 orphaned assets — no `.uid` orphans, no script missing a `.uid`.
- §9 menu navigability — `car_list.gd` and `tuning_panel.gd` have no
  `MenuNav.attach` of their own but both are hosted by scripts that do attach
  (`hq.gd`, `hq_overlays.gd`, `start_line.gd`) — checked and cleared, not a gap.
- §10 loose ends — 3 `TODO`s, all pointing at the live `todo/tarmac-texture.md`.
- §11 project integrity — headless `--check-only` clean; zero dangling
  `ext_resource` across all 7 root scenes.
- §12 autoloads + input actions — all 9 autoload paths resolve; all 21 input
  actions used and defined, both directions.
- §14 generated caches — no staleness; `track_cache.json` and its generator
  last touched the same day.
- §15 CI — last 6 runs green, ~3 min each.
- §15 secrets — nothing committed (`git ls-files` clean against
  keystore/jks/service-account/.env patterns).

## §15/§16 — Android presets ship a desktop texture format (highest severity)

`export_presets.cfg:160-161` (Android) and `:210-211` (Android Play AAB):

```
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
```

Both Android presets ship S3TC/BPTC only, with ETC2/ASTC disabled. S3TC is a
desktop format; GLES3/Vulkan-mobile guarantees ETC2, not S3TC. On the low-end
Adreno/Mali/PowerVR devices this game targets, those textures can't be sampled
compressed — decompress-to-RGBA8 at load (~4 MB VRAM per 1024² texture instead
of ~0.5 MB) or broken sampling. The `.import` files already generate both
variants (`acty_texture.png.import` lists
`imported_formats: ["s3tc_bptc", "etc2_astc"]`), so the ETC2 payload exists and
is simply not being shipped.

**Recommended:** flip both Android presets to `etc2_astc=true`,
`s3tc_bptc=false`. Bundle size stays flat (one variant either way) and it's the
correct format for the target hardware. Wants an on-device check before the
Play publish. `fix` (config), then verify on device.

## §16 — Android bundle size

Measured, not guessed: parsed the pck directory out of `build/web/index.pck`
(v3, dir-at-end). 526 files, 16.60 MB. Two assertions I would have guessed
turned out wrong, which is why the section insists on measuring first:

- `ref/` (28 MB on disk) — 0 files packed. Not shipping; `exclude_filter`
  works as intended.
- `blender/` — 42 files but only 8.9 KB (`.import` stubs and remaps; the real
  bytes live under `.godot/imported/`). Excluding it saves nothing.

Actual composition: `.godot/imported/` is 15.85 MB of 16.60 MB. Within that,
car body textures are 10.00 MB (60% of the bundle) across 15 files at a
uniform 682.7 KB, and music is 4.47 MB (27%). Together, 87%.

| # | Finding | Saving | Risk |
|---|---|---|---|
| 1 | 7 byte-identical duplicate car textures are packed. Every car has both `<car>_texture.png` and `texture.png` (or `mx5_Untitled.png`) with matching md5s; only one of each pair is referenced by any script or scene. Mapped each source through its `.import` `dest_files` to the packed entry — the 7 unreferenced ones account for 4.67 MB | 4.67 MB (28% of bundle) | safe once confirmed per-car which name is referenced (list below) |
| 2 | `build/bench-results/` ships — 45 files, 124.8 KB. `build/` is gitignored but absent from `exclude_filter`, and the bench results got imported as project resources | 125 KB | safe — add `build/*` to `exclude_filter` on all four presets |
| 3 | Car textures are 1024² (all 15 sources verified). For a deliberately PS1-era flat/unshaded look, 512² would likely be indistinguishable and cuts download and VRAM 4× | ~7.5 MB | designer's call |

Duplicate-texture map (source → status):

```
911/texture.png            REFERENCED   37.3 KB packed
911/911_texture.png        ORPHAN       682.7 KB packed
acty/acty_texture.png      REFERENCED   682.7 KB packed
charger/charger_texture.png REFERENCED  682.7 KB packed
focus/focus_texture.png    REFERENCED   682.7 KB packed
focus/texture.png          ORPHAN       682.7 KB packed
mx5/mx5_texture.png        REFERENCED   34.9 KB packed
mx5/mx5_Untitled.png       ORPHAN       682.7 KB packed
thebeast/mrbeast_texture.png REFERENCED 682.7 KB packed
thebeast/texture.png       ORPHAN       682.7 KB packed
twingo/twingo_texture.png  REFERENCED   682.7 KB packed
twingo/texture.png         ORPHAN       682.7 KB packed
viper/texture.png          REFERENCED   682.7 KB packed
viper/viper_texture.png    ORPHAN       682.7 KB packed
xjs/texture.png            REFERENCED   682.7 KB packed
xjs/xjs_texture.png        ORPHAN       682.7 KB packed
```

Inconsistency worth a decision (interacts with §17): the referenced
`911/texture.png` and `mx5/mx5_texture.png` pack to 37 KB / 35 KB, not 683 KB —
they use `compress/mode=1` (lossy) with `vram_texture=false` and
**`mipmaps/generate=false`**, while the other 7 use `mode=2` (VRAM) with
`mipmaps/generate=true`. So two cars are 18× smaller to download but violate
§17's mipmap rule and cost ~8× the VRAM at runtime. Recommend going the other
way — mode=2 + mipmaps everywhere, taking the download hit — and recovering
the size from #1 and #3 instead. Designer's call.

## §3 — Test-convention violations

Generally disciplined (most files carry "derived, not pinned" comments and
`fx_*` fixture ids), but a real cluster exists.

**Class 1 — pins a tunable/balance value:**
- `test_car_library.gd:335-371` — four tests pinned to named entries
  (`test_focus_is_a_fwd_model_car`, `test_twingo_is_a_fwd_model_car`, and the
  two collision-box variants), asserting `"FocusBody"`/`"TwingoBody"`. The
  generic contract is already covered at `:288`. Fix: delete, or rewrite the
  collision-box pair as one loop over `use_model` cars.
- `test_car_library.gd:44` (`engines.size() >= 4`) and
  `test_engine_library.gd:40` (`layouts.size() >= 4`) — pin roster variety a
  designer could reasonably shrink.
- `test_car_types.gd:281,320-321,336` (`seen.size() > 1` for shift times,
  travels, stiffnesses, volume) — same issue, four separate assertions.
- `test_upgrade_library.gd:171-175` — asserts `"engine_stage1"` stays removed
  and pins two ids to specific slots — pure catalogue snapshotting; the
  generic `test_lookups` already proves the contract.
- `test_rally_library.gd:594-596` — hardcodes a `1.25` spread hand-derived
  from the authored pace band; should derive from `_pace_band(difficulty)`
  instead.
- `test_reward_system.gd:82` — `parts > consumables` depends on the shipped
  catalogue's weighting.
- Borderline (flagged, not recommended): `test_rally_library.gd:36`,
  `events.size() == 3` — reads as a structural contract of the run flow, not a
  balance value; left as a call for the user.

**Class 2 — depends on a specific catalogue entry:**
- `test_upgrade_library.gd` — the main offender. Installs `CarFixtures` but
  never `UpgradeFixtures`, so ~12 tests run against shipped `UPGRADES` ids
  (`"turbo_large"`, `"brake_kit"`, `"aero_kit"`, `"ballast_large"`,
  `"drivetrain_swap"`) at `:48, 52-55, 70-73, 115-117, 141, 150-151, 187, 197,
  204-234`. `upgrade_fixtures.gd` exists to cover exactly these effect shapes.
  Fix: install it, re-point to `fx_turbo_big` / `fx_brakes` /
  `fx_lightweight` / `fx_aero` / `fx_ballast` / `fx_drivetrain`.
- `test_car.gd:739-766` — three tests reaching for
  `CarLibrary.index_of("mx5")` / `("viper")`, asserting texture paths end with
  `mx5/wheel.png` / `mx5_texture.png`, or relying on "viper has no
  wheel_texture spec". Fix: build a synthetic spec and assert against its own
  fields, matching the sibling test at `test_car_library.gd:288/328`.
- `test_menu_flow.gd:2415-2421` — `EngineSwap.display_name` tested against
  real engine id `"ford_50_v8"`. Fix: `EngineLibrary.override_for_test([...])`
  with synthetic engines.
- `test_menu_flow.gd:2274-2298` — asserts `hq._eligible.size() == 3` (comment:
  "mx5 + focus + twingo") and picks `"focus"` by id. Fix: assert against
  `hq.STARTER_MODEL_IDS.size()` as the sibling test at `:783` does; pick
  `hq._eligible[0]`.
- `grant_car("mx5")` in logic tests with no `CarFixtures.install()`:
  `test_damage_model.gd:284`, `test_menu_nav.gd:222`, `test_pause_menu.gd:192`.
- Lower confidence: `test_reward_system.gd:109,123` — `"model_id": "mx5"`
  inside an otherwise-synthetic dict while `CarFixtures` is installed; the id
  resolves to nothing so nothing is actually leaned on, but it's a stale
  reference worth swapping to `"synthetic"` or a fixture id.

**Class 3 — catalogue-dependent test skips fixture install:**
- `test_upgrade_library.gd` (whole file) — installs `CarFixtures` but never
  `UpgradeFixtures`.
- `test_damage_model.gd:284` — installs `UpgradeFixtures` but not
  `CarFixtures`, then grants `"mx5"`.
- `test_menu_nav.gd:222`, `test_pause_menu.gd:192` — install `RallyFixtures`
  only, then grant `"mx5"`.
- `test_reward_system.gd:71-90,132` — installs `CarFixtures` but draws from
  the real `UPGRADES` table for pool-composition and membership checks.
- `test_upgrades_menu.gd:190-191` (low priority) — needs both a free and a
  gated weight part from the real catalogue; `UpgradeFixtures` ships exactly
  `fx_ballast` (free) + `fx_lightweight` (gated) and isn't installed.

**Explicitly verified as legitimate (not violations):** `test_car_types.gd`,
`test_engine_library.gd`, and the roster-invariant tests in
`test_car_library.gd` (catalogue-contract tests); `test_catalogue_seam.gd`;
whole-table iteration in `test_reward_system` / `test_rally_library` /
`test_car_prop_prune` / `test_seedlab` / `test_track_cache` /
`test_track_generator`; `test_rally_eligibility_reason.gd`; all `fx_*` id
usage; sanity guards (`mass > 0`, `is_finite`, `assert_between`) across the
catalogue test files.

## §2 — Test runtime over budget

352.4 s (5.87 min) against the ~5 min budget — 17% over. 1389 tests, 114,887
asserts, 124 scripts. One `push_warning` surfaced during the run: `wreck site:
no verge within suspension budget (0.35 m); using flattest spread 0.60 m` —
benign but noisy. Also `ObjectDB instances leaked at exit` and `3 resources
still in use at exit` — a teardown-hygiene smell, not a failure.
Recommended: a `before_each` → `before_all` audit on the heaviest files;
`todo/test-suite-runtime.md` already exists for this.

No regressions against the `MEMORY.md` baseline. Notably, the four recorded
baseline failures (reward-system stuck-player grant, car-spawns, chase-camera
orbit, swap-token) all passed this run — those memory entries look stale and
are worth revisiting/removing.

## §17 — Mobile performance headroom

- `crowd.gd:46-62` (via `world.gd:1077`) has no distance cull — the only
  instanced field in the world cluster with neither `visible_instance_count`
  nor `visibility_range_*`, so wreck/HQ/podium crowds vertex-process at any
  distance. `sign_field.gd:178`, `world.gd:1183`, and
  `spectator_group.gd:113-118` all apply it. Fix:
  `MeshUtil.apply_visibility_range(mmi, cfg.tree_render_distance_m,
  cfg.tree_render_fade_m)`. This is the exact regression class §17 exists to
  catch.
- Per-frame allocation regressions re-introduced in previously-cleaned hot
  paths:
  - `car.gd:705` — `_update_steering()` returns a fresh 3-key `Dictionary`
    every physics tick, 140 lines below the `_inputs_scratch` buffer pattern
    it should follow.
  - `car.gd:541` — `_step_replay` allocates `omap := {}` every replay frame.
  - `tire_marks.gd:224-225` — `.slice(6)` reallocates the whole ribbon buffer
    per segment per wheel on ring-buffer overflow.
  - `tire_marks.gd:197,235` — a 4-element `Array` per emitted segment, plus a
    fresh `Mesh.ARRAY_MAX`-sized array per upload.
  - `engine_audio.gd:92,100,107` — re-walks `get_parent().drivetrain.engine`
    and a dynamic `get("config")` string lookup every render frame.
- Frame cap intact but the mechanism moved: now `world.gd:54-56` via
  `FpsSetting.resolve()` / `default_cap()` wrapping `GameConfig.target_fps_for`,
  not a direct `Engine.max_fps = cfg.target_fps_for(...)` call as this skill's
  §17 text currently describes (doc is stale — see §4 below).
- Web `thread_support=false` intact; no quality-tier fork found; Android
  `arm64-v8a`-only and AAB (`export_format=1`) intact.

## §18 — Codebase-wide simplification (top items; ~36 total findings across 3 slices)

**hq.gd (3103 lines):**
- Five near-identical car-park entry blocks at `:1086, 1895, 1928, 1973, 2042`
  (`_open_garage_picker` / `_enter_car_screen` / `_enter_free_roam` /
  `_enter_engine_swap` / `_enter_starter_pick`) that have already drifted apart
  — collapse into one `_open_carpark(mode, cars, banner, start_text,
  start_index := 0, snap := true, empty_message := "")`.
- Concrete 3-way split proposed: `hq_table.gd` (~600 L: map pins, table
  targets, pan/focus), `hq_lift.gd` (~370 L: lift raise/lower, repair),
  `hq_carpark.gd` (~640 L: lineup build/render/stream, modals) — leaving a
  ~500-line controller (`_ready`/`_build_hq`, `_go_to`, camera,
  `_unhandled_input` routing).
- `_normalize_menus()` (`:1022`) re-walks all seven CanvasLayers on every
  car-park flick/swipe; should take a target layer.
- Duplicated HP/health derivation across 4 sites (`:1688-1691, 1712-1714,
  2663-2669`, plus `save_manager.gd:243`) → one `Save.car_health(owned)`
  accessor.
- Altitude: `hq.gd:1156-1170` (`_prepare_free_roam`) hardcodes terrain-look
  ranges and picks the region as `"greece" if randi() % 2 == 0 else "home"` —
  a newly added region silently never appears in free roam. Move ranges to
  `GameConfig`, pick the region via `RegionLibrary`.

**settings_menu.gd (1173 lines):**
- The seed lab (`_build_seedlab_page` and friends, `:268-1095`) is ~450 lines
  and the sole reason the settings page depends on the track-generation
  stack — move to `seed_lab.gd`.
- `_make_camera_row` / `_make_fps_row` are byte-for-byte identical except the
  bound setter; `_build_event_picker` / `_build_terrain_editor` repeat the
  same overlay scaffold.

**World/terrain cluster:**
- `tree_mesh_field.gd:26-45,153-215` — the entire collision+felling half is
  dead in production (only tests exercise it; production bushes go through
  `Foliage.spawn_bushes`, trees through `BillboardField`) — ~90 lines.
- The binned-MultiMesh field is implemented twice:
  `billboard_field.gd:88-207` vs `tree_mesh_field.gd:64-140` — the comments in
  each even call the other "the twin"/"the mirror".
- `terrain_manager.gd:756-1008` — `bake_track` is a 250-line function that
  reads as five, propping up 13 transient `_cv_*` instance fields.
- `track_generator.gd:89-116` — `rasterize_cells` still uses the abandoned
  per-sample stamping algorithm; its own sibling's comment says stamping cost
  ~70 ms per candidate. Runs 2-3× per world build.
- `world.gd:28-227` — `_ready` is a 200-line boot script mixing config
  application, staged loading, generation, and prop placement; member vars
  are scattered at `:1133-1178, 1380, 1567` instead of grouped at the top.
- `start_line.gd:161-186,505-537` and `:230-360,782-802` — duplicated
  scripted-AI-prop setup and duplicated overlay scaffolding respectively.
- Altitude: hardcoded thresholds outside `GameConfig` in `car.gd:568, 585,
  598, 675, 927` and `drivetrain.gd:451` (grip-curve falloff width), plus
  `engine_audio_synth.gd:57-62` (turbo/supercharger/antilag constants) next to
  sibling knobs that are already config fields. Also `start_line.gd:317,793` —
  hardcoded panel widths that belong in `UITheme`.

## §13 — Save schema (healthy, two notes)

Chain is contiguous and correct: `SCHEMA_VERSION = 2`, `_MIGRATABLE_FROM =
[1]`, the 1→2 step sets `schema_version = 2`, and there's a missing-key
backfill from `_default_profile()`. Notes:
- A save with no `schema_version` key reads as v0, isn't in
  `_MIGRATABLE_FROM`, and is refused — deliberate ("refuse rather than
  guess"), but means any pre-versioning file loses progress silently. Worth
  confirming this can't happen for a real installed base.
- Typo at `save_manager.gd:219` — comment says "the single version N -> N+1
  transform.aa" (stray `.aa`).

## §4/§5 — Doc and spec drift

- `todo/audio.md` cites `scripts/audio.gd`, which doesn't exist.
- This skill file (`.claude/skills/housekeeping/SKILL.md`) has drifted from
  what it audits: §8's worked example (`tools/lowpoly_tree.gd`) was removed
  long ago (confirmed via `todo/performance-optimisations.md:363`); §17's
  description of the frame-cap mechanism is stale post the FPS-setting
  refactor (see §17 above); its line-count figures for `hq.gd` (~3400 vs
  actual 3103) and `game_config.gd` (~1550 vs actual 1767) are off. Worth
  fixing in the same breath since the check caught its own rot.
- `features/` index is complete; every cross-referenced script path in
  `features/*.md` resolves.

## §19 — Git and repo hygiene

- 9 `.DS_Store` files are tracked in git, including `.claude/.DS_Store`, and
  `.gitignore` has no rule for them (one is currently modified in
  `git status`).
- 83 of 90 remote branches are already merged into `origin/main`; two stale
  local branches (`physics-lap-time`, `task/S-45617`).

## Suggested order

1. Android texture format flip (`export_presets.cfg` — gates the Play publish).
2. Duplicate-texture dedup (4.67 MB) + add `build/*` to `exclude_filter`.
3. `crowd.gd` distance cull + the five per-frame allocation regressions.
4. `test_upgrade_library.gd` fixture conversion (biggest test-convention win).
5. `hq.gd` split, doc/hygiene cleanup — lower-stakes, no rush.

Nothing was changed as part of this sweep except earlier edits to the
housekeeping skill file itself (from the prior conversation turn). Everything
above is report-only, per the skill's rules.
