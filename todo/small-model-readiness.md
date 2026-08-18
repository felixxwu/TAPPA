# Small-model readiness — carried backlog

Failure causes observed by the `/small-model-readiness` loop but not yet fixed.
Loop-owned file: the loop adds and removes items here without asking, unlike the
other `todo/` specs (see `.claude/skills/small-model-readiness/SKILL.md` §0).

Design: `docs/superpowers/specs/2026-08-18-small-model-readiness-loop-design.md`
(gitignored, like all specs in that folder).

## Open

1. **`features/` updates are still not universal** (round 001, 5/5 probes;
   round 002, improved — 4/5 probes DID update their area doc). Round 002 fixed
   the *indexing* half (`test_features_docs.gd` fails an unindexed doc) but not
   the "remember to touch the doc at all" half. Downgraded, not closed: watch
   round 003 before spending a structural fix.
2. **No point-of-use signal that reward AMOUNTS are `GameConfig` tunables**
   (round 002, T008). The probe hardcoded a bare `1` at
   `rally_session.gd::_resolve_results`; there is no sibling star-amount
   `@export` in `game_config.gd` to pattern-match and no comment at the site.
   Candidate: add the `@export` + a one-line note where stars are awarded.
3. **`features/reward-system.md` disclaims ownership without redirecting**
   (round 002, T008). Both the doc and `reward_system.gd`'s header say they do
   not own *when* a reward fires, and neither says who does. A reader looking for
   "where do I add a star bonus" is left with no destination.
4. **End-of-rally HP is not a damage signal** (round 002, T008). Pit repairs
   restore HP between events, so `hp >= max_hp` at resolve reads a
   crashed-then-repaired car as pristine. Nothing near the damage seam says so.
   Candidate: a note in `features/damage.md` and at the seam.
5. **One fact duplicated across two docs with no pointer** (round 002, T003 —
   NEW cause). The rock-density ranking lives in both `features/regions.md` and
   `features/rocks.md`; correcting one leaves the other stale. Candidate: make
   one canonical and have the other link to it. Worth a sweep for other
   duplicated single-sources-of-truth across `features/`.
6. **Tunable knobs carry no sense of scale** (round 002, T006). A model that
   cannot drive the car has no way to know what change to a value is
   *perceptible*, so it picks a safe-looking bump that does nothing. Candidate:
   a typical-range hint on the feel-critical `@export`s.
7. **Menu nav tests are skipped** (round 001, T002 and T007). Same shape as (1):
   the rule is documented, and unreached.
8. **Settings that persist are not re-applied at boot** (round 001, T007). Every
   existing setting has a module that reads it back (`camera_manager`,
   `fps_setting`, `music_director`); nothing at the point of use says a new one
   must. Candidate: a note where `Save.set_setting` is defined.

## Fixed

- **Which tests cover an area was undiscoverable** (round 002, 4/5 probes; two
  shipped a red test without noticing). Every `features/*.md` area doc now has a
  `**Tests:**` line directly under `**Source:**`, enforced with the indexing rule
  by the new `tests/headless/test_features_docs.gd`.
- **A grip effect could name a field nothing READS** (round 002, T001 — the
  escalation of round 001's fix, which only made the name have to *exist*).
  Guarded by `test_upgrade_library.gd` →
  `test_every_grip_feeding_effect_field_is_read_by_the_physics`, plus a
  point-of-use note on `game_config.gd`'s closed snow/tarmac pair.
- **A region could be added and never be reachable** (round 002, T003) — nothing
  selects a region except a rally's `region` tag. Guarded by
  `test_region_assets.gd` → `test_every_region_is_reachable_from_at_least_one_rally`,
  plus point-of-use notes on `RegionLibrary.REGIONS` and in `features/regions.md`.

- **The skill's §2.2 seeding step was mechanically impossible** (round 001) —
  `isolation: "worktree"` creates the worktree at dispatch, leaving no window to
  seed it. Fixed post-round: the parent now runs `git worktree add` itself,
  seeds (patch + untracked + warm `.godot`), verifies, then dispatches a plain
  agent confined by prompt, and re-checks the main tree after probes finish.
  Round 002 is unblocked.
- **Effect targets could name nothing** (round 001) — `EFFECTS` entries writing
  to an undeclared name applied silently and no test failed. Now guarded by
  `test_upgrade_library.gd` → `test_every_effect_target_name_exists`, plus a
  point-of-use note in the `EFFECTS` header.
- **`features/engine-and-transmission.md` had a wrong value** (round 001) —
  `engine_friction_slope` documented as 4, actually 1.0.
