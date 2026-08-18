# Baseline — current as of the round-008 close, 2026-08-18

Full `./run_tests.sh` on the main checkout with rounds 004–008's uncommitted work in
place. This run **discharges the verification debt** that had accumulated across six
rounds (003 ran no tests; 004–008 ran test mode `fast`, which has no closing full run).

| Metric | Value | Previous (round 002) | Delta |
|---|---|---|---|
| Result | **ALL TESTS PASSED** | ALL TESTS PASSED | — |
| Scripts | 207 | 202 | +5 |
| Tests | **3293** | 3255 | **+38** |
| Passing | 3290 | 3252 | +38 |
| Risky/Pending | 3 | 3 | 0 |
| Asserts | **167,469** | 159,957 | +7,512 |
| Wall-clock (GUT `Time`) | **329.098 s** | 335.051 s | **−5.95 s** |

## Totals conservation (§2.9) — RECONCILED

The +38 is exactly the figure rounds 004–008 predicted while unable to verify it, and
every test is accounted for:

| Round | Added | What |
|---|---|---|
| 003 | +1 | `test_region_assets` region-path guard (written under a no-test directive, never run until now) |
| 004 | +5 | `test_tire_surface_axes` — the tyre-registry guard |
| 005 | +5 | `test_script_breadcrumbs` — 3 validity/cap tests + 2 ratchet tests |
| 006 | +6 | `test_tire_surface_axes` +1 (weather-context), `test_hud` +5 (one bundled test split into six) |
| 007 | +13 | `test_region_docs` +2, `test_speed_lines` +7, `test_rally_session` +4 |
| 008 | +8 | `test_audio` +9, `test_hud_docs` +2, `test_hud` −3 (per-element membership tests deliberately deleted) |

Sum: 1+5+5+6+13+8 = **+38**. No test was silently lost to a discovery or `extends`
failure, which is the hazard §2.9 exists to catch.

## Known-failure list: EMPTY

Nothing is excused. The 3 pendings are the same three standing fixture-conditional
ones as the round-002 baseline, unchanged in identity:

- `fixture profile keeps the garage at the centre; ordering not exercised`
- `no convertible-only car in this fixture lineup — nothing to assert`
- `no blocked car in this fixture lineup — nothing to assert`

These are pendings, not failures. **Any red test is therefore a real regression.**

## Runtime

**329.098 s is the new halt reference.** It is 6 s FASTER than the round-002 baseline
despite +38 tests and +7,512 asserts, so nothing added across rounds 003–008 regressed
the suite's runtime. Comfortably inside the ~5 minute budget in `CLAUDE.md`.

The audio-mixer SIGSEGV remains a genuine engine flake, retried by `run_tests.sh` via
`TEST_CRASH_RETRIES`; a signal-crash run is re-run, never scored. Worth noting that
round 008 added an `Audio` autoload that plays nothing headless by construction, which
should if anything reduce exposure to it.

## What this run unblocks

Backlog item 0 — migrating the star-reward `const`s to `GameConfig` `@export`s — was
deferred out of rounds 005–008 specifically because it needs full-suite verification
(`MAX_STARS_PER_RALLY := STARS_FOR_WIN` is a const expression with 25 call sites). This
baseline is the green tree that work can now be done against.
