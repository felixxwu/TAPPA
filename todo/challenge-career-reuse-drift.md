# Challenge / career reuse drift — remaining work

All 13 sections of this `/refactor-after-bugfix` spec (2026-07-31, from the "Daily
challenge road drives into the water" bug) are **IMPLEMENTED**, item 4 in its
redesigned form. `features/rally-challenge.md` and `features/cloud-save.md` are the
living docs. One follow-up remains.

## Open: retire the `ChallengeSession.abandon()` alias

`challenge_session.gd` keeps `abandon()` as a **DEPRECATED alias for `pause_run()`**,
solely so existing `if is_active(): abandon()` test teardowns keep compiling. The
terminal DNF path is now reachable only through `report_wreck()`, which is what makes
the "only a wreck DNFs a challenge" rule unmissable — so the alias is pure legacy.

Migrate these five test files to `pause_run()`, then delete `abandon()`:

- `tests/headless/test_start_line.gd`
- `tests/headless/test_menu_flow.gd` (also has a comment referring to `abandon()`)
- `tests/headless/test_challenge_run_end.gd`
- `tests/headless/test_rally_session.gd`
- `tests/headless/test_upgrade_reveal.gd`

Note `RallySession.abandon()` is a different method (career only) and is unaffected.

Also still wanted from item 12: a **synthetic period-key seam for tests**, so a
challenge period can be forced rather than depending on the real clock.
