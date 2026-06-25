# rally — project rules for Claude

## Feature documentation

- The `features/` folder is the agent-oriented overview of how this project
  works — one file per feature area (car physics, drivetrain, engine, terrain,
  rendering, testing, etc.), indexed in `features/README.md`. Read it first to
  get oriented.
- Every time a feature is added or modified, update the relevant `features/`
  file(s) in the SAME piece of work — keep the docs in sync with the code, the
  same way tests are kept in sync.
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
- After any change, run `./run_tests.sh` and make sure ALL tests pass before
  declaring the work complete.
- ALWAYS run `./run_tests.sh` in the background (`run_in_background: true`) and
  keep working / wait for the completion notification rather than blocking on
  it. Tests take a while, so never run them in the foreground.
- Be mindful that the FULL test suite takes a while to run. During a long task,
  avoid running the entire suite mid-stream — where you need feedback, run only
  the relevant subset (e.g. the specific test file/script affected by your
  change). Save the full `./run_tests.sh` run for the END of a task, as the final
  verification before declaring the work complete.
- For the FINAL full-suite run (and any run you expect to need failure triage),
  prefer delegating it to a sub-agent (launched in the BACKGROUND, so the main
  agent stays unblocked and is notified on completion) rather than running it
  inline. The agent runs `./run_tests.sh`, reads the verbose GUT output, and
  returns just a clean verdict (pass / fail + the failing test names and
  messages) — keeping hundreds of lines of test log out of the main context.
  Tell the sub-agent the run is slow (15-20 min; GUT physics tests are
  wall-clock-paced) so it waits with a generous timeout instead of killing it
  early. The sub-agent does NOT add concurrency (the one-run-at-a-time rule below
  still holds, across agents too); its only job is to absorb noisy output and
  hand back the digest. For quick `--fast` subset iteration, an inline background
  run with a grep filter is lighter-weight and fine.
- While waiting on a test run, periodically check that it is actually making
  progress and not hung — a finished run prints `ALL TESTS PASSED` / `TESTS
  FAILED`, so prolonged silence past the usual duration is a red flag. Inspect
  the live Godot processes and their ages, e.g.
  `ps -eo pid,etimes,args | grep '[G]odot'`: a healthy headless run lasts a few
  minutes, so a Godot test process whose elapsed time (`etimes`, in seconds) is
  far beyond that — tens of minutes or more — is stuck/orphaned (often a hung run
  from earlier). A stale process also starves the real run of CPU, and because
  GUT physics tests are paced to real wall-clock time, that drags everything out.
  Confirm it is the headless test binary (the Godot path above) and clearly too
  old to be the current run, then ask before killing it (`kill <pid>`) so the
  active run can finish promptly. Don't kill a process you can't confidently
  identify as a stuck test run.
- If a test run ever takes noticeably longer than expected, investigate the
  tests rather than shrugging it off. Physics-test cost is wall-clock (paced to
  real time at the tick rate), so slowness almost always means awaited frames:
  the usual culprit is a `before_each` re-instantiating `main.tscn` (full
  terrain + track generation) per test where a single shared `before_all`
  instance would do, or a long `await`-in-loop settle. Read `features/testing.md`
  for the cost model and the `sim_test.gd` warm-restore pattern.
- Before starting a test run, check whether a background shell is already
  running `./run_tests.sh`. If one is, do NOT start another — wait for the
  existing run to finish and use its result. Concurrent runs waste resources
  and produce confusing, interleaved output.
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
- All gameplay/look tuning values live in `config/game_config.tres`
  (a `GameConfig` resource) — change values there, not in scripts or
  `main.tscn`. Scene/script literals are only fallback defaults.
