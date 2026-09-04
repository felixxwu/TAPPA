# Rally Challenge (Daily / Weekly / Monthly)

A DiRT Rally-style seeded challenge: a stage set that's identical for every
player during a period (day/week/month), where time accumulates across the
stages and damage carries over between them. Retained wholesale by the
roguelike pivot (`todo/roguelike-pivot.md` decision 15) — it's structurally the
same object as a region run ("N sequential stages, no rivals, with a fail
rule"), which is exactly why it shares `RunSession` with the region run rather
than keeping its own session type.

**Tests:** `tests/headless/test_challenge_library.gd`, `tests/headless/test_challenge_session.gd`, `tests/headless/test_challenge_run_end.gd`, `tests/headless/test_challenge_leaderboard.gd`

**This doc owns the challenge's own half only.** The shared run spine —
`RunSession`, the `RunMode` strategy seam, the persisted run slot, the field
repair, the car lock — is documented in [region-runs.md](region-runs.md); read
that first if a term here (`RunMode`, `to_record()`, `stage_target_ms`) is
unfamiliar.

## Pieces

- **`ChallengeLibrary`** (`scripts/challenge_library.gd`, `class_name`, static,
  no autoload) — pure period/seed math. `current_period(kind, unix_time) ->
  {key, stage_count, starts_at, ends_at}` for `ChallengeLibrary.DAILY` /
  `WEEKLY` / `MONTHLY`; `ceiling_for(period_key) -> float` (the period's rolled
  `CarPerformance` rating cap, from `CEILING_BAND_RATING`); `stages_for(key,
  stage_count)` rolls each stage's `TrackGenParams`. Same key → same seed →
  same stages/ceiling for every player; a new period rolls new values the
  moment its date key changes.
- **`RunSession`** (`scripts/run_session.gd`, autoload) — the shared per-run
  state machine (see [region-runs.md](region-runs.md)). Entry point for a
  challenge: `RunSession.start(kind, owned_car, unix_time)`, which builds a
  `ChallengeRunMode` and hands it to the generic `begin()`.
- **`ChallengeRunMode`** (`scripts/challenge_run_mode.gd`, a `RunMode`) — the
  challenge's answers to the strategy seam: rolled stages from
  `ChallengeLibrary`, **no target time and therefore no fail state** (a
  challenge is scored by cumulative time on a cloud board, not survived stage
  by stage), the one-attempt-per-period outcome record, the car-eligibility
  rules (§2 below) and the placement-gated completion reward (§6 below).
- **The run slot.** `profile["run"]` (`Save.KEY_RUN`) persists
  `{mode, car_instance_id, stage_index, stage_times_ms, dnf, money_earned}`
  plus the challenge's own `{period_key, kind}` (`ChallengeRunMode.to_record`)
  after every stage, so quitting mid-week resumes at the next stage with
  damage intact. It is **one slot shared with the region run** (decision 27):
  starting a region run discards a paused challenge run, behind
  `RunSession.discard_run` (§ below), and vice versa.
- **`world.gd` integration** — a single, mode-agnostic signal wire, not a
  branch: `StageManager.stage_completed → RunSession.report_event_result`, and
  the per-stage interstitial listens on `RunSession.standings_ready`. There is
  no more RallySession/ChallengeSession split to route between — `RunSession`
  is the sole session type now (`RallySession` and the career it drove are
  fully deleted, decision 5).
- **`DrivingContext`** (`scripts/driving_context.gd`, `class_name`, static, no
  autoload) — the one shared accessor for "which session is fielding a car,
  what rating ceiling applies, is this car locked". `rating_limit()` reads a
  challenge's ceiling and returns `NO_LIMIT` for a region run (a region run has
  no car ceiling by design — its difficulty is the clock, decision 11).

## Stage-generation retry (unlike a rally's seed, a challenge's isn't pre-verified)

A rally event's seed is authored and lockfile-verified in advance
(`TrackCache`/`cache_tracks.sh`) — it's known to route before it ever ships.
A challenge stage's seed is rolled blind by `ChallengeLibrary.stages_for` every
period, with no such verification, so `TrackGenerator.generate` can
occasionally exhaust all of its internal `MAX_RESTARTS` and return an
INCOMPLETE result (as few as zero corners placed) for a genuinely hard
`(seed, turn_count, reserved-corridor)` combination — this was an observed
real bug: a Daily challenge with `turn_count` in the low-40s hit exactly this
and produced a track with **zero baked length** (empty terrain).

`world.gd._generate_track` guards against it: when `RunSession.is_active()`
and the primary `generate_cached` result comes back incomplete, it
deterministically bumps the stage's seed by a large stride
(`base_seed + attempt * 104729`) and retries `TrackGenerator.generate` a few
more times. This preserves the "identical stage for every player" contract —
every client hits the exact same failure on the exact same period key, so
retrying with the SAME bumped-seed sequence means every client converges on
the same (different) working seed, not an unplayable one. If every retry also
fails (never observed, but theoretically possible), it falls back to
whatever partial track was found and logs a `push_error` naming the period/
seed/turn_count for follow-up, rather than silently shipping an empty stage.
**A region run's authored events skip this retry deliberately** — their seeds
are already lockfile-verified (`data/track_cache.json`), so a live incomplete
result there is a data bug worth surfacing loudly, not silently routing
around; see [region-runs.md](region-runs.md) → "The stage draw".

See `tests/headless/test_smoke.gd`'s
`test_entering_a_challenge_stage_generates_its_track` for the reproduction —
it drives a REAL challenge stage through `RunSession.current_stage_params()
-> TrackGenParams.for_event`.

## Stage config application (the road-into-the-lake bug)

**A stage's rolled parameters reach the run through `Config.data`, and they are
seated at CONSUME time, in exactly one place:** `world.gd._ready` calls
`DrivingContext.apply_stage_config(Config.data)` before anything reads the
config. That resolver asks `RunSession` (whichever kind of run is active) for
its current stage dict and forwards it to `StageConfig.apply_event_config`.

There is deliberately **no per-producer call** — a scene-entry site cannot
forget to seat the config, because nothing seats it except this one consume-time
pull. `TrackGenParams.for_event` reads only `seed`/`turn_count`/`width`/
`straightness`/`water_*` out of the stage dict — **`forestiness`, `cliffiness`,
`surface_mix` and every `terrain_layer*` amplitude reach generation ONLY via
`cfg`** — and the lake actually rendered and collided against is built from
`cfg.track_water_level_m` in `world.gd._build_lakes`, not from `params.water_level`.

Safe at consume time because `StageConfig.apply_event_config` is pure and
idempotent: it reloads the pristine `config/game_config.tres` on every call and
pins every omitted field to it. Session-less entries (benchmark, dev boot)
no-op, so their deliberate writes survive.

The original bug: a Daily stage whose road drove straight into the water — the
stage rolled `water_level -5.0` / `terrain_layer1_amplitude 18.84` while
generation ran against config defaults `-10.0` / `30.0` because nothing had
seated the rolled values before generation ran. Regression coverage lives in
`test_challenge_session.gd`: the resolved config is asserted **field-for-field
identical** to `StageConfig.canonical_event_config(stage)`, plus a
session-less no-op guard.

## Start-line staging (shared with the region run, not re-implemented)

A challenge stage opens with the pre-countdown start line — the briefing
screen, the orbit-camera idle, and the **Tune Car** overlay (decision 29 — no
Upgrades entry any more, since parts are gone). This is the same `StartLine`
scene a region run's stages use; nothing here is challenge-specific except the
few call sites noted below.

- **`world.gd._should_stage()`** gates staging on `Config.data.start_line_enabled`
  plus a real stage existing — `RunSession.is_active() and not
  RunSession.current_stage_params().is_empty()`. This answers for **either**
  run kind identically; there is no per-kind branch left to keep in sync.
- **`world.gd._build_start_line()`** hands `StartLine` a synthesized event
  dict, `{"name": String(info["rally_name"])}`, where `info` comes from
  `_arch_event_info()` (below) — there is no authored `RALLIES` restriction
  dict behind either kind of run any more, so `StartLine`'s `_rally` is always
  effectively open-class. See [rally-roster.md](rally-roster.md) → "Dead code
  awaiting demolition" for why `RallyLibrary.ineligibility_reason` is still
  called here but is a permanent no-op today.
- **`world.gd._arch_event_info()`** is the single source of event framing for
  both the arch banners and the start-line header, for either run kind:
  `RunSession.display_name()`, `RunSession.events_completed()` /
  `stage_count()`, and `RunSession.stage_target_ms()` for the time row (`0` for
  a challenge — no target, no time row, no rival ghost; a region run's target
  is seated by `RunSession.set_stage_track()` once the track is generated —
  see [region-runs.md](region-runs.md) → "Where the target is seated").
- **There is no rival-times reveal any more, for either kind.** `StartLine`'s
  MENU fades straight to the countdown (decision 29 — the start line's REVEAL
  phase died with the rival field; only its MENU survives).
- **`start_line.gd` resolves the driven car through `DrivingContext.driven_car()`**,
  which reads `RunSession.car_instance_id()`. The `TuningPanel` component is
  reused unchanged — it was always per-car, never rally-specific.

## Car eligibility (§2)

Rally Challenge is the **one** place a performance ceiling survives — a region
run deliberately has none (its difficulty is the clock, decision 11). The
ceiling is a `CarPerformance` rating, not hp/tonne.

`ChallengeRunMode.eligible_cars(kind, profile, unix_time)` lists the player's
owned cars whose *current build* rates at or under that period's ceiling **as
the player sees it** — see "Rounding" below. The build's rating comes from
`CarPerformance.rating(CarPerformance.merged_meta(owned, entry))`:
`merged_meta`, not `effective_meta` alone, because the rating must see tyres
and aero, which `effective_meta` withholds.

**Over the ceiling means plainly ineligible** (design doc D5). There is no
detune escape and no auto-disabling of parts — the player picks or builds
another car. Recomputed live, not cached at grant time. Zero eligible cars
blocks starting outright — no loaner car.

### The ceiling band, and how it was authored

`ChallengeLibrary.CEILING_BAND_RATING` is the four-rung ladder a period's seed
picks from, authored against `CarPerformance.REFERENCE_CAR`. Tunable — never
assert a specific value in a test.

### Rounding: the ceiling is judged as displayed

`ChallengeLibrary.ceiling_for` returns a raw `float`, but every label prints it
whole and `CarPerformance.rating` returns an `int`. Comparing an int rating
against an unrounded ceiling would reject a car whose displayed rating exactly
equals the displayed cap, so the challenge path rounds in exactly one place:

- `ChallengeRunMode.displayed_ceiling(kind, unix_time) -> int` — the ceiling as
  printed, and the number eligibility is judged against.
- `ChallengeRunMode.classify_car(raw_ceiling, owned, entry)` — the single
  implementation of the comparison: rounds `raw_ceiling`, returns
  `{"state": READY | EXCLUDED}`.
- `ChallengeRunMode.classify_cars(kind, profile, unix_time)` — runs that over
  the profile and returns `{"ceiling": int, "eligible", "ready"}` (the two
  lists hold the same cars — a UI reads `eligible` as "what can enter" and
  `ready` as "what to name"). `eligible_cars` is just its `"eligible"` list.

## The flat entry screen does not exist yet

**Everything this section used to document — `hq_challenge.gd`'s garage-station
overlay, its Daily/Weekly/Monthly tab row, the win-condition/reward/eligible-cars/
progress readout, `hq.gd`'s `CarparkMode.CHALLENGE` car-park hand-off — is gone.**
`hq.gd`, `hq_challenge.gd`, `hq_overlays.gd` and `hq_carpark.gd` were all deleted
in the diegetic-hub demolition (decision 9). Every piece of business logic those
files orchestrated (the win-condition fetch, the caching/generation-guard
pattern, the per-visit cache, the signed-out short-circuit, the car picker) is
recorded as a requirement in `todo/roguelike-pivot.md` → "Salvaged from
`hq_challenge.gd` — what the flat rebuild MUST reproduce" — read that section
before building the replacement screen, not this doc, since this doc no longer
has a live UI to describe. Stage 4+ of the pivot plan (`todo/roguelike-pivot-plan.md`)
is where the flat hub, including a challenge entry point, gets built; nothing
in `scripts/` today opens a challenge except a direct `RunSession.start(kind,
owned_car, unix_time)` call, which currently has **no menu caller at all**.

If you're implementing that screen: the pieces above (`ChallengeRunMode.classify_cars`,
`displayed_ceiling`, `CHALLENGE_TOP_FRACTION`, `try_grant_completion_reward`)
are all still live and unit-tested — build the new screen on them, don't
re-derive any of the comparisons they already own.

## Car lock (§2) — the RUN is locked to a car, the CAR is not reserved

Starting a run commits it to `car_instance_id` for its duration: **you cannot
switch to a different car for that run.** It does NOT reserve the car — it
stays fully usable in the garage, free tuning, engine swaps and wheel swaps
while the run is in progress (there is no more career rally to also use it in,
since career is deleted).

`DrivingContext.is_car_locked` / `Save.is_challenge_locked` remain the
predicate for "is this run committed to this car" — do not use them to gate
anything outside the run itself. "You can't switch cars mid-run" needs no
enforcement of its own: `RunSession.begin` already refuses while a run is
active.

**Accepted consequence — mid-run repair.** Because the car is usable between
stages, a player can repair or tune it between a challenge's stages and return
in better condition than the pure per-stage field repair would leave it. This
weakens the damage-carry-over contract, and the user has explicitly accepted
it: a challenge is a time competition, not a survival one.

## One attempt per period

A finished run is TERMINAL for its period — completed OR DNF'd (a persisted
`dnf` is only reachable on a run resumed from an older build; nothing sets one
live any more, see below) — and cannot be started again until the period rolls
over. `ChallengeRunMode.record_outcome` writes it into
`Save.profile["challenge_results"]`, keyed by period key, and
`RunSession.start` refuses any period with an outcome already recorded.
`challenge_results` is pruned to LIVE periods on every write, so it holds at
most three records rather than growing one entry per day forever, and is kept
deliberately SEPARATE from `profile["run"]` (`resumable_run` keys on that being
non-empty, so a terminal record stored there would make the game try to RESUME
a finished run).

**NOTHING DNFs a challenge run any more.** Damage can never wreck the car (see
[damage.md](damage.md)), so a challenge either completes every stage or is
left with `pause_run()` / `discard_run()` (below), neither of which is a
"crash" outcome in the old sense.

## Leaving a run: pause vs. discard (decision 48 — discarding BURNS the attempt)

Two different exits, and they are **not** the same thing any more:

- **`RunSession.pause_run()`** — the non-terminal exit. Clears the active
  flags, leaves `profile["run"]` persisted at its current stage index and
  banked times, records **no outcome**, and does not emit `run_finished` (that
  signal is what makes `world.gd` post a DNF to the board — pausing must not
  trigger it). Resuming picks the run straight back up at the paused stage; the
  in-progress stage's partial time is discarded and that stage is re-driven.
  The pause menu's "Quit to HQ" and `Benchmark.start` both call this. **There
  is no `abandon()` alias any more** — it was retired in the `RunSession`
  generalisation (a stale reference to it surviving anywhere is a leftover from
  before this rewrite).
- **`RunSession.discard_run(unix_time)`** — decision 27's one-slot rule means
  starting a region run while a challenge is paused (or vice versa) has to do
  *something* with the paused run, and decision 48 settles what: **it BURNS
  the attempt.** Before clearing the slot, it calls the paused run's mode's
  `record_outcome({"dnf": true, "completed": false, "cumulative_ms": 0,
  "abandoned": true}, unix_time)` — for a challenge, that's exactly
  `ChallengeRunMode.record_outcome`, so the period is marked finished (DNF) and
  cannot be restarted from stage 1 until it rolls over. Without this, the
  one-slot rule would hand out a free retry: discarding a paused period used to
  write no outcome at all, so a player could reroll a Daily until they liked
  their opening stage by starting-then-discarding it under a region run.
  **The screen offering the discard must say plainly that quitting costs the
  attempt** — a silent burn is the unfair version of this rule, and the confirm
  dialog is what stops it from being silent. `discard_stale_run(unix_time)` is
  the same burn, reserved for a run whose period has already rolled over on its
  own (still an attempted-and-lost run, not a free one).

## Cloud leaderboard (§5)

One Firestore collection, `challenge_runs/{period_key}/entries/{uid}`
(`firestore.rules`) — world-readable, owner-only write, updated after every
stage rather than only at the end. Each `cum_ms_N` field is write-once; `dnf`
is the one field that flips `false → true`, gated by its own rules branch:

- `maxStage(periodKey)` — daily→1, weekly→4, monthly→10, regex-matched on the
  key's kind prefix.
- `isValidCreate()` — a document is only ever born at `stages_completed == 1`
  with a real `cum_ms_1`.
- `isStageAdvance(periodKey)` — binds the new checkpoint's field NAME to
  `before.stages_completed + 1`, blocks once `dnf` is true, enforces strict
  monotonicity against the previous checkpoint.
- `isDnfFlip()` — `dnf` false→true and nothing else.

`scripts/cloud/challenge_leaderboard.gd` (`ChallengeLeaderboard`, instantiated
as `Cloud.challenge_leaderboard`) is the client half, same "never cost a
player their run" posture as every other cloud path — every failure collapses
to `{"ok": false}` / a no-op, no retry loop:

- `post_checkpoint(period_key, k, cum_ms, identity)` — creates the doc at
  k==1, advances it at k>1. Pre-checks the transition client-side before
  attempting the write, so a failed/skipped checkpoint permanently strands that
  run's board entry at its last successful post — `RunSession` never retries or
  attempts an out-of-order catch-up write.
- `post_dnf(period_key)` — flips `dnf`; a silent no-op if no document exists
  yet or the run already ended.
- `fetch_standings_at(period_key, k)` — top rows ordered by `cum_ms_k`
  ascending, the player's own row/rank, `total_entries`, `not_yet_complete`.
- `fetch_final_rank(period_key, stage_count)` — thin wrapper over the above at
  the final checkpoint, for the completion-reward placement gate below.

**Global per-stage leaderboards are gone** (decision 30) — `cloud/leaderboard.gd`,
`global_standings.gd`, `standings.gd`/`standings.tscn` and the `stage_times`
Firestore rules are all deleted. The **challenge's own** board
(`ChallengeLeaderboard`, `challenge_runs/{period_key}/entries`, described
above) is unaffected — decision 30 dropped the per-*stage* boards, not the
challenge's per-*period* one, which decision 15 explicitly keeps.
`firestore_board.gd` (the shared REST base both boards used) survives for this
reason. `username_popup.gd` still owns `profile["username"]`, which the
challenge board needs.

## The between-stage interstitial

`world.gd` connects `RunSession.standings_ready` to `_present_standings_overlay`
for **any** active run — challenge or region, identically, since neither one
gets a special case any more. That function:

1. Stops the replay recorder, hides the driving HUD, spins up a `ReplayCamera`
   over the just-finished stage.
2. Resets any knocked-over props (felled trees, toppled signs) so the replay
   plays back against an intact stage.
3. **Loads `Scenes.STANDINGS` (`res://standings.tscn`) and instantiates it**,
   sets `panel.set_challenge_mode(RunSession.is_active())`, and shows it as a
   `CanvasLayer` overlay.

### Known bug: the between-stage interstitial loads a deleted scene

**`standings.tscn` / `scripts/standings.gd` do not exist any more** — they were
deleted along with the old per-stage career leaderboard (decision 30, see
above), but `scripts/scenes.gd`'s `STANDINGS` constant was never repointed and
`world.gd._present_standings_overlay` still calls
`load(Scenes.STANDINGS).instantiate()` unconditionally on every
`standings_ready` emission that isn't headless — which is **every stage clear
of every challenge or region run**, in a windowed (non-headless) build.
`load()` on a path with nothing there returns `null`; calling `.instantiate()`
on `null` is a runtime error. This is a real, currently-shipping code bug, not
a documentation problem — flagging it here rather than fixing it, since fixing
`.gd`/`.tscn` files is out of scope for this pass. Whoever builds the run
summary screen (decision 19 — `podium.tscn`'s replacement, which is also where
this interstitial's replacement logically lives per `todo/roguelike-pivot.md`
stage 3/9) needs to either repoint `Scenes.STANDINGS` at a real scene or change
`_present_standings_overlay`'s call site before this can be exercised outside
a headless test run.

**What the `RunSession` side of this interstitial still does correctly**
(this part is real code, worth building the replacement screen on rather than
re-deriving): `continue_to_next_stage()` is the single exit into the next
stage — `report_event_result` has already advanced the cursor and parked the
field repair, so re-entering the scene at boot re-reads
`current_stage_params()`/`take_pending_repair()` exactly as stage 1 did. There
is deliberately no "or resolve results" arm, since `report_event_result`
already ends the run on the final stage or a missed target, making a
post-finish call to `continue_to_next_stage()` a no-op by construction. On the
final stage, `run_finished` is what a caller waits on instead (see below).
`current_stage_times_ms()` / `run_times_ms()` are the plain-int-list readouts a
summary screen would render (the just-finished stage, and every stage so far).

## Completion reward (§6)

**There is no per-stage reward.** A stage pays nothing but its time on the
board (or, for a region run, money — see [region-runs.md](region-runs.md)).
One path remains, and it's placement-gated:

- **Per-challenge** (finishing every stage, no DNF):
  `ChallengeRunMode.try_grant_completion_reward(result)` awaits
  `Cloud.challenge_leaderboard.fetch_final_rank` and grants iff
  `rank <= ceil(total_entries * CHALLENGE_TOP_FRACTION)` (0.5 today — top
  half), judged **against the board as it stands at that moment** (an early
  finisher is compared to a smaller field — a deliberate generous quirk, not a
  bug). Skipped entirely (`{}`) if the run was a DNF or no cloud rank is
  available at all (signed out, no username, or the final checkpoint never
  posted).

  **The payout is money** (decision 21 — stars are gone). A single flat
  `GameConfig.challenge_completion_money`, banked through `Save.add_money`,
  rather than the per-stage/fast-bonus pair a region run earns: a challenge has
  no target time to be fast against, and its whole reward IS the placement, so
  a curve keyed to stage count would just re-price the same single event. This
  income is renewable over real time — a period rolls over and the challenge
  can be entered again — independent of region-ladder progress.

  Returns `{"placed", "rank", "total_entries", "item_id", "money"}` (`item_id`
  always `""` — nothing item-shaped is granted).

### Where the run's end is resolved (`world.gd._on_challenge_run_finished`)

Fires from `RunSession.run_finished`, while the player is still in the driving
scene, before the hand-off to the hub.

- **Clean finish** → the final stage's interstitial (`_present_standings_overlay`,
  once it's fixed — see the bug above) is awaited before the reward is
  fetched, so the fetch happens after the last checkpoint has actually posted;
  a `CloudBusy` cover wraps the round trip. `try_grant_completion_reward` runs
  unconditionally (there's no "reward pending reveal" state — the period is
  already terminal by the time this fires), and the reveal card
  (`ConfirmPopup`, `allow_stack = true`) is guaranteed to show rather than
  silently dropped if another modal has the slot.
- **DNF** → `Cloud.challenge_leaderboard.post_dnf(period_key())`, fired
  **without `await`** — no cloud call may cost the player anything, so the
  return to hub never waits on the network.
- Both paths hand off to the hub (`Scenes.hub_path()` — a plain flat shell now,
  decision 9; `RallySession.return_to_garage` no longer exists to set).

## Testing

- `tests/headless/test_challenge_library.gd` — `current_period`/seed/ceiling
  roll determinism and stability, the `:eN`-suffixed key format,
  `stages_for`'s `seed = base_seed + i` contract. Never pins the specific
  ceiling-band values or turn-count ranges (tunable).
- `tests/headless/test_challenge_session.gd` — start/resume/resumable_run
  staleness, `eligible_cars`/`classify_cars` filtering and bucket partition (via
  `CarFixtures`, never the real catalogue), the displayed-ceiling boundary
  rule, `displayed_ceiling == roundi(current_ceiling)`, stage
  accumulation/final-stage termination, `pause_run()` leaving a resumable run
  rather than ending it, the completion-reward DNF short-circuit, and the full
  multi-stage drive-through for the longest kind.
- `tests/headless/test_challenge_run_end.gd` — `world.gd._on_challenge_run_finished`
  on a cheap `SceneTestHelpers.minimal_world()` boot, with a real
  `ChallengeLeaderboard` on a `FakeRestClient` swapped onto `Cloud`: a clean
  finish consults the board for placement (and still reaches the hub when the
  fetch fails), a DNF hands off immediately with `post_dnf` still in flight
  behind it, and a null board is harmless.
- `tests/headless/test_challenge_leaderboard.gd` — uses the `FakeRestClient`
  seam (`tests/headless/fake_rest_client.gd`) directly: create-at-k=1,
  advance-at-k>1, out-of-order/post-DNF refusal, `post_dnf`'s no-op-on-missing-doc,
  `fetch_standings_at`'s rank/total/not-yet-complete assembly. (An earlier
  version of this doc said this file "reuses `test_cloud_leaderboard.gd`'s
  fake-REST-client seam" — `test_cloud_leaderboard.gd` no longer exists, since
  the global per-stage board it tested is deleted; the seam it used lives in
  its own file and both test files use it directly.)
- `tests/headless/test_start_line.gd` — a challenge run's start line: both
  pre-race menus bind to `RunSession`'s locked car, an upgrade edit refits the
  live car, no rival card is shown and Start fades straight to the countdown,
  and the header counts the run's own stages.
- `tests/headless/test_smoke.gd` — `_should_stage()` returns true for a
  challenge stage, and `_arch_event_info()` reports the challenge's
  name/stage/count with no time-to-beat.
- `tests/headless/test_menu_flow.gd` — still carries Challenge-entry-point
  coverage written against the deleted `hq_challenge.gd`/`hq.gd`. Per
  `todo/roguelike-pivot.md` decision 47, this 5880-line file is salvaged, not
  deleted, but only *after* the flat shell exists — it currently fails to parse
  cleanly (146 parse errors, per that decision) because it drives a controller
  that no longer exists. Do not trust anything this file currently claims to
  cover for the Challenge screen; read decision 47 before touching it.
