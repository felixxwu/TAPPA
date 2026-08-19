# Small-model readiness — task bank

Real, user-phrased feature requests used to probe whether a Haiku-class model can
ship work in this repo unaided. **The rubric under each task is hidden from the
probe** — it sees only the quoted request line.

Authored round 001; rubrics augmented round 002. See `.claude/skills/small-model-readiness/SKILL.md` §1 for the
ratchet rules (retire after two consecutive clean solves; replenish harder).

---

### T001 — "Add a gravel-spec tyre upgrade to the catalogue."
- status: **live — RETIREMENT REVERSED in round 042 by §1's own ratchet.** Round 042 sampled it as the
  confirming probe for round 040's provisional retirement and scored **3/3/2/3 — not clean** (it introduced
  a slot member count into `upgrade-catalogue.md`, which `test_no_feature_doc_states_a_slot_member_count`
  rejects). §1 resets `clean_solves` to 0 on any non-clean attempt, so the two-consecutive-clean-solves
  condition is not met and the task returns to the live pool. This also DISPOSES of the round-041 doubt
  about round 021 without needing to resolve it: T001 is live either way.
- clean_solves: **0**  (round 040 clean, then round 042 non-clean -> reset. Earlier: rounds 001-003, 009
  non-clean; round 017 A/B control 3/2/0/3 + treatment 3/3/0/3; round 019 3/2/3/3; round 020 3/2/3/3;
  **round 021 3/3/3/3 — but see round 041: its `EFFECTS` row was never verified and cannot now be**)
- **RUBRIC NOTE round 021 — CLEAN SOLVE (3/3/3/3).** The probe authored a NEW surface axis and made all
  three round-004 registry edits (`@export tire_gravel_grip_mult`, the `TIRE_SURFACE_AXES` row, the
  `_channel_weight` "gravel" arm matching its siblings' contract), added the row, and made six
  substantive edits across BOTH docs — including the new axis's table row and the menu-label count.
  Effective grip: gravel_tires 1.183 gravel / 1.160 snow / 1.044 tarmac, giving a clean three-way split
  (gravel_tires wins gravel, snow_tires wins snow, race_tires wins tarmac) — **every row wins somewhere**,
  so the symmetric invariant added in round 020 held. It reproduced that win-table in its own code
  comment. `config/game_config.tres` correctly unchanged (new export's default = its authored value).
  All six relevant test files green. **The fix chain that got here: round 018 form (prose -> numbered
  procedure) -> round 019 mechanism -> invariant -> round 020 invariant stated symmetrically.**
- **RUBRIC NOTE round 019 — the note-FORM experiment WORKED on docs, and exposed the next layer.**
  Round 018 rebuilt this slot's note from a prose clause into a numbered procedure (parts 1-3, the
  half-done failure named, the guard named by test name). Doc compliance went **0/2 -> 2/2**: the probe
  updated `features/upgrade-catalogue.md` AND `features/drivetrain-and-tires.md` (three separate edits
  in the latter, including the enumerated compound sentence). It also authored three surface terms and
  gated on a REAL rally id (`sp_dust_trial`). **Remaining defect: the part is strictly dominated by
  `race_tires` on every surface** — gravel 1.12 vs race's 1.15 flat, snow 1.008, tarmac 0.896, so it
  wins nowhere and nobody would ever fit it. Round 009 recorded this same defect. Cause: the note
  specified the MECHANISM ("author surface terms") not the INVARIANT ("must beat every sibling
  somewhere") — three terms is satisfiable while still being a weaker rung. Round 019 rewrote part 1 to
  state the invariant and show the arithmetic. **Grade down any answer whose part wins on no surface.**
  Note also: a guard test for this is **forbidden** by CLAUDE.md (ordering relationships across
  authored entries), so the note is the only lever.
- **RUBRIC NOTE round 020 (3/2/3/3 — same score, DIFFERENT defect; the invariant fix WORKED).** The
  probe read round 019's invariant, **worked the arithmetic through in its own code comment**, and
  authored `1.20 / 0.88 snow / 0.98 tarmac` — winning on gravel (1.200) and tarmac (1.176). So
  "the new part must win somewhere" is now reliably achievable and docs held at 2/2.
  **The defect MIRRORED: `race_tires` now wins on NOTHING** (1.150 vs gravel's 1.200 and 1.176, vs
  snow's 1.296). The slot still has a dead part, just a different one. Cause: round 019's invariant was
  stated **one-directionally**; round 020 restated it symmetrically — (a) your part must win somewhere,
  (b) it must not take the last surface from a sibling, so the test is "EVERY row in this slot wins
  somewhere". **Grade down any answer that leaves any tyre row winning on no surface.**
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

### T011 — "Also show the gap to the car behind me, not just the one ahead."
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

### T014 — "When I open the full map with M, show how many stars I've earned on the rally pin I've highlighted."
- status: live  (**authored round 033; RE-AUTHORED round 045 — see below**)
- clean_solves: 0  (round 033's dispatches VOID — see below; **round 034 = 3/3/2/3, first scored probe**;
  **round 045 drill: two attempts 1/0/0/1 → 1/0/0/1, deliberate early stop at 2 — both probes concluded
  FALSE ALREADY-DONE from the in-world markers**, which genuinely satisfy a plain reading of the old
  wording)
- **RE-AUTHORED round 045.** Old wording ("On the overworld map … when I look at its pin") is satisfiable
  by the in-world marker star rows (`overworld_marker.gd::_apply_stars`), so two drill probes verified
  that surface and reported no work needed — even after round 045 planted a three-surface disambiguation
  note in `overworld_map.gd`, `overworld_marker.gd` and `features/map-exploration.md` (that note stays;
  it is true and serves T015). New wording pins the surface by the ACTION that opens it (M / full map).
  The re-authored task is unmeasured — probe it fresh before trusting any prior score. Round-033 rule
  extended: if two surfaces both satisfy the wording, the wording is the bug.
- **RETARGETED round 033, and the reason is an authoring rule.** The task first read "…when I look at its map
  pin", which is ambiguous between the **overworld** map and the **HQ's diegetic 3D map table**. The probe chose
  the HQ table — and `hq.gd::_build_readout_box(title, stars, unlock)` **already** builds a `StarRow` there, with
  the "-1 = unreached event" case handled. So the task asked for a feature that exists, and the probe added a
  redundant numeric label above the existing row rather than reporting it was already done.
  **My error: I grepped `overworld_map.gd` (genuinely has no star data) and never checked the other surface.**
  With round 017's T007 ("already half-implemented") that is two instances, so:
  **before authoring, enumerate EVERY surface the wording could mean and check each — a grep of the file you are
  thinking of proves nothing about the file you are not.**
  Now names the overworld map explicitly, where the readout genuinely does not exist and the ONE-NAME-ONLY trap
  lives. **Correctness/convention were VOID for that attempt** (the rubric assumed absence); navigation scored 3.
- **RUBRIC NOTE round 034 (3/3/2/3, first scored probe).** Traps 1, 2 and 4 all held: stars went in the **footer**
  (`_write_footer`) rather than on every pin, via `RallyLibrary.stars_for_placement(Save.best_placement(id))`, with
  non-rally pins guarded and a `stars > 0` guard so nothing renders when nothing was earned. Docs 1 of 2
  (`overworld.md` yes, `map-exploration.md` no); no test.
  **Trap 3 held in CODE but failed in PROSE:** it wrote `if placement > 0:  # Only show if the rally has been
  completed` — right code, wrong reason, since `best_placement` is podium-gated so `> 0` means PODIUMED. Round 034
  found the cause: rounds 015/016 warned on `rally_podiumed`/`podium_count`/`podium_rally_count` but **never on
  `best_placement()`**, the accessor a UI consumer actually reaches for. Warning added there.
  **NOTE FOR A FUTURE ROUND: this task cannot settle the "does a documented rationale generalise" question** — the
  footer is both the correct answer AND the obvious one, so the two explanations cannot separate. A real test needs
  a readout with no existing single-pin home.
- AUTHORED ROUND 033, applying round 032's authoring rule: **this task is ADDITIVE** (a new readout) rather than
  a change to tested behaviour, which is what made T002, T008 and T013 unwinnable-clean.
- **§2.5 FROZEN-ASSERTION CHECK RUN AT AUTHORING TIME (round 032's other lesson).** I grepped
  `tests/headless/test_overworld_map.gd` (49 tests) for draw-call, label-count and pin-visual assertions: **there
  are none.** Nothing pins what a pin draws, so an added readout cannot redden an existing test. The correctness
  axis is therefore scoreable — unlike the three behaviour-changing tasks.
- GROUNDED IN (read, not guessed):
  - `overworld_map.gd:1493` `_paint_pins` draws a glyph/icon, a route ring, a selection ring, and exactly one name.
  - `overworld_map.gd` references **no** star data today (`grep best_placement|stars_for_placement` -> nothing), so
    the readout genuinely does not exist.
  - `save_manager.gd:1667` `best_placement(rally_id)` and `RallyLibrary.stars_for_placement()` are the existing
    seams — the latter is "THE one definition" per its own comment.
- expected_files: `scripts/overworld_map.gd`
- expected_docs: `features/map-exploration.md`, `features/overworld.md`
- expected_tests: `overworld_map`, `overworld`
- test_conventions: never assert a star COUNT for a rally, nor the authored placement->stars table (both are
  tunable/authored — `CLAUDE.md` forbids pinning them). Test the LOGIC: an unplaced rally reads zero, and the
  readout is drawn for the asked-about pin only.
- conventions: any new offset/size is a `GameConfig` knob, not a literal (`overworld_map_*` is the existing
  naming); `features/` updated
- HIDDEN TRAPS:
  1. **DO NOT DRAW IT ON EVERY PIN — and the reason is already in the file's header.**
     `overworld_map.gd:62` explains that every pin used to carry its name and "turned the full map into a wall of
     overlapping capitals with the roads invisible underneath — the map stopped answering 'where do the roads go',
     which is the only reason it exists." The name is now drawn only for the pin the player is **asking about**
     (hovered, else selected — `_named_id()`). A star readout on all pins repeats exactly the mistake that rule
     records. **Grade down an answer that paints stars on every pin.**
  2. **USE THE ONE DEFINITION.** `RallyLibrary.stars_for_placement(Save.best_placement(id))`. Re-deriving a
     placement->stars mapping duplicates an authored table.
  3. **`best_placement` IS PODIUM-GATED** (rounds 015/016). It returns 0 when the player never PLACED, which
     includes finishing 5th — so "0 stars" does not mean "never attempted", and a readout that renders 0 as
     "unattempted" is wrong. `save_manager.gd`'s `record_podium_rally` comment states the gate.
  4. Non-rally pins (garage, parts, specials) have no placement at all; the readout must not claim zero stars for
     a pin that cannot have any.
- why this task: the `overworld`/map area is the largest surface with no bank task (`overworld_map.gd` is 1,755
  lines), and the task is the first authored under round 032's additive rule with the frozen-assertion check done
  up front. Its main trap is an anti-clutter rule whose RATIONALE is written down — a direct test of whether a
  documented "why" reaches a small model, not merely a "what".

### T015 — "On the overworld map, make it easy to see at a glance which rallies I've already won."
- status: live  (**authored round 035**)
- clean_solves: 0  (never probed)
- AUTHORED ROUND 035 as the **deliberate redesign of round 034's experiment**, which was inconclusive because the
  correct answer (the footer) was also the convenient one. This task is chosen so that **the cluttered
  implementation is the path of least resistance** and only the documented rationale argues against it:
  "at a glance" over the whole map inherently implies marking MANY pins, so text-on-every-pin is the obvious move.
- **THE EXPERIMENT.** `overworld_map.gd:62` explains that every pin used to carry its name and that this "turned the
  full map into a wall of overlapping capitals with the roads invisible underneath — the map stopped answering
  'where do the roads go', which is the only reason it exists", and ends: **"The other pins still say what they are
  by their glyph and colour."** So the file states both a prohibition (no text on every pin) AND the sanctioned
  channel (glyph/colour). The rule's literal subject is *names*; this task is about *won-ness*.
  - **rationale generalised** -> the won state is carried by **glyph and/or colour** (or another non-text per-pin
    channel), leaving the map readable.
  - **rationale did not generalise** -> text/stars/a tick drawn on every won pin, reproducing the exact failure the
    header records.
- **AUTHORING CHECKS RUN BEFORE WRITING THIS (rounds 032/033 rules), all three pass:**
  - **(a) additive?** Yes — a new visual distinction; nothing existing changes meaning.
  - **(b) already exists on ANY surface the wording could mean?** No. `_kind_color` (:1638) colours by KIND only
    (car/part gold, special red, garage green, else INK) and `_draw_glyph` (:1557) switches on kind; there is no
    won/unwon distinction. On the HQ map table, `hq_table.gd:427` reads `Save.rally_podiumed` only to pick a FOCUS
    target, and `hq.gd:3472` puts "(done)" in the banner for the SELECTED rally — neither is an at-a-glance marker.
  - **(c) would a correct implementation redden a test?** No. `test_overworld_map.gd` (49 tests) has no assertion on
    pin colour; its two glyph-related comments concern every `Kind` having a glyph and the garage not taking a part
    icon, neither of which a won-marker touches.
- expected_files: `scripts/overworld_map.gd`
- expected_docs: `features/map-exploration.md`, `features/overworld.md`
- expected_tests: `overworld_map`, `overworld`
- test_conventions: never assert a specific colour, alpha or glyph shape (all authored/tunable). Test the LOGIC: a
  won rally is distinguished from an unwon one, and a non-rally pin is unaffected.
- conventions: any new colour/alpha/size is a `GameConfig` knob or an existing `UITheme` constant, not a literal
- HIDDEN TRAPS:
  1. **NO TEXT ON EVERY PIN** — the central measurement, above.
  2. **"Won" is `Save.rally_podiumed(id)`, not `best_placement(id) > 0` reasoning about completion.** Both happen to
     agree today (both podium-gated), but the honest predicate is the named one, and round 034 caught a probe writing
     "completed" for a podium-gated value. Either is acceptable in CODE; **grade down a comment that calls it
     "completed" or "finished".**
  3. **Non-rally pins have no won state.** Garage, car, part and special pins must not be marked won (a SPECIAL is a
     rally and may legitimately be, but the garage cannot).
  4. Colours must come from `UITheme`, whose existing meanings the file documents ("gold is reward, green is 'your
     own thing', red is the showdown") — inventing a new colour with a new meaning fights that legend.
- why this task: the loop's one clean instrument for its last open question — whether a documented **rationale**
  transfers to a decision it does not literally cover — with the cluttered answer deliberately made the easy one.
- **RUBRIC NOTE round 035 — THE TASK WORDING IS STILL AMBIGUOUS AND THE FEATURE ALREADY EXISTS ON THE OTHER READING.**
  "On the overworld map" also reads as "in the overworld", and the probe took that: it edited `rally_flag.gd` /
  `rally_trophy.gd` (the 3D markers at rally sites), **never opened `overworld_map.gd`**, and so never met the
  clutter rationale this task exists to test. Worse, **that surface already distinguishes won rallies by glyph AND
  colour** — `rally_flag.gd::pennant_kind()` switches the pennant at `stars >= 1` and `accent_color()` changes colour
  at `STARS_FOR_WIN`. The probe added an emissive glow **on top of** it and reported it as newly making wins obvious.
  **Correctness VOID for that attempt** (the rubric assumed absence); navigation 3, convention 2, completion 3.
  **Also: this rubric's "colours belong in UITheme" line is MAP-SPECIFIC** — `rally_flag.gd` deliberately uses named
  raw `Color` constants and no `UITheme`, so a probe following that style is correct. I graded it down before
  checking and reversed it.
  **BEFORE RE-USING THIS TASK: say "the map overlay (M / gamepad Back)" explicitly**, and re-check whether the
  overlay still lacks the distinction.

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
- clean_solves: 0  (rounds 002–003, 009, 010 non-clean; **round 018 = 3/2/3/3, the best ever — and
  possibly a clean solve depending on the rubric ambiguity below**)
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

### T005 — "Track how many rallies the player has finished and show it on the profile."
- status: live
- clean_solves: 0  (round 003 non-clean; round 014 3/2/2/3; **round 015 drill 3 attempts:
  3/1/1/3 -> 3/2/1/3 -> 3/3/1/3 — correctness SOLVED, convention the sole remaining blocker**)
- **ROUND 016 SETTLEMENT: NOT harness-limited — T005 STAYS in the pool.** Round 015's
  convention-only reading did not survive its own follow-up. A settlement probe on the SAME fixed
  tree scored **3/1/1/3**: it declared `rallies_finished` correctly in `_default_profile()` but
  incremented it **inside the podium-gated `complete_rally()`**, so the counter counts first
  PODIUMS and the HUD read "Rallies Finished:". A THIRD route to the same wrong number, and
  neither round 014's undeclared-key ratchet (the key WAS declared) nor round 015's read-side
  guard caught it — 107 tests green. So correctness is still a live blocker and §2.4's
  harness-limited rule does not apply.
  **Round 015's "correctness solved" was n=1.** Across four probes on the fixed tree: declaring
  the key succeeded 2/2 (after the rule was placed at the top of `save_manager.gd`), while
  avoiding the podium gate failed 1/3. Round 016 renamed `complete_rally()` ->
  `record_podium_rally()`, put the gate rule INSIDE that function, and added
  `test_the_podium_gated_recorder_writes_no_finish_named_profile_key`.
  **Grade down any answer whose finish counter is written inside `record_podium_rally()`.**
- **RUBRIC NOTE round 037 (3/3/1/3 — all FOUR known routes avoided).** Declared `rallies_finished` in
  `_default_profile()`, added a separate idempotent `record_finished_rally()`, called it from the **any-finish** gate
  in `_resolve_results`, used `String(_rally.get("id",""))` (no bare `rally_id`), and the project compiles with 0
  script errors. All six relevant test files green. Docs 0 of 2, no test.
  **DO NOT read this as "T005 is solved."** Round 015's attempt 3 also scored 3/3/1/3 and round 016's settlement probe
  then scored 3/1/1/3 on the same tree via an unanticipated route. Correctness across four probes: **3, 1, 0, 3**.
  What IS established: three of the four routes are now machine-guarded (declared-key ratchet, recorder guard, shadow
  guard) plus a runtime tripwire, so those failures are no longer silent.
- **RUBRIC NOTE round 017 (3/0/1/2 — a FOURTH distinct route, and the first that does not compile).**
  Round 016's rename + write-site rule appear to have WORKED: this probe went straight to the
  any-finish gate, wrote a separate `record_rally_finish()`, touched no gated field and invented no
  top-level key. **But it wrote a bare `rally_id` in `_resolve_results`, where no such local exists
  — the name bound to `func rally_id() -> String`, and the whole project failed to compile** (every
  autoload dead). It had copied the identifier from the neighbouring `_award_podium_rewards`, which
  DID declare that local. Round 017 renamed all four method-shadowing locals in `scripts/` and added
  `test_no_local_variable_shadows_a_method_of_the_same_class`. The T005 failure has now moved off
  save-schema semantics entirely — three routes were wrong numbers, this one was a GDScript hazard.
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
  unupdated — **but that half of the round-014 penalty is WITHDRAWN (round 015): that doc is
  `TrackProgress`, not career progression, so it was never the right file to update.**
- RUBRIC NOTE round 003: Save.completed_rally_count() counts TOP-3 finishes, not
  finishes — a correct attempt must either surface it honestly or use a true
  finish count. Probe's hq_overlays.gd title-label approach was otherwise sound
  (nav 3 / corr 3); failed on docs+tests+mislabel.
- RUBRIC NOTE round 015 (**1st attempt 3/1/1/3; supersedes the round-001 correction
  below**): the probe added `RallyLibrary.finished_count()` counting `best_placed > 0` and
  labelled it "Rallies finished: N". That is the **podium count under a better name** —
  `Save.complete_rally` has exactly one caller (`rally_session.gd`, inside
  `_award_podium_rewards`, gated on `podium_or_opening`), so a 5th-place finish writes
  NOTHING into the record and every field of it is podium-gated. Round 003's note was
  seven lines above and did not stop it, because the note's reasoning named only the
  `completed` flag. Round 015 renamed `Save.rally_completed()` -> `Save.rally_podiumed()`
  (no wrapper), generalised the gate statement on all three read paths, and added
  `test_no_finish_named_symbol_derives_from_the_podium_gated_rally_record`. **Grade any
  answer that derives a finish count from the rally record as correctness <= 1.**
- **RUBRIC CORRECTED round 001 is WITHDRAWN (round 015).** It read "this needs NO
  migration; `Save.completed_rally_count()` already exists — do not penalise reuse of it."
  That was written against a **lying name**: the function counts PODIUMS. Reusing it (or any
  record-derived substitute) is now the primary failure mode, not the sanctioned answer.
- areas: save, progress
- expected_files: `scripts/save_manager.gd` (a new persisted counter **declared in
  `_default_profile()`** so `_migrate`'s key backfill seeds existing saves), the any-finish
  increment site (`rally_session.gd` — the `finished`/`_award_any_finish_*` seam, NOT the
  podium seam), and a display site (e.g. `scripts/overworld_garage.gd`, `scripts/account_menu.gd`)
- expected_docs: `features/save-persistence.md` (owns the profile/persistence API), and
  `features/star-economy.md` where the change touches the ledger.
  **`features/progress.md` REMOVED from this list (round 015): it documents `TrackProgress`
  — distance along the road centerline and off-track reset — not career progression.** The
  two senses of "progress" collided; round 014 marked a probe down for not updating a doc
  that was never the right one. Career progression is `save-persistence.md` +
  `star-economy.md`.
- expected_tests: `save_manager`, `save_sandbox`
- test_conventions: must use the save sandbox; `save_test_helpers.gd` exists
- conventions: migrations are mandatory for new persisted fields
- why this task: the migration requirement is real, load-bearing, and invisible
  unless you read `save_manager.gd` carefully — a strong probe of "hidden coupling"

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

### T008 — "Give the player a star bonus for finishing a rally without any damage."
- status: live
- clean_solves: 0  (rounds 002, 005, 007, 008, 009, 010 non-clean; round 016 3/3/2/3;
  **round 036 = 3/3/2/3 again, from an independent probe 20 rounds later — reproducible**)
- **RUBRIC NOTE round 036 (3/3/2/3; all five predictions confirmed).** Every trap this task accumulated over six
  rounds was avoided: the **any-finish** gate, the **latched `_took_damage_this_rally`** flag (not HP), an **int**
  return through the seam, and a **`GameConfig` `@export`** (`clean_run_bonus_stars`, correctly with no `.tres` line
  since the default is the authored value). **No test reddened — round 016's `assert_gte` unfreeze is durable after
  20 rounds of change**, and the probe explicitly cited it ("tests … already use `>=` … for this exact reason") and
  updated the seam comment's tense rather than deleting it. Remaining gap is the known tail: docs 1 of 3
  (`reward-system.md` only) and no test. **Nothing left to fix here — do not re-drill.**
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
- **RUBRIC NOTE round 016 — THE FROZEN ASSERTION IS GONE; the round-010 note above is obsolete
  on this point.** For six rounds no correct implementation of T008 could reach a green suite:
  `test_a_rewin_pays_stars_again_but_never_another_car` and
  `test_the_opening_rally_completes_on_a_losing_finish` both asserted
  `stars_gained == stars_for_placement(...)` on fixtures that finish UNDAMAGED, so any bonus
  reddened them. Round 010 diagnosed this and answered it with a 22-line note telling a future
  implementer to fix the tests — which probes, being barred from running tests, can never
  discover. §2.5 makes finding these the PARENT's job. Round 016 relaxed both to `assert_gte`
  (every other assertion intact) and deleted the note. **Do NOT mark a probe down for those two
  tests any more, and if either reddens again it is a real regression.**
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
- status: **live — CAPPED at 3 attempts in round 041, deliberately NOT marked `too_hard`.** See the
  round-041 note: the attempt curve CLIMBED monotonically on correctness (1 -> 2 -> 3) and ended at
  3/3/2/3, the task's best ever, with all seven test files green. §D5's `too_hard` exists for a task
  that outran the loop; this one is a single one-line convention miss from clean, so retiring it from
  the live pool would discard the loop's most nearly-solved hard task. Recorded as an argued deviation.
- clean_solves: 0  (rounds 006, 009, 010 non-clean; **round 024 = 3/1/2/3, a REGRESSION — invented gate id**; round 010 best yet at 3/3/2/2 — but see the round-006 rubric note: the design, not the probe, was at fault; round 009 was near-clean at 3/2/2/2)
- **RUBRIC NOTE round 039 (3/1/2/3 — the invented gate id RECURRED).** All three registry edits again, reading
  `ctx.get("is_wet", false)` so the axis fires in storm too; the symmetric invariant holds (race wins gravel+tarmac,
  snow wins snow, wet wins wet) and **the probe quoted round 020's clause in its own rationale**. **Docs 2 of 3** —
  `drivetrain-and-tires.md` AND `upgrade-catalogue.md`, this task's best. But it gated on **`sp_coastal_challenge`,
  which does not exist** — a second invented id after round 024's `h_coast_qualifier`, on the same task fifteen rounds
  apart, each a different plausible-sounding invention. Round 024 left the code alone because the defect was already
  guarded; **two data points supersede one**, so round 039 stated the requirement at the field itself: consequence
  first (permanently unwinnable, silent), the guard named by test file, a concrete `grep` to verify, and an explicit
  "that is a test you may not be running, so do the grep".
- **RUBRIC NOTE round 024 (3/1/2/3).** The three causes rounds 006/007/009 fixed are all **settled**: the
  probe made all three registry edits in `game_config.gd`, touched no consumer, and read
  **`ctx.get("is_wet", false)`** rather than comparing weather strings — so the axis fires in **storm** as
  well as rain, the defect three consecutive rounds shipped. **The new failure is
  `unlocked_by_rally: "h_coast_qualifier"`, a rally id that does not exist**, which makes the part
  permanently unwinnable; `test_rally_library.gd` catches it exactly ("must be a real rally" / "must be a
  SPECIAL event"). Docs: 1 of 3 (`drivetrain-and-tires.md` only). **Grade down any answer whose gate id
  does not resolve**, and always run `rally_library` here.
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
- expected_docs: `features/drivetrain-and-tires.md`, `features/upgrade-catalogue.md` — and
  `features/weather.md` **ONLY for a route-(b) answer** (via `WeatherLibrary.rain_grip_mult`).
  **CORRECTED round 041:** `weather.md` had never been updated by any probe in six samples, and no
  route to discovering it exists — it does not enumerate tyre parts by id, so the doc guard cannot
  cover it without becoming broad and noisy, and the loop has already falsified six wording
  mechanisms for out-of-file doc obligations. A route-(a) answer's doc obligation is the two tyre
  docs, both of which ARE now guarded (test_upgrade_library.gd, widened round 041).
- expected_tests: `tire_surface_axes`, `upgrade_library`, `upgrades_grid`, **and `rally_library`**
  (**added round 024**: a new `UPGRADES` row carries an `unlocked_by_rally` gate, and the guard that every
  authored gate resolves to a real SPECIAL rally lives in `test_rally_library.gd`. Omitting it made round
  024's first run green on a probe whose part was permanently unwinnable. A rubric's `expected_tests` is a
  hint, never the blast radius.)
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
