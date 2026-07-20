---
name: housekeeping
description: Use when the user invokes /housekeeping or asks for a repo health check, maintenance sweep, or to find things that have drifted — failing tests, docs out of sync with code, orphaned assets, oversized scripts needing refactor, config drift, tests that violate project conventions, mobile-phone performance regressions, or codebase-wide simplification opportunities.
---

# Housekeeping

## Overview

A periodic health sweep for the `rally` repo: catch the things that quietly rot
over time — tests breaking, `features/` docs drifting from the code, `todo/`
specs left stale after work lands, config fields diverging, scripts growing past
the point they should be split, assets/tests going stale, mobile-phone
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

### 4. Docs (`features/`) in sync with code

- Every file in `features/` should be listed in `features/README.md`'s index —
  diff the directory against the index.
- Spot-check that recently-changed systems (look at recent commits /
  `git status`) had their matching `features/` file updated in the same work.
  Untouched doc + changed code = drift.
- Check for broken cross-reference links between feature files and to
  `scripts/*.gd` paths that no longer exist.

### 5. `todo/` specs current

- For each spec in `todo/`, check whether its items have already landed in code
  (grep for the functions/files it cites). A spec describing work that's done is
  stale — per `CLAUDE.md`, ask the user whether to remove completed points, and
  if every item in a spec is done, whether to delete the file.
- Flag specs that cite files/line numbers/symbols that no longer exist (they
  were supposed to be kept grounded in real code).

### 6. Config drift (`GameConfig`)

- `config/game_config.tres` is authored data for the `GameConfig` resource
  (`scripts/game_config.gd`, ~1550 lines). Check the `.tres` for properties that
  no longer exist as `@export`s in the script (orphaned authored values) and
  `@export`s with no counterpart being exercised.
- Reminder to surface: tuning values belong in the `.tres`, not script/scene
  literals. Flag any newly-hardcoded gameplay/look constants in scripts that
  should be config fields.

### 7. Oversized scripts / refactor candidates

- `wc -l scripts/*.gd | sort -rn | head`. Current giants: `hq.gd` (~3400),
  `game_config.gd`, `car.gd`, `world.gd` (each >1000). Flag scripts that have
  grown a lot since the last sweep or that mix several responsibilities — these
  are refactor candidates. Don't refactor here; note it and suggest a split.
- Also worth flagging: a single function that's very long, deeply nested
  `_process`/`_physics_process` bodies, copy-pasted blocks across scripts.

### 8. Orphaned / stale assets

- Assets deleted from disk but still referenced (check `git status` for deleted
  `models/`, `textures/`, `tools/` and grep the codebase for references to
  them). At time of writing `low_poly_tree.glb`, `leaves.png`, and
  `tools/lowpoly_tree.gd` were deleted — confirm nothing still loads them.
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

### 11. Mobile-phone performance headroom

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
  via `Engine.max_fps = cfg.target_fps_for(Platform.is_mobile_or_web(), Platform.is_web())`
  (`target_fps` = 60 desktop, `target_fps_mobile` = 60 native mobile, `target_fps_web`
  = 30 web; `game_config.gd`). Regression smell: a new `Engine.max_fps = 0`, a removed
  cap, or the web/mobile branch lost. Grep: `grep -rn "max_fps\|target_fps" scripts/`.
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

### 12. Codebase-wide simplification pass

Run the `/simplify` lens — **reuse, simplification, efficiency, altitude**
(quality only, *not* bug-hunting; that's `/code-review`) — but over the **entire
codebase**, not the working diff that `/simplify` normally targets. This is the
"the whole tree has drifted" version: duplication that's accreted across files,
helpers that grew a second responsibility, hand-rolled loops that a built-in or
an existing utility already covers, dead abstractions, needless indirection.

- **Fan out — don't read the tree serially.** `scripts/` alone has multi-
  thousand-line files (`hq.gd` ~3400, `game_config.gd`, `car.gd`, `world.gd`).
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
    the mobile-perf lens in §11), `find_children` in hot paths, needless
    allocations — *quality-level*, leave deep perf work to the perf spec.
  - **Altitude** — logic sitting at the wrong layer (gameplay constants hardcoded
    in a script instead of `GameConfig`; a script reaching across a boundary it
    shouldn't).
- **Report-first, like the rest of this skill.** Group the candidates, rank by
  value (broad duplication and dead abstractions first; micro-nits last — don't
  dump every trivial tidy), and give a recommended change for each. **Do not
  refactor silently.** This overlaps §7 (oversized scripts) — fold size-driven
  split suggestions in there and keep §12 for the quality/reuse findings.
- **Applying, once the user picks.** For the subset they choose, either apply a
  small safe batch directly or run `/simplify --fix` scoped to those files. Then
  honour `CLAUDE.md`: it's a **behaviour-preserving** change, so the relevant
  tests must stay green **unchanged** — pick the tests covering what you touched
  (be generous about blast radius) and run them (`./run_tests.sh --fast <name>`).
  Never weaken a test to accommodate a "simplification"; if a green test breaks,
  the refactor changed behaviour — back it out.

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
