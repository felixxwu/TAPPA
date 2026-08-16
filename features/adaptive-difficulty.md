# Adaptive difficulty

The rival field pitches itself at the player: it eases after a run of stages they did
not win, and tightens when they keep taking P1.

- **Rule:** `scripts/ai_difficulty.gd` (`AiDifficulty`) — pure logic over a profile dict
- **Signal + wiring:** `scripts/rally_session.gd` (`_won_stage`, `_field_rating`,
  `report_event_result`)
- **State:** the save profile (`AiDifficulty.KEY_STEPS` / `KEY_WIN_STREAK` /
  `KEY_LOSS_STREAK`), schema v4
- **Config:** `GameConfig.ai_adapt_*`
- **Design:** `docs/superpowers/specs/2026-08-16-adaptive-difficulty-design.md`

## The lever is machinery, not driving

The opponent field is already drawn matched to the player's `CarPerformance` rating
([car-performance.md](car-performance.md)). Adaptive difficulty does not add a second
mechanism — it simply hands the matcher a **different rating**:

```
target_rating = player_rating * (1 + difficulty_steps * ai_adapt_step_fraction)
```

A harder field is one drawn from quicker cars. `generate_opponent_field` needed no
change at all: it already takes a rating and weights the draw toward it.

**Why machinery rather than pace**, which was the obvious first idea:

- A rival in a faster car has a genuinely **lower optimum**, so its time can be quicker in
  absolute terms while still sitting at a sane multiple of *its own* optimum. `RivalPace`
  stays inside its skill bracket and the windscreen ghost can always show what the
  standings claim.
- Scaling pace instead would have needed rivals to beat their own physics optimum. The
  ghost cannot represent that: measured, it tops out **2.4% faster than optimum** at
  `rival_ghost_skill_max`, because `rival_ghost_grip_exponent` ships at 0 so the skill
  factor only adds power and a grip-limited lap does not care. Getting real headroom would
  have meant changing how *every* rival ghost drives, game-wide.
- It is legible: you lose to someone who brought a quicker car, not to someone driving
  impossibly.

`LapTimeModel`'s optimum is a **reference, not a limit** — it solves a point mass welded
to the centreline of a 6 m road, so a driver using the racing line can beat it. Any design
that treated it as a ceiling would run out of room against exactly the player it exists to
challenge.

## The signal

One bit per stage: **did the player beat every rival on it.** Read in
`report_event_result`, which already has the player's time, against
`current_event_leaders` — so nothing new is persisted per stage and no new plumbing was
needed.

- Per **stage**, not per rally: a rally is three stages, so this gives three times the
  evidence and can respond inside an event rather than after a whole rally has gone badly.
- A **DNF moves nothing** — it measures neither pace nor skill.
- An **empty field is not a win.** With nobody to beat there is no evidence the player is
  quick, and counting it would ratchet difficulty up on no information.

## How the offset moves

`difficulty_steps` is signed: **positive = harder**, negative = easier, 0 = matched.

| Result | If it undoes the current offset | Otherwise |
|---|---|---|
| Stage won | give back one step **immediately** | count toward a win streak; `ai_adapt_stages_per_step` in a row pushes one step harder |
| Stage not won | give back one step **immediately** | count toward a loss streak; that many in a row pushes one step easier |

**Deliberately asymmetric.** Returning to matched takes a single result; moving *past*
matched takes a sustained run. A player who was struggling and then wins should not have
to win three times before the game stops helping. The opposite streak clears on every
result, so alternating finishes never creep in either direction.

Caps are **separate per direction** (`ai_adapt_max_ease_steps` / `_max_hard_steps`)
because the car roster is not symmetric around the player: there is far more of it below a
mid-pack car than above a quick one, so the easy side is fully reachable while the hard
side is limited by what can actually be fielded. Both ship as placeholders to be set from
real play.

## Matched is an exact no-op

At 0 steps the target IS the player's rating, so the field is drawn exactly as it was
before this system existed. **There is no cold-start branch, because none is needed** —
a fresh career and a profile migrated from v3 both start at 0 and play the old game until
they produce results. `ai_adapt_enabled = false` restores the same state at any point.

A `player_rating` of 0 means "draw unmatched" (the no-car / test path) and is passed
through untouched; offsetting it would turn a deliberate non-match into a small positive
rating and quietly start matching against nothing.

## Silent

No UI, in either direction (design D1). The player experiences a field that fits them and
is never told the game adjusted.

Accepted with that: a player who is doing well gets a harder game with no explanation, and
may read it as inconsistency rather than as the system responding. Naming it was judged
the worse trade — it undercuts the win it exists to set up.

Two **dev console logs** carry it, because a silent system with no diagnostics is a
system nobody can tell is broken. Both are console surfaces, not player-facing ones.

**Per stage** (`RallySession._record_and_log_stage_result`), the direction of travel:

```
[difficulty] fx_open stage 1 — LOST | matched  (1/3 to a step easier)  (+30.0s vs P1)
[difficulty] fx_open stage 1 — LOST | matched  (2/3 to a step easier)  (+28.0s vs P1)
[difficulty] fx_open stage 1 — LOST | easier -1 step  ->  EASIER (0 => -1)  (+1.0s vs P1)
[difficulty] fx_open stage 1 — WON  | matched  ->  back to matched (-1 => 0)  (-1.0s vs P1)
[difficulty] fx_open stage 1 — WON  | matched  (1/3 to a step harder)  (-2.0s vs P1)
```

Three things it reports on purpose:

- **The streak fraction.** Two stages in three change nothing, so without it those lines
  would be indistinguishable from a system that had stopped responding.
- **Giving back vs committing.** `back to matched` and `HARDER` are different events —
  "the game has stopped helping you" is not "the game is now pushing past a fair match" —
  and a log that called both HARDER would hide the one worth noticing.
- **The margin.** Losing by 0.2 s and losing by 30 s both read as `LOST` to the rule, and
  only the log can say which kind of trouble the player is in. A DNF prints as ignored,
  so a missing line is never ambiguous.

**Per field draw** (`RallySession._log_opponent_field`), the state the draw used:
`AiDifficulty.describe` alongside the target rating, so a grid drawn well off the player's
own rating reads as the system working rather than as a matching bug.

## Rivals may run anything

Rival builds are NOT gated on the player's own unlocks (design D2), matching how the
engine-swap pool already behaves. A rival can therefore turn up with a part the player has
never seen — a mild spoiler, and it slightly blurs what the part-unlock rallies signify.
In exchange the hardening lever has its full range from the first rally, when the player's
own roster is thinnest and a gated pool would leave almost nothing above them.

## Headroom: rivals get upgrades

The rating lever is bounded by what the roster can field. With an engine swap as their
only upgrade, rivals spanned 99 combos at `min 207 / p50 475 / max 536`, with almost
nothing above 510 — while an upgraded player climbs well past that. At the top of the
range, exactly where a dominating player sits, the lever had nowhere to point.

So rivals now scale by the same mechanism the player does: `RallyLibrary._eligible_combos`
crosses each car+engine pairing with a small set of **build levels** (stock / ballasted /
lightly built / fully built), each entering the pool as its own combo with its own rating.
That takes the pool to 396 combos at `min 141 / p25 453 / p50 503 / p75 598 / p90 646 /
max 706` for ~300 ms cold (~35 ms warm — `CarPerformance` memoises per input), once per
field draw. The draw itself needed no change at all. See
[rally-roster.md](rally-roster.md) → *Build levels* for the rules a level obeys and why
nitrous is excluded from every one of them.

## Residual: a small pace trim

The roster is still finite, and a categorical restriction can thin it hard — a
country-locked rally may offer few cars at any rating. When the closest thing the pool can
field is short of the target, `RallyLibrary._residual_pace_trim` takes up **the shortfall
only**, never the whole offset, by scaling every rival's time. Rating is proportional to
average speed, so the scale is just `reachable / target`: a pool topping out at 90% of the
target runs its rivals at 0.90× their times. Inside the pool's range — the normal case,
and every unadapted field — it is exactly 1.0, so the trim is a true no-op there.

Two ordering details matter:

- It is applied **after** the `PACE_MIN_FLOOR` clamp, not before. The fastest rival sits
  near the bottom of the pace band at every tier, so a trim folded in ahead of a binding
  floor would be clamped straight back off — precisely where hardening is needed most.
  (`PACE_MIN_FLOOR` itself was lowered to a sanity guard for that reason; design D3.)
- The result is bounded by `RallyLibrary.GHOST_SOLVABLE_PACE` (0.976× the rival's own
  optimum) — what `RivalPace` can solve, not what physics allows. Past it the ghost warns,
  clamps and visibly stops matching the standings.

## It deliberately breaks re-attempt determinism

`rally_library.gd` states that a rally's field is fixed by its seed, so re-attempting one
chases the same leaderboard. **Adaptive difficulty overrides that**, and it has to: a
player who loses a rally three stages running and comes back to the identical wall is
exactly the case the system exists for.

The offset moves on stage results, and the field is drawn at `start_rally`, so:

- **Within a rally the grid never changes.** The offset banked from stage 1 does not
  re-draw stages 2 and 3 — `refield_opponents` refuses once a stage has been raced, so the
  standings you are racing stay coherent for the whole rally.
- **Between rallies it does.** A re-attempt after a bad run is drawn against the new
  offset, so it is genuinely a different field.

Everything else about the seed still holds — names, wrecks and the draw order are stable
for a given (rally, target rating) pair. It is the target rating that moves, not the
determinism of the draw.

`test_no_retry_reenter_resets_and_field_is_fixed` asserts the old invariant and therefore
sets `ai_adapt_enabled = false`: it is testing the seeded draw, not the difficulty system
layered over it.

## Scope

**Career only.** Rally Challenge has no rival field to scale.

Both `RallySession.start_rally` and `refield_opponents` go through `_field_rating`, so a
re-draw after a start-line upgrade edit carries the offset rather than silently resetting
to a plain match.

## Testing

`tests/headless/test_ai_difficulty.gd` covers the rule as pure logic — direction, the
immediate give-back, the streak requirement, alternating results not accumulating, both
caps, and the matched no-op. `tests/headless/test_rally_session.gd` covers the wiring: the
stage signal moving the offset, an empty field never hardening, and the offset actually
reaching the draw (including across a re-field).

Per CLAUDE.md these are all relations, never tuned values — retuning any `ai_adapt_*`
value in the inspector must not break them.
