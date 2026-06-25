# Menus & game-loop shell

**Sources:** `hq.tscn` + `scripts/hq.gd`, `podium.tscn` + `scripts/podium.gd`,
plus the session-aware fielding in `scripts/world.gd`. See the full design in
[../todo/menus.md](../todo/menus.md).

This is the **minimal vertical slice** of the menu shell: a working
HQ → field car → run → podium → HQ loop with **placeholder flat UI**. The full
spec calls for a diegetic 3D world (car-park / tuning-lift / map-table stations,
a stylised map plane with rally pins, SubViewport stats panels, a 3D podium,
camera fly-throughs, `menu_*` input actions) — that staging is **deferred**; this
slice proves the loop end-to-end and wires [rally-session.md](rally-session.md)
into the run scene.

## The loop

```
HQ (boot scene) ─Start─▶ RallySession.start_rally ─▶ main.tscn (event 0)
   main.tscn ─StageManager.stage_completed─▶ report_event_result ─▶ next event (reload)
                                          └─ car.wrecked ─▶ report_wreck (DNF)
   final event / DNF ─rally_finished─▶ podium.tscn ─Continue─▶ HQ
```

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight `Control` with no
track generation. On first visit it grants the **immortal starter** (`mx5`) — the
anti-soft-lock floor. It lists the owned cars and, for the selected car, the
rallies it can enter (`RallyLibrary.is_eligible`; the showdown only once
`showdown_unlocked`; completed rallies marked but still enterable for farming).
**Start** calls `RallySession.start_rally(rally, owned)`.

## Run-scene fielding (`world.gd`)

When a `RallySession` is active, `world._ready` fields the player's OwnedCar via
`Car.apply_owned` (CarLibrary baseline → installed upgrades → bound damage from
the saved HP) instead of the default `apply_car(0)`, and wires this event's
`StageManager.stage_completed` → `report_event_result(elapsed_ms, hp_lost)` and
the car's `wrecked` → `report_wreck`. `rally_finished` loads the podium. With no
session (a plain dev boot of `main.tscn`) the default car is fielded and none of
this runs — `main.tscn` is still independently runnable.

## Podium (`podium.gd`)

Reads `RallySession.last_result()` and shows the placement / combined time, or
DNF, and whether the rally was won (reward delivered to HQ). **Continue** returns
to HQ.

## Deferred (full menus build)

Diegetic 3D staging, the map/pins, tuning lift + inventory overlay, standings &
pause overlays, reward-reveal rig, `menu_*` input actions, and camera fly-through
transitions. The between-event **standings interstitial** is currently a straight
reload (RallySession still emits `standings_ready` for the overlay to hook).

## Tests

`tests/headless/test_menu_flow.gd` — HQ grants the starter and lists cars/rallies,
Start launches a session, the podium renders a finish summary, and the run scene
fields the bound session car.
