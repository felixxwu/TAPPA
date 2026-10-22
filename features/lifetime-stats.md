# Lifetime stats

**Source:** `scripts/lifetime_stats.gd` (`LifetimeStats`), `Save.lifetime_stat` /
`Save.add_lifetime_stat` (`scripts/save_manager.gd`), and the free-roam writers
(`WorldSession.light`, `free_roam.gd`); the stats page is `WorldPages.show_stats`.

**Tests:** `tests/headless/test_lifetime_stats.gd`

Persistent counters that track a player's whole save. Nothing is gated on them
(decision 22); they are a read-out on the map page's Stats view.

## The registry

One authored dict, `LifetimeStats.STATS`. Adding a stat is a one-place change: a
`const` id, a `STATS` entry (`label`, `description`) and an `IDS` entry.

Every stat is persisted on `Save.profile[Save.KEY_LIFETIME]` (a `{stat_id: int}` dict)
and **only ever grows**:

- `Save.lifetime_stat(id) -> int` — read, defaulting to 0 for an unset id.
- `Save.add_lifetime_stat(id, amount := 1)` — accumulate. A non-positive amount is a no-op.

## Which counters are wired, and where

| Stat id | Written at |
| --- | --- |
| `distance_driven_m` | `free_roam.gd`'s odometer, every few seconds (teleports excluded) |
| `rest_stops_lit` | `WorldSession.light()`, the first time a rest stop is lit |
| `times_gave_up` | `free_roam.gd` on `RestStops.respawned` (the car hit 0 HP) |

`WorldPages.STATS_SHOWN` picks which of them the Stats view shows.

**If you add an id, wire its writer in the same change:** an unwritten stat is a row
pinned at zero forever, which a player reads as a broken counter.
