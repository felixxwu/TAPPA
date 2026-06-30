# rally — project rules for Claude

## Feature documentation

- The `features/` folder is the agent-oriented overview of how this project
  works — one file per feature area (car physics, drivetrain, engine, terrain,
  rendering, testing, etc.), indexed in `features/README.md`. Read it first to
  get oriented.
- Every time a feature is added or modified, update the relevant `features/`
  file(s) in the SAME piece of work — keep the docs in sync with the code, the
  same way tests are kept in sync.
- **Menus must be keyboard + gamepad navigable.** Every menu in the game supports
  up / down / left / right / enter / back on keyboard AND controller (not just
  mouse / touch) — see `features/menus.md` → "Menu navigation". When you ADD a new
  menu or CHANGE an existing one, wire its navigation in the SAME piece of work:
  - A flat widget list (overlay / panel): make its buttons `focus_mode = FOCUS_ALL`,
    `UITheme.focus_grab(first_button)` (deferred) when it's shown, and route "back"
    through `ui_cancel` / `menu_back`. The theme's `focus` stylebox paints the cursor
    (it matches hover), so there's no extra visual work.
  - A diegetic 3D HQ station: add a `menu_*` branch in `hq.gd._unhandled_input` and
    `get_viewport().gui_release_focus()` on entry (HQ hides overlays via CanvasLayer,
    which does not clear Control focus).
  Add / update a nav test (`tests/headless/test_menu_nav.gd`, or the nav cases in
  `test_menu_flow.gd` / `test_pause_menu.gd`). Don't ship a menu reachable only by
  pointer.
- `gameplay.md` is the high-level gameplay design / vision doc ("Gran Turismo,
  but with rally stages") — the north star the `todo/` specs ladder up to. Read
  it for intent on progression, damage, rewards, tuning, and the final showdown.
  It's design-level, not an implementation spec; keep it aligned when gameplay
  direction changes.

## Todo / specs folder

- The `todo/` folder holds planning specs for work to be implemented later
  (e.g. `todo/performance-optimisations.md`). Read the relevant spec before
  implementing anything it covers, and keep it in sync as items land.
- When writing a new todo spec, ground it in REAL code: cite concrete files,
  line numbers, function/variable names, and config fields as they actually
  exist (verify by reading the code, don't guess). Brainstorm the spec WITH the
  user before/while writing it — surface the approach, trade-offs, and open
  questions and let them steer it, rather than committing a finished spec
  unilaterally.
- If a todo depends on other work (another spec, or a prerequisite feature),
  note that dependency explicitly in the spec file. Before implementing a todo
  that has dependencies, make sure the dependency is done first — implement it
  (or confirm it's already in place) before starting the dependent work.
- When you finish implementing items from a todo spec, ask the user whether
  to remove the completed points from the spec — and if EVERY item in a spec
  is done, ask whether to delete the whole `.md` file. Do not remove items or
  delete the file without checking first.

## Testing (mandatory)

- When adding or changing functionality, add or update tests in the same piece
  of work: gameplay/logic tests in `tests/headless/`, scene/structure checks in
  `tests/headless/test_smoke.gd`.
- After any change, run the tests that are relevant to the work before
  declaring it complete — you do NOT need to run the entire suite after every
  prompt. Decide which tests cover what you touched and run just those (e.g.
  `./run_tests.sh --fast <name>` for the specific file(s)/script(s) affected).
- When choosing which tests to run, be GENEROUS about the blast radius: think
  about everything the change could plausibly affect — direct callers, shared
  config/resources, physics or scene setup that depends on what you touched —
  and include those tests too, not just the one file you edited. When in doubt,
  pull a test in rather than leaving it out.
- Reserve the full `./run_tests.sh` run for when it actually makes sense: a
  change with wide or hard-to-scope blast radius (shared physics/config, core
  scene setup, cross-cutting refactors), when you're genuinely unsure which
  tests cover the work, or as a final pre-handoff check on a large task. For
  small, well-contained changes a targeted subset is enough — don't run the
  whole suite by reflex.
- The Godot project lives at the repository root — `project.godot`, `run_tests.sh`,
  `build_web.sh`, etc. are all directly in the repo root, so there's no subdirectory
  to `cd` into. Invoke the runners by path (`./run_tests.sh`) from the root.
- **Test runtime budget (~5 minutes).** The full suite should stay under about 5
  minutes. If a full run takes longer than that, spend some effort bringing the
  runtime back down before declaring the work complete — don't just accept the
  regression. The cost is CPU-bound (the runner uses `--fixed-fps 60`, so awaited
  frames are cheap); the usual culprit is full-world generation — instantiating
  `main.tscn` runs `world.gd._ready()`, which generates the track + scatters
  trees/bushes for ~15 s per instance. Reach for the cheap patterns first:
  `SceneTestHelpers.minimal_world()` for tests that don't inspect the
  track/terrain/foliage (cuts a build to <1 s), `sim_test.gd`'s cached settle for
  physics tests, and bare-logic tests (no scene) where possible. Reserve full
  generation for the few files that genuinely assert on it. See
  `features/testing.md` for the cost model and the available levers.
- If a test run ever takes noticeably longer than expected, investigate the
  tests rather than shrugging it off. With the runner's `--fixed-fps 60` the
  loop runs at CPU speed, so cost is dominated by genuine CPU work — usually a
  `before_each` re-instantiating `main.tscn` (full terrain + track generation)
  per test where a single shared `before_all` instance would do, or a long
  `await`-in-loop settle. Read `features/testing.md` for the cost model and the
  `sim_test.gd` warm-restore pattern.
- Don't start a test run while another `./run_tests.sh` is already in
  progress — wait for it to finish and use its result. Concurrent runs waste
  resources and produce confusing, interleaved output.
- If an existing test breaks, treat the NEW CHANGES as the prime suspect, not
  the test. The tests encode agreed behavior (e.g. W drives the car forward,
  reset returns to start), so a previously-green test failing usually means
  the new changes are no good. Before touching the test, verify whether it
  SHOULD change: did the user explicitly ask for the behavior it asserts to
  change? If yes, update the test and say so in your summary. If no, fix the
  code — never weaken thresholds, flip signs, or delete assertions just to
  get back to green.

## Environment

- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`
  (override with `$GODOT`). Tests use GUT, vendored in `addons/gut/`.
- Do NOT work in a separate git worktree. Make changes directly in this
  checkout so the user sees them in the project they actually run. Never create
  or switch into a worktree (no `EnterWorktree`, no `git worktree add`) — even
  if a harness prompt suggests isolating; working in a worktree hides edits from
  the user's running game and forces a later merge. Stay in this directory.
- NEVER create a new git branch without the user's explicit consent. Work on
  the current branch unless the user asks you to branch (or you're in the remote
  environment on a harness-assigned branch). Don't run `git checkout -b`,
  `git switch -c`, or otherwise start a new branch on your own initiative.
- All gameplay/look tuning values live in `config/game_config.tres`
  (a `GameConfig` resource) — change values there, not in scripts or
  `main.tscn`. Scene/script literals are only fallback defaults.
- If you're running in a managed remote execution environment (Claude Code on
  the web — an isolated cloud container, not the user's local machine), keep
  developing on whatever feature branch the harness assigned, but ALWAYS merge
  that branch into `main` and push `main` when you're done working — every time,
  as the last step before handing back. Getting the work onto `main` is what
  shortens the iteration cycle; the feature branch alone doesn't help the user.
  You can detect this environment deterministically: the env var
  `CLAUDE_CODE_REMOTE` is `true` (the same signal
  `.claude/hooks/session-start.sh` keys off). When in doubt, check it rather
  than guessing.
  - Do NOT merge to `main` if you're in ANY other environment (e.g. local dev,
    where `CLAUDE_CODE_REMOTE` is not `true`). There, leave the branch as-is and
    let the user handle merging — only the remote environment auto-merges.
