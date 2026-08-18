# Challenge / career reuse drift — remaining work

All 13 sections of this `/refactor-after-bugfix` spec (2026-07-31, from the "Daily
challenge road drives into the water" bug) are **IMPLEMENTED**, item 4 in its
redesigned form. `features/rally-challenge.md` and `features/cloud-save.md` are the
living docs. One follow-up remains.

## Open: retire the `ChallengeSession.abandon()` alias

`challenge_session.gd` keeps `abandon()` as a **DEPRECATED alias for `pause_run()`**,
solely so existing `if is_active(): abandon()` test teardowns keep compiling. The
terminal DNF path has since been **removed outright**: `report_wreck()` and
`_end_as_dnf()` are both gone from `challenge_session.gd` and **nothing DNFs a challenge
run any more** (damage can no longer wreck a car at all). `pause_run()` / `abandon()`
— pause, resumable — are now the only non-completion exits, and the `_dnf` var survives
only to be read back off a persisted run for standings.

That strengthens the case for the alias's retirement rather than weakening it: with no
"only a wreck DNFs" rule left to make unmissable, `abandon()` no longer even hints at a
distinct behaviour — it is a second name for the one exit path, kept purely so old test
teardowns compile.

Migrate these five test files to `pause_run()`, then delete `abandon()`:

- `tests/headless/test_start_line.gd`
- `tests/headless/test_menu_flow.gd` (also has a comment referring to `abandon()`)
- `tests/headless/test_challenge_run_end.gd`
- `tests/headless/test_rally_session.gd`
- `tests/headless/test_upgrade_reveal.gd`

Note `RallySession.abandon()` is a different method (career only) and is unaffected.

Also still wanted from item 12: a **synthetic period-key seam for tests**, so a
challenge period can be forced rather than depending on the real clock.
