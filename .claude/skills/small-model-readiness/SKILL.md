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
each step to see what's next. (One exception: a **structural round** — declared
per §2.6 when an overdue layer-1 fix needs the whole round — skips steps 3–7 and
spends the round on that fix; steps 1–2 and 9–12 still apply in full.)

1.  Verify preconditions; resolve test mode, asking if unset (§0.5, §2.0);
    re-measure size
2.  **Open `rounds/NNN.md` NOW; append to it at every step below** (§2.0)
3.  Retire / replenish / sample ~5 tasks (§2.1)
4.  Create + seed + verify one worktree per task, then dispatch probes (§2.2)
5.  Run each probe's `expected_tests` — you, serially, in its worktree (§2.3;
    skipped under test mode `none`)
6.  Grade each diff, 4 axes (§2.4)
7.  Taxonomise every failure into a cause (§2.5)
8.  Fix top 1–3 causes in the main checkout, layer coverage per fix (§2.6)
8a. **Durability pass — make each fix survive the NEXT file** (§2.6a). Not
    optional and not foldable into step 8: a fix applied to today's files decays
    the moment someone adds one.
9.  Closing suite per test mode — full under `fast+full`, `--fast` blast-radius
    under `fast`, skipped under `none`; any red is yours to fix (§2.7)
10. Mechanical post-checks (§2.8) + Totals conservation (§2.9)
11. Tear down every probe worktree (§2.10)
12. Finish the report; update bank/backlog/baseline; print CONTINUE/STOP (§2.11)

## Assumptions

- **Sole occupancy.** No other agent is working in this checkout. This is what
  makes "any red test is ours — fix it" safe. If the user says others are
  working, stop and say so.
- **The tree is green on entry — as deep as the test mode proves.** Under
  `fast+full` (§0.5) that is the previous round's closing full run, established
  at loop start by the P4 baseline; do NOT re-run the suite at the start of a
  round — that runs it twice back-to-back for the same answer. Under `fast` the
  invariant is only `--fast`-deep; under `none` it is unverified and the reports
  must say so.
- **At most one full-suite run per round**, at the end, and only under
  `fast+full`. Per-attempt checks are targeted `--fast` selections. Which runs
  happen at all is the user's test-mode choice (§0.5), never yours.

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

**P4 — the green baseline (first run only; skipped under test mode `none`,
see §0.5).** One full `./run_tests.sh`; record
the pass/fail set and wall-clock in `evals/small-model/baseline.md`. If it is not
green, stop and report — never probe against a red tree. The suite has been over
the ~5 min budget at every measurement so far; `features/testing.md` carries the
current floor and it MOVES, so read it rather than trusting any number pinned in
a doc. Your halt condition is a regression against your own baseline, never
against an absolute.

**Scaffolding (first run only)** — these are the loop's own files, yours to
create without asking: `evals/small-model/{tasks.md,solved.md,baseline.md,rounds/}`
and `todo/small-model-readiness.md`. Then author the seed bank per §1.

## 0.5 Test mode — ask once, then honour it

Testing during rounds is **optional and user-chosen**. On the first round (or
whenever `evals/small-model/test-mode.md` is missing), ask the user — one
question, three options — and persist the answer to that file so `/loop`-driven
rounds do not re-ask:

- **`fast+full`** — per-attempt `--fast` runs (§2.3) AND the closing full suite
  every round (§2.7). The full behaviour this skill was written for.
- **`fast`** — per-attempt and blast-radius `--fast` runs only; **no closing
  full suite**. Cheaper per round. Honest costs, stated in every report: the
  green-tree invariant is only `--fast`-deep, order-dependent cross-file leakage
  goes undetected (this repo's characteristic failure), Totals conservation
  (§2.9) cannot run, and the runtime baseline goes stale.
- **`none`** — no test execution at all. The correctness axis (§2.4) is graded
  by inspection of the diff alone and must be reported as such; red tests can
  accumulate silently across rounds. The mechanical post-checks (§2.8) still
  run — they are greps and a project-load, not tests — and P4's one-off baseline
  is skipped.

The user can change mode at any time by editing or deleting `test-mode.md` (the
next round re-asks). Every round report states the mode it ran under. When a
round under `fast` or `none` makes a wide or cross-cutting change, say in the
report that a full run is OWED and recommend the user schedule one — do not
silently upgrade the mode yourself.

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

The tree is green on entry as deep as the test mode proves (see Assumptions).
**Do not run the suite here** in any mode. Resolve the test mode now: read
`evals/small-model/test-mode.md`, or ask the user per §0.5 if it is missing.

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

**Test mode `none`: skip this step** — record "not run (mode: none)" per attempt
and grade correctness by inspection. Otherwise:

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
  baseline*? (Under test mode `none` this is graded from the diff alone — say so
  in the score's note; a 3 by inspection is weaker evidence than a 3 by run.)
- **convention** — `features/` updated and indexed, config values in the right
  place, and the probe's **newly written tests** checked against
  `test_conventions`?
- **completion** — finished, versus stalled or context-exhausted?

**Static-grading mode (when the user has forbidden test runs):** grading still
works, and worked well in round 003 — but only if the grader is told to VERIFY,
not trust. Instruct it to: confirm every edit the probe *claims* by reading the
diff; grep the whole repo (tests included) for every symbol whose signature or
arity changed (this caught a compile-breaking test-caller miss without executing
anything); and check that every authored resource path exists on disk. The round
report must state that the green-tree invariant is unproven and name the tests
that were written but never run.

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

**The escalation trigger is mechanical, not a judgement call: if the same AREA
has produced a failure in three rounds, layer-1 restructuring of that area is
mandatory that round, and comments/tests no longer count as a fix for it.** The
grip area proved this: three rounds, three differently-shaped failures
(undeclared field → declared-but-unread field → correct expansion that broke
test callers), each "fixed" with a longer note — when the actual defect was a
design that forces a 6-site edit. When a point-of-use checklist grows past ~3
sites, **the checklist itself is the defect — collapse the sites** (e.g. a dict
keyed by domain name beats N parallel parameters).

**Take the correct option, not the cheap one.** "Correct" means the failure mode
can no longer be written; "cheap" means it is warned about. When you catch
yourself documenting around a design defect, the document is the cheap option
and the restructuring is the correct one — take the correct one; the loop
exists to spend that effort. Do not let the frequency × cost ranking launder
this choice: a comment sweep scores as low-cost because its RISK is low, but
for this loop's purpose the accounting is closer to the reverse — every comment
adds context load for a small model and rots, while a good seam removes the
need for the context at all. This is strictness about correctness, not about
size: a large fix that moves lines without cutting dependencies is the `hq.gd`
mistake (§3) and is still wrong. And a correct fix carries its verification
cost with it — in a test-forbidden round, that means applying the §2.4
repo-wide grep discipline to your own change, or deferring the fix to a
structural round rather than shipping it unverified.

**Make the correct path CHEAP; do not merely forbid the cheap wrong one.** These
agents complete what is cheap and stop at their own model of "done" — which is a
better predictor of what they skip than how prominently anything is stated. So a fix
that BANS a shortcut without supplying an equally cheap correct route does not remove
the failure, it relocates it. Round 007 told probes to prefer adding a rally over
retagging one; round 008's probe obeyed, found authoring a rally meant discovering a
schema in another file, and tagged nothing at all — its own report said it knew. If
you take away the one-token path, ship a paste-and-edit template in its place, and
make the guard's failure message hand back the patch rather than a complaint.

**Prefer deleting an obligation over describing it.** Before writing another note,
ask whether the obligation should exist. Round 006 added per-element named tests so a
membership change would fail a test named after the thing changed; that worked once,
then made the constant's own "this is a one-line edit" promise false and got skipped.
The fix was to DELETE those tests — they pinned a product choice, which this project's
own rules forbid — leaving the membership-driven test that needs no edit ever. A
three-part change became two.

**Notes at the edit site have a ceiling, and you will hit it.** §2.6a's ranking is not
decoration: by round 008 the `REGIONS` table carried a ~30-line comment block that
probes demonstrably READ and still did not fully obey, while the one intervention with
a clean before/after — a machine-checkable doc guard — worked the first round it
existed. When a note has failed twice, the next fix must be an executable check or a
deleted obligation, never a third note. Count the comment lines you are adding and
delete what your addition makes redundant.

**Probes cannot run tests, so a test-based ratchet is invisible to them mid-task —
and that is fine.** Twice in round 008 the completeness gate existed and fired, and
the probe shipped anyway because it could not see red. Do not read that as the guard
failing: the guard protects the REPO, which is the actual goal, and a real user's
model would run the suite. But it does mean this loop measures "can a small model get
it right BLIND", which is strictly harder than reality, so **the scores understate
readiness** — say so when reporting them, and never fix a cause by making the probe
smarter about tests it is not allowed to run. If an agent knows it left work undone
and hands back anyway (round 008's T003 wrote the gap into its own report), no note
can fix that; only a stopping condition it cannot self-certify past.

**Structural rounds.** A real layer-1 restructuring competes for the round with
probing, grading, and reporting — that schedule pressure is exactly what makes
the cheap option attractive. When the mechanical three-round trigger above has
fired (or a fix you know is correct clearly won't fit alongside a probe cycle),
declare the round a **structural round** in its report: skip §2.1–§2.5
(no sampling, no probes, no graders), spend the whole round on that one fix
with full §2.7–§2.11 closing discipline, and let the NEXT round's probes be the
measurement of it — bias its sampling toward the restructured area. This is an
escape valve for overdue structural work, not a way to dodge probing: never run
two structural rounds back-to-back.

Rules of thumb the fix step must apply, learned the expensive way (round 003):

- **Checklists must be derivable, not enumerable.** Probes execute lists
  *exactly and only as written* — they stop where the list stops, and stale
  enumerations rot. A point-of-use note should give the search command ("grep
  the ENTIRE repo, scripts/ AND tests/, for `<symbol>`"), not the site list —
  and must say "update this note too" if the note states a fact the change can
  invalidate.
- **Every convention you introduce ships with its own enforcement test, in the
  same round.** A convention without a guard is the half-fix pattern in a new
  coat (round 003 added `# Docs:`/`# Tests:` breadcrumbs to 82 scripts with
  nothing checking that new scripts get one or that the pointers stay live).
  §2.6a is where you prove this per fix — and note that the guard must cover the
  files that do not exist yet, not merely validate the ones you just edited.
- **A name that lies about its metric is a priority refactor, not a backlog
  item.** Rename it and leave a one-line deprecated wrapper for compatibility —
  the shim makes the rename cheap, and documentation of a lying name only
  preserves the lie (round 003: `completed_rally_count()` counts top-3 finishes;
  a probe shipped "Rallies Completed" to the UI).
- **Keep in-code pointers short.** A breadcrumb naming 16 test files is noise a
  small model will not triage; cap it at the 2–3 primary ones.

State in the round report, per fix, which layers it covers and why the ones it
skips are skipped — and, per §2.6a, what carries it forward to files that do not
exist yet.

### 2.6a Durability — will this fix still be true in fifty files' time?

**The question this step exists to force:** *what happens to my fix when someone
adds a new file, a new menu, a new catalogue row, a new setting tomorrow?* A fix
that improves the 82 files that exist today and says nothing about the 83rd has
bought a decaying asset. The codebase drifts back, the next round re-discovers the
same cause, and the round after that "fixes" it again with a longer comment.

This is the sweep-versus-ratchet distinction, and it is the single most common way
this loop wastes a round:

- A **sweep** changes the files that exist now. Breadcrumbs added to 82 scripts.
  A stale value corrected in four docs. A note planted at six call sites.
- A **ratchet** makes the property true of files that do not exist yet. It has
  teeth: something FAILS when the property is violated, and the failure names the
  fix.

**A sweep without a ratchet is half a fix, and must be reported as one.** Round 003
swept `# Docs:`/`# Tests:` breadcrumbs into 82 scripts with nothing requiring the
83rd to have one; round 005 had to come back and cap the lists AND guard them. That
round-trip is the cost of skipping this step.

For **every** fix in §2.6, write down in the round report which of these carries it
forward — and if the answer is "nothing", say so explicitly rather than letting it
pass as done:

1. **An enforcement test** — the strongest, and the default. It runs in CI, it
   fails loudly, and the failure message can name the fix. Prefer a test that
   derives its subject list from the filesystem or a registry (`every script in
   scripts/`, `every row in REGIONS`) over one that hardcodes today's list — a
   hardcoded list is itself a sweep and rots identically.
2. **A structural impossibility** — the failure mode cannot be written. A registry
   that must be extended for the feature to work at all beats any test, because
   there is nothing to remember. This is layer 1 of §2.6 and the best answer when
   it is available.
3. **A copyable sibling** — a one-concern template file, or a canonical example the
   convention points at. Small models clone neighbours; make the nearest neighbour
   correct. Note that a sibling only propagates a pattern if the NEW file is
   plausibly created by copying it.
4. **A point-of-use note** — the weakest, and acceptable only where nothing above
   can apply (e.g. a fact about a value a test may not assert). Never let a note be
   the sole durability mechanism for a convention about FILES; a new file does not
   contain the note.
5. **`CLAUDE.md`** — project-wide rules a person will read. Real, but remember the
   loop's own evidence: a small model under context pressure does not reliably read
   it, which is why `CLAUDE.md` is a supplement to a test and not a substitute.

**The baseline-allowlist ratchet.** When a property should hold for all future files
but does not hold for all current ones, do not give up on the ratchet and do not
"fix everything first". Freeze the current violators in an explicit exemption list
inside the enforcement test, and assert two things: anything NOT on the list must
comply (so every new file complies by default), and anything ON the list that has
since started complying must be REMOVED from it (so the list can only shrink and
cannot silently absorb new violations). This converts an unfinishable sweep into a
ratchet that tightens on its own.

**Ask it of the convention, not just the code.** If the fix introduced a rule
("breadcrumbs name at most 3 tests", "reward amounts are GameConfig knobs"), the
rule itself needs a home where the next author meets it — the enforcement test's
failure message is usually the best one, because it is delivered exactly when it is
needed and cannot be skipped.

### 2.7 Verify

**Mode-dependent.** Under `none`: skip, and record that the round closed
unverified. Under `fast`: run `--fast` across the round's blast radius instead
of the full suite, and state in the report what a full run would additionally
have covered. Under `fast+full`:

The round's **one** full-suite run. It is **unconditional** under this mode — the next round
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

Requires a full-suite run, so `fast+full` mode only — under other modes record
the delta as UNVERIFIED. Any round touching test files records GUT's `Totals` (Tests **and** Asserts)
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
files the fix step creates), every private symbol renamed, and **a durability line
per fix** (§2.6a): sweep or ratchet, and if a sweep, what makes the next file
comply. A fix whose durability line reads "nothing" is carried into the backlog as
unfinished, not filed under Fixed. Update
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
  indirection chains. **Audit this per failed task in §2.5:** take the request's
  own nouns and grep for them; if the user's vocabulary doesn't hit the owning
  file (round 003: "profile" matched nothing, the code says "overlay"/"save"),
  that mismatch is itself a fixable cause — rename, or plant the word where it
  belongs.
- **The best structure for a small model is a copyable sibling.** Where a
  pattern exists only as folklore spread across files (round 003: every
  persisted setting has a boot-time apply-owner, but the pattern lives in three
  unrelated scripts), consider restructuring it into one-concern template files
  in a shared folder — cloning a 30-line neighbour is the task small models are
  best at.
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
