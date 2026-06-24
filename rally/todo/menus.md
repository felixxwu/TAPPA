# Menus & UI Shell — implementation spec (diegetic / in-world)

> Status: **planned, not yet implemented.** Implementation brief for the
> meta-game UI described in `gameplay.md`. Follow the config-first convention
> (`CLAUDE.md`): tunables (camera move times, panel offsets, station positions
> worth exposing) go in `GameConfig` (`scripts/game_config.gd` +
> `config/game_config.tres`), never hardcoded. Update the relevant `features/*.md`
> doc and add/adjust tests in the same piece of work.
>
> **Direction (decided with the user): the menus live in the 3D world.** There is
> no flat "menu layer" for navigation — you move a camera through physical
> locations and read **world-anchored floating panels**. This deliberately blurs
> the menu/screen line, so this spec is organised around **locations** and the
> **diegetic rigs** reused inside them, not around flat screens.
>
> **Three settled choices shape everything below:**
> - **World map = a stylised map plane with 3D location pins** the camera pans
>   across (not a flat menu, but lighter than an orbited relief diorama).
> - **Pragmatic hybrid diegesis** — 3D staging + world-anchored panels for
>   navigation and stats; flat overlays kept *only* for **Pause** and **dense
>   data** (full standings). Readability wins over purity there.
> - **Combine surfaces into shared continuous locations, fly the camera between
>   locations.** Related surfaces share one physical space (you pan within it);
>   distinct spaces are linked by camera fly-throughs.
>
> **Dependencies (none implemented yet — see `gameplay.md` › Foundations):**
> Save/persistence, CarLibrary metadata + per-car HP (both specced in
> `todo/save-persistence.md`), and the rally roster (`todo/rally-roster.md`).
> Every location reads that state. **Relates to** `todo/stage-start-and-end.md` (the
> Start-line location *is* its countdown + pre-launch presence scene; its
> placeholder stage-complete panel becomes the Podium location here) and
> `todo/track-progress-and-reset.md` (event completion + in-run reset surfaced by
> Pause).

## Goal

Cover every surface `gameplay.md` implies with **3 locations**, **6 diegetic
rigs**, and **4 flat overlays** — reusing the car you already render and the
camera you already drive, so the menu count stays tiny.

## Current state (measured from the code)

- **No meta-game UI and nothing pauses.** Only `HUD` (layer 2, `scripts/hud.gd`,
  `main.tscn:87-89`), `MobileControls` (layer 3, `main.tscn:143-145`) and the
  perf overlay exist; nothing uses `get_tree().paused` (per
  `todo/stage-start-and-end.md`). The scene is live on load
  (`world.gd._ready()`, `scripts/world.gd:10`).
- **The car is already a reusable 3D node.** `Car.apply_car(index)` /
  `respawn(old, index, spawn_xform)` / `next_car_index()` (`car.gd:253,226,239`)
  build a car (procedural chassis or the glb body) at a transform. The diegetic
  car lineups **reuse this** to spawn *parked, physics-frozen* cars at station
  markers — no new render path. `CarLibrary.CARS` (`car_library.gd:81+`) is the
  source (and where metadata/HP get added).
- **The camera is already retargetable.** `CameraManager` has
  `enum Mode { CHASE, BONNET }` (`camera_manager.gd:7`), with `cycle()`,
  `retarget(car)` and `_apply()` (`camera_manager.gd:31,42,53`); `ChaseCamera`
  smooths toward its `target` (`chase_camera.gd:3,25`). The menu camera is a
  **new mode / dedicated cinematic camera** that animates between station markers
  using the same retarget pattern.
- **Start-line reuse:** `world._generate_track(cfg)` builds a stage from
  `cfg.track_seed` (`world.gd:58,65`) — the map passes a rally's seed in to
  enter that rally.
- **No player-progress save.** `Config` autoload (`scripts/config.gd`) holds only
  the working `GameConfig` (`Config.data`, `:6`).

---

## Locations (continuous spaces, linked by camera fly-throughs)

1. **HQ / Garage** *(the hub — one continuous space you pan around, an outdoor
   car park wrapping a garage building)*. Physically contains three **stations**:
   - **Car park** *(outdoor)* — your owned cars parked in the lot (the *showroom
     rig*). **On first run this same lot shows the 3 starter cars** for the
     starter pick; the two unchosen starters can be won later (`gameplay.md`).
   - **Tuning lift** *(inside the building)* — the selected car raised; tuning
     happens here, **and** upgrades are installed here (the inventory opens as a
     flat overlay — see overlay 9 — when you choose *add upgrade* / *use repair
     kit*). Absorbs the old separate parts bench.
   - **Map table** *(inside)* — the rally selector: a stylised map plane with 3D
     pins (see rig 3).
   The camera glides from the car park into the building and between stations;
   this single location absorbs what would have been the Garage, Tuning,
   Inventory, Starter-showroom **and** World Map screens.
2. **Start line** *(per rally)* — the fielded car on the grid with the stage
   ahead: **briefing → pre-launch presence → countdown → run → between-event
   standings**. Mostly owned by `todo/stage-start-and-end.md` /
   `track-progress-and-reset.md`; entered by fly-through from the map.
3. **Podium** *(end of rally)* — a 3D podium with the top-3 cars + the reward
   reveal, then a fly-through back to HQ (the won car arrives in the car park).

## Diegetic rigs (3D, reusable inside locations)

1. **Showroom rig** — N parked, physics-frozen car nodes (here, in the outdoor
   **car park**) + the menu camera dollying to the focused car + a world-anchored
   **stats panel**. Parameterised by *(car list, optional filter, on-select)*.
   **The workhorse**, reused for: the first-run **starter pick** (car list = the
   3 starters), **HQ owned-car browse** (car list = owned), and **field-a-car**
   for a rally (filtered to *owned ∧ eligible*). Built on `Car.respawn`/`apply_car`.
2. **Stats panel (world-anchored)** — floating panel beside the focused car:
   metadata tags (engine/drivetrain/country/type/power-to-weight), **HP bar**,
   installed upgrades, performance summary. Rendered as a `SubViewport` texture on
   a camera-facing quad (or `Label3D` for simple text). Reused wherever a car is
   focused (showroom rig, tuning lift, reward arrival).
3. **Map (stylised plane + 3D pins)** — a styled map plane the camera pans
   across; rally **pins** show *locked / eligible / completed* state and, on
   focus, the rally's restriction + 3 events; a **showdown progress meter**
   (*rallies completed / total*) sits alongside. Selecting a pin → fly-through to
   the Start line.
4. **Tuning lift** — the selected car raised on the lift; world-anchored sliders
   drive the real config knobs (below). **Also the install point for upgrades**:
   an *add upgrade* / *use repair kit* action opens the **inventory overlay**
   (overlay 9) to pick a part to fit; installing applies it to the raised car.
   This rolls the old parts bench into the lift.
5. **Reward reveal** — a *physical* reveal replacing the slot-machine metaphor: a
   spotlight sweeps the car park and stops on the reward, or a garage door opens
   and the won car rolls in; item rewards drop into the inventory. Resolves to a
   *stats panel* (car) or a toast + inventory badge (item).
6. **Podium** — top-3 cars on a 3D podium; the diegetic counterpart of the
   standings overlay for the headline result.

## Flat overlays (pragmatic hybrid — dense data & pause only)

7. **Standings overlay** — full ranked field (position, name, time / `DNF` /
   `WRECKED`, player highlighted). Shown as a between-event interstitial and at
   results; the Podium handles the top-3 flourish, this handles the full list.
8. **Pause overlay** — Resume / **Abandon to HQ** (no retry — a non-top-3 rally is
   re-entered later from the map, `gameplay.md`). First user of `get_tree().paused`.
9. **Inventory / upgrade picker** — the flat list of owned items (upgrade parts +
   repair kits, with counts) the **tuning lift** opens to install a part onto the
   raised car or spend a repair kit. Flat by design (pragmatic hybrid: dense list,
   readability wins); replaces the old physical parts bench.
10. **ConfirmModal** — small message + confirm/cancel: "field this low-HP car?",
    "abandon rally?", "install upgrade?", "use repair kit?".

### Tuning-lift knobs (real config fields)

Per `gameplay.md` › Tuning, mapped to existing `GameConfig` (`game_config.gd`):
- **Front/rear grip balance** — `wheel_friction_slip_front` (`:106`) /
  `wheel_friction_slip_rear` (`:107`).
- **Aero balance** *(only if the aero upgrade is installed)* —
  `downforce_front` / `downforce_rear` (`:76,80`).
- **Brake bias** — **new knob** (today `brake_torque` `:66` is one per-axle
  value); add a front/rear split.

## Reuse matrix (location × rig/overlay)

| Rig / overlay | HQ | Start line | Podium |
|---|:--:|:--:|:--:|
| Showroom rig | ● (car park: owned + starter pick) | ● (field-a-car) | |
| Stats panel | ● | ● | ● (reward) |
| Map (plane + pins) | ● | | |
| Tuning lift (+ upgrade install) | ● | | |
| Reward reveal | ● (car arrives) | | ● |
| Podium | | | ● |
| Standings overlay | | ● (interstitial) | ● |
| Pause overlay | | ● | |
| Inventory / upgrade picker | ● | | |
| ConfirmModal | ● | ● | ● |

## Navigation flow

```
Title ─New─▶ HQ car park (starter pick) ─────────────────▶ HQ ◀───────┐
      Continue ───────────────────────────────────────────▶ HQ       │
HQ (pan): car park (lineup) ⇄ tuning lift (tune + upgrades) ⇄ map     │
   tuning lift ─add upgrade▶ Inventory overlay ▶ install ▶ lift       │
   map ─select rally▶ field-a-car (showroom rig) ─flythrough─▶         │
        Start line: briefing ▶ presence ▶ countdown ▶ RUN (HUD)        │
            RUN ⇄ Pause overlay                                        │
            RUN ─(events 1,2)▶ Standings overlay ▶ RUN                 │
            RUN ─(event 3)──▶ Podium: standings + Reward reveal ───────┘
                  (no retry: a non-top-3 rally returns to HQ, re-enter from map)
```

## Technical approach (proposed)

- **Menu camera:** add a `MENU` mode to `CameraManager` (`camera_manager.gd:7`)
  or a dedicated cinematic camera that tweens between named **station markers**
  (Position3D nodes) per location, reusing the `retarget`/`_apply` pattern
  (`:42,53`). Camera move times → `GameConfig`.
- **Parked cars:** instantiate via `Car.respawn`/`apply_car` (`car.gd:226,253`)
  with physics frozen (`freeze = true`) at car-park markers — reuses the existing
  car visuals, no new render path.
- **World-anchored panels:** `SubViewport` → texture on a camera-facing quad
  (`Sprite3D`/`MeshInstance3D`), or `Label3D` for simple labels. Flat overlays
  (standings/pause) stay on a `CanvasLayer` above the HUD.
- **HQ is its own lightweight scene** (no track generation); the Start line uses
  `world._generate_track(cfg)` (`world.gd:58`) with the selected rally seed.
- **Scene boundaries follow the locations:** HQ (car park + garage building;
  first-run starter pick is just the car park in starter mode), Start line+run
  (existing `main.tscn`), Podium. Fly-throughs are camera tweens; scene loads
  happen under cover of the fly-through/fade.

## Out of scope / open questions

- **HQ environment art** (the garage building, the outdoor car park, lighting,
  station layout, the indoor/outdoor transition) — design during build; only
  station-marker positions are config.
- **Input model for camera navigation** (left/right to next station/car, select,
  back) — unspecified here; needs an input-map pass.
- **Panel tech final call** — SubViewport-quad vs Label3D per panel; prototype
  both for legibility before committing.
- **Drivable overworld** was considered and **deferred** in favour of the
  stylised map + pins; revisit only if HQ→rally wants physical travel later.
- **Save format & slots** — owned by `todo/save-persistence.md`.
- **Mobile layout** for world-anchored panels and camera nav — unspecified.
