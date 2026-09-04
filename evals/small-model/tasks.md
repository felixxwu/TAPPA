# Small-model readiness — task bank

Real, user-phrased feature requests used to probe whether a Haiku-class model can
ship work in this repo unaided. **The rubric under each task is hidden from the
probe** — it sees only the quoted request line.

Authored round 001; rubrics augmented round 002. See `.claude/skills/small-model-readiness/SKILL.md` §1 for the
ratchet rules (retire after two consecutive clean solves; replenish harder).

> **STAGE 9 OF THE ROGUELIKE PIVOT RE-AUTHORED SIX TASKS AND RESHAPED ONE**
> (`todo/roguelike-pivot-plan.md`, decision 41). T001, T005, T008, T014 and T015 targeted the star
> economy, the parts catalogue, the career rally, the overworld map and the podium — all deleted —
> and were measuring nothing. T009 moved house (tyre compounds are boosts now) and T003 gained real
> obligations (a linear unlock `order`, a 16-event pool floor). **Their clean_solve counters are
> reset**, because a score against a deleted system says nothing about the current one. The rounds in
> `evals/small-model/rounds/` are left exactly as they were: they are the record of what the loop
> found, and several of their FINDINGS outlived their tasks — every re-authored entry says which.

---

### T001 — "Add a new boost to the between-stage pick."
- status: **live — RE-AUTHORED in stage 9 of the roguelike pivot.**
- clean_solves: **0** (the counter resets: this is a different task against a different system)
- **WHAT THIS REPLACED, AND WHY THE SCORES ARE GONE.** T001 was "Add a gravel-spec tyre upgrade to
  the catalogue" and had a long history (rounds 001-042, one clean solve at 021, retirement reversed
  at 042). `UpgradeLibrary`'s authored `UPGRADES` catalogue, its slots, its star purchase and its
  per-car install are all **deleted** by the roguelike pivot (`todo/roguelike-pivot.md`), so the task
  measured nothing. Its history is preserved in `evals/small-model/rounds/` and in
  `todo/small-model-readiness.md`; do not read the old scores as applying here.
- **WHAT IT MEASURES NOW — the same coupling, one system over.** `BoostLibrary.CATALOGUE`
  (`scripts/boost_library.gd`) is the in-run boost pool, and every entry names an
  `UpgradeLibrary.EFFECTS` key plus the `GameConfig` field its magnitude is read from. So a new boost
  is a **three-site edit** with a silent-failure trap at each: the catalogue entry, the `EFFECTS` row
  (if the effect key is new), and the `@export` on `GameConfig`. This is deliberately the SAME shape
  as the retired task — one authored row that only works if two registries agree — against the
  system that replaced it.
- **THE TRAP TO GRADE ON (round 041's finding, still live).** An effect key with no `EFFECTS` row is
  DROPPED by `UpgradeLibrary.apply`: the boost reads as active, the config is untouched, and the
  feature simply does not happen. `apply` now `push_error`s on it and
  `test_boost_library.gd` asserts every authored key has a row — so a probe that skips the row should
  go red rather than pass silently. A probe that reuses an EXISTING effect key (`mass_mult`,
  `tire_grip_mult`, …) has taken a legitimate shortcut and must not be marked down for it; the row is
  only required for a NEW key.
- **ALSO GRADE:** `level_direction` (+1 if a purchased level should push the magnitude UP, -1 if
  down) — getting it backwards makes the meta shop weaken the boost, and no test catches it, so it is
  a correctness call. And the magnitude belongs in `config/game_config.tres`, never as a const in the
  catalogue.
- areas: upgrades, config, run loop
- expected_files: `scripts/boost_library.gd` (`CATALOGUE`), `scripts/game_config.gd` (the magnitude
  `@export`, under `@export_group("Roguelike Run Boosts")`), `config/game_config.tres`, and
  `scripts/upgrade_library.gd` (`EFFECTS`) only if the effect key is new
- expected_docs: `features/region-runs.md` (the boost catalogue section),
  `features/upgrade-catalogue.md` (only if an `EFFECTS` row was added)
- expected_tests: `boost_library`, `upgrade_library`
- test_conventions: no asserting a shipped magnitude, a catalogue size, or that a particular boost
  exists — those are all authored data. Test the contract (every authored effect key has an `EFFECTS`
  row; a drawn boost is a real catalogue entry; level 0 is an exact no-op)
- conventions: values in `config/game_config.tres`
- why this task: it is the narrowest real "one authored row, two registries must agree" change in the
  repo, and both registries fail SILENTLY when they disagree

---

### T011 — "Also show the gap to the car behind me, not just the one ahead." — RETIRED

> **RETIRED: unrunnable.** This task's whole subject — the multiplayer lobby
> (`scripts/multiplayer/`, `LobbyStandings.gap_ms`, `features/multiplayer-lobby.md`)
> — has been deleted from the project. The round records below are kept as history;
> do not dispatch this task. See `todo/roguelike-pivot.md`.
- status: live  (**authored round 026**)
- clean_solves: 0  (never probed)
- AUTHORED ROUND 026, and why: after 25 rounds the bank had **no task at all** in the
  multiplayer, cloud-save or challenge subsystems — ~4,100 lines across `scripts/cloud/` and
  `scripts/multiplayer/` with 17 dedicated test files and three feature docs, entirely unmeasured.
  Round 025 concluded the loop's remaining value is **breadth, not depth**, so this is the
  replenishment (§1) into the largest unprobed area.
- GROUNDED IN (read, not guessed): `scripts/multiplayer/lobby_field.gd::readout_for` (line ~205)
  computes exactly ONE gap — to the **chaser** when `place == 1`, otherwise to the car **ahead** —
  and hands four values to `Hud.show_position(position, field, gap_ms, leading)`
  (`scripts/hud.gd:801`). So "the gap behind" genuinely does not exist for a non-leader.
- expected_files: **`scripts/live_standings.gd`** (`standing()` — the SINGLE-PLAYER owner, and where a
  normal rally's HUD gap actually comes from; **added round 026 — my original rubric missed it and the
  probe found it**), `scripts/multiplayer/lobby_field.gd` (`readout_for`, the pure seam), `scripts/hud.gd`
  (`show_position` / the gap label), and `scripts/stage_manager.gd` if the HUD method list changes
- **RUBRIC NOTE round 026 (3/1/2/3, first probe).** Navigation was **better than this rubric**: it found
  both standings owners, the HUD, the stage-manager call site, updated `test_hud.gd`'s call sites and
  `features/hud.md`. **Prediction refuted in a useful way: it got the behind-gap DIVISOR right**
  (`behind.speed_mms`, with the same `maxi(...,1)` guard as its neighbour) purely from the adjacent
  asymmetric code — no note states that rule. Two defects: (a) it widened `show_position` to 5 args and
  missed `StubHud` in `test_stage_manager.gd:44`, so `_hud_can`'s `has_method` gate stayed green and two
  tests died on the call — **now guarded** by
  `test_script_breadcrumbs.gd -> test_stub_hud_matches_the_real_hud_signature_for_every_duck_typed_method`;
  (b) a silent off-by-one in `live_standings.gd` (`ahead + 1 < times.size()` where the car behind is
  `times[ahead]`, valid iff `ahead < times.size()`), so a player with exactly one rival behind gets no
  behind-gap. **Grade down both.**
- **RUBRIC NOTE round 029 (3/1/1/3).** Round 026's off-by-one is **fixed** (`ahead < times.size()`), and
  navigation held at 3 across five files. But it **again widened `show_position` and again missed `StubHud`** —
  this time round 026's guard caught it by name, and `test_stage_manager` produced no `Totals` at all because its
  run died on the debugger break, which vindicated moving that guard into a source-scanning file.
  **Docs 0 of 2**, despite every edited file carrying a `# Docs:` breadcrumb naming both required docs between
  them — the strongest breadcrumb condition available. Also declared an unused `var _gap_behind_label`.
  **This task is the loop's clearest evidence that doc compliance tracks CODE-CHANGE SIZE rather than how the
  docs are pointed at** (5 scripts -> 1 doc in round 026; 4 scripts + a test -> 0 in round 029).
- expected_docs: `features/multiplayer-lobby.md`, `features/hud.md`
- expected_tests: `lobby_field`, `lobby_standings`, `hud`, `stage_manager`
- test_conventions: never pin a gap in seconds, a label position or a font size — those are tunables
  or authored layout. Test the LOGIC: a behind-gap is >= 0; a racer alone in the field has no behind-gap;
  the conversion is metres/(mm/s) so a slower chaser yields a LARGER gap. `readout_for` is documented as
  "Pure so the test can pin the gap conversion without a scene" — so a test needs no scene.
- conventions: reuse `LobbyStandings.gap_ms`, never re-derive the conversion; any new label
  position/size belongs in `config/game_config.tres`
- HIDDEN TRAPS (all real, all already documented in-file — this task measures whether those notes work):
  1. **THE UNITS TRAP.** `lobby_standings.gd:8-13` warns in a dedicated UNITS block: `progress_m` is
     metres, `speed_mms` is millimetres/second, so metres -> milliseconds is `* 1_000_000 / speed_mms`,
     "NOT the intuitive `* 1000`", and "a 1000x slip here still looks almost right on a slow car, which
     is exactly why it would ship." **Grade down any answer that re-derives the conversion instead of
     calling `LobbyStandings.gap_ms`.**
  2. **WHICH speed divides.** The existing code is asymmetric on purpose: the leading branch divides by
     the CHASER's `speed_mms`, the trailing branch by MINE (`maxi(..., 1)`). A behind-gap must divide by
     the **car behind's** speed, and must guard a zero speed as the existing branches do.
  3. **`_hud_can` does not check ARITY.** `stage_manager.gd:88-93` builds `_hud_can` from
     `has_method(m)` alone, so widening `show_position`'s signature leaves the guard green and breaks the
     CALL at runtime instead. A probe that changes the signature must update `stage_manager.gd:404` and
     `lobby_field.gd:232` too.
  4. `MAX_GAP_MS` (an hour) is the sanctioned ceiling for an unknowable gap — a stopped car behind must
     not produce an unbounded number.
- why this task: the first bank task in the multiplayer subsystem, and it crosses a pure-logic seam, a
  duck-typed HUD boundary with no arity checking, and a documented arithmetic trap whose whole point is
  that getting it wrong still looks plausible.

### T012 — "On the account screen, show which device my cloud save last came from, not just when."
- status: live  (**authored round 027**)
- clean_solves: 0  (never probed)
- AUTHORED ROUND 027, and why: round 026's replenishment into `scripts/multiplayer/` found a new unguarded
  defect class on its FIRST probe, so round 026 recommended continuing into the other never-probed
  subsystems. **Cloud save is the largest of them** (~2,900 lines in `scripts/cloud/`, 6 dedicated test
  files) and no bank task has ever touched it.
- GROUNDED IN (read, not guessed):
  - `cloud_sync.gd:214-215` — `push()` writes the document with
    `to_document(..., stamp, FirebaseConfig.device_tag())`, so the device tag **is already stored**.
  - `cloud_sync.gd:~380` — `from_document` reads `device` back out.
  - `cloud_sync.gd:284` — it is surfaced in **exactly one place**, `conflict_summary()`'s `cloud_device`,
    i.e. **only during a conflict**.
  - `account_menu.gd:153-161` — the normal screen shows `"Last synced %s UTC"` off
    `Cloud.sync.last_sync_utc` and says **nothing** about the device.
  - `cloud_sync.gd:45,228,342` — `last_sync_utc` is a plain field on the sync node, assigned at **two**
    sites: after a successful push (228) and after applying a remote profile (342).
  So the data exists end to end and is simply never shown outside a conflict.
- expected_files: `scripts/cloud/cloud_sync.gd` (a `last_sync_device` alongside `last_sync_utc`),
  `scripts/account_menu.gd` (the readout)
- expected_docs: `features/cloud-save.md`; `features/menus.md` only if the screen's structure changes
- expected_tests: `cloud_sync`, `cloud_auth`, `account_menu`, `menu_flow`
- test_conventions: never assert a device NAME or a formatted timestamp (both are environment-dependent —
  `FirebaseConfig.device_tag()` differs per platform). Test the LOGIC: the field is set by the same paths
  that set `last_sync_utc`, and the screen renders without it when it is empty.
- conventions: keyboard + gamepad navigability applies to FOCUSABLES. `account_menu.gd` uses
  `MenuNav.attach`, and a plain `_sub()` label is not focusable — **so a read-only readout needs no nav
  test, and a grader must not demand one.** If the answer adds a BUTTON, the nav test is required.
- HIDDEN TRAPS (all real, all already documented in-file):
  1. **DO NOT BRANCH ON THE TIMESTAMP.** `cloud_sync.gd:10-17` explains at length why ordering uses a
     revision counter and not wall-clock time ("a phone and a desktop routinely disagree, and a device with
     a wrong clock would silently eat the other device's career") and ends: "**updated_utc is stored purely
     so the conflict prompt can say '2 hours ago'; nothing branches on it.**" An answer that gates the
     device readout on timestamp freshness, or compares timestamps to decide anything, has violated the
     module's central design rule. **Grade that down hard.**
  2. **THE TWO-SITE SYMMETRY.** `last_sync_utc` is assigned in **both** the push path (228) and the
     apply-remote path (342). A `last_sync_device` set in only one of them goes stale or blank after the
     other — the same one-directional-fix shape round 020 recorded. **Grade down an answer that updates one
     site.** Note the two sites need DIFFERENT values: after a push it is THIS device; after applying a
     remote it is the device named in the remote document.
  3. **Settings are deliberately not published** (`blob.erase("settings")` at :213, with the reason in
     comment). An answer must not smuggle device-local state into the published blob.
- why this task: the first bank task in cloud save. It is small in code and rich in traps, and every trap
  is a rule the module already states in prose — so it measures whether a strongly-worded design rationale
  actually reaches a small model, which is the loop's central question.
- **RUBRIC NOTE round 027 (3/2/1/3, first probe).** Traps 1 and 2 both **held**: it did not branch on
  `updated_utc` (the header's emphatic rule reached it), and it set `last_sync_device` in **both** the push
  and apply-remote paths with the correct different values — refuting my prediction, because `last_sync_utc`
  is already handled correctly in both places (the "adjacent correct sibling" lever, n=2 with round 026).
  Defects: (a) it moved the `" UTC"` suffix after the device clause, so the row reads
  `"…:45 · from macos UTC"` — the unit label now appears to qualify the device; (b) 0 of 1 docs; (c) it wrote
  "three halves of the same answer" into a comment. **Round 027 then found and fixed the reason for (b):
  `test_script_breadcrumbs.gd` scanned only the TOP level of `scripts/`, so all of `scripts/cloud/` was
  unguarded and 12 of 13 files — including `cloud_sync.gd` — had no `# Docs:` breadcrumb at all.** Scan is
  now recursive and the 12 breadcrumbs added, so a re-probe measures whether a named doc changes the outcome.
- **RUBRIC NOTE round 028 (3/3/2/3 — best yet; the breadcrumb WORKED).** With
  `# Docs: features/cloud-save.md` now in `cloud_sync.gd`'s header, the probe **updated the doc** (0/1 -> 1/1),
  correcting the exact example row its change falsified. Attribution is clean: `account_menu.gd` is still on
  `BREADCRUMB_BASELINE` with no breadcrumb, so the only pointer in play was the new one. It also set
  `last_device_name` in **both** sync paths with the correct different values (second consecutive probe to do
  so — the adjacent-`last_sync_utc` sibling teaches it), did not branch on `updated_utc`, and kept `"UTC"`
  attached to the timestamp (fixing round 027's wart). **One defect: it documented the screen as showing
  "from iPhone" and commented `e.g. "iPhone", "Desktop"` — values `FirebaseConfig.device_tag()` cannot return
  (it yields "web" or `OS.get_name().to_lower()`).** Round 028 documented the exact value set at `device_tag()`.
  **Grade down any answer that invents a friendly device label.**

### T013 — "Add a confirmation before starting the daily challenge, since you only get one attempt."
- status: live  (**authored round 031**)
- clean_solves: 0  (never probed; round 031's first dispatch was VOID — see below)
- **WORDING CORRECTED round 031, and this is a rule for authoring future tasks.** The task first read
  *"Warn me that the daily challenge is only one attempt before I start it."* A probe read that as an
  instruction **to itself** — a request to warn the user — replied asking what to implement, and made zero tool
  calls. **My authoring error, not a codebase signal, and the dispatch was voided rather than scored.**
  Every other task in the bank opens with a verb about the GAME ("Add", "Show", "Make", "Track", "Play",
  "Give"); this was the only one phrased in the second person at the reader. **Author task text so it cannot
  parse as an instruction to the assistant** — bare-prompt probes have no framing to disambiguate it.
- AUTHORED ROUND 031, and why: the **rally challenge was the last subsystem with no bank task**. Round 027
  investigated it and rejected it for having no dangling seam — correct at the time, but T011 and T012 show a
  plausible ADDITION works just as well, so this is that. Multiplayer (T011), cloud save (T012) and now the
  challenge are all covered; the bank finally spans every major subsystem.
- GROUNDED IN (read, not guessed):
  - `challenge_session.gd:218` — "One attempt per period. A finished run — completed OR DNF'd — is terminal until"
    the period rolls; :305 and :510 restate it ("neither can be started again", "a period cannot be re-farmed").
    It is a load-bearing product rule, documented three times **in code**.
  - **Nothing tells the player.** `grep -niE 'one attempt|no retry|are you sure|confirm' scripts/hq_challenge.gd`
    finds only a code comment at :374. There is no warning anywhere in the UI.
  - `hq_challenge.gd:516` — `ChallengeSession.start(...)` is the commit point, reached from the car-park
    selection; :416 notes `_begin_challenge_start` "does the actual ChallengeSession.start + scene hand-off".
- expected_files: `scripts/hq_challenge.gd` (a confirm step before the `ChallengeSession.start` commit)
- expected_docs: `features/rally-challenge.md`; `features/modals.md` if the modal's own behaviour changes
- expected_tests: `challenge_session`, `menu_flow`, `hq_multiplayer` is NOT relevant — use `challenge_run_end`
  and `modals` instead
- test_conventions: never assert the warning's wording (copy is not a contract); assert the LOGIC — that
  `ChallengeSession.start` is not reached until the player confirms, and that dismissing leaves no run active
  (`is_active()` false)
- conventions: keyboard + gamepad navigable — but see the trap below, this is **inherited** if the answer reuses
  `ConfirmPopup`, whose header says it is already "MenuNav-wired (keyboard + gamepad)"
- HIDDEN TRAPS:
  1. **THERE IS AN ADJACENT CORRECT SIBLING, AND THIS TASK EXISTS PARTLY TO MEASURE WHETHER IT IS USED.**
     `ConfirmPopup.open(host, title, body, actions, …)` (`scripts/confirm_popup.gd:62`) is the reusable on-brand
     modal, already MenuNav-wired, with a `MODAL_GROUP` and `any_open()` so two modals cannot stack. And
     `hq_carpark.gd` already uses it for the detune confirm **in the same HQ subsystem** — its comment at :614
     names "the two bugs that hand-rolling this cost (an invisible modal in world-menu mode, and a 3D panel
     eating its clicks)". **Grade down hard any answer that hand-rolls a panel instead of calling
     `ConfirmPopup`.** The adjacent-sibling lever is 4-for-4 in this loop; this is a fair test of it.
  2. **The warning must gate the COMMIT, not the navigation.** `ChallengeSession.start` is what spends the
     attempt. A confirm placed anywhere earlier (e.g. on entering the challenge screen) warns without protecting
     anything, and a player who backs out after confirming must still have spent nothing.
  3. **Do not change the one-attempt rule itself.** The task is to *warn*, not to add a retry. An answer that
     makes the run resumable or non-terminal has changed a product decision it was not asked to change.
  4. `ConfirmPopup.any_open(tree)` exists because the HQ can already have a modal up; a second one must not stack.
- why this task: the last uncovered subsystem, and it is the cleanest available test of the loop's
  best-supported lever — a correct sibling doing exactly this, in the same subsystem, versus a hand-rolled panel
  whose failure modes are already written down.
- **RUBRIC NOTE round 031 (3/1/1/2, first scored probe).** **Trap 1 held perfectly:** it reused
  `ConfirmPopup.open` and matched `hq_carpark.gd`'s call shape exactly, including `], 1, 0)` and the no-op
  `Callable()` Cancel — the sibling lever's 5th consecutive success and the first with the sibling in a DIFFERENT
  FILE. **Trap 2 fired:** it added TWO confirms, one on the entry-overlay Start (pure navigation — spends nothing)
  and one at the car-park commit, so the player is asked twice and `test_menu_flow` reddens on
  "Start opens the challenge car park, not a direct commit". **NOT a frozen assertion** — that test pins
  navigation behaviour this task has no business changing; do not relax it. **Plus a silent touch-only dead end:**
  both handlers clear `_pending_challenge_start` before calling `_hq._start_preflight(<self>)`, whose `resume` may
  fire much later, so the retry hits their own `is_empty(): return` and the challenge never starts. Round 031
  documented that contract at `_start_preflight`, naming the `.bind()` pattern the free-roam caller uses.
  **Grade down: a confirm on navigation rather than the commit, and state cleared before a deferred resume.**
- **RUBRIC NOTE round 032 (3/3/1/3 — best result; both round-031 fixes WORKED) AND THE TASK IS NOW MARKED
  HARNESS-LIMITED ON CORRECTNESS.** The probe put ONE confirm at `_begin_challenge_start` and cited this round's
  new label in its report ("at the exact point where the attempt is spent, as noted in the existing code
  comments"); it avoided the deferred-resume dead end by setting its state **after** `_start_preflight` rather than
  binding — cleaner than the `.bind()` pattern the note recommends; and it reused `ConfirmPopup` with the sibling's
  exact call shape for the 6th consecutive time. Docs 0 of 1 (and `features/menus.md`, which this file's breadcrumb
  DOES name, was also untouched).
  **BUT `test_menu_flow` reddens in six places on a FROZEN ASSERTION I failed to check for when authoring:**
  `hq._on_start_pressed(); assert_true(ChallengeSession.is_active(), "committing the car park begins a
  ChallengeSession run")` pins the commit as immediate, so **no** confirmation can be added without breaking it.
  Unlike T008's freeze (one relaxable equality), these tests would have to DRIVE a dialog that does not exist in
  main, so they cannot be pre-adapted. **The reds are EXCUSED — score correctness on the implementation — and no
  future round should chase a clean solve here.**

### T014 — "On the region list, tell me how many stages each region can offer before it starts repeating."
- status: **live — RE-AUTHORED in stage 9 of the roguelike pivot.**
- clean_solves: **0**
- **WHAT THIS REPLACED.** T014 was "When I open the full map with M, show how many stars I've earned
  on the rally pin I've highlighted." The full map (`overworld_map.gd`), the pins and the star ledger
  are all deleted. History in `evals/small-model/rounds/`.
- **WHAT IT MEASURES NOW.** A read-only addition to `HubShell`'s REGION page, sourced from
  `RegionStagePool.pool_size(region_id)` — which already exists and already answers exactly this. The
  interesting part is not the arithmetic; it is that the probe must (a) find the existing query rather
  than re-flattening `RallyLibrary` itself, (b) put the number on the row without breaking the page's
  navigation contract, and (c) leave the LOCKED rows' `menu_nav_skip` intact.
- **THE TRAP TO GRADE ON.** `MenuNav.attach` runs AFTER the page is built and re-enables focus on
  every `BaseButton` it finds. A probe that turns a row into a `Label` to show a number, or that sets
  `focus_mode` without the `menu_nav_skip` meta, breaks keyboard navigation — and CLAUDE.md makes that
  a hard requirement with a nav test attached. `test_hub_shell.gd` walks every view and asserts each
  has at least one focusable control, so a wholesale conversion should redden; a subtler break (a
  locked row becoming focusable) may not, and is a correctness call.
- **ALSO GRADE:** decision 32's pool floor is 16 events per region. A probe that discovers a region
  under the floor while doing this should report it, not silently paper over it.
- areas: menus, regions, run loop
- expected_files: `scripts/hub_shell.gd` (`_build_region`)
- expected_docs: `features/hub-shell.md`, `features/region-runs.md`
- expected_tests: `hub_shell`
- test_conventions: no asserting a particular region's pool size (authored data); assert the row
  reports what `RegionStagePool.pool_size` returns, and that navigation still holds
- conventions: no new persisted state — this is derived, not stored
- why this task: the flat shell's pages are where a small model is most likely to break the
  keyboard/gamepad contract, because the break is invisible without a controller

---

### T015 — "Let me sell a car I don't want any more and get some money back."
- status: **live — RE-AUTHORED in stage 9 of the roguelike pivot.**
- clean_solves: **0**
- **WHAT THIS REPLACED.** T015 was "On the overworld map, make it easy to see at a glance which
  rallies I've already won." The overworld is deleted. History in `evals/small-model/rounds/`.
- **WHAT IT MEASURES NOW — a real economy mutator, which is the shape the bank was missing.** Selling
  is the inverse of `Save.buy_car`, and the repo has a written house rule for exactly this class of
  change: **every meta-shop refusal leaves the profile byte-identical** — every precondition is
  checked BEFORE `spend_money`/`add_money`, so a caller never half-mutates into a rejected purchase.
  `buy_car`, `buy_boost_level`, `buy_engine_swap_unlock`, `buy_perk` and `buy_drive_mode` all follow
  it; a `sell_car` that does not is wrong even if it "works".
- **THE TRAPS TO GRADE ON**, none of which any test currently catches:
  1. **Selling the car in an active run.** `RunSession.car_instance_id()` is the fielded car; selling
     it mid-run strands the session. A correct answer refuses, or there must be no way to reach the
     action during a run.
  2. **Selling the LAST car.** A profile with no cars and not enough money to buy one is a dead end —
     decision 28's whole point is that the shop is always reachable.
  3. **`selected_instance_id`** points at the sold car afterwards.
  4. **The refund price.** `CarLibrary`'s `cost` is authored data; a refund fraction is a tunable and
     belongs in `config/game_config.tres`, not as a literal.
- **A PROBE THAT ASKS RATHER THAN GUESSES** on the refund fraction, or that reports trap 2 instead of
  silently allowing it, should score WELL on judgment even if it ships less code.
- areas: save/profile, economy, menus
- expected_files: `scripts/save_manager.gd` (the mutator), `scripts/hub_shell.gd` (the CAR page row),
  `scripts/game_config.gd` + `config/game_config.tres` (the refund fraction)
- expected_docs: `features/save-persistence.md`, `features/region-runs.md` (the meta tier),
  `features/hub-shell.md`
- expected_tests: `save_manager`, `hub_shell`
- test_conventions: no asserting the refund fraction or any car's cost; assert the RULE (a refused
  sale leaves the profile byte-identical; money goes up by the same amount the car left for)
- conventions: values in `config/game_config.tres`; the byte-identical-refusal rule
- why this task: it is the first task in the bank that ADDS money rather than spending it, and the
  failure modes are all state-consistency ones that a passing test suite would not catch

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
- status: **live — RESHAPED in stage 9 of the roguelike pivot. The request is unchanged; the
  obligations are not.**
- **WHAT A CORRECT ANSWER NOW OWES, on top of everything in the notes below.** The region system
  survived the pivot but gained a progression, so the old "two edits" answer is no longer complete:
  1. **An `order` field** on the `REGIONS` entry. Regions unlock LINEARLY (decision 12) — order 0 is
     always open, every other is gated on the one before it being cleared. Array position carries no
     meaning; `RegionLibrary.ordered()` reads the field. A region with no `order`, or one colliding
     with an existing region's, breaks the unlock chain.
  2. **Sixteen authored events, not one rally.** Decision 32 sets a pool floor of 16 per region so a
     run of 8 stages can be played twice without repeats (`RegionStagePool.pool_size`). The old
     rubric's "add at least one rally tagged with the region" made it REACHABLE; it no longer makes
     it PLAYABLE. A probe that authors a handful and says so is being honest about scope and should
     be graded on that, not marked down to zero.
  3. **The map is gone.** `map_pos` is still authored on every rally and is still guarded for
     well-formedness, but nothing reads it — so `RallyLibrary.suggest_map_pos()` is still the way to
     get a legal value, and it is no longer the interesting part of the task.
- **THE ROUND-018 RUBRIC AMBIGUITY IS RESOLVED: option (a).** `look_from` + an own sky + own scatter
  PARAMETERS satisfies "its own skybox and scatter set". `region_library.gd`'s documented idiom is to
  author `look_from` and then only the keys that DIFFER, and grading a probe down for following the
  codebase's own convention measures the rubric, not the repo. Round 018 therefore scores 3/3/3/3 in
  retrospect — but it is not carried forward as a clean solve, because the obligations above did not
  exist when it was graded.
- clean_solves: **0** (reset by the reshape)
- PRIOR SCORES (against the pre-pivot obligations): rounds 002-003, 009, 010 non-clean;
  **round 018 = 3/2/3/3, the best ever** — see the resolution above.
- **RUBRIC NOTE round 018 (3/2/3/3 — by far the best result this task has had; previous best
  3/1/1/2).** The probe did **all three mandatory sites unaided**: a `badlands` region with
  `look_from: "greece"` and **its own** `sky_panorama` (`sky-night.jpg` — the one unused sky in the
  repo), a genuinely NEW rally tagged `"region": "badlands"` (it did not retag an existing one), and
  a thorough `features/regions.md` update including the count claim its change falsified. Verified
  by hand: the asset exists, `rock_density` is a real key, `"night"` is a real weather id, and
  `map_pos` is 0.0582 from its nearest of 39 pins (limit 0.03). **Every guard that reddened in
  rounds 009/010 passed.** So round 010's "four parts is too much for one Haiku attempt" is refuted.
- **RUBRIC AMBIGUITY THIS TASK MUST RESOLVE (round 018), and it is the reason the correctness score
  is contestable.** The request says "its own skybox **and scatter set**". The probe authored its own
  sky but **inherited Greece's `tree_mix`/`spawn_bush_mesh`** via `look_from`, overriding only
  `rock_density`. Round 009's precedent treats an inherited look as a shortfall — **but
  `region_library.gd`'s own documented idiom actively instructs the opposite**: "author
  `look_from: "<other_region_id>"` and then only the keys that DIFFER — that is this file's idiom."
  **Grading a probe down for following the codebase's own convention measures the RUBRIC, not the
  repo.** Decide which the task wants and say so here, rather than re-litigating it every round:
  either (a) accept `look_from` + an own sky + own scatter *parameters* as satisfying the request —
  in which case round 018 scores 3/3/3/3 and this task is SOLVED once and needs a second consecutive
  clean solve to retire; or (b) require an authored `tree_mix` of its own, in which case the task
  wording should say "its own tree mix" explicitly, because "scatter set" does not obviously exclude
  inheriting one. **Flagged for the user: this is a product/eval-design call, not mine to take
  unilaterally, and it decides whether the bank's hardest task is now solved.**
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
- expected_files: `scripts/region_library.gd` (the `REGIONS` table, including `order`),
  `scripts/rally_library.gd` (the `region` tag on enough events to fill the pool), plus whatever the
  region's surface/water/scatter hooks require
- expected_docs: `features/regions.md`, `features/terrain.md`, `features/region-runs.md`
- expected_tests: `region_library`, `region_assets`, `region_docs`, `terrain`, `region_stage_pool`
- test_conventions: no asserting a specific region exists or its authored values;
  test the contract (`by_id` round-trips, `count()` consistent, grip lookups finite)
- conventions: values in `config/game_config.tres`
- why this task: `region_library.gd` has a wide static surface
  (`surface_grip_of`, `deep_snow_of`, `water_level_of`) and touches
  `terrain_manager.gd` (2895 lines) — a real coupling test

### T004 — "Show the current gear on the HUD."
- status: live
- clean_solves: **1**  (rounds 002, 005, 006 non-clean; round 007 3/3/1/2; round 023 = 3/3/3/3 clean;
  **round 044 drill: attempt 1 = 3/3/2/3, attempt 2 = 3/2/2/3, attempt 3 = 3/3/3/3 — PASSED at
  attempt 3.** The non-clean attempts reset the counter per §1, then the clean attempt-3 solve set it
  back to 1 — the round-023 solve is no longer consecutive with anything. One clean FIRST-attempt solve
  in a future sampled round retires it.)
- **RUBRIC NOTE round 044:** three general fixes landed off this task: (1) `test_hud_docs.gd`'s
  membership parser was VACUOUS (stopped at the `]` in `Array[StringName]`, parsed empty, all guards
  passed trivially) — fixed, empty parse now fails; (2) the transcription guard now also matches prose
  word forms (speed/rpm/…), and a new inverse-direction test rejects docs calling an un-gated label
  hidden; (3) `features/hud.md` gating prose is per-membership ("every label named in the constant is
  hidden…") so a membership move needs NO doc edit, and the constant carries a per-label caution
  (attempt 2's probe un-gated speed+RPM along with gear — scope overreach). Grade future attempts
  accordingly: no doc edit to the gating paragraph is CORRECT; any extra label moved is a correctness
  failure.
- **RUBRIC NOTE round 023 — CLEAN SOLVE (3/3/3/3).** One-line `DEBUG_READOUT_NODES` membership edit,
  `features/hud.md` given a Visibility column plus prose fixes, **and `features/debug-tools.md` updated
  unprompted** (three falsified statements found there — it is not in `expected_docs`). No test edit
  needed: round 008's membership-driven tests iterate the constant and adapted themselves.
  I additionally verified two things tests could not catch: the gear text still updates (line 601 is
  unconditional; `_gear_label` resolves via `@onready`, not via the array), and the label is not visually
  stranded (absolutely positioned at (8,28), so it sits top-left rather than orphaned) — and it correctly
  introduced no hardcoded layout value.
- **RUBRIC NOTE round 023 — THE ROUND-006/007 NOTES BELOW ARE STALE ON THE TEST OBLIGATION.**
  `test_gear_label_is_part_of_the_h_gated_debug_readout` **no longer exists**: round 008 deleted the
  per-element membership tests deliberately (see the eighteen-line explanation in
  `tests/headless/test_hud.gd`) because they pinned a product choice and falsified
  `DEBUG_READOUT_NODES`' own "one-line edit" promise. The contract is now covered by two
  **membership-driven** tests that iterate the constant and need no edit when it changes, and the doc is
  guarded by `test_hud_docs.gd`. **So a correct answer today is a one-line membership edit plus
  `features/hud.md` — do NOT expect or require any test edit.** This is the leanest obligation set in
  the bank.
- RUBRIC NOTE round 007 (**test half superseded above**): **SOLVED on correctness (3/3/1/2) — the structural fix worked.**
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

### T005 — "Keep track of my best single-stage time and show it with my other stats."
- status: **live — RE-AUTHORED in stage 9 of the roguelike pivot.**
- clean_solves: **0**
- **WHAT THIS REPLACED.** T005 was "Track how many rallies the player has finished and show it on the
  profile", whose whole point (rounds 006-014) was that **"profile" had no UI referent** and that
  `record_podium_rally` counted PODIUMS, not finishes. Both the career rally and the podium gate are
  deleted. History in `evals/small-model/rounds/`.
- **WHAT IT MEASURES NOW — the same "find the one registry" shape, with the referent now real.**
  `LifetimeStats` (`scripts/lifetime_stats.gd`) is a single authored `STATS` dict, and its header
  states the rule: adding a stat is a one-place change (a `const` id, a `label`, a `description`, an
  entry in `IDS`) and **the writer must be wired in the same change** — a declared-but-unwritten stat
  is a Stats-page row pinned at zero forever, which reads as a broken counter. `distance_driven_m`
  shipped that way in stage 7 and was fixed in stage 9; the rule exists because of it.
- **THE TRAP TO GRADE ON — this is a RATCHET, not a sum.** `Save.add_lifetime_stat` accumulates;
  `Save.raise_lifetime_stat` takes `max(current, value)`. A best TIME is neither: it is a
  **minimum**, and the ledger's own invariant is "only ever grows". A probe must notice the conflict
  and resolve it (store a negated/derived value, or add a third mutator, or store it outside the
  ledger) rather than calling `add_lifetime_stat` and producing a running total of every stage time —
  which is what a fast reading gives. **This is the single thing to grade correctness on.**
- **ALSO GRADE:** the write site. `RunSession.report_event_result` receives `elapsed_ms` and already
  writes four lifetime stats; a probe that instead reaches into `world.gd` or the HUD has not found
  the funnel. And the Stats page (`HubShell._build_stats`) iterates `LifetimeStats.IDS`, so it needs
  NO edit — a probe that hand-adds a row there has missed the registry's point.
- areas: save/profile, run loop, menus
- expected_files: `scripts/lifetime_stats.gd`, `scripts/run_session.gd` (the writer),
  `scripts/save_manager.gd` only if a new mutator is genuinely needed
- expected_docs: `features/lifetime-stats.md`
- expected_tests: `lifetime_stats`, `region_run`
- test_conventions: no asserting a threshold or a shipped label; assert the RULE (the value moves the
  right way, and never the wrong way, when a faster/slower stage is reported)
- conventions: one registry, no parallel id list
- why this task: `LifetimeStats` is the cleanest single-registry contract in the repo, and this
  request quietly violates its central invariant — a probe that ships without noticing has told you
  something specific about what it reads

---

### T006 — "Make the engine braking stronger when you lift off the throttle."
- status: live
- clean_solves: 0  (rounds 001, 002, 005, 009 non-clean; round 010 best yet at 3/3/2/2;
  **round 021 = 3/1/2/3, a REGRESSION — a real red, see below**)
- **RUBRIC NOTE round 021 (3/1/2/3).** The probe found everything earlier rounds fixed — `is_lifting_off()`,
  the globally-live knob rather than the overwritten `engine_friction_base`, a `GameConfig` `@export`
  rather than a literal — reasoned correctly about fuel cut, mid-shift, declutch, rev-limiter bounce and
  the turbo/supercharger drags, and chose a magnitude that would actually be felt (1.5x the whole FMEP
  term). **It still reddened `test_drivetrain -> test_brake_lockup` ("rear axle locked"): main is 33/33,
  its tree 32/33.** NOT a frozen assertion — that test asserts real braking physics and must not be
  relaxed. **Cause: `is_lifting_off()` is TRUE while BRAKING**, so a multiplier gated on it rescales
  engine drag during every brake application. Its own docstring said "coasting", which is the reading
  that caused it; round 021 rewrote that comment to say plainly that braking is included, name the
  consequence, and name `test_brake_lockup` as the guard. **Grade down any answer that gates lift-off
  drag on `is_lifting_off` without addressing braking.**
  Round 021 also added a numbered procedure at the knob site whose part 3 carries a **paste-able
  behavioural-test skeleton** — the loop's first attempt at moving a TEST obligation (see round 021's
  report; round 008 concluded no note could).
- **RUBRIC NOTE round 022 (3/3/2/3 — best result this task has had). Both round-021 fixes measured:**
  **(A) the `is_lifting_off` brake warning WORKED.** The probe's report quotes it back — "it strengthens
  engine braking during both throttle lift-off AND foot braking (since `is_lifting_off()` is true while
  braking)" — and, knowing it, **scoped the change** to a `friction_effective` local used only for
  `crank`, leaving `friction` untouched for other consumers. `test_drivetrain` 33/33 green at gain **2.0**,
  where round 021's unscoped 1.5x reddened it. **(B) the paste-able test skeleton did NOT work — no test
  was written.** Convention gap here is now **test-only + `car-physics.md`**, i.e. harness-limited per
  §2.4; do not attack it with further notes (see round 022's verdict).
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
- clean_solves: 0  (round 003 non-clean; **round 030 = 3/3/2/3, best ever**)
- **RUBRIC NOTE round 030 (3/3/2/3 — first probe since round 003).** Correctness is **settled**: it wired the row
  through the existing `SpeedLinesSetting.apply()`, used `_make_action_button` (-> `_make_row_button`, which sets
  `focus_mode = FOCUS_ALL`, so the row IS keyboard/gamepad navigable — it avoided this repo's `FOCUS_NONE` trap by
  cloning the sibling helper), and put its refresher in the same group as `_refresh_fps_selection()` so the init
  ordering is right. It also fixed `speed_lines_setting.gd`'s own "menu row is deliberately NOT done here" note,
  which its change falsified. **Remaining: no NAV TEST** — a hard CLAUDE.md violation for a menu change, and the
  one task in the bank where the missing test is not merely a tail nicety — and `features/rendering.md` untouched
  **even though the probe edited the file whose breadcrumb names it** (by two comment lines). Docs 1 of 2.
  **Grade a future attempt primarily on the nav test.**
- **RUBRIC NOTE round 017 — THE TASK IS NOW HALF-IMPLEMENTED; the round-003 note below describes
  a failure that can no longer happen.** `scripts/speed_lines_setting.gd` (`SpeedLinesSetting`)
  now exists as a complete apply-owner — `SETTING_KEY`, the authored `GameConfig` default,
  `resolve()`, and a live `apply(tree, on)` that re-applies to every overlay in its group — and it
  says of itself: "adding the player-facing menu row is deliberately NOT done here; only the seam
  exists so far." `features/settings.md` names it as an exemplar beside `fps_setting.gd`.
  **Consequence: round 003's failure (source of truth as a static on `SettingsMenu`) is
  structurally impossible now, and the boot-reapply convention is already satisfied by the
  module.** What remains is the menu row calling `SpeedLinesSetting.apply()`, its nav test, and
  the docs — i.e. **convention-axis work only**, which §2.4 has shown is harness-limited. Grade
  accordingly: reaching for the existing module is the CORRECT answer and must not be marked down
  as "not implementing the setting".
  **This also disqualified T007 as round 017's A/B subject** — there is no unmet correctness
  convention left here to measure a note's position against.
- RUBRIC NOTE round 003 (**superseded above**): probe persisted + boot-applied correctly but OFF→ON mid-run
  is dead (speed_lines.gd _ready early-return with _mat unset — disabled treated as
  terminal), source of truth landed as a static on SettingsMenu instead of an
  apply-module (fps_setting/camera_manager shape), no docs/tests/nav test.
- areas: menus, settings, rendering
- expected_files: `scripts/settings_menu.gd` (the menu row), calling the EXISTING
  `scripts/speed_lines_setting.gd` (`SpeedLinesSetting.resolve()` / `.apply()`). The apply-owner
  module and the rendering site's `set_effect_enabled` seam already exist — a correct answer wires
  the row to them rather than reimplementing either.
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

### T008 — "Pay a bonus for finishing a stage without taking any damage."
- status: **live — RE-AUTHORED in stage 9 of the roguelike pivot.**
- clean_solves: **0**
- **WHAT THIS REPLACED, AND WHAT SURVIVED.** T008 was the same request paid in STARS. The star ledger
  is deleted (decision 21) and money replaced it, so the task is re-pointed rather than replaced —
  **and the trap that made it valuable is completely intact.** History in
  `evals/small-model/rounds/`.
- **THE TRAP, verbatim from `features/damage.md` and worth quoting to a grader.** *Never derive "did
  the player take damage" from the car's HP.* It is wrong in BOTH directions: the between-stage
  repair and the self-heal perk both raise HP after the fact, so a crashed car can read pristine; and
  a car routinely STARTS a stage below `max_hp` carrying damage in from an earlier one, so
  `hp < max_hp` at the finish may be none of this stage's doing and `hp >= max_hp` is simply
  unreachable for it. **A probe that compares `hp` to `max_hp` has failed correctness**, however
  clean the rest is. The deleted career session latched the fact instead
  (`_took_damage_this_rally`); the signal available today is `hp_lost > 0` where
  `RunSession.report_event_result` already sees it.
- **ALSO GRADE:** where the money is added. `RegionRunMode.stage_money` is the one place a stage's
  payout is computed and takes the arguments a bonus needs; adding money anywhere else bypasses the
  region scale and the fast-completion bonus and will not appear in `RunSession.money_earned()`.
  The amount is a tunable (`config/game_config.tres`), never a literal. And a challenge stage has no
  `stage_money` of its own — decide whether the bonus applies there and say so.
- areas: economy, damage, run loop
- expected_files: `scripts/region_run_mode.gd` (`stage_money`), `scripts/run_session.gd` (carrying
  the clean-stage signal to it), `scripts/game_config.gd` + `config/game_config.tres`
- expected_docs: `features/region-runs.md` (the money sources), `features/damage.md`
- expected_tests: `region_run`
- test_conventions: no asserting the bonus amount; assert that a stage reported with damage pays
  strictly less than the same stage reported without it
- why this task: it is the bank's best measurement of whether a probe READS the doc for the system it
  is touching — the trap is written down in plain words, in the file it would have to open anyway

---

### T009 — "Add a wet-weather tyre boost that grips better in the rain."
- status: **live — RE-POINTED in stage 9 of the roguelike pivot.**
- clean_solves: **0**
- **WHAT CHANGED.** The request is unchanged in substance; only its home moved. Tyre compounds were
  authored `UpgradeLibrary` parts and are now `BoostLibrary` entries running through the same
  `EFFECTS` funnel. Rounds 007-041's findings all still apply. History in
  `evals/small-model/rounds/`.
- **THE FOUR-SITE TRAP (round 041's finding — this task IS the reason `apply` push_errors).** A
  surface-dependent tyre axis needs FOUR edits, and the failure mode of missing the last one is
  invisible: (1) the `@export` on `GameConfig`, (2) a `TIRE_SURFACE_AXES` row so the blend knows
  about it, (3) the `_channel_weight` arm matching its siblings' contract, and (4) **an
  `UpgradeLibrary.EFFECTS` row for the effect key**. Round 041 shipped a wet tyre with (1), (2) and
  (3) all correct and **no rain grip at all**, because `apply` silently drops an effect key with no
  row. That is now a `push_error` plus a test — grade whether the probe's own run would have caught
  it.
- **ALSO GRADE:** there must be no `WeatherLibrary.is_wet()` predicate (round 007's finding, still
  true) — the probe has to decide what "in the rain" keys off, and inventing a clear one is a good
  answer, not a deviation.
- areas: upgrades, tyres, weather
- expected_files: `scripts/boost_library.gd` (`CATALOGUE`), `scripts/upgrade_library.gd` (`EFFECTS`),
  `scripts/game_config.gd` (`TIRE_SURFACE_AXES` + the `@export`), `config/game_config.tres`
- expected_docs: `features/drivetrain-and-tires.md`, `features/region-runs.md`
- expected_tests: `boost_library`, `upgrade_library`, `drivetrain`
- test_conventions: no asserting a grip magnitude; assert the axis behaves like its siblings (the
  blend weight is finite and sums correctly, the effect key resolves)
- conventions: values in `config/game_config.tres`
- why this task: it is the deepest registry chain left in the repo, and three of its four sites give
  no feedback when skipped

---

### T010 — "Play a beep on each count of the 3-2-1-GO countdown."
- status: live
- clean_solves: 0  (round 008 2/0/0/0, round 010 3/3/2/1, **round 025 3/2/1/3**)
- **RUBRIC NOTE round 025 (3/2/1/3).** Navigation is settled — the probe found `stage_manager.gd` (not
  `hud.gd`), called `Audio.play_beep()` rather than hand-rolling DSP, and pitched GO higher, all as the
  hook comment instructed. **Two new defects, both silent (five test files green):**
  (a) it keyed the beeps off **float threshold crossings**, so the "3" count is **never beeped** (the HUD
  already shows 3 before any threshold is crossed) and at zero a tick fires in the **same frame** as the
  1200 Hz GO cue — a doubled GO. Round 010's `_last_countdown_display` approach got this right, so it is
  a regression on reachable behaviour. **Grade down any answer keyed on crossings rather than on the
  displayed integer.**
  (b) **it DELETED the AUDIO HOOK comment** — the only place carrying the "never hand-roll DSP"
  prohibition (round 008's 2/0/0/0 failure), the `Audio`-autoload rationale, and the pointers to
  `features/sfx.md` / `todo/audio.md` — while three cues remain unwired. Round 025 rewrote it as a
  **standing AUDIO RULES block** that says it is not a TODO and must not be deleted, in numbered form,
  with the docs as part 3 and the display-integer rule as part 2.
  Docs: 0 of 2. `features/sfx.md` still claims the beep is "still unwired".
- **RUBRIC NOTE round 038 (3/2/1/3 — same score, strictly smaller defects; BOTH round-025 fixes held).**
  **The AUDIO RULES block SURVIVED** (1 block, 4 parts) where round 025's probe deleted the placeholder-phrased
  version — the self-preserving wording works, and the probe cited the rules by name. **It keyed off the displayed
  integer** (`ceili()` change detection), producing four correct cues with no silent "3" and no doubled GO.
  Two new, smaller defects: (a) `Audio.play_beep(800.0)` for GO commented "higher frequency", but
  `sfx_beep_frequency_hz` is **880.0**, so GO sounds LOWER than the ticks; (b) it reset its tracker at only **two of
  the three** countdown-arm sites, so re-arming through the third within the first second swallows the "3" cue.
  Round 038 fixed both at cause: the three arm sites are now one `_arm_countdown()` helper (structural), and part 1
  states the actual default so "higher" is checkable. **Docs 0 of 2 again despite part 3 naming both files as a
  numbered obligation — do not attempt a seventh docs wording; guard it.**
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
