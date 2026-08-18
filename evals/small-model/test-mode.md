# Test mode: `fast`

Chosen 2026-08-18 (round 004) — targeted `--fast` runs during the round and a
`--fast` blast-radius run at the close; **no closing full suite**.

Rationale: a standing user preference (persistent memory, "targeted test runs
only") forbids the loop starting a full `./run_tests.sh` on its own initiative —
a full run is ~6 minutes and stalls the session. Round 003 ran under an even
stricter user directive (no test execution at all), which left round 003's new
region guard test unrun; `fast` is the cheapest mode that can close that gap.

## Honest costs of this mode, restated in every round report

- The green-tree invariant is only `--fast`-deep. Order-dependent cross-file
  leakage — this repo's characteristic failure (leaked `Config.data` baselines,
  un-`restore()`d fixture overrides, escaped `change_scene_to_file`, `SimTest`'s
  process-wide settle cache) — passes under `--fast` and is NOT detected.
- Totals conservation (§2.9) cannot run; test/assert deltas are UNVERIFIED.
- The runtime baseline in `baseline.md` (335.051 s, round 002 close) goes stale.
- A round that makes a wide or cross-cutting change must say a full run is OWED.

## Changing it

Edit or delete this file — the next round re-asks. `fast+full` restores the
closing full suite; `none` disables test execution entirely.
