# Small-model readiness — carried backlog

Failure causes observed by the `/small-model-readiness` loop but not yet fixed.
Loop-owned file: the loop adds and removes items here without asking, unlike the
other `todo/` specs (see `.claude/skills/small-model-readiness/SKILL.md` §0).

Design: `docs/superpowers/specs/2026-08-18-small-model-readiness-loop-design.md`
(gitignored, like all specs in that folder).

## Open

> **THE ROGUELIKE PIVOT INVALIDATED PART OF THIS BACKLOG (stage 9, decision 41).** Six of the
> fifteen task-bank entries targeted systems the pivot deleted — the star economy, the parts
> catalogue, the career rally, the overworld map, the podium — and have been re-authored against the
> systems that replaced them (`evals/small-model/tasks.md` says which, per entry); T003 was reshaped
> and every affected `clean_solves` counter reset.
>
> **The FINDINGS below are a different matter and mostly survive**, because they are about how the
> repo reads rather than what it contains: a fact stated in prose but absent from data, a registry
> whose three sites give no feedback when one is skipped, a doc whose insertion point costs more to
> find than the change. Read each one and ask whether its SHAPE still exists; several now point at
> `BoostLibrary`/`PerkLibrary`/`LifetimeStats` instead of the tables they were written against.
> Items naming `RewardSystem`, `RallySession`, `hq.gd`, the star ledger or `UpgradeLibrary`'s
> catalogue are **historical** — the loop has not re-measured this codebase since the pivot, and
> **round 044 is the last round whose numbers mean anything about the current tree.**

**THE LOOP WAS RESTARTED AT ROUND 011, in DRILL mode** (`/small-model-readiness-drill`, its
first ever execution). Round 010's handoff below still stands except where round 011 changed it.
Items are ordered by what the evidence says is most valuable, not by age.

**Round 011 (drill, T002) closed:**
- The **rubric leak in the base skill's §2.2**. The exclusion only ever filtered *untracked*
  files; once `evals/small-model/` became tracked, `git worktree add ... HEAD` restored the whole
  task bank — including every hidden rubric — into the probe worktree. Caught before dispatch.
  Fixed in both skills (by the authoring peer session) as an unconditional post-creation scrub.
- **A frozen assertion that made T002 unwinnable for three rounds.**
  `test_pause_menu_is_keyboard_navigable` pinned a product choice a live bank task exists to
  change. Renegotiated; proven green both with and without the sanctioned change. Added to the
  §2.5 cause taxonomy as "a frozen assertion blocking a sanctioned change".
- **`remember` is now a `MenuNav` capability** (~50 call sites), with `MenuNav.of()` and
  `forget()`, a filesystem-derived one-owner-for-opening-focus ratchet, and the framework's
  `# Docs:` breadcrumb repointed from `features/world-panel.md` (which does not document it) to
  `features/menus.md`.

**Round 011 opened — and this is now the top structural item:**

0. ~~**`features/menus.md` is ~2,500 lines...**~~ **DONE — round 012 (structural).** Split into
   `menu-navigation.md`, `settings.md`, `modals.md` and `hq.md`; `menus.md` is now 492 lines.
   Acceptance test 7/10 nouns (was ~3) — measured in `rounds/012.md`, **not** a pass. Two
   residual misses (`pause`, `keyboard`) both trace to `features/overworld.md` at 1,817 lines,
   which is **the next structural target** and is already frozen on the new doc-size baseline.
   Also fixed on the way: `settings_menu.gd`'s breadcrumb pointed at `features/benchmark.md`.

0a. **THE TAIL IS NOT MEASURABLE BY THIS LOOP — round 013's negative result, and the most
   important thing on this list.** Two rounds and five probes eliminated both available
   hypotheses for why probes ship code without docs or tests:
   - *the doc is too hard to find* — refuted by round 012 (split `menus.md` 2,539 -> 492; probe
     still edited nothing);
   - *the doc is never opened* — refuted by round 013 attempt 2, which **opened
     `features/menu-navigation.md`, cited it by line range, and still did not edit it**.

   What remains is round 008's conclusion: the probe's model of "done" is "the code works", and
   the only intervention that changes that is a check it **cannot self-certify past** — a failing
   test. Probes are forbidden to run tests, by construction, in every round. So on tasks whose
   only gap is the tail, the convention axis measures the HARNESS, not the codebase.

   **Consequences:** (a) stop sampling tail-only tasks (T002, T004, T009 are all 3/3/x/x with
   convention the sole blocker) — sample navigation/correctness gaps, where the loop still has
   signal; (b) §2.4's convention axis and §5's stop condition assume convention is a codebase
   property, which on these tasks it is not — a SKILL change, deliberately left to the user or the
   skill author rather than made unilaterally.

0b. ~~**Re-probe T002 out of "Too hard" in round 013.**~~ **DONE — see 0a.** Result: 3/3/0/2 twice.
   Navigation and correctness solid, convention unmoved. Original text:
   **Re-probe T002 out of "Too hard" in round 013.** It was discarded for doc-location cost,
   which is exactly what round 012 attacked. A clean solve is the strongest evidence the fix
   worked; a convention failure means the cause was never doc location.

**Old text of item 0, for context:**
   **`features/menus.md` was ~2,500 lines covering every menu in the game, and that was the
   blocker.** Three probes in a row solved T002's code (one of them in a single line) and all
   three updated no doc at all — while one of them wrote a test unprompted, so this is not
   doc-writing reluctance, it is **doc-location cost**: finding the insertion point is more
   expensive than the change. T002 was discarded `too_hard` on this. **The next round is declared
   STRUCTURAL against this file.** Acceptance test, fixed in advance: a probe must reach the right
   section by grepping the request's own nouns ("pause", "settings", "gear", "blur") without
   reading an index first. Splitting it into parts that still need each other's context is the
   `hq.gd` mistake in doc form and does not count.

**Also learned in round 011, worth acting on:** §2.6a ranks "a copyable sibling" third among
durability mechanisms, above a point-of-use note. Round 011 is counter-evidence. Attempt 3's probe
wrote a test whose precondition line failed — reproducing a bug that the **adjacent test,
seventeen lines above, fixes and explains by name in a twelve-line comment**. A prose-annotated
sibling did not propagate. Treat "copyable sibling" as durable only when copying it is genuinely
the cheapest route to the goal.

**Round 010 closed:** item 25 (doc slot-count drift — now guarded by
`test_no_feature_doc_states_a_slot_member_count`), and the round-009 `map_pos` template hazard
(pasteable literal restored, both templates synced, both guarded).

**ROUND 014 WAS THE LAST ROUND — the user stopped the loop here.** The skill's own stop
condition did NOT fire; nine tasks are live and T005 scored 3/2/2/3, not clean.

**Round 014 closed:** the undeclared-persisted-key defect. A probe added a `rallies_finished`
counter without declaring it in `_default_profile()`, so `_migrate`'s key backfill never seeded
it — silent, and every test passed. Now guarded by
`test_every_persisted_key_written_is_declared_in_the_default_profile`, source-derived, validated
red against the probe's tree and green on main.

**Round 014's finding, which supersedes round 013's negative result and is the most useful thing
the loop has produced about docs:**

> **A probe updates a doc when its change makes a statement in that doc FALSE. It does not update
> a doc merely because its change is relevant to that doc.**

This fits every observation: round 010's T009/T006 probes changed systems their docs described;
round 014's probe falsified one sentence and rewrote exactly that sentence; round 013's probe
*used* a documented capability, invalidated nothing, and edited nothing even though it had opened
the doc and cited it by line range. **It inverts the usual advice:** docs written as capability
descriptions ("you can pass `remember = true`") will not be maintained by these agents; docs
written as **falsifiable statements about the current system** ("there is no such counter") will.
Round 003 wrote that sentence as a warning; it worked as a tripwire eleven rounds later.

**FIRST THING TO DO IF THE LOOP RESUMES:** re-probe T005. Round 014's ratchet is **unmeasured** —
the round ended after one attempt at the user's request. Round 013 predicts a test-based guard is
invisible to a probe that cannot run tests, which would make it a repo-protecting fix rather than
a probe-facing one. Worth knowing either way.

**Top recommendations, if this work is picked up again:**

A. **Run a full `./run_tests.sh`.** It is now NINE rounds overdue (round 011 also ran `fast`); ~+56 tests have been added
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
   T005 — NEW). `record_podium_rally` is called only inside the podium gate, so a 4th or
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

## Round 015 (drill mode, T005 — save/progress)

- **`Save.rally_completed()` was a lying name** — it returned the podium-gated `completed` flag,
  i.e. "podiumed", not "finished". Round 003 fixed the *count*
  (`completed_rally_count()` -> `podium_rally_count()`) and left the per-rally predicate lying, and
  `features/save-persistence.md` had settled into *documenting* the lie. **Renamed to
  `Save.rally_podiumed()` across all 16 sites with no compat wrapper** (deleting the obligation
  rather than describing it). A probe had just mislabelled a podium count as "Rallies finished: N"
  on the profile screen, with a fully green suite.
- **The podium gate is on the WRITE, not on any one field.** `Save.record_podium_rally` has exactly one
  caller (`rally_session.gd`, inside `_award_podium_rewards`, gated on `podium_or_opening`), so a
  5th-place finish writes NOTHING into a rally's record — every field of it (`completed`,
  `best_placed`, `best_combined_ms`) is equally gated. Round 003's note explained the gate as a
  fact about `completed` alone, so `best_placed` read as an untainted sibling and a probe escaped
  through it. All three read paths now say **"there is no untainted sibling field to escape
  through."** Guarded by
  `test_save_manager.gd` -> `test_no_finish_named_symbol_derives_from_the_podium_gated_rally_record`.
- **Undeclared persisted keys now announce themselves at RUNTIME** — round 014 shipped only the CI
  test, and a second probe made the same mistake because it could not run the suite. `save()` now
  `push_error`s any top-level key code wrote without declaring it in `_default_profile()`.
  "Known" is declared-keys UNION keys-as-loaded, because load backfills missing keys but **never
  prunes retired ones**, so the naive check would false-alarm on real players' saves.
- **"Progress" was ambiguous across two unrelated systems.** `features/progress.md` documents
  `TrackProgress` (distance along one stage), NOT career progress — a small model grepping the
  request's own noun landed there. Both the doc and its `features/README.md` row now say so and
  point career readers at `save-persistence.md` / `star-economy.md`. **This ambiguity had already
  corrupted the eval**: round 014 marked a probe down for not updating `progress.md`, which was
  never the right file.
- **Two copies of one stale fact corrected**: both `features/save-persistence.md` and the
  `stars_earned` comment in `_default_profile()` claimed `record_podium_rally` credits only the
  IMPROVEMENT over a rally's previous best. That anti-grind rule was deliberately removed; every
  finish pays.
- **Open lever worth testing (n=1, round 015):** for a convention, **position may beat mechanism**.
  A rule stated near the top of the file every reader passes appeared to outperform the same rule
  at a specific function 1,600 lines down, a CI test, and a runtime error. Needs a controlled
  re-test before being believed.

## Round 016 (drill mode — T005 settlement + T008)

- **`Save.complete_rally()` was the WRITE-side lying name** — round 015 renamed the read-side
  predicate (`rally_completed` -> `rally_podiumed`) and left the writer. A probe wanting to record a
  *finish* reached for `complete_rally`, incremented a new `rallies_finished` key inside it, and
  shipped the **podium count** under the label "Rallies Finished:" — with 107 tests green.
  **Renamed to `record_podium_rally()` across all 80 sites** (57 code, 20 docs, 3 todo), no compat
  wrapper. Guarded by `test_save_manager.gd` ->
  `test_the_podium_gated_recorder_writes_no_finish_named_profile_key`.
- **T008 was unwinnable-clean for SIX rounds because of a frozen assertion.**
  `test_a_rewin_pays_stars_again_but_never_another_car` and
  `test_the_opening_rally_completes_on_a_losing_finish` asserted
  `stars_gained == stars_for_placement(...)` on fixtures that finish UNDAMAGED, so any clean-run
  bonus reddened them. Round 010 diagnosed it and wrote a 22-line note telling a future implementer
  to fix the tests — which probes, barred from running tests, can never discover. Both relaxed to
  `assert_gte` (every other assertion intact) and the note deleted. **Verified: the very next probe
  shipped a working bonus with `ALL TESTS PASSED`.** Same shape as T002's three wasted rounds; §2.5
  makes this the parent's job to look for, and it is worth doing on any task that keeps failing.
- **The position lever, now 3 predictions for 3 (correlational, not yet A/B'd):** a convention
  stated **at the site of the edit** gets obeyed; the same convention stated where the related
  concept is *defined* does not. Declaration rule at the top of `save_manager.gd` -> obeyed twice.
  Amount rule inside the seam function -> obeyed. Gate rules on read paths a writer never opens ->
  ignored twice. **When planting a convention, ask "what file will the author actually have open?"**
- **Round 014's doc lever is real but gated by crispness.** A probe rewrote a `features/` **table
  cell** its change falsified ("nothing yet — returns `0`"), unprompted; round 015's probes ignored
  falsified **prose buried in long paragraphs**. Write the falsifiable statement short, local, and
  structured.

## Round 017 (drill mode — T005 settlement + the T001 position A/B)

- **A local must never shadow a method of its own class.** `rally_session.gd` had
  `func rally_id() -> String` **and** locals named `rally_id` in two of its methods. A probe copied
  the neighbours' bare identifier into a third function, the name bound to the method, and the
  argument became a `Callable` — **the whole project failed to compile** and every autoload died.
  All four collisions in `scripts/` renamed (locals, never methods); guarded by
  `test_script_breadcrumbs.gd` -> `test_no_local_variable_shadows_a_method_of_the_same_class`, with
  **no exemptions**. First fix this loop has made about a GDScript hazard rather than a domain
  convention — and a reminder that whole classes of defect had gone unlooked-at for sixteen rounds.
- **THE POSITION LEVER IS REFUTED in its general form.** A controlled A/B on T001 — the identical
  7-line checklist, byte-for-byte, one entry above the insertion point vs. AT it, nothing else
  changed — scored **0/3 on both arms** against a metric registered before either ran. The
  treatment probe demonstrably READ the relocated note (it obeyed the note's ungated-justification
  clause almost verbatim) and still updated neither doc it names.
  **The surviving statement, which is what to use:** *position determines whether a note is READ; it
  does not make an agent leave the file it is working in.* In-file obligations (use this shape,
  justify that choice) are movable by putting them at the edit site. Out-of-file obligations (update
  two docs, add a test) are not.
- **Out-of-file obligations are now SETTLED harness-limited — stop attacking them with prose.** Four
  independent interventions have failed on that one axis: splitting the doc (012), making it
  necessary to read (013), falsifiable statements (015), position (017). The answer is to convert the
  obligation into an executable check, as round 017 did for the tyre doc
  (`test_every_tyre_slot_part_is_documented_in_the_tyre_doc`).
- **Measure a guard's baseline BEFORE shipping it.** The broad version of that doc guard — every
  `UPGRADES` id must appear in `features/upgrade-catalogue.md` — looked obviously right and was
  wrong: 9/10 pass and the failure (`aero_kit`) is a false positive, because that doc covers the part
  as "Aero Kit" and never writes the id. Narrow and true beats broad and noisy.

## Round 018 (drill mode — T003, regions/terrain)

- **T003, the bank's hardest and never-solved task, came in at 3/2/3/3** (previous best 3/1/1/2). A
  Haiku probe authored a `badlands` region with its own sky panorama (the one unused sky asset in the
  repo), a genuinely new rally to make it reachable, and a thorough `features/regions.md` update —
  all three mandatory sites, unaided, with every guard that reddened in rounds 009/010 passing.
  Round 010's "four parts is simply too much for one Haiku attempt" is **refuted**.
- **Round 017's "out-of-file obligations are settled harness-limited" is WRONG and is hereby walked
  back.** This probe left its file twice with no prompting beyond a comment in a third file. The
  distinguishing variable looks like **form**:
  - **works** (T003): a numbered procedure — "ADDING A ROW HERE IS A FOUR-PART CHANGE", parts 1–4,
    the half-done failure named up front, guards named by test name, and a **complete paste-and-edit
    template with `# EDIT` markers** carrying the payload.
  - **fails** (T001, both arms of round 017's A/B): the same information as a **clause in a prose
    paragraph** — "Docs: features/upgrade-catalogue.md AND features/drivetrain-and-tires.md".
  **So: when you need an agent to leave the file it is in, write an enumerated procedure that carries
  its own payload, not a sentence naming the files.** n=1 each way — a hypothesis, with the T001 note
  now rebuilt in T003's shape and a prediction recorded for the next round.
- **Standing lesson for this loop, learned twice in two rounds:** do not declare something "settled"
  from a single task, however many interventions that one task absorbed. Round 017 generalised from
  T001 alone and was wrong within one round; round 016's position lever generalised from three
  correlational points and was refuted by one controlled pair.
- **A rubric ambiguity can masquerade as a codebase defect.** T003 asks for a region with "its own
  skybox and scatter set", while `region_library.gd`'s own idiom instructs authors to inherit a look
  via `look_from` and override only what differs. Grading a probe down for following the repo's
  documented convention measures the rubric, not the repo — flagged for the user rather than decided
  unilaterally, because it determines whether the task is now solved.
- **Dropping a designed fix when its premise is refuted is part of the job.** A structural change to
  make regions authorable from one file was designed before the probe and discarded after it, because
  the site-count hypothesis it rested on was disproved. Keeping it would have made the next
  measurement uninterpretable.

## Round 019 (drill mode — T001, the note-form experiment)

- **CONFIRMED: note FORM is what moves out-of-file work. Doc compliance went 0/2 -> 2/2.** Round 017's
  controlled A/B failed twice with the obligation written as a prose clause ("Docs: X AND Y"). Round
  018 rebuilt it as a **numbered procedure** — parts 1-3, the half-done failure named up front, the
  guard named by test name, the payload inline — and the next probe updated **both** docs thoroughly,
  including the enumerated sentence a guard checks. With round 018's T003 result that is **two
  independent tasks agreeing**.
  **Rule: when you need an agent to leave the file it is in, write a numbered procedure that carries
  its own payload — not a sentence naming the files.** Round 017's "out-of-file obligations are settled
  harness-limited" is fully retired.
- **A note that specifies the MECHANISM is satisfiable without achieving the INVARIANT.** The note said
  "author surface terms, not a bare multiplier". The probe authored three surface terms — and the part
  was still **strictly dominated by `race_tires` on every surface** (gravel 1.12 vs race's 1.15 flat;
  snow 1.008; tarmac 0.896), so nobody would ever fit it. Round 009 had recorded the identical defect.
  **State the property the change must satisfy and the check that proves it, not the code shape that
  usually satisfies it.** Part 1 now states the invariant ("must beat every sibling on at least one
  surface"), says "CHECK IT, do not assume it", and works the arithmetic through.
- **Sometimes the executable check is forbidden, and the project's rules win.** A guard test for that
  invariant would assert an ordering relationship across authored catalogue entries, which `CLAUDE.md`
  explicitly bans (a designer retuning a value would redden it). So §2.6's "prefer an executable check
  over a note" yields here — worth knowing before reaching for a guard in any balance-adjacent area.
- **A fix can invalidate a pre-registered metric.** Round 017 registered "a test added or updated" as
  one of three items; round 018's own note change then said no new test is needed, making that item
  unattainable by design. Reporting "2/3" would have flattered the comparison — the honest figure is
  the two doc items, 0/2 -> 2/2. **When a fix edits what a metric measures, re-register the metric.**

## Round 020 (drill mode — T001, measuring the invariant fix)

- **"State the property and the check, not the code shape" is CONFIRMED.** The probe read round 019's
  invariant and **reproduced its arithmetic in its own code comment** ("Flat term 1.20 beats race_tires'
  1.15 on gravel… 1.20 * 0.88 = 1.056 on snow"), using it to pick numbers that win on gravel (1.200) and
  tarmac (1.176). Docs held at 2/2. Compare round 019, where the note named the mechanism ("author
  surface terms") and the probe complied while still shipping a dead part.
- **But a one-directional invariant produces a mirrored defect.** "Your part must win somewhere" was
  satisfied — and `race_tires` was left winning **nothing** (1.150 against gravel's 1.200/1.176 and
  snow's 1.296). The slot still had a dead part; it had just moved. Now stated symmetrically: (a) your
  part must win somewhere, **(b) it must not take the last surface from a sibling**, so the test is
  "EVERY row in this slot wins somewhere".
- **Standing lesson — my own recurring error, three rounds in a row.** Each fix was obeyed precisely and
  was incomplete in the same way: the requirement was stated too narrowly. Form fix -> docs updated but
  mechanism wrong; mechanism->invariant fix -> invariant met but symmetry unstated. **When writing a
  property into a note, ask what a compliant answer could still get wrong — and check whether the
  property is symmetric before writing it one-directionally.**
- **Watch for "fix landed, unmeasured, next round measures it" becoming a habit.** Three consecutive
  rounds ended that way. Each was defensible alone; together it means every fix runs one round behind
  its evidence, and one task can absorb the whole loop. Round 021 measures the symmetric invariant and
  then leaves T001 alone regardless of outcome.

## Round 021 (drill mode — T001 clean solve + T006)

- **THE LOOP'S FIRST CLEAN SOLVE, 21 rounds in.** T001 scored **3/3/3/3**: the probe authored a NEW tyre
  surface axis with all three round-004 registry edits (`@export`, `TIRE_SURFACE_AXES` row,
  `_channel_weight` arm), added the row, and made six substantive edits across both docs. Effective grip
  gave a clean three-way split — gravel wins gravel, snow wins snow, race wins tarmac — so **every row
  wins somewhere**, and it reproduced that win-table in its own code comment.
  **The chain that got there took four rounds of narrowing ONE cause:** form (prose -> numbered
  procedure, 018) -> mechanism -> invariant (019) -> invariant stated **symmetrically** (020) -> solved
  (021). Worth remembering as the shape of a fix that actually lands: each round's fix was obeyed
  precisely and revealed the next unstated requirement.
- **`Engine.is_lifting_off()` is TRUE while BRAKING — and its own docstring said "coasting".** A probe
  reasoned correctly about fuel cut, mid-shift, declutch, rev-limiter bounce and turbo drag, then gated a
  1.5x friction multiplier on `is_lifting_off` and reddened
  `test_drivetrain -> test_brake_lockup` (main 33/33, its tree 32/33). Braking is off-throttle, so the
  multiplier applied to every brake application. The comment now says braking is included, names the
  consequence and names the guard test. **There is no `is_coasting()` seam** — making one means plumbing
  the brake input into `engine.gd`, which is the mandatory structural fix **if this cause recurs**.
- **The loop's oldest open question is finally under test: can a note make a probe write a TEST?** Round
  008 said no ("only a stopping condition it cannot self-certify past"), and every intervention since has
  aimed at docs. The engine-braking knob site now carries a numbered procedure whose part 3 is a
  **paste-able behavioural-test skeleton** — closure, two `# EDIT` lines, `assert_gt` on the direction
  (never the value, which CLAUDE.md bans), `Config.reset()`, and the exact run command. Prediction on
  record; round 022 measures it.

## Round 022 (drill mode — T006; the test-obligation question, settled)

- **SETTLED: a note cannot make a probe write a test. The obligation TYPE is the variable, not the note.**
  The intervention was the strongest available: the **exact numbered-procedure form independently
  confirmed to move docs** (rounds 018/019/021), placed **at the edit site the probe demonstrably read**
  (it quoted part 1's pointer back), carrying the **entire payload** (a paste-able skeleton, two `# EDIT`
  lines, the assertion written, `Config.reset()`, the run command), with the obvious excuse pre-empted
  ("asserting the direction is legal; 'no test is possible here' is wrong"). **No test was written.**
  Round 008's mechanism survives: a probe's model of "done" is "the code works", and a test is a separate
  verification activity it is barred from running. **Do not spend another round on a note-shaped attempt
  at the test obligation.**
- **A warning that names the CONSEQUENCE buys a better design, not just avoidance.** Round 021's probe
  gated a 1.5x friction multiplier on `is_lifting_off` and reddened `test_brake_lockup`. After the
  docstring was corrected to say braking is included, name the lock-up consequence and name the guard
  test, the next probe **quoted it back** and scoped its change to a `friction_effective` local used only
  for `crank` — green at **2.0x**, twice the gain. Same feature, same predicate; the difference was blast
  radius, and the note bought that.
- **Where the bank stands: 7 of 9 live tasks now sit at navigation 3 / correctness 3 with convention as
  the sole or near-sole blocker** — and the largest part of that tail (tests) is now known to be
  unmovable by this loop's only instrument. The measurable signal is thinning. T004, T009 and T010 have
  not been probed since round 010, and round 017 is the precedent for why that still matters (T005 looked
  convention-bound for rounds, then a probe surfaced a compile-breaking GDScript hazard). Sweep those
  three, settle T003's rubric, then stopping is reasonable.

## Round 023 (drill mode — T004, second clean solve)

- **SECOND CLEAN SOLVE: T004 scored 3/3/3/3**, sixteen rounds after it was last measured (round 007, best
  3/3/1/2). One-line `DEBUG_READOUT_NODES` membership edit, `features/hud.md` given a Visibility column,
  **and `features/debug-tools.md` updated unprompted** — the probe found three statements its change had
  falsified in a doc the rubric does not even list. **No fix was needed from me**; the round's value was
  in measuring a stale task.
- **Round 022's "probes will not write tests" now has a CONSTRUCTIVE answer**, assembled across rounds
  006/007/008/023: a probe will not **author** a new test; it will sometimes **reconcile** an existing one
  whose name identifies the contract; and the durable move is to **owe no test at all**.
  - Round 006 made membership a single source of truth (`DEBUG_READOUT_NODES`) — the code half became one
    line.
  - Round 008 then **deleted** the per-element named tests, because they pinned a product choice AND
    falsified the constant's own "one-line edit" promise ("two separate eval probes duly did the first and
    skipped the second"). Coverage moved to two **membership-driven** tests that iterate the constant.
  - Round 023's probe therefore owed **no test edit**, and the tests adapted themselves.
  **Pattern to reuse: single-source-of-truth constant + tests that iterate it + a separate machine guard
  for the docs.** That combination is what makes a task cleanly solvable by a small model.
- **Verify the things a green suite cannot see.** Two plausible defects here would not have reddened
  anything: whether the label still updates (it does — the write is unconditional and the reference is
  `@onready`, neither gated on the array), and whether it ends up visually stranded (it does not — the
  labels are absolutely positioned, so gear alone sits top-left). Checking both was the difference between
  a justified 3 and a guessed one.

## Round 024 (drill mode — T009, wet tyre)

- **T009 regressed to 3/1/2/3 on a NEW cause: an invented `unlocked_by_rally` id
  (`"h_coast_qualifier"`) that makes the part permanently unwinnable.** Everything rounds 006/007/009
  fixed is settled — all three `TIRE_SURFACE_AXES` registry edits, no consumer touched, and the arm reads
  **`ctx.get("is_wet", false)`** rather than comparing weather strings, so the axis finally fires in
  **storm** as well as rain (the defect three consecutive rounds shipped). Already guarded:
  `test_rally_library.gd` fails with "must be a real rally" / "must be a SPECIAL event". **No codebase fix
  was needed.**
- **A rubric's `expected_tests` is a HINT, never a blast radius.** T009's list omits `rally_library`; I
  followed it, got a fully green first run, and nearly recorded a guarded defect as unguarded — then
  nearly built a duplicate guard for it. The blast radius follows from **what the change touches** (a new
  `UPGRADES` row with a gate field is rally-library territory), not from what a rubric happens to list.
  `expected_tests` widened.
- **The numbered-procedure docs lever is weaker than round 019 claimed. Full tally: 0/2 (both round-017
  A/B arms) -> 2/2 (019) -> 2/2 (021) -> 1/2 (022) -> 1/2 (024).** It raises doc compliance from
  reliably-zero to usually-partial-or-complete; **it does not guarantee it.** Round 020's probe and round
  024's had identical insertion geometry relative to the note (both inserting at line 190) and scored 2/2
  and 1/2 — so the residual is **variance, not position**. No further position work is warranted, and the
  round-019 phrasing ("the usable rule…") was too strong.

## Round 025 (drill mode — T010 countdown beep; the sweep completed)

- **NEW DEFECT CLASS: a point-of-use note phrased as a PLACEHOLDER was implemented and then DELETED.**
  `stage_manager.gd`'s `# AUDIO HOOK` block said the countdown beep "belongs here". A probe wired the beep
  at that spot, obeyed the comment's code instruction — and removed the whole block, which carried the
  **"never hand-roll an AudioStreamGenerator/PCM loop in this file"** prohibition (violating it is what
  scored round 008's probe **2/0/0/0** and took a suite down), the `Audio`-autoload rationale, and the only
  pointers to `features/sfx.md` / `todo/audio.md` — while **three cues remain unwired**.
  **Lesson: a note phrased as a placeholder invites its own deletion. Phrase point-of-use guidance as a
  STANDING RULE about the file or subsystem, say explicitly that it is not a TODO, and list what still
  depends on it.** Rewritten that way (numbered, self-preserving, docs as part 3, unwired cues as part 4).
- **Per-count cues must key off the DISPLAYED value, not a float threshold crossing.** The probe beeped on
  crossings of 2.0/1.0/0.0, which leaves the "3" count **silent** (the HUD already shows 3 before any
  crossing) and fires a tick in the **same frame** as the GO cue — a doubled GO. Five test files green;
  nothing caught it. Round 010's `_last_countdown_display` approach was correct, so this was a regression
  on reachable behaviour.
- **Round 014's falsifiable-statement doc lever needs a reachability caveat.** `features/sfx.md` says the
  countdown beep is "still unwired" — squarely falsified — and went untouched, because the probe **never
  opened the file**: it was named only in a trailing prose clause of the hook comment, the exact form round
  019 showed does not move docs. So: falsifiable statements work **only if the statement is reached**;
  naming a doc in a prose clause does not reach it.
- **Sweep verdict (rounds 023-025): worth running.** T004 clean-solved with no fix needed; T009 and T010
  each surfaced a **new, previously unrecorded cause**. Round 022's worry that only harness artefacts
  remained was too pessimistic. **Revised guidance: probe BREADTH, not depth** — keep sampling stale and
  untouched areas (~one new cause per two rounds), and stop drilling tasks whose only gap is docs or tests.
  **The multiplayer, cloud-save and challenge subsystems have NO bank task at all** — replenishing there is
  where new signal lives.

## Round 026 (drill mode — bank replenishment into multiplayer; T011 authored and probed)

- **A test DOUBLE can drift from a duck-typed interface invisibly, because `has_method()` ignores ARITY.**
  `stage_manager.gd` gates every HUD call on `_hud_can[m] = _hud.has_method(m)`. A probe widened
  `Hud.show_position` from 4 args to 5, updated the real call site and `test_hud.gd`'s call sites, and missed
  `StubHud` in `test_stage_manager.gd:44` — the gate stayed **green** and two tests died on the call.
  **Now guarded:** `test_script_breadcrumbs.gd ->
  test_stub_hud_matches_the_real_hud_signature_for_every_duck_typed_method`, which takes the method NAMES
  from `stage_manager.gd`'s own `for m in [...]` block and compares arities in `hud.gd` vs `StubHud`. Ten
  methods, zero exemptions, and it fails loudly if that block is restructured.
- **A guard must not be reachable only AFTER the failure it diagnoses.** I first appended that guard to
  `test_stage_manager.gd` and it **never ran**: the arity break triggers a Godot debugger break mid-run,
  which halted GUT before reaching a test at the end of the file. Relocated to the source-scanning file,
  which instantiates nothing — and the reason is written into the guard's comment so the placement is not
  "tidied" back.
- **Don't ship a guard whose message asserts something false.** My first failure text said the drift "does
  NOT show up as a clear error". The engine *does* print `Invalid call to function ... Expected 4
  argument(s)`; my grep had filtered it out. Corrected to what is actually true — it surfaces as a debugger
  break attributed to whichever test was mid-flight, so what you see first is unrelated-looking assertions.
- **NEW LEVER (n=1): adjacent correct code can carry a rule that no note states.** Nothing says which speed
  divides a behind-gap; `lobby_field.readout_for` merely *demonstrates* an asymmetry (leading branch divides
  by the chaser's speed, trailing by the player's). The probe wrote the behind-gap with the **car-behind's**
  speed and the same zero guard, six lines from its neighbour. Worth testing deliberately: **a visible
  contrast inside the function being edited may beat a note about it.**
- **Breadth beat depth, immediately.** T011 is the first bank task authored since round 001 and the first
  ever in `scripts/multiplayer/`; it surfaced a new unguarded defect class on its **first** probe, where four
  prior rounds of drilling convention tails surfaced none. **Cloud save and the rally challenge are still
  untouched by any task** — replenish there next.

## Round 027 (drill mode — cloud save; T012 authored and probed)

- **THE BREADCRUMB GUARD ONLY WALKED THE TOP LEVEL OF `scripts/`.** `test_script_breadcrumbs.gd` used
  `DirAccess.open("res://scripts")` + `get_files()` with no recursion, so **every file in a subdirectory
  escaped the convention**: `scripts/cloud/` (13 files, **12 with no `# Docs:` breadcrumb at all**) and
  `scripts/multiplayer/` (5, compliant by luck). Both directories were created AFTER the convention landed —
  exactly the decay the guard's own header warns about ("a convention that only holds for the files that
  happened to exist on the day of the sweep decays from that day onward"). **This is why a cloud-save probe
  had nothing pointing it at `features/cloud-save.md`.** Fixed: scan is recursive (reusing `_gd_scripts_under`),
  12 breadcrumbs added naming real docs and existing tests, a sanity floor so a broken walk fails loudly, and
  the failure message now prints the FULL path (it said `scripts/<basename>`, which misdirects for a subdir file).
  Verified first that no subdirectory basename collides with `BREADCRUMB_BASELINE`, which matches on basename
  and would otherwise have silently exempted a file.
- **WHEN A GUARD EXISTS, CHECK WHAT IT ACTUALLY WALKS.** Second instance in four rounds of a guard not covering
  what it appeared to: round 024's `expected_tests` was too narrow (a guarded defect looked unguarded), and now
  this. A guard's existence is not coverage.
- **"ADJACENT CORRECT SIBLING" IS NOW n=2 AND IS THE MOST ACTIONABLE LEVER THE LOOP HAS FOUND.** I predicted
  T012's probe would set the new `last_sync_device` in only one of the two sync paths (round 020's
  one-directional shape). It set **both**, with the correct *different* values — `FirebaseConfig.device_tag()`
  after a push, `remote.get("device")` after applying a remote — because `last_sync_utc` is already assigned
  correctly in both. Round 026's probe likewise inferred an unstated divisor rule from an adjacent asymmetric
  branch.
  **Rule: a multi-site obligation becomes reliable when a correctly-handled sibling already exists at every
  site — not when a comment enumerates the sites.** Structural, unlike most of what this loop has learned.
- **An emphatic design rule DID reach the model.** `cloud_sync.gd`'s header forbids branching on `updated_utc`
  (a wrong clock "would silently eat the other device's career"); the probe read a 480-line module it had never
  seen and did not branch on it. Combined with rounds 019–025: **rules about the code in front of you land;
  obligations to go elsewhere do not.**

## Round 028 (drill mode — T012 re-probe; the breadcrumb convention measured)

- **THE `# Docs:` BREADCRUMB WORKS — first clean measurement in 28 rounds.** Round 027's probe edited
  `cloud_sync.gd` when it had **no** breadcrumb and scored **0 of 1** on docs. Round 028's probe, with
  `# Docs: features/cloud-save.md — update in the same change as this file.` in that file's header, **updated the
  doc** — correcting the exact example row its change falsified. **Attribution is clean:** the other file it
  edited (`account_menu.gd`) is on `BREADCRUMB_BASELINE` and still has no breadcrumb, so the only pointer in play
  was the new one.
  **The docs picture, consolidated:** trailing prose clause -> ignored; numbered procedure naming two docs ->
  usually partial (2/2, 2/2, 1/2, 1/2); **one doc named in the `# Docs:` header of the file being edited ->
  updated.** Its limitation is structural: a breadcrumb names a FILE, not an obligation, so it cannot express
  "and the other doc too" — which is exactly where every two-doc case has failed.
- **"Adjacent correct sibling" is n=3 and has never failed.** Two different probes, two different variable names
  (`last_sync_device`, `last_device_name`), both set the new field in BOTH sync paths with the correct different
  values, because `last_sync_utc` is already handled correctly in both. Neither branched on `updated_utc`.
- **Getting a probe to the right file does not make what it writes there true.** The breadcrumb steered it to
  `cloud-save.md`, where it documented the screen as showing "from iPhone" and commented `e.g. "iPhone",
  "Desktop"` — values `FirebaseConfig.device_tag()` cannot return (it yields `"web"` or
  `OS.get_name().to_lower()`: "macos", "android", "ios"…). Round 003's invented-asset-path failure in milder
  form. **Fix: document the exact VALUE SET where the value is produced, not just the purpose** — a docstring
  that explains why a value exists but not what it can be invites plausible invention.

## Round 029 (drill mode — T011 re-probe; round 028's finding corrected)

- **ROUND 028's BREADCRUMB FINDING WAS OVER-READ. Docs came back 0/2 under the best possible condition** —
  every file the probe edited carried a `# Docs:` breadcrumb, and between them they named **both** required docs.
  So the breadcrumb is not the mechanism.
- **The better hypothesis: doc compliance tracks the SIZE of the code change, not how the docs are pointed at.**
  Every doc result the loop has, against scripts edited:
  | scripts edited | docs owed | docs updated |
  |---|---|---|
  | 1 (T004, r023) | 2 | **2** |
  | 2 (T012, r028) | 1 | **1** |
  | 2 (T006, r022) | 3 | 1 |
  | 3 (T009, r024) | 3 | 1 |
  | 5 (T011, r026) | 2 | 1 |
  | 4 + a test file (T011, r029) | 2 | **0** |
  A one-script change updated two docs unprompted (r023 even found one the rubric did not list); a five-script
  change updated one; a four-script change plus a test reconciliation updated none. This **subsumes** round 028
  (a two-script change, still in the high-compliance zone), matches round 010's independent "budget/scope
  truncation" read of T003, and explains why five separate interventions on the docs axis all landed on "usually
  partial" — they were fighting the wrong variable. **n=6, correlational, confounded** (bigger changes are also
  harder tasks); testing it needs one doc obligation behind both a one-file and a four-file variant.
- **I declined to ship a fix I had already measured for.** I was about to cap the `# Docs:` half the way round
  005 capped `# Tests:` (of 107 breadcrumbs: 86 name one doc, 15 two, 4 three, `game_config.gd` **six**). But the
  dilution here was across FILES, not within a line, so the cap addressed the wrong thing. Recorded as a
  candidate. Round 018's lesson — drop a designed fix when the evidence refutes its premise.
- **A guard for FILE pointers is not a guard for PROSE pointers.** `stage_manager.gd`'s breadcrumb said "see the
  AUDIO HOOK note", which round 025 renamed to AUDIO RULES — my own rot, four rounds old, invisible to the
  breadcrumb guard because that guard validates named *file paths*. This loop generates concept-pointers
  constantly ("the FALLBACK ONLY block", "the UNITS block"); nothing checks them.
- **Round 026's `StubHud` guard fired on first real exposure, and round 027's relocation was vindicated:**
  `test_stage_manager` produced **no `Totals` at all** (its run died on the arity debugger break) while the guard
  — in a source-scanning file that instantiates nothing — named the drifted stub and the file to fix.

## Round 030 (drill mode — T007; the scope hypothesis tested, and "contradiction beats reference")

- **THE CLEANEST EVIDENCE THE LOOP HAS ON DOCS, and it is from a single probe two lines apart in one file.**
  The same probe, in `speed_lines_setting.gd`:
  - **fixed a falsified statement** — that file said "adding the player-facing menu row is deliberately NOT done
    here", its change made that false, and it rewrote the sentence unprompted;
  - **ignored a reference** — the same file's `# Docs:` breadcrumb names `features/rendering.md`, which went
    untouched.
  Same file, same run, opposite outcomes, which rules out probe-to-probe variance.
  > **A statement the change makes FALSE, in the file being edited, gets fixed. A POINTER to a file that should
  > change does not.**
  **Consequence — the loop's docs strategy is settled: stop trying to make pointers work.** Put the *claim* where
  the editor is working (probes repair contradicted claims), and enforce genuine cross-file doc obligations with a
  **machine guard** (round 017's tyre-doc guard is the working example). Breadcrumbs and notes are for humans.
- **The scope hypothesis survives, refined: doc effort follows the weight of the change PER FILE**, not overall
  size and not whether a file was touched. `settings_menu.gd` (~30 lines of work) -> its doc updated;
  `speed_lines_setting.gd` (2 comment lines) -> its doc not. That also explains round 029's 0/2 (four files each
  moderately changed, attention spread) without a separate story.
- **A CONFIRMED PREDICTION NEARLY HID A WRONG MECHANISM.** I predicted `rendering.md` would be missed *because the
  probe would only read* that file. It **edited** it and still missed the doc — so "the pointer must be in a file
  you edit" is refuted as sufficient, and ticking the outcome would have concealed that. **Standing caution:
  verify the mechanism of a confirmed prediction, not just its outcome.**
- **Cloning a sibling helper carried three correctness properties at once** (n=4 for that lever): using
  `_make_action_button` inherited `focus_mode = FOCUS_ALL` (so the new menu row is keyboard-navigable, avoiding
  this repo's recorded `FOCUS_NONE` trap), and placing the refresher beside `_refresh_fps_selection()` inherited
  the correct init ordering. Nobody told it either thing.

## Round 031 (drill mode — the rally challenge; T013 authored and probed)

- **THE BANK NOW SPANS EVERY MAJOR SUBSYSTEM.** T013 (rally challenge) joins T011 (multiplayer) and T012 (cloud
  save) — three tasks authored in six rounds, each finding a real defect on its first scored probe. Breadth beat
  depth again.
- **THE ADJACENT-SIBLING LEVER IS 5-FOR-5, AND WORKS ACROSS FILES.** I predicted a failure here would mark its
  boundary ("the sibling must be in the same function or module"). It did not fail: the probe found
  `ConfirmPopup.open` used correctly in **`hq_carpark.gd`** and reproduced the call shape in `hq_challenge.gd`
  **exactly** — including the trailing `], 1, 0)` argument defaults and the no-op `Callable()` Cancel. **A correct
  usage anywhere in the codebase can teach the pattern; it does not have to be adjacent.**
- **`_start_preflight`'s `resume` CAN FIRE MUCH LATER, and nothing said so.** On touch with no control scheme
  chosen, it stashes the callable and opens the picker, to be resumed after the player saves. Both of the probe's
  new handlers **cleared their state before calling it** and opened with `if …is_empty(): return`, so a touch
  player confirmed, picked a scheme, and **nothing happened** — silent, and invisible to the suite because the
  gate is behind `Platform.is_touch()`. Documented at the seam, naming the working pattern the free-roam caller
  already uses (`_launch_free_roam.bind(instance_id, model_id)`). **If this cause recurs, the mandated escalation
  is making `_start_preflight` take the state explicitly instead of a bare `Callable`.**
- **Confirms must gate the COMMIT, not the navigation.** The probe added two — one on a Start that merely opens the
  car park (spends nothing) and one at the real commit — so the player is asked twice and `test_menu_flow`
  reddened on "Start opens the challenge car park, not a direct commit". **Checked and confirmed NOT a frozen
  assertion:** that test pins navigation behaviour the task has no business changing.
- **AUTHORING RULE: task text must not parse as an instruction to the assistant.** My first T013 wording —
  *"Warn me that the daily challenge is only one attempt…"* — made a probe reply "what's the actual task?" with
  zero tool calls. Every other bank task opens with a verb about the GAME ("Add", "Show", "Make", "Track", "Play",
  "Give"). **Dispatch voided, not scored** — scoring it would have charged the codebase for my prompt bug, and
  the reply's shape is close enough to a normal summary that skimming it would have produced a phantom 0/0/0/0.

## Round 032 (drill mode — T013 re-probe; the authoring rule that explains three tasks)

- **AUTHORING RULE, and it is the most valuable thing this round produced: a task that CHANGES existing, tested
  behaviour cannot be cleanly solved in this harness.** It will always redden the tests pinning the old behaviour,
  and probes do not author or update tests (round 022). **Prefer ADDITIVE tasks** — a new part, region, field or
  readout. Three cases fit exactly:
  | task | changes tested behaviour? | outcome |
  |---|---|---|
  | T002 (pause menu remembers the row) | yes — a nav test pinned "open() focuses Resume" | **too_hard**, discarded r011 |
  | T008 (clean-run star bonus) | yes — two tests pinned `stars_gained == stars_for_placement` | unwinnable 6 rounds; rescued only because the freeze was one relaxable equality |
  | T013 (confirmation before start) | yes — six assertions pin the immediate commit | unwinnable-clean, NOT relaxable |
  Every **additive** task in the bank (T001, T003, T004, T005, T009, T011, T012) has been scoreable on correctness.
  **§2.5's frozen-assertion check belongs in the AUTHORING step, not only in diagnosis** — I authored T013 in r031
  and found its freeze in r032, one round later.
- **Both r031 fixes worked, and the probe improved on one.** The commit-point label ("THIS IS THE POINT THAT SPENDS
  THE ATTEMPT") moved the confirmation to the right call on **first exposure** — the probe quoted the comment back
  in its report. The `_start_preflight` deferred-resume contract prevented the touch dead end, and the probe got
  there by a **simpler route than the note suggested**: set the state *after* the gate instead of `.bind()`-ing it.
- **The adjacent-sibling lever is 6-for-6** — same function, same module, and different file all work.
- **Two docs explanations died.** `features/menus.md` IS named by the edited file's breadcrumb and was **not**
  updated, so breadcrumbs do not steer effort to whatever they name; and a **one-file change produced ZERO docs**,
  contradicting r029's change-size story. **Only r030's "contradiction beats reference" still stands** — and it held
  again here: the probe rewrote the in-file comment its change made stale, while touching no doc. I have now
  proposed and falsified three doc mechanisms (pointer form, breadcrumb presence, change size); the docs axis should
  be handled with guards, not theories.

## Round 033 (drill mode — T014 authored; two voids, two authoring rules)

- **AUTHORING RULE: before authoring, enumerate EVERY surface the request could mean and check each one.** I wrote
  T014 as "…show the stars when I look at its **map pin**", grepped `overworld_map.gd` (genuinely has no star data),
  and never checked the **HQ's diegetic 3D map table** — whose
  `hq.gd::_build_readout_box(title, stars, unlock)` has **always** built a `StarRow`, with the "-1 = unreached
  event" case handled. The probe chose that surface and the feature was already there. **A grep of the file you are
  thinking of proves nothing about the file you are not.** With round 017's T007 ("already half-implemented") that
  is two instances of the same class.
- **NEW FAILURE MODE: given an already-satisfied request, a probe manufactures a redundant duplicate rather than
  reporting the work is done.** Its own summary listed the **existing** star row as item 3 of what the box shows
  and its **new** numeric label as item 2 — so it saw the row and added a second display of the same number,
  justifying it as saving the player "counting visual stars". It never said "this already exists". Round 017's T007
  and round 018's T003 also involved pre-existing seams, but there the probe still had real work; **this is the
  first case where the correct answer was "nothing to do".** Worth knowing independently of my authoring error: a
  real user asking for something already built would get the same answer.
- **Voids do not burn attempts, and there are two distinct kinds.** This round had one transient **521 origin-down
  API outage** (nobody's fault) and one **defective task** (mine). Neither is evidence about the repo, and scoring
  either would charge the codebase for something else's failure — the same discipline as round 031's voided
  mis-parse. Distinguishing them in the report matters: one says retry, the other says fix the task.
- **Two of my last three authored tasks were defective** (T013's frozen assertion, T014's already-existing
  feature), both caught within a round by verifying rather than assuming. The authoring checklist is now: **(a) is
  it additive? (b) does it already exist on ANY surface the wording could mean? (c) would a correct implementation
  redden an existing test?**

## Round 034 (drill mode — T014 on the overworld map)

- **T014 scored 3/3/2/3.** Stars went in `_write_footer` (not on every pin), via
  `RallyLibrary.stars_for_placement(Save.best_placement(id))`, with non-rally pins guarded and a `stars > 0` guard.
  Docs 1 of 2. The **sibling / one-definition lever is 7-for-7**.
- **I DECLINED TO BANK THE RESULT THE ROUND WAS DESIGNED FOR.** The experiment — does a documented *rationale*
  generalise to a decision it does not literally cover? — is **inconclusive by construction**: the footer is both
  the correct answer AND the convenient one (it already renders the pin the player is "looking at"), so "the
  rationale generalised" and "the obvious place happened to be right" cannot be separated. The probe never mentioned
  the clutter rule, which mildly favours the second. **My design flaw, not bad luck.** A real test needs a readout
  with **no existing single-pin home**, so the cluttered implementation is the path of least resistance.
  (Round 030's lesson applied: verify the *mechanism* of a confirmed prediction, not just its outcome.)
- **A SIXTEEN-ROUND-OLD FIX HAD A HOLE: rounds 015/016 warned about the podium gate on `rally_podiumed`,
  `podium_count` and `podium_rally_count` — but never on `best_placement()`**, which is the accessor a UI consumer
  actually reaches for. The conflation duly resurfaced at a new consumer in a different file: a probe wrote
  `if placement > 0:  # Only show if the rally has been completed` — **right code, wrong reason** (`> 0` means
  PODIUMED). Warning added at `best_placement()`.
  **This is the THIRD time a past fix or guard has been found not to cover what it appeared to** (round 024's
  `expected_tests` too narrow, round 027's breadcrumb scan non-recursive, now this). **Standing rule: when a past
  round says "fixed", check which paths it actually touched.**

## Round 035 (drill mode — T015; the rationale experiment fails to run a third time)

- **"DUPLICATE RATHER THAN REPORT" IS NOW n=2 AND A REAL FINDING.** Round 033's probe added a numeric star label
  above an existing `StarRow`; round 035's added an emissive glow on top of `rally_flag.gd`'s existing
  pennant-and-colour won/unwon distinction (`pennant_kind()` switches the pennant at `stars >= 1`, `accent_color()`
  changes colour at `STARS_FOR_WIN`). **Two independent probes, two subsystems, both building a second mechanism for
  a feature that already existed rather than saying so** — and both reporting it as newly achieving the goal. This is
  the failure mode with the clearest real-world cost: a user asking for something already built gets redundant
  machinery instead of an answer.
- **MECHANICAL AUTHORING RULE (a reminder was not enough — check (b) failed three rounds running): before authoring,
  grep the request's key NOUN across all of `scripts/`, not the file you have in mind.** T014's miss
  (`grep -rn 'StarRow' scripts/` -> `hq.gd`'s readout box) and T015's (`grep -rn 'stars' scripts/` ->
  `rally_flag.gd::pennant_kind`) were **each one grep away**.
- **A RUBRIC CAN BE SURFACE-SPECIFIC WITHOUT SAYING SO.** I marked T015's probe down for inventing raw `Color`
  literals instead of `UITheme` constants — then checked the file: `rally_flag.gd` uses named raw-`Color` constants
  throughout (`ACCENT_GOLD`, `PENNANT_GREEN`, …) and references `UITheme` nowhere, because these are 3D material
  colours. The probe followed the local style exactly. **My rubric line came from `overworld_map.gd`'s conventions and
  I applied it to a different file.** Corrected; convention 1 -> 2.
- **METHOD SIGNAL WORTH ACTING ON: rounds 033-035 produced four findings about my own process and one about the
  codebase.** Earlier rounds found real defects (a stale test double, a non-recursive guard, a compile-breaking
  shadow, a silent touch dead end); the last three mostly found my authoring errors, because each new task is
  unfamiliar ground. **The bank already holds twelve well-characterised live tasks whose rubrics have been corrected
  over many rounds — probe those. New tasks buy breadth at the cost of two or three rounds of rubric debugging each.**

## Round 036 (drill mode — T008; the method change pays off)

- **ROUND 035's METHOD CHANGE WORKED IMMEDIATELY.** Probing a well-characterised task produced a clean, fully
  predicted measurement with **zero rounds spent on rubric repair** — against rounds 033-035, where each newly
  authored task cost exactly that. The mechanical noun-grep (`grep -rniE 'clean_run|no_damage|damage.*bonus' scripts/`)
  confirmed the premise in one command before any work began.
- **T008 scored 3/3/2/3, equalling its best from round 016 — from an independent probe twenty rounds later.** A
  reproducibility datapoint the loop rarely gets, since most tasks change between probes. Every trap accumulated over
  six rounds was avoided: any-finish gate, latched `_took_damage_this_rally` (not HP), int return through the seam,
  `GameConfig` `@export` with correctly no `.tres` line.
- **ROUND 016's UNFREEZE IS VERIFIABLY DURABLE, and its explanatory comment was read, cited and maintained.** The
  probe's report said the tests "already use `>=` … **for this exact reason**", and it updated the comment's tense
  rather than deleting it. Given the loop has found **three** past fixes that did NOT cover what they appeared to
  (r024's narrow `expected_tests`, r027's non-recursive scan, r034's missed accessor), **a fix confirmed still working
  is worth recording as such.**
- **Bounding that carefully: this is a rationale being applied to EXACTLY the case it was written about** — the probe
  used it to know it was safe to proceed. That is **not** evidence a rationale generalises to a decision it does not
  cover, which is round 035's still-open question. Real evidence such comments are read; not evidence they transfer.

## Round 037 (drill mode — T005; four routes, four fixes, none recurred)

- **T005 — the bank's most-fixed task — came back clean on ALL FOUR of its known failure routes** (3/3/1/3). It
  declared `rallies_finished` in `_default_profile()`, added a separate idempotent `record_finished_rally()`, called it
  from the **any-finish** gate, avoided the bare-`rally_id` shadow that broke compilation in round 017, and passed six
  test files with 0 script errors.
- **I am deliberately NOT calling it solved, because I made exactly that error on this task before.** Round 015's
  attempt 3 also scored 3/3/1/3, I wrote that correctness was "solved", and round 016's settlement probe scored
  **3/1/1/3** on the *same tree* via a route nobody had anticipated. Correctness across four probes reads **3, 1, 0,
  3**. One clean probe closes the **known** routes; it does not bound the unknown ones.
- **The durable half, which holds regardless of any single score: three of the four routes are now MACHINE-GUARDED**
  (the declared-key ratchet, the recorder guard, the shadow guard) plus a runtime tripwire. A probe taking any of them
  now reddens a test or fails to boot instead of shipping a plausible wrong number. **That is the part worth having —
  not the score.**
- **Round 035's method change has paid off twice running** (036, 037): draw a *corrected* task, run the noun grep to
  confirm the premise, get a clean measurement, spend **zero** rounds on rubric repair. Compare rounds 033-035, where
  each newly authored task cost two or three.

## Round 038 (drill mode — T010; the self-preserving note works)

- **A SELF-PRESERVING POINT-OF-USE NOTE WORKS — new transferable fix pattern.** Round 025's probe deleted a
  placeholder-phrased `# AUDIO HOOK` block after implementing the cue it described, taking a suite-killing prohibition
  and both doc pointers with it. Round 025 rewrote it as a **standing rule about the file**: it says "these hold
  whether or not any cue is wired yet, so do NOT delete this block", names the observed deletion, and lists the three
  cues still depending on it. Round 038's probe implemented the very cue it describes and **left all four parts
  intact**, citing them by name.
  **Rule: phrase point-of-use guidance as a standing rule about the FILE, never as a marker for the work it
  describes.** A note that reads like a TODO gets discharged along with the TODO.
- **Round 025's display-integer rule also held:** `ceili()` change detection produced four correct cues, eliminating
  both the silent "3" and the doubled GO that the float-threshold version shipped.
- **"Higher" was not checkable, so it was not checked.** Part 1 said `Audio.play_beep(<higher hz>)` for GO; the probe
  passed **800.0** and commented it "higher frequency" — but `sfx_beep_frequency_hz` is **880.0**, so GO sounded LOWER
  than the ticks it punctuates. Fixed by naming the actual default in the rule (with a caveat to re-read the export,
  since quoting an authored number invites staleness). **Same mechanism-vs-invariant shape as round 019: a comparative
  instruction needs its reference point, or its form can be satisfied while its intent is inverted.**
- **Three arm sites collapsed into one `_arm_countdown()` helper (structural).** The probe reset its per-countdown
  tracker at two of three sites, so re-arming through the third within the first second silently swallowed the first
  cue. §2.6's "a checklist past ~3 sites IS the defect — collapse the sites" applied literally: there is now one place
  any per-countdown state can live, making the class **unwritable** rather than warned about.
- **NUMBERING IS NOT SUFFICIENT FOR DOCS EITHER — sixth mechanism to fail.** Part 3 named `features/sfx.md` AND
  `todo/audio.md` as an enumerated obligation *with its reason*, and neither moved. Numbered-part results now read
  2/2, 2/2, 1/2, 1/2, **0/2**. **Stop wording it; guard it** (round 032's standing conclusion, now better evidenced).

## Round 039 (drill mode — T009; a pre-registered interpretation pays off)

- **THE INVENTED GATE ID RECURRED: two of two T009 probes composed a plausible-sounding `unlocked_by_rally` that does
  not exist** — `h_coast_qualifier` (r024) and `sp_coastal_challenge` (r039), fifteen rounds apart, each a different
  invention fitting the `sp_*` naming scheme. A gate naming no rally can never be met, so the part is **permanently
  unwinnable** and nothing at runtime complains.
- **WRITING THE INTERPRETATION DOWN BEFORE THE PROBE IS WHAT MADE THE FIX DEFENSIBLE.** Round 024 saw this once and
  deliberately fixed nothing, because an existing test already caught it. Before dispatching round 039 I recorded: *if
  it recurs, that is a cause to fix at the point of use; if not, it was probe variance.* It recurred, so the fix rests
  on evidence rather than on re-reading a single failure. **Round 024's call was right for one data point and wrong for
  two — and only the pre-registration makes that distinction honest rather than convenient.**
- **The fix acknowledges the harness limit INSIDE the instruction, which is new.** The guard exists and fires; what was
  missing was reachability for an author who cannot run tests. So the note names the guard by test file **and then
  says "that is a test you may not be running, so do the grep"**, with the exact `grep` command. Pointing a probe at a
  test it is forbidden to run is pointing at something out of reach — every previous guard-naming note ignored that.
- **Round 020's symmetric invariant was read and QUOTED.** The probe's rationale paraphrases the clause ("every tire
  compound wins somewhere but loses somewhere else"), and the computed table confirms it holds across four surfaces.
  The tyre-slot procedure now demonstrably steers design on two separate tasks (T001, T009).
- **The corrected-task pass is complete** (T008 r036, T005 r037, T010 r038, T009 r039): **four rounds, four usable
  measurements, zero rounds spent on rubric debugging** — against the three rounds before them, which were spent almost
  entirely on my own authoring errors. Round 035's method change is confirmed.
