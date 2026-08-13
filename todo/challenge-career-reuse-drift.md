# Challenge / career reuse drift — one rule, N call sites

Findings from a `/refactor-after-bugfix` investigation run on 2026-07-31, after
fixing the "Daily challenge road drives into the water" bug. Every item below was
verified against the code by reading it; none are speculative.

| Section | Status |
|---|---|
| 1. Invert the config direction (the class fix) | IMPLEMENTED |
| 2. The final challenge stage's interstitial reads the wrong session | IMPLEMENTED |
| 3. Free roam re-implements `apply_event_config` partially | IMPLEMENTED |
| 4. The car lock is scoped far too widely — REDESIGNED | REDESIGNED — implemented per new rule; test migration outstanding (five test files off the deprecated `abandon()` alias, then delete it) |
| 5. Challenge does not repair after its final stage — it should | IMPLEMENTED |
| 6. Challenge start skips part of the career start composite | IMPLEMENTED |
| 7. `Benchmark._OVERRIDDEN_FIELDS` is a hand-maintained subset | IMPLEMENTED |
| 8. `ChallengeSession` has no phase gate on wreck / result reporting | IMPLEMENTED |
| 9. Free-roam region leaks into a challenge stage | IMPLEMENTED |
| 10. The sync-conflict prompt is owned by an OPTIONAL screen | IMPLEMENTED |
| 11. No standard "waiting on Firebase" loading state | IMPLEMENTED |
| 12. "Return to HQ" DNFs a challenge — it should just pause it | IMPLEMENTED — test migration outstanding (five test files off the deprecated `abandon()` alias, then delete it) and a synthetic period-key seam for tests |
| 13. The title screen repopulates in front of the player — IMPLEMENTED | IMPLEMENTED |

## The mechanism

**A rule or multi-step sequence that should live in ONE shared place is re-derived
per call site, and the divergence fails SILENTLY** — a stale global, a fallback
default, or a divergent list — rather than loudly.

`res://main.tscn` has **five producers and one consumer**:

| producer | writes `Config.data` before loading the scene? |
|---|---|
| `rally_session.gd` → `_load_event_scene` | yes — `apply_event_config` |
| `challenge_session.gd` → `continue_to_next_stage` | yes (added by the water fix) |
| `hq_challenge.gd` → `_hand_off_to_challenge_scene` | yes (added by the water fix) |
| `hq.gd` → `_launch_free_roam` → `_prepare_free_roam` | **partially — see item 3** |
| `benchmark_mode.gd` → `Benchmark.start` | **partially — see item 7** |

The consumer, `world.gd._ready`, does `var cfg: GameConfig = Config.data` and
trusts it. The producer/consumer contract is pure convention; nothing states or
checks it. Every field `TrackGenParams.for_event` does NOT read
(`track_forestiness`, `cliff_amount`, `track_tarmac_fraction`, every
`terrain_layer*`, and the *rendered* `track_water_level_m`) is delivered only by
that convention. **The omitted step leaves a plausible config, not a missing one**
— which is why it failed silently.

`Config.reset()` has no production callers, so `Config.data` is never reset
between scenes. Stale values persist across an entire play session.

## Already fixed (context, do not redo)

- The challenge path now calls `DrivingContext.apply_stage_config` from both
  entry points. **Item 1 below supersedes this** — it deletes those two calls.
- `ChallengeLibrary.stages_for` now rolls `water_level` and
  `terrain_layer1_amplitude` together, from the bands real authored content uses.
- An earlier `/refactor-after-bugfix` run produced `DrivingContext`, unifying
  "which car is driven / what p/w limit applies / is it locked". Everything here
  should compose with it, not add a third parallel concept.

## Prior art — this mechanism was already on record

`todo/backlog.md` carries: *"Detune-to-enter flow is duplicated across hq.gd and
start_line.gd — left un-consolidated because the two flows differ materially;
revisit only if they converge."* That is the same mechanism, already known and
consciously deferred. Worth re-reading that call in light of the findings below:
the deferral was reasonable in isolation, but this spec shows the pattern is
systemic rather than a one-off, and the p/w-ceiling bug that produced
`DrivingContext` came out of exactly that duplicated detune-to-enter surface.

---

## 1. Invert the config direction (the class fix)

**Depends on: nothing. Do this first — items 3 and 7 build on it.**

Add to `scripts/driving_context.gd`:

```gdscript
# The ONE place a stage's track parameters reach the live config. Idempotent:
# apply_event_config reloads the authored baseline and pins every omitted field
# to it, so applying at consume-time is identical to applying at produce-time.
static func apply_stage_config(cfg: GameConfig) -> void:
    if ChallengeSession.is_active():
        RallySession.apply_event_config(cfg, ChallengeSession.current_stage_params())
    elif RallySession.is_active():
        RallySession.apply_event_config(cfg, RallySession.current_event())
    # free roam / benchmark / dev boot: no session — cfg as authored by the caller
```

Call it **once**, at the top of `world.gd._ready`, before the `var cfg :=
Config.data` read. Then DELETE the three producer-side calls:
`rally_session.gd._load_event_scene`, `challenge_session.gd.continue_to_next_stage`,
`hq_challenge.gd._hand_off_to_challenge_scene`. `DrivingContext.apply_stage_config`
becomes a thin forwarder or is removed.

**Why this and not "remember to call it".** The current fix is correct but local:
it adds a third and fourth call site someone must remember. Inverting removes the
ordering dependency entirely — "a new scene-entry site forgot step 1" stops being
expressible. Note `world.gd._generate_track` ALREADY pulls the event dict from the
active session while the surrounding config comes from a global someone else wrote;
this makes both come from the same place.

**Why it's safe.** `RallySession.apply_event_config` reloads the pristine `.tres`
on every call and pins omitted fields to it (deliberately, so one event can't leak
into the next), so there is no accumulated state to lose.
`RallySession.canonical_event_config` — the lockfile / target-time path — never
touched `Config.data` and is unaffected.

**Migration risk (narrow, and loud rather than silent):** headless tests that
hand-write `Config.data` and then instantiate `main.tscn` **while a session is
active** would now be overwritten. Tests using `SceneTestHelpers.minimal_world()`
or with no active session are unaffected.

**Optional belt-and-braces:** a `push_error` in `world.gd._ready` when a session is
active and `Config.data`'s shape-determining fields disagree with the session's
stage. Detects drift; does not prevent it. Only worth ~10 lines alongside item 1,
never as the primary fix.

## 2. The final challenge stage's interstitial reads the wrong session

**Player-visible. Depends on: nothing.**

`ChallengeSession.report_event_result` calls `_finish_locally()` (which sets
`_active = false`) and THEN emits `standings_ready` unconditionally:

```gdscript
if is_final:
    _finish_locally()
standings_ready.emit(_stage_index)
```

`world.gd` wires that signal to `_present_standings_overlay`, so the overlay is
built while `ChallengeSession.is_active()` is already false. Every read in
`standings.gd` uses the `if ChallengeSession.is_active(): … else: RallySession…`
idiom — `_stages_done`, `_stage_total`, `_stage_upgrade`, `_driven_instance_id`,
both leaderboard sections, and the Continue handler — so on the final stage they
ALL fall through to the idle career session:

- the header reads "stage 0 of N"
- both leaderboards render `RallySession`'s empty field
- **Continue is a dead button** (`RallySession.continue_to_next_event()` is a
  no-op while its phase is IDLE)
- `GlobalStandings.for_current_stage()` posts/fetches the **career** `stage_times`
  board with `stage_key == ""` instead of the challenge board

Reachable in normal play: `world.gd._on_challenge_run_finished` awaits
`try_grant_completion_reward`, which awaits a real network round-trip
(`fetch_final_rank`), so the overlay is visible for that whole duration.

### Severity: a DAILY time is NEVER posted, on every single run

Confirmed by a player report on 2026-07-31 ("finished the daily, got forced back
to the HQ while looking at the leaderboard without pressing next, and no new data
in Firestore about my time").

`ChallengeLeaderboard.post_checkpoint` — the only writer of a challenge time — is
reachable ONLY via `GlobalStandings._refresh_challenge`, which requires
`is_challenge == true`, which requires `GlobalStandings.for_current_stage()` to
have taken its `if ChallengeSession.is_active()` branch.

`STAGE_COUNTS[DAILY] == 1`, so a Daily's ONLY stage is also its FINAL stage.
`_finish_locally()` has therefore always already cleared `_active` by the time the
interstitial resolves. **The challenge branch is never taken for a Daily, so a
Daily time is never posted to Firestore at all** — not intermittently, on 100% of
runs. The board the player sees is the career `stage_times` board with an empty
`stage_key`.

For Weekly/Monthly the intermediate stages post correctly; only the final stage's
checkpoint is lost (and with it the run's finishing total).

Two knock-on effects of the same cause:

- **The player is ejected to the HQ mid-read.** `_on_challenge_run_finished` never
  waits for the interstitial's Continue — it awaits the reward round-trip and then
  transitions. The overlay is on screen only for the duration of that fetch. The
  run-end flow and the interstitial are two independent owners of "what happens
  after the last stage", which is the same one-rule-two-places mechanism.
- **The completion reward is probably denied too.** `try_grant_completion_reward`
  gates on `fetch_final_rank` against a board the player was never written to.

Whatever fix item 2 takes must therefore be verified against a DAILY (the
single-stage case), not just a multi-stage kind — a Weekly would mask most of it.
Fixing the interstitial's session read alone is NOT sufficient: the run-end
handler's unconditional HQ transition has to be reconciled with the interstitial
so the player dismisses the final standings themselves.

**Fix direction:** pin which session an interstitial belongs to at construction,
rather than re-asking `is_active()` six times against a session that clears itself
mid-sequence. Either latch the mode when the overlay is built, or have
`_finish_locally` defer clearing `_active` until after the emit — the former is
safer, since other code may also read `is_active()` in that window.

**Also correct the docs:** `features/rally-challenge.md` currently claims "a
challenge's final stage therefore never shows the interstitial at all". That is
false, and is probably why this went unnoticed.

## 3. Free roam re-implements `apply_event_config` partially

**Player-visible. Depends on: item 1 (do it after, and reuse the same writer).**

`hq.gd._prepare_free_roam` writes only `track_seed`, `track_straightness`,
`track_forestiness`, `track_tarmac_fraction`, `track_water_level_m`,
`terrain_layer1_amplitude`.

`RallySession.apply_event_config` — the canonical writer — additionally resets
`track_turn_count`, `track_width`, `cliff_amount`, `water_enabled`,
`terrain_layer1/2/3_wavelength` and `terrain_layer2/3_amplitude`, all from the
pristine baseline. Authored events DO set these (`RallyLibrary.RALLIES` has
entries with `turn_count: 40` and `cliffiness` up to 1.0, and several set
`terrain_layer2_amplitude`).

Since `Config.data` is never reset between scenes: finish or abandon a rally with
high cliffiness and a high turn count, return to HQ, enter Free Roam → free roam
generates a 40-turn track over max-cliff terrain with the previous event's layer-2
amplitude, silently. `world.gd` uses `TrackGenParams.for_config(cfg)` for free
roam, so every stale field reaches generation.

**This is the same bug as the water bug, on a different path.**

**Fix direction:** have free roam go through the canonical writer with its rolled
values as an event-shaped dict, rather than hand-writing a subset — so "fields the
writer resets" can never drift from "fields free roam remembers to set".

## 4. The car lock is scoped far too widely — REDESIGNED

**Design rule changed by the user on 2026-07-31. The original version of this item
(and part of a fix already shipped that day) was based on a wrong premise; both are
superseded by what follows.**

### The rule

> "I don't think the car should be unusable in other modes. It's just locked in the
> sense that you can't switch to use a different car in the challenge. But the car
> should still be usable in other modes."

So the lock means exactly ONE thing: **while a challenge run is active, that run is
committed to the car it started with, and the player cannot swap to a different car
for that run.** It is a property of the RUN, not a reservation on the CAR. The car
stays fully usable in career rallies, free roam, the garage, engine swaps and
upgrades.

### What must be REMOVED (this is the actual work)

A fix shipped earlier on 2026-07-31 under the heading "car lock defeatable via the
garage" made `hq.gd`'s garage picker and engine-swap partner list exclude
`DrivingContext.is_car_locked` cars. **Under the rule above that is not a fix, it is
the bug** — it is precisely what made the car unusable elsewhere. Remove those
exclusions.

Audit every `DrivingContext.is_car_locked` / `Save.is_challenge_locked` call site and
delete the ones that gate anything OUTSIDE the challenge run itself. Do NOT add the
lock filter to `ChallengeSession.eligible_cars` (an earlier draft of this item called
for that — it is now wrong).

### What must be VERIFIED, not assumed

"Can't switch cars mid-run" may already hold with no new code: `ChallengeSession.start`
already refuses while a run is active, and the entry screen already shows Resume plus
the single committed car rather than a picker. Confirm that by reading the code before
adding anything. If it already holds, this item is purely a deletion.

### Accepted consequence — mid-run repair (user-approved)

Because the car is usable between stages, a player can finish a stage, repair or
upgrade in the garage (or drive a career rally, which applies its own pit repairs) and
return to the next stage in better condition than they left it. This weakens the
damage-carryover contract.

**The user has explicitly accepted this** — a challenge is a time competition, not a
survival one. Do NOT add stage-boundary condition snapshotting to "protect" carry-over
unless the user asks for it later.

### Still valid from the original item — the three-way disagreement

Independently of the lock's scope, "which cars are eligible" is derived three times
and the derivations can disagree:

- `hq_challenge.gd._refresh_challenge_overlay` uses `ChallengeSession.eligible_cars(...)` raw for
  both the "Eligible" label and the Start gate
- `hq_challenge.gd._build_challenge_lineup` additionally drops locked cars
- `ChallengeSession.eligible_cars` filters on ceiling / detune-reachability only

Once the lock exclusions are removed the three should collapse to one list naturally.
Verify they agree afterwards rather than assuming, and keep a test that asserts the
label, the Start gate and the parked lineup derive ONE list.

Also still valid: `_enter_challenge_car_screen`'s empty-state message blames the
ceiling ("none of your cars meet the ceiling") for what is essentially never the real
reason — a probe over the whole roster x every `CEILING_BAND_HP_TONNE` value found
ZERO cars excluded on power-to-weight grounds at any band. Make the message accurate.

### Forfeit — DROPPED

An earlier draft proposed a confirmed "Forfeit run" action, because the lock pinned a
car for up to a month. With the lock no longer reserving the car, that justification is
gone and the user declined it. Do not implement it.

**Already shipped and still correct:** the entry screen shows `IN PROGRESS - X/Y
stages` and names the single committed car for the kind holding the run — that
communicates the commitment without reserving anything.

## 5. Challenge does not repair after its final stage — it should

**DECIDED (user, 2026-07-31): a challenge SHOULD repair after the final stage,
matching career.**

`RallySession._resolve_results` deliberately applies `_apply_field_repair()` after
the final event, so the last event's damage isn't left unrepaired. The equivalent
branch in `ChallengeSession.report_event_result` is a literal `pass`.

The challenge side also re-implements the repair as
`_field_repair_for_next_stage` rather than calling the shared
`RallySession._apply_field_repair` — the same duplication mechanism.

**Fix direction:** fold both onto one shared helper (a `DrivingContext` static, or
promote `_apply_field_repair`), then apply it on the challenge's final stage too.
Use the SAME configured fraction as the other stages — do not hardcode a literal,
and do not repair to full.

## 6. Challenge start skips part of the career start composite

**Player-visible on touch devices. Depends on: nothing.**

Career's Start (`_on_start_pressed` → `_proceed_with_start` → `_begin_rally_start`)
does two things `hq_challenge.gd._begin_challenge_start` does not:

- the **mobile control-scheme gate** — if on mobile and no scheme has been chosen,
  open settings and return
- `Save.set_selected_car(_selected_instance_id)`

The CHALLENGE arm of `_on_start_pressed` returns before both. So a touch player
whose first-ever drive is a challenge is dropped into the stage with no control
scheme chosen, and the garage lift won't show the car they just raced.
`hq.gd._start_free_roam` skips the mobile gate too.

## 7. `Benchmark._OVERRIDDEN_FIELDS` is a hand-maintained subset

**Affects measurement validity, not players. Depends on: item 1.**

`benchmark_mode.gd` snapshots/overrides `track_seed`, `track_turn_count`,
`track_straightness`, `track_forestiness`, `track_tarmac_fraction` — but NOT
`cliff_amount`, `water_enabled`, `track_water_level_m`, or any `terrain_layer*`.
Same stale-global channel as item 3: a benchmark started after a rally runs over
that rally's cliffs, relief and waterline, so numbers aren't comparable between a
fresh boot and a post-rally boot.

`Benchmark.start` also abandons only `RallySession`, not `ChallengeSession`.

## 8. `ChallengeSession` has no phase gate on wreck / result reporting

**Fragile, not proven reachable. Depends on: nothing.**

`RallySession.report_event_result` and `report_wreck` both early-out unless
`_phase == Phase.RUNNING`, so a wreck signal arriving during the standings/replay
window is ignored. The challenge equivalents guard only `_active`, and the
standings overlay keeps the run world (and `$Car`) alive with `begin_replay`
running. Any `wrecked` emission in that window would DNF the run.

## 9. Free-roam region leaks into a challenge stage

**Player-visible. Depends on: nothing.**

`world.gd._current_region_look` branches `RallySession.is_active()` → the rally's
region; `elif free_roam_instance_id >= 0 or free_roam_model_id != ""` →
`free_roam_region_id`; else "home". **There is no challenge arm.**

`RallySession.start_rally` explicitly clears the free-roam handoff ("a real rally
supersedes any pending free-roam pick") and `Benchmark.start` does the same.
`ChallengeSession.start` / `resume` clear nothing, and nothing else resets those
vars.

Failure: free-roam drive (which sets a random `free_roam_region_id`) → Pause →
Quit (the no-session branch just loads `hq.tscn`, leaving the ids set) → start a
Daily. The challenge car is fielded correctly (challenge is checked first), but the
stage wears the leftover free-roam region's sky/ground/tree mix.

**Fix direction:** give `_current_region_look` a challenge arm, and have
`ChallengeSession.start`/`resume` clear the free-roam handoff the same way
`start_rally` does — ideally via one shared "a real session supersedes a pending
free-roam pick" helper rather than a third copy.

---

## 10. The sync-conflict prompt is owned by an OPTIONAL screen

**Player-visible and silently breaks cloud saving. Depends on: nothing.**
**Reported by the user on 2026-07-31:** *"the 'your progress differs' popup isn't
showing up in the right place. I can only access it when I go into the accounts page
so if the user doesn't go there the rest of the game might seem broken."*

`Cloud.conflict_detected` has **exactly one subscriber in the entire codebase**:
`account_menu.gd` (`Cloud.conflict_detected.connect(_on_conflict_detected)`). That
node only exists while the account page is open. A conflict raised anywhere else —
at sign-in on boot, or on a background sync — emits into nothing.

This is not merely a missed notification. `cloud_sync.gd` sets
`blocked_by_conflict = true` when both sides have moved on, and `push()` then returns
`{"ok": false, "error": "Resolve the sync conflict first."}` for **every subsequent
save**. So:

- cloud saving silently stops for the rest of the session
- there is no on-screen indication of why
- the only resolution UI (`account_menu.gd._prompt_conflict`, and the "Resolve sync
  conflict" action it builds) lives behind a page the player has no reason to visit
- a player who never opens the account page experiences it as "the game stopped
  saving", with no path to recovery

### The reported scenario — it is DESTRUCTIVE, not just silent

Reported 2026-08-01:

> "I boot the game and for whatever reason my progress is lost (I'm picking a
> starter car). But I am still logged in. The game will happily let me pick a
> starter car and continue with the game even though I am logged in and have a real
> save that should be loaded. The save conflict message never appears. It's only
> when I click the account page from the title screen that the conflict popup
> appears."

This is worse than "cloud saving silently stops". The boot flow does not merely fail
to NOTIFY — it lets the player begin a brand-new career (the starter-car pick) on top
of an unresolved conflict. Consequences:

- The player is asked to make a permanent, game-defining choice while signed in to an
  account that already holds a real career. Nothing on screen suggests anything is
  wrong.
- The local side of the conflict is then MUTATED by that new career, so by the time
  the player finds the account page, "keep local" no longer means "keep what I had" —
  it means "keep the fresh save I was just tricked into starting".
- The player has no reason to suspect their real save exists, so the most likely
  outcome is that they keep playing and eventually resolve the conflict in favour of
  the wrong side, or never resolve it at all.

**So the fix is not only "surface the prompt somewhere always-present". The boot flow
must BLOCK irreversible progression while a conflict is unresolved.** Specifically:
if signed in and `blocked_by_conflict` is true, the starter-car pick (and any other
new-career entry point) must not be reachable until the conflict is resolved —
resolve first, then continue into whichever save won.

Note there is existing precedent for gating the starter pick on cloud state: an
earlier fix already made the starter pick wait for a cloud restore
(see `hq.gd` around the first-run/`_pick_starter` path). That gate is the natural
place to also account for an unresolved conflict — a conflict is precisely the case
where the restore did NOT complete.

### Same mechanism, worst instance

Every other item here is "a rule owned by N call sites that drifted". This one is a
rule owned by **one OPTIONAL screen** — strictly worse, because the owner is not
merely duplicated, it is usually absent. The state (`blocked_by_conflict`) lives in
an always-present autoload while the only thing that can clear it lives in a
sometimes-present node.

### Fix direction

Give the prompt an owner that always exists:

- Raise it wherever the player actually is. An autoload-level overlay is the strongest
  option (it cannot be missed regardless of scene); hosting it in the HQ is the
  cheaper option, since that is where the player returns between everything, but it
  still misses a conflict raised mid-drive.
- Keep the account page's "Resolve sync conflict" action as a SECONDARY route, not the
  only one. Do not delete it.
- Make the blocked state VISIBLE while unresolved rather than failing pushes silently
  — a persistent indicator, so "my saves aren't uploading" is never invisible.
- Keep `_conflict_open` (or an equivalent) so the prompt can't stack if several sync
  attempts raise it in a row.

#Test gaps

- Nothing asserts that a conflict raised with the account page CLOSED reaches the
  player. Test at the signal level: emit/raise a conflict with no account menu in the
  tree and assert the prompt is presented.
- Nothing asserts the blocked state is visible, or that resolving it re-enables
  `push()`.
- Any new prompt must be keyboard/gamepad navigable per CLAUDE.md, with a nav test.

Do NOT assert specific popup copy or button labels — those are content. Assert that a
prompt EXISTS, that it offers both resolutions, and that choosing one clears
`blocked_by_conflict`.

## 11. No standard "waiting on Firebase" loading state

**Player-visible. Reported by the user on 2026-08-01:** *"is there a delay while
querying or writing to firebase after clicking one of the conflict resolution
buttons? I feel like I clicked it but nothing happened for a while... that loading
state should be a standard pattern everywhere firebase is involved."*

Yes, there is a real delay — `Cloud.resolve_keep_local` uploads the whole profile and
`Cloud.resolve_use_cloud` downloads and applies it, both full Firestore round-trips.

### The state today: three different answers to one question

Every screen that awaits Cloud invents its own waiting UI, or none:

| call site | busy state |
|---|---|
| `account_menu.gd` (sign-in, register, reset, sync_now, both resolutions) | its own private `_begin(text)` / `_finish(result)` + `_set_message` |
| `hq.gd._await_cloud_restore` | a covering `LoadingScreen` |
| `cloud/conflict_prompt.gd._resolve` | a covering `LoadingScreen` (added 2026-08-01 — it had NONE when first written) |
| `challenge_session.try_grant_completion_reward` -> `fetch_final_rank` | **none** — this is the pause the player experiences at the end of a run |
| `global_standings` -> `submit_and_fetch` / `post_checkpoint` / `fetch_standings_at` | its own in-panel "unavailable"/placeholder handling |

This is the spec's mechanism again: "show that we are waiting on the network" is a
rule re-derived per call site, and the derivations disagree — including one that
resolves to nothing at all.

### Fix direction

One shared way to say "a cloud call is in flight", used by every `await Cloud.*`
call site. Design questions worth settling BEFORE implementing (this is not a
mechanical sweep):

- **Blocking vs. ambient.** A resolution that rewrites the whole profile should
  probably block input (a cover); a leaderboard fetch behind an already-rendered
  panel should probably not — an ambient spinner/label is better than a modal.
  Likely both, with one helper each, rather than forcing every site into a cover.
- **Where it lives.** A static helper (like `ConflictPrompt._resolve`) that wraps a
  Callable is the cheapest shape and composes with any host. Avoid a new autoload.
- **Minimum visible duration.** A round-trip that completes in 50 ms should not
  flash a cover for one frame — consider a small floor, or a delay before showing.
- **Failure.** Today some sites surface the error text and some swallow it. The
  shared helper should have ONE answer for what the player sees when a call fails.
- **Headless.** Must skip the visual and never the await — the rule
  `hq.gd._await_cloud_restore` and `ConflictPrompt._resolve` already follow.

### Scope note

`account_menu.gd`'s existing `_begin`/`_finish` is a working implementation of this
idea that is private to one screen. The cheapest honest path is probably to promote
THAT concept rather than invent a third, then migrate the sites in the table above.

### Test gaps

- Nothing asserts a busy/loading state is shown for any cloud call.
- Assert the RELATIONSHIP (a cover exists while the call is in flight and is gone
  after), never specific copy — the strings are content.

## 12. "Return to HQ" DNFs a challenge — it should just pause it

**Player-visible, and now DESTRUCTIVE since item 5's one-attempt rule landed.**
**Raised by the user on 2026-08-01:** *"when the user presses 'return to hq' from the
pause menu, does it register the challenge as DNF? It should just pause it.
Challenges should not DNF unless the car is wrecked."*

Confirmed. `pause_menu.gd.quit_to_hq()` branches:

```gdscript
elif ChallengeSession.is_active():
    ChallengeSession.abandon()
```

and `abandon()` calls `_end_as_dnf()`. So stepping out to the HQ mid-run ends the run
as a DNF. Since one-attempt-per-period landed, that DNF is now TERMINAL — the period
is spent and cannot be replayed until it rolls over. Leaving a stage to look at the
garage costs the player their whole Daily.

The confirm copy is wrong for a challenge too: *"Abandon this rally and return to HQ?
Your progress in this run is lost."* A challenge already persists `challenge_run`
after every stage and has a working Resume path, so the progress is NOT lost — the
dialogue is describing career behaviour.

### The rule

**Only a wreck DNFs a challenge.** Everything else that leaves the run — the pause
menu, and anything else that needs the run to stop being active — should PAUSE it:
persist `challenge_run` as-is and return to the HQ, leaving it resumable.

### Fix direction

Split the two meanings that `abandon()` currently conflates:

- **`report_wreck()`** — terminal. DNF, records the period outcome, cannot be retried.
  Unchanged.
- **A new "leave the run" path** (`pause_run()` / `leave_for_hq()`) — NOT terminal.
  Clears `_active` and `_stage_running` so no scene keeps driving it, leaves
  `challenge_run` persisted at its current `stage_index`/`stage_times_ms`, records NO
  outcome, and returns to the HQ. The entry screen's existing Resume path then picks
  it straight back up.

The in-progress stage's partial time is discarded — the player re-drives that stage on
resume. That is the correct and expected behaviour, and already how resume works.

### Other callers to audit

- `benchmark_mode.gd` `Benchmark.start` calls `ChallengeSession.abandon()` to clear a
  live session before a benchmark. That would DNF a run for starting a dev benchmark —
  it should pause, not DNF.
- `hq.gd` calls `RallySession.abandon()` (career only) — unaffected.
- Whether `abandon()` should survive at all as a public name is worth deciding: if
  every remaining caller wants "pause", the terminal path can be private to
  `report_wreck()`, which makes the DNF rule unmissable.

### Test impact to expect

`tests/headless/test_challenge_session.gd`'s `after_each` calls `abandon()` as cleanup.
If `abandon` stops being terminal, tests that rely on it recording a DNF (and the
smoke tests that now clear `challenge_results` because of it) need revisiting —
check both rather than assuming.

### Test gaps

- Nothing asserts that quitting to the HQ leaves a challenge RESUMABLE. Add: start a
  run, leave via the pause-menu path, assert `resumable_run` is non-empty, no outcome
  was recorded, and the banked stage times survived.
- Nothing asserts a wreck is still terminal after the split.
- Assert the confirm copy DIFFERS for a challenge only at the level of "it does not
  claim progress is lost" — do not pin the strings.

## 13. The title screen repopulates in front of the player — IMPLEMENTED

**Player-visible. Reported by the user on 2026-08-01:** *"sometimes I see a 1-2 second
delay on the title screen as my save data is being fetched and I see my garage update
in front of my eyes. Shouldn't this kind of thing be hidden behind a loading screen?
I.e. start loading -> if not logged in go straight to the title screen -> if logged in
wait until data is fetched -> then release loading screen."*

Confirmed. `hq.gd._on_cloud_profile_replaced` runs when the boot pull lands and, while
`_view == View.EXTERIOR`, calls `_clear_lift_car()` + `_build_title_lineup()`. So the
title screen is built from the LOCAL profile first and then visibly rebuilt from the
downloaded one a second or two later — the player watches their garage pop in.

### Why the existing gate does not cover it

`hq.gd._await_cloud_restore` gates the STARTER PICK only, and its comment justifies
that deliberately:

> "WHY ONLY THE PICK IS GATED, not the title screen. Gating the title itself would make
> an offline player, or one who has never signed in, wait for something that is never
> coming — and signing in is never required."

The concern is real but the conclusion is **over-broad**. `Cloud.initial_pull_pending`
is already false for a player with no stored credential — that IS the "not logged in,
go straight to the title" condition, and `_await_cloud_restore` already early-returns
on it. The narrow gate was available; the comment argued against the wide one.

### Fix direction

Extend the existing wait to cover the title reveal, gated on the SAME
`initial_pull_pending` condition, so the sequence becomes: cover -> no credential?
reveal immediately -> credential? await the pull (already hard-capped by
`Cloud.await_initial_sync`) -> reveal once. Reuse `_await_cloud_restore` /
`CloudBusy.cover` rather than adding a third waiting mechanism (item 11).

Things that must not regress, all already load-bearing in `_await_cloud_restore`:

- **Guaranteed exit.** The wait is capped inside `Cloud.await_initial_sync`; a hung or
  failed pull must still reveal the title. No path may hang forever.
- **Offline / never-signed-in players wait for nothing.**
- **The conflict case.** A pull that settles as a CONFLICT does not apply the download
  (item 10), so the title should reveal against the local profile and the conflict
  prompt should still be raised.
- **Headless.** Skip the cover, never the decision — the same rule the rest of this
  file follows.

Once the title is gated, check whether `_on_cloud_profile_replaced`'s EXTERIOR rebuild
arm is still reachable at boot. If the only way a profile lands while the title is up
is a mid-session sign-in, say so in the comment rather than leaving it looking like the
boot path.

### Test gaps

- Nothing asserts the title is not built twice at boot. Add: with a pending pull, the
  title lineup is built once, after the pull settles — a relationship (build count /
  ordering), never a timing value.
- Nothing asserts a signed-out player reveals immediately.
- `test_cloud_boot_gate.gd` already has the harness for all of this
  (`Cloud.initial_pull_pending`, `Cloud._settle_initial_sync`, a zero-budget timeout
  path) — extend it rather than building a new one.

## Test gaps

### Why the suite missed the water bug

Four compounding causes, none of which is "nobody wrote a test":

1. **The one end-to-end challenge test hand-rolls the code path it was meant to
   cover.** `tests/headless/test_smoke.gd::test_entering_a_challenge_stage_generates_its_track`
   calls `ChallengeSession.start(...)` directly and then instantiates `main.tscn`
   itself, bypassing `hq_challenge.gd._hand_off_to_challenge_scene` — where the missing step
   lived. It also passed a stale `Config.data` into generation and called that a pass.
2. **Its assertions are liveness-only** — Floor exists, TrackProgress exists,
   `baked_length() > 0`. The bug produced a valid, non-degenerate track; the road
   and the lake both existed and merely disagreed. Presence assertions are blind to
   disagreement, and disagreement is this whole bug class.
3. **`Config.data` is treated as hygiene, never as an output.** Every challenge
   test calls `Config.reset()` in setup/teardown and nothing ever asserts on it, so
   "never written" is indistinguishable from "reset".
4. **Career's composite is tested as ingredients, never as a sequence.**
   `apply_event_config` is tested pure and scene entry is tested pure, but nothing
   asserts `_load_event_scene` is *apply-then-load*. When `ChallengeSession`
   reimplemented the composite there was no contract test to violate.

### Tests to add, ranked

All must obey CLAUDE.md: no pinned tunable/balance values, no dependence on a
specific catalogue entry, keep the suite under ~5 minutes (prefer bare-logic tests
and `SceneTestHelpers.minimal_world()` over full world generation).

**A. `test_challenge_session.gd` — a stage's config equals what the career path would build.**
Highest value: closes the CLASS, not the fields this bug happened to hit. Assert the
`GameConfig` produced by applying the current stage is **field-for-field identical**
to `RallySession.canonical_event_config(stage)`, by iterating
`cfg.get_property_list()` and diffing every `SCRIPT_VARIABLE`. A per-event field
added tomorrow is covered automatically; no value is pinned. No scene, sub-second.

**B. `test_menu_flow.gd` — the HQ hand-off seats the stage's config.**
Covers the actual buggy call site, which A does not. With
`ChallengeSession.auto_load_scenes = false`, poison `Config.data.track_seed = -1`,
run `hq._begin_challenge_start()`, assert `Config.data` agrees with
`ChallengeSession.current_stage_params()`. Add the twin for the **Resume** path — a
second, independent caller of the same hand-off.

**C. `test_menu_flow.gd` — the entry screen and the car park agree on eligibility.**
Drives item 4's fix. With an eligible car locked by an active run of a different
kind, assert that when the parked lineup is empty the Start button is disabled —
i.e. the label, the gate and the lineup derive ONE list. A relationship assertion;
no counts or car identities pinned. Note the existing
`test_hq_challenge_sections_reflect_the_current_kind_and_ceiling` is **tautological**
here: it computes its expected value with `eligible_cars`, the same call the UI
makes, so it can never catch the picker disagreeing.

**D. `test_challenge_session.gd` — resume restores the stage the run was left on.**
`test_resume_restores_an_active_session_from_a_current_stored_run` does **not** do
what its name says — it starts, abandons, and asserts resume *fails*. Nothing tests
that a resumed run lands on the right stage with the right banked times.

**E. `test_challenge_run_end.gd` — the completion reward is gated on placing.**
`try_grant_completion_reward`'s placement gate is entirely untested. Use the
existing `FakeRestClient` harness with two clearly-separated ranks (first of a large
field grants; last of a large field does not) so it holds for any reasonable
placement rule. Assert THAT a grant happened, never what.

**F. `test_challenge_session.gd` — a stage's damage and repair reach the driven car.**
Assert `report_event_result(t, hp_lost)` lowers the driven car's hp, and the pending
repair raises it back partially but not to full (a relationship, not the fraction).
Also assert the stage reward installs on `car_instance_id()` and not on another
owned car. Extend to cover item 5 once implemented.

**G. `test_challenge_session.gd` — the challenge board opts describe the stage just finished.**
`GlobalStandings._for_current_challenge_stage` posts **cumulative** time and a
**1-based** stage index, both different from the career path's per-stage time —
duplicated rule, divergent behaviour, and no test references the challenge fetcher
at all. Assert `is_challenge` is true, `stage_index` equals `events_completed()`,
and `time_ms` equals `cumulative_ms()` and therefore grows across stages.

**H. Harden `test_smoke.gd`'s challenge test** — drive it through the real hand-off
instead of hand-rolling `main.tscn`, and assert `Config.data` agrees with the stage.
Ranked last: A+B cover the logic at ~1% of the runtime. Only worth it to stop the
end-to-end test being a false negative.

### Testing hazard introduced by one-attempt-per-period

`Save` is a live autoload and `ChallengeSession.start` derives its period from the
WALL CLOCK, so every test file that finishes or wrecks a challenge writes a terminal
outcome for the REAL current Daily/Weekly/Monthly period. That record lives in the
shared in-memory `Save.profile` and leaks ACROSS test scripts: a test in
`test_challenge_session.gd` that plays a run to the end can make a later
`ChallengeSession.start(...)` in `test_smoke.gd` return false, with a confusing
"setup: run starts" failure far from the cause.

`test_smoke.gd` carries `Save.profile["challenge_results"] = {}` before its two
challenge starts for exactly this reason. (An earlier draft of this spec claimed those
lines had become unnecessary once quitting stopped being terminal — that was WRONG;
removing them makes both smoke tests fail. The cause is cross-FILE leakage of the real
period's outcome, not same-file teardown.)

Any new test that ends a challenge run must clear `challenge_results`, or the suite
becomes order-dependent. A sturdier fix worth considering: give the tests a way to
drive a SYNTHETIC period key instead of the wall clock, so no test can ever collide
with the real one.

### Tests deliberately rejected

- **"a challenge stage's road never crosses the waterline"** — the literal symptom.
  Needs full world generation (~15 s) on a seed that changes daily, and any
  threshold it picks is a tuning value. A+B catch the cause deterministically in
  milliseconds.
- **"the seed-retry loop recovers an incomplete challenge stage"** — genuine
  untested logic, but reaching it needs real `TrackGenerator` runs against a
  deliberately unroutable stage, and it would pin the stride constant and retry
  count. Rejected on the runtime budget.
- **Anything asserting a specific completion reward, ceiling value, stage count,
  placement boundary, or repair fraction** — all authored/tunable.

---

## Suggested order

EVERY item in this spec (1-13, with item 4 in its redesigned form) is IMPLEMENTED as
of 2026-08-01. What remains is only the follow-ups noted inside items 4 and 12 —
migrating the five test files off the deprecated `abandon()` alias and then deleting
it, and a synthetic period-key seam for tests.

Original ordering, kept as the rationale record:

0. **Item 2 first — the most severe defect in this spec.** A Daily's time never
   reaches Firestore on any run, and the player is ejected from the final standings
   without pressing Continue.
1. Item 1 (the class fix) — unblocks 3 and 7.
2. Item 10 — cloud saving silently stops for any player who never opens the account
   page, and the boot flow lets a new career start on top of the conflict.
   (Item 11 is its natural follow-on: the resolutions it raises are slow.)
3. Item 12 — "return to HQ" burns a challenge period. Compounds with item 5's
   one-attempt rule.
4. Item 13 — the title screen visibly repopulates at boot. Small, and it reuses the
   gate item 10 already touches.
5. Items 4, 9 — the remaining player-visible broken ones, both independent.
6. Item 5 (decided) and item 6.
7. Items 3 and 7 — after item 1.
8. Item 8 — cheap hardening.
9. Tests A–G alongside their matching items; H last if at all.

Keep `features/rally-challenge.md` and `features/cloud-save.md` in sync as items land.
