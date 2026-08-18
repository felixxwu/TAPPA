---
name: small-model-readiness
description: Use when the user invokes /small-model-readiness, or asks to make this codebase easier for a small/cheap model to work in, to measure whether a Haiku-class model can ship a feature here, to run a small-model eval round, or to refactor for AI legibility rather than for style. Runs ONE round of the readiness loop — probe with small-model agents, grade, taxonomise the failures, fix the top causes, verify, record. Designed to be driven repeatedly by `/loop /small-model-readiness`.
---

# Small-model readiness

## Overview

One round of an evidence-driven loop that makes this codebase navigable by a
Haiku-class model. The design doc is
`docs/superpowers/specs/2026-08-18-small-model-readiness-loop-design.md` — read it
if anything here is ambiguous; this file is the executable form of it.

**Stance: this skill acts, it does not report and wait.** It refactors the main
checkout on its own judgement, like `optimise-test-suite` and unlike
`housekeeping`. It **never commits** — the user owns committing and reverting.
It itemises everything it did in a round report afterwards.

**One round per invocation.** End by printing `CONTINUE` or `STOP` and the
reason. `/loop /small-model-readiness` drives the rounds; do not loop internally.
**The round ends at §2.11 and nowhere else.** If you delegate fix-step work to
subagents, their completion is a waypoint, not a resting point — §2.7–§2.11
(closing suite, post-checks, teardown, report) are still yours. A round that
stops when its delegated work returns leaves worktrees on disk and the green-tree
invariant unproven (this happened in round 002 and needed a manual nudge).

**Two rules that are not negotiable, because breaking either makes the whole
round worthless:**

1. **You (the parent) run every test. Probes and graders never do.** `CLAUDE.md`
   bans subagents from executing tests by any spelling, and both probes and
   graders are subagents. Probes must be told explicitly not to run tests or
   launch Godot.
2. **Probe worktrees are created and seeded BY YOU, before dispatch.** The loop
   never commits, so any worktree branched from a ref lacks the loop's
   accumulated work — you must transplant the working tree in yourself (§2.2)
   and verify it landed. A probe against an unseeded tree measures an
   unrefactored codebase, and every round re-discovers causes the last round
   already fixed.

**Snippet discipline:** every ```bash block below is tagged. `VERIFIED <round>`
means it was executed against this repo in that round and behaved. If you edit a
snippet or add one, re-run it against the repo before the round continues, or
tag it `SKETCH` — both of this skill's shipped footguns (the rubric-leaking
transplant, the red-hiding `tail`) were unexecuted code that read as tested.

## The round at a glance

The complete round, in order. Every step is mandatory; the round ends at step 12
and nowhere else. Details live in the matching § below — come back here after
each step to see what's next.

1.  Verify preconditions; re-measure size (§2.0)
2.  **Open `rounds/NNN.md` NOW; append to it at every step below** (§2.0)
3.  Retire / replenish / sample ~5 tasks (§2.1)
4.  Create + seed + verify one worktree per task, then dispatch probes (§2.2)
5.  Run each probe's `expected_tests` — you, serially, in its worktree (§2.3)
6.  Grade each diff, 4 axes (§2.4)
7.  Taxonomise every failure into a cause (§2.5)
8.  Fix top 1–3 causes in the main checkout, layer coverage per fix (§2.6)
9.  Closing full suite — unconditional, red is yours to fix (§2.7)
10. Mechanical post-checks (§2.8) + Totals conservation (§2.9)
11. Tear down every probe worktree (§2.10)
12. Finish the report; update bank/backlog/baseline; print CONTINUE/STOP (§2.11)

## Assumptions

- **Sole occupancy.** No other agent is working in this checkout. This is what
  makes "any red test is ours — fix it" safe. If the user says others are
  working, stop and say so.
- **The tree is green on entry.** At loop start you establish that with one full
  run (step 0). On every later round the previous round's closing run is the
  baseline — do NOT re-run the suite at the start of a round, or you run it twice
  back-to-back for the same answer.
- **Exactly one full-suite run per round**, at the end. Per-attempt checks are
  targeted `--fast` selections.

## 0. Preconditions — verify, never self-install

P1–P3 were applied by hand by the user on 2026-08-18. **Verify them and refuse
to run if any is missing.** Do not silently re-apply them: they touch the user's
rulebook and settings, and a loop that rewrites those on its own initiative is
exactly what the user declined.

```bash
# VERIFIED round 001 (precondition checks)
cd /Users/felixwu/git/rallygodot
python3 -c "import json;print(json.load(open('.claude/settings.json')).get('worktree'))"  # baseRef: head — vestigial
# (probes no longer use isolation:"worktree"; the parent runs `git worktree add`
# itself in §2.2, so this setting is harmless but no longer load-bearing)
grep -q 'claude/worktrees' .gitignore && echo 'P3 ok' || echo 'P3 MISSING'
grep -q 'small-model-readiness' CLAUDE.md && echo 'P2 ok' || echo 'P2 MISSING'
```

If any reports missing, **stop and tell the user which one** — do not fix it and
do not proceed.

**P4 — the green baseline (first run only).** One full `./run_tests.sh`; record
the pass/fail set and wall-clock in `evals/small-model/baseline.md`. If it is not
green, stop and report — never probe against a red tree. The suite has been over
the ~5 min budget at every measurement so far; `features/testing.md` carries the
current floor and it MOVES, so read it rather than trusting any number pinned in
a doc. Your halt condition is a regression against your own baseline, never
against an absolute.

**Scaffolding (first run only)** — these are the loop's own files, yours to
create without asking: `evals/small-model/{tasks.md,solved.md,baseline.md,rounds/}`
and `todo/small-model-readiness.md`. Then author the seed bank per §1.

## 1. The task bank

`evals/small-model/tasks.md`. Each task is a real, user-phrased feature request —
how the user would actually type it, not a spec. Plus a **hidden rubric** the
probe never sees:

```markdown
### T012 — "Add a gravel-spec tyre upgrade to the catalogue."
- status: live | retired (round NN)
- clean_solves: 0
- expected_files: scripts/upgrade_library.gd, ...
- expected_docs: features/upgrade-catalogue.md, features/README.md
- expected_tests: test_upgrades_grid, test_upgrade_library
- test_conventions: no tunable-value pins; no CarLibrary.by_id() identity;
  CarFixtures.restore() in teardown; Config.reset() after a non-authored baseline
- conventions: values in config/game_config.tres; features/ updated AND indexed
- areas: catalogue, garage-ui
```

Spread the bank across distinct areas — catalogue data, a menu, terrain/region,
physics/tuning, save/progress, HUD.

**The bank is a ratchet, not a benchmark.**

- **Retire** a task after it is solved cleanly (full marks, all four axes) in
  **two consecutive rounds it was sampled in** → move to `solved.md` with the
  round number. A task the model reliably solves measures nothing. Track this in
  `clean_solves`, and **reset it to 0 on any non-clean attempt** — the rule is
  two *consecutive* clean solves, not two ever.
- **Replenish** each round: replacements biased toward areas the last refactor
  changed, areas never probed, and *harder* work than what retired.
- **Floor: 8 live tasks.** Author replacements before sampling if under.
- **Scores are not comparable across rounds and are not a progress signal** —
  difficulty rises as readiness rises, so a flat score is the expected steady
  state. Read the **retirement rate** and the **cause taxonomy** instead.

## 2. Round procedure

### 2.0 Guard

**First action of the round: create `evals/small-model/rounds/NNN.md` and append
to it after every step** — sampled tasks, dispatched probes, test results,
scores, fixes, check outputs — as they happen, not reconstructed at the end. The
report doubles as the round's resumable state: if the round is interrupted at
any point (a stall, a crash, a context reset), whoever resumes reads this file
and continues from the last recorded step instead of guessing from worktree
debris. Round 002 stalled mid-fix and was recoverable only by external
reconstruction; this file is the fix.

Verify P1–P3 (the checks in §0). P4 applies on the first run only; on later
rounds confirm `evals/small-model/baseline.md` exists and carries the previous
round's closing result. Re-measure and record the size picture:

```bash
# VERIFIED rounds 001-002 (size picture)
cd /Users/felixwu/git/rallygodot
echo "scripts: $(find scripts -name '*.gd' | wc -l) files, $(find scripts -name '*.gd' -exec cat {} + | wc -l) lines"
find scripts tests -name '*.gd' -exec wc -l {} + | sort -rn | sed -n '2,11p'
```

The tree is green on entry by the invariant. **Do not run the suite here.**

### 2.1 Sample

Retire anything that qualifies, author replacements if under the floor, then draw
~5 live tasks, weighted toward areas not recently probed and areas the previous
round's refactor changed.

### 2.2 Probe

**The parent creates and seeds each worktree BEFORE dispatch. Do NOT use
`isolation: "worktree"`** — the harness creates that worktree *at* dispatch,
atomically with the agent starting, so there is no window to seed it, and a
fresh worktree branched from HEAD lacks every uncommitted change this loop has
made (the loop never commits). Round 001 got away with `isolation` only because
the tree happened to be fully committed; no later round will be.

Per sampled task:

```bash
# VERIFIED round 002 (seed + transplant); rubric exclusion verified post-002
cd /Users/felixwu/git/rallygodot
SCRATCH="$(mktemp -d)"                       # NOT /tmp/fixed-name, NOT $CLAUDE_JOB_DIR
git diff HEAD > "$SCRATCH/loop.patch"
git status --porcelain -uall > "$SCRATCH/main_before.txt"   # for the post-probe check

WT=".claude/worktrees/probe-<task-id>"
git worktree add --detach "$WT" HEAD
git -C "$WT" apply "$SCRATCH/loop.patch"     # tracked uncommitted changes
# untracked files (new modules + their .gd.uid sidecars). macOS ships openrsync,
# which has no --from0, so pipe through tar; --null survives the ~30 repo paths
# that contain spaces.
git ls-files --others --exclude-standard -z \
  | grep -zv -e '^evals/small-model/' -e '^todo/small-model-readiness' \
  | tar --null -T - -cf - | (cd "$WT" && tar xf -)
# The exclusions SEAL THE MEASUREMENT: tasks.md carries every hidden rubric and
# rounds/*.md describe the traps — transplanting them hands the probe the answer
# key (found leaking in round 002).
cp -R .godot "$WT"/.godot                    # warm class cache — a cold worktree
                                             # pays a full --import rebuild
                                             # (WARMUP_TIMEOUT default 300 s)
```

**Verify the seed landed before dispatching** — diff a file you know this loop
changed against the worktree copy, and abort the round if it is absent. A probe
against an unrefactored tree measures nothing and wastes the round.

Then dispatch one plain `Agent` per task, in parallel, `model: "haiku"` — **no
`isolation` option**. The prompt is the bare task text, the worktree boundary,
and the test/Godot ban:

```
Work exclusively inside <absolute path to $WT>. That directory is a complete
copy of the project; do not read or write anything outside it.

<the user-phrased task text, verbatim>

Do not run tests. Do not launch Godot. Do not run ./run_tests.sh, gut_cmdln.gd,
or any Godot binary. Make the change and report what you did and why.
```

No rubric, no hints, no mention of the eval, no pointers to files. **The point is
to find out what the codebase tells them unaided** — helping them corrupts the
measurement.

**The boundary is prompt-enforced, so verify it afterwards:** when all probes
have reported, re-run `git status --porcelain -uall` in the main checkout and
compare against `$SCRATCH/main_before.txt`. If the main tree changed while
probes ran, a probe wandered out of its worktree — its measurement is
untrustworthy and the main tree needs inspecting before the round continues.

### 2.3 Run

You, serially, holding the lock. Never concurrently — `run_tests.sh`'s watchdog
has historically fallen back to `pkill -f gut_cmdln.gd`, which kills every Godot
test process on the machine including the user's.

Targeted `--fast` selections only, and **run them inside that attempt's
worktree**, not the main checkout — the whole point is to test the probe's
change:

```bash
# VERIFIED rounds 001-002 — but READ THE RESULT per the note below
pgrep -f run_tests.sh && echo "ALREADY RUNNING — wait for it" || \
  (cd "$WT" && ./run_tests.sh --fast <names_from_expected_tests>)
```

**Reading multi-name results:** `--fast <a> <b> <c>` runs each name as a
SEPARATE GUT run, so the output holds one summary per name and a `tail` keeps
only the last — a red in an earlier selection scrolls away. Check every
`ALL TESTS PASSED`/`TESTS FAILED` line, or run one name per invocation. And
never trust a piped exit code: grep's status wins the pipe (both found in
rounds 001–002).

### 2.4 Grade

One Opus grader subagent per attempt. It reads the diff plus your recorded test
results; **it does not run anything**. Four axes, 0–3:

- **navigation** — did it find the right code?
- **correctness** — does the change work; do `expected_tests` pass *relative to
  baseline*?
- **convention** — `features/` updated and indexed, config values in the right
  place, and the probe's **newly written tests** checked against
  `test_conventions`?
- **completion** — finished, versus stalled or context-exhausted?

Excused failures come from `evals/small-model/baseline.md`'s known-failure list
and **nowhere else** — do not excuse a red test from memory or from a note in a
doc. As of round 001 that list is **EMPTY** (the once-flaky
`test_reward_system` passes), so any red test is a real regression.

Audio-mixer SIGSEGVs are different: they are signal deaths, retried by
`run_tests.sh` via `TEST_CRASH_RETRIES`, and never scored.

### 2.5 Taxonomise

Every failure gets a *cause*, not a description. Starter set, extensible:

- file too large to hold in context
- no `features/` entry for the area
- `features/` entry stale or misleading
- hidden coupling across files
- convention undiscoverable at the point of use
- unclear which tests cover the area

### 2.6 Fix

Top 1–3 causes by frequency × cost, **in the main checkout**. Read §3 before
touching anything — the objective is small-model legibility, not line count.

**For every fix, walk the failure back to its earliest catchable moment and ask
at each layer: does my fix fire HERE?**

1. **Authoring time** — could the mistake have been impossible to write, or
   flagged where it was written (a point-of-use comment, a structure that
   won't hold a dangling name)?
2. **Runtime** — does the broken state announce itself when it executes
   (`push_error` / debug assert on a name that resolves to nothing), so a
   person in the editor sees it without ever running tests?
3. **Test time** — does a guard test go red in CI?

A test alone is **detection, not prevention** — it protects the suite, not the
next author, and small models are exactly the authors least likely to run it.
When the observed cause is a *silent* failure, a fix that only adds a test has
half-fixed it: add the runtime loudness too when it costs a few lines (round
001 shipped the guard test for silent no-op upgrade effects and stopped there;
the ~5-line `push_error` in the apply path was the better half and had to be
retro-added). Escalate to layer-1 restructuring only when a cause REPEATS
across rounds despite layers 2–3 — that repetition is the evidence the design
demands, not a licence you have in round one.

State in the round report, per fix, which layers it covers and why the ones it
skips are skipped.

### 2.7 Verify

The round's **one** full-suite run. It is **unconditional** — the next round
inherits this run as its green baseline and does not re-establish it, so a round
that skips it leaves the invariant unproven and the loop blind.

`--fast` is a pre-check only, never the closing run. The full run matters most
when the fix step split a file, moved a `before_all`/fixture, or touched shared
config or scene setup, because this repo's
characteristic failure is order-dependent cross-file leakage (leaked
`Config.data` baselines, un-`restore()`d fixture overrides, escaped
`change_scene_to_file`, `SimTest`'s process-wide settle cache) which passes under
`--fast` and fails only in a full run. That is exactly what splits provoke.

**A red test at the end of the round is yours. Fix it.** Sole occupancy means
there is nobody else it could belong to. Do not attribute it, do not defer it,
do not weaken the test. Halt only if you genuinely cannot fix it.

### 2.8 Mechanical post-checks

A test run cannot catch the three most likely silent failures of a refactor here:

```bash
# VERIFIED round 001 close (all four checks)
cd /Users/felixwu/git/rallygodot
# authored config values — tests CANNOT cover this (CLAUDE.md bans asserting tunables,
# and .tres stores only non-defaults, so a renamed @export silently reverts the value)
grep -c '=' config/game_config.tres
# uid integrity — every .gd has a tracked .gd.uid sidecar; a move that drops it
# makes Godot mint a fresh uid and silently orphans every uid= reference
git ls-files '*.gd.uid' | wc -l
grep -rho 'uid://[a-z0-9]*' --include='*.tscn' --include='*.tres' . | sort -u | wc -l
# namespace integrity — class_name is one flat project-wide namespace; a collision
# breaks PROJECT LOAD, not one test
grep -rh '^class_name' scripts/ | awk '{print $2}' | sort | uniq -d
"${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}" --headless --quit  # project still loads
```

Every `key = value` in `config/game_config.tres` must still resolve to a live
`GameConfig` property, and the authored set must be unchanged except where you
deliberately changed it.

### 2.9 Conserve

Any round touching test files records GUT's `Totals` (Tests **and** Asserts)
before and after, and justifies any delta. A test moved into a file that misses
`-gdir`/`test_*.gd` discovery, or that loses its `extends SimTest`/`before_all`,
silently stops running and **reports as a pass** — step 2.7 cannot detect it.

### 2.10 Teardown

`git worktree remove --force` per probe after grading; verify in the report.
**Do this on every exit path, including every halt** — a round that stops early
otherwise leaves changed worktrees on disk, and the harness only auto-cleans
unchanged ones. The
harness auto-cleans only *unchanged* worktrees, and every probe worktree is
changed by construction.

### 2.11 Record

**Finish** `evals/small-model/rounds/NNN.md` — you have been appending since
§2.0, so this step is completing and tidying, not writing from memory. It must
end with: re-measured counts, sampled tasks, per-attempt
scores, retirements, the cause taxonomy, causes fixed, what changed,
`git status --porcelain -uall` (**not** `git diff --stat` — it omits the new
files the fix step creates), and every private symbol renamed. Update
`todo/small-model-readiness.md`, `solved.md`, and reconcile rubrics.

**Rubric reconciliation is round-blocking.** The fix step renames and splits the
very files the rubrics name; re-derive every `expected_files`/`expected_tests`
you invalidated, this round. Otherwise later rounds grade navigation against
files that no longer exist and score correct work as failure.

## 3. What "readable" means here

Not code beauty. Not smaller files as an end in themselves. This:

> A competent small model, given one feature request and no hand-holding, can
> find the right place, understand it well enough to change it safely, and know
> what else it must update — while holding only a small part of this repo in
> context at once.

- **Optimise for local reasoning.** The unit is "one file plus its `features/`
  doc". A change needing four files to verify is the defect even if all four are
  short.
- **Do not repeat the `hq.gd` mistake.** It was already split into `HqTable` /
  `HqCarpark` / `HqOverlays` / `HqChallenge`, each back-pointing into the
  controller's private state — and it is still ~4700 lines. That is extraction
  without decoupling: lines moved, dependencies intact, reader no better off.
  **A split whose parts still need each other's internals has failed** and is not
  progress in a round report.
- **A good seam** can be described in a sentence, takes typed inputs, returns a
  result, does not reach back. If you cannot write that sentence, leave the file
  large and fix a different cause. A large honest file beats five files
  pretending to be five things.
- **Findable by name.** Small models search for the words in the request — name
  things in domain language ("tyre grip", "start line", "region"), avoid
  indirection chains.
- **Explicit over clever.** Typed params over duck-typed `Object` seams
  (`terrain_manager.gd` has four `*_source: Object` injection points a split can
  break with no compile error). A little straight-through repetition beats an
  abstraction to reverse-engineer.
- **Convention at the point of use.** A one-line comment where a literal is
  declared ("tunables live in `config/game_config.tres`") beats another paragraph
  in `CLAUDE.md`, which a small model under context pressure will not have read.
- **Every extracted module ships orientation**: header comment (what it does,
  what it depends on, where its tests live) plus a `features/` entry indexed in
  `features/README.md`. An extraction without a doc entry moved the navigation
  problem rather than solving it.
- **Fixing a doc IS the refactor** when that is what the probes tripped on —
  often the highest-value fix available.

## 4. Contracts a refactor can break silently

Check these against anything you move. All verified present in this repo:

- **`.gd.uid` sidecars** (521 tracked) — a move must carry the sidecar; new
  modules have none until an import runs. Record generated uids in the report.
- **`class_name`** — one flat namespace, ~172 entries. Prefix extracted modules
  by owner (`hq.gd` → `HqLineup`). A collision breaks project load.
- **Autoloads** — 11 in `project.godot`, none with `class_name`, so their statics
  are reached by `preload` of the script (`hq.gd`'s `RallySessionScript` idiom),
  plus ~23 other `preload("res://scripts/*.gd")` sites and `scripts/scenes.gd`'s
  path constants.
- **`scripts/game_config.gd` is split-exempt.** `config/game_config.tres` binds
  it as one `script_class` + `ext_resource`, and
  `snapshot_values()`/`restore_values()` walk *one* script's property list
  (relied on by `car.gd`'s `_live_baseline`, `start_line.gd`'s `_spawn_grid`).
  `Config.data` identity-by-reference is load-bearing — never reassign it.
- **"Private" is not private.** Tests reach into privates of `world.gd` (43 test
  files), `hq.gd`, `car.gd`, `terrain_manager.gd`, `overworld.gd`. A rename
  inside any of them is a test-breaking API change.
- **Save schema** — `SCHEMA_VERSION` and the `_migrate_step` chain; a newly
  persisted field needs a migration.

## 5. Stop / continue

Print `STOP` when, for **two consecutive rounds**: every sampled task was solved
cleanly, no new failure cause appeared, **and** the deliberately-harder
replacement tasks were also solved on first sight. That last clause is the guard
against manufacturing exotic tasks forever — if even fresh hard tasks pass, the
codebase is ready.

Also `STOP` immediately on: a baseline-relative test failure you cannot fix; a
full-suite runtime regression against the baseline; a failed mechanical
post-check; an unreconciled rubric; an unjustifiable `Totals` delta; or a
refactor needing a decision the user must make.

Otherwise `CONTINUE`, with the round's retirements and causes.

**There is no round cap and no cost ceiling** — this is deliberate. The loop runs
until the stop condition genuinely fires. Report each round's cost in its report
so the user can see the trend and interrupt if they want to.

## Out of scope

- Committing, branching, pushing. Ever.
- Landing any probe's diff — a probe is a measurement. If it produced a good
  change, fix the *cause* yourself, from scratch, in the main checkout.
- Changing authored gameplay balance values. You may add a `@export` mirroring an
  existing literal **at its current value**; you may never change an authored
  value in `config/game_config.tres`.
