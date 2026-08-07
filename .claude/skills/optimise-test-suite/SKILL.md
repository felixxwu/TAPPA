---
name: optimise-test-suite
description: Use when the user invokes /optimise-test-suite or asks to speed up, trim, or optimise the test suite — the full `./run_tests.sh` run creeping past its ~5 minute budget, "why are the tests so slow", a test-runtime regression, per-test timing analysis, finding slow tests to rewrite or merge, or pruning tests that add little robustness value. Also covers deleting redundant, tautological, or convention-violating tests.
---

# Optimise the test suite

## Overview

`CLAUDE.md` and [testing.md](../../../features/testing.md) set a **~5 minute
budget** for the full `./run_tests.sh` run. This skill measures the suite against
that budget and, if it's over, brings it back down two ways:

1. **Rewrite / combine** tests so they cost less wall-clock for the same coverage.
2. **Delete** tests that add little or no robustness value.

**This skill ACTS — it does not report and wait.** Unlike
[`/housekeeping`](../housekeeping/SKILL.md), which is deliberately report-first,
here you go with your own recommendation: rewrite the slow tests, delete the
low-value ones, verify green, commit. Do **not** ask the user to approve
individual rewrites or deletions. The one thing you still do is *tell them what
you did* in the final report, itemised, so it's reviewable after the fact.

Acting without asking raises the stakes on being right, so the guardrails in
§4 and §5 are not optional — the failure mode this skill must never produce is a
faster suite that has stopped catching regressions.

## 0. Measure first — never optimise on a guess

Two numbers matter: **total wall-clock** and **per-test cost**. Get both from a
**single** run — the suite takes ~11 minutes, so never spend two. GUT's exit output
has no timings, so ask for the JUnit XML (there is no `-gtimes` flag), and time it
yourself. This mirrors `run_tests.sh`'s own `GUT_BASE` invocation plus the XML flag,
writing the XML to `user://` so it never lands in the checkout (`test_results.xml`
is **not** in `.gitignore`):

```bash
GODOT="${GODOT:-/usr/local/bin/godot}"        # macOS: see CLAUDE.md for the path
W0=$(date +%s); "$GODOT" --headless --import >/dev/null 2>&1   # class-cache warmup
echo "warmup=$(( $(date +%s) - W0 ))s"
S0=$(date +%s)
"$GODOT" --headless --fixed-fps 60 -d -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests/headless -ginclude_subdirs -gexit \
  -gjunit_xml_file=user://test_results.xml > /tmp/suite.txt 2>&1
echo "suite=$(( $(date +%s) - S0 ))s"; tail -6 /tmp/suite.txt   # GUT's Totals block
```

Run it detached (`nohup … &`) and poll, rather than blocking a foreground call past
its timeout. The tail gives you GUT's `Totals` — **record `Tests` and `Asserts`**,
they're the baseline for the §4 no-silent-loss check.

**A truncated run looks like a fast run — always validate before believing a
number.** Invoking Godot directly skips the check `run_tests.sh` does for you: its
`TEST_ERROR_PATTERN` (`SCRIPT ERROR|Parse Error|Failed to load script`) exists
because **GUT's exit status is 0 even when a script error kills the run**. In this
skill's own development a run came back at 279 s versus a 655 s baseline — not a 2.3×
win, but a run that died two-thirds of the way through on a script error, with no
`Totals` block at all. Every time, before comparing timings:

```bash
grep -cE 'SCRIPT ERROR|Parse Error|Failed to load script|Debugger Break' /tmp/suite.txt  # must be 0
grep -c '^res://tests/headless/' /tmp/suite.txt   # script count — must match the baseline
grep -A4 '^Totals' /tmp/suite.txt                 # must exist, with the expected Tests count
```

No `Totals` block, a short script count, or a non-zero error count means **you have
no measurement** — diagnose that first and discard the timing.

The XML lands in Godot's user data dir — on Linux
`~/.local/share/godot/app_userdata/TAPPA/test_results.xml`. Rank by `time`:

```bash
python3 - <<'EOF'
import xml.etree.ElementTree as ET, collections, os
p = os.path.expanduser("~/.local/share/godot/app_userdata/TAPPA/test_results.xml")
root, per_file = ET.parse(p).getroot(), collections.Counter()
cases = []
for ts in root.iter("testsuite"):
    for tc in ts.iter("testcase"):
        t = float(tc.get("time") or 0)
        per_file[ts.get("name")] += t
        cases.append((t, ts.get("name"), tc.get("name")))
print("== slowest FILES ==")
for name, t in per_file.most_common(20): print(f"{t:7.2f}s  {name}")
print("\n== slowest TESTS ==")
for t, f, n in sorted(cases, reverse=True)[:25]: print(f"{t:7.2f}s  {f} :: {n}")
EOF
```

**Critical caveat: JUnit `time` covers test bodies only, not `before_all`.** On the
2026-08 baseline the per-test times summed to 483 s against a 655 s wall-clock — the
missing ~170 s was `before_all` world builds and script loading, invisible in the
XML. So a file with a heavy `before_all` and cheap tests **looks free and isn't**.
Reconcile the two totals every time; if there's a large gap, hunt the `before_all`
builds separately (`grep -n 'func before_all' -A6 tests/headless/*.gd | grep main.tscn`)
and treat the wall-clock number as the real one.

Rules for this step:

- **Run the suite ONCE.** Per `CLAUDE.md`, never start a run while another is
  active, and reuse the result you already have rather than re-running to
  double-check a number.
- **Under budget → stop.** If the full run is comfortably under ~5 min, say so
  with the number and change nothing. Churning a healthy suite is a regression
  risk with no upside. (Do still report the slowest files, so the user knows
  where the headroom went.)
- **Record the baseline**: total wall-clock, warmup seconds, and the top ~20
  files by cost. Every claim in the final report is measured against it.
- **Green before you start.** Note any pre-existing failures and cross-check
  `MEMORY.md` for known baseline failures. A test that was already red is a bug
  signal — it is **not** a deletion candidate (§5).

## 1. The cost model (what actually costs time)

[testing.md](../../../features/testing.md) → *Keeping the suite fast* is the
authoritative version; internalise it before touching anything. The short form:

- `--fixed-fps 60` (in `run_tests.sh`'s `GUT_BASE`) already collapses time spent
  **awaiting frames** — frames run at CPU speed with an unchanged 1/60 delta. So
  "this test awaits 600 frames" is **not** automatically the problem.
- What's left is genuine CPU. The dominant cost is **`main.tscn` generation**:
  `world.gd._ready()` runs the track DFS (~7 s) and scatters trees + bushes
  (~7 s), so a full instantiate is **~15 s of CPU each**.
  `SceneTestHelpers.minimal_world()` cuts that to **<1 s**.
- Second is **physics solver work per step** — settling a car from its spawn
  clearance is ~150 frames of solver, which is why `sim_test.gd` caches the
  settled pose and restores in ~10.

So the levers, in payoff order: *don't build a world you don't inspect* →
*build it once per file, not per test* → *don't settle when you can restore* →
*don't use a scene at all*.

## 2. Prong 1 — rewrite and combine

Work top-down from the measured slowest files. For each, find which lever applies
and apply it.

### 2a. The test does far more work than its assertions need — check this FIRST

Before reaching for any scene-level lever, read what the expensive call actually
*returns* versus what the test actually *asserts*. The biggest single win in the
2026-08 pass was this, not a world build:
`test_track_cache.gd::test_committed_cache_covers_every_event` swept all ~97 rally
events through `TrackCache.lookup()`, which **rebuilds each track's full geometry**
— while asserting only that the entry exists and its `complete` flag is set. Both
are properties of the stored dict. Adding a rebuild-free `TrackCache.raw_entry()`
seam took that one test from **47.6 s to under a second** with zero coverage lost
(the rebuild path is covered on a small synthetic track by two neighbouring tests).

The pattern to look for: a convenience API that does *retrieve + reconstruct*,
*generate + measure*, or *load + validate*, where the assertion only needs the
first half. The fix is usually a small, documented seam on the production side
exposing the cheap half — which is legitimate production code, not test-only
scaffolding, as long as the expensive path still exists and is still tested.

Ask of every slow test: **"what is the cheapest call that could still fail this
assertion?"** If the answer is much cheaper than what it calls, that's the fix.

### 2b. Full generation where `minimal_world()` would do

The biggest *scene-level* win, at ~14 s recovered per instantiate. Find the files
still paying full generation:

```bash
for f in $(grep -rln 'main\.tscn' tests/headless/*.gd); do
  grep -q 'minimal_world' "$f" || echo "$f"
done
```

For each hit, read what it actually asserts. If it never inspects the
**track shape, terrain heightfield, or foliage**, switch it to
`SceneTestHelpers.minimal_world()` immediately before instantiating (in place of
`Config.reset()`), and add `Config.reset()` to `after_each`/`after_all` so the
trimmed track doesn't leak into later files.

Note that `minimal_world()` does **not** touch the `$Floor` heightfield, so a
terrain test can still use it and get real terrain (`test_car_terrain.gd` is the
canary that relies on exactly that; `test_terrain.gd`'s spawn test was converted
on exactly that basis, 10.6 s → <1 s).

**Read the whole file before converting a shared scene, not just the test names.**
`test_smoke.gd` looks like a pile of structural node-existence checks — but one
test counts colliding vs non-colliding `TreeMeshField` children of the shared
scene, so `trees_per_turn = 0` would silently turn it vacuous or red. It and
`test_loading_screen.gd` are the files that legitimately pay full generation. The
grep finds candidates; only reading the assertions confirms one.

Cheaper still: a test that only needs the car + flat ground should instantiate
`res://tests/fixtures/test_track.tscn` directly and skip `main.tscn` entirely —
the `test_debug_arrows.gd` pattern.

### 2c. `before_each` building a world that `before_all` could build once

A world built per test in a 10-test file costs 10× what it needs to. Find them:

```bash
grep -rn -A12 'func before_each' tests/headless/*.gd | grep -n 'main\.tscn'
```

Convert to a shared `before_all` (plain `add_child`, freed in `after_all`) and
restore only the per-test *state* in `before_each`. `test_world_engine_mute.gd`
and `test_load_finished.gd` are the shape to copy; `test_world_water_reconcile.gd`,
`test_car_water.gd` and `test_turbo_fielding.gd` are the shape to fix.

**The catch that makes this a judgement call:** a shared world means tests now
share mutable state. Only do this where the tests don't mutate the world in ways
that leak — or where `before_each` can cheaply restore what they touch (reset the
car transform, re-apply config, clear signals). If a test genuinely needs a
pristine world, leave it per-test and say so. A shared-world conversion that
introduces order-dependence is worse than the seconds it saved: verify by running
the file **and** the full suite, since GUT's file order differs between a
`--fast` run and a full one.

### 2d. Cold settle where a cached pose would do

Physics-scene tests should `extends SimTest` and call `setup_settled_car()`,
which settles once per whole GUT run and afterwards restores the cached
`Transform3D` in `RESTORE_FRAMES` (~10) instead of `SETTLE_FRAMES` (150). A file
hand-rolling its own drop-and-wait is a candidate. `test_car_types.gd` shows the
variant for a per-car-index pose cache.

### 2e. Split scene-free tests out of a scene-building file

When most of a file needs the world but a few tests are pure logic, the pure ones
still pay the `before_each` build. Move them to a sibling file with no scene at
all. This is already done once and is the exemplar to follow:
`test_aero_visible_traversal.gd` was split out of `test_aero_visibility.gd` for
exactly this reason (its header comment says so). `test_engine_logic.gd` (bare
`EngineSim`, no scene) is the same idea at file scale.

### 2f. Combine files that each pay their own setup

Several small files each building their own world pay the setup N times for a
handful of assertions. Where they share the *same* setup and are cohesive, merge
them into one file with a single `before_all`. Good candidates cluster by subject
— e.g. the tiny `test_world_*.gd` files each boot `minimal_world()` + `main.tscn`
for 1–3 assertions.

Keep this honest: **merge only what belongs together.** A 6000-line grab-bag is
its own maintenance cost, and `test_menu_flow.gd` (~5900 lines) is already at the
edge of that. If merging would produce a file with no coherent subject, don't —
take the `before_all` win inside each file instead. Never merge a file that needs
a *different* config baseline (`use_test_config()` vs `minimal_world()`) or a
different catalogue override; you'll create cross-test leakage.

### 2g. Frame counts — the careful case

Reducing an awaited frame count is usually **not** where the win is
(`--fixed-fps` already made frames cheap) and it is the easiest way to silently
weaken a test. Only trim a loop when you can show the assertion is reached well
before the loop ends — e.g. the loop `break`s on a condition and the count is
just a safety ceiling, in which case the ceiling costs nothing and should be left
alone anyway.

**Never** trim frames to make a threshold assertion pass faster. That is
weakening a test, which `CLAUDE.md` forbids outright.

## 3. Prong 2 — delete tests that add little or no value

The goal is a suite that catches as much as before with less to run and read.
Judge value as: *if this test disappeared, what real regression could now ship
unnoticed?* If the honest answer is "none", delete it.

Delete these, no permission needed:

| Category | How to spot it | Why it's worthless |
|---|---|---|
| **Can't-fail / tautology** | Asserts only what the test's own setup just did (`x = 5; assert_eq(x, 5)`), or has no `assert` at all | Passes by construction |
| **Engine-behaviour test** | Asserts a Godot built-in (`Vector3` math, `Array.size()` after an append, a signal firing that Godot guarantees) | Tests Godot, not this project |
| **Duplicate coverage** | The same behaviour asserted in several files | Keep the cheapest and most direct one; delete the rest |
| **Tunable-value pin** | Asserts a specific stat, reward tier, power-to-weight band, ordering across authored entries, or an exported enum's hint string | `CLAUDE.md` bans these — a designer retuning breaks them for no reason |
| **Catalogue-identity dependence** | A logic/physics test reaching for `CarLibrary.by_id("mx5")` etc. and leaning on that entry's stats | `CLAUDE.md` bans these. If it can *only* be written against one authored entry, it's testing the catalogue |
| **Dead feature** | Exercises a system that no longer exists, or is `pending()`/commented out with no ticket | Nothing left to protect |
| **Existence-only restatement of a `.tscn`** | `assert_not_null` on a node the scene file statically guarantees, already covered by `test_smoke.gd` | Scene load already proves it |

Two useful greps to start from (they surface candidates, they don't decide):

```bash
grep -rn 'by_id("' tests/headless/*.gd     # catalogue-identity dependence
grep -rn 'pending(' tests/headless/*.gd    # parked tests
```

For the tunable-value pins, apply `CLAUDE.md`'s test: *"would a designer
retuning this in the inspector break my test?"* If yes, delete the **assertion**
— and if that empties the test, delete the test. Often the right move is to
rewrite rather than delete: keep the behaviour ("applying a car copies its
engine's torque onto the config") and drop the number ("torque is 400").

### Guardrails — do NOT delete

These are the ways this prong goes wrong. Every one of them is a case where a
test *looks* low-value and isn't:

- **A failing test.** Red means a bug or a real behaviour change, never dead
  weight. Report it; leave it.
- **A negative assertion.** `assert_null(ghost._nametag, ...)` proving a thing
  was *not* built is high-value — it's the only thing standing between you and a
  silent re-introduction. Several such tests exist in
  `test_ghost_car_display.gd` and are deliberate.
- **A regression guard for something already removed once.** e.g.
  `test_hud.gd` → `test_hud_has_no_version_label`. It reads trivial; it exists
  because the thing came back.
- **A catalogue-*contract* test.** `test_car_types.gd`, `test_engine_library.gd`
  and the roster invariants in `test_car_library.gd`/`test_car_stats.gd` are
  *supposed* to run against the real shipped data — asserting every real entry is
  well-formed is their entire job. Don't mistake them for catalogue dependence.
- **A whole-table sweep.** "Empty restriction accepts every car in `CARS`",
  "every drawn part is a real catalogue item" — iterating the table as opaque
  input is the encouraged pattern, not a value pin.
- **Sanity guards on values** (`mass > 0`, a grip coefficient is finite). Cheap,
  and they rule out genuinely broken data.
- **The slow-but-load-bearing tests.** `test_loading_screen.gd` and
  `test_smoke.gd` pay full generation *because they assert on it*, and the
  generation sweeps in §3b cost tens of seconds each for real coverage. Slow is
  not the same as low-value — this prong is about value, prong 1 is about cost.
- **A test whose NAME reads worse than its body.** `test_car_library.gd` →
  `test_mx5_renders_the_authored_model_others_render_boxes` names a shipped car and
  looks like textbook catalogue dependence; its body actually derives everything
  from each spec's own `use_model` flag and depends on no particular entry. Judge
  the assertions, never the title. (If you find one of these, the useful fix is to
  rename it so the next reader isn't misled — not to delete it.)
- **Anything whose coverage you can't name a survivor for.** Before deleting a
  duplicate, identify the test that still covers the behaviour. If you can't
  name one, it wasn't a duplicate.

## 3b. When both prongs aren't enough

Sometimes the honest answer is that the remaining cost is irreducible without an
architectural change. This suite's floor is set by a handful of **full-library
generation sweeps** — every authored rally event generated live, ~0.7 s each:

- `test_track_generator.gd::test_every_rally_event_generates_a_complete_track_quickly`
  (~69 s) — the regression guard for the seed-3002 blow-up, where one seed once
  took ~474 s. Its own header explains that the honest baseline moved to ~70–80 s
  when the events were authored ~15% longer, and DFS cost is not linear in
  `turn_count`.
- `test_lakes_integration.gd`, `test_track_gen_frame_consistency.gd`, and the
  challenge-stage generation test in `test_smoke.gd`.

**Do not weaken these to hit the budget.** Sampling a subset of events defeats the
point (the original bug was a *single* seed), and the guard covers something the
lockfile cannot: a DFS *control-flow* regression that `constants_fingerprint()`
doesn't capture, so a fresh `data/track_cache.json` does not imply live generation
is still fast.

When you land here, say so plainly and put the structural options in front of the
user rather than silently accepting a red budget or quietly gutting a guard:

1. **Move the full-library sweeps into a separate slow lane** — a CI/pre-release
   pass like `run_benchmark.sh` is to the suite, leaving the per-change dev loop
   fast. This is usually the right answer, but it edits the CI contract, so
   propose it and let the user decide rather than doing it under this skill.
2. **Re-base the budget** in `CLAUDE.md` and `features/testing.md` with the
   measured floor and the reason, so future sessions stop chasing an impossible
   number.

Either way, report the measured floor and what makes it a floor.

## 4. Verify — mandatory, and the part that makes acting-without-asking safe

You changed tests without asking, so the proof has to be complete:

1. **Run the full suite** (`./run_tests.sh`), not a `--fast` subset. Ordering and
   config/catalogue leakage between files are exactly what these rewrites risk,
   and only a full run exercises that. This is the "wide blast radius" case
   `CLAUDE.md` reserves full runs for.
2. **Same pass/fail as the baseline.** Every test that was green must still be
   green, with its assertions **unchanged** except where you deliberately removed
   a banned value pin (say which, and why, in the report).
3. **Assertion count must only fall by what you deleted.** GUT prints totals —
   compare against the baseline. An unexplained drop means a test silently
   stopped running (a common outcome of a botched merge or a renamed file), which
   looks like a pass and isn't.
4. **Confirm the runtime actually improved**, and by how much. If it didn't,
   revert that change rather than keeping churn that bought nothing.
5. **If a green test goes red, the rewrite is the prime suspect** — per
   `CLAUDE.md`, fix the rewrite. Never weaken the assertion to get back to green.
6. **Expect to shake out latent async races, and prove ownership before blaming
   yourself — or absolving yourself.** Speeding the suite up changes when things
   interleave, so a pre-existing race can start firing on the run that validates your
   work. This happened here: `test_seedlab.gd` left an async `TrackGenerator` search
   in flight (its abort/progress callables are lambdas capturing the menu), GUT then
   autofreed the menu, and the generator polled a half-destroyed owner — faulting
   inside `track_generator._search` and taking the whole run down. It passed under
   `--fast seedlab` every time.
   Establish causality by **ordering and reachability**, not by reverting (which
   `CLAUDE.md` forbids): the failing script was #107 of 164, the test files you edited
   were #121 and #131 (so they had not run yet), and the one production file touched
   was never on the failing code path at all. That's a proof of non-involvement.
   Then fix the race — a flake that aborts the suite is squarely in scope — and say
   plainly in the report that it was pre-existing and how you know.

Per `CLAUDE.md`: other agents may be editing this checkout concurrently. **Never**
`git stash`/`restore`/`reset --hard` to isolate a failure, and if a failure looks
like someone else's in-flight work, report it with the output and your read
rather than "fixing" it.

## 5. Update the docs and commit

- **`features/testing.md`** is the cost model's home — update it in the same
  piece of work (`CLAUDE.md` requires it). If you added a lever, changed which
  files pay full generation, or removed a listed test file, the doc is now wrong
  until you fix it. Keep citations durable: file + symbol, not line numbers.
- If you deleted a test file, check it isn't referenced by name in
  `features/testing.md`'s table, `.claude/skills/`, or CI.
- Commit with the specific paths you touched — never `git add -A`/`git commit -a`,
  since unrelated modified files are probably another agent's work.

## Report format

Lead with the numbers, then the itemised changes (this is the user's chance to
review decisions you already made, so be specific):

```
Baseline:  <total> wall-clock (warmup <n>s) · <n> tests · <n> assertions
After:     <total> wall-clock · <n> tests · <n> assertions
Saved:     <n>s (<n>%)

Rewritten / combined:
  <file> · <lever applied> · <before>s -> <after>s

Deleted:
  <file>::<test> · <category> · covered instead by <surviving test, or "nothing — low value because ...">

Left alone (and why):
  <file> · <n>s · <why the cost is load-bearing>

result: <under / over> the ~5 min budget
```

End with a `result:` line. If the suite is **still** over budget after both
prongs, say so plainly with what's left and the biggest remaining cost — don't
pad the report to look like a win.

## Common mistakes

- **Optimising without measuring.** The intuitive culprit (a 600-frame loop) is
  usually cheap under `--fixed-fps`, while the real cost is a world build you
  didn't notice. Always start from the JUnit timings.
- **Asking for permission.** This skill is explicitly act-first. Go with the
  recommendation; report afterwards.
- **Deleting a slow test instead of making it cheap.** Prong 1 before prong 2 —
  cost and value are different axes. Only delete on *value* grounds.
- **Trimming frame counts to buy time.** Nearly always weakening the test for
  almost no gain, since `--fixed-fps` already made frames cheap.
- **Merging files into an incoherent grab-bag**, or merging files with different
  config baselines / catalogue overrides — that's how leakage bugs get born.
- **Verifying with `--fast` only.** The risks these rewrites introduce
  (order-dependence, leaked `Config`/catalogue overrides) are invisible in a
  single-file run — that's precisely the green-on-fast/red-in-CI trap
  `features/testing.md` warns about.
- **Forgetting `CarFixtures.restore()`** (or the rally/upgrade equivalents) when
  restructuring a file that installs a synthetic roster. A leaked override
  breaks every file that runs after it — a mandatory rule in
  `features/testing.md`.
- **Leaving `Config` trimmed.** A file that calls `minimal_world()` must
  `Config.reset()` in `after_each`/`after_all`, or later files silently run on a
  1-turn, tree-free world and their assertions stop meaning what they say.
- **Counting the warmup as suite time.** The `--import` class-cache warmup is a
  fixed ~15 s that isn't test cost and isn't yours to optimise; report it
  separately.
- **Leaving `test_results.xml` in the checkout.** It isn't gitignored — write it
  to `user://`.
- **Believing a timing without validating the run finished.** GUT exits 0 on a script
  error; a run that died early reads as a huge speedup. Check `Totals`, the script
  count, and the error grep every single time (§0).
- **Adding a "safety" guard without checking the engine semantics first.** A one-line
  probe script settles what Godot actually does far faster than reasoning about it —
  e.g. a lambda capturing `self` whose owner is freed reports `is_valid() == false`
  and `get_object_id() == 0`, indistinguishable from an unset `Callable()`, so an
  id-based dangling-callable guard cannot work. Probe, then fix the root cause (there,
  the test leaving work in flight) instead of hardening the wrong layer.
- **Running two suites at once**, or re-running to re-check a number.
