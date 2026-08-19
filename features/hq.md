# HQ — the garage hub (`hq.gd`)

**Sources:** `hq.tscn` + `scripts/hq.gd` (`class_name HqController`), the 2D overlay/menu-layer
builders in `scripts/hq_overlays.gd` (`class_name HqOverlays`), the Rally Challenge screen in
`scripts/hq_challenge.gd`, the Multiplayer entry screen in `scripts/hq_multiplayer.gd`, the map
table's navigation in `scripts/hq_table.gd` (`class_name HqTable`) and its pin/fog layer in
`scripts/hq_map_table.gd` (`class_name HqMapTable`), the car park in `scripts/hq_carpark.gd`
(`class_name HqCarpark`), the tuning lift in `scripts/hq_tuning_lift.gd` (`class_name
HqTuningLift`), the present-box car reveal in `scripts/hq_present_reveal.gd` (`class_name
HqPresentReveal`), and the shared rally-detail panel in `scripts/rally_detail.gd`.

**Tests:** `tests/headless/test_menu_flow.gd`, `tests/headless/test_overworld_garage.gd`, `tests/headless/test_hq_multiplayer.gd`, `tests/headless/test_hq_map_table.gd`, `tests/headless/test_hq_tuning_lift.gd`, `tests/headless/test_hq_present_reveal.gd`

The diegetic 3D hub the player returns to between rallies. The game-loop shell around it —
what leads where — is [menus.md](menus.md); how any of these screens is driven by keyboard and
gamepad is [menu-navigation.md](menu-navigation.md); adding a persisted setting is
[settings.md](settings.md), which used to be a subsection of this page and is not an HQ concern.

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). A first-time player (no `starter_picked`) is **not** auto-granted
a car: pressing **Start** on the title routes them into the car park's
**starter picker** (`_enter_starter_pick`, which puts the car park in `CarparkMode.STARTER`)
showing the three
authored-body cars (Miot Roadster, Fjord Focal, Rondel Twist) as preview cars from `CarLibrary`; choosing one
(`_confirm_starter`) grants it as a normal first car, records
`starter_picked` / `starter_model_id` / the selection, and enters the garage. Back
returns to the title. Returning players skip the picker and Start goes straight to
the garage. The picker reuses the car park's keyboard/gamepad nav (`_cars_input`:
left/right/select/back). Building the HQ (the ground — grass with the tarmac apron
feathered into it via the shared road-blend mesh, `MeshUtil.feathered_ground_mesh`,
the same treatment as the track verges and podium pads — buildings, the tree ring plus an
interleaved bush ring and three static spectator crowds — pure scenery, no steering
(`HQEnvironment._build_bushes` / `_build_spectators`) — the garage, the parked
lineup) is synchronous and takes a beat, so on a real display
`_ready` shows a **`LoadingScreen` cover** the moment the scene starts, builds behind
it (`_build_hq`), then reveals — bridging the gap after Godot's boot bar so the load
never looks frozen. Under the headless test runner it builds synchronously with no
cover (so tests see a ready HQ after one frame). HQ is **one diegetic 3D space** the camera flies through; an
`enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS }` names the camera **stations** and
`go_to(view)` tweens the single `Camera3D` between their poses
(`GameConfig.hq_*_cam_eye/look`, eased over `menu_camera_move_time`). Clickable 3D
objects (the table, the lift, the rally pins) are `Area3D` with `input_ray_pickable`
(`get_viewport().physics_object_picking` is on); their handlers also respond to
`menu_*` keyboard/gamepad input. The **static 3D world** — everything that never
changes once built — is split into **`HQEnvironment`** (`scripts/hq_environment.gd`),
a small `RefCounted` collaborator `hq.gd._build_hq` drives via `_env.build(self,
_on_table_input, _on_lift_input)`: it parents all the geometry to the HQ node (so the
scene tree is unchanged), wires the pickable table/lift areas back to hq's own click
handlers, and hands back the `camera` / `map_table` / `pins_root` handles hq keeps
driving (the dynamic props — the parked-car lineup, the lift car, the map pins — stay
in `hq.gd`). Its pieces: a block-building skyline **behind the garage**
(`_build_buildings`, kept clear of the title camera's view), low-poly mesh **trees**
framing the lot (`_build_trees`, reusing the stage's `TreeMeshField` via
`MeshUtil.first_mesh`), the garage shell, the lift — built from `BoxMesh`
blocks via `_block()` (placeholder art; the framing/positions that the flow depends
on are in `GameConfig`). The **map table** is the exception: `_build_map_table`
instantiates a proper `MapTable` model (`scripts/map_table.gd`) — a wooden tabletop
on four legs, with a skirt apron under the top edge and low stretcher rails, all
wearing a procedurally-generated wood-grain texture. Its origin is the floor centre
and its top surface stays at `hq_table_size.y`, so the satellite map plane and the
rally pins still align. The model is standalone-renderable for visual iteration via
`tools/render_map_table.sh` (→ `docs/map_table/*.png`). The ground is a **grass-textured field** (the run scene's
`textures/grass.jpg`, tiled by `terrain_tile_per_meter`) with a **grey concrete
apron** laid on top around the garage + car park (`hq_concrete_center`/`hq_concrete_size`),
so the lot reads as paved and everything beyond it as field. The car park itself is a
**painted parking-bay surface** (`_build_carpark`): a tarmac plane over the apron with
white bay dividers (one bay per `carpark_page_size`, `menu_car_spacing` wide) generated
procedurally as an `ImageTexture` (`_carpark_bay_texture`), so each parked car sits in
its own marked bay.

**EXTERIOR (boot/title).** A side-by-side row of — left to right —
**Exit Game | Free Roam | Settings | Start**, per the button-order rule above: leaving is
leftmost, proceeding is rightmost. **Exit Game** (`_on_exterior_exit` →
`get_tree().quit()`) is built on non-web builds ONLY, where the tab owns the process
lifecycle, which is why Start's cursor index is computed rather than hardcoded. **There is
no Account button** — that slot holds Free Roam, and the account page is reached as a
Settings page instead (one route, not two; see the note in
`hq_overlays.gd::build_title_overlay`). The row sits at the bottom over an establishing shot of the
outdoor car park, with a block skyline **behind the garage** and trees framing the
lot. The player's **whole owned collection** is parked in the car park here
(`_build_title_lineup`, rebuilt on entering EXTERIOR) so the title shows off every
car. Because `_render_lineup_page`'s per-car build is progressive (one fresh prop per
frame — below), and `_build_hq` never awaits it, `hq.gd::_ready` explicitly `await
lineup_built` after `_build_hq()` (EXTERIOR boot only, before `loading.finish()`):
without that await, `_build_hq()`'s call returns the instant the first uncached owned
car yields a frame, so the rest of that page's fresh spawns — bounded to
`carpark_page_size`, but still the expensive `CarProp.spawn` per car (below) — would
trickle out **after** the loading cover lifts, landing as the "big lag spike right
after the game first loads" for a player with several owned cars. Awaiting
`lineup_built` keeps that whole page's worth of cold-instantiate cost **behind the
cover**, where a brief wait reads as loading rather than gameplay jank, and it warms
`_car_cache` for every parked car so the car park and tuning lift (above) start
from a hit, not a cold build.

**The map table is likewise split out** into **`HqTable`** (`scripts/hq_table.gd`), held as
`_table_ui`: entering the table, the new-rally reveal sequence, pin focus / panning / target
selection, and opening the rally detail panel — 25 functions. (The panel ITSELF has since
moved out again, to `RallyDetail` — see "The rally-detail panel" below.)

Three things stayed on `HqController` and are worth knowing about, because they sat *inside*
the moved region: **`_process`** (an engine callback — Godot would never fire it on a
`RefCounted`, so the table pan and reveal animation would silently stop advancing), and
**`_eligibility_summary` / `_qualifying_cars_text`**, which `hq_challenge.gd` also calls. They
now live directly below the table code under a banner saying so — as *names*: the derivations
themselves moved to `RallyDetail` with the panel that is their main consumer, and
`HqController` keeps one-line wrappers so every existing caller (and every test that calls
them off the controller) is unchanged.

### The rally-detail panel (`scripts/rally_detail.gd`)

The card that names a rally, says which of your cars may enter it, shows your best finish and
offers `Enter Rally — choose car` is **`RallyDetail`**, and it is the one component in the HQ
set that is NOT an `HqController` collaborator: it takes a **host `Node`**, not a back-reference,
so either hub can show it. It used to be split in half — built by
`hq_overlays.gd::build_detail_overlay`, filled by `hq_table.gd::_show_detail`, with its nine
widget handles and its open flag living on the HQ node — which made it reachable only from
inside `hq.tscn`.

- **`build(host, on_back, on_enter, on_dev_win)`** — parents the panel under `host` via
  `MenuPage.open_modal` and wires the three footer controls. `on_dev_win` may be an empty
  `Callable`, in which case the dev "win this rally" button is not built at all (it is still
  additionally gated on `SettingsMenu.dev_tools_enabled()`).
- **`fill(rally, profile, rally_id := "")`** — rewrites the card for one rally against one
  profile's garage and sets `open`. The host owns making the layer visible, because only it
  knows whether its own view is on screen (`hq.gd::update_overlays`).
- **State** — `layer`, `page`, `open`, and the nine widget handles (`title`, `region`,
  `special`, `restriction`, `qualify`, `adjust`, `record`, `stars`, `enter_button`, plus
  `dev_win_button`) all live on the panel. `hq.gd` keeps one-line forwarding properties at the
  old `_detail_*` names, because the readers are spread across `hq.gd`, `hq_table.gd`,
  `hq_challenge.gd` and the menu tests; `_detail_open` has a setter too, since every screen
  that leaves the table closes the panel by writing it.
- **Shared vocabulary moved with it, as statics** — the widget builders (`plain_label`,
  `heading`, `wrap_label`), the modal width rule (`body_width`) and the text/eligibility
  derivations (`restriction_text`, `entry_plan`, `convertible_for`, `eligibility_summary`,
  `qualifying_cars_text`, `stars_for`). `HqController`'s `label()` / `detail_heading()` /
  `detail_wrap_label()` / `_modal_body_width` / `_restriction_text` / `_entry_plan` /
  `_convertible_for` / `_eligibility_summary` / `_qualifying_cars_text` / `_stars_for` are now
  wrappers over them, so `hq_challenge.gd`, `hq_carpark.gd` and the tests keep calling the
  names they always did. `MAX_QUALIFY_NAMES` is declared on `RallyDetail` and re-exported by
  `HqController` for the same reason — one value, both names.
- **The dependency runs ONE way.** `hq.gd` knows about `RallyDetail`; `RallyDetail` knows
  nothing about `HqController`, so the two classes cannot cycle and the overworld can host the
  panel without dragging the HQ in.

### Two hubs, and where the boot redirect sits

`hq.tscn` is both `run/main_scene` and the "back to the hub" destination. Behind
`GameConfig.overworld_enabled` (**ships false**) there is a **second hub**: a life-size
drivable version of the same map (`overworld.tscn`, see
[overworld.md](overworld.md) and the design spec under `docs/superpowers/specs/`). Every
"return to the hub" transition routes through **`Scenes.hub_path()`** so a single missed site
cannot send the player to the wrong hub, and `Scenes.is_hub_scene()` answers the same question
for the music director, which picks hub-vs-rally music from the live scene path.

`hq.gd::_ready` carries the redirect, and **its placement is load-bearing** — it sits **after**
`_ensure_selection()` and **after** the `_should_autostart_benchmark()` check, in
`_maybe_redirect_to_overworld()`:

1. **After `_ensure_selection()`**, because the overworld fields the profile's *selected* car
   and `Save.selected_car()` is what heals a stale selection.
2. **After the benchmark check**, or the `?bench=1` web profiling boot stops reaching
   `Benchmark.start()`.
3. **It must not bypass `_build_hq`**, which is the ONLY consumer of the `RallySession`
   one-shots. So the redirect *reads* them and declines whenever one is set — it never clears
   them; clearing stays `_build_hq`'s job, because consuming a one-shot in two places is how
   one of them goes missing:

| One-shot | Effect on the redirect |
|---|---|
| `return_to_garage` | Stay in `hq.tscn`; `_build_hq` boots at `GARAGE`. **This is the infinite-loop guard** — it is exactly how the overworld's garage zone works, and a redirect here would bounce straight back. |
| `return_to_map` | Stay; the new-rally reveal parade runs on the table as today. |
| `pending_car_reveal_instance_id` | Stay; the won-car present box opens as today. |
| `pending_rally_pick_id` *(new)* | Stay; `_build_hq` seats it as `_selected_rally_id` and calls `_enter_car_screen()`, so a zone activation in the overworld lands on that rally's car picker. The zone names the rally, never the car. |

The redirect is **additionally gated on `Save.profile.starter_picked`**. A fresh profile has it
false and **zero owned cars**, and the starter picker plus the opening-rally drop is reachable
only from the title's Start (`_on_exterior_start` → `_enter_starter_pick` / `_confirm_starter`)
— so redirecting a fresh save leaves the overworld with no car to field and no route to pick
one, i.e. the game cannot be started at all. A fresh profile therefore always gets the normal
HQ flow, and the handoff happens on the next boot.

One zone restores the whole hub: the garage zone raises `return_to_garage` and loads
`hq.tscn`, whose garage row already reaches everything (`< Back` → the title row, `Career` →
the map table, `Online` → the challenge overlay, `Multiplayer` → the lobby entry screen,
Settings → account and reset).

**The exploration fog is shared too.** `HqController.build_fog_mask(profile)` is a static that
rasterises the 64×64 R8 lit mask from `RallyLibrary.lit_sources` in **normalised map space** —
the map table multiplies it into the map plane (`_apply_map_fog` + `FOG_SHADER`), and the
overworld's fog boundary feeds the same texture to its terrain shader. See
[map-exploration.md](map-exploration.md).

**The Rally Challenge screen is likewise split out** into **`HqChallenge`**
(`scripts/hq_challenge.gd`), held by `hq.gd` as `_challenge_ui` and built alongside `_overlays`
in `_build_hq`. It owns the 18 `*_challenge_*` functions — building and refreshing the
Daily/Weekly/Monthly overlay, fetching its leaderboard placing and cutoff, and the entry path
into a challenge stage.

The cut started **functions-only**, then followed up by moving the state each collaborator is
the SOLE user of — see "Where a field lives" below. The two player-facing text constants moved
with the functions and are reached statically as `HqChallenge._CHALLENGE_WIN_CONDITION` /
`._CHALLENGE_REWARD_TEXT`. See [../todo/hq-split.md](../todo/hq-split.md).

**The car park is likewise split out** into **`HqCarpark`** (`scripts/hq_carpark.gd`), held as
`_carpark_ui`: the eligible-lineup build, the parked-car prop cache and its Free-Roam prewarm,
focus cycling, the swap/damage readouts and the carpark modals — 35 functions, the largest of
the three cuts.

Two things stayed on `HqController` here for reasons the parser will not tell you about. The
`lineup_built` **signal** is declared on the node, so `HqCarpark` emits it as
`_hq.emit_signal("lineup_built")` — a `RefCounted` has no such signal. And anywhere the old
code passed `self` as a parent or host `Node` (`CarProp.spawn`, `ConfirmPopup.open`) it now
passes `_hq`; `self` would compile fine and fail only when the line ran. The boot-instrumentation
helpers (`_log_boot_cost` and friends, driven from `_ready`) and the shared `_car_stats_text` /
`_restriction_text` also stayed, below the carpark code under a banner saying so.

**Three more cuts followed**, finishing the split the markers in `hq.gd` were admitting to
(`4,764` lines → `3,564`):

* **`HqMapTable`** (`scripts/hq_map_table.gd`), held as `_map_table_ui` — the map table's
  DRAWN layer: `_refresh_map_pins` and its rebuild-skip stamp, `_make_pin` (flag / trophy /
  prize-car marker), the floating readout sprites, the dotted reveal graph, and the
  exploration-fog shader. The split against `HqTable` is **drawing vs. navigating**: this file
  builds the pins, `HqTable` walks them. They meet at exactly two calls, `_refresh_map_pins`
  and `_paint_pin_readout`, which stay as forwarders on `HqController` because `hq_table.gd`
  and the menu tests reach them by those names.
* **`HqTuningLift`** (`scripts/hq_tuning_lift.gd`), held as `_tuning_lift` — the whole lift
  station: the raise/lower rig (car + beam), the two-row HUB cursor, the Upgrades / Tuning
  sub-pages, the display car's spawn/reuse/stow cache, Repair, Test Drive, and the LIFT input
  branch (now `handle_input`).
* **`HqPresentReveal`** (`scripts/hq_present_reveal.gd`), held as `_present_ui` — the forced
  won-a-car beat: the box, its single bay marker, the Open button's states and the opening
  cinematic.

These three moved **functions only**. Unlike the earlier cuts, almost none of their state
followed, and that is the "ONE user" rule below doing its job rather than an omission: the
lift's widgets are built by `hq_overlays.gd` and its flags are read by `go_to` /
`update_overlays`; the pin state is navigated by `HqTable`; and `_present_opened` is branched on
by `hq.gd::_car_back` and asserted by `test_menu_flow.gd`. Every entry point that something
outside the new file already called by name stayed on `HqController` as a one-line forwarder —
moving a call site is not a behaviour-preserving refactor, so the names did not move.

### Where a field lives: ONE user means it is not shared state

The rule the cuts settled on. A field belongs to a collaborator when **exactly one**
collaborator reads or writes it and `hq.gd` itself never does; it stays on `HqController` when
two or more touch it. That second case is common and not a failure — `hq_overlays.gd` BUILDS
most of the widgets that `hq_table.gd` / `hq_challenge.gd` then read, so a widget handle
genuinely has two owners.

The tell for a field on the wrong side is `@warning_ignore("unused_private_class_variable")` on
`hq.gd`: the analyzer sees one file at a time, so a field only a collaborator touches reads as
dead there, and the tag was suppressing that. Nineteen such fields have moved to their single
user — the reveal parade's queue/token (`HqTable`), the Change-Upgrades popup handles, the
lineup settle generation, the focus-rev audio player and the prewarm stow marker (`HqCarpark`),
the challenge refresh generation and its two per-period board caches (`HqChallenge`), and the
title row's Free Roam / Settings / Exit buttons, the build watermark and the dev-win button
(`HqOverlays`). The tags that remain name genuinely shared state. **Don't add a new
`@warning_ignore` to `hq.gd` for a field one collaborator owns — put the field there instead.**

`hq.gd` grew a small **public** API for what collaborators legitimately need back from the
controller, so those calls stop reading as private reach-through: **`view()`** (which station is
live), **`go_to(view_id, snap)`**, **`update_overlays()`**, and the widget factories
**`label()`**, **`detail_heading()`**, **`detail_wrap_label()`**, **`challenge_info_row()`**.
The rest of the traffic is still `_hq._field` state access, deliberately: converting it all
would be churn without a boundary, and the fields above are where the boundary actually was.

### Input: one branch per station, and each cluster owns its own

`hq.gd::_unhandled_input` is a **dispatch**, not a switchboard. It still owns the things that
apply to every station in order — the `MenuNav.is_text_editing()` bail, the debug F7 world-menu
A/B and F8 config reload, and the `ConfirmPopup.any_open()` modal bail — and then hands the
event on:

```
if _challenge_ui.handle_input(event):   # the challenge modal owns the screen: stations stand down
    return
match _view:
    View.EXTERIOR: _exterior_input(event)
    View.SETTINGS: _settings_input(event)
    View.GARAGE:   _garage_input(event)
    View.LIFT:     _tuning_lift.handle_input(event)
    View.TABLE:    _table_ui.handle_input(event)
    View.CARPARK:  _carpark_ui.handle_input(event)
```

Every handler returns **whether it consumed the event**. Nothing chains off the answer after
the `match` — `_unhandled_input` is the last stop, and the one handler that must really mark the
viewport handled (the reveal parade's press swallow, now `hq_table.gd::_is_any_press`) does that
itself — but the contract is what lets `HqChallenge.handle_input` stand every station down by
answering `true` instead of `hq.gd` reading `_challenge_shown` by hand. The three stations whose
handlers stayed on `HqController` (title, settings, garage) have no collaborator of their
own; their widgets are built by `HqOverlays` but their focus cursors and transitions are
`hq.gd`'s. The LIFT branch was `hq.gd::_lift_input` until the lift cut and is now
`HqTuningLift.handle_input`, reached exactly the same way — the move renamed the function, not
the routing.

The **present box** deliberately has no branch of its own. It runs INSIDE `View.CARPARK`
(`CarparkMode.PRESENT`), so its keyboard/gamepad input arrives through
`_carpark_ui.handle_input` plus `hq.gd`'s `_car_back` / `_on_start_pressed`, both of which
branch on `_present_opened`. `HqPresentReveal` owns the beat's behaviour, not its input route.

**No binding moved.** The keyboard/gamepad map is unchanged: EXTERIOR left/right/select, GARAGE
left/right/select/back, LIFT hub up/down/left/right/select/back (sub-page: back), TABLE
select/back plus `dev_complete_rally` and pointer pan, CARPARK left/right/select/back plus
up/down in the wheel view. `test_menu_nav.gd`, `test_menu_flow.gd` and `test_world_panel.gd`
guard it.

**A car that fails to spawn must never hang boot forever (regression, fixed).**
`_spawn_lineup_progressive` (`hq_carpark.gd`) loops `_obtain_parked_car` → `_spawn_parked_car`
→ `CarProp.spawn` (`car_prop.gd`) for each car on the page; if the underlying model
scene fails to instantiate (e.g. a texture dependency the export stripped — see the
`export_presets.cfg` note below), `CarProp.spawn`'s `scene.instantiate()` itself
returns null, and that null propagates all the way up. Each GDScript runtime error
along the way (`use_isolated_config` on null, `set_meta` on null) aborts only the
**current function's** execution and returns to its caller — so the null bubbles up
one frame at a time until it reaches `_spawn_lineup_progressive`'s own
`car.get_meta("lineup_fresh", false)` check. Erroring there aborted
`_spawn_lineup_progressive` itself **permanently**, before the `for` loop could reach
its later cars or the trailing `emit_signal("lineup_built")` — so `_ready`'s
`await lineup_built` (above) never resolved and the `LoadingScreen` cover stayed up
forever, even though the scene underneath had already finished building and was
rendering at a steady frame rate (confirmed via `adb logcat` on a real device: the
`[perf]` counter kept ticking at 60fps behind the stuck "Preparing the garage…" cover).
The fix is a plain `if car == null: push_warning(...); continue` right before that
`get_meta` call — a single bad car is now skipped and logged, and the rest of the page
(and `lineup_built`) still complete normally. See
`tests/headless/test_lineup_cache.gd::test_a_car_that_fails_to_spawn_is_skipped_not_hung`
and the test double `tests/headless/carpark_null_spawn_double.gd`, which subclasses
`HqCarpark` and is installed over `hq._carpark_ui`.

The title camera is a **low, near-ground front-3/4 hero shot** posed ~45° off
the front of the **first (leftmost) parked car**, looking diagonally down the line
to reveal the rest of the lineup. Its `hq_exterior_cam_eye`/`_look` (GameConfig) are
**offsets from that lead car** (`_station_xform` → `_first_car_anchor`), so the framing
**tracks the first car** as the centred lineup grows and its leftmost car slides toward
−X with more cars owned — it's not a fixed world pose. The **build version** (`v0.<n> (<sha>)`) is shown in the bottom-right corner
here only — not on the in-run HUD (see [hud.md](hud.md) → Build version). The title row
is **no longer a native-focus list** — it's the same diegetic **`ButtonCursor`** idiom
the garage row and lift hub use: `FOCUS_NONE` buttons (`_station_button`) over a single
left/right cursor (`_title_cursor`/`_title_focus`), painted by `UITheme.mark_focused`
and driven by `menu_left`/`menu_right`/`menu_select` in the EXTERIOR branch of
`_unhandled_input` (mirroring the GARAGE branch exactly). The cursor re-seats on **Start**
(index 0) every time `go_to(View.EXTERIOR)` runs. Start (`_on_exterior_start`) flies the
camera into the garage; **Free Roam** (`_enter_free_roam`, `CarparkMode.FREEROAM`) opens
the whole-catalogue car park for a session-less drive — it lives here rather than in the
garage because it needs no owned car, no session and no lift, so reaching it through the
garage was a detour through state it doesn't use, and backing out of its picker returns
to this screen (`CarparkMode.FREEROAM` in `_carpark_back`);
**Settings** (`_open_settings(false)`) opens the shared camera/controls page — it moved
here from the garage action row (see the GARAGE section above), and because it now only
ever opens from the title, backing out of it (`_on_settings_action`) always returns to
EXTERIOR, never the garage; **Exit Game** (`_on_exterior_exit` → `get_tree().quit()`)
quits the app — it's built only on non-web builds, since a browser tab owns its own
lifecycle.

**Account is deliberately NOT on this row.** It used to sit next to Start, but it is
also a **Settings page** (`settings_menu.gd::show_account`), and two routes to one
optional-cloud-save form is one more than the screen needs — Free Roam took the slot.
The reinstall/new-device case it existed for is still served: Settings is right there on
the same row, before any career is started.

**SETTINGS.** A flat overlay over the exterior shot (no dedicated camera pose)
hosting the **shared `SettingsMenu`** (`scripts/settings_menu.gd`, `class_name
SettingsMenu`) — the SAME component the in-run pause menu uses, so the two pages
match. It opens on a **category list** — one button per area, laid out in a
**2-column grid** so the list stays short instead of overflowing into a scroll —
and each button drills into **its own sub-page**:

- **Display** — pick the **frame-rate cap**: **30 / 60 / uncapped**
  (`FpsSetting.OPTIONS`, `scripts/fps_setting.gd`). The choice persists under
  `FpsSetting.SETTING_KEY` (`"fps_cap"`) and applies **live** — `select_fps` writes
  `Engine.max_fps` directly (the frame cap is a global engine property, so no
  live-scene signal is needed; both hosts take effect immediately), and
  `world._ready()` re-derives it next run. Defaults to the platform's natural cap when
  unset (web-touch 30, else 60, via `FpsSetting.default_cap()`); the default option
  reads as selected. See [rendering.md](rendering.md) → frame cap.
- **Camera** — pick the **camera angle** (chase / bonnet, from `CameraManager.MODES`);
  the choice persists under `CameraManager.SETTING_KEY` and is applied on the next run
  (or live, in the pause menu, via the `camera_changed` signal). See
  [camera.md](camera.md).
- **Key bindings** — **rebind** the keyboard and controller controls. One row per
  driving action (`InputRemap.ACTIONS`) with a keyboard button and a controller
  button showing the current binding; tap one and press the new key / gamepad input
  to reassign it (Esc cancels), plus a **Reset to defaults** row. The model is the
  `InputRemap` autoload (`scripts/input_remap.gd`), which patches the global InputMap
  from overrides saved under `InputRemap.SETTING_KEY`. See [controls.md](controls.md).
- **Mobile controls** — pick the **touch control scheme**. Each of the six schemes
  ([mobile-controls.md](mobile-controls.md)) is a tappable row with a vector
  **diagram** of its layout (`ControlSchemeDiagram`, `scripts/control_scheme_diagram.gd`),
  its name and how-to. The choice persists under `MobileControls.SETTING_KEY` and is
  applied on the next run (or **live**, in the pause menu, via the `scheme_changed`
  signal — the on-screen controls rebuild the instant you pick a scheme).
- **Benchmark** — configure and launch the **in-game performance benchmark**
  ([benchmark.md](benchmark.md)): one ON/OFF row per `Benchmark.TOGGLES` entry
  (vegetation, spectators, render distance, uncap FPS, …) and a **Start benchmark**
  row that hands off to the `Benchmark` autoload (config overrides + run-scene
  load). Toggle states are session-scoped, not saved.
- **Reset progress** — the player-facing **start over**, shown to EVERYONE (it is
  deliberately not gated on `dev_tools_enabled()` — wiping your own save is
  something any player is allowed to do, and hiding it would leave no way to do
  it). One **Wipe all progress** button, a standing warning line above it, and a
  `ConfirmPopup` in between: `_prompt_wipe_progress` raises the modal (Cancel
  leftmost = default focus AND the Back target, "Wipe everything" right, per
  "Button order" below) and only its confirming action calls `_wipe_progress`,
  which runs `Save.reset_new_game()` (back to a fresh new game) and, when signed
  in, `Cloud.publish_local_wipe()` so the cloud copy is cleared too — otherwise
  the next pull restores everything and the wipe undoes itself; see
  [cloud-save.md](cloud-save.md). The status line reports the outcome, including a
  failed cloud clear ("it may come back"). `_wipe_progress` stays the plain "do it"
  entry point (what the tests drive); asking is the prompt's job.
- **Dev** — a debug page: **3-star all rallies** (`Save.dev_three_star_all_rallies`, unlocks
  every region), **Add 1 star** (`Save.award_stars(1)` — the same entry point the Rally
  Challenge banks through, rather than poking `stars_earned` directly, so the shortcut can
  never drift from how stars are really credited; the status line quotes the new spendable
  balance). One star at a time is deliberate: it lets you sit exactly on a price boundary and
  check the present box's affordable / unaffordable / free states — see
  `features/star-economy.md`. Plus one button per car (`Save.grant_car`, from
  `CarLibrary.CARS`) and per upgrade (from `UpgradeLibrary.UPGRADES`) to unlock anything in
  the game.
  **Complete rally (win now)** appears ONLY while a rally is active (i.e. from the
  in-run pause menu, gated on `RallySession.is_active()`): it unfreezes the tree and
  calls `RallySession.dev_complete_rally`, which credits every event a perfect 0 ms
  time, resolves to a P1 (top-3) finish, and routes straight to the podium — so the
  player banks the stars (and sees the stars beat) without driving the stages. Note it no
  longer yields a CAR: no rally pays one, and cars are bought at the present box.
  Upgrades are car-bound, so a slottable part **fits straight onto the selected car**
  (`Save.install_upgrade` — no-op with a "own a car first" note when nothing's owned);
  a consumable would instead go to the inventory (`Save.add_item`) — a path that still
  works but has no occupants, since `UpgradeLibrary` ships no consumable entries today.
  A status line reports the last action.

### Adding a setting

**Moved to [settings.md](settings.md).** Adding or changing a persisted setting (the
`*_setting.gd` apply-owner pattern, the settings menu's categories, and the developer-only
pages) is its own area doc — it was never really an HQ concern, and burying it under this
heading is what made it hard to find.

### Upgrades / Tune panel width

**The panel takes its width from its widest ROW, not from a configured fraction.** The lift
sub-pages are built as a `MenuPage` with no `set_body_width` call
(`hq_overlays.gd` → `build_lift_overlay`), so the body box hugs its contents; the only bound
is the page margin, plus the box's `clip_contents` as a last resort. There is no
width-fraction knob any more — a `hq_lift_menu_centered_width_frac` config field drove this
before the `MenuPage` migration and has been removed.

What still matters is **what the rows are measured against**, because it is the thing everyone
gets wrong: the space available is the **logical UI canvas**, which `scripts/display_stretch.gd`
lays out at `DisplayStretch.DESIGN_HEIGHT * window_aspect / Config.data.horizontal_stretch`
(a real per-instance `content_scale_size`, not the raw window). `horizontal_stretch`
(authored ~1.2) is a purely visual anamorphic widening applied via the stretch system, and it
SHRINKS the canvas UI actually lays out against — any measurement that skips the
`/ horizontal_stretch` step overstates available space by that same factor.

At the narrowest supported aspect (4:3, `project.godot`'s
`window_width_override`/`window_height_override` = 1280×960) that canvas is tight, which is
part of why the upgrades page is a **3-column grid of tiles** rather than a row of options
per slot: a tile's width is set by the layout, not by how many parts a slot happens to hold,
so the widest row on the page is a known quantity instead of a function of the catalogue.
The option labels that used to have to fit side by side now each get a full-width row inside
`UpgradeSlotPopup`, which is sized and centred independently of the page behind it. Hugging
the content does not make an over-wide row fit — it just pushes the box out to the margin
(and then clips) — so keeping the page's widest element bounded by construction is the
actual fix.

When re-measuring this by hand, always go through `DisplayStretch.logical_size()` (or an
equivalent `/ horizontal_stretch` step) and replicate the actual worst-case
selected/bracketed option — a measurement that skips either one will look fine in a
throwaway test and still clip in the real game.

- **Tune** (`LiftPage.TUNE`) — a slider per handling tuning axis (grip / brake-bias /
  aero; aero is greyed with a "needs Aero Kit" note until the kit is fitted — grip and
  brake bias are always tunable). **Reset to neutral** and **Wheels** sit in the page's
  bottom action row, not in the body; Reset clears only the handling axes and
  **preserves** engine detune. Each change saves via
  `Save.set_tuning`. The engine-detune slider is NOT here — it lives on the **Upgrades**
  page's `tune` tile (detune is a power / power-to-weight knob, not a handling axis).
  The slider holding the cursor lights up (its row wraps in a panel painted by
  `UITheme.mark_panel_focused` on `focus_entered`/`focus_exited`) so it's obvious which
  is selected, and left/right nudges it in place (see the `MenuNav` slider note above).
  No page title/subtitle — the sliders take the full height.
- **Upgrades** (`LiftPage.UPGRADES`) — the reusable **`UpgradesGrid`** component
  (`scripts/upgrades_grid.gd`). It is **one view, not a pair of pages**: a heading row, a
  performance line, and a grid of slot tiles, each of which opens a popup listing that
  slot's options. See "The upgrades page: a grid of slots" just below for the shape and the
  reasoning; this entry covers what the page contains.

  **The heading row** (`UpgradesGrid.build_title_row("Upgrades")`) carries the page title
  and the player's **star balance** — the digits of `Save.stars_available()` beside a drawn
  `StarRow` star. The balance rides on the component rather than on any one host's page
  chrome, because the option popups quote **prices**: all four hosts show it, and every
  `rebuild()` (which a purchase triggers) re-reads it.

  **A single `PERFORMANCE <n>` line** sits under the heading — the whole build's
  `CarPerformance.rating` (`current_rating()`), with the ceiling beside it (`512 / 480`, red
  when over) when a host sets one. It is a plain `Label`, so it adds nothing to
  keyboard/gamepad nav, and it is the page's only aggregate number: everything else on the
  page is a part and its current setting.

  **The grid** is a `GridContainer` of **3 columns and 9 tiles** — the seven
  `UpgradeLibrary.SLOTS` (turbo, gearbox, aero, tires, weight, drivetrain, nitrous) plus two
  **pseudo-slots**, `engine` (engine swap) and `tune` (engine detune). Swap and detune being
  tiles rather than bespoke rows is the point of the layout: every way of changing this car
  is one of nine equally-weighted squares, so "where do I change X?" is answered by looking
  rather than by scrolling to the end of a list. Tile order and membership come from
  `UpgradeOptions.grid_slots()`, not from the widget code.

  **Each tile is a focusable `Button`** wrapping a full-rect `VBoxContainer`
  (`MOUSE_FILTER_IGNORE`, so the whole tile stays one press target) holding an **SVG icon**
  above a `Label` reading `"<slot>: <value>"` — `turbo: Small`, `tune: 80%`, `engine: V12`.
  The value comes from `UpgradeOptions.current_label`, so a tile always states what is
  fitted right now and the grid reads as a summary of the car before the player presses
  anything.

  **The label is ONE line — it neither wraps nor clips.** Wrapping makes a tile taller and
  a grid of uneven rows stops reading as a grid; clipping truncates silently, which is worse
  than overflowing because the player cannot tell it happened. Fitting is handled by keeping
  the TEXT short rather than by growing the tile, in two places:

  - `UpgradeOptions.tile_slot_name` abbreviates the long slot NAMES for the tile only —
    `drivetrain` → `drive`, `gearbox` → `gears`, `nitrous` → `nos`.
  - An option's optional `tile_label` abbreviates the VALUE, and the popup ignores it: the
    engine shows its layout shorthand (`V12`) rather than its marketing name
    (`27L Merlin V12`), and drivetrain drops the `(Stock)` qualifier that earns its place in
    the list but not on a square that has to fit three across a phone.

  With both, every stock caption fits inside `TILE_MIN_W` with room to spare (widest is
  `WEIGHT: STOCK`). Tiles also `EXPAND_FILL`, so on any page wider than the phone floor
  there is more room again — the floor is what the longest fitted part names lean on. Icons load
  through `UpgradeIcons.texture(slot)` (`scripts/upgrade_icons.gd`) from
  `textures/icons/<slot>.svg` into a `TextureRect`, tinted via `modulate` — an SVG rather
  than a glyph for the same reason as the price star below: Syne Mono has no icon glyphs and
  the web export has no system font to borrow one from, so a character would be a tofu box
  on mobile web.

  **A tile GREYS OUT when the slot offers no choice** (`UpgradeOptions.has_choice`, which
  asks whether any option is selectable AND not already current — testing "is it current"
  rather than "is it Stock", because drivetrain's options are drive MODES with no empty-id
  Stock entry and the car's own layout is always selectable). If every part in a slot is
  still locked, the only thing the popup could offer is the state the car is already in — a press, a read of greyed lines and a back-out that teach
  nothing. The tile still shows what is fitted, dims, and drops out of the focus order, so
  the grid says up front where there is a decision to make. It comes back the moment the
  gating rally is won.

  **The `engine` tile is an ACTION, not a list.** A swap TRADES this car's engine with
  another car the player owns, so the choice being made is *which car* —
  and the host owns that screen (`hq.gd::_enter_engine_swap` puts the car park into SWAP
  mode). Pressing the tile calls the host's `on_swap`; it never opens the engine catalogue,
  which would imply you can simply fit any engine. Only the HQ lift supplies that action, so
  on the other three hosts the tile is informational and greyed. The only other thing that
  greys it is the capability still being locked — `UpgradeOptions.engine_swap_blocked_reason`
  returns just `"Locked"` or `""`, and the reason goes in the tooltip. Winning the
  unlock rally is the WHOLE gate: after that, swapping is **free and unlimited**, so the
  tile is permanently live and never has to report a spent resource.

  **The `tune` popup carries a Done button**, and it is the only variant that does. The
  option list closes itself the moment a row is picked, so its exit is the gesture the
  player already wanted; a slider has no equivalent, and Esc / gamepad-B are undiscoverable
  and absent entirely for a pointer or touchscreen. The detune writes through live on every
  drag, so Done confirms nothing — it just leaves.

  **Pressing a tile opens `UpgradeSlotPopup`** (`scripts/upgrade_slot_popup.gd`) — see "The
  slot popup" below. Applying an option closes the popup and rebuilds the page; **focus
  survives the rebuild** via an `upgrade_focus_key` meta on each tile plus a deferred
  `_restore_focus`, so pressing a tile and coming back lands the cursor on that same tile
  rather than at the top of the grid.

  What the individual slots hold is [upgrade-catalogue.md](upgrade-catalogue.md)'s subject,
  but three are worth knowing here because their options do not read like "a part or not":
  the **drivetrain** tile is an FWD/RWD/AWD picker (a `drive_mode` override, gated as a
  whole on the swap kit); the **weight** tile is the one slot whose rows are NOT part names
  — `UpgradeOptions._option_label` labels each weight option with a bare signed mass delta
  (`+200`, `-200`, with `Stock` still reading `Stock`), because "Heavy Ballast" is three
  words for a slot that is really one number and what the player is picking is how much
  mass to add or shed. The kilos are derived from the part's mass MULTIPLIER against the
  car with the slot empty, then rounded to the nearest 100 (floored at 100, so a real part
  never reads `+0`) — a multiplier lands on figures like 243, which is precision the player
  cannot act on where a round number reads as a decision. The tile caption — which is just
  `UpgradeOptions.current_label` — reads `weight: +200`, and the two ballast options are
  free while the lightweight kit is earned; and the **tune** tile is the one
  slider in the grid (below). The `nitrous` tile is an ordinary slot tile — see
  [nitrous.md](nitrous.md) for why the part installs pre-enabled.

  Prices in the popup are quoted as `Name N★` where **the star is DRAWN**
  (`StarRow.price_icon()` on the row's `icon`, `icon_alignment` RIGHT), never the `★`
  CHARACTER: Syne Mono has no `★` glyph, so a `★` in a label only rendered at all because
  the OS supplied a fallback font, and the **web export has no system fonts** — every price
  read as a tofu box on mobile web. The heading's balance does it the other way round (a
  sibling `StarRow` beside digit-only text, since a Label carries no icon), as does the
  hub's **Repair N★**; see [star-economy.md](star-economy.md) → "Where the player sees it"
  for both shapes. Guarded by
  `test_menu_flow.gd::test_hq_lift_text_only_uses_characters_the_bundled_font_can_draw`,
  which sweeps the whole lift station for any character the bundled font cannot draw.

  **`UpgradesGrid.setup(owned, on_change, on_swap, rating_limit)`** takes an optional
  `rating_limit` (a `CarPerformance` rating ceiling, `NO_LIMIT` = `-1` for none); when set
  ≥ 0, the overlay's **close button is gated** (`bind_close_button` + `request_close` /
  `can_close` / `over_rating_limit`): it reads **Done**, turns red with **"Over limit —
  reduce to N performance"** and blocks closing (button + Esc / back) while the live build
  exceeds the ceiling — over it the car is ineligible, so closing would only defer the
  refusal to the start line. Used by the start-line upgrades overlay, the reward reveal and
  the HQ car-park Change-Upgrades modal, all of which source it from `DrivingContext`; only
  a Rally Challenge actually has one, and the HQ garage lift omits it entirely.
  (There is no Repair anywhere — see [damage.md](damage.md).)

  The **`engine` tile** is the engine swap (`UpgradeOptions.SLOT_ENGINE`): it reads the
  car's current engine, and its options are the swap targets, gated **only** on the
  capability having been won (not on HP, and not on any consumable — swaps are free and
  repeatable once unlocked). The lineup is **every other owned
  car regardless of health**. It is effectively **lift-only** — the HQ lift is the one host
  that passes `on_swap`, since pressing through opens the car park in **swap mode**
  (`_enter_engine_swap` / `_carpark_swap_mode`), where the normal car-park cycle / confirm /
  back flow exchanges the two cars' engines (`Save.swap_engines`, which consumes nothing)
  and returns here; the
  other hosts leave `on_swap` unset, because that flow would tear down the screen they are
  running on. See [engine-swap.md](engine-swap.md).

  **The upgrades page: a grid of slots.** All four hosts — the HQ lift (`hq_overlays.gd`),
  the HQ car-park Change-Upgrades popup (`hq_carpark.gd`), the start-line upgrades overlay
  (`start_line.gd`) and the reward reveal (`upgrade_reveal.gd`) — instantiate the same
  **`UpgradesGrid`**, and the host-facing contract (`setup` / `rebuild` / `first_control` /
  `bind_close_button` / `request_close` / `can_close` / `over_rating_limit` /
  `current_rating`) is what they all speak, so the gated-close machinery is written once
  rather than four times.

  **Why a grid and not a list of rows.** A slot's options are a *choice among a few*, and a
  row that lays every option out horizontally has to fit an unknown number of buttons into a
  fixed width — which is what drove the old page's squeezing, wrapping and hidden-option
  rules. Pushing the options into a popup makes the page itself a fixed 3×3 shape that never
  reflows, gives each option a full-width row it can caption freely ("Needs Big", "3
  stars"), and turns the top level into something the player can read at a glance: nine
  tiles, each stating what is currently fitted. It is also **one page deep and no more**:
  the whole car is on screen at once, so nothing needs a second page, a stat-to-category
  index or a filter to reach it — the tile IS the index.

  **The slot popup** (`UpgradeSlotPopup`, `scripts/upgrade_slot_popup.gd`) is a
  `CanvasLayer` modal joining **`ConfirmPopup.MODAL_GROUP`** — so one modal at a time (see
  "One modal at a time"), and `MenuNav.input_blocked` deafens the grid behind it rather than
  the two competing for arrow keys. It draws a dim backdrop and a centred `UITheme.panel`
  and then, deliberately, **no title and no Cancel/OK row**. The tile the player just
  pressed is the title, and a button row would only add a second way to do what pressing an
  option or backing out already does.
  - **One explainer line at the top**, from `UpgradeOptions.slot_description(slot)`, saying
    what the slot *does* in plain language ("which wheels get the power"). Not a title —
    a heading repeating "TURBO" over a list of turbos says nothing, while this is the only
    thing telling a player who knows nothing about cars why the slot is worth opening. It
    is dim and word-wrapped (reference text, must not compete with the options), and being
    a `Label` it is never focusable, so the cursor still opens on the fitted option and the
    keyboard/gamepad path is unchanged. A slot with no entry draws no row at all. Both
    entry points take it — the option list and the detune slider. See
    [upgrade-catalogue.md](upgrade-catalogue.md) → `slot_description`.
  - Selectable options are `FOCUS_ALL` buttons; **locked or unaffordable ones are shown
    GREYED and `FOCUS_NONE`**, captioned with their reason ("Locked", "Needs Big",
    "3 stars"). Showing them is a deliberate reversal of the old "hide what you can't have"
    rule — a tile hides its ladder until pressed, so a popup that listed only the reachable
    rungs would leave the player unable to learn the slot has more in it (see
    [upgrade-catalogue.md](upgrade-catalogue.md) → "Locked options are LISTED, GREYED").
    `FOCUS_NONE` is what keeps that from costing anything at the keyboard: nav **skips** the
    dead rows, so the cursor only ever stops on something that does something.
  - The current option is marked with `UITheme.mark_selected` and **the cursor opens on
    it**, so the popup starts by answering "what is fitted now" without the player moving.
  - Purchase options carry the drawn star price. The digits and the star sit **together at
    the right edge**, as a full-rect `HBoxContainer` overlay aligned to the end
    (`_add_price_tag`) — not as `b.text + b.icon`, which is what this was. A `Button` draws
    all its text as one left-aligned run and its icon at the far right, so a price appended
    to the text hugged the option's NAME with the whole row's slack between it and the star
    it belonged to, reading as part of the label rather than as its price. The overlay
    ignores the mouse so the row still presses as one button, and sets `MENU_ROW_H` by hand
    because having a child makes it skip `UITheme.enforce`'s single-line-button branch.
  - **Every row quotes the performance rating that option would give the car** —
    `UpgradeSlotPopup._row_label` renders it as `Small (412)`, and both the pickable-button
    and the greyed locked-row paths go through it, so a rung the player cannot take yet
    still says what it would be worth. The figure is **parenthesised** precisely so it
    cannot be misread as the star price, which is drawn after it with its own icon. There
    is deliberately **no per-row "before → after" progression**: `Stock` is always the first
    row and always rates the car as it stands, so the before-figure is stated once at the
    top of the list instead of being repeated on every line.
    The numbers come from `UpgradeOptions.rating_with` (via `UpgradeOptions.build_with`, a
    pure hypothetical build — nothing is written to the save), stamped onto the rows by
    `UpgradesGrid._rated_options` on the way into the popup rather than inside
    `options_for`, because a rating is a simulated benchmark lap and `options_for` runs for
    every tile on every grid rebuild — see
    [upgrade-catalogue.md](upgrade-catalogue.md) → "The option model is pure data".
  - **Clicking a row applies and closes**; back closes without applying. One press per
    decision — the option list IS the confirmation step, since the player chose the slot,
    then chose the option. Applying a PURCHASE now also **switches the part on**
    (`UpgradesGrid._apply_option` calls `Save.set_upgrade_enabled` after a successful
    `Save.buy_part`): a granted part arrives parked precisely so
    an unasked-for gift never changes how the car drives, but here the player opened the
    slot, picked the rung and spent the stars — leaving it parked meant the menu took the
    payment and visibly did nothing.

  **The `tune` tile is the one exception: a SLIDER popup**
  (`UpgradeSlotPopup.open_slider`) — a single `SliderRow`, 0–100 step 5, with a live label,
  writing through `Save.set_engine_detune` on change. Detune is a continuous power /
  power-to-weight knob (it lives here rather than on the Tune page for that reason, see
  below), and chopping it into list rows would throw away the fine control the player
  reaches for it for. It is the same widget the tuning sliders use, so left/right nudges the
  value in place.

  **Navigation.** The grid is navigable on **both axes** — up / down / left / right, keyboard
  AND gamepad — via `MenuNav` over the `GridContainer`'s geometry; because the tiles are
  equal-sized cells in a real grid, Godot's geometric neighbour search is reliable here in a
  way it was not for the old page's mix of full-width rows and right-pinned buttons, so
  nothing needs hand-wiring. The popup list is navigable vertically, its unselectable rows
  skipped, and back closes it. Both halves are covered by nav tests — a menu reachable only
  by pointer is not shippable (see "Menu navigation" above).

  The page's **`< Back`** button (`_lift_back_button`, returns to the hub) sits in the page
  `root` **below** the scroll container — a different node level from the tune/upgrades
  body — but it's `FOCUS_ALL`, so `menu_down` off the bottom row of tiles reaches it by
  geometry (the box `MenuNav`s move focus across container boundaries). It's also the focus
  fallback (`_grab_lift_page_focus`) when a page body has no focusable control at all, so
  the page is never dead to keyboard/gamepad.

`_refresh_lift_ui` toggles which face (hub vs. a menu page) is shown from `_lift_page`.
See [tuning.md](tuning.md) for the underlying config pipeline.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane — a **square** table top (`hq_table_size`/`hq_map_plane_size` are equal in
X/Z) surfaced with a **satellite map photo** (`RegionLibrary.DEFAULT_MAP_IMAGE` —
`textures/map_world.jpg`, an unshaded albedo texture so the aerial colours read true
under the garage lighting). There is **ONE world map**: no swap arrows, no viewed
region, no way to change maps. `_refresh_map_pins` loads that one texture and pins
**every** rally in `RallyLibrary.all()` at once, so a corner the player hasn't earned
is visible from the first minute — its rallies simply render locked. Under the pins it
also draws the **reveal graph** — faint dotted lines joining rallies whose circles reach
each other, but **only where both ends are already revealed**, so the lines chart the route
the player has lit rather than spoiling the dark (`hq_map_table._build_reveal_links` /
`RallyLibrary.reveal_link_pairs`, see
[map-exploration.md](map-exploration.md) → "The graph on the table").
See [regions.md](regions.md) for the region look (it no longer gates anything —
regions are look + waterline only; the completion-gated specials are
[rally-roster.md](rally-roster.md)'s territory). Every
rally in the roster is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
**state-driven marker** — an ordinary rally gets a **flag** (`RallyFlag` — a small
**base disk** the pin stands on + a pole + waving pennant + finial bead), a
**SPECIAL** gets a **trophy** (`RallyTrophy`, see below) — topped by a **billboarded design-system box** (`_build_pin_label`) that
holds the rally name and a row of proper **five-pointed stars** — 1st-place best = 3
gold, 2nd = 2, 3rd = 1, else dim (`_stars_for`). The box is a real `UITheme` panel
(Syne Mono, uppercase) composited in an off-screen `SubViewport` and shown
on a `Sprite3D`, so text and stars live in **one box** that always faces the camera;

**EVERY readout wears the same pure-black panel** — house rule 4 with no exception. A
special event's box used to be INVERTED (a light-brown face via the retired
`ACCENT_READOUT_BG` / `ACCENT_READOUT_INK` and `_build_readout_sprite`'s `accent` flag);
that is gone, because the 3D markers now carry the "this one is different" job (a car
model, a trophy, or a flag) and a panel colour saying it on top of a marker that already
says so was the same emphasis twice.

**No drop shadow on a floating readout.** The global theme gives every `Label` a hard black
shadow (`tools/build_ui_theme.gd` → `font_shadow_color` + `shadow_offset_*`), which is the
terminal look on a flat menu — but on a black readout it is invisible. `_build_readout_sprite`
clears it per-label rather than changing the theme, so the rest of the UI keeps the house look.

the stars are drawn by **`StarRow`** (`scripts/star_row.gd`) as polygons, sidestepping
the font's missing ★/☆ glyphs (same reason the UI uses ASCII `<`/`>` for nav) — a rule that
holds for **every** star in the game, including the star PRICES on buttons, which take
`StarRow.price_icon()` as their `icon` because a Button lays out no children. **The
rasteriser itself now lives in `PolygonIcon`** (`scripts/polygon_icon.gd`): its
`texture(key, points, color)` supersamples a flat polygon (`PolygonIcon.SUPERSAMPLES`) into
a cached, centred `ImageTexture`, and `StarRow.texture` is a thin delegate onto it. It was
extracted from `StarRow` — which had the only copy — when a second drawn icon needed the
same rasteriser; two hand-rolled supersamplers would drift, and the
tofu-box rationale above is identical for every drawn icon, not just stars.
(`StarRow.TEXTURE_SS` and its private texture cache are gone with the move.) The
flag encodes the rally's state on **two axes** (`RallyFlag.pennant_kind` /
`RallyFlag.accent_color`). **Pennant:** placed 3rd or better → a **black-and-grey
checkered** racing flag; else **bright green** when the player owns a car eligible to
enter (`_has_eligible_car`); else **dark grey** (no qualifying car — also a locked
special). **Tip + base** (the finial bead and base disk, always one colour): **warm
gold** once the rally is **won** (1st place, 3 stars), **metal grey** otherwise. The
stars in the box remain the exact readout.

**A special event stands a TROPHY instead of a flag** (`RallyTrophy`, procedural like
the flag — base coin, square plinth, stem, tapered bowl with two ring handles, finial
bead). Two reasons it isn't just a differently-coloured flag: a special is the
**prestige event** on its corner and shouldn't read as one more pennant, and a cup can
show **which** medal you took where a pennant only says "podiumed". It keeps the flag's
two axes so the map speaks one language: **cup + finial** = best result — **gold** (1st)
/ **silver** (2nd) / **bronze** (3rd) / **plain metal** (never podiumed, including
locked); **plinth + coin** = raceability — a deep **racing green** when an eligible car
is owned, else **grey** (the green is *darkened* from the flag's pennant green, which
covers far less area and would overpower the cup at plinth size). It shares the flag's
base radius/thickness so pin spacing and hit spheres need no special case, and stands
the same height as a flag pole (`RallyTrophy.HEIGHT` ≈ `RallyFlag.POLE_HEIGHT`) so
`_make_pin` hangs the readout box off whichever marker it built and specials never look
diminished beside ordinary rallies.

**The readout box is HOVER-ONLY, on every pin.** One rule for all of them, whatever they
stand and whatever state they are in: `_make_pin` always builds the box, always starts it
`visible = false`, and the focus pass shows it only while the cursor is on that pin — which
is what keeps the table a map rather than a noticeboard (a dozen open boxes at once read as
a wall of menus). A rally that isn't enterable — out in the fog, or reachable with nothing
in the garage that fits — keeps its box but renders it faded (`FOGGED_PIN_DIM_ALPHA`), so a
pin the player can't enter yet still *answers* when they point at it. The **3D marker stands
at every pin** regardless, so the map always marks where the unavailable rallies are.
An available pin carries **two** pickable `Area3D` hit spheres bound to the same handler
(`_add_pick_sphere`, rally id bound) — one over the flag/pole and one over the
floating **readout box itself**, so a click on the menu enters the rally just like a
click on the flag — while an unlocked-but-ineligible pin has only the flag sphere (no
live box to click). Each pin also
carries its `rally_id`/`locked` in metadata; a pin is grey + **non-pickable**
whenever it isn't **revealed** yet (`RallyLibrary.rally_revealed`). Reveal is
**purely geometric** now — `rally_revealed` → `position_revealed` asks whether the
rally's `map_pos` falls inside any of `RallyLibrary.lit_sources`, the circles grown
around what the player has already completed. There is **no star gate and no
`reveal_after`/`requires_completions` count** any more (the old wave counters, and
before them the roster-wide STAR TOTAL, are both gone — stars became a spendable
balance, see [star-economy.md](star-economy.md)). The fog mask on the map plane
shades with the SAME predicate, so what looks lit and what can be entered cannot
drift — see [map-exploration.md](map-exploration.md).
**The next locked special still gets a teaser box:** it renders a **full-opacity,
non-pickable** teaser (`hq_map_table._build_special_teaser_label`, via `hq_map_table._make_pin`) naming the
event over an unlock line (`hq_map_table._special_unlock_line` — "unlocks engine swaps" for
`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`, and **empty** where the rally's own name already
carries its reward, i.e. anything in `UpgradeLibrary.unlocked_by`). No count is quoted:
with reveal geometric there is no counter to quote, so the line names a *destination*
rather than a requirement. The grey trophy below already carries the "not yet" signal, so
the teaser doesn't need dimming to read as locked.
**ONLY the nearest one is teased** — `RallyLibrary.nearest_locked_special_id` (which
replaced `next_locked_special_id`) picks the locked special with the smallest
`distance_beyond_frontier`, and every other locked special hangs **no box at all**, just
its trophy: a special further out isn't something the player can work on yet, and eight
teasers at once buried the map under unreachable menus. It is **hoisted out of the pin
loop** in `_refresh_map_pins` and passed in per pin — the answer is the same for every pin
and the query walks every special through `distance_beyond_frontier` (which rebuilds
`lit_sources`), so asking it per pin was ~32× the work for one answer.
**This is the ONLY place that event is named.** The garage used to carry it too, as a
permanent next-carrot line; that line is gone (see the GARAGE section above) — off the map
the name has no context to stand in, while here it is placed on the world.
An unlocked special's pin names its unlock too. A meter sits at the **bottom centre** of
the HUD (`build_table_overlay`) — a drawn gold star (a one-star `StarRow`, since Syne Mono
has no ★) beside the **digits alone**: `hq._refresh_meter` writes `"%d"` and the glyph
replaces the word. Centre-bottom rather than the top-left corner it started in: it is the
map's one number and the currency the special pins are gated on, so it sits on the centre
line the eye already travels instead of over the pins. One star and a count, deliberately
NOT a `StarRow` of N-lit-of-M — that shape is the rally MEDAL readout and would imply a
maximum. It shows the **spendable balance**
(`Save.stars_available`) with **no denominator**: stars are currency now, so what
matters is what the player can take to the present box, and there is no meaningful
maximum to divide by (the balance falls on a purchase and the Rally Challenge tops it
up without bound).
### What a map-table entry actually costs

Where the hitch on "tap the table" came from, and what a rebuild still costs when one is
genuinely needed. Measured headless (32-rally roster, fast x86, **no GPU work included** —
treat these as a CPU floor, not the device cost):

| step | cost | notes |
|---|---|---|
| `_refresh_map_pins()` — real rebuild | **~20 ms** | frees all 32 pins and rebuilds them |
| ↳ 32 × `_make_pin` | ~8.4 ms | flag/trophy meshes + one readout `SubViewport` each |
| ↳ `_apply_map_fog` / `build_fog_mask` | ~0.8 ms | 64² `Image` loop — cheap, not the problem |
| ↳ `_build_reveal_links` | ~0.9 ms | |
| ↳ 32 × `_has_eligible_car` | ~0.0 ms | |
| ↳ `nearest_locked_special_id` | ~0.2 ms | hoisted out of the pin loop |
| `_enter_table()` — before the skip | **~42 ms** | the rebuild above, plus focus/pan setup |
| `_refresh_map_pins()` — **skipped** | **~0.04 ms** | stamp matched; the stamp itself is 0.04 ms |

**"Warming the table" is NOT the fix, and the numbers above are why.** `_build_hq` calls
`_refresh_map_pins()` unconditionally at boot, behind the `LoadingScreen` cover, so the map
texture, the fog shader, the wood grain (`MapTable._wood_tex`, a `static var` generated once
per *process*) and the cached prize-car props (`_prize_car_props`) are all live before the
player ever sees HQ. There was no cold cache to pre-warm — the cost was work being **redone**
at the worst possible moment. Three things fixed it, and the reasons they are safe are the
part worth keeping:

1. **A table entry no longer rebuilds pins that would come out identical.**
   `_refresh_map_pins` opens by comparing `_map_pins_stamp(hold_locked)` against
   `_pins_stamp` and returning early when they match (it still re-seats selection and
   rewrites the meter, because a table entry re-centres `_table_pan` and so moves the
   cursor). The stamp is deliberately **coarse and conservative** — the whole profile hash,
   the whole of each authored table, `hold_locked`, and the map/fog Config values — because a
   missed input means a STALE MAP (a pin still grey after the rally that lights it), which is
   far worse than an occasional needless rebuild. **Add to it if you make the pins read
   something new.** Measured: **0.04 ms** on the skip path against **22 ms** for the rebuild,
   and the stamp itself is 0.04 ms, so the check pays for itself ~500×. Everything that
   should still rebuild does: the reveal parade varies `hold_locked` per step, and every
   other caller (`_on_cloud_profile_replaced`, `_enter_present_box`,
   `_dev_complete_selected_rally`, `_finish_reveals`) writes the profile first.
   Guarded by `test_menu_flow.gd::test_hq_table_entry_reuses_unchanged_pins` and
   `::test_hq_map_table_focus_highlight_survives_a_pin_rebuild` (which clears the stamp to
   force a real rebuild, since that is what it is about).
2. **Only the HOVERED readout's `SubViewport` renders.** They are built `UPDATE_DISABLED`,
   and `hq._paint_pin_readout` — now the single place a readout's visibility changes, and it
   carries the focus repaint too — arms `UPDATE_ALWAYS` on the one box that is up and
   disables it again when it closes. `UPDATE_ALWAYS` rather than a one-shot `UPDATE_ONCE`
   on purpose: it is one viewport at a time, and a single render can be taken *before* a
   `Control` finishes its deferred container sort, which would bake a blank panel and never
   correct it. Guarded by `::test_hq_only_the_hovered_pin_readout_renders`.
3. **The Free-Roam prewarm waits for stillness** (see the GARAGE section's Free Roam
   paragraph, and `hq._prewarm_should_wait`) instead of firing ~100 ms car-instantiate
   frames into whatever the player is doing.

**Podium → map table was the worst case, and #3 is the reason.** The podium's Continue boots
a FRESH HQ, and `_ready` only awaits `lineup_built` when `_view == View.EXTERIOR`. A podium
return opens on the GARAGE (or, after the opening rally, straight on the TABLE), so the cover
lifted and the deferred prewarm then instantiated one `car.tscn` **per catalogue car, one per
frame** (9 today, measured at ~3× the rest of HQ boot) *while the player was already reaching
for the table* — and the pin rebuild landed on top of those frames. Note the `return_to_map`
path also builds the pins **twice** at boot (`_build_hq`, then `_enter_table`); with the
stamp in place the second pass is a no-op rather than a second full build.

**Drag to pan** the map (mouse, or
finger via `emulate_mouse_from_touch`): `_pan_table` shifts the camera in the table
plane, clamped to the map extents. **The map tracks the pointer 1:1** — the drag delta is
measured by raycasting the pointer's before/after screen positions onto the map plane
(`_map_drag_delta` / `_map_point_at`) and moving the camera by the difference, so the map
point you grabbed stays under your finger. It used to be pixels × a fixed metres-per-pixel
constant (`hq_table_pan_speed`), which was only ever right for one camera height / FOV /
viewport height and for the shipped ones ran **~2.1× too fast across and ~1.9× down** (the
table camera is tilted, so one constant can't even be right on both axes at once): the map
raced ahead of the finger, so a pin you started a drag beside had slid well away by the
time you let go.
Projection is exact for free and survives re-posing the table camera or adding a zoom.
`hq_table_pan_gain` remains as a multiplier on top, and 1.0 (exact tracking) is the only
value that doesn't reintroduce the old feel. Guarded by
`test_hq_dragging_the_map_keeps_the_grabbed_point_under_the_pointer`. Pin selection fires on
**release** and only if the press wasn't a drag (`_table_dragged`), so panning never
opens the pin under the finger. **Crucially the station overlays are made
pass-through** (`_passthrough_overlay` sets every non-button control to
`MOUSE_FILTER_IGNORE`) — otherwise the full-rect HUD container/labels/spacer (all
default `STOP`) would swallow every touch and the 3D pins would never get a pick.
**THE PRESENT BOX — the prize-car reveal, not a shop.** Cars are **not bought**: a car is
won at the rally that advertises it, and the box is how it is handed over. The prop is still
`scripts/present_box.gd` (`class_name PresentBox` — `build()` for a plain box,
`build_openable(width, depth, body_h)` for the openable reveal copy), but there is **no box
on the map any more and no price anywhere**. `RewardSystem.car_price` / `purchase_car` /
`is_stranded` and `GameConfig.star_cost_per_car` are all **deleted**; stars are spent
per-item instead — `GameConfig.star_cost_per_repair` / `star_cost_per_part` /
`star_cost_per_drive_mode`, see [star-economy.md](star-economy.md). `hq._make_present_pin`,
`hq.PRESENT_MAP_POS`, `hq._present_cost_line`, `hq._on_present_input` and
`hq_table.activate_present_box` are gone with it, and `hq_table._build_table_targets` now
returns only `{node, kind: "pin", pos}` entries — one per unlocked rally pin — so the map has
no non-rally target at all.

Instead the box is **forced on arrival at the HQ**: the finish flow sets
`RallySession.pending_car_reveal_instance_id` to a car the player has ALREADY been granted,
and `hq._build_hq` consumes that one-shot **before every other destination** (it outranks
both `return_to_map` and `return_to_garage`, because it is the payoff for the rally just
driven) and calls `hq._enter_present_box(instance_id)`. Because the car is already owned the
box is a **presentation, not a transaction** — backing out or quitting cannot cost the player
the car, and `_car_back` holds them on the screen until they open it.
- **The box screen** (`CarparkMode.PRESENT`, `hq._enter_present_box`): the car park emptied
  of cars with one oversized openable box in the middle. It
  reuses the ordinary car-park chrome rather than a modal — `_start_button` is the bottom
  button and reads **"Open it"** while the box is shut and **"Back to garage"** once it is
  open (`_refresh_present_button`), and it is **never disabled**: the player is forced
  through this beat, so a dead button here would be a dead end rather than a pause. The
  **"< Back" button is hidden until the box is open** — there is nowhere to go back TO, the
  player arrived straight from a rally they won. The prev/next
  **arrows are hidden** (`_set_carpark_arrows_visible`) because there is
  nothing to cycle — though the centre label they share a row with is where the revealed
  car's name lands. `_car_hint_label` — hidden and empty in every ordinary lineup — is
  SHOWN here, and only here, for "Open it to see what is inside": the box is the one target
  with no other affordance, whereas a lot full of cars with a ◄ / ► row needed no caption.
- **The empty lot still needs one marker — the panel is welded to it.** In world-space-menu
  mode the car-park chrome rides a `WorldPanel` anchored to `_markers[_focus]`
  (`hq.gd::_car_panel_xform`), and `_clear_lineup()` frees every marker
  (`hq_carpark.gd::_release_page_props`). With no marker the transform is `null`,
  `WorldPanel.place` early-returns, and the panel — bottom button and all — stays wherever
  it last was, i.e. nowhere the player can see it. So `_enter_present_box` calls
  `hq.gd::_add_present_marker()` immediately after clearing and seats `_focus = 0` **before**
  `update_overlays()`: one bay marker at `HQEnvironment.carpark_center()` with the same
  `rotation.y = PI` every other bay marker uses. It is kept on `_present_marker` and
  **`_open_present` reuses it** to seat the revealed car rather than making a second one —
  which is the point of the arrangement: "Open it" and the car detail that replaces it after
  the name reveal are read at exactly the same position and angle, so the panel does not jump
  when the lid comes off. See [world-panel.md](world-panel.md) → "The car-park host swap" for
  the general rule; any future car-park mode that clears the lineup loses its panel the same
  way.
- **Opening it** (`hq._open_present`, on the bottom button): makes the revealed car the
  SELECTED car (`Save.set_selected_car`, so the "Back to garage" exit lands on it), then
  **puts it in the box BEFORE a single wall moves** — the car is spawned at the box centre
  while the walls still hide it, so the reveal is the box genuinely opening *on* the car
  rather than a car fading in afterwards. It seats the
  car on the `_present_marker` created on entry (above), which already carries
  `rotation.y = PI` so the nose faces the courtyard/camera, matching every other bay marker
  (`hq_carpark._render_lineup_page`) — without that the car presents its back. Then
  `hq._refresh_map_pins()` (a new car can make previously un-enterable rallies raceable, so
  the map behind the beat is now stale), and
  the car's name goes into `_car_name_label` **under the car** — **no result card, no
  modal**. If the profile no longer holds the car at all (`Save.get_car` comes back empty),
  `_open_present` leaves for the garage rather than stranding the player in a forced screen
  with nothing in it.
- **Once open, the bottom button becomes the way OUT** — `_refresh_present_button` relabels it
  **"Back to garage"** and leaves it ENABLED (`_leave_present_to_garage`). It is never left
  disabled: a dead action row is a dead end, and the player has somewhere to go next — the
  garage, where their new car is. The **"< Back"** action goes to the garage from this screen
  too, for the same reason. That also makes a second purchase impossible without a
  `_present_opened` re-entrancy check doing the work.
- **The animation** (`hq._animate_present_open`): the **lid tweens up** out of frame while
  the **four walls fall outward**, each hinged on the axis parallel to its own base edge
  (see `PresentBox.build_openable`). The walls use **`TRANS_QUAD` + `EASE_IN` — the gravity
  curve**, so displacement goes as t²: a wall barely moves at first and then accelerates
  into the floor like a panel tipping past its balance point. Deliberately **not
  `TRANS_BACK`**, which overshoots *backwards* before travelling and made every wall visibly
  suck inward through the box before falling out. The wall fall time is a slow ~1 s — the
  panels should read as having weight. The reveal's four look/feel values are GameConfig
  fields (`hq_present_clearance_m` / `_lid_rise` / `_open_time` / `_wall_time`), with the
  `hq_present_reveal.gd` consts kept as fallback defaults only; see
  [configuration.md](configuration.md) → *HQ Present Box*.
- **Sizing is DERIVED, not tuned.** `PresentBox.build_openable(width, depth, body_h)` takes
  **metres**, and the car park sizes it from `CarLibrary.max_car_bounds()` — the per-axis
  maximum across the whole roster — plus the `hq_present_clearance_m` GameConfig field
  (fallback `HqPresentReveal.PRESENT_CLEARANCE_M`). So the box fits the widest
  and longest car by construction and keeps fitting when a bigger one is authored. A single
  scale multiplier could not express this: the roster spans **3.8 m to 5.9 m** of length
  against ~1.9 m of width, so a square box either clips the long cars or dwarfs the narrow
  ones (an earlier 24× square footprint clipped the 5.9 m car badly). `max_car_bounds` takes
  the greater of the body box and `track + wheel width` for WIDTH, because on the
  widest-tracked cars the wheels stand proud of the bodywork. Trim sizes (ribbon, bow, wall
  thickness) scale off the box's NARROW dimension so a long thin box does not get a 6 m ribbon
  on a 2 m face.
- Under `Platform.is_headless()` the whole beat **resolves immediately** — the car is parked
  and named with no tweens and no awaited timers, so tests pay no cinematic time.
  `_cleanup_present_reveal` is shared by the generic car-park Back and restores the arrows
  and hint, so backing out mid-reveal can't leave a giant box parked in the lot.

Tapping a pin opens the **rally detail** sub-panel — a **single-column card** built and
populated by `RallyDetail` (`scripts/rally_detail.gd`: `build()` / `fill()`, reached from
`hq_table.gd::_show_detail`), shared with the overworld hub. Header:
rally name **with the stage count appended** (`"Pinewood Sprint - 3 stages"`, singular
"stage" for a one-stage rally), region tag, and a gold **SPECIAL EVENT** chip
(`RallyDetail.special`, forwarded as `hq._detail_special`) on special rallies. There is deliberately **no per-stage breakdown** — the old left-hand STAGES
column (one row per event with its gravel/tarmac surface mix) was removed to free the
full panel width on small screens; the stage count on the title is the whole story.
**Body (full width):** the eligible-cars **restriction** (the
power-to-weight gate, not the hidden difficulty tier — the band is printed as a bare
`N–M hp/tonne`, the unit carries the meaning); an **eligibility read-out** —
`_eligibility_summary(rally, owned)` collects the qualifying cars and
`_qualifying_cars_text` **names them** (GREEN), up to `MAX_QUALIFY_NAMES` with a
`+N more` tail, or RED "no cars qualify" / muted "no cars owned yet" — with a GOLD
caution for how many **need a tune / swap to
fit** — and a **YOUR RECORD** line (best finish + a
`StarRow`, hidden entirely until the rally has a placement).
Everything is uppercase + one font size (`UITheme.enforce`), so
hierarchy comes from **layout, colour, and separators**, not font size. The
summary is tallied on top of `_entry_plan` so it always agrees with the map pin.
**Enter Rally** flies out to the car park, **◄ Map** dismisses the panel, and the
table Back returns to the garage. Nav stays diegetic (`menu_select` → Enter,
`menu_back` → Map; both buttons `FOCUS_NONE`).

**CARPARK (the outdoor lineup).** The owned cars **eligible for the chosen
rally** (`RallyLibrary.is_eligible`) — plus any car a **drivetrain conversion**
would qualify (below) — are parked at `GameConfig.hq_carpark_origin`,
in a **centred row ALONG X** — one car per painted bay (`menu_car_spacing` wide), with
fewer cars than bays centred within the grid — each **parked nose-out toward the
courtyard / menu camera (+Z)** so the camera frames its front with the garage behind;
each is a silenced `Car` prop (reusing `Car.apply_owned`). The exterior/title camera is
shifted by `menu_car_park_offset` (the same lot-centre offset) so it stays centred on
the row. Parking is shared with the title via `_build_lineup(cars)` — the car-select
screen and the title both pass **all owned cars** — or, for a fresh player
with an empty garage, the three starter-car previews (`_starter_previews`) so the lot
is never empty behind the title. Each `Car` prop is a full
physics scene (chassis + wheels + drivetrain + per-instance mesh duplication), so
`_build_lineup` lays out all the lot **markers up front** (cheap `Marker3D`s — the
camera framing and focus cursor key off `_markers`/`_eligible`, not the props) and then
streams the heavy car props in **one-per-frame** via `_spawn_lineup_progressive`,
rather than instantiating the whole lineup in a single frame (which hitched on every
rebuild — notably the new Change-Car lineup). A `lineup_built` signal fires once the
stream finishes. The props **drop in live**
(raised by `menu_car_drop_height` onto a collision floor under the lot) so they
**settle onto their suspension**, then `_freeze_lineup` freezes the settled pose after
`menu_car_settle_seconds` (both the per-frame stream and the freeze are guarded by the
same `hq_carpark.gd::_settle_generation` id so re-entering the lot — or backing out — abandons a
half-spawned lineup and cancels a stale freeze) — so a full car park costs nothing to
keep parked. Re-entry is also cheap: a **reuse cache** (`_car_cache`, keyed by the
owned car's `instance_id` → the built node + a deep `owned.hash()`) means
`_build_lineup` **rebuilds only the cars whose data actually changed** — an unchanged
car is shown at its new bay from the cache with no re-instance, mesh duplication, or
settle (`_obtain_parked_car`), so an unchanged re-entry parks instantly and only a
freshly-built car pays the per-frame stream + settle. `_release_page_props` **hides +
stows off-screen** the parked page's cars instead of freeing them (they stay parented to
HQ, frozen; stowed so a hidden car can't intercept a tap-to-focus ray meant for the next
page's car at the same bay); the cache is shared across every car-park lineup (car-select,
engine-swap, wheels, starter, Free Roam, title), **evicts** entries for cars no
longer offered (`_evict_unowned_cached_cars`, run each build), and is freed wholesale with the HQ node
on exit-to-race. `◄ ►` (or
`menu_left`/`menu_right`) move the focus and the camera eases to a **front 3/4 hero
shot from in front of the car** (`menu_camera_offset` is added in world space; +Z sits
the eye ahead of the nose-out car, looking back past it at the garage) over
`menu_camera_move_time`; the focused car **is** the selected car. The overlay shows
its name + stats (drive / **horsepower (HP)** / **weight (kg)** / **Health %**) via
`_car_stats_text` — the single stat-list formatter shared by the car-select and LIFT
overlays. Power-to-weight is deliberately **not** shown here; the p/w ratio
only surfaces where it matters, in the upgrades-menu detune readout. There is
no floating 3D label above the car. **Damage never blocks entry** (`_refresh_focus_damage`):
there is no health at which a car stops being raceable — even at 0 HP it drives, just
slowly (see [damage.md](damage.md)) — so Start stays ENABLED at every health level and the
warning is an **instruction**, not a verdict, pointing at the repair the player can go and
buy ("Damaged — the engine is down on power. Repair it at the lift."). It is gated on
`Save.car_handles_badly`, not `car_needs_repair`, so a car at 98% health doesn't get told it
handles badly.

Rally entry is **purely categorical** — body type, country, doors, cylinders,
displacement, drive mode. There is no performance band: a car is never too fast or too
slow for a career rally, only the wrong KIND of car (`RallyLibrary.ineligibility_reason`).
The one restriction the player can fix without changing car is **drive mode**, because a
drivetrain conversion changes it: `_entry_plan` parks such a car as eligible and records
the target mode in `_drivetrain_needed`, and the detail panel counts it under "N need a
drivetrain conversion to fit".

The **"Too powerful" modal** (`_show_over_limit_prompt` → `_make_carpark_modal`, i.e. a
`MenuPage` with `dim`: a full-screen dimmer + centred house panel, NOT a native grey
dialog) therefore belongs to **Rally Challenge only** — the one mode that still enforces a
performance ceiling (as a `CarPerformance` rating, see
[rally-challenge.md](rally-challenge.md)). Its **Change Upgrades** button
(`_detune_change_upgrades`) opens the **Change-Upgrades popup** — the shared
`UpgradesGrid` component (see [upgrade-catalogue.md](upgrade-catalogue.md)) in a
matching centred modal (`_show_upgrades_popup`, engine-swap row dropped, passed the
challenge's rating ceiling; `_make_carpark_modal` hosts it via **`MenuPage.open_modal`** — see
"Hosting a modal" below, which is not optional) so the player can shed performance. Its
close button is the gated **Done** (blocking both the button and back) until the build is
under the ceiling; closing it (`_close_upgrades_popup`) rebuilds the lineup if anything
changed, and the player re-presses Start (**close → re-press**, no auto-launch). Both
modals are wired with `MenuNav.attach` (the upgrades popup hands its gated
`request_close` as `on_back` so Esc is gated too), and `_carpark_modal_open` makes
`_unhandled_input` hand navigation to the modal instead of the lineup beneath. Any fix
the player makes is an ordinary garage edit and **persists after the run**.

The map pin's green "raceable" pennant counts every owned car that fits the restriction
(or could after a drivetrain conversion) — `_has_eligible_car` builds on `_entry_plan`. Rivals field only cars that fit the restriction: the
opponent field is drawn from `RallyLibrary._eligible_cars` (the restriction's own pool). A **banner** names the rally + restriction; **Start** records the
fielded car as the **selected car** (`Save.set_selected_car` in `_begin_rally_start`,
so the tuning lift shows the car last raced), shows the
`LoadingScreen` overlay immediately and (after a fully presented frame, so it paints)
calls `RallySession.start_rally(rally, owned)` — the handoff derives event target
times by generating each track, which is heavy, so the overlay covers that work
instead of freezing HQ. **◄ Back** (or `menu_back`) returns to the map table and
clears the lineup. If no owned car qualifies, a hint shows and Start is disabled.

**Unbounded collection + pagination.** There is **no ownership cap** — the player can
own any number of cars, and there is no "garage full" gate or scrapping (both removed).
Instead every car-park screen **paginates**: `_build_lineup(cars, start_global)` hands
the WHOLE list to `CarList` (`scripts/car_list.gd`, the `_lineup` member) and
`_render_lineup_page` spawns only the current page — at most `GameConfig.carpark_page_size`
(10, the painted-bay count) heavy props at once. `CarList` treats the list as one wrapped
ring: `_cycle_focus` → `_lineup.advance(step)` moves the cursor car-by-car and, when it
crosses a page boundary, flips the page and re-spawns its props (snapping the camera);
past the very first / last car it wraps around (a single page wraps within itself). The
`(n of N)` label counts across the WHOLE list (`_lineup.global_index()` / `total()`). This
is the same machinery for rally car-select, engine-swap, the starter
picker, Free Roam and the title backdrop, so they all page identically.

Star ratings come from `Save.best_placement(rally_id)` — the best (lowest)
finishing position ever recorded there, stored by `Save.record_podium_rally(id, ms,
placed)` on each finish (`RallySession` passes the placement). A rally's
displayed rating is therefore always `RallyLibrary.stars_for_placement` of that
best placement; the SPENDABLE balance shown on the map meter is a separate,
persisted ledger (`record_podium_rally` returns what it credited for THIS finish, which
can be less than the displayed rating on a replay that finished worse) — see
[star-economy.md](star-economy.md).

Each parked car gets its **own duplicated meshes** (`CarProp.dup_meshes`) so a mixed
lineup renders each at its true size despite `car.tscn`'s shared mesh
sub-resources. The shared-`Config.data` write from `apply_owned` is harmless here —
the props don't simulate and `world.gd` re-applies the fielded car's config per run.

### Android app notice (mobile web boot)

Booting the **web build in an Android browser** (`OS.has_feature("web_android")`,
checked by `_should_show_android_app_notice`) shows a one-per-boot overlay over the
title shot: mobile-web performance is poor, so it points the player at the itch.io
page (`ANDROID_APP_URL`) hosting the much-faster APK. Two buttons: **Get the Android
app** (`OS.shell_open` → opens the itch page in a new tab) and **Continue in
browser** (dismiss). Desktop web and iOS never see it (nothing to install there),
and it only appears over a normal title boot.
While the notice is up, `_title_layer` is hidden so the title's MenuNav can't fight
the notice's for focus; dismissing (button, Esc, or gamepad B via the notice's
`MenuNav.attach(..., on_back = ...)`) frees the layer and re-shows the title, whose
MenuNav re-grabs the Start button through `visibility_changed`. Covered by the
Android-notice tests in `tests/headless/test_menu_flow.gd`.

