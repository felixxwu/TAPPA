# Rally Challenge (Daily / Weekly / Monthly)

A DiRT Rally-style seeded challenge: a stage set that's identical for every
player during a period (day/week/month), where time accumulates across the
stages and damage carries over between them. Full design:
`docs/superpowers/specs/2026-07-31-rally-challenge-design.md`.

**Tests:** `tests/headless/test_challenge_library.gd`, `tests/headless/test_challenge_session.gd`, `tests/headless/test_challenge_run_end.gd`, `tests/headless/test_challenge_leaderboard.gd`

## Pieces

- **`ChallengeLibrary`** (`scripts/challenge_library.gd`, `class_name`, static,
  no autoload) — pure period/seed math. `current_period(kind, unix_time) ->
  {key, stage_count, starts_at, ends_at}` for `ChallengeLibrary.DAILY` /
  `WEEKLY` / `MONTHLY`; `ceiling_for(period_key) -> float` (the period's
  rolled `CarPerformance` rating cap, picked from `CEILING_BAND_RATING`); `stages_for(key,
  stage_count)` rolls each stage's `TrackGenParams`. Same key → same seed →
  same stages/ceiling for every player; a new period rolls new values the
  moment its date key changes. `CHALLENGE_EPOCH` lives inside the key itself
  (bump it when the seed roll's inputs change).
- **`RunSession`** (`scripts/run_session.gd`, autoload) — the SHARED per-run state
  machine. It is not challenge-specific any more: the roguelike region run is its
  other caller, and which kind of run is live comes from a `RunMode` strategy. The
  spine (the stage cursor, the persisted run slot, the field repair, the car lock)
  and that seam are documented in **[region-runs.md](region-runs.md)**; only the
  challenge's own half lives here. Read surface: `is_active()`,
  `car_instance_id()`, `kind()`, `period_key()`, `stage_count()`,
  `events_completed()`, `current_stage_params()`. Lifecycle:
  `start(kind, owned_car, unix_time)` (the challenge's entry point — it builds a
  `ChallengeRunMode` and hands it to the generic `begin()`), `resume(unix_time)`,
  `resumable_run(profile, unix_time)` / `has_stale_run` / `discard_stale_run`
  (pure, testable with a synthetic profile). Per-stage flow:
  `report_event_result(elapsed_ms, hp_lost)`, `take_pending_repair()`,
  `pause_run()` (leave the run where it is, resumable). Nothing DNFs a run;
  `report_wreck()` is gone, and the deprecated `abandon()` alias is retired —
  call `pause_run()`.
- **`ChallengeRunMode`** (`scripts/challenge_run_mode.gd`, a `RunMode`) — the
  challenge's answers to the seam: rolled stages from `ChallengeLibrary`, **no
  target time and therefore no fail state**, the one-attempt-per-period outcome
  record, the car-eligibility rules (`eligible_cars` / `classify_cars` /
  `classify_car` / `displayed_ceiling`, §2 below) and the placement-gated
  completion reward.
- **The run slot.** `profile["run"]` (`Save.KEY_RUN`) persists
  `{mode, car_instance_id, stage_index, stage_times_ms, dnf, money_earned}` plus
  the challenge's own `{period_key, kind}` after every stage, so quitting mid-week
  resumes at the next stage with damage intact. It is ONE slot shared with the
  region run (pivot decision 27): starting a region run discards a paused challenge
  run and vice versa. It was `profile["challenge_run"]` before the generalisation.
- **`world.gd` / `global_standings.gd` integration** — a small, explicit mode
  branch at the one signal-routing call site
  (`StageManager.stage_completed` → `RunSession.report_event_result`
  instead of `RallySession.report_event_result` whenever
  `RunSession.is_active()`), and the per-stage interstitial
  (`GlobalStandings.for_current_stage()`) reading from `RunSession`
  instead of `RallySession` under the same condition. Every stage is still
  driven by the same `StageManager`/`TrackProgress`/countdown as a normal
  rally — nothing about *driving* a stage changes.
- **`DrivingContext`** (`scripts/driving_context.gd`, `class_name`, static, no
  autoload) — the one shared accessor for "which session is fielding a car,
  what p/w ceiling applies, and is this car locked". See "Car lock" below.
- **HQ entry point** (`scripts/hq_challenge.gd` / `scripts/hq_overlays.gd`) — see below.

## Stage-generation retry (unlike a rally's seed, a challenge's isn't pre-verified)

A rally event's seed is authored and lockfile-verified in advance
(`TrackCache`/`cache_tracks.sh`) — it's known to route before it ever ships.
A challenge stage's seed is rolled blind by `ChallengeLibrary.stages_for`
every period, with no such verification, so `TrackGenerator.generate` can
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
Rally events are deliberately excluded from this retry (their seeds are
already lockfile-verified — a live incomplete result there is a data bug
worth surfacing loudly, not silently routing around).

See `tests/headless/test_smoke.gd`'s
`test_entering_a_challenge_stage_generates_its_track` for the reproduction —
it drives a REAL challenge stage through `RunSession.current_stage_params()
-> TrackGenParams.for_event` (unlike the adjacent rally test, which pokes
`Config.data.track_*` directly and actually exercises the free-roam
`TrackGenParams.for_config` fallback, not `for_event`, so it could never
have caught this).

## Stage config application (the road-into-the-lake bug)

**A stage's rolled parameters reach the run through `Config.data`, and they are
seated at CONSUME time, in exactly one place:** `world.gd._ready` calls
`DrivingContext.apply_stage_config(Config.data)` before anything reads the config.
That resolver asks whichever session is active (challenge first, then career) for its
stage/event dict and forwards it to `StageConfig.apply_event_config`.

There is deliberately **no per-producer call**. `rally_session._load_event_scene`,
`run_session.continue_to_next_stage` and `hq._hand_off_to_challenge_scene` used
to each seat the config before loading the scene; those calls are gone. Pulling at
consume time means "a new scene-entry site forgot to seat the config" is not
expressible — which is what the original bug was.

This is load-bearing because the split is not obvious:
`TrackGenParams.for_event` reads only `seed` / `turn_count` / `width` /
`straightness` / `water_*` out of the event dict. **`forestiness`, `cliffiness`,
`surface_mix` and every `terrain_layer*` amplitude reach generation ONLY via
`cfg`** — and the lake actually rendered and collided against is built from
`cfg.track_water_level_m` in `world.gd._build_lakes` (and the car's
`set_water_query`), not from `params.water_level`.

Safe at consume time because `StageConfig.apply_event_config` is pure and idempotent: it reloads
the pristine `config/game_config.tres` on every call and pins every omitted field to
it. Session-less entries (free roam, benchmark, dev boot) no-op, so their deliberate
writes survive — free roam now goes through the same canonical writer
(`hq._prepare_free_roam`) rather than hand-writing a subset.

The original bug: a Daily stage whose road drove straight into the water. On
`daily:2026-07-31:e1` the stage rolled `water_level -5.0` /
`terrain_layer1_amplitude 18.84` while generation actually ran against the config
defaults `-10.0` / `30.0`, so the road dodged a waterline the renderer never used
over relief far more extreme than the roll intended. At that relief
`TrackGenerator.generate` returned `complete = false` outright, which the seed-bump
retry above then papered over.

Regression coverage lives in `test_challenge_session.gd` and `test_rally_session.gd`:
the resolved config is asserted **field-for-field identical** to
`StageConfig.canonical_event_config(stage)` (diffing every `SCRIPT_VARIABLE`, so a
per-event field added later is covered automatically), plus a session-less no-op
guard. Nothing pins a value; every one is a rolled/tunable number.

## Start-line staging (shared with career, not re-implemented)

A challenge stage opens with the **same pre-countdown start line** a career rally
event does — the briefing screen, the orbit-camera idle, the staged lead-in, and
the **Upgrades / Tune Car** overlays hosted there. See
[start-line.md](start-line.md) for the sequence itself (career version); this
section only records what differs for a challenge.

- **`world.gd._should_stage()`** gates staging on `Config.data.start_line_enabled`
  plus "a real event exists". It used to test `RallySession.is_active()` only, so a
  challenge run always fell through to `staged == false` and dropped the player
  straight into driving with no start line and no pre-race menus. It now answers for
  whichever session is running: a challenge stages iff
  `RunSession.current_stage_params()` is non-empty (the same
  "never strand the car in `STAGING` with nothing to launch it" guard the rally
  branch gets from `RallyLibrary.by_id`).
- `world.gd._ready()`'s rally and challenge branches are now **one block** — the two
  are mutually exclusive and want identical treatment (`_wire_session_signals()`,
  the staged start line, then that session's pending pit repair); only the
  `take_pending_repair()` source differs.
- **`world.gd._build_start_line()`** hands `StartLine` a synthetic event dict for a
  challenge: `{"name": "<Kind> Challenge", "restriction": {}}`. The performance ceiling is
  NOT smuggled in as a restriction key — restrictions are categorical — the start line
  asks `DrivingContext.rating_limit()` for it, so its launch gate and its Upgrades ceiling
  are literally the career code path, not a challenge copy of it. (The car park never commits an over-ceiling car
  — `hq.gd`'s `CarparkMode.CHALLENGE` branch makes the player tune down first — but
  the detune slider itself stays editable at the line either way, same as career;
  see "Car lock" below for why it's no longer frozen.)
- **`world.gd._arch_event_info()`** is now the single source of the event framing for
  BOTH the arch banners and the start-line header, and answers for a challenge:
  `"<Kind> Challenge"`, `RunSession.events_completed()` /
  `stage_count()`. `target_ms` stays `-1` — no rival field, no time to beat, and
  therefore **no rival ghost** either ([rival-ghost.md](rival-ghost.md) is gated on a
  classified P1 row, which a challenge run never has) — which
  `FinishArch` already renders as "omit the time row" (the same graceful empty state
  a session-less dev boot gets).
- **`start_line.gd` resolves the driven car through one helper**, `_driven_car()`
  — a thin wrapper over `DrivingContext.driven_car()` (see "Car lock" below),
  which answers `RunSession.car_instance_id()` when a challenge is active,
  else `RallySession`'s. All four consumers — the launch eligibility gate, the
  `TuningPanel`, the `UpgradesGrid`, and the live `refit_upgrades` on an edit — go
  through it, so there is exactly one answer to "whose car is on the line". The
  `TuningPanel`/`UpgradesGrid` components themselves are reused **unchanged**; they
  are per-car and were never rally-specific. `_stage_total()` is the same idea for
  "Stage N of M": the rally's authored `events` list, or the run's
  `RunSession.stage_count()` when there isn't one.
- **The rival-times reveal is omitted, not faked.** `_build_start_line` passes an
  EMPTY leaders array for a challenge, which takes `start_line.gd`'s pre-existing
  empty-leaders path (`_grid_ahead_count() == 0`): no grid cars spawn, the reveal
  card never shows, and Start fades straight to the countdown. No new hidden-state
  mechanism was added — this is the same path a dev/test harness with no field
  already used. `_build_overall_ranks()` likewise no-ops (it is guarded on
  `RallySession.is_active()`), so no bogus championship rank is invented.

Free roam is deliberately NOT folded into `_driven_car()`: it is session-less, never
stages (`_should_stage()` requires an active session, so no `StartLine` is ever built
for it), and its car may be a bare catalogue MODEL rather than an `OwnedCar`
(`RallySession.free_roam_model_id`) — a different question, answered once in
`world.gd`'s fielding chain.

## Car eligibility (§2)

Rally Challenge is the ONE place a performance ceiling survives — career rally
restrictions are purely categorical (see
`docs/superpowers/specs/2026-08-15-car-performance-rating-design.md`). The
ceiling is a **`CarPerformance` rating**, not hp/tonne.

`ChallengeRunMode.eligible_cars(kind, profile, unix_time)` lists the player's
owned cars whose *current build* rates at or under that period's ceiling **as
the player sees it** — see "Rounding" below. The build's rating comes from
`CarPerformance.rating(CarPerformance.merged_meta(owned, entry))`:
`merged_meta`, not `effective_meta` alone, because the rating must see tyres and
aero, which `effective_meta` withholds.

**Over the ceiling means plainly ineligible** (design doc D5). There is no
detune escape and no auto-disabling of parts — the player picks or builds
another car, and the upgrade screen's rating readout shows why. Recomputed live,
not cached at grant time. Zero eligible cars blocks starting outright — no
loaner car.

The check deliberately does NOT go through `RallyLibrary.ineligibility_reason`,
which handles only categorical keys now; the challenge's numeric ceiling stays
on its own path rather than reintroducing a numeric key into the shared
restriction schema.

### The ceiling band, and how it was authored

`ChallengeLibrary.CEILING_BAND_RATING` is the four-rung ladder a period's seed
picks from. It was re-authored from the old hp/tonne band `[120, 150, 180, 220]`
by rating the shipped roster and reading off the rating each hp/tonne figure
corresponded to, so each rung admits broadly the cars it used to. Ratings are
normalised against `CarPerformance.REFERENCE_CAR`, which is what keeps these
authored numbers meaningful when a benchmark knob moves. Tunable — never assert
a specific value in a test.

### Rounding: the ceiling is judged as displayed

`ChallengeLibrary.ceiling_for` returns a raw `float`, but every label prints it
whole and `CarPerformance.rating` returns an `int`. Comparing an int rating
against an unrounded ceiling would reject a car whose displayed rating exactly
equals the displayed cap, so the challenge path rounds in exactly one place:

- `ChallengeRunMode.displayed_ceiling(kind, unix_time) -> int` — the ceiling as
  printed, and the number eligibility is judged against. Every challenge label
  (`hq_challenge.gd`'s entry-screen subtitle and car-park banner) uses this
  rather than rounding locally.
- `ChallengeRunMode.classify_car(raw_ceiling, owned, entry)` — the single
  implementation of the comparison. Rounds `raw_ceiling`, then returns
  `{"state": READY | EXCLUDED}`.
- `ChallengeRunMode.classify_cars(kind, profile, unix_time)` — runs that over
  the profile and returns `{"ceiling": int, "eligible", "ready"}` (the two lists
  hold the same cars; the UI reads `eligible` as "what can enter" and `ready` as
  "what to name"). `eligible_cars` is just its `"eligible"` list, and the UI
  reads the buckets instead of re-deriving the comparison, so the rule cannot
  drift between the entry screen and the car park.

## HQ entry point (`hq_challenge.gd`)

The garage station's bottom action row is **Back / Career / Garage / Free
Roam / Challenge** (a single left/right `ButtonCursor`, `_garage_cursor` —
see [menus.md](menus.md) → "GARAGE"; Settings moved to the title screen's
own horizontal cursor row). **Challenge** opens
`_open_challenge_overlay()`: a modal `CanvasLayer` over the garage (built
once in `_ready` via `HqOverlays.build_challenge_overlay`, hidden until
opened — a "modal layer, not a `View` enum entry" shape, the same one the
since-removed title-screen Account overlay used). Opening it first discards any
stale stored run (`RunSession.has_stale_run` / `discard_stale_run`, so
a rolled-over period shows a fresh entry rather than a dead Resume button).

**Visual design: a dark detail-card sibling to the rally map-pin detail
panel**, not a flat button list. `HqOverlays.build_challenge_overlay` mirrors
`build_detail_overlay`'s exact shape: a `UITheme.MODAL_DIM` backing
`ColorRect` behind the content, a header row (`_challenge_title_label` +
`_challenge_subtitle_label`, the same two-line "title / dimmer subtitle"
stack as `_detail_title`/`_detail_region`), an `HSeparator`, then a status
column built from `hq._detail_heading(...)` + `hq._detail_wrap_label()` rows
— reused verbatim rather than re-invented, so the two panels read as one
design system. Every row is a short phrase (a HUD readout, not prose) — four
sections, each a SINGLE row (`hq._challenge_info_row`: a fixed-width dim
heading beside its value, not heading-above-value-below) so four sections
cost four lines, not eight:

1. **Win condition** — `Top 50%`, plus the CURRENT time on that cut line
   appended to the same row when the board can answer it: `Top 50% - 1:52.24`.
   **The label is DERIVED, not typed:** `hq_challenge.gd._CHALLENGE_WIN_CONDITION`
   is formatted (`"Top %d%%"`) from `ChallengeRunMode.CHALLENGE_TOP_FRACTION`, the
   same const the placing rule in `try_grant_completion_reward` compares against
   (`rank > ceili(float(total) * CHALLENGE_TOP_FRACTION)`), so the rule and its
   label cannot drift apart. That fraction is a const on `ChallengeRunMode`, not a
   `GameConfig` export — it decides who gets PAID, so it is a reward rule rather
   than a look/feel tunable.
   The time comes from `ChallengeLeaderboard.fetch_cutoff`, fired
   non-blocking by `hq_challenge.gd._fetch_challenge_cutoff` — the row is already
   correct without it, so there's no `CloudBusy` cover and an unreachable
   board just leaves the bare condition standing. **Fetched live, never
   stored**, for the same reason the completed placing is (§below): the cut
   moves as entrants arrive and times improve. Skipped entirely when signed
   out — the board is world-readable, but a signed-out player can't post a
   checkpoint, so there is no cut for them to make and no reason to spend a
   round trip per page visit. (The ceiling already rides on the header
   subtitle below, so there's no separate "entry requirement" row repeating
   it.)

   `fetch_cutoff` mirrors the gate, but against the field the player is ABOUT
   TO JOIN. The gate is `rank <= ceil(total_entries / 2)` evaluated once they
   are in the field, so the denominator to predict against is the current entry
   count **plus one** when they haven't posted yet (`_read_own` decides; an
   existing entry is already counted). Beating the current rank-r time is what
   puts you at rank r, so the line is the entry at `ceil(field / 2)` — order by
   final cumulative time ascending and read the row at offset
   `ceil(field / 2) - 1` (`_run_query` takes `limit`/`offset` for this).

   Worked through: **1 rival** → field 2 → need rank ≤ 1 → beat the current P1.
   **2 rivals** → field 3 → need rank ≤ 2 → beat the current P2. **3 rivals** →
   field 4 → need rank ≤ 2 → still the current P2. Counting only the existing
   entries put the line a whole place too high in the even cases and quoted P1's
   time when P2's was what mattered.

   While fewer players have FINISHED than that rank the query is empty —
   reported as `{"ok": true, "exists": false}`, i.e. any finish currently makes
   the cut.

   **Both decorations are guarded by `hq.gd._challenge_refresh_generation`, not
   by comparing the label text.** Every `_refresh_challenge_overlay` bumps the
   counter; each async query captures it and writes only while it is current.
   The obvious-looking alternative ("is the row still exactly the string I left
   it at?") is broken here: `_open_challenge_overlay` runs `UITheme.enforce`
   immediately after building the row, which UPPERCASES every `Label`, so a
   mixed-case comparison never matched and the answer was silently dropped.
   The win row is written only through `hq_challenge.gd._set_challenge_win_text(tail)`,
   which ALWAYS rebuilds it from `_CHALLENGE_WIN_CONDITION` (uppercasing via
   `UITheme.caps`, since this row is rewritten asynchronously long after the
   one-shot enforce pass) rather than appending to whatever is on screen. While
   the query is in flight the row reads **`TOP 50% - LOADING…`** instead of
   leaving a gap the time pops into; an unreachable board or an empty cut line
   clears it back to the bare condition, so the placeholder is never a resting
   state. Rebuilding rather than appending is what stops the placeholder being
   cemented in front of the answer.

   **Both answers are cached per period key for the duration of one visit**
   (`hq.gd._challenge_cutoff_cache` / `_challenge_placing_cache`). Switching
   Daily/Weekly/Monthly re-renders the whole screen, so without this every tab
   flip re-issued both queries and flashed `LOADING…` on rows the player had
   already seen answered; a cached answer renders synchronously with no
   placeholder at all. Keyed by period key, so a period rolling over mid-session
   re-asks by itself. The cache is stored BEFORE the generation staleness check,
   so an answer that arrives after the player has switched tabs still counts —
   switching back is instant rather than paying for the same query twice.
   **Invalidated in `_close_challenge_overlay`**: leaving for the garage is the
   invalidation point, so the next visit re-asks a board that has kept moving.
   Only `ok` answers are cached — a failure is a transient condition (offline,
   board unreachable), not a value, so it retries on the next tab visit instead
   of sticking for the whole session.

   The **progress row's COMPLETED state follows the identical contract** via
   `_set_challenge_completed_text(tail)`: `COMPLETED - LOADING…` while the
   placing query is in flight, `COMPLETED - 2 OF 3` when it answers, and back to
   a bare `COMPLETED` if the board can't be reached. Both placeholders are set
   only AFTER every "we are not going to ask" guard (signed out, no period, no
   board), so a row that will never gain a value never advertises one.
2. **Win reward** — the payout is **money** now, a single flat
   `GameConfig.challenge_completion_money` (see *Completion reward* below). The
   entry screen that rendered this died with the hub; the flat rebuild should read
   the config value rather than restating a number in prose, which is what the old
   `_CHALLENGE_REWARD_TEXT` mirror did and what left the screen able to lie about
   the payout after a retune.
3. **Eligible cars** — NAMES them (not just a count), mirroring the rally
   pin detail panel's own eligibility read-out exactly:
   `_qualifying_cars_text` (capped at `MAX_QUALIFY_NAMES`, tailing off as
   `"+N more"`) over the ready-now names, plus a second line
   `"Needs tune: ..."` for any only reachable with a tune
   (`ChallengeRunMode.eligible_cars`, which already folds those in — §2), or
   "No eligible car" with Start disabled.
   **While a run for this kind is in progress this row instead names the ONE
   locked car it was started with** (gold): the choice is already committed for
   the rest of the period, so listing the wider eligible set would imply a switch
   that isn't possible — and naming it explains why that car has vanished from
   the garage and career pickers.
4. **Current progress** — the stored run for this kind, if any:
   `IN PROGRESS - N/M stages` (gold), `COMPLETED - R of N` (green), `DNF` (red),
   or `Not started`. The
   in-progress wording is deliberate: a bare `0 / M stages` reads identically to
   "not started" and gave no hint that the kind was holding a car locked. The
   colour override is cleared explicitly on the `Not started` branch, since the
   label is reused across kind switches.

**The kind picker is a visible Daily/Weekly/Monthly tab row in the header
(`_challenge_kind_buttons`).** Each tab is `Control.FOCUS_ALL`, and arriving via
focus IS the selection: `focus_entered` calls `_select_challenge_kind(kind_str)`
directly — no separate confirm press. Keyboard/gamepad reach the tabs by native
left/right focus-neighbour movement (`menu_nav.gd`, the same mechanism every other
`MenuNav`-driven page uses).

**Tabs are pointer-selectable, and a tap SELECTS ONLY.** They were originally
built `mouse_filter = MOUSE_FILTER_IGNORE` — deliberately not pointer-interactive
at all — which left a touch device with **no way whatsoever to change kind**: the
tabs are the only control that picks one, and `menu_left`/`menu_right` are
keyboard/gamepad-only actions. They are hit-testable now, but the naive fix is a
trap: each tab's `pressed` is wired to **start** the challenge
(`_on_challenge_tab_activated`), and a pointer press would both move focus onto the
tab (selecting) and fire `pressed` in the same gesture — so tapping "Weekly" to
look at it would launch the Weekly run. `hq_overlays.gd::_tab_pointer_select`
handles the tab's `gui_input`, grabs focus itself (that is the selection) and calls
`accept_event()`. This works because Godot's `Control::_call_gui_input` emits the
`gui_input` SIGNAL first and then skips the `_gui_input` virtual entirely when the
viewport reports the event handled — so `BaseButton`'s own press handling never
runs, and the original invariant holds for touch too: **`pressed` only ever arrives
from `ui_accept`.** The current kind's tab is highlighted
with `UITheme.GOLD` (vs. `INK_DIM` for the others), refreshed every repaint.
`_open_challenge_overlay` explicitly re-focuses the CURRENT kind's own tab
on every open (`_challenge_kind_button`), not just tree-order-first, so
reopening the screen after switching kind doesn't reset the cursor to Daily.

**Enter/gamepad-accept on a focused tab acts as Start**, exactly as if the
Start button itself had focus — the player doesn't have to tab down to
Start once they've settled on a kind. Each tab's `pressed` signal (which,
with `mouse_filter` set to IGNORE, can ONLY ever fire via keyboard/gamepad
activate-while-focused, never a stray click) is wired to
`_on_challenge_tab_activated`, which checks `_challenge_start_button.disabled`
itself before calling `_on_challenge_start_pressed` — a *different* button's
`disabled` flag doesn't block another control's `pressed` signal on its own,
so this has to be checked explicitly rather than relying on Godot to block it.
Above the tab row (via up/down) sit the ordinary Back/Start focus stops —
switching kind re-derives the whole screen instantly, and Resume is only
offered for the kind whose stored run matches (`_select_challenge_kind`).

A **Start/Resume** button: "Resume" (calls `RunSession.resume`
directly — no car to pick, the locked car is already fixed) whenever
`RunSession.resumable_run(Save.profile, unix_time)` is non-empty *for
the currently-shown kind*; otherwise "Start" now **opens the real 3D car
park** (`_enter_challenge_car_screen`, a new `CarparkMode.CHALLENGE`)
restricted to this kind's eligible cars, instead of committing straight from
a focused list item.

`unix_time` is read via `Time.get_unix_time_from_system()` at the point it's
needed (there's no injected clock seam in this codebase — `auth_service.gd`
reads the wall clock the same way).

### Car park hand-off (`CarparkMode.CHALLENGE`)

`_enter_challenge_car_screen(kind_str)` mirrors `_enter_car_screen`'s shape
for a normal rally: it sets `_carpark_mode = CarparkMode.CHALLENGE`, calls
`_build_challenge_lineup(kind_str)`, frames the lot, and shows the "no
eligible car" empty state if none qualify. `_build_challenge_lineup` parks
exactly what `ChallengeRunMode.classify_cars(kind, Save.profile, unix_time)`
reports as `"eligible"` (challenge-lock-excluded via `Save.is_challenge_locked`),
— it does NOT redo the comparison itself (see "Rounding" above). A car either
rates under the ceiling or is not parked at all: there is no
"parks looking eligible, prompts at Start" middle state for a challenge, since
an over-ceiling build has no detune escape.

`_on_start_pressed`'s mode-dispatch `match` gained a `CarparkMode.CHALLENGE`
branch alongside `STARTER`/`SWAP`/`WHEELS`/`GARAGE`/`FREEROAM`: instead of
falling through to the `RallySession.start_rally` path every other mode
skips past, it checks `_detune_needed` (over-limit prompt if positive) and
otherwise calls `_begin_challenge_start()`, which calls
`RunSession.start(kind, owned_car, unix_time)` and then the SAME
loading-screen + `change_scene_to_file` hand-off `_on_challenge_start_pressed`
already used for Resume — factored into a shared
`_hand_off_to_challenge_scene()` so both paths (Resume, and committing the
car park) go through one scene-transition tail. Backing out of the car park
(`_car_back`) with `CarparkMode.CHALLENGE` returns to the garage and reopens
the challenge overlay (rather than the map table a rally back-out reaches),
so the player lands back where they started.

**Design decision — a new `CarparkMode` value, not a reuse of `RALLY`:** the
rally branch's `_on_start_pressed` code path is intertwined with
`_selected_rally_id`, `RallyLibrary.by_id`, and drivetrain-switch bookkeeping
(`RallySession.register_detune_revert` and friends) that a
challenge has no equivalent for (no authored rally, no drivetrain
restriction rule). The drivetrain half of that bookkeeping is gone entirely —
`_drivetrain_needed` / `RallySession.register_drivetrain_revert` and the
switch-at-Start-then-revert flow they drove are deleted, because conversion now
carries a per-car star price and is a garage decision (see
`hq_carpark.gd::_build_eligible_lineup`) — parameterizing that single
`match` arm to serve both would have meant branching on "is this a
challenge?" *inside* the RALLY case anyway. A dedicated `CHALLENGE` value
keeps each mode's intent a single, git-blameable `match` arm, matching how
every other special car-park job (`GARAGE`, `FREEROAM`, `SWAP`, `STARTER`,
`WHEELS`) already gets its own value rather than overloading `RALLY`.

Quitting mid-run (`pause_menu.gd.quit_to_hq`) checks
`RunSession.is_active()` before `RallySession.is_active()` and calls
`RunSession.pause_run()` — the alias `abandon()` that used to sit in front of it is retired, so
quitting to HQ leaves the run parked at its current stage rather than ending it.

## Car lock (§2) — the RUN is locked to a car, the CAR is not reserved

Starting a run commits it to `car_instance_id` for its duration. That is the whole
meaning of the lock: **you cannot switch to a different car for that run.** It does
NOT reserve the car — it stays fully usable in career rallies, free roam, the garage,
engine swaps and upgrades while the run is in progress.

Two earlier designs were both WRONG and have been removed:

- **Freezing the detune slider.** An early draft set `editable = false` on the slider
  for the locked car. It looked broken (the slider silently wouldn't move, with no
  explanation) and duplicated the p/w enforcement a career rally already does through
  the close-button gate (`UpgradesGrid.bind_close_button` / its rating gate). Removed; the
  ceiling is enforced by that one shared mechanism.
- **Excluding the car everywhere else.** A later fix made the garage's car picking, the
  engine-swap partner list, the career rally lineup and the (since-removed) post-stage
  reward reveal all skip the locked car. That made an owned car unusable across the whole
  game, which was never the intent. All four exclusions are gone.

`DrivingContext.is_car_locked` / `Save.is_challenge_locked` remain as the predicate
for "is this run committed to this car", and both carry comments saying not to use
them to gate anything outside the run. The full "a challenge locks the RUN, not the car"
rationale now lives in `hq.gd` → `_swap_targets` (the engine-swap partner list), which
`_build_eligible_lineup` points at rather than restating. "You can't switch cars mid-run" needs no
enforcement of its own — `RunSession.start` already refuses while a run is
active, and the entry screen shows Resume plus the single committed car rather than a
picker.

**Accepted consequence — mid-run repair.** Because the car is usable between stages,
a player can repair or upgrade it (or drive a career rally, which applies its own pit
repairs) and return to the next stage in better condition. This weakens the
damage-carry-over contract, and the user has explicitly accepted it: a challenge is a
time competition, not a survival one. Do not add stage-boundary condition snapshotting
to "protect" carry-over.

## One attempt per period

A finished run is TERMINAL for its period — completed OR DNF'd — and cannot be started
again until the period rolls over. `RunSession` records the outcome in
`Save.profile["challenge_results"]`, keyed by period key, and `start()` refuses any
period with an outcome. The entry screen reads `COMPLETED` (green) or `DNF` (red) and
disables Start.

**The completed row shows the player's placing, fetched LIVE every time**
(`hq_challenge.gd._fetch_challenge_placing`). The row renders `COMPLETED` immediately and
becomes `COMPLETED - 3 of 42` when `Cloud.challenge_leaderboard.fetch_final_rank`
answers. The rank is deliberately NOT stored with the outcome: `challenge_results`
is pruned to LIVE periods, so every completed record on screen belongs to a board
that is still taking entries — the field keeps growing and faster times keep pushing
the player down, so a rank cached at finish time is stale by construction. The fetch
is non-blocking (no `CloudBusy` cover — the label is already correct and nothing is
gated on the answer), re-checks that the player has not switched tabs before writing,
and on any failure (signed out, no username, board unreachable) simply leaves the row
at a bare `COMPLETED` rather than rendering `0 of 0`.

`challenge_results` is deliberately SEPARATE from `profile["run"]` rather than folded
into it: `resumable_run` keys on `profile["run"]` being non-empty, so a terminal record
stored there would make the game try to RESUME a finished run. The map is pruned to
the live periods on every write, so it holds at most three records rather than growing
one entry per day forever.

**NOTHING DNFs a challenge run any more.** Damage can never wreck the car (see
[damage.md](damage.md)), so `report_wreck()` and `_end_as_dnf` are both gone and there
is no live path that ends a run as a DNF: a run either completes every stage or is
left with `pause_run()` / `abandon()` (see below), which record no outcome at all.
The `dnf` shape SURVIVES either side of that, and is not dead code: `_dnf` is still
read back from a persisted `profile["run"]`, still written into the persisted run dict
and the finished-run result, and the entry screen still renders a stored `DNF`
outcome in red. The cloud half likewise stands —
`ChallengeLeaderboard.post_dnf`, the `isDnfFlip()` rules branch, and
`world.gd._on_challenge_run_finished`'s `result["dnf"]` arm are all still there for
legacy/persisted runs, they simply never fire from a run started today.

## Leaving a run (pause, not abandon)

`RunSession.pause_run()` is the non-terminal exit: it clears `_active` /
`_stage_running`, leaves `profile["run"]` persisted at its current stage index and
banked times, records NO outcome, and deliberately does NOT emit `run_finished` (that
signal is what makes `world.gd` post a DNF to the board). The entry screen's Resume
picks it straight back up; the in-progress stage's partial time is discarded and that
stage is re-driven.

The pause-menu "Quit to HQ" and `Benchmark.start` both use it, and the pause-menu
confirm says the run is saved rather than the career copy's "your progress is lost".
`abandon()` survives only as a deprecated alias for `pause_run()`, kept so existing
test teardowns compile — new code should call `pause_run()`.

## Cloud leaderboard (§5)

One Firestore collection, `challenge_runs/{period_key}/entries/{uid}`
(`firestore.rules`), mirroring `stage_times`'s trust model one level deeper —
world-readable, owner-only write, updated after every stage rather than only
at the end. Each `cum_ms_N` field is write-once; `dnf` is the one field that
flips `false -> true`, gated by its own rules branch:

- `maxStage(periodKey)` — daily→1, weekly→4, monthly→10, regex-matched on the
  key's kind prefix (`^daily:.*` etc — the same prefix `ChallengeLibrary`'s
  key format always produces).
- `isValidCreate()` — a document is only ever born at `stages_completed == 1`
  with a real `cum_ms_1`.
- `isStageAdvance(periodKey)` — binds the new checkpoint's field NAME to
  `before.stages_completed + 1` (closing the checkpoint-skip hole a naive
  "any cum_ms_* write" rule would leave open), blocks once `dnf` is true,
  enforces strict monotonicity against the previous checkpoint.
- `isDnfFlip()` — `dnf` false→true and nothing else.
- The `request.resource.data[field]`-style dynamic-key indexing this needs is
  flagged in the rules as unverified against a live Firestore Rules emulator
  (the documented fallback is an explicit `k in [1..N]` chain).

`scripts/cloud/challenge_leaderboard.gd` (`ChallengeLeaderboard`, instantiated
as `Cloud.challenge_leaderboard` alongside `Cloud.leaderboard`) is the client
half, same "never cost a player their run" posture as `Leaderboard` — every
failure collapses to `{"ok": false}` / a no-op, no retry loop:

- `post_checkpoint(period_key, k, cum_ms, identity)` — creates the doc at
  k==1, advances it at k>1. Pre-checks the same transition the rules enforce
  (reads the doc first; refuses out-of-order or post-DNF advances client-side
  before ever attempting the write) so a failed/skipped checkpoint simply
  **permanently strands that run's board entry at its last successful post**
  (§5) — `RunSession`/`GlobalStandings` never retries or attempts an
  out-of-order catch-up write.
- `post_dnf(period_key)` — flips `dnf`; a silent no-op if no document exists
  yet (a DNF before the first successful checkpoint leaves no trace at all,
  by design) or the run already ended.
- `fetch_standings_at(period_key, k)` — top rows ordered by `cum_ms_k`
  ascending (Firestore's `orderBy` naturally excludes any document missing
  that field — exactly "hasn't reached stage k yet", no extra filter needed),
  each row's OWN `cum_ms_k` value, the player's own row/rank, `total_entries`
  (every document that has ever posted `cum_ms_1`, regardless of `dnf`), and
  `not_yet_complete` (`total_entries` minus how many have reached stage k —
  a single count line, never per-row placeholders).
- `fetch_final_rank(period_key, stage_count)` — thin wrapper over
  `fetch_standings_at` at the final checkpoint, for the completion-reward
  placement gate below.
- `FirestoreCodec` gained `bool_value`/`bool_field` (previously string/int
  only) to encode/decode `dnf` as a real Firestore boolean rather than the
  string `"true"`, which the rules' `d.dnf == false` comparisons require.

**UI layer deleted (roguelike pivot, decision 30).** `GlobalStandings`
(`global_standings.gd`) and its host `standings.gd`/`standings.tscn` are gone —
along with `scripts/cloud/leaderboard.gd` (`Leaderboard`, the per-stage global
board and `Cloud.leaderboard`) and the `stage_times` Firestore rules. The
paragraph that used to describe `GlobalStandings`'s `is_challenge` routing
path and its `Leaderboard.display_rows` reuse is removed with it — there is no
longer a screen that posts to `Cloud.challenge_leaderboard` at all. The client
half (`ChallengeLeaderboard`, `post_checkpoint` / `post_dnf` /
`fetch_standings_at` / `fetch_final_rank`, described above) and the Firestore
rules are untouched and still correct; they just have no caller until stage 3
(`todo/roguelike-pivot-plan.md`) gives the challenge a new run-summary host.

## Stage-to-stage advancement (the between-stage interstitial)

**The screen this section describes is deleted.** `standings.tscn` /
`scripts/standings.gd` and `scripts/global_standings.gd` were removed in the
roguelike pivot (decision 30, `todo/roguelike-pivot.md`) along with the global
per-stage leaderboards they were built to host a page for. `world.gd` no
longer loads them. The section below is kept as-is because everything it
documents on the **`RunSession` side** — `continue_to_next_stage()`,
`current_stage_times_ms()` / `run_times_ms()`, `take_pending_repair()`, the
`standings_ready` / `run_completed` signals, and the session-latching bug fix
— is still live and still correct; only the UI that consumed it is gone. A
challenge run currently has **no working between-stage screen at all** until
stage 3 (`todo/roguelike-pivot-plan.md`) gives it one, built on the new
`RunSession`/run-summary screen that replaces `podium.tscn` (decision 19) —
read this section for what that replacement has to reproduce on the
`RunSession` side, not for what currently renders.

`world.gd` used to load `standings.tscn` after EVERY stage of a challenge,
exactly as it did after a career rally event (both are driven by the same
`StageManager` / `TrackProgress`), so `standings.gd` served both sessions.

- **`RunSession.continue_to_next_stage()`** is the counterpart to
  `RallySession.continue_to_next_event()` and the interstitial's single exit when
  a challenge is active. `report_event_result` has already advanced
  `_stage_index` and parked the field repair in `_pending_repair`, so the whole
  of "enter the next stage" is **re-entering `main.tscn`** — `world.gd` reads
  `current_stage_params()` / `take_pending_repair()` on boot just as it did for
  stage 1 — plus `apply_stage_config(Config.data)`, exactly as
  `RallySession._load_event_scene` applies its event config immediately before
  the scene change (see "Stage config application" below). It emits `stage_started(stage_index)`
  (mirroring `RallySession.event_started`) whether or not `auto_load_scenes` is
  on, so tests can observe the advance with no scene load.
- There is deliberately **no "or resolve results" arm**: `report_event_result`
  already ends the run on the final stage (`_finish_locally`), so by then
  `is_active()` is false and the call is a no-op. The final stage's Continue instead
  emits `run_completed`, which `world.gd._on_challenge_run_finished` awaits — the
  player dismisses the final standings themselves rather than being ejected mid-read.
  (An earlier version of this file claimed a challenge's final stage "never shows the
  interstitial at all". That was FALSE — `standings_ready` is emitted unconditionally
  — and the false claim is probably why the bug below survived so long.)

- **THE SESSION IS LATCHED, NEVER RE-ASKED.** `_finish_locally` clears `_active`
  BEFORE `standings_ready` is emitted, so on the final stage the interstitial builds
  against an already-inactive session. Every read in `standings.gd` used to be its own
  `if RunSession.is_active():`, and all six silently fell through to the idle
  career session: the header read "stage 0 of N", both boards rendered an empty field,
  Continue was a dead button, and `GlobalStandings` posted to the career `stage_times`
  board with a blank `stage_key`. Because `STAGE_COUNTS[DAILY] == 1`, a Daily's only
  stage IS its final stage — **so no Daily time was ever posted to Firestore at all,
  on 100% of runs.** `standings.gd` now pins the mode once in `_ready` (or via
  `set_challenge_mode`) and `GlobalStandings.for_current_stage(force_challenge)` takes
  it as an argument.

- **A challenge skips page 1.** It has no AI opponents — only real people on the
  online board — so the local event standings would be a table holding nothing but the
  player's own row. The interstitial opens straight on the world board and tears down
  page 1, so Back never offers a page that was never shown. Keyed off the LATCHED mode,
  so it holds on the final stage too.
- **`standings.gd` branches every session read** on `RunSession.is_active()`,
  the same convention `GlobalStandings.for_current_stage()` uses: `_stages_done()`
  / `_stage_total()` / `_driven_instance_id()` are the helpers, and `_advance()`'s
  final step calls `continue_to_next_stage()` instead of `continue_to_next_event()`.
  The ladder is otherwise identical — and it is now strictly **two rungs**, page 1
  local standings → page 2 world board → resume. The old third rung, the reward
  reveal, went with the per-stage upgrade draw (`_collect_reward` /
  `_reward_pending` / `_stage_upgrade` / `_reveal` are all gone from `standings.gd`,
  and `RunSession._stage_upgrade` / `stage_upgrade()` with them) — see
  [reward-system.md](reward-system.md).
- **A challenge has no local standings at all.** It has no rivals, so there is
  nothing to rank: `standings.gd` feeds page 1's two sections an EMPTY row list in
  challenge mode (and `_ready` frees the page outright, opening straight on the
  world board). What a challenge run reports instead are plain millisecond TIMES —
  `RunSession.current_stage_times_ms()` (the stage just driven, as a
  one-element list, `[]` before any stage completes) and `run_times_ms()` (every
  completed stage, in stage order, summing to `cumulative_ms()`). These two used to
  be `current_event_standings()` / `current_standings()`, which handed
  `RallyLibrary.build_standings` an empty field to get the player's own row back.
### Known deferred: field-repair timing

`report_event_result` computes the field repair at stage END, whereas
`RallySession` applies it at the START of the next event (`_enter_event`, after
the between-event garage visit). Left as-is deliberately: challenge stages are
back-to-back (interstitial → next stage, with no HQ/garage visit in between), so
there is no player-visible moment between the two points, and the repair is
consumed identically either way by `world.gd`'s boot-time `take_pending_repair()`.
Worth revisiting only if a between-stage garage screen is ever added.

## Completion reward (§6)

**There is no per-stage reward.** A stage pays nothing but its time on the board;
the random per-event upgrade draw was deleted game-wide (see
[reward-system.md](reward-system.md)), so `report_event_result` only accumulates
the time and parks the field repair. One path remains:

- **Per-challenge** (finishing every stage, no DNF): `RunSession.
  try_grant_completion_reward(result)` awaits `Cloud.challenge_leaderboard.
  fetch_final_rank` and grants iff `rank <= ceil(total_entries / 2)` —
  checked against the board AS IT STANDS at that moment (an early finisher is
  compared to a smaller field; accepted as a deliberate generous quirk, not a
  bug). Skipped entirely (returns `{}`) if the run was a DNF, or if no cloud
  rank is available at all (signed out, no username, or the final checkpoint
  never posted — same graceful skip). Reward per kind:

  **The payout is MONEY** (`todo/roguelike-pivot.md` decision 21). It used to be a
  flat per-kind star amount plus a placement bonus on
  `RallyLibrary.stars_for_placement`; the whole star ledger is deleted, and the
  reward — which decision 15 keeps, since the challenge survives — was re-pointed at
  the new currency. It is a **single flat `GameConfig.challenge_completion_money`**,
  banked through `Save.add_money`, rather than the per-stage/fast-bonus pair a region
  run earns: a challenge has no target time to be fast against, and its whole reward
  IS the placement, so a curve keyed to stage count would only re-price the same
  single event. The amount is a tunable in `config/game_config.tres` — do not quote
  it anywhere.

  This income is **renewable over real time**, deliberately: a period rolls over and
  the challenge can be entered again, so it is a money source that keeps flowing
  independently of how deep the player is in the region ladder.

  Returns `{"placed", "rank", "total_entries", "item_id", "money"}` (`item_id`
  always `""`, since nothing item-shaped is granted).
  `world.gd._completion_reward_body` renders whatever actually landed, and
  `won_something` gates the card on `money > 0`, so nothing banked is ever silent.

### Where the run's end is resolved (`world.gd._on_challenge_run_finished`)

This handler is the challenge's counterpart to `RallySession._resolve_results` —
the one place a finished run is turned into a reward. It fires from
`RunSession._finish_locally` — the only remaining path, now that `_end_as_dnf` is
gone — while the player is **still in the driving scene**, before the hand-off to HQ.

- **Clean finish** → `await ChallengeRunMode.try_grant_completion_reward(result)`,
  then, on a grant, a plain `ConfirmPopup` card ("Challenge Complete!", placing +
  what was won) over the world — a plain card is the right shape for a reward
  moment that isn't mid-interstitial. Skipped headless (the grant still runs headless — see below). A
  failed/unavailable placement fetch just grants nothing and continues to HQ.

  **The grant and its reveal cannot diverge, but not via `ConfirmPopup.
  open_committing`.** That helper (added for a since-removed HQ reward popup) acquires the
  modal slot FIRST and skips its `commit` callable entirely when the slot is
  refused — the right contract when "never happened" is a true, harmless
  fallback state. The challenge completion reward does not have that fallback:
  by the time `run_finished` fires, `RunSession._finish_locally` has
  already recorded this period's outcome and cleared `profile["run"]`
  (`start`/`resume` both refuse once `period_outcome` is set), so the period is
  terminal — there is no "reward pending reveal" state to retry later, and
  `try_grant_completion_reward` itself can't be deferred behind a modal check
  anyway (`fetch_final_rank` has to be judged against this run's own
  just-posted final checkpoint). Making the grant conditional on modal
  availability would therefore not defer it on refusal, it would silently keep
  a reward the player could never be told about — worse than the original bug,
  which dropped only the reveal, never the reward. So `world.gd` grants
  unconditionally (as above) and instead **guarantees** the reveal: the
  `ConfirmPopup.open(..., allow_stack = true)` call passes `allow_stack`, the
  same escape hatch `CloudBusy.report_failure` uses for its "must be seen even
  over another modal" failure notice, so modal contention can never refuse the
  card — at worst it stacks on top of whatever else is on screen.
- **DNF** → `Cloud.challenge_leaderboard.post_dnf(RunSession.period_key())`,
  fired **without `await`**: the house posture is that no cloud call ever costs
  the player anything, so the return to HQ must not wait on (or surface) the
  network. The coroutine resolves against the `Cloud` autoload's board, which
  outlives the scene. A null board is a no-op.
- Both paths then set `RallySession.return_to_garage` and change to `hq.tscn`.

## Testing

- `tests/headless/test_challenge_library.gd` — `current_period`/seed/ceiling
  roll determinism and stability (same key → same roll; different key → a
  different one; a period-boundary crossing rolls a new value), the
  `:eN`-suffixed key format, `stages_for`'s `seed = base_seed + i` contract.
  Never pins the specific ceiling-band values or turn-count ranges (tunable).
- `tests/headless/test_challenge_session.gd` — start/resume/resumable_run
  staleness, `eligible_cars`/`classify_cars` filtering and bucket partition (via
  `CarFixtures`, never the real catalogue), the displayed-ceiling boundary rule
  (`classify_car` with a self-authored fractional ceiling: a car whose displayed
  rating equals the displayed ceiling is `READY`; one over it is `EXCLUDED`)
  and `displayed_ceiling == roundi(current_ceiling)`, stage accumulation/final-stage termination, `pause_run()`
  leaving a resumable run rather than ending it, the completion-reward DNF
  short-circuit (driven from a persisted `dnf`, since no live path sets one), plus the full
  multi-stage drive-through (`report_event_result` + `continue_to_next_stage()`
  for every stage of the longest kind, reaching `events_completed() ==
  stage_count()` and `is_active() == false` — the regression test for "a
  Weekly/Monthly run can't get past stage 1") and the field-of-one local
  standings.
- `tests/headless/test_challenge_run_end.gd` — `world.gd._on_challenge_run_finished`
  on a cheap `SceneTestHelpers.minimal_world()` boot, with a real `ChallengeLeaderboard`
  on a `FakeRestClient` swapped onto `Cloud`: a clean finish consults the board for
  placement (and still reaches HQ when the fetch fails), a DNF hands off to HQ
  IMMEDIATELY with `post_dnf` still in flight behind it, and a null board is
  harmless. Also covers the grant/reveal ordering guarantee: a headless finish
  with a qualifying placement still grants the reward (the star balance moves) with
  no popup attempted, and — with `_headless` forced false and
  another `ConfirmPopup` already on screen — the reward card still opens
  (stacked, via `allow_stack`) instead of being refused, and the hand-off to HQ
  waits for it.
- `tests/headless/test_challenge_leaderboard.gd` — reuses
  `test_cloud_leaderboard.gd`'s fake-REST-client seam: create-at-k=1,
  advance-at-k>1, out-of-order/post-DNF refusal (client-side, before ever
  attempting the write), `post_dnf`'s no-op-on-missing-doc, `fetch_standings_at`'s
  rank/total/not-yet-complete assembly, `FirestoreCodec.bool_value`/`bool_field`
  round-trip.
- `tests/headless/test_start_line.gd` — a challenge run's start line: both pre-race
  menus bind to `RunSession`'s locked car (not `RallySession`'s inactive -1),
  an upgrade edit refits the live car, no rival card is shown and Start fades
  straight to the countdown, and the header counts the run's own stages.
- `tests/headless/test_smoke.gd` — `_should_stage()` returns true for a challenge
  stage (and still honours `start_line_enabled`), and `_arch_event_info()` reports
  the challenge's name/stage/count with no time-to-beat.
- `tests/headless/test_menu_flow.gd` — the Challenge entry point's nav
  (opens, navigable, `menu_back` closes it), instant kind-switching via
  `menu_left`/`menu_right` regardless of focus, the five sections reflecting
  the current kind/ceiling (via `ChallengeRunMode.eligible_cars`), the
  no-eligible-car block disabling Start, Start opening the REAL car park
  (`CarparkMode.CHALLENGE`, asserted on `hq._eligible`/`hq._carpark_mode`)
  then Start↔Resume switching once a run is stored, and the
  over-ceiling-but-detune-reachable car parking eligible and routing Start to
  the "Too powerful" agreement (mirroring the normal-rally car-park test).
  Also the challenge side of the standings interstitial: it renders a stage as a
  field of one, and a non-final stage's Continue actually advances the run to the
  next stage.
