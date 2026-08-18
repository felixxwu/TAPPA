# Small-model readiness — task bank

Real, user-phrased feature requests used to probe whether a Haiku-class model can
ship work in this repo unaided. **The rubric under each task is hidden from the
probe** — it sees only the quoted request line.

Authored round 001; rubrics augmented round 002. See `.claude/skills/small-model-readiness/SKILL.md` §1 for the
ratchet rules (retire after two consecutive clean solves; replenish harder).

---

### T001 — "Add a gravel-spec tyre upgrade to the catalogue."
- status: live
- clean_solves: 0  (rounds 001–003 non-clean)
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
- status: live
- clean_solves: 0  (rounds 003, 005, 006 non-clean)
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
- expected_docs: `features/menus.md`
- expected_tests: `menu_nav`, `menu_flow`
- test_conventions: menu changes need a keyboard+gamepad nav test (CLAUDE.md);
  no pinning of focus indices as tunables
- conventions: must stay navigable by up/down/left/right/enter/back on BOTH
  keyboard and controller
- why this task: exercises the menu-nav convention, which is stated in CLAUDE.md
  but is easy to miss under context pressure

### T003 — "Add a new region with its own skybox and scatter set."
- status: live
- clean_solves: 0  (rounds 002–003 non-clean)
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
- clean_solves: 0  (round 003 non-clean)
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
- clean_solves: 0  (rounds 001, 002, 005 non-clean; round 006 best yet at 3/2/3/1)
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
- expected_docs: `features/menus.md`, `features/rendering.md`
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
- clean_solves: 0  (round 002 non-clean)
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
- clean_solves: 0  (round 006 non-clean — but see the round-006 rubric note: the design, not the probe, was at fault)
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
- clean_solves: 0  (authored round 007, not yet sampled)
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
