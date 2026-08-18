---
name: housekeeping
description: Use when the user invokes /housekeeping or asks for a repo health check, maintenance sweep, or to find things that have drifted — failing tests, docs out of sync with code, orphaned assets, oversized scripts needing refactor, config drift, tests that violate project conventions, broken autoloads or input actions, save-schema compatibility, stale generated caches, build/CI and export-preset health, Android bundle size, mobile-phone performance regressions, git hygiene, duplicated single-sources-of-truth (the same value hardcoded in project.godot, a scene, a script, a test and a doc), or codebase-wide simplification opportunities.
---

# Housekeeping

## Overview

A periodic health sweep for the `rally` repo: catch the things that quietly rot
over time — tests breaking, `features/` docs drifting from the code, `todo/`
specs left stale after work lands, config fields diverging, scripts growing past
the point they should be split, assets/tests going stale, autoloads and input
actions pointing at things that moved, save migrations missing for newly-
persisted fields, committed generated caches going stale, build scripts and
export presets diverging from CI, the Android download growing, mobile-phone
performance headroom eroding (the game is meant to run on old phones), and
simplification/reuse debt accreting across the whole codebase.

This is a **report-first** skill. Run the checks, then present findings grouped
by category with concrete file/line references and a recommended action for
each. **Do not fix things silently** — surface everything, let the user pick
what to act on. Small, obviously-safe fixes (a broken doc link, a stale todo
line) can be offered as a batch to apply after the user confirms.

## How to run it

Work through the checklist below. Run independent checks in parallel where you
can (grep sweeps, `wc`, git). For anything noisy (full-repo greps, log
trawling), spawn an `Explore` or `general-purpose` subagent and keep only the
findings here. Then write up a grouped report.

Scope control: if the user names an area ("just the docs", "check the tests"),
run only those sections. A bare `/housekeeping` runs everything.

## Checklist

### 1. Tests green

- Run the full suite: `./run_tests.sh`. It's CPU-bound and should finish in
  **~5 minutes** (see `features/testing.md`).
- Report any failures with the assertion + file.
- **Cross-check against known baseline failures** before calling anything a
  regression — check the auto-memory index (`MEMORY.md`) for pre-existing
  failures (e.g. reward-system stuck-player grant, car-spawns, chase-camera
  orbit). A failure already recorded there is not new; a failure NOT recorded
  there is the interesting one.

### 2. Test-suite runtime hasn't regressed

- If the full run took noticeably longer than ~5 min, flag it. Per
  `features/testing.md` the usual culprit is a test re-instantiating
  `main.tscn` (full terrain + track generation, ~15 s each) in `before_each`
  where a shared `before_all` or `SceneTestHelpers.minimal_world()` would do.
- Grep for the smell: `grep -rn "before_each" tests/headless/` and check which
  ones build a full world per test.
- **Over budget → hand off to [`/optimise-test-suite`](../optimise-test-suite/SKILL.md)**
  instead of diagnosing it here. That skill owns the per-test JUnit timing
  measurement and both remedies (rewrite/combine the expensive tests; delete the
  low-value ones). Note the difference in stance: it is deliberately **act-first**
  and applies its own recommendations without asking, whereas this sweep is
  report-first — so mention in your report that you're invoking it (or recommend
  the user run it), and don't duplicate its analysis. Reuse the run from §1 as its
  baseline rather than starting a second suite run.

### 3. Tests that violate project conventions

Per `CLAUDE.md` (Testing section), flag tests that:
- **Pin tunable/balance values** — assert a specific stat, reward tier,
  ordering across authored entries, or an exported enum hint string. Ask "would
  a designer retuning this in the inspector break this test?"
- **Depend on a specific catalogue entry** — `CarLibrary.by_id("mx5")`,
  `EngineLibrary.by_id(...)`, `RallyLibrary`/`UpgradeLibrary` lookups by id in a
  logic/physics test. Grep: `grep -rn "by_id(" tests/headless/`. Iterating a
  whole table as opaque input is fine; leaning on one entry's identity is not.
- **Skip `CarFixtures.install()`** where a synthetic roster belongs (catalogue-
  dependent tests that aren't catalogue-contract tests).

Report these here; the value-based *pruning* of such tests (deleting the banned
value pins and catalogue-identity tests outright, rather than just flagging them)
belongs to [`/optimise-test-suite`](../optimise-test-suite/SKILL.md) → prong 2.
Point at it instead of deleting anything in this sweep.

### 4. Docs in sync with code (`features/` and beyond)

- Every file in `features/` should be listed in `features/README.md`'s index —
  diff the directory against the index.
- Spot-check that recently-changed systems (look at recent commits /
  `git status`) had their matching `features/` file updated in the same work.
  Untouched doc + changed code = drift.
- Check for broken cross-reference links between feature files and to
  `scripts/*.gd` paths that no longer exist.
- **Docs outside `features/` drift too** — don't stop at the index:
  - `gameplay.md` is the north star `CLAUDE.md` says to keep aligned when
    gameplay direction changes. If progression / damage / rewards / tuning moved,
    check it still describes the game that exists.
  - `README.md` — do the documented setup steps and script names
    (`./run_tests.sh`, `./build_web.sh`, the Godot version) still match reality?
  - `docs/`, `good-seeds.md` — flag content referencing removed systems, and
    seeds that no longer generate what they claim (track generation changes
    invalidate them silently).
  - `CLAUDE.md` and `.claude/skills/*` (**including this file**) — the rules
    cite concrete paths, symbols and helpers (`CarFixtures.install()`,
    `SceneTestHelpers.minimal_world()`, `MenuNav.attach`, `scripts/menu_nav.gd`).
    When one gets renamed or removed, the instructions rot and quietly mislead
    every future session. Verify the cited symbols still exist.

### 5. `todo/` specs current

- For each spec in `todo/`, check whether its items have already landed in code
  (grep for the functions/files it cites). A spec describing work that's done is
  stale — per `CLAUDE.md`, ask the user whether to remove completed points, and
  if every item in a spec is done, whether to delete the file.
- Flag specs that cite files/line numbers/symbols that no longer exist (they
  were supposed to be kept grounded in real code).

### 6. Config drift (`GameConfig`)

- `config/game_config.tres` is authored data for the `GameConfig` resource
  (`scripts/game_config.gd`, one of the largest scripts in the repo — several
  thousand `@export`s' worth). Check the `.tres` for properties that
  no longer exist as `@export`s in the script (orphaned authored values) and
  `@export`s with no counterpart being exercised.
- Reminder to surface: tuning values belong in the `.tres`, not script/scene
  literals. Flag any newly-hardcoded gameplay/look constants in scripts that
  should be config fields.

### 7. Oversized scripts / refactor candidates

- `wc -l scripts/*.gd | sort -rn | head`. **Measure, don't trust this list** —
  it moves every month. As of 2026-08 the giants, descending, are `hq.gd`
  (~4700), `game_config.gd` (~3800), `terrain_manager.gd` (~2900),
  `overworld.gd` (~2700), `world.gd` (~2560), `car.gd` (~2510),
  `rally_library.gd` (~2220), then a tail of >1000-line scripts
  (`overworld_map.gd`, `save_manager.gd`, `settings_menu.gd`,
  `mobile_controls.gd`, `start_line.gd`, `upgrade_library.gd`,
  `rally_session.gd`, `overworld_picker.gd`). Flag scripts that have
  grown a lot since the last sweep or that mix several responsibilities — these
  are refactor candidates. Don't refactor here; note it and suggest a split.
- Also worth flagging: a single function that's very long, deeply nested
  `_process`/`_physics_process` bodies, copy-pasted blocks across scripts.

### 8. Orphaned / stale assets

- Assets deleted from disk but still referenced (check `git status` for deleted
  `models/`, `textures/`, `tools/` and grep the codebase for references to
  them). For each recently deleted asset — see
  `git log --diff-filter=D --name-only -- 'models/*' 'textures/*' 'tools/*'` —
  confirm nothing still loads it.
- `.import` / `.uid` files whose source asset is gone, or assets with no
  `.import` sibling.
- Scripts in `scripts/` that nothing references (no `preload`/`load`/`class_name`
  usage, not attached to any scene) — potential dead code.

### 9. Menu navigability

Per `CLAUDE.md`, every menu must be keyboard + gamepad navigable. Spot-check
that menus built recently call `MenuNav.attach(...)` (flat overlays) or wire a
`menu_*` branch in `hq.gd._unhandled_input` (diegetic HQ stations), and have a
nav test. Grep new/changed menu scripts for `MenuNav.attach`.

### 10. Loose ends in code

- `grep -rn "TODO\|FIXME\|HACK\|XXX" scripts/ shaders/` — surface stragglers,
  especially ones referencing work that's since been done.
- Uncommitted work: summarize `git status` so the user knows what's in flight
  (don't commit anything without being asked).

### 11. Godot project integrity (import / parse pass)

The test suite (§1) exercises code, but it won't tell you the *project* is
loadable — a scene pointing at a moved script, or a `.uid` that drifted, can be
green in tests and broken in the editor.

- Run a headless load pass: `"$GODOT" --headless --path . --check-only --quit`
  (binary per `CLAUDE.md`; `$GODOT` overrides). Surface every parse error and
  script warning it prints — these are the ones nobody sees until they open the
  editor.
- Enumerate the root scenes explicitly (`ls *.tscn` — currently `main.tscn`,
  `hq.tscn`, `overworld.tscn`, `garage.tscn`, `podium.tscn`, `standings.tscn`,
  `corner_catalog.tscn`, `exhaust_lab.tscn`, `car.tscn`) and check
  each `ext_resource` path in them still exists on disk. A dangling
  `ext_resource` is the classic post-refactor rot.
- Check `.uid` files whose sibling script is gone, and scripts with no `.uid`.

### 12. Autoloads and input actions vs code

`project.godot` is hand-authored data that nothing type-checks, so it drifts
silently when scripts move or features are removed.

- **Autoloads** — the `[autoload]` block registers ~11 singletons (`Config`,
  `Save`, `Cloud`, `InputRemap`, `RallySession`, `ChallengeSession`, `Benchmark`,
  `DisplayStretch`, `WebFullscreen`, `PerfLog`, `Music`). Check each `res://scripts/*.gd` path
  still exists, and flag any autoload nothing references (grep the singleton
  name across `scripts/`) — a resident singleton with no callers is dead weight
  loaded on every boot, including on the weakest phone.
- **Input actions** — the `[input]` block defines the gameplay map
  (`accelerate`, `brake_reverse`, `steer_left`, `steer_right`, `pause`,
  `toggle_debug_arrows`, `toggle_perf_overlay`, `skip_to_finish`, …). Check both
  directions: an action defined in `project.godot` that no code reads (commit
  `ed4a9a8` replaced `reset_car` with `pause` — exactly this shape of leftover),
  and an `is_action_pressed("…")` in code naming an action that isn't defined.
  Also confirm rebindable actions are known to `scripts/input_remap.gd` and the
  controls doc (`features/controls.md`) matches.

### 13. Save-schema compatibility

`scripts/save_manager.gd` versions the save file (`SCHEMA_VERSION`) and steps
old files forward through `_migrate_step(from_version, p)`. A miss here destroys
real player progress, so treat it as higher severity than anything else in this
sweep.

- If recent work added a persisted field, check it either got a migration step
  **or** is covered by the missing-key backfill — and that `SCHEMA_VERSION` was
  bumped iff a step was added.
- Verify the migration chain is contiguous: every version between the oldest
  supported and current has a `_migrate_step` branch, and each branch sets
  `schema_version` to exactly `from_version + 1`.
- Check `todo/web-save-persistence.md` against what's landed (§5 rules apply), and
  confirm `features/save-persistence.md` documents the current schema version.

### 14. Generated data caches

`data/` holds exactly two committed generated artifacts:

- **`data/track_cache.json`** — the track-turn lockfile, baked by
  `./cache_tracks.sh` (which `./cache_all.sh` now just wraps). Read by
  `scripts/track_cache.gd`.
- **`data/eligibility.json`** — the rally × car eligibility matrix, baked by
  `./export_eligibility.sh` (`tools/export_eligibility.gd`) for
  `tools/fit_map_pins.py`. Regenerate after any change to a restriction band,
  car or engine.

If generation code changed after the bake, the game ships content that no longer
matches the generator — invisible in tests.

- Compare mtimes / last-commit dates: is either cache older than the code that
  produces it (track generation in `world.gd` / `track_generator.gd`;
  `RallyLibrary.is_eligible` / `ineligibility_reason` and the car/engine tables
  for the matrix)? If so, flag it and suggest re-running `./cache_all.sh` /
  `./export_eligibility.sh` — don't regenerate unasked, since it rewrites
  committed content.
- Check the cache schema still matches what the loader reads (a renamed field
  makes entries silently default). `track_cache.gd` also carries a
  `constants_fingerprint()` guard — note if it's stale.
- **There is no opponent-field cache, and adding one back is wrong.** The old
  `data/opponent_cache.json` / `cache_opponents.sh` are gone: the rival grid is
  drawn matched to the PLAYER's car rating, so a field is a function of the
  player as well as the rally and cannot be keyed on rally properties alone
  (`rally_library.gd` → `generate_opponent_field`'s `player_rating`,
  `rally_session.gd` → `_generate_event_tracks` path). If a sweep "finds" the
  cache missing, that's the design, not drift.

### 15. Build, export presets and CI health

Nothing else in this sweep looks at how the game actually ships.

- **CI** — `.github/workflows/deploy.yml`. Check the last few runs
  (`gh run list -L 5`) and surface failures. Per the `google-play-publishing`
  auto-memory a first Play publish is still pending; note anything blocking it.
- **Presets vs scripts** — `export_presets.cfg` defines `Web`, `Android`,
  `Android Play (AAB)` and `Windows Desktop`. Confirm every preset name referenced by `build_web.sh`,
  `build_android.sh`, `build_android_play.sh`, `build_windows.sh` and the
  workflow still exists and is spelled identically; a renamed preset fails only
  at release time.
- **Presets consistent with each other** — all four presets share a
  byte-identical `exclude_filter`; if a new asset directory got excluded in one and not the
  others, that's drift. Also flag `variant/thread_support` flipping to `true`
  on Web (see §17) and Android `architectures/arm64-v8a` being turned off.
- **Secrets never committed** — `.gitignore` guards `*.keystore`, `*.jks`,
  `service-account*.json`, `.env`. Verify `git ls-files` actually agrees
  (`git ls-files | grep -iE 'keystore|\.jks|service-account|\.env$'` should be
  empty). A committed signing key is the one finding worth interrupting for.

### 16. Android bundle-size quick wins

The download size gates installs on exactly the low-end audience the game targets
(§17), and it's the metric Play surfaces first. This is a **report** pass —
propose wins, don't delete assets or re-encode audio unasked.

- **Measure before theorising.** Read the real payload rather than guessing from
  the repo: build (or reuse the newest artifact in `build/`) and list the
  packaged files by size — `unzip -l` the `.apk`/`.aab`, or inspect the `.pck`.
  Report the top ~20 entries. Repo size ≠ bundle size, and the whole value of
  this pass is knowing which is which.
- **Confirm the excludes are doing their job.** All four presets share a
  byte-identical `exclude_filter`: `addons/gut/*, tests/*, docs/*, tools/*,
  benchmark/*, todo/*, features/*, build/*, *.mp3, *.blend, *.blend1,
  blender/*/*.gltf, blender/*/*.bin, ref/*`. The two big tracked trees that
  would otherwise dominate the bundle — `ref/` (~28 MB of car reference
  screenshots) and the `.gltf`/`.bin` source siblings under `blender/` — are
  therefore already covered, and a 2026-08 sweep confirmed empirically that a
  built APK contains **zero** entries under `assets/ref/` or
  `assets/blender/`; only the imported `.glb` artifacts under
  `assets/.godot/imported/` ship. Re-verify against the packaged list rather
  than assuming, but do not expect this to be the big win — it is handled.
  What the sweep DID surface as the top lead: check whether the artifact you
  measured was built `--debug` or `--export-release`, because the debug
  `libgodot_android.so` is several times the release one and will dominate the
  listing misleadingly.
- **Duplicate model payloads.** Where a car ships both `.gltf` + `.bin` and a
  `.glb`, only the imported one is needed at runtime. Flag the redundant pair.
- **Oversized textures.** Check the largest entries under `textures/` (e.g.
  `greece.png`, `sky_field.png`, `sky-greece.jpg`) against the resolution the
  game actually samples at — a sky or ground texture authored larger than it's
  displayed is pure download. Note candidates and let the user decide; keep §17's
  mipmap requirement intact if anything is re-imported.
- **Audio.** `music/` is ~4.3 MB of `.ogg` (`.mp3` is already excluded but isn't
  the shipped format). Flag tracks whose bitrate is well above what a phone
  speaker resolves, and any `.ogg` no longer referenced by
  `scripts/music_director.gd` — an orphaned track is free savings.
- **Unreferenced assets are bundle weight, not just clutter.** Cross-reference
  §8's orphan findings here: anything imported but never loaded still ships.
- **Architectures and format.** Only `arm64-v8a` is enabled — confirm it stayed
  that way (adding `armeabi-v7a` roughly doubles the native payload). For Play,
  `export_format=1` (AAB) lets Google split delivery per device; flag if it
  reverted to APK.
- **Report savings with numbers.** Each candidate gets an estimated KB/MB saved
  and a risk note (`safe` / `needs a look in-game` / `designer's call`), ranked
  biggest-win-first. Wins that are pure preset config are the ones to recommend
  applying first; asset re-encodes are the user's call.

### 17. Mobile-phone performance headroom

The game's design principle is that it's **inherently low-end** — one lean
pipeline that must run on old phones, no quality-tier switch
(`todo/performance-optimisations.md`, `features/rendering.md`). This pass is a
**static regression check** that recent work hasn't quietly eroded that. It's a
report — don't re-tune values, flag drift. (Actually *measuring* frame cost is a
separate, heavier step: the in-game **Settings → Benchmark**
([benchmark.md](../../../features/benchmark.md)), the standalone
`./run_benchmark.sh`, and the in-run **P** perf overlay
(`scripts/perf_overlay.gd`). Only suggest running one if a check below turns up a
real suspect — the housekeeping pass itself is grep/read-level.)

- **Frame cap still applied.** `world.gd._ready()` must still cap the render loop
  via `Engine.max_fps`, now sourced through `FpsSetting` (`scripts/fps_setting.gd`):
  `FpsSetting.default_cap() if Benchmark.active else FpsSetting.resolve()`, applied
  unless `Platform.is_headless()`. `FpsSetting.resolve()` returns the player's saved
  Settings → Display choice, falling back to `FpsSetting.default_cap()`, which is
  `Config.data.target_fps_for(Platform.is_mobile_or_web(), Platform.is_web(),
  Platform.is_touch())` (`target_fps` = 60 desktop, `target_fps_mobile` = 60 native
  mobile, `target_fps_web` = 30 web touch; `game_config.gd`). Regression smell: a new
  unconditional `Engine.max_fps = 0`, a removed cap, the headless guard gone, or the
  web/mobile branch lost. Grep:
  `grep -rn "max_fps\|target_fps\|FpsSetting" scripts/`.
- **Foliage / draw budget hasn't ballooned.** The scene builds roughly
  `track_turn_count × trees_per_turn` instances (`world.gd`). Check
  `config/game_config.tres` for upward drift in `trees_per_turn`,
  `track_turn_count`, `tree_render_distance_m`, `tree_spawn_radius_m` since the
  last sweep — bigger numbers = more vertices/fill/collision every frame on the
  weakest device. These are designer values, so *flag drift*, don't "fix"; but a
  large jump is worth surfacing.
- **New MultiMesh / instanced fields stay bounded.** Any new instanced field must
  set `visible_instance_count` or a `visibility_range_*` / LOD cull (the pattern
  in `scripts/tree_mesh_field.gd`) — an unbounded `MultiMesh` that vertex-
  processes every instance every frame is the single biggest GPU regression
  (`todo/performance-optimisations.md` §2). Grep new/changed fields:
  `grep -rn "MultiMesh\|instance_count\|visible_instance_count\|visibility_range" scripts/`.
- **No new per-frame allocations in hot paths.** `_process` / `_physics_process`
  / the audio `fill()` should not allocate dicts/arrays per tick — GC pressure
  hits low-end hardest (`todo/performance-optimisations.md` §6, §8, §10, §11,
  all marked DONE; a regression re-introduces them). Spot-check
  `car.gd`, `drivetrain.gd`, `engine_audio*.gd`, `hud.gd` for dict/array
  literals or `slice()`/`+`-concat inside per-tick bodies where a reused scratch
  belongs.
- **New textures carry mipmaps.** A big instanced texture without mipmaps
  thrashes the mobile texture cache and aliases (`todo/…` §1). Check that new
  entries under `textures/` have `mipmaps/generate=true` in their `.import`,
  especially anything instanced at distance (foliage, ground).
- **New shaders stay mobile-cheap.** GL Compatibility, `unshaded`, no per-
  fragment `hint_screen_texture` back-buffer beyond the single
  `ps1_post_process` pass, and no `vertex()` stage on terrain-heavy materials
  (`ps1_models.gdshader` deliberately has none — `features/rendering.md`). Flag a
  new shader that adds a screen-texture read, lighting math, or a heavy vertex
  stage.
- **Single-threaded web export intact.** `export_presets.cfg` ships
  `variant/thread_support=false` for maximum device reach
  (`todo/…` §7). Flag if it flipped back to `true`, or if new code makes a
  web-critical path depend on `WorkerThreadPool` (terrain gen already routes web
  through the frame-budgeted main-thread queue — new code shouldn't reintroduce a
  thread dependency there).
- **No quality-tier switch crept in.** There is exactly one shipped value per
  knob — no "high/low graphics" branch. Flag any new code that forks the render
  path by device class instead of shipping the single lean value.
- **Cross-reference the perf spec.** Skim `todo/performance-optimisations.md` for
  still-open items (foliage view-cone cull + visible cap, a bush mesh, tree
  collision-box culling) — note if recent work landed any of them (update the
  spec per the `todo/` rules in `CLAUDE.md`) or made an open one more pressing.

### 18. Codebase-wide simplification pass

Run the `/simplify` lens — **reuse, simplification, efficiency, altitude**
(quality only, *not* bug-hunting; that's `/code-review`) — but over the **entire
codebase**, not the working diff that `/simplify` normally targets. This is the
"the whole tree has drifted" version: duplication that's accreted across files,
helpers that grew a second responsibility, hand-rolled loops that a built-in or
an existing utility already covers, dead abstractions, needless indirection.

- **Fan out — don't read the tree serially.** `scripts/` alone has multi-
  thousand-line files — run `wc -l scripts/*.gd | sort -rn | head -12` to get
  the current shape rather than trusting a list; as of 2026-08 that is `hq.gd`
  (~4700), `game_config.gd` (~3800), `terrain_manager.gd` (~2900),
  `overworld.gd` (~2700), `world.gd` (~2560), `car.gd` (~2510) and
  `rally_library.gd` (~2220).
  Spawn several `Explore` / `general-purpose` subagents, each owning a slice
  (a big script, or a cluster of related ones — e.g. the drivetrain/tire files,
  the menu scripts, the terrain files), each returning candidate simplifications
  as `file:line · what · suggested change`. Keep only the findings here; don't
  echo whole files back.
- **What to surface** (the `/simplify` categories):
  - **Reuse** — the same block/idiom repeated across scripts that should be one
    helper; a computation re-done where a cached value or existing utility
    (`Platform`, `MenuNav`, the `*Library` lookups, `GameConfig` accessors)
    already exists.
  - **Simplification** — over-nested conditionals, redundant state, a long
    function that reads as 3 smaller ones, dead branches.
  - **Efficiency** — work done per-frame that could be hoisted/cached (respect
    the mobile-perf lens in §17), `find_children` in hot paths, needless
    allocations — *quality-level*, leave deep perf work to the perf spec.
  - **Altitude** — logic sitting at the wrong layer (gameplay constants hardcoded
    in a script instead of `GameConfig`; a script reaching across a boundary it
    shouldn't).
- **Report-first, like the rest of this skill.** Group the candidates, rank by
  value (broad duplication and dead abstractions first; micro-nits last — don't
  dump every trivial tidy), and give a recommended change for each. **Do not
  refactor silently.** This overlaps §7 (oversized scripts) — fold size-driven
  split suggestions in there and keep §18 for the quality/reuse findings.
- **Applying, once the user picks.** For the subset they choose, either apply a
  small safe batch directly or run `/simplify --fix` scoped to those files. Then
  honour `CLAUDE.md`: it's a **behaviour-preserving** change, so the relevant
  tests must stay green **unchanged** — pick the tests covering what you touched
  (be generous about blast radius) and run them (`./run_tests.sh --fast <name>`).
  Never weaken a test to accommodate a "simplification"; if a green test breaks,
  the refactor changed behaviour — back it out.

### 19. Repo and git hygiene

Low severity, purely report-only — but it accretes, so it's worth a glance each
sweep. Never delete a branch or commit anything here without being asked.

- **Merged branches** — `git branch -r --merged origin/main | wc -l` against
  `git branch -r | wc -l`. When most remote branches are already merged, offer to
  list them for pruning. Same for stale locals (`git branch --merged main`).
- **Junk tracked in git** — check for `.DS_Store` and other OS/editor detritus in
  the index (`git ls-files | grep -iE '\.DS_Store|Thumbs\.db|\.swp$'`) and whether
  `.gitignore` actually covers them. Committed `.DS_Store` files are the common
  case in this repo.
- **Ignore-rule drift** — `.gitignore` names specific scratch artifacts
  (`/tools/render_out/`, the sign/UI preview PNGs, `/fonts/candidates/`,
  `/.superpowers/`). Flag rules whose target no longer exists (dead rule) and
  generated scratch files sitting tracked or untracked-but-unignored.
- **Large files** — flag any newly-committed file over a few MB; git keeps it
  forever. Cross-reference §16 if it also ships in the bundle.

### 20. Single-source-of-truth smells

A value that means one thing but is *written down* in more than one place will
drift — silently, and usually in the direction that's hardest to notice (a doc,
a scene literal, a test's private copy). This pass hunts duplicated definitions
of the same fact and, where the duplicate is unavoidable, checks a test or a
comment pins them together. Report-only, like the rest of the skill; the fix is
almost always "derive the copy from the original" or "add a guard test".

What to look for, cheapest first:

- **Engine settings copied into GDScript.** Anything in `project.godot` that a
  script also hardcodes. The established pattern is to READ the setting instead:
  `Platform.gravity()` → `physics/3d/default_gravity`, and
  `DisplayStretch.DESIGN_HEIGHT` → `display/window/size/viewport_height` (a
  `static var` from `ProjectSettings.get_setting`, since `const` can't call it).
  Flag any new literal that mirrors a project setting — the render resolution,
  gravity, physics tick rate, orientation, window size — and recommend reading it.
- **Scene literals shadowing `GameConfig`.** A node/material property authored in
  a `.tscn` that a script also writes from `cfg` at boot: the scene value is a
  dead fallback that reads as authoritative. `main.tscn`'s
  `shader_parameter/virtual_resolution` vs `cfg.virtual_resolution` is the type
  case. Check `test_config_applied.gd` covers each such pair — that test IS the
  pin; a config→scene pair with no assertion there is the finding.
- **Derived values authored independently.** Two config fields where one is a
  function of the other (an aspect-ratio pair, a min/max that must bracket a
  default, a duration and the frame count that covers it). Either derive it or
  note the relationship in the `@export` comment and guard the *relationship*
  (not the values — see the tuning-value rule in `CLAUDE.md`).
- **A test with its own copy of a production list/constant.** e.g. a local
  `ACTIONS` array alongside `InputRemap.ACTIONS`, or a duplicated
  `DESIGN_HEIGHT`. (`tests/headless/test_smoke.gd` is the *good* example here —
  it iterates `InputRemap.ACTIONS` directly.) A test asserting a
  hand-copied list can't catch the production list changing. Recommend
  referencing the real symbol (iterating the production table as opaque input is
  the encouraged pattern; hand-copying it is the smell).
- **Docs restating a number instead of naming the symbol.** `features/*.md`
  quoting `[480,360]` or "the design height (360)" rots at the next retune. Flag
  literals in docs where the symbol name (`cfg.virtual_resolution`,
  `DisplayStretch.DESIGN_HEIGHT`) would say it durably — same spirit as the
  "prefer file + symbol over line numbers" rule in `CLAUDE.md`. Cross-check
  against §4: a doc number that disagrees with the code is the loud version of
  this, a doc number that currently agrees is the quiet one.
- **Palette / theme values re-typed as raw literals.** `scripts/ui_theme.gd`
  owns the UI palette (`PANEL`, `INK`, `GREEN`, `GOLD`, …) and the spacing
  scale (`GAP`, `MARGIN`, `MENU_ROW_H`). A UI script writing
  `Color(0.0, 0.0, 0.0, 0.96)` instead of `UiTheme.PANEL` is a near-miss that no
  test catches. Sweep with `grep -rn "Color(0\.[0-9]" --include="*.gd" scripts`
  and triage: 3D/world/material colours are legitimately outside the palette —
  only flag colours on `Control`/`CanvasLayer` UI. Same for magic pixel gaps that
  duplicate the spacing constants.
- **Magic strings for things that have a table.** Bare `"Music"` / `"Master"` bus
  names, save-profile keys (`"cars"`, `"rallies"`, `"owned"`) and `res://*.tscn`
  paths repeated across many scripts. Low severity — flag only when a key is
  spread wide enough that a rename would realistically miss one, and recommend a
  `const` on the owning module (`Save`, `Music`) rather than a new indirection
  layer.
- **Two places that must be bumped together.** Version/schema-ish pairs:
  `SaveManager.SCHEMA_VERSION` vs the migration steps it walks, the Godot version
  in CI vs `android/.build_version`, `export_presets.cfg` `version/code` vs what
  the build script stamps. Confirm the coupling is either scripted (the
  `build_*.sh` `sed` stamps are the right pattern — git is the single source for
  version) or asserted; an unpinned pair is the finding.

Report each as: the fact, the places it's written, which one should be the source
of truth, and the pin (derive / read the setting / guard test). Rank by blast
radius — a duplicated engine setting or config↔scene pair above a repeated
string key. Overlaps §4 (docs), §6 (config drift), §12 (autoloads/input actions)
and §18 (reuse); fold each finding into whichever section the user will act on
and don't report it twice.

## Report format

Group findings under the section headings above. For each finding give:
`file:line` · what's wrong · recommended action (fix / update doc / delete /
refactor / ask designer). Put a short summary at the top: how many checks ran,
how many are clean, how many need attention. End with a `result:` line.

## Common mistakes

- **Fixing instead of reporting.** Default to surfacing. Only apply fixes after
  the user picks them.
- **Calling a baseline failure a regression.** Always cross-check `MEMORY.md`
  first (section 1).
- **Flagging tunable values as bugs.** A config value being "wrong" is a
  designer's call, not a housekeeping fix — only flag genuinely broken values
  (mass ≤ 0, non-finite grip) or convention violations (tests pinning them).
- **Deleting todo specs or doc content without asking** — `CLAUDE.md` requires
  confirming first.
- **Running the full test suite twice** — if you just ran it for section 1,
  reuse that result.
- **Guessing bundle size from repo size** — §16 is worthless without reading the
  actual packaged file list. `ref/` being 28 MB on disk says nothing about
  whether it ships. Measure, then recommend.
- **Regenerating caches or re-encoding assets unasked** — §14 and §16 rewrite
  committed content. Report the finding and the estimated saving; let the user
  trigger the rebake.
- **Pruning branches or deleting tracked junk on your own** — §19 is report-only,
  same as the rest.
