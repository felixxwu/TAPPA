# Menus & UI Shell — implementation spec (diegetic / in-world)

> Status: **🟡 FLAT-UI LOOP COMPLETE — full diegetic 3D build still open.** A
> flat-UI loop is in place and proves the loop end-to-end with the meta-game made
> legible: **HQ (boot) → field car → run → podium → HQ**, wiring `RallySession`
> (`todo/rally-event-flow.md`) into the run scene. See the living doc
> [`features/menus.md`](../features/menus.md) (source: `hq.tscn` + `scripts/hq.gd`,
> `podium.tscn` + `scripts/podium.gd`, session-aware fielding in `scripts/world.gd`;
> tests in `tests/headless/test_menu_flow.gd`).
>
> **What the flat-UI build already covers (struck from the build list below):** the
> HQ hub as the boot scene (immortal-starter grant, scrollable so Start never
> clips on phones); **car selection as stat cards** (drivetrain/country/type/
> reward-tier/power-to-weight + an HP bar + installed upgrades — the flat stand-in
> for rig 1+2); the **rally board with unlock state** (every rally shown,
> ineligible ones disabled with their restriction spelled out, showdown gated with
> a progress meter — the flat stand-in for rig 3); the **Start →
> `RallySession.start_rally`** handoff; run-scene **fielding** +
> `stage_completed`/`wrecked` → `report_*` wiring; the **Podium reward reveal**
> (won car with a NEW badge + per-event upgrades — flat stand-in for rig 5+6); and
> the **Standings overlay (overlay 7)** at results (full ranked field via
> `RallyLibrary.build_standings`).
>
> **What remains (the bulk of this spec):** the entire **diegetic 3D staging** —
> the car-park / tuning-lift / map-table locations, the stylised map plane + pins,
> world-anchored SubViewport stats panels, the 3D podium + reward-reveal rig, the
> Pause / Inventory / Confirm overlays, the between-event standings interstitial,
> the `menu_*` input action set + mobile gestures, and the camera fly-through
> transitions. The sections below specify that remaining work. **The HQ flow has
> SHIPPED as three separate screens** — a **basic pannable world map** of icon pins
> with star ratings (best-placement: 1st→★★★, 3rd→★☆☆) + showdown lock + progress,
> a **rally-detail** screen (Enter Rally), then a **3D car park** showing only the
> eligible cars (parked lineup + panning menu camera + `Label3D` stats + `menu_*`
> inputs); see [`todo/diegetic-hq.md`](diegetic-hq.md). Still deferred: the map's
> **stylised 3D plane + 3D pins** (the flat map is the basic version), per-car
> paint, the tuning lift, the 3D podium/reward rig, and the fly-throughs.
>
> Follow the config-first convention
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

0. **Title** *(boot)* — **diegetic**: the menu camera opens on the **HQ exterior**
   with a flat title card + **Continue / New / Settings** (Continue shown only if
   `Save.has_save()`). New → `ConfirmModal` (overwrites the single profile) →
   starter pick; Continue → fly into HQ; Settings → overlay 11. Not a separate
   scene — it's the HQ scene framed from outside with the title overlay, then the
   same fly-through into the car park. Kept lightweight.
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
   standings**. The **briefing** is a world-anchored panel showing rally name,
   restriction, the 3-event overview, and your fielded car + **HP bar** (so the
   risk is legible before you commit). The presence cars (ahead/behind) are
   atmospheric flavour, not the real opponent field (`todo/rally-event-flow.md`).
   Mostly owned by `todo/stage-start-and-end.md` /
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
   **Duplicate models** (instance-based ownership allows two of the same model
   with diverging HP/upgrades — `todo/save-persistence.md`) are disambiguated by a
   short auto-suffix in the lineup/stats label (e.g. "MX-5 #2"), keyed on
   `OwnedCar.instance_id`.
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
   `WRECKED`, player highlighted). ~~Shown at results~~ ~~and as a between-event
   interstitial~~ **(DONE, flat: at the podium via `RallyLibrary.build_standings`,
   AND as the between-event interstitial `standings.tscn` showing the cumulative
   leaderboard — the rally pauses there and `continue_to_next_event()` resumes).**
   The Podium handles the top-3 flourish; this handles the full list. Open: the
   diegetic 3D styling.
8. **Pause overlay** — Resume / **Settings** (opens overlay 11 without unpausing) /
   **Abandon to HQ** (no retry — a non-top-3 rally is re-entered later from the
   map, `gameplay.md`). First user of `get_tree().paused`.
9. **Inventory / upgrade picker** — the flat list of owned items (upgrade parts +
   repair kits, with counts) the **tuning lift** opens to install a part onto the
   raised car or spend a repair kit. Flat by design (pragmatic hybrid: dense list,
   readability wins); replaces the old physical parts bench.
10. **ConfirmModal** — small message + confirm/cancel: "field this low-HP car?",
    "abandon rally?", "install upgrade?", "use repair kit?".
11. **Settings overlay** — volume sliders (Master / SFX / Music / Engine) + a
    quality toggle, reachable from **Pause** and **Title**. Flat by design (dense
    controls). Owned by `todo/settings.md` (persists to `settings.cfg`, separate
    from the progression save); this list just notes where it surfaces.

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

## Menu navigation & input

The diegetic menus need a small, **dedicated input action set**, separate from
the driving inputs (`accelerate`/`steer_*`/etc. in `project.godot [input]`), so
panning between stations/cars/pins is unambiguous:

- **Actions** (new entries in `project.godot [input]`): `menu_left` / `menu_right`
  (previous/next car or station), `menu_up` / `menu_down` (move between focusable
  panels, slider rows), `menu_select` (confirm / pick), `menu_back` (up a level /
  close overlay). Defaults: arrows + Enter/Esc; gamepad d-pad + A/B.
- **Camera response:** `menu_left/right` retarget the menu camera to the
  adjacent station marker / parked car (reusing `CameraManager.retarget` /
  the `MENU` mode below); `menu_select` triggers the focused action (field a car,
  select a rally pin, install an upgrade).
- **Mobile:** tap a car/pin/panel to focus + select; swipe left/right to pan
  between stations/cars; a Back button mirrors `menu_back`. Reuses the
  `MobileControls` `CanvasLayer` pattern (`mobile-controls.md`) but with menu
  affordances, not driving sticks. Layout of these is still open (below).
- **UI audio:** `menu_*` actions fire `ui_move` / `ui_select` / `ui_back` SFX
  (`todo/audio.md`).

An input-map pass adds these actions; the rigs read them uniformly so every
location navigates the same way.

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
- **Input model for camera navigation** — specced in *Menu navigation & input*
  above (new `menu_*` actions + mobile gestures); the concrete keybind defaults
  and an input-map pass are the remaining work.
- **Panel tech final call** — SubViewport-quad vs Label3D per panel; prototype
  both for legibility before committing.
- **Drivable overworld** was considered and **deferred** in favour of the
  stylised map + pins; revisit only if HQ→rally wants physical travel later.
- **Save format & slots** — owned by `todo/save-persistence.md`.
- **Mobile layout** for world-anchored panels and camera nav — unspecified.
