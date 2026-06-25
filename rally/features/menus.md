# Menus & game-loop shell

**Sources:** `hq.tscn` + `scripts/hq.gd`, `podium.tscn` + `scripts/podium.gd`,
plus the session-aware fielding in `scripts/world.gd`. See the full design in
[../todo/menus.md](../todo/menus.md).

This is the **flat-UI build** of the menu shell: a working
HQ → field car → run → podium → HQ loop that makes the whole meta-game legible —
car selection with stats, a rally board that shows what's locked and why, a
podium reward reveal, and full opponent standings. The full spec calls for a
diegetic 3D world (car-park / tuning-lift / map-table stations, a stylised map
plane with rally pins, SubViewport stats panels, a 3D podium, camera
fly-throughs, `menu_*` input actions) — that staging is **deferred**, with its
first concrete slice kicked off in [../todo/diegetic-hq.md](../todo/diegetic-hq.md).
The flat UI here proves the loop end-to-end and wires
[rally-session.md](rally-session.md) into the run scene.

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
anti-soft-lock floor.

**Car selection (stat cards).** Each owned car is a selectable card showing the
data the player needs to weigh the risk: model + instance id, a metadata line
(drivetrain / country / type / reward tier / power-to-weight via
`CarLibrary.power_to_weight`), an **HP bar** (∞ for the immortal starter), and
the installed upgrades when fitted.

**Rally board (unlock state).** Unlike a filtered list, **every** rally is shown
so the unlock path is legible. For the selected car a rally is either
*enterable* (eligible, selectable, ✓ if already completed — still enterable to
farm rewards) or *locked* and disabled with the reason spelled out: the
restriction it fails (`needs RWD cars`, `needs JP cars`, …) or, for the showdown,
`complete all rallies first (X/Y)`. A **showdown progress meter**
(`completed / total`) sits above the board. **Start** calls
`RallySession.start_rally(rally, owned)`.

Layout: the title is fixed at the top and the **Start** button is pinned at the
bottom, with the car/rally lists in a `ScrollContainer` that fills the space
between them — so on short/phone screens the lists scroll and the primary action
is never clipped off the bottom edge.

## Run-scene fielding (`world.gd`)

When a `RallySession` is active, `world._ready` fields the player's OwnedCar via
`Car.apply_owned` (CarLibrary baseline → installed upgrades → bound damage from
the saved HP) instead of the default `apply_car(0)`, and wires this event's
`StageManager.stage_completed` → `report_event_result(elapsed_ms, hp_lost)` and
the car's `wrecked` → `report_wreck`. `rally_finished` loads the podium. With no
session (a plain dev boot of `main.tscn`) the default car is fielded and none of
this runs — `main.tscn` is still independently runnable.

## Podium (`podium.gd`)

Reads `RallySession.last_result()` (a scrollable layout like HQ) and shows three
things:
- **Headline result** — rally name, placement + combined time, or DNF; a top-3
  reads as `RALLY WON!` (or `THE SHOWDOWN IS WON` for the final rally).
- **Reward reveal** — the won car by name with a `⭐ NEW` badge when first owned
  (`car_reward` / `car_reward_is_new`), plus the per-event **upgrades** collected,
  aggregated as `Name ×N`. Both were already granted by `RallySession`; the podium
  only reveals them.
- **Standings** — the full ranked field (`RallyLibrary.build_standings`): position,
  name, time / `WRECKED`, with the player's row marked `▶` and tinted.

`last_result` carries `rally_name`, `standings`, `upgrades`, `car_reward`,
`car_reward_is_new`, and `showdown_won` alongside the original
`placed`/`completed`/`combined_ms`/`dnf`. **Continue** returns to HQ.

## Deferred (full diegetic 3D build)

Diegetic 3D staging, the map/pins, tuning lift + inventory overlay, the pause
overlay, the 3D reward-reveal rig + 3D podium, `menu_*` input actions, and camera
fly-through transitions. The first concrete slice (the 3D HQ car park + menu
camera + showroom rig) is kicked off in
[../todo/diegetic-hq.md](../todo/diegetic-hq.md); the umbrella vision stays in
[../todo/menus.md](../todo/menus.md). The between-event **standings interstitial**
is currently a straight reload (RallySession still emits `standings_ready` for the
overlay to hook); standings are surfaced at the podium for now.

## Tests

`tests/headless/test_menu_flow.gd` — HQ grants the starter and lists cars/rallies,
the rally board shows locked rallies with their restriction + the showdown meter,
Start launches a session, the podium renders the finish summary **and the reward
reveal + standings**, and the run scene fields the bound session car. The pure
`RallyLibrary.build_standings` ranking and the enriched `RallySession` result are
covered in `test_rally_library.gd` / `test_rally_session.gd`.
