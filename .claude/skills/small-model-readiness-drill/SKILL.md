---
name: small-model-readiness-drill
description: Use when the user invokes /small-model-readiness-drill, or asks to run the small-model readiness loop one task at a time, to drill a single task until a fresh Haiku agent can complete it unaided, or to fix the codebase until a small model succeeds rather than sampling five tasks in parallel. A serial, inner-loop variant of /small-model-readiness — one task, one probe at a time, fix-and-retry with a fresh probe until it passes or the task is deemed too hard and discarded.
---

# Small-model readiness — drill mode

## Relationship to `/small-model-readiness`

**This skill is a variant, not a replacement.** The baseline operation — every
precondition, every rule, every contract, every definition of "readable" — is
`.claude/skills/small-model-readiness/SKILL.md`. **Read that file first, in
full, at the start of every drill round.** It is the source of truth for:

- §0 preconditions P1–P4 and §0.5 test mode (ask once, persist, honour)
- §1 the task bank format, hidden rubrics, retirement, the 8-task floor
- §2.2 worktree creation + seeding + transplant (including the rubric exclusion)
- §2.3 how the parent runs tests (and that probes/graders never do)
- §2.4 the four grading axes and static-grading mode (the axes are
  inherited; *who* applies them is overridden — see §D3a)
- §2.5 the cause taxonomy
- §2.6 / §2.6a the fix discipline: layers, sweep-vs-ratchet, durability
- §2.7–§2.10 closing suite, mechanical post-checks, Totals, teardown
- §3 what "readable" means, §4 silently-breakable contracts, "Out of scope"

Everything in that file applies here unchanged **except** where this file
explicitly overrides it. The overrides are all in one place: §D below. If the
two ever conflict on anything not listed in §D, the original wins.

The non-negotiables carry over verbatim and are worth restating, because drill
mode multiplies the number of dispatches and so multiplies the chances to break
them:

1. **You (the parent) run every test. Probes and graders never do.**
2. **Probe worktrees are created and seeded BY YOU, before dispatch** — no
   `isolation: "worktree"`, and re-seeded from the CURRENT main checkout on
   every attempt (see §D3).
3. **Never commit.** The user owns committing and reverting.

## D. The overrides — what drill mode changes

### D1. One task per round, one probe at a time

The original samples ~5 tasks and dispatches ~5 Haiku probes in parallel. Drill
mode samples **one** live task (§2.1 selection weighting still applies) and runs
**one** Haiku probe at a time. No parallel fan-out. The round's whole budget goes
into that single task.

### D2. The inner loop — fix until a fresh probe succeeds

The heart of this variant. For the drawn task, repeat:

```
attempt := 1
loop:
  seed a FRESH worktree from the CURRENT main checkout      (§D3)
  dispatch ONE fresh haiku probe, bare task text            (original §2.2 prompt)
  run its expected_tests yourself, per test mode            (original §2.3)
  grade it YOURSELF, inline, 4 axes                          (§D3a)
  if clean (full marks on all four axes):
      record the pass and the attempt number  ->  EXIT LOOP, task PASSED
  taxonomise the failure into a cause                       (original §2.5)
  fix that cause in the MAIN checkout                       (original §2.6)
  durability pass on the fix                                (original §2.6a)
  attempt := attempt + 1
  if attempt > MAX_ATTEMPTS:  ->  EXIT LOOP, task TOO_HARD  (§D5)
```

**`MAX_ATTEMPTS = 3`** unless the user says otherwise. Persist any override in
`evals/small-model/drill-config.md` alongside `test-mode.md`.

Three is a starting value, not a measured one. The attempt curve in §D7 is what
retunes it: if most tasks pass at 1 the cap is idle and the tasks are too easy;
if passes cluster at 3 it is too tight and real fixes are being abandoned one
attempt short. Revisit it after a few rounds rather than treating it as settled.

Each iteration is a complete probe → grade → fix cycle against a codebase that
now carries every prior iteration's fix. That is the point: the loop asks "what
would this codebase have to look like for a small model to get this right?" and
then makes the codebase look like that, one catchable cause at a time.

**The probe is the only idle window, and it is not a window for fixing.** With
grading inlined (§D3a), every other part of an attempt is parent work; the one
stretch where you are genuinely waiting is while the Haiku probe is out. That
cannot be removed — the probe *is* the measurement, and it must be a separate
fresh agent by construction. The tempting way to fill it is to start the next
fix, and that is exactly what §D3a forbids: deciding a fix before you have seen
the failure is the back-filling that a separate grader used to make structurally
hard. The probe's worktree is already seeded, so a main-checkout edit would not
corrupt *that* attempt — the damage is to your grading, which is why the ban is
about your reasoning order, not about file safety.

Work that is safe to do while a probe is out — bookkeeping that touches no code
the loop is measuring:

- Writing up the previous attempt in `evals/small-model/rounds/NNN.md` (§D7).
- Reconciling rubrics the previous fix invalidated (original §2.11) — renamed
  files, split modules, moved tests.
- Replenishing the task bank toward the 8-task floor, or authoring the
  too-hard write-up for a discarded task (§D5).
- Re-reading the original skill's §2.6/§2.6a before the fix you have not yet
  chosen.

Not safe: any edit to `scripts/`, `tests/`, `features/`, or config. If you have
nothing on the bookkeeping list, wait.

**The probe must be genuinely fresh every attempt** — a new `Agent` dispatch,
`model: "haiku"`, no memory of prior attempts, no `SendMessage` to a prior
probe, no hint that this is attempt N, no mention of what changed. If a probe
knows it is being retried, the measurement is dead: you are then testing whether
a hint works, not whether the codebase teaches.

### D3. Re-seed the worktree every attempt, from the current main checkout

The original seeds once per task, before a single dispatch. Here the main
checkout **changes between attempts** — that is the entire mechanism — so:

- Tear down the previous attempt's worktree (`git worktree remove --force`)
  before creating the next; never reuse one.
- Re-run the original §2.2 seed procedure in full for each attempt, against the
  main checkout as it stands NOW, including the untracked-file transplant and
  the `evals/small-model/` + `todo/small-model-readiness` exclusions that keep
  the rubric out of the probe's hands.
- **Verify the seed carried this attempt's fix** — diff the file you just
  changed against the worktree copy. A probe that runs against a tree missing
  the fix produces a false failure and burns an attempt; this check is cheap and
  catches it.
- Name worktrees `.claude/worktrees/drill-<task-id>-a<attempt>` so debris is
  attributable.

### D3a. The parent grades, inline — no grader subagent

The original dispatches one Opus grader subagent per attempt because five
attempts are graded at once and the parent is busy orchestrating them. Drill
mode is serial: while grading would happen, **the parent has nothing else to
do**. So grade the attempt yourself, inline, and skip the grader dispatch
entirely. It is the same model tier doing the same reading, with less latency,
no prompt round-trip, and no summary-of-a-summary between you and the diff.

Everything about *how* to grade is unchanged from the original §2.4 — the same
four axes (navigation, correctness, convention, completion), the same 0–3
scale, the same rule that excused failures come only from
`evals/small-model/baseline.md`, the same static-grading discipline under test
mode `none`. You are now the audience for those instructions instead of a
subagent.

Three things the delegation was implicitly buying, which you must now supply
deliberately:

- **You still do not trust the probe's report.** The original's static-grading
  instruction ("VERIFY, not trust") was aimed at a grader and now binds you:
  confirm every edit the probe *claims* by reading the diff; grep the whole
  repo — `scripts/` **and** `tests/` — for every symbol whose signature or arity
  changed; check that every authored resource path exists on disk.
- **Grade before you diagnose.** Read the diff and score the four axes first,
  then move to §2.5 taxonomy and the fix. Deciding the fix first and
  back-filling a score to justify it is the failure mode a separate grader
  made structurally hard, and it is now on you to avoid.
- **You wrote the previous attempt's fix, so you are not a neutral reader.**
  This is the one real cost of inlining, and drill mode makes it sharper than
  the original ever could: by attempt 3 you are grading a probe against a
  codebase you shaped specifically to help it. Guard it by scoring against the
  rubric in `evals/small-model/tasks.md` as written — `expected_files`,
  `expected_docs`, `expected_tests`, `test_conventions`, `conventions` — and not
  against your memory of what you hoped the fix would achieve. If a probe
  reached the right file by a route your fix did not create, navigation is still
  a 3; if it missed despite your fix, the fix did not work and the score says
  so. Record the axis scores in the report before writing the next fix, so the
  attempt curve (§D7) is a record and not a narrative.

**Escape hatch:** if the attempt is genuinely contested — you cannot separate
"the probe failed" from "my last fix was wrong" — dispatch one independent
grader subagent per the original §2.4 for that attempt only, and say in the
report why. Delegation stays available as a tiebreaker; it just stops being the
default.

### D4. The fix between attempts must generalise, never target the probe

The single largest risk in drill mode, and the one the parallel design did not
have. Iterating against one fixed task invites overfitting: it is very easy to
make attempt N+1 pass by handing the answer over rather than by making the
codebase legible.

**Forbidden between attempts:**

- Writing the task's text, or a paraphrase of it, into any file the probe reads.
- Adding a doc section, comment, or template that describes THIS feature request
  specifically ("to add a gravel tyre, edit X then Y").
- Landing any part of a probe's diff. A probe is a measurement (original "Out of
  scope"). If a probe wrote the right change, you still fix the CAUSE from
  scratch yourself.
- Anything in the original's "Out of scope" list.

**The test each fix must pass before you dispatch the next probe** — state the
answer in the round report, per fix:

> Would this fix have helped a probe on a DIFFERENT task in the same area? Name
> the other task or feature it also serves.

If you cannot name one, the fix is task-shaped and must be reworked into
something general or dropped. This is §2.6a's durability question sharpened for
the serial loop: sweep-vs-ratchet still applies, and a ratchet is by
construction general while a note aimed at one request is by construction not.

### D5. Too-hard: the attempt cap, and what happens after

When `MAX_ATTEMPTS` iterations have run without a clean solve, the task is
**too hard for the codebase as it can reasonably be made this round**. Then:

- Mark the task `status: too_hard (round NN, N attempts)` in
  `evals/small-model/tasks.md` and move it out of the live pool (it does not go
  to `solved.md`; give it a `too-hard.md` section or file so it is not silently
  lost — a later structural round may make it winnable, and the user may want to
  look at it).
- **Keep every fix made along the way.** They were real causes, fixed in the
  main checkout, and each one passed §D4's generalisation test. A discarded task
  does not mean a wasted round; it means the task outran the loop, not that the
  fixes were wrong. Say so plainly in the report rather than framing the round as
  a failure.
- Write down WHY it was too hard, in cause terms — the same taxonomy as §2.5,
  plus whether the failures repeated (same cause every attempt = a structural
  defect you did not reach) or wandered (a different cause each attempt = the
  task is too broad to be one task, and should be re-authored as two).
- Then **draw a fresh task and start a new inner loop** on it, same rules.

**Round-level cap: at most 2 too-hard discards per round.** After the second
discard, close the round (§D6) rather than drawing a third. A round that keeps
drawing forever never reaches its closing suite, and an unclosed round leaves
worktrees on disk and the green-tree invariant unproven — the failure the
original called out in its Overview.

**A repeated too-hard is the structural-round trigger.** If a task is discarded
as too hard and the same AREA has produced failures in earlier rounds, the
original §2.6 mechanical three-round trigger has fired: declare the next round a
**structural round** per the original's rules and spend it on that area's
layer-1 restructuring. Do not drill the same area again with notes.

### D6. Round shape and closing

A drill round is one to three inner loops (a pass, or a discard plus a fresh
task, at most twice), then the original's closing discipline **in full and
unchanged**:

1. Preconditions + test mode + size picture (original §2.0)
2. Open `evals/small-model/rounds/NNN.md` immediately and append at every step —
   including **every attempt** of every inner loop (§D7)
3. Draw one task (original §2.1 weighting; retire/replenish/floor rules apply)
4. Inner loop per §D2 until PASSED or TOO_HARD
5. On TOO_HARD: record per §D5, draw a fresh task, repeat step 4 (max 2 discards)
6. Closing suite per test mode (original §2.7) — any red is yours to fix
7. Mechanical post-checks + Totals conservation (original §2.8, §2.9)
8. Tear down **every** worktree from **every** attempt (original §2.10, and note
   drill mode creates several per round — check `git worktree list`)
9. Finish the report; update bank / `too-hard` / backlog / baseline; reconcile
   rubrics (original §2.11)
10. Print `CONTINUE` or `STOP` (§D8)

**The round ends at step 10 and nowhere else.** A passed inner loop is a
waypoint, not a resting point — the original's warning applies with more force
here, because a clean solve feels like the end of the work and is not.

**Cost note.** Drill mode is serial, so wall-clock per round is longer than the
parallel original — up to `MAX_ATTEMPTS` probe+grade cycles instead of one round
of five in parallel. That is the trade being made: depth on one cause chain
instead of breadth across five. Report the attempt count and cost per round so
the user can see the trend, per the original's no-cost-ceiling stance.

### D7. What the report must additionally record

Everything the original §2.11 requires, plus, per inner loop:

- The task, and the attempt count it took (or that it hit the cap).
- **A per-attempt line**: attempt N → cause diagnosed → fix applied → durability
  (sweep or ratchet) → §D4 generalisation answer (which other task/feature it
  also serves) → next attempt's outcome.
- The **attempt curve** in grading terms: did the four-axis scores climb across
  attempts, plateau, or wander? A climb says the fixes are landing. A plateau
  says you are fixing the wrong layer — escalate per the original §2.6 rather
  than adding another note. Wandering scores say the task is too broad.
- For a discarded task: the too-hard analysis from §D5.

This per-attempt trace is the artefact drill mode exists to produce. The parallel
original gives you a wide, shallow cause census; this gives you one deep,
causally-ordered chain showing exactly what had to change before a small model
could do the job unaided. Do not compress it into a summary.

### D8. Stop / continue

The original §5 conditions apply, plus one drill-specific `CONTINUE` nuance:
a round that ends in a too-hard discard is still `CONTINUE` — the discard is the
loop working as designed, not a halt condition — unless it fired the structural
trigger in §D5, in which case say so in the verdict and make the next round
structural.

`STOP` immediately on the original's hard conditions (unfixable red, runtime
regression, failed mechanical post-check, unreconciled rubric, unjustifiable
Totals delta, a decision only the user can make).

`/loop /small-model-readiness-drill` drives the rounds; do not loop rounds
internally (the inner loop of §D2 is within a round and is not the same thing).
Under dynamic `/loop` pacing, schedule the next round immediately
(`delaySeconds: 60`, `noop: false`) on `CONTINUE`, and `stop: true` on `STOP` —
same as the original.
