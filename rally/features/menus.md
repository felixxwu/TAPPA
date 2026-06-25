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
HQ map (pick rally) ─▶ HQ car select (pick eligible car) ─Start─▶ RallySession.start_rally ─▶ main.tscn (event 0)
   main.tscn ─StageManager.stage_completed─▶ report_event_result ─▶ next event (reload)
                                          └─ car.wrecked ─▶ report_wreck (DNF)
   final event / DNF ─rally_finished─▶ podium.tscn ─Continue─▶ HQ map
```

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). On first visit it grants the **immortal starter** (`mx5`) — the
anti-soft-lock floor. HQ is **two separate screens**, shown one at a time, in the
order **pick rally → pick eligible car → Start** (`enum Screen { MAP, CARS }`).

**Screen 1 — World map (flat overlay).** A basic map: every rally is a **pin**
placed at its authored `map_pos` (a normalised point, positioned by fractional
anchors so it lands correctly at any size). Each pin shows the rally name, its
difficulty + restriction (`any car` / `RWD cars` / …), and a ✓ when completed. The
**showdown** pin is locked (disabled) until every other rally is completed; a
**progress meter** (`completed / total`) sits up top. Picking a pin sets the chosen
rally and flies to screen 2. *(Basic flat map; the stylised 3D map plane of
`menus.md` rig 3 is a later slice.)*

**Screen 2 — Car select (3D car park).** Only the owned cars **eligible for the
chosen rally** (`RallyLibrary.is_eligible`) are parked in a lit lot, in a centred
row spaced by `GameConfig.menu_car_spacing`, each a physics-frozen, silenced `Car`
prop (reusing `Car.apply_owned`). A **menu camera** pans between them — `◄ ►` (or
`menu_left`/`menu_right`) move the focus and the camera eases to a 3/4 hero shot
(`GameConfig.menu_camera_offset` / `menu_camera_move_time`); the focused car **is**
the selected car. A billboarded `Label3D` shows its name + stats beside it (drive /
country / type / tier / power-to-weight / HP), mirrored into the overlay. A
**banner** names the rally + its restriction; **Start** calls
`RallySession.start_rally(rally, owned)`; **◄ Map** (or `menu_back`) returns to the
map. If no owned car qualifies, a hint shows and Start is disabled.

Each parked car gets its **own duplicated meshes** (`_dup_meshes`) so a mixed
lineup renders each at its true size despite `car.tscn`'s shared mesh
sub-resources. The shared-`Config.data` write from `apply_owned` is harmless here —
the props don't simulate and `world.gd` re-applies the fielded car's config per run.

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

## Deferred (rest of the diegetic 3D build)

The HQ 3D car park (above, full parked lineup) is in. Still deferred
([../todo/diegetic-hq.md](../todo/diegetic-hq.md) for the next slices, umbrella in
[../todo/menus.md](../todo/menus.md)): per-car paint + duplicate-model name
suffixes, the map → 3D pins port, the tuning lift + inventory overlay, the pause
overlay, the 3D reward-reveal rig + 3D podium, the full `menu_*` set + mobile
gestures, and camera fly-through transitions *between* locations. The between-event
**standings interstitial** is still a straight reload (RallySession emits
`standings_ready` for the overlay to hook); standings are surfaced at the podium.

## Tests

`tests/headless/test_menu_flow.gd` — HQ boots to the world map (one pin per rally,
showdown pin locked); choosing a rally moves to the car screen and **filters to the
eligible cars** (an AWD car is excluded from an RWD-only rally); an open rally parks
the whole lineup with **per-car meshes** (a mixed lineup keeps each body at its true
size); cycling focus re-selects the car and wraps; **◄ Map** returns to the map and
clears the lineup; choosing rally → car → Start launches a session; the podium
renders the finish summary **and the reward reveal + standings**; and the run scene
fields the bound session car. The pure `RallyLibrary.build_standings` ranking and
the enriched `RallySession` result are covered in `test_rally_library.gd` /
`test_rally_session.gd`.
