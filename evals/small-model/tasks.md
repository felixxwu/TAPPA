# Small-model readiness — task bank

Real, user-phrased feature requests used to probe whether a Haiku-class model can
ship work in this repo unaided. **The rubric under each task is hidden from the
probe** — it sees only the quoted request line.

Authored round 001; rubrics augmented round 002. See `.claude/skills/small-model-readiness/SKILL.md` §1 for the
ratchet rules (retire after two consecutive clean solves; replenish harder).

---

### T001 — "Add a gravel-spec tyre upgrade to the catalogue."
- status: live
- clean_solves: 0  (rounds 001–003, 009 non-clean)
- RUBRIC NOTE round 009 (3/2/2/2, best result this task has had): the probe correctly
  reused the EXISTING axes (flat + tarmac + snow terms, gravel as the neutral base) rather
  than authoring a new one — under the round-004 registry that is the fully-correct answer,
  so do NOT require three registry edits for a part that needs no new axis. Two real misses
  remain: `features/drivetrain-and-tires.md` still said the tyre slot "holds two parts" and
  went unupdated, and the new part is dominated everywhere by `race_tires` (a strictly-weaker
  rung, which the slot was explicitly restructured to eliminate). CAUSE recorded for a later
  round: the tyre-slot authoring checklist is attached to the `snow_tires` row, ABOVE the
  point where a new part is appended, so it is positionally invisible. NOT fixed this round.
- RUBRIC NOTE round 004 (**SUPERSEDES the round-002 and round-003 notes below — the
  design they graded against no longer exists**): round 004 restructured the surface
  axes into the `GameConfig.TIRE_SURFACE_AXES` registry. A new surface axis is now
  THREE edits, all in `scripts/game_config.gd` and all adjacent: the `@export`, the
  registry row, and the `_channel_weight` arm. Grade a new-axis answer as complete
  only if all three are present; consumer files (`drivetrain.gd`, `lap_time_model.gd`,
  `car.gd`, `car_performance.gd`) must NOT need editing, and editing them is a signal
  the probe was working from the stale doc rather than the code. `tire_surface_mult`'s
  4-arg shim still exists for test callers — widening it is unnecessary and touching
  its signature is a defect, not a fix. A gravel part built from the EXISTING flat and
  tarmac terms without a new axis remains a fully correct alternative answer.
  Guards: `test_tire_surface_axes.gd` (both registry directions) and
  `test_every_grip_feeding_effect_field_is_read_by_the_physics`.
- ~~RUBRIC NOTE round 003~~ (historical): round 003's probe expanded every production
  site correctly but broke test_drivetrain.gd's 6 direct tire_surface_mult calls at
  compile time and left the "CLOSED PAIR" note stale. Both hazards are designed out as
  of round 004. Still check `unlocked_by_rally` parity with sibling tyres.
- ~~RUBRIC NOTE round 002~~ (historical): the blend used to be a CLOSED PAIR requiring
  a 6-site edit across 5 files. Retained only to explain why the round-004 note
  supersedes it; do not grade against it.
- areas: catalogue, upgrades
- expected_files: `scripts/upgrade_library.gd` (the `UPGRADES` table; slot must be
  the existing `TIRE_SLOT` = `"tires"`)
- expected_docs: `features/upgrade-catalogue.md`, `features/drivetrain-and-tires.md`
- expected_tests: `upgrade_library`, `upgrades_grid`, and `tire_surface_axes` if the
  answer registers a new surface axis (round 004)
- test_conventions: must NOT pin the new part's stats or assert it exists by id
  (catalogue entries are authored data); may assert catalogue-contract properties
  that hold for any entry
- conventions: any tunable it introduces belongs in `config/game_config.tres`, not
  a script literal; `features/` updated AND indexed in `features/README.md`
- why this task: catalogue tables are the easiest possible change — if a small
  model fails HERE, the problem is navigation, not difficulty

### T002 — "Make the pause menu remember which row was selected when you reopen it."
- status: **too_hard (round 011, 3 attempts)** — moved out of the live pool; see
  "Too hard" at the foot of this file. NOT retired and NOT solved: a later round may
  make it winnable, and round 011's fixes moved it a long way.
- clean_solves: 0  (rounds 003, 005, 006 non-clean; round 011 drill 3/3/0/2 -> 3/2/0/2 -> 3/2/1/2)
- RUBRIC NOTE round 011 (**supersedes the round-005/006 notes on the incidental pass —
  the assertion they describe no longer exists**): `test_pause_menu_is_keyboard_navigable`
  was renegotiated. It no longer pins "open() focuses Resume" unconditionally; it asserts
  that with NOTHING REMEMBERED the cursor lands on `first`, establishing that precondition
  via `MenuNav.forget()` instead of relying on file order, and a sibling test asserts the
  cursor always lands inside the menu whatever is remembered. **Do not re-add the old
  assertion.** Also: `remember` is now a `MenuNav.attach` opt, so the correct answer to this
  task is ONE LINE plus a doc line plus a test — grade a four-site hand-rolled focus tracker
  as a navigation miss, not as thoroughness.
- RUBRIC NOTE round 011 on expected_docs: `features/menus.md` -> "Menu navigation" now
  documents `remember` generically. What is still owed by a probe is the **Pause menu**
  section noting that this menu opts in. Three probes in a row updated no doc at all, so
  this remains a real, unmet requirement — do NOT delete it to make the task passable.
- RUBRIC NOTE round 006: probed again, same result (2/3/0/2) — correctness 3,
  convention 0, and the incidental pass at `test_pause_menu.gd:121` left in place a
  second time. Two graders have now confirmed the incidental pass is real: the file
  shares one `_pause` via `before_all` and no earlier test moves focus. Backlog item
  16 covers it. Do NOT credit a green `test_pause_menu` run here as correctness.
- RUBRIC NOTE round 005: the round-005 probe's CODE was excellent (3/3 correctness —
  whitelist-guarded restore that survives the Settings sub-panel path) and its
  convention score was 0: no doc, no test, and `test_pause_menu.gd:121` left pinning
  "open() focuses Resume", now passing only INCIDENTALLY because it runs before any
  test that moves focus. Grade that incidental pass as a failure — it is order-dependent
  leakage, not a green.
- RUBRIC NOTE round 003: probe's capture-at-close in resume() with a hard-coded
  4-button identity check was sound but shipped no doc/test work;
  test_pause_menu.gd::test_pause_menu_is_keyboard_navigable pins "open() focuses
  Resume" and must be renegotiated, not left passing incidentally. pause_menu.gd now
  carries a # Docs/# Tests breadcrumb (Fix A).
- areas: menus, ui
- expected_files: `scripts/pause_menu.gd` (`open()` currently always focus-grabs
  `_resume_button`; the `_settings_button` return-focus precedent is right there)
- expected_docs: `features/menus.md` -> "Pause menu" for the screen itself;
  `features/menu-navigation.md` for anything about focus behaviour (**split out in round 012**)
- expected_tests: `menu_nav`, `menu_flow`
- test_conventions: menu changes need a keyboard+gamepad nav test (CLAUDE.md);
  no pinning of focus indices as tunables
- conventions: must stay navigable by up/down/left/right/enter/back on BOTH
  keyboard and controller
- why this task: exercises the menu-nav convention, which is stated in CLAUDE.md
  but is easy to miss under context pressure

### T003 — "Add a new region with its own skybox and scatter set."
- status: live
- clean_solves: 0  (rounds 002–003, 009, 010 non-clean — never solved)
- RUBRIC NOTE round 010 (2/1/1/1 — REGRESSION): the probe added the region with `look_from`
  (correct idiom) but authored NO rally and touched NO doc — strictly worse than round 009,
  which at least made the region reachable. Three assertions red across `test_region_assets`
  and `test_region_docs`. It also cloned four values `look_from` already supplies, and knew
  it (its own comment says so), so "its own skybox/scatter set" is unmet. I suspected my
  round-009 template change (map_pos as an unevaluatable function call) caused this; a grader
  refuted that — the probe skipped the DOCS too, which no map_pos blocker explains, and round
  008 failed identically under the old literal template. Best read is budget/scope truncation.
  Round 010 restored a pasteable literal anyway (with a guard that keeps it legal) since the
  hazard was real even if it was not the cause. THIS TASK IS THE BANK'S HARDEST and has never
  been solved; consider whether four parts is simply too much for one Haiku attempt.
- RUBRIC NOTE round 009 (3/1/1/2): **the round-008 template worked.** Where round 008
  refused to make the region reachable, this probe wrote a valid `RALLIES` row — three
  events, real weather id, real map slot — and updated the region count in the doc. All five
  texture paths resolve; the round-003 invented-asset failure did not recur. It failed on
  ONE thing: `map_pos` landed 0.021 from an existing pin (limit 0.03), reddening
  `test_map_pins_are_well_formed_and_never_stack`. Round 009 fixed that cause with
  `RallyLibrary.suggest_map_pos()`, the template now says to paste its result, and the guard
  prints a legal pin. Round 010 grades whether that lands. Also still open: reusing Greece's
  sky/ground textures is not "its own skybox", and `look_from` remains unguarded.
- RUBRIC NOTE round 003: probe read-and-IGNORED the TWO-edits note and invented 3
  nonexistent texture paths by analogy (-canyon). Now guarded by
  test_every_authored_region_resource_path_resolves; notes strengthened. Check asset
  paths exist FIRST when grading.
- RUBRIC NOTE round 002: a region entry is INERT until a rally tags it. The attempt must
  also add `"region": "<id>"` to at least one entry in `RallyLibrary.RALLIES`, or the
  region can never be reached. Also: `res://textures/sky_field.png` is already
  `GameConfig.default_sky_panorama`, so reusing it is not "its own skybox". Guarded by
  `test_every_region_is_reachable_from_at_least_one_rally`.
- areas: terrain, regions
- expected_files: `scripts/region_library.gd` (the `REGIONS` table), `scripts/rally_library.gd`
  (the `region` tag that makes it reachable), plus whatever the region's
  surface/water/scatter hooks require
- expected_docs: `features/regions.md`, `features/terrain.md`
- expected_tests: `region_library`, `region_assets`, `terrain`
- test_conventions: no asserting a specific region exists or its authored values;
  test the contract (`by_id` round-trips, `count()` consistent, grip lookups finite)
- conventions: values in `config/game_config.tres`
- why this task: `region_library.gd` has a wide static surface
  (`surface_grip_of`, `deep_snow_of`, `water_level_of`) and touches
  `terrain_manager.gd` (2895 lines) — a real coupling test

### T004 — "Show the current gear on the HUD."
- status: live
- clean_solves: 0  (rounds 002, 005, 006 non-clean; round 007 best yet 3/3/1/2)
- RUBRIC NOTE round 007: **SOLVED on correctness (3/3/1/2) — the structural fix worked.**
  The probe made the one-line `DEBUG_READOUT_NODES` edit AND rewrote the named gear test
  (genuinely — the grader checked it was not gutted). It still skipped `features/hud.md`,
  which round 007 addressed by naming the docs AT the constant. Grade a round-008 attempt
  primarily on whether the DOCS now follow; the code+test half is demonstrably reachable.
- RUBRIC NOTE round 006 (SUPERSEDES the round-005 note): the bundled test is GONE.
  `hud.gd` now owns `DEBUG_READOUT_NODES`, one membership list driving both `_ready`
  and the H-toggle, and `tests/headless/test_hud.gd` binds to it — including
  `test_gear_label_is_part_of_the_h_gated_debug_readout`, whose NAME identifies the
  gear contract. A correct answer is now a one-line membership edit plus updating
  that named test. If a probe STILL ships red here, in-file structure has failed too
  and the next escalation must be outside the file (a hook, or a CI diff check).
- RUBRIC NOTE round 005: `hud.gd`'s `# Tests:` breadcrumb was cut from 6 named files to 3
  primary ones plus a grep. Round 005's probe followed the Docs half and ignored the
  Tests half, shipping `test_hud.gd:125` red; the SAME red test is the thing to watch
  for. Un-grouping gear from the H-key debug set is the correct approach — the failure
  is not reconciling `test_speed_gear_rpm_hidden_until_h_toggle`, whose name bundles
  three contracts, and leaving the stale comment at `hud.gd:176`.
- RUBRIC NOTE round 002: `GearLabel` ALREADY EXISTS in `main.tscn` and is already updated
  every frame — it is merely hidden, as one third of the H-key debug readout
  (speed/gear/rpm). So the work is not building a label; it is un-grouping gear from that
  deliberate debug set AND reconciling `tests/headless/test_hud.gd`'s "gear hidden on
  startup" assertion, which pins the old behaviour. Leaving that test red is a
  correctness AND completion failure. Reusing the existing label is correct — do not
  penalise it as "didn't follow the `_build_*_label` pattern".
- areas: hud, ui
- expected_files: `scripts/hud.gd` (follow the existing `_build_*_label` /
  `_update_*` pattern), reading gear from the drivetrain/engine seam
- expected_docs: `features/hud.md`
- expected_tests: `hud`
- test_conventions: no pinning label positions or font sizes (tunables)
- conventions: any position/size value belongs in `config/game_config.tres`
- why this task: `hud.gd` is 781 lines of many near-identical `_build_*` methods —
  tests whether the pattern is discoverable enough to copy correctly

### T005 — "Track how many rallies the player has finished and show it on the profile."
- status: live
- clean_solves: 0  (round 003 non-clean; round 014 3/2/2/3 non-clean)
- RUBRIC NOTE round 014 (**3/2/2/3 — best result this task has had, and the first
  completion-3 in the loop**): round 003's rename landed and WORKED. The probe did not
  mislabel the podium count; it added a real `rallies_finished` counter, wired it in
  `rally_session.gd` after `complete_rally()` so it counts every finish including DNF, put a
  career-stat row on the map table, AND updated `features/save-persistence.md` — including
  rewriting the "there is no finished-in-any-position counter" sentence its own change
  falsified. One defect: it never declared `rallies_finished` in `_default_profile()`, so
  `_migrate`'s key backfill never seeds it (silent; every test passed). **Round 014 added
  `test_every_persisted_key_written_is_declared_in_the_default_profile` to catch exactly
  that** — validated red against this probe's tree, green on main. Grade a future attempt
  down if it writes a profile key it does not declare. `features/progress.md` still went
  unupdated.
- RUBRIC NOTE round 003: Save.completed_rally_count() counts TOP-3 finishes, not
  finishes — a correct attempt must either surface it honestly or use a true
  finish count. Probe's hq_overlays.gd title-label approach was otherwise sound
  (nav 3 / corr 3); failed on docs+tests+mislabel.
- RUBRIC CORRECTED round 001: this needs NO migration. `Save.completed_rally_count()`
  already exists (`save_manager.gd:1608`). Do not penalise reuse of it.
- areas: save, progress
- expected_files: a display site (e.g. `scripts/overworld_garage.gd`), reading
  the existing `Save.completed_rally_count()`
- expected_docs: `features/save-persistence.md`, `features/progress.md`
- expected_tests: `save_manager`, `save_sandbox`
- test_conventions: must use the save sandbox; `save_test_helpers.gd` exists
- conventions: migrations are mandatory for new persisted fields
- why this task: the migration requirement is real, load-bearing, and invisible
  unless you read `save_manager.gd` carefully — a strong probe of "hidden coupling"

### T006 — "Make the engine braking stronger when you lift off the throttle."
- status: live
- clean_solves: 0  (rounds 001, 002, 005, 009 non-clean; round 010 best yet at 3/3/2/2)
- RUBRIC NOTE round 010 (3/3/2/2 — FIRST CORRECTNESS 3): the probe used `is_lifting_off()`,
  added `engine_braking_lift_off_gain` to GameConfig with an authored `.tres` value, and
  updated the doc in three places. The grader verified it leaves fuel cut, mid-shift, declutch
  and the idle clamp untouched. THE ONE RED WAS MY OWN TEST'S FAULT, not the probe's:
  round 009's `test_coasting_and_fuel_cut_share_one_friction_term` pinned an equality that
  holds only while the gain is 1.0 — it forbade the very feature this task asks for. Replaced
  in round 010 with a fuel-cut-only invariant. Do NOT reinstate an equality assertion here.
  Still missing: a behavioural test ("raising the gain increases coast decel and leaves
  fuel-cut decel unchanged"), which is legal and easy.
- RUBRIC NOTE round 009 (3/2/2/1): the probe multiplied coasting torque at `not combusting`,
  which is ALSO true mid-gearchange and under `fuel_cut` (the rev limiter depends on that same
  friction term), so it silently retuned shifts and limiter bounce. Round 009 fixed the cause:
  `Engine.is_lifting_off()` now exists as the searchable throttle-position-only predicate and
  `combusting`'s comment is an explicit three-state table. GRADE A ROUND-010 ATTEMPT ON
  WHETHER IT FINDS `is_lifting_off`. Note for the grader: a new `@export` whose authored value
  equals its default correctly has NO `config/game_config.tres` line — Godot serialises only
  non-defaults. Do not dock convention for that (round 009's grader did; I overrode it).
  Still missing from every attempt so far: `features/engine-and-transmission.md` and a test.
- RUBRIC NOTE round 006: **solved on convention** (3/2/3/1) — the probe added
  `engine_friction_slope = 2.0` to `config/game_config.tres` and never touched the
  trap property, citing the hoisted FALLBACK ONLY block. The remaining gaps are
  MAGNITUDE (2x the slope is only 9-23% more braking torque because the base
  dominates — grade a bare doubling as insufficient) and the stale doc at
  `features/engine-and-transmission.md:92`.
- RUBRIC NOTE round 005: `engine_friction_base` is OVERWRITTEN per-engine by
  `EngineLibrary.apply` from the authored ENGINES table, so raising it changes nothing
  once a car is fielded — round 005's probe raised it and half its edit was inert. That
  warning is now hoisted onto its own comment block above the export, and
  `game_config.gd`'s header states the .tres rule plus the grep that tells you whether a
  literal is live. Judge: did the probe touch `engine_friction_slope` (globally live) or
  the ENGINES table, rather than `engine_friction_base`? And is the magnitude big enough
  to FEEL — the round-005 attempt bought ~8% at 4000 rpm, which is not.
- RUBRIC NOTE round 002: `engine_friction_slope` in `config/game_config.tres` is the right
  knob and raising it there is a legitimate, full-marks answer on convention — no test is
  required (pinning the chosen value is banned). Judge correctness on MAGNITUDE: the base
  term dominates, so a change must be big enough to actually feel.
- areas: physics, tuning
- expected_files: `scripts/car.gd` (2509 lines) and/or `scripts/engine.gd`, with
  the strength itself as a `GameConfig` knob
- expected_docs: `features/car-physics.md`, `features/engine-and-transmission.md`,
  `features/configuration.md`
- expected_tests: `car`, `sim`, `retune`
- test_conventions: NEVER pin the chosen value; test the behaviour that must hold
  for any reasonable setting (lifting off decelerates the car)
- conventions: the value goes in `config/game_config.tres`; `car.gd`'s
  `_live_baseline` snapshot/restore contract must not break
- why this task: the single most likely place for a small model to hardcode a
  literal instead of adding a config knob

### T007 — "Add a setting to turn off the speed blur effect."
- status: live
- clean_solves: 0  (round 003 non-clean)
- RUBRIC NOTE round 003: probe persisted + boot-applied correctly but OFF→ON mid-run
  is dead (speed_lines.gd _ready early-return with _mat unset — disabled treated as
  terminal), source of truth landed as a static on SettingsMenu instead of an
  apply-module (fps_setting/camera_manager shape), no docs/tests/nav test.
- areas: menus, settings, rendering
- expected_files: `scripts/settings_menu.gd` (1432 lines), the rendering site,
  and the persisted setting
- expected_docs: `features/settings.md` (**moved out of `menus.md` in round 012** — the
  settings half used to be a subsection under the HQ heading), `features/rendering.md`
- expected_tests: `settings`, `menu_nav`
- RUBRIC CORRECTED round 001: `Save.get_setting`/`set_setting` is a generic
  settings dict — NO `SCHEMA_VERSION` bump is needed. The real requirement is
  that the setting is RE-APPLIED AT BOOT (see `camera_manager.gd`,
  `fps_setting.gd`, `music_director.gd` for the pattern); writing `Config.data`
  only at toggle time means it silently will not survive a restart.
- test_conventions: nav test required for the new row
- conventions: keyboard + gamepad navigable
- why this task: deliberately spans three areas (menu + render + save) — tests
  whether "what else must I update" is discoverable

### T008 — "Give the player a star bonus for finishing a rally without any damage."
- status: live
- clean_solves: 0  (rounds 002, 005, 007, 008, 009, 010 non-clean; round 010 best yet at 3/2/2/1)
- RUBRIC NOTE round 010 (3/2/2/1 — the typed seam WORKED): the probe called
  `_award_any_finish_bonus_stars()`, returned an int, put the amount in a NEW
  `@export_range(0,10) no_damage_bonus_stars` with a `.tres` value, and never touched
  `RallyLibrary.STARS_FOR_*`. Its whole logic is two lines. After five failures this is the
  first attempt whose mechanic AND value placement are both right, and the grader judges the
  int seam (not variance) the credible reason — the invented-key failure is now
  unrepresentable. Two pre-existing tests went red; the grader confirms that is the CORRECT
  consequence (both assert `stars_gained == stars_for_placement(...)` on undamaged fixtures)
  and an implementer should relax them — round 010 added a note at the seam naming both tests,
  since they are green until the seam pays out and so cannot be discovered by running first.
  REMAINING: no docs, no test. And see backlog — a grader argues `stars_gained` is overloaded
  and the bonus deserves its own displayed key; that is a PRODUCT decision, not mine to take.
- RUBRIC NOTE round 009 (3/1/0/1 — DOWN, and the fourth failure at this site): the core
  mechanic was right for the second round running (any-finish gate, `took_damage_this_rally()`
  not the HP oracle), but the bonus was returned under an invented key `clean_run_stars` that
  nothing reads — round 008 did the identical thing under the name `stars_bonus`. Confirmed by
  run: `test_a_rewin_pays_stars_again_but_never_another_car` went red. Round 009 removed the
  cause structurally: the seam is now `_award_any_finish_bonus_stars() -> int`, so an invented
  key is not expressible, and a separate dict seam is allowlist-checked with a `push_error`
  that hands back the instruction. **Round 010 must re-probe this task**; if the int seam is
  used, the remaining failure is amount-placement (see backlog item 0, still open).
- RUBRIC NOTE round 002: `reward_system.gd` and `features/reward-system.md` both disclaim
  owning WHEN a reward fires, so `rally_session.gd::_resolve_results` is a DEFENSIBLE home
  — do not mark navigation down for choosing it. Mark down for: the bonus as a bare
  literal instead of a `GameConfig` knob; an unrequested placement gate; using end-of-rally
  `hp >= max_hp` as the damage signal (pit repairs restore HP between events, so a
  crashed-then-repaired car reads pristine); and leaving `test_rally_session.gd:728`
  (`the podium re-win pays its stars`) red, which any added star breaks.
- RUBRIC NOTE round 005: two NEW traps confirmed. (a) The probe dropped its bonus inside
  `_resolve_results`' `if record_completion:` block and silently inherited a TOP-3 GATE —
  a player finishing 5th undamaged got nothing, so the literal request was unmet. That
  local is now named `podium_or_opening` and carries a note saying where an any-finish
  reward belongs. (b) It `+=`'d the bonus into `stars_gained`, which existing tests pin
  as the PLACEMENT payout — hence the two reds. Also: tracking damage with a flag set in
  `report_event_result` is BETTER than the `hp >= max_hp` end-state check and should be
  credited, not penalised.
- areas: rewards, star-economy, damage
- expected_files: `scripts/reward_system.gd`, reading damage state from its
  existing seam
- expected_docs: `features/reward-system.md`, `features/star-economy.md`,
  `features/damage.md`
- expected_tests: `reward_system`, `star_row`
- test_conventions: do NOT pin the bonus amount or a reward tier; test the logic
  (a clean run earns strictly more than an identical damaged run)
- conventions: the bonus amount is a `GameConfig` tunable
- NOTE FOR GRADER: `test_reward_system` PASSES on the round-001 baseline. Older
  notes calling it a standing failure are stale — do not excuse a red here
- why this task: reward logic is where "don't test tunable values" is easiest to
  violate; strong probe of the convention axis

### T009 — "Add a wet-weather tyre compound that grips better in the rain."
- status: live
- clean_solves: 0  (rounds 006, 009, 010 non-clean; round 010 best yet at 3/3/2/2 — but see the round-006 rubric note: the design, not the probe, was at fault; round 009 was near-clean at 3/2/2/2)
- RUBRIC NOTE round 010 (3/3/2/2 — FIRST CORRECTNESS 3, and the round-006/009 causes are
  settled): the probe added the export, the registry row and a `_channel_weight` arm reading
  `ctx["is_wet"]` — the bool round 009 seated in `fill_tire_context` — so the axis fires for
  BOTH rain and storm, for player and AI, with no string comparison anywhere. The gate is real
  in DATA this time (`unlocked_by_rally: "sp_lakeshore_trial"`, an id that exists). Grader
  credits the seam over variance: three consecutive probes wrote at that exact site.
  REMAINING (new): `features/upgrade-catalogue.md` is stale in three places after a tyre part
  is added — round 010's `test_no_feature_doc_states_a_slot_member_count` now guards the count
  half; the unlock-id list and menu-label list are still unguarded.
- RUBRIC NOTE round 009 (3/2/2/2 — near-clean, and the round-006 note is now settled): the
  probe made all three `TIRE_SURFACE_AXES` registry edits plus the `EFFECTS` row and BOTH tyre
  docs, touched zero consumers, and the grader traced the axis firing end to end for player and
  AI. The round-006 verdict that the DESIGN was at fault is confirmed — under the registry this
  task is nearly solved. Two defects left: the arm was rain-only so wet tyres were dead in a
  `storm` (third round running), and the row's comment claimed a rally gate it did not author.
  Round 009 fixed the first cause — `WeatherLibrary.is_wet()` now exists, is guarded so no
  condition can ship unclassified, and `fill_tire_context` seats `ctx["is_wet"]` at the exact
  site where all three probes wrote their comparison. Grade round 010 on whether it reads that
  bool. The `unlocked_by_rally`-claimed-in-prose-but-absent-in-data gap stays unguarded.
- areas: catalogue, upgrades, physics, weather
- DELIBERATELY HARDER than T001, and it is the direct measurement of round 004's
  structural fix. T001 has a legitimate no-new-axis answer (build a gravel part from
  the existing flat and tarmac terms). This one does NOT: "grips better in the rain"
  is a condition no existing axis expresses, so a correct answer must either
  (a) register a new axis in `GameConfig.TIRE_SURFACE_AXES` — the `@export`, the
  registry row, the `_channel_weight` arm, all three, all in `game_config.gd` — or
  (b) go through `WeatherLibrary`'s `rain_grip_mult` seam instead, and say why.
  Both are correct; picking one and doing it completely is the bar.
- expected_files: `scripts/game_config.gd` (registry + export + blend arm) OR
  `scripts/weather_library.gd`; `scripts/upgrade_library.gd` (`UPGRADES`, existing
  `TIRE_SLOT`)
- expected_docs: `features/drivetrain-and-tires.md`, `features/upgrade-catalogue.md`,
  `features/weather.md`
- expected_tests: `tire_surface_axes`, `upgrade_library`, `upgrades_grid`
- test_conventions: must NOT pin the part's stats, the multiplier value, or assert
  the part exists by id; must not pin which axes are registered
- conventions: authored figures live on the part in `UPGRADES`, not as script
  literals; `features/` updated AND indexed
- RUBRIC NOTE round 007: three-edits-in-one-file **confirmed genuinely satisfied**
  (3/2/2/1). Remaining, and unfixed as of round 007: the arm hardcodes `"rain"` instead of
  `RallyLibrary.WEATHER_RAIN` and misses `"storm"`, which is wetter. No
  `WeatherLibrary.is_wet()` exists (backlog 17). Grade storm handling explicitly.
- RUBRIC NOTE round 006 (**REWRITES the WATCH FOR list below — round 004's design
  was at fault, not the probe**): probing this task exposed that the registry
  hardcoded its context inputs, so a weather axis could NOT be added without widening
  the resolver. Round 006 fixed that: `tire_surface_mult_for(source, ctx)` now takes a
  stage context from `GameConfig.fill_tire_context`, which carries tarmac weight,
  snowy AND weather. A correct answer is therefore three edits in `game_config.gd`
  with NO consumer edits and NO signature change — and that is now actually true.
  Also grade: does the arm use `RallyLibrary.WEATHER_RAIN` rather than the bare
  string, and does it handle `"storm"` (also wet)? Round 006's probe hardcoded
  `"rain"` and its wet tyre did nothing in a storm.
- WATCH FOR (the failure modes round 004 designed out — if any recurs, the fix did
  not reach the model): editing `drivetrain.gd` / `lap_time_model.gd` /
  `car.gd::_apply_physics_spec` / `car_performance.gd::merged_meta` to teach them a
  new axis (all four now derive from the registry and must NOT need edits); widening
  `tire_surface_mult`'s 4-arg signature (the shim exists for test callers — touching
  it breaks `test_drivetrain.gd` at compile time); adding the `@export` alone and
  stopping (now caught by `test_tire_surface_axes.gd` in both directions).
- why this task: the retirement candidate for the whole grip area. If a Haiku-class
  model can do this in one file, four rounds of work on that area are done.

### T010 — "Play a beep on each count of the 3-2-1-GO countdown."
- status: live
- clean_solves: 0  (round 008 2/0/0/0, round 010 3/3/2/1)
- RUBRIC NOTE round 010 (3/3/2/1 — the biggest jump in the loop's history, from 2/0/0/0):
  the probe called `Audio.play_beep()`, found the real timing owner (`stage_manager.gd`, not
  `hud.gd`), and beeps exactly once per count via a `_last_countdown_display` tracker reset in
  all three arm/reset paths. Four suites green where round 008's hand-rolled DSP took the
  stage-manager suite down. The grader credits the hardcoded `1200.0` for GO as CORRECT — both
  `sfx_beep_frequency_hz`'s docstring and `features/sfx.md` sanction overriding for a
  deliberately different pitch — so do not dock it. REMAINING and the whole gap now:
  `features/sfx.md` line ~108 still lists "the countdown beep" as PLANNED, `todo/audio.md` is
  unticked, and there is no test (`beep_spec()` exists precisely so this is testable headless).
- areas: audio, stage-start, hud
- WHY THIS AREA: audio is the last major subsystem the bank never touches, and this
  task crosses three of them — the countdown state lives in the stage-start flow, the
  3·2·1·GO text is `hud.gd`'s `_countdown_label`, and all existing audio is either the
  PROCEDURAL engine synth (`scripts/engine_audio.gd`, no samples anywhere) or
  `MusicDirector.play_song`. There is no one-shot SFX facility, so the probe must
  either build one or justify reusing something. Grade the JUSTIFICATION as much as
  the code — this is a task where "there is no existing seam" is the right finding.
- expected_files: whatever owns the countdown tick (find it — do not assume `hud.gd`
  owns the timing just because it owns the label), plus a new or reused audio player
- expected_docs: `features/engine-audio.md` (or a NEW `features/sfx.md` indexed in
  `features/README.md` if the probe creates a general one-shot facility), `features/hud.md`
- expected_tests: `hud`, `countdown_hold`, `start_line`
- test_conventions: never pin a volume, pitch, or beep duration — those are tunables;
  test the LOGIC (a beep fires once per count and not twice; nothing plays after GO)
- conventions: any volume/pitch/duration value belongs in `config/game_config.tres`;
  a new script needs the `# Docs:` / `# Tests:` header breadcrumb (a guard test
  enforces this for every script not in the frozen baseline — so a NEW file WILL fail
  the suite if it has no breadcrumb). **This task is the first live test of the
  round-005 breadcrumb ratchet against a genuinely new file.**
- WATCH FOR: procedural-vs-sample confusion (the project ships NO audio samples, so a
  probe that references a `.wav` has invented an asset — round 003's dangling-region-
  path failure in a new area); a beep that retriggers every frame instead of once per
  count; and whether the probe notices `Config.data` has no sfx volume knob.


---

## Too hard

Tasks that outran the drill loop's attempt cap. **Not retired, not solved.** Every fix made
while drilling them was kept — a discard means the task outran the loop, not that the work
was wasted. A later structural round may make one winnable; re-probe before assuming.

### T002 — "Make the pause menu remember which row was selected when you reopen it."
- discarded: round 011, drill mode, 3 attempts (`MAX_ATTEMPTS`)
- attempt curve: **3/3/0/2 -> 3/2/0/2 -> 3/2/1/2**
- **AMENDED round 013 — the round-011 reason below is REFUTED.** T002 was re-probed twice after
  round 012 split `features/menus.md` (2,539 -> 492 lines, with `menu-navigation.md` carrying this
  task's subject). Both probes scored **3/3/0/2**: one line, correct, suite green, no doc, no test.
  Attempt 2 **opened `menu-navigation.md`, cited it by line range, and still did not edit it.** So
  the blocker is neither doc-location cost nor doc-ignorance. It is that the probe's model of
  "done" is "the code works", and the only thing that changes that is a check it cannot
  self-certify past — i.e. a test, which probes are forbidden to run. **This task's convention
  score measures the probe harness, not this codebase.** On navigation and correctness it is
  3/3 and stable across four probes. Do NOT re-probe it to measure the codebase; re-probe it only
  if the harness ever lets probes run tests.
- ~~superseded~~ **why, in cause terms — the failures REPEATED, they did not wander.** Navigation was 3 at
  every attempt. Convention was the blocker every time, on the same two obligations: the
  `features/menus.md` entry (missed 3/3) and a working test (missed 3/3, though attempt 3
  wrote one that did not pass). A repeating cause means a structural defect the round did not
  reach — per §D2 that is "fixing the wrong layer", not a broad task.
- **the unreached layer:** `features/menus.md` is ~2,500 lines covering every menu in the game.
  The obligation is not that probes refuse to write docs — attempt 3 proved willingness by
  writing a test unprompted. It is that **locating the insertion point in a 2,500-line monolith
  costs more than the change itself**. That is the layer-1 target and it needs a structural
  round.
- **caveat on the earlier numbers:** rounds 005 and 006 graded this task with a frozen
  assertion standing that made a correct implementation unable to reach green (see
  `rounds/011.md` -> "Contamination notice"). Their convention-0 scores are not clean readings.
