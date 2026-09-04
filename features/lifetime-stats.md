# Lifetime stats

**Source:** `scripts/lifetime_stats.gd` (`LifetimeStats` — the registry), `scripts/save_manager.gd` (`Save.lifetime_stat` / `add_lifetime_stat` / `raise_lifetime_stat` — the persistence), `scripts/hub_shell.gd` (`HubShell._build_stats` — the read-out page).

**Tests:** `tests/headless/test_lifetime_stats.gd`, `tests/headless/test_hub_shell.gd` (the STATS page + its nav)

Persistent counters that track a player's career across every run, region and
challenge — never reset by a failed run (`todo/roguelike-pivot.md`, "Lifetime global
stats"). They are what `features/perks.md`'s unlock gates read: a perk stays
locked until one of these counters crosses an authored threshold.

## The registry

One authored dict, `LifetimeStats.STATS`, mirroring the RR original's
`GLOBAL_STAT_DEFINITIONS` (`roguelike-rally/src/game/constants.ts`) and the "one
registry, not parallel lists" rule that project's own `CLAUDE.md` states. Adding a
stat is a one-place change: a new key in `STATS` (with a `const` id, a `label` and a
`description`), added to `IDS`. Nothing else — the menu, the perk gates, and the save
backfill all read this one table, never a duplicated id list.

Every stat is persisted on `Save.profile[Save.KEY_LIFETIME]` (a `{stat_id: int}`
dict), and **only ever grows**. Soft permadeath destroys a run — its stage progress,
its picked boosts, the car's accrued damage — and never touches this ledger; that
asymmetry is the whole point (mirrors the money/regions-cleared/boost-levels block
`save_manager.gd`'s header comment already documents).

## Two mutators, because not every stat is a running sum

`Save` owns persistence (mirroring how `BoostLibrary` is content and `Save` owns
`boost_level`/`buy_boost_level`):

- `Save.lifetime_stat(id) -> int` — read, defaulting to 0 for an unset id.
- `Save.add_lifetime_stat(id, amount := 1)` — accumulate. A non-positive amount is a
  no-op, the same guard `add_money` uses.
- `Save.raise_lifetime_stat(id, value)` — ratchet a HIGH-WATER MARK up to
  `max(current, value)`, never down. For a counter like "deepest region reached",
  where a repeat visit must not read as new progress but the number must still obey
  "only ever grows".

## Which counters are wired, and where

| Stat id | Wired? | Written at |
| --- | --- | --- |
| `stages_cleared` | yes | `RunSession.report_event_result`, on every stage that is not missed (region or challenge) |
| `runs_started` | yes | `RunSession.begin()` — the one entry point both `RegionRunMode` and `ChallengeRunMode` pass through |
| `runs_failed` | yes | `RunSession._finish_locally()`, when `_failed` is true — a challenge never sets this (its mode's `stage_failed` always returns false) |
| `regions_cleared_total` | yes | `RegionRunMode.record_outcome()`, on every COMPLETED region run — repeats included (decision 12's grind valve), unlike the unique `Save.KEY_REGIONS_CLEARED` unlock ledger it sits beside |
| `damage_taken` | yes | `RunSession.report_event_result`, alongside `Save.apply_damage`, rounded to the nearest whole HP |
| `money_earned` | yes | `Save.add_money` — the ONE funnel every money source (stage payout, fast-completion bonus, a future challenge reward) already goes through |
| `money_spent` | yes | `Save.spend_money` — the ONE funnel every purchase (car, boost level, engine-swap unlock, perk, drivetrain conversion) already goes through |
| `best_region_order` | yes | `RegionRunMode.record_outcome()`, ratcheted via `raise_lifetime_stat` against `region_index()` |
| `distance_driven_m` | yes | `RunSession.report_event_result`, from the offset `world.gd` snapshots at the finish crossing (`_event_distance_at_finish`). The odometer is `TrackProgress.progress_offset()` — a BEST-offset reading, so forward progress down the centreline counts and a reverse or a wander off it does not. Missed stages count too: the metres were driven either way |

Writing at the shared funnel (`add_money`/`spend_money`) rather than at each payout
or purchase site is deliberate: it means a future money source or shop sink is
covered automatically, with nothing to remember to wire.

## The menu

`HubShell.View.STATS`, reached from `View.MAIN`'s "Lifetime stats" row. Pure
read-out — one `UITheme.label` row per `LifetimeStats.IDS`, in table order. **The
menu-nav trap this page exists to avoid:** a page of nothing but read-only rows has
nothing focusable at all if every row is a `Label` — `MenuNav` only walks focusable
controls (`features/menu-navigation.md`). The page's Back action (a real `Button`,
added via `HubShell._action`) is deliberately its only focusable control, so the page
still satisfies CLAUDE.md's "every menu is keyboard + gamepad navigable" rule despite
having nothing to choose.

## Every id has a writer, and that is a rule

There are no declared-but-unwritten stats left (`distance_driven_m` was the last, wired in
stage 9 — decision 54). **If you add an id here, wire its writer in the same change:** an
unwritten stat is a row on the Stats page pinned at zero forever, which a player reads as a
broken counter rather than an unfinished feature.

## Notes

- These counters are read ONLY by the unlock gates. A perk's actual effect comes from
  its `effect_fields` (`features/perks.md` → "What each perk actually does"), never
  from a lifetime stat, so a counter that stops moving weakens no equipped perk.
