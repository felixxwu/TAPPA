# Pre-event Start Line

**Source:** `scripts/start_line.gd` (`class_name StartLine extends Node3D`), created
and wired by `scripts/world.gd` for staged session runs. Holds the
[`StageManager`](stage.md) in its `STAGING` phase and launches it.

The diegetic moment between picking a car in HQ and the `3·2·1·GO` countdown
(`todo/menus.md` location 2). It runs **inside the live run scene** (`main.tscn`)
once the world is built and a [`RallySession`](rally-session.md) is active, while
the car is held locked, and shows two things until the player launches:

- **Briefing panel** — a world-anchored, billboarded panel (a `Control` rendered
  through a `SubViewport` onto a `Sprite3D`) with the rally name, **Event N of 3**,
  the car restriction, the fielded car's name, and its **HP bar** — so the risk is
  legible before committing (`gameplay.md`). The HP bar mirrors the HUD's
  green→amber→red grade; the immortal starter reads `INF`.
- **Presence cars** — a few atmosphere cars staggered at the grid (alternating
  sides, stepping back a row every two cars). **Flavour only — NOT the real
  opponent field** (that's `RallyLibrary`'s per-seed roster, surfaced in the
  standings). Frozen, collision-off, silenced car props with their own mesh copies,
  reusing the HQ car-park prop pattern (see [menus.md](menus.md)). Models are picked
  deterministically from the rally's first seed, so a given event's line-up is
  stable. They sit on the terrain when a `TerrainManager` is passed.

## Launch

`menu_select` (Enter / gamepad A) or a tap/click calls `launch()`, which hides the
briefing and calls `StageManager.begin_countdown()` to start the run. `launch()` is
idempotent — a second tap during the countdown is ignored (and `begin_countdown()`
is itself a no-op outside `STAGING`), so the run can't be restarted.

## Wiring & lifecycle

`world.gd._should_stage()` decides whether a run opens with the start line: a
session run **and** `start_line_enabled` **and** a resolvable rally (so a missing
rally never strands the car in `STAGING` with nothing to launch it). When true,
`world.gd` sets up the `StageManager` `staged` (it waits in `STAGING`) and builds
the `StartLine` after the world is generated. Each rally event reloads `main.tscn`,
so the `StartLine` is created fresh per event and freed with the scene — no reuse
logic. A plain dev boot of `main.tscn` (no session) never builds a `StartLine` and
the countdown arms immediately.

## Config knobs

| Field | Default | Purpose |
|-------|---------|---------|
| `start_line_enabled` | `true` | Run the start-line scene in a session. Off → straight to the countdown even in a session. |
| `start_presence_count` | `3` | Number of atmosphere presence cars (0 disables them). |
| `start_presence_lateral` | `3.2` | Lateral spacing (m) between staggered presence cars. |
| `start_presence_longitudinal` | `5.5` | Distance (m) further back per staggered row. |
| `start_briefing_offset` | `(0, 2.6, -2.6)` | Briefing panel position relative to the car's start pose (car space). |
| `start_briefing_pixel_size` | `0.0045` | World-space size (m/px) of the billboarded panel. |

See [configuration.md](configuration.md).

## Tests

- `tests/headless/test_start_line.gd` — the briefing reflects the rally / event /
  restriction / fielded car, the HP bar tracks the car's HP (and shows `INF` for an
  immortal car), the configured number of presence cars line up (0 → none), and
  `launch()` hands off to `begin_countdown()` exactly once (idempotent).
- `tests/headless/test_stage_manager.gd` — the `STAGING` phase holds with no
  countdown until `begin_countdown()` arms it, and `begin_countdown()` is a no-op
  outside `STAGING`.
