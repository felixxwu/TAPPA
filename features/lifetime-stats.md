# Lifetime stats

**Source:** `scripts/lifetime_stats.gd` (`LifetimeStats`) and `Save.lifetime_stat` /
`Save.add_lifetime_stat` (`scripts/save_manager.gd`).

**Tests:** `tests/headless/test_lifetime_stats.gd`

Persistent counters that track a player's whole save. Nothing is gated on them
(decision 22); the island's map page showed them, and was deleted with it.

## The registry

One authored dict, `LifetimeStats.STATS`. Adding a stat is a one-place change: a
`const` id, a `STATS` entry (`label`, `description`) and an `IDS` entry.

Every stat is persisted on `Save.profile[Save.KEY_LIFETIME]` (a `{stat_id: int}` dict)
and **only ever grows**:

- `Save.lifetime_stat(id) -> int` — read, defaulting to 0 for an unset id.
- `Save.add_lifetime_stat(id, amount := 1)` — accumulate. A non-positive amount is a no-op.

## Which counters are wired, and where

None today. `distance_driven_m`, `rest_stops_lit` and `times_gave_up` were written by the
free-roam island (its odometer, its rest stops and its respawns), deleted in November 2026.
The ids stay so saved counts survive; wiring them into the level, or dropping them, is open.

**If you add an id, wire its writer in the same change:** an unwritten stat is a row
pinned at zero forever, which a player reads as a broken counter.
