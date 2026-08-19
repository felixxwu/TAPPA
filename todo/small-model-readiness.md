# Small-model readiness — carried backlog

Failure causes observed by the `/small-model-readiness` loop but not yet fixed.
Loop-owned file: the loop adds and removes items here without asking, unlike the
other `todo/` specs (see `.claude/skills/small-model-readiness/SKILL.md` §0).

Design: `docs/superpowers/specs/2026-08-18-small-model-readiness-loop-design.md`
(gitignored, like all specs in that folder).

## Open

**THE LOOP WAS STOPPED BY THE USER AFTER ROUND 010.** This file is the handoff. Items are
ordered by what the evidence says is most valuable, not by age.

**Round 010 closed:** item 25 (doc slot-count drift — now guarded by
`test_no_feature_doc_states_a_slot_member_count`), and the round-009 `map_pos` template hazard
(pasteable literal restored, both templates synced, both guarded).

**Top recommendations, if this work is picked up again:**

A. **Run a full `./run_tests.sh`.** It is now EIGHT rounds overdue; ~+56 tests have been added
   and never verified together against round 002's baseline (3255 tests / 159,957 asserts /
   335.1 s). Every round since 004 ran in `fast` mode, which cannot detect this repo's
   characteristic failure — order-dependent cross-file leakage. This is the single highest-value
   next action and it needs a human to okay the ~6 minutes.

B. **`stars_gained` is overloaded, and a grader makes a strong case it is the wrong shape**
   (round 010, T008). It means both "what placement paid" (which two tests, the ledger and the
   podium caption treat as an identity) and "total credited". Folding a bonus into it is the
   only thing that WORKS today, but it means the podium can never say "+1 clean run", and every
   future any-finish reward reddens the same two equalities. Proposed: return the bonus under
   its own allowlisted `bonus_stars` key, sum it for `Save.award_stars`, and render it as a
   second caption line. **I did not do this: it changes what the player sees, which is a product
   decision for the user, not a legibility refactor.**

C. **Backlog item 0 (star amounts as consts) is now PARTLY OBSOLETE and worth re-reading.**
   Round 010's probe, given the typed int seam, put its amount in a new `GameConfig` `@export`
   and never reached for `RallyLibrary.STARS_FOR_*`. So the const pattern may no longer be the
   attractor it was in rounds 002-008 — the seam's type appears to have redirected the author
   before the local pattern could. Re-probe before spending a structural round on the migration.
   The migration still needs `fast+full` (25 call sites of `MAX_STARS_PER_RALLY`).

D. **T003 (new region) has never been solved, in five attempts.** It is a four-part change
   (region row + reachability rally + docs + a genuinely distinct look) and probes reliably do
   part 1 and stop. Consider whether the task is simply too large for one small-model attempt,
   or whether the four parts should be collapsed — e.g. a region row that is INERT until tagged
   is arguably the design defect, and a `REGIONS` entry that carries its own starter rally would
   remove the second part entirely.



**Round 009 closed these (removed from the list below):** the free-form result-dict seam
(now a typed `int`), the missing wetness predicate (`WeatherLibrary.is_wet` + classification
guard + `ctx["is_wet"]`), `map_pos` as prose (now `suggest_map_pos()`), and `combusting` as a
name that lies (now `is_lifting_off`).

**NEW from round 009, not yet fixed:**

25. ~~**The tyre-slot authoring checklist sits ABOVE the append point**~~ — the COUNT half is
    FIXED (round 010, `test_no_feature_doc_states_a_slot_member_count`); the checklist-position
    and part-dominance halves remain open. Original text: (round 009, T001). The
    rules — both docs to update, the `unlocked_by_rally` parity question, "not a strictly-weaker
    rung" — are attached to the `snow_tires` row; a new part is appended after `race_tires`,
    below all of it. The probe wrote a part dominated everywhere by `race_tires` and updated
    only one of the two docs. `features/drivetrain-and-tires.md` still said the slot "holds two
    parts". Candidate: a doc guard in the shape of `test_region_docs.gd` (no doc line may state
    a slot's member COUNT), plus moving the checklist to the end of the slot block. Note the
    dominance rule has no data-level or test-level seam at all today.
26. **`unlocked_by_rally` can be claimed in prose and absent in data** (round 009, T009). The
    new part's own comment said it was gated behind a rain-heavy rally; the row had no gate key,
    so it is silently buyable from the start. Nothing checks that a comment claiming a gate
    matches the data.
27. **`features/weather.md` and the `rain_*` doc comments in `game_config.gd` still teach the
    rain-only comparison** (round 009). Prose at lines ~1628-1642 says "on a wet stage
    (weather == RallyLibrary.WEATHER_RAIN)". That prose is what taught three probes the wrong
    condition; it should point at `is_wet`. Cheap, and it is the same file the fix already
    touched.


0. **STRUCTURAL-ROUND CANDIDATE: star reward amounts are `const`s in
   `rally_library.gd`, which teaches every new reward to be one too** (round 005,
   T008 — the sharpened form of item 4). `STARS_FOR_WIN` / `STARS_FOR_PODIUM` /
   `STARS_FOR_FINISH` sit in a commented "star scoring" block that reads as an
   invitation, and the probe put its new bonus there in the same style. As round
   005's grader put it: the GameConfig rule cannot win against a local pattern this
   strong. The correct fix is to migrate the three existing amounts to `@export`s,
   NOT to add a comment. **Deferred deliberately, not cheaply:**
   `MAX_STARS_PER_RALLY := STARS_FOR_WIN` is a const expression with 25 call sites,
   so the migration needs a const-to-runtime conversion across the star rows and a
   FULL suite run to verify — which test mode `fast` cannot give. Do this in a
   structural round, under `fast+full`.

1. **`features/`+test updates are still not universal — REGRESSED round 003**
   (round 002: 4/5 updated docs; round 003: 1/5 updated docs, 0/5 wrote a test).
   Round 003's Fix A puts a `# Docs:` / `# Tests:` breadcrumb in the header of
   every doc-covered script (82 files) — validate in round 004 before closing.
2. ~~`Save.completed_rally_count()` counts TOP-3 finishes but its name says
   "finished"~~ — **FIXED round 006** (renamed; see below). Recurred verbatim in
   round 006 before the fix, which is what finally justified the rename.
3. **Disabled-state treated as terminal** (round 003, T007 — NEW).
   `speed_lines.gd::_ready` early-returns with `_mat` unset when disabled, so
   any later enable is dead. Candidate: a note at the early-return + the
   boot-apply-owner pattern below.
4. **No point-of-use signal that reward AMOUNTS are `GameConfig` tunables**
   (round 002, T008). The probe hardcoded a bare `1` at
   `rally_session.gd::_resolve_results`; there is no sibling star-amount
   `@export` in `game_config.gd` to pattern-match and no comment at the site.
   Candidate: add the `@export` + a one-line note where stars are awarded.
5. **`features/reward-system.md` disclaims ownership without redirecting**
   (round 002, T008). Both the doc and `reward_system.gd`'s header say they do
   not own *when* a reward fires, and neither says who does. A reader looking for
   "where do I add a star bonus" is left with no destination.
6. **End-of-rally HP is not a damage signal** (round 002, T008). Pit repairs
   restore HP between events, so `hp >= max_hp` at resolve reads a
   crashed-then-repaired car as pristine. Nothing near the damage seam says so.
   Candidate: a note in `features/damage.md` and at the seam.
7. **One fact duplicated across two docs with no pointer** (round 002, T003 —
   NEW cause). The rock-density ranking lives in both `features/regions.md` and
   `features/rocks.md`; correcting one leaves the other stale. Candidate: make
   one canonical and have the other link to it. Worth a sweep for other
   duplicated single-sources-of-truth across `features/`.
8. **Tunable knobs carry no sense of scale** (round 002, T006). A model that
   cannot drive the car has no way to know what change to a value is
   *perceptible*, so it picks a safe-looking bump that does nothing. Candidate:
   a typical-range hint on the feel-critical `@export`s.
9. **Menu nav tests are skipped** (round 001, T002 and T007). Same shape as (1):
   the rule is documented, and unreached.
10. **Settings that persist are not re-applied at boot (CONFIRMED round 003, T007)** (round 001, T007). Every
   existing setting has a module that reads it back (`camera_manager`,
   `fps_setting`, `music_director`); nothing at the point of use says a new one
   must. Candidate: a note where `Save.set_setting` is defined.

11. ~~`# Tests:` breadcrumbs are too long on the widest scripts~~ — **FIXED round
   005**, see below. Round 005 supplied the missing evidence that this was not
   cosmetic.

12. **`game_config.gd`'s new header rule is a SWEEP with no ratchet** (round 005,
   durability pass). The header explains that literals are fallbacks and gives the
   grep that tells you whether one is live, but nothing makes a NEW `@export`
   inherit that warning, and nothing detects the specific trap that cost round 005
   its T006 attempt: a property overwritten downstream from an authored table
   (`EngineLibrary.apply`, `CarLibrary`, `UpgradeLibrary`) whose export carries no
   `FALLBACK ONLY` note. Candidate ratchet: a test that cross-references every
   `cfg.<prop> =` assignment in the library `apply` functions against the exports,
   and requires a `FALLBACK ONLY` marker on each one it finds. That is derivable
   rather than enumerable, so it would cover exports that do not exist yet.

13. **"Profile" has no UI referent** (round 006, T005 — NEW). The user's word maps
   only to `Save.profile` (a save-data Dictionary) and `profile_changed` (a data
   signal); the nearest screen is `account_menu.gd`, headed "Account", with no
   stats. An agent greps the request's own noun and lands in the save layer.
   Candidate: add a stats/profile surface, or state in `features/menus.md` that the
   player-facing account surface is `AccountMenu` and that no stats screen exists.
14. **No "finished any position" concept exists in the save schema** (round 006,
   T005 — NEW). `complete_rally` is called only inside the podium gate, so a 4th or
   5th place leaves zero persisted trace. Nothing correct is available to reuse and
   no lookup fails, so the wrong metric is the path of least resistance. Round 006
   documented the absence at the definition; the feature itself is unbuilt.
15. **Docs quote live tunable values inline** (round 006, T006 — NEW).
   `features/engine-and-transmission.md:92` states the slope is **1.0** AND that it
   "is not overridden in `config/game_config.tres`"; a correct one-line change
   falsified all of it. Nothing routes an edit in the `.tres` back to the doc that
   quotes it — the `.tres` carries no breadcrumb of its own. Candidate: describe the
   knob's role and point at the `.tres` for the number, plus a clause on the header
   recipe's "Miss" branch ("...and update the owning feature doc if it quotes it").
16. **Shared-fixture assertions can pass incidentally** (round 006, T002 — NEW).
   `test_pause_menu.gd` builds one `_pause` in `before_all`; the assertion pinning
   "open() focuses Resume" now holds only because no earlier test moves focus, and
   the file header still claims order-safety. Candidate: establish the precondition
   inside the assertion, and treat "header comment asserts a cross-test invariant
   with no mechanism behind it" as a pattern to sweep for.

17. **No `WeatherLibrary.is_wet()` predicate** (round 007, T009 — NEW, and it has now
   caused the same bug twice). Nothing correct exists for a weather-keyed tyre channel
   to call, so `"rain"` gets hardcoded and `"storm"` — authored on ~14 events and
   wetter than rain — silently gets nothing. Candidate: add the predicate to
   `WeatherLibrary`, point the tyre channel arm and `features/weather.md` at it.
18. **The region reachability guard's message prescribes the damaging shortcut**
   (round 007, T003 — NEW). It says `give a rally "region": "<id>"`, and tag-set
   membership cannot distinguish authoring a home from stealing one. A probe retagged
   an existing mid-map fog/night rally into an arid canyon and the suite went green.
   Round 007 added the "prefer adding a rally" note at the table; the GUARD still
   needs to detect a retag (e.g. assert no rally's region tag changed, or that a
   region's rallies cluster in `map_pos`).
19. **Weather-placement conventions are prose-only and one-directional** (round 007,
   T003 — NEW). Sandstorm-only-on-greece is test-enforced; fog and night are not, so
   retagging a fog rally into an arid region is invisible to the suite.
20. **`main.tscn` HUD label offsets assume all debug labels share a hidden overlay**
   (round 007, T004 — NEW, cosmetic). Promoting an element out of the overlay implies
   a repositioning decision nothing signals; gear now sits at y=28 with an empty row
   above it and overlaps RPM when H is pressed.

21. **`stars_gained` is the only star channel the podium reads** (round 008, T008 —
   NEW). A probe added a correct clean-run bonus under an invented `stars_bonus` result
   key that nothing consumes, so the ledger gains a star the results screen never
   mentions. Candidate: fold bonus income into `stars_gained` (restoring the "the result
   tells you everything the finish credited" invariant that an unrelated car test
   enforces incidentally), or teach `podium.gd::_show_stars` to sum both. State the
   invariant where a reward author will meet it.
22. **`# Docs:` breadcrumbs name the most recent feature, not the file's subject**
   (round 008, T007 — NEW, cross-cutting and cheap). `settings_menu.gd` points at
   `features/benchmark.md`; a probe that OBEYS the breadcrumb is steered away from
   `features/menus.md`. Audit the highest-traffic scripts so the primary doc leads.
23. **No exemplar for a boolean settings row** (round 008, T007 — NEW). Every Display
   row is an N-way `_build_option_page` selector; the only two-state toggles live on the
   benchmark page keyed off a dict, so a probe hand-rolls one.
24. **The audio seam is built but unmeasured** (round 008 — NEW). `scripts/audio.gd`
   landed this round in response to the worst-scoring probe in eight rounds; no probe
   has seen it. Re-probe T010 before assuming it works.

## Fixed

- **The HUD docs had no machine gate while the region docs did** (round 008) — new
  `tests/headless/test_hud_docs.gd` fails when a doc calls a label always-visible while
  it is still H-gated, or transcribes the membership list. Modelled on the one
  intervention with clean before/after evidence in this loop.
- **Per-element HUD membership tests pinned a product choice** (round 008) — deleted;
  the membership-driven tests already cover the real contract, and their removal makes
  the constant's "one-line edit" promise true.
- **There was no SFX facility, so every SFX task was a build-the-facility task**
  (round 008, T010 — the worst-scoring probe in eight rounds) — new `Audio` autoload
  encapsulating the headless guard, the play/get_playback order, `push_buffer`, and a
  build-once player; tunables authored; the hook comment rewritten as a directive; the
  headless-audio SIGSEGV rule promoted out of its single comment into two feature docs.
- **Region reachability had no cheap CORRECT path** (round 008, T003) — a
  copy-pasteable minimal `RALLIES` row at the point of use, the reachability guard's
  failure message now emits that row with the id substituted instead of prescribing the
  damaging retag, and `look_from` reframed as the variant-region idiom.
- **Obligations lived at the top of files agents never scroll back to** (rounds
  003-007, the mechanism behind the dominant cause — identified independently by two
  round-007 graders). These agents navigate by symbol search and land mid-file, so a
  line-3 breadcrumb is never ARRIVED at, let alone ignored. Round 007 put the
  obligation AT the edit site for the three highest-traffic authored blocks
  (`DEBUG_READOUT_NODES`, `RegionLibrary.REGIONS`, the `UPGRADES` tyre block), each
  naming the docs by path, and stopped `features/hud.md` transcribing a list the code
  owns. Ratchet: new `tests/headless/test_region_docs.gd` fails when a region exists
  that `features/regions.md` never mentions, or when a count the doc states is wrong.
- **The speed-blur setting had no apply-owner and its disabled state was terminal**
  (rounds 003 and 007, identical failures) — new `scripts/speed_lines_setting.gd`
  following the `fps_setting.gd` exemplar, `speed_lines.gd::_ready` split into
  unconditional wiring plus an idempotent `set_effect_enabled(on)`, and the
  `Config.data`-drift bug designed out with a test enforcing it. The pattern is now
  named in `features/menus.md`'s Settings section — at the point of use, not the top.
- **The clean-run damage signal was computed and thrown away, and the reward block had
  no seam** (rounds 005-007) — `_took_damage_this_rally` is latched where damage
  happens and exposed at resolve time, so round 005's comment now points at something
  that exists; `_resolve_results` splits into `_award_podium_rewards` and
  `_award_any_finish_rewards` so an any-finish reward has a named home. Behaviour
  unchanged. Also defused the `_start` test helper that positionally shadowed
  `start_rally` and broke a whole test file for one probe: now
  `_grant_and_start(rally_id: String, model_id: String)`, 43 call sites updated.
- **The tyre registry hardcoded its context inputs, so a non-surface axis forced a
  signature change through every consumer** (round 006, T009 — a defect round 004
  introduced and round 004's own docs advertised as the easy case). The resolver now
  takes a stage-context Dictionary built by `GameConfig.fill_tire_context`, filled in
  place so the hot path still allocates nothing, and carrying weather ahead of any
  axis needing it. `_channel_weight` returns NAN for an unregistered channel so the
  guard can distinguish "no rule" from "not on that channel"; the guard no longer
  probes for inertness and can no longer fail a correct axis. The doc now states what
  "three edits" is conditional on.
- **The HUD debug-readout membership was straight-line code at two sites, and its
  test bundled five contracts into one body** (round 006, T004 — the escalation after
  two rounds of breadcrumb prose failed). `hud.gd` now has one `DEBUG_READOUT_NODES`
  list driving both sites, and the tests bind to it, with per-element contracts named
  after their element so a gear change fails a test that says "gear".
- **`Save.completed_rally_count()` lied about its metric** (rounds 003 and 006, same
  failure twice on an unchanged name) — renamed to `podium_rally_count()` /
  `RallyLibrary.podium_count()`, deprecated wrappers left at the old names, all call
  sites and three feature docs updated. The definition now says what is NOT counted
  and that no finish counter exists to reuse.
- **New scripts inherited no breadcrumb at all** (round 005 durability pass, §2.6a)
  — `test_script_breadcrumbs.gd` now requires a `# Docs:` header on every script not
  in the frozen 97-entry `BREADCRUMB_BASELINE`, and forces entries out of that list
  once they comply, so it can only shrink. Verified by watching it go red against a
  throwaway breadcrumb-less script and green again after deletion.
- **`# Tests:` breadcrumbs were haystacks, and the Tests half of the convention was
  being skipped because of it** (round 005, T004 + T002 — the mechanism behind the
  dominant cause of rounds 001–005). 41 scripts rewritten: at most 3 primary test
  files named, followed by the `grep` that derives the rest. Enforced by the new
  `tests/headless/test_script_breadcrumbs.gd` (named docs and tests must exist; the
  test list must stay within the cap), and the convention is stated in
  `features/README.md` along with "before you change behaviour, find the assertion
  that pins it".
- **A local's name hid a podium gate that silently captured any reward dropped near
  it** (round 005, T008) — `rally_session.gd`'s `record_completion` is now
  `podium_or_opening`, with a note at the declaration saying where an any-finish
  reward belongs instead.
- **One boolean did two unrelated jobs at the damage seam** (round 005, T008) —
  `damaged` is now `took_damage and can_persist`, so "did the player take damage"
  no longer silently means "and we had somewhere to save it".
- **`game_config.gd`'s literals read as the tuning surface, and `.tres` sparse
  authoring made it impossible to tell from the script whether an edit was live**
  (round 005, T006) — file header now states the rule and gives the one-line grep
  that answers it, and the buried "FALLBACK ONLY, EngineLibrary overwrites this"
  warning on `engine_friction_base` is hoisted off the end of a 200-character line
  onto its own block, with a feel-magnitude anchor added to `engine_friction_slope`.

- **The surface-tyre model forced a 6-site edit across 5 files, and step 1 was a
  silent no-op** (rounds 001/002/003, the three-round escalation trigger) —
  round 004's structural fix. `GameConfig.TIRE_SURFACE_AXES` is now the registry
  every consumer derives from (`tire_surface_mult_for`, `car.gd`'s re-seed,
  `car_performance.merged_meta`'s carry list); adding an axis is three adjacent
  edits in one file. Guarded both ways by `test_tire_surface_axes.gd`, plus
  `push_error` on an unregistered field or a channel with no blend rule. This
  retires the 24-line checklist comment that rounds 001–003 kept extending.
- **Point-of-use checklists stopped at production code** (round 003, T001) — the
  closed-pair note now also names test_drivetrain.gd's direct callers and
  instructs updating the note itself when the pair widens. SUPERSEDED by round
  004: the checklist it fixed no longer exists, because the sites were collapsed.
- **Region asset paths could dangle silently** (round 003, T003) — new guard
  `test_region_assets.gd` → `test_every_authored_region_resource_path_resolves`
  walks every res:// string in REGIONS; "never invent a filename" notes at the
  table and in features/regions.md.
- **Docs/tests convention unreachable from the script being edited** (rounds
  001–003, dominant) — 82 scripts now carry `# Docs:` / `# Tests:` header
  breadcrumbs (Fix A, round 003); convention stated in features/README.md.


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
