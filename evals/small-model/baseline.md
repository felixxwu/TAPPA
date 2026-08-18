# Baseline — current as of round 002 close, 2026-08-18

Round 003 inherits this and must NOT re-run the suite at its start.
Closing full `./run_tests.sh` of round 002 (commit `99e8565` + rounds 001–002's
uncommitted changes).

| Metric | Value |
|---|---|
| Result | **ALL TESTS PASSED** |
| Scripts | 202 |
| Tests | 3255 |
| Passing | 3252 |
| Pending/risky | 3 (fixture-conditional) |
| Asserts | 159,957 |
| Wall-clock | **335.051 s** (GUT `Time`; `5:48.28` including engine start/import) |

Round-001 close for comparison: 201 scripts / 3249 tests / 159,611 asserts / 345.4 s.
Delta is +1 script, +6 tests, +346 asserts — `test_features_docs.gd` (4),
`test_every_grip_feeding_effect_field_is_read_by_the_physics` (1) and
`test_every_region_is_reachable_from_at_least_one_rally` (1), all justified in
`rounds/002.md`. Runtime improved by 10 s; no regression.

## Known-failure list: EMPTY

Nothing is excused. The full round-002 run was green with only the 3 standing
fixture-conditional pendings (`test_overworld` ×1, `test_overworld_picker` ×2), which are
pendings, not failures.

**Any red test is therefore a real regression** and belongs to whichever round produced
it. Do not excuse a failure by citing this file unless the failure is named in this
section — and right now, nothing is.

The audio-mixer SIGSEGV remains a genuine engine flake: `run_tests.sh` retries signal
deaths via `TEST_CRASH_RETRIES`. A signal-crash run is re-run, never scored. That is
separate from a test failing. It did not fire in the round-002 closing run.

## Runtime

335.051 s is the halt reference. A round halts on a runtime **regression against this
number**, not against any absolute budget.
