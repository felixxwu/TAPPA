# Small-model readiness — task bank

Real, user-phrased feature requests used to probe whether a Haiku-class model can
ship work in this repo unaided. **The rubric under each task is hidden from the
probe** — it sees only the quoted request line.

Authored round 001; rubrics augmented round 002. See `.claude/skills/small-model-readiness/SKILL.md` §1 for the
ratchet rules (retire after two consecutive clean solves; replenish harder).

---

### T001 — "Add a gravel-spec tyre upgrade to the catalogue."
- status: live
- clean_solves: 0  (round 001 non-clean, round 002 non-clean — reset)
- RUBRIC NOTE round 002: the surface-grip blend is a CLOSED PAIR
  (`GameConfig.tire_surface_mult` takes exactly a snow and a tarmac multiplier).
  Declaring a third `@export` is NOT enough — a gravel axis must also be read by
  `drivetrain.gd`'s `_surface_at`, `lap_time_model.gd`, `car.gd::_apply_physics_spec`'s
  reset and `car_performance.gd::merged_meta`'s carry list, or the part is inert. A
  correct alternative answer is a gravel part built from the EXISTING flat/tarmac terms
  without inventing a new axis. Guarded by
  `test_every_grip_feeding_effect_field_is_read_by_the_physics`.
- areas: catalogue, upgrades
- expected_files: `scripts/upgrade_library.gd` (the `UPGRADES` table; slot must be
  the existing `TIRE_SLOT` = `"tires"`)
- expected_docs: `features/upgrade-catalogue.md`, `features/drivetrain-and-tires.md`
- expected_tests: `upgrade_library`, `upgrades_grid`
- test_conventions: must NOT pin the new part's stats or assert it exists by id
  (catalogue entries are authored data); may assert catalogue-contract properties
  that hold for any entry
- conventions: any tunable it introduces belongs in `config/game_config.tres`, not
  a script literal; `features/` updated AND indexed in `features/README.md`
- why this task: catalogue tables are the easiest possible change — if a small
  model fails HERE, the problem is navigation, not difficulty

### T002 — "Make the pause menu remember which row was selected when you reopen it."
- status: live
- clean_solves: 0
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
- clean_solves: 0  (round 002 non-clean)
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
- clean_solves: 0  (round 002 non-clean)
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
- clean_solves: 0
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
- clean_solves: 0  (round 001 non-clean, round 002 non-clean — reset)
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
- clean_solves: 0
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
