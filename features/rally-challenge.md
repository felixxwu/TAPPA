# Rally Challenge (Daily / Weekly / Monthly)

A DiRT Rally-style seeded challenge: a stage set that's identical for every
player during a period (day/week/month), where time accumulates across the
stages and damage carries over between them. Full design:
`docs/superpowers/specs/2026-07-31-rally-challenge-design.md`.

## Pieces

- **`ChallengeLibrary`** (`scripts/challenge_library.gd`, `class_name`, static,
  no autoload) — pure period/seed math. `current_period(kind, unix_time) ->
  {key, stage_count, starts_at, ends_at}` for `ChallengeLibrary.DAILY` /
  `WEEKLY` / `MONTHLY`; `ceiling_for(period_key) -> float` (the period's
  rolled hp/tonne cap, picked from `CEILING_BAND_HP_TONNE`); `stages_for(key,
  stage_count)` rolls each stage's `TrackGenParams`. Same key → same seed →
  same stages/ceiling for every player; a new period rolls new values the
  moment its date key changes. `CHALLENGE_EPOCH` lives inside the key itself
  (bump it when the seed roll's inputs change).
- **`ChallengeSession`** (`scripts/challenge_session.gd`, autoload) — the
  per-run state machine, parallel to `RallySession` rather than a reuse of it
  (no rival/`OpponentCache`, no special-event unlock, no
  `Save.complete_rally` — so no career star credit; its own star payout is
  placement-based, see *Completion reward* below). Read surface: `is_active()`, `car_instance_id()`,
  `kind()`, `stage_count()`, `events_completed()`, `current_stage_params()`.
  Lifecycle: `start(kind, owned_car, unix_time)`, `resume(unix_time)`,
  `resumable_run(profile, unix_time)` / `has_stale_run` / `discard_stale_run`
  (pure, testable with a synthetic profile), `eligible_cars(kind, profile,
  unix_time)` (§2 below). Per-stage flow: `report_event_result(elapsed_ms,
  hp_lost)`, `take_pending_repair()`, `report_wreck()`, `abandon()` (both end
  the run as a DNF — no-retry, matching the rest of the game).
  `profile["challenge_run"]` persists `{period_key, kind, car_instance_id,
  stage_index, stage_times_ms, dnf}` after every stage so quitting mid-week
  resumes at the next stage with damage intact.
- **`world.gd` / `global_standings.gd` integration** — a small, explicit mode
  branch at the one signal-routing call site
  (`StageManager.stage_completed` → `ChallengeSession.report_event_result`
  instead of `RallySession.report_event_result` whenever
  `ChallengeSession.is_active()`), and the per-stage interstitial
  (`GlobalStandings.for_current_stage()`) reading from `ChallengeSession`
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

`world.gd._generate_track` guards against it: when `ChallengeSession.is_active()`
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
it drives a REAL challenge stage through `ChallengeSession.current_stage_params()
-> TrackGenParams.for_event` (unlike the adjacent rally test, which pokes
`Config.data.track_*` directly and actually exercises the free-roam
`TrackGenParams.for_config` fallback, not `for_event`, so it could never
have caught this).

## Stage config application (the road-into-the-lake bug)

**A stage's rolled parameters reach the run through `Config.data`, and they are
seated at CONSUME time, in exactly one place:** `world.gd._ready` calls
`DrivingContext.apply_stage_config(Config.data)` before anything reads the config.
That resolver asks whichever session is active (challenge first, then career) for its
stage/event dict and forwards it to `RallySession.apply_event_config`.

There is deliberately **no per-producer call**. `rally_session._load_event_scene`,
`challenge_session.continue_to_next_stage` and `hq._hand_off_to_challenge_scene` used
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

Safe at consume time because `apply_event_config` is pure and idempotent: it reloads
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
`RallySession.canonical_event_config(stage)` (diffing every `SCRIPT_VARIABLE`, so a
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
  `ChallengeSession.current_stage_params()` is non-empty (the same
  "never strand the car in `STAGING` with nothing to launch it" guard the rally
  branch gets from `RallyLibrary.by_id`).
- `world.gd._ready()`'s rally and challenge branches are now **one block** — the two
  are mutually exclusive and want identical treatment (`_wire_session_signals()`,
  the staged start line, then that session's pending pit repair); only the
  `take_pending_repair()` source differs.
- **`world.gd._build_start_line()`** hands `StartLine` a synthetic event dict for a
  challenge: `{"name": "<Kind> Challenge", "restriction": {"pw_max": ceiling}}` —
  the SAME rally-shaped restriction `hq.gd`'s challenge car park and
  `ChallengeSession.eligible_cars` already judge cars against, so the start line's
  launch eligibility gate and its Upgrades p/w cap are literally the career code
  path, not a challenge copy of it. (The car park never commits an over-ceiling car
  — `hq.gd`'s `CarparkMode.CHALLENGE` branch makes the player tune down first — but
  the detune slider itself stays editable at the line either way, same as career;
  see "Car lock" below for why it's no longer frozen.)
- **`world.gd._arch_event_info()`** is now the single source of the event framing for
  BOTH the arch banners and the start-line header, and answers for a challenge:
  `"<Kind> Challenge"`, `ChallengeSession.events_completed()` /
  `stage_count()`. `target_ms` stays `-1` — no rival field, no time to beat — which
  `FinishArch` already renders as "omit the time row" (the same graceful empty state
  a session-less dev boot gets).
- **`start_line.gd` resolves the driven car through one helper**, `_driven_car()`
  — a thin wrapper over `DrivingContext.driven_car()` (see "Car lock" below),
  which answers `ChallengeSession.car_instance_id()` when a challenge is active,
  else `RallySession`'s. All four consumers — the launch eligibility gate, the
  `TuningPanel`, the `UpgradesMenu`, and the live `refit_upgrades` on an edit — go
  through it, so there is exactly one answer to "whose car is on the line". The
  `TuningPanel`/`UpgradesMenu` components themselves are reused **unchanged**; they
  are per-car and were never rally-specific. `_stage_total()` is the same idea for
  "Stage N of M": the rally's authored `events` list, or the run's
  `ChallengeSession.stage_count()` when there isn't one.
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

`ChallengeSession.eligible_cars(kind, profile, unix_time)` lists the player's
owned cars whose *current* effective power-to-weight (installed upgrades +
detune, via `UpgradeLibrary.effective_meta` + `CarLibrary.power_to_weight_hp_tonne`)
is at or under that period's ceiling **as the player sees it** — see "Rounding"
below — **or reachable by lowering
detune**, consistent with how a career rally treats an over-the-cap car
(`hq_carpark.gd._qualifying_detune_for` / `RallyLibrary.qualifying_detune`):
`ChallengeSession.qualifying_detune_for({"restriction": {"pw_max": ceiling}},
owned, entry)` judges the car at FULL power and returns the absolute detune
fraction that would fit it, or `-1.0` if none does. A car isn't excluded just
because its slider happens to sit above what the ceiling needs right now —
it shows up eligible-with-a-note, and the player tunes down (in the garage,
before starting) same as any other rally. Recomputed live, not cached at
grant time. Zero eligible cars (none reachable even via detune) blocks
starting outright — no loaner car, no forced auto-detune.

### Rounding: the ceiling is judged as displayed

`ChallengeLibrary.ceiling_for` returns a raw `float`, but every label prints it
whole (`"%d hp/t max"`), and `CarLibrary.power_to_weight_hp_tonne` is itself
rounded. Comparing a rounded car figure against an unrounded ceiling would
reject a car whose displayed hp/tonne exactly equals the displayed cap — the
confusing case `hq_carpark.gd._qualifying_detune_for` and
`RallyLibrary.ineligibility_reason` already `roundi(pw_max)` to avoid. So the
challenge path rounds too, in exactly one place:

- `ChallengeSession.displayed_ceiling(kind, unix_time) -> int` — the ceiling as
  printed, and the number eligibility is judged against. Every challenge label
  (`hq_challenge.gd`'s entry-screen subtitle and car-park banner) uses this
  rather than rounding locally.
- `ChallengeSession.classify_car(raw_ceiling, owned, entry)` — the single
  implementation of the comparison. Rounds `raw_ceiling`, then returns
  `{"state": READY | NEEDS_TUNE | EXCLUDED, "detune": frac}` (the synthetic
  `{"restriction": {"pw_max": <rounded ceiling>}}` it feeds
  `qualifying_detune_for` carries the rounded cap too).
- `ChallengeSession.classify_cars(kind, profile, unix_time)` — runs that over
  the profile and returns `{"ceiling": int, "eligible", "ready", "needs_tune",
  "detune": {instance_id: frac}}`. `eligible_cars` is now just its `"eligible"`
  list, and the UI reads the buckets instead of re-deriving the comparison, so
  the rule cannot drift between the entry screen and the car park.

The start-line launch gate (`world.gd`'s synthetic rally →
`RallyLibrary.ineligibility_reason`) needs no change: that path rounds `pw_max`
itself. `DrivingContext.pw_limit()` / the upgrades popup cap stay raw floats —
they are a *display* cap for the upgrades screen, not the eligibility verdict.

## HQ entry point (`hq_challenge.gd`)

The garage station's bottom action row is **Back / Career / Garage / Free
Roam / Challenge** (a single left/right `ButtonCursor`, `_garage_cursor` —
see [menus.md](menus.md) → "GARAGE"; Settings moved to the title screen's
own horizontal cursor row). **Challenge** opens
`_open_challenge_overlay()`: a modal `CanvasLayer` over the garage (built
once in `_ready` via `HqOverlays.build_challenge_overlay`, hidden until
opened — a "modal layer, not a `View` enum entry" shape, the same one the
since-removed title-screen Account overlay used). Opening it first discards any
stale stored run (`ChallengeSession.has_stale_run` / `discard_stale_run`, so
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
2. **Win reward** — per-kind text (`_CHALLENGE_REWARD_TEXT`: `2 mystery boxes` /
   `3 mystery boxes + 1 low-tier car` / `4 mystery boxes + 1 high-tier car`).
   **This string is stale**: `_COMPLETION_REWARD` pays boxes + placement stars and
   no car at all any more (see *Completion reward* below), so the weekly/monthly
   text still advertises a car the run cannot grant — it needs rewording to the
   boxes-plus-stars payout. These boxes are why `RewardSystem.pick_mystery_box_grant` no longer excludes
   the current car: a challenge box is tied to no car at all, so the old "never
   the car it came from" rule stopped describing anything real — see
   [reward-system.md](reward-system.md) → *Mystery box*. A
   plain-language mirror of `ChallengeSession._COMPLETION_REWARD`; keep both in
   step when the table is retuned.
3. **Eligible cars** — NAMES them (not just a count), mirroring the rally
   pin detail panel's own eligibility read-out exactly:
   `_qualifying_cars_text` (capped at `MAX_QUALIFY_NAMES`, tailing off as
   `"+N more"`) over the ready-now names, plus a second line
   `"Needs tune: ..."` for any only reachable with a tune
   (`ChallengeSession.eligible_cars`, which already folds those in — §2), or
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

A **Start/Resume** button: "Resume" (calls `ChallengeSession.resume`
directly — no car to pick, the locked car is already fixed) whenever
`ChallengeSession.resumable_run(Save.profile, unix_time)` is non-empty *for
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
exactly what `ChallengeSession.classify_cars(kind, Save.profile, unix_time)`
reports as `"eligible"` (challenge-lock-excluded via `Save.is_challenge_locked`),
and forwards that same call's `"detune"` map into the SAME `_detune_needed` dict
the rally car-select uses — it does NOT redo the comparison itself (see
"Rounding" above). An over-ceiling car therefore
parks looking eligible, and pressing Start on it pops the SAME
`_show_over_limit_prompt` "Too powerful" agreement a normal rally's
over-cap car does, routing to the gated upgrades popup
(`_show_upgrades_popup`, which reads the ceiling from
`ChallengeLibrary.ceiling_for` instead of a rally's `pw_max` restriction
when `_carpark_mode == CarparkMode.CHALLENGE`).

`_on_start_pressed`'s mode-dispatch `match` gained a `CarparkMode.CHALLENGE`
branch alongside `STARTER`/`SWAP`/`WHEELS`/`GARAGE`/`FREEROAM`: instead of
falling through to the `RallySession.start_rally` path every other mode
skips past, it checks `_detune_needed` (over-limit prompt if positive) and
otherwise calls `_begin_challenge_start()`, which calls
`ChallengeSession.start(kind, owned_car, unix_time)` and then the SAME
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
(`_drivetrain_needed`/`RallySession.register_drivetrain_revert`) that a
challenge has no equivalent for (no authored rally, no drivetrain
restriction rule, no drivetrain-switch flow) — parameterizing that single
`match` arm to serve both would have meant branching on "is this a
challenge?" *inside* the RALLY case anyway. A dedicated `CHALLENGE` value
keeps each mode's intent a single, git-blameable `match` arm, matching how
every other special car-park job (`GARAGE`, `FREEROAM`, `SWAP`, `STARTER`,
`WHEELS`) already gets its own value rather than overloading `RALLY`.

Quitting mid-run (`pause_menu.gd.quit_to_hq`) checks
`ChallengeSession.is_active()` before `RallySession.is_active()` and calls
`ChallengeSession.abandon()` — the same explicit-quit-is-DNF outcome §3
describes, distinct from a wreck only in cause.

## Car lock (§2) — the RUN is locked to a car, the CAR is not reserved

Starting a run commits it to `car_instance_id` for its duration. That is the whole
meaning of the lock: **you cannot switch to a different car for that run.** It does
NOT reserve the car — it stays fully usable in career rallies, free roam, the garage,
engine swaps and upgrades while the run is in progress.

Two earlier designs were both WRONG and have been removed:

- **Freezing the detune slider.** An early draft set `editable = false` on the slider
  for the locked car. It looked broken (the slider silently wouldn't move, with no
  explanation) and duplicated the p/w enforcement a career rally already does through
  the close-button gate (`UpgradesMenu.bind_close_button` / `_pw_limit`). Removed; the
  ceiling is enforced by that one shared mechanism.
- **Excluding the car everywhere else.** A later fix made the garage's car picking, the
  engine-swap partner list, the career rally lineup and the reward reveal's "Repair
  now" offer all skip the locked car. That made an owned car unusable across the whole
  game, which was never the intent. All four exclusions are gone.

`DrivingContext.is_car_locked` / `Save.is_challenge_locked` remain as the predicate
for "is this run committed to this car", and both carry comments saying not to use
them to gate anything outside the run. The full "a challenge locks the RUN, not the car"
rationale now lives in `hq.gd` → `_swap_targets` (the engine-swap partner list), which
`_build_eligible_lineup` points at rather than restating. "You can't switch cars mid-run" needs no
enforcement of its own — `ChallengeSession.start` already refuses while a run is
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
again until the period rolls over. `ChallengeSession` records the outcome in
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

`challenge_results` is deliberately SEPARATE from `challenge_run` rather than folded
into it: `resumable_run` keys on `challenge_run` being non-empty, so a terminal record
stored there would make the game try to RESUME a finished run. The map is pruned to
the live periods on every write, so it holds at most three records rather than growing
one entry per day forever.

**Only a WRECK produces a DNF.** `_end_as_dnf` is reachable solely through
`report_wreck()`. Everything else that leaves a run pauses it — see below.

## Leaving a run (pause, not abandon)

`ChallengeSession.pause_run()` is the non-terminal exit: it clears `_active` /
`_stage_running`, leaves `challenge_run` persisted at its current stage index and
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
  (§5) — `ChallengeSession`/`GlobalStandings` never retries or attempts an
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

`GlobalStandings` (the per-stage interstitial, `global_standings.gd`) grows a
parallel `is_challenge` path: `for_current_stage()` returns
`{is_challenge, period_key, stage_index, time_ms (= cumulative, via
ChallengeSession.cumulative_ms()), car_name, car_id, dnf}` instead of a
`stage_key`-based dict (a challenge stage has no `stage_key` and is never
posted to `stage_times` — spec §5). `_refresh_challenge`/`_land_challenge`
call `Cloud.challenge_leaderboard.post_checkpoint` + `fetch_standings_at`
instead of `Cloud.leaderboard.submit_and_fetch`, reusing the SAME `State`
enum (`LOADING`/`SIGNED_OUT`/`NO_USERNAME`/`POSTED`/`UNAVAILABLE`) and
`Leaderboard.display_rows` assembly — a `challenge_fetcher: Callable` test
seam mirrors the existing `fetcher` one.

## Stage-to-stage advancement (the between-stage interstitial)

`world.gd` loads `standings.tscn` after EVERY stage of a challenge, exactly as it
does after a career rally event (both are driven by the same `StageManager` /
`TrackProgress`), so `standings.gd` serves both sessions.

- **`ChallengeSession.continue_to_next_stage()`** is the counterpart to
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
  `if ChallengeSession.is_active():`, and all six silently fell through to the idle
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
- **`standings.gd` branches every session read** on `ChallengeSession.is_active()`,
  the same convention `GlobalStandings.for_current_stage()` uses: `_stages_done()`
  / `_stage_total()` / `_stage_upgrade()` / `_driven_instance_id()` are the four
  helpers, and `_advance()`'s final step calls `continue_to_next_stage()` instead
  of `continue_to_next_event()`. The three-step ladder (page 1 local standings →
  page 2 world board → reward reveal) is otherwise identical.
- **Local standings are a field of one.** A challenge has no rivals, so
  `ChallengeSession.current_event_standings()` / `current_standings()` feed
  `RallyLibrary.build_standings` an EMPTY field — the exact rendering a rally with
  zero rivals produces — rather than introducing a "no standings" UI state. The
  player's row carries that stage's time and the cumulative time respectively.
- **The per-stage reward now actually shows.** `standings.gd` reads
  `ChallengeSession.stage_upgrade()` (a plain accessor alongside the existing
  `stage_upgrade_revealed` signal — the interstitial doesn't exist yet when
  `report_event_result` emits, so it can only read the state) and reveals it with
  the SAME `UpgradeReveal` card / `_collect_reward` flow a career event's reward
  uses. Before this it was installed on the car silently.

### Known deferred: field-repair timing

`report_event_result` computes the field repair at stage END, whereas
`RallySession` applies it at the START of the next event (`_enter_event`, after
the between-event garage visit). Left as-is deliberately: challenge stages are
back-to-back (interstitial → next stage, with no HQ/garage visit in between), so
there is no player-visible moment between the two points, and the repair is
consumed identically either way by `world.gd`'s boot-time `take_pending_repair()`.
Worth revisiting only if a between-stage garage screen is ever added.

## Completion reward (§6)

Two separate reward paths:

- **Per-stage** (non-final stages, unchanged from career): `ChallengeSession.
  report_event_result` calls `RewardSystem.draw_upgrade(Save.profile, null,
  driven)` — the draw takes no difficulty any more (upgrade `tier` is gone; the
  pool is flat and gated on won special events, see
  [reward-system.md](reward-system.md)) — and
  installs/adds the result exactly like `RallySession` does: consumables straight
  to inventory, car-bound parts fitted DISABLED except the
  `UpgradeLibrary.HIDDEN_SLOTS` (nitrous) slot, which fits ENABLED. The draw
  can legitimately come back `RewardSystem.NO_REWARD` (`""`) for a maxed-out car,
  in which case nothing installs and no reveal fires.
- **Per-challenge** (finishing every stage, no DNF): `ChallengeSession.
  try_grant_completion_reward(result)` awaits `Cloud.challenge_leaderboard.
  fetch_final_rank` and grants iff `rank <= ceil(total_entries / 2)` —
  checked against the board AS IT STANDS at that moment (an early finisher is
  compared to a smaller field; accepted as a deliberate generous quirk, not a
  bug). Skipped entirely (returns `{}`) if the run was a DNF, or if no cloud
  rank is available at all (signed out, no username, or the final checkpoint
  never posted — same graceful skip). Reward per kind:

  Reward table (`ChallengeSession._COMPLETION_REWARD` — **tunable, change the
  numbers there**; `HqChallenge._CHALLENGE_REWARD_TEXT` is the player-facing summary and
  has to be kept in step):

  | Kind | Mystery boxes |
  |---|---|
  | Daily | 2 |
  | Weekly | 3 |
  | Monthly | 4 |

  **No car** — the table is boxes-only now, and `car_tier` is gone from it: cars
  are bought with stars at the HQ present box rather than handed out
  ([star-economy.md](star-economy.md)). A placing challenge instead pays **stars
  by placement**, on the SAME `RallyLibrary.stars_for_placement` curve a career
  rally uses (1st/2nd/3rd → 3/2/1), credited via `Save.award_stars`. Note the
  placement gate here (top HALF of the board) is far more lenient than the podium
  that curve pays out to, so a mid-table finish legitimately banks **0 stars** and
  walks away with just the boxes — which is exactly why the boxes are granted
  unconditionally, so a player who placed never walks away with nothing.

  Unlike career stars, this income is **renewable over real time** — deliberately,
  since it is the only star source still flowing once every career rally is won at
  P1 and `complete_rally` has no improvement left to credit.

  Emits `completion_reward_revealed(item_id)` on a grant — always `""` now, since
  nothing item-shaped is granted — and returns `{"placed", "rank",
  "total_entries", "item_id", "boxes", "stars"}`.
  `world.gd._completion_reward_body` renders whatever actually landed, so a win
  that banked only boxes is never silent.

### Where the run's end is resolved (`world.gd._on_challenge_run_finished`)

This handler is the challenge's counterpart to `RallySession._resolve_results` —
the one place a finished run is turned into a reward. It fires from
`ChallengeSession._finish_locally` / `_end_as_dnf` while the player is **still in
the driving scene**, before the hand-off to HQ.

- **Clean finish** → `await ChallengeSession.try_grant_completion_reward(result)`,
  then, on a grant, a plain `ConfirmPopup` card ("Challenge Complete!", placing +
  what was won + where it landed) over the world — the same shape `hq.gd`'s
  mystery box uses for a reward moment that isn't mid-interstitial. A full
  `UpgradeReveal` page belongs to `standings.gd`, which is not up at this point in
  the flow. Skipped headless (the grant still runs headless — see below). A
  failed/unavailable placement fetch just grants nothing and continues to HQ.

  **The grant and its reveal cannot diverge, but not via `ConfirmPopup.
  open_committing`.** That helper (added for the mystery-box shape) acquires the
  modal slot FIRST and skips its `commit` callable entirely when the slot is
  refused — the right contract when "never happened" is a true, harmless
  fallback state. The challenge completion reward does not have that fallback:
  by the time `run_finished` fires, `ChallengeSession._finish_locally` has
  already recorded this period's outcome and cleared `challenge_run`
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
- **DNF** → `Cloud.challenge_leaderboard.post_dnf(ChallengeSession.period_key())`,
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
  hp/tonne equals the displayed ceiling is `READY`; one over it is still
  `NEEDS_TUNE`) and `displayed_ceiling == roundi(current_ceiling)`, stage accumulation/final-stage termination, DNF via
  wreck/abandon, the completion-reward DNF short-circuit, plus the full
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
  with a qualifying placement still grants the reward (inventory gains a
  mystery box) with no popup attempted, and — with `_headless` forced false and
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
  menus bind to `ChallengeSession`'s locked car (not `RallySession`'s inactive -1),
  an upgrade edit refits the live car, no rival card is shown and Start fades
  straight to the countdown, and the header counts the run's own stages.
- `tests/headless/test_smoke.gd` — `_should_stage()` returns true for a challenge
  stage (and still honours `start_line_enabled`), and `_arch_event_info()` reports
  the challenge's name/stage/count with no time-to-beat.
- `tests/headless/test_menu_flow.gd` — the Challenge entry point's nav
  (opens, navigable, `menu_back` closes it), instant kind-switching via
  `menu_left`/`menu_right` regardless of focus, the five sections reflecting
  the current kind/ceiling (via `ChallengeSession.eligible_cars`), the
  no-eligible-car block disabling Start, Start opening the REAL car park
  (`CarparkMode.CHALLENGE`, asserted on `hq._eligible`/`hq._carpark_mode`)
  then Start↔Resume switching once a run is stored, and the
  over-ceiling-but-detune-reachable car parking eligible and routing Start to
  the "Too powerful" agreement (mirroring the normal-rally car-park test).
  Also the challenge side of the standings interstitial: it renders a stage as a
  field of one, a non-final stage's reward is collected through the same
  page 1 → page 2 → `UpgradeReveal` ladder and its Continue actually advances the
  run to the next stage, and the final stage offers no collect step.
