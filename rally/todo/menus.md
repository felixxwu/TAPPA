# Menus & UI Shell — implementation spec

> Status: **planned, not yet implemented.** Implementation brief for the
> meta-game menu layer described in `gameplay.md`. Follow the config-first
> convention (`CLAUDE.md`): any tunable (animation times, layout constants worth
> exposing) goes in `GameConfig` (`scripts/game_config.gd` +
> `config/game_config.tres`), never hardcoded. Update the relevant `features/*.md`
> doc and add/adjust tests in the same piece of work.
>
> **Design goal (from the user): the shortest possible menu set, achieved by
> reusing components.** This spec is organised around a handful of reusable
> components that the screens compose — not one bespoke screen per feature.
>
> **Dependencies (none implemented yet — see `gameplay.md` › Foundations):**
> - **Save / persistence** — owned cars, per-car HP, installed upgrades,
>   inventory, rally-completion state. Every screen here reads/writes it. Needs
>   its own todo first.
> - **CarLibrary metadata + per-car max HP** — the picker filters and the car
>   card read tags (engine/drivetrain/country/type/p-w) and HP that don't exist
>   on `CarLibrary.CARS` yet.
> - **Rally roster** — the finite list of rallies (seed + restriction) the World
>   Map renders.
>
> **Relates to** `todo/stage-start-and-end.md` (its placeholder stage-complete
> panel becomes the **Results** screen here; the countdown / pre-launch presence
> scene stay in that spec) and `todo/track-progress-and-reset.md` (event
> completion + the in-run reset that Pause exposes).

## Goal

Cover every UI surface `gameplay.md` implies with **5 reusable components** plus
**1 small utility**, composed into **6 screens** (the in-car HUD already exists).
Tuning and Inventory are **panels inside the Garage**, not separate screens, to
keep the count down.

## Current state (measured from the code)

- **No menu/meta-game UI exists.** The only UI is three `CanvasLayer`s:
  `HUD` (layer 2, `scripts/hud.gd`, `main.tscn:87-89`), `MobileControls`
  (layer 3, `main.tscn:143-145`), and the perf overlay (`scripts/perf_overlay.gd`).
  HUD visibility is gated by `Config.data.hud_enabled` (`hud.gd:18`).
- **Nothing pauses the game.** Per `todo/stage-start-and-end.md`, nothing uses
  `get_tree().paused` and there is no popup/menu/pause layer anywhere. The scene
  is live the instant it loads (`world.gd._ready()`, `scripts/world.gd:10`).
- **No player-progress persistence.** The `Config` autoload (`scripts/config.gd`)
  only holds the working `GameConfig` (`Config.data`, `config.gd:6`) and can
  `reset()` it to the authored baseline (`config.gd:18`). There is **no save of
  owned cars / HP / inventory / completion.**
- **Cars** live in `CarLibrary.CARS` — an array of dicts (`car_library.gd:81+`)
  with `name`, `mass`, `engine_type`, `drive_mode` (`RWD/AWD/FWD` consts at
  `car_library.gd:65-67`), grip, body dims, etc. **No** country / car-type /
  HP / power-to-weight fields yet. Car selection today is a debug cycle:
  `Car.apply_car(index)` / `respawn(old, index, spawn_xform)` / `next_car_index()`
  (`car.gd:253,226,239`), driven by `world.cycle_car()` (`world.gd:105`) off the
  HUD `CarButton` (`hud.gd:33-36`). The picker below **replaces** that debug cycle
  with real selection.
- **Track is seeded:** `world._generate_track(cfg)` uses `cfg.track_seed`
  (`world.gd:58,65`) — the World Map / Rally Briefing pass a per-rally seed in
  here to load a specific rally.

> Implication: this is greenfield. Build it as scene-based `Control` trees under
> `CanvasLayer`s (matching `hud.gd`'s pattern) on layers **above** the HUD, with
> one script per component/screen in `scripts/ui/` (proposed folder).

---

## Reusable components (build once)

1. **`CarPicker`** — a scrollable list / carousel of cars. Parameterised by
   *(source list, optional filter predicate, action label, on-select callback)*.
   Renders a `CarCard` for the focused entry. **This is the workhorse** the user
   flagged — see the reuse matrix.
2. **`CarCard`** — read-only display of **one** car: name, metadata tags
   (engine / drivetrain / country / type / power-to-weight), **HP bar**, installed
   upgrades, performance summary. A pure display unit; everything car-shaped
   embeds it.
3. **`StandingsList`** — ranked rows: position, name, combined/event time or
   `DNF`/`WRECKED`, with the player's row highlighted. Built from a rally's fixed
   opponent field (`gameplay.md` › Opponents).
4. **`RewardReveal`** — the lootbox / slot-machine reveal. Resolves to either a
   `CarCard` (rally reward) or an item tile (event reward) — one animation, two
   payload types.
5. **`ItemList`** — grid of inventory items (upgrades + repair kits) with a select
   callback. Item tile is its sub-unit; reused as `RewardReveal`'s item payload.
6. **`ConfirmModal`** *(small utility)* — generic message + confirm/cancel. Reused
   for "field this low-HP car?", "abandon rally?", "install upgrade?", "use repair
   kit?".

## Screens (compose the components)

1. **Title / Save** — New Game / Continue. New Game opens `CarPicker` over the 3
   starters ("choose your starter"). Minimal.
2. **World Map** *(hub)* — lists the rally roster with per-rally state
   (**locked** / **eligible** / **completed**), shows the **showdown progress
   meter** (*rallies completed / total*, `gameplay.md` › Final showdown), and a
   button into the Garage. Selecting a rally → Rally Briefing.
3. **Rally Briefing** — one rally: its restriction, the 3 events, and **Field a
   car** → `CarPicker` filtered to *owned ∧ eligible*; `ConfirmModal` if the
   chosen car is low on HP; **Start** loads the rally seed into
   `world._generate_track` and begins the run. The **final showdown is just a
   rally** here (unlocked once all others are completed) — no extra screen.
4. **Garage** *(hub)* — composes `CarPicker` (owned cars) + `CarCard` (selected) +
   a **Tuning panel** (sliders, below) + an **Inventory panel** (`ItemList` →
   apply upgrade / repair kit to the selected car, via `ConfirmModal`). Tuning and
   Inventory are **panels here, not separate screens.**
5. **Pause overlay** *(in-run)* — Resume / **Retry** (damage sticks,
   `gameplay.md` › Run stakes) / Abandon to map. First user of `get_tree().paused`.
6. **Results → Reward** — post-run sequence: `StandingsList` (final combined
   standings, **podium** styling for top-3) → `RewardReveal` (the per-event
   upgrades and, if **top-3**, the rally car). Offers **Retry** if not top-3. This
   is the concrete realisation of the placeholder panel from
   `todo/stage-start-and-end.md`.

> **Between-events leaderboard** (after events 1 & 2) is **not a new screen** — it
> is `StandingsList` shown as a short interstitial, then the next event starts.
> **HUD** already exists (`hud.gd`); its debug `CarButton` is removed once the
> Garage/Briefing own car selection.

### Tuning panel knobs (real config fields)

Per `gameplay.md` › Tuning, mapped to existing `GameConfig` (`game_config.gd`):
- **Front/rear grip balance** — `wheel_friction_slip_front` (`:106`) /
  `wheel_friction_slip_rear` (`:107`).
- **Aero balance** *(only if the aero upgrade is installed)* —
  `downforce_front` / `downforce_rear` (`:76,80`).
- **Brake bias** — **new knob** (today `brake_torque` `:66` is a single per-axle
  value); add a front/rear split.

## Reuse matrix

| Component | Title | World Map | Rally Briefing | Garage | Pause | Results |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| `CarPicker` | ● (starter) | | ● (field) | ● (browse) | | |
| `CarCard` | ● | | ● (fielded) | ● | | ● (reward) |
| `StandingsList` | | | | | | ● (+ podium, interstitial) |
| `RewardReveal` | | | | | | ● (car + items) |
| `ItemList` | | | | ● (inventory) | | ● (item reward) |
| `ConfirmModal` | | | ● | ● | ● | ● (retry) |

## Navigation flow

```
Title ─New─▶ CarPicker(starter) ─▶ World Map ◀────────────────┐
            Continue ─────────────▶ World Map (hub)           │
World Map ⇄ Garage (CarPicker+CarCard+Tuning+Inventory)       │
World Map ─▶ Rally Briefing ─field(CarPicker)▶ Run (HUD) ──┐  │
                                         Pause overlay ⇄ Run│  │
   Run ─(events 1,2)▶ StandingsList interstitial ─▶ Run     │  │
   Run ─(event 3)──▶ Results (StandingsList/podium)         │  │
                       └▶ RewardReveal ─▶ World Map ─────────┴──┘
                       └▶ Retry (if not top-3) ─▶ Run
```

## Out of scope / open questions

- **Visual style & animation** of each component (slot-machine timing, podium
  staging) — to be designed during build; expose timings via `GameConfig`.
- **Confirm panel-vs-screen** for Tuning/Inventory: spec'd as Garage panels to
  minimise screens; revisit if they grow.
- **Mobile layout** — `MobileControls` (layer 3) coexists with the run HUD only;
  menus assume pointer/touch but their responsive layout is unspecified here.
- **Save format & slots** — owned by the (pending) save/persistence todo, not
  this one.
