# Menus & UI shell — remaining diegetic slices

**The diegetic 3D HQ has SHIPPED**, and so has almost everything this spec once
described. `features/menus.md` is the living doc (source: `hq.tscn` + `scripts/hq.gd`
with its `hq_challenge.gd` / `hq_table.gd` / `hq_carpark.gd` split, `podium.tscn` +
`scripts/podium.gd`, `standings.tscn`, `start_line.gd`, `pause_menu.gd`,
`confirm_popup.gd`, `settings_menu.gd`; nav tests in `tests/headless/test_menu_flow.gd`
and `test_menu_nav.gd`). HQ is ONE 3D space the camera flies through
(`enum View { EXTERIOR, GARAGE, TABLE, CARPARK }` + `_go_to(view)`), with the 3D map
table and pins, the parked-car lineup, the tuning lift (TUNE sliders + UPGRADES
install/repair), the `RallySession.start_rally` handoff, the start-line sequence, the
podium reward reveal, the standings overlay and the between-event interstitial all in.
The `menu_*` input actions exist in `project.godot` and every menu is keyboard +
gamepad navigable (see `features/menus.md` → "Menu navigation").

## What is still open

- **World-anchored SubViewport stats panels** — richer than the current `Label3D`
  labels. Open question kept from the original spec: SubViewport-quad vs `Label3D` per
  panel; prototype both for legibility before committing.
- **The 3D podium + reward-reveal rig** — the podium and standings are still flat
  scenes. The diegetic version is top-3 cars on a real podium, and a *physical* reveal
  instead of the slot-machine metaphor (a spotlight sweeping the car park and stopping
  on the reward, or a garage door opening and the won car rolling in). Item rewards
  resolve to a toast + inventory badge.
- **Per-car paint, and duplicate-model name suffixes** — instance-based ownership
  allows two of the same model with diverging HP/upgrades, so the lineup/stats label
  wants a short auto-suffix ("MX-5 #2") keyed on the owned car's `instance_id`.
- **Camera fly-through transitions for the longer hops** — notably the
  **map → start-line** transition, which still cuts.
- **Designed HQ environment art** — the garage building, the outdoor car park,
  lighting, station layout, the indoor/outdoor transition. Blocks are placeholder;
  only station-marker positions are config.
- **Diegetic styling for the flat overlays that remain deliberately flat** — the
  standings list and pause menu work, but read as programmer UI.
- **Mobile layout** for world-anchored panels and camera navigation — unspecified.
  Tap to focus/select and swipe to pan between stations, reusing the `MobileControls`
  `CanvasLayer` pattern (`features/mobile-controls.md`) with menu affordances rather
  than driving sticks.
- **UI audio** — `menu_*` actions should fire `ui_move` / `ui_select` / `ui_back`
  SFX; blocked on `todo/audio.md` (there is no `Audio` autoload yet).

Follow the config-first convention: tunables (camera move times, panel offsets,
station positions worth exposing) go in `GameConfig` (`scripts/game_config.gd` +
`config/game_config.tres`), never hardcoded. Update `features/menus.md` and add/adjust
nav tests in the same piece of work.

## Superseded

The original spec deferred a **drivable overworld** in favour of the stylised map + pins.
That decision has since been revisited and the overworld shipped behind
`GameConfig.overworld_enabled` — see `todo/overworld-hq.md` and `features/overworld.md`.
